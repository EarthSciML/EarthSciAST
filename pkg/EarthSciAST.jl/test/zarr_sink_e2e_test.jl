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
    # Wave 3: meta-aware gridding names axes by their REAL index-set names
    # (lon/lat), matching what the sink wrote — not positional <base>_d0.
    grid = derive_output_gridding(prep.var_map, prep.output_meta)
    varnames = String[g.base for g in grid]
    @test length(grid) == 1                       # single state c[lon,lat] (6 cells)
    @test grid[1].dimnames == ["lon", "lat"]      # real dim names, not Grid.c_d0/_d1

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
        @test Set(dims) == Set(String[g.dimnames..., "time"])   # real names on disk
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

# The 0-D case, end to end through the REAL sink and the REAL reader
# (streaming-output-sinks RFC §16.12). This is the evidence that the synthetic
# `<base>_d0` singleton axis a scalar used to carry was never load-bearing: the
# `ZarrSink` -> `write_record!` -> Zarr v3 path already writes rank-1
# `[time_dim]` arrays (the time coordinate is one), so a scalar variable whose
# only on-disk axis IS the record axis writes, commits and reads back unchanged.
#
# Driven from a bare `var_map` + `OutputMeta` rather than a solve: the clause
# under test is the derivation/write shape, and a 0-D model with three scalars is
# exactly the state vector a solve would hand over.
@testset "0-D model: scalars share one grid and write [time]-only arrays" begin
    doc = Dict{String,Any}(
        "domain" => Dict{String,Any}("independent_variable" => "time"),
        "models" => Dict{String,Any}("M" => Dict{String,Any}(
            "variables" => Dict{String,Any}(
                "a" => Dict{String,Any}("type" => "state", "units" => "K"),
                "b" => Dict{String,Any}("type" => "state", "units" => "kg"),
                "c" => Dict{String,Any}("type" => "state")))))
    var_map = Dict("M.a" => 1, "M.b" => 2, "M.c" => 3)
    meta = derive_output_meta(doc)
    @test meta.time_dim == "time"

    # One grid, not one per scalar; every variable 0-spatial-dimensional.
    plan = derive_output_plan(doc, var_map)
    @test length(plan.grids) == 1
    @test isempty(plan.grids[1].dims)
    @test [v.dims for v in plan.grids[1].vars] == [["time"], ["time"], ["time"]]

    dir = mktempdir()
    base_url = "file://" * joinpath(dir, "scalars.zarr")
    times = [0.0, 1.0, 2.0]
    sink = build_zarr_sink(var_map, base_url; output_times = times, meta = meta,
                           records_per_shard = 2)   # forces a partial trailing shard
    sink_open!(sink)
    for (k, t) in enumerate(times)
        u = [10.0k, 20.0k, 30.0k]
        sink_write!(sink, StateSnapshot(t,
            Tuple{Array,Tuple{Vararg{UnitRange{Int}}}}[(u, (1:3,))], Dict{String,Array}()))
    end
    man = sink_close!(sink)
    @test man !== nothing
    @test man.n_records == length(times)

    cache = EarthSciIO.Cache(EarthSciIO.LocalStore(joinpath(dir, "cache")); offline = false)
    nds = EarthSciIO.read_store(EarthSciIO.ZarrReader(), cache, base_url;
                                variables = ["M.a", "M.b", "M.c", "time"])
    @test nds.variables["time"].dims == ["time"]
    for (nm, scale) in ("M.a" => 10.0, "M.b" => 20.0, "M.c" => 30.0)
        v = nds.variables[nm]
        @test v.dims == ["time"]                       # NOT ["M.a_d0", "time"]
        @test size(v.data) == (length(times),)
        @test isapprox(collect(v.data), scale .* [1.0, 2.0, 3.0]; atol = 1e-9)
    end

    # The restart direction: a rank-1 slab gathers back into the flat state, which
    # is the path a bare `Float64` slice would have broken.
    gridding = derive_output_gridding(var_map, meta)
    u0 = zeros(Float64, length(var_map))
    for g in gridding
        v = nds.variables[g.base]
        slab = dropdims(v.data[length(times):length(times)]; dims = 1)
        @test ndims(slab) == 0
        gather_flat!(u0, g, slab)
    end
    @test u0 == [30.0, 60.0, 90.0]
end
