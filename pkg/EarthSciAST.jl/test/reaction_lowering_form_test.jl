# Cross-language pin for the EXACT TREE a reaction system lowers to.
#
# Drives the shared, hand-written corpus at
# tests/conformance/reactions/lowering_form.json: every binding's `derive_odes`
# and `flatten` must produce the same expressions for a reaction network,
# compared as JSON with integer and non-integer numbers kept apart
# (esm-libraries-spec §4.6.2). Derived documents copy flattened terms verbatim,
# so a binding that lowers a reaction to a different tree writes different
# bytes. Before §4.6.2 this binding wrote a loss as a unary minus and every
# other coefficient as a float (`-2.0`); `serialize_expression` keeps a
# `NumExpr` a float, so the kind-aware comparison below is what catches that.
#
# The expected trees are read with JSON.jl, which keeps `-1` an `Int64` and
# `1.5` a `Float64`; the documents are read with JSON3 and handed to
# `load_string` as text, which keeps the `species` key order the lowering walks.

using Test
using JSON
using JSON3
using EarthSciAST

if !isdefined(Main, :ESM_TESTUTILS_LOADED)
    include("testutils.jl")
end

const _REACTION_LOWERING_CORPUS_PATH = joinpath(
    TESTUTILS_REPO_ROOT, "tests", "conformance", "reactions", "lowering_form.json")

"""JSON equality that keeps integers and non-integers apart."""
function _lowering_same(actual, expected)::Bool
    if expected isa Real
        return actual isa Real && (actual isa Integer) == (expected isa Integer) &&
               actual == expected
    elseif expected isa AbstractDict
        actual isa AbstractDict || return false
        Set(String.(collect(keys(actual)))) == Set(String.(collect(keys(expected)))) || return false
        return all(_lowering_same(actual[k], expected[k]) for k in keys(expected))
    elseif expected isa AbstractVector
        actual isa AbstractVector && length(actual) == length(expected) || return false
        return all(_lowering_same(a, e) for (a, e) in zip(actual, expected))
    else
        return actual == expected
    end
end

"""The species a flattened left-hand side differentiates: `D(x, t)`, or the
lift's `faq` over `D(index(x, …), t)`."""
function _lowering_species(lhs::AbstractDict)::String
    d = lhs["op"] == "faq" ? lhs["expr"] : lhs
    @test d["op"] == "D"
    target = d["args"][1]
    return target isa AbstractDict ? String(target["args"][1]) : String(target)
end

@testset "Reaction lowering form conformance" begin
    if _require_fixture(_REACTION_LOWERING_CORPUS_PATH)
        text = read(_REACTION_LOWERING_CORPUS_PATH, String)
        documents = JSON3.read(text)["cases"]
        cases = JSON.parse(text)["cases"]
        @test length(cases) >= 3

        for (case, document_case) in zip(cases, documents)
            @testset "$(case["name"])" begin
                system_name = case["system"]
                file = load_string(JSON3.write(document_case["document"]))

                model = derive_odes(file.reaction_systems[system_name])
                @test length(model.equations) == length(case["derive_odes"])
                for (eq, exp) in zip(model.equations, case["derive_odes"])
                    @test _lowering_same(EarthSciAST.serialize_expression(eq.lhs), exp["lhs"])
                    @test _lowering_same(EarthSciAST.serialize_expression(eq.rhs), exp["rhs"])
                end

                flat = flatten(file)
                selected = Tuple{Any,Vector{EarthSciAST.Contribution},EarthSciAST.Contribution}[]
                for (eq, contributions) in zip(flat.equations, flat.equation_contributions)
                    mine = [c for c in contributions
                            if length(c.origins) == 1 &&
                               c.origins[1].component == system_name &&
                               c.origins[1].coupling === nothing]
                    isempty(mine) && continue
                    @test length(mine) == 1
                    push!(selected, (eq, contributions, mine[1]))
                end
                @test length(selected) == length(case["flatten"])
                for ((eq, contributions, contribution), exp) in zip(selected, case["flatten"])
                    lhs = EarthSciAST.serialize_expression(eq.lhs)
                    @test _lowering_species(lhs) == exp["species"]
                    @test _lowering_same(EarthSciAST.serialize_expression(contribution.expr),
                                         exp["contribution"])
                    if !case["lifted"]
                        @test length(contributions) == 1
                        @test _lowering_same(EarthSciAST.serialize_expression(eq.rhs), exp["contribution"])
                        @test _lowering_same(lhs, Dict("op" => "D",
                            "args" => Any[exp["species"]], "wrt" => "t"))
                    end
                end
            end
        end
    end
end
