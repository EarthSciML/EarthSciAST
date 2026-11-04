# The run_esm_tests walker (src/run_tests.jl, esm-ol5qa) on runs that compile
# a fixture: PASS/FAIL/exit_code paths, the model-relative fallback in
# _resolve_handle (spec §10.7 subsystem refs), JUnit XML emission, and the
# per-test duration split. The runner compiles through ModelingToolkit, so this
# half runs in the ModelingToolkit suite (test/mtk/runtests.jl); discovery and
# the rest stay in test/run_esm_tests_test.jl.
using Test
using EarthSciAST
import ModelingToolkit
import OrdinaryDiffEqTsit5

const _inline_dir = joinpath(@__DIR__, "..", "fixtures", "inline_tests")

@testset "run_esm_tests walker on compiled fixtures (esm-ol5qa)" begin

    @testset "passing fixture → all PASS" begin
        passing = joinpath(_inline_dir, "passing_decay.esm")
        results, exit_code = run_esm_tests(
            [_inline_dir];
            verbose = false,
            exclude = [
                "failing_decay",
                "subsystem_composed",
            ]
        )
        passing_results = filter(r -> r.file == passing, results)
        @test !isempty(passing_results)
        @test all(r -> r.status == EarthSciAST.PASS, passing_results)
        @test exit_code == 0
    end

    @testset "failing fixture → reports FAIL, exit_code != 0" begin
        failing = joinpath(_inline_dir, "failing_decay.esm")
        results, exit_code = run_esm_tests(
            [_inline_dir];
            verbose = false,
            exclude = [
                "passing_decay",
                "subsystem_composed",
            ]
        )
        failing_results = filter(r -> r.file == failing, results)
        @test !isempty(failing_results)
        @test any(r -> r.status == EarthSciAST.FAIL, failing_results)
        @test exit_code != 0
    end

    @testset "subsystem-composed fixture → all PASS (esm-ol5qa)" begin
        # Exercises the model-relative fallback in _resolve_handle: assertions
        # and parameter_overrides use spec §10.7 fully-qualified refs of the
        # form "ModelName.sub.var", which MTK exposes as the model-relative
        # "sub_var" property (stripping the system-name prefix).
        results, exit_code = run_esm_tests(
            [_inline_dir];
            verbose = false,
            exclude = [
                "failing_decay",
                "passing_decay",
            ]
        )
        @test !isempty(results)
        @test all(r -> r.status == EarthSciAST.PASS, results)
        @test exit_code == 0
    end

    @testset "junit XML emission" begin
        mktempdir() do tmp
            xml_path = joinpath(tmp, "report.xml")
            results, _ = run_esm_tests(
                [_inline_dir];
                verbose = false, junit_xml = xml_path
            )
            @test isfile(xml_path)
            content = read(xml_path, String)
            @test occursin("<testsuites", content)
            @test occursin("FailingDecay", content)
            @test occursin("<failure", content)
        end
    end

    @testset "per-test duration split evenly across assertions (no N-fold overcount)" begin
        results, _ = run_esm_tests(
            [_inline_dir];
            verbose = false,
            exclude = [
                "failing_decay",
                "subsystem_composed",
            ]
        )
        by_test = Dict{Tuple{String, String, String}, Vector{Float64}}()
        for r in results
            push!(
                get!(
                    by_test, (r.file, r.container_name, r.test_id),
                    Float64[]
                ), r.duration_s
            )
        end
        @test !isempty(by_test)
        # Every assertion of one test carries the SAME even share of the
        # test's wall time (the pre-fix code stamped cumulative elapsed time,
        # strictly increasing across a test's assertions).
        for durations in values(by_test)
            @test all(d -> d == durations[1], durations)
            @test all(d -> d >= 0.0, durations)
        end
    end

end
