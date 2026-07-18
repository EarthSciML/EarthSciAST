# Named scalar-observed prelude slots (ess-obs-slots).
#
# A SCALAR observed compiles ONCE as a NAMED PRELUDE DEF (an `_NK_CACHED` slot
# evaluated in dependency order before the equations) instead of being spliced
# into every reader (`_plan_observed_slots` / `_cse_compile_scalar`). These
# tests pin the new mechanism:
#
#   * slots      — each safe scalar observed is a named slot (`n_obs_slots`),
#                  evaluated once per call, in dependency order (chains work);
#   * fallbacks  — guard-only references, structural (build-time) references,
#                  leaf bodies and array-valued observeds stay INLINED
#                  (`n_obs_inlined`) — behavior identical to the pre-slot build;
#   * cadence    — a parameter-only observed slot lands in the CONST tier;
#   * AD         — slots ride the eltype-generic alt-buffer scheme (ForwardDiff
#                  over state AND over parameters), and `:oop` ≡ `:inplace`;
#   * zero-alloc — the slot prelude keeps `f!` allocation-free at Float64.

using Test
using EarthSciAST
using ForwardDiff
const ESM = EarthSciAST

include("testutils.jl")  # zero_alloc_harness.jl → rhs_alloc_bytes

_obs_n(x) = NumExpr(Float64(x))
_obs_v(n) = VarExpr(n)
_obs_op(op, args...; kw...) = OpExpr(op, ESM.ASTExpr[args...]; kw...)
_obs_D(v) = _obs_op("D", _obs_v(v); wrt="t")

@testset "scalar observeds compile as named prelude slots (ess-obs-slots)" begin

    # ----------------------------------------------------------------
    # The basic slot: one observed, several readers — one named def, zero
    # anonymous CSE (the name carries the sharing), bit-exact numerics.
    # ----------------------------------------------------------------
    @testset "one named slot, many readers, no anonymous CSE" begin
        vars = Dict{String,ModelVariable}(
            "x" => ModelVariable(StateVariable; default=0.4),
            "y" => ModelVariable(StateVariable; default=1.1),
            "k" => ModelVariable(ParameterVariable; default=0.7),
            "flux" => ModelVariable(ObservedVariable),
        )
        # flux = k*x*y; D(x) = -flux; D(y) = flux + sin(flux)
        eqs = ESM.Equation[
            ESM.Equation(_obs_v("flux"), _obs_op("*", _obs_v("k"), _obs_v("x"), _obs_v("y"))),
            ESM.Equation(_obs_D("x"), _obs_op("neg", _obs_v("flux"))),
            ESM.Equation(_obs_D("y"), _obs_op("+", _obs_v("flux"), _obs_op("sin", _obs_v("flux")))),
        ]
        f!, u0, p, _ts, vm, diag = ESM._build_evaluator_impl(ESM.Model(vars, eqs))
        @test diag.n_obs_slots == 1
        @test diag.n_obs_inlined == 0
        @test diag.n_cse_slots == 0          # the name subsumed the sharing
        fluxv = 0.7 * 0.4 * 1.1
        du = similar(u0)
        f!(du, u0, p, 0.0)
        @test du[vm["x"]] === -fluxv
        @test du[vm["y"]] === fluxv + sin(fluxv)
    end

    # ----------------------------------------------------------------
    # Chains: a slot def reads ANOTHER slot by name (dependency order), and a
    # LEAF-bodied observed (a bare alias) is inlined — a slot would only add a
    # store + a load around a bare read.
    # ----------------------------------------------------------------
    @testset "observed-into-observed chains are slot-to-slot reads" begin
        vars = Dict{String,ModelVariable}(
            "x" => ModelVariable(StateVariable; default=1.0),
            "k" => ModelVariable(ParameterVariable; default=2.0),
            "a" => ModelVariable(ObservedVariable),
            "b" => ModelVariable(ObservedVariable),
            "c" => ModelVariable(ObservedVariable),
        )
        # c = b + 1; b = a * a; a = k (leaf → inlined);  D(x) = c * x
        eqs = ESM.Equation[
            ESM.Equation(_obs_v("c"), _obs_op("+", _obs_v("b"), _obs_n(1.0))),
            ESM.Equation(_obs_v("b"), _obs_op("*", _obs_v("a"), _obs_v("a"))),
            ESM.Equation(_obs_v("a"), _obs_v("k")),
            ESM.Equation(_obs_D("x"), _obs_op("*", _obs_v("c"), _obs_v("x"))),
        ]
        f!, u0, p, _ts, vm, diag = ESM._build_evaluator_impl(ESM.Model(vars, eqs))
        @test diag.n_obs_slots == 2      # b and c; a is a leaf alias
        @test diag.n_obs_inlined == 1
        du = similar(u0)
        f!(du, u0, p, 0.0)
        @test du[vm["x"]] === (2.0 * 2.0 + 1.0) * 1.0
    end

    # ----------------------------------------------------------------
    # GUARD fallback: an observed referenced ONLY under a lazy guard must not
    # be hoisted into the unconditional prelude — `sqrt(a)` at `a = -1` would
    # turn into a DomainError. It stays inlined behind its guard (per-observed,
    # the same rule CSE applies per-key).
    # ----------------------------------------------------------------
    @testset "guard-only observed stays inlined (no new DomainError)" begin
        vars = Dict{String,ModelVariable}(
            "a" => ModelVariable(StateVariable; default=-1.0),
            "g" => ModelVariable(ObservedVariable),
        )
        eqs = ESM.Equation[
            ESM.Equation(_obs_v("g"), _obs_op("sqrt", _obs_v("a"))),
            ESM.Equation(_obs_D("a"),
                _obs_op("ifelse", _obs_op(">=", _obs_v("a"), _obs_n(0.0)),
                        _obs_v("g"), _obs_n(0.0))),
        ]
        f!, u0, p, _ts, vm, diag = ESM._build_evaluator_impl(ESM.Model(vars, eqs))
        @test diag.n_obs_slots == 0
        @test diag.n_obs_inlined == 1
        du = similar(u0)
        f!(du, u0, p, 0.0)     # must NOT throw
        @test du[vm["a"]] === 0.0
    end

    # ----------------------------------------------------------------
    # ... but ONE unconditional reference makes the slot safe (the pre-slot
    # walk evaluated the body every call anyway), and the guarded readers then
    # share it.
    # ----------------------------------------------------------------
    @testset "one unconditional reference keeps the slot" begin
        vars = Dict{String,ModelVariable}(
            "a" => ModelVariable(StateVariable; default=2.25),
            "z" => ModelVariable(StateVariable; default=0.0),
            "g" => ModelVariable(ObservedVariable),
        )
        eqs = ESM.Equation[
            ESM.Equation(_obs_v("g"), _obs_op("sqrt", _obs_v("a"))),
            ESM.Equation(_obs_D("z"), _obs_v("g")),                       # unconditional
            ESM.Equation(_obs_D("a"),
                _obs_op("ifelse", _obs_op(">=", _obs_v("a"), _obs_n(0.0)),
                        _obs_v("g"), _obs_n(0.0))),                       # guarded
        ]
        f!, u0, p, _ts, vm, diag = ESM._build_evaluator_impl(ESM.Model(vars, eqs))
        @test diag.n_obs_slots == 1
        du = similar(u0)
        f!(du, u0, p, 0.0)
        @test du[vm["z"]] === sqrt(2.25)
        @test du[vm["a"]] === sqrt(2.25)
    end

    # ----------------------------------------------------------------
    # Transitive guard demotion (the fixed point): X is referenced
    # unconditionally ONLY by Y's def, and Y only under a guard. Slotting X
    # would evaluate it unconditionally through nothing but demoted defs — both
    # must fall back to inlining.
    # ----------------------------------------------------------------
    @testset "a slot kept alive only by a demoted def is demoted too" begin
        vars = Dict{String,ModelVariable}(
            "a" => ModelVariable(StateVariable; default=-4.0),
            "X" => ModelVariable(ObservedVariable),
            "Y" => ModelVariable(ObservedVariable),
        )
        eqs = ESM.Equation[
            ESM.Equation(_obs_v("X"), _obs_op("sqrt", _obs_v("a"))),
            ESM.Equation(_obs_v("Y"), _obs_op("+", _obs_v("X"), _obs_n(1.0))),
            ESM.Equation(_obs_D("a"),
                _obs_op("ifelse", _obs_op(">=", _obs_v("a"), _obs_n(0.0)),
                        _obs_v("Y"), _obs_n(0.0))),
        ]
        f!, u0, p, _ts, vm, diag = ESM._build_evaluator_impl(ESM.Model(vars, eqs))
        @test diag.n_obs_slots == 0
        @test diag.n_obs_inlined == 2
        du = similar(u0)
        f!(du, u0, p, 0.0)     # must NOT throw (sqrt(-4) never evaluated)
        @test du[vm["a"]] === 0.0
    end

    # ----------------------------------------------------------------
    # STRUCTURAL fallback: an observed read where the build needs a concrete
    # value at build time — a gather subscript — stays inlined so the existing
    # const-index folding still works.
    # ----------------------------------------------------------------
    @testset "observed in a gather subscript stays inlined" begin
        vars = Dict{String,ModelVariable}(
            "u" => ModelVariable(StateVariable; shape=["i"]),
            "sel" => ModelVariable(ObservedVariable),
            "z" => ModelVariable(StateVariable; default=0.0),
        )
        # sel = 1 + 1 (an OpExpr body, but referenced as a subscript);
        # D(z) = u[sel]; D(u[i]) = 0 for i in 1..3
        eqs = ESM.Equation[
            ESM.Equation(_obs_v("sel"), _obs_op("+", _obs_n(1.0), _obs_n(1.0))),
            ESM.Equation(_obs_D("z"),
                _obs_op("index", _obs_v("u"), _obs_v("sel"))),
        ]
        for i in 1:3
            push!(eqs, ESM.Equation(
                _obs_op("D", _obs_op("index", _obs_v("u"), IntExpr(Int64(i))); wrt="t"),
                _obs_n(0.0)))
        end
        ics = Dict{String,Float64}("u[1]" => 10.0, "u[2]" => 20.0, "u[3]" => 30.0)
        f!, u0, p, _ts, vm, diag = ESM._build_evaluator_impl(
            ESM.Model(vars, eqs); initial_conditions=ics)
        @test diag.n_obs_slots == 0
        @test diag.n_obs_inlined == 1
        du = similar(u0)
        f!(du, u0, p, 0.0)
        @test du[vm["z"]] === 20.0     # u[1+1] — folded at build time, as before
    end

    # ----------------------------------------------------------------
    # Two observeds with canonically identical bodies: the second ALIASES the
    # first's prelude def (one def evaluated, two names) — and the numbers are
    # exactly the shared value.
    # ----------------------------------------------------------------
    @testset "identical observed bodies alias one prelude def" begin
        vars = Dict{String,ModelVariable}(
            "x" => ModelVariable(StateVariable; default=0.9),
            "p1" => ModelVariable(ObservedVariable),
            "p2" => ModelVariable(ObservedVariable),
        )
        body() = _obs_op("exp", _obs_op("*", _obs_n(2.0), _obs_v("x")))
        eqs = ESM.Equation[
            ESM.Equation(_obs_v("p1"), body()),
            ESM.Equation(_obs_v("p2"), body()),
            ESM.Equation(_obs_D("x"), _obs_op("+", _obs_v("p1"), _obs_v("p2"))),
        ]
        f!, u0, p, _ts, vm, diag = ESM._build_evaluator_impl(ESM.Model(vars, eqs))
        @test diag.n_obs_slots == 2               # two NAMED slots …
        # … sharing anonymous CSE defs (the whole body, and — nested hoisting —
        # its `2*x` child get their own slots; both names alias the body's).
        @test 1 <= diag.n_cse_slots <= 2
        du = similar(u0)
        f!(du, u0, p, 0.0)
        @test du[vm["x"]] === exp(2.0 * 0.9) + exp(2.0 * 0.9)
    end

    # ----------------------------------------------------------------
    # Cadence: a parameter-only observed def is a CONST-tier slot — skipped
    # while `p` has not moved — and a state-reading one is DYNAMIC.
    # ----------------------------------------------------------------
    @testset "parameter-only observed slot lands in the const tier" begin
        vars = Dict{String,ModelVariable}(
            "x" => ModelVariable(StateVariable; default=1.0),
            "A" => ModelVariable(ParameterVariable; default=3.0),
            "Ea" => ModelVariable(ParameterVariable; default=0.5),
            "arr" => ModelVariable(ObservedVariable),   # A*exp(-Ea) — p-only
            "sc" => ModelVariable(ObservedVariable),    # arr*x — state-reading
        )
        eqs = ESM.Equation[
            ESM.Equation(_obs_v("arr"),
                _obs_op("*", _obs_v("A"), _obs_op("exp", _obs_op("neg", _obs_v("Ea"))))),
            ESM.Equation(_obs_v("sc"), _obs_op("*", _obs_v("arr"), _obs_v("x"))),
            ESM.Equation(_obs_D("x"), _obs_op("neg", _obs_v("sc"))),
        ]
        f!, u0, p, _ts, vm, diag = ESM._build_evaluator_impl(ESM.Model(vars, eqs))
        @test diag.n_obs_slots == 2
        @test diag.n_const_slots >= 1     # `arr` (and nothing forces more)
        @test diag.n_dynamic_slots >= 1   # `sc` reads state
        du = similar(u0)
        f!(du, u0, p, 0.0)
        @test du[vm["x"]] === -(3.0 * exp(-0.5) * 1.0)
    end

    # ----------------------------------------------------------------
    # Zero-allocation: the slot prelude is part of the same zero-alloc `f!`
    # contract as the CSE prelude (steady state, repeated same-`p` calls).
    # ----------------------------------------------------------------
    @testset "slot prelude keeps f! allocation-free at Float64" begin
        vars = Dict{String,ModelVariable}(
            "x" => ModelVariable(StateVariable; default=0.4),
            "y" => ModelVariable(StateVariable; default=1.1),
            "k" => ModelVariable(ParameterVariable; default=0.7),
            "flux" => ModelVariable(ObservedVariable),
        )
        eqs = ESM.Equation[
            ESM.Equation(_obs_v("flux"), _obs_op("*", _obs_v("k"), _obs_v("x"), _obs_v("y"))),
            ESM.Equation(_obs_D("x"), _obs_op("neg", _obs_v("flux"))),
            ESM.Equation(_obs_D("y"), _obs_v("flux")),
        ]
        f!, u0, p, _ts, _vm, _diag = ESM._build_evaluator_impl(ESM.Model(vars, eqs))
        du = similar(u0)
        @test rhs_alloc_bytes(f!, du, u0, p, 0.0) == 0
    end

    # ----------------------------------------------------------------
    # AD gate: ForwardDiff over the STATE and over the PARAMETERS through the
    # slot prelude (the eltype-generic alt buffer), and `:oop` ≡ `:inplace`
    # bit-for-bit at Float64.
    # ----------------------------------------------------------------
    @testset "ForwardDiff through observed slots; :oop ≡ :inplace" begin
        vars = Dict{String,ModelVariable}(
            "x" => ModelVariable(StateVariable; default=0.8),
            "k" => ModelVariable(ParameterVariable; default=1.3),
            "r" => ModelVariable(ObservedVariable),
        )
        # r = k * x^2; D(x) = -r + sin(r)
        eqs = ESM.Equation[
            ESM.Equation(_obs_v("r"),
                _obs_op("*", _obs_v("k"), _obs_op("^", _obs_v("x"), _obs_n(2.0)))),
            ESM.Equation(_obs_D("x"), _obs_op("+", _obs_op("neg", _obs_v("r")),
                                              _obs_op("sin", _obs_v("r")))),
        ]
        model = ESM.Model(vars, eqs)
        f!, u0, p, _ts, vm, diag = ESM._build_evaluator_impl(model)
        @test diag.n_obs_slots == 1
        foop, _u2, _p2, _ts2, _vm2, _d2 = ESM._build_evaluator_impl(model; form=:oop)

        # Analytic: du/dx of (-kx² + sin(kx²)) = -2kx + cos(kx²)·2kx
        k, x = 1.3, 0.8
        dref = -2k * x + cos(k * x^2) * 2k * x
        # over the STATE (in place — the Dual alt buffer)
        J = ForwardDiff.jacobian((du, u) -> f!(du, u, p, 0.0), similar(u0), u0)
        @test isapprox(J[1, 1], dref; rtol=1e-12, atol=1e-12)
        # over the PARAMETERS (Dual p values; u stays Float64)
        g = ForwardDiff.derivative(kk -> begin
            du = zeros(typeof(kk), 1)
            f!(du, u0, (; k=kk), 0.0)
            du[vm["x"]]
        end, k)
        gref = -x^2 + cos(k * x^2) * x^2
        @test isapprox(g, gref; rtol=1e-12, atol=1e-12)
        # Float64 :oop is bit-identical to :inplace
        du = similar(u0)
        f!(du, u0, p, 0.0)
        @test foop(u0, p, 0.0) == du
        # and a Float64 call AFTER the Dual calls is still bit-identical
        # (the f64 buffer was not clobbered by the alt buffer)
        f!(du, u0, p, 0.0)
        @test du == foop(u0, p, 0.0)
    end

    # ----------------------------------------------------------------
    # Numeric identity with the pre-slot build on a plain chain: the slot
    # mechanism evaluates the same body once and feeds the same value to each
    # reader, so the trajectory-level values are bit-identical to hand
    # evaluation.
    # ----------------------------------------------------------------
    @testset "slot values are the hand-evaluated values, bit for bit" begin
        vars = Dict{String,ModelVariable}(
            "T" => ModelVariable(StateVariable; default=300.0),
            "q" => ModelVariable(StateVariable; default=0.01),
            "es" => ModelVariable(ObservedVariable),
            "rh" => ModelVariable(ObservedVariable),
        )
        # es = 610.78*exp(17.27*(T-273.15)/(T-35.85)); rh = q*1e5/(0.622*es)
        es_body = _obs_op("*", _obs_n(610.78),
            _obs_op("exp", _obs_op("/",
                _obs_op("*", _obs_n(17.27), _obs_op("-", _obs_v("T"), _obs_n(273.15))),
                _obs_op("-", _obs_v("T"), _obs_n(35.85)))))
        rh_body = _obs_op("/", _obs_op("*", _obs_v("q"), _obs_n(1e5)),
                          _obs_op("*", _obs_n(0.622), _obs_v("es")))
        eqs = ESM.Equation[
            ESM.Equation(_obs_v("es"), es_body),
            ESM.Equation(_obs_v("rh"), rh_body),
            ESM.Equation(_obs_D("T"), _obs_op("*", _obs_n(-0.01), _obs_v("rh"))),
            ESM.Equation(_obs_D("q"), _obs_op("*", _obs_n(-1e-6), _obs_v("es"))),
        ]
        f!, u0, p, _ts, vm, diag = ESM._build_evaluator_impl(ESM.Model(vars, eqs))
        @test diag.n_obs_slots == 2
        T, q = 300.0, 0.01
        es = 610.78 * exp(17.27 * (T - 273.15) / (T - 35.85))
        rh = q * 1e5 / (0.622 * es)
        du = similar(u0)
        f!(du, u0, p, 0.0)
        @test du[vm["T"]] === -0.01 * rh
        @test du[vm["q"]] === -1e-6 * es
    end
end
