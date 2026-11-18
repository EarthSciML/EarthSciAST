# Conformance harness adapter — pde_inline_ic_param_override category.
#
# esm-spec §6.6.5 "Build-time evaluation scope": every reference resolved
# BEFORE the simulation runs — a coordinate-expression `ic` (§11.4.1) and an
# inline analytic assertion `reference` — binds the model's parameters to their
# `parameter_overrides`-or-default values, with the overrides keyed by LOCAL
# parameter name (§6.6). The reference binding (Julia) runs the OFFICIAL
# `run_inline_tests` pathway over the committed fixture and must reproduce the
# committed golden actuals (which that same pathway minted). The manifest
# declares julia/python/rust as bindings_required.
#
# Overrides are keyed by LOCAL name (`A`) and must reach the flattening-qualified
# parameter (`M.A`) in every consumer: the coordinate-expression `ic` seed, the
# parameter vector, and the §6.6.5 reference scope. Fixture parameter `A`
# appears ONLY in `ic(u)` and in assertion references, never in an equation,
# so the override can change the answer through the build-time scope and
# nowhere else.
# See tests/conformance/pde_inline_ic_param_override/.

using Test
using JSON3
using EarthSciAST
import SciMLBase
import SciMLBase: solve
import OrdinaryDiffEqTsit5

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _ICPO_CAT_DIR = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance", "pde_inline_ic_param_override")

@testset "Conformance: pde_inline_ic_param_override (manifest-driven)" begin
    # `compiler=:interpreter`: the `ic_param_override` fixture seeds from a
    # coordinate expression, which the seed lowers once per cell — a
    # construction-time tree walk per cell that the strict `native` refuses
    # (API_SPEC §5.8). This tier's subject is §6.6.5 build-time override scope
    # against a committed golden, so it is measured under the reference
    # evaluator, as CONFORMANCE_SPEC §5.44 has every non-compiler conformance
    # stage pin. The category has THREE tests in one model, distinguished only
    # by their `parameter_overrides`, so results match the golden by
    # `(test_id, assertion_idx)`.
    check_inline_golden(
        "pde_inline_ic_param_override", OrdinaryDiffEqTsit5.Tsit5();
        by_test = true, compiler = :interpreter
    )
end

# Direct unit coverage of the key canonicalization the category gates, on the
# TYPED build path: a LOCAL-named override must bind a flattening-qualified
# parameter, and an already-qualified key must keep working.
@testset "parameter_overrides key canonicalization (esm-spec §6.6)" begin
    esm_path = joinpath(_ICPO_CAT_DIR, "fixtures", "ic_param_override.esm")

    for (spelling, key) in (("local", "A"), ("qualified", "M.A"))
        @testset "$(spelling) override key" begin
            insp = EarthSciAST.BuildInspection()
            sim = solve(
                EarthSciAST.esm_problem(
                    esm_path, (0.0, 1.0); inspect = insp,
                    p = Dict(key => 0.0),
                    compiler = :interpreter
                ),
                OrdinaryDiffEqTsit5.Tsit5();
                saveat = [0.0]
            )
            @test SciMLBase.successful_retcode(sim)
            # The build resolved the parameter to the OVERRIDE, not the 1.0
            # default, whichever spelling the caller used.
            @test insp.params["M.A"] == 0.0
            # ...and the coordinate-expression ic seeded from that same scope.
            for i in 1:5
                @test sim[Symbol("M.u[$i]")][1] == 0.0
            end
        end
    end

    # An override naming NO parameter of the model is REJECTED (esm-spec §6.6.2
    # "Unrecognized override keys"): an inert key would leave the run measuring
    # a configuration the author thought they had changed. Rust and Python
    # refuse it too.
    @test_throws SimulateError solve(
        EarthSciAST.esm_problem(
            esm_path, (0.0, 1.0); compiler = :interpreter,
            p = Dict("not_a_param" => 7.0)
        ), OrdinaryDiffEqTsit5.Tsit5(); saveat = [0.0]
    )
end
