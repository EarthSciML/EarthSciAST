# Tests for the run_esm_tests walker (src/run_tests.jl, esm-ol5qa).
#
# Covers what needs no compiled system: discover_esm_files, the zero-file
# warning, and the JUnit testcase-time arithmetic. The runs that compile a
# fixture (PASS/FAIL/exit_code, the model-relative fallback in _resolve_handle
# for spec §10.7 subsystem refs, and JUnit XML emission from a real run) go
# through ModelingToolkit, so they live in the ModelingToolkit suite as
# test/mtk/run_esm_tests_mtk_test.jl.
using Test
using EarthSciAST

const _inline_dir = joinpath(@__DIR__, "fixtures", "inline_tests")

@testset "run_esm_tests walker (esm-ol5qa)" begin

    @testset "discover_esm_files" begin
        found = discover_esm_files([_inline_dir])
        @test length(found) == 3
        @test all(endswith(f, ".esm") for f in found)
        @test issorted(found)
    end

    @testset "root keyword resolves relative roots (no esm_root override)" begin
        found = discover_esm_files(
            ["inline_tests"];
            root = joinpath(@__DIR__, "fixtures")
        )
        @test length(found) == 3
        @test all(endswith(f, ".esm") for f in found)
    end

    @testset "zero-file discovery warns" begin
        @test_logs (:warn, r"discovered no \.esm files") begin
            results, exit_code = run_esm_tests(
                ["no_such_dir_anywhere"];
                verbose = false
            )
            @test isempty(results)
            @test exit_code == 0
        end
    end

    @testset "discover_esm_files honours exclude" begin
        kw = discover_esm_files([_inline_dir]; exclude = ["failing_decay"])
        @test length(kw) == 2
        @test any(endswith(f, "passing_decay.esm") for f in kw)
        @test any(endswith(f, "subsystem_composed_decay.esm") for f in kw)

        prev = get(ENV, "ESM_TESTS_EXCLUDE", nothing)
        try
            ENV["ESM_TESTS_EXCLUDE"] = "failing_decay.esm"
            envf = discover_esm_files([_inline_dir])
            @test length(envf) == 2
            @test any(endswith(f, "passing_decay.esm") for f in envf)
        finally
            if prev === nothing
                delete!(ENV, "ESM_TESTS_EXCLUDE")
            else
                ENV["ESM_TESTS_EXCLUDE"] = prev
            end
        end
    end

    @testset "junit testcase time == sum of per-assertion durations" begin
        # Synthetic results with known durations: the testcase `time` must be
        # exactly the sum of its assertions' duration_s.
        mk(i, dur) = EarthSciAST.AssertionResult(
            "f.esm", :model, "M", "t1", i, "x", 0.0, 1.0, 1.0,
            EarthSciAST.PASS, "", dur
        )
        results = [mk(1, 0.125), mk(2, 0.125), mk(3, 0.125)]
        mktempdir() do tmp
            xml_path = joinpath(tmp, "durations.xml")
            write_junit_xml(results, xml_path)
            content = read(xml_path, String)
            @test occursin("time=\"0.375\"", content)
        end
    end

end
