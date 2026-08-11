# PUBLIC-SURFACE projection pushdown — Phase 1 (clean consolidation).
#
# Phase 4/5 proved the automatic rewrite + gated deferral through the PRIVATE
# `build_evaluator` front door (`_gated_providers`, hand-authored gate dicts).
# This test drives the same clean pattern through the PUBLIC `prepare` surface:
#
#   * `prepare(input; pushdown_rewrite=true, providers=…)` — the rewrite runs
#     on the AUTHORED document BEFORE flattening (post-flatten the coupling
#     substitution has split equation names from variable-expression names and
#     the pattern no longer matches);
#   * the engine derives every provider gate from the rewrite's OWN record
#     (`metadata.x_esd.pushdown.gated_select`) + the document coupling — the
#     caller hand-authors NO gate dict and implements NO `provider_gate_spec`;
#   * the loader's `metadata.x_esd.gated_select.axes` template contributes the
#     NATIVE axis layout (the `fixed` emission-layer axis), with the record's
#     GENERATED set name substituted over the template's stale one;
#   * `observed_field(prep, insp, name)` reads the results back through the
#     prepared document's own graph.
#
# The fixture mirrors isrm.esm's structure: data_loaders + variable_map
# coupling + a clean model with in-model LCC projection observeds, at the
# reusable 9-cell L1 scale with the L1 oracle numerics.

module PreparePushdownRecordGateTests

using Test
using EarthSciAST
import GeometryOps
import GeoInterface

const EA = EarthSciAST

# ---- small JSON AST builders (shared spelling with the sibling tests) -------
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

@testset "prepare(pushdown_rewrite=true) + record-derived provider gating" begin

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
        "lcc_n"=>scal(C.n), "lcc_rf"=>scal(C.rf), "lcc_rho0"=>scal(C.ρ0),
        "lcc_lam0"=>scal(C.λ0), "lcc_qp"=>scal(pi/4), "lcc_d2r"=>scal(pi/180),
        "fact"=>scal(FACT), "pop_scale"=>scal(POP_SCALE), "mort_scale"=>scal(MORT_SCALE),
        "rr_K"=>scal(RR_K), "rr_L"=>scal(RR_L))

    # data_loaders: the SR loader declares a NATIVE-axes gated_select template
    # (fixed layer + a STALE gated_by name the record must override); the point
    # loader has none. `esio_format` is absent — providers are mocks here, so
    # nothing consults it (providers_from_document is the EarthSciIO ext's job).
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
    # is_* are PARAMETERS here (loader-fed masks), unlike isrm.esm's observeds —
    # exercises the coupling alias path on more than just coordinates.

    doc = Dict{String,Any}(
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

    # ---- idempotency guard: a desugared document does NOT re-desugar --------
    td = EA.desugar_pushdown(doc; model_name="ISRM")
    @test td !== doc
    @test EA.desugar_pushdown(td; model_name="ISRM") === td
    SET = td["metadata"]["x_esd"]["pushdown"]["gated_select"]["gated_by"]
    @test SET == "pd_support__src_cells"

    # ---- providers: mocks only, keyed by the document's loader variables ----
    gmocks = Dict(v => MockGatedP1(fullSR[v], Any[]) for v in LVARS)
    providers = Dict{String,Any}(
        "MockSR.TotalPop" => MockConstP1(TotalPop),
        "MockSR.MortalityRate" => MockConstP1(MortalityRate),
        "MockPts.lon" => MockConstP1(lon), "MockPts.lat" => MockConstP1(lat),
        "MockPts.annual" => MockConstP1(emis_annual),
        "MockPts.vVOC" => MockConstP1(is_VOC), "MockPts.vNOx" => MockConstP1(is_NOx),
        "MockPts.vNH3" => MockConstP1(is_NH3), "MockPts.vSOx" => MockConstP1(is_SOx),
        "MockPts.vPM25" => MockConstP1(is_PM25))
    for v in LVARS
        providers["MockSR.$v"] = gmocks[v]
    end

    # src rects ride const_arrays under their BARE authored names (the alias
    # injection must surface them under the flattened spelling).
    ca = Dict{String,Any}("src_W"=>W, "src_S"=>Sv, "src_E"=>Ev, "src_N"=>Nv)

    insp = EA.BuildInspection()
    prep = EA.prepare(doc; providers=providers, const_arrays=ca,
                      inspect=insp, pushdown_rewrite=true)
    @test prep isa EA.PreparedModel

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
    @test EA.observed_field(prep, insp, "E_VOC")  ≈ oracle_E(is_VOC)
    @test EA.observed_field(prep, insp, "ISRM.E_PM25") ≈ oracle_E(is_PM25)
    @test EA.observed_field(prep, insp, "conc_SOA") ≈ oracle_conc("SOA")
    @test EA.observed_field(prep, insp, "TotalPM25") ≈ oracle_TotalPM25
    @test EA.observed_field(prep, insp, "deathsK") ≈ oracle_deaths(RR_K)
    @test EA.observed_field(prep, insp, "deathsL") ≈ oracle_deaths(RR_L)
    @test_throws EA.SimulateError EA.observed_field(prep, insp, "no_such_observed")
end

end # module PreparePushdownRecordGateTests
