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
