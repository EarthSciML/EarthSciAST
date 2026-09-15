# The branch-free `interp.*` lane evaluators (src/tree_walk/interp_lanes.jl).
#
# A compiled backend cannot branch on a query value, so the `interp.*` closed
# functions lower as locate → gather → blend over a whole lane at once: count how
# many knots the query passes, gather the bracketing pair, blend, and select the
# clamp arms with `ifelse` rather than an early return. That program has to agree
# with the branchy scalar `_interp_*_core` kernels (registered_functions.jl) that
# `f!` and the scalar walk call — bit for bit, not approximately, because the two
# are the same function evaluated by different tiers of the same build.
#
# So this file is a differential test against those cores, over query sweeps that
# hit every arm the cores branch on: in range, ON a knot, below the table, above
# the table, and NaN. `isequal`, so NaN pins as NaN.
#
# Both spec families are covered. `_Interp*Spec` is one table shared by every
# lane; `_Interp*LaneSpec` is the kernel-class merge's per-lane table columns,
# where lane `l` must reproduce its own MEMBER's original spec — the identity the
# merge is defined by. (The lane-spec forms' constant-folding is pinned
# separately in test/lane_table_intern_test.jl, and their emitted StableHLO in
# test/reactant_locate_test.jl under ESM_TEST_REACTANT=1.)
using Test
include("testutils.jl")

using EarthSciAST
const _IL_ESS = EarthSciAST

# A dense sweep plus the exact boundary values a sweep steps over.
const _IL_Q = vcat(collect(-1.0:0.037:5.0),
                   [0.0, 1.0, 2.0, 3.0, 4.0, -0.0, NaN])

_il_same(got, want) = length(got) == length(want) &&
                      all(isequal(a, b) for (a, b) in zip(got, want))

@testset "branch-free interp.* lanes ≡ the scalar cores" begin

    @testset "interp.linear, one shared table" begin
        h = _IL_ESS._InterpLinearSpec([10.0, 20.0, 40.0, 80.0, 160.0],
                                      [0.0, 1.0, 2.0, 3.0, 4.0])
        @test _il_same(_IL_ESS._interp_linear_lanes(h, _IL_Q),
                       [_IL_ESS._interp_linear_core(h.table, h.axis, q) for q in _IL_Q])
        # A lane-INVARIANT scalar query broadcasts to a scalar, and is the core's
        # answer for that one query.
        @test _IL_ESS._interp_linear_lanes(h, 2.25) ===
              _IL_ESS._interp_linear_core(h.table, h.axis, 2.25)
    end

    @testset "interp.searchsorted, one shared table (duplicate knot)" begin
        # A duplicate knot is the case where "first index ≥ x" and "count of
        # strictly-less + 1" could disagree if the count used the wrong compare.
        h = _IL_ESS._InterpSearchsortedSpec([1.0, 2.0, 2.0, 3.0, 4.0])
        @test _il_same(_IL_ESS._interp_searchsorted_lanes(h, _IL_Q),
                       [Float64(_IL_ESS._interp_searchsorted_core(
                            "interp.searchsorted", q, h.xs)) for q in _IL_Q])
        # The empty table is the core's own documented rule (answer 1).
        e = _IL_ESS._InterpSearchsortedSpec(Float64[])
        @test all(_IL_ESS._interp_searchsorted_lanes(e, _IL_Q) .== 1.0)
    end

    @testset "interp.bilinear, one shared table" begin
        h = _IL_ESS._InterpBilinearSpec(
            [[1.0, 1.5, 2.0], [1.1, 1.6, 2.1], [1.2, 1.7, 2.2]],
            [0.0, 1.0, 2.0], [0.0, 1.0, 2.0])
        xs = vcat(collect(-0.5:0.13:2.5), [0.0, 1.0, 2.0, NaN, 0.7])
        ys = reverse(vcat(collect(-0.5:0.13:2.5), [1.0, NaN, 0.0, 2.0, 1.3]))
        @test _il_same(_IL_ESS._interp_bilinear_lanes(h, xs, ys),
                       [_IL_ESS._interp_bilinear_core(h.table, h.axis_x, h.axis_y, x, y)
                        for (x, y) in zip(xs, ys)])
        # One axis lane-varying, the other invariant — the shape a kernel whose
        # second query hoisted out of the cell loop lowers to.
        @test _il_same(_IL_ESS._interp_bilinear_lanes(h, xs, 1.25),
                       [_IL_ESS._interp_bilinear_core(h.table, h.axis_x, h.axis_y,
                                                      x, 1.25) for x in xs])
    end

    # ---- the per-lane spec forms: lane `l` ≡ member `l`'s own core -----------

    @testset "interp.linear, per-lane table columns" begin
        a = _IL_ESS._InterpLinearSpec([10.0, 20.0, 40.0, 80.0, 160.0],
                                      [0.0, 1.0, 2.0, 3.0, 4.0])
        b = _IL_ESS._InterpLinearSpec([-1.0, 0.0, 3.0, 5.0, 11.0],
                                      [0.5, 1.0, 2.0, 3.0, 3.5])
        h = _IL_ESS._InterpLinearLaneSpec(
            _IL_ESS._InterpLinearSpec[isodd(l) ? a : b for l in 1:8], 1, 0, 0, 1)
        qs = Float64[-2.0, 0.0, 0.75, 2.0, 3.0, 3.5, 9.0, NaN]
        @test _il_same(_IL_ESS._interp_linear_lanes(h, qs),
                       [_IL_ESS._interp_linear_core(h.specs[l].table, h.specs[l].axis,
                                                    qs[l]) for l in 1:8])
    end

    @testset "interp.searchsorted, per-lane table columns" begin
        a = _IL_ESS._InterpSearchsortedSpec([1.0, 2.0, 3.0, 4.0])
        b = _IL_ESS._InterpSearchsortedSpec([0.5, 0.5, 2.5, 6.0])
        h = _IL_ESS._InterpSearchsortedLaneSpec(
            _IL_ESS._InterpSearchsortedSpec[isodd(l) ? a : b for l in 1:6], 1, 0, 0, 1)
        qs = Float64[-1.0, 0.5, 2.5, 4.0, 7.0, NaN]
        @test _il_same(_IL_ESS._interp_searchsorted_lanes(h, qs),
                       [Float64(_IL_ESS._interp_searchsorted_core(
                            "interp.searchsorted", qs[l], h.specs[l].xs)) for l in 1:6])
    end

    @testset "interp.bilinear, per-lane table columns" begin
        band(v) = _IL_ESS._InterpBilinearSpec(
            [Float64[v + 0.01j + 0.1i for j in 0:2] for i in 0:2],
            [0.0, 1.0, 2.0], [0.0, 1.0, 2.0])
        h = _IL_ESS._InterpBilinearLaneSpec(
            _IL_ESS._InterpBilinearSpec[band(Float64(1 + (l - 1) ÷ 3)) for l in 1:9],
            1, 0, 0, 1)
        xs = Float64[-0.7, 0.0, 0.31, 1.0, 1.62, 2.0, 2.9, NaN, 0.5]
        ys = Float64[2.6, 2.0, 1.75, 1.0, 0.42, 0.0, -0.3, 0.25, NaN]
        @test _il_same(_IL_ESS._interp_bilinear_lanes(h, xs, ys),
                       [_IL_ESS._interp_bilinear_core(
                            h.specs[l].table, h.specs[l].axis_x, h.specs[l].axis_y,
                            xs[l], ys[l]) for l in 1:9])
        # A lane-invariant query on one axis still owes one value PER LANE: the
        # tables differ, so a collapsed bound must not collapse the lane axis.
        g = _IL_ESS._interp_bilinear_lanes(h, xs, 1.25)
        @test _il_same(g, [_IL_ESS._interp_bilinear_core(
                               h.specs[l].table, h.specs[l].axis_x, h.specs[l].axis_y,
                               xs[l], 1.25) for l in 1:9])
    end
end
