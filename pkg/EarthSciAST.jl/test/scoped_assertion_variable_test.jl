# An assertion's `variable` may be a SCOPED reference (issue #263).
#
# The schema documents `Assertion.variable` as "the local name (e.g. "O3") or a
# scoped reference relative to this component (e.g. "subsystem.X")", and the
# same string already resolves as an equation operand. The runner looked the
# name up in the asserting component's own `variables` only, so a `coords` or
# `reduce` assertion on a mounted leaf's field errored with
# `variable 'Leaf.key' is not declared in model 'Host'`, and with two components
# answering to `Leaf` a pointwise one read the wrong one.
#
# The fixtures are shared with the Python and Rust bindings
# (tests/conformance/scoped_assertion_variable/), which pin the same rule.

using Test
using EarthSciAST
import OrdinaryDiffEqTsit5

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _SAV_DIR = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance",
                          "scoped_assertion_variable", "fixtures")

_sav_run(name) = run_inline_tests(joinpath(_SAV_DIR, name);
                                  alg=OrdinaryDiffEqTsit5.Tsit5())

function _sav_actuals(results)
    for r in results
        @test r.status == PASS
        r.status == PASS || @info "assertion did not pass" r.variable r.message
    end
    return [r.actual for r in results]
end

@testset "Scoped Assertion.variable (issue #263)" begin
    @testset "the leaf alone passes" begin
        results = _sav_run("leaf.esm")
        @test [r.container_name for r in results] == ["Leaf", "Leaf"]
        _sav_actuals(results)
    end

    # Both mount forms: a sibling top-level `{ref}` (document-absolute) and the
    # asserting model's own `subsystems` mount (component-relative).
    for name in ("top_level_mount.esm", "nested_mount.esm")
        @testset "a mounted leaf is assertable by scoped name: $name" begin
            results = _sav_run(name)
            @test [r.container_name for r in results] == fill("Host", 5)
            @test [r.variable for r in results] ==
                  ["w", "Leaf.u", "Leaf.v", "Leaf.key", "Leaf.key"]
            actual = _sav_actuals(results)
            e = exp(-1)
            @test all(isapprox.(actual, [3e, e, 2e, 7.0, 9.0]; rtol=1e-4))
        end
    end

    # The equation binder reads `Leaf.u` in `Host` as `Host`'s own subsystem
    # when it has one; an assertion must read the same component.
    @testset "a subsystem shadows a top-level component of the same name" begin
        actual = _sav_actuals(_sav_run("shadowed_mount.esm"))
        @test all(isapprox.(actual, [6.0, 2.0, 1.0, 3.0]; rtol=1e-4))
    end
end
