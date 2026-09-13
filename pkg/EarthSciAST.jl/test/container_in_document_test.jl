# A container's inline tests build over the WHOLE DOCUMENT, not over the
# container in isolation (src/run_tests.jl).
#
# `MTK.System(::Model)` wraps one model in a synthetic single-model `EsmFile`,
# which drops everything the document supplies around that container. Two
# things the corpus actually relies on went with it:
#
#   * the document-scoped `expression_templates` registry (`Model` carries no
#     such field), so `expand_flattened_refs` ran against an EMPTY registry,
#     silently did nothing, and a §9.6.4 Option-B `apply_expression_template`
#     reference reached the symbolic lowering as
#     `Unsupported operator: apply_expression_template`;
#   * every sibling component's variables, so an equation reading another
#     component — `D(Rs.A, t)`, the §6.6 instantaneous-derivative shape for a
#     mechanism's species tendencies, or a plain `Rs.A` — died as
#     `Variable 'Rs.A' not found in variable dictionary`.
#
# The Python gate builds `esm_problem` over `flatten(ef)` and the Rust CLI
# builds over the whole flattened document; §6.6 selects WHICH tests run, not
# what the system contains. These fixtures are the two symptoms and a control.
using Test
using EarthSciAST
include("testutils.jl")  # shared prelude: TESTUTILS_REPO_ROOT
import ModelingToolkit
import Catalyst
import OrdinaryDiffEqTsit5
import OrdinaryDiffEqRosenbrock
import OrdinaryDiffEqNonlinearSolve

const _cid_dir = joinpath(@__DIR__, "fixtures", "container_in_document")

@testset "a container builds over its document" begin
    results, exit_code = run_esm_tests([_cid_dir]; root=_cid_dir, verbose=false)

    @test exit_code == 0
    @test !isempty(results)
    @test all(r -> r.status == EarthSciAST.PASS, results)

    # Name the two symptoms explicitly: a regression in either one reappears as
    # its own message, and a bare "some assertion failed" would not say which.
    for r in results
        @test !occursin("Unsupported operator: apply_expression_template",
                        something(r.message, ""))
        @test !occursin("not found in variable dictionary",
                        something(r.message, ""))
    end

    # The product-only species P is reached through the same path as the
    # substrates: it has a net stoichiometry, so it has an ODE, and its
    # tendency is asserted alongside theirs.
    ids = Set(r.test_id for r in results)
    @test "tendencies_at_t0" in ids
    @test "template_reference_at_t0" in ids
    @test "plain_read_at_t0" in ids
end

# ---------------------------------------------------------------------------
# The two ways a DOCUMENT build can be worse than the per-container one it
# replaced. Both are about a container paying for a SIBLING, which is exactly
# the boundary this file is here to pin, so they belong with the fixtures above
# rather than in a file of their own. They run against real corpus documents in
# `tests/` — hand-cut fixtures would restate what those already say.
# ---------------------------------------------------------------------------

function _file_counts(relpath::AbstractString)
    p = joinpath(TESTUTILS_REPO_ROOT, relpath)
    isfile(p) || error("fixture missing: $(relpath)")
    res = EarthSciAST.AssertionResult[]
    EarthSciAST.run_file_tests!(res, p)
    return res
end

@testset "a document this engine cannot build refuses ALL of its containers" begin
    # `tests/valid/units_dimensional_analysis.esm` declares five models. One —
    # `FluidMechanics` — carries `grad(P, dim: x)`, an unlowered rewrite-target
    # operator that puts `x` in the DOCUMENT's independent variables, and
    # `ModelingToolkit.System` refuses a flattened system with spatial
    # independent variables (it redirects to `PDESystem`, which this MTK engine
    # has no route to). Spatiality is a property of the whole flatten, so the
    # refusal reaches all five containers and not just the one that caused it.
    #
    # That is deliberate and it is the CROSS-BINDING number: the Rust CLI
    # reports 0 pass / 18 err on this same file, refusing the whole document for
    # the same unlowered `grad` (`esm test tests/valid/units_dimensional_analysis.esm`).
    # A document must not validate under one binding and fail under another, so
    # the four purely temporal siblings do NOT get a private per-container build
    # that would pass 13 assertions here alone. If this assertion ever goes red
    # with a NON-ZERO pass count, Julia and Rust have diverged about this
    # document — check `esm test` on it before changing the number.
    res = _file_counts("tests/valid/units_dimensional_analysis.esm")
    @test !isempty(res)
    @test count(r -> r.status == EarthSciAST.PASS, res) == 0   # Rust: 0
    @test all(r -> r.status == EarthSciAST.ERROR, res)
    @test all(r -> occursin("PDESystem", r.message), res)
    # All five containers are refused, not only the one carrying the `grad`.
    @test length(Set(r.container_name for r in res)) == 5
end

@testset "an operator_compose merge does not hide the state a test names" begin
    # esm-spec §4.7.1 step 4 / issue #230: a renaming match DELETES the spelling
    # the test keys on (`Sink.O3` folded onto `Chem.ozone`). Only a DOCUMENT
    # build ever sees the coupling that does it, so this became reachable the
    # moment the build moved to document scope; the flatten records the survivor
    # in `merged_variable_renames` and the handle resolution follows it, as the
    # tree-walk engine already did.
    res = _file_counts(
        "tests/conformance/merged_rename_reach/fixtures/" *
        "inline_test_names_the_merged_away_state.esm")
    @test !isempty(res)
    @test all(r -> r.status == EarthSciAST.PASS, res)
end
