# Projection-pushdown CONST-tier dependency edge — L1 MILESTONE (Phase 2b).
#
# Drives a SMALL ISRM-like model end-to-end through the REAL build/prepare path
# and proves the whole edge:
#
#   value-invention (overlap-gate producer → distinct containing cells `ppl`)
#     → Hook 1: `ppl` fed back as the const factor `src_cell_of_ppl`
#     → Hook 2: `ppl` pushed down to a GATED provider as a per-axis `selection`,
#               which fetches ONLY the compact SR[layer0, ppl, :] slab (never the
#               whole SR), merged back into const_arrays
#     → downstream E_* / conc_* / TotalPM25 / deathsK,L reproduce a plain-Julia
#       STEP-0 oracle on the same inputs.
#
# The gated provider is a MOCK that records the `selection` it is handed and the
# fields it slices; the assertions pin (1) the invented member set, (2) the
# pushed-down selection == members in order with NO wholesale fetch, (3) the
# members-fed factor + cell_* gathers, and (4) the full oracle match.

using Test
using EarthSciAST
import JSON3
# GeometryOps/GeoInterface activate the STRtree broad-phase fast path used by the
# overlap join-gate (Phase 2a/3a); the brute-force core also works, so this is a
# fast-path exercise, not a hard dependency.
import GeometryOps
import GeoInterface

const EA = EarthSciAST

# ---- small JSON AST builders ----------------------------------------------
_ix(f, args...) = Dict("op" => "index", "args" => Any[f, args...])
_op(o, args...) = Dict("op" => o, "args" => Any[args...])
# elementwise / reducing aggregate helper
function _agg(output_idx, ranges, expr; reduce=nothing, args=String[], extra...)
    d = Dict{String,Any}("op" => "aggregate", "output_idx" => collect(output_idx),
                         "ranges" => ranges, "args" => collect(args), "expr" => expr)
    reduce === nothing || (d["reduce"] = reduce)
    for (k, v) in extra
        d[String(k)] = v
    end
    return d
end

# =============================================================================
# GATED PROVIDER MOCK — records every call; slices the synthetic SR per selection.
# =============================================================================
mutable struct MockSR
    full::Dict{String,Array{Float64,3}}     # applies_to name => [layer, src, rcv]
    gate::Dict{String,Any}
    calls::Vector{Any}                       # (:selection, sel) or (:wholesale,)
end
EA.provider_gate_spec(m::MockSR) = m.gate
EA.provider_supports_selection(m::MockSR) = true
EA.provider_refresh_times(m::MockSR) = Float64[]     # const (never reached: gated first)
function EA.provider_sample(m::MockSR, ::Real; selection=nothing)
    if selection === nothing
        push!(m.calls, (:wholesale,))
        return Dict{String,Any}(k => v for (k, v) in m.full)   # MUST NOT happen in the edge
    end
    push!(m.calls, (:selection, deepcopy(selection)))
    lay, src, rcv = selection[1], selection[2], selection[3]   # Integer, Vector, Colon
    out = Dict{String,Any}()
    for (k, v) in m.full
        # Phase-1 contract: a fixed Integer keeps its axis as length-1.
        out[k] = v[lay:lay, src, rcv]
    end
    return out
end

@testset "projection-pushdown const-tier edge — L1 milestone (Phase 2b)" begin

    # ---- geometry: a 3×3 grid of 2×2 cells; cell k=(row-1)*3+col ------------
    GRID = 9; N_RCV = 4; N_REC = 5; N_LAYER = 3
    W = zeros(GRID); S = zeros(GRID); E = zeros(GRID); Nn = zeros(GRID)
    for row in 1:3, col in 1:3
        k = (row - 1) * 3 + col
        W[k] = (col - 1) * 2.0; E[k] = col * 2.0
        S[k] = (row - 1) * 2.0; Nn[k] = row * 2.0
    end
    # 5 emissions placed inside cells {1, 2, 4, 9} (hand-computed):
    #   e1(1,1)→c1  e2(3,1)→c2  e3(1,3)→c4  e4(5,5)→c9  e5(1.5,1.5)→c1
    X = [1.0, 3.0, 1.0, 5.0, 1.5]
    Y = [1.0, 1.0, 3.0, 5.0, 1.5]
    HAND_MEMBERS = [1, 2, 4, 9]                 # sorted distinct containing cells
    emis_annual = [10.0, 20.0, 30.0, 40.0, 50.0]
    is_VOC  = [1.0, 0.0, 1.0, 0.0, 0.0]         # e1,e3
    is_NOx  = [0.0, 1.0, 0.0, 0.0, 0.0]         # e2
    is_NH3  = [0.0, 0.0, 0.0, 0.0, 1.0]         # e5
    is_SOx  = [0.0, 0.0, 0.0, 0.0, 0.0]         # none
    is_PM25 = [0.0, 0.0, 0.0, 1.0, 0.0]         # e4
    TotalPop      = [100.0, 200.0, 300.0, 400.0]
    MortalityRate = [500.0, 600.0, 700.0, 800.0]

    FACT = 28766.639; POP_SCALE = 1.0465819687408728; MORT_SCALE = 1.025229357798165
    RR_K = 1.06; RR_L = 1.14

    # synthetic full SR (per pathway): distinct, layer-0 (0-based) is the used slab
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

    # ---- plain-Julia STEP-0 ORACLE on these same inputs --------------------
    pathway_is = Dict("SR_SOA"=>is_VOC, "SR_pNO3"=>is_NOx, "SR_pNH4"=>is_NH3,
                      "SR_pSO4"=>is_SOx, "SR_PrimaryPM25"=>is_PM25)
    cellW = [W[HAND_MEMBERS[c]] for c in 1:length(HAND_MEMBERS)]
    cellS = [S[HAND_MEMBERS[c]] for c in 1:length(HAND_MEMBERS)]
    cellE = [E[HAND_MEMBERS[c]] for c in 1:length(HAND_MEMBERS)]
    cellN = [Nn[HAND_MEMBERS[c]] for c in 1:length(HAND_MEMBERS)]
    contains(c, r) = cellW[c] <= X[r] < cellE[c] && cellS[c] <= Y[r] < cellN[c]
    NP = length(HAND_MEMBERS)
    function oracle_E(is_p)
        [sum((contains(c, r) ? 1.0 : 0.0) * emis_annual[r] * is_p[r]
             for r in 1:N_REC) for c in 1:NP]
    end
    # SR compact slab (layer-0 == 1-based 1) at the invented members, in order
    srC(name) = [fullSR[name][1, HAND_MEMBERS[c], rcv] for c in 1:NP, rcv in 1:N_RCV]
    oracle_conc(name) = (Ep = oracle_E(pathway_is[name]);
        [sum(srC(name)[c, rcv] * Ep[c] for c in 1:NP) for rcv in 1:N_RCV])
    oracle_TotalPM25 = [FACT * sum(oracle_conc(name)[rcv] for name in PATHS)
                        for rcv in 1:N_RCV]
    oracle_deaths(rr) = [(exp(log(rr) / 10 * oracle_TotalPM25[rcv]) - 1) *
                         TotalPop[rcv] * POP_SCALE *
                         MortalityRate[rcv] * MORT_SCALE / 100000 for rcv in 1:N_RCV]

    # ---- the document (pushdown-style: derived emis_src_cells + gated SR) ---
    # containment predicate reused by producer filter and E_* narrow phase
    _contain_and(Wf, Sf, Ef, Nf) = _op("and",
        _op("<=", _ix(Wf, "c"), _ix("X", "r")), _op("<", _ix("X", "r"), _ix(Ef, "c")),
        _op("<=", _ix(Sf, "c"), _ix("Y", "r")), _op("<", _ix("Y", "r"), _ix(Nf, "c")))
    # producer filter: PRODUCT of comparisons (kept iff > 0), c over pop_cells
    _prod_filter = _op("*",
        _op("*", _op("<=", _ix("W", "c"), _ix("X", "r")),
                 _op("<",  _ix("X", "r"), _ix("E", "c"))),
        _op("*", _op("<=", _ix("S", "c"), _ix("Y", "r")),
                 _op("<",  _ix("Y", "r"), _ix("N", "c"))))

    _E_expr(is_p) = _op("*",
        _op("ifelse", _contain_and("cell_W", "cell_S", "cell_E", "cell_N"), 1.0, 0.0),
        _op("*", _ix("emis_annual", "r"), _ix(is_p, "r")))
    _E_agg(is_p) = _agg(["c"],
        Dict("c"=>Dict("from"=>"emis_src_cells"), "r"=>Dict("from"=>"emis_records")),
        _E_expr(is_p); reduce="+",
        args=["cell_W","cell_S","cell_E","cell_N","X","Y","emis_annual",is_p])

    _cell_edge(edge) = _agg(["c"], Dict("c"=>Dict("from"=>"emis_src_cells")),
        _ix(edge, _ix("src_cell_of_ppl", "c")); args=[edge, "src_cell_of_ppl"])

    _conc_agg(SRname, Ename) = _agg(["rcv"],
        Dict("s"=>Dict("from"=>"emis_src_cells"), "rcv"=>Dict("from"=>"rcv_cells")),
        _op("*", _ix(SRname, "s", "rcv"), _ix(Ename, "s")); reduce="+",
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
        "W"=>param(["pop_cells"]), "S"=>param(["pop_cells"]),
        "E"=>param(["pop_cells"]), "N"=>param(["pop_cells"]),
        "TotalPop"=>param(["rcv_cells"]), "MortalityRate"=>param(["rcv_cells"]),
        "SR_SOA"=>param(["emis_src_cells","rcv_cells"]),
        "SR_pNO3"=>param(["emis_src_cells","rcv_cells"]),
        "SR_pNH4"=>param(["emis_src_cells","rcv_cells"]),
        "SR_pSO4"=>param(["emis_src_cells","rcv_cells"]),
        "SR_PrimaryPM25"=>param(["emis_src_cells","rcv_cells"]),
        "src_cell_of_ppl"=>param(["emis_src_cells"]),
        "emis_src_cell_member"=>Dict("type"=>"state", "shape"=>["emis_src_cells"]),
        "cell_W"=>obs(["emis_src_cells"], _cell_edge("W")),
        "cell_S"=>obs(["emis_src_cells"], _cell_edge("S")),
        "cell_E"=>obs(["emis_src_cells"], _cell_edge("E")),
        "cell_N"=>obs(["emis_src_cells"], _cell_edge("N")),
        "E_VOC"=>obs(["emis_src_cells"], _E_agg("is_VOC")),
        "E_NOx"=>obs(["emis_src_cells"], _E_agg("is_NOx")),
        "E_NH3"=>obs(["emis_src_cells"], _E_agg("is_NH3")),
        "E_SOx"=>obs(["emis_src_cells"], _E_agg("is_SOx")),
        "E_PM25"=>obs(["emis_src_cells"], _E_agg("is_PM25")),
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

    producer_eq = Dict(
        "lhs" => _ix("emis_src_cell_member", "m"),
        "rhs" => _agg(["m"],
            Dict("r"=>Dict("from"=>"emis_records"), "c"=>Dict("from"=>"pop_cells")),
            Dict("op"=>"true", "args"=>[]);
            args=["X","Y","W","S","E","N"],
            id="emis_src_cells_faq", semiring="bool_and_or", distinct=true,
            join=[Dict("overlap"=>Dict("src_env"=>["X","Y"],
                                       "tgt_env"=>["W","S","E","N"], "eps"=>0.0))],
            filter=_prod_filter,
            key=Dict("op"=>"skolem", "label"=>"cell", "args"=>["c"])))

    doc = Dict(
        "esm" => "0.9.0",
        "metadata" => Dict("name" => "isrm_pushdown_L1"),
        "index_sets" => Dict(
            "src_cells"  => Dict("kind"=>"interval", "size"=>GRID),
            "rcv_cells"  => Dict("kind"=>"interval", "size"=>N_RCV),
            "pop_cells"  => Dict("kind"=>"interval", "size"=>GRID),
            "emis_records" => Dict("kind"=>"interval", "size"=>N_REC),
            "emis_src_cells" => Dict("kind"=>"derived", "from_faq"=>"emis_src_cells_faq",
                                     "member_factor"=>"src_cell_of_ppl")),
        "models" => Dict("ISRM" => Dict("variables"=>variables,
                                        "equations"=>[producer_eq])))

    # const arrays supplied by the caller (Hook 3: X/Y and cell rects are cheap;
    # the runner projects them — SR is the only gated, deferred fetch)
    ca = Dict{String,Any}(
        "X"=>X, "Y"=>Y, "emis_annual"=>emis_annual,
        "is_VOC"=>is_VOC, "is_NOx"=>is_NOx, "is_NH3"=>is_NH3,
        "is_SOx"=>is_SOx, "is_PM25"=>is_PM25,
        "W"=>W, "S"=>S, "E"=>E, "N"=>Nn,
        "TotalPop"=>TotalPop, "MortalityRate"=>MortalityRate)

    gate = Dict{String,Any}(
        "axes" => Any[Dict("fixed"=>[0]), Dict("gated_by"=>"emis_src_cells"), "all"],
        "applies_to" => PATHS)
    mock = MockSR(fullSR, gate, Any[])

    f = EA.load(doc; base_path=pwd())

    # ============================================================
    # ASSERTION 1 — the invented member set == hand-computed containing cells
    # ============================================================
    model = EA._select_model(f, "ISRM")
    vi = EA.materialize_value_invention(model, f.index_sets,
        Dict{String,Any}("X"=>X, "Y"=>Y, "W"=>W, "S"=>S, "E"=>E, "N"=>Nn),
        Dict{String,Any}())
    @test sort(collect(Int, vi.members["emis_src_cells_faq"])) == HAND_MEMBERS
    @test vi.extents["emis_src_cells_faq"] == length(HAND_MEMBERS)

    # ============================================================
    # BUILD through the front-door — Hook 1 (feedback) + Hook 2 (defer+fetch).
    # The front door does NOT namespace (bare names throughout, like the overlap
    # conformance test), so the gated fetch, the members-fed factor, and the
    # supplied const arrays all resolve under the authored names. `prepare`'s
    # eager-loop deferral ROUTING is exercised by the separate testset below.
    # ============================================================
    insp = EA.BuildInspection()
    f!, u0, p, _tspan, var_map = EA.build_evaluator(doc;
        model_name = "ISRM", const_arrays = ca, inspect = insp,
        _gated_providers = Dict{String,Any}("ISRM_SR" => mock), _sample_time = 0.0)

    # ============================================================
    # ASSERTION 2 — gated provider got the pushed-down selection == members,
    #               in order, and was NEVER materialized wholesale.
    # ============================================================
    sel_calls = [c for c in mock.calls if c[1] == :selection]
    whole_calls = [c for c in mock.calls if c[1] == :wholesale]
    @test length(whole_calls) == 0                 # NEVER pulled whole (no 330 GB fold)
    @test length(sel_calls) >= 1
    sel = sel_calls[1][2]
    @test sel[1] == 1                              # layer fixed [0] → 1-based 1
    @test sel[2] == HAND_MEMBERS                   # source axis gated == members, IN ORDER
    @test sel[3] === Colon()                       # receptor axis whole

    # ============================================================
    # ASSERTION 3 — members fed back as `src_cell_of_ppl`; cell_* gathers resolve
    # ============================================================
    @test haskey(insp.const_arrays, "src_cell_of_ppl")
    @test Vector{Float64}(insp.const_arrays["src_cell_of_ppl"]) ==
          Float64.(HAND_MEMBERS)
    # the gated SR slab landed compact in const_arrays: [members, rcv]
    for name in PATHS
        @test haskey(insp.const_arrays, name)
        @test size(insp.const_arrays[name]) == (NP, N_RCV)
        @test insp.const_arrays[name] ≈ srC(name)
    end
    # cell_* gathers (evaluate the derived-shaped observeds over the compact axis)
    cell_cells = [[c] for c in 1:NP]
    for (edge, oracleE) in (("cell_W", cellW), ("cell_S", cellS),
                            ("cell_E", cellE), ("cell_N", cellN))
        expr = get(insp.observed_exprs, "ISRM.$edge", get(insp.observed_exprs, edge, nothing))
        @test expr !== nothing
        got = EA.evaluate_cellwise(expr, cell_cells;
            const_arrays=insp.const_arrays,
            params=EA._param_scope_with_aliases(insp.params))
        @test got ≈ oracleE
    end

    # ============================================================
    # ASSERTION 4 — downstream E_*/conc_*/TotalPM25/deaths == STEP-0 oracle
    # ============================================================
    # E_* are shaped over the DERIVED axis → evaluate the resolved expr directly.
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

    # conc_*/TotalPM25/deaths are shaped over rcv_cells (interval) → _observed_field.
    rt(name) = (fld = EA._observed_field(insp, f, "ISRM", name);
        fld === nothing ? error("observed $name not evaluable via _observed_field") : fld[1])
    @test rt("conc_SOA")  ≈ oracle_conc("SR_SOA")
    @test rt("conc_pNO3") ≈ oracle_conc("SR_pNO3")
    @test rt("conc_pNH4") ≈ oracle_conc("SR_pNH4")
    @test rt("conc_pSO4") ≈ oracle_conc("SR_pSO4")
    @test rt("conc_PrimaryPM25") ≈ oracle_conc("SR_PrimaryPM25")
    @test rt("TotalPM25") ≈ oracle_TotalPM25
    @test rt("deathsK")   ≈ oracle_deaths(RR_K)
    @test rt("deathsL")   ≈ oracle_deaths(RR_L)

    # ============================================================
    # PREPARE PATH — the public API (flattens + qualifies names). Proves the
    # eager-loop DEFERRAL literally: the gated provider is never wholesale-pulled
    # by prepare's const loop; it is fetched pre-sliced after value-invention.
    # (Const arrays are model-qualified — the standard flattened convention, cf.
    # the runner's part_b.jl — and Hook 1/2 resolve the bare factor names to the
    # namespaced variable keys.)
    # ============================================================
    @testset "full prepare() API: eager-loop deferral + fetch" begin
        ca_q = Dict{String,Any}("ISRM." * k => v for (k, v) in ca)
        insp2 = EA.BuildInspection()
        mock2 = MockSR(fullSR, gate, Any[])
        prep = EA.prepare(f; const_arrays=ca_q, providers=Dict("ISRM_SR"=>mock2),
                          inspect=insp2)
        @test prep isa EA.PreparedModel
        # deferral: NEVER wholesale-materialized in the eager const loop
        @test count(c -> c[1] == :wholesale, mock2.calls) == 0
        selc = [c for c in mock2.calls if c[1] == :selection]
        @test length(selc) >= 1
        @test selc[1][2][2] == HAND_MEMBERS               # pushed-down members, in order
        # members fed back + compact SR merged under the namespaced keys
        @test Vector{Float64}(insp2.const_arrays["ISRM.src_cell_of_ppl"]) ==
              Float64.(HAND_MEMBERS)
        @test size(insp2.const_arrays["ISRM.SR_SOA"]) == (NP, N_RCV)
        # end-to-end oracle through the real prepare pipeline (spot-check deaths)
        @test EA._observed_field(insp2, f, "ISRM", "deathsK")[1] ≈ oracle_deaths(RR_K)
        @test EA._observed_field(insp2, f, "ISRM", "TotalPM25")[1] ≈ oracle_TotalPM25
    end
end
