# End-to-end streaming-output test (streaming-output-sinks RFC, Wave 2): run a real
# flattened multi-grid model, stream its state to a Zarr v3 store via `ZarrSink`
# (EarthSciIO write boundary), read it back with the upgraded `ZarrReader`, and
# assert the decoded gridded arrays equal an in-RAM reference run — TOLERANCE-BASED
# (RFC §16.6), not byte-identity. Exercises the flat→gridded column-major scatter
# (`derive_output_gridding`/`scatter_grid!`), the sink lifecycle wired into
# `simulate`, and the round-trip through EarthSciIO.
#
# Requires the EarthSciIO + DiffEqCallbacks + SciMLBase + solver weakdeps; run under
# a target that provides them (see the guard in runtests.jl).

using Test
using EarthSciAST
import EarthSciIO
import Blosc            # activates EarthSciIOBloscExt so the Zarr writer can compress (weakdep)
using DiffEqCallbacks, SciMLBase
using OrdinaryDiffEqTsit5: Tsit5

@testset "ZarrSink end-to-end round-trip (Wave 2)" begin
    fixture = joinpath(@__DIR__, "fixtures", "streaming_decay_grid.esm")
    @test isfile(fixture)

    prep = prepare(fixture)
    tspan = (0.0, 100.0)
    times = [20.0, 40.0, 60.0, 80.0, 100.0]   # strictly inside (0, tend]

    # Distinct per-element initial conditions so a scatter/placement bug cannot hide
    # behind uniform values (the fixture defaults are all 0.0). Same seed for both
    # runs, so the reference and the streamed store must agree.
    seed! = (u0, _var_map) -> (@inbounds for i in eachindex(u0); u0[i] = Float64(i); end)

    # (a) reference run: in-RAM trajectory at the output times.
    ref = simulate(prep, tspan; alg = Tsit5(), saveat = times, seed_ic! = seed!)
    @test length(ref.t) == length(times)

    # (b) streamed run: same model/ICs, state streamed to a Zarr v3 store.
    dir = mktempdir()
    base_url = "file://" * joinpath(dir, "out.zarr")
    sink = build_zarr_sink(prep, base_url; output_times = times, records_per_shard = 8)
    simulate(prep, tspan; alg = Tsit5(), sinks = [sink], seed_ic! = seed!)

    man = sink.manifest
    @test man !== nothing
    @test man.n_records == length(times)
    @test man.zarr_format == 3

    # --- read the store back through the real reader ---
    grid = derive_output_gridding(prep.var_map)
    varnames = String[g.base for g in grid]
    @test length(grid) == 1                       # single state c[lon,lat] (6 cells)

    cache = EarthSciIO.Cache(EarthSciIO.LocalStore(joinpath(dir, "cache")); offline = false)
    nds = EarthSciIO.read_store(EarthSciIO.ZarrReader(), cache, base_url;
                                variables = String[varnames..., "time"])

    tdata = nds.variables["time"].data
    @test length(tdata) == length(times)
    for t in times
        @test any(x -> isapprox(x, t; atol = 1e-9), tdata)
    end

    # Element-by-element comparison, robust to read-back dim ordering: index the
    # decoded array by mapping each on-disk dim name to its axis, using the
    # gridding's CartesianIndex for the spatial position and the matching time slot.
    for g in grid
        v = nds.variables[g.base]
        dims = v.dims
        data = v.data
        @test length(dims) == length(g.dimnames) + 1     # spatial dims + time
        for t in times
            r = findfirst(x -> isapprox(x, t; atol = 1e-9), tdata)
            kref = findfirst(x -> isapprox(x, t; atol = 1e-9), ref.t)
            uref = ref.u[kref]
            for m in eachindex(g.flat_indices)
                cart = g.cart[m]
                idx = Vector{Int}(undef, length(dims))
                for (p, dn) in enumerate(dims)
                    if dn == "time"
                        idx[p] = r
                    else
                        d = findfirst(==(dn), g.dimnames)
                        @test d !== nothing
                        idx[p] = cart[d]
                    end
                end
                @test isapprox(data[idx...], uref[g.flat_indices[m]];
                               atol = 1e-8, rtol = 1e-8)
            end
        end
    end
end
