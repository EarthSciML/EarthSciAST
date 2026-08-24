# PUBLIC-SURFACE projection pushdown — Phase 1 (clean consolidation).
#
# Phase 4/5 proved the automatic rewrite + gated deferral through the PRIVATE
# `build_evaluator` front door (`_gated_providers`, hand-authored gate dicts).
# This test drives the same clean pattern through the PUBLIC `esm_problem` surface:
#
#   * `esm_problem(input, tspan; pushdown_rewrite=true, providers=…)` — the rewrite runs
#     on the AUTHORED document BEFORE flattening (post-flatten the coupling
#     substitution has split equation names from variable-expression names and
#     the pattern no longer matches);
#   * the engine derives every provider gate from the rewrite's OWN record
#     (`metadata.x_esd.pushdown.gated_select`) + the document coupling — the
#     caller hand-authors NO gate dict and implements NO `provider_gate_spec`;
#   * the loader's `metadata.x_esd.gated_select.axes` template contributes the
#     NATIVE axis layout (the `fixed` emission-layer axis), with the record's
#     GENERATED set name substituted over the template's stale one;
#   * `observed_field(prep, name)` reads the results back through the
#     prepared document's own graph.
#
# The fixture mirrors isrm.esm's structure: `data_sources` + a clean model with
# in-model LCC projection observeds, at the reusable 9-cell L1 scale with the L1
# oracle numerics. esm 1.0.0 (§8): a data source is INGEST CONFIGURATION, not a
# component — it exposes no `variables` and is not a coupling endpoint, so the
# consuming PARAMETER carries `update: {kind: data, source, from.file_variable}`
# and the provider is keyed by that parameter's flattened name (`ISRM.SR_SOA`).

module PreparePushdownRecordGateTests

using Test
using EarthSciAST
import GeometryOps
import GeoInterface

const EA = EarthSciAST

# ---- small JSON AST builders (shared spelling with the sibling tests) -------
_ix(f, args...) = Dict("op" => "index", "args" => Any[f, args...])
_op(o, args...) = Dict("op" => o, "args" => Any[args...])

# The defining right-hand side of the observed unknown `name` — where esm 1.0.0
# keeps what 0.x wrote in `variables[name]["expression"]` (esm-spec §6.3.1).
function _defrhs(model, name)
    for eq in model["equations"]
        get(eq, "lhs", nothing) == name && return eq["rhs"]
    end
    error("$(name) has no defining equation")
end
function _agg(output_idx, ranges, expr; reduce=nothing, args=String[], extra...)
    d = Dict{String,Any}("op" => "aggregate", "output_idx" => collect(output_idx),
                         "ranges" => ranges, "args" => collect(args), "expr" => expr)
    reduce === nothing || (d["reduce"] = reduce)
    for (k, v) in extra
        d[String(k)] = v
    end
    return d
end

# esm 1.0.0 (§5.4/§6.3.1): a variable has NO `expression`. `obs_v` declares the
# observed as a plain `unknown` and pushes its DEFINING bare-variable-LHS
# equation onto `eqs`, which is what `observed_definitions` reads back.
function obs_v(eqs, name, shape, expr)
    push!(eqs, Dict("lhs"=>name, "rhs"=>expr))
    return Dict("type"=>"unknown", "shape"=>shape)
end

# ---- Lambert conformal conic (unit sphere), plain Julia ORACLE --------------
_d2r(d) = d * pi / 180
function _lcc_consts(lat1, lat2, lat0, lon0)
    φ1 = _d2r(lat1); φ2 = _d2r(lat2); φ0 = _d2r(lat0); λ0 = _d2r(lon0)
    n  = log(cos(φ1) / cos(φ2)) / log(tan(pi/4 + φ2/2) / tan(pi/4 + φ1/2))
    F  = cos(φ1) * tan(pi/4 + φ1/2)^n / n
    ρ0 = F / tan(pi/4 + φ0/2)^n
    return (n = n, rf = F, ρ0 = ρ0, λ0 = λ0)
end
function _lcc_fwd(lon_deg, lat_deg, c)
    latr = lat_deg * (pi/180); lonr = lon_deg * (pi/180)
    ρ = c.rf / tan(pi/4 + latr/2)^c.n
    θ = c.n * (lonr - c.λ0)
    return (ρ * sin(θ), c.ρ0 - ρ * cos(θ))
end
function _lcc_inv(x, y, c)
    ρ = sign(c.n) * sqrt(x^2 + (c.ρ0 - y)^2)
    θ = atan(x, c.ρ0 - y)
    return (rad2deg(c.λ0 + θ / c.n), rad2deg(2 * atan((c.rf / ρ)^(1 / c.n)) - pi/2))
end

# ---- provider mocks — NO provider_gate_spec anywhere ------------------------
struct MockConstP1
    arr::Any
end
EA.provider_refresh_times(::MockConstP1) = Float64[]
EA.provider_sample(m::MockConstP1, ::Real; selection=nothing) = m.arr

mutable struct MockGatedP1
    full::Array{Float64,3}          # native [layer, src, rcv]
    calls::Vector{Any}
end
EA.provider_refresh_times(::MockGatedP1) = Float64[]
EA.provider_supports_selection(::MockGatedP1) = true
function EA.provider_sample(m::MockGatedP1, ::Real; selection=nothing)
    if selection === nothing
        push!(m.calls, (:wholesale,))
        return m.full
    end
    push!(m.calls, (:selection, deepcopy(selection)))
    lay, src, rcv = selection[1], selection[2], selection[3]
    return m.full[lay:lay, src, rcv]
end

@testset "esm_problem(pushdown_rewrite=true) + record-derived provider gating" begin

    GRID = 9; N_RCV = 4; N_REC = 5; N_LAYER = 3
    W = zeros(GRID); Sv = zeros(GRID); Ev = zeros(GRID); Nv = zeros(GRID)
    for row in 1:3, col in 1:3
        k = (row - 1) * 3 + col
        W[k] = (col - 1) * 2.0; Ev[k] = col * 2.0
        Sv[k] = (row - 1) * 2.0; Nv[k] = row * 2.0
    end

    LAT1, LAT2, LAT0, LON0 = 33.0, 45.0, 40.0, -97.0
    C = _lcc_consts(LAT1, LAT2, LAT0, LON0)
    Xtarget = [1.0, 3.0, 1.0, 5.0, 1.5]
    Ytarget = [1.0, 1.0, 3.0, 5.0, 1.5]
    lon = Float64[]; lat = Float64[]
    for r in 1:N_REC
        lo, la = _lcc_inv(Xtarget[r], Ytarget[r], C)
        push!(lon, lo); push!(lat, la)
    end
    projX = Float64[_lcc_fwd(lon[r], lat[r], C)[1] for r in 1:N_REC]
    projY = Float64[_lcc_fwd(lon[r], lat[r], C)[2] for r in 1:N_REC]
    @test projX ≈ Xtarget && projY ≈ Ytarget

    emis_annual = [10.0, 20.0, 30.0, 40.0, 50.0]
    is_VOC  = [1.0, 0.0, 1.0, 0.0, 0.0]
    is_NOx  = [0.0, 1.0, 0.0, 0.0, 0.0]
    is_NH3  = [0.0, 0.0, 0.0, 0.0, 1.0]
    is_SOx  = [0.0, 0.0, 0.0, 0.0, 0.0]
    is_PM25 = [0.0, 0.0, 0.0, 1.0, 0.0]
    TotalPop      = [100.0, 200.0, 300.0, 400.0]
    MortalityRate = [500.0, 600.0, 700.0, 800.0]
    FACT = 28766.639; POP_SCALE = 1.0465819687408728; MORT_SCALE = 1.025229357798165
    RR_K = 1.06; RR_L = 1.14
    APATHS = ["SR_SOA", "SR_pNO3", "SR_pNH4", "SR_pSO4", "SR_PrimaryPM25"]
    LVARS  = ["SOA", "pNO3", "pNH4", "pSO4", "PrimaryPM25"]
    base = Dict("SOA"=>1.0, "pNO3"=>2.0, "pNH4"=>3.0, "pSO4"=>4.0, "PrimaryPM25"=>5.0)
    fullSR = Dict{String,Array{Float64,3}}()
    for name in LVARS
        A = Array{Float64}(undef, N_LAYER, GRID, N_RCV)
        for l in 1:N_LAYER, s in 1:GRID, r in 1:N_RCV
            A[l, s, r] = (l - 1) * 1.0e6 + base[name] * 1000 + s * 10 + r
        end
        fullSR[name] = A
    end

    # ---- plain-Julia STEP-0 ORACLE ------------------------------------------
    cont(c, r) = W[c] <= projX[r] < Ev[c] && Sv[c] <= projY[r] < Nv[c]
    MEMBERS = sort(unique([c for c in 1:GRID for r in 1:N_REC if cont(c, r)]))
    @test MEMBERS == [1, 2, 4, 9]
    NP = length(MEMBERS)
    pathway_is = Dict("SOA"=>is_VOC, "pNO3"=>is_NOx, "pNH4"=>is_NH3,
                      "pSO4"=>is_SOx, "PrimaryPM25"=>is_PM25)
    oracle_E(is_p) = [sum((cont(MEMBERS[c], r) ? 1.0 : 0.0) * emis_annual[r] * is_p[r]
                          for r in 1:N_REC) for c in 1:NP]
    srC(name) = [fullSR[name][1, MEMBERS[c], rcv] for c in 1:NP, rcv in 1:N_RCV]
    oracle_conc(name) = (Ep = oracle_E(pathway_is[name]);
        [sum(srC(name)[c, rcv] * Ep[c] for c in 1:NP) for rcv in 1:N_RCV])
    oracle_TotalPM25 = [FACT * sum(oracle_conc(name)[rcv] for name in LVARS)
                        for rcv in 1:N_RCV]
    oracle_deaths(rr) = [(exp(log(rr) / 10 * oracle_TotalPM25[rcv]) - 1) *
                         TotalPop[rcv] * POP_SCALE *
                         MortalityRate[rcv] * MORT_SCALE / 100000 for rcv in 1:N_RCV]

    # ---- the AUTHORED document: loaders + coupling + clean model ------------
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
    scal(v) = Dict("type"=>"parameter", "default"=>v)
    # A data-fed parameter (esm 1.0.0 §8): the CONSUMER names the source and the
    # file variable, owns the units, and MUST declare a shape.
    dparam(shape, src, fv) = Dict("type"=>"parameter", "default"=>0.0,
        "shape"=>shape, "units"=>"1",
        "update"=>Dict("kind"=>"data", "source"=>src,
                       "from"=>Dict("file_variable"=>fv)))
    # the observeds' DEFINING equations, collected as the declarations are built
    obs_eqs = Any[]

    variables = Dict{String,Any}(
        "emis_lon"=>dparam(["emis_records"], "MockPts", "lon"),
        "emis_lat"=>dparam(["emis_records"], "MockPts", "lat"),
        "X"=>obs_v(obs_eqs, "X", ["emis_records"], _proj_obs(_Xbody)),
        "Y"=>obs_v(obs_eqs, "Y", ["emis_records"], _proj_obs(_Ybody)),
        "emis_annual"=>dparam(["emis_records"], "MockPts", "annual"),
        "is_VOC"=>dparam(["emis_records"], "MockPts", "vVOC"),
        "is_NOx"=>dparam(["emis_records"], "MockPts", "vNOx"),
        "is_NH3"=>dparam(["emis_records"], "MockPts", "vNH3"),
        "is_SOx"=>dparam(["emis_records"], "MockPts", "vSOx"),
        "is_PM25"=>dparam(["emis_records"], "MockPts", "vPM25"),
        "src_W"=>param(["src_cells"]), "src_S"=>param(["src_cells"]),
        "src_E"=>param(["src_cells"]), "src_N"=>param(["src_cells"]),
        "TotalPop"=>dparam(["rcv_cells"], "MockSR", "TotalPop"),
        "MortalityRate"=>dparam(["rcv_cells"], "MockSR", "MortalityRate"),
        "SR_SOA"=>dparam(["src_cells","rcv_cells"], "MockSR", "SOA"),
        "SR_pNO3"=>dparam(["src_cells","rcv_cells"], "MockSR", "pNO3"),
        "SR_pNH4"=>dparam(["src_cells","rcv_cells"], "MockSR", "pNH4"),
        "SR_pSO4"=>dparam(["src_cells","rcv_cells"], "MockSR", "pSO4"),
        "SR_PrimaryPM25"=>dparam(["src_cells","rcv_cells"], "MockSR", "PrimaryPM25"),
        "E_VOC"=>obs_v(obs_eqs, "E_VOC", ["src_cells"], _E_agg("is_VOC")),
        "E_NOx"=>obs_v(obs_eqs, "E_NOx", ["src_cells"], _E_agg("is_NOx")),
        "E_NH3"=>obs_v(obs_eqs, "E_NH3", ["src_cells"], _E_agg("is_NH3")),
        "E_SOx"=>obs_v(obs_eqs, "E_SOx", ["src_cells"], _E_agg("is_SOx")),
        "E_PM25"=>obs_v(obs_eqs, "E_PM25", ["src_cells"], _E_agg("is_PM25")),
        "conc_SOA"=>obs_v(obs_eqs, "conc_SOA", ["rcv_cells"], _conc_agg("SR_SOA","E_VOC")),
        "conc_pNO3"=>obs_v(obs_eqs, "conc_pNO3", ["rcv_cells"], _conc_agg("SR_pNO3","E_NOx")),
        "conc_pNH4"=>obs_v(obs_eqs, "conc_pNH4", ["rcv_cells"], _conc_agg("SR_pNH4","E_NH3")),
        "conc_pSO4"=>obs_v(obs_eqs, "conc_pSO4", ["rcv_cells"], _conc_agg("SR_pSO4","E_SOx")),
        "conc_PrimaryPM25"=>obs_v(obs_eqs, "conc_PrimaryPM25", ["rcv_cells"], _conc_agg("SR_PrimaryPM25","E_PM25")),
        "TotalPM25"=>obs_v(obs_eqs, "TotalPM25", ["rcv_cells"], _agg(["rcv"],
            Dict("rcv"=>Dict("from"=>"rcv_cells")),
            _op("*", "fact", _op("+", _ix("conc_SOA","rcv"), _ix("conc_pNO3","rcv"),
                _ix("conc_pNH4","rcv"), _ix("conc_pSO4","rcv"),
                _ix("conc_PrimaryPM25","rcv")));
            args=["conc_SOA","conc_pNO3","conc_pNH4","conc_pSO4","conc_PrimaryPM25"])),
        "deathsK"=>obs_v(obs_eqs, "deathsK", ["rcv_cells"], _deaths("rr_K")),
        "deathsL"=>obs_v(obs_eqs, "deathsL", ["rcv_cells"], _deaths("rr_L")),
        "lcc_n"=>scal(C.n), "lcc_rf"=>scal(C.rf), "lcc_rho0"=>scal(C.ρ0),
        "lcc_lam0"=>scal(C.λ0), "lcc_qp"=>scal(pi/4), "lcc_d2r"=>scal(pi/180),
        "fact"=>scal(FACT), "pop_scale"=>scal(POP_SCALE), "mort_scale"=>scal(MORT_SCALE),
        "rr_K"=>scal(RR_K), "rr_L"=>scal(RR_L))

    # data_sources: the SR loader declares a NATIVE-axes gated_select template
    # (fixed layer + a STALE gated_by name the record must override); the point
    # loader has none. `esio_format` is absent — providers are mocks here, so
    # nothing consults it (providers_from_document is the EarthSciIO ext's job).
    # esm 1.0.0 §8: a data source exposes NO `variables` — it is ingest config
    # only. The bindings live on the consuming parameters above (`dparam`).
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
    # is_* are data-fed PARAMETERS here (loader masks), unlike isrm.esm's
    # observeds — exercises the binding path on more than just coordinates.

    doc = Dict{String,Any}(
        "esm" => "0.9.0",
        "metadata" => Dict{String,Any}("name" => "prepare_pushdown_L1"),
        "index_sets" => Dict{String,Any}(
            "src_cells"    => Dict("kind"=>"interval", "size"=>GRID),
            "rcv_cells"    => Dict("kind"=>"interval", "size"=>N_RCV),
            "emis_records" => Dict("kind"=>"interval", "size"=>N_REC)),
        "data_sources" => data_sources,
        "models" => Dict{String,Any}("ISRM" =>
            Dict{String,Any}("variables"=>variables, "equations"=>obs_eqs)))

    # ---- idempotency guard: a desugared document does NOT re-desugar --------
    td = EA.desugar_pushdown(doc; model_name="ISRM")
    @test td !== doc
    @test EA.desugar_pushdown(td; model_name="ISRM") === td
    SET = td["metadata"]["x_esd"]["pushdown"]["gated_select"]["gated_by"]
    @test SET == "pd_support__src_cells"

    # ---- providers: mocks only, keyed by the CONSUMING PARAMETER's flattened
    #      name (esm 1.0.0: a source is not a component, so there is no
    #      "<Loader>.<var>" endpoint to key on) ------------------------------
    gmocks = Dict(v => MockGatedP1(fullSR[v], Any[]) for v in LVARS)
    providers = Dict{String,Any}(
        "ISRM.TotalPop" => MockConstP1(TotalPop),
        "ISRM.MortalityRate" => MockConstP1(MortalityRate),
        "ISRM.emis_lon" => MockConstP1(lon), "ISRM.emis_lat" => MockConstP1(lat),
        "ISRM.emis_annual" => MockConstP1(emis_annual),
        "ISRM.is_VOC" => MockConstP1(is_VOC), "ISRM.is_NOx" => MockConstP1(is_NOx),
        "ISRM.is_NH3" => MockConstP1(is_NH3), "ISRM.is_SOx" => MockConstP1(is_SOx),
        "ISRM.is_PM25" => MockConstP1(is_PM25))
    for v in LVARS
        providers["ISRM.SR_$v"] = gmocks[v]
    end

    # src rects ride const_arrays under their BARE authored names (the alias
    # injection must surface them under the flattened spelling).
    ca = Dict{String,Any}("src_W"=>W, "src_S"=>Sv, "src_E"=>Ev, "src_N"=>Nv)

    insp = EA.BuildInspection()
    prep = EA.esm_problem(doc, (0.0, 1.0); providers=providers, const_arrays=ca,
                      inspect=insp, pushdown_rewrite=true)
    @test prep isa EA.ESMProblem

    # ---- the gated mocks were fetched pre-sliced, never wholesale -----------
    for v in LVARS
        sel = [c for c in gmocks[v].calls if c[1] == :selection]
        whole = [c for c in gmocks[v].calls if c[1] == :wholesale]
        @test isempty(whole)
        @test length(sel) == 1
        @test sel[1][2][1] == 1                 # fixed layer, 1-based
        @test sel[1][2][2] == MEMBERS           # the record-derived gate members
        @test sel[1][2][3] === Colon()
    end

    # ---- results through the prepared document's own graph ------------------
    @test EA.observed_field(prep, "E_VOC")  ≈ oracle_E(is_VOC)
    @test EA.observed_field(prep, "ISRM.E_PM25") ≈ oracle_E(is_PM25)
    @test EA.observed_field(prep, "conc_SOA") ≈ oracle_conc("SOA")
    @test EA.observed_field(prep, "TotalPM25") ≈ oracle_TotalPM25
    @test EA.observed_field(prep, "deathsK") ≈ oracle_deaths(RR_K)
    @test EA.observed_field(prep, "deathsL") ≈ oracle_deaths(RR_L)
    @test_throws EA.SimulateError EA.observed_field(prep, "no_such_observed")

    # ---- the SAME run, with the binning bodies factored through a template --
    # esm-spec §9.6.4 Option B preserves `apply_expression_template` references
    # through `load`, so `esm_problem` runs the desugar on a document whose binning
    # body may be a reference rather than the containment `ifelse`. Whether the
    # pushdown fires MUST NOT depend on that (CONFORMANCE_SPEC §5.5.7), and this
    # is the numeric discharge of the claim: same gated selections, same fetched
    # slabs, same observed values — through the same public `esm_problem` surface.
    #
    # The template body names ONLY its own params. `emis_annual` and the `is_*`
    # masks are COUPLING-FED (`MockPts.annual → ISRM.emis_annual`), so naming them
    # in the body would trip flatten's
    # `template_body_references_coupling_rewritten_variable`; they ride as
    # bindings, which is exactly what that diagnostic tells authors to do.
    @testset "same run with the E bodies factored through a template" begin
        tdoc = deepcopy(doc)
        tm = tdoc["models"]["ISRM"]
        tpl_contain = _op("and",
            _op("<=", _ix("xmin", "c"), _ix("ptx", "r")),
            _op("<",  _ix("ptx", "r"),  _ix("xmax", "c")),
            _op("<=", _ix("ymin", "c"), _ix("pty", "r")),
            _op("<",  _ix("pty", "r"),  _ix("ymax", "c")))
        tm["expression_templates"] = Dict{String,Any}(
            "bin_emissions" => Dict{String,Any}(
                "params" => Any["xmin", "ymin", "xmax", "ymax", "ptx", "pty", "tot", "frac"],
                "body" => _op("*", _op("ifelse", tpl_contain, 1.0, 0.0),
                                   _op("*", _ix("tot", "r"), _ix("frac", "r")))))
        for (Ename, isp) in (("E_VOC", "is_VOC"), ("E_NOx", "is_NOx"),
                             ("E_NH3", "is_NH3"), ("E_SOx", "is_SOx"),
                             ("E_PM25", "is_PM25"))
            _defrhs(tm, Ename)["expr"] = Dict{String,Any}(
                "op" => "apply_expression_template", "args" => Any[],
                "name" => "bin_emissions",
                "bindings" => Dict{String,Any}(
                    "xmin" => "src_W", "ymin" => "src_S",
                    "xmax" => "src_E", "ymax" => "src_N",
                    "ptx" => "X", "pty" => "Y",
                    "tot" => "emis_annual", "frac" => isp))
        end
        tpl_before = deepcopy(tm["expression_templates"])

        trd = EA.desugar_pushdown(tdoc; model_name="ISRM")
        @test trd !== tdoc                                     # it fired
        @test trd["metadata"]["x_esd"]["pushdown"]["gated_select"]["gated_by"] == SET
        # the SHARED body is not edited — Option B's single lowering survives
        @test trd["models"]["ISRM"]["expression_templates"] == tpl_before
        # the CALL SITES are: each E now gathers the compact per-support rects
        for Ename in ("E_VOC", "E_NOx", "E_NH3", "E_SOx", "E_PM25")
            b = _defrhs(trd["models"]["ISRM"], Ename)["expr"]["bindings"]
            @test b["xmin"] == "pd_cell__src_cells__src_W"
            @test b["ymax"] == "pd_cell__src_cells__src_N"
            @test b["ptx"] == "X"                              # record side untouched
        end

        # Same provider KEYS as the run above — the consuming parameter's
        # flattened name. Keying these on the SOURCE ("MockSR.$v") would leave
        # the gated `ISRM.SR_$v` mocks in place and add a second, ungated
        # provider beside them, so the assertions below would read a wholesale
        # fetch that the rewrite never asked for.
        gmocks2 = Dict(v => MockGatedP1(fullSR[v], Any[]) for v in LVARS)
        providers2 = Dict{String,Any}(k => v for (k, v) in providers)
        for v in LVARS
            providers2["ISRM.SR_$v"] = gmocks2[v]
        end
        insp2 = EA.BuildInspection()
        prep2 = EA.esm_problem(tdoc, (0.0, 1.0); providers=providers2,
                           const_arrays=Dict{String,Any}("src_W"=>W, "src_S"=>Sv,
                                                         "src_E"=>Ev, "src_N"=>Nv),
                           inspect=insp2, pushdown_rewrite=true)
        @test prep2 isa EA.ESMProblem
        for v in LVARS
            sel = [c for c in gmocks2[v].calls if c[1] == :selection]
            @test isempty([c for c in gmocks2[v].calls if c[1] == :wholesale])
            @test length(sel) == 1
            @test sel[1][2][1] == 1
            @test sel[1][2][2] == MEMBERS                      # the same derived gate
            @test sel[1][2][3] === Colon()
        end
        @test EA.observed_field(prep2, "E_VOC")  ≈ oracle_E(is_VOC)
        @test EA.observed_field(prep2, "ISRM.E_PM25") ≈ oracle_E(is_PM25)
        @test EA.observed_field(prep2, "conc_SOA") ≈ oracle_conc("SOA")
        @test EA.observed_field(prep2, "TotalPM25") ≈ oracle_TotalPM25
        @test EA.observed_field(prep2, "deathsK") ≈ oracle_deaths(RR_K)
        @test EA.observed_field(prep2, "deathsL") ≈ oracle_deaths(RR_L)
    end
end

end # module PreparePushdownRecordGateTests
