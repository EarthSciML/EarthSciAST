# Conservative-regridding ASSEMBLY — Julia evaluator conformance (INLINE weights,
# FUSED polygon_intersection_area narrow phase).
#
# Bead ess-my4.4.6. RFC semiring-faq-unified-ir §A.8 / §8.1 / §6.1;
# CONFORMANCE_SPEC.md §5.8; esm-spec.md §8.6.1. The fixture
# tests/valid/geometry/conservative_regrid_assembly.esm computes the overlap
# weights INLINE from cell geometry — it does not SUPPLY an A_ij / dst_areas const.
# The full first-order conservative-regrid pipeline it declares:
#
#   A_ij = polygon_intersection_area(src_i, tgt_j)   (narrow phase, FUSED leaf)
#   A_j  = Σ_i A_ij                                   (row-sum normalization)
#   W_ij = A_ij / A_j                                 (the weights)
#   F_tgt[j] = Σ_i W_ij · F_src[i]                    (apply)
#
# with the candidate pairs from the bin-skolem BROAD phase (floor → skolem bin keys
# → distinct equi-join on the materialized bin buffers) and F_src a
# SPATIALLY-VARYING source ([10,20,30,40]) so conservation / partition-of-unity are
# non-trivial. The source (4 cells) and target (4 cells) grids tile [0,4]×[0,1] with
# DIFFERENT cell boundaries, so the overlaps are fractional.
#
# WHAT IS NOW DENSELY EVALUABLE (the §8.6.1 change). The narrow phase used to clip
# each pair to a `intersect_polygon` ring of DATA-DEPENDENT length (a per-clip
# `clip_ring` derived set) and area it with a `polygon_area` shoelace FAQ, so the
# full-mesh narrow phase was only STRUCTURALLY valid — no single dense FAQ can clip
# all pairs at once. The fixture now spells A_ij with the FUSED
# `polygon_intersection_area` leaf: it returns the SCALAR overlap area (defined to
# equal the clip-then-shoelace composition) and HIDES the ring inside the kernel, so
# A_ij is an ordinary DENSE aggregate over the candidate set — no ragged
# intermediate. This test therefore drives the narrow phase THROUGH the evaluator:
#
#   1. BROAD phase (build-time value invention, §8.6.1): the candidate pair set is
#      the bin-skolem equi-join — floor(coord/dx)→skolem bin key→shared-bin pairs.
#      This is build-time (`skolem`/`distinct`), computed here mirroring the fixture.
#   2. NARROW phase (through build_evaluator): the fused `polygon_intersection_area`
#      leaf is lowered and evaluated by `build_evaluator` as ONE WHOLE-MESH aggregate
#      — the fixture's OWN `A_ij[i,j] = polygon_intersection_area(src_poly[i],
#      tgt_poly[j])` node, with the ranged fused leaf resolving its INDEXED operands
#      by gathering each cell's ring from the in-file const ring stacks at setup. A_ij
#      materializes as one dense [i,j] const array in a single call
#      (`_build_Aij_via_evaluator`, reading `index(A_ij,i,j)` into a state). A_ij[i,j]
#      for a non-candidate pair is 0 (zero geometric overlap), matching the fixture's
#      `join.on [[src_bin,tgt_bin]]`. This REPLACES both the old standalone
#      `ESS.intersect_polygon`+`ESS.polygon_area` computation AND the earlier
#      per-candidate-pair driving — A_ij now flows through the evaluator's whole-mesh
#      fused-leaf aggregate. (A definitional cross-check against the standalone kernels
#      is retained as an oracle.)
#   3. APPLY / NORMALIZE (through build_evaluator): A_j, F_tgt via the evaluable
#      apply FAQ with the load-bearing bin join + sliver filter (`_apply_only_esm`).
#
# The one part that stays build-time is the candidate-set CONSTRUCTION (the
# `skolem`/`distinct` broad phase), by design (§8.6.1). The narrow phase A_ij is now
# a SINGLE whole-mesh aggregate call over the entire src × tgt mesh (the ranged fused
# leaf resolves `index(src_poly,i)` / `index(tgt_poly,j)` operands from the in-file
# const rings), no longer driven per candidate pair. The WHOLE fixture — broad phase,
# narrow phase, row-sum/normalize, and apply — additionally builds end-to-end through
# ONE build_evaluator call (`_build_fixture_end_to_end`), reproducing A_j and F_tgt.
# The conservation / partition-of-unity NUMERIC checks are UNCHANGED in strength.

using Test
using EarthSciSerialization
import JSON3

const ESS = EarthSciSerialization
include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _ASM_REPO_ROOT = TESTUTILS_REPO_ROOT
const _ASM_FIXTURE = joinpath(_ASM_REPO_ROOT, "tests", "valid", "geometry",
                              "conservative_regrid_assembly.esm")

const _REP_I, _REP_J = 2, 1   # representative fractional pair: src 2 ∩ tgt 1 = 0.5

# ---- read the in-file `const` geometry straight from the fixture ----
_asm_raw() = JSON3.read(read(_ASM_FIXTURE, String))
_asm_vars(raw) = raw["models"]["ConservativeRegridAssembly"]["variables"]

function _const_rings(vars, name)
    v = vars[name]["expression"]["value"]
    nv = length(v[1])
    nc = length(v[1][1])
    [[Float64(v[i][k][c]) for k in 1:nv, c in 1:nc] for i in 1:length(v)]
end
_const_vec(vars, name) = [Float64(x) for x in vars[name]["expression"]["value"]]
_param_default(vars, name) = Float64(vars[name]["default"])

# Collect every expression node with op == `opname` under `node`.
function _find_ops(node, opname, acc=Any[])
    if node isa JSON3.Object || node isa AbstractDict
        get(node, "op", nothing) == opname && push!(acc, node)
        for (_, v) in node
            _find_ops(v, opname, acc)
        end
    elseif node isa JSON3.Array || node isa AbstractVector
        for v in node
            _find_ops(v, opname, acc)
        end
    end
    return acc
end

# ======================================================================
# BROAD PHASE (build-time value invention): the bin-skolem candidate set.
# ======================================================================
# Mirror the fixture's skolem("bin", floor(lon/dx), floor(lat/dy)) binning: two
# cells share a candidate bin iff their integer (floor(lon/dx), floor(lat/dy)) keys
# are equal (§8.6.1 — build-time `skolem`/`distinct`, run once at construction).
_bin_key(lon, lat, dx, dy) = (floor(Int, lon / dx), floor(Int, lat / dy))

function _candidate_pairs(src_bins, tgt_bins)
    pairs = Tuple{Int,Int}[]
    for i in eachindex(src_bins), j in eachindex(tgt_bins)
        src_bins[i] == tgt_bins[j] && push!(pairs, (i, j))
    end
    return pairs
end

# ======================================================================
# NARROW PHASE through build_evaluator: the WHOLE-MESH fused-leaf aggregate.
# ======================================================================
# The narrow phase is now driven as ONE whole-mesh aggregate — the FIXTURE's OWN
# `A_ij[i,j] = polygon_intersection_area(src_poly[i], tgt_poly[j])` node — not per
# candidate pair. The evaluator resolves the ranged fused leaf with INDEXED operands
# (`index(src_poly,i)` / `index(tgt_poly,j)`) by gathering each cell's ring from the
# in-file const ring stacks at setup, so A_ij materializes as one dense [i,j] const
# array. We extract it by reading `index(A_ij,i,j)` into a zero-IC array state
# `A_ex[i,j]` (du = the fused-leaf overlap area for every cell in one call).
_native(x) = ESS.Cadence.to_native(x)

# The whole-mesh A_ij extraction ESM: the fixture's OWN src_poly / tgt_poly const
# rings and its OWN A_ij aggregate node, plus D(A_ex[i,j]) = index(A_ij,i,j). The
# A_ij join references the broad-phase bins (src_bin/tgt_bin); those columns are
# absent here, so the setup gate skips them (a non-candidate pair has zero overlap
# regardless — the join is a candidate-set narrowing, not a correctness gate for
# the geometric area itself).
function _aij_extract_esm(vars)
    ix(a...) = Dict{String,Any}("op" => "index", "args" => collect(Any, a))
    nv = length(vars["src_poly"]["expression"]["value"][1])
    nc = length(vars["src_poly"]["expression"]["value"][1][1])
    nS = length(vars["src_poly"]["expression"]["value"])
    nT = length(vars["tgt_poly"]["expression"]["value"])
    agg(oidx, body) = Dict{String,Any}("op" => "aggregate", "output_idx" => collect(Any, oidx),
        "ranges" => Dict{String,Any}("i" => Dict{String,Any}("from" => "src_cells"),
                                     "j" => Dict{String,Any}("from" => "tgt_cells")),
        "expr" => body)
    model = Dict{String,Any}("variables" => Dict{String,Any}(
            "src_poly" => Dict{String,Any}("type" => "observed",
                "shape" => Any["src_cells", "cell_verts", "coord"],
                "expression" => _native(vars["src_poly"]["expression"])),
            "tgt_poly" => Dict{String,Any}("type" => "observed",
                "shape" => Any["tgt_cells", "cell_verts", "coord"],
                "expression" => _native(vars["tgt_poly"]["expression"])),
            "A_ij" => Dict{String,Any}("type" => "observed",
                "shape" => Any["src_cells", "tgt_cells"],
                "expression" => _native(vars["A_ij"]["expression"])),
            "A_ex" => Dict{String,Any}("type" => "state", "shape" => Any["src_cells", "tgt_cells"])),
        "equations" => Any[Dict{String,Any}(
            "lhs" => agg(["i", "j"], Dict{String,Any}("op" => "D", "args" => Any[ix("A_ex", "i", "j")], "wrt" => "t")),
            "rhs" => agg(["i", "j"], ix("A_ij", "i", "j")))])
    Dict{String,Any}("esm" => "0.8.0", "metadata" => Dict{String,Any}("name" => "aij_extract"),
        "index_sets" => Dict{String,Any}(
            "coord" => Dict{String,Any}("kind" => "interval", "size" => nc),
            "cell_verts" => Dict{String,Any}("kind" => "interval", "size" => nv),
            "src_cells" => Dict{String,Any}("kind" => "interval", "size" => nS),
            "tgt_cells" => Dict{String,Any}("kind" => "interval", "size" => nT)),
        "models" => Dict{String,Any}("AijExtract" => model))
end

# Build the overlap-area matrix A_ij by driving the fixture's OWN whole-mesh fused-
# leaf aggregate through ONE build_evaluator call. Returns (A_ij, F_src, pairs); the
# candidate pairs come from the broad-phase bin mirror (used only for the broad-phase
# candidate-set assertion — the narrow phase is now a single dense aggregate call).
function _build_Aij_via_evaluator()
    vars = _asm_vars(_asm_raw())
    SRC = _const_rings(vars, "src_poly")
    TGT = _const_rings(vars, "tgt_poly")
    F_SRC = _const_vec(vars, "F_src")
    dx = _param_default(vars, "dx")
    dy = _param_default(vars, "dy")
    # Binning coords mirror the fixture's inline `min`-reduction over each cell's
    # vertex ring (src_lon[i] = min_v src_poly[i,v,1], etc.) — the pure form the
    # evaluator now derives at setup, so this host-side broad-phase mirror computes
    # them the same way instead of reading a (no-longer-present) const vector.
    _min_ring(rings, c) = [minimum(@view r[:, c]) for r in rings]
    src_lon, src_lat = _min_ring(SRC, 1), _min_ring(SRC, 2)
    tgt_lon, tgt_lat = _min_ring(TGT, 1), _min_ring(TGT, 2)
    src_bins = [_bin_key(src_lon[i], src_lat[i], dx, dy) for i in eachindex(SRC)]
    tgt_bins = [_bin_key(tgt_lon[j], tgt_lat[j], dx, dy) for j in eachindex(TGT)]
    pairs = _candidate_pairs(src_bins, tgt_bins)

    nS, nT = length(SRC), length(TGT)
    ics = Dict("A_ex[$i,$j]" => 0.0 for i in 1:nS, j in 1:nT)
    f!, u0, p, _, vmap = build_evaluator(_aij_extract_esm(vars);
        model_name="AijExtract", initial_conditions=ics)
    du = similar(u0); f!(du, u0, p, 0.0)
    A = [du[vmap["A_ex[$i,$j]"]] for i in 1:nS, j in 1:nT]   # whole-mesh fused-leaf A_ij
    return A, F_SRC, pairs
end

# Drive the WHOLE fixture end-to-end through ONE build_evaluator call: the bin-skolem
# broad phase (value invention), the fused-leaf narrow phase (A_ij at setup), the
# row-sum / normalize (A_j / W_ij at setup), and the apply ODEs (A_j_check, F_tgt).
# The binning coords enter value invention as const factors DERIVED IN-FILE: each is
# an inline `min`-reduction over the cell geometry (src_lon[i] = min_v src_poly[i,v,1]),
# which the front-door evaluates at setup from the `const` src_poly/tgt_poly ring
# stacks — so no host-supplied binning coords are needed (RFC §8.6.1 purity).
# Returns (A_j, F_tgt).
function _build_fixture_end_to_end()
    raw = _asm_raw()
    f!, u0, p, _, vmap = build_evaluator(raw; model_name="ConservativeRegridAssembly")
    du = similar(u0); f!(du, u0, p, 0.0)
    n = 4
    A_j = [du[vmap["A_j_check[$j]"]] for j in 1:n]
    F_tgt = [du[vmap["F_tgt[$j]"]] for j in 1:n]
    return A_j, F_tgt
end

# Definitional oracle: A_ij via the STANDALONE constituent kernels
# (intersect_polygon clip + polygon_area shoelace) over the fixture's own rings.
# `polygon_intersection_area` is DEFINED to equal this composition (§8.6.1), so it is
# a cross-check on the fused-leaf-through-evaluator matrix, not the driver.
function _build_Aij_standalone_oracle()
    vars = _asm_vars(_asm_raw())
    SRC = _const_rings(vars, "src_poly")
    TGT = _const_rings(vars, "tgt_poly")
    nS, nT = length(SRC), length(TGT)
    A = zeros(Float64, nS, nT)
    for i in 1:nS, j in 1:nT
        ring = ESS.intersect_polygon(SRC[i], TGT[j], "planar")
        A[i, j] = size(ring, 1) >= 3 ? ESS.polygon_area(ring, "planar") : 0.0
    end
    return A
end

# The evaluable apply/normalize FAQ, mirroring the fixture's declared assembly:
# A_j[j] = Σ_i A_ij[i,j] and F_tgt[j] = Σ_i A_ij[i,j]·F_src[i]/dst_areas[j], both
# gated by the bin equi-join (join.on [[i,j]] over the categorical bin members)
# and the sub-atol sliver filter. Driven with the GEOMETRY-DERIVED A_ij so the
# evaluator runs exactly the assembly the fixture declares.
function _apply_only_esm()
    ix(a...) = Dict{String,Any}("op" => "index", "args" => collect(Any, a))
    joinij = Any[Dict{String,Any}("on" => Any[Any["i", "j"]])]
    filt = Dict{String,Any}("op" => ">", "args" => Any[ix("A_ij", "i", "j"), "atol"])
    Dlhs(sv) = Dict{String,Any}("op" => "aggregate", "args" => Any[], "output_idx" => Any["j"],
        "expr" => Dict{String,Any}("op" => "D", "args" => Any[ix(sv, "j")], "wrt" => "t"),
        "ranges" => Dict{String,Any}("j" => Any[1, 4]))
    aj_rhs = Dict{String,Any}("op" => "aggregate", "semiring" => "sum_product", "output_idx" => Any["j"],
        "ranges" => Dict{String,Any}("i" => Dict{String,Any}("from" => "src_cells"), "j" => Dict{String,Any}("from" => "tgt_cells")),
        "join" => joinij, "filter" => filt, "args" => Any["A_ij"], "expr" => ix("A_ij", "i", "j"))
    ft_rhs = Dict{String,Any}("op" => "aggregate", "semiring" => "sum_product", "output_idx" => Any["j"],
        "ranges" => Dict{String,Any}("i" => Dict{String,Any}("from" => "src_cells"), "j" => Dict{String,Any}("from" => "tgt_cells")),
        "join" => joinij, "filter" => filt, "args" => Any["A_ij", "F_src", "dst_areas"],
        "expr" => Dict{String,Any}("op" => "/", "args" => Any[
            Dict{String,Any}("op" => "*", "args" => Any[ix("A_ij", "i", "j"), ix("F_src", "i")]), ix("dst_areas", "j")]))
    vars = Dict{String,Any}(
        "A_ij" => Dict{String,Any}("type" => "parameter", "shape" => Any["src_cells", "tgt_cells"]),
        "F_src" => Dict{String,Any}("type" => "parameter", "shape" => Any["src_cells"]),
        "dst_areas" => Dict{String,Any}("type" => "parameter", "shape" => Any["tgt_cells"]),
        "atol" => Dict{String,Any}("type" => "parameter", "default" => 1e-12),
        "A_j" => Dict{String,Any}("type" => "state", "shape" => Any["tgt_cells"]),
        "F_tgt" => Dict{String,Any}("type" => "state", "shape" => Any["tgt_cells"]))
    Dict{String,Any}("esm" => "0.8.0", "metadata" => Dict{String,Any}("name" => "apply_only"),
        "index_sets" => Dict{String,Any}(
            "src_cells" => Dict{String,Any}("kind" => "categorical", "members" => Any["b0", "b0", "b1", "b1"]),
            "tgt_cells" => Dict{String,Any}("kind" => "categorical", "members" => Any["b0", "b0", "b1", "b1"])),
        "models" => Dict{String,Any}("ApplyOnly" => Dict{String,Any}("variables" => vars,
            "equations" => Any[Dict{String,Any}("lhs" => Dlhs("A_j"), "rhs" => aj_rhs),
                               Dict{String,Any}("lhs" => Dlhs("F_tgt"), "rhs" => ft_rhs)])))
end

# Drive the apply/normalize FAQ from the geometry-derived A_ij; du = f!(u0) at the
# zero IC IS the assembled value for each constant-RHS D-equation.
function _eval_assembly(A_ij::Matrix{Float64}, dst_areas::Vector{Float64}, F_src::Vector{Float64};
                        atol::Float64=1e-12)
    n = length(dst_areas)
    ics = Dict(("A_j[$j]" => 0.0 for j in 1:n)..., ("F_tgt[$j]" => 0.0 for j in 1:n)...)
    f!, u0, p, _, vmap = build_evaluator(
        _apply_only_esm(); model_name="ApplyOnly", initial_conditions=ics,
        const_arrays=Dict("A_ij" => A_ij, "F_src" => F_src, "dst_areas" => dst_areas),
        parameter_overrides=Dict("atol" => atol))
    du = similar(u0); f!(du, u0, p, 0.0)
    A_j = [du[vmap["A_j[$j]"]] for j in 1:n]
    F_tgt = [du[vmap["F_tgt[$j]"]] for j in 1:n]
    return A_j, F_tgt
end

@testset "M4 conservative-regridding assembly, inline fused-leaf weights (ess-my4.4.6)" begin

    # NARROW PHASE through the evaluator: A_ij from the fused polygon_intersection_area
    # leaf over the bin-skolem candidate set, driven by build_evaluator from the
    # fixture's own geometry.
    A_ij, F_src, candidate_pairs = _build_Aij_via_evaluator()
    dst_areas = vec(sum(A_ij; dims=1))   # column sums = A_j = dst_areas
    src_areas = vec(sum(A_ij; dims=2))   # row sums = source cell areas

    @testset "fixture loads (schema + structural)" begin
        @test isfile(_ASM_FIXTURE)
        @test (ESS.load(_ASM_FIXTURE); true)
    end

    # A_ij PROVENANCE — the fixture must DECLARE the weights from geometry in-file via
    # the FUSED leaf: A_ij is a geometry-derived observed (NOT a supplied const), its
    # aggregate body is polygon_intersection_area(src_poly[i], tgt_poly[j]) with NO
    # exposed clip ring, and it carries the bin-skolem candidate join.
    @testset "A_ij is declared INLINE via the fused polygon_intersection_area leaf" begin
        raw = _asm_raw()
        vars = _asm_vars(raw)
        # geometry is declared in-file as `const` vertex rings / a spatial field.
        @test vars["src_poly"]["expression"]["op"] == "const"
        @test vars["tgt_poly"]["expression"]["op"] == "const"
        @test vars["F_src"]["expression"]["op"] == "const"
        # A_ij is a geometry-derived observed aggregate, NOT a supplied parameter/const.
        @test vars["A_ij"]["type"] == "observed"
        @test vars["A_ij"]["expression"]["op"] == "aggregate"
        @test !haskey(vars["A_ij"], "value")
        # the narrow phase is the FUSED leaf: A_ij body = polygon_intersection_area(...).
        pias = _find_ops(vars["A_ij"]["expression"], "polygon_intersection_area")
        @test length(pias) == 1
        @test pias[1]["manifold"] == "planar"
        refs = Set{String}()
        for iv in _find_ops(pias[1], "index")
            iv["args"][1] isa AbstractString && push!(refs, String(iv["args"][1]))
        end
        @test "src_poly" in refs && "tgt_poly" in refs
        # the fused leaf hides the ring: NO intersect_polygon / clip ring survives, and
        # the old ragged-clip `clip` observed is gone.
        @test isempty(_find_ops(vars["A_ij"]["expression"], "intersect_polygon"))
        @test !haskey(vars, "clip")
        @test !haskey(raw["index_sets"], "clip_ring")
        # A_ij is ranged over the bin-skolem candidate pairs (join.on [[src_bin,tgt_bin]]).
        @test haskey(vars["A_ij"]["expression"], "join")
        @test vars["A_ij"]["expression"]["join"][1]["on"][1] == ["src_bin", "tgt_bin"]
        # the broad-phase bin equi-join also gates the row-sum / apply.
        @test haskey(vars["A_j"]["expression"], "join")
        @test vars["A_j"]["expression"]["join"][1]["on"][1] == ["src_bin", "tgt_bin"]
        @test haskey(vars["A_j"]["expression"], "filter")
    end

    # The WHOLE-MESH fused-leaf narrow phase (ONE build_evaluator call over the entire
    # src × tgt aggregate) built the expected sparse overlap-area matrix from the
    # fixture's OWN geometry: a within-bin refinement overlap pattern, zero across bins,
    # full source coverage (row sums = cell areas = 1) ⇒ conservation exact.
    # Definitionally cross-checked against the standalone intersect_polygon+polygon_area
    # kernels (§8.6.1: the fused leaf equals them).
    @testset "narrow phase A_ij (whole-mesh fused-leaf aggregate) is the expected sparse matrix" begin
        @test A_ij ≈ [1.0 0.0 0.0 0.0;
                      0.5 0.5 0.0 0.0;
                      0.0 0.0 1.0 0.0;
                      0.0 0.0 0.5 0.5]
        @test src_areas ≈ [1.0, 1.0, 1.0, 1.0]
        @test dst_areas ≈ [1.5, 0.5, 1.5, 0.5]
        # representative fractional clip src 2 ∩ tgt 1 = 0.5 (the clip demo pair).
        @test isapprox(A_ij[_REP_I, _REP_J], 0.5; atol=1e-12)
        # the candidate set (broad phase) is exactly the two within-bin blocks.
        @test Set(candidate_pairs) == Set([(1, 1), (1, 2), (2, 1), (2, 2),
                                           (3, 3), (3, 4), (4, 3), (4, 4)])
        # fused-leaf-through-evaluator == standalone clip+area oracle (definitional).
        @test A_ij ≈ _build_Aij_standalone_oracle()
    end

    @testset "end-to-end assembly: A_j, F_tgt via the evaluable apply FAQ" begin
        A_j, F_tgt = _eval_assembly(A_ij, dst_areas, F_src)
        # (3) A_j group-by-j FAQ reproduces the geometry-derived dst_areas row-sums.
        @test A_j ≈ dst_areas
        # (4)+(5) apply + normalize: F_tgt[j] = (1/A_j[j])·Σ_i A_ij[i,j]·F_src[i].
        F_tgt_expected = [sum(A_ij[i, j] * F_src[i] for i in 1:4) / dst_areas[j] for j in 1:4]
        @test F_tgt ≈ F_tgt_expected
        @test F_tgt ≈ [40.0 / 3, 20.0, 100.0 / 3, 40.0]
    end

    # WHOLE-FIXTURE END-TO-END through ONE build_evaluator call: the fixture's own
    # broad phase (bin-skolem value invention), whole-mesh fused-leaf narrow phase
    # (A_ij at setup), row-sum / normalize (A_j / W_ij at setup) and apply ODEs all
    # run together — no per-part harness, no host-supplied A_ij. A_j_check (= A_j) and
    # F_tgt are read straight off the integrated states. This is the fixture built as
    # ONE whole-mesh aggregate; it must reproduce the apply-FAQ A_j / F_tgt exactly.
    @testset "WHOLE fixture builds + evaluates end-to-end (one build_evaluator call)" begin
        A_j_e2e, F_tgt_e2e = _build_fixture_end_to_end()
        @test A_j_e2e ≈ dst_areas
        @test A_j_e2e ≈ [1.5, 0.5, 1.5, 0.5]
        @test F_tgt_e2e ≈ [40.0 / 3, 20.0, 100.0 / 3, 40.0]
        # conservation Σ_j A_j·F_tgt = Σ_i A_i·F_src = 100, straight from the fixture.
        @test isapprox(sum(A_j_e2e .* F_tgt_e2e), 100.0; rtol=1e-12)
        # partition-of-unity Σ_i W_ij = Σ_i A_ij / A_j = 1 for every target cell.
        for j in 1:4
            @test isapprox(sum(A_ij[i, j] for i in 1:4) / A_j_e2e[j], 1.0; rtol=1e-12, atol=1e-12)
        end
    end

    # ACCEPTANCE INVARIANT 1 — CONSERVATION (§5.8.3): the global remapped mass
    # equals the source mass. Σ_j A_j·F_tgt[j] = Σ_i A_i·F_src[i] exactly because
    # the target grid fully tiles each source cell (row sums = cell areas).
    @testset "CONSERVATION: Σ_j A_j·F_tgt = Σ_i A_i·F_src" begin
        A_j, F_tgt = _eval_assembly(A_ij, dst_areas, F_src)
        mass_tgt = sum(A_j .* F_tgt)
        mass_src = sum(src_areas .* F_src)
        @test isapprox(mass_tgt, mass_src; rtol=1e-12, atol=1e-12)
        @test isapprox(mass_tgt, 100.0; rtol=1e-12)
    end

    # ACCEPTANCE INVARIANT 2 — PARTITION-OF-UNITY (§5.8.3): W_ij = A_ij/A_j sum to
    # 1 over each target cell, BY CONSTRUCTION, because the denominator A_j is the
    # row-sum of the SAME areas in the numerator.
    @testset "PARTITION-OF-UNITY: Σ_i W_ij = 1 for every target cell" begin
        A_j, _ = _eval_assembly(A_ij, dst_areas, F_src)
        for j in 1:4
            w_sum = sum(A_ij[i, j] for i in 1:4) / A_j[j]
            @test isapprox(w_sum, 1.0; rtol=1e-12, atol=1e-12)
        end
    end

    # The OVERLAP JOIN is load-bearing: join.on admits a contraction term only when
    # src and tgt share a bin. A spurious CROSS-bin overlap entry (src 1 ∈ b0, tgt
    # 3 ∈ b1) must be EXCLUDED by the join — proving the broad phase restricts the
    # candidate set and is not a no-op.
    @testset "bin overlap join excludes cross-bin pairs (candidate set)" begin
        contaminated = copy(A_ij)
        contaminated[1, 3] = 99.0     # src cell 1 (b0) × tgt cell 3 (b1): cross-bin
        A_j, F_tgt = _eval_assembly(contaminated, dst_areas, F_src)
        @test isapprox(A_j[3], 1.5; rtol=1e-12)               # 99.0 excluded, not 100.5
        @test isapprox(F_tgt[3], 100.0 / 3; rtol=1e-12)       # apply unaffected too
        @test isapprox(sum(A_j .* F_tgt), 100.0; rtol=1e-12)  # conservation holds
    end

    # The ZERO-AREA FILTER is load-bearing: filter A_ij > atol drops sub-atol
    # slivers, turning the byte-identical CANDIDATE set into the tolerance-dependent
    # SURVIVING-overlap set (§5.8.5). A WITHIN-bin sliver (src 1 ∈ b0, tgt 2 ∈ b0)
    # below atol must be dropped.
    @testset "zero-area filter drops sub-atol within-bin slivers (surviving set)" begin
        slivered = copy(A_ij)
        slivered[1, 2] = 1e-6         # src 1 (b0) × tgt 2 (b0): within-bin sliver
        A_j, _ = _eval_assembly(slivered, dst_areas, F_src; atol=1e-3)
        @test isapprox(A_j[2], 0.5; rtol=1e-12)               # atol above ⇒ dropped
        A_j_admit, _ = _eval_assembly(slivered, dst_areas, F_src; atol=1e-12)
        @test isapprox(A_j_admit[2], 0.5 + 1e-6; rtol=1e-9)   # atol below ⇒ admitted
    end
end
