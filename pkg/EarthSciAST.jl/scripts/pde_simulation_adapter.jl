# Julia adapter for the cross-language PDE-simulation conformance tier.
#
# Reference binding. For every fixture in the manifest it:
#   * evaluates the discretized RHS f(u, t) at each declared probe state via the
#     MTK-free tree-walk evaluator (`Internal.build` -> `f!(du, u, p, t)`), and
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
#         --manifest <manifest.json> --output <out.json> --compiler <value>
#
# `--compiler` is REQUIRED and names which strategy builds the right-hand side
# (API_SPEC §5.8's closed vocabulary), passed straight to `Internal.build` /
# `esm_problem`. The stages pass `native`, because every fixture here builds
# under it.

# The adapter project (scripts/pde_sim_adapter/Project.toml) pins EarthSciAST
# (developed from ../..), OrdinaryDiffEqTsit5 and JSON3.
include(joinpath(@__DIR__, "adapter_support.jl"))
activate_adapter_env(joinpath(@__DIR__, "pde_sim_adapter"))

using EarthSciAST
using JSON3
import OrdinaryDiffEqTsit5
import SciMLBase
const ODE = OrdinaryDiffEqTsit5
const ESS = EarthSciAST

# `--compiler` is REQUIRED: a problem-building stage NAMES the compiler it runs
# (CONFORMANCE_SPEC §5.44.5), so this adapter never inherits the library
# default. Inheriting it would put the stage back in the position the rule
# exists to prevent — a change to that default silently changing what this tier
# measures.

# The value after the flag at `args[i]`; a flag at the end of the line has none.
_flag_value(args, i) =
    i < length(args) ? args[i + 1] : error("$(PROGRAM_FILE): $(args[i]) needs a value")

function parse_args(args)
    manifest = nothing
    output = nothing
    compiler = nothing
    i = 1
    while i <= length(args)
        if args[i] == "--manifest"
            manifest = _flag_value(args, i); i += 2
        elseif args[i] == "--output"
            output = _flag_value(args, i); i += 2
        elseif args[i] == "--compiler"
            compiler = _flag_value(args, i); i += 2
        else
            error("$(PROGRAM_FILE): unrecognised argument $(repr(args[i]))")
        end
    end
    manifest === nothing && error("--manifest is required")
    output === nothing && error("--output is required")
    compiler === nothing && error("--compiler is required")
    check_compiler(compiler, EarthSciAST.COMPILER_VOCABULARY)
    return (manifest, output, compiler)
end

# Trajectory time key: a plain float string. The Python harness re-normalizes
# every key via float(k):g, so the exact rendering here only has to round-trip.
tkey(t) = string(float(t))

# The manifest names a component's states bare; the build names them qualified.
_ic_dict(obj, mname) = Dict{String, Float64}(
    "$mname.$(String(k))" => Float64(v) for (k, v) in pairs(obj)
)

# The component `mname` of a pre-discretized fixture, built on its own.
_build_component(model, mname, ics, compiler) = EarthSciAST.Internal.build(
    model; model_name = mname, initial_conditions = ics, compiler = Symbol(compiler)
)

function rhs_at(model, mname, probe_state, t, compiler)
    f!, u0, p, _, vmap = _build_component(
        model, mname, _ic_dict(probe_state, mname), compiler
    )
    # `zero`, not `similar`: a state with no `D` equation is never written by
    # `f!`, so its slot must start at zero rather than hold whatever memory
    # `similar` returned.
    du = zero(u0)
    f!(du, u0, p, Float64(t))
    return Dict{String, Float64}(bare_name(name) => Float64(du[idx]) for (name, idx) in vmap)
end

function trajectory(model, mname, ic, t0, t1, out_times, reltol, abstol, compiler)
    f!, u0, p, _, vmap = _build_component(model, mname, _ic_dict(ic, mname), compiler)
    prob = ODE.ODEProblem(f!, u0, (Float64(t0), Float64(t1)), p)
    sol = ODE.solve(prob, ODE.Tsit5(); reltol = reltol, abstol = abstol)
    out = Dict{String, Any}()
    for t in out_times
        st = sol(Float64(t))
        out[tkey(t)] = Dict{String, Float64}(
            bare_name(name) => Float64(st[idx])
                for (name, idx) in vmap
        )
    end
    return out
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
# the run extracts each variable's field by name; empty `refresh_times` ⇒
# CONST ⇒ materialized once at build time into `const_arrays` under the loader
# name, reachable by the scoped-`ic` fold (u0) and the loader→consumer gather.
struct _StubLoaderProvider
    fields::Dict{String, Array{Float64}}
end
ESS.provider_refresh_times(::_StubLoaderProvider) = Float64[]
ESS.provider_sample(p::_StubLoaderProvider, ::Real) = p.fields

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
    fields = Dict{String, Array{Float64}}()
    for (k, v) in pairs(inputs)
        fields[String(k)] = _to_field(v)
    end
    stub = _StubLoaderProvider(fields)
    return Dict{String, Any}(k => stub for k in keys(fields))
end

# Build the provider-folded tree-walk evaluator: fold every CONST provider's field
# into `const_arrays` under its loader name, then build the flattened document
# (which folds scoped-`ic` `Loader.*` into u0 and resolves the lifted consumer
# gather from the loader name).
function _pipeline_evaluator(path, providers, t0, compiler)
    merged_const = Dict{String, Any}()
    for (rawk, prov) in providers
        k = String(rawk)
        merged_const[k] = ESS.forcing_from_sample(ESS.provider_sample(prov, t0), k)
    end
    return EarthSciAST.Internal.build(
        path; const_arrays = merged_const, compiler = Symbol(compiler)
    )
end

function pipeline_fixture(fx, base, reltol, abstol, compiler)
    path = joinpath(base, String(fx.path))
    providers = _stub_providers(fx.inputs)
    checkpoints = Float64[Float64(c) for c in fx.trajectory.checkpoints]
    t0 = checkpoints[1]
    t1 = checkpoints[end]

    # --- RHS at each probe via the provider-folded evaluator ------------------
    f!, u0, p, _, var_map = _pipeline_evaluator(path, providers, t0, compiler)
    baremap = Dict{String, Int}()
    for (k, idx) in var_map
        baremap[bare_name(k)] = idx
    end
    rhs = Dict{String, Any}()
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
        rhs[String(pr.id)] = Dict{String, Float64}(
            name => Float64(du[idx])
                for (name, idx) in var_map
        )
    end

    # --- Trajectory via the sanctioned EsmProblem provider path ---------------
    prob = ESS.esm_problem(
        path, (t0, t1); providers = providers,
        compiler = Symbol(compiler)
    )
    r = SciMLBase.solve(
        prob, ODE.Tsit5(); reltol = reltol, abstol = abstol,
        saveat = checkpoints
    )
    SciMLBase.successful_retcode(r) || error("solve failed: retcode $(r.retcode)")
    traj = Dict{String, Any}()
    for tc in checkpoints
        ti = nearest_index(r.t, tc)
        traj[tkey(tc)] = Dict{String, Float64}(
            name => Float64(r.u[ti][idx])
                for (name, idx) in var_map
        )
    end
    return Dict("rhs" => rhs, "trajectory" => traj)
end

# Pre-discretized path (pde_simulation): evaluate the compiled makearray RHS and
# integrate the declared `initial_conditions` over `time_span`.
function discretized_fixture(fx, base, reltol, abstol, compiler)
    path = joinpath(base, String(fx.path))
    file = load_path(path)
    mname = String(fx.model)
    model = file.models[mname]

    rhs = Dict{String, Any}()
    for pr in fx.rhs_probes
        rhs[String(pr.id)] = rhs_at(model, mname, pr.state, pr.t, compiler)
    end

    tr = fx.trajectory
    ts = tr.time_span
    traj = trajectory(
        model, mname, tr.initial_conditions,
        ts[Symbol("start")], ts[Symbol("end")],
        tr.output_times, reltol, abstol, compiler
    )

    return Dict("rhs" => rhs, "trajectory" => traj)
end

function main()
    manifest_path, output_path, compiler = parse_args(ARGS)
    manifest = JSON3.read(read(manifest_path, String))
    integ = manifest.integrators.julia
    reltol = Float64(integ.reltol)
    abstol = Float64(integ.abstol)
    base = dirname(manifest_path)

    fixtures = Dict{String, Any}()
    for fx in manifest.fixtures
        if haskey(fx, :pipeline) && String(fx.pipeline) == "full"
            fixtures[String(fx.id)] = pipeline_fixture(
                fx, base, reltol, abstol,
                compiler
            )
        else
            fixtures[String(fx.id)] = discretized_fixture(
                fx, base, reltol, abstol,
                compiler
            )
        end
    end

    payload = Dict("binding" => "julia", "fixtures" => fixtures)
    return open(output_path, "w") do io
        JSON3.write(io, payload)
    end
end

main()
