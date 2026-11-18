# Conformance harness adapter — pde_inline_dead_observed category.
#
# §6.6.5 inline-test assertions on an array OBSERVED that NO LIVE EQUATION
# CONSUMES. The reference binding (Julia) runs the OFFICIAL `run_inline_tests`
# pathway over the committed fixture and must reproduce the committed golden
# actuals (which that same pathway minted). The manifest declares
# julia/python/rust as bindings_required, so the golden is the shared
# cross-binding anchor.
#
# The assertions read an array observed no live
# equation reads (`diag`, and `chain`, which reads `diag`): the elementwise
# array-observed fold inlines an observed into its readers, so a dead one must
# still be answerable from its defining equation. See
# tests/conformance/pde_inline_dead_observed/ and the unit coverage in
# pde_inline_dead_observed_test.jl.

using Test
using JSON3
using EarthSciAST
import OrdinaryDiffEqTsit5

include("testutils.jl")  # check_inline_golden

@testset "Conformance: pde_inline_dead_observed (manifest-driven)" begin
    # Each golden actual (the cross-binding anchor) and, through `extra`, the
    # fixture's own declared `expected` (author intent).
    check_inline_golden(
        "pde_inline_dead_observed", OrdinaryDiffEqTsit5.Tsit5();
        extra = function (fixture, by_idx, (rtol, atol))
            for a in fixture.assertions
                r = by_idx[Int(a.assertion_idx)]
                @test String(r.variable) == String(a.variable)
                @test isapprox(r.actual, Float64(a.expected); rtol = rtol, atol = atol)
            end
        end
    )
end
