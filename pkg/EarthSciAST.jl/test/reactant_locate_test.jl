# The count-locate seam under a TRACE, without a reduction
# (ext/EarthSciASTReactantExt.jl, `_oop_knot_count`).
#
# WHAT THIS PINS. The locate seam was emitting one `stablehlo.reduce` per interp
# call site — ~32 per ReSEACT chemistry RHS evaluation, ~103 per ROS23 step — and
# locating elementwise instead MEASURES 1.27x faster on the chemistry RHS at
# ReSEACT/CONUS, bit-exact, for +2.7% emitted ops. (An earlier rationale credited
# that to reduces being hard fusion boundaries, priced by a toy at ~6x; that
# model was FALSIFIED — see the `count-locate` header in
# ext/EarthSciASTReactantExt.jl, which records the retraction.) The seam now
# computes the count elementwise in three tiers (LADDER for a small axis, AFFINE
# guess + two-gather correction for a big uniform one, and the old REDUCE as the
# documented fallback), selectable with `ESS_RX_LOCATE` for A/B measurement.
#
# The tiers are an EMISSION choice, so the whole assertion is that they are
# observationally identical:
#
#   1. every tier is BIT-IDENTICAL to the host ladder in tree_walk/oop.jl —
#      `==`, not `isapprox`. That is assertable here where it is not for the
#      interp evaluators as a whole (XLA reassociates the blend) because the
#      count is a sum of exact 0.0/1.0 terms with `n ≪ 2^53`, and the affine
#      tier only ever adds exact small integers to an exact small integer;
#   2. over the queries that actually break a locate: exactly ON each knot, one
#      ULP either side of each knot, below the first, above the last, ±Inf, NaN,
#      and ±0.0. The on-knot case is the load-bearing one — landing one cell low
#      there returns `t_{k-1} + 1·(t_k − t_{k-1})` where the reference returns
#      `t_k`, equal in real arithmetic and not in Float64. The ONE carve-out is
#      a SUBNORMAL query, where XLA:CPU disagrees with the host for reasons that
#      have nothing to do with this seam — see the flush-to-zero testset, which
#      pins the cause and pins that the reduce tier does exactly the same;
#   3. the LADDER and AFFINE tiers emit no `stablehlo.reduce` at all, which is
#      the point of the change;
#   4. both knot SHAPES (one shared axis, and one column per lane) and both
#      query shapes (a lane vector, and a lane-invariant scalar — the `Lq` trap
#      `_rx_knot_matrix` documents) go through every tier.
#
# The affine tier's ±1 fit is verified on the HOST at trace time
# (`_rx_affine_ok`); the testset "the affine fit is a proof obligation" pins
# that verifier against brute force, including that it REFUSES the axes it
# cannot serve.
#
# OPT-IN like the other Reactant files: included only under ESM_TEST_REACTANT=1.

using Test
using EarthSciAST
using Reactant

const ESM = EarthSciAST
const RX = Reactant
const RXE = Base.get_extension(EarthSciAST, :EarthSciASTReactantExt)

# The reference: the host ladder, i.e. `_oop_knot_count`'s generic method.
_lc_ref(knots, q::Float64, cmp) = ESM._oop_knot_count(knots, q, cmp)

# Queries that break locates. Every knot, both ULP neighbours of every knot,
# outside both ends, the infinities, NaN and both zeros.
#
# `_lc_normal` drops the SUBNORMAL ones. An axis with a knot at exactly 0.0 has
# `prevfloat(0.0) = -5e-324` and `nextfloat(0.0) = 5e-324` among its probes, and
# XLA:CPU FLUSHES a subnormal input to zero, so `0.0 ≤ -5e-324` comes back TRUE
# on the device and false on the host. That is a backend rounding mode, not a
# locate: the testset below pins it directly, and pins that the untouched reduce
# tier flushes identically. Every other query is compared bit for bit.
_lc_normal(qs::Vector{Float64}) = filter(q -> !issubnormal(q), qs)
_lc_sub(qs::Vector{Float64}) = filter(issubnormal, qs)

function _lc_queries(ax::Vector{Float64})
    qs = Float64[]
    for x in ax
        push!(qs, prevfloat(x), x, nextfloat(x))
    end
    append!(qs, [ax[1] - 1.0, ax[end] + 1.0, ax[1] - 1e-9, ax[end] + 1e-9,
                 -Inf, Inf, NaN, 0.0, -0.0,
                 0.5 * (ax[1] + ax[end])])
    return qs
end

# Trace `_oop_knot_count` over a lane VECTOR of queries and read the lanes back.
function _lc_traced(knots, qs::Vector{Float64}, cmp)
    f = x -> ESM._oop_knot_count(knots, x, cmp)
    qr = RX.ConcreteRArray(qs)
    return Array((RX.@compile sync = true f(qr))(qr))
end

# The unoptimized module for the same trace, to look for `stablehlo.reduce`.
function _lc_hlo(knots, qs::Vector{Float64}, cmp)
    f = x -> ESM._oop_knot_count(knots, x, cmp)
    qr = RX.ConcreteRArray(qs)
    return repr(RX.@code_hlo optimize = false f(qr))
end

# Run `body` with ESS_RX_LOCATE forced, restoring whatever was there.
function _lc_withmode(mode::String, body)
    old = get(ENV, "ESS_RX_LOCATE", nothing)
    ENV["ESS_RX_LOCATE"] = mode
    try
        body()
    finally
        old === nothing ? delete!(ENV, "ESS_RX_LOCATE") : (ENV["ESS_RX_LOCATE"] = old)
    end
end

# The axes that matter. `flux_x`/`flux_y` are Fast-JX's actinic-flux table axes
# verbatim — the two that were reducing over 61 and 23 knots at every one of the
# 18 bands; `sigma2`/`sigma3` are its cross-section TEMPERATURE axes, the shape
# 180 of its 198 interp call sites actually have (a reduce over two elements).
const _LC_AXES = Dict{String,Vector{Float64}}(
    "flux_x (61, uniform 0.02)" => collect(range(-0.2; step = 0.02, length = 61)),
    "flux_y (23, uniform 4500)" => collect(range(1000.0; step = 4500.0, length = 23)),
    "sigma2 (2 knots)"          => [223.0, 298.0],
    "sigma3 (3, uniform)"       => [218.0, 258.0, 298.0],
    "sigma3 (3, NON-uniform)"   => [190.0, 230.0, 298.0],
    "months (12, integers)"     => collect(1.0:12.0),
    "hours (24, integers)"      => collect(1.0:24.0),
    "big NON-uniform (40)"      => Float64[exp(0.11k) + 0.3sin(k) for k in 1:40],
    "big uniform (40)"          => collect(range(-3.5; step = 0.25, length = 40)),
    "ties (7, with a repeat)"   => [0.0, 1.0, 1.0, 2.0, 3.0, 3.0, 4.0],
)

@testset "traced count-locate emits no reduction and stays bit-exact" begin

    @testset "every tier ≡ the host ladder, bit for bit" begin
        for mode in ("auto", "ladder", "reduce"), (nm, ax) in _LC_AXES,
            cmp in (<=, <)
            # `ladder` on a 61-knot axis is a deliberate stress of the tier, not
            # something `auto` would ever pick.
            qs = _lc_normal(_lc_queries(ax))
            ref = Float64[_lc_ref(ax, q, cmp) for q in qs]
            got = _lc_withmode(mode, () -> _lc_traced(ax, qs, cmp))
            @test got == ref            # `==`, and NaN never reaches the result
        end
    end

    @testset "a subnormal query is XLA:CPU's flush-to-zero, not the seam's" begin
        # The carve-out above, pinned from both ends so it cannot quietly become
        # a cover for a real locate bug.
        #
        # (a) the CAUSE, with no locate involved at all: a bare compare against
        #     0.0 already disagrees with the host on a subnormal input, which is
        #     only possible if the device flushed it to zero.
        f = q -> ifelse.(0.0 .<= q, 1.0, 0.0)
        sub = Float64[prevfloat(0.0), nextfloat(0.0), 0.0]
        qr = RX.ConcreteRArray(sub)
        dev = Array((RX.@compile sync = true f(qr))(qr))
        host = Float64[0.0 <= q ? 1.0 : 0.0 for q in sub]
        @test host == [0.0, 1.0, 1.0]          # -5e-324 < 0 on the host
        @test dev == [1.0, 1.0, 1.0]           # ...and == 0 on the device
        # (b) the CONSEQUENCE is tier-independent: on exactly those queries all
        #     three tiers still agree with EACH OTHER, the reduce tier — which
        #     this change did not touch — included. That is the whole claim the
        #     tiers make; agreeing with the host on a flushed input is not
        #     something any of them can do.
        for (nm, ax) in _LC_AXES, cmp in (<=, <)
            qs = _lc_sub(_lc_queries(ax))
            isempty(qs) && continue
            base = _lc_withmode("reduce", () -> _lc_traced(ax, qs, cmp))
            @test _lc_withmode("ladder", () -> _lc_traced(ax, qs, cmp)) == base
            @test _lc_withmode("auto",   () -> _lc_traced(ax, qs, cmp)) == base
            # ...and the disagreement really is only where the flush bites: the
            # flushed query gets the count of ±0.0.
            @test base == Float64[_lc_ref(ax, 0.0, cmp) for _ in qs]
        end
    end

    @testset "the AFFINE tier is exercised, and is bit-exact" begin
        # `auto` sends anything over ESS_RX_LOCATE_LADDER_MAX (8) to the affine
        # fit, so the big axes above already went through it — but pin it
        # explicitly, with the ladder cut pushed down so even the small axes do.
        old = get(ENV, "ESS_RX_LOCATE_LADDER_MAX", nothing)
        ENV["ESS_RX_LOCATE_LADDER_MAX"] = "1"
        try
            for (nm, ax) in _LC_AXES, cmp in (<=, <)
                RXE._rx_affine_fit(ax, cmp) === nothing && continue
                qs = _lc_normal(_lc_queries(ax))
                ref = Float64[_lc_ref(ax, q, cmp) for q in qs]
                got = _lc_withmode("auto", () -> _lc_traced(ax, qs, cmp))
                @test got == ref
                # ...and it really did take the affine route: a gather, no reduce.
                hlo = _lc_withmode("auto", () -> _lc_hlo(ax, qs, cmp))
                @test !occursin("stablehlo.reduce", hlo)
            end
        finally
            old === nothing ? delete!(ENV, "ESS_RX_LOCATE_LADDER_MAX") :
                (ENV["ESS_RX_LOCATE_LADDER_MAX"] = old)
        end
    end

    @testset "no `stablehlo.reduce` survives for the axes ReSEACT actually has" begin
        # THE REGRESSION. Every Fast-JX / NEI axis must locate without a
        # reduction under the default settings; the reduce tier is reachable
        # only for an axis no tier can serve (kept, and pinned, below).
        for nm in ("flux_x (61, uniform 0.02)", "flux_y (23, uniform 4500)",
                   "sigma2 (2 knots)", "sigma3 (3, uniform)",
                   "sigma3 (3, NON-uniform)", "months (12, integers)",
                   "hours (24, integers)", "big uniform (40)")
            ax = _LC_AXES[nm]
            hlo = _lc_withmode("auto", () -> _lc_hlo(ax, _lc_queries(ax), <=))
            @test !occursin("stablehlo.reduce", hlo)
        end
        # The fallback is still there, still correct, and still the thing an
        # unservable axis gets: a big non-uniform axis.
        ax = _LC_AXES["big NON-uniform (40)"]
        @test RXE._rx_affine_fit(ax, <=) === nothing
        hlo = _lc_withmode("auto", () -> _lc_hlo(ax, _lc_queries(ax), <=))
        @test occursin("stablehlo.reduce", hlo)
        qs = _lc_normal(_lc_queries(ax))
        @test _lc_withmode("auto", () -> _lc_traced(ax, qs, <=)) ==
              Float64[_lc_ref(ax, q, <=) for q in qs]
    end

    @testset "the affine fit is a proof obligation, not a guess" begin
        # `_rx_affine_ok` claims the ONE-SIDED bound `0 ≤ count − guess ≤ 1` for
        # EVERY Float64 query, from a check at 3n probe points. Brute-force the
        # claim on a dense sweep (which the monotone-sandwich argument says is
        # redundant — that is exactly what is being checked). One-sidedness, not
        # just |·| ≤ 1, is what lets the correction be a single gather.
        for (nm, ax) in _LC_AXES, cmp in (<=, <)
            fit = RXE._rx_affine_fit(ax, cmp)
            fit === nothing && continue
            a, b = fit
            n = length(ax)
            lo, hi = ax[1] - 2.5, ax[end] + 2.5
            for j in 0:4000
                q = lo + (hi - lo) * j / 4000
                g = RXE._rx_affine_guess(a, b, n, q)
                c = Float64(count(x -> cmp(x, q), ax))
                @test 0.0 <= c - g <= 1.0
            end
        end

        # It must REFUSE what it cannot serve. A reversed axis breaks the
        # correction identity's prefix-monotone predicate even though its
        # spacing is perfectly uniform, so sortedness is checked, not assumed.
        @test RXE._rx_affine_fit(collect(10.0:-1.0:1.0), <=) === nothing
        @test RXE._rx_affine_fit([0.0, 5.0, 1.0, 6.0, 2.0, 7.0], <=) === nothing
        @test RXE._rx_affine_fit(Float64[exp(k) for k in 1:20], <=) === nothing
        @test RXE._rx_affine_fit([0.0, NaN, 2.0, 3.0], <=) === nothing
        @test RXE._rx_affine_fit([0.0, 1.0, 2.0, Inf], <=) === nothing
        @test RXE._rx_affine_fit(Float64[1.0], <=) === nothing
        # ...and accept the ones it must, on the real Fast-JX axes.
        @test RXE._rx_affine_fit(_LC_AXES["flux_x (61, uniform 0.02)"], <=) !== nothing
        @test RXE._rx_affine_fit(_LC_AXES["flux_y (23, uniform 4500)"], <=) !== nothing
    end

    @testset "the guess really is wrong on knots — the correction is load-bearing" begin
        # If `floor(q·a + b)` already equalled the count the correction gather
        # would be dead weight, and this test would be pinning nothing. It does
        # not: on the Fast-JX flux axis the guess is short by one at every knot,
        # which is exactly the state the one-sided bound is chosen to guarantee
        # and the gathered compare is there to repair.
        ax = _LC_AXES["flux_x (61, uniform 0.02)"]
        a, b = RXE._rx_affine_fit(ax, <=)
        off = count(k -> RXE._rx_affine_guess(a, b, length(ax), ax[k]) != Float64(k),
                    eachindex(ax))
        @test off > 0
    end

    @testset "both knot shapes and both query shapes, through every tier" begin
        # Lane-tabled knots (`Vector{Vector{Float64}}`, one column per lane) —
        # the kernel-class merge's shape. Two lane groups so the D>1 path with
        # its gid map is traced, plus the all-equal case that dedups to D == 1.
        L = 6
        for (label, cols) in (
                "D == 1 (one shared axis)" =>
                    [fill(x, L) for x in _LC_AXES["flux_y (23, uniform 4500)"]],
                "D == 2 (two lane axes)" =>
                    [Float64[l <= 3 ? x : x + 0.5 for l in 1:L]
                     for x in _LC_AXES["big uniform (40)"]],
                "D == 2, small (ladder)" =>
                    [Float64[l <= 3 ? x : 2x for l in 1:L]
                     for x in _LC_AXES["sigma3 (3, uniform)"]])
            for mode in ("auto", "ladder", "reduce"), cmp in (<=, <)
                # (a) a lane VECTOR query.
                qs = Float64[(-1.0)^l * 1000l + 220.0 for l in 1:L]
                ref = ESM._oop_knot_count(cols, qs, cmp)
                got = _lc_withmode(mode, () -> _lc_traced(cols, qs, cmp))
                @test got == ref
                # (b) a lane-INVARIANT scalar query still yields L lanes — the
                # `Lq` trap: the result's lane axis comes from the KNOTS here.
                gs = _lc_withmode(mode, () -> begin
                    f = x -> ESM._oop_knot_count(cols, x, cmp)
                    qr = RX.ConcreteRNumber(2200.0)
                    Array((RX.@compile sync = true f(qr))(qr))
                end)
                @test length(gs) == L
                @test gs == ESM._oop_knot_count(cols, 2200.0, cmp)
            end
        end
    end

    @testset "the interp evaluators agree with the scalar cores on the edges" begin
        # End to end, through the seam: the three lane evaluators against the
        # `_interp_*_core` kernels the in-place path calls, on the same edge
        # queries. The blend is XLA-reassociable, so a few ULP is the honest
        # tolerance for the VALUE — but a locate that is off by one cell is not
        # a few ULP, it is a different table entry, which this catches.
        ax = _LC_AXES["flux_x (61, uniform 0.02)"]
        tbl = Float64[sinpi(0.7x) + 2x for x in ax]
        h = ESM._InterpLinearSpec(tbl, copy(ax))
        qs = _lc_normal(_lc_queries(ax))
        ref = Float64[ESM._interp_linear_core(tbl, ax, q) for q in qs]
        got = _lc_withmode("auto", () -> begin
            f = x -> ESM._oop_interp_linear_lanes(h, x, RX.TracedRNumber{Float64})
            qr = RX.ConcreteRArray(qs)
            Array((RX.@compile sync = true f(qr))(qr))
        end)
        for (g, r) in zip(got, ref)
            @test (isnan(g) && isnan(r)) || isapprox(g, r; rtol = 1e-14, atol = 0.0)
        end
        # ON a knot the answer is the table entry EXACTLY (no blend runs), which
        # is the case a wrong locate silently turns into `t_{k-1} + 1·Δ`.
        onknot = _lc_withmode("auto", () -> begin
            f = x -> ESM._oop_interp_linear_lanes(h, x, RX.TracedRNumber{Float64})
            qr = RX.ConcreteRArray(copy(ax))
            Array((RX.@compile sync = true f(qr))(qr))
        end)
        @test onknot == tbl

        # searchsorted: an integer-valued result, so `==` is the right assertion.
        xs = _LC_AXES["hours (24, integers)"]
        s = ESM._InterpSearchsortedSpec(copy(xs))
        sq = _lc_normal(_lc_queries(xs))
        sref = Float64[ESM._interp_searchsorted_core("interp.searchsorted", q, xs)
                       for q in sq]
        sgot = _lc_withmode("auto", () -> begin
            f = x -> ESM._oop_interp_searchsorted_lanes(s, x, RX.TracedRNumber{Float64})
            qr = RX.ConcreteRArray(sq)
            Array((RX.@compile sync = true f(qr))(qr))
        end)
        @test sgot == sref
    end
end
