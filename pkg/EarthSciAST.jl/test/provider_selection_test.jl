# Phase 1b — projection pushdown across the EarthSciAST↔EarthSciIO provider seam.
#
# Exercises the neutral, 1-based, per-axis `selection` on `provider_sample` and
# its translation (in ext/EarthSciASTEarthSciIOExt.jl) into EarthSciIO's native
# 0-based zarr `select`, over a SMALL synthetic on-disk zarr store (the minimal
# store-writing helpers are copied from EarthSciIO's own test/test_zarr.jl).
#
# The store is a (3,50,4) `sr` array, chunks (1,10,4), where each element encodes
# its own 0-based coordinates:  A[l,s,r] = l*1_000_000 + s*1000 + r  (exact in
# Float32 for this range). So a 1-BASED neutral `selection` indexes the Julia
# oracle `A` directly — `provider_sample(p, t; selection=[i, v, :])` must return
# `A[i:i, v, :]`, values AND row-order — which makes every assertion self-checking.

using Test
using EarthSciAST
using EarthSciIO
using EarthSciIO: Cache, LocalStore, ZarrReader, CSVReader, const_provider,
                  materialize, cache_key, supports_selection
import Blosc
import JSON
using SHA: sha256

# --- minimal zarr store-writing helpers (verbatim shape of EarthSciIO's) ----- #

# C-order flatten of a native (dims-order) array.
_corder(a::AbstractVector) = collect(a)
_corder(a::AbstractArray) = vec(permutedims(a, reverse(1:ndims(a))))

function _z_zarray(shape, chunks, dtype)
    d = Dict("zarr_format" => 2, "shape" => collect(shape), "chunks" => collect(chunks),
             "dtype" => dtype,
             "compressor" => Dict("id" => "blosc", "cname" => "lz4", "clevel" => 5,
                                  "shuffle" => 1, "blocksize" => 0),
             "fill_value" => 0.0, "order" => "C", "filters" => nothing,
             "dimension_separator" => nothing)
    return Vector{UInt8}(codeunits(JSON.json(d)))
end

function _z_encode(chunk::AbstractArray)
    Blosc.set_compressor("lz4")
    flatC = _corder(chunk)
    return Blosc.compress(flatC; level = 5, shuffle = true, itemsize = sizeof(eltype(chunk)))
end

function _z_populate(root, objects)
    store = LocalStore(root)
    for (url, data) in objects
        key = cache_key(url)
        staged = EarthSciIO.staging_path(store)
        write(staged, data)
        EarthSciIO.put_blob!(store, key, staged; ext = "")
        m = EarthSciIO.Manifest(url, nothing, nothing, bytes2hex(sha256(data)),
                                length(data), "2026-06-26T00:00:00Z", nothing, nothing)
        EarthSciIO.put_meta!(store, key, m)
    end
    return store
end

# A Store that records every `get_blob` KEY (each on-demand object fetch is exactly
# one `get_blob` on the fast offline path), so a test can prove ONLY the needed
# objects were fetched. Everything else forwards to a LocalStore.
mutable struct CountingStore <: EarthSciIO.Store
    inner::LocalStore
    gets::Vector{String}
end
CountingStore(inner::LocalStore) = CountingStore(inner, String[])
EarthSciIO.store_name(s::CountingStore) = EarthSciIO.store_name(s.inner)
function EarthSciIO.get_blob(s::CountingStore, key::AbstractString)
    push!(s.gets, String(key))
    return EarthSciIO.get_blob(s.inner, key)
end
EarthSciIO.blob_exists(s::CountingStore, key::AbstractString) = EarthSciIO.blob_exists(s.inner, key)
EarthSciIO.get_meta(s::CountingStore, key::AbstractString) = EarthSciIO.get_meta(s.inner, key)
EarthSciIO.staging_path(s::CountingStore) = EarthSciIO.staging_path(s.inner)
EarthSciIO.put_blob!(s::CountingStore, key::AbstractString, staged::AbstractString; kwargs...) =
    EarthSciIO.put_blob!(s.inner, key, staged; kwargs...)
EarthSciIO.put_meta!(s::CountingStore, key::AbstractString, m::EarthSciIO.Manifest) =
    EarthSciIO.put_meta!(s.inner, key, m)
EarthSciIO.lock_key(f::Function, s::CountingStore, key::AbstractString) =
    EarthSciIO.lock_key(f, s.inner, key)

const ZSEL = "s3://earthsci-fixtures/sr-select.zarr"

# Julia oracle: A[l,s,r] = (l-1)*1_000_000 + (s-1)*1000 + (r-1)  (0-based coords).
const SR_A = let A = Array{Float64}(undef, 3, 50, 4)
    for l in 1:3, s in 1:50, r in 1:4
        A[l, s, r] = (l - 1) * 1_000_000 + (s - 1) * 1000 + (r - 1)
    end
    A
end

# Build the on-disk store from SR_A: shape (3,50,4), chunks (1,10,4) -> 3x5x1 = 15
# chunk objects. `store_ctor` wraps the freshly-populated LocalStore.
function _sr_store(root; store_ctor = identity)
    objs = Dict{String,Vector{UInt8}}()
    objs["$ZSEL/sr/.zarray"] = _z_zarray((3, 50, 4), (1, 10, 4), "<f4")
    objs["$ZSEL/sr/.zattrs"] = Vector{UInt8}(codeunits(JSON.json(
        Dict("_ARRAY_DIMENSIONS" => ["layer", "source", "receptor"]))))
    for c0 in 0:2, c1 in 0:4, c2 in 0:0
        chunk = Array{Float32}(undef, 1, 10, 4)
        for j0 in 0:0, j1 in 0:9, j2 in 0:3
            chunk[j0 + 1, j1 + 1, j2 + 1] =
                Float32(SR_A[c0 + j0 + 1, c1 * 10 + j1 + 1, c2 * 4 + j2 + 1])
        end
        objs["$ZSEL/sr/$c0.$c1.$c2"] = _z_encode(chunk)
    end
    return store_ctor(_z_populate(root, objs))
end

_zarr_provider(store) = const_provider(Cache(store; offline = true, verify = false),
                                       ZSEL; format = "zarr", variables = ["sr"])

# A source with NO protocol methods — provider_supports_selection must default false.
struct _FakeCSVSource end

@testset "provider_sample selection pushdown (Phase 1b)" begin

    @testset "(a) neutral 1-based selection -> native 0-based sub-array, right values" begin
        p = _zarr_provider(_sr_store(mktempdir()))
        # layer 1; sources {3,7,10,25} (1-based); all receptors.
        f = provider_sample(p, 0.0; selection = [1, [3, 7, 10, 25], Colon()])
        @test f isa AbstractArray
        @test size(f) == (1, 4, 4)
        # 1-based selection indexes the oracle directly: A[1:1, [3,7,10,25], :].
        @test f == SR_A[1:1, [3, 7, 10, 25], :]
        # spot-check absolute values (layer 0 => src*1000 + rec).
        @test vec(f[1, 1, :]) == Float64[2000, 2001, 2002, 2003]   # src 3 -> 0-based 2
        @test vec(f[1, 4, :]) == Float64[24000, 24001, 24002, 24003]  # src 25 -> 0-based 24
    end

    @testset "(b) fetch count: only intersecting chunks fetched, huge rest untouched" begin
        store = _sr_store(mktempdir(); store_ctor = CountingStore)
        p = _zarr_provider(store)
        f = provider_sample(p, 0.0; selection = [1, [3, 7, 10, 25], Colon()])
        @test f == SR_A[1:1, [3, 7, 10, 25], :]

        # 0-based indices: layer 0 (chunk 0); sources [2,6,9,24] -> chunks {0,2};
        # receptor chunk 0.  So ONLY chunks (0,0,0) and (0,2,0), plus .zarray/.zattrs.
        expected = Set(cache_key.(["$ZSEL/sr/.zarray", "$ZSEL/sr/.zattrs",
                                    "$ZSEL/sr/0.0.0", "$ZSEL/sr/0.2.0"]))
        @test Set(store.gets) == expected
        @test length(store.gets) == 4
        # Explicitly: none of the other 13 chunk objects were fetched.
        got = Set(store.gets)
        for c0 in 0:2, c1 in 0:4, c2 in 0:0
            (c0, c1, c2) in ((0, 0, 0), (0, 2, 0)) && continue
            @test cache_key("$ZSEL/sr/$c0.$c1.$c2") ∉ got
        end
    end

    @testset "(c) ORDERING: permuted non-contiguous index vector -> rows in that order" begin
        p = _zarr_provider(_sr_store(mktempdir()))
        perm = [25, 3, 10, 7]                      # 1-based, permuted + non-contiguous
        f = provider_sample(p, 0.0; selection = [1, perm, Colon()])
        @test size(f) == (1, 4, 4)
        # rows follow `perm` EXACTLY (not sorted).
        @test f == SR_A[1:1, perm, :]
        @test vec(f[1, 1, :]) == vec(SR_A[1, 25, :])   # first row is src 25, not src 3
        @test vec(f[1, 2, :]) == vec(SR_A[1, 3, :])
        @test vec(f[1, 3, :]) == vec(SR_A[1, 10, :])
        @test vec(f[1, 4, :]) == vec(SR_A[1, 7, :])
        # and it is NOT the sorted result — order is load-bearing.
        @test f != SR_A[1:1, sort(perm), :]
    end

    @testset "(d) selection===nothing ⇒ identical to the pre-pushdown full sample" begin
        p = _zarr_provider(_sr_store(mktempdir()))
        full = provider_sample(p, 0.0)                      # 2-arg, unchanged path
        full_kw = provider_sample(p, 0.0; selection = nothing)
        @test size(full) == (3, 50, 4)
        @test full == SR_A
        @test full_kw == full                               # nothing ≡ no keyword
    end

    @testset "(e) selection on a non-pushdown provider is a clear error" begin
        csv_cache = Cache(LocalStore(mktempdir()); offline = true)
        pcsv = const_provider(csv_cache, "file:///dev/null"; format = "csv")
        err = try
            provider_sample(pcsv, 0; selection = [Colon()])
            nothing
        catch e
            e
        end
        @test err isa EarthSciAST.RefreshError
        @test occursin("does not support selection", sprint(showerror, err))
    end

    @testset "(f) provider_supports_selection: true for zarr, false for csv/mock" begin
        pz = _zarr_provider(_sr_store(mktempdir()))
        @test provider_supports_selection(pz) == true

        csv_cache = Cache(LocalStore(mktempdir()); offline = true)
        pcsv = const_provider(csv_cache, "file:///dev/null"; format = "csv")
        @test provider_supports_selection(pcsv) == false
        @test supports_selection(pcsv) == false           # the underlying bridge

        # a non-EarthSciIO source falls to the generic default.
        @test provider_supports_selection(_FakeCSVSource()) == false
    end

    @testset "1-based validation: a 0-based index in the selection is rejected" begin
        p = _zarr_provider(_sr_store(mktempdir()))
        @test_throws EarthSciAST.RefreshError provider_sample(p, 0.0; selection = [0, [1], Colon()])
        @test_throws EarthSciAST.RefreshError provider_sample(p, 0.0; selection = [1, [0, 3], Colon()])
    end
end
