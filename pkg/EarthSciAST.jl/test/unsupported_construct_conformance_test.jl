# Cross-language conformance for the three constructs the tree-walk evaluator does
# not run: a continuous event, a discrete event and an implicit equation
# (EarthSciML/EarthSciAST#264, #356).
#
# Drives the shared manifest at `tests/conformance/unsupported_construct/`. The
# tree-walk evaluator serves both `simulate` and `run_inline_tests`, on scalar and
# array documents alike. It used to drop both kinds of event without a word, so an
# inline test reported the model's value as if no event existed (and, for an
# array observed of a discrete event's unknown, "array state ... has no cells in
# var_map"); it refused an implicit equation, but as the Julia-local
# `E_TREEWALK_UNSUPPORTED_EQUATION` naming only the LHS's Julia type. Every
# refusal case must now fail with `unsupported_construct` naming the construct and
# the evaluator; the control must still run. The ModelingToolkit export runs all
# three constructs and is not covered.
#
# `flatten` also used to drop a REACTION SYSTEM's events outright, so the refusal
# never fired for a reaction-system document and both the tree-walk evaluator and
# the ModelingToolkit export ran it without its event; the two
# `..._on_a_reaction_system` cases pin that.

using Test
using EarthSciAST
using JSON3
using OrdinaryDiffEqTsit5   # the inline-test surface needs an ODE algorithm

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _UC_DIR = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance", "unsupported_construct")

@assert isfile(joinpath(_UC_DIR, "manifest.json")) "manifest not found in $(_UC_DIR)"
const _UC_MANIFEST = JSON3.read(read(joinpath(_UC_DIR, "manifest.json"), String))
const _UC_EVALUATOR = "Julia tree-walk evaluator"

@testset "conformance: unsupported_construct (esm-spec §9.6.6)" begin
    @test _UC_MANIFEST.code == EarthSciAST.ERROR_CODES.UNSUPPORTED_CONSTRUCT
    @test "unsupported_construct" in EarthSciAST.error_code_names()
    @test any(c -> c.expect == "run", _UC_MANIFEST.cases)
    @test any(c -> c.expect == "refuse", _UC_MANIFEST.cases)

    for case in _UC_MANIFEST.cases
        path = joinpath(_UC_DIR, String(case.path))
        @testset "$(case.id)" begin
            if case.expect == "refuse"
                construct = String(case.construct)
                # The build itself refuses, with the registered code. Only a
                # single-model document has a model to select; anything else —
                # several models, or a reaction system, whose events reach the
                # evaluator only through `flatten` — is built the way
                # `esm_problem` builds it: flattened first.
                doc = EarthSciAST.load_path(path)
                n_models = doc.models === nothing ? 0 : length(doc.models)
                n_rs = doc.reaction_systems === nothing ? 0 :
                       length(doc.reaction_systems)
                target = (n_models == 1 && n_rs == 0) ? doc : EarthSciAST.flatten(doc)
                err = try
                    EarthSciAST._build_evaluator(target)
                    nothing
                catch e
                    e
                end
                @test err isa EarthSciAST.TreeWalkError
                @test err !== nothing && err.code == "unsupported_construct"
                @test err !== nothing && startswith(err.detail, construct)
                @test err !== nothing && occursin(_UC_EVALUATOR, err.detail)

                # And an inline test reports the refusal, not a number.
                results = run_inline_tests(path; alg=Tsit5())
                @test !isempty(results)
                for r in results
                    @test r.passed == false
                    @test r.actual === nothing
                    @test occursin("unsupported_construct: $(construct)", r.message)
                    @test occursin(_UC_EVALUATOR, r.message)
                end
            else
                results = run_inline_tests(path; alg=Tsit5())
                @test !isempty(results)
                @test all(r -> r.passed, results)
            end
        end
    end
end
