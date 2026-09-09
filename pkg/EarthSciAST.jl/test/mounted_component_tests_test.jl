# esm-spec §6.6: a component's inline tests do NOT cross a mount edge.
#
# A leaf's `tests` are assertions about the leaf under the leaf's OWN standalone
# conditions. A document that mounts it by a top-level `models` `{ref}` (§4.7 /
# §9.7.10) may legitimately change those conditions — here a `variable_map` entry
# replaces the leaf's decay rate `k` with a fivefold forcing — so re-running the
# leaf's assertions inside the assembly checks a claim its author never made and
# reports a correct component as broken.
#
# Reported against a real coupled assembly as issue #198 item 2, where a leaf
# that passes standalone contributed 767 ERROR/FAIL rows to the document that
# mounted it. The fixtures are shared with the Python and Rust bindings
# (tests/conformance/mounted_component_tests/), which pin the same rule.

using Test
using EarthSciAST
import SciMLBase
import OrdinaryDiffEqTsit5

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _MCT_DIR = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance",
                          "mounted_component_tests", "fixtures")

# #210 unified this runner's result type with the directory runner's: an
# `AssertionResult` names its component `container_name` — a model OR a reaction
# system, both of which the runner now walks — and carries a three-valued
# `status`, not a `passed` Bool.
_mct_run(name) = run_inline_tests(joinpath(_MCT_DIR, name);
                                  alg=OrdinaryDiffEqTsit5.Tsit5())

@testset "Mounted components' inline tests (esm-spec §6.6)" begin
    @testset "the leaf alone passes its own test" begin
        # k = 1, so u(1) = 1/e. This is what attributes a failure inside the
        # assembly to the mount rather than to the leaf.
        results = _mct_run("leaf.esm")
        @test [r.container_name for r in results] == ["Decay"]
        @test results[1].status == PASS
    end

    @testset "a mounted component's tests do not run in the assembly" begin
        # Before the fix the leaf's assertion ran here too, under k = 5, and
        # failed by two orders of magnitude.
        results = _mct_run("assembly.esm")
        @test [r.container_name for r in results] == ["Forcing"]
        @test results[1].status == PASS
    end

    @testset "the mount does not carry the leaf's tests" begin
        # Dropped at the mount, not skipped by the runner — so every consumer of
        # the assembled document agrees about what it asserts.
        file = load_path(joinpath(_MCT_DIR, "assembly.esm"))
        @test isempty(file.models["Decay"].tests)
        # The mount is otherwise a faithful splice.
        @test haskey(file.models["Decay"].variables, "u")
        @test [t.id for t in file.models["Forcing"].tests] == ["forcing_accumulates_its_rate"]
    end
end
