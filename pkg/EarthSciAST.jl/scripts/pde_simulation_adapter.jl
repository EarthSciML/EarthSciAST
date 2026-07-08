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
#   julia --project=pkg/EarthSciAST.jl/scripts/pde_sim_adapter \
#         pkg/EarthSciAST.jl/scripts/pde_simulation_adapter.jl \
#         --manifest <manifest.json> --output <out.json>

# Self-contained environment bootstrap. The dedicated adapter project
# (scripts/pde_sim_adapter/Project.toml) pins EarthSciAST (dev'd from
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

using EarthSciAST
using JSON3
import OrdinaryDiffEqTsit5
const ODE = OrdinaryDiffEqTsit5
const ESS = EarthSciAST

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

# ---------------------------------------------------------------------------- #
# Full-pipeline path (pde_simulation_pipeline; DESIGN §7). A fixture tagged
# `pipeline:"full"` is NOT pre-discretized: it must run the whole lowering
# pipeline (reaction-gen → template `match` → `operator_compose` → pointwise-lift
# → scoped-`ic`) with every loaded field injected through the data-Provider seam
# from the manifest `inputs`. This reuses the exact machinery the Phase-1 gate
# test (`test/loaded_ic_bc_simulation_test.jl`) exercises.
# ---------------------------------------------------------------------------- #

# Static CONST stub Provider (DESIGN §2), identical protocol to the gate test:
# `provider_sample` returns the whole `<Loader>.<var> => field` table and
# `simulate` extracts each variable's field by name; empty `refresh_times` ⇒
# CONST ⇒ materialized once at build time into `const_arrays` under the loader
# name, reachable by the scoped-`ic` fold (u0) and the loader→consumer gather.
struct _StubLoaderProvider
    fields::Dict{String,Array{Float64}}
end
ESS.provider_refresh_times(::_StubLoaderProvider) = Float64[]
ESS.provider_sample(p::_StubLoaderProvider, ::Real) = p.fields

# Strip a leading `Model.` namespace so an element name compares against the
# manifest `state_order` (`Chemistry.O3[1,1]` → `O3[1,1]`).
_bare(name::AbstractString) = occursin('.', name) ? split(name, '.'; limit = 2)[2] : name

# Convert a manifest `inputs` value (nested JSON arrays, row=lon/col=lat) into a
# dense Julia array: a `[[..],[..]]` grid → an (nlon×nlat) Matrix; a `[..]` line
# → a Vector.
function _to_field(v)
    if length(v) > 0 && (v[1] isa AbstractArray)
        nrow = length(v)
        ncol = length(v[1])
        M = Array{Float64}(undef, nrow, ncol)
        for i in 1:nrow, j in 1:ncol
            M[i, j] = Float64(v[i][j])
        end
        return M
    end
    return Float64[Float64(x) for x in v]
end

# One shared stub backs every declared loader variable; `providers` maps each
# `<Loader>.<var>` name to it (mirrors the gate test's `_loaded_providers`).
function _stub_providers(inputs)
    fields = Dict{String,Array{Float64}}()
    for (k, v) in pairs(inputs)
        fields[String(k)] = _to_field(v)
    end
    stub = _StubLoaderProvider(fields)
    return Dict{String,Any}(k => stub for k in keys(fields))
end

# Index of the saved time point closest to `t` (endpoints are `saveat`-pinned).
function _time_index(times, t)
    best = firstindex(times)
    bestd = abs(times[best] - t)
    for i in eachindex(times)
        d = abs(times[i] - t)
        if d < bestd
            bestd = d
            best = i
        end
    end
    best
end

# Build the provider-folded tree-walk evaluator exactly as `simulate` does: fold
# every CONST provider's field into `const_arrays` under its loader name, then
# `build_evaluator` (which folds scoped-`ic` `Loader.*` into u0 and resolves the
# lifted consumer gather from the loader name).
function _pipeline_evaluator(path, providers, t0)
    doc = ESS._prepare_run_doc(path)
    merged_const = Dict{String,Any}()
    for (rawk, prov) in providers
        k = String(rawk)
        merged_const[k] = ESS._provider_const_field(ESS.provider_sample(prov, t0), k)
    end
    return build_evaluator(doc; const_arrays = merged_const)
end

function pipeline_fixture(fx, base, reltol, abstol)
    path = joinpath(base, String(fx.path))
    providers = _stub_providers(fx.inputs)
    checkpoints = Float64[Float64(c) for c in fx.trajectory.checkpoints]
    t0 = checkpoints[1]
    t1 = checkpoints[end]

    # --- RHS at each probe via the provider-folded evaluator ------------------
    f!, u0, p, _, var_map = _pipeline_evaluator(path, providers, t0)
    baremap = Dict{String,Int}()
    for (k, idx) in var_map
        baremap[_bare(k)] = idx
    end
    rhs = Dict{String,Any}()
    for pr in fx.rhs_probes
        u = copy(u0)
        for (rawn, val) in pairs(pr.state)
            name = String(rawn)
            idx = get(baremap, name, get(var_map, name, nothing))
            idx === nothing && error("probe state var $name not in evaluator var_map")
            u[idx] = Float64(val)
        end
        # Zero-initialize du: state slots that carry no explicit `D`-equation
        # (e.g. ic-only fields like wind_u/phi/u_ocean) are never written by `f!`,
        # so `similar` would leave uninitialized garbage in their RHS entries. The
        # sanctioned integrator zero-inits du before each `f!`; mirror that here so
        # the probe reports a deterministic 0 for those slots. (No effect on
        # fixtures whose every state has a `D`-equation.)
        du = zero(u)
        f!(du, u, p, Float64(pr.t))
        rhs[String(pr.id)] = Dict{String,Float64}(name => Float64(du[idx])
                                                   for (name, idx) in var_map)
    end

    # --- Trajectory via the sanctioned `simulate` provider path ---------------
    r = ESS.simulate(path, (t0, t1); alg = ODE.Tsit5(),
                     providers = providers, reltol = reltol, abstol = abstol,
                     saveat = checkpoints)
    r.success || error("simulate failed: $(r.message)")
    traj = Dict{String,Any}()
    for tc in checkpoints
        ti = _time_index(r.t, tc)
        traj[tkey(tc)] = Dict{String,Float64}(name => Float64(r.u[ti][idx])
                                              for (name, idx) in var_map)
    end
    return Dict("rhs" => rhs, "trajectory" => traj)
end

# Pre-discretized path (pde_simulation): evaluate the compiled makearray RHS and
# integrate the declared `initial_conditions` over `time_span`.
function discretized_fixture(fx, base, reltol, abstol)
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

    return Dict("rhs" => rhs, "trajectory" => traj)
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
        if haskey(fx, :pipeline) && String(fx.pipeline) == "full"
            fixtures[String(fx.id)] = pipeline_fixture(fx, base, reltol, abstol)
        else
            fixtures[String(fx.id)] = discretized_fixture(fx, base, reltol, abstol)
        end
    end

    payload = Dict("binding" => "julia", "fixtures" => fixtures)
    open(output_path, "w") do io
        JSON3.write(io, payload)
    end
end

main()
