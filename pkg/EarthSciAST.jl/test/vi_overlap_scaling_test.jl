# Value-invention OVERLAP-gate producer SCALING (projection-pushdown Wall #1).
#
# A producer gated by `join.overlap` used to enumerate the FULL cartesian product
# of its ranges (here points × cells) and membership-test each tuple against the
# prebuilt broad-phase candidate set — O(N_point·N_cell). At ISRM scale
# (emis_records × 596444 pop_cells) that is ~7 hours. The fix drives enumeration
# from the candidate pairs directly: O(|candidates|).
#
# This fixture lays 20000 unit cells on a 200×100 grid and drops 200 points, each
# at a DISTINCT cell centre (strict interior → exactly one broad candidate, kept
# by the rectangle narrow `filter`). It asserts:
#   (a) the materialised `distinct` member set == an INDEPENDENT brute-force
#       point-in-cell computation (correctness), AND
#   (b) the producer VISITED ~O(|candidates|)=200 tuples — not O(200·20000)=4e6 —
#       and completes in well under a couple seconds (the scaling fix).
# It also confirms the candidate-set CONSTRUCTION takes the STRtree fast path.

using Test
using EarthSciAST
import JSON3
using Random
# These four weakdeps load EarthSciASTGeometryOpsExt → the STRtree fast path for
# the broad phase (so candidate construction is O(N log N), not O(N·M)). All four
# are the extension's trigger set, imported explicitly so the fast path is
# exercised even when this file runs standalone.
import GeometryOps
import GeoInterface
import SortTileRecursiveTree
import Extents

const ESS = EarthSciAST

# ---- small JSON AST builders (mirroring overlap_gate_conformance_test.jl) ----
_ix(f, args...) = Dict("op" => "index", "args" => Any[f, args...])
_op(o, args...) = Dict("op" => o, "args" => Any[args...])

@testset "VI overlap-gate producer scaling (Wall #1)" begin

    # STRtree fast path is available (ext loaded) → candidate construction is the
    # O(N log N) dual-tree descent, not the O(N·M) brute pass.
    @test hasmethod(ESS.build_spatial_index, Tuple{AbstractVector})

    # ---- grid of cells + points at distinct cell centres ------------------
    Random.seed!(0xC0FFEE)
    gx, gy = 200, 100
    ncells = gx * gy                      # 20000
    npts   = 200
    CW = Vector{Float64}(undef, ncells); CS = similar(CW)
    CE = similar(CW);                      CN = similar(CW)
    cell_ab = Vector{Tuple{Int,Int}}(undef, ncells)
    for k in 1:ncells
        a = (k - 1) ÷ gy                  # column 0..gx-1
        b = (k - 1) % gy                  # row    0..gy-1
        CW[k] = a; CE[k] = a + 1
        CS[k] = b; CN[k] = b + 1
        cell_ab[k] = (a, b)
    end
    chosen = randperm(ncells)[1:npts]     # distinct cells → distinct point cells
    PX = Vector{Float64}(undef, npts); PY = similar(PX)
    for p in 1:npts
        a, b = cell_ab[chosen[p]]
        PX[p] = a + 0.5; PY[p] = b + 0.5  # strict interior of exactly one cell
    end

    const_arrays = Dict{String,Any}(
        "X" => PX, "Y" => PY, "W" => CW, "S" => CS, "E" => CE, "N" => CN)

    # ---- candidate set construction: O(N log N) STRtree, |cands| == npts ---
    tcands = @elapsed cands =
        ESS._overlap_candidate_set(["X", "Y"], ["W", "S", "E", "N"], const_arrays; eps=0.0)
    # each point centre intersects exactly ONE closed cell envelope
    @test length(cands) == npts
    @test tcands < 2.0

    # ---- independent brute-force ORACLE (point strictly inside cell) -------
    true_cells = Set{Int}()
    for p in 1:npts, c in 1:ncells
        if CW[c] < PX[p] < CE[c] && CS[c] < PY[p] < CN[c]
            push!(true_cells, c)
        end
    end
    oracle = sort!(collect(true_cells))
    @test length(oracle) == npts          # distinct cells ⇒ npts containments

    # (X-W)(E-X)(Y-S)(N-Y) > 0 : strict rectangle-interior narrow phase.
    _filter = _op(">",
        _op("*",
            _op("*", _op("-", _ix("X", "i"), _ix("W", "j")),
                     _op("-", _ix("E", "j"), _ix("X", "i"))),
            _op("*", _op("-", _ix("Y", "i"), _ix("S", "j")),
                     _op("-", _ix("N", "j"), _ix("Y", "i")))),
        0.0)

    _mkdoc(np, nc) = Dict(
        "esm" => "0.6.0",
        "metadata" => Dict("name" => "vi_overlap_scaling"),
        "index_sets" => Dict(
            "points" => Dict("kind" => "interval", "size" => np),
            "cells"  => Dict("kind" => "interval", "size" => nc),
            "present_cells" => Dict("kind" => "derived", "from_faq" => "scaling_producer")),
        "models" => Dict("ScalingPIR" => Dict(
            "variables" => Dict(
                "X" => Dict("type" => "parameter", "shape" => ["points"]),
                "Y" => Dict("type" => "parameter", "shape" => ["points"]),
                "W" => Dict("type" => "parameter", "shape" => ["cells"]),
                "S" => Dict("type" => "parameter", "shape" => ["cells"]),
                "E" => Dict("type" => "parameter", "shape" => ["cells"]),
                "N" => Dict("type" => "parameter", "shape" => ["cells"]),
                "cell_present" => Dict("type" => "state", "shape" => ["present_cells"])),
            "equations" => [Dict(
                "lhs" => _ix("cell_present", "m"),
                "rhs" => Dict(
                    "op" => "aggregate",
                    "id" => "scaling_producer",
                    "semiring" => "bool_and_or",
                    "distinct" => true,
                    "output_idx" => ["m"],
                    "ranges" => Dict("i" => Dict("from" => "points"),
                                     "j" => Dict("from" => "cells")),
                    "join" => [Dict("overlap" => Dict(
                        "src_env" => ["X", "Y"],
                        "tgt_env" => ["W", "S", "E", "N"],
                        "eps" => 0.0))],
                    "filter" => _filter,
                    "args" => ["X", "Y", "W", "S", "E", "N"],
                    "key" => Dict("op" => "skolem", "label" => "cell", "args" => ["j"]),
                    "expr" => Dict("op" => "true", "args" => [])))])))

    bigdoc = _mkdoc(npts, ncells)
    file = ESS.coerce_esm_file(JSON3.read(JSON3.write(bigdoc)))
    model = ESS._select_model(file, "ScalingPIR")

    # WARM UP the whole front door on a TINY same-typed fixture so the timed run
    # below measures runtime, not JIT.
    let sm = _mkdoc(2, 4)
        sf = ESS.coerce_esm_file(JSON3.read(JSON3.write(sm)))
        smodel = ESS._select_model(sf, "ScalingPIR")
        sconst = Dict{String,Any}("X" => [0.5, 2.5], "Y" => [0.5, 2.5],
            "W" => [0.0, 1.0, 2.0, 3.0], "S" => [0.0, 0.0, 0.0, 0.0],
            "E" => [1.0, 2.0, 3.0, 4.0], "N" => [1.0, 1.0, 1.0, 1.0])
        ESS.materialize_value_invention(smodel, sf.index_sets, sconst, Dict{String,Any}())
    end

    # ---- TIMED, INSTRUMENTED materialisation ------------------------------
    ESS._VI_ENUM_VISITS[] = 0
    twall = @elapsed vi =
        ESS.materialize_value_invention(model, file.index_sets, const_arrays, Dict{String,Any}())
    visits = ESS._VI_ENUM_VISITS[]

    # (a) correctness — materialised set == independent brute-force oracle
    @test sort(collect(vi.members["scaling_producer"])) == oracle
    @test vi.extents["scaling_producer"] == npts

    # (b) scaling — visited O(|candidates|), NOT O(npts·ncells)
    @test visits == npts                       # candidate-driven, no ungated ranges
    @test visits < ncells                      # ≪ even a single full cell sweep
    @test visits < npts * ncells ÷ 100         # ≪ 4e6 full product
    @test twall < 2.0                          # fast wall-time (post-warmup)
end
