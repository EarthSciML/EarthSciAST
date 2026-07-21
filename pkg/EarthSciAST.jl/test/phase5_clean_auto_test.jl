# FULLY-AUTOMATIC clean projection-pushdown path — Phase 5.
#
# This is the end of the projection-pushdown road: a CLEAN, full-domain model
# that needs NO hand-authored pushdown constructs AND NO caller-supplied
# projected coordinates. It closes the last caveat left by Phase 4
# (`auto_pushdown_rewrite_test.jl`), where the caller still handed in the
# already-projected `X`/`Y`.
#
# The author writes only:
#   (i)   a full-domain provider-backed `SR[src_cells, rcv]` (mock gated),
#   (ii)  `E` as the emission→cell binning `+`-aggregate over the FULL grid,
#   (iii) emission coordinates as RAW `lon`/`lat` (degrees), with an in-model
#         Lambert-conformal PROJECTION observed
#           `X[e] = lambert_conformal_forward_x(lon[e], lat[e])`,
#           `Y[e] = lambert_conformal_forward_y(lon[e], lat[e])`,
#         expanded to trig (`tan`/`sin`/`cos`/`^`) — an op vocabulary the
#         setup-time geometry language and value-invention's `_vi_eval` cannot
#         speak,
#   (iv)  NO derived set / NO producer / NO gated_select / NO member_factor.
#
# The ONLY runtime inputs are RAW `lon`/`lat` (+ the grid rects / emissions /
# receptor fields) and the gated provider. NO projected `X`/`Y` is supplied.
#
# The two automatic mechanisms under test, composed:
#   * Phase 5 Part A (LCC-at-build-time): `_derive_binning_coords` routes the
#     projection observed to the GENERAL build-time cell evaluator, so `X`/`Y`
#     are computed BEFORE value-invention and fed into `const_arrays` — the
#     caller never pre-projects.
#   * Phase 4 auto-rewrite (`pushdown_rewrite=true`): recognises the
#     `+`-aggregate / sparse-binned-factor pattern and GENERATES the four
#     Phase-2b constructs.
#
# Assertions: (1) the rewrite generated the four constructs; (2) Part A's
# build-time LCC projection produced `X`/`Y` == a plain-Julia forward-projection
# oracle, feeding value-invention; (3) `vi.members` == the support set the
# projected points bin into; (4) the gated provider got `selection == members`,
# no wholesale fetch; (5) conc / TotalPM25 / deaths == a plain-Julia STEP-0
# oracle to machine precision — with the only inputs being raw lon/lat + the
# provider.
#
# NOTE ON SCALE: full-SCALE (52411 src cells) validation through the observed
# evaluator is blocked by a separate, pre-existing type-instability (Wall #2),
# independent of this projection change. L1-scale machine precision is the
# Phase-5 acceptance criterion; Wall #2 remains as documented future work.

using Test
using EarthSciAST
import JSON3
# STRtree broad-phase fast path (Phase 2a/3a); the brute-force core is
# byte-identical, so this is a fast-path exercise, not a hard dependency.
import GeometryOps
import GeoInterface

const EA = EarthSciAST

# ---- small JSON AST builders (shared spelling with the sibling pushdown tests) --
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

# ---- Lambert conformal conic (two standard parallels), plain Julia ORACLE ----
# Reference for the identical formula compiled by the in-model observed below.
# Unit sphere (R = 1); the projection is a pure trig map. `lcc_inv` is used only
# to synthesise raw lon/lat that forward-project onto the chosen fixture grid, so
# the reusable L1 support set / oracle numerics carry over verbatim.
_d2r(d) = d * pi / 180
function _lcc_consts(lat1, lat2, lat0, lon0)
    φ1 = _d2r(lat1); φ2 = _d2r(lat2); φ0 = _d2r(lat0); λ0 = _d2r(lon0)
    n  = log(cos(φ1) / cos(φ2)) / log(tan(pi/4 + φ2/2) / tan(pi/4 + φ1/2))
    F  = cos(φ1) * tan(pi/4 + φ1/2)^n / n
    ρ0 = F / tan(pi/4 + φ0/2)^n
    return (n = n, rf = F, ρ0 = ρ0, λ0 = λ0)
end
# forward: raw lon/lat DEGREES → projected (x, y). Mirrors the in-model AST arm
# for arm (deg→rad, then the ρ/θ/x/y trig), so the build-time general-eval
# projection reproduces this bit-for-bit up to floating rounding.
function _lcc_fwd(lon_deg, lat_deg, c)
    latr = lat_deg * (pi/180)
    lonr = lon_deg * (pi/180)
    ρ = c.rf / tan(pi/4 + latr/2)^c.n
    θ = c.n * (lonr - c.λ0)
    return (ρ * sin(θ), c.ρ0 - ρ * cos(θ))
end
# inverse: projected (x, y) → raw lon/lat DEGREES.
function _lcc_inv(x, y, c)
    ρ = sign(c.n) * sqrt(x^2 + (c.ρ0 - y)^2)
    θ = atan(x, c.ρ0 - y)
    lonr = c.λ0 + θ / c.n
    latr = 2 * atan((c.rf / ρ)^(1 / c.n)) - pi/2
    return (rad2deg(lonr), rad2deg(latr))
end

# GATED PROVIDER MOCK — records every call; slices the synthetic SR per selection.
mutable struct MockSRP5
    full::Dict{String,Array{Float64,3}}
    gate::Dict{String,Any}
    calls::Vector{Any}
end
EA.provider_gate_spec(m::MockSRP5) = m.gate
EA.provider_supports_selection(m::MockSRP5) = true
EA.provider_refresh_times(m::MockSRP5) = Float64[]
function EA.provider_sample(m::MockSRP5, ::Real; selection=nothing)
    if selection === nothing
        push!(m.calls, (:wholesale,))
        return Dict{String,Any}(k => v for (k, v) in m.full)
    end
    push!(m.calls, (:selection, deepcopy(selection)))
    lay, src, rcv = selection[1], selection[2], selection[3]
    out = Dict{String,Any}()
    for (k, v) in m.full
        out[k] = v[lay:lay, src, rcv]
    end
    return out
end

@testset "fully-automatic clean projection-pushdown (Phase 5: LCC@build + auto-rewrite)" begin

    # ---- fixture grid + emissions (byte-identical L1 numerics) ---------------
    GRID = 9; N_RCV = 4; N_REC = 5; N_LAYER = 3
    W = zeros(GRID); Sv = zeros(GRID); Ev = zeros(GRID); Nv = zeros(GRID)
    for row in 1:3, col in 1:3
        k = (row - 1) * 3 + col
        W[k] = (col - 1) * 2.0; Ev[k] = col * 2.0
        Sv[k] = (row - 1) * 2.0; Nv[k] = row * 2.0
    end

    # LCC params (InMAP-style two-parallel conic) + target PROJECTED coordinates
    # (the reusable L1 fixture) → synthesise the RAW lon/lat that project onto
    # them. ONLY lon/lat are handed to the build; X/Y are recomputed at build
    # time by Part A's general-eval projection.
    LAT1, LAT2, LAT0, LON0 = 33.0, 45.0, 40.0, -97.0
    C = _lcc_consts(LAT1, LAT2, LAT0, LON0)
    Xtarget = [1.0, 3.0, 1.0, 5.0, 1.5]
    Ytarget = [1.0, 1.0, 3.0, 5.0, 1.5]
    lon = Float64[]; lat = Float64[]
    for r in 1:N_REC
        lo, la = _lcc_inv(Xtarget[r], Ytarget[r], C)
        push!(lon, lo); push!(lat, la)
    end
    # the forward-projection ORACLE (what the build-time general map must produce)
    projX = Float64[_lcc_fwd(lon[r], lat[r], C)[1] for r in 1:N_REC]
    projY = Float64[_lcc_fwd(lon[r], lat[r], C)[2] for r in 1:N_REC]
    @test projX ≈ Xtarget                                # round-trip sanity
    @test projY ≈ Ytarget

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
    PATHS = ["SR_SOA", "SR_pNO3", "SR_pNH4", "SR_pSO4", "SR_PrimaryPM25"]
    base = Dict("SR_SOA"=>1.0, "SR_pNO3"=>2.0, "SR_pNH4"=>3.0, "SR_pSO4"=>4.0,
                "SR_PrimaryPM25"=>5.0)
    fullSR = Dict{String,Array{Float64,3}}()
    for name in PATHS
        A = Array{Float64}(undef, N_LAYER, GRID, N_RCV)
        for l in 1:N_LAYER, s in 1:GRID, r in 1:N_RCV
            A[l, s, r] = (l - 1) * 1.0e6 + base[name] * 1000 + s * 10 + r
        end
        fullSR[name] = A
    end

    # ---- plain-Julia STEP-0 ORACLE (member set computed from PROJECTED coords) ----
    # containment is over the projected X/Y (the actual build-time values); the
    # points are cell-INTERIOR, so it is identical to the L1 support set.
    cont(c, r) = W[c] <= projX[r] < Ev[c] && Sv[c] <= projY[r] < Nv[c]
    MEMBERS = sort(unique([c for c in 1:GRID for r in 1:N_REC if cont(c, r)]))
    @test MEMBERS == [1, 2, 4, 9]                        # the reusable L1 support set
    NP = length(MEMBERS)
    cellW = [W[MEMBERS[c]]  for c in 1:NP]
    cellS = [Sv[MEMBERS[c]] for c in 1:NP]
    cellE = [Ev[MEMBERS[c]] for c in 1:NP]
    cellN = [Nv[MEMBERS[c]] for c in 1:NP]
    incell(c, r) = cellW[c] <= projX[r] < cellE[c] && cellS[c] <= projY[r] < cellN[c]
    pathway_is = Dict("SR_SOA"=>is_VOC, "SR_pNO3"=>is_NOx, "SR_pNH4"=>is_NH3,
                      "SR_pSO4"=>is_SOx, "SR_PrimaryPM25"=>is_PM25)
    oracle_E(is_p) = [sum((incell(c, r) ? 1.0 : 0.0) * emis_annual[r] * is_p[r]
                          for r in 1:N_REC) for c in 1:NP]
    srC(name) = [fullSR[name][1, MEMBERS[c], rcv] for c in 1:NP, rcv in 1:N_RCV]
    oracle_conc(name) = (Ep = oracle_E(pathway_is[name]);
        [sum(srC(name)[c, rcv] * Ep[c] for c in 1:NP) for rcv in 1:N_RCV])
    oracle_TotalPM25 = [FACT * sum(oracle_conc(name)[rcv] for name in PATHS)
                        for rcv in 1:N_RCV]
    oracle_deaths(rr) = [(exp(log(rr) / 10 * oracle_TotalPM25[rcv]) - 1) *
                         TotalPop[rcv] * POP_SCALE *
                         MortalityRate[rcv] * MORT_SCALE / 100000 for rcv in 1:N_RCV]

    # ---- CLEAN model: LCC projection observeds; NO manual pushdown constructs ----
    # projected-coordinate observeds — trig over raw lon/lat + scalar LCC params.
    # deg→rad then the conic ρ/θ/x/y. `tan` is OUTSIDE the setup-time geometry
    # vocabulary, so `_body_needs_general_eval` fires and Part A routes these to
    # the general build-time cell evaluator.
    _latr(e) = _op("*", _ix("lat", e), "lcc_d2r")
    _lonr(e) = _op("*", _ix("lon", e), "lcc_d2r")
    _rho(e)  = _op("/", "lcc_rf",
                   _op("^", _op("tan", _op("+", "lcc_qp", _op("/", _latr(e), 2.0))), "lcc_n"))
    _theta(e)= _op("*", "lcc_n", _op("-", _lonr(e), "lcc_lam0"))
    _Xbody(e) = _op("*", _rho(e), _op("sin", _theta(e)))
    _Ybody(e) = _op("-", "lcc_rho0", _op("*", _rho(e), _op("cos", _theta(e))))
    _proj_obs(bodyfn) = _agg(["e"], Dict("e"=>Dict("from"=>"emis_records")),
                             bodyfn("e"); args=["lon", "lat"])

    function clean_doc(; conc_semiring=nothing)
        _contain = _op("and",
            _op("<=", _ix("W", "c"), _ix("X", "r")), _op("<", _ix("X", "r"), _ix("E", "c")),
            _op("<=", _ix("S", "c"), _ix("Y", "r")), _op("<", _ix("Y", "r"), _ix("N", "c")))
        _E_agg(is_p) = _agg(["c"],
            Dict("c"=>Dict("from"=>"src_cells"), "r"=>Dict("from"=>"emis_records")),
            _op("*", _op("ifelse", _contain, 1.0, 0.0),
                     _op("*", _ix("emis_annual", "r"), _ix(is_p, "r")));
            reduce="+", args=["W","S","E","N","X","Y","emis_annual",is_p])

        _conc_agg(SRname, Ename) = _agg(["rcv"],
            Dict("s"=>Dict("from"=>"src_cells"), "rcv"=>Dict("from"=>"rcv_cells")),
            _op("*", _ix(SRname, "s", "rcv"), _ix(Ename, "s"));
            (conc_semiring === nothing ? (reduce="+",) : (semiring=conc_semiring,))...,
            args=[SRname, Ename])

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
            # RAW geographic coordinates (the ONLY emission-coordinate inputs).
            "lon"=>param(["emis_records"]), "lat"=>param(["emis_records"]),
            # PROJECTED coordinates — DERIVED in-model by the LCC forward map.
            "X"=>obs(["emis_records"], _proj_obs(_Xbody)),
            "Y"=>obs(["emis_records"], _proj_obs(_Ybody)),
            "emis_annual"=>param(["emis_records"]),
            "is_VOC"=>param(["emis_records"]), "is_NOx"=>param(["emis_records"]),
            "is_NH3"=>param(["emis_records"]), "is_SOx"=>param(["emis_records"]),
            "is_PM25"=>param(["emis_records"]),
            "W"=>param(["src_cells"]), "S"=>param(["src_cells"]),
            "E"=>param(["src_cells"]), "N"=>param(["src_cells"]),
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
            # scalar LCC constants (build-time-available const params).
            "lcc_n"=>scal(C.n), "lcc_rf"=>scal(C.rf), "lcc_rho0"=>scal(C.ρ0),
            "lcc_lam0"=>scal(C.λ0), "lcc_qp"=>scal(pi/4), "lcc_d2r"=>scal(pi/180),
            "fact"=>scal(FACT), "pop_scale"=>scal(POP_SCALE), "mort_scale"=>scal(MORT_SCALE),
            "rr_K"=>scal(RR_K), "rr_L"=>scal(RR_L))

        return Dict(
            "esm" => "0.9.0",
            "metadata" => Dict("name" => "isrm_clean_auto_L1"),
            "index_sets" => Dict(
                "src_cells"    => Dict("kind"=>"interval", "size"=>GRID),
                "rcv_cells"    => Dict("kind"=>"interval", "size"=>N_RCV),
                "emis_records" => Dict("kind"=>"interval", "size"=>N_REC)),
            "models" => Dict("ISRM" => Dict("variables"=>variables, "equations"=>[])))
    end

    # generated (deterministic) construct names
    SET  = "pd_support__src_cells"
    FAQ  = "pd_faq__src_cells"
    MEMV = "pd_members__src_cells"
    MF   = "pd_member_factor__src_cells"

    # ---- const arrays: RAW lon/lat only (NO projected X/Y), grid + fields -----
    ca = Dict{String,Any}(
        "lon"=>lon, "lat"=>lat, "emis_annual"=>emis_annual,
        "is_VOC"=>is_VOC, "is_NOx"=>is_NOx, "is_NH3"=>is_NH3,
        "is_SOx"=>is_SOx, "is_PM25"=>is_PM25,
        "W"=>W, "S"=>Sv, "E"=>Ev, "N"=>Nv,
        "TotalPop"=>TotalPop, "MortalityRate"=>MortalityRate)
    @test !haskey(ca, "X") && !haskey(ca, "Y")           # NO projected coords supplied

    doc = clean_doc()
    # the authored model carries NONE of the four pushdown constructs
    @test !haskey(doc["index_sets"], SET)
    @test !haskey(doc["models"]["ISRM"]["variables"], MF)
    @test !haskey(doc["models"]["ISRM"]["variables"], MEMV)
    @test isempty(doc["models"]["ISRM"]["equations"])

    # ============================================================
    # ASSERTION 1 — the auto-rewrite GENERATED the four Phase-2b constructs.
    # ============================================================
    td = EA.desugar_pushdown(doc; model_name="ISRM")
    @test td !== doc
    @test haskey(td["index_sets"], SET)
    ds = td["index_sets"][SET]
    @test ds["kind"] == "derived" && ds["from_faq"] == FAQ && ds["member_factor"] == MF
    tvars = td["models"]["ISRM"]["variables"]
    @test tvars[MF]["type"] == "parameter" && tvars[MF]["shape"] == [SET]
    @test tvars[MEMV]["type"] == "state"
    teqs = td["models"]["ISRM"]["equations"]
    prod_eqs = [eq for eq in teqs if get(get(eq, "rhs", Dict()), "id", nothing) == FAQ]
    @test length(prod_eqs) == 1
    prhs = prod_eqs[1]["rhs"]
    @test prhs["distinct"] === true && prhs["semiring"] == "bool_and_or"
    ov = first(j["overlap"] for j in prhs["join"] if haskey(j, "overlap"))
    @test ov["src_env"] == ["X", "Y"]                    # the PROJECTED point coords
    @test ov["tgt_env"] == ["W", "S", "E", "N"]
    gs = td["metadata"]["x_esd"]["pushdown"]["gated_select"]
    @test gs["gated_by"] == SET && Set(gs["applies_to"]) == Set(PATHS)
    @test tvars["SR_SOA"]["shape"] == [SET, "rcv_cells"] && tvars["E_VOC"]["shape"] == [SET]
    # the LCC projection observeds survive the rewrite, still over emis_records
    @test tvars["X"]["type"] == "observed" && tvars["X"]["shape"] == ["emis_records"]
    @test tvars["Y"]["type"] == "observed"

    # ============================================================
    # ASSERTION 2 — Part A: build-time LCC projection produces X/Y for VI, and
    #               vi.members == the projected-point support set (only lon/lat in).
    # ============================================================
    f = EA.load(td; base_path=pwd())
    model = EA._select_model(f, "ISRM")
    # raw lon/lat only; the scalar LCC params ride the model defaults.
    ca_vi = Dict{String,Any}("lon"=>lon, "lat"=>lat, "W"=>W, "S"=>Sv, "E"=>Ev, "N"=>Nv)
    @test !haskey(ca_vi, "X") && !haskey(ca_vi, "Y")
    vt = EA._vi_skolem_index_targets(model)
    @test "X" in vt && "Y" in vt                         # projection targets detected
    derived = EA._derive_binning_coords(model, f.index_sets, ca_vi,
                                        Dict{String,Float64}(), vt)
    @test haskey(derived, "X") && haskey(derived, "Y")   # Part A projected at build time
    @test derived["X"] ≈ projX                           # == plain-Julia forward oracle
    @test derived["Y"] ≈ projY
    merge!(ca_vi, derived)
    vi = EA.materialize_value_invention(model, f.index_sets, ca_vi, Dict{String,Float64}())
    @test sort(collect(Int, vi.members[FAQ])) == MEMBERS
    @test vi.extents[FAQ] == NP

    # ============================================================
    # BUILD through the front door: auto-rewrite ON, ONLY raw lon/lat + provider.
    # ============================================================
    gate = Dict{String,Any}(
        "axes" => Any[Dict("fixed"=>[0]), Dict("gated_by"=>SET), "all"],
        "applies_to" => PATHS)
    mock = MockSRP5(fullSR, gate, Any[])
    insp = EA.BuildInspection()
    f!, u0, p, _tspan, var_map = EA.build_evaluator(doc;
        model_name = "ISRM", const_arrays = ca, inspect = insp,
        pushdown_rewrite = true,
        _gated_providers = Dict{String,Any}("ISRM_SR" => mock), _sample_time = 0.0)

    # X/Y were projected at BUILD time and landed in const_arrays for VI/E.
    @test haskey(insp.const_arrays, "X") && haskey(insp.const_arrays, "Y")
    @test Vector{Float64}(insp.const_arrays["X"]) ≈ projX
    @test Vector{Float64}(insp.const_arrays["Y"]) ≈ projY

    # ============================================================
    # ASSERTION 3 — gated provider got selection == members, no wholesale fetch.
    # ============================================================
    sel_calls = [c for c in mock.calls if c[1] == :selection]
    whole_calls = [c for c in mock.calls if c[1] == :wholesale]
    @test length(whole_calls) == 0
    @test length(sel_calls) >= 1
    sel = sel_calls[1][2]
    @test sel[1] == 1
    @test sel[2] == MEMBERS
    @test sel[3] === Colon()

    # members fed back as the generated member_factor; compact SR merged.
    @test haskey(insp.const_arrays, MF)
    @test Vector{Float64}(insp.const_arrays[MF]) == Float64.(MEMBERS)
    for name in PATHS
        @test haskey(insp.const_arrays, name)
        @test size(insp.const_arrays[name]) == (NP, N_RCV)
        @test insp.const_arrays[name] ≈ srC(name)
    end

    # ============================================================
    # ASSERTION 4 — downstream E_*/conc_*/TotalPM25/deaths == STEP-0 oracle.
    # ============================================================
    cell_cells = [[c] for c in 1:NP]
    ev(name) = (expr = get(insp.observed_exprs, "ISRM.$name",
                           get(insp.observed_exprs, name, nothing));
        expr === nothing ? error("no observed expr for $name") :
        EA.evaluate_cellwise(expr, cell_cells; const_arrays=insp.const_arrays,
            params=EA._param_scope_with_aliases(insp.params)))
    @test ev("E_VOC")  ≈ oracle_E(is_VOC)
    @test ev("E_NOx")  ≈ oracle_E(is_NOx)
    @test ev("E_NH3")  ≈ oracle_E(is_NH3)
    @test ev("E_SOx")  ≈ oracle_E(is_SOx)
    @test ev("E_PM25") ≈ oracle_E(is_PM25)

    rt(name) = (fld = EA._observed_field(insp, f, "ISRM", name);
        fld === nothing ? error("observed $name not evaluable") : fld[1])
    @test rt("conc_SOA")  ≈ oracle_conc("SR_SOA")
    @test rt("conc_pNO3") ≈ oracle_conc("SR_pNO3")
    @test rt("conc_pNH4") ≈ oracle_conc("SR_pNH4")
    @test rt("conc_pSO4") ≈ oracle_conc("SR_pSO4")
    @test rt("conc_PrimaryPM25") ≈ oracle_conc("SR_PrimaryPM25")
    @test rt("TotalPM25") ≈ oracle_TotalPM25
    @test rt("deathsK")   ≈ oracle_deaths(RR_K)
    @test rt("deathsL")   ≈ oracle_deaths(RR_L)

    # ============================================================
    # NEGATIVE — the projection alone must NOT trip the rewrite: a `max`-semiring
    # conc (same shape, same LCC coords) leaves the rewrite UNFIRED.
    # ============================================================
    @testset "max-semiring conc → rewrite does NOT fire" begin
        doc_max = clean_doc(; conc_semiring="max_product")
        td_max = EA.desugar_pushdown(doc_max; model_name="ISRM")
        @test td_max === doc_max
        @test !haskey(td_max["index_sets"], SET)
        @test !haskey(td_max["models"]["ISRM"]["variables"], MF)
        @test !haskey(get(td_max["metadata"], "x_esd", Dict()), "pushdown")
    end
end
