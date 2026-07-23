# Wave 3 (streaming-output-sinks RFC §8): the `coordinates` registry → CF
# dimension-coordinate emission. Runs the streaming_decay_grid_coords model (which
# carries a `coordinates` registry giving rectilinear lon/lat values + CF metadata),
# streams to a Zarr v3 store, and asserts:
#   * the registry survives flatten and reaches `prep.output_meta` (§8.3 threading),
#   * the store's lon/lat are true CF dimension coordinates whose VALUES read back
#     through the real reader, and
#   * the coordinate + data-variable CF ATTRS (standard_name/units/axis; per-var
#     units) are on disk in the array nodes (asserted on `zarr.json`, the
#     language-neutral surface the cross-language conformance corpus will use — the
#     reader intentionally surfaces dim names + values, not the full attrs dict).
#
# Requires the EarthSciIO + DiffEqCallbacks + SciMLBase + solver weakdeps.

using Test
using EarthSciAST
import EarthSciIO
import Blosc
import JSON
using DiffEqCallbacks, SciMLBase
using OrdinaryDiffEqTsit5: Tsit5

@testset "ZarrSink CF dimension coordinates (Wave 3)" begin
    fixture = joinpath(@__DIR__, "fixtures", "streaming_decay_grid_coords.esm")
    @test isfile(fixture)

    prep = prepare(fixture)

    # (1) the `coordinates` registry survived flatten and reached output metadata.
    meta = prep.output_meta
    @test haskey(meta.coordinates, "lon")
    @test haskey(meta.coordinates, "lat")
    @test meta.var_dims["Grid.c"] == ["lon", "lat"]
    @test get(meta.var_attrs["Grid.c"], "units", nothing) == "kg"

    # planned dimension coordinates: lon/lat with values + CF attrs.
    grid = derive_output_gridding(prep.var_map, meta)
    dcoords = plan_dimension_coordinates(grid, meta)
    @test Set(c.name for c in dcoords) == Set(["lon", "lat"])
    lonc = dcoords[findfirst(c -> c.name == "lon", dcoords)]
    @test lonc.values == [-100.0, -90.0, -80.0]
    @test lonc.attrs["standard_name"] == "longitude"
    @test lonc.attrs["axis"] == "X"

    tspan = (0.0, 100.0)
    times = [25.0, 50.0, 75.0, 100.0]
    seed! = (u0, _vm) -> (@inbounds for i in eachindex(u0); u0[i] = Float64(i); end)

    dir = mktempdir()
    store_path = joinpath(dir, "out.zarr")
    base_url = "file://" * store_path
    sink = build_zarr_sink(prep, base_url; output_times = times, records_per_shard = 8)
    simulate(prep, tspan; alg = Tsit5(), sinks = [sink], seed_ic! = seed!)
    @test sink.manifest.n_records == length(times)

    # (2) coordinate VALUES read back through the real reader.
    cache = EarthSciIO.Cache(EarthSciIO.LocalStore(joinpath(dir, "cache")); offline = false)
    nds = EarthSciIO.read_store(EarthSciIO.ZarrReader(), cache, base_url;
                                variables = String["Grid.c", "lon", "lat", "time"])
    @test collect(nds.variables["lon"].data) == [-100.0, -90.0, -80.0]
    @test collect(nds.variables["lat"].data) == [30.0, 40.0]
    @test nds.variables["lon"].dims == ["lon"]     # CF dimension coordinate (name == dim)
    @test nds.variables["lat"].dims == ["lat"]

    # (3) CF ATTRS on disk (zarr.json array nodes).
    read_attrs(name) = JSON.parsefile(joinpath(store_path, name, "zarr.json"))["attributes"]
    la = read_attrs("lon")
    @test la["standard_name"] == "longitude"
    @test la["units"] == "degrees_east"
    @test la["axis"] == "X"
    @test la["_ARRAY_DIMENSIONS"] == ["lon"]
    ta = read_attrs("lat")
    @test ta["standard_name"] == "latitude"
    @test ta["units"] == "degrees_north"
    @test ta["axis"] == "Y"

    # the data variable carries its own units + the real dimension order.
    ca = read_attrs("Grid.c")
    @test ca["units"] == "kg"
    @test ca["_ARRAY_DIMENSIONS"] == ["lon", "lat", "time"]
end
