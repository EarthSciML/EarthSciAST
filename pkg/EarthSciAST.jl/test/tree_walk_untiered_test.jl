# `compiler=:interpreter` against `compiler=:native`, on the prelude.
#
# WHAT THIS FILE IS FOR. The cadence tiers of the in-place prelude (const_tier.jl)
# let `f!` SKIP refilling a slot whose inputs provably have not moved. Every test
# that pins "the skip changed no number" needs a reference evaluator that skips
# nothing, and `:interpreter` is it: it classifies every prelude slot DYNAMIC, so
# `f!` refills all of them, in ascending slot order, on every call.
#
# This file is what makes that reference trustworthy — it pins the interpreter's
# own prelude (every slot really is classified dynamic, and the prelude is
# otherwise unchanged) and then `f!(:native) == f!(:interpreter)` bit for bit
# over the call sequences the tiers are allowed to skip on. The other tiering
# tests use `:interpreter` as their oracle for the same reason.
#
# THE FIXTURES exercise the two tiers separately and then together:
#
#   * the Arrhenius model — a parameter-only chain, so every slot is CONST and the
#     const skip is what the comparison is about;
#   * the FastJX-shaped model over a LIVE forcing buffer — state-blind observed
#     chains in `t`, so the slots are TIME and the comparison covers the `(p, t,
#     epoch)` stamp, including an in-place buffer refresh and a revisited `t`;
#   * three `tests/valid` fixtures with observed chains, so the switch is pinned on
#     documents nobody wrote for this test. (No fixture in that corpus carries a
#     TIME-tier slot — the corpus models are `t`-free — which is why the
#     time-cadence arm rides on the hand-built buffer fixture above.)
#
# The call SEQUENCES are the ones the tiers are allowed to skip on: a repeat of the
# same `(u, p, t)`, a parameter change, a new `t`, a `t` that is REVISITED after
# moving away (the rejected-step shape), and a forcing-buffer refresh at an
# unchanged `t`. Comparison is on raw bits (`reinterpret`), not `==`, so a `NaN`
# agrees with itself and a signed zero does not agree with its opposite.

using Test
using EarthSciAST
const ESM = EarthSciAST

include("testutils.jl")  # _n/_v/_op/_D/_idx + TESTUTILS_REPO_ROOT

_ut_call(f!, u, p, t) = (d = zeros(Float64, length(u)); f!(d, u, p, t); d)

# Bit identity, so `NaN === NaN` and `0.0 !== -0.0`.
_ut_bits(v) = UInt64[reinterpret(UInt64, Float64(x)) for x in v]
_ut_same(a, b) = _ut_bits(collect(a)) == _ut_bits(collect(b))

# The three builds under comparison, from one model-producing thunk.
_ut_tiered(mk; kw...) = ESM._build_evaluator_impl(mk(); kw...)
_ut_untiered(mk; kw...) =
    ESM._build_evaluator_impl(mk(); compiler=:interpreter, kw...)

# ---------------------------------------------------------------------------
# Fixture 1 — the parameter-only Arrhenius chain: `k = A*exp(-Ea/(R*Tref))`
# shared by two equations, so CSE names the whole chain and every slot is
# CONST-cadence. Carried here rather than borrowed so this file runs standalone.
# ---------------------------------------------------------------------------
_ut_arrhenius() = ESM.Model(
    Dict{String,ModelVariable}(
        "x"    => ModelVariable(UnknownVariable; default=1.5),
        "y"    => ModelVariable(UnknownVariable; default=2.5),
        "A"    => ModelVariable(ParameterVariable; default=3.2e5),
        "Ea"   => ModelVariable(ParameterVariable; default=5.0e4),
        "R"    => ModelVariable(ParameterVariable; default=8.314),
        "Tref" => ModelVariable(ParameterVariable; default=300.0),
    ),
    begin
        arr() = _op("*", _v("A"),
                    _op("exp", _op("/", _op("neg", _v("Ea")),
                                _op("*", _v("R"), _v("Tref")))))
        ESM.Equation[
            ESM.Equation(_D("x"), _op("*", arr(), _v("x"))),
            ESM.Equation(_D("y"), _op("*", _op("neg", arr()), _v("y"))),
        ]
    end)

# ---------------------------------------------------------------------------
# Fixture 2 — the FastJX-shaped model: K photolysis bands interpolated over a
# shared solar-angle chain in `t`, plus a met gather from a LIVE buffer, feeding
# M chemistry states. Every observed is state-blind, so the slots are TIME.
# ---------------------------------------------------------------------------
_ut_fn(name, args...) = OpExpr("fn", ESM.ASTExpr[args...]; name=String(name))
_ut_const(v) = OpExpr("const", ESM.ASTExpr[]; value=v)
_ut_axis() = Float64[0.0, 0.25, 0.5, 0.75, 1.0]
_ut_table(i) = Float64[0.1i, 0.22i, 0.35i, 0.51i, 0.8i]

function _ut_fastjx_model(K::Int, M::Int)
    vars = Dict{String,ModelVariable}(
        "w" => ModelVariable(ParameterVariable; default=0.7),
        "scale" => ModelVariable(ParameterVariable; default=1.5),
        "sza" => ModelVariable(UnknownVariable),
        "met" => ModelVariable(UnknownVariable),
    )
    eqs = ESM.Equation[
        ESM.Equation(_v("sza"),
            _op("+", _n(0.5), _op("*", _n(0.4),
                _op("sin", _op("*", _v("w"), _v("t")))))),
        ESM.Equation(_v("met"), _op("*", _idx("F", _i(1)), _v("scale"))),
    ]
    for i in 1:K
        vars["band$i"] = ModelVariable(UnknownVariable)
        push!(eqs, ESM.Equation(_v("band$i"),
            _ut_fn("interp.linear", _ut_const(_ut_table(i)), _ut_const(_ut_axis()),
                   _v("sza"))))
    end
    for j in 1:M
        vars["x$j"] = ModelVariable(UnknownVariable; default=1.0 + 0.25j)
        terms = ESM.ASTExpr[_op("*", _n(0.1 + 0.05i + 0.02j),
                                _op("*", _v("band$i"), _v("met"))) for i in 1:K]
        prod = length(terms) == 1 ? terms[1] : OpExpr("+", terms)
        push!(eqs, ESM.Equation(_D("x$j"),
            _op("-", prod,
                _op("*", _n(0.3 + 0.1j), _op("*", _v("met"), _v("x$j"))))))
    end
    return ESM.Model(vars, eqs)
end

# ---------------------------------------------------------------------------
# Fixture 3 — repo documents. `EarthSciAST._build_evaluator(::EsmFile)` drops the diagnostics,
# and this file needs them (a fixture whose prelude turned out EMPTY would pass
# every assertion below while exercising nothing), so it goes through the same
# model/index-set/template plumbing that method does.
# ---------------------------------------------------------------------------
_ut_file(rel) = ESM.load_path(joinpath(TESTUTILS_REPO_ROOT, "tests", "valid", rel))
_ut_doc_build(file, name; kw...) = ESM._build_evaluator_impl(
    ESM._select_model(file, name);
    index_sets=file.index_sets,
    _template_reg=ESM._component_template_reg(file, name),
    _model_name=String(name), kw...)

@testset "compiler=:interpreter ≡ the tiered prelude" begin

    # ----------------------------------------------------------------
    # (1) The switch does what it says: no slot is left in a skippable tier,
    # and the dynamic vector is the WHOLE prelude. Checked on both hand-built
    # fixtures, because the const tier and the time tier are routed separately.
    # ----------------------------------------------------------------
    @testset "every prelude slot is classified dynamic" begin
        _f, _u, _p, _ts, _vm, dt = _ut_tiered(_ut_arrhenius)
        _fu, _u2, _p2, _ts2, _vm2, du = _ut_untiered(_ut_arrhenius)
        @test dt.n_const_slots == 5 && dt.n_dynamic_slots == 0
        @test du.n_const_slots == 0 && du.n_time_slots == 0
        @test du.n_dynamic_slots == dt.n_const_slots + dt.n_time_slots +
                                    dt.n_dynamic_slots

        K, M = 5, 3
        mk() = _ut_fastjx_model(K, M)
        pa = Dict("F" => [6.0])
        _g, _, _, _, _, gt = _ut_tiered(mk; param_arrays=pa)
        _gu, _, _, _, _, gu = _ut_untiered(mk; param_arrays=pa)
        @test gt.n_time_slots > 0
        @test gu.n_const_slots == 0 && gu.n_time_slots == 0
        @test gu.n_dynamic_slots == gt.n_const_slots + gt.n_time_slots +
                                    gt.n_dynamic_slots
        # The prelude itself is unchanged — the switch routes, it does not rewrite.
        @test gu.n_cse_slots == gt.n_cse_slots
        @test gu.n_obs_slots == gt.n_obs_slots
    end

    # ----------------------------------------------------------------
    # (2) CONST tier. `f!(tiered)` ≡ `f!(untiered)` across a parameter change, a
    # parameter change BACK (the stamp must not confuse "same values, different
    # object"), and repeated calls.
    # ----------------------------------------------------------------
    @testset "const tier: tiered ≡ untiered (Arrhenius)" begin
        fi, u0, p, _ts, _vm, _di = _ut_tiered(_ut_arrhenius)
        fu, _u2, _p2, _ts2, _vm2, _du = _ut_untiered(_ut_arrhenius)

        p2 = merge(p, (; A = 7.0 * p.A, R = 8.0))
        seq = [(u0, p, 0.0), (u0, p, 0.0), (u0, p2, 0.0), ([0.4, -1.3], p, 0.0),
               (u0, p, 0.5), (u0, p2, 0.5), (u0, p, 0.5), ([2.0, 2.0], p2, 0.0),
               (u0, p, 0.0)]
        for (u, pp, t) in seq
            a = _ut_call(fu, u, pp, t)
            @test _ut_same(_ut_call(fi, u, pp, t), a)
        end
    end

    # ----------------------------------------------------------------
    # (3) TIME tier, over a live forcing buffer shared by all three builds.
    # The sequence walks every trigger the t-stamp arbitrates: a repeat (the
    # skip), a finite-difference column at the SAME t, a new t, a `p` change,
    # an in-place buffer refresh announced through `notify_forcing_refresh!`,
    # and a revisited t (the rejected-step shape).
    # ----------------------------------------------------------------
    @testset "time tier: tiered ≡ untiered (forcing buffer)" begin
        K, M = 5, 3
        buf = [6.0]
        mk() = _ut_fastjx_model(K, M)
        pa() = Dict("F" => buf)
        fi, u0, p, _ts, _vm, di = _ut_tiered(mk; param_arrays=pa())
        fu, _u2, _p2, _ts2, _vm2, _du = _ut_untiered(mk; param_arrays=pa())
        @test di.n_time_slots > 0

        p2 = merge(p, (; w = 0.9, scale = 2.25))
        up = copy(u0); up[1] += 1e-6
        seq = Any[]
        push!(seq, (u0, p, 0.0)); push!(seq, (u0, p, 0.0))      # skip
        push!(seq, (up, p, 0.0))                                # FD column, same t
        push!(seq, (u0, p, 0.125)); push!(seq, (u0, p, 0.125))  # new t + skip
        push!(seq, (u0, p2, 0.125))                             # p change
        push!(seq, (u0, p, 0.125))                              # p back
        push!(seq, (:refresh, 42.5, nothing))                   # in-place refresh
        push!(seq, (u0, p, 0.125))                              # same t, new F
        push!(seq, (u0, p, 0.0))                                # revisited t
        push!(seq, (up, p2, 0.125))
        for step in seq
            if step[1] === :refresh
                buf[1] = step[2]
                ESM.notify_forcing_refresh!()
                continue
            end
            u, pp, t = step
            a = _ut_call(fu, u, pp, t)
            @test _ut_same(_ut_call(fi, u, pp, t), a)
        end
    end

    # ----------------------------------------------------------------
    # (4) Repo documents with observed chains. The `p` arm is per fixture: the
    # geometry model declares no parameters at all, which is its own shape.
    # ----------------------------------------------------------------
    @testset "tests/valid fixtures: tiered ≡ untiered" begin
        cases = (
            # (file, model, a second `p` builder or `nothing`)
            ("units_moves_registry.esm", "UnitsMovesRegistry",
             p -> merge(p, (; link_avg_speed = 55.0, engine_power = 210.0))),
            ("units_propagation.esm", "UnitPropagationModel",
             p -> merge(p, (; temperature = 310.0, pressure = 90000.0))),
            ("geometry/polygon_intersection_area_planar.esm",
             "PolygonIntersectionAreaPlanar", nothing),
        )
        for (rel, name, bump) in cases
            @testset "$rel" begin
                file = _ut_file(rel)
                fi, u0, p, _ts, _vm, di = _ut_doc_build(file, name)
                fu, _u2, _p2, _ts2, _vm2, du =
                    _ut_doc_build(file, name; compiler=:interpreter)

                # The fixture must actually HAVE a prelude, or this proves nothing.
                nslots = di.n_const_slots + di.n_time_slots + di.n_dynamic_slots
                @test nslots > 0
                @test du.n_dynamic_slots == nslots
                @test du.n_const_slots == 0 && du.n_time_slots == 0

                ps = bump === nothing ? (p,) : (p, bump(p), p)
                u1 = u0 .+ 0.5
                for pp in ps, u in (u0, u1, u0), t in (0.0, 0.0, 0.75, 0.0)
                    a = _ut_call(fu, u, pp, t)
                    @test _ut_same(_ut_call(fi, u, pp, t), a)
                end
            end
        end
    end
end
