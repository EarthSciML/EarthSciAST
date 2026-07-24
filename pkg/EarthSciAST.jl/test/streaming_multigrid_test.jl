# Wave 3 (streaming-output-sinks RFC §9): multi-grid output. One model carries two
# decoupled array states on DIFFERENT grids (`a` over 1-D `col`, `b` over 2-D
# `row`x`lev`); `group_gridding_by_grid` splits them by spatial-dim signature and one
# ZarrSink per grid writes to its own store. Each store is read back and checked
# against the closed-form decay c(t) = c0*exp(-rate*t) (per-variable rate).

using Test
using EarthSciAST
import EarthSciIO
import Blosc
using DiffEqCallbacks, SciMLBase
using OrdinaryDiffEqTsit5: Tsit5

@testset "Multi-grid per-grid sinks (Wave 3)" begin
    fixture = joinpath(@__DIR__, "fixtures", "streaming_multigrid.esm")
    prep = prepare(fixture)
    gridding = derive_output_gridding(prep.var_map, prep.output_meta)

    # two emergent grids: {col} and {lev,row} (sorted signatures).
    groups = group_gridding_by_grid(gridding)
    @test length(groups) == 2
    sig(grp) = sort(collect(String, grp[1].dimnames))
    bysig = Dict(sig(grp) => Set(String[g.base for g in grp]) for grp in groups)
    @test Set(keys(bysig)) == Set([["col"], ["lev", "row"]])
    @test bysig[["col"]] == Set(["Grid.a"])
    @test bysig[["lev", "row"]] == Set(["Grid.b"])

    ka, kb = 0.001, 0.002
    rate_of = base -> base == "Grid.a" ? ka : kb
    seed! = (u0, _vm) -> (@inbounds for i in eachindex(u0); u0[i] = Float64(i); end)

    tspan = (0.0, 100.0)
    times = [40.0, 80.0]
    dir = mktempdir()

    # one sink per grid → its own store (the RFC §9 "separable" layout).
    sinks = Any[]
    stores = Dict{String,String}()
    for grp in groups
        bases = String[g.base for g in grp]
        label = join(sig(grp), "_")
        url = "file://" * joinpath(dir, "grid_$(label).zarr")
        for b in bases; stores[b] = url; end
        push!(sinks, build_zarr_sink(prep, url; output_times = times, variables = bases))
    end
    @test length(sinks) == 2

    simulate(prep, tspan; alg = Tsit5(), sinks = sinks, seed_ic! = seed!)
    for s in sinks
        @test s.manifest.n_records == length(times)
    end

    # read each store back and verify analytically, element by element.
    cache = EarthSciIO.Cache(EarthSciIO.LocalStore(joinpath(dir, "cache")); offline = false)
    for grp in groups
        url = stores[grp[1].base]
        varnames = String[g.base for g in grp]
        nds = EarthSciIO.read_store(EarthSciIO.ZarrReader(), cache, url;
                                    variables = String[varnames..., "time"])
        tdata = collect(nds.variables["time"].data)
        @test length(tdata) == length(times)
        for g in grp
            v = nds.variables[g.base]
            r = rate_of(g.base)
            @test Set(v.dims) == Set(String[g.dimnames..., "time"])
            for t in times
                ti = findfirst(x -> isapprox(x, t; atol = 1e-9), tdata)
                for m in eachindex(g.flat_indices)
                    fi = g.flat_indices[m]
                    cart = g.cart[m]
                    idx = Vector{Int}(undef, length(v.dims))
                    for (p, dn) in enumerate(v.dims)
                        idx[p] = dn == "time" ? ti : cart[findfirst(==(dn), g.dimnames)]
                    end
                    @test isapprox(v.data[idx...], Float64(fi) * exp(-r * t);
                                   rtol = 1e-4, atol = 1e-6)
                end
            end
        end
    end
end
