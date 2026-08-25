# Cross-language conformance for SPECIES ORDER in the two Analysis-tier
# reaction operations — `derive_odes` and `stoichiometric_matrix`
# (API_SPEC.md §5.10).
#
# Drives the shared corpus at tests/conformance/reactions/species_order.json.
# Unlike tests/conformance/graph/cases.json this corpus is HAND-WRITTEN: there
# is no generator and no oracle binding, so the expected values were derived
# from the documents themselves and cross-checked against the bindings.
#
# WHY the pin exists: species order is OBSERVABLE — it *is* the ROW order of
# the stoichiometric matrix and the EQUATION order of the derived model — so it
# is a contract, not an implementation detail. Nothing in `tests/` asserted it,
# and five bindings quietly diverged for the length of the project (Go sorted in
# both operations, Rust sorted in `stoichiometric_matrix` only, Julia/Python/
# TypeScript used declaration order in both). Canonical order is DECLARATION
# order: the order the document writes the `species` object's keys in. This file
# is Julia's driver; §5.10 and the corpus README list the other four.
#
# ANTI-VACUITY. Every case declares its species in an order that is NOT their
# sorted order (asserted below, per case), and at least two cases must be read,
# so a binding that sorts fails rather than passing by coincidence. The derived
# model is read through `model.equations` DIRECTLY and never through
# `ode_states`, which sorts its result by design (esm-spec §6.3.1) and would
# make the assertion pass vacuously in every binding.

using Test
using JSON3
using EarthSciAST

# `testutils.jl` provides TESTUTILS_REPO_ROOT + `_require_fixture`. `Test` must
# already be imported before it is included (its guard block expands
# `@test_skip` at lowering time).
if !isdefined(Main, :ESM_TESTUTILS_LOADED)
    include("testutils.jl")
end

const _REACTION_ORDER_CORPUS_PATH = joinpath(
    TESTUTILS_REPO_ROOT, "tests", "conformance", "reactions", "species_order.json")

"""Rows of a `Matrix` as plain `Vector{Float64}`s, for row-wise comparison."""
_rows(S::AbstractMatrix) = [Float64.(collect(S[i, :])) for i in 1:size(S, 1)]

"""Rows of the corpus' nested-array expectation, likewise as `Vector{Float64}`."""
_rows(rows::Union{JSON3.Array,AbstractVector}) = [Float64.(collect(r)) for r in rows]

"""
The species each equation of `model` differentiates, in EQUATION order.

Each reaction-derived equation's LHS is a `D(<species>, t)` node; the species is
that node's FIRST argument. Read directly — deliberately NOT via `ode_states`.
"""
function _equation_species(model::EarthSciAST.Model)
    names = String[]
    for eq in model.equations
        @test eq.lhs isa EarthSciAST.OpExpr
        @test eq.lhs.op == "D"
        target = eq.lhs.args[1]
        @test target isa EarthSciAST.VarExpr
        push!(names, target.name)
    end
    return names
end

@testset "Reaction species order conformance" begin
    if _require_fixture(_REACTION_ORDER_CORPUS_PATH)
        corpus = JSON3.read(read(_REACTION_ORDER_CORPUS_PATH, String))
        cases = corpus["cases"]

        # Anti-vacuity: the corpus must actually have been read, and with more
        # than a single case (one of the two is a full reverse-sorted chain).
        @test length(cases) >= 2

        for case in cases
            name = String(case["name"])
            @testset "$name" begin
                declaration = [String(s) for s in case["species_declaration_order"]]
                sorted_order = [String(s) for s in case["species_sorted_order"]]

                # Anti-vacuity, per case: declaration order and sorted order
                # MUST differ, or a sorting binding would pass by coincidence.
                @test declaration != sorted_order
                @test sort(declaration) == sorted_order

                # Round-tripped through JSON TEXT into `load_string` rather than
                # normalized into a Dict for `load_document`: the property
                # under test is the `species` object's KEY ORDER, which an
                # unordered Dict would destroy before the loader ever saw it.
                file = load_string(JSON3.write(case["document"]))
                @test file.reaction_systems !== nothing
                system = file.reaction_systems[String(case["system"])]

                # Rows = species in DECLARATION order, columns = reactions in
                # declaration order, entries = products − substrates.
                @test _rows(stoichiometric_matrix(system)) ==
                      _rows(case["stoichiometric_matrix"])

                # Equation order of the DERIVED model. A reservoir species
                # (`constant: true`) keeps its matrix row but lowers to a
                # parameter, so it contributes no equation.
                expected_eq_species =
                    [String(s) for s in case["derive_odes_equation_species"]]
                @test _equation_species(derive_odes(system)) == expected_eq_species
            end
        end
    end
end
