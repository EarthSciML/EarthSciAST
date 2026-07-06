# Cross-language conformance for a pure-I/O data loader MOUNTED AS A MODEL
# SUBSYSTEM and consumed by the owning model's OWN equations (RFC
# pure-io-data-loaders §4.3; CONFORMANCE_SPEC.md §5.11). Shared fixture + analytic
# golden live under `tests/conformance/subsystem_loader/`.
#
# This exercises the Julia flatten fix (`_collect_model!` no longer SKIPS a
# DataLoader subsystem — it lowers each loader variable to a const-array-backed
# observed `<owner>.<subkey>.<var>`) and the provider seam:
#   * `Box.raw.k`    — a BARE-SCALAR loader reference (`raw.k`), the path that
#     previously threw `E_TREEWALK_UNBOUND_VARIABLE: Box.raw.k`.
#   * `Box.raw.wind` — a GATHER `index(raw.wind, 2)`.
# Both bind through the offline CONST provider seam; the forcing is constant
# (F = k + wind[2] = 2 + 5 = 7) so `c(t) = 7 (1 - e^-t)` is analytic and exact.
using Test
using EarthSciSerialization
import OrdinaryDiffEqTsit5: Tsit5
using JSON3
const _ESS_SL = EarthSciSerialization

# Offline CONST stub provider: returns a fixed field array (empty refresh_times ⇒
# CONST ⇒ materialized once at build time into `const_arrays`, no network).
struct _SubsysLoaderStub
    field::Vector{Float64}
end
_ESS_SL.provider_refresh_times(::_SubsysLoaderStub) = Float64[]
_ESS_SL.provider_sample(p::_SubsysLoaderStub, ::Real) = p.field

@testset "subsystem_loader conformance — mounted CONST loader, bare-scalar + gather (§5.11)" begin
    root = joinpath(@__DIR__, "..", "..", "..", "tests", "conformance", "subsystem_loader")
    fixture = joinpath(root, "fixtures", "subsystem_loader_ode.esm")
    golden_path = joinpath(root, "golden", "subsystem_loader_ode.json")
    if _require_fixture(fixture) && _require_fixture(golden_path)
        golden = JSON3.read(read(golden_path, String))

        # (a) flatten lowers each loader-subsystem variable to a materialized
        # observed with NO defining equation (its value is injected, not computed).
        flat = _ESS_SL.flatten(_ESS_SL.load(fixture))
        obs = Set(String.(keys(flat.observed_variables)))
        @test "Box.raw.k" in obs
        @test "Box.raw.wind" in obs
        lhs_names = Set{String}()
        for eq in flat.equations
            eq.lhs isa _ESS_SL.VarExpr && push!(lhs_names, (eq.lhs::_ESS_SL.VarExpr).name)
        end
        @test !("Box.raw.k" in lhs_names)     # no synthesized defining equation
        @test !("Box.raw.wind" in lhs_names)

        # (b) simulate binds both fields through the offline CONST provider seam.
        providers = Dict{String,Any}(
            "Box.raw.k"    => _SubsysLoaderStub(Vector{Float64}(golden["loaders"]["Box.raw.k"]["native"])),
            "Box.raw.wind" => _SubsysLoaderStub(Vector{Float64}(golden["loaders"]["Box.raw.wind"]["native"])),
        )
        @test _ESS_SL.provider_is_const(providers["Box.raw.k"])

        tspan = (Float64(golden["cadence"]["tspan"][1]), Float64(golden["cadence"]["tspan"][2]))
        traj = golden["trajectory"]
        atimes = sort!(Float64[parse(Float64, String(k)) for k in keys(traj) if String(k) != "comment"])

        r = _ESS_SL.simulate(fixture, tspan; alg = Tsit5(),
                             providers = providers,
                             reltol = 1e-9, abstol = 1e-11, saveat = atimes)
        @test r.success && r.retcode == :Success
        @test haskey(r.var_map, "Box.c")

        rtol = 1e-4   # trajectory band (manifest §5.11 tolerances)
        atol = 1e-6
        for tk in keys(traj)
            String(tk) == "comment" && continue
            t = parse(Float64, String(tk))
            ti = findfirst(x -> isapprox(x, t; atol = 1e-9), r.t)
            @test ti !== nothing
            expected = Float64(traj[tk]["Box.c"])
            @test isapprox(r["Box.c"][ti], expected; rtol = rtol, atol = atol)
        end
    end
end
