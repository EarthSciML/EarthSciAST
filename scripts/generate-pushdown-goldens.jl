#!/usr/bin/env julia
# =============================================================================
# generate-pushdown-goldens.jl — emit the shared pushdown-rewrite conformance
# corpus (tests/conformance/pushdown/) from the Julia reference implementation.
#
# Four input/golden pairs (see each builder for what its golden pins):
#   * pushdown_l1  — the reusable 9-cell isrm-SHAPED L1 fixture (the document
#     built by test/prepare_pushdown_record_gate_test.jl, frozen here);
#   * pushdown_envelope_overlap — the second containment shape: a record with
#     EXTENT, gated by envelope-vs-envelope AABB overlap rather than
#     point-in-rectangle;
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
# esm 1.0.0: observed variables are DEFINED BY EQUATIONS.
#
# Builders declare an observed as `Dict("type"=>"unknown", "shape"=>…, _DEFKEY=>rhs)`
# and `_split_observeds!` moves each `_DEFKEY` into a bare-variable-LHS equation.
# The order matters and is not incidental: `equations` is an ordered array, and
# the committed fixtures list these in the order their builder declares them, so
# the lift walks a SORTED name list to stay deterministic across Julia's Dict
# iteration order. (Hand-conversion of the shared corpus alphabetized several
# goldens against fixtures that had not been, which is exactly the class of
# mismatch this avoids.)
# ---------------------------------------------------------------------------
const _DEFKEY = "__defining_rhs__"

function _split_observeds!(model::AbstractDict)
    vars = model["variables"]
    eqs = model["equations"]
    for name in sort!(collect(String.(keys(vars))))
        v = vars[name]
        v isa AbstractDict || continue
        haskey(v, _DEFKEY) || continue
        rhs = pop!(v, _DEFKEY)
        # A builder that derives from another (the template-factored and
        # unreadable-join fixtures both start from `build_gated_dense_doc`) may
        # REDECLARE a name whose definition has already been lifted. Rewrite that
        # equation in place: appending a second one for the same LHS would leave
        # the fixture with two definitions, of which classification reads the
        # first — the redeclaration would be silently inert.
        i = findfirst(e -> e isa AbstractDict && get(e, "lhs", nothing) == name, eqs)
        if i === nothing
            push!(eqs, Dict{String,Any}("lhs" => name, "rhs" => rhs))
        else
            eqs[i] = Dict{String,Any}("lhs" => name, "rhs" => rhs)
        end
    end
    return model
end

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
    # esm 1.0.0: an observed quantity is an `unknown` DECLARED here and DEFINED
    # by a bare-variable-LHS equation; the variable carries no `expression`.
    # `obs` stashes the defining RHS under a private key that `_split_observeds!`
    # lifts into the model's `equations` in declaration order.
    obs(shape, expr) = Dict("type"=>"unknown", "shape"=>shape, _DEFKEY=>expr)
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

    # esm 1.0.0: a data source is a document-scoped INGEST REGISTRY, not a
    # component. It no longer declares the fields it provides, it is not a
    # coupling endpoint, and the 15 variable_map entries that used to wire its
    # fields into the model are gone. The CONSUMING PARAMETER carries the
    # binding instead, and owns the units.
    data_sources = Dict{String,Any}(
        "MockSR" => Dict{String,Any}(
            "kind" => "static",
            "source" => Dict{String,Any}("url_template" => "mock://sr"),
            "metadata" => Dict{String,Any}("x_esd" => Dict{String,Any}(
                "gated_select" => Dict{String,Any}(
                    "axes" => Any[Dict("fixed"=>[0]),
                                  Dict("gated_by"=>"stale_hand_authored_set"), "all"],
                    "applies_to" => Any[LVARS...])))),
        "MockPts" => Dict{String,Any}(
            "kind" => "points",
            "source" => Dict{String,Any}("url_template" => "mock://pts")))

    # `update` binds the model parameter to the file variable the loader used to
    # publish. `shape` is already declared by `param`, which a `data` update
    # requires.
    function _fed!(vname, src, file_variable)
        v = variables[vname]
        v["units"] = "1"
        v["update"] = Dict{String,Any}(
            "kind" => "data", "source" => src,
            "from" => Dict{String,Any}("file_variable" => file_variable))
        return v
    end
    for lv in LVARS; _fed!("SR_$lv", "MockSR", lv); end
    _fed!("TotalPop", "MockSR", "TotalPop")
    _fed!("MortalityRate", "MockSR", "MortalityRate")
    _fed!("emis_lon", "MockPts", "lon")
    _fed!("emis_lat", "MockPts", "lat")
    _fed!("emis_annual", "MockPts", "annual")
    for (vn, fv) in (("is_VOC", "vVOC"), ("is_NOx", "vNOx"), ("is_NH3", "vNH3"),
                     ("is_SOx", "vSOx"), ("is_PM25", "vPM25"))
        _fed!(vn, "MockPts", fv)
    end

    doc = Dict{String,Any}(
        "esm" => "1.0.0",
        "metadata" => Dict{String,Any}("name" => "prepare_pushdown_L1"),
        "index_sets" => Dict{String,Any}(
            "src_cells"    => Dict("kind"=>"interval", "size"=>GRID),
            "rcv_cells"    => Dict("kind"=>"interval", "size"=>N_RCV),
            "emis_records" => Dict("kind"=>"interval", "size"=>N_REC)),
        "data_sources" => data_sources,
        "models" => Dict{String,Any}("ISRM" =>
            Dict{String,Any}("variables"=>variables, "equations"=>Any[])))
    _split_observeds!(doc["models"]["ISRM"])
    return doc
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
_pd_obs(shape, expr) = Dict{String,Any}("type"=>"unknown", "shape"=>shape, _DEFKEY=>expr)

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
    doc = Dict{String,Any}(
        "esm" => "1.0.0",
        "metadata" => Dict{String,Any}("name" => "pushdown_gated_dense"),
        "index_sets" => Dict{String,Any}(
            "src_cells"    => Dict("kind"=>"interval", "size"=>NC),
            "rcv_cells"    => Dict("kind"=>"interval", "size"=>NRCV),
            "emis_records" => Dict("kind"=>"interval", "size"=>NR)),
        "models" => Dict{String,Any}("Binned" =>
            Dict{String,Any}("variables"=>variables, "equations"=>Any[])))
    _split_observeds!(doc["models"]["Binned"])
    return doc
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
    # `plume_top` and `in_grid` are declared AFTER build_gated_dense_doc has
    # already split its own observeds, so they still carry the private defining
    # key and need a second lift. Without this the two mirror artifacts diverge
    # from the committed corpus while the other five stay deep-equal.
    _split_observeds!(d["models"]["Binned"])
    return d
end

# ---------------------------------------------------------------------------
# ENVELOPE-vs-ENVELOPE fixture — the second containment shape.
#
# A record with EXTENT rather than a position: the predicate is the 2-D AABB
# overlap test between the cell rectangle and the record's own bounding box,
#
#   src_W[c] <= rec_xmax[r] ∧ rec_xmin[r] <= src_E[c] ∧
#   src_S[c] <= rec_ymax[r] ∧ rec_ymin[r] <= src_N[c]
#
# which is what a polygon or line record needs — the exact geometry (clipped
# area, clipped length) stays the aggregate's own narrow phase, and this is the
# broad phase around it. §5.5.6 already admits an arity-4 envelope on EITHER
# side independently; only the recogniser was point-only.
#
# What the golden pins:
#
#   * `src_env` is the record's FOUR bounds `[rec_xmin, rec_ymin, rec_xmax,
#     rec_ymax]` — not two coordinates — while `tgt_env` is the same four cell
#     bounds the point shape yields, so everything downstream of the parse
#     (derived set, producer, member factor, cell gathers, `gated_select`) is
#     arity-agnostic and emits exactly as in `pushdown_gated_dense`;
#   * each bound is placed by the ORIENTATION of its comparison: a record factor
#     bounded BELOW by a cell factor is that axis's record maximum;
#   * the MIRRORED arm still resolves. An envelope predicate is SYMMETRIC — it
#     parses with either symbol taken as the cell — so unlike the point shape it
#     cannot say which side is which on its own. `overlapping_cells[r]` is here
#     to pin that the orientation comes from the caller (the mat-vec's first axis
#     forward, the already-fixed `C`/`R` for a mirror) and that a mirror is NOT
#     misread as a second forward.
# ---------------------------------------------------------------------------
_pd_env_overlap() = _op("and",
    _op("<=", _ix("src_W", "c"), _ix("rec_xmax", "r")),
    _op("<=", _ix("rec_xmin", "r"), _ix("src_E", "c")),
    _op("<=", _ix("src_S", "c"), _ix("rec_ymax", "r")),
    _op("<=", _ix("rec_ymin", "r"), _ix("src_N", "c")))

const _PD_ENV_ARGS = ["src_W","src_S","src_E","src_N",
                      "rec_xmin","rec_ymin","rec_xmax","rec_ymax"]

function build_envelope_overlap_doc()
    d = build_gated_dense_doc()
    d["metadata"]["name"] = "pushdown_envelope_overlap"
    v = d["models"]["Binned"]["variables"]
    for n in ("rec_xmin", "rec_ymin", "rec_xmax", "rec_ymax")
        v[n] = _pd_param(["emis_records"])
    end
    # FORWARD: the record's emissions are binned into every cell its envelope
    # meets. `overlap_frac` stands in for the narrow phase a real polygon
    # document computes (clipped area / record area); the rewrite neither reads
    # nor touches it.
    v["overlap_frac"] = _pd_param(["emis_records"])
    v["E_PM25"] = _pd_obs(["src_cells"], _agg(["c"],
        Dict("c"=>Dict("from"=>"src_cells"), "r"=>Dict("from"=>"emis_records")),
        _op("*", _op("ifelse", _pd_env_overlap(), 1.0, 0.0),
                 _op("*", _ix("emis_annual", "r"), _ix("overlap_frac", "r")));
        reduce="+", args=vcat(_PD_ENV_ARGS, ["emis_annual", "overlap_frac"])))
    # MIRROR: how many cells this record spills into. Gate only.
    v["overlapping_cells"] = _pd_obs(["emis_records"], _agg(["r"],
        Dict("c"=>Dict("from"=>"src_cells"), "r"=>Dict("from"=>"emis_records")),
        _op("ifelse", _pd_env_overlap(), 1.0, 0.0);
        reduce="+", args=_PD_ENV_ARGS))
    _split_observeds!(d["models"]["Binned"])
    return d
end

# ---------------------------------------------------------------------------
# TEMPLATE-FACTORED forward fixture — the ACCEPTANCE case.
#
# Byte-for-byte the same math as `pushdown_gated_dense`, but the binning body is
# factored through an `expression_templates` entry with the four rect factors and
# the two point coordinates passed as BINDINGS. Under esm-spec §9.6.4 Option B
# that reference SURVIVES load and reaches `desugar_pushdown` unexpanded; §9.6.4
# rule 2 (a reference denotes its expansion) governs this consumer, so the
# rewrite MUST fire exactly as it does on the longhand form.
#
# What the golden pins, beyond "it fired":
#
#   * the derived set, producer, member factor, cell gathers, gate and
#     `gated_select` record are IDENTICAL to the longhand golden — whether the
#     pushdown fires does not depend on how the author factored the body;
#   * the template BODY is untouched — the rewrite re-points the CALL SITE's
#     `bindings` onto the generated `pd_cell__*` gathers, so the body stays
#     shared and singly-lowered (that is the ~50x node-lowering win Option B
#     exists for);
#   * the generated producer `filter` still carries the FULL-GRID rect
#     references, read off the expanded body before the call site is rewritten.
#
# This is the shape `flatten.jl`'s `template_body_references_coupling_rewritten_variable`
# tells authors to write ("Bind the value through the template's params"): it now
# both flattens AND is recognised by the pushdown.
# ---------------------------------------------------------------------------
function build_template_body_doc()
    d = build_gated_dense_doc()
    d["metadata"]["name"] = "pushdown_template_body"
    m = d["models"]["Binned"]
    # The body names ONLY its own params; every geometry factor arrives as a
    # binding. `r` and `c` are the call site's own range symbols.
    tpl_contain = _op("and",
        _op("<=", _ix("xmin", "c"), _ix("ptx", "r")),
        _op("<",  _ix("ptx", "r"),  _ix("xmax", "c")),
        _op("<=", _ix("ymin", "c"), _ix("pty", "r")),
        _op("<",  _ix("pty", "r"),  _ix("ymax", "c")))
    m["expression_templates"] = Dict{String,Any}(
        "bin_into_cell" => Dict{String,Any}(
            "params" => Any["xmin", "ymin", "xmax", "ymax", "ptx", "pty", "wgt"],
            "body" => _op("*", _op("ifelse", tpl_contain, 1.0, 0.0), _ix("wgt", "r"))))
    m["variables"]["E_PM25"] = _pd_obs(["src_cells"], _agg(["c"],
        Dict("c"=>Dict("from"=>"src_cells"), "r"=>Dict("from"=>"emis_records")),
        Dict{String,Any}("op" => "apply_expression_template", "args" => Any[],
                         "name" => "bin_into_cell",
                         "bindings" => Dict{String,Any}(
                             "xmin"=>"src_W", "ymin"=>"src_S",
                             "xmax"=>"src_E", "ymax"=>"src_N",
                             "ptx"=>"px", "pty"=>"py", "wgt"=>"emis_annual"));
        reduce="+", args=["src_W","src_S","src_E","src_N","px","py","emis_annual"]))
    # `E_PM25` is REDECLARED here, after `build_gated_dense_doc` lifted its own
    # definition — so its defining equation is rewritten, not duplicated.
    _split_observeds!(m)
    return d
end

# ---------------------------------------------------------------------------
# RESIDUAL-DIAGNOSTIC fixture — "a join I could not read".
#
# `E_PM25` bins records into `src_cells` with a THREE-dimensional box
# containment and feeds the provider-backed `SR_PM25` through `conc_PM25`: the
# join position, unmistakably. The recogniser handles 2-D rectangles only, so
# `_pd_parse_containment` refuses and the rewrite does not fire — which used to
# be entirely silent and surfaced as an ungated whole-array fetch hours later.
#
# The golden here is the DIAGNOSTIC list, not a rewritten document: this fixture
# asserts that the rewrite leaves the document alone AND says why.
# ---------------------------------------------------------------------------
function build_unreadable_join_doc()
    d = build_gated_dense_doc()
    d["metadata"]["name"] = "pushdown_unreadable_join"
    v = d["models"]["Binned"]["variables"]
    v["pz"]    = _pd_param(["emis_records"])
    v["src_B"] = _pd_param(["src_cells"])
    v["src_T"] = _pd_param(["src_cells"])
    v["E_PM25"] = _pd_obs(["src_cells"], _agg(["c"],
        Dict("c"=>Dict("from"=>"src_cells"), "r"=>Dict("from"=>"emis_records")),
        _op("*", _op("ifelse", _op("and",
            _op("<=", _ix("src_W","c"), _ix("px","r")), _op("<", _ix("px","r"), _ix("src_E","c")),
            _op("<=", _ix("src_S","c"), _ix("py","r")), _op("<", _ix("py","r"), _ix("src_N","c")),
            _op("<=", _ix("src_B","c"), _ix("pz","r")), _op("<", _ix("pz","r"), _ix("src_T","c"))),
            1.0, 0.0), _ix("emis_annual", "r"));
        reduce="+", args=["src_W","src_S","src_E","src_N","src_B","src_T",
                          "px","py","pz","emis_annual"]))
    # As in `build_template_body_doc`: `E_PM25` is redeclared over an already
    # lifted definition, so this rewrites that equation in place.
    _split_observeds!(d["models"]["Binned"])
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

    eo = build_envelope_overlap_doc()
    eor = EA.desugar_pushdown(eo; model_name="Binned")
    eor === eo && error("envelope-overlap fixture: desugar_pushdown did not fire")
    EA.desugar_pushdown(eor) === eor || error("envelope-overlap golden re-desugars (idempotency broken)")
    EA.load(eo)          # the fixture must be a VALID document, not just a dict
    write_canon(joinpath(OUTDIR, "fixtures", "pushdown_envelope_overlap.esm"), eo)
    write_canon(joinpath(OUTDIR, "golden", "pushdown_envelope_overlap.rewritten.json"), eor)

    tb = build_template_body_doc()
    tbr = EA.desugar_pushdown(tb; model_name="Binned")
    tbr === tb && error("template-body fixture: desugar_pushdown did not fire")
    EA.desugar_pushdown(tbr) === tbr || error("template-body golden re-desugars (idempotency broken)")
    EA.load(tb)          # the fixture must be a VALID document, not just a dict
    write_canon(joinpath(OUTDIR, "fixtures", "pushdown_template_body.esm"), tb)
    write_canon(joinpath(OUTDIR, "golden", "pushdown_template_body.rewritten.json"), tbr)

    uj = build_unreadable_join_doc()
    ujr = EA.desugar_pushdown(uj; model_name="Binned")
    ujr === uj || error("unreadable-join fixture: desugar_pushdown fired but must not")
    ujd = EA.pushdown_diagnostics(uj; model_name="Binned")
    isempty(ujd) && error("unreadable-join fixture: no residual diagnostic emitted")
    EA.load(uj)          # the fixture must be a VALID document, not just a dict
    write_canon(joinpath(OUTDIR, "fixtures", "pushdown_unreadable_join.esm"), uj)
    write_canon(joinpath(OUTDIR, "golden", "pushdown_unreadable_join.diagnostics.json"), ujd)

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
