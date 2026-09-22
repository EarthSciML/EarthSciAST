# Cross-binding conformance for one unknown carrying two whole definitions.
#
# Drives the shared manifest at `tests/conformance/doubly_defined_state/`.
# `D(x, t) ~ f` beside `x ~ g` is two equations for one unknown (esm-spec
# §4.9.4), so the document is unbalanced and `validate` reports
# `equation_count_mismatch`. The ruling this category pins is that the BUILD says
# the same thing. This binding used to leave both equations standing —
# `algebraic_states_to_observeds` keeps a doubly-defined name a STATE — and then
# fail deep in classification with the Julia-local
# `E_TREEWALK_UNSUPPORTED_EQUATION: VarExpr`, which named neither the unknown nor
# either equation. Every refusal case must now fail with `equation_count_mismatch`
# naming the unknown and both equations; the controls must still run.
#
# The ModelingToolkit route is a code GENERATOR here (`to_julia_code`), not a
# build, so it is outside this category, exactly as it is for
# `unsupported_construct`.

using Test
using EarthSciAST
using JSON3
using OrdinaryDiffEqTsit5   # the inline-test surface needs an ODE algorithm

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _DD_DIR = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance",
                         "doubly_defined_state")

@assert isfile(joinpath(_DD_DIR, "manifest.json")) "manifest not found in $(_DD_DIR)"
const _DD_MANIFEST = JSON3.read(read(joinpath(_DD_DIR, "manifest.json"), String))

@testset "conformance: doubly_defined_state (esm-spec §4.9.4)" begin
    @test _DD_MANIFEST.code == EarthSciAST.ERROR_CODES.EQUATION_COUNT_MISMATCH
    @test "equation_count_mismatch" in EarthSciAST.error_code_names()
    @test any(c -> c.expect == "run", _DD_MANIFEST.cases)
    @test any(c -> c.expect == "refuse", _DD_MANIFEST.cases)

    for case in _DD_MANIFEST.cases
        path = joinpath(_DD_DIR, String(case.path))
        @testset "$(case.id)" begin
            doc = EarthSciAST.load_path(path)
            if case.expect == "refuse"
                unknown = String(case.unknown)
                # The build refuses, with the registered code, under both
                # compilers — `esm_problem` is the one front door, so the answer
                # must not depend on which one the caller names.
                for compiler in (:native, :interpreter)
                    err = try
                        EarthSciAST.esm_problem(doc, (0.0, 1.0); compiler=compiler)
                        nothing
                    catch e
                        e
                    end
                    @test err isa EarthSciAST.TreeWalkError
                    @test err !== nothing && err.code == "equation_count_mismatch"
                    # The unknown and BOTH equations are named, so the author can
                    # see which of the two definitions to remove.
                    @test err !== nothing && occursin(unknown, err.detail)
                    @test err !== nothing && occursin("D(", err.detail)
                    @test err !== nothing && occursin("§4.9.4", err.detail)
                end

                # …and `validate` says the same, which is what makes the refusal
                # a property of the file rather than of the evaluator.
                result = EarthSciAST.validate(doc)
                @test !result.is_valid
                @test any(e -> e.error_type == "equation_count_mismatch",
                          result.structural_errors)

                # An inline test reports the refusal, not a number.
                results = run_inline_tests(path; alg=Tsit5())
                @test !isempty(results)
                for r in results
                    @test r.passed == false
                    @test r.actual === nothing
                    @test occursin("equation_count_mismatch", r.message)
                end
            else
                results = run_inline_tests(path; alg=Tsit5())
                @test !isempty(results)
                @test all(r -> r.passed, results)
            end
        end
    end
end
