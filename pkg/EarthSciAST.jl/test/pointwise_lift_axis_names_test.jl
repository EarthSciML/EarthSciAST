# Pointwise lift (§10.5): the grid axes a lifted species is promoted to come
# from the axis NAMES its operator's operands are declared on, not from a
# size lookup.
#
# `_pointwise_lift_axes` used to map each makearray dimension to a declared
# index set purely by matching that dimension's EXTENT. Sizes collide readily —
# a square domain (NLON == NLAT), a vertical axis the same length as some other
# model's node axis, or a second grid mounted in the same document (a regridder's
# target ring is `NLON` long BY CONSTRUCTION, so it aliases `lon` at EVERY grid) —
# and on a collision the lift gave up and promoted the species to a SYNTHETIC
# dense axis `_liftdim<d>_<extent>` instead of an index-set reference.
#
# The names are already present: every operand gathered inside the operator's
# makearray is indexed at the lift's own loop variables and declares an index set
# at each of its positions, so `index(dp, i, j, k)` with `dp :: [lon, lat, lev]`
# says outright that loop `i` runs over `lon`.
#
# EXTENT AGREEMENT is the part that has to be there. A flux-form stencil gathers
# STAGGERED face arrays over the very same loops — `Mx :: [lon_nodes, lat, lev]`
# is read at `i` too — and those name the wrong, one-longer axis. Requiring the
# candidate index set's size to equal the dimension's cell extent rejects exactly
# the staggered operands. It also makes the pass a strict refinement of the size
# match: where only one index set has the dimension's size, any extent-agreeing
# name IS that index set, so nothing that used to resolve can change.

using Test
using EarthSciAST
using OrderedCollections: OrderedDict

include("testutils.jl")

const ESM = EarthSciAST

# A rank-3 makearray over `ext`, one region, whose value gathers each operand in
# `gathers` (name => loop-name-per-position) at the loops `i`/`j`/`k`.
function _mk_operator(ext::Vector{Int}, gathers::Vector{<:Pair})
    body = _n(0.0)
    for (v, loops) in gathers
        body = _op("+", body,
                   _op("index", _v(v), (_v(l) for l in loops)...))
    end
    # The interior-stencil gather the loop detection reads: the lifted species
    # itself, at full rank, every position a loop variable.
    body = _op("+", body, _op("index", _v("sp"), _v("i"), _v("j"), _v("k")))
    return _op("makearray";
               regions=[[[1, ext[1]], [1, ext[2]], [1, ext[3]]]],
               values=ESM.ASTExpr[body])
end

_iset(n) = ESM.IndexSet("interval"; size=n)

@testset "pointwise lift axis names (§10.5)" begin

    # A deliberately hostile size table: EVERY one of the three cell axes
    # collides with something. lon(6) vs lat(6) — a square domain. lev(8) vs
    # lat_nodes(8) — the vertical against a staggered horizontal. And
    # tgt.ring_x(6) — a co-mounted regridder's target ring.
    index_sets = OrderedDict{String,ESM.IndexSet}(
        "lon" => _iset(6), "lat" => _iset(6), "lev" => _iset(8),
        "lon_nodes" => _iset(7), "lat_nodes" => _iset(8), "lev_nodes" => _iset(9),
        "tgt.ring_x" => _iset(6),
    )
    var_shapes = Dict{String,Vector{String}}(
        # Cell-centred, full rank: the decisive witness for all three axes.
        "dp" => ["lon", "lat", "lev"],
        # Staggered face arrays, gathered at the SAME loops — each names a
        # one-longer axis in exactly one position.
        "Mx" => ["lon_nodes", "lat", "lev"],
        "My" => ["lon", "lat_nodes", "lev"],
        "Mz" => ["lon", "lat", "lev_nodes"],
    )
    loops = ["i", "j", "k"]
    ext = [6, 6, 8]
    ma = _mk_operator(ext, ["dp" => loops, "Mx" => loops,
                            "My" => loops, "Mz" => loops])
    size_to_names = ESM._index_sets_by_size(index_sets)

    @testset "names are propagated, staggered operands self-exclude" begin
        named = ESM._lift_axis_names([ma], loops, ext, var_shapes, index_sets, nothing)
        @test named == ["lon", "lat", "lev"]

        gaxes, ranges = ESM._pointwise_lift_axes(ma, loops, size_to_names, "sp", 3;
            mas=[ma], var_shapes=var_shapes, index_sets=index_sets, reg=nothing)
        @test gaxes == ["lon", "lat", "lev"]
        @test !any(a -> startswith(a, "_liftdim"), gaxes)
        for (d, l) in enumerate(loops)
            @test ranges[l] isa ESM.IndexSetRef
            @test (ranges[l]::ESM.IndexSetRef).from == gaxes[d]
        end
    end

    @testset "the staggered witness alone resolves nothing (extent disagrees)" begin
        # Drop the cell-centred operand: every surviving name is one longer than
        # its dimension's extent, so the filter rejects all of them rather than
        # naming a face axis.
        only_faces = _mk_operator(ext, ["Mx" => loops])
        named = ESM._lift_axis_names([only_faces], loops, ext, var_shapes,
                                     index_sets, nothing)
        @test named[1] === nothing            # lon_nodes is 7, the extent is 6
        @test named[2] == "lat"               # Mx's OTHER positions are cell-centred
        @test named[3] == "lev"
    end

    @testset "conflicting evidence declines rather than guessing" begin
        # Two cell-centred operands that disagree about dimension 1 (`lon` vs
        # the regridder ring `tgt.ring_x`, both size 6): ambiguous ⇒ no name.
        shapes2 = merge(var_shapes,
            Dict("ring" => ["tgt.ring_x", "lat", "lev"]))
        ma2 = _mk_operator(ext, ["dp" => loops, "ring" => loops])
        named = ESM._lift_axis_names([ma2], loops, ext, shapes2, index_sets, nothing)
        @test named[1] === nothing
        @test named[2] == "lat"
        @test named[3] == "lev"
        # …and the fallback still produces a usable synthetic axis for that one
        # dimension while naming the other two.
        gaxes, _ = ESM._pointwise_lift_axes(ma2, loops, size_to_names, "sp", 3;
            mas=[ma2], var_shapes=shapes2, index_sets=index_sets, reg=nothing)
        @test gaxes == ["_liftdim1_6", "lat", "lev"]
    end

    @testset "no evidence ⇒ exactly the old size match" begin
        # With no declared-shape operands at all the pass is inert, and the
        # unique-size dimension still resolves while the colliding ones fall
        # back — byte-for-byte the pre-existing behaviour.
        bare = _mk_operator(ext, Pair[])
        gaxes, _ = ESM._pointwise_lift_axes(bare, loops, size_to_names, "sp", 3;
            mas=[bare], var_shapes=Dict{String,Vector{String}}(),
            index_sets=index_sets, reg=nothing)
        @test gaxes == ["_liftdim1_6", "_liftdim2_6", "_liftdim3_8"]
        # And the un-keyworded call (no name evidence available) is unchanged.
        gaxes0, _ = ESM._pointwise_lift_axes(bare, loops, size_to_names, "sp", 3)
        @test gaxes0 == gaxes
    end

    @testset "a repeated loop name is not resolved from a diagonal gather" begin
        # `index(V, i, i, k)` binds one dimension's name to two positions; the
        # lift must not pick one. (Pathological, but the guard is cheap and the
        # alternative is a silent wrong axis.)
        diag_loops = ["i", "i", "k"]
        ma3 = _mk_operator(ext, ["dp" => diag_loops])
        named = ESM._lift_axis_names([ma3], diag_loops, ext, var_shapes,
                                     index_sets, nothing)
        @test named[1] === nothing
        @test named[2] === nothing
        @test named[3] == "lev"
    end
end
