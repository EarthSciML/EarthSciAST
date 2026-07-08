# Cross-binding conformance for the `expression` initial-condition type
# (bead ess-gjn, epic campfire-e2e ea-6sh).
#
# The shared golden under tests/valid/initial_conditions/ declares a domain-level
# `expression` initial condition: u's initial field is the existing expression
# AST psi(x) = 0.5 * (1 + tanh((x - 0.3) / 0.15)) evaluated over the spatial grid
# at t=0 (no new primitive). Python evaluates this end-to-end; Julia loads it as
# the shared contract — expression-IC evaluation in Julia is deferred per ess-gjn
# (Python-first scope). This test pins that Julia parses the golden, that the
# domain exposes the spatial grid, and that the initial condition carries the
# Expression AST, so the fixture is the lever the Julia evaluator builds against.

using Test
using EarthSciAST
using JSON3
const ESS = EarthSciAST

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _EXPRIC_REPO_ROOT = TESTUTILS_REPO_ROOT

@testset "expression initial-condition golden loads (ess-gjn)" begin
    path = joinpath(_EXPRIC_REPO_ROOT, "tests", "valid", "initial_conditions",
                    "expression_ignition_front_1d.esm")
    @test isfile(path)

    # Julia parses the golden into an EsmFile (round-trip / evaluation deferred).
    file = ESS.load(path)
    @test file isa ESS.EsmFile
    @test file.esm == "0.6.0"

    # esm-spec v0.8.0 removed the domain-level `initial_conditions` block; the
    # expression IC is now carried by an `ic(u)` equation whose RHS is the
    # Expression AST psi(x) = 0.5 * (1 + tanh((x - 0.3)/0.15)) in the spatial
    # coordinate `x`. The state field is method-of-lines discretized over the
    # 1-D grid via `shape: [i]`.
    raw = JSON3.read(read(path, String), Dict)
    model = raw["models"]["IgnitionFront1D"]
    @test model["variables"]["u"]["shape"] == ["i"]

    ic_eq = first(e for e in model["equations"]
                  if e["lhs"] isa AbstractDict && get(e["lhs"], "op", nothing) == "ic")
    @test ic_eq["lhs"]["args"] == ["u"]
    @test ic_eq["rhs"]["op"] == "*"  # psi(x) = 0.5 * (1 + tanh(...))
end
