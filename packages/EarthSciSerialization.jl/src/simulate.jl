# ===========================================================================
# simulate — the one-call run entry (load → discretize → build_evaluator →
# seed ICs → cadence-refresh → solve), the Julia counterpart of the Python
# `earthsci_toolkit.simulation.simulate`.
#
# It threads the pieces that already exist — `flatten`, `discretize(…; promote)`
# (the Phase-1 monolithic lowering), `build_evaluator`, and the Phase-4
# `build_refresh_callback` data-refresh seam — into a single call returning a
# `SimulationResult`, so a runner is `simulate(esm, tspan; …)` rather than a
# hand-wired build/seed/solve block.
#
# `[[library-exposes-rhs-not-solver]]`: ESS never depends on a solver. The
# orchestration here (coerce → discretize → build_evaluator → seed → callback)
# is solver-free; the final `ODEProblem` + `solve` lives in a SciMLBase package
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
final state with `final(result)`.
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

"The final state vector (empty if the solve produced no points)."
final(r::SimulationResult) = isempty(r.u) ? Float64[] : r.u[end]
nelements(r::SimulationResult) = length(r.var_map)

struct SimulateError <: Exception
    msg::String
end
Base.showerror(io::IO, e::SimulateError) = print(io, "SimulateError: ", e.msg)

# --------------------------------------------------------------------------- #
# Input coercion: path | EsmFile | FlattenedSystem | native Dict → a runnable
# ESM document for build_evaluator. Discretizes only when the caller asks for
# it (rules / grids / promote) — an already-discretized Dict passes through.
# --------------------------------------------------------------------------- #
function _prepare_run_doc(input; rules, grids, promote, spatial_loops,
                          strict_unrewritten, discretize_kwargs)
    if input isa AbstractString
        isfile(input) || throw(SimulateError("simulate: no such file '$input'"))
        input = load(input)
    end
    if input isa EsmFile
        input = flatten(input)
    end
    if input isa FlattenedSystem
        if promote || rules !== nothing || grids !== nothing
            return discretize(input; rules = rules, grids = grids, promote = promote,
                              spatial_loops = spatial_loops,
                              strict_unrewritten = strict_unrewritten,
                              discretize_kwargs...)
        end
        return flattened_to_esm(input)
    end
    if input isa AbstractDict
        # A native ESM doc. Re-discretize only if the caller spliced in rules/grids;
        # the common case (an already-discretized doc, e.g. a regridder-merged
        # level-set) is used verbatim.
        if rules !== nothing || grids !== nothing
            doc = Dict{String,Any}(String(k) => v for (k, v) in input)
            grids === nothing || (doc["grids"] = Dict{String,Any}(String(k) => v for (k, v) in grids))
            rules === nothing || (doc["rules"] = collect(Any, rules))
            return discretize(doc; strict_unrewritten = strict_unrewritten, discretize_kwargs...)
        end
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
        prefix = key * "["
        hit = false
        for (vname, idx) in var_map
            if startswith(vname, prefix)
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
[`FlattenedSystem`](@ref), or an already-discretized native ESM `Dict`. A
spatial PDE is lowered when the caller supplies discretization `rules` / `grids`
or `promote = true` (the Phase-1 monolithic lowering: fold elementwise array
observeds, reclassify algebraic-state physics, promote the scalar chain to the
grid, discretize the `grad` stencils, index the per-cell refs).

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
* `providers::AbstractDict` — `var name => data Provider`; when given, a
  [`build_refresh_callback`](@ref) is attached so DISCRETE forcing refreshes in
  place at its cadence (CONST providers ride `const_arrays`). `regrid` selects
  the [`RegridApplier`](@ref) (default [`IdentityRegrid`](@ref)).
* `rules`, `grids`, `promote`, `spatial_loops`, `strict_unrewritten` — the
  discretization controls (see [`discretize`](@ref)).
* `reltol`, `abstol`, `saveat` — forwarded to the solver.
* `model_name` — select one model when the document holds several.

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
                  rules = nothing,
                  grids = nothing,
                  promote::Bool = false,
                  spatial_loops::Vector{String} = ["i", "j"],
                  strict_unrewritten::Bool = true,
                  model_name::Union{Nothing,AbstractString} = nothing,
                  reltol::Float64 = 1e-4,
                  abstol::Float64 = 1e-6,
                  saveat = nothing,
                  discretize_kwargs = NamedTuple())
    doc = _prepare_run_doc(input; rules = rules, grids = grids, promote = promote,
                           spatial_loops = spatial_loops,
                           strict_unrewritten = strict_unrewritten,
                           discretize_kwargs = discretize_kwargs)

    overrides = Dict{String,Float64}(String(k) => Float64(v) for (k, v) in parameters)
    f!, u0, p, _tspan, var_map = build_evaluator(doc;
        model_name = model_name,
        parameter_overrides = overrides,
        const_arrays = Dict{String,Any}(String(k) => v for (k, v) in const_arrays),
        param_arrays = Dict{String,Any}(String(k) => v for (k, v) in param_arrays))

    isempty(initial_conditions) || _apply_initial_conditions!(u0, var_map, initial_conditions)
    seed_ic! === nothing || seed_ic!(u0, var_map)

    cb = nothing
    tstops = Float64[]
    if providers !== nothing && !isempty(providers)
        file = coerce_esm_file(JSON3.read(JSON3.write(doc)))
        model = _select_model(file, model_name)
        cb, tstops = build_refresh_callback(model;
            providers = Dict{String,Any}(String(k) => v for (k, v) in providers),
            buffers = RefreshBuffers(Dict{String,Any}(String(k) => v for (k, v) in param_arrays)),
            regrid = regrid)
    end

    return _simulate_solve(f!, u0, (Float64(tspan[1]), Float64(tspan[2])), p, alg, var_map;
                           callback = cb, tstops = tstops,
                           reltol = reltol, abstol = abstol, saveat = saveat)
end
