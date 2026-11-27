# promote_downstream_shapes: consumer-side gathers for newly promoted variables.
#
# `promote_downstream_shapes` lifts a scalar-authored physics chain fed by array
# sources (Fast-JX j-rates fed by [lon,lat,lev] met fields) into the grid shape
# and rewrites each promoted variable's OWN defining equation into a `faq`. A
# pointwise-lifted species ODE indexes only the operands that carried a shape AT
# FLATTEN TIME, so the pass also rewrites bare references to newly promoted
# variables inside loop-carrying faq bodies into `index(var, <loops>)` gathers
# bound in the body's own scope (name-aligned against the ranges' index sets;
# positional over the producer's `output_idx` as fallback); each consumer
# equation iterates its OWN loop names.
using Test
import EarthSciAST as ESS
const E = ESS

op(o, a...) = Dict{String, Any}("op" => o, "args" => collect(Any, a))
ix(a...) = Dict{String, Any}("op" => "index", "args" => collect(Any, a))
isref(n) = Dict{String, Any}("from" => n)
agg(oi, ranges, body) = Dict{String, Any}(
    "op" => "faq",
    "semiring" => "sum_product", "output_idx" => oi, "ranges" => ranges,
    "args" => Any[], "expr" => body
)

roundtrip(d) = E.flatten(ESS.coerce_esm_file(ESS.JSON3.read(ESS.JSON3.write(d))))

# Record `state` as pointwise-lifted over `extents`, as the §10.5 lift does: a
# bare name in a lifted equation's `faq` body was put there by the lift, so the
# consumer rewrite gathers it. In an AUTHORED `faq` body the same bare read is
# `faq_bare_array_operand` (esm-spec §4.3.1).
as_lifted(flat, state, extents) = E.FlattenedSystem(
    flat; lifted_shapes = ESS.OrderedDict{String, Vector{Int}}(state => extents)
)

# The distilled Fast-JX structural pattern: an array source f[c], a
# scalar-authored rate j = f*2 (promoted to [c] only by
# promote_downstream_shapes), and a pre-lifted per-cell species ODE — the shape
# a §10.5 pointwise lift produces — whose aggregate body references `j` BARE:
#   aggregate[i∈c]( D(s[i],t) ) = aggregate[i∈c]( j * s[i] )
function lifted_consumer_doc()
    lhs = agg(
        Any["i"], Dict{String, Any}("i" => isref("c")),
        Dict{String, Any}("op" => "D", "args" => Any[ix("s", "i")], "wrt" => "t")
    )
    rhs = agg(
        Any["i"], Dict{String, Any}("i" => isref("c")),
        op("*", "j", ix("s", "i"))
    )
    return Dict{String, Any}(
        "esm" => "0.5.0", "metadata" => Dict("name" => "P"),
        "index_sets" => Dict{String, Any}("c" => Dict{String, Any}("kind" => "interval", "size" => 3)),
        "models" => Dict{String, Any}(
            "M" => Dict{String, Any}(
                "variables" => Dict{String, Any}(
                    "f" => Dict{String, Any}("type" => "parameter", "shape" => Any["c"]),
                    # esm 1.0.0 §6.3: `j` is an `unknown` DEFINED by its bare-LHS equation.
                    "j" => Dict{String, Any}("type" => "unknown"),
                    "s" => Dict{String, Any}("type" => "unknown", "shape" => Any["c"])
                ),
                "equations" => Any[
                    Dict{String, Any}("lhs" => "j", "rhs" => op("*", "f", 2)),
                    Dict{String, Any}("lhs" => lhs, "rhs" => rhs),
                ]
            )
        )
    )
end

# The CONSUMER equation's RHS — the one that references the promoted variable.
#
# Selected by its LHS being structured (an indexed-`faq` LHS in the array cases,
# `D(z)` in the contracted-reduction case) rather than a bare variable: shape
# promotion also lifts the promoted observed `M.j` itself into an array
# producer, so more than one equation now carries a `faq` RHS, and the promoted
# observed is exactly the bare-variable-LHS definition.
#
# The lift and the consumer carry the same node, `faq`
# (docs/content/rfcs/faq-node-rename.md), so they cannot be told apart by tag.
# This helper does not mean "the only `faq`"; it means "the consumer".
consumer_rhs(sys) = only(
    eq for eq in sys.equations
        if eq.rhs isa E.OpExpr && eq.rhs.op == "faq" &&
        !(eq.lhs isa E.VarExpr)
).rhs

@testset "consumer refs to promoted vars are gathered in-loop" begin
    flat = as_lifted(roundtrip(lifted_consumer_doc()), "M.s", [3])
    pre = E.algebraic_states_to_observeds(flat)

    @testset "with the fix: bare ref becomes an in-scope gather, evaluates" begin
        prom = E.promote_downstream_shapes(pre)
        @test prom.observed_variables["M.j"].shape == ["c"]
        body = consumer_rhs(prom).expr_body
        # j is gathered at the lift's OWN loop (`i`), not left bare.
        gathers = [
            c for c in E.child_exprs(body)
                if c isa E.OpExpr && c.op == "index" &&
                c.args[1] == E.VarExpr("M.j")
        ]
        @test length(gathers) == 1
        @test gathers[1].args[2:end] == E.ASTExpr[E.VarExpr("i")]
        f!, u0, p, _t, vmap = E.Internal.build(
            prom;
            const_arrays = Dict("M.f" => [1.0, 2.0, 3.0]),
            initial_conditions = Dict("M.s[$i]" => 1.0 for i in 1:3)
        )
        du = similar(u0); f!(du, u0, p, 0.0)
        # f=[1,2,3] → j=[2,4,6]; s≡1 → D(s[i]) = j[i]·s[i] = j[i]
        for (i, expect) in zip(1:3, (2.0, 4.0, 6.0))
            @test du[vmap["M.s[$i]"]] ≈ expect
        end
    end
end

@testset "contracted-loop consumer: env binds ranges, not just output_idx" begin
    # A SCALAR reduction consuming the promoted var bare: D(z,t) = Σ_{k∈c} j.
    # The loop `k` is CONTRACTED (empty output_idx) — the case the downstream
    # per-equation workaround skipped and the ranges-scoped env closes.
    red = agg(Any[], Dict{String, Any}("k" => isref("c")), "j")
    d = Dict{String, Any}(
        "esm" => "0.5.0", "metadata" => Dict("name" => "P"),
        "index_sets" => Dict{String, Any}("c" => Dict{String, Any}("kind" => "interval", "size" => 3)),
        "models" => Dict{String, Any}(
            "M" => Dict{String, Any}(
                "variables" => Dict{String, Any}(
                    "f" => Dict{String, Any}("type" => "parameter", "shape" => Any["c"]),
                    "j" => Dict{String, Any}("type" => "unknown"),
                    "z" => Dict{String, Any}("type" => "unknown")
                ),
                "equations" => Any[
                    Dict{String, Any}("lhs" => "j", "rhs" => op("*", "f", 2)),
                    Dict{String, Any}(
                        "lhs" => Dict{String, Any}("op" => "D", "args" => Any["z"], "wrt" => "t"),
                        "rhs" => red
                    ),
                ]
            )
        )
    )
    flat = roundtrip(d)
    # The rewrite binds the contracted loop: `j` is read at `k`.
    body = E._index_promoted_consumer_refs(
        consumer_rhs(flat), Set(["M.j"]), Dict("M.j" => ["c"])
    ).expr_body
    @test body isa E.OpExpr && body.op == "index" &&
        body.args == E.ASTExpr[E.VarExpr("M.j"), E.VarExpr("k")]
    # Authored, the same bare read of the now-array `j` is refused rather than
    # aligned by the rewrite (esm-spec §4.3.1).
    err = try
        E.promote_downstream_shapes(flat)
        nothing
    catch e
        e
    end
    @test err isa E.DimensionPromotionError && err.code == "faq_bare_array_operand"
end

@testset "name alignment transposes a permuted-shape operand" begin
    # g[d,c] seeds jj with shape [d,c]; the consumer body iterates [i∈c, k∈d]
    # (the PERMUTED order). The gather must follow jj's DECLARED axis order —
    # index(jj, k, i) — not the loop order, or c≠d would mis-shape / transpose.
    lhs = agg(
        Any["i", "k"],
        Dict{String, Any}("i" => isref("c"), "k" => isref("d")),
        Dict{String, Any}("op" => "D", "args" => Any[ix("s2", "i", "k")], "wrt" => "t")
    )
    rhs = agg(
        Any["i", "k"],
        Dict{String, Any}("i" => isref("c"), "k" => isref("d")),
        op("*", "jj", ix("s2", "i", "k"))
    )
    d = Dict{String, Any}(
        "esm" => "0.5.0", "metadata" => Dict("name" => "P"),
        "index_sets" => Dict{String, Any}(
            "c" => Dict{String, Any}("kind" => "interval", "size" => 3),
            "d" => Dict{String, Any}("kind" => "interval", "size" => 2)
        ),
        "models" => Dict{String, Any}(
            "M" => Dict{String, Any}(
                "variables" => Dict{String, Any}(
                    "g" => Dict{String, Any}("type" => "parameter", "shape" => Any["d", "c"]),
                    "jj" => Dict{String, Any}("type" => "unknown"),
                    "s2" => Dict{String, Any}("type" => "unknown", "shape" => Any["c", "d"])
                ),
                "equations" => Any[
                    Dict{String, Any}("lhs" => "jj", "rhs" => op("*", "g", 2)),
                    Dict{String, Any}("lhs" => lhs, "rhs" => rhs),
                ]
            )
        )
    )
    prom = E.promote_downstream_shapes(as_lifted(roundtrip(d), "M.s2", [3, 2]))
    @test prom.observed_variables["M.jj"].shape == ["d", "c"]
    body = consumer_rhs(prom).expr_body
    gathers = [
        c for c in E.child_exprs(body)
            if c isa E.OpExpr && c.op == "index" && c.args[1] == E.VarExpr("M.jj")
    ]
    @test length(gathers) == 1
    # Declared-axis order [d,c] → loops (k, i), NOT the body's (i, k).
    @test gathers[1].args[2:end] == E.ASTExpr[E.VarExpr("k"), E.VarExpr("i")]
end

@testset "scalar-position refs stay bare (post-discretize contract)" begin
    # The wildfire/level-set path: an un-discretized spatial state equation
    # references the promoted chain in SCALAR position. Its loops do not exist
    # until `discretize`, so the promote pass leaves it bare.
    d = Dict{String, Any}(
        "esm" => "0.5.0", "metadata" => Dict("name" => "P"),
        "index_sets" => Dict{String, Any}("c" => Dict{String, Any}("kind" => "interval", "size" => 3)),
        "models" => Dict{String, Any}(
            "M" => Dict{String, Any}(
                "variables" => Dict{String, Any}(
                    "f" => Dict{String, Any}("type" => "parameter", "shape" => Any["c"]),
                    "j" => Dict{String, Any}("type" => "unknown"),
                    "psi" => Dict{String, Any}("type" => "unknown", "shape" => Any["c"])
                ),
                "equations" => Any[
                    Dict{String, Any}("lhs" => "j", "rhs" => op("*", "f", 2)),
                    Dict{String, Any}(
                        "lhs" => Dict{String, Any}("op" => "D", "args" => Any["psi"], "wrt" => "t"),
                        "rhs" => op("-", "j")
                    ),
                ]
            )
        )
    )
    prom = E.promote_downstream_shapes(roundtrip(d))
    deq = only(
        eq for eq in prom.equations
            if eq.lhs isa E.OpExpr && eq.lhs.op == "D"
    )
    @test deq.rhs isa E.OpExpr && deq.rhs.args == E.ASTExpr[E.VarExpr("M.j")]
end

@testset "explicitly indexed consumers are untouched (M2-1 contract)" begin
    # The original M2-1 fixture indexes the promoted chain EXPLICITLY
    # (`index(b,k)`); the consumer pass must not rewrap it.
    aggd = agg(Any[], Dict{String, Any}("k" => isref("c")), ix("b", "k"))
    d = Dict{String, Any}(
        "esm" => "0.5.0", "metadata" => Dict("name" => "P"),
        "index_sets" => Dict{String, Any}("c" => Dict{String, Any}("kind" => "interval", "size" => 3)),
        "models" => Dict{String, Any}(
            "M" => Dict{String, Any}(
                "variables" => Dict{String, Any}(
                    "f" => Dict{String, Any}("type" => "parameter", "shape" => Any["c"]),
                    "a" => Dict{String, Any}("type" => "unknown"),
                    "b" => Dict{String, Any}("type" => "unknown"),
                    "s" => Dict{String, Any}("type" => "unknown")
                ),
                "equations" => Any[
                    Dict{String, Any}("lhs" => "a", "rhs" => op("*", "f", 2)),
                    Dict{String, Any}("lhs" => "b", "rhs" => op("+", "a", "f")),
                    Dict{String, Any}(
                        "lhs" => Dict{String, Any}("op" => "D", "args" => Any["s"], "wrt" => "t"), "rhs" => aggd
                    ),
                ]
            )
        )
    )
    flat = roundtrip(d)
    prom = E.promote_downstream_shapes(flat)
    f!, u0, p, _t, vmap = E.Internal.build(
        prom;
        const_arrays = Dict("M.f" => [1.0, 2.0, 3.0]), initial_conditions = Dict("M.s" => 0.0)
    )
    du = similar(u0); f!(du, u0, p, 0.0)
    @test du[vmap["M.s"]] ≈ 18.0
end
