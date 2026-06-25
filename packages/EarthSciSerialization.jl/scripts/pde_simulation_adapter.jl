# Julia adapter for the cross-language PDE-simulation conformance tier (ess-fmw).
#
# Reference binding. For every fixture in the manifest it:
#   * evaluates the discretized RHS f(u, t) at each declared probe state via the
#     MTK-free tree-walk evaluator (`build_evaluator` -> `f!(du, u, p, t)`), and
#   * integrates the trajectory from the declared initial conditions with the
#     pinned integrator (Tsit5 + manifest reltol/abstol), sampling at the
#     declared output times.
#
# Output element names are the bare `u[i]` / `u[i,j]` slot names from the
# evaluator's var map (shared with Python/Rust). Emits, to --output:
#   {"binding":"julia","fixtures":{<id>:{"rhs":{<probe>:{name:val}},
#                                        "trajectory":{<tstr>:{name:val}}}}}
#
# Invoked with the dedicated env that carries OrdinaryDiffEqTsit5 + JSON3:
#   julia --project=packages/EarthSciSerialization.jl/scripts/pde_sim_adapter \
#         packages/EarthSciSerialization.jl/scripts/pde_simulation_adapter.jl \
#         --manifest <manifest.json> --output <out.json>

# Self-contained environment bootstrap. The dedicated adapter project
# (scripts/pde_sim_adapter/Project.toml) pins EarthSciSerialization (dev'd from
# ../..) + OrdinaryDiffEqTsit5 + JSON3. Manifest.toml is gitignored repo-wide,
# so on a fresh checkout we re-establish the local dev path then instantiate; on
# warm runs (Manifest already present) this is just a fast resolve check.
import Pkg
let env = joinpath(@__DIR__, "pde_sim_adapter")
    Pkg.activate(env; io=devnull)
    isfile(joinpath(env, "Manifest.toml")) ||
        Pkg.develop(path=normpath(joinpath(@__DIR__, "..")); io=devnull)
    Pkg.instantiate(; io=devnull)
end

using EarthSciSerialization
using JSON3
import OrdinaryDiffEqTsit5
const ODE = OrdinaryDiffEqTsit5

function parse_args(args)
    manifest = nothing
    output = nothing
    i = 1
    while i <= length(args)
        if args[i] == "--manifest"
            manifest = args[i + 1]; i += 2
        elseif args[i] == "--output"
            output = args[i + 1]; i += 2
        else
            i += 1
        end
    end
    manifest === nothing && error("--manifest is required")
    output === nothing && error("--output is required")
    (manifest, output)
end

# Trajectory time key: a plain float string. The Python harness re-normalizes
# every key via float(k):g, so the exact rendering here only has to round-trip.
tkey(t) = string(float(t))

_ic_dict(obj) = Dict{String,Float64}(String(k) => Float64(v) for (k, v) in pairs(obj))

function rhs_at(model, probe_state, t)
    ics = _ic_dict(probe_state)
    f!, u0, p, _, vmap = build_evaluator(model; initial_conditions=ics)
    du = similar(u0)
    f!(du, u0, p, Float64(t))
    Dict{String,Float64}(name => Float64(du[idx]) for (name, idx) in vmap)
end

function trajectory(model, ic, t0, t1, out_times, reltol, abstol)
    ics = _ic_dict(ic)
    f!, u0, p, _, vmap = build_evaluator(model; initial_conditions=ics)
    prob = ODE.ODEProblem(f!, u0, (Float64(t0), Float64(t1)), p)
    sol = ODE.solve(prob, ODE.Tsit5(); reltol=reltol, abstol=abstol)
    out = Dict{String,Any}()
    for t in out_times
        st = sol(Float64(t))
        out[tkey(t)] = Dict{String,Float64}(name => Float64(st[idx])
                                            for (name, idx) in vmap)
    end
    out
end

function main()
    manifest_path, output_path = parse_args(ARGS)
    manifest = JSON3.read(read(manifest_path, String))
    integ = manifest.integrators.julia
    reltol = Float64(integ.reltol)
    abstol = Float64(integ.abstol)
    base = dirname(manifest_path)

    fixtures = Dict{String,Any}()
    for fx in manifest.fixtures
        path = joinpath(base, String(fx.path))
        file = load(path)
        model = file.models[String(fx.model)]

        rhs = Dict{String,Any}()
        for pr in fx.rhs_probes
            rhs[String(pr.id)] = rhs_at(model, pr.state, pr.t)
        end

        tr = fx.trajectory
        ts = tr.time_span
        traj = trajectory(model, tr.initial_conditions,
                          ts[Symbol("start")], ts[Symbol("end")],
                          tr.output_times, reltol, abstol)

        fixtures[String(fx.id)] = Dict("rhs" => rhs, "trajectory" => traj)
    end

    payload = Dict("binding" => "julia", "fixtures" => fixtures)
    open(output_path, "w") do io
        JSON3.write(io, payload)
    end
end

main()
