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

# Wrapped in a module so this file's local AST-builder helpers (`_op`, `_ix`, …)
# stay isolated from other test files' identically-named helpers in the shared
# `Main` namespace — otherwise `array_ops_test.jl`'s more-specific
# `_op(::AbstractString, …)` (which builds `ASTExpr[…]`) shadows the Dict-based
# `_op` below and dispatch fails with a Dict→ASTExpr convert error.
module VIOverlapScalingTests

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
                "cell_present" => Dict("type" => "unknown", "shape" => ["present_cells"])),
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

# ===========================================================================
# DENSE-AGGREGATE scaling — §5.5.6: the gate drives ANY aggregate, not only a
# `distinct` producer.
#
# Same geometry as above (20000 cells, 200 points, each point strictly inside
# exactly one cell), but now the gate rides an ORDINARY `+`-semiring aggregate.
# Two orientations, both of which used to walk the full product and reject every
# non-candidate tuple with a membership test:
#
#   (A) MIRRORED — a main-graph `P[p] = Σ_c […]` reducing over CELLS. Full
#       product 200·20000 = 4e6.
#   (B) FORWARD  — the projection-pushdown rewrite's own `E[c] = Σ_r […]` after
#       `desugar_pushdown` re-points it onto the compact support axis and gates
#       it on the generated `pd_cell__*` envelopes. Full product |support|·|records|.
#
# Each asserts the VISIT COUNT (`_VI_ENUM_VISITS`, now instrumented on the dense
# path too) and, independently, that the values equal a plain-Julia oracle — the
# driver must remove work without moving a number.
# ===========================================================================
@testset "overlap-gated DENSE aggregate scaling (both orientations)" begin
    Random.seed!(0xC0FFEE)
    gx, gy = 200, 100
    ncells = gx * gy
    npts = 200
    CW = Vector{Float64}(undef, ncells); CS = similar(CW)
    CE = similar(CW);                      CN = similar(CW)
    cell_ab = Vector{Tuple{Int,Int}}(undef, ncells)
    for k in 1:ncells
        a = (k - 1) ÷ gy; b = (k - 1) % gy
        CW[k] = a; CE[k] = a + 1; CS[k] = b; CN[k] = b + 1
        cell_ab[k] = (a, b)
    end
    chosen = randperm(ncells)[1:npts]
    PX = Vector{Float64}(undef, npts); PY = similar(PX)
    for p in 1:npts
        a, b = cell_ab[chosen[p]]
        PX[p] = a + 0.5; PY[p] = b + 0.5
    end

    # the rectangle-containment predicate, cell symbol `c`, record symbol `r`
    _contain(csym, rsym) = _op("and",
        _op("<=", _ix("W", csym), _ix("X", rsym)), _op("<", _ix("X", rsym), _ix("E", csym)),
        _op("<=", _ix("S", csym), _ix("Y", rsym)), _op("<", _ix("Y", rsym), _ix("N", csym)))

    # ---- (A) MIRRORED orientation on the MAIN GRAPH ----------------------
    _rectvars = Dict(
        "X" => Dict("type" => "parameter", "shape" => ["points"]),
        "Y" => Dict("type" => "parameter", "shape" => ["points"]),
        "W" => Dict("type" => "parameter", "shape" => ["cells"]),
        "S" => Dict("type" => "parameter", "shape" => ["cells"]),
        "E" => Dict("type" => "parameter", "shape" => ["cells"]),
        "N" => Dict("type" => "parameter", "shape" => ["cells"]))
    _mirror_doc(np, nc) = Dict(
        "esm" => "0.6.0",
        "metadata" => Dict("name" => "dense_overlap_mirror"),
        "index_sets" => Dict("points" => Dict("kind" => "interval", "size" => np),
                             "cells"  => Dict("kind" => "interval", "size" => nc)),
        "models" => Dict("Mirror" => Dict(
            "variables" => merge(_rectvars,
                Dict("P" => Dict("type" => "unknown", "shape" => ["points"]))),
            "equations" => [Dict(
                "lhs" => Dict("op" => "aggregate", "args" => [], "output_idx" => ["p"],
                    "expr" => Dict("op" => "D", "args" => [_ix("P", "p")], "wrt" => "t"),
                    "ranges" => Dict("p" => [1, np])),
                "rhs" => Dict("op" => "aggregate", "semiring" => "sum_product",
                    "output_idx" => ["p"],
                    "ranges" => Dict("p" => Dict("from" => "points"),
                                     "c" => Dict("from" => "cells")),
                    "join" => [Dict("overlap" => Dict(
                        "src_env" => ["X", "Y"], "tgt_env" => ["W", "S", "E", "N"],
                        "eps" => 0.0))],
                    "filter" => _op("and",
                        _op("<=", _ix("W", "c"), _ix("X", "p")),
                        _op("<", _ix("X", "p"), _ix("E", "c")),
                        _op("<=", _ix("S", "c"), _ix("Y", "p")),
                        _op("<", _ix("Y", "p"), _ix("N", "c"))),
                    "args" => ["X", "Y", "W", "S", "E", "N"],
                    "expr" => _op("+", _ix("W", "c"), _ix("S", "c"))))])))

    _mca(np, nc) = Dict{String,Any}("X" => PX[1:np], "Y" => PY[1:np],
        "W" => CW[1:nc], "S" => CS[1:nc], "E" => CE[1:nc], "N" => CN[1:nc])

    # warm the whole front door on a tiny same-typed fixture (JIT, not runtime)
    let sm = Dict(
            "esm" => "0.6.0", "metadata" => Dict("name" => "dense_overlap_mirror"),
            "index_sets" => Dict("points" => Dict("kind" => "interval", "size" => 1),
                                 "cells"  => Dict("kind" => "interval", "size" => 2)),
            "models" => _mirror_doc(1, 2)["models"])
        ESS.build_evaluator(sm; model_name="Mirror",
            const_arrays=Dict{String,Any}("X" => [0.5], "Y" => [0.5],
                "W" => [0.0, 1.0], "S" => [0.0, 0.0],
                "E" => [1.0, 2.0], "N" => [1.0, 1.0]))
    end

    ESS._VI_ENUM_VISITS[] = 0
    tmir = @elapsed f!, u0, pp, _, vmap =
        ESS.build_evaluator(_mirror_doc(npts, ncells); model_name="Mirror",
                            const_arrays=_mca(npts, ncells))
    mir_visits = ESS._VI_ENUM_VISITS[]

    du = similar(u0); f!(du, u0, pp, 0.0)
    got = [du[vmap["P[$p]"]] for p in 1:npts]
    oracle = [Float64(cell_ab[chosen[p]][1] + cell_ab[chosen[p]][2]) for p in 1:npts]
    @test got == oracle                        # EXACT — one term per record
    # one candidate per point ⇒ the driver visits `npts` tuples, not npts·ncells
    @test mir_visits == npts
    @test mir_visits < npts * ncells ÷ 1000    # 200 vs 4_000_000
    @test tmir < 120.0

    # ---- (B) FORWARD orientation, through the pushdown REWRITE -------------
    _param(shape) = Dict("type" => "parameter", "default" => 0.0, "shape" => shape)
    _obs(shape, e) = Dict("type" => "observed", "shape" => shape, "expression" => e)
    _binagg = Dict("op" => "aggregate", "output_idx" => ["c"], "reduce" => "+",
        "ranges" => Dict("c" => Dict("from" => "cells"), "r" => Dict("from" => "points")),
        "args" => ["W", "S", "E", "N", "X", "Y", "annual"],
        "expr" => _op("*", _op("ifelse", _contain("c", "r"), 1.0, 0.0),
                      _ix("annual", "r")))
    _concagg = Dict("op" => "aggregate", "output_idx" => ["rcv"], "reduce" => "+",
        "ranges" => Dict("s" => Dict("from" => "cells"),
                         "rcv" => Dict("from" => "rcv_cells")),
        "args" => ["SR", "Emis"],
        "expr" => _op("*", _ix("SR", "s", "rcv"), _ix("Emis", "s")))
    annual = collect(1.0:npts)
    SR = [Float64((i % 7) + j) for i in 1:ncells, j in 1:2]
    fwd_doc = Dict{String,Any}(
        "esm" => "0.9.0", "metadata" => Dict("name" => "dense_overlap_forward"),
        "index_sets" => Dict{String,Any}(
            "points" => Dict("kind" => "interval", "size" => npts),
            "cells" => Dict("kind" => "interval", "size" => ncells),
            "rcv_cells" => Dict("kind" => "interval", "size" => 2)),
        "models" => Dict{String,Any}("Fwd" => Dict{String,Any}(
            "variables" => Dict{String,Any}(
                "X" => _param(["points"]), "Y" => _param(["points"]),
                "annual" => _param(["points"]),
                "W" => _param(["cells"]), "S" => _param(["cells"]),
                "E" => _param(["cells"]), "N" => _param(["cells"]),
                "SR" => _param(["cells", "rcv_cells"]),
                "Emis" => _obs(["cells"], _binagg),
                "conc" => _obs(["rcv_cells"], _concagg)),
            "equations" => Any[])))

    rw = ESS.desugar_pushdown(fwd_doc; model_name="Fwd")
    @test rw !== fwd_doc
    Emis_expr = rw["models"]["Fwd"]["variables"]["Emis"]["expression"]
    # the rewritten binning aggregate carries the DERIVED gate, over the
    # generated compact-axis envelopes (not the full-grid rects)
    @test haskey(Emis_expr, "join")
    ov = Emis_expr["join"][1]["overlap"]
    @test ov["src_env"] == ["X", "Y"]
    @test ov["tgt_env"] == ["pd_cell__cells__W", "pd_cell__cells__S",
                            "pd_cell__cells__E", "pd_cell__cells__N"]

    fca = Dict{String,Any}("X" => PX, "Y" => PY, "annual" => annual,
        "W" => CW, "S" => CS, "E" => CE, "N" => CN, "SR" => SR)
    insp = ESS.BuildInspection()
    ESS.build_evaluator(rw; model_name="Fwd", const_arrays=fca, inspect=insp)
    nsupport = insp.derived_extents["pd_faq__cells"]
    @test nsupport == npts                     # distinct cells, one point each

    file = ESS.coerce_esm_file(rw)
    ESS._VI_ENUM_VISITS[] = 0
    fwd_field, _ = ESS._observed_field(insp, file, "Fwd", "Emis")
    fwd_visits = ESS._VI_ENUM_VISITS[]
    @test length(fwd_field) == nsupport
    # every record contributes its `annual` to exactly one support cell
    @test sum(fwd_field) == sum(annual)
    @test fwd_visits == npts
    @test fwd_visits < nsupport * npts ÷ 100   # 200 vs 40_000
end

end # module VIOverlapScalingTests
