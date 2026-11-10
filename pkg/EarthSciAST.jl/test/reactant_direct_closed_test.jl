# The closed-AST standard-library shapes under direct StableHLO emission
# (ext/reactant_direct/closed.jl), against the in-place interpreter.
#
# OPT-IN, like every reactant_*_test.jl: included only under `ESM_TEST_REACTANT=1`.
# Standalone, from an environment with Reactant + JSON3:
#
#     ESM_TEST_REACTANT=1 julia --project=<env> \
#       -e 'cd("pkg/EarthSciAST.jl/test"); include("reactant_direct_closed_test.jl")'
#
# WHAT IS ASSERTED.
#
#   THE COUNT. A `+` fold from +0.0 of `ifelse(key REL x, 1, 0)` (or its
#   swapped branches) over host-data keys is emitted as ONE count
#   (`:count_fold` in the emitter's tallies), never one compare per key, and the
#   model `D(x[i]) = count` returns the interpreter's value BIT FOR BIT — the
#   count is an integer, so the tolerance classes do not apply to it. Covered:
#   the `searchsorted` template over sorted and unsorted knots with a duplicate,
#   `rank_of` and `rank_of_set` with duplicate members (the term the
#   common-subexpression pass replaces by a cache read), the `<` and `>`
#   relations, a long uniform axis and a long irregular one, and NaN, infinite,
#   signed-zero and on-a-knot queries. A near miss (branch literal 2) is not a
#   count and still agrees.
#
#   THE COMPUTED-SUBSCRIPT CONST READ. The `linear` and `bilinear` templates
#   read their tables at a subscript computed from the state; it lowers
#   (`:const_gather_computed`) because the subscript is provably in range, and
#   agrees within the compiled tier's `algebraic` class. A read whose subscript can leave the array
#   under the `error` policy is refused by name.

using Test
using EarthSciAST
using Reactant
using JSON3

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const CT_RX = Reactant
const CT_EXT = Base.get_extension(EarthSciAST, :EarthSciASTReactantExt)
@assert CT_EXT !== nothing "the Reactant extension did not load"

_ct_o(o, a...) = Dict{String, Any}("op" => o, "args" => Any[a...])
_ct_ix(v, i...) = _ct_o("index", v, i...)
_ct_cst(v) = Dict{String, Any}("op" => "const", "args" => Any[], "value" => v)
_ct_apply(name; kw...) = Dict{String, Any}(
    "op" => "apply_expression_template", "args" => Any[], "name" => name,
    "bindings" => Dict{String, Any}(String(k) => v for (k, v) in kw)
)
_ct_faq(e; out = Any["i"], ranges = Dict{String, Any}("i" => Dict{String, Any}("from" => "p"))) =
    Dict{String, Any}("op" => "faq", "args" => Any[], "output_idx" => out, "ranges" => ranges, "expr" => e)

function _ct_lib(file)
    path = joinpath(TESTUTILS_REPO_ROOT, "lib", file)
    return JSON3.read(read(path, String), Dict{String, Any})["expression_templates"]
end

const CT_X = _ct_ix("x", "i")

# `D(x[i]) = y[i]`, `y[i] = body` over `i in p`; `extra` adds variables and
# equations (a member table).
function _ct_doc(body, libs; np = 12, ng = 6, extra_vars = Dict{String, Any}(), extra_eqs = Any[])
    vars = Dict{String, Any}(
        "x" => Dict{String, Any}("type" => "unknown", "shape" => Any["p"], "default" => 1.0),
        "y" => Dict{String, Any}("type" => "unknown", "shape" => Any["p"]),
    )
    merge!(vars, extra_vars)
    tpl = Dict{String, Any}()
    for f in libs
        merge!(tpl, _ct_lib(f))
    end
    eqs = Any[
        extra_eqs...,
        Dict{String, Any}("lhs" => "y", "rhs" => _ct_faq(body)),
        Dict{String, Any}(
            "lhs" => _ct_faq(Dict{String, Any}("op" => "D", "args" => Any[CT_X], "wrt" => "t")),
            "rhs" => _ct_faq(_ct_ix("y", "i"))
        ),
    ]
    return Dict{String, Any}(
        "esm" => "1.2.0", "metadata" => Dict{String, Any}("name" => "ClosedShapes"),
        "index_sets" => Dict{String, Any}(
            "p" => Dict{String, Any}("kind" => "interval", "size" => np),
            "g" => Dict{String, Any}("kind" => "interval", "size" => ng)
        ),
        "models" => Dict{String, Any}(
            "M" => Dict{String, Any}(
                "variables" => vars, "equations" => eqs, "expression_templates" => tpl
            )
        )
    )
end

_ct_members(vals) = (
    Dict{String, Any}("gx" => Dict{String, Any}("type" => "unknown", "shape" => Any["g"])),
    Any[Dict{String, Any}("lhs" => "gx", "rhs" => _ct_cst(vals))],
)

# The direct program, compiled once, and the interpreter's `f!`.
function _ct_build(doc)
    fo, u0, p, _, vmap = EarthSciAST._build_evaluator(doc; form = :oop)
    fi!, _, _, _, _ = EarthSciAST._build_evaluator(doc)
    d = CT_EXT.direct_rhs(fo; var_map = vmap)
    pr = p === nothing ? nothing : NamedTuple{keys(p)}(map(CT_RX.ConcreteRNumber, values(p)))
    ur = CT_RX.ConcreteRArray(copy(u0)); tr = CT_RX.ConcreteRNumber(0.0)
    compiled = CT_RX.@compile sync = true d(ur, pr, tr)
    run(u) = Array(compiled(CT_RX.ConcreteRArray(copy(u)), pr, CT_RX.ConcreteRNumber(0.0)))
    ref(u) = (du = zero(u); fi!(du, u, p, 0.0); du)
    return d, run, ref, length(u0)
end

# Query states: every edge of a count plus `knots` themselves and their
# neighbours, cycled over `n` cells.
function _ct_states(n, knots)
    pool = Float64[NaN, Inf, -Inf, 0.0, -0.0, -50.0, 50.0]
    for k in knots
        isfinite(k) && append!(pool, (k, prevfloat(k), nextfloat(k)))
    end
    # XLA:CPU flushes subnormals to zero, so a subnormal query compares as a
    # zero in the compiled program; that is the lane's arithmetic, not the
    # count's, and it is left out here.
    filter!(!issubnormal, pool)
    states = Vector{Float64}[]
    for s in 0:cld(length(pool), n)
        push!(states, Float64[pool[mod1(s * n + j, length(pool))] for j in 1:n])
    end
    return states
end

# Bit equality, naming the cells that differ when it fails.
function _ct_bits(a, b, u)
    ok = length(a) == length(b)
    for i in eachindex(a)
        isequal(a[i], b[i]) && continue
        println("    query ", u[i], ": compiled ", a[i], ", interpreter ", b[i])
        ok = false
    end
    return ok
end

function _ct_count_case(label, doc, knots; want_count = true)
    d, run, ref, n = _ct_build(doc)
    @testset "$label" begin
        @test (get(d.stats, :count_fold, 0) >= 1) == want_count
        for u in _ct_states(n, knots)
            @test _ct_bits(run(u), ref(u), u)
        end
    end
    return d
end

@testset "direct emission of the closed-AST library shapes" begin
    sorted8 = [0.0, 0.5, 1.0, 1.0, 1.5, 2.0, 2.5, 3.0]
    unsorted8 = [1.5, 0.0, 3.0, 1.0, 2.5, 1.0, 0.5, 2.0]
    dupes = [0.5, 1.0, 1.5, 1.0, 2.0, 2.5]

    @testset "the count is one count, and the interpreter's integer" begin
        _ct_count_case(
            "searchsorted, sorted knots with a duplicate",
            _ct_doc(_ct_apply("searchsorted"; x = CT_X, xs = _ct_cst(sorted8), n = 8), ["interp.esm"]),
            sorted8
        )
        _ct_count_case(
            "searchsorted, unsorted knots",
            _ct_doc(_ct_apply("searchsorted"; x = CT_X, xs = _ct_cst(unsorted8), n = 8), ["interp.esm"]),
            unsorted8
        )
        _ct_count_case(
            "rank_of over literal members",
            _ct_doc(_ct_apply("rank_of"; x = CT_X, members = _ct_cst(dupes), n = 6), ["relational.esm"]),
            dupes
        )
        mv, me = _ct_members(dupes)
        _ct_count_case(
            "rank_of_set over members with a duplicate (a cached term)",
            _ct_doc(
                _ct_apply("rank_of_set"; x = CT_X, members = "gx", S = "g"), ["relational.esm"];
                extra_vars = mv, extra_eqs = me
            ),
            dupes
        )
        for (rel, yes, no) in (("<", 1, 0), (">", 1, 0), (">", 0, 1), ("<=", 0, 1))
            body = _ct_faq(
                _ct_o("ifelse", _ct_o(rel, _ct_ix("gx", "k"), CT_X), yes, no);
                out = Any[], ranges = Dict{String, Any}("k" => Dict{String, Any}("from" => "g"))
            )
            body["reduce"] = "+"
            _ct_count_case(
                "key $rel query, branches ($yes, $no)",
                _ct_doc(body, String[]; extra_vars = mv, extra_eqs = me), dupes
            )
        end
        uniform = [0.25 * k for k in 0:63]
        _ct_count_case(
            "a long uniform axis",
            _ct_doc(_ct_apply("searchsorted"; x = CT_X, xs = _ct_cst(uniform), n = 64), ["interp.esm"]),
            uniform
        )
        irregular = sort([mod(0.618 * k^1.3, 16.0) for k in 1:64])
        _ct_count_case(
            "a long irregular axis",
            _ct_doc(_ct_apply("searchsorted"; x = CT_X, xs = _ct_cst(irregular), n = 64), ["interp.esm"]),
            irregular
        )
        near = _ct_faq(
            _ct_o("ifelse", _ct_o("<=", _ct_ix("gx", "k"), CT_X), 2, 0);
            out = Any[], ranges = Dict{String, Any}("k" => Dict{String, Any}("from" => "g"))
        )
        near["reduce"] = "+"
        _ct_count_case(
            "near miss: branch literal 2 is an ordinary fold",
            _ct_doc(near, String[]; extra_vars = mv, extra_eqs = me), dupes;
            want_count = false
        )
    end

    @testset "computed-subscript table reads in the interp templates" begin
        axis = [0.0, 0.5, 1.25, 2.0, 3.5]
        table = [1.0, 0.25, 4.0, -2.0, 9.0]
        lin = _ct_doc(
            _ct_apply("linear"; table = _ct_cst(table), axis = _ct_cst(axis), x = CT_X, n = 5),
            ["interp.esm"]
        )
        t2 = [[1.0, 2.0, 0.5, 3.0], [0.0, -1.0, 2.5, 4.0], [5.0, 1.5, 2.0, -0.5]]
        bil = _ct_doc(
            _ct_apply(
                "bilinear"; table = _ct_cst(t2), axis_x = _ct_cst([0.0, 1.0, 2.5]),
                axis_y = _ct_cst([0.0, 0.75, 1.5, 3.0]), x = CT_X,
                y = _ct_o("+", 0.2, _ct_o("*", 0.9, CT_X)), nx = 3, ny = 4
            ),
            ["interp.esm"]
        )
        for (label, doc, knots) in (("linear", lin, axis), ("bilinear", bil, [0.0, 1.0, 2.5]))
            d, run, ref, n = _ct_build(doc)
            @testset "$label" begin
                @test get(d.stats, :const_gather_computed, 0) >= 1
                worst = 0.0
                for u in _ct_states(n, knots)
                    a, b = run(u), ref(u)
                    # The `algebraic` class of the compiled tier: the blend is
                    # the template's own arithmetic, which XLA may contract
                    # into fused multiply-adds. NaN where the interpreter has NaN.
                    @test all(
                        isequal(a[i], b[i]) || isapprox(a[i], b[i]; rtol = 1.0e-13, atol = 0.0)
                            for i in eachindex(a)
                    )
                    for i in eachindex(a)
                        isequal(a[i], b[i]) ||
                            (worst = max(worst, abs(a[i] - b[i]) / abs(b[i])))
                    end
                end
                println("  ", label, " template: worst relative difference ", worst)
            end
        end
    end

    @testset "a table read that can leave the array is refused by name" begin
        doc = _ct_doc(
            _ct_ix(_ct_cst([1.0, 2.0, 3.0]), _ct_o("floor", CT_X)), String[]
        )
        fo, u0, p, _, vmap = EarthSciAST._build_evaluator(doc; form = :oop)
        d = CT_EXT.direct_rhs(fo; var_map = vmap)
        err = try
            CT_RX.@compile sync = true d(
                CT_RX.ConcreteRArray(copy(u0)), nothing, CT_RX.ConcreteRNumber(0.0)
            )
            nothing
        catch e
            e
        end
        de = EarthSciAST._find_direct_emit_error(err)
        @test de isa EarthSciAST.DirectEmitError
        @test occursin("computed subscript", de.construct)
    end
end
