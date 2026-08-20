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
#
# The trailing testsets extend layer 3 to the lane-table-intern change's traced
# side: the clamp-bound collapse (`_oop_lane_bound`) must land as SCALAR
# constants (lane-wide splat columns under the ESS_LANE_INTERN_DISABLE=1
# oracle), and the module must hold ONE table payload per distinct CONTENT —
# under both env settings, and through `build_evaluator(form=:oop)` itself.

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

# How many f64 constants of width `w` carry a full PAYLOAD (`dense<[…]>`, a real
# per-element list — a table) — as opposed to splat constants (`dense<7.25…>`,
# one repeated value: broadcast scaffolding, or an UN-collapsed all-equal bound
# column). The distinction is load-bearing: only payload constants are tables.
_ld_npayload(hlo::String, w::Int) =
    length(collect(eachmatch(Regex("dense<\\[[^\\n]+\\]> : tensor<$(w)xf64>"), hlo)))

# A splat f64 constant of MLIR spelling `v` ("%.6e", e.g. "7.250000e+00") at
# width `w` — a lane-wide bound column — or as a scalar `tensor<f64>` — a
# collapsed bound. The fixtures below pick bound values whose spelling appears
# nowhere else in the module, so presence/absence is exact.
_ld_has_col(hlo, v::String, w) = occursin("dense<$v> : tensor<$(w)xf64>", hlo)
_ld_has_scalar(hlo, v::String) = occursin("dense<$v> : tensor<f64>", hlo)

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

    # ---- the lane-table-intern change's TRACED-SIDE claims, measured in HLO.
    #
    # Two claims landed host-side (tree_walk/acc_merge.jl `_lane_intern`,
    # tree_walk/oop.jl `_oop_lane_bound`, both under ESS_LANE_INTERN_DISABLE=1)
    # with their Reactant-side effect asserted only by argument. Pinned here on
    # the emitted module text (`@code_hlo optimize = false` — pre-canonicalize,
    # so every constant is still visible where the trace put it):
    #
    #   * CLAMP/EDGE BOUNDS. `_oop_lane_bound` collapses an all-bitwise-equal
    #     boundary column to its one scalar HOST-side, so the trace embeds a
    #     `tensor<f64>` and never sees the column; under the kill switch the
    #     column reaches the broadcast and is embedded as a lane-wide
    #     `tensor<Lxf64>` splat — the O(lanes) constant the collapse retires
    #     (4 per bilinear; measured 3.6 MB → 32 B per 13×7×72 call site).
    #     `_oop_lane_bound` reads the env var PER CALL, i.e. at TRACE time, so
    #     the oracle toggles around the trace, not around spec construction.
    #
    #   * TABLE CONSTANTS DO **NOT** REVERT under the kill switch — and must
    #     not: build-time interning shares SPEC OBJECTS, but the seams here
    #     dedup the knot COLUMNS by VALUE (`_rx_lane_groups`), which was
    #     deliberately KEPT (it is finer than spec identity, and the seams
    #     never see spec identity at all). So the flat table payload is
    #     `Nx·Ny·D` with D = distinct CONTENTS in both worlds. Asserting the
    #     oracle arm pins that deliberate redundancy: an env var must never be
    #     able to reintroduce the O(lanes) constant.
    #
    # The bound values (5.0, 7.25 — MLIR spells them "%.6e") are chosen to
    # appear nowhere else in the module, so splat presence/absence is exact.

    @testset "clamp bounds: scalar consts collapsed, lane columns under the oracle" begin
        ax = [5.0, 6.0, 7.25]
        band(b) = ESM._InterpBilinearSpec(
            [Float64[b + 0.01j + 0.1i for j in 0:2] for i in 0:2],
            copy(ax), copy(ax))
        specs = ESM._InterpBilinearSpec[band(Float64(1 + (l - 1) % 3)) for l in 1:21]
        h = ESM._InterpBilinearLaneSpec(specs, 1, 0, 0, 1)
        L = length(h.specs)                    # 21 lanes, D = 3 tables, 1 axis
        xs = Float64[4.0 + 0.2k for k in 0:(L - 1)]   # spans both clamps
        ys = Float64[8.0 - 0.2k for k in 0:(L - 1)]
        f = (x, y) -> ESM._oop_interp_bilinear_lanes(h, x, y,
                                                     RX.TracedRNumber{Float64})
        xr, yr = RX.ConcreteRArray(xs), RX.ConcreteRArray(ys)
        son = repr(RX.@code_hlo optimize = false f(xr, yr))
        soff = withenv("ESS_LANE_INTERN_DISABLE" => "1") do
            repr(RX.@code_hlo optimize = false f(xr, yr))
        end

        # Collapsed: each bound is a scalar constant; NO lane-wide bound column.
        @test _ld_has_scalar(son, "5.000000e+00")
        @test _ld_has_scalar(son, "7.250000e+00")
        @test !_ld_has_col(son, "5.000000e+00", L)
        @test !_ld_has_col(son, "7.250000e+00", L)
        # Oracle: the very same values come back as L-wide splat columns.
        @test _ld_has_col(soff, "5.000000e+00", L)
        @test _ld_has_col(soff, "7.250000e+00", L)

        # ONE table payload of Nx·Ny·D — not one per corner gather (four
        # gathers share it via `Ops.constant`'s value memo), not Nx·Ny·L — and
        # the SAME one under the oracle (the kept trace-time dedup, see above).
        @test _ld_npayload(son, 9 * 3) == 1
        @test _ld_npayload(soff, 9 * 3) == 1
        @test !(9L in _f64_widths(son)) && !(9L in _f64_widths(soff))
        # The shared axis dedups to D = 1: one 3-wide payload serves 21 lanes.
        @test _ld_npayload(son, 3) == 1

        # Both programs still compute the per-lane host oracle's numbers.
        ref = ESM._oop_interp_bilinear_lanes(h, xs, ys, Float64)
        gon = Array((RX.@compile sync = true f(xr, yr))(xr, yr))
        goff = withenv("ESS_LANE_INTERN_DISABLE" => "1") do
            Array((RX.@compile sync = true f(xr, yr))(xr, yr))
        end
        @test all(isapprox(a, b; rtol = 1e-14) for (a, b) in zip(gon, ref))
        @test all(isapprox(a, b; rtol = 1e-14) for (a, b) in zip(goff, ref))
    end

    # The same claims through the FRONT DOOR: `build_evaluator(doc; form=:oop)`
    # — so the build-time intern pool, the kernel-class merge, and the ext's
    # seams are all in the traced pipeline, not just a hand-built lane spec.
    # Four members over one axis: u/v/w carry two distinct table CONTENTS in
    # three spellings (Float64, Int — the coercion twin AST interning cannot
    # unify — and a distinct copy), so they merge into ONE class whose flat
    # table is 9·D = 18 wide (D = 2 contents, NOT 3 members); z reuses content
    # A under a DIFFERENT template, landing in its own class — whose single
    # shared spec takes the scalar-spec lane form (host-scalar bounds by
    # construction, no columns to collapse). Everything is pinned at two grid
    # sizes: the payload inventory must not move when N does.
    @testset "built model: one constant per distinct content (N=$N)" for N in (5, 11)
        ax = Any[5.0, 6.0, 7.25]
        ta_f = Any[Any[1.0, 2.0, 3.0], Any[4.0, 5.5, 6.0], Any[7.0, 8.0, 9.0]]
        ta_i = Any[Any[1, 2, 3], Any[4, 5.5, 6], Any[7, 8, 9]]
        tb = Any[Any[-9.0, 3.0, -1.0], Any[2.5, -4.0, 0.5], Any[-0.25, 8.0, -6.0]]
        bil(x, tbl) = Dict{String,Any}("op" => "fn", "name" => "interp.bilinear",
            "args" => Any[Dict{String,Any}("op" => "const", "value" => tbl),
                          Dict{String,Any}("op" => "const", "value" => ax),
                          Dict{String,Any}("op" => "const", "value" => ax),
                          Dict{String,Any}("op" => "index", "args" => Any[x, "i"]),
                          Dict{String,Any}("op" => "index", "args" => Any[x, "i"])])
        ao(e) = Dict{String,Any}("op" => "arrayop", "output_idx" => Any["i"],
            "ranges" => Dict{String,Any}("i" => Dict{String,Any}("from" => "n")),
            "args" => Any[], "expr" => e)
        eq(x, rhs) = Dict{String,Any}(
            "lhs" => ao(Dict{String,Any}("op" => "D", "wrt" => "t",
                "args" => Any[Dict{String,Any}("op" => "index",
                                               "args" => Any[x, "i"])])),
            "rhs" => ao(rhs))
        st() = Dict{String,Any}("type" => "unknown", "shape" => Any["n"])
        doc = Dict{String,Any}(
            "esm" => "0.5.0", "metadata" => Dict{String,Any}("name" => "LD"),
            "index_sets" => Dict{String,Any}("n" => Dict{String,Any}(
                "kind" => "interval", "size" => N)),
            "models" => Dict{String,Any}("M" => Dict{String,Any}(
                "variables" => Dict{String,Any}("u" => st(), "v" => st(),
                                                "w" => st(), "z" => st()),
                "equations" => Any[
                    eq("u", bil("u", ta_f)), eq("v", bil("v", ta_i)),
                    eq("w", bil("w", tb)),
                    eq("z", Dict{String,Any}("op" => "*",
                        "args" => Any[2.0, bil("z", ta_f)]))])))

        fo, _, p, _, _ = ESM.build_evaluator(doc; form = :oop)
        fi, _, _, _, _ = ESM.build_evaluator(doc)
        Lm = 3N                                # the merged u/v/w class's lanes
        u = Float64[4.2 + 0.23(k % 17) for k in 1:(4N)]
        ur, tr = RX.ConcreteRArray(u), RX.ConcreteRNumber(0.0)
        s = repr(RX.@code_hlo optimize = false fo(ur, p, tr))

        @test _ld_npayload(s, 18) == 1        # merged class: 9·D, D = 2 contents
        @test _ld_npayload(s, 9) == 1         # z's class: content A once more
        @test _ld_npayload(s, 3) == 1         # ONE axis payload across BOTH classes
        @test !(9Lm in _f64_widths(s))        # no per-lane flattening anywhere
        @test _ld_has_scalar(s, "7.250000e+00")
        @test !_ld_has_col(s, "7.250000e+00", Lm) && !_ld_has_col(s, "7.250000e+00", N)

        # Oracle build+trace: bound columns return on the merged class (z's
        # scalar-spec form has none to lose); the table inventory is unmoved.
        s_off, fo_off = withenv("ESS_LANE_INTERN_DISABLE" => "1") do
            g, _, _, _, _ = ESM.build_evaluator(doc; form = :oop)
            repr(RX.@code_hlo optimize = false g(ur, p, tr)), g
        end
        @test _ld_has_col(s_off, "7.250000e+00", Lm)
        @test _ld_has_col(s_off, "5.000000e+00", Lm)
        @test _ld_npayload(s_off, 18) == 1 && _ld_npayload(s_off, 9) == 1

        # Numbers: the compiled module agrees with the trusted in-place f!,
        # interned and oracle alike (XLA reassociates — tolerance, not ==).
        du = zero(u); fi(du, u, p, 0.0)
        got = Array((RX.@compile sync = true fo(ur, p, tr))(ur, p, tr))
        @test all(isapprox(a, b; rtol = 1e-12, atol = 1e-13) for (a, b) in zip(got, du))
        got_off = withenv("ESS_LANE_INTERN_DISABLE" => "1") do
            Array((RX.@compile sync = true fo_off(ur, p, tr))(ur, p, tr))
        end
        @test all(isapprox(a, b; rtol = 1e-12, atol = 1e-13) for (a, b) in zip(got_off, du))
    end
end
