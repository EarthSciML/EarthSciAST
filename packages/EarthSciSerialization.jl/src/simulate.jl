# ===========================================================================
# simulate — the one-call run entry (load → build_evaluator → seed ICs →
# cadence-refresh → solve), the Julia counterpart of the Python
# `earthsci_toolkit.simulation.simulate`.
#
# It threads the pieces that already exist — `flatten`, `build_evaluator`, and
# the Phase-4 `build_refresh_callback` data-refresh seam — into a single call
# returning a `SimulationResult`, so a runner is `simulate(esm, tspan; …)`
# rather than a hand-wired build/seed/solve block.
#
# `[[library-exposes-rhs-not-solver]]`: ESS never depends on a solver. The
# orchestration here (coerce → build_evaluator → seed → callback) is
# solver-free; the final `ODEProblem` + `solve` lives in a SciMLBase package
# EXTENSION (EarthSciSerializationSimulateExt) and is reached through the
# `_simulate_solve` generic — exactly the `build_refresh_callback` pattern. The
# caller picks the algorithm and passes it as `alg = Tsit5()`; without the
# extension loaded (no SciMLBase), the core fallback throws a helpful error.
# ===========================================================================

"""
    SimulationResult

The outcome of a [`simulate`](@ref) run.

* `t::Vector{Float64}` — the saved time points.
* `u::Vector{Vector{Float64}}` — the flat state vector at each `t`.
* `var_map::Dict{String,Int}` — state-element name → flat index (e.g.
  `"LevelSetFireSpread.psi[3,4]" => 57`), the same map `build_evaluator` returns.
* `success::Bool` — `true` iff the solver reported `ReturnCode.Success`.
* `retcode::Symbol` — the solver return code.
* `message::String` — a human-readable status line.

Index a single state element's trajectory with `result["name"]`, and read the
final state with `final_state(result)`.
"""
struct SimulationResult
    t::Vector{Float64}
    u::Vector{Vector{Float64}}
    var_map::Dict{String,Int}
    success::Bool
    retcode::Symbol
    message::String
end

"Trajectory of one state element by name (`result[\"u[1,2]\"]`)."
function Base.getindex(r::SimulationResult, name::AbstractString)
    i = get(r.var_map, String(name), nothing)
    i === nothing && throw(KeyError(name))
    return Float64[u[i] for u in r.u]
end

"""
    final_state(r::SimulationResult) -> Vector{Float64}

The final state vector (empty if the solve produced no points).
"""
final_state(r::SimulationResult) = isempty(r.u) ? Float64[] : r.u[end]

"""
    nelements(r::SimulationResult) -> Int

Number of flat state elements in the result (`length(r.var_map)`).
"""
nelements(r::SimulationResult) = length(r.var_map)

struct SimulateError <: Exception
    msg::String
end
Base.showerror(io::IO, e::SimulateError) = print(io, "SimulateError: ", e.msg)

# --------------------------------------------------------------------------- #
# Default solver tolerances for `simulate`. Shared with the SciMLBase solve
# extension (ext/EarthSciSerializationSimulateExt.jl), which references these
# consts instead of duplicating the literals.
# --------------------------------------------------------------------------- #
const DEFAULT_SIM_RELTOL = 1e-4
const DEFAULT_SIM_ABSTOL = 1e-6

# --------------------------------------------------------------------------- #
# Input coercion: path | EsmFile | FlattenedSystem | native Dict → a runnable
# ESM document for build_evaluator. A FlattenedSystem is lowered to a native
# ESM Dict; a native Dict (e.g. a regridder-merged level-set) passes through.
# --------------------------------------------------------------------------- #
function _prepare_run_doc(input)
    if input isa AbstractString
        isfile(input) || throw(SimulateError("simulate: no such file '$input'"))
        input = load(input)
    end
    if input isa EsmFile
        input = flatten(input)
    end
    if input isa FlattenedSystem
        # Lift a feed-forward algebraic physics chain authored as scalars into the
        # grid shape it inherits from the fields it reads (regrid outputs, loader
        # fields, the spatial state), so a scalar observed that consumes a build-once
        # spatial field (`tan_phi = sqrt(dzdx² + dzdy²)` over the regridded terrain)
        # becomes a per-cell array whose operand references lower to gathers
        # (`index(TerrainRegrid.dzdx, i, j)`) the evaluator resolves against the
        # const-array registry. Both transforms are no-ops (return an equivalent
        # system) for a document with no algebraic states / no scalar-downstream-of-
        # array observeds, so an already-array (discretized) or purely-scalar (0-D)
        # run is byte-identical.
        input = promote_downstream_shapes(algebraic_states_to_observeds(input))
        return flattened_to_esm(input)
    end
    if input isa AbstractDict
        return input
    end
    throw(SimulateError("simulate: unsupported input of type $(typeof(input)); " *
                        "pass a path, EsmFile, FlattenedSystem, or native ESM Dict"))
end

# --------------------------------------------------------------------------- #
# Initial-condition seeding (mirrors the Python `_apply_initial_conditions`):
# a key may be a scalar name, an explicit element `name[i,j]`, or a bare array
# name that broadcasts a single value over every element of that array.
# --------------------------------------------------------------------------- #
function _apply_initial_conditions!(u0::Vector{Float64}, var_map::AbstractDict,
                                    ics::AbstractDict)
    for (rawkey, value) in ics
        key = String(rawkey)
        if haskey(var_map, key)
            u0[var_map[key]] = Float64(value)
            continue
        end
        # Broadcast: `name` names an array → set every `name[...]` element.
        # `_parse_cell_key` (tree_walk.jl) is the single inverse of
        # `_cell_key`'s "name[i,j]" element encoding.
        hit = false
        for (vname, idx) in var_map
            parsed = _parse_cell_key(String(vname))
            if parsed !== nothing && parsed[1] == key
                u0[idx] = Float64(value)
                hit = true
            end
        end
        hit || throw(SimulateError("simulate: initial_conditions names unknown " *
                                   "state element '$key'"))
    end
    return u0
end

"""
    seed_expression_ic!(u0, var_map, var_name, expr, coords) -> u0

Seed an array state's initial field from an expression evaluated over a grid —
the generic form of a domain-level `expression` initial condition (the Python
`_seed_expression_initial_conditions`). `coords` is an ordered collection of
`dim_name => coordinate_vector` pairs (one per array axis, in index order);
`expr` is evaluated at each grid node with the dimension names bound to the
node's coordinates and written into `u0` at `var_map["var_name[i,j,…]"]`.

Used to seed the level-set's signed-distance `psi` from the domain's declared
IC over the real (projected) fire grid — no per-cell loop in the runner.
"""
function seed_expression_ic!(u0::Vector{Float64}, var_map::AbstractDict,
                             var_name::AbstractString, expr::Expr, coords)
    pairs_ = collect(coords)
    dims = String[String(first(p)) for p in pairs_]
    axes_ = [collect(Float64, last(p)) for p in pairs_]
    sizes = Tuple(length.(axes_))
    for I in CartesianIndices(sizes)
        t = Tuple(I)
        key = string(var_name, "[", join(t, ","), "]")
        k = get(var_map, key, nothing)
        k === nothing && continue
        binding = Dict{String,Any}(dims[d] => axes_[d][t[d]] for d in eachindex(dims))
        u0[k] = evaluate_expr(expr, binding)
    end
    return u0
end

# --------------------------------------------------------------------------- #
# CONST-provider materialization: pull one forcing variable's field out of a
# `provider_sample` result and coerce to a dense Float64 array, preserving the
# native (e.g. [lon,lat]) shape so a scoped-`ic` fold reads it per cell and the
# array-gather indexes it. Reuses the same sample-extraction seam as the refresh
# callback's `IdentityRegrid` (`_regrid_field`: AbstractDict var=>field, or a
# bare AbstractArray for a single-variable sample).
# --------------------------------------------------------------------------- #
_provider_const_field(sample, var::AbstractString) =
    Array{Float64}(_regrid_field(sample, String(var)))

# --------------------------------------------------------------------------- #
# Solve seam — the method lives in EarthSciSerializationSimulateExt (SciMLBase).
# The core fallback (untyped `alg`) fires only when no solver extension is
# loaded, or `alg` is omitted.
# --------------------------------------------------------------------------- #
function _simulate_solve end
_simulate_solve(f!, u0, tspan, p, alg, var_map; kwargs...) = throw(SimulateError(
    alg === nothing ?
    "simulate needs an ODE algorithm: pass `alg = Tsit5()` (and `using OrdinaryDiffEqTsit5`)" :
    "simulate needs the SciMLBase solver extension; add `using SciMLBase` plus a solver " *
    "(e.g. OrdinaryDiffEqTsit5) so EarthSciSerializationSimulateExt is active"))

"""
    simulate(input, tspan; alg, kwargs...) -> SimulationResult

Run an ESM model end to end: coerce `input` to a runnable document, build the
tree-walk evaluator, seed initial conditions, wire any discrete-cadence data
providers, and integrate over `tspan = (t0, t1)`.

`input` may be a path to an `.esm` file, a loaded [`EsmFile`](@ref), a
[`FlattenedSystem`](@ref), or a native ESM `Dict`.

Keyword arguments
* `alg` — the ODE algorithm, e.g. `Tsit5()`. REQUIRED (the solve runs in the
  SciMLBase extension; ESS itself carries no solver, `[[library-exposes-rhs-not-solver]]`).
* `parameters::AbstractDict` — parameter overrides (→ `build_evaluator`'s
  `parameter_overrides`).
* `initial_conditions::AbstractDict` — per-element or broadcast IC overrides,
  applied first.
* `seed_ic!` — optional `(u0, var_map) -> nothing` for array ICs that need grid
  geometry (e.g. a signed-distance `psi`); runs after `initial_conditions`. See
  [`seed_expression_ic!`](@ref).
* `const_arrays`, `param_arrays` — forwarded to `build_evaluator` (the regridder
  source polygons and the live forcing buffers).
* `providers::AbstractDict` — `<Loader>.<var> => data Provider`, the loaded-data
  injection seam. CONST providers ([`provider_is_const`](@ref)) are materialized
  once at build time into `const_arrays` under their loader variable name — so a
  scoped-reference `ic(Sys.sp) ~ Loader.var` folds the seeded field into u0 and a
  loader→consumer `variable_map` binding resolves the consumer gather from it.
  DISCRETE providers get a [`build_refresh_callback`](@ref) so their forcing
  refreshes in place at its cadence; `regrid` selects the
  [`RegridApplier`](@ref) (default [`IdentityRegrid`](@ref)).
* `reltol`, `abstol`, `saveat` — forwarded to the solver.
* `model_name` — select one model when the document holds several.
* `inspect::BuildInspection` — optional build-observability sink forwarded to
  `build_evaluator` (the materialized setup-time geometry arrays, the
  const-array registry, the resolved observed map). Never changes the run.

Returns a [`SimulationResult`](@ref).
"""
function simulate(input, tspan;
                  alg = nothing,
                  parameters::AbstractDict = Dict{String,Float64}(),
                  initial_conditions::AbstractDict = Dict{String,Float64}(),
                  seed_ic! = nothing,
                  const_arrays::AbstractDict = Dict{String,Any}(),
                  param_arrays::AbstractDict = Dict{String,Any}(),
                  providers::Union{Nothing,AbstractDict} = nothing,
                  regrid::RegridApplier = IdentityRegrid(),
                  model_name::Union{Nothing,AbstractString} = nothing,
                  reltol::Float64 = DEFAULT_SIM_RELTOL,
                  abstol::Float64 = DEFAULT_SIM_ABSTOL,
                  saveat = nothing,
                  inspect::Union{Nothing,BuildInspection} = nothing)
    doc = _prepare_run_doc(input)

    overrides = Dict{String,Float64}(String(k) => Float64(v) for (k, v) in parameters)

    # Provider injection (DESIGN pde_simulation_pipeline §2). Loaded fields enter
    # through the Provider seam, never as raw `const_arrays` keyed by internal
    # consumer names. CONST providers (empty `provider_refresh_times`) are
    # materialized ONCE at build time into `const_arrays` keyed by their declared
    # loader variable name — reachable when scoped-`ic` folds `Loader.*` into u0
    # (R2) and when the loader→consumer `variable_map` binding routes a consumer
    # gather to the loader name. DISCRETE providers ride the refresh callback.
    merged_const = Dict{String,Any}(String(k) => v for (k, v) in const_arrays)
    discrete_providers = Dict{String,Any}()
    if providers !== nothing
        t0 = Float64(tspan[1])
        for (rawk, prov) in providers
            k = String(rawk)
            if provider_is_const(prov)
                merged_const[k] = _provider_const_field(provider_sample(prov, t0), k)
            else
                discrete_providers[k] = prov
            end
        end
    end

    f!, u0, p, _tspan, var_map = build_evaluator(doc;
        model_name = model_name,
        parameter_overrides = overrides,
        const_arrays = merged_const,
        param_arrays = Dict{String,Any}(String(k) => v for (k, v) in param_arrays),
        inspect = inspect)

    isempty(initial_conditions) || _apply_initial_conditions!(u0, var_map, initial_conditions)
    seed_ic! === nothing || seed_ic!(u0, var_map)

    cb = nothing
    tstops = Float64[]
    if !isempty(discrete_providers)
        file = coerce_esm_file(doc)
        model = _select_model(file, model_name)
        cb, tstops = build_refresh_callback(model;
            providers = discrete_providers,
            buffers = RefreshBuffers(Dict{String,Any}(String(k) => v for (k, v) in param_arrays)),
            regrid = regrid)
    end

    return _simulate_solve(f!, u0, (Float64(tspan[1]), Float64(tspan[2])), p, alg, var_map;
                           callback = cb, tstops = tstops,
                           reltol = reltol, abstol = abstol, saveat = saveat)
end
