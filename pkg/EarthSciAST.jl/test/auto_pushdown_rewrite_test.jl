# Automatic projection-pushdown DESUGAR — Phase 4.
#
# The Phase-2b `pushdown_edge_test.jl` HAND-AUTHORS four constructs (a derived
# IndexSet, a `distinct` producer, a `member_factor` const var, and a gated
# provider). This test proves Phase 4: the author writes a CLEAN, full-domain
# model — full-domain provider-backed `SR[src_cells, rcv]`, `E` as the binning
# aggregate, and NO derived set / NO producer / NO gated_select / NO
# member_factor — and `desugar_pushdown` RECOGNISES the `+`-aggregate /
# sparse-binned-factor pattern and GENERATES exactly those four constructs, so
# the existing 2b pipeline reproduces the SAME plain-Julia STEP-0 oracle as L1.
#
# Assertions: (1) the rewrite generated the derived set + producer +
# gated_select + member_factor (inspected on the transformed model); (2)
# `vi.members == [1,2,4,9]` — the identical L1 support set on the identical
# fixture; (3) the gated provider got `selection == members`, no wholesale
# fetch; (4) conc / TotalPM25 / deaths == the L1 oracle to machine precision.
# NEGATIVE: the same model with a `max`-semiring conc leaves the rewrite unfired.

# Wrapped in a module so this file's local AST-builder helpers (`_op`, `_ix`, …)
# stay isolated from other test files' identically-named helpers in the shared
# `Main` namespace — otherwise `array_ops_test.jl`'s more-specific
# `_op(::AbstractString, …)` (which builds `ASTExpr[…]`) shadows the Dict-based
# `_op` below and dispatch fails with a Dict→ASTExpr convert error.
module AutoPushdownRewriteTests

using Test
using EarthSciAST
import JSON3
# The STRtree broad-phase fast path (Phase 2a/3a) via GeometryOps/GeoInterface;
# the dependency-free brute-force core is byte-identical, so this is a fast-path
# exercise, not a hard dependency.
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

# GATED PROVIDER MOCK — records every call; slices the synthetic SR per selection.
# (Uniquely named to coexist with pushdown_edge_test.jl's MockSR under runtests.)
mutable struct MockSRAuto
    full::Dict{String,Array{Float64,3}}
    gate::Dict{String,Any}
    calls::Vector{Any}
end
EA.provider_gate_spec(m::MockSRAuto) = m.gate
EA.provider_supports_selection(m::MockSRAuto) = true
EA.provider_refresh_times(m::MockSRAuto) = Float64[]
function EA.provider_sample(m::MockSRAuto, ::Real; selection=nothing)
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

@testset "automatic pushdown rewrite — desugar to Phase-2b (Phase 4)" begin

    # ---- shared fixture (byte-identical numerics to the L1 milestone) --------
    GRID = 9; N_RCV = 4; N_REC = 5; N_LAYER = 3
    W = zeros(GRID); Sv = zeros(GRID); Ev = zeros(GRID); Nv = zeros(GRID)
    for row in 1:3, col in 1:3
        k = (row - 1) * 3 + col
        W[k] = (col - 1) * 2.0; Ev[k] = col * 2.0
        Sv[k] = (row - 1) * 2.0; Nv[k] = row * 2.0
    end
    X = [1.0, 3.0, 1.0, 5.0, 1.5]
    Y = [1.0, 1.0, 3.0, 5.0, 1.5]
    HAND_MEMBERS = [1, 2, 4, 9]
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

    # ---- plain-Julia STEP-0 ORACLE (identical to L1) -------------------------
    pathway_is = Dict("SR_SOA"=>is_VOC, "SR_pNO3"=>is_NOx, "SR_pNH4"=>is_NH3,
                      "SR_pSO4"=>is_SOx, "SR_PrimaryPM25"=>is_PM25)
    cellW = [W[HAND_MEMBERS[c]] for c in 1:length(HAND_MEMBERS)]
    cellS = [Sv[HAND_MEMBERS[c]] for c in 1:length(HAND_MEMBERS)]
    cellE = [Ev[HAND_MEMBERS[c]] for c in 1:length(HAND_MEMBERS)]
    cellN = [Nv[HAND_MEMBERS[c]] for c in 1:length(HAND_MEMBERS)]
    incell(c, r) = cellW[c] <= X[r] < cellE[c] && cellS[c] <= Y[r] < cellN[c]
    NP = length(HAND_MEMBERS)
    oracle_E(is_p) = [sum((incell(c, r) ? 1.0 : 0.0) * emis_annual[r] * is_p[r]
                          for r in 1:N_REC) for c in 1:NP]
    srC(name) = [fullSR[name][1, HAND_MEMBERS[c], rcv] for c in 1:NP, rcv in 1:N_RCV]
    oracle_conc(name) = (Ep = oracle_E(pathway_is[name]);
        [sum(srC(name)[c, rcv] * Ep[c] for c in 1:NP) for rcv in 1:N_RCV])
    oracle_TotalPM25 = [FACT * sum(oracle_conc(name)[rcv] for name in PATHS)
                        for rcv in 1:N_RCV]
    oracle_deaths(rr) = [(exp(log(rr) / 10 * oracle_TotalPM25[rcv]) - 1) *
                         TotalPop[rcv] * POP_SCALE *
                         MortalityRate[rcv] * MORT_SCALE / 100000 for rcv in 1:N_RCV]

    # ---- CLEAN model — NO derived set / producer / gated_select / member_factor.
    # `conc_semiring` lets the negative test flip to a `max`-semiring aggregate.
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
            "X"=>param(["emis_records"]), "Y"=>param(["emis_records"]),
            "emis_annual"=>param(["emis_records"]),
            "is_VOC"=>param(["emis_records"]), "is_NOx"=>param(["emis_records"]),
            "is_NH3"=>param(["emis_records"]), "is_SOx"=>param(["emis_records"]),
            "is_PM25"=>param(["emis_records"]),
            "W"=>param(["src_cells"]), "S"=>param(["src_cells"]),
            "E"=>param(["src_cells"]), "N"=>param(["src_cells"]),
            "TotalPop"=>param(["rcv_cells"]), "MortalityRate"=>param(["rcv_cells"]),
            # Provider-backed FULL-DOMAIN source-receptor arrays [src_cells, rcv_cells].
            "SR_SOA"=>param(["src_cells","rcv_cells"]),
            "SR_pNO3"=>param(["src_cells","rcv_cells"]),
            "SR_pNH4"=>param(["src_cells","rcv_cells"]),
            "SR_pSO4"=>param(["src_cells","rcv_cells"]),
            "SR_PrimaryPM25"=>param(["src_cells","rcv_cells"]),
            # E over the FULL cell domain (binning aggregate).
            "E_VOC"=>obs(["src_cells"], _E_agg("is_VOC")),
            "E_NOx"=>obs(["src_cells"], _E_agg("is_NOx")),
            "E_NH3"=>obs(["src_cells"], _E_agg("is_NH3")),
            "E_SOx"=>obs(["src_cells"], _E_agg("is_SOx")),
            "E_PM25"=>obs(["src_cells"], _E_agg("is_PM25")),
            # conc = Σ_{s∈src_cells} SR[s,rcv]·E[s].
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
            "fact"=>scal(FACT), "pop_scale"=>scal(POP_SCALE), "mort_scale"=>scal(MORT_SCALE),
            "rr_K"=>scal(RR_K), "rr_L"=>scal(RR_L))

        return Dict(
            "esm" => "0.9.0",
            "metadata" => Dict("name" => "isrm_clean_L1"),
            "index_sets" => Dict(
                "src_cells"    => Dict("kind"=>"interval", "size"=>GRID),
                "rcv_cells"    => Dict("kind"=>"interval", "size"=>N_RCV),
                "emis_records" => Dict("kind"=>"interval", "size"=>N_REC)),
            "models" => Dict("ISRM" => Dict("variables"=>variables, "equations"=>[])))
    end

    # generated (deterministic) names
    SET  = "pd_support__src_cells"
    FAQ  = "pd_faq__src_cells"
    MEMV = "pd_members__src_cells"
    MF   = "pd_member_factor__src_cells"

    ca = Dict{String,Any}(
        "X"=>X, "Y"=>Y, "emis_annual"=>emis_annual,
        "is_VOC"=>is_VOC, "is_NOx"=>is_NOx, "is_NH3"=>is_NH3,
        "is_SOx"=>is_SOx, "is_PM25"=>is_PM25,
        "W"=>W, "S"=>Sv, "E"=>Ev, "N"=>Nv,
        "TotalPop"=>TotalPop, "MortalityRate"=>MortalityRate)

    doc = clean_doc()

    # ============================================================
    # ASSERTION 1 — the rewrite GENERATED the four Phase-2b constructs.
    # ============================================================
    td = EA.desugar_pushdown(doc; model_name="ISRM")
    @test td !== doc                                    # a transformed copy

    # (a) derived IndexSet
    @test haskey(td["index_sets"], SET)
    ds = td["index_sets"][SET]
    @test ds["kind"] == "derived"
    @test ds["from_faq"] == FAQ
    @test ds["member_factor"] == MF

    tvars = td["models"]["ISRM"]["variables"]
    # (b) member_factor const parameter + the producer's member state var
    @test haskey(tvars, MF)
    @test tvars[MF]["type"] == "parameter"
    @test tvars[MF]["shape"] == [SET]
    @test haskey(tvars, MEMV)
    @test tvars[MEMV]["type"] == "state"

    # (c) the `distinct` producer aggregate
    teqs = td["models"]["ISRM"]["equations"]
    prod_eqs = [eq for eq in teqs if get(get(eq, "rhs", Dict()), "id", nothing) == FAQ]
    @test length(prod_eqs) == 1
    prhs = prod_eqs[1]["rhs"]
    @test prhs["distinct"] === true
    @test prhs["semiring"] == "bool_and_or"
    @test prhs["key"]["op"] == "skolem"
    @test haskey(prhs, "filter")
    @test any(j -> haskey(j, "overlap"), prhs["join"])
    ov = first(j["overlap"] for j in prhs["join"] if haskey(j, "overlap"))
    @test ov["src_env"] == ["X", "Y"]                    # points
    @test ov["tgt_env"] == ["W", "S", "E", "N"]          # rect [xmin,ymin,xmax,ymax]

    # (d) the inspectable gated_select record (under metadata.x_esd, the spec's
    #     free-form extension point, so the doc still passes `load` schema val)
    pdrec = td["metadata"]["x_esd"]["pushdown"]
    gs = pdrec["gated_select"]
    @test gs["gated_by"] == SET
    @test Set(gs["applies_to"]) == Set(PATHS)

    # (e) the provider-backed SR arrays were re-pointed onto the derived axis
    @test tvars["SR_SOA"]["shape"] == [SET, "rcv_cells"]
    @test tvars["E_VOC"]["shape"] == [SET]

    # ============================================================
    # ASSERTION 2 — the invented member set == the L1 support set [1,2,4,9].
    # ============================================================
    f = EA.load(td; base_path=pwd())
    model = EA._select_model(f, "ISRM")
    vi = EA.materialize_value_invention(model, f.index_sets,
        Dict{String,Any}("X"=>X, "Y"=>Y, "W"=>W, "S"=>Sv, "E"=>Ev, "N"=>Nv),
        Dict{String,Any}())
    @test sort(collect(Int, vi.members[FAQ])) == HAND_MEMBERS
    @test vi.extents[FAQ] == length(HAND_MEMBERS)

    # ============================================================
    # BUILD through the front door WITH the rewrite ON (pushdown_rewrite=true).
    # ============================================================
    gate = Dict{String,Any}(
        "axes" => Any[Dict("fixed"=>[0]), Dict("gated_by"=>SET), "all"],
        "applies_to" => PATHS)
    mock = MockSRAuto(fullSR, gate, Any[])
    insp = EA.BuildInspection()
    f!, u0, p, _tspan, var_map = EA.build_evaluator(doc;
        model_name = "ISRM", const_arrays = ca, inspect = insp,
        pushdown_rewrite = true,
        _gated_providers = Dict{String,Any}("ISRM_SR" => mock), _sample_time = 0.0)

    # ============================================================
    # ASSERTION 3 — gated provider got the pushed-down selection == members,
    #               in order, and was NEVER materialized wholesale.
    # ============================================================
    sel_calls = [c for c in mock.calls if c[1] == :selection]
    whole_calls = [c for c in mock.calls if c[1] == :wholesale]
    @test length(whole_calls) == 0
    @test length(sel_calls) >= 1
    sel = sel_calls[1][2]
    @test sel[1] == 1                                    # layer fixed [0] → 1-based 1
    @test sel[2] == HAND_MEMBERS                         # source axis gated == members
    @test sel[3] === Colon()

    # ============================================================
    # ASSERTION 3b — members fed back as the generated member_factor; compact SR.
    # ============================================================
    @test haskey(insp.const_arrays, MF)
    @test Vector{Float64}(insp.const_arrays[MF]) == Float64.(HAND_MEMBERS)
    for name in PATHS
        @test haskey(insp.const_arrays, name)
        @test size(insp.const_arrays[name]) == (NP, N_RCV)
        @test insp.const_arrays[name] ≈ srC(name)
    end

    # ============================================================
    # ASSERTION 4 — downstream E_*/conc_*/TotalPM25/deaths == the L1 STEP-0 oracle.
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
    # NEGATIVE — a `max`-semiring conc of the SAME shape leaves the rewrite
    # UNFIRED (soundness guard: only `(+, 0)` fires).
    # ============================================================
    @testset "max-semiring conc → rewrite does NOT fire" begin
        doc_max = clean_doc(; conc_semiring="max_product")
        td_max = EA.desugar_pushdown(doc_max; model_name="ISRM")
        @test td_max === doc_max                          # returned UNCHANGED
        @test !haskey(td_max["index_sets"], SET)
        @test !haskey(td_max["models"]["ISRM"]["variables"], MF)
        @test !haskey(get(td_max["metadata"], "x_esd", Dict()), "pushdown")
    end
end

end # module AutoPushdownRewriteTests
