# Cross-language conformance for a BUILD-ONCE SPATIAL FIELD materialized once at
# setup and consumed elementwise by an ODE (CONFORMANCE_SPEC.md §5.12). Shared
# fixture + analytic golden live under `tests/conformance/build_once_spatial_field/`.
#
# This exercises the two build-once-spatial gaps fixed in the Julia runner:
#   * Gap 1 — the setup-time materializer handles a NON-aggregate build-once array
#     op: `Field.darea` is a periodic `makearray` STENCIL (the form a
#     discretization rule lowers `D` to; no `output_idx`), materialized per output
#     cell through the same build-time array pipeline the ODE RHS uses.
#   * Gap 2 — the build-once materialized arrays (`Field.area`, `Field.darea`) are
#     registered as gatherable const arrays, so the per-cell ODE `D(u[c]) =
#     darea[c] - u[c]` resolves `index(darea, c)` at every RHS call.
# The forcing is CONST, so `u_c(t) = darea_c (1 - e^-t)` is analytic and exact.
using Test
using EarthSciAST
import OrdinaryDiffEqTsit5: Tsit5
using JSON3
const _ESS_BO = EarthSciAST

@testset "build_once_spatial_field conformance — setup makearray + gather into ODE (§5.12)" begin
    root = joinpath(@__DIR__, "..", "..", "..", "tests", "conformance", "build_once_spatial_field")
    fixture = joinpath(root, "fixtures", "build_once_spatial_ode.esm")
    golden_path = joinpath(root, "golden", "build_once_spatial_ode.json")
    if _require_fixture(fixture) && _require_fixture(golden_path)
        golden = JSON3.read(read(golden_path, String))

        # (a) flatten: area/darea are observeds (materialized/inlined), not ODE
        # state slots — only `Field.u` is a state.
        flat = _ESS_BO.flatten(_ESS_BO.load(fixture))
        obs = Set(String.(keys(flat.observed_variables)))
        @test "Field.area" in obs
        @test "Field.darea" in obs
        @test haskey(flat.state_variables, "Field.u")
        @test !("Field.area" in Set(String.(keys(flat.state_variables))))

        # (b) simulate materializes the build-once fields at setup and integrates.
        insp = _ESS_BO.BuildInspection()
        tspan = (Float64(golden["cadence"]["tspan"][1]), Float64(golden["cadence"]["tspan"][2]))
        traj = golden["trajectory"]
        atimes = sort!(Float64[parse(Float64, String(k)) for k in keys(traj) if String(k) != "comment"])
        r = _ESS_BO.simulate(fixture, tspan; alg = Tsit5(),
                             reltol = 1e-10, abstol = 1e-12, saveat = atimes, inspect = insp)
        @test r.success && r.retcode == :Success

        # (c) setup fields materialized correctly (Gap 1: makearray at setup).
        for (name, want) in golden["setup_fields"]
            got = insp.setup_arrays[String(name)]
            @test vec(Float64.(got)) ≈ Float64.(collect(want)) atol = 1e-9
        end

        # (d) trajectory band (manifest §5.12 tolerances) — Gap 2: darea gathered
        # into the ODE RHS.
        rtol = 1e-4; atol = 1e-6
        for tk in keys(traj)
            String(tk) == "comment" && continue
            t = parse(Float64, String(tk))
            ti = findfirst(x -> isapprox(x, t; atol = 1e-9), r.t)
            @test ti !== nothing
            for cell in ("Field.u[1]", "Field.u[2]", "Field.u[3]")
                @test haskey(r.var_map, cell)
                @test isapprox(r[cell][ti], Float64(traj[tk][cell]); rtol = rtol, atol = atol)
            end
        end
    end
end
