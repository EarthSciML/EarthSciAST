# The esm-spec §9.5.3 `table_lookup` lowering on the evaluation paths that go
# through ModelingToolkit (issue #188): the inline-test runner
# (`run_esm_tests`, which compiles through the MTK extension) over the shared
# function_tables fixtures, and `compiler = :mtk` refusing an
# `out_of_bounds: "error"` table by name (§9.5.3a) rather than clamp. The rest
# of the lowering-path tests are test/function_tables_lowering_path_test.jl.

using Test
using EarthSciAST
using JSON3
import ModelingToolkit             # activates the MTK ext `run_esm_tests` compiles through
import OrdinaryDiffEqTsit5

const _FTP = EarthSciAST

const FT_PATH_FIXTURES_ROOT = abspath(
    joinpath(
        @__DIR__, "..", "..", "..", "..",
        "tests", "conformance", "function_tables"
    )
)

_ft_path_fixture(name) = joinpath(FT_PATH_FIXTURES_ROOT, name, "fixture.esm")

@testset "table_lookup lowering through ModelingToolkit (esm-spec §9.5.3, #188)" begin

    # ---- The regression itself: the shared end-to-end fixture, run through the
    #      inline-test runner (§6.6, Julia's `esm test`). `y` is a table_lookup,
    #      `z` its hand-lowered twin, `w` a lookup above the last knot that the
    #      default `out_of_bounds: "clamp"` holds at the last table value.
    #      Before the fix `y` and `w` could not even compile ("Unsupported
    #      operator: table_lookup") while `z` answered 25.
    @testset "inline_test fixture: all three assertions pass (#188)" begin
        dir = joinpath(FT_PATH_FIXTURES_ROOT, "inline_test")
        results, exit_code = _FTP.run_esm_tests([dir]; root = dir, verbose = false)
        @test length(results) == 3
        by = Dict(r.variable => r for r in results)
        for (name, expected) in ("y" => 25.0, "z" => 25.0, "w" => 40.0)
            r = get(by, name, nothing)
            @test r !== nothing
            r === nothing && continue
            @test r.status == _FTP.PASS
            @test r.actual ≈ expected rtol = 1.0e-12
        end
        # §9.5's central promise: the lowered lookup and the hand-written
        # inline-const one are the SAME computation, not merely close.
        @test by["y"].actual == by["z"].actual
        @test exit_code == 0
    end

    # The §9.5.3 `nearest` composition and the §9.5.2 / §9.5.3 defaults, through
    # the same runner. Each fixture's assertions carry their expected values.
    for name in ("nearest", "lookup_defaults")
        @testset "$(name) fixture through the inline-test runner" begin
            dir = joinpath(FT_PATH_FIXTURES_ROOT, name)
            doc = JSON3.read(read(_ft_path_fixture(name), String))
            want = Dict(
                String(a.variable) => Float64(a.expected)
                    for m in values(doc.models) for t in m.tests for a in t.assertions
            )
            results, exit_code = _FTP.run_esm_tests([dir]; root = dir, verbose = false)
            @test length(results) == length(want)
            for r in results
                @test r.status == _FTP.PASS
                @test r.actual == want[r.variable]
            end
            @test exit_code == 0
        end
    end


    # The ModelingToolkit lowering has no raising form, so `compiler = :mtk`
    # refuses an `out_of_bounds: "error"` table by name rather than clamp —
    # on the fixture's linear table, and on a nearest one.
    @testset "out_of_bounds: \"error\" is refused by :mtk (§9.5.3a)" begin
        raised(f) = try
            f(); nothing
        catch err
            err
        end
        path = _ft_path_fixture("out_of_bounds_error")
        e3 = raised(() -> _FTP.esm_problem(path, (0.0, 1.0); compiler = :mtk))
        @test e3 isa _FTP.TableLookupError
        @test e3 isa _FTP.TableLookupError &&
            e3.code == ERROR_CODES.TABLE_OUT_OF_BOUNDS_UNSUPPORTED

        doc = JSON3.read(read(path, String), Dict{String, Any})
        doc["function_tables"]["strict_tab"]["interpolation"] = "nearest"
        m = doc["models"]["M"]
        m["variables"]["x"] = Dict{String, Any}("type" => "unknown", "default" => 2.5)
        push!(
            m["equations"], Dict(
                "lhs" => Dict("op" => "D", "args" => Any["x"], "wrt" => "t"),
                "rhs" => Dict(
                    "op" => "table_lookup", "table" => "strict_tab",
                    "axes" => Dict("p" => "x"), "args" => Any[]
                )
            )
        )
        e4 = raised(() -> _FTP.esm_problem(doc, (0.0, 1.0); compiler = :mtk))
        @test e4 isa _FTP.TableLookupError &&
            e4.code == ERROR_CODES.TABLE_OUT_OF_BOUNDS_UNSUPPORTED
    end
end
