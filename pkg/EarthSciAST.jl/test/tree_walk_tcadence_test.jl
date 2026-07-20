# The B3 TIME-cadence tier of the CSE prelude (tree_walk/const_tier.jl).
#
# A prelude slot whose def reaches no `_NK_STATE` leaf — only `t`, parameters, and
# live forcing gathers — is memoized on `(p, t, forcing epoch)` with `t` compared by
# `===` (bit compare). The tier's target is the finite-difference Jacobian: N+1 RHS
# calls at the LITERALLY same `t` with a perturbed state must evaluate the
# state-blind forcing chains (photolysis interpolations, met gathers, `w_time`
# blends) exactly ONCE. These tests pin:
#
#   * the classification (diag counts on a FastJX-shaped fixture),
#   * the EVALUATION COUNT over a mimicked Jacobian fill (a live buffer is the
#     evaluation probe: each evaluation samples its current contents, so pinning
#     which value shows up in `du` counts evaluations exactly),
#   * the invalidation triggers — `t` moved, `p` moved, forcing refreshed,
#   * the AD traps — a `Dual` `t` never hits the Float64-keyed memo; a `Dual` `p`
#     with same values / different partials never reuses another chunk's seed,
#   * step-rejection safety (revisiting a `t` is a pure re-evaluation),
#   * a BIT-EXACT differential oracle vs `ESS_TCADENCE_DISABLE=1` and vs the
#     untiered `:oop` emitter over a mixed call sequence,
#   * an actual stiff Rosenbrock solve (ForwardDiff AND finite-difference
#     Jacobians): identical solutions with the tier on and off.

using Test
using EarthSciAST
using ForwardDiff
import OrdinaryDiffEqRosenbrock
import SciMLBase
const ESM = EarthSciAST

include("testutils.jl")  # _n/_i/_v/_op/_D/_idx + zero-alloc harness

_tc_fn(name, args...) = OpExpr("fn", ESM.ASTExpr[args...]; name=String(name))
_tc_const(v) = OpExpr("const", ESM.ASTExpr[]; value=v)

_tc_call(f!, u, p, t, ::Type{T}=Float64) where {T} =
    (d = zeros(T, length(u)); f!(d, u, p, t); d)

# ---------------------------------------------------------------------------
# The FastJX-shaped fixture: K photolysis bands, each an `interp.linear` over a
# shared solar-angle chain in `t`, plus a met gather from a live buffer, feeding
# a small chemistry. Every observed is state-blind — the B3 shape.
#
#   sza     = 0.5 + 0.4*sin(w*t)                            (t + p)
#   met     = F[1] * scale                                  (forcing + p)
#   band_i  = interp.linear(tbl_i, axis, sza)               (t + p, via a slot ref)
#   D(x_j)  = Σ_i c_ji * band_i * met − loss_j * met * x_j  (state enters HERE
#             only; the loss is met-scaled so the forcing probe shows in ∂f/∂u too)
# ---------------------------------------------------------------------------
_tc_axis() = Float64[0.0, 0.25, 0.5, 0.75, 1.0]
_tc_table(i) = Float64[0.1i, 0.22i, 0.35i, 0.51i, 0.8i]

function _tc_fastjx_model(K::Int, M::Int)
    vars = Dict{String,ModelVariable}(
        "w" => ModelVariable(ParameterVariable; default=0.7),
        "scale" => ModelVariable(ParameterVariable; default=1.5),
        "sza" => ModelVariable(ObservedVariable),
        "met" => ModelVariable(ObservedVariable),
    )
    eqs = ESM.Equation[
        ESM.Equation(_v("sza"),
            _op("+", _n(0.5), _op("*", _n(0.4),
                _op("sin", _op("*", _v("w"), _v("t")))))),
        ESM.Equation(_v("met"), _op("*", _idx("F", _i(1)), _v("scale"))),
    ]
    for i in 1:K
        vars["band$i"] = ModelVariable(ObservedVariable)
        push!(eqs, ESM.Equation(_v("band$i"),
            _tc_fn("interp.linear", _tc_const(_tc_table(i)), _tc_const(_tc_axis()),
                   _v("sza"))))
    end
    for j in 1:M
        vars["x$j"] = ModelVariable(StateVariable; default=1.0 + 0.25j)
        terms = ESM.ASTExpr[_op("*", _n(0.1 + 0.05i + 0.02j),
                                _op("*", _v("band$i"), _v("met"))) for i in 1:K]
        prod = length(terms) == 1 ? terms[1] : OpExpr("+", terms)
        push!(eqs, ESM.Equation(_D("x$j"),
            _op("-", prod,
                _op("*", _n(0.3 + 0.1j), _op("*", _v("met"), _v("x$j"))))))
    end
    return ESM.Model(vars, eqs)
end

# The reference value of one state's derivative, computed the naive way.
function _tc_ref_du(K, j, t, F1; w=0.7, scale=1.5, xj=1.0 + 0.25j)
    sza = 0.5 + 0.4 * sin(w * t)
    met = F1 * scale
    acc = 0.0
    for i in 1:K
        bi = Float64(ESM.evaluate_closed_function(
            "interp.linear", Any[_tc_table(i), _tc_axis(), sza]))
        term = (0.1 + 0.05i + 0.02j) * (bi * met)
        acc = i == 1 ? term : acc + term
    end
    return acc - (0.3 + 0.1j) * (met * xj)
end

@testset "tree_walk TIME-cadence tier (B3)" begin

    # ----------------------------------------------------------------
    # Classification: on the FastJX fixture every observed chain is TIME (the
    # bands read `sza` through a slot ref — clause-2 propagation — and `met`
    # reads a live gather, admissible in the t-tier via the epoch stamp).
    # Nothing is misclassified CONST, nothing state-blind is left DYNAMIC.
    # ----------------------------------------------------------------
    @testset "classification: FastJX-shaped observeds are TIME slots" begin
        K, M = 6, 3
        buf = [2.0]
        _f!, _u0, _p, _ts, _vm, diag = ESM._build_evaluator_impl(
            _tc_fastjx_model(K, M); param_arrays=Dict("F" => buf))
        # sza + met + K bands, all named slots, all t-only.
        @test diag.n_obs_slots == K + 2
        @test diag.n_time_slots >= K + 2
        @test diag.n_const_slots + diag.n_time_slots + diag.n_dynamic_slots ==
              diag.n_cse_slots + diag.n_obs_slots

        # ...and the kill switch demotes every one of them.
        _f2!, _u02, _p2, _ts2, _vm2, d2 = withenv("ESS_TCADENCE_DISABLE" => "1") do
            ESM._build_evaluator_impl(_tc_fastjx_model(K, M);
                param_arrays=Dict("F" => buf))
        end
        @test d2.n_time_slots == 0
        @test d2.n_dynamic_slots == diag.n_dynamic_slots + diag.n_time_slots
        @test d2.n_const_slots == diag.n_const_slots
    end

    # ----------------------------------------------------------------
    # THE COUNTING TEST. A live forcing buffer is the evaluation probe: `met`
    # samples `F[1]` at each EVALUATION, so the value that shows up in `du`
    # identifies which call last evaluated the time tier. Mimic an FD Jacobian
    # fill — N+1 calls at the bit-same `t`, state perturbed one column at a
    # time, with the probe advanced (no notify) before every call. Exactly ONE
    # evaluation ⇒ every du carries the FIRST call's probe value.
    # ----------------------------------------------------------------
    @testset "a mimicked FD-Jacobian fill evaluates the time tier exactly once" begin
        K, M = 4, 3
        buf = [10.0]
        f!, u0, p, _ts, vm, _diag = ESM._build_evaluator_impl(
            _tc_fastjx_model(K, M); param_arrays=Dict("F" => buf))
        t = 1.75
        N = length(u0)

        # Call 1 (the unperturbed RHS of the fill): evaluates the tier at F[1]=10.
        du = _tc_call(f!, u0, p, t)
        for j in 1:M
            @test du[vm["x$j"]] === _tc_ref_du(K, j, t, 10.0; xj=u0[vm["x$j"]])
        end

        # Calls 2..N+1: perturb one state per call, advance the probe per call.
        # If ANY of them re-evaluated the time tier, its du would sample the
        # advanced probe (F[1] = 100+col) instead of 10.0 — a loud mismatch,
        # since the ref value below is pinned at 10.0.
        for col in 1:N
            buf[1] = 100.0 + col                    # probe: no notify, same t
            up = copy(u0); up[col] += 1e-6 * (1.0 + abs(u0[col]))
            dup = _tc_call(f!, up, p, t)
            for j in 1:M
                @test dup[vm["x$j"]] === _tc_ref_du(K, j, t, 10.0; xj=up[vm["x$j"]])
            end
        end

        # Trigger 1 — `t` moved (a new step): re-evaluates, sees the probe's
        # current value. Bit-compare on t means ANY different t refills.
        t2 = t + 1e-9
        du2 = _tc_call(f!, u0, p, t2)
        @test du2[vm["x1"]] === _tc_ref_du(K, 1, t2, 100.0 + N; xj=u0[vm["x1"]])

        # Trigger 2 — forcing refresh at the SAME t: notify bumps the epoch and
        # the very next call re-evaluates.
        buf[1] = 55.0
        ESM.notify_forcing_refresh!()
        du3 = _tc_call(f!, u0, p, t2)
        @test du3[vm["x1"]] === _tc_ref_du(K, 1, t2, 55.0; xj=u0[vm["x1"]])

        # ...and WITHOUT a further notify, the memo holds again at t2.
        buf[1] = 77.0
        du4 = _tc_call(f!, u0, p, t2)
        @test du4[vm["x1"]] === _tc_ref_du(K, 1, t2, 55.0; xj=u0[vm["x1"]])

        # Trigger 3 — `p` moved: refills even at an unchanged (t, epoch).
        p2 = merge(p, (; scale = 2.0 * p.scale))
        du5 = _tc_call(f!, u0, p2, t2)
        @test du5[vm["x1"]] ===
              _tc_ref_du(K, 1, t2, 77.0; scale=2.0 * p.scale, xj=u0[vm["x1"]])

        # STEP REJECTION: revisit the original t. The slots are pure functions
        # of (p, t, forcing) — no history — so the revisit recomputes exactly
        # the value the first visit would produce with the CURRENT forcing.
        du6 = _tc_call(f!, u0, p, t)
        @test du6[vm["x1"]] === _tc_ref_du(K, 1, t, 77.0; xj=u0[vm["x1"]])
    end

    # ----------------------------------------------------------------
    # The same count under a REAL ForwardDiff Jacobian (Dual state, fixed t —
    # the stiff-solver shape). The probe is advanced between two jacobian
    # calls without notify: identical J ⇒ the Dual-buffer time tier did not
    # re-evaluate. After notify, J moves.
    # ----------------------------------------------------------------
    @testset "ForwardDiff Jacobian at fixed t reuses one time-tier fill" begin
        K, M = 4, 2
        buf = [3.0]
        f!, u0, p, _ts, _vm, _diag = ESM._build_evaluator_impl(
            _tc_fastjx_model(K, M); param_arrays=Dict("F" => buf))
        t = 0.6
        g!(d, uu) = f!(d, uu, p, t)
        J1 = ForwardDiff.jacobian(g!, zeros(length(u0)), u0)
        # ∂(du_j)/∂x_j = -loss_j*met — the probe IS visible in the Jacobian.
        @test any(!iszero, J1)

        buf[1] = 30.0                       # probe: no notify, same t
        J2 = ForwardDiff.jacobian(g!, zeros(length(u0)), u0)
        @test J2 == J1                      # zero re-evaluations of the tier

        ESM.notify_forcing_refresh!()
        J3 = ForwardDiff.jacobian(g!, zeros(length(u0)), u0)
        @test J3 != J1                      # the refresh reached the Dual buffer
        # met went 3.0*scale → 30.0*scale and enters ∂/∂x linearly:
        @test J3 ≈ 10.0 .* J1
    end

    # ----------------------------------------------------------------
    # AD TRAP 1 — a Dual `t` must not hit the Float64-keyed memo. Alternate a
    # Float64 call and a ForwardDiff.derivative over `t` AT THE SAME VALUE of
    # `t`, both orders; egal is type-discriminating, so each rides its own
    # buffer/stamp and both are exact.
    # ----------------------------------------------------------------
    @testset "Dual t never satisfies the Float64 memo (AD over time)" begin
        K, M = 3, 2
        buf = [4.0]
        for float_first in (true, false)
            f!, u0, p, _ts, vm, _diag = ESM._build_evaluator_impl(
                _tc_fastjx_model(K, M); param_arrays=Dict("F" => buf))
            t = 0.4     # keeps sza well inside one interp cell (knot at 0.625)
            sumdu(tt) = sum(_tc_call(f!, u0, p, tt, typeof(tt)))
            if float_first
                _ = sumdu(t)                       # stamp the Float64 memo at t
            end
            dS = ForwardDiff.derivative(sumdu, t)  # Dual t, SAME value of t
            # Central-difference reference on the disabled build (independent).
            fd!, u0d, pd, _tsd, _vmd, _dd = withenv("ESS_TCADENCE_DISABLE" => "1") do
                ESM._build_evaluator_impl(_tc_fastjx_model(K, M);
                    param_arrays=Dict("F" => buf))
            end
            h = 1e-7
            ref = (sum(_tc_call(fd!, u0d, pd, t + h)) -
                   sum(_tc_call(fd!, u0d, pd, t - h))) / 2h
            @test isapprox(dS, ref; rtol=1e-6, atol=1e-10)
            # And the Float64 path afterwards is not poisoned by the Dual call.
            du = _tc_call(f!, u0, p, t)
            @test du[vm["x1"]] === _tc_ref_du(K, 1, t, 4.0; xj=u0[vm["x1"]])
        end
    end

    # ----------------------------------------------------------------
    # AD TRAP 2 — ForwardDiff over PARAMETERS through a TIME slot, Chunk{1}:
    # four Dual `p`s with the SAME values and DIFFERENT partials at one fixed
    # `t`. A stamp keyed on `==` (or on values only) would reuse chunk 1's
    # seed for chunks 2..4 and silently zero their sensitivities; `===` sees
    # the partials.
    # ----------------------------------------------------------------
    @testset "ForwardDiff over p through a time slot (Chunk{1})" begin
        K, M = 3, 2
        buf = [2.5]
        f!, u0, p, _ts, _vm, _diag = ESM._build_evaluator_impl(
            _tc_fastjx_model(K, M); param_arrays=Dict("F" => buf))
        t = 1.1
        syms = keys(p)
        pv = collect(values(p))
        mk(v) = NamedTuple{syms}(Tuple(v))
        gfun = v -> sum(_tc_call(f!, u0, mk(v), t, eltype(v)))
        cfg = ForwardDiff.GradientConfig(gfun, pv, ForwardDiff.Chunk{1}())
        g = ForwardDiff.gradient(gfun, pv, cfg)
        @test all(!iszero, g)
        h = 1e-6
        for i in eachindex(pv)
            s = h * max(1.0, abs(pv[i]))
            up = copy(pv); up[i] += s
            um = copy(pv); um[i] -= s
            fd = (sum(_tc_call(f!, u0, mk(up), t)) -
                  sum(_tc_call(f!, u0, mk(um), t))) / 2s
            @test isapprox(g[i], fd; rtol=1e-5, atol=1e-10)
        end
    end

    # ----------------------------------------------------------------
    # THE DIFFERENTIAL ORACLE. Tiered `f!` ≡ `ESS_TCADENCE_DISABLE=1` build ≡
    # untiered `:oop`, BIT-FOR-BIT, over a mixed sequence: repeated t (the
    # skip), new t, perturbed u, changed p, in-place forcing refresh through
    # the supported (notify) surface, and a revisited t. Same buffer feeds all
    # three builds, refreshes are notified, so all three must agree exactly.
    # ----------------------------------------------------------------
    @testset "bit-exact differential oracle: tiered ≡ disabled ≡ :oop" begin
        K, M = 5, 3
        buf = [6.0]
        mk() = _tc_fastjx_model(K, M)
        pa() = Dict("F" => buf)
        fi, u0, p, _ts, _vm, di = ESM._build_evaluator_impl(mk(); param_arrays=pa())
        fdis, _u2, _p2, _ts2, _vm2, ddis = withenv("ESS_TCADENCE_DISABLE" => "1") do
            ESM._build_evaluator_impl(mk(); param_arrays=pa())
        end
        foop, _u3, _p3, _ts3, _vm3, _doop =
            ESM._build_evaluator_impl(mk(); param_arrays=pa(), form=:oop)
        @test di.n_time_slots > 0
        @test ddis.n_time_slots == 0

        p2 = merge(p, (; w = 0.9, scale = 2.25))
        seq = Any[]
        push!(seq, (u0, p, 0.0));  push!(seq, (u0, p, 0.0))         # skip
        up = copy(u0); up[1] += 1e-6
        push!(seq, (up, p, 0.0))                                    # FD column
        push!(seq, (u0, p, 0.125)); push!(seq, (u0, p, 0.125))      # new t + skip
        push!(seq, (u0, p2, 0.125))                                 # p change
        push!(seq, (u0, p, 0.125))                                  # p back
        push!(seq, (:refresh, 42.5, nothing))                       # refresh+notify
        push!(seq, (u0, p, 0.125))                                  # same t, new F
        push!(seq, (u0, p, 0.0))                                    # rejected-step revisit
        push!(seq, (up, p2, 0.125))
        for step in seq
            if step[1] === :refresh
                buf[1] = step[2]
                ESM.notify_forcing_refresh!()
                continue
            end
            u, pp, t = step
            a = _tc_call(fi, u, pp, t)
            b = _tc_call(fdis, u, pp, t)
            c = foop(u, pp, t)
            @test a == b
            @test collect(c) == a
        end
    end

    # ----------------------------------------------------------------
    # Zero-allocation: the t-tier adds no per-call allocation — neither on the
    # repeated same-t path (the skip) nor when t MOVES every call (the stamp
    # write is a typed field store, not a box).
    # ----------------------------------------------------------------
    @testset "f! stays allocation-free: same t and moving t" begin
        K, M = 4, 2
        buf = [1.0]
        f!, u0, p, _ts, _vm, diag = ESM._build_evaluator_impl(
            _tc_fastjx_model(K, M); param_arrays=Dict("F" => buf))
        @test diag.n_time_slots > 0
        du = similar(u0)
        @test rhs_alloc_bytes(f!, du, u0, p, 0.5) == 0
        # moving t: warm at several t, then measure with a fresh t each sample
        f!(du, u0, p, 0.1); f!(du, u0, p, 0.2); f!(du, u0, p, 0.3)
        best = typemax(Int)
        tnext = 1.0
        for _ in 1:5
            tnext += 0.03125
            best = min(best, @allocated f!(du, u0, p, tnext))
        end
        @test best == 0
    end

    # ----------------------------------------------------------------
    # END TO END: a small stiff solve whose Jacobians are built BOTH ways —
    # ForwardDiff (Dual u at fixed t) and finite differences (Float64 u at
    # fixed t, the N+1-calls shape) — must produce IDENTICAL solutions with
    # the tier on and off. This is the whole-integrator statement of the
    # bit-exactness contract (same RHS bits ⇒ same solver decisions ⇒ same
    # trajectory, bit for bit).
    # ----------------------------------------------------------------
    @testset "Rosenbrock23 solve: tiered ≡ disabled, AD and FD Jacobians" begin
        K, M = 4, 3
        buf = [2.0]
        prob_of(f!, u0, p) = SciMLBase.ODEProblem(f!, copy(u0), (0.0, 5.0), p)
        fi, u0, p, _ts, _vm, di = ESM._build_evaluator_impl(
            _tc_fastjx_model(K, M); param_arrays=Dict("F" => buf))
        fdis, _u, _p, _ts2, _vm2, ddis = withenv("ESS_TCADENCE_DISABLE" => "1") do
            ESM._build_evaluator_impl(_tc_fastjx_model(K, M);
                param_arrays=Dict("F" => buf))
        end
        @test di.n_time_slots > 0 && ddis.n_time_slots == 0
        for autodiff in (true, false)
            alg = autodiff ? OrdinaryDiffEqRosenbrock.Rosenbrock23() :
                OrdinaryDiffEqRosenbrock.Rosenbrock23(;
                    autodiff=OrdinaryDiffEqRosenbrock.AutoFiniteDiff())
            s1 = OrdinaryDiffEqRosenbrock.solve(prob_of(fi, u0, p), alg;
                reltol=1e-8, abstol=1e-10)
            s2 = OrdinaryDiffEqRosenbrock.solve(prob_of(fdis, u0, p), alg;
                reltol=1e-8, abstol=1e-10)
            @test SciMLBase.successful_retcode(s1)
            @test s1.t == s2.t
            @test s1.u == s2.u
        end
    end
end
