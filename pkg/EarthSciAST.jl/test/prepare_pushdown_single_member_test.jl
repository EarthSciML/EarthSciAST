# n=1 pin — the single-member support set (cross-language: the Python
# binding's bare-reference scalarisation footgun).
#
# Every emission record lands in ONE grid cell, so the engine-derived support
# set has exactly one member and the `pd_member_factor__*` feedback vector is
# a SIZE-1 const array. A one-member axis must stay an axis: the generated
# `index(F, index(mf, c))` gathers, the one-member gated selection, and the
# full downstream graph must all evaluate. (Julia's `_resolve_indices` scalar
# fold only fires on BARE references outside the gather path, so Julia never
# had the footgun; this test keeps it that way, mirroring
# `test_prepare_pushdown_single_member_support_set` in earthsci-ast-py and
# `prepare_pushdown_l1_single_member_support_set` in earthsci-ast-rs.)
#
# The document is the COMMITTED conformance fixture
# (tests/conformance/pushdown/fixtures/pushdown_l1.esm) — the LCC constants
# needed to invert the target points are read from the fixture itself.

module PreparePushdownSingleMemberTests

using Test
using JSON
using EarthSciAST
const EA = EarthSciAST

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _FIXTURE = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance",
                          "pushdown", "fixtures", "pushdown_l1.esm")

# ---- provider mocks (module-local types for the sample overloads) -----------
struct MockConstN1
    arr::Any
end
EA.provider_refresh_times(::MockConstN1) = Float64[]
EA.provider_sample(m::MockConstN1, ::Real; selection=nothing) = m.arr

mutable struct MockGatedN1
    full::Array{Float64,3}          # native [layer, src, rcv]
    calls::Vector{Any}
end
EA.provider_refresh_times(::MockGatedN1) = Float64[]
EA.provider_supports_selection(::MockGatedN1) = true
function EA.provider_sample(m::MockGatedN1, ::Real; selection=nothing)
    if selection === nothing
        push!(m.calls, (:wholesale,))
        return m.full
    end
    push!(m.calls, (:selection, deepcopy(selection)))
    lay, src, rcv = selection[1], selection[2], selection[3]
    return m.full[lay:lay, src, rcv]
end

@testset "prepare(pushdown_rewrite=true) with a ONE-member support set" begin
    GRID = 9; N_RCV = 4; N_REC = 5; N_LAYER = 3
    W = zeros(GRID); Sv = zeros(GRID); Ev = zeros(GRID); Nv = zeros(GRID)
    for row in 1:3, col in 1:3
        k = (row - 1) * 3 + col
        W[k] = (col - 1) * 2.0; Ev[k] = col * 2.0
        Sv[k] = (row - 1) * 2.0; Nv[k] = row * 2.0
    end

    doc = JSON.parsefile(_FIXTURE)

    # LCC inverse from the fixture's own frozen constants.
    v = doc["models"]["ISRM"]["variables"]
    n = v["lcc_n"]["default"]; rf = v["lcc_rf"]["default"]
    ρ0 = v["lcc_rho0"]["default"]; λ0 = v["lcc_lam0"]["default"]
    function lcc_inv(x, y)
        ρ = sign(n) * sqrt(x^2 + (ρ0 - y)^2)
        θ = atan(x, ρ0 - y)
        return (rad2deg(λ0 + θ / n), rad2deg(2 * atan((rf / ρ)^(1 / n)) - pi/2))
    end

    # All five records inside cell 1 (rect [0,2) × [0,2)).
    Xt = [0.5, 1.0, 1.5, 0.5, 1.2]
    Yt = [0.5, 0.5, 1.0, 1.5, 0.8]
    lon = Float64[]; lat = Float64[]
    for r in 1:N_REC
        lo, la = lcc_inv(Xt[r], Yt[r])
        push!(lon, lo); push!(lat, la)
    end

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
    LVARS = ["SOA", "pNO3", "pNH4", "pSO4", "PrimaryPM25"]
    base = Dict("SOA"=>1.0, "pNO3"=>2.0, "pNH4"=>3.0, "pSO4"=>4.0, "PrimaryPM25"=>5.0)
    fullSR = Dict{String,Array{Float64,3}}()
    for name in LVARS
        A = Array{Float64}(undef, N_LAYER, GRID, N_RCV)
        for l in 1:N_LAYER, s in 1:GRID, r in 1:N_RCV
            A[l, s, r] = (l - 1) * 1.0e6 + base[name] * 1000 + s * 10 + r
        end
        fullSR[name] = A
    end

    # Oracle with the one-member support set {cell 1}: every record contributes.
    pathway_is = Dict("SOA"=>is_VOC, "pNO3"=>is_NOx, "pNH4"=>is_NH3,
                      "pSO4"=>is_SOx, "PrimaryPM25"=>is_PM25)
    oracle_E(is_p) = [sum(emis_annual .* is_p)]
    oracle_conc(name) = (Ep = oracle_E(pathway_is[name]);
        [fullSR[name][1, 1, rcv] * Ep[1] for rcv in 1:N_RCV])
    oracle_TotalPM25 = [FACT * sum(oracle_conc(name)[rcv] for name in LVARS)
                        for rcv in 1:N_RCV]
    oracle_deaths(rr) = [(exp(log(rr) / 10 * oracle_TotalPM25[rcv]) - 1) *
                         TotalPop[rcv] * POP_SCALE *
                         MortalityRate[rcv] * MORT_SCALE / 100000 for rcv in 1:N_RCV]

    gmocks = Dict(v => MockGatedN1(fullSR[v], Any[]) for v in LVARS)
    # esm 1.0.0 (esm-spec §8.5): a data source exposes no variables of its own,
    # so a provider is keyed by the CONSUMING PARAMETER's flattened name
    # (`ISRM.emis_lon`), not by `<Source>.<file_variable>` (`MockPts.lon`).
    providers = Dict{String,Any}(
        "ISRM.TotalPop" => MockConstN1(TotalPop),
        "ISRM.MortalityRate" => MockConstN1(MortalityRate),
        "ISRM.emis_lon" => MockConstN1(lon), "ISRM.emis_lat" => MockConstN1(lat),
        "ISRM.emis_annual" => MockConstN1(emis_annual),
        "ISRM.is_VOC" => MockConstN1(is_VOC), "ISRM.is_NOx" => MockConstN1(is_NOx),
        "ISRM.is_NH3" => MockConstN1(is_NH3), "ISRM.is_SOx" => MockConstN1(is_SOx),
        "ISRM.is_PM25" => MockConstN1(is_PM25))
    for v in LVARS
        providers["ISRM.SR_$v"] = gmocks[v]
    end
    ca = Dict{String,Any}("src_W"=>W, "src_S"=>Sv, "src_E"=>Ev, "src_N"=>Nv)

    insp = EA.BuildInspection()
    prep = EA.prepare(doc; providers=providers, const_arrays=ca,
                      inspect=insp, pushdown_rewrite=true)
    @test prep isa EA.PreparedModel

    # The single-member feedback vector survived as a 1-element ARRAY.
    mfk = [k for k in keys(insp.const_arrays)
           if startswith(String(k), "pd_member_factor__")]
    @test !isempty(mfk)
    mf = insp.const_arrays[first(mfk)]
    @test length(mf) == 1 && Int(first(mf)) == 1

    # Gated fetches pushed the one-member selection down, never wholesale.
    for v in LVARS
        sel = [c for c in gmocks[v].calls if c[1] == :selection]
        whole = [c for c in gmocks[v].calls if c[1] == :wholesale]
        @test isempty(whole)
        @test length(sel) == 1
        @test sel[1][2][1] == 1
        @test sel[1][2][2] == [1]
        @test sel[1][2][3] === Colon()
    end

    # The full downstream graph evaluated off the one-member axis.
    E_voc = EA.observed_field(prep, insp, "E_VOC")
    @test length(E_voc) == 1
    @test E_voc ≈ oracle_E(is_VOC)
    @test EA.observed_field(prep, insp, "conc_SOA") ≈ oracle_conc("SOA")
    @test EA.observed_field(prep, insp, "TotalPM25") ≈ oracle_TotalPM25
    @test EA.observed_field(prep, insp, "deathsK") ≈ oracle_deaths(RR_K)
    @test EA.observed_field(prep, insp, "deathsL") ≈ oracle_deaths(RR_L)
end

end # module PreparePushdownSingleMemberTests
