# Registry-declared typed scalar cores for closed functions (ess-dtcore).
#
# `datetime.*` used to reach every evaluator tier through the boxed
# `(fname, nothing)` payload: args in a `Vector{Any}`, dispatched by name
# through `_eval_closed_fn` — the single residual allocation on the lane tape
# (~480 B/call) and one opaque call per lane on the `:oop` lane path. The
# registry now DECLARES a typed scalar core per all-scalar function
# (`_FN_TYPED_SCALAR_CORES`, registered_functions.jl), `_compile_fn_node`
# mints the `(fname, _FnTypedCoreSpec)` payload, and every tier's `Float64`
# path calls the shared `_fn_typed_core_call` ladder.
#
# Pinned here:
#   * the typed call is BIT-IDENTICAL to the boxed registry (its differential
#     oracle — each core is by construction the same composition) and to
#     direct `Dates`-derived values over a boundary-spanning timestamp grid;
#   * a datetime-carrying kernel is bit-identical across the scalar
#     interpreter, the lane tape, the codegen tier and the `:oop` host path;
#   * the tape path through a `datetime.*` spine is ZERO-ALLOCATION (it was
#     ~480 B/call), with the boxed twin kernel as the sensitivity control;
#   * ForwardDiff `Dual` input still takes the pre-change boxed route and
#     matches it exactly (values + partials);
#   * an all-scalar fn WITHOUT a declaration (the `(fname, nothing)` payload)
#     still takes the boxed path on every tier and agrees bit-for-bit.
using Test
using Dates
using ForwardDiff
using EarthSciAST
include("testutils.jl")
const ESM = EarthSciAST

# The nine declared functions and their `Dates` oracles (`dt` is the
# ms-truncated `unix2datetime(t)` — the same truncation the spec pins).
const _DTC_FIELDS = [
    ("datetime.year",         dt -> Dates.year(dt)),
    ("datetime.month",        dt -> Dates.month(dt)),
    ("datetime.day",          dt -> Dates.day(dt)),
    ("datetime.hour",         dt -> Dates.hour(dt)),
    ("datetime.minute",       dt -> Dates.minute(dt)),
    ("datetime.second",       dt -> Dates.second(dt)),
    ("datetime.day_of_year",  dt -> Dates.dayofyear(dt)),
    ("datetime.is_leap_year", dt -> Dates.isleapyear(Dates.year(dt)) ? 1 : 0),
]

# Timestamp grid spanning the boundaries where a calendar bug would live:
# month ends, year ends, Feb 29 (leap), Feb 28→Mar 1 of a NON-leap century
# (2100), the leap century (2000), pre-epoch, and sub-second fractions.
function _dtc_grid()
    ds = [DateTime(1969, 12, 31, 23, 0, 0),   DateTime(1970, 1, 1),
          DateTime(1999, 12, 31, 23, 59, 59), DateTime(2000, 2, 28, 12),
          DateTime(2000, 2, 29),              DateTime(2000, 3, 1),
          DateTime(2015, 12, 31, 23, 59, 30), DateTime(2016, 1, 1, 0, 0, 30),
          DateTime(2016, 2, 28, 23, 59, 59),  DateTime(2016, 2, 29, 11, 30, 15),
          DateTime(2016, 3, 1),               DateTime(2016, 12, 31),
          DateTime(2017, 1, 1),               DateTime(2099, 12, 31, 6, 7, 8),
          DateTime(2100, 2, 28, 23, 0, 0),    DateTime(2100, 3, 1, 1, 2, 3),
          DateTime(2024, 6, 30, 23, 59, 59),  DateTime(2024, 7, 1)]
    ts = Float64[Dates.datetime2unix(d) for d in ds]
    # Sub-second offsets (exact ms, so the Dates oracle sees the same instant).
    append!(ts, ts[1:6] .+ 0.25)
    push!(ts, 1462345200.5)
    return ts
end

@testset "registry-declared typed scalar cores (ess-dtcore)" begin

    # ---- The declaration itself -------------------------------------------
    @testset "declaration coverage" begin
        for (name, _) in _DTC_FIELDS
            sp = ESM._fn_typed_core_spec(name)
            @test sp isa ESM._FnTypedCoreSpec
            @test sp.arity == 1
        end
        @test ESM._fn_typed_core_spec("datetime.julian_day") isa ESM._FnTypedCoreSpec
        # The interp family keeps its own typed protocol (const-arg specs) and
        # must NOT be declared here.
        for name in ("interp.searchsorted", "interp.linear", "interp.bilinear")
            @test ESM._fn_typed_core_spec(name) === nothing
        end
        @test ESM._fn_typed_core_spec("datetime.century") === nothing
    end

    # ---- Typed core ≡ boxed registry ≡ Dates, over the grid ----------------
    @testset "typed core ≡ boxed registry ≡ Dates over boundary grid" begin
        for t in _dtc_grid()
            dt = Dates.unix2datetime(t)
            for (name, oracle) in _DTC_FIELDS
                sp = ESM._fn_typed_core_spec(name)
                typed = ESM._fn_typed_core_call(sp.id, t)
                boxed = convert(Float64, evaluate_closed_function(name, Any[t]))
                @test typed === boxed                      # bit-identity oracle
                @test typed === Float64(oracle(dt))        # Dates oracle
            end
            spj = ESM._fn_typed_core_spec("datetime.julian_day")
            jt = ESM._fn_typed_core_call(spj.id, t)
            jb = evaluate_closed_function("datetime.julian_day", Any[t])::Float64
            @test jt === jb
            # Fliegel–van Flandern vs Dates: the spec pins ≤ 1 ulp on the JDN
            # composition; allow 2 ulps of the (large) result.
            @test abs(jt - Dates.datetime2julian(dt)) <= 2 * eps(jt)
        end
        # The `_cal_i32` overflow/NaN throws are part of the pinned semantics
        # and must survive the typed route.
        spy = ESM._fn_typed_core_spec("datetime.year")
        @test_throws ESM.ClosedFunctionError ESM._fn_typed_core_call(spy.id, 1.0e300)
        @test_throws ESM.ClosedFunctionError ESM._fn_typed_core_call(spy.id, NaN)
        @test_throws ESM.ClosedFunctionError evaluate_closed_function(
            "datetime.year", Any[1.0e300])
    end

    # ---- Payload minting + scalar walker, typed vs boxed (negative control) -
    tnode() = ESM._mknode(kind=ESM._NK_TIME)
    fnnode(name, spec, kids...) = ESM._mknode(kind=ESM._NK_OP, op=:fn,
        children=ESM._Node[kids...], payload=(name, spec))

    @testset "compile mints the typed payload; boxed nodes still evaluate" begin
        for (name, _) in _DTC_FIELDS
            expr = _op("fn", _v("t"); name=name)
            nd = ESM._compile(expr, Dict{String,Int}(), Set{Symbol}(), nothing)
            @test nd.payload isa Tuple{String,ESM._FnTypedCoreSpec}
            @test nd.payload[1] == name
        end
        # interp keeps its own spec family, untouched.
        ssx = _op("fn", _v("t"), _const([0.0, 1.0, 2.0]); name="interp.searchsorted")
        nds = ESM._compile(ssx, Dict{String,Int}(), Set{Symbol}(), nothing)
        @test nds.payload isa Tuple{String,ESM._InterpSearchsortedSpec}

        # NEGATIVE CONTROL: a hand-built `(name, nothing)` node — what an
        # UNDECLARED all-scalar closed fn compiles to — takes the boxed arm
        # and agrees bit-for-bit with the typed node, in both the scalar
        # walker (`_eval_node`) and the access evaluator (`_eval_acc`).
        K0 = ESM._AccKernel(ESM._contig_cells(1), ESM._alit(0.0), ESM._AccDesc[],
                            ESM._FixedBound(0), 0.0)
        for t in (1462345200.0, Dates.datetime2unix(DateTime(2016, 2, 29, 23, 59, 59)))
            for (name, _) in _DTC_FIELDS
                typednd = fnnode(name, ESM._fn_typed_core_spec(name), tnode())
                boxednd = fnnode(name, nothing, tnode())
                vt = ESM._eval_node(typednd, Float64[], (;), t, Float64)
                vb = ESM._eval_node(boxednd, Float64[], (;), t, Float64)
                @test Float64(vt) === Float64(vb)
                at = ESM._eval_acc(typednd, Float64[], (;), t, 1, 0, 1, (1, 1, 1),
                                   K0, Float64)
                ab = ESM._eval_acc(boxednd, Float64[], (;), t, 1, 0, 1, (1, 1, 1),
                                   K0, Float64)
                @test Float64(at) === Float64(ab)
                @test Float64(at) === Float64(vt)
            end
        end
    end

    # ---- Lane tape: typed opcode, bit-identity, ZERO allocation -------------
    @testset "lane tape: _TC_FN_TYPED, bit-identical, zero-alloc" begin
        N = 48
        u = Float64[(-1.0)^k * (0.05 + 0.03k) for k in 1:N]
        tval = Dates.datetime2unix(DateTime(2016, 2, 29, 12))   # leap noon
        cells = ESM._CellSet([1], UnitRange{Int}[1:N], 0)
        mkK(spine) = ESM._AccKernel(cells, spine,
            ESM._AccDesc[ESM._AccStateAffine(0)], ESM._FixedBound(0), 0.0)
        # Lane-varying arg (t + u[i]·3600) through day_of_year, plus the
        # lane-invariant julian_day(t) — one spine exercising both the
        # per-lane loop and the invariant one-call broadcast.
        spine(spec_of) = ESM._aop(:+,
            fnnode("datetime.day_of_year", spec_of("datetime.day_of_year"),
                   ESM._aop(:+, tnode(),
                            ESM._aop(:*, ESM._acc(1), ESM._alit(3600.0)))),
            fnnode("datetime.julian_day", spec_of("datetime.julian_day"), tnode()))

        Kt = mkK(spine(name -> ESM._fn_typed_core_spec(name)))
        Kb = mkK(spine(name -> nothing))
        Pt = ESM._build_acc_plan(Kt; tile=16)
        Pb = ESM._build_acc_plan(Kb; tile=16)
        @test Pt !== nothing && Pb !== nothing
        @test any(ins -> ins.code === ESM._TC_FN_TYPED, Pt.instrs)
        @test !any(ins -> ins.code === ESM._TC_FN, Pt.instrs)
        @test any(ins -> ins.code === ESM._TC_FN, Pb.instrs)   # boxed control

        ref = zeros(N); ESM._run_acc_kernel!(ref, u, nothing, tval, Kt)
        refb = zeros(N); ESM._run_acc_kernel!(refb, u, nothing, tval, Kb)
        tape = zeros(N); ESM._run_acc_plan!(tape, u, nothing, tval, Kt, Pt)
        tapeb = zeros(N); ESM._run_acc_plan!(tapeb, u, nothing, tval, Kb, Pb)
        @test tape == ref                       # typed tape ≡ scalar walk
        @test tape == refb == tapeb             # …≡ the boxed route, both tiers

        # THE allocation pin: warm up, then the typed plan run must allocate
        # NOTHING; the boxed twin is the sensitivity control proving the
        # measurement can see the old per-lane box at all.
        a_typed = @allocated ESM._run_acc_plan!(tape, u, nothing, tval, Kt, Pt)
        a_boxed = @allocated ESM._run_acc_plan!(tapeb, u, nothing, tval, Kb, Pb)
        @test a_typed == 0
        @test a_boxed > 0
    end

    # ---- End-to-end: one model, four tiers, bit-identical -------------------
    # D(u[i]) = doy(t + u[i]·3600) + julian_day(t)·1e-3 — a lane-varying
    # datetime arg on the spine plus a hoistable invariant one.
    function _dtc_model(N)
        vars = Dict("u" => ESM.ModelVariable(ESM.StateVariable))
        targ = _op("+", _v("t"), _op("*", _idx("u", _v("i")), _n(3600.0)))
        body = _op("+",
            _op("fn", targ; name="datetime.day_of_year"),
            _op("*", _op("fn", _v("t"); name="datetime.julian_day"), _n(1.0e-3)))
        ESM.Model(vars, [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                                      _ao1(body, "i", 1, N))])
    end

    @testset "kernel bit-identity: interpreter ≡ tape ≡ codegen ≡ :oop" begin
        N = 24
        ics = Dict("u[$k]" => 0.2 + 0.15k for k in 1:N)
        build(; form=:inplace, env...) =
            withenv((String(k) => v for (k, v) in pairs(env))...) do
            ESM._reset_cascade_tally!()
            f, u0, p, _t, _vm, _d = ESM._build_evaluator_impl(_dtc_model(N);
                initial_conditions=ics, form=form)
            (f, u0, p, copy(ESM._CASCADE_TALLY))
        end
        fref, u0, pref, _ = build(; ESS_STENCIL_DISABLE="1", ESS_CODEGEN_DISABLE="1")
        ftape, _, ptape, _ = build(; ESS_CODEGEN_DISABLE="1")
        fcg, _, pcg, cgtally = build()
        foop, _, poop, _ = build(; form=:oop)
        @test get(cgtally, :codegen_kernel, 0) >= 1   # codegen really fired

        run!(f!, u, p, t) = (d = zeros(length(u)); f!(d, u, p, t); d)
        ts = [Dates.datetime2unix(DateTime(2015, 12, 31, 23, 59, 30)),
              Dates.datetime2unix(DateTime(2016, 2, 29, 11, 30, 15)),
              Dates.datetime2unix(DateTime(2100, 2, 28, 23, 30, 0)) + 0.25]
        for t in ts, k in 1:3
            u = k == 1 ? copy(u0) :
                Float64[0.4 + 0.9 * sin(1.3i + 0.7k) for i in 1:N]
            dref = run!(fref, u, pref, t)
            @test all(run!(ftape, u, ptape, t) .=== dref)
            @test all(run!(fcg, u, pcg, t) .=== dref)
            @test all(foop(u, poop, t) .=== dref)
            # Dates-derived expected values, composed in the spine's own
            # order (`convert(Float64, doy) + jd*1e-3`), so the comparison is
            # exact for the field term and ≤ ulps for the julian_day product.
            for i in 1:N
                doy = Float64(Dates.dayofyear(Dates.unix2datetime(t + u[i] * 3600.0)))
                jd = evaluate_closed_function("datetime.julian_day", Any[t])::Float64
                expct = doy + jd * 1.0e-3
                @test dref[i] === expct
            end
        end

        # The end-to-end RHS is now allocation-free through the datetime spine
        # on BOTH compiled tiers (tape was ~480 B/call before ess-dtcore).
        du = zeros(N); t0 = ts[1]
        ftape(du, u0, ptape, t0); fcg(du, u0, pcg, t0)   # warmup
        @test (@allocated ftape(du, u0, ptape, t0)) == 0
        @test (@allocated fcg(du, u0, pcg, t0)) == 0
    end

    # ---- ForwardDiff: Duals keep the pre-change boxed route -----------------
    @testset "Dual input: typed payload falls back to the boxed route" begin
        t0 = Dates.datetime2unix(DateTime(2016, 2, 29, 11, 30, 15))
        d0 = ForwardDiff.Dual{Nothing}(t0, 1.0)
        TD = typeof(d0)
        for name in (first.(_DTC_FIELDS)..., "datetime.julian_day")
            typednd = fnnode(name, ESM._fn_typed_core_spec(name), tnode())
            boxednd = fnnode(name, nothing, tnode())
            vt = ESM._eval_node(typednd, TD[], (;), d0, TD)
            vb = ESM._eval_node(boxednd, TD[], (;), d0, TD)
            # The typed payload's non-Float64 branch IS the boxed call, so
            # value and partials match exactly.
            @test ForwardDiff.value(vt) === ForwardDiff.value(vb)
            @test ForwardDiff.partials(vt) === ForwardDiff.partials(vb)
            # …and against the pre-change registry route directly.
            ad = evaluate_closed_function_ad(name, Any[d0])
            @test ForwardDiff.value(vt) === Float64(ForwardDiff.value(ad))
            if name == "datetime.julian_day"
                @test ForwardDiff.partials(vt, 1) === 1.0 / 86400.0  # ∂jd/∂t
            else
                @test ForwardDiff.partials(vt, 1) === 0.0            # discrete
            end
        end

        # End-to-end: Jacobian over the state, codegen (which folds its own
        # `_cgT === Float64` branch) vs the scalar reference, bit-identical.
        N = 8
        ics = Dict("u[$k]" => 0.2 + 0.15k for k in 1:N)
        fref, u0, pref, _t1, _v1, _d1 = withenv("ESS_STENCIL_DISABLE" => "1",
                                                "ESS_CODEGEN_DISABLE" => "1") do
            ESM._build_evaluator_impl(_dtc_model(N); initial_conditions=ics)
        end
        fcg, v0, pcg, _t2, _v2, _d2 =
            ESM._build_evaluator_impl(_dtc_model(N); initial_conditions=ics)
        du!(f!, u, p, t) = (d = zeros(eltype(u), length(u)); f!(d, u, p, t); d)
        Jr = ForwardDiff.jacobian(uu -> du!(fref, uu, pref, t0), u0)
        Jc = ForwardDiff.jacobian(uu -> du!(fcg, uu, pcg, t0), v0)
        @test all(Jr .=== Jc)
    end
end
