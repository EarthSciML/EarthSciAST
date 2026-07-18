# Regression test for the exponential-path DAG walk (ESS-1p5).
#
# `_resolve_observed` (tree_walk/helpers.jl) inlines observed-into-observed
# with IDENTITY-PRESERVING substitution (`_sub_preserving`), so resolved
# bodies are compact DAGs: O(n) distinct nodes for a depth-n chain, but
# exponentially many root-to-leaf PATHS when each level references its
# predecessor more than once. `_referenced_var_names` used to walk PATHS
# (plain `foreach_subexpr`), and `_resolve_observed` calls it inside its own
# fixed-point loop — a depth-32 doubling chain (o_k = o_{k-1} + o_{k-1}) cost
# ~2^31 node visits, an effective hang. The fix (`foreach_subexpr_once`,
# expression.jl) memoizes on `OpExpr` identity so the walk is O(distinct
# nodes + edges). These tests pin BOTH properties: memoization must not
# change the collected name set, and the trigger must complete instantly
# (asserted with a wall-clock bound generous enough that machine load can
# never flake it while an exponential regression still trips it: pre-fix the
# depth-32 resolve alone extrapolates to well over 4 minutes).

using Test
using EarthSciAST

include("testutils.jl")  # _n/_v/_op builder quartet + _D

const ESM = EarthSciAST

# The doubling observed chain: o1 = x + x; o_k = o_{k-1} + o_{k-1}.
function _doubling_chain(depth::Int)
    obs = Dict{String,ESM.ASTExpr}("o1" => _op("+", _v("x"), _v("x")))
    for k in 2:depth
        obs["o$k"] = _op("+", _v("o$(k - 1)"), _v("o$(k - 1)"))
    end
    return obs
end

@testset "DAG-memoized subexpression walk (ESS-1p5)" begin

    @testset "foreach_subexpr_once semantics on a shared DAG" begin
        # One shared OpExpr referenced twice; `z` is reachable ONLY through it.
        shared = _op("*", _v("y"), _v("z"))
        expr = _op("+", shared, shared, _v("x"))

        # The un-memoized walk visits `shared` once per PATH (2×); the
        # memoized walk enters it exactly once. Leaves under a shared node
        # are reached through it, so they dedupe with it.
        ops_plain = 0
        ESM.foreach_subexpr(e -> (e isa ESM.OpExpr && (ops_plain += 1); nothing), expr)
        @test ops_plain == 3   # `+` node, `shared` twice

        ops_once = 0
        leaves_once = 0
        ESM.foreach_subexpr_once(expr) do e
            e isa ESM.OpExpr ? (ops_once += 1) : (leaves_once += 1)
            nothing
        end
        @test ops_once == 2    # `+` node, `shared` once
        @test leaves_once == 3 # y, z (via the single `shared` entry), x

        # Memoization must not change RESULTS: the collected name set is
        # exactly right, including a name reachable only through the shared
        # subtree (`z`).
        @test ESM._referenced_var_names(expr) == Set(["x", "y", "z"])

        # `wrt` is still collected (parity with `free_variables`).
        @test ESM._referenced_var_names(_D("u")) == Set(["u", "t"])
    end

    @testset "depth-32 doubling chain through _resolve_observed" begin
        obs = _doubling_chain(32)
        resolved = Dict{String,ESM.ASTExpr}()
        t = @elapsed (resolved = ESM._resolve_observed(obs))
        @test t < 30   # pre-fix: ~2^31 visits, minutes-to-hang; post-fix: ms
        # Fully collapsed: every observed body bottoms out on the state alone.
        @test ESM._referenced_var_names(resolved["o32"]) == Set(["x"])
        @test ESM._referenced_var_names(resolved["o1"]) == Set(["x"])
    end

    @testset "depth-32 doubling chain through build_evaluator" begin
        # Same trigger driven through the full build path that previously
        # detonated inside `_split_observed_and_derivatives`. o32 = 2^32 · x,
        # so the RHS value is exactly checkable.
        depth = 32
        vars = Dict{String,ModelVariable}(
            "x" => ModelVariable(StateVariable; default=1.0))
        eqs = ESM.Equation[ESM.Equation(_v("o1"), _op("+", _v("x"), _v("x")))]
        for k in 2:depth
            push!(eqs, ESM.Equation(_v("o$k"),
                _op("+", _v("o$(k - 1)"), _v("o$(k - 1)"))))
        end
        for k in 1:depth
            vars["o$k"] = ModelVariable(ObservedVariable)
        end
        push!(eqs, ESM.Equation(_D("x"), _v("o$depth")))

        du_val = NaN
        t = @elapsed begin
            f!, u0, p, _tspan, var_map = build_evaluator(ESM.Model(vars, eqs))
            du = similar(u0)
            f!(du, u0, p, 0.0)
            du_val = du[var_map["x"]]
        end
        @test t < 120  # generous: post-fix ~3 s (mostly first-call JIT)
        @test du_val === 2.0^depth
    end
end
