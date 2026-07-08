# Common-subexpression elimination on the tree-walk evaluator (ess-r7h).
#
# Approach (a) eval-time memo: a subexpression that occurs K times is compiled
# once into a prelude that fills a per-call scratch cache, and each occurrence
# reads it via an `_NK_CACHED` ref. These tests pin the three load-bearing
# acceptance criteria:
#
#   #2 evaluate-once   — the build diagnostic reports `n_cse_slots` (distinct
#                        canonical subexpressions, each evaluated once per RHS)
#                        and `n_cse_occurrences` (total occurrences). They are
#                        the instrumented count "distinct evaluations == distinct
#                        canonical subexpressions, not total occurrences".
#   #3 numeric identity — CSE only dedupes byte-identical computations, so f!
#                        output is bit-for-bit unchanged; a model with nothing
#                        to share gets an empty prelude.
#   reuse/no-new-infra — keyed on canonicalize.jl `canonical_json` (verified by
#                        commutative/structural sharing matching that identity).

using Test
using EarthSciAST
import OrdinaryDiffEqTsit5
const ESM = EarthSciAST

_cse_n(x) = NumExpr(Float64(x))
_cse_v(n) = VarExpr(n)
_cse_op(op, args...; kw...) = OpExpr(op, ESM.Expr[args...]; kw...)
_cse_D(varname) = _cse_op("D", _cse_v(varname); wrt="t")

@testset "tree_walk common-subexpression elimination (ess-r7h)" begin

    # ----------------------------------------------------------------
    # #2 evaluate-once: intra-RHS + cross-equation sharing of `a+b`.
    #   D(a) = sin(a+b) + cos(a+b)   (a+b twice in one RHS)
    #   D(b) = k * (a+b)             (a+b again, across equations) → 3 total
    # ----------------------------------------------------------------
    @testset "instrumented count: K occurrences → 1 cached subexpression" begin
        vars = Dict{String,ModelVariable}(
            "a" => ModelVariable(StateVariable; default=0.3),
            "b" => ModelVariable(StateVariable; default=0.5),
            "k" => ModelVariable(ParameterVariable; default=2.0),
        )
        apb = _cse_op("+", _cse_v("a"), _cse_v("b"))
        eqs = ESM.Equation[
            ESM.Equation(_cse_D("a"),
                         _cse_op("+", _cse_op("sin", apb), _cse_op("cos", apb))),
            ESM.Equation(_cse_D("b"), _cse_op("*", _cse_v("k"), apb)),
        ]
        f!, u0, p, _tspan, var_map, diag = ESM._build_evaluator_impl(ESM.Model(vars, eqs))

        # Exactly one distinct canonical subexpression (a+b) is cached, across
        # its three textual occurrences — the evaluate-once witness.
        @test diag.n_cse_slots == 1
        @test diag.n_cse_occurrences == 3

        # Bit-exact: CSE dedupes the identical `a+b`, so the result equals the
        # naive hand-evaluation to the last bit.
        a, b, k = 0.3, 0.5, 2.0
        du = similar(u0)
        f!(du, u0, p, 0.0)
        @test du[var_map["a"]] === sin(a + b) + cos(a + b)
        @test du[var_map["b"]] === k * (a + b)
    end

    # ----------------------------------------------------------------
    # Nested sharing: the cached `(a+b)*(a+b)` def must itself reference the
    # cached `a+b` slot. Exercises topological prelude ordering (a child slot is
    # always lower than its parent's, so each prelude read is already filled).
    #   D(a) = sin((a+b)*(a+b));  D(b) = cos((a+b)*(a+b));  D(c) = a+b
    # ----------------------------------------------------------------
    @testset "nested cached subexpressions are topologically ordered" begin
        vars = Dict{String,ModelVariable}(
            "a" => ModelVariable(StateVariable; default=0.7),
            "b" => ModelVariable(StateVariable; default=0.2),
            "c" => ModelVariable(StateVariable; default=0.0),
        )
        s  = _cse_op("+", _cse_v("a"), _cse_v("b"))
        ss = _cse_op("*", _cse_op("+", _cse_v("a"), _cse_v("b")),
                          _cse_op("+", _cse_v("a"), _cse_v("b")))
        eqs = ESM.Equation[
            ESM.Equation(_cse_D("a"), _cse_op("sin", ss)),
            ESM.Equation(_cse_D("b"), _cse_op("cos", ss)),
            ESM.Equation(_cse_D("c"), s),
        ]
        f!, u0, p, _tspan, var_map, diag = ESM._build_evaluator_impl(ESM.Model(vars, eqs))

        # Both `a+b` and `(a+b)*(a+b)` are shared, so ≥2 slots are allocated and
        # the dedup removed strictly more occurrences than slots.
        @test diag.n_cse_slots >= 2
        @test diag.n_cse_occurrences > diag.n_cse_slots

        a, b = 0.7, 0.2
        sval = a + b
        ssval = sval * sval
        du = similar(u0)
        f!(du, u0, p, 0.0)
        @test du[var_map["a"]] === sin(ssval)
        @test du[var_map["b"]] === cos(ssval)
        @test du[var_map["c"]] === sval
    end

    # ----------------------------------------------------------------
    # #3 numeric identity: a model with no repeated subexpression gets an empty
    # prelude — the compiled rhs nodes are byte-identical to the pre-CSE path.
    # ----------------------------------------------------------------
    @testset "no common subexpressions → empty prelude (unchanged f!)" begin
        vars = Dict{String,ModelVariable}(
            "x" => ModelVariable(StateVariable; default=1.0),
            "y" => ModelVariable(StateVariable; default=2.0),
            "r" => ModelVariable(ParameterVariable; default=0.5),
        )
        eqs = ESM.Equation[
            ESM.Equation(_cse_D("x"), _cse_op("*", _cse_op("neg", _cse_v("r")), _cse_v("x"))),
            ESM.Equation(_cse_D("y"), _cse_op("*", _cse_v("r"), _cse_v("y"))),
        ]
        f!, u0, p, _tspan, var_map, diag = ESM._build_evaluator_impl(ESM.Model(vars, eqs))
        @test diag.n_cse_slots == 0
        @test diag.n_cse_occurrences == 0

        du = similar(u0)
        f!(du, u0, p, 0.0)
        @test du[var_map["x"]] === -0.5 * 1.0
        @test du[var_map["y"]] === 0.5 * 2.0
    end

    # ----------------------------------------------------------------
    # Cross-equation CSE on a realistic reaction network (the redundancy the
    # bead calls out). The two reaction fluxes appear in every species' balance.
    #   d[A] = -f1 + f2 ; d[B] = -f1 + f2 ; d[C] = f1 - f2
    #   f1 = k1*A*B , f2 = k2*C
    # ----------------------------------------------------------------
    @testset "reaction-network fluxes shared across species balances" begin
        vars = Dict{String,ModelVariable}(
            "A" => ModelVariable(StateVariable; default=1.5),
            "B" => ModelVariable(StateVariable; default=0.8),
            "C" => ModelVariable(StateVariable; default=0.4),
            "k1" => ModelVariable(ParameterVariable; default=0.3),
            "k2" => ModelVariable(ParameterVariable; default=0.7),
        )
        f1() = _cse_op("*", _cse_v("k1"), _cse_v("A"), _cse_v("B"))
        f2() = _cse_op("*", _cse_v("k2"), _cse_v("C"))
        eqs = ESM.Equation[
            ESM.Equation(_cse_D("A"), _cse_op("-", f2(), f1())),
            ESM.Equation(_cse_D("B"), _cse_op("-", f2(), f1())),
            ESM.Equation(_cse_D("C"), _cse_op("-", f1(), f2())),
        ]
        f!, u0, p, _tspan, var_map, diag = ESM._build_evaluator_impl(ESM.Model(vars, eqs))

        # Both fluxes (k1*A*B and k2*C) recur across the three balances.
        @test diag.n_cse_slots >= 2
        @test diag.n_cse_occurrences >= 6

        A, B, C, k1, k2 = 1.5, 0.8, 0.4, 0.3, 0.7
        f1v = k1 * A * B
        f2v = k2 * C
        du = similar(u0)
        f!(du, u0, p, 0.0)
        @test du[var_map["A"]] === f2v - f1v
        @test du[var_map["B"]] === f2v - f1v
        @test du[var_map["C"]] === f1v - f2v

        # Cache freshness: a second call at a different state must recompute the
        # prelude (no stale cache carried across calls). Fill u in var_map order
        # so state slots line up regardless of layout.
        uu = similar(u0)
        statevals = Dict("A" => 2.0, "B" => 1.0, "C" => 0.5)
        for (nm, i) in var_map
            uu[i] = statevals[nm]
        end
        f!(du, uu, p, 0.0)
        A2, B2, C2 = 2.0, 1.0, 0.5
        @test du[var_map["A"]] === k2 * C2 - k1 * A2 * B2
        @test du[var_map["C"]] === k1 * A2 * B2 - k2 * C2
    end

    # ----------------------------------------------------------------
    # End-to-end: CSE must not change the integrated trajectory. Analytic decay
    # D(N) = -λN with a deliberately duplicated rate term still integrates to
    # N0·exp(-λt).
    # ----------------------------------------------------------------
    @testset "integration unchanged by CSE (analytic decay)" begin
        λ = 0.9
        N0 = 5.0
        vars = Dict{String,ModelVariable}(
            "N" => ModelVariable(StateVariable; default=N0),
            "lam" => ModelVariable(ParameterVariable; default=λ),
        )
        # D(N) = -(lam*N) - (lam*N) + (lam*N)  ≡ -(lam*N); lam*N appears 3×.
        lamN() = _cse_op("*", _cse_v("lam"), _cse_v("N"))
        rhs = _cse_op("+", _cse_op("neg", lamN()),
                      _cse_op("+", _cse_op("neg", lamN()), lamN()))
        f!, u0, p, _tspan, var_map, diag = ESM._build_evaluator_impl(
            ESM.Model(vars, ESM.Equation[ESM.Equation(_cse_D("N"), rhs)]))
        @test diag.n_cse_slots >= 1
        @test diag.n_cse_occurrences >= 3

        prob = OrdinaryDiffEqTsit5.ODEProblem(f!, u0, (0.0, 1.5), p)
        sol = OrdinaryDiffEqTsit5.solve(prob, OrdinaryDiffEqTsit5.Tsit5();
                                        reltol=1e-10, abstol=1e-12)
        @test isapprox(sol.u[end][var_map["N"]], N0 * exp(-λ * 1.5); rtol=1e-6)
    end
end
