# REGRESSION (data corruption): `sink_flush!` interleaved with ordinary
# `sink_write!`s — the cadence a long run uses to keep its store restartable —
# silently corrupted the stream. A partial flush advanced the writer's SHARD index,
# so the next record jumped to the next shard's first slot: the skipped slots read
# back as fill-valued (all-zero) phantom records at every shard tail, and the
# declared `shape[time]` (a running sum of committed records) stopped covering the
# records written past the gaps, so the tail of the run silently vanished.
#
# Driven through the sink protocol with a SYNTHETIC var_map (no model build), in
# the same shape a driver uses it: a species-major flat state over a small grid,
# `records_per_shard = 8`, and 21 records so the stream crosses three shard
# boundaries. Values are distinct per (variable, cell, record) so neither a
# permutation nor a stale-slot bug can hide behind a min/max or a checksum — the
# comparison is element-by-element over every cell of every record.
#
# Requires the EarthSciIO extension (+ Blosc for the diagnostic codec).

using Test
using EarthSciAST
import EarthSciIO
import Blosc            # activates EarthSciIOBloscExt so the Zarr writer can compress

@testset "ZarrSink: interleaved sink_flush! writes a gap-free, complete stream" begin
    NX, NY = 3, 2
    bases = ["Chem.a", "Chem.b"]

    # species-major flat layout: all of "Chem.a"'s cells, then all of "Chem.b"'s.
    var_map = Dict{String,Int}()
    k = 0
    for nm in bases, j in 1:NY, i in 1:NX
        k += 1
        var_map["$nm[$i,$j]"] = k
    end
    N = k

    # distinct per (variable, cell, record); no two elements of any record collide
    _val(s, i, j, r) = 1000.0 * s + 100.0 * i + 10.0 * j + 0.001 * r
    function _state(r)
        u = zeros(Float64, N)
        for (s, nm) in enumerate(bases), j in 1:NY, i in 1:NX
            u[var_map["$nm[$i,$j]"]] = _val(s, i, j, r)
        end
        return u
    end

    NREC = 21
    times = collect(1.0:1.0:NREC)

    # Flush cadences that land mid-shard (5, 3), on the shard boundary (8), and on
    # every record (1). None of them may move, drop, or duplicate a record.
    for flush_every in (1, 3, 5, 8)
        dir = mktempdir()
        base_url = "file://" * joinpath(dir, "flush.zarr")
        sink = build_zarr_sink(var_map, base_url; output_times = times,
                               records_per_shard = 8)
        sink_open!(sink)
        for r in 1:NREC
            sink_write!(sink, StateSnapshot(times[r], [(_state(r), (1:N,))],
                                            Dict{String,Array}()))
            r % flush_every == 0 && sink_flush!(sink)
        end
        man = sink_close!(sink)

        @test man !== nothing
        @test man.n_records == NREC          # every record committed, none phantom
        @test man.last_t == times[end]
        @test sum(s.n for s in man.time_shards) == NREC
        # one manifest entry per occupied shard — a re-committed partial shard
        # refreshes its entry rather than pushing a duplicate.
        @test length(man.time_shards) == cld(NREC, 8)
        @test [s.index for s in man.time_shards] == collect(0:(cld(NREC, 8) - 1))

        cache = EarthSciIO.Cache(EarthSciIO.LocalStore(joinpath(dir, "cache"));
                                 offline = false)
        nds = EarthSciIO.read_store(EarthSciIO.ZarrReader(), cache, base_url;
                                    variables = String[bases..., "time"])

        # the time axis is exactly the records written, in order — no fill slots
        @test isapprox(nds.variables["time"].data, times; atol = 1e-9)

        grid = derive_output_gridding(var_map)
        for (s, g) in enumerate(grid)
            v = nds.variables[g.base]
            # Record axis FIRST, then the spatial axes (RFC §16.12).
            @test v.dims == String["time", g.dimnames...]
            @test size(v.data) == (NREC, NX, NY)
            for r in 1:NREC, j in 1:NY, i in 1:NX
                @test v.data[r, i, j] == _val(s, i, j, r)
            end
        end
    end
end
