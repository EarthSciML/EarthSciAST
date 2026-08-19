# SIBLING LOADERS THAT EXPOSE THE SAME VARIABLE NAME — projection-pushdown
# hook 2 (`_fetch_gated_providers`) regression.
#
# `isrm.esm` states plume rise by fetching the SAME zarr array at three
# different emission layers through three sibling loaders — `ISRM_SR_L0.SOA`,
# `ISRM_SR_L1.SOA`, `ISRM_SR_L2.SOA` — which differ in NOTHING but the
# `{"fixed": [layer]}` axis of their `gated_select`. They are three DIFFERENT
# slabs told apart only by which loader they came from.
#
# Hook 2 used to publish each fetched slab under `_const_factor_aliases`, which
# resolves a bare name against EVERY model variable with the same dotted TAIL.
# All three providers therefore claimed all three keys, and whichever the
# `gated` Dict happened to visit LAST silently won for all of them: every layer
# of the model was contracted against one arbitrary sibling's slab. Hash order
# picked a different winner per variable name, so the answer was wrong,
# reproducible within a run, and raised nothing. Measured on isrm.esm at
# ISRM_FIRSTN=200 it moved sum(deathsK) by 6.6%.
#
# A provider owns an alias when it is the SOLE claimant, or when the alias IS
# its own provider key. An alias several claim and none owns stays UNWRITTEN —
# a missing const array fails loudly at gather time.

module GatedSiblingLoaderTests

using Test
using EarthSciAST
const EA = EarthSciAST

# A gated provider that slices its own [layer, src, rcv] block per selection.
mutable struct SiblingMock
    full::Array{Float64,3}
    calls::Vector{Any}
end
EA.provider_supports_selection(::SiblingMock) = true
EA.provider_refresh_times(::SiblingMock) = Float64[]
function EA.provider_sample(m::SiblingMock, ::Real; selection=nothing)
    selection === nothing && (push!(m.calls, (:wholesale,)); return m.full)
    push!(m.calls, (:selection, deepcopy(selection)))
    lay, src, rcv = selection[1], selection[2], selection[3]
    return m.full[lay:lay, src, rcv]      # a fixed Integer keeps its axis length-1
end

@testset "gated hook 2 — sibling loaders sharing a variable name" begin
    N_LAYER, N_SRC, N_RCV = 3, 6, 4
    full = reshape(collect(1.0:(N_LAYER * N_SRC * N_RCV)), (N_LAYER, N_SRC, N_RCV))
    members = [2, 4, 6]                      # 1-based support-set members

    idx = Dict{String,Any}("supp" =>
        EA.IndexSet("derived"; from_faq="faq1", member_factor=nothing))
    vi = (members = Dict{String,Vector{Any}}("faq1" => Any[members...]),
          extents = Dict{String,Int}("faq1" => length(members)))
    # The post-flatten model: one variable per (loader, layer), all tail "SOA".
    model = (variables = Dict{String,Any}("SR_L$(L).SOA" => nothing for L in 0:2),)

    mocks = Dict(L => SiblingMock(copy(full), Any[]) for L in 0:2)
    gated = Dict{String,Any}(
        "SR_L$(L).SOA" => (prov = mocks[L],
                           gate = Dict{String,Any}(
                               "axes" => Any[Dict("fixed" => Any[L]),
                                             Dict("gated_by" => "supp"), "all"],
                               "applies_to" => Any["SOA"]))
        for L in 0:2)

    out = EA._fetch_gated_providers(gated, idx, vi, 0.0, model)

    # Every sibling published ITS OWN layer under ITS OWN key — no overwrite.
    for L in 0:2
        want = full[L + 1, members, :]
        @test haskey(out, "SR_L$(L).SOA")
        @test out["SR_L$(L).SOA"] == want
    end
    # …and the three slabs are genuinely different, so an overwrite could not
    # have hidden inside an accidental equality.
    @test out["SR_L0.SOA"] != out["SR_L1.SOA"] != out["SR_L2.SOA"]

    # The bare tail is claimed by all three and owned by none: left unwritten
    # rather than arbitrarily assigned.
    @test !haskey(out, "SOA")

    # Each provider was asked for its own layer, and none was pulled wholesale.
    for L in 0:2
        @test length(mocks[L].calls) == 1
        kind, sel = mocks[L].calls[1]
        @test kind === :selection
        @test sel[1] == L + 1                # 0-based native fixed → 1-based neutral
        @test sel[2] == members
    end
end

@testset "gated hook 2 — a lone loader still gets its bare + aliased keys" begin
    # The single-loader shape (the pre-plume isrm.esm, and every other document)
    # is unchanged: with one claimant, both the bare name and the flattened
    # alias are published, exactly as before.
    full = reshape(collect(1.0:24.0), (2, 6, 2))
    idx = Dict{String,Any}("supp" => EA.IndexSet("derived"; from_faq="faq1"))
    vi = (members = Dict{String,Vector{Any}}("faq1" => Any[1, 3]),
          extents = Dict{String,Int}("faq1" => 2))
    model = (variables = Dict{String,Any}("Flattened.SR" => nothing),)
    gated = Dict{String,Any}("L.SR" => (prov = SiblingMock(copy(full), Any[]),
        gate = Dict{String,Any}(
            "axes" => Any[Dict("fixed" => Any[0]), Dict("gated_by" => "supp"), "all"],
            "applies_to" => Any["SR"])))
    out = EA._fetch_gated_providers(gated, idx, vi, 0.0, model)
    @test sort!(collect(keys(out))) == ["Flattened.SR", "SR"]
    @test out["SR"] == full[1, [1, 3], :]
end

end # module
