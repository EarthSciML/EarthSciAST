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

include("testutils.jl")  # zero_alloc_harness.jl → rhs_alloc_bytes

_cse_n(x) = NumExpr(Float64(x))
_cse_v(n) = VarExpr(n)
_cse_op(op, args...; kw...) = OpExpr(op, ESM.ASTExpr[args...]; kw...)
_cse_D(varname) = _cse_op("D", _cse_v(varname); wrt="t")
_cse_const(v) = OpExpr("const", ESM.ASTExpr[]; value=v)
_cse_fn(name, args...) = OpExpr("fn", ESM.ASTExpr[args...]; name=String(name))

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

# ====================================================================
# CSE through closed-function (`fn`) nodes (ess-obs).
#
# `fn` used to be flagged `cse_opaque`, which made every `interp.*` / `datetime.*`
# call a SHARING BARRIER: `_cse_count!` stopped at the `fn` node, so neither the
# call itself nor any subexpression below it could be hoisted. An observed chain
# that reaches an expensive subtree THROUGH a closed function — the ReSEACT box's
# `Solar.cos_zenith` → `FastJX.cos_sza` → 18 `F_i = interp.linear(band_i, axis,
# cos_sza)` actinic-flux bands → ~14 photolysis rates each summing all 18 bands —
# therefore re-walked the whole solar subtree ~250× per RHS call.
#
# These tests pin the fix STRUCTURALLY, without a magic byte constant: the boxed
# all-scalar closed-function path (`datetime.*`) allocates a fixed number of bytes
# per evaluation, so the RHS's steady-state per-call allocation IS a counter of
# `datetime.*` evaluations. With the barrier gone, that count equals the number of
# DISTINCT `datetime.*` nodes in the flattened system — so it must be INVARIANT
# under fan-out (more bands, more consumers). Before the fix it grew as
# bands × consumers.
# ====================================================================
@testset "tree_walk CSE sees through closed-function `fn` nodes (ess-obs)" begin

    # A monotone table/axis for `interp.linear`. Distinct per band so the K `fn`
    # nodes are genuinely distinct subexpressions (each shared across consumers,
    # none shared with another band).
    _band_axis() = Float64[0.0, 0.25, 0.5, 0.75, 1.0]
    _band_table(i) = Float64[0.1 * i, 0.2 * i, 0.35 * i, 0.55 * i, 0.8 * i]

    # A `Solar.cos_zenith`-shaped observed: an arithmetic body over TWO boxed
    # `datetime.*` closed-function calls (the "countable side-effect-free cost").
    #   sza = sin(datetime.hour(t)/24 + datetime.minute(t)/1440)
    _sza_expr() = _cse_op("sin",
        _cse_op("+",
            _cse_op("/", _cse_fn("datetime.hour", _cse_v("t")), _cse_n(24.0)),
            _cse_op("/", _cse_fn("datetime.minute", _cse_v("t")), _cse_n(1440.0))))

    # The box's shape, parameterized by fan-out:
    #   observed sza  = <2 datetime.* calls>                       (the deep subtree)
    #   observed F_i  = interp.linear(table_i, axis, sza)   i=1..K (the `fn` BARRIER)
    #   D(x_j)        = Σ_i w_ji * F_i                      j=1..M (the wide fan-out)
    # The per-consumer weights differ, so the Σ is NOT itself a shared expression —
    # only the `F_i` (and the `sza` beneath them) can be shared. That is precisely
    # the sharing the `fn` barrier used to forbid.
    function _fanout_model(K::Int, M::Int)
        vars = Dict{String,ModelVariable}("sza" => ModelVariable(ObservedVariable))
        eqs = ESM.Equation[ESM.Equation(_cse_v("sza"), _sza_expr())]
        for i in 1:K
            vars["F$i"] = ModelVariable(ObservedVariable)
            push!(eqs, ESM.Equation(_cse_v("F$i"),
                _cse_fn("interp.linear", _cse_const(_band_table(i)),
                        _cse_const(_band_axis()), _cse_v("sza"))))
        end
        for j in 1:M
            vars["x$j"] = ModelVariable(StateVariable; default=0.0)
            terms = ESM.ASTExpr[_cse_op("*", _cse_n(1.0 + 0.5 * i + 0.25 * j),
                                        _cse_v("F$i")) for i in 1:K]
            push!(eqs, ESM.Equation(_cse_D("x$j"), OpExpr("+", terms)))
        end
        return ESM.Model(vars, eqs)
    end

    # Reference `du` for one state, evaluated the naive (fully re-walked) way, in
    # the SAME operand order the compiler emits — so `===` is a bit-exactness test,
    # not an approximate one.
    function _reference_du(K::Int, j::Int, t::Float64)
        sza = sin(Float64(ESM.evaluate_closed_function("datetime.hour", Any[t])) / 24.0 +
                  Float64(ESM.evaluate_closed_function("datetime.minute", Any[t])) / 1440.0)
        acc = 0.0
        for i in 1:K
            fi = Float64(ESM.evaluate_closed_function(
                "interp.linear", Any[_band_table(i), _band_axis(), sza]))
            term = (1.0 + 0.5 * i + 0.25 * j) * fi
            acc = i == 1 ? term : acc + term
        end
        return acc
    end

    _alloc_of(K, M, t) = begin
        f!, u0, p, _ts, _vm = build_evaluator(_fanout_model(K, M))
        du = similar(u0)
        rhs_alloc_bytes(f!, du, u0, p, t)
    end

    # ----------------------------------------------------------------
    # Evaluate-once: the observed subtree beneath the `fn` barrier is evaluated
    # ONCE per RHS call, no matter how many bands reference it or how many states
    # consume the bands. The boxed-`datetime.*` allocation is the evaluation
    # counter; it must not grow with the fan-out.
    # ----------------------------------------------------------------
    @testset "observed under a closed-function barrier is evaluated once per call" begin
        t = 43200.0
        base = _alloc_of(1, 1, t)          # 1 band, 1 consumer  → 2 datetime evals
        @test base > 0                     # sanity: the boxed path DOES allocate,
                                           # so allocation is a usable counter
        # Widen the fan-out 8×6 = 48-fold. With the barrier gone, `sza` is still
        # evaluated exactly once, so the byte count is IDENTICAL. Before the fix
        # it was 48× larger (one full re-walk of `sza` per band per consumer).
        @test _alloc_of(4, 3, t) == base
        @test _alloc_of(8, 6, t) == base
        @test _alloc_of(18, 14, t) == base   # the ReSEACT FastJX shape
    end

    # ----------------------------------------------------------------
    # The `fn` node itself is hoisted (each band computed once, not once per
    # consumer), witnessed by the build diagnostic.
    # ----------------------------------------------------------------
    @testset "closed-function calls are hoisted into cache slots" begin
        K, M = 8, 6
        _f!, _u0, _p, _ts, _vm, diag =
            ESM._build_evaluator_impl(_fanout_model(K, M))
        # ≥ K slots: one per distinct `interp.linear` band, plus the shared `sza`
        # subtree and its two `datetime.*` calls beneath it.
        @test diag.n_cse_slots >= K + 1
        # Each band occurs once per consumer → ≥ K*M replaced occurrences.
        @test diag.n_cse_occurrences >= K * M
    end

    # ----------------------------------------------------------------
    # Bit-exact numerics: hoisting a `fn` node and the subtree under it must not
    # perturb a single bit (`===` on Float64, not `isapprox`).
    # ----------------------------------------------------------------
    @testset "hoisting through `fn` is bit-identical" begin
        K, M = 8, 6
        f!, u0, p, _ts, var_map = build_evaluator(_fanout_model(K, M))
        du = similar(u0)
        for t in (0.0, 3600.0, 43200.0, 86400.0)
            f!(du, u0, p, t)
            for j in 1:M
                @test du[var_map["x$j"]] === _reference_du(K, j, t)
            end
        end
    end

    # ----------------------------------------------------------------
    # The barrier also blocked sharing of subexpressions used BOTH inside a `fn`
    # argument and outside one. Pin that CSE now recurses INTO `fn` args.
    #   D(a) = interp.linear(tbl, ax, a+b) + sin(a+b)
    #   D(b) = interp.linear(tbl, ax, a+b)          (same call, second consumer)
    # ----------------------------------------------------------------
    @testset "subexpressions inside a `fn` argument are shared with outside uses" begin
        tbl, ax = _band_table(1), _band_axis()
        vars = Dict{String,ModelVariable}(
            "a" => ModelVariable(StateVariable; default=0.3),
            "b" => ModelVariable(StateVariable; default=0.5),
        )
        apb() = _cse_op("+", _cse_v("a"), _cse_v("b"))
        call() = _cse_fn("interp.linear", _cse_const(tbl), _cse_const(ax), apb())
        eqs = ESM.Equation[
            ESM.Equation(_cse_D("a"), _cse_op("+", call(), _cse_op("sin", apb()))),
            ESM.Equation(_cse_D("b"), call()),
        ]
        f!, u0, p, _ts, var_map, diag =
            ESM._build_evaluator_impl(ESM.Model(vars, eqs))

        # Both `a+b` (3 occurrences: 2 inside `fn` args, 1 outside) and the
        # `interp.linear` call (2 occurrences) are shared.
        @test diag.n_cse_slots >= 2
        @test diag.n_cse_occurrences >= 5

        a, b = 0.3, 0.5
        ipl = Float64(ESM.evaluate_closed_function("interp.linear", Any[tbl, ax, a + b]))
        du = similar(u0)
        f!(du, u0, p, 0.0)
        @test du[var_map["a"]] === ipl + sin(a + b)
        @test du[var_map["b"]] === ipl
    end
end
