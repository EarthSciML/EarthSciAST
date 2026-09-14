# A bare `const` array as an `index` base, run through the MTK inline-test
# runner (issue #286). esm-spec §9.2 says a `const` array carries tables that
# "participate in `index` lookups", and CONFORMANCE_SPEC §5.5.5 fixes how an
# out-of-range const-array gather behaves, so the spelling is legal; the MTK
# lowering refused it outright. Two spellings are pinned — the table named by an
# observed whose definition is the `const`, and the `const` written inline — at
# an index only known once the observeds are evaluated, plus the out-of-range
# default (raise, never the zero ghost) and the row-major layout of a 2-D table.

using Test
using EarthSciAST
import JSON3
import ModelingToolkit
import OrdinaryDiffEqTsit5

const _CAI_TABLE = [10.0, 20.0, 30.0, 40.0, 50.0]

# `plnk = table[T - 159]` with `T` a chain of observeds; the flux state gives
# the system something to integrate. `inline=true` writes the table into the
# `index` node instead of naming a `totplnk` observed.
function _cai_doc(; T_surface=163.0, inline=false, index=nothing, expected=40.0)
    table = Dict{String,Any}("op" => "const", "args" => Any[], "value" => _CAI_TABLE)
    idx = index === nothing ?
        Dict{String,Any}("op" => "-", "args" => Any["T", 159]) : index
    variables = Dict{String,Any}(
        "T_surface" => Dict("type" => "unknown"),
        "T" => Dict("type" => "unknown"),
        "plnk" => Dict("type" => "unknown"),
        "flux" => Dict("type" => "unknown", "default" => 0.0))
    equations = Any[
        Dict("lhs" => "T_surface", "rhs" => T_surface),
        Dict("lhs" => "T", "rhs" => "T_surface"),
        Dict("lhs" => "plnk", "rhs" => Dict("op" => "index",
            "args" => Any[inline ? table : "totplnk", idx])),
        Dict("lhs" => Dict("op" => "D", "args" => Any["flux"], "wrt" => "t"),
             "rhs" => 0.0)]
    if !inline
        variables["totplnk"] = Dict("type" => "unknown", "shape" => Any["tbl"])
        push!(equations, Dict("lhs" => "totplnk", "rhs" => table))
    end
    return Dict{String,Any}(
        "esm" => "1.0.0",
        "metadata" => Dict("name" => "ConstArrayIndex"),
        "index_sets" => Dict("tbl" => Dict("kind" => "interval", "size" => 5)),
        "models" => Dict("Solo" => Dict(
            "variables" => variables,
            "equations" => equations,
            "tests" => Any[Dict(
                "id" => "gather",
                "time_span" => Dict("start" => 0.0, "end" => 1.0),
                "assertions" => Any[Dict("variable" => "plnk", "time" => 0.0,
                                         "expected" => expected)])])))
end

function _cai_run(doc)
    path = joinpath(mktempdir(), "doc.esm")
    write(path, JSON3.write(doc))
    results = EarthSciAST.AssertionResult[]
    EarthSciAST.run_file_tests!(results, path)
    @test length(results) == 1
    return only(results)
end

@testset "MTK — bare const array as an index base (#286)" begin
    @testset "$(inline ? "inline" : "named") table, observed index" for inline in (false, true)
        r = _cai_run(_cai_doc(; inline))
        @test r.status == EarthSciAST.PASS
        @test r.actual == 40.0
        # A different index reads a different element: the gather is evaluated,
        # not folded to one constant.
        r = _cai_run(_cai_doc(; inline, T_surface=161.0, expected=20.0))
        @test r.status == EarthSciAST.PASS
        @test r.actual == 20.0
    end

    @testset "$(inline ? "inline" : "named") table, literal index" for inline in (false, true)
        r = _cai_run(_cai_doc(; inline, index=4))
        @test r.status == EarthSciAST.PASS
        @test r.actual == 40.0
    end

    # §5.5.5: no boundary policy is declared, so out of range raises — at a
    # run-time index and at a literal one — and never reads the zero ghost.
    @testset "$(inline ? "inline" : "named") table, out of range" for inline in (false, true)
        for doc in (_cai_doc(; inline, T_surface=170.0), _cai_doc(; inline, index=7),
                    _cai_doc(; inline, index=0))
            r = _cai_run(doc)
            @test r.status == EarthSciAST.ERROR
            @test occursin("E_TREEWALK_CONSTARRAY_OOB", r.message)
        end
    end

    # `value[i][j]` is element (i, j): row 2, column 3 of [[1,2,3],[4,5,6]].
    @testset "2-D table is row-major" begin
        doc = _cai_doc(; inline=true, expected=6.0)
        eqs = doc["models"]["Solo"]["equations"]
        eqs[1]["rhs"] = 161.0   # T - 159 = 2
        eqs[3]["rhs"] = Dict("op" => "index", "args" => Any[
            Dict("op" => "const", "args" => Any[],
                 "value" => Any[[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]]),
            Dict("op" => "-", "args" => Any["T", 159]), 3])
        r = _cai_run(doc)
        @test r.status == EarthSciAST.PASS
        @test r.actual == 6.0
    end
end
