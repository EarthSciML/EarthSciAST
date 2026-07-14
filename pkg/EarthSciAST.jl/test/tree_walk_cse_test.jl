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
using ForwardDiff
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
# CSE MUST NOT HOIST OUT FROM BEHIND A GUARD.
#
# The prelude is UNCONDITIONAL (`_make_rhs` fills every slot at the top of every
# call) while the scalar walkers are LAZY: `ifelse` walks only the taken branch and
# `and`/`or` short-circuit. So a subexpression that occurs ONLY under a guard must
# never become a cache slot — hoisting it evaluates it when no guard fires, which
# turned `ifelse(a >= 0, sqrt(a), 0)` at `a = -1` into a `DomainError` *as soon as a
# second occurrence appeared elsewhere in the model*. Whether a guard protected its
# operand depended on how many times that operand happened to be written.
#
# The rule (`_cse_count!` / `_cse_compile_scalar`): hoist a key iff
# `total_occurrences >= 2` AND `unconditional_occurrences >= 1`. The second clause is
# what makes the prelude safe (an unconditional occurrence is evaluated by the walk
# anyway); the first makes it worth doing. Both halves are pinned below — the crash
# must be gone, AND a subexpression with one unconditional occurrence must still be
# shared with its guarded ones.
# ====================================================================
@testset "tree_walk CSE respects lazy guards (ifelse / and / or)" begin

    # `run_rhs(model, form)` → the `du` vector, for whichever RHS form. The two
    # emitters must agree: a Float64 `:oop` run is bit-identical to `:inplace`, which
    # requires `_oop_eval_op` to short-circuit the guard ops exactly as `_eval_node_op`
    # does (it filled every child into a buffer before dispatch, i.e. it was EAGER —
    # so `:oop` threw on models `f!` ran fine, with or without CSE).
    function _guard_rhs(model, form::Symbol)
        f, u0, p, _ts, var_map, diag = ESM._build_evaluator_impl(model; form=form)
        du = form === :inplace ? (d = similar(u0); f(d, u0, p, 0.0); d) : f(u0, p, 0.0)
        return du, var_map, diag
    end

    # ----------------------------------------------------------------
    # The regression itself: a guarded `sqrt(a)` at a NEGATIVE `a`, written twice.
    #   D(a) =     ifelse(a >= 0, sqrt(a), 0)
    #   D(b) = 2 * ifelse(a >= 0, sqrt(a), 0)     ← the second occurrence
    # One occurrence always worked; two used to throw `DomainError with -1.0` from
    # inside the prelude loop.
    # ----------------------------------------------------------------
    @testset "a guarded sqrt is not hoisted out of its ifelse" begin
        guarded() = _cse_op("ifelse", _cse_op(">=", _cse_v("a"), _cse_n(0)),
                            _cse_op("sqrt", _cse_v("a")), _cse_n(0))
        model(a0) = ESM.Model(
            Dict{String,ModelVariable}(
                "a" => ModelVariable(StateVariable; default=a0),
                "b" => ModelVariable(StateVariable; default=0.0),
            ),
            ESM.Equation[
                ESM.Equation(_cse_D("a"), guarded()),
                ESM.Equation(_cse_D("b"), _cse_op("*", _cse_n(2), guarded())),
            ])

        for form in (:inplace, :oop)
            # Guard NOT taken (a < 0): `sqrt(a)` must never be evaluated.
            du, vm, diag = _guard_rhs(model(-1.0), form)
            @test du[vm["a"]] === 0.0
            @test du[vm["b"]] === 0.0
            # The guarded `sqrt(a)` is left inline (behind its guard), but the whole
            # `ifelse` — which IS unconditional, twice — is still shared.
            @test diag.n_cse_slots >= 1
            @test !isnan(du[vm["a"]])

            # Guard TAKEN (a >= 0): the shared branch still computes, and shares.
            du4, vm4, _ = _guard_rhs(model(4.0), form)
            @test du4[vm4["a"]] === sqrt(4.0)
            @test du4[vm4["b"]] === 2.0 * sqrt(4.0)
        end
    end

    # ----------------------------------------------------------------
    # Same story for a short-circuiting `or`: `log(a)` sits in arg 2, which is only
    # evaluated when arg 1 is false. Two occurrences used to hoist it into the
    # prelude and throw at `a = -1`.
    #   D(a) = D(b) = or(a < 0, log(a) > 1)
    # ----------------------------------------------------------------
    @testset "a short-circuited log is not hoisted out of its `or`" begin
        disj() = _cse_op("or", _cse_op("<", _cse_v("a"), _cse_n(0)),
                         _cse_op(">", _cse_op("log", _cse_v("a")), _cse_n(1)))
        m = ESM.Model(
            Dict{String,ModelVariable}(
                "a" => ModelVariable(StateVariable; default=-1.0),
                "b" => ModelVariable(StateVariable; default=0.0),
            ),
            ESM.Equation[ESM.Equation(_cse_D("a"), disj()),
                         ESM.Equation(_cse_D("b"), disj())])

        for form in (:inplace, :oop)
            du, vm, _diag = _guard_rhs(m, form)
            # `a < 0` is true, so the disjunction short-circuits to 1.0 without ever
            # touching `log(-1.0)`.
            @test du[vm["a"]] === 1.0
            @test du[vm["b"]] === 1.0
        end
    end

    # `and` is the mirror image: arg 2 runs only when arg 1 is TRUE.
    #   D(a) = D(b) = and(a >= 0, sqrt(a) > 1)      at a = -1 → 0.0, no sqrt(-1)
    @testset "a short-circuited sqrt is not hoisted out of an `and`" begin
        conj() = _cse_op("and", _cse_op(">=", _cse_v("a"), _cse_n(0)),
                         _cse_op(">", _cse_op("sqrt", _cse_v("a")), _cse_n(1)))
        m = ESM.Model(
            Dict{String,ModelVariable}(
                "a" => ModelVariable(StateVariable; default=-1.0),
                "b" => ModelVariable(StateVariable; default=0.0),
            ),
            ESM.Equation[ESM.Equation(_cse_D("a"), conj()),
                         ESM.Equation(_cse_D("b"), conj())])
        for form in (:inplace, :oop)
            du, vm, _ = _guard_rhs(m, form)
            @test du[vm["a"]] === 0.0
            @test du[vm["b"]] === 0.0
        end
    end

    # ----------------------------------------------------------------
    # The OTHER half of the rule — the fix must not over-restrict. A key with ONE
    # unconditional occurrence is still hoisted, and its GUARDED occurrences read the
    # cache: the unconditional occurrence makes the prelude evaluation safe (the walk
    # performs it regardless), so there is nothing left to protect.
    #   D(a) = ifelse(a >= 0, sin(a+b), 0)   ← guarded occurrence of `a+b`
    #   D(c) = a + b                         ← unconditional occurrence
    # A "don't recurse into guarded arms" fix would lose this sharing.
    # ----------------------------------------------------------------
    @testset "1 unconditional + 1 guarded occurrence is still shared" begin
        apb() = _cse_op("+", _cse_v("a"), _cse_v("b"))
        m = ESM.Model(
            Dict{String,ModelVariable}(
                "a" => ModelVariable(StateVariable; default=0.3),
                "b" => ModelVariable(StateVariable; default=0.5),
                "c" => ModelVariable(StateVariable; default=0.0),
            ),
            ESM.Equation[
                ESM.Equation(_cse_D("a"),
                    _cse_op("ifelse", _cse_op(">=", _cse_v("a"), _cse_n(0)),
                            _cse_op("sin", apb()), _cse_n(0))),
                ESM.Equation(_cse_D("c"), apb()),
            ])
        f!, u0, p, _ts, var_map, diag = ESM._build_evaluator_impl(m)
        @test diag.n_cse_slots >= 1            # `a+b` IS cached
        @test diag.n_cse_occurrences >= 2      # both occurrences replaced

        du = similar(u0)
        f!(du, u0, p, 0.0)
        @test du[var_map["a"]] === sin(0.3 + 0.5)
        @test du[var_map["c"]] === 0.3 + 0.5
    end
end

# ====================================================================
# PINNED: CSE keys on CANONICAL identity, so reassociation-equivalent expressions
# SHARE a slot and the FIRST-SEEN operand order is what every occurrence reads back.
#
# `canonical_json` flattens and sorts n-ary `+`/`*`, so `(a+b)+c` and `a+(b+c)` have
# ONE key. Float `+` is not associative, so the two associations are different
# numbers — and the consequence, which this test exists to make explicit rather than
# latent, is that AN EQUATION'S NUMERIC OUTPUT IS NOT A FUNCTION OF THAT EQUATION
# ALONE: adding a canonically-equal expression elsewhere in the model can shift it.
#
# This is a decision, not a bug (see the header note in compile.jl): canonical form
# IS this format's notion of expression identity — `discretize` canonicalizes every
# per-cell RHS before it is compiled, so the format reassociates as a matter of
# course — and keying structurally instead would lose the commutative sharing the
# tests above pin. The differences are bounded by float reassociation of a
# CANONICALLY EQUAL expression; catastrophic cancellation is used here only because
# it makes an otherwise sub-ulp effect visible to `===`.
# ====================================================================
@testset "tree_walk CSE keys on canonical identity (reassociation is shared)" begin
    # (1e16 + -1e16) + 1.0 == 1.0   but   1e16 + (-1e16 + 1.0) == 0.0
    A, B, C = 1e16, -1e16, 1.0
    @test (A + B) + C === 1.0
    @test A + (B + C) === 0.0

    _vars() = Dict{String,ModelVariable}(
        "a" => ModelVariable(StateVariable; default=A),
        "b" => ModelVariable(StateVariable; default=B),
        "c" => ModelVariable(StateVariable; default=C),
        "x" => ModelVariable(StateVariable; default=0.0),
        "y" => ModelVariable(StateVariable; default=0.0),
    )
    _held() = ESM.Equation[ESM.Equation(_cse_D(s), _cse_n(0)) for s in ("a", "b", "c")]
    left()  = _cse_op("+", _cse_op("+", _cse_v("a"), _cse_v("b")), _cse_v("c"))
    right() = _cse_op("+", _cse_v("a"), _cse_op("+", _cse_v("b"), _cse_v("c")))

    # The two trees ARE one canonical expression — this is the whole mechanism.
    @test ESM.canonical_json(left()) == ESM.canonical_json(right())

    _du(eqs) = begin
        f!, u0, p, _ts, vm, diag = ESM._build_evaluator_impl(ESM.Model(_vars(), eqs))
        du = similar(u0); f!(du, u0, p, 0.0)
        (du, vm, diag)
    end

    # Alone: nothing to share, so `D(y) = a+(b+c)` evaluates exactly as written.
    du1, vm1, diag1 = _du(ESM.Equation[_held()..., ESM.Equation(_cse_D("y"), right())])
    @test diag1.n_cse_slots == 0
    @test du1[vm1["y"]] === 0.0

    # Add a canonically-equal sibling that is seen FIRST: one slot for both, and
    # `D(y)` now reads back `(a+b)+c` — the first-seen association.
    du2, vm2, diag2 = _du(ESM.Equation[_held()...,
        ESM.Equation(_cse_D("x"), left()), ESM.Equation(_cse_D("y"), right())])
    @test diag2.n_cse_slots == 1
    @test diag2.n_cse_occurrences == 2
    @test du2[vm2["x"]] === 1.0
    @test du2[vm2["y"]] === 1.0      # ← NOT 0.0: `D(y)`'s own equation is unchanged

    # Swap the order and the OTHER association wins for both — "first-seen", exactly.
    du3, vm3, diag3 = _du(ESM.Equation[_held()...,
        ESM.Equation(_cse_D("y"), right()), ESM.Equation(_cse_D("x"), left())])
    @test diag3.n_cse_slots == 1
    @test du3[vm3["y"]] === 0.0
    @test du3[vm3["x"]] === 0.0      # ← NOT 1.0, for the same reason
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

# ================================================================
# CSE over LIVE forcing buffers (ess-qic).
#
# A resolved `param_arrays` gather is an argless `index` node carrying a
# `_PGatherRef` runtime payload in `value`. `canonical_json` emits `value`, and
# a `_PGatherRef` is not a JSON type — so keying ANY ancestor of a live gather
# threw `E_CANONICAL_BAD_CONST`, `_cse_key` caught it and declined, and CSE was
# silently switched off for every expression built over a forcing buffer (the
# met→physics stack, i.e. the biggest CSE target there is). The gather now keys
# as a leaf with a canonicalizable `(buffer name, linear offset)` identity, and
# stays CSE-opaque so it is never itself hoisted.
# ================================================================
@testset "tree_walk CSE over live forcing buffers (ess-qic)" begin

    # `F[1]*k` three times over: twice inside D(x), once as D(y).
    #   D(x) = sin(F[1]*k) + cos(F[1]*k);   D(y) = F[1]*k
    _pg_shared_model() = ESM.Model(
        Dict{String,ModelVariable}(
            "x" => ModelVariable(StateVariable; default=1.0),
            "y" => ModelVariable(StateVariable; default=1.0),
            "k" => ModelVariable(ParameterVariable; default=2.0),
        ),
        begin
            fk() = _cse_op("*", _idx("F", _i(1)), _cse_v("k"))
            ESM.Equation[
                ESM.Equation(_cse_D("x"),
                    _cse_op("+", _cse_op("sin", fk()), _cse_op("cos", fk()))),
                ESM.Equation(_cse_D("y"), fk()),
            ]
        end)

    @testset "a shared expression over a LIVE forcing buffer is cached (ess-qic)" begin
        # Baseline: bound as a FROZEN const array the gather folds to a literal, so
        # `F[1]*k` is a plain parameter product — 1 slot, 3 occurrences.
        _, _, _, _, _, d_const = ESM._build_evaluator_impl(_pg_shared_model();
            const_arrays=Dict("F" => [5.0, 6.0]))
        @test d_const.n_cse_slots == 1
        @test d_const.n_cse_occurrences == 3

        # The SAME model with `F` bound as a LIVE buffer must share identically.
        # Before ess-qic this reported 0 slots / 0 occurrences.
        buf = [5.0, 6.0]
        f!, u0, p, _ts, vm, d_live = ESM._build_evaluator_impl(_pg_shared_model();
            param_arrays=Dict("F" => buf))
        @test d_live.n_cse_slots == 1
        @test d_live.n_cse_occurrences == 3

        # Bit-exact against the un-CSE'd evaluation: the cached slot holds exactly
        # the `F[1]*k` an inline walk would have computed, so `===`, not `≈`.
        k, F1 = 2.0, 5.0
        du = similar(u0)
        f!(du, u0, p, 0.0)
        @test du[vm["x"]] === sin(F1 * k) + cos(F1 * k)
        @test du[vm["y"]] === F1 * k
    end

    @testset "live-gather keys are distinct per OFFSET and per BUFFER (ess-qic)" begin
        # The one way this change could be catastrophic: if two gathers collided on a
        # key, CSE would MERGE two different reads into one slot and the model would
        # compute silently wrong numbers. Three products that must NOT share —
        # `F[1]*k` (buffer F, offset 1), `F[2]*k` (SAME buffer, different offset), and
        # `G[1]*k` (DIFFERENT buffer, SAME offset) — each duplicated so each is a
        # hoist candidate in its own right. Distinct buffer VALUES make a merge show
        # up as a wrong number, not just a wrong slot count.
        vars = Dict{String,ModelVariable}(
            "x" => ModelVariable(StateVariable; default=1.0),
            "y" => ModelVariable(StateVariable; default=1.0),
            "z" => ModelVariable(StateVariable; default=1.0),
            "w" => ModelVariable(StateVariable; default=1.0),
            "k" => ModelVariable(ParameterVariable; default=2.0),
        )
        prod(buf, off) = _cse_op("*", _idx(buf, _i(off)), _cse_v("k"))
        both(e) = _cse_op("+", _cse_op("sin", e), _cse_op("cos", e))
        eqs = ESM.Equation[
            ESM.Equation(_cse_D("x"), both(prod("F", 1))),
            ESM.Equation(_cse_D("y"), both(prod("F", 2))),
            ESM.Equation(_cse_D("z"), both(prod("G", 1))),
            ESM.Equation(_cse_D("w"), prod("F", 1)),   # 3rd occurrence of F[1]*k
        ]
        F = [3.0, 5.0]
        G = [7.0, 11.0]
        f!, u0, p, _ts, vm, diag = ESM._build_evaluator_impl(ESM.Model(vars, eqs);
            param_arrays=Dict("F" => F, "G" => G))

        # THREE slots, not one: F[1]*k, F[2]*k, G[1]*k are three distinct values.
        @test diag.n_cse_slots == 3
        @test diag.n_cse_occurrences == 7   # 3 + 2 + 2

        # And — the assertion that actually matters — every equation still computes
        # its OWN gather. A key collision would make two of these four agree.
        k = 2.0
        du = similar(u0)
        f!(du, u0, p, 0.0)
        @test du[vm["x"]] === sin(3.0 * k) + cos(3.0 * k)
        @test du[vm["y"]] === sin(5.0 * k) + cos(5.0 * k)
        @test du[vm["z"]] === sin(7.0 * k) + cos(7.0 * k)
        @test du[vm["w"]] === 3.0 * k
    end

    @testset "a CSE'd live gather still reads the buffer LIVE (ess-qic)" begin
        # Hoisting caches the value for ONE `f!` call: the prelude is refilled at the
        # top of every call, and the buffer cannot change mid-call. So an in-place
        # refresh BETWEEN calls must show through the cached slot.
        buf = [5.0, 6.0]
        f!, u0, p, _ts, vm, diag = ESM._build_evaluator_impl(_pg_shared_model();
            param_arrays=Dict("F" => buf))
        @test diag.n_cse_slots >= 1          # the expression IS cached...
        k = 2.0
        du = similar(u0)
        f!(du, u0, p, 0.0)
        @test du[vm["y"]] === 5.0 * k

        buf[1] = 42.0                        # ...and still tracks the live buffer.
        f!(du, u0, p, 0.0)
        @test du[vm["x"]] === sin(42.0 * k) + cos(42.0 * k)
        @test du[vm["y"]] === 42.0 * k
    end

    # ---- discrete-cadence caches ride the same `pgather` channel ----
    # `_build_discrete_materializer!` registers each discrete var's cache buffer in
    # the SAME `pgather` dict, so a reader's `index(g, j)` resolves to a live gather
    # over the cache and gets a `_PGatherRef` exactly like a raw forcing read. These
    # must key distinctly from each other AND refresh (their contents change on a
    # data-refresh event, between calls — a `materialize!`).
    _PG_W = [1.0 2.0 3.0; 4.0 5.0 6.0]   # W[i,j], i=1..2, j=1..3
    _pg_agg(scale) = OpExpr("aggregate", ESM.ASTExpr[];
        output_idx=Any["j"], reduce="+", ranges=Dict("j" => [1, 3], "i" => [1, 2]),
        expr_body=_cse_op("*", _cse_n(scale),
                          _cse_op("*", _idx("W", _v("i"), _v("j")), _idx("src", _v("i")))))
    # g[j] = Σᵢ W[i,j]·src[i];  h[j] = Σᵢ 3·W[i,j]·src[i]  (both state-free +
    # param-tainted ⇒ discrete caches). Scalar readers:
    #   D(x) = sin(g[1]*k) + cos(g[1]*k);  D(y) = g[1]*k;  D(z) = sin(h[1]*k) + cos(h[1]*k)
    _pg_discrete_model() = ESM.Model(
        Dict{String,ModelVariable}(
            "x" => ModelVariable(StateVariable; default=1.0),
            "y" => ModelVariable(StateVariable; default=1.0),
            "z" => ModelVariable(StateVariable; default=1.0),
            "k" => ModelVariable(ParameterVariable; default=2.0),
            "g" => ModelVariable(ObservedVariable; shape=["j"], expression=_pg_agg(1.0)),
            "h" => ModelVariable(ObservedVariable; shape=["j"], expression=_pg_agg(3.0)),
        ),
        begin
            gk() = _cse_op("*", _idx("g", _i(1)), _cse_v("k"))
            hk() = _cse_op("*", _idx("h", _i(1)), _cse_v("k"))
            ESM.Equation[
                ESM.Equation(_cse_D("x"),
                    _cse_op("+", _cse_op("sin", gk()), _cse_op("cos", gk()))),
                ESM.Equation(_cse_D("y"), gk()),
                ESM.Equation(_cse_D("z"),
                    _cse_op("+", _cse_op("sin", hk()), _cse_op("cos", hk()))),
            ]
        end)

    @testset "discrete-cadence cache gathers are CSE'd, distinct, and refresh (ess-qic)" begin
        src = [1.0, 1.0]
        dm = ESM.DiscreteMaterializer()
        f!, u0, p, _ts, vm, diag = ESM._build_evaluator_impl(_pg_discrete_model();
            const_arrays=Dict("W" => _PG_W), param_arrays=Dict("src" => src),
            materialize_out=dm)
        @test haskey(dm.caches, "g") && haskey(dm.caches, "h")

        # TWO slots — `g[1]*k` and `h[1]*k` gather two DIFFERENT cache buffers at the
        # SAME offset, so a name-blind key would collapse them into one.
        @test diag.n_cse_slots == 2
        @test diag.n_cse_occurrences == 5   # 3 × g[1]*k + 2 × h[1]*k

        k = 2.0
        du = similar(u0)
        f!(du, u0, p, 0.0)
        g1, h1 = dm.caches["g"][1], dm.caches["h"][1]
        @test g1 ≈ 1.0 * 1.0 + 4.0 * 1.0      # Σᵢ W[i,1]·src[i]
        @test h1 ≈ 3.0 * g1
        @test du[vm["x"]] === sin(g1 * k) + cos(g1 * k)
        @test du[vm["y"]] === g1 * k
        @test du[vm["z"]] === sin(h1 * k) + cos(h1 * k)

        # A data-refresh event: the raw buffer changes in place and `materialize!`
        # refills the caches. The CSE'd readers must track — the prelude re-gathers
        # the cache on every call.
        src .= [2.0, 3.0]
        dm.materialize!()
        g1n, h1n = dm.caches["g"][1], dm.caches["h"][1]
        @test g1n ≈ 1.0 * 2.0 + 4.0 * 3.0
        @test g1n != g1
        f!(du, u0, p, 0.0)
        @test du[vm["x"]] === sin(g1n * k) + cos(g1n * k)
        @test du[vm["y"]] === g1n * k
        @test du[vm["z"]] === sin(h1n * k) + cos(h1n * k)
    end
end

# ================================================================
# The CONST-CADENCE tier of the prelude (4qf; audit finding #5).
#
# The prelude used to refill EVERY slot on EVERY call. Many slots are pure parameter
# algebra — an Arrhenius factor `A*exp(-Ea/(R*Tref))`, all four leaves parameters —
# and `p` does not move between the stages of a step. `f!` now refills the CONST slots
# only when `p` has changed (`_classify_const_slots` / `_cse_const_stale`).
#
# THE FAILURE MODE THESE TESTS EXIST FOR IS SILENT. A const tier that freezes too much
# passes every Float64 test that never changes `p` and then returns WRONG DERIVATIVES.
# So the load-bearing assertions here are the AD ones, and they assert VALUES (against
# finite differences, and against zero) — not just the slot classification.
# ================================================================

# `f!` with a `du` of whatever value type the call induces (`Dual` under AD).
_ct_call(f!, u, p, t, ::Type{T}=Float64) where {T} =
    (d = zeros(T, length(u)); f!(d, u, p, t); d)

# The model's `p` with every value lifted to a 1-partial `Dual` — the shape ForwardDiff
# hands `f!` when differentiating w.r.t. the PARAMETERS.
_ct_dualp(p) = NamedTuple{keys(p)}(map(v -> ForwardDiff.Dual{Nothing}(v, 1.0), values(p)))

# The audit's probe model. `k = A*exp(-Ea/(R*Tref))` — every leaf a PARAMETER — shared
# across two equations, so CSE names the whole chain (neg · * · / · exp · *) and all
# five slots are const-cadence.
#   D(x) = k*x ;  D(y) = (-k)*y
_ct_arrhenius() = ESM.Model(
    Dict{String,ModelVariable}(
        "x"    => ModelVariable(StateVariable; default=1.5),
        "y"    => ModelVariable(StateVariable; default=2.5),
        "A"    => ModelVariable(ParameterVariable; default=3.2e5),
        "Ea"   => ModelVariable(ParameterVariable; default=5.0e4),
        "R"    => ModelVariable(ParameterVariable; default=8.314),
        "Tref" => ModelVariable(ParameterVariable; default=300.0),
    ),
    begin
        arr() = _cse_op("*", _cse_v("A"),
                    _cse_op("exp", _cse_op("/", _cse_op("neg", _cse_v("Ea")),
                                _cse_op("*", _cse_v("R"), _cse_v("Tref")))))
        ESM.Equation[
            ESM.Equation(_cse_D("x"), _cse_op("*", arr(), _cse_v("x"))),
            ESM.Equation(_cse_D("y"), _cse_op("*", _cse_op("neg", arr()), _cse_v("y"))),
        ]
    end)

_ct_k(p) = p.A * exp(-p.Ea / (p.R * p.Tref))

@testset "tree_walk CSE const-cadence tier (4qf)" begin

    # ----------------------------------------------------------------
    # (5) The probe. The audit measured "5 of 5 prelude slots state-free AND
    # time-free" and the prelude re-evaluated all five — including the `exp` — on
    # every stage of every step. All five are now CONST, and the numbers are
    # BIT-IDENTICAL to the untiered evaluator.
    # ----------------------------------------------------------------
    @testset "the Arrhenius probe: 5/5 prelude slots are const-cadence" begin
        f!, u0, p, _ts, vm, diag = ESM._build_evaluator_impl(_ct_arrhenius())

        @test diag.n_cse_slots == 5              # neg · * · / · exp · *
        @test diag.n_const_slots == 5
        @test diag.n_dynamic_slots == 0
        # The two counters partition the FINAL prelude (CSE slots + invariant slots).
        @test diag.n_const_slots + diag.n_dynamic_slots ==
              diag.n_cse_slots + diag.n_invariant_slots

        # Bit-exact — `===`, not `≈`. Skipping the const refill must not perturb a
        # single bit of the arithmetic the untiered prelude did.
        k = _ct_k(p)
        du = _ct_call(f!, u0, p, 0.0)
        @test du[vm["x"]] === k * u0[vm["x"]]
        @test du[vm["y"]] === -k * u0[vm["y"]]

        # ...and it stays bit-exact on the SECOND call, the one that actually takes
        # the skip. (A first call fills the const slots; a stale-but-plausible tier
        # would show up here, not above.)
        du2 = _ct_call(f!, u0, p, 0.0)
        @test du2 == du
    end

    # ----------------------------------------------------------------
    # (1) THE TEST THAT MATTERS. ForwardDiff over the PARAMETERS, where the RHS
    # depends on `A`/`Ea`/`R`/`Tref` ONLY through const-tier slots. Hoisting those
    # slots to build time — or keying their validity on `==` instead of `===` —
    # returns a ZERO (or stale-seed) derivative that still looks plausible.
    #
    # Chunk{1} is deliberate: it makes ForwardDiff call `f!` FOUR times, once per
    # parameter, with four DIFFERENT `Dual` NamedTuples that have the SAME values and
    # different PARTIALS. ForwardDiff's `==` on `Dual` compares values only — so a
    # validity stamp keyed on `==` would call chunks 2..4 "unchanged", reuse chunk 1's
    # seed, and silently return the wrong gradient. `===` (egal) sees the partials.
    # ----------------------------------------------------------------
    @testset "ForwardDiff over PARAMETERS through a const-tier slot" begin
        f!, u0, p, _ts, vm, diag = ESM._build_evaluator_impl(_ct_arrhenius())
        @test diag.n_const_slots == 5

        syms = keys(p)
        pv = collect(values(p))
        mk(v) = NamedTuple{syms}(Tuple(v))
        gfun = v -> sum(_ct_call(f!, u0, mk(v), 0.0, eltype(v)))

        cfg = ForwardDiff.GradientConfig(gfun, pv, ForwardDiff.Chunk{1}())
        g = ForwardDiff.gradient(gfun, pv, cfg)
        @test eltype(g) === Float64
        @test length(g) == length(pv)

        # A frozen const slot returns EXACTLY zero for every parameter sensitivity.
        # Assert it did not.
        @test all(!iszero, g)

        # And assert the actual values against central differences on `f!` itself.
        h = 1e-6
        for i in eachindex(pv)
            s = h * max(1.0, abs(pv[i]))
            up = copy(pv); up[i] += s
            um = copy(pv); um[i] -= s
            fd = (sum(_ct_call(f!, u0, mk(up), 0.0)) -
                  sum(_ct_call(f!, u0, mk(um), 0.0))) / 2s
            @test isapprox(g[i], fd; rtol=1e-5, atol=1e-12)
        end

        # The closed form, for the one the chain rule makes easiest to get wrong:
        # ∂/∂A [k*x + (-k)*y] = exp(-Ea/(R*Tref)) * (x - y).
        E = exp(-p.Ea / (p.R * p.Tref))
        @test isapprox(g[findfirst(==(:A), collect(syms))],
                       E * (u0[vm["x"]] - u0[vm["y"]]); rtol=1e-12)
    end

    # ----------------------------------------------------------------
    # (2) ForwardDiff over the STATE still correct: the const slots must be PRESENT
    # and correctly typed in the Dual buffer. A freshly allocated `alt` buffer is
    # `undef` — if its stamp were not invalidated on allocation, the const slots would
    # be read as GARBAGE on the very first Dual call.
    # ----------------------------------------------------------------
    @testset "ForwardDiff over the STATE, through the const tier" begin
        f!, u0, p, _ts, vm, _diag = ESM._build_evaluator_impl(_ct_arrhenius())
        u = [1.25, -0.75]
        J = ForwardDiff.jacobian((d, uu) -> f!(d, uu, p, 0.0), zeros(2), u)

        # D(x) = k*x, D(y) = -k*y ⇒ J = diag(k, -k) in var_map order.
        k = _ct_k(p)
        ix, iy = vm["x"], vm["y"]
        @test J[ix, ix] ≈ k
        @test J[iy, iy] ≈ -k
        @test J[ix, iy] == 0.0
        @test J[iy, ix] == 0.0
        @test all(isfinite, J)
    end

    # ----------------------------------------------------------------
    # (3) `p` CHANGED between calls — what `remake` and a parameter sweep do. The
    # const slots are keyed on `p`, so a new NamedTuple with different values must
    # refill them. This is the plain-Float64 half of the staleness question.
    # ----------------------------------------------------------------
    @testset "a changed `p` refills the const slots (remake / sweep)" begin
        f!, u0, p, _ts, vm, _diag = ESM._build_evaluator_impl(_ct_arrhenius())

        du1 = _ct_call(f!, u0, p, 0.0)
        @test du1[vm["x"]] === _ct_k(p) * u0[vm["x"]]

        # A DIFFERENT NamedTuple, same shape — exactly what `remake(prob; p = …)` hands
        # the RHS. Every equation depends on these only through const-tier slots.
        p2 = merge(p, (; A = 2.0 * p.A, Tref = 350.0))
        du2 = _ct_call(f!, u0, p2, 0.0)
        @test du2[vm["x"]] === _ct_k(p2) * u0[vm["x"]]
        @test du2[vm["y"]] === -_ct_k(p2) * u0[vm["y"]]
        @test du2[vm["x"]] != du1[vm["x"]]

        # ...and back again. A stamp that only ever moved forward would fail here.
        du3 = _ct_call(f!, u0, p, 0.0)
        @test du3 == du1

        # A SEPARATELY CONSTRUCTED NamedTuple with the same values. `===` on an
        # `isbits` immutable is a BITWISE compare, not an object-identity compare, so
        # this is egal to `p` and the tier skips the refill — which is exactly right,
        # and is why the stamp may use `===` at all: same bits ⇒ same parameter values
        # ⇒ same const slots. (Egal is strictly finer than `==`: it separates `0.0`
        # from `-0.0` and never merges two `p`s whose const slots could differ.)
        pdup = NamedTuple{keys(p)}(Tuple(collect(values(p))))
        @test pdup === p
        @test _ct_call(f!, u0, pdup, 0.0) == du1
    end

    # ----------------------------------------------------------------
    # (4) THE BUFFER-STALENESS KILLER. `_CSECache` holds TWO buffers (`f64`, and the
    # lazily created `alt` for a non-Float64 value type), so the validity stamp must be
    # PER BUFFER. Alternate Float64 and Dual calls, repeatedly, in BOTH orders: a
    # single shared stamp would let a Float64 call's "p unchanged" mark the `undef`
    # Dual buffer valid (garbage), or vice versa.
    # ----------------------------------------------------------------
    @testset "alternating Float64 and Dual calls, both orders" begin
        for float_first in (true, false)
            f!, u0, p, _ts, vm, _diag = ESM._build_evaluator_impl(_ct_arrhenius())
            k = _ct_k(p)
            pd = _ct_dualp(p)
            D1 = ForwardDiff.Dual{Nothing,Float64,1}
            kd = _ct_k(pd)

            float_first || _ct_call(f!, u0, pd, 0.0, D1)   # Dual buffer created first

            for _ in 1:3
                duf = _ct_call(f!, u0, p, 0.0)
                @test duf[vm["x"]] === k * u0[vm["x"]]
                @test duf[vm["y"]] === -k * u0[vm["y"]]

                dud = _ct_call(f!, u0, pd, 0.0, D1)
                # Primal AND partials — a garbage/stale const slot in the Dual buffer
                # shows up in one or the other.
                @test ForwardDiff.value(dud[vm["x"]]) ≈ ForwardDiff.value(kd * u0[vm["x"]])
                @test ForwardDiff.partials(dud[vm["x"]], 1) ≈
                      ForwardDiff.partials(kd * u0[vm["x"]], 1)
                @test ForwardDiff.partials(dud[vm["y"]], 1) ≈
                      ForwardDiff.partials(-kd * u0[vm["y"]], 1)
                @test all(isfinite ∘ ForwardDiff.value, dud)
                @test any(!iszero, ForwardDiff.partials.(dud, 1))
            end
        end
    end

    # ----------------------------------------------------------------
    # (6) TRAP, HALF ONE — `_NK_PARAM_GATHER`. A live forcing buffer is refreshed IN
    # PLACE between calls while `p` never moves, so a `p`-keyed stamp cannot see it
    # change: a slot reading one is DISCRETE cadence, not const. The model carries BOTH
    # a param-only chain (const) and a gather chain (dynamic), so "all dynamic" cannot
    # pass this vacuously.
    #   D(x) = sin(F[1]*k) + cos(F[1]*k) ;  D(y) = F[1]*k ;  D(z) = exp(k*m) + 2*exp(k*m)
    # ----------------------------------------------------------------
    @testset "a slot reading a live forcing buffer is DYNAMIC, not const" begin
        vars = Dict{String,ModelVariable}(
            "x" => ModelVariable(StateVariable; default=1.0),
            "y" => ModelVariable(StateVariable; default=1.0),
            "z" => ModelVariable(StateVariable; default=1.0),
            "k" => ModelVariable(ParameterVariable; default=2.0),
            "m" => ModelVariable(ParameterVariable; default=3.0),
        )
        km() = _cse_op("exp", _cse_op("*", _cse_v("k"), _cse_v("m")))   # → CONST
        fk() = _cse_op("*", _idx("F", _i(1)), _cse_v("k"))              # → DYNAMIC
        eqs = ESM.Equation[
            ESM.Equation(_cse_D("x"),
                _cse_op("+", _cse_op("sin", fk()), _cse_op("cos", fk()))),
            ESM.Equation(_cse_D("y"), fk()),
            ESM.Equation(_cse_D("z"),
                _cse_op("+", km(), _cse_op("*", _cse_n(2.0), km()))),
        ]
        buf = [5.0, 6.0]
        f!, u0, p, _ts, vm, diag = ESM._build_evaluator_impl(ESM.Model(vars, eqs);
            param_arrays=Dict("F" => buf))

        # 3 slots: `k*m` and `exp(k*m)` are const; `F[1]*k` reads the live buffer.
        @test diag.n_cse_slots == 3
        @test diag.n_const_slots == 2
        @test diag.n_dynamic_slots == 1

        k, m = 2.0, 3.0
        du = _ct_call(f!, u0, p, 0.0)
        @test du[vm["y"]] === 5.0 * k
        @test du[vm["z"]] === exp(k * m) + 2.0 * exp(k * m)

        # THE ASSERTION. Refresh the buffer in place — `p` is unchanged, so a const
        # classification of the gather slot would freeze `F[1]*k` at 10.0 forever.
        buf[1] = 42.0
        du = _ct_call(f!, u0, p, 0.0)
        @test du[vm["x"]] === sin(42.0 * k) + cos(42.0 * k)
        @test du[vm["y"]] === 42.0 * k
        @test du[vm["z"]] === exp(k * m) + 2.0 * exp(k * m)   # the const chain holds
    end

    # ----------------------------------------------------------------
    # (7) TRAP, HALF TWO — `_NK_CACHED`. A cache ref carries NO leaf of its own, so a
    # def whose only child is one looks state-free to a naive leaf scan. Here
    #   slot 1 = a+b            (states → DYNAMIC)
    #   slot 2 = sin(cache[1])  (leaf-clean! but reads a DYNAMIC slot ⇒ DYNAMIC)
    # A naive classifier reports `n_const_slots == 1` and then freezes `sin(a+b)` at
    # its first-call value: `f!` keeps returning the u₀ answer for every later `u`.
    #   D(a) = sin(a+b) + cos(sin(a+b)) ;  D(b) = 2*sin(a+b)
    # ----------------------------------------------------------------
    @testset "a def reading a DYNAMIC slot through a cache ref is DYNAMIC" begin
        vars = Dict{String,ModelVariable}(
            "a" => ModelVariable(StateVariable; default=0.3),
            "b" => ModelVariable(StateVariable; default=0.5),
        )
        S() = _cse_op("+", _cse_v("a"), _cse_v("b"))
        Q() = _cse_op("sin", S())
        eqs = ESM.Equation[
            ESM.Equation(_cse_D("a"), _cse_op("+", Q(), _cse_op("cos", Q()))),
            ESM.Equation(_cse_D("b"), _cse_op("*", _cse_n(2.0), Q())),
        ]
        f!, u0, p, _ts, vm, diag = ESM._build_evaluator_impl(ESM.Model(vars, eqs))

        # The classification itself: BOTH slots dynamic. The naive scan says 1 const.
        @test diag.n_cse_slots == 2
        @test diag.n_const_slots == 0
        @test diag.n_dynamic_slots == 2

        # And the values, which is what the misclassification would actually corrupt.
        ia, ib = vm["a"], vm["b"]
        for u in ([0.3, 0.5], [1.1, -0.4], [-2.0, 0.25])
            uu = zeros(2); uu[ia] = u[1]; uu[ib] = u[2]
            s = uu[ia] + uu[ib]
            du = _ct_call(f!, uu, p, 0.0)
            @test du[ia] === sin(s) + cos(sin(s))
            @test du[ib] === 2.0 * sin(s)
        end
    end

    # ----------------------------------------------------------------
    # (8) The const tier must not cost the Float64 hot path its zero-allocation
    # property. The stamp lives in an `Any` field, so ASSIGNING it boxes — but that
    # happens only when `p` CHANGES, never on the repeated same-`p` calls an
    # integrator makes. Reading it back and comparing with `===` must not box.
    # ----------------------------------------------------------------
    @testset "zero-allocation `f!` on repeated same-`p` calls" begin
        f!, u0, p, _ts, _vm, diag = ESM._build_evaluator_impl(_ct_arrhenius())
        @test diag.n_const_slots == 5
        du = similar(u0)
        @test rhs_alloc_bytes(f!, du, u0, p, 0.0) == 0
    end

    # ----------------------------------------------------------------
    # (9) `:inplace` (tiered) ≡ `:oop` (untiered — it allocates a fresh cache per call
    # and refills every slot, so it IS the pre-tier evaluator). Bit-for-bit, across a
    # `p` change and repeated calls.
    # ----------------------------------------------------------------
    @testset "`form=:inplace` (tiered) agrees bit-for-bit with `form=:oop`" begin
        fi, u0, p, _ts, _vm, di = ESM._build_evaluator_impl(_ct_arrhenius(); form=:inplace)
        fo, _u0, _p, _ts2, _vm2, dobj =
            ESM._build_evaluator_impl(_ct_arrhenius(); form=:oop)

        # The classification is a property of the PRELUDE, so an `:oop` build reports
        # the same counts — it simply does not act on them.
        @test di.n_const_slots == dobj.n_const_slots == 5
        @test di.n_dynamic_slots == dobj.n_dynamic_slots == 0

        p2 = merge(p, (; A = 7.0 * p.A, R = 8.0))
        for (u, pp) in ((u0, p), (u0, p2), ([0.4, -1.3], p), (u0, p), ([2.0, 2.0], p2))
            @test _ct_call(fi, u, pp, 0.0) == fo(u, pp, 0.0)
        end
    end
end
