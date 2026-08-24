# Cross-language conformance for a pure-I/O data SOURCE consumed by the owning
# model's OWN equations (esm-spec §8.5; CONFORMANCE_SPEC.md §5.11). Shared
# fixture + analytic golden live under `tests/conformance/subsystem_loader/`.
#
# esm 1.0.0 semantics: a data source is a document-scoped REGISTRY ENTRY, not a
# component — it is never mounted as a subsystem and exposes no variables of its
# own. The model consumes it by declaring PARAMETERS whose `update` names the
# source and binds a `file_variable`, so the flattened names are `<Model>.<param>`
# (`Box.k`, `Box.wind`) rather than the 0.x `<owner>.<subkey>.<var>`
# (`Box.raw.k`, `Box.raw.wind`). The provider seam is keyed by those same names.
#   * `Box.k`    — a BARE-SCALAR source-backed parameter reference.
#   * `Box.wind` — a GATHER `index(wind, 2)`.
# Both bind through the offline CONST provider seam; the forcing is constant
# (F = k + wind[2] = 2 + 5 = 7) so `c(t) = 7 (1 - e^-t)` is analytic and exact.
using Test
using EarthSciAST
import SciMLBase
import SciMLBase: solve, remake
import OrdinaryDiffEqTsit5: Tsit5
using JSON3
const _ESS_SL = EarthSciAST

# Offline CONST stub provider: returns a fixed field array (empty refresh_times ⇒
# CONST ⇒ materialized once at build time into `const_arrays`, no network).
struct _SubsysLoaderStub
    field::Vector{Float64}
end
_ESS_SL.provider_refresh_times(::_SubsysLoaderStub) = Float64[]
_ESS_SL.provider_sample(p::_SubsysLoaderStub, ::Real) = p.field

@testset "subsystem_loader conformance — source-backed CONST parameters, bare-scalar + gather (§5.11)" begin
    root = joinpath(@__DIR__, "..", "..", "..", "tests", "conformance", "subsystem_loader")
    fixture = joinpath(root, "fixtures", "subsystem_loader_ode.esm")
    golden_path = joinpath(root, "golden", "subsystem_loader_ode.json")
    if _require_fixture(fixture) && _require_fixture(golden_path)
        golden = JSON3.read(read(golden_path, String))

        # (a) flatten carries each source-backed consumer through as a
        # namespaced PARAMETER with NO defining equation (its value is injected
        # by the provider seam, not computed). In 0.x these were observed
        # variables synthesized from a mounted loader subsystem; in 1.0.0 the
        # declaration is a parameter on the consuming model and stays one.
        model = _ESS_SL.load_path(fixture)
        flat = _ESS_SL.flatten(model)
        params = Set(String.(keys(flat.parameters)))
        @test "Box.k" in params
        @test "Box.wind" in params
        # …and each is a `data` update naming the registry entry it reads.
        for (pname, fvar) in ("Box.k" => "K", "Box.wind" => "U")
            upd = flat.parameters[pname].update
            @test upd !== nothing && length(upd) == 1
            @test upd[1].kind == "data"
            @test upd[1].source == "raw"
            @test upd[1].from !== nothing && upd[1].from.file_variable == fvar
        end
        # The data source itself is a registry entry, never a subsystem: it
        # contributes no flattened variable of its own under the `raw.` prefix.
        @test !any(n -> startswith(n, "Box.raw."), params)
        @test !any(n -> startswith(n, "Box.raw."), String.(keys(flat.observed_variables)))
        lhs_names = Set{String}()
        for eq in flat.equations
            eq.lhs isa _ESS_SL.VarExpr && push!(lhs_names, (eq.lhs::_ESS_SL.VarExpr).name)
        end
        @test !("Box.k" in lhs_names)        # no synthesized defining equation
        @test !("Box.wind" in lhs_names)

        # (b) the run binds both fields through the offline CONST provider seam,
        # keyed by the flattened PARAMETER name.
        providers = Dict{String,Any}(
            "Box.k"    => _SubsysLoaderStub(Vector{Float64}(golden["loaders"]["Box.k"]["native"])),
            "Box.wind" => _SubsysLoaderStub(Vector{Float64}(golden["loaders"]["Box.wind"]["native"])),
        )
        @test _ESS_SL.provider_is_const(providers["Box.k"])

        tspan = (Float64(golden["cadence"]["tspan"][1]), Float64(golden["cadence"]["tspan"][2]))
        traj = golden["trajectory"]
        atimes = sort!(Float64[parse(Float64, String(k)) for k in keys(traj) if String(k) != "comment"])

        prob = _ESS_SL.esm_problem(fixture, tspan; providers = providers)
        r = solve(prob, Tsit5(); reltol = 1e-9, abstol = 1e-11, saveat = atimes)
        @test SciMLBase.successful_retcode(r)
        @test haskey(prob.var_map, "Box.c")

        rtol = 1e-4   # trajectory band (manifest §5.11 tolerances)
        atol = 1e-6
        for tk in keys(traj)
            String(tk) == "comment" && continue
            t = parse(Float64, String(tk))
            ti = findfirst(x -> isapprox(x, t; atol = 1e-9), r.t)
            @test ti !== nothing
            expected = Float64(traj[tk]["Box.c"])
            @test isapprox(r[Symbol("Box.c")][ti], expected; rtol = rtol, atol = atol)
        end
    end
end
