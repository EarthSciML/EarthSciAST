# The shared scalar pieces of the compiled IR (src/tree_walk/scalar_ops.jl):
# the operator ladder every consumer of a build evaluates an `_NK_OP` node
# through, and the resolver that turns a gather subscript into an `Int`. Plus
# the one thing an out-of-place build says when it is called: that it is the
# compiled IR, not a host evaluator.
#
# The ladder is a THIRD implementation beside `_eval_node_op` (the scalar walker)
# and `_eval_acc_op` (the access-kernel lane walker), and a compiled backend
# folds constant subtrees through THIS one at Float64 so a folded subtree is
# bit-identical to what `f!` computes. So it is pinned by differential test
# against the scalar walker: same op, same arguments, same value, bit for bit.

using Test
using EarthSciAST

include("testutils.jl")

const ESM = EarthSciAST

@testset "shared scalar op ladder and subscript resolver" begin

@testset "the shared ladder covers every op the scalar ladder does" begin
    # `_scalar_op` is a THIRD op ladder beside `_eval_node_op` and `_eval_acc_op`.
    # Pin it to the scalar one by differential test: same op, same args, same
    # value — bit for bit. A registry op added without an `_scalar_op` arm fails here
    # rather than at some user's first `form = :oop` build.
    u = [0.3, -0.8]
    p = (a = 1.7,)
    t = 0.5
    lit(x) = ESM._mknode(kind = ESM._NK_LITERAL, literal = x)
    scalar(op, vals) = ESM._eval_node(
        ESM._mknode(kind = ESM._NK_OP, op = op,
                    children = ESM._Node[lit(v) for v in vals]), u, p, t)

    # Every mechanical unary op, straight from the registry that generates the arm.
    for row in ESM._UNARY_ELEMENTWISE_OPS
        x = row.sym in (:sqrt, :log, :log10, :acosh) ? 1.7 :
            row.sym in (:asin, :acos, :atanh) ? 0.4 : 0.6
        @test ESM._scalar_op(row.sym, [x], Float64) == scalar(row.sym, [x])
    end

    # The structurally distinct arms, including every arity that has its own path.
    cases = Any[
        (:+, [1.5]), (:+, [1.5, 2.25]), (:+, [1.5, 2.25, -0.5]),
        (:*, [1.5]), (:*, [1.5, 2.25]), (:*, [1.5, 2.25, -0.5]),
        (:-, [1.5]), (:-, [1.5, 2.25]),
        (:neg, [1.5]), (:/, [1.5, 2.0]), (:^, [1.5, 3.0]), (:pow, [1.5, 3.0]),
        (:<, [1.0, 2.0]), (:<, [2.0, 1.0]),
        (Symbol("<="), [2.0, 2.0]), (:>, [1.0, 2.0]), (Symbol(">="), [2.0, 2.0]),
        (Symbol("=="), [2.0, 2.0]), (Symbol("!="), [2.0, 2.0]),
        (:and, [1.0, 0.0]), (:and, [1.0, 3.0]), (:or, [0.0, 0.0]), (:or, [0.0, 2.0]),
        (:not, [0.0]), (:not, [1.0]),
        (:ifelse, [1.0, 7.0, 9.0]), (:ifelse, [0.0, 7.0, 9.0]),
        (:atan, [0.7]), (:atan, [0.7, 1.3]), (:atan2, [0.7, 1.3]),
        (:min, [3.0, 1.0]), (:min, [3.0, 1.0, 2.0]),
        (:max, [3.0, 1.0]), (:max, [3.0, 1.0, 2.0]),
        (:pi, Float64[]), (:e, Float64[]), (:Pre, [4.25]),
    ]
    for (op, vals) in cases
        @test ESM._scalar_op(op, vals, Float64) == scalar(op, vals)
    end
end

@testset "a gather subscript resolves to a build-time integer, or says why not" begin
    lit(x) = ESM._mknode(kind = ESM._NK_LITERAL, literal = x)
    op(o, cs...) = ESM._mknode(kind = ESM._NK_OP, op = o,
                               children = ESM._Node[cs...])
    @test ESM._index_int(lit(4.0)) == 4
    @test ESM._index_int(op(:+, lit(2.0), lit(3.0), lit(1.0))) == 6
    @test ESM._index_int(op(:-, lit(7.0))) == -7
    @test ESM._index_int(op(:-, lit(7.0), lit(2.0))) == 5
    @test ESM._index_int(op(:*, lit(3.0), lit(4.0))) == 12
    @test ESM._index_int(op(:/, lit(7.0), lit(2.0))) == 3

    # The enclosing runtime contraction loop's counter, read through its `Ref`.
    r = Ref(5)
    lv = ESM._mknode(kind = ESM._NK_LOOPVAR, payload = r)
    @test ESM._index_int(lv) == 5
    r[] = 9
    @test ESM._index_int(lv) == 9
    @test ESM._index_int(op(:+, lv, lit(1.0))) == 10

    # A frozen array read at a computed offset: the subscripts resolve, the
    # column-major stride arithmetic picks the element, and the VALUE is itself
    # an index (a connectivity table is the live case).
    cg = ESM._ConstGatherArray(Float64[11, 12, 13, 21, 22, 23], [1, 3], [3, 2],
                               [:error, :error], "table")
    gat(i, j) = ESM._mknode(kind = ESM._NK_CONST_GATHER, payload = cg,
                            children = ESM._Node[lit(Float64(i)), lit(Float64(j))])
    @test ESM._index_int(gat(1, 1)) == 11
    @test ESM._index_int(gat(3, 2)) == 23
    @test ESM._index_int(op(:+, gat(2, 1), lit(1.0))) == 13
    # Each subscript answers to its OWN axis: an overflow on a non-final axis
    # stays inside the flattened buffer, so a check on the linearized offset
    # alone would read the neighbouring column instead of refusing.
    for oob in (gat(4, 1), gat(4, 2), gat(1, 3))
        err = try
            ESM._index_int(oob); nothing
        catch e
            e
        end
        @test err isa ESM.TreeWalkError
        @test err.code == "E_TREEWALK_CONSTARRAY_OOB"
    end

    # A subscript computed from the STATE is the one thing that cannot resolve:
    # a backend would need the value to pick a slot, so this refuses by name
    # rather than lowering something that silently reads the wrong element.
    st = ESM._mknode(kind = ESM._NK_STATE, idx = 1)
    err = try
        ESM._index_int(st); nothing
    catch e
        e
    end
    @test err isa ESM.TreeWalkError
    @test err.code == "E_TREEWALK_TRACED_SUBSCRIPT"
    @test occursin("out-of-place gather subscript", sprint(showerror, err))
end

# An out-of-place build is the compiled IR, not a host evaluator: calling it
# says so by CODE, and the message names both ways out (compile it, or build
# `form = :inplace`). A consumer that probes the form by method applicability
# still reads it as out-of-place — three arguments, never four — which is what
# `EarthSciASTDiff` does, so that pair is pinned here too.
@testset "an out-of-place build refuses host evaluation, by name" begin
    doc = Dict{String,Any}("esm" => "1.0.0", "metadata" => Dict("name" => "sop"),
        "models" => Dict("M" => Dict{String,Any}(
            "variables" => Dict("a" => Dict("type" => "unknown", "default" => 2.0)),
            "equations" => Any[Dict("lhs" => Dict("op" => "D", "wrt" => "t",
                                                  "args" => Any["a"]),
                                    "rhs" => Dict("op" => "*",
                                                  "args" => Any[-1.0, "a"]))])))
    fo, u0, p, _, _ = ESM._build_evaluator(doc; form = :oop)
    @test applicable(fo, zeros(1), p, 0.0)              # reads as out-of-place …
    @test !applicable(fo, zeros(1), zeros(1), p, 0.0)   # … and never as in-place
    err = try
        fo(u0, p, 0.0); nothing
    catch e
        e
    end
    @test err isa ESM.TreeWalkError
    @test err.code == "E_TREEWALK_OOP_NOT_EVALUABLE"
    msg = sprint(showerror, err)
    # It names the two PUBLIC ways out, never the private build.
    @test occursin("compiler = :xla", msg)
    @test occursin("prob.f!", msg)
    @test !occursin("_build_evaluator", msg)
end

end
