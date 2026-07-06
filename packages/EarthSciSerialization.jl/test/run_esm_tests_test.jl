# Tests for the run_esm_tests walker (src/run_tests.jl, esm-ol5qa).
#
# Covers: discover_esm_files, run_esm_tests PASS/FAIL/exit_code paths, the
# model-relative fallback in _resolve_handle (spec §10.7 subsystem refs), and
# JUnit XML emission.
using Test
using EarthSciSerialization
import ModelingToolkit
import OrdinaryDiffEqTsit5

const _inline_dir = joinpath(@__DIR__, "fixtures", "inline_tests")

@testset "run_esm_tests walker (esm-ol5qa)" begin

    @testset "discover_esm_files" begin
        found = discover_esm_files([_inline_dir])
        @test length(found) == 3
        @test all(endswith(f, ".esm") for f in found)
        @test issorted(found)
    end

    @testset "root keyword resolves relative roots (no esm_root override)" begin
        found = discover_esm_files(["inline_tests"];
                                   root=joinpath(@__DIR__, "fixtures"))
        @test length(found) == 3
        @test all(endswith(f, ".esm") for f in found)
    end

    @testset "zero-file discovery warns" begin
        @test_logs (:warn, r"discovered no \.esm files") begin
            results, exit_code = run_esm_tests(["no_such_dir_anywhere"];
                                                verbose=false)
            @test isempty(results)
            @test exit_code == 0
        end
    end

    @testset "discover_esm_files honours exclude" begin
        kw = discover_esm_files([_inline_dir]; exclude=["failing_decay"])
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

    @testset "passing fixture → all PASS" begin
        passing = joinpath(_inline_dir, "passing_decay.esm")
        results, exit_code = run_esm_tests([_inline_dir];
                                            verbose=false,
                                            exclude=["failing_decay",
                                                     "subsystem_composed"])
        passing_results = filter(r -> r.file == passing, results)
        @test !isempty(passing_results)
        @test all(r -> r.status == EarthSciSerialization.PASS, passing_results)
        @test exit_code == 0
    end

    @testset "failing fixture → reports FAIL, exit_code != 0" begin
        failing = joinpath(_inline_dir, "failing_decay.esm")
        results, exit_code = run_esm_tests([_inline_dir];
                                            verbose=false,
                                            exclude=["passing_decay",
                                                     "subsystem_composed"])
        failing_results = filter(r -> r.file == failing, results)
        @test !isempty(failing_results)
        @test any(r -> r.status == EarthSciSerialization.FAIL, failing_results)
        @test exit_code != 0
    end

    @testset "subsystem-composed fixture → all PASS (esm-ol5qa)" begin
        # Exercises the model-relative fallback in _resolve_handle: assertions
        # and parameter_overrides use spec §10.7 fully-qualified refs of the
        # form "ModelName.sub.var", which MTK exposes as the model-relative
        # "sub_var" property (stripping the system-name prefix).
        results, exit_code = run_esm_tests([_inline_dir];
                                            verbose=false,
                                            exclude=["failing_decay",
                                                     "passing_decay"])
        @test !isempty(results)
        @test all(r -> r.status == EarthSciSerialization.PASS, results)
        @test exit_code == 0
    end

    @testset "junit XML emission" begin
        mktempdir() do tmp
            xml_path = joinpath(tmp, "report.xml")
            results, _ = run_esm_tests([_inline_dir];
                                        verbose=false, junit_xml=xml_path)
            @test isfile(xml_path)
            content = read(xml_path, String)
            @test occursin("<testsuites", content)
            @test occursin("FailingDecay", content)
            @test occursin("<failure", content)
        end
    end

    @testset "per-test duration split evenly across assertions (no N-fold overcount)" begin
        results, _ = run_esm_tests([_inline_dir];
                                    verbose=false,
                                    exclude=["failing_decay",
                                             "subsystem_composed"])
        by_test = Dict{Tuple{String,String,String},Vector{Float64}}()
        for r in results
            push!(get!(by_test, (r.file, r.container_name, r.test_id),
                        Float64[]), r.duration_s)
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

    @testset "junit testcase time == sum of per-assertion durations" begin
        # Synthetic results with known durations: the testcase `time` must be
        # exactly the sum of its assertions' duration_s.
        mk(i, dur) = EarthSciSerialization.AssertionResult(
            "f.esm", :model, "M", "t1", i, "x", 0.0, 1.0, 1.0,
            EarthSciSerialization.PASS, "", dur)
        results = [mk(1, 0.125), mk(2, 0.125), mk(3, 0.125)]
        mktempdir() do tmp
            xml_path = joinpath(tmp, "durations.xml")
            write_junit_xml(results, xml_path)
            content = read(xml_path, String)
            @test occursin("time=\"0.375\"", content)
        end
    end

end
