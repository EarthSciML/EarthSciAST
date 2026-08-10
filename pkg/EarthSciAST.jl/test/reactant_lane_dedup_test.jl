# Lane dedup in the traced interp seams (ext/EarthSciASTReactantExt.jl).
#
# THE DEFECT THIS PINS. The kernel-class merge tables one spec PER LANE, and a
# lane is (cell × member). Merging an N-member group over a grid therefore
# yields `L = N · ncells` lanes — but the members' tables do not vary with the
# cell, so there are only N DISTINCT tables and `ncells` copies of each. The
# traced seams used to flatten all L copies into the emitted XLA constant, which
# made the CONSTANT SCALE WITH THE GRID. Fast-JX's 18 actinic-flux bands over a
# 13×7×72 domain reached 117,936 lanes × 61 × 23 doubles = 1.32 GB and Reactant
# refused to emit it (100 MB threshold). At 7×7×8 the same table came to 75.5 MB
# and compiled, so the failure only appeared at scale.
#
# WHAT IS ASSERTED, in three independent layers:
#   1. the grouping itself (host, `_rx_lane_groups`) — including that it splits
#      on BITWISE difference, so `-0.0`/`0.0` stay apart and `NaN`s unify;
#   2. the numbers out of the traced seam, against the per-lane HOST oracle
#      (`T<:Real` dispatch calls each member's ORIGINAL spec — the very identity
#      the merge is defined by);
#   3. the emitted HLO, where the claim is not "smaller" but GRID-INDEPENDENT:
#      the largest f64 constant must be identical at two lane multiplicities.
#
# Layer 3 is the one that would have caught the original defect; layers 1-2 are
# what stop a dedup from silently mixing lanes up.

using Test
using EarthSciAST
using Reactant

const ESM = EarthSciAST
const RX = Reactant

# One 3×3 bilinear table per "band", reused across every "cell".
_band_tbl(b) = [[b + 0.01j + 0.1i for j in 0:2] for i in 0:2]
const _AX = [0.0, 1.0, 2.0]

# `nbands` distinct tables, each repeated over `ncells` lanes — the reseact
# shape. Lane order is cell-major within band, which is what the merge mints.
function _lane_spec(nbands::Int, ncells::Int)
    specs = ESM._InterpBilinearSpec[]
    for b in 1:nbands, _ in 1:ncells
        push!(specs, ESM._InterpBilinearSpec(_band_tbl(Float64(b)), copy(_AX), copy(_AX)))
    end
    return ESM._InterpBilinearLaneSpec(specs, 1, 0, 0, 1)
end

# Every 1-D f64 tensor width in the compiled module, in elements. `Ops.constant`
# emits `dense<...> : tensor<Nxf64>`.
function _f64_widths(hlo::String)
    return Set(parse(Int, m.captures[1]) for m in eachmatch(r"tensor<(\d+)xf64>", hlo))
end

@testset "traced interp lane dedup (grid-independent constants)" begin

    @testset "_rx_lane_groups keys lanes bitwise" begin
        RXE = Base.get_extension(EarthSciAST, :EarthSciASTReactantExt)
        @test RXE !== nothing

        # 3 distinct columns repeated over 4 lanes each.
        cols = [Float64[c for c in (1.0, 1.0, 1.0, 1.0, 2.0, 2.0, 2.0, 2.0,
                                    3.0, 3.0, 3.0, 3.0)],
                Float64[10c for c in (1.0, 1.0, 1.0, 1.0, 2.0, 2.0, 2.0, 2.0,
                                      3.0, 3.0, 3.0, 3.0)]]
        reps, gid = RXE._rx_lane_groups(cols)
        @test length(reps) == 3
        @test gid == Int64[1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3]
        # A representative really does carry its group's values.
        for l in eachindex(gid), (q, c) in enumerate(cols)
            @test c[l] === cols[q][reps[gid[l]]]
        end

        # All lanes distinct → the degenerate identity map, i.e. exactly the
        # pre-dedup layout. This is the "no regression when nothing repeats" arm.
        d = [Float64[1.0, 2.0, 3.0]]
        reps_d, gid_d = RXE._rx_lane_groups(d)
        @test reps_d == [1, 2, 3]
        @test gid_d == Int64[1, 2, 3]

        # Bitwise, not `==`: -0.0 must NOT merge with 0.0 (they are `==`), and
        # NaN must merge with NaN (it is not `==` itself). Getting this wrong
        # would swap a signed zero into a neighbouring lane's table.
        z = [Float64[0.0, -0.0, 0.0]]
        @test length(RXE._rx_lane_groups(z)[1]) == 2
        @test RXE._rx_lane_groups(z)[2] == Int64[1, 2, 1]
        nn = [Float64[NaN, NaN]]
        @test length(RXE._rx_lane_groups(nn)[1]) == 1
    end

    @testset "traced lanes ≡ the per-lane host oracle" begin
        h = _lane_spec(4, 5)                   # 4 bands × 5 cells = 20 lanes
        L = length(h.specs)
        # Queries spanning in-range, both clamps, and every knot.
        xs = Float64[-0.4 + 0.13k for k in 0:(L - 1)]
        ys = Float64[2.4 - 0.11k for k in 0:(L - 1)]

        ref = ESM._oop_interp_bilinear_lanes(h, xs, ys, Float64)   # host, per-spec
        f = (x, y) -> ESM._oop_interp_bilinear_lanes(h, x, y, RX.TracedRNumber{Float64})
        xr, yr = RX.ConcreteRArray(xs), RX.ConcreteRArray(ys)
        got = Array((RX.@compile sync = true f(xr, yr))(xr, yr))

        @test length(got) == L
        # The corners are GATHERED (exact); only the blend can be reassociated,
        # so a few ULP is the honest tolerance — cf. reactant_oop_test.jl.
        @test all(isapprox(a, b; rtol = 1e-14) for (a, b) in zip(got, ref))
        # ...and the lanes are not permuted: each band's block must differ.
        @test length(unique(round.(got; digits = 9))) > 1
    end

    @testset "the emitted table constant does not scale with the lane count" begin
        # THE REGRESSION. Same 4 tables at 5 cells and at 40 cells — an 8× lane
        # count over the SAME distinct-table set. The table constant must be
        # `Nx·Ny·D` at both, and `Nx·Ny·L` must appear at neither.
        #
        # Asserted as membership rather than as "the largest constant". The
        # clamp bounds `ax[1]` / `ax[Nx]` used to survive as lane COLUMNS (4
        # L-wide constants per bilinear — 3.8 MB at 13×7×72, against the
        # table's former 1.32 GB); `_oop_lane_bound` (oop.jl, part of the
        # lane-table interning change) now collapses an all-equal boundary
        # column to its one scalar HOST-SIDE, so those constants no longer
        # reach the trace at all in this fixture (every lane shares `_AX`).
        # The RESULT-LENGTH hazard that made this a separate change — a
        # collapsed bound meeting a lane-invariant query, the same trap
        # `_rx_knot_matrix`'s `Lq` guard exists for — is covered by the length
        # pins here (the L-lane testset below) and by the host-side sweeps in
        # test/lane_table_intern_test.jl: the length-L knot columns still flow
        # through every seam, so they carry the lane axis regardless.
        mk(nc) = begin
            h = _lane_spec(4, nc)
            L = length(h.specs)
            xs = Float64[-0.4 + 0.13(k % 17) for k in 0:(L - 1)]
            ys = Float64[2.4 - 0.11(k % 13) for k in 0:(L - 1)]
            f = (x, y) -> ESM._oop_interp_bilinear_lanes(h, x, y, RX.TracedRNumber{Float64})
            xr, yr = RX.ConcreteRArray(xs), RX.ConcreteRArray(ys)
            (L, _f64_widths(repr(RX.@code_hlo optimize = false f(xr, yr))))
        end
        for nc in (5, 40)
            L, widths = mk(nc)
            @test 4 * 3 * 3 in widths          # 4 distinct tables, deduped
            @test !(L * 3 * 3 in widths)       # the per-lane flattening is gone
        end
    end

    @testset "per-lane knots with a lane-invariant query keep their L lanes" begin
        # The `_rx_knot_matrix` guard. Collapsing all-equal per-lane knots to one
        # ROW is only sound when the QUERY carries the lane axis; with a scalar
        # query the L×n compare matrix is the only thing giving the result its L
        # rows, so collapsing would silently return one lane where the caller
        # unwraps L. Same tables on every lane is exactly the collapsible case.
        h = _lane_spec(1, 6)                   # 1 band × 6 cells: all knots equal
        L = length(h.specs)
        f = (x) -> ESM._oop_interp_bilinear_lanes(h, x, RX.ConcreteRNumber(1.25),
                                                  RX.TracedRNumber{Float64})
        xs = Float64[0.2k for k in 0:(L - 1)]
        xr = RX.ConcreteRArray(xs)
        got = Array((RX.@compile sync = true f(xr))(xr))
        @test length(got) == L
        ref = ESM._oop_interp_bilinear_lanes(h, xs, fill(1.25, L), Float64)
        @test all(isapprox(a, b; rtol = 1e-14) for (a, b) in zip(got, ref))
    end
end
