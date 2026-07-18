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

# An IN-MEMORY doubling DAG over `leaf`: depth levels of `n = n + n` where BOTH
# args are the SAME object — O(depth) distinct nodes, 2^depth root-to-leaf
# paths. This is the compact-sharing shape `_sub_preserving` / template
# lowering produce; any per-path walk detonates on it.
function _doubling_dag(leaf::ESM.ASTExpr, depth::Int)
    e = leaf
    for _ in 1:depth
        e = _op("+", e, e)
    end
    return e
end

# The elementwise ARRAY-observed trigger (ESS-0hh): a spatial state psi[c] with
# an elementwise array observed a = psi + psi and a second array observed b
# whose RAW body is a depth-`depth` doubling DAG over `a`. Both fold via
# `_fold_elementwise_array_observeds` (WS4), so D(psi) = b detonates the
# fold's per-path `free_variables` dependency scan and its sharing-destroying
# `substitute` pre-fix — and every downstream build stage post-fold.
# b = 2^depth · a = 2^(depth+1) · psi, so the RHS value is exactly checkable.
function _elemwise_array_chain_model(depth::Int)
    vars = Dict{String,ModelVariable}(
        "psi" => ModelVariable(StateVariable; shape=["c"]),
        "a"   => ModelVariable(ObservedVariable; shape=["c"]),
        "b"   => ModelVariable(ObservedVariable; shape=["c"]),
    )
    eqs = ESM.Equation[
        ESM.Equation(_v("a"), _op("+", _v("psi"), _v("psi"))),
        ESM.Equation(_v("b"), _doubling_dag(_v("a"), depth)),
        ESM.Equation(_D("psi"), _v("b")),
    ]
    return ESM.Model(vars, eqs)
end

const _CHAIN_INDEX_SETS = Dict("c" => ESM.IndexSet("interval"; size=3))
const _CHAIN_ICS = Dict("psi[1]" => 1.0, "psi[2]" => 2.0, "psi[3]" => 3.0)

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

    # ================================================================
    # ESS-0hh: the remaining exposed walks.
    # ================================================================

    @testset "small-depth probe: the array trigger reaches the WS4 fold" begin
        # The regression below is only meaningful if the model actually routes
        # through `_fold_elementwise_array_observeds` — pin that directly.
        model = _elemwise_array_chain_model(3)
        _eqs2, folded = ESM._fold_elementwise_array_observeds(model.equations, model)
        @test folded == Set(["a", "b"])
        f!, u0, p, _t, vmap = build_evaluator(model;
            index_sets=_CHAIN_INDEX_SETS, initial_conditions=_CHAIN_ICS)
        # Folded observeds carry no ODE slots; values are exact powers of two.
        @test !any(k -> occursin(r"^[ab]\[", k), keys(vmap))
        du = similar(u0)
        f!(du, u0, p, 0.0)
        for (i, ic) in zip(1:3, (1.0, 2.0, 3.0))
            @test du[vmap["psi[$i]"]] === 2.0^4 * ic
        end
    end

    @testset "depth-32 elementwise ARRAY-observed chain through build_evaluator" begin
        # Pre-fix this detonated in `_fold_elementwise_array_observeds`
        # (per-path `free_variables` deps scan, then the non-memoized
        # `substitute` re-inflating the resolved body into a 2^32-node TREE)
        # and, once the fold was DAG-safe, in a cascade of downstream
        # per-path walks (`_resolve_isr`, `_branch_key!`, `_lower_to_access`,
        # `_build_acc_cse`, …). Post-fix the whole build is O(depth).
        depth = 32
        model = _elemwise_array_chain_model(depth)
        local du, vmap
        t = @elapsed begin
            f!, u0, p, _t, vmap = build_evaluator(model;
                index_sets=_CHAIN_INDEX_SETS, initial_conditions=_CHAIN_ICS)
            du = similar(u0)
            f!(du, u0, p, 0.0)
        end
        @test t < 120   # generous; post-fix ~10 ms after JIT warm-up
        for (i, ic) in zip(1:3, (1.0, 2.0, 3.0))
            @test du[vmap["psi[$i]"]] === 2.0^(depth + 1) * ic
        end
    end

    @testset "_count_obs_refs! path-multiplicity DP on a shared DAG" begin
        names = Set(["g"])
        # A depth-20 doubling DAG: totals must equal the PER-PATH enumeration
        # (2^20 occurrences of `g`), not the distinct-node count — the demotion
        # rule's semantics — while completing in O(depth).
        deep = _doubling_dag(_v("g"), 20)
        tot = Dict{String,Int}(); unc = Dict{String,Int}()
        t = @elapsed ESM._count_obs_refs!(deep, names, tot, unc, false)
        @test t < 10
        @test tot["g"] == 2^20
        @test unc["g"] == 2^20
        # A guard above the shared DAG forwards NO unconditional multiplicity.
        guarded = _op("ifelse", _v("c"), deep, _n(0.0))
        tot2 = Dict{String,Int}(); unc2 = Dict{String,Int}()
        ESM._count_obs_refs!(guarded, names, tot2, unc2, false)
        @test tot2["g"] == 2^20
        @test get(unc2, "g", 0) == 0
        # Small-tree reference values (identical to the old per-path recursion):
        # g*g contributes (2 tot, 2 unc); ifelse(q, g, g) contributes (2 tot,
        # 0 unc — both branches are lazy).
        small = _op("+", _op("*", _v("g"), _v("g")),
                    _op("ifelse", _v("q"), _v("g"), _v("g")))
        tot3 = Dict{String,Int}(); unc3 = Dict{String,Int}()
        ESM._count_obs_refs!(small, names, tot3, unc3, false)
        @test tot3["g"] == 4
        @test unc3["g"] == 2
        # Barrier ops (index/aggregate/makearray) tally DISTINCT names once per
        # PATH to the barrier: a shared gather reached twice contributes 2.
        gat = _op("index", _v("arr"), _op("+", _v("g"), _v("g")))
        both = _op("+", gat, gat)
        tot4 = Dict{String,Int}(); unc4 = Dict{String,Int}()
        ESM._count_obs_refs!(both, names, tot4, unc4, false)
        @test tot4["g"] == 2
        @test get(unc4, "g", 0) == 0
    end

    @testset "observed-slot demotion decisions unchanged on a shared-subtree fixture" begin
        # `g`'s only references sit under a lazy guard, reached through ONE
        # shared subtree object — guard-only ⇒ demoted (inlined), exactly as
        # the per-path counter decided (tree_walk_observed_slots_test is the
        # broader pin; this one drives the SHARED shape specifically).
        S = _op("+", _v("g"), _v("g"))     # one object, shared below
        vars = Dict{String,ModelVariable}(
            "x" => ModelVariable(StateVariable; default=0.5),
            "k" => ModelVariable(ParameterVariable; default=2.0),
            "g" => ModelVariable(ObservedVariable),
        )
        eqs = ESM.Equation[
            ESM.Equation(_v("g"), _op("*", _v("x"), _v("k"))),
            ESM.Equation(_D("x"),
                _op("ifelse", _op(">", _v("x"), _n(0.0)), S, _n(0.0))),
        ]
        f!, u0, p, _ts, vm, diag = ESM._build_evaluator_impl(ESM.Model(vars, eqs))
        @test diag.n_obs_slots == 0     # guard-only → demoted
        @test diag.n_obs_inlined == 1
        du = similar(u0)
        f!(du, u0, p, 0.0)
        @test du[vm["x"]] === 2 * (0.5 * 2.0)

        # One additional UNCONDITIONAL reader through the SAME shared subtree
        # flips it to a slot (unconditional multiplicity ≥ 1).
        vars2 = copy(vars)
        vars2["y"] = ModelVariable(StateVariable; default=1.0)
        eqs2 = ESM.Equation[
            ESM.Equation(_v("g"), _op("*", _v("x"), _v("k"))),
            ESM.Equation(_D("x"),
                _op("ifelse", _op(">", _v("x"), _n(0.0)), S, _n(0.0))),
            ESM.Equation(_D("y"), S),
        ]
        f2!, u02, p2, _ts2, vm2, diag2 =
            ESM._build_evaluator_impl(ESM.Model(vars2, eqs2))
        @test diag2.n_obs_slots == 1
        @test diag2.n_obs_inlined == 0
        du2 = similar(u02)
        f2!(du2, u02, p2, 0.0)
        @test du2[vm2["x"]] === 2 * (0.5 * 2.0)
        @test du2[vm2["y"]] === 2 * (0.5 * 2.0)
    end

    @testset "_obs_structural_refs! (node, mode) memo keeps structural hits" begin
        names = Set(["o"])
        # `shared` is reached FIRST in an EXPRESSION position (spine mode — its
        # `o` is not a structural hit) and THEN as a gather SUBSCRIPT
        # (mark-all mode — every reference below is a hit). A node-identity-only
        # memo would skip the second visit and drop the hit; the (node, mode)
        # bits must re-enter it.
        shared = _op("+", _v("o"), _n(1.0))
        e = _op("*", _op("sin", shared), _op("index", _v("arr"), shared))
        hits = Set{String}()
        ESM._obs_structural_refs!(e, names, hits)
        @test hits == Set(["o"])
        # No false positives: a purely-expression-position reference stays clean.
        hits0 = Set{String}()
        ESM._obs_structural_refs!(_op("sin", shared), names, hits0)
        @test isempty(hits0)
        # And the walk is DAG-safe: a doubling spine over a structural hit.
        deep = _doubling_dag(_op("index", _v("arr"), _v("o")), 30)
        hits2 = Set{String}()
        t = @elapsed ESM._obs_structural_refs!(deep, names, hits2)
        @test t < 10
        @test hits2 == Set(["o"])
    end

    @testset "predicate walks are DAG-safe (miss case is the trigger)" begin
        # `_refs_loop_var`: the NO-HIT scan must visit each node once.
        deep = _doubling_dag(_v("i"), 30)
        t = @elapsed r = ESM._refs_loop_var(deep, Set{String}(["nope"]))
        @test t < 10
        @test !r
        @test ESM._refs_loop_var(deep, Set{String}(["i"]))
        # `_has_param_indexed_gather`: same, over a shared gather chain.
        gath = _doubling_dag(_op("index", _v("F"), _op("+", _v("p0"), _i(1))), 30)
        t2 = @elapsed g = ESM._has_param_indexed_gather(gath, Set{String}(["q"]))
        @test t2 < 10
        @test !g
        @test ESM._has_param_indexed_gather(gath, Set{String}(["p0"]))
    end

    @testset "free_variables is DAG-safe and binder-correct" begin
        deep = _doubling_dag(_op("-", _v("x"), _v("y")), 30)
        t = @elapsed fv = ESM.free_variables(deep)
        @test t < 10
        @test fv == Set(["x", "y"])
        # Binder subtraction happens at the binder node: a loop index is bound
        # away, an outer name stays free.
        agg = _op("arrayop"; output_idx=Any["i"],
                  expr_body=_op("+", _v("i"), _v("z")),
                  ranges=Dict("i" => [1, 3]))
        @test ESM.free_variables(agg) == Set(["z"])
    end

    @testset "_substitute_shared ≡ substitute up to sharing" begin
        shared = _op("+", _v("o"), _n(1.0))
        e = _op("*", shared, shared)
        b = Dict{String,ESM.ASTExpr}("o" => _op("neg", _v("x")))
        r1 = ESM.substitute(e, b)
        r2 = ESM._substitute_shared(e, b)
        @test ESM.canonical_json(r1) == ESM.canonical_json(r2)
        @test r2 isa ESM.OpExpr
        @test r2.args[1] === r2.args[2]   # sharing preserved, not re-inflated
        # No-hit substitution is fully identity-preserving.
        @test ESM._substitute_shared(e, Dict{String,ESM.ASTExpr}("zz" => _n(1.0))) === e
    end
end
