#!/usr/bin/env julia
# =============================================================================
# generate-pushdown-goldens.jl — emit the shared pushdown-rewrite conformance
# corpus (tests/conformance/pushdown/) from the Julia reference implementation.
#
# Two input/golden pairs:
#   * pushdown_l1  — the reusable 9-cell isrm-SHAPED L1 fixture (the document
#     built by test/prepare_pushdown_record_gate_test.jl, frozen here);
#   * isrm         — the real isrm.esm (point the ISRM_ESM env var at a
#     checkout of the isrm.esm repo), loaded with its metaparameter DEFAULTS
#     and re-emitted through `serialize_esm_file` so the committed input is a
#     self-contained document (sizes substituted, no open metaparameters).
#
# For each pair the INPUT document and the GOLDEN `desugar_pushdown(input)`
# output are written in CANONICAL JSON — recursively sorted object keys,
# 2-space indent, JSON3 scalar encoding (shortest-round-trip floats) — so the
# committed files are byte-stable under re-emission. Bindings compare their
# own rewrite output to the golden by PARSED-JSON deep equality (numbers
# compared by value), the same comparison contract as the round_trip category;
# the canonical bytes exist for diff stability, not for byte-level assertion.
#
# Usage:
#   julia --project=<env with EarthSciAST> scripts/generate-pushdown-goldens.jl
#   ISRM_ESM=/path/to/isrm.esm  (default: ../isrm.esm/isrm.esm next to this repo)
# =============================================================================
using EarthSciAST
using JSON3
const EA = EarthSciAST

const REPO = normpath(joinpath(@__DIR__, ".."))
const OUTDIR = joinpath(REPO, "tests", "conformance", "pushdown")

# ---------------------------------------------------------------------------
# Canonical JSON writer: sorted keys, 2-space indent, JSON3 scalars.
# ---------------------------------------------------------------------------
function canon(io::IO, x, level::Int)
    pad = "  "^level
    padin = "  "^(level + 1)
    if x isa AbstractDict
        ks = sort!(collect(String.(keys(x))))
        isempty(ks) && return print(io, "{}")
        print(io, "{\n")
        for (i, k) in enumerate(ks)
            print(io, padin, JSON3.write(k), ": ")
            canon(io, x[k], level + 1)
            i < length(ks) && print(io, ",")
            print(io, "\n")
        end
        print(io, pad, "}")
    elseif x isa AbstractVector
        isempty(x) && return print(io, "[]")
        print(io, "[\n")
        for (i, v) in enumerate(x)
            print(io, padin)
            canon(io, v, level + 1)
            i < length(x) && print(io, ",")
            print(io, "\n")
        end
        print(io, pad, "]")
    elseif x === nothing
        print(io, "null")
    else
        print(io, JSON3.write(x))   # strings, bools, ints, shortest-rt floats
    end
end

function write_canon(path::AbstractString, doc)
    mkpath(dirname(path))
    open(path, "w") do io
        canon(io, doc, 0)
        print(io, "\n")
    end
    println("  wrote $path")
end

# ---------------------------------------------------------------------------
# L1 fixture document — the exact document prepare_pushdown_record_gate_test.jl
# builds (same builders, same frozen numerics), extracted into the corpus.
# ---------------------------------------------------------------------------
_ix(f, args...) = Dict("op" => "index", "args" => Any[f, args...])
_op(o, args...) = Dict("op" => o, "args" => Any[args...])
function _agg(output_idx, ranges, expr; reduce=nothing, args=String[], extra...)
    d = Dict{String,Any}("op" => "aggregate", "output_idx" => collect(output_idx),
                         "ranges" => ranges, "args" => collect(args), "expr" => expr)
    reduce === nothing || (d["reduce"] = reduce)
    for (k, v) in extra
        d[String(k)] = v
    end
    return d
end

_d2r(d) = d * pi / 180
function _lcc_consts(lat1, lat2, lat0, lon0)
    p1 = _d2r(lat1); p2 = _d2r(lat2); p0 = _d2r(lat0); l0 = _d2r(lon0)
    n  = log(cos(p1) / cos(p2)) / log(tan(pi/4 + p2/2) / tan(pi/4 + p1/2))
    F  = cos(p1) * tan(pi/4 + p1/2)^n / n
    r0 = F / tan(pi/4 + p0/2)^n
    return (n = n, rf = F, rho0 = r0, lam0 = l0)
end

function build_l1_doc()
    GRID = 9; N_RCV = 4; N_REC = 5
    LAT1, LAT2, LAT0, LON0 = 33.0, 45.0, 40.0, -97.0
    C = _lcc_consts(LAT1, LAT2, LAT0, LON0)
    FACT = 28766.639; POP_SCALE = 1.0465819687408728; MORT_SCALE = 1.025229357798165
    RR_K = 1.06; RR_L = 1.14
    LVARS = ["SOA", "pNO3", "pNH4", "pSO4", "PrimaryPM25"]

    _latr(e) = _op("*", _ix("emis_lat", e), "lcc_d2r")
    _lonr(e) = _op("*", _ix("emis_lon", e), "lcc_d2r")
    _rho(e)  = _op("/", "lcc_rf",
                   _op("^", _op("tan", _op("+", "lcc_qp", _op("/", _latr(e), 2.0))), "lcc_n"))
    _theta(e)= _op("*", "lcc_n", _op("-", _lonr(e), "lcc_lam0"))
    _Xbody(e) = _op("*", _rho(e), _op("sin", _theta(e)))
    _Ybody(e) = _op("-", "lcc_rho0", _op("*", _rho(e), _op("cos", _theta(e))))
    _proj_obs(bodyfn) = _agg(["e"], Dict("e"=>Dict("from"=>"emis_records")),
                             bodyfn("e"); args=["emis_lon", "emis_lat"])

    _contain = _op("and",
        _op("<=", _ix("src_W", "c"), _ix("X", "r")), _op("<", _ix("X", "r"), _ix("src_E", "c")),
        _op("<=", _ix("src_S", "c"), _ix("Y", "r")), _op("<", _ix("Y", "r"), _ix("src_N", "c")))
    _E_agg(is_p) = _agg(["c"],
        Dict("c"=>Dict("from"=>"src_cells"), "r"=>Dict("from"=>"emis_records")),
        _op("*", _op("ifelse", _contain, 1.0, 0.0),
                 _op("*", _ix("emis_annual", "r"), _ix(is_p, "r")));
        reduce="+", args=["src_W","src_S","src_E","src_N","X","Y","emis_annual",is_p])
    _conc_agg(SRname, Ename) = _agg(["rcv"],
        Dict("s"=>Dict("from"=>"src_cells"), "rcv"=>Dict("from"=>"rcv_cells")),
        _op("*", _ix(SRname, "s", "rcv"), _ix(Ename, "s"));
        reduce="+", args=[SRname, Ename])
    _deaths(rr) = _agg(["rcv"], Dict("rcv"=>Dict("from"=>"rcv_cells")),
        _op("*", _op("*", _op("*",
            _op("-", _op("exp", _op("*",
                _op("/", _op("log", rr), 10), _ix("TotalPM25", "rcv"))), 1),
            _op("*", _ix("TotalPop", "rcv"), "pop_scale")),
            _op("/", _ix("MortalityRate", "rcv"), 100000)), "mort_scale");
        args=["TotalPM25","TotalPop","MortalityRate"])

    param(shape) = Dict("type"=>"parameter", "default"=>0.0, "shape"=>shape)
    obs(shape, expr) = Dict("type"=>"observed", "shape"=>shape, "expression"=>expr)
    scal(v) = Dict("type"=>"parameter", "default"=>v)

    variables = Dict{String,Any}(
        "emis_lon"=>param(["emis_records"]), "emis_lat"=>param(["emis_records"]),
        "X"=>obs(["emis_records"], _proj_obs(_Xbody)),
        "Y"=>obs(["emis_records"], _proj_obs(_Ybody)),
        "emis_annual"=>param(["emis_records"]),
        "is_VOC"=>param(["emis_records"]), "is_NOx"=>param(["emis_records"]),
        "is_NH3"=>param(["emis_records"]), "is_SOx"=>param(["emis_records"]),
        "is_PM25"=>param(["emis_records"]),
        "src_W"=>param(["src_cells"]), "src_S"=>param(["src_cells"]),
        "src_E"=>param(["src_cells"]), "src_N"=>param(["src_cells"]),
        "TotalPop"=>param(["rcv_cells"]), "MortalityRate"=>param(["rcv_cells"]),
        "SR_SOA"=>param(["src_cells","rcv_cells"]),
        "SR_pNO3"=>param(["src_cells","rcv_cells"]),
        "SR_pNH4"=>param(["src_cells","rcv_cells"]),
        "SR_pSO4"=>param(["src_cells","rcv_cells"]),
        "SR_PrimaryPM25"=>param(["src_cells","rcv_cells"]),
        "E_VOC"=>obs(["src_cells"], _E_agg("is_VOC")),
        "E_NOx"=>obs(["src_cells"], _E_agg("is_NOx")),
        "E_NH3"=>obs(["src_cells"], _E_agg("is_NH3")),
        "E_SOx"=>obs(["src_cells"], _E_agg("is_SOx")),
        "E_PM25"=>obs(["src_cells"], _E_agg("is_PM25")),
        "conc_SOA"=>obs(["rcv_cells"], _conc_agg("SR_SOA","E_VOC")),
        "conc_pNO3"=>obs(["rcv_cells"], _conc_agg("SR_pNO3","E_NOx")),
        "conc_pNH4"=>obs(["rcv_cells"], _conc_agg("SR_pNH4","E_NH3")),
        "conc_pSO4"=>obs(["rcv_cells"], _conc_agg("SR_pSO4","E_SOx")),
        "conc_PrimaryPM25"=>obs(["rcv_cells"], _conc_agg("SR_PrimaryPM25","E_PM25")),
        "TotalPM25"=>obs(["rcv_cells"], _agg(["rcv"],
            Dict("rcv"=>Dict("from"=>"rcv_cells")),
            _op("*", "fact", _op("+", _ix("conc_SOA","rcv"), _ix("conc_pNO3","rcv"),
                _ix("conc_pNH4","rcv"), _ix("conc_pSO4","rcv"),
                _ix("conc_PrimaryPM25","rcv")));
            args=["conc_SOA","conc_pNO3","conc_pNH4","conc_pSO4","conc_PrimaryPM25"])),
        "deathsK"=>obs(["rcv_cells"], _deaths("rr_K")),
        "deathsL"=>obs(["rcv_cells"], _deaths("rr_L")),
        "lcc_n"=>scal(C.n), "lcc_rf"=>scal(C.rf), "lcc_rho0"=>scal(C.rho0),
        "lcc_lam0"=>scal(C.lam0), "lcc_qp"=>scal(pi/4), "lcc_d2r"=>scal(pi/180),
        "fact"=>scal(FACT), "pop_scale"=>scal(POP_SCALE), "mort_scale"=>scal(MORT_SCALE),
        "rr_K"=>scal(RR_K), "rr_L"=>scal(RR_L))

    loader_var(fv) = Dict{String,Any}("file_variable" => fv, "units" => "1")
    data_loaders = Dict{String,Any}(
        "MockSR" => Dict{String,Any}(
            "kind" => "static",
            "source" => Dict{String,Any}("url_template" => "mock://sr"),
            "variables" => Dict{String,Any}(
                fv => loader_var(fv) for fv in vcat(LVARS, ["TotalPop", "MortalityRate"])),
            "metadata" => Dict{String,Any}("x_esd" => Dict{String,Any}(
                "gated_select" => Dict{String,Any}(
                    "axes" => Any[Dict("fixed"=>[0]),
                                  Dict("gated_by"=>"stale_hand_authored_set"), "all"],
                    "applies_to" => Any[LVARS...])))),
        "MockPts" => Dict{String,Any}(
            "kind" => "points",
            "source" => Dict{String,Any}("url_template" => "mock://pts"),
            "variables" => Dict{String,Any}(
                fv => loader_var(fv) for fv in
                    ["lon", "lat", "annual", "vVOC", "vNOx", "vNH3", "vSOx", "vPM25"])))
    coupling = Any[]
    for (frm, to) in vcat(
        [("MockSR.$v", "ISRM.SR_$v") for v in LVARS],
        [("MockSR.TotalPop", "ISRM.TotalPop"),
         ("MockSR.MortalityRate", "ISRM.MortalityRate"),
         ("MockPts.lon", "ISRM.emis_lon"), ("MockPts.lat", "ISRM.emis_lat"),
         ("MockPts.annual", "ISRM.emis_annual"),
         ("MockPts.vVOC", "ISRM.is_VOC"), ("MockPts.vNOx", "ISRM.is_NOx"),
         ("MockPts.vNH3", "ISRM.is_NH3"), ("MockPts.vSOx", "ISRM.is_SOx"),
         ("MockPts.vPM25", "ISRM.is_PM25")])
        push!(coupling, Dict{String,Any}("type" => "variable_map",
                                         "from" => frm, "to" => to,
                                         "transform" => "param_to_var"))
    end

    return Dict{String,Any}(
        "esm" => "0.9.0",
        "metadata" => Dict{String,Any}("name" => "prepare_pushdown_L1"),
        "index_sets" => Dict{String,Any}(
            "src_cells"    => Dict("kind"=>"interval", "size"=>GRID),
            "rcv_cells"    => Dict("kind"=>"interval", "size"=>N_RCV),
            "emis_records" => Dict("kind"=>"interval", "size"=>N_REC)),
        "data_loaders" => data_loaders,
        "coupling" => coupling,
        "models" => Dict{String,Any}("ISRM" =>
            Dict{String,Any}("variables"=>variables, "equations"=>Any[])))
end

# ---------------------------------------------------------------------------
# MINIMAL forward fixture — the GATED DENSE AGGREGATE.
#
# The smallest document the rewrite fires on: one provider-backed SR array, one
# binning observed `E[c]`, one `conc[rcv]`. Its golden is the reference for the
# gate the rewrite now attaches to the REWRITTEN binning aggregate: `join.overlap`
# with `src_env` the record point coordinates and `tgt_env` the GENERATED
# `pd_cell__*` gathers, i.e. the envelopes on the COMPACT derived axis the
# aggregate now ranges over. Deliberately tiny so the whole rewritten document
# is reviewable in a diff.
# ---------------------------------------------------------------------------
_pd_contain() = _op("and",
    _op("<=", _ix("src_W", "c"), _ix("px", "r")), _op("<", _ix("px", "r"), _ix("src_E", "c")),
    _op("<=", _ix("src_S", "c"), _ix("py", "r")), _op("<", _ix("py", "r"), _ix("src_N", "c")))

_pd_param(shape) = Dict{String,Any}("type"=>"parameter", "default"=>0.0, "shape"=>shape)
_pd_obs(shape, expr) = Dict{String,Any}("type"=>"observed", "shape"=>shape, "expression"=>expr)

# The 4 cell-rect factors + the 2 record point coordinates, shared by both docs.
function _pd_geometry_vars()
    v = Dict{String,Any}()
    for n in ("src_W", "src_S", "src_E", "src_N"); v[n] = _pd_param(["src_cells"]); end
    for n in ("px", "py", "emis_annual"); v[n] = _pd_param(["emis_records"]); end
    return v
end

function build_gated_dense_doc()
    NC = 4; NR = 3; NRCV = 2
    variables = _pd_geometry_vars()
    variables["SR_PM25"] = _pd_param(["src_cells", "rcv_cells"])
    variables["E_PM25"] = _pd_obs(["src_cells"], _agg(["c"],
        Dict("c"=>Dict("from"=>"src_cells"), "r"=>Dict("from"=>"emis_records")),
        _op("*", _op("ifelse", _pd_contain(), 1.0, 0.0), _ix("emis_annual", "r"));
        reduce="+", args=["src_W","src_S","src_E","src_N","px","py","emis_annual"]))
    variables["conc_PM25"] = _pd_obs(["rcv_cells"], _agg(["rcv"],
        Dict("s"=>Dict("from"=>"src_cells"), "rcv"=>Dict("from"=>"rcv_cells")),
        _op("*", _ix("SR_PM25", "s", "rcv"), _ix("E_PM25", "s"));
        reduce="+", args=["SR_PM25", "E_PM25"]))
    return Dict{String,Any}(
        "esm" => "0.9.0",
        "metadata" => Dict{String,Any}("name" => "pushdown_gated_dense"),
        "index_sets" => Dict{String,Any}(
            "src_cells"    => Dict("kind"=>"interval", "size"=>NC),
            "rcv_cells"    => Dict("kind"=>"interval", "size"=>NRCV),
            "emis_records" => Dict("kind"=>"interval", "size"=>NR)),
        "models" => Dict{String,Any}("Binned" =>
            Dict{String,Any}("variables"=>variables, "equations"=>Any[])))
end

# ---------------------------------------------------------------------------
# MIRRORED-ORIENTATION fixture.
#
# The same join read the other way round: per-RECORD observeds
# `P[r] = Σ_{c∈src_cells} [contains(cell_c, pt_r)] · …` reducing over CELLS and
# carrying the identical containment predicate. This is the shape plume rise
# needs. Its golden pins the second detector arm:
#
#   * the mirrored aggregates get ONLY a `join.overlap` clause — their envelopes
#     are the document's OWN const rect factors (`src_W…src_N`), because their
#     cell axis is NOT re-pointed onto the compact derived set;
#   * no second derived index set, `distinct` producer, member factor or
#     `gated_select` entry is emitted for them;
#   * their `shape`, `output_idx` and `ranges` are untouched — every record
#     keeps a value, and a record outside the grid reduces to the semiring
#     identity 0.
#
# Two mirrors are present so the emission order (sorted by name) is observable,
# and one of them reads a CELL factor while the other reads only the predicate.
# ---------------------------------------------------------------------------
function build_mirror_doc()
    d = build_gated_dense_doc()
    d["metadata"]["name"] = "pushdown_mirror"
    v = d["models"]["Binned"]["variables"]
    # plume_top[r] — the north edge of the cell each record falls in.
    v["plume_top"] = _pd_obs(["emis_records"], _agg(["r"],
        Dict("c"=>Dict("from"=>"src_cells"), "r"=>Dict("from"=>"emis_records")),
        _op("*", _op("ifelse", _pd_contain(), 1.0, 0.0), _ix("src_N", "c"));
        reduce="+", args=["src_W","src_S","src_E","src_N","px","py"]))
    # in_grid[r] — 1 when the record is inside SOME cell, 0 otherwise.
    v["in_grid"] = _pd_obs(["emis_records"], _agg(["r"],
        Dict("c"=>Dict("from"=>"src_cells"), "r"=>Dict("from"=>"emis_records")),
        _op("ifelse", _pd_contain(), 1.0, 0.0);
        reduce="+", args=["src_W","src_S","src_E","src_N","px","py"]))
    return d
end

# ---------------------------------------------------------------------------
function main()
    println("emitting pushdown conformance corpus under $OUTDIR")

    l1 = build_l1_doc()
    l1r = EA.desugar_pushdown(l1; model_name="ISRM")
    l1r === l1 && error("L1 fixture: desugar_pushdown did not fire")
    EA.desugar_pushdown(l1r) === l1r || error("L1 golden re-desugars (idempotency broken)")
    write_canon(joinpath(OUTDIR, "fixtures", "pushdown_l1.esm"), l1)
    write_canon(joinpath(OUTDIR, "golden", "pushdown_l1.rewritten.json"), l1r)

    gd = build_gated_dense_doc()
    gdr = EA.desugar_pushdown(gd; model_name="Binned")
    gdr === gd && error("gated-dense fixture: desugar_pushdown did not fire")
    EA.desugar_pushdown(gdr) === gdr || error("gated-dense golden re-desugars (idempotency broken)")
    write_canon(joinpath(OUTDIR, "fixtures", "pushdown_gated_dense.esm"), gd)
    write_canon(joinpath(OUTDIR, "golden", "pushdown_gated_dense.rewritten.json"), gdr)

    mr = build_mirror_doc()
    mrr = EA.desugar_pushdown(mr; model_name="Binned")
    mrr === mr && error("mirror fixture: desugar_pushdown did not fire")
    EA.desugar_pushdown(mrr) === mrr || error("mirror golden re-desugars (idempotency broken)")
    write_canon(joinpath(OUTDIR, "fixtures", "pushdown_mirror.esm"), mr)
    write_canon(joinpath(OUTDIR, "golden", "pushdown_mirror.rewritten.json"), mrr)

    # The isrm pair regenerates from the COMMITTED input fixture by default: the
    # upstream isrm.esm keeps evolving, and the frozen fixture — not whatever the
    # sibling checkout currently holds — is the cross-binding contract. Set
    # ISRM_ESM_REFRESH=1 to re-cut the input from a checkout instead.
    if get(ENV, "ISRM_ESM_REFRESH", "0") == "1"
        isrm_path = get(ENV, "ISRM_ESM",
                        normpath(joinpath(REPO, "..", "isrm.esm", "isrm.esm")))
        isfile(isrm_path) || error("isrm.esm not found at $isrm_path (set ISRM_ESM)")
        ser = EA.serialize_esm_file(EA.load(isrm_path))   # metaparameter defaults folded
        write_canon(joinpath(OUTDIR, "fixtures", "isrm.esm"), ser)
    end
    ser = EA.serialize_esm_file(EA.load(joinpath(OUTDIR, "fixtures", "isrm.esm")))
    isrm = EA.desugar_pushdown(ser)
    isrm === ser && error("isrm.esm: desugar_pushdown did not fire")
    EA.desugar_pushdown(isrm) === isrm || error("isrm golden re-desugars (idempotency broken)")
    write_canon(joinpath(OUTDIR, "golden", "isrm.rewritten.json"), isrm)
    println("done")
end

main()
