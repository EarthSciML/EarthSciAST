# Build-time materialization of an observed's PRODUCERS
# (`_materialized_obs_scope`, pde_inline_tests.jl).
#
# `evaluate_cellwise` walks an expression once PER OUTPUT CELL, so an array
# observed inlined into its readers is re-executed at every cell of the
# consumer's field. For a chain that ends in a spatial join — emissions binned
# into cells, contracted with a source-receptor matrix, turned into a per-
# receptor field — that is the difference between evaluating the join once and
# evaluating it 52,411 times. `_materialized_obs_scope` exists to evaluate each
# producer once, in dependency order, and hand the consumer buffers.
#
# It walked `insp.observed_defs`, the UN-inlined bodies, and the build does not
# publish one for every observed: an intermediate it folded into its readers
# appears only in `observed_exprs`, the fully substituted map. So the first
# producer whose definition named such an intermediate raised
# E_TREEWALK_UNBOUND_VARIABLE, was swallowed by the pass's tolerant `catch`, and
# every producer above it then failed on the one below. Nothing was
# materialized and the whole chain was re-executed per output cell — silently,
# because the fallback is slower and never wrong.
#
# The shape that exposes it is a LINE-source allocation: no geometry kernel
# anywhere (so nothing is setup-materialized, unlike the polygon document in
# `pushdown_cell_geometry_test.jl`), a rank-2 projected-coordinate observed that
# the build inlines away, and a chain of ordinary record-axis observeds above
# it. This document is that shape, at four cells and four records.

module ObservedMaterializationTests

using Test
using EarthSciAST
const EA = EarthSciAST

_ix(f, idx...) = Dict{String,Any}("op" => "index", "args" => Any[f, idx...])
_op(o, args...) = Dict{String,Any}("op" => o, "args" => Any[args...])
_param(shape) = Dict{String,Any}("type" => "parameter", "default" => 0.0,
                                 "shape" => Any[shape...])
_obs(shape) = Dict{String,Any}("type" => "unknown", "shape" => Any[shape...])
_agg(out, ranges, args, expr; reduce=nothing) = begin
    d = Dict{String,Any}("op" => "aggregate", "output_idx" => Any[out...])
    reduce === nothing || (d["reduce"] = reduce)
    d["ranges"] = Dict{String,Any}(k => Dict("from" => v) for (k, v) in ranges)
    d["args"] = Any[args...]
    d["expr"] = expr
    d
end

# A 2×2 grid of unit cells over [0,2]².
const CW = [0.0, 1.0, 0.0, 1.0]
const CS = [0.0, 0.0, 1.0, 1.0]
const CE = [1.0, 2.0, 1.0, 2.0]
const CN = [1.0, 1.0, 2.0, 2.0]

# Four two-vertex segments. Records 1 and 2 belong to one road (KEY 1) and
# record 3 to another; record 4 is off the grid entirely.
#   1  horizontal y=0.5, x 0.5→1.5  — straddles cells 1 and 2, and dy is EXACTLY
#                                     zero, so it exercises the divisor floor
#   2  vertical  x=0.5, y 1.5→1.75  — inside cell 3, dx EXACTLY zero
#   3  horizontal y=0.2, x 1.2→1.8  — inside cell 2
#   4  x 5→6 at y=5                 — matches no cell, joins no support member
const PX = [0.5 1.5; 0.5 0.5; 1.2 1.8; 5.0 6.0]
const PY = [0.5 0.5; 1.5 1.75; 0.2 0.2; 5.0 5.0]
const KEY = [1.0, 1.0, 2.0, 3.0]
# EMIS is the PARENT ROAD's total, replicated onto each of its segments.
const EMIS = [10.0, 10.0, 4.0, 7.0]
const EPS = 1e-9

# Lengths: 1.0, 0.25, 0.6, 1.0.  Road 1 is 1.25 long, so its 10 t split 8 / 2.
# Cell 1 takes half of segment 1 (4.0); cell 2 takes the other half plus all of
# segment 3 (4.0 + 4.0); cell 3 takes all of segment 2 (2.0); cell 4 is met by
# nothing, so it never joins the support set. Segment 4 lands nowhere.
const EXPECT_E = [4.0, 8.0, 2.0]          # over the support set [1, 2, 3]
const SR = [1.0 0.5; 2.0 0.25; 3.0 0.125; 4.0 0.0625]
const EXPECT_CONC = [4.0 * 1.0 + 8.0 * 2.0 + 2.0 * 3.0,
                     4.0 * 0.5 + 8.0 * 0.25 + 2.0 * 0.125]

_env_overlap() = _op("and",
    _op("<=", _ix("src_W", "c"), _ix("seg_xmax", "r")),
    _op("<=", _ix("seg_xmin", "r"), _ix("src_E", "c")),
    _op("<=", _ix("src_S", "c"), _ix("seg_ymax", "r")),
    _op("<=", _ix("seg_ymin", "r"), _ix("src_N", "c")))

# Liang–Barsky, branchless, with a SIGN-PRESERVING floor under each divisor so a
# segment parallel to an axis does not divide by zero (`ifelse` does not guard
# its arms inside an aggregate).
function _length_share()
    x0, x1 = _ix("px", "r", 1), _ix("px", "r", 2)
    y0, y1 = _ix("py", "r", 1), _ix("py", "r", 2)
    dx, dy = _op("-", x1, x0), _op("-", y1, y0)
    neg = _op("-", 0.0, EPS)
    dxs = _op("ifelse", _op(">=", dx, 0.0), _op("max", dx, EPS), _op("min", dx, neg))
    dys = _op("ifelse", _op(">=", dy, 0.0), _op("max", dy, EPS), _op("min", dy, neg))
    ta = _op("/", _op("-", _ix("src_W", "c"), x0), dxs)
    tb = _op("/", _op("-", _ix("src_E", "c"), x0), dxs)
    tc = _op("/", _op("-", _ix("src_S", "c"), y0), dys)
    td = _op("/", _op("-", _ix("src_N", "c"), y0), dys)
    enter = _op("max", 0.0, _op("min", ta, tb), _op("min", tc, td))
    exit_ = _op("min", 1.0, _op("max", ta, tb), _op("max", tc, td))
    return _op("max", _op("-", exit_, enter), 0.0)
end

function _doc()
    v = Dict{String,Any}()
    for n in ("src_W", "src_S", "src_E", "src_N")
        v[n] = _param(["src_cells"])
    end
    v["raw_x"] = _param(["emis_records", "seg_vertex"])
    v["raw_y"] = _param(["emis_records", "seg_vertex"])
    for n in ("seg_key", "seg_emis_in")
        v[n] = _param(["emis_records"])
    end
    v["SR_PM25"] = Dict{String,Any}(
        "type" => "parameter", "default" => 0.0, "units" => "1",
        "shape" => Any["src_cells", "rcv_cells"],
        "update" => Dict{String,Any}("kind" => "data", "source" => "MockSR",
                                     "from" => Dict("file_variable" => "PM25")))
    # `px` / `py` are the ones that matter: rank-2 maps over the record axis
    # that the build folds into their readers, so they get NO entry in
    # `observed_defs` and are not const arrays either.
    v["px"] = _obs(["emis_records", "seg_vertex"])
    v["py"] = _obs(["emis_records", "seg_vertex"])
    for n in ("seg_xmin", "seg_xmax", "seg_ymin", "seg_ymax",
              "seg_len", "road_len", "seg_emis")
        v[n] = _obs(["emis_records"])
    end
    v["E_PM25"] = _obs(["src_cells"])
    v["conc_PM25"] = _obs(["rcv_cells"])

    eqs = Any[]
    push!(eqs, Dict{String,Any}("lhs" => "px", "rhs" => _agg(
        ["r", "v"], [("r", "emis_records"), ("v", "seg_vertex")], ["raw_x"],
        _op("*", _ix("raw_x", "r", "v"), 1.0))))
    push!(eqs, Dict{String,Any}("lhs" => "py", "rhs" => _agg(
        ["r", "v"], [("r", "emis_records"), ("v", "seg_vertex")], ["raw_y"],
        _op("*", _ix("raw_y", "r", "v"), 1.0))))
    for (nm, col, o) in (("seg_xmin", "px", "min"), ("seg_xmax", "px", "max"),
                         ("seg_ymin", "py", "min"), ("seg_ymax", "py", "max"))
        push!(eqs, Dict{String,Any}("lhs" => nm, "rhs" => _agg(
            ["r"], [("r", "emis_records")], [col],
            _op(o, _ix(col, "r", 1), _ix(col, "r", 2)))))
    end
    push!(eqs, Dict{String,Any}("lhs" => "seg_len", "rhs" => _agg(
        ["r"], [("r", "emis_records")], ["px", "py"],
        _op("sqrt", _op("+",
            _op("^", _op("-", _ix("px", "r", 2), _ix("px", "r", 1)), 2.0),
            _op("^", _op("-", _ix("py", "r", 2), _ix("py", "r", 1)), 2.0))))))
    # The group total is a SELF-JOIN: both symbols range over the record axis.
    # The contracted one is `q` and not `t` on purpose — Python's build-time
    # hoist reads a bound symbol named `t` as the time variable.
    push!(eqs, Dict{String,Any}("lhs" => "road_len", "rhs" => _agg(
        ["r"], [("r", "emis_records"), ("q", "emis_records")], ["seg_key", "seg_len"],
        _op("*", _op("ifelse", _op("==", _ix("seg_key", "q"), _ix("seg_key", "r")),
                     1.0, 0.0),
                 _ix("seg_len", "q")); reduce="+")))
    push!(eqs, Dict{String,Any}("lhs" => "seg_emis", "rhs" => _agg(
        ["r"], [("r", "emis_records")], ["seg_emis_in", "seg_len", "road_len"],
        _op("/", _op("*", _ix("seg_emis_in", "r"), _ix("seg_len", "r")),
                 _ix("road_len", "r")))))
    push!(eqs, Dict{String,Any}("lhs" => "E_PM25", "rhs" => _agg(
        ["c"], [("c", "src_cells"), ("r", "emis_records")],
        ["src_W", "src_S", "src_E", "src_N",
         "seg_xmin", "seg_ymin", "seg_xmax", "seg_ymax", "px", "py", "seg_emis"],
        _op("*", _op("ifelse", _env_overlap(), 1.0, 0.0),
                 _op("*", _ix("seg_emis", "r"), _length_share())); reduce="+")))
    push!(eqs, Dict{String,Any}("lhs" => "conc_PM25", "rhs" => _agg(
        ["rcv"], [("rcv", "rcv_cells"), ("s", "src_cells")], ["SR_PM25", "E_PM25"],
        _op("*", _ix("SR_PM25", "s", "rcv"), _ix("E_PM25", "s")); reduce="+")))

    return Dict{String,Any}(
        "esm" => "1.0.0",
        "metadata" => Dict{String,Any}("name" => "observed_materialization"),
        "data_sources" => Dict{String,Any}("MockSR" => Dict{String,Any}(
            "kind" => "static", "source" => Dict("url_template" => "mock://sr"))),
        "index_sets" => Dict{String,Any}(
            "src_cells"    => Dict("kind" => "interval", "size" => 4),
            "rcv_cells"    => Dict("kind" => "interval", "size" => 2),
            "emis_records" => Dict("kind" => "interval", "size" => 4),
            "seg_vertex"   => Dict("kind" => "interval", "size" => 2)),
        "models" => Dict{String,Any}("Binned" =>
            Dict{String,Any}("variables" => v, "equations" => eqs)))
end

mutable struct MockGatedSR
    full::Matrix{Float64}
    calls::Vector{Any}
end
EA.provider_refresh_times(::MockGatedSR) = Float64[]
EA.provider_supports_selection(::MockGatedSR) = true
function EA.provider_sample(m::MockGatedSR, ::Real; selection=nothing)
    if selection === nothing
        push!(m.calls, (:wholesale,))
        return m.full
    end
    push!(m.calls, (:selection, deepcopy(selection)))
    return m.full[selection[1], selection[2]]
end

function _prepared()
    ca = Dict{String,Any}(
        "src_W" => CW, "src_S" => CS, "src_E" => CE, "src_N" => CN,
        "raw_x" => PX, "raw_y" => PY, "seg_key" => KEY, "seg_emis_in" => EMIS)
    for (k, v) in collect(ca)
        ca["Binned." * k] = v
    end
    g = MockGatedSR(SR, Any[])
    insp = EA.BuildInspection()
    prep = EA.prepare(_doc(); const_arrays=ca,
                      providers=Dict{String,Any}("Binned.SR_PM25" => g),
                      inspect=insp, pushdown_rewrite=true)
    return prep, insp, g
end

@testset "line allocation: the values, with no geometry kernel in the path" begin
    prep, insp, g = _prepared()
    mf = Int.(insp.const_arrays["pd_member_factor__src_cells"])
    @test mf == [1, 2, 3]                    # cell 4 is met by nothing
    @test EA.observed_field(prep, insp, "seg_len") ≈ [1.0, 0.25, 0.6, 1.0]
    @test EA.observed_field(prep, insp, "road_len") ≈ [1.25, 1.25, 0.6, 1.0]
    @test EA.observed_field(prep, insp, "seg_emis") ≈ [8.0, 2.0, 4.0, 7.0]
    @test EA.observed_field(prep, insp, "E_PM25") ≈ EXPECT_E
    @test EA.observed_field(prep, insp, "conc_PM25") ≈ EXPECT_CONC
    # Mass in equals mass out for every road that lies inside the grid: the
    # length shares of a segment sum to exactly 1, with no clipping tolerance
    # anywhere to leak through. Roads 1 and 2 are inside; road 3 (segment 4) is
    # off the grid and delivers nothing, which is the right answer too.
    @test sum(EXPECT_E) ≈ 10.0 + 4.0
    # And the gate still did its job.
    @test isempty([c for c in g.calls if c[1] == :wholesale])
end

@testset "the producers of a build-time field are materialized ONCE" begin
    prep, insp, _ = _prepared()
    # `observed_field` coerces this lazily on first use; do the same so the
    # scope call below sees exactly the file the production path passes.
    prep.run_file[] === nothing && (prep.run_file[] = EA.coerce_esm_file(prep.run_doc))
    file = prep.run_file[]
    mname = String(first(keys(file.models)))
    vars = keys(file.models[mname].variables)
    qual(n) = String(first(k for k in vars
                           if String(k) == n || endswith(String(k), "." * n)))
    params = EA._param_scope_with_aliases(insp.params)
    scope = EA._materialized_obs_scope(insp, file, mname, qual("conc_PM25"), params)

    # THE REGRESSION. Before the fix this scope came back as `insp.const_arrays`
    # itself — nothing materialized — and `conc_PM25` then re-ran the binning
    # aggregate once per receptor cell.
    @test length(scope) > length(insp.const_arrays)
    tails = Set(String(split(String(k), '.')[end]) for k in keys(scope))
    for n in ("px", "py", "seg_len", "road_len", "seg_emis", "E_PM25")
        @test n in tails
    end
    # Buffers, and the right ones: a materialized producer must hold exactly
    # what the consumer would otherwise have recomputed inline.
    getbuf(n) = scope[first(k for k in keys(scope)
                            if String(k) == qual(n) || String(k) == n)]
    @test vec(getbuf("seg_len")) ≈ [1.0, 0.25, 0.6, 1.0]
    @test vec(getbuf("E_PM25")) ≈ EXPECT_E
    @test size(getbuf("px")) == (4, 2)

    # `px` is the one that broke the pass: the build publishes a fully
    # substituted body for it and NO un-inlined definition, so a traversal that
    # reads only `observed_defs` stops dead at the first producer that names it.
    # If this precondition ever stops holding, this test has stopped covering
    # the defect and the coverage should be moved rather than deleted.
    defs = Set(String(split(String(k), '.')[end]) for k in keys(insp.observed_defs))
    exprs = Set(String(split(String(k), '.')[end]) for k in keys(insp.observed_exprs))
    @test "px" in exprs
    @test !("px" in defs)
end

end # module ObservedMaterializationTests
