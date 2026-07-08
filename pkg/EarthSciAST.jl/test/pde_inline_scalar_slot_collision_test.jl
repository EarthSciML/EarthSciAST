# Regression: model-qualified-first scalar-slot / array-cell resolution in the
# §6.6.5 inline-test runner (pde_inline_tests.jl).
#
# Flattening qualifies every element with its owning model ("M1.k", "M2.k"), and
# a coupled document routinely reuses the same BARE name across sibling
# components (six reaction-rate coefficients all named `k`). The old
# `_scalar_slot` / `_state_cells` did a single OR-pass that accepted a bare-name
# match, so they returned whichever same-bare element came FIRST in `var_map`
# iteration — reading/collecting the WRONG model's element. In Julia this is
# worse than Python: `Dict` iteration is hash-ordered (NOT insertion-ordered),
# so which wrong element wins is non-deterministic across key sets.
#
# The fix is two passes: an exact qualified / exact-bare match first, then a
# bare-suffix fallback (reached only for a bare-keyed single-model build). These
# tests are written to catch the bug INDEPENDENTLY of `Dict` iteration order by
# asserting BOTH models' elements — the single-pass code returns the same
# (hash-first) element for both models, so at least one assertion must fail.

using Test
using EarthSciAST
import JSON3
import OrdinaryDiffEqTsit5
const _SSC_ESS = EarthSciAST

@testset "pde_inline: model-qualified-first slot/cell resolution (§6.6.5)" begin

    # ---- `_scalar_slot`: the model-qualified element wins, order-independent --
    @testset "_scalar_slot prefers the model-qualified element" begin
        vm = Dict("M1.k" => 1, "M2.k" => 2)
        # The buggy single-pass returned whichever bare `k` hashed first for
        # BOTH models, so one of these two catches it regardless of hash order.
        @test _SSC_ESS._scalar_slot(vm, "k", "M1") == 1
        @test _SSC_ESS._scalar_slot(vm, "k", "M2") == 2
        # Bare-suffix fallback still resolves a single-model bare-keyed build.
        @test _SSC_ESS._scalar_slot(Dict("k" => 7), "k", "M2") == 7
        # Absent name → 0 sentinel (unchanged).
        @test _SSC_ESS._scalar_slot(vm, "z", "M2") == 0
    end

    # ---- `_state_cells`: only the asserted model's cells (array analog) -------
    @testset "_state_cells collects only the asserted model's cells" begin
        vm = Dict("M1.u[1]" => 1, "M1.u[2]" => 2,
                  "M2.u[1]" => 3, "M2.u[2]" => 4)
        c1 = _SSC_ESS._state_cells(vm, "u", "M1")
        @test [cell for (cell, _) in c1] == [[1], [2]]
        @test [slot for (_, slot) in c1] == [1, 2]
        c2 = _SSC_ESS._state_cells(vm, "u", "M2")
        @test [cell for (cell, _) in c2] == [[1], [2]]
        @test [slot for (_, slot) in c2] == [3, 4]
        # Bare-suffix fallback: a single-model bare-keyed build still collects.
        cb = _SSC_ESS._state_cells(Dict("u[1]" => 1, "u[2]" => 2), "u", "M9")
        @test [slot for (_, slot) in cb] == [1, 2]
    end

    # ---- End-to-end: run_pde_tests over a 2-model doc (the Julia mirror of the
    #      Python test_run_pde_tests_scalar_observed_tracks_parameter_overrides).
    @testset "run_pde_tests reads each model's own k under overrides" begin
        # Each model M: k(0)=0, dk/dt = a·T, so k(t=1) = a·T. M1 (a=2) is laid
        # out before M2 (a=5). Julia's tree-walk pathway exposes STATES (not
        # scalar observeds) on the trajectory, so `k` is a scalar state here —
        # exactly the `_scalar_slot` lookup the fix guards. M2 owns two tests,
        # each overriding its own T (namespaced `M2.T`); a lone bare-name match
        # would cross-read M1's slot (or, under Julia's hash order, make M1's
        # test read M2's slot), so we assert BOTH models to be order-independent.
        component(a, tests) = Dict{String,Any}(
            "variables" => Dict{String,Any}(
                "T" => Dict("type" => "parameter", "units" => "K", "default" => 10.0),
                "a" => Dict("type" => "parameter", "units" => "1", "default" => a),
                "k" => Dict("type" => "state", "units" => "1", "default" => 0.0)),
            "equations" => Any[
                Dict("lhs" => Dict("op" => "D", "args" => Any["k"], "wrt" => "t"),
                     "rhs" => Dict("op" => "*", "args" => Any["a", "T"]))],
            "tests" => tests)

        doc = Dict{String,Any}(
            "esm" => "0.8.0",
            "metadata" => Dict("name" => "scalar_slot_param_override"),
            "models" => Dict{String,Any}(
                "M1" => component(2.0, Any[
                    Dict("id" => "m1_base",
                         "time_span" => Dict("start" => 0.0, "end" => 1.0),
                         "assertions" => Any[Dict("variable" => "k", "time" => 1.0,
                             "expected" => 20.0, "tolerance" => Dict("rel" => 1e-9))])]),
                "M2" => component(5.0, Any[
                    Dict("id" => "t_lo",
                         "time_span" => Dict("start" => 0.0, "end" => 1.0),
                         "parameter_overrides" => Dict("M2.T" => 10.0),
                         "assertions" => Any[Dict("variable" => "k", "time" => 1.0,
                             "expected" => 50.0, "tolerance" => Dict("rel" => 1e-9))]),
                    Dict("id" => "t_hi",
                         "time_span" => Dict("start" => 0.0, "end" => 1.0),
                         "parameter_overrides" => Dict("M2.T" => 20.0),
                         "assertions" => Any[Dict("variable" => "k", "time" => 1.0,
                             "expected" => 100.0, "tolerance" => Dict("rel" => 1e-9))])])))

        file = _SSC_ESS.load(IOBuffer(JSON3.write(doc)))
        results = run_pde_tests(file; alg = OrdinaryDiffEqTsit5.Tsit5(),
                                reltol = 1e-12, abstol = 1e-14)
        by = Dict((r.model, r.test_id) => r for r in results)
        @test Set(keys(by)) == Set([("M1", "m1_base"), ("M2", "t_lo"), ("M2", "t_hi")])

        # M2's k tracks M2's OWN per-test T override: 5·10 then 5·20, distinct.
        @test by[("M2", "t_lo")].actual ≈ 50.0 rtol=1e-9
        @test by[("M2", "t_hi")].actual ≈ 100.0 rtol=1e-9
        @test by[("M2", "t_lo")].actual != by[("M2", "t_hi")].actual
        # M1's k is read from M1's OWN slot (2·10), not shadowed by M2's `k`.
        @test by[("M1", "m1_base")].actual ≈ 20.0 rtol=1e-9
        @test all(r.passed for r in results)
    end
end
