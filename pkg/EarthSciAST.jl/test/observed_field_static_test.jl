# `observed_field` on a document with NO state variables (API_SPEC §5.8).
#
# A document that declares no differential equations has nothing to integrate,
# but its whole content is its observed graph — and reading that back by name is
# what `observed_field` is for. Two properties are pinned here:
#
#  1. It answers with NO extra construction options. `observed_field` is stable
#     API; a stable function that needs an undocumented build flag to say
#     anything is not one.
#
#  2. The name-resolution rule. A bare name resolves only on a SINGLE-component
#     document. On a multi-component one it is refused with the candidates
#     named, rather than bound to whichever the variable iteration reached
#     first — the wrong-answer-instead-of-missing-answer failure esm-spec
#     §6.6.2 rules specifically non-conforming for override keys.
#
# The Python mirror is `earthsci-ast-py/tests/test_observed_field_static.py`;
# the Rust one is `earthsci-ast-rs/tests/observed_field_static.rs`.

module ObservedFieldStaticTests

using Test
using EarthSciAST
const EA = EarthSciAST

isdefined(@__MODULE__, :TESTUTILS_REPO_ROOT) || include("testutils.jl")

const ONE_COMPONENT = joinpath(TESTUTILS_REPO_ROOT, "tests", "valid",
                               "nonlinear_mogi_shape.esm")
const TWO_COMPONENT = joinpath(TESTUTILS_REPO_ROOT, "tests", "valid",
                               "nonlinear_two_component_static.esm")

# The Mogi fixture's two closed-form displacements at the declared defaults
# (dV = 1e6, d = 3000, r = 1000, nu = 0.25), computed WITHOUT the library so a
# shared bug in the evaluator cannot make this pass by agreeing with itself.
function mogi_oracle()
    dV, d, r, nu = 1.0e6, 3000.0, 1000.0, 0.25
    denom = pi * (r^2 + d^2)^1.5
    return ((1 - nu) * dV * r / denom, (1 - nu) * dV * d / denom)
end

@testset "observed_field on a state-free document" begin

    if _require_fixture(ONE_COMPONENT)
        @testset "single component: both spellings resolve" begin
            ur, uz = mogi_oracle()
            prob = EA.esm_problem(ONE_COMPONENT, (0.0, 1.0))
            @test isempty(prob.u0)          # nothing to integrate
            @test EA.observed_field(prob, "MogiModel.ur")[1] ≈ ur
            @test EA.observed_field(prob, "MogiModel.uz")[1] ≈ uz
            # One component, so the bare spelling names the same field.
            @test EA.observed_field(prob, "ur")[1] ≈ ur
            @test EA.observed_field(prob, "uz")[1] ≈ uz
            # Names the document does not declare stay refused.
            @test_throws EA.SimulateError EA.observed_field(prob, "nope")
            @test_throws EA.SimulateError EA.observed_field(prob, "Nope.ur")
        end

        @testset "p reaches the static fields" begin
            # `ur` is linear in `dV`, so the field must describe the problem
            # that was built rather than the document's declared default.
            ur, _ = mogi_oracle()
            prob = EA.esm_problem(ONE_COMPONENT, (0.0, 1.0);
                                  p = Dict("MogiModel.dV" => 2.0e6))
            @test EA.observed_field(prob, "ur")[1] ≈ 2ur
        end
    end

    if _require_fixture(TWO_COMPONENT)
        @testset "two components: only the qualified spellings resolve" begin
            prob = EA.esm_problem(TWO_COMPONENT, (0.0, 1.0))
            @test EA.observed_field(prob, "Sites.North.u")[1] ≈ 6.0
            @test EA.observed_field(prob, "Sites.North.ur")[1] ≈ 3.0
            @test EA.observed_field(prob, "Sites.South.u")[1] ≈ 35.0

            # Shared local name: refused, with both candidates named.
            e = try
                EA.observed_field(prob, "u"); nothing
            catch err
                err
            end
            @test e isa EA.SimulateError
            @test occursin("bare name", sprint(showerror, e))
            @test occursin("Sites.North.u", sprint(showerror, e))
            @test occursin("Sites.South.u", sprint(showerror, e))

            # UNIQUE local name: still refused. The gate is the component
            # count, not ambiguity — mounting a second component must not
            # silently change what a bare name in an existing script means.
            e = try
                EA.observed_field(prob, "ur"); nothing
            catch err
                err
            end
            @test e isa EA.SimulateError
            @test occursin("bare name", sprint(showerror, e))
            @test occursin("Sites.North.ur", sprint(showerror, e))

            # A partial qualification is not a spelling of anything.
            @test_throws EA.SimulateError EA.observed_field(prob, "North.u")
        end
    end
end

end # module ObservedFieldStaticTests
