# Cell-axis arrays under the projection-pushdown rewrite (CONFORMANCE_SPEC
# §5.5.7 "Cell-axis arrays"). The Julia half of the pair; the Python mirror is
# `earthsci-ast-py/tests/test_pushdown_cell_geometry.py`.
#
# The rewrite re-points a binning aggregate's reduction range onto the compact
# derived support set, which RENUMBERS the cell symbol: after it fires, that
# symbol counts support positions and support position i is grid cell
# member_factor[i]. Every array the body reads through it must be renumbered
# with it — not only the four envelope bounds of the containment predicate.
#
# Polygon allocation is the shape that makes the difference visible. Its weight
# is `polygon_intersection_area(cell_ring[c], rec_ring[r]) / cell_area[c]`, so
# the body reads a rank-3 [cells, vertex, xy] ring stack and a rank-1 area, and
# neither is an envelope factor. Gathering only the envelopes leaves both
# pointing at the full grid while the axis is compact: full-grid values read at
# support positions, wrong numbers, no diagnostic anywhere.

module PushdownCellGeometryTests

using Test
using EarthSciAST
const EA = EarthSciAST

_ix(f, idx...) = Dict{String,Any}("op" => "index", "args" => Any[f, idx...])
_op(o, args...) = Dict{String,Any}("op" => o, "args" => Any[args...])
_param(shape) = Dict{String,Any}("type" => "parameter", "default" => 0.0,
                                 "shape" => Any[shape...])

_ring(x0, y0, x1, y1) = [[x0, y0], [x1, y0], [x1, y1], [x0, y1], [x0, y0]]

# A 2×2 grid of unit cells over [0,2]².
const CW = [0.0, 1.0, 0.0, 1.0]
const CS = [0.0, 0.0, 1.0, 1.0]
const CE = [1.0, 2.0, 1.0, 2.0]
const CN = [1.0, 1.0, 2.0, 2.0]
# Record 1 straddles cells 1 and 2; record 2 sits inside cell 4; record 3 is off
# the grid entirely, so it contributes to no cell and joins no support member.
const RECS = [(0.5, 0.25, 1.5, 0.75), (1.2, 1.2, 1.8, 1.8), (5.0, 5.0, 6.0, 6.0)]
const EMIS = [10.0, 4.0, 7.0]
const SR = [1.0 0.5; 2.0 0.25; 3.0 0.125; 4.0 0.0625]
# Cells 1 and 2 each take a quarter of record 1's 0.5 area; cell 4 takes all of
# record 2's 0.36; cell 3 is met by nothing.
const EXPECT_E = [10.0 * 0.25, 10.0 * 0.25, 0.0, 4.0 * 0.36]

_env_overlap() = _op("and",
    _op("<=", _ix("src_W", "c"), _ix("rec_xmax", "r")),
    _op("<=", _ix("rec_xmin", "r"), _ix("src_E", "c")),
    _op("<=", _ix("src_S", "c"), _ix("rec_ymax", "r")),
    _op("<=", _ix("rec_ymin", "r"), _ix("src_N", "c")))

# The polygon-allocation document: an envelope broad phase, an intersection area
# for the narrow phase, and a data-fed SR array for the mat-vec.
function _doc()
    v = Dict{String,Any}()
    for n in ("src_W", "src_S", "src_E", "src_N", "cell_area")
        v[n] = _param(["src_cells"])
    end
    for n in ("rec_xmin", "rec_ymin", "rec_xmax", "rec_ymax", "emis_annual")
        v[n] = _param(["emis_records"])
    end
    v["cell_ring"] = _param(["src_cells", "ring_vertex", "xy"])
    v["rec_ring"]  = _param(["emis_records", "ring_vertex", "xy"])
    v["SR_PM25"] = Dict{String,Any}(
        "type" => "parameter", "default" => 0.0, "units" => "1",
        "shape" => Any["src_cells", "rcv_cells"],
        "update" => Dict{String,Any}("kind" => "data", "source" => "MockSR",
                                     "from" => Dict("file_variable" => "PM25")))
    v["E_PM25"] = Dict{String,Any}("type" => "unknown", "shape" => Any["src_cells"])
    v["conc_PM25"] = Dict{String,Any}("type" => "unknown", "shape" => Any["rcv_cells"])

    E_body = _op("*",
        _op("ifelse", _env_overlap(), 1.0, 0.0),
        _op("*", _ix("emis_annual", "r"),
                 _op("/", Dict{String,Any}("op" => "polygon_intersection_area",
                                           "manifold" => "planar",
                                           "args" => Any[_ix("cell_ring", "c"),
                                                         _ix("rec_ring", "r")]),
                          _ix("cell_area", "c"))))
    eqs = Any[
        Dict{String,Any}("lhs" => "E_PM25", "rhs" => Dict{String,Any}(
            "op" => "aggregate", "reduce" => "+", "output_idx" => Any["c"],
            "ranges" => Dict{String,Any}("c" => Dict("from" => "src_cells"),
                                         "r" => Dict("from" => "emis_records")),
            "args" => Any["src_W", "src_S", "src_E", "src_N",
                          "rec_xmin", "rec_ymin", "rec_xmax", "rec_ymax",
                          "cell_ring", "cell_area", "rec_ring", "emis_annual"],
            "expr" => E_body)),
        Dict{String,Any}("lhs" => "conc_PM25", "rhs" => Dict{String,Any}(
            "op" => "aggregate", "reduce" => "+", "output_idx" => Any["rcv"],
            "ranges" => Dict{String,Any}("rcv" => Dict("from" => "rcv_cells"),
                                         "s" => Dict("from" => "src_cells")),
            "args" => Any["SR_PM25", "E_PM25"],
            "expr" => _op("*", _ix("SR_PM25", "s", "rcv"), _ix("E_PM25", "s")))),
    ]
    return Dict{String,Any}(
        "esm" => "1.0.0",
        "metadata" => Dict{String,Any}("name" => "pushdown_cell_geometry"),
        "data_sources" => Dict{String,Any}("MockSR" => Dict{String,Any}(
            "kind" => "static", "source" => Dict("url_template" => "mock://sr"))),
        "index_sets" => Dict{String,Any}(
            "src_cells"    => Dict("kind" => "interval", "size" => 4),
            "rcv_cells"    => Dict("kind" => "interval", "size" => 2),
            "emis_records" => Dict("kind" => "interval", "size" => 3),
            "ring_vertex"  => Dict("kind" => "interval", "size" => 5),
            "xy"           => Dict("kind" => "interval", "size" => 2)),
        "models" => Dict{String,Any}("Binned" =>
            Dict{String,Any}("variables" => v, "equations" => eqs)))
end

# A binning body carrying `polygon_intersection_area` is SETUP-TIME geometry, so
# its result is materialized into `insp.setup_arrays` rather than left as a
# build-time observed. Read whichever the engine chose.
# The plain public read. It used to be unusable on this document: a body
# carrying a geometry leaf is materialized into `insp.setup_arrays` at setup,
# and so, transitively, is everything downstream of it, so `observed_field`
# refused every observed here with "not a build-time-evaluable observed" while
# the build had computed all of them. `observed_field` now falls back to the
# build's own materialized arrays; this alias is what pins that it does.
_field(prep, insp, name::AbstractString) = EA.observed_field(prep, insp, name)

_defs(out) = Dict(String(e["lhs"]) => e["rhs"]
                  for e in out["models"]["Binned"]["equations"]
                  if get(e, "lhs", nothing) isa AbstractString)

# Every `index(F, …)` base name reachable from `node`.
function _bases!(node, out::Set{String})
    if node isa AbstractDict
        if get(node, "op", nothing) == "index"
            a = get(node, "args", nothing)
            a isa AbstractVector && !isempty(a) && a[1] isa AbstractString &&
                push!(out, String(a[1]))
        end
        for v in values(node); _bases!(v, out); end
    elseif node isa AbstractVector
        for x in node; _bases!(x, out); end
    end
    return out
end

function _find_pia(node, out::Vector{Any})
    if node isa AbstractDict
        get(node, "op", nothing) == "polygon_intersection_area" && push!(out, node)
        for v in values(node); _find_pia(v, out); end
    elseif node isa AbstractVector
        for x in node; _find_pia(x, out); end
    end
    return out
end

# ---- provider mock ---------------------------------------------------------
mutable struct MockGatedPoly
    full::Matrix{Float64}
    calls::Vector{Any}
end
EA.provider_refresh_times(::MockGatedPoly) = Float64[]
EA.provider_supports_selection(::MockGatedPoly) = true
function EA.provider_sample(m::MockGatedPoly, ::Real; selection=nothing)
    if selection === nothing
        push!(m.calls, (:wholesale,))
        return m.full
    end
    push!(m.calls, (:selection, deepcopy(selection)))
    return m.full[selection[1], selection[2]]
end

@testset "pushdown: every cell-axis array is gathered, rank-preserving" begin
    out = EA.desugar_pushdown(_doc(); model_name="Binned")
    @test out !== nothing
    v = out["models"]["Binned"]["variables"]
    gathers = Dict(k => v[k]["shape"] for k in keys(v) if startswith(k, "pd_cell__"))
    @test Set(keys(gathers)) == Set([
        "pd_cell__src_cells__src_W", "pd_cell__src_cells__src_S",
        "pd_cell__src_cells__src_E", "pd_cell__src_cells__src_N",
        "pd_cell__src_cells__cell_area", "pd_cell__src_cells__cell_ring"])

    # RANK-PRESERVING: only the FIRST axis moves onto the derived set.
    @test gathers["pd_cell__src_cells__cell_ring"] ==
          Any["pd_support__src_cells", "ring_vertex", "xy"]
    @test gathers["pd_cell__src_cells__cell_area"] == Any["pd_support__src_cells"]

    defs = _defs(out)
    ring = defs["pd_cell__src_cells__cell_ring"]
    # A MAP, not a reduction: every range is an output index.
    @test ring["output_idx"] == Any["c", "pd_t0", "pd_t1"]
    @test Set(keys(ring["ranges"])) == Set(["c", "pd_t0", "pd_t1"])
    @test ring["ranges"]["pd_t0"]["from"] == "ring_vertex"
    @test ring["ranges"]["pd_t1"]["from"] == "xy"
    @test ring["expr"]["args"][1] == "cell_ring"
    @test ring["expr"]["args"][3:end] == Any["pd_t0", "pd_t1"]
    # The rank-1 arm is byte-identical to what it always emitted.
    @test defs["pd_cell__src_cells__src_W"]["output_idx"] == Any["c"]
end

@testset "pushdown: the body's cell reads follow the envelopes onto the gathers" begin
    out = EA.desugar_pushdown(_doc(); model_name="Binned")
    body = _defs(out)["E_PM25"]
    @test body["ranges"]["c"]["from"] == "pd_support__src_cells"

    bases = _bases!(body, Set{String}())
    # NOTHING in the rewritten body still reads a full-grid cell-axis array.
    @test isempty(intersect(bases, Set(["cell_ring", "cell_area",
                                        "src_W", "src_S", "src_E", "src_N"])))
    @test "pd_cell__src_cells__cell_ring" in bases
    @test "pd_cell__src_cells__cell_area" in bases

    # The polygon operand keeps its SLICED spelling: the base name changed and
    # nothing else did, which is what rank preservation buys.
    pia = _find_pia(body, Any[])
    @test length(pia) == 1
    @test pia[1]["args"][1] == _ix("pd_cell__src_cells__cell_ring", "c")
    @test pia[1]["args"][2] == _ix("rec_ring", "r")
end

@testset "pushdown: a computed cell position is refused loudly" begin
    # A cell-axis array read at `c + 1` cannot be re-pointed: the compact axis is
    # a renumbering and no arithmetic on a support position survives it. A hard
    # error naming the array and the subscript — declining silently would hide an
    # ungated fetch, and emitting anyway would be wrong numbers.
    doc = _doc()
    body = doc["models"]["Binned"]["equations"][1]["rhs"]["expr"]
    body["args"][2]["args"][2]["args"][2] = _ix("cell_area", _op("+", "c", 1))
    err = try
        EA.desugar_pushdown(doc; model_name="Binned")
        nothing
    catch e
        e
    end
    @test err !== nothing
    msg = sprint(showerror, err)
    @test occursin("cell_area", msg)
    @test occursin("+(c, 1)", msg)
    @test occursin("COMPUTED cell position", msg)
end

@testset "pushdown: an array off the cell axis is left alone" begin
    # A flat-offset gather into ANOTHER axis is not on the cell axis: it stays
    # full-grid, and it is still correct after the rewrite because nothing about
    # it moved. Gathering it would be the bug in the other direction.
    doc = _doc()
    doc["index_sets"]["all_cells"] = Dict("kind" => "interval", "size" => 8)
    m = doc["models"]["Binned"]
    m["variables"]["temperature"] = _param(["all_cells"])
    rhs = m["equations"][1]["rhs"]
    push!(rhs["args"], "temperature")
    rhs["expr"] = _op("*", rhs["expr"], _ix("temperature", _op("+", "c", 4)))

    out = EA.desugar_pushdown(doc; model_name="Binned")
    @test !haskey(out["models"]["Binned"]["variables"], "pd_cell__src_cells__temperature")
    @test "temperature" in _bases!(_defs(out)["E_PM25"], Set{String}())
end

@testset "pushdown: rewritten polygon allocation matches the dense evaluation" begin
    ca = Dict{String,Any}(
        "src_W" => CW, "src_S" => CS, "src_E" => CE, "src_N" => CN,
        "cell_area" => fill(1.0, 4),
        "cell_ring" => cat([permutedims(hcat(_ring(CW[c], CS[c], CE[c], CN[c])...))
                            for c in 1:4]...; dims=3),
        "rec_ring" => cat([permutedims(hcat(_ring(r...)...)) for r in RECS]...; dims=3),
        "rec_xmin" => [r[1] for r in RECS], "rec_ymin" => [r[2] for r in RECS],
        "rec_xmax" => [r[3] for r in RECS], "rec_ymax" => [r[4] for r in RECS],
        "emis_annual" => EMIS)
    # `cat(…; dims=3)` stacks along the LAST axis; the declaration is
    # [cells, vertex, xy], so bring the stacking axis to the front.
    ca["cell_ring"] = permutedims(ca["cell_ring"], (3, 1, 2))
    ca["rec_ring"] = permutedims(ca["rec_ring"], (3, 1, 2))
    # The flattened consumer is `<Model>.<parameter>`. The pushdown path aliases
    # bare keys onto it; the dense path does not, so both spellings are supplied.
    for (k, v) in collect(ca)
        ca["Binned." * k] = v
    end

    # --- dense reference: no rewrite, SR an ordinary const array -------------
    dense_ca = merge(ca, Dict{String,Any}("SR_PM25" => SR, "Binned.SR_PM25" => SR))
    dense_insp = EA.BuildInspection()
    dense = EA.prepare(_doc(); const_arrays=dense_ca, inspect=dense_insp)
    E_dense = _field(dense, dense_insp, "E_PM25")
    conc_dense = _field(dense, dense_insp, "conc_PM25")
    # The dense arm is itself checked against a hand oracle, so a shared bug in
    # both arms cannot pass this test by agreeing with itself.
    @test E_dense ≈ EXPECT_E
    @test conc_dense ≈ vec(permutedims(EXPECT_E) * SR)

    # --- rewritten: SR gated, cell_ring gathered onto the support axis -------
    g = MockGatedPoly(SR, Any[])
    insp = EA.BuildInspection()
    prep = EA.prepare(_doc(); const_arrays=ca,
                      providers=Dict{String,Any}("Binned.SR_PM25" => g),
                      inspect=insp, pushdown_rewrite=true)
    mf = Int.(insp.const_arrays["pd_member_factor__src_cells"])
    @test mf == [1, 2, 4]                     # 1-based; cell 3 is met by nothing
    @test _field(prep, insp, "E_PM25") ≈ EXPECT_E[mf]
    @test _field(prep, insp, "conc_PM25") ≈ conc_dense

    # And the gate did its job: the SR rows were selected, not taken wholesale.
    @test isempty([c for c in g.calls if c[1] == :wholesale])
    sel = [c for c in g.calls if c[1] == :selection]
    @test length(sel) == 1 && sel[1][2][1] == [1, 2, 4]

    # The reported chain here is ENTIRELY setup-materialized — the geometry
    # weight makes `E_PM25` a setup array, and `conc_PM25` folds against it —
    # so these reads exercise `observed_field`'s materialized-array fallback and
    # nothing else. Both spellings must agree with the array the build used, and
    # a name that is not an observed must still be refused rather than answered
    # out of the const-array registry (`SR_PM25` is a PARAMETER).
    @test EA.observed_field(prep, insp, "E_PM25") ≈ insp.setup_arrays["Binned.E_PM25"]
    @test EA.observed_field(prep, insp, "conc_PM25") ≈ insp.setup_arrays["Binned.conc_PM25"]
    @test_throws EA.SimulateError EA.observed_field(prep, insp, "SR_PM25")
    @test_throws EA.SimulateError EA.observed_field(prep, insp, "no_such_thing")
end

end # module PushdownCellGeometryTests
