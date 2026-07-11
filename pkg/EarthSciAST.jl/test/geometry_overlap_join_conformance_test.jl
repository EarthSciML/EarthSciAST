# Conservative-regridding OVERLAP-JOIN — Julia evaluator conformance (END-TO-END).
#
# Bead ess-3lj.3 (F3). RFC semiring-faq-unified-ir §A.8 / §8.1 / §6.1 / §5.3 /
# §5.5; CONFORMANCE_SPEC.md §5.8. Drives the FULL conservative-regridding idiom in
# ONE document — tests/valid/geometry/conservative_regrid_overlap_join.esm —
# through build_evaluator, with NO pre-baked bins:
#
#   floor → skolem bin keys → distinct candidate pairs → equijoin   (broad phase)
#   → intersect_polygon clip → polygon_area                          (narrow phase)
#   → A_j row-sum → apply → normalize                                (assembly)
#
# Unlike conservative_regrid_assembly.esm (categorical PRE-BAKED bins, join.on
# [[i,j]] on the loop symbols), this fixture COMPUTES each cell's bin key from its
# representative lon/lat (skolem("bin", floor(lon/dx), floor(lat/dy))) in the
# value-invention front-door (F1/F2) and the A_j / apply FAQs gate on the
# MATERIALISED bin buffers: join.on [[src_bin, tgt_bin]] (the F3 buffer-gated join,
# §5.3). The narrow phase is SPHERICAL — the clip runs through the evaluator via
# GeometryOps and A_ij_rep is the Van Oosterom-Strackee spherical-excess
# polygon_area FAQ over the derived clip ring.
#
# Every assembled state is a constant-RHS D-equation from a zero IC, so the
# derivative du = f!(u0) IS the assembled value — exact, no integrator (the
# assembly precedent). The fixture is supplied A_ij / F_src / dst_areas /
# src_poly_rep / tgt_poly_rep as const_arrays, so per CONFORMANCE_SPEC §5.8 the
# other bindings schema-/structurally-validate it while Julia evaluates it here.

using Test
using EarthSciAST
import JSON3
# GeometryOps + GeoInterface trigger EarthSciASTGeometryOpsExt — the spherical
# clip/area the narrow phase runs through. Under runtests.jl the sibling
# geometry files already load them; the imports keep this file standalone-safe.
import GeometryOps
import GeoInterface

const ESS = EarthSciAST
include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _OJ_REPO_ROOT = TESTUTILS_REPO_ROOT
const _OJ_FIXTURE = joinpath(_OJ_REPO_ROOT, "tests", "valid", "geometry",
                             "conservative_regrid_overlap_join.esm")

# A closed axis-aligned spherical cell as a CCW lon/lat vertex ring (degrees).
_rect(x0, x1, y0, y1) = [x0 y0; x1 y0; x1 y1; x0 y1]

# 3 source + 3 target cells in a thin equatorial band lat∈[0,1]°, domain lon
# [0,3]°. With dx=dy=2 the bin of a cell is (floor(repr_lon/2), floor(repr_lat/2)):
# source/target cells 1,2 fall in lon-bin 0, cell 3 in lon-bin 1 — so the broad
# phase is LOAD-BEARING (the candidate set is the within-bin block, not the full
# 3×3 cross product). The target grid refines the source within each bin.
const _SRC = [_rect(0, 1, 0, 1), _rect(1, 2, 0, 1), _rect(2, 3, 0, 1)]
const _TGT = [_rect(0, 1.5, 0, 1), _rect(1.5, 2, 0, 1), _rect(2, 3, 0, 1)]
# Representative (bbox-min corner) lon/lat the broad phase bins each cell by.
const _SRC_LON = [0.0, 1.0, 2.0]; const _SRC_LAT = [0.0, 0.0, 0.0]
const _TGT_LON = [0.0, 1.5, 2.0]; const _TGT_LAT = [0.0, 0.0, 0.0]
const _F_SRC = [10.0, 20.0, 30.0]
const _DX = 2.0; const _DY = 2.0
# Representative narrow-phase pair: src 2 ∩ tgt 1 = lon[1,1.5]×lat[0,1], fractional.
const _OJ_REP_I, _OJ_REP_J = 2, 1

# Build the build-once overlap-area matrix A_ij = polygon_area(intersect_polygon(
# src_i, tgt_j, "spherical"), "spherical") via the landed GeometryOps clip + the
# VOS area — ConservativeRegridding.jl's `intersections` matrix of RAW areas.
function _oj_build_Aij()
    A = zeros(Float64, length(_SRC), length(_TGT))
    for i in 1:length(_SRC), j in 1:length(_TGT)
        ring = ESS.intersect_polygon(_SRC[i], _TGT[j], "spherical")
        size(ring, 1) < 3 && continue
        A[i, j] = ESS.polygon_area(ring, "spherical")
    end
    return A
end

_oj_const_arrays(A_ij, dst_areas) = Dict(
    "A_ij" => A_ij, "F_src" => _F_SRC, "dst_areas" => dst_areas,
    "src_lon" => _SRC_LON, "src_lat" => _SRC_LAT,
    "tgt_lon" => _TGT_LON, "tgt_lat" => _TGT_LAT,
    "src_poly_rep" => _SRC[_OJ_REP_I], "tgt_poly_rep" => _TGT[_OJ_REP_J])

# Drive the overlap-join fixture through build_evaluator, returning
# (A_j, F_tgt, narrow_phase_area). du = f!(u0) at the zero IC IS the assembled
# value for each constant-RHS D-equation.
function _oj_eval(A_ij, dst_areas; atol::Float64=1e-15)
    # The VALUE-INVENTION broad phase (src_bin/tgt_bin/candidate_pairs) is
    # materialised only on the AbstractDict front-door, so drive the RAW document
    # through build_evaluator (NOT the typed EsmFile path, which skips it).
    raw = JSON3.read(read(_OJ_FIXTURE, String))
    n = length(dst_areas)
    ics = Dict("narrow_phase_area" => 0.0,
               ("A_j[$j]" => 0.0 for j in 1:n)...,
               ("F_tgt[$j]" => 0.0 for j in 1:n)...)
    f!, u0, p, _, vmap = build_evaluator(
        raw; model_name="ConservativeRegridOverlapJoin",
        initial_conditions=ics, const_arrays=_oj_const_arrays(A_ij, dst_areas),
        parameter_overrides=Dict("dx" => _DX, "dy" => _DY, "atol" => atol))
    du = similar(u0); f!(du, u0, p, 0.0)
    A_j   = [du[vmap["A_j[$j]"]] for j in 1:n]
    F_tgt = [du[vmap["F_tgt[$j]"]] for j in 1:n]
    return A_j, F_tgt, du[vmap["narrow_phase_area"]]
end

@testset "M4 conservative-regridding overlap-join end-to-end (ess-3lj.3)" begin

    A_ij = _oj_build_Aij()
    dst_areas = vec(sum(A_ij; dims=1))   # column sums = A_j = dst_areas
    src_areas = vec(sum(A_ij; dims=2))   # row sums (overlap mass per source cell)

    @testset "fixture loads (schema + structural)" begin
        @test isfile(_OJ_FIXTURE)
        @test (ESS.load(_OJ_FIXTURE); true)
    end

    # (1) BROAD PHASE — the bin-Skolem candidate set is materialised through the
    # value-invention front-door from the COMPUTED bins (no pre-baked categorical
    # members). dx=2 ⇒ cells {1,2} share lon-bin 0, cell 3 is lon-bin 1.
    @testset "broad phase: candidate set = computed bin-Skolem equi-join" begin
        mj = ESS._select_model_json(JSON3.read(read(_OJ_FIXTURE, String)),
                                    "ConservativeRegridOverlapJoin")
        vi = ESS.materialize_value_invention(
            mj, Dict("src_lon" => _SRC_LON, "src_lat" => _SRC_LAT,
                     "tgt_lon" => _TGT_LON, "tgt_lat" => _TGT_LAT),
            Dict("dx" => _DX, "dy" => _DY, "atol" => 1e-15))
        @test vi.members["candidate_set"] == [(1, 1), (1, 2), (2, 1), (2, 2), (3, 3)]
        @test vi.extents["candidate_set"] == 5
        @test vi.vi_var_names == Set(["src_bin", "tgt_bin", "pair_exists"])
        # the materialised bin buffers the F3 join gates on
        @test vi.maps["src_bin"][1] == vi.maps["src_bin"][2]       # cells 1,2 same bin
        @test vi.maps["src_bin"][1] != vi.maps["src_bin"][3]       # cell 3 different
        @test vi.map_sets["src_bin"] == "src_cells"
    end

    # (2) NARROW PHASE — the SPHERICAL clip runs through the evaluator and the
    # A_ij_rep FAQ is the Van Oosterom-Strackee spherical-excess area over the
    # derived clip ring (gap 2). It equals the kept polygon_area VOS oracle and the
    # matching build-once A_ij entry (the clip's provenance).
    @testset "narrow phase: spherical clip + VOS area FAQ through the evaluator" begin
        A_j, F_tgt, narrow = _oj_eval(A_ij, dst_areas)
        clip = ESS.intersect_polygon(_SRC[_OJ_REP_I], _TGT[_OJ_REP_J], "spherical")
        @test isapprox(narrow, ESS.polygon_area(clip, "spherical"); rtol=1e-9, atol=1e-14)
        @test isapprox(narrow, A_ij[_OJ_REP_I, _OJ_REP_J]; rtol=1e-9, atol=1e-14)
        @test narrow > 0
    end

    # (3) A_j group-by-`j` FAQ over the BUFFER-GATED candidate join reproduces the
    # build-once dst_areas row-sums (the F3 join.on [[src_bin,tgt_bin]] capability).
    @testset "assembly: A_j reproduces dst_areas (buffer-gated join)" begin
        A_j, _, _ = _oj_eval(A_ij, dst_areas)
        @test A_j ≈ dst_areas
    end

    # (4)+(5) APPLY + NORMALIZE — F_tgt[j] = (1/dst_areas[j])·Σ_i A_ij·F_src[i].
    @testset "assembly: apply + normalize" begin
        _, F_tgt, _ = _oj_eval(A_ij, dst_areas)
        F_tgt_expected = [sum(A_ij[i, j] * _F_SRC[i] for i in 1:length(_SRC)) / dst_areas[j]
                          for j in 1:length(_TGT)]
        @test F_tgt ≈ F_tgt_expected
    end

    # ACCEPTANCE INVARIANT 1 — PARTITION-OF-UNITY (§5.8.3): W_ij = A_ij/A_j sum to
    # 1 over each target cell, EXACT by construction (the denominator A_j is the
    # row-sum of the SAME areas in the numerator).
    @testset "PARTITION-OF-UNITY: Σ_i W_ij = 1 (exact by construction)" begin
        A_j, _, _ = _oj_eval(A_ij, dst_areas)
        for j in 1:length(_TGT)
            w_sum = sum(A_ij[i, j] for i in 1:length(_SRC)) / A_j[j]
            @test isapprox(w_sum, 1.0; rtol=1e-12, atol=1e-12)
        end
    end

    # ACCEPTANCE INVARIANT 2 — CONSERVATION (§5.8.3): the global remapped mass
    # equals the source mass. The assembly identity Σ_j A_j·F_tgt = Σ_i A_i·F_src
    # (A_i = overlap-mass row-sum) is exact; full spherical coverage (row-sum =
    # the cell's own spherical area) holds to the great-circle edge tolerance.
    @testset "CONSERVATION: Σ_j A_j·F_tgt = Σ_i A_i·F_src" begin
        A_j, F_tgt, _ = _oj_eval(A_ij, dst_areas)
        @test isapprox(sum(A_j .* F_tgt), sum(src_areas .* _F_SRC); rtol=1e-12, atol=1e-12)
        # physical full-coverage: each source cell's overlap mass ≈ its own spherical
        # area, to the GREAT-CIRCLE edge-model tolerance (§5.8.3: "conservation
        # tolerance is application-set and resolution-dependent"). The clip of a cell
        # against two refining targets follows the lower envelope of two distinct
        # great-circle top edges, so coverage is exact only up to that edge model
        # (≈1e-5 here); the source cells fully contained in one target are exact.
        for i in 1:length(_SRC)
            @test isapprox(src_areas[i], ESS.polygon_area(_SRC[i], "spherical"); rtol=1e-4)
        end
    end

    # The OVERLAP JOIN is load-bearing: join.on [[src_bin,tgt_bin]] admits a term
    # only when src and tgt share a COMPUTED bin. A cross-bin entry (src 1 ∈ bin 0,
    # tgt 3 ∈ bin 1) must be EXCLUDED by the buffer-gated join — proving the broad
    # phase restricts the candidate set and is not a no-op.
    @testset "buffer-gated join excludes cross-bin pairs" begin
        contaminated = copy(A_ij)
        contaminated[1, 3] = 99.0     # src 1 (bin 0) × tgt 3 (bin 1): cross-bin
        A_j, F_tgt, _ = _oj_eval(contaminated, dst_areas)
        @test isapprox(A_j[3], dst_areas[3]; rtol=1e-12)   # 99.0 excluded
        @test isapprox(sum(A_j .* F_tgt), sum(src_areas .* _F_SRC); rtol=1e-12)
    end

    # The ZERO-AREA FILTER is load-bearing: filter A_ij > atol drops sub-atol
    # slivers, turning the byte-identical CANDIDATE set into the tolerance-dependent
    # SURVIVING set (§5.8.5). A WITHIN-bin sliver (src 1 ∈ bin 0, tgt 2 ∈ bin 0)
    # below atol must be dropped.
    @testset "zero-area filter drops sub-atol within-bin slivers" begin
        # A_ij entries are spherical steradians (~1.5e-4 here), so the sliver and
        # atol are scaled to that magnitude: a 1e-9 sliver is dropped by atol=1e-7
        # (well below the real ~1.5e-4 overlaps) and admitted by atol=1e-12.
        slivered = copy(A_ij)
        slivered[1, 2] = 1e-9         # src 1 (bin 0) × tgt 2 (bin 0): within-bin sliver
        A_j_drop, _, _ = _oj_eval(slivered, dst_areas; atol=1e-7)
        @test isapprox(A_j_drop[2], dst_areas[2]; rtol=1e-9)            # dropped
        A_j_admit, _, _ = _oj_eval(slivered, dst_areas; atol=1e-12)
        @test isapprox(A_j_admit[2], dst_areas[2] + 1e-9; rtol=1e-5)    # admitted
    end
end
