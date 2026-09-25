# The bin-EQUALITY broad phase at SETUP — a `join.on` key pair drives the
# geometry sweep from its key-equality matches instead of testing every tuple
# of the output × contracted product (`_geo_equality_drive`,
# tree_walk/geometry_setup.jl; `_equality_match_index`, src/broad_phase.jl).
#
# The driver is a pure optimization: the driven sweeps still apply the gate to
# every tuple they visit, a MAP writes the same cells, and a contraction folds
# the same terms in the same order. So every case compares the driven array
# against `compiler=:interpreter` (plan field `join_on_gate` off: the dense
# sweep) with `isequal` element by element, and the fold values are chosen so
# a reordered sum would round differently. The engagement counter keeps each
# comparison non-vacuous.

module GeomOnDriveTests

using Test
using EarthSciAST
const EA = EarthSciAST

_op(o, args...) = Dict{String,Any}("op" => o, "args" => Any[args...])
_ix(f, args...) = Dict{String,Any}("op" => "index", "args" => Any[f, args...])
function _agg(output_idx, ranges, expr; kw...)
    d = Dict{String,Any}("op" => "faq", "output_idx" => collect(output_idx),
                         "ranges" => Dict{String,Any}(k => Dict{String,Any}("from" => v)
                                                      for (k, v) in ranges),
                         "args" => Any[], "expr" => expr)
    for (k, v) in kw
        d[String(k)] = v
    end
    return d
end
_on(a, b) = Any[Dict{String,Any}("on" => Any[Any[a, b]])]

const IDX = Dict{String,Int}("S" => 6, "T" => 4, "K" => 2)
const SHAPES = Dict{String,Vector{String}}(
    "sb" => ["S"], "tb" => ["T"], "sv" => ["S"], "tv" => ["T"], "kk" => ["K"],
    "sb_short" => ["S"])
# Bin keys: target 1 matches sources 1, 3, 6; target 2 matches 2 and 5; target 3
# (key -0.0) matches source 4 (key +0.0), since `-0.0 == 0.0`; target 4 is NaN
# and matches nothing, not even the NaN source key a hash on `isequal` would
# pair it with. Source 6 keys as the Int 7 against the Float 7.0.
const ENV0 = Dict{String,Any}(
    "sb" => Any[7.0, 2.0, 7.0, 0.0, 2.0, 7],
    "tb" => Any[7.0, 2.0, -0.0, NaN],
    "sv" => Float64[1e16, 1.0, -1e16, 3.0, 0.5, 1.0],
    "tv" => Float64[1.0, 2.0, 3.0, 4.0],
    "kk" => Float64[1.0, -1.0],
    "sb_short" => Float64[7.0, 2.0],
    "atol" => 0.25)

function both_ways(json, env = ENV0)
    rhs = EA.expression_from_json(json)
    e0 = EA._GEOM_EQ_DRIVE[]
    got = EA._materialize_geom_array(rhs, copy(env), nothing, IDX, SHAPES)
    de = EA._GEOM_EQ_DRIVE[] - e0
    ref = EA._with_compiler_plan(EA._compiler_plan(:interpreter)) do
        EA._materialize_geom_array(rhs, copy(env), nothing, IDX, SHAPES)
    end
    return got, ref, de
end

bitsame(a, b) = size(a) == size(b) && all(isequal(a[i], b[i]) for i in eachindex(a))

@testset "setup-time bin-equality broad phase" begin

    @testset "MAP over both gated indices: PAIRS-driven, bit-identical" begin
        j = _agg(["i", "j"], ["i" => "S", "j" => "T"], _op("*", _ix("sv", "i"), _ix("tv", "j"));
                 join = _on("sb", "tb"))
        got, ref, de = both_ways(j)
        @test de == 1
        @test bitsame(got, ref)
        @test count(!iszero, got) == 6           # (1,1) (3,1) (6,1) (2,2) (5,2) (4,3)
        @test got[4, 3] == 3.0 * 3.0
        @test all(iszero, got[:, 4])             # the NaN key matches nothing
    end

    @testset "MAP with an ungated output index around the pairs" begin
        j = _agg(["i", "k", "j"], ["i" => "S", "k" => "K", "j" => "T"],
                 _op("*", _ix("kk", "k"), _op("+", _ix("sv", "i"), _ix("tv", "j")));
                 join = _on("sb", "tb"))
        got, ref, de = both_ways(j)
        @test de == 1
        @test bitsame(got, ref)
        @test count(!iszero, got) == 12
    end

    @testset "contraction: RESTRICT-driven, same fold order" begin
        # Target 1 folds 1e16 + (-1e16) + 1.0 in source order: 1.0. Any other
        # order of those three terms rounds to 0.0 or 2.0.
        for (nm, extra) in ("plain" => Dict{String,Any}(),
                            "filtered" => Dict{String,Any}(
                                "filter" => _op(">", _op("abs", _ix("sv", "i")), "atol")),
                            "max" => Dict{String,Any}("reduce" => "max"),
                            "min" => Dict{String,Any}("reduce" => "min"))
            j = _agg(["j"], ["i" => "S", "j" => "T"], _ix("sv", "i"); join = _on("sb", "tb"))
            merge!(j, extra)
            got, ref, de = both_ways(j)
            @test (nm, de) == (nm, 1)
            @test (nm, bitsame(got, ref)) == (nm, true)
        end
        j = _agg(["j"], ["i" => "S", "j" => "T"], _ix("sv", "i"); join = _on("sb", "tb"))
        got, _, _ = both_ways(j)
        @test got == [1.0, 1.5, 3.0, 0.0]
    end

    @testset "the gated index may be the contracted one on either side" begin
        j = _agg(["i"], ["i" => "S", "j" => "T"], _op("*", _ix("sv", "i"), _ix("tv", "j"));
                 join = _on("sb", "tb"))
        got, ref, de = both_ways(j)
        @test de == 1
        @test bitsame(got, ref)
        @test got[6] == 1.0
    end

    @testset "declines keep the dense sweep" begin
        # Both gated indices contracted: the drive plan cannot express it.
        j = _agg(["k"], ["i" => "S", "j" => "T", "k" => "K"],
                 _op("*", _ix("kk", "k"), _op("*", _ix("sv", "i"), _ix("tv", "j")));
                 join = _on("sb", "tb"))
        got, ref, de = both_ways(j)
        @test de == 0
        @test bitsame(got, ref)
        # A key column shorter than its range is never indexed.
        rhs = EA.expression_from_json(_agg(["j"], ["i" => "S", "j" => "T"], _ix("sv", "i");
                                           join = _on("sb_short", "tb")))
        g = EA._GeoCompileCtx(EA._GeoCtx(ENV0, nothing, IDX, SHAPES),
                              Dict("j" => 1, "i" => 2), Dict("i" => "S", "j" => "T"), Ref(2))
        gates = EA._geo_slot_gates(rhs, g)
        @test EA._geo_equality_drive(gates, ["j"], ["i"], [4], nothing, IDX, rhs) === nothing
        # A key kind the index does not hash declines rather than guessing.
        env = merge(copy(ENV0), Dict{String,Any}("tb" => Any[[1.0], [2.0], [3.0], [4.0]]))
        g2 = EA._GeoCompileCtx(EA._GeoCtx(env, nothing, IDX, SHAPES),
                               Dict("j" => 1, "i" => 2), Dict("i" => "S", "j" => "T"), Ref(2))
        rhs2 = EA.expression_from_json(_agg(["j"], ["i" => "S", "j" => "T"], _ix("sv", "i");
                                            join = _on("sb", "tb")))
        @test EA._geo_equality_drive(EA._geo_slot_gates(rhs2, g2), ["j"], ["i"], [4],
                                     nothing, IDX, rhs2) === nothing
    end

    @testset "the interpreter takes the dense sweep" begin
        rhs = EA.expression_from_json(_agg(["j"], ["i" => "S", "j" => "T"], _ix("sv", "i");
                                           join = _on("sb", "tb")))
        e0 = EA._GEOM_EQ_DRIVE[]
        EA._with_compiler_plan(EA._compiler_plan(:interpreter)) do
            EA._materialize_geom_array(rhs, copy(ENV0), nothing, IDX, SHAPES)
        end
        @test EA._GEOM_EQ_DRIVE[] == e0
    end

    @testset "the match index" begin
        oi = EA._equality_match_index(1:3, p -> (1, 2.0, 0.0)[p], 1:4, p -> (2, 1.0, -0.0, NaN)[p])
        @test oi.sorted == [(1, 2), (2, 1), (3, 3)]
        @test EA._equality_match_index(1:1, p -> (1, "a"), 1:2, p -> ((1.0, "a"), (1, "b"))[p]).sorted ==
              [(1, 1)]
        @test EA._equality_match_index(1:1, p -> missing, 1:1, p -> 1) === nothing
    end
end

end # module
