# ===========================================================================
# simulate — the one-call run entry (load → build_evaluator → seed ICs →
# cadence-refresh → solve), the Julia counterpart of the Python
# `earthsci_ast.simulation.simulate`.
#
# It threads the pieces that already exist — `flatten`, `build_evaluator`, and
# the Phase-4 `build_refresh_callback` data-refresh seam — into a single call
# returning a `SimulationResult`, so a runner is `simulate(esm, tspan; …)`
# rather than a hand-wired build/seed/solve block.
#
# `[[library-exposes-rhs-not-solver]]`: EarthSciAST never depends on a solver. The
# orchestration here (coerce → build_evaluator → seed → callback) is
# solver-free; the final `ODEProblem` + `solve` lives in a SciMLBase package
# EXTENSION (EarthSciASTSimulateExt) and is reached through the
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

struct SimulateError <: Exception
    msg::String
end
Base.showerror(io::IO, e::SimulateError) = print(io, "SimulateError: ", e.msg)

# --------------------------------------------------------------------------- #
# Default solver tolerances for `simulate`. Shared with the SciMLBase solve
# extension (ext/EarthSciASTSimulateExt.jl), which references these
# consts instead of duplicating the literals.
# --------------------------------------------------------------------------- #
const DEFAULT_SIM_RELTOL = 1e-4
const DEFAULT_SIM_ABSTOL = 1e-6

# --------------------------------------------------------------------------- #
# Input coercion: path | native Dict | EsmFile | FlattenedSystem → a runnable
# ESM document for build_evaluator.
#
# EVERY carrier of an AUTHORED document (a path, or the same document as a
# Dict) is parsed and FLATTENED; only a `FlattenedSystem` — the type that says
# "already flattened" — skips the flattener, and it is lowered to the native
# single-model run document `build_evaluator` actually consumes.
#
# A Dict must NOT be handed to `build_evaluator` directly. `build_evaluator`
# runs ONE model (`_select_model`) and never reads `reaction_systems` or
# `coupling` — those are lowered/applied BY `flatten`. So passing an authored
# Dict through silently ran a single model with the reaction network and every
# coupling edge dropped, reporting `success = true` on a system the caller
# never wrote (an authored `{reaction_systems, models: {Sink}}` document ran as
# the bare `Sink`, with an empty state vector). Routing it through `load`
# instead gives a Dict the schema validation, version gates and `{ref}`
# resolution a path input has always had — the last of these mattering because
# `flatten` SKIPS an unresolved `SubsystemRef` (`_collect_model!`), so merely
# coercing would swap one silent drop for another.
#
# Consequence: state names from a Dict are now the flattener's namespaced names
# (`"M.y"`, not `"y"`) — i.e. exactly what the identical document in a file has
# always produced. `base_path = pwd()` anchors its relative refs, a file input
# anchoring them at its own directory.
# --------------------------------------------------------------------------- #
function _prepare_run_doc(input)
    if input isa AbstractString
        isfile(input) || throw(SimulateError("simulate: no such file '$input'"))
        input = load(input)
    end
    if input isa AbstractDict
        input = load(input; base_path=pwd())
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
                             var_name::AbstractString, expr::ASTExpr, coords)
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
# callback's forcing write (`_sample_field`: AbstractDict var=>field, or a
# bare AbstractArray for a single-variable sample).
# --------------------------------------------------------------------------- #
_provider_const_field(sample, var::AbstractString) =
    Array{Float64}(_sample_field(sample, String(var)))

# --------------------------------------------------------------------------- #
# Solve seam — the method lives in EarthSciASTSimulateExt (SciMLBase).
# The core fallback (untyped `alg`) fires only when no solver extension is
# loaded, or `alg` is omitted.
# --------------------------------------------------------------------------- #
function _simulate_solve end
_simulate_solve(f!, u0, tspan, p, alg, var_map; kwargs...) = throw(SimulateError(
    alg === nothing ?
    "simulate needs an ODE algorithm: pass `alg = Tsit5()` (and `using OrdinaryDiffEqTsit5`)" :
    "simulate needs the SciMLBase solver extension; add `using SciMLBase` plus a solver " *
    "(e.g. OrdinaryDiffEqTsit5) so EarthSciASTSimulateExt is active"))

"""
    simulate(input, tspan; alg, kwargs...) -> SimulationResult

Run an ESM model end to end: coerce `input` to a runnable document, build the
tree-walk evaluator, seed initial conditions, wire any discrete-cadence data
providers, and integrate over `tspan = (t0, t1)`.

`input` may be a path to an `.esm` file, a native ESM `Dict` (the same document
held in memory), a loaded [`EsmFile`](@ref), or a [`FlattenedSystem`](@ref).

The first three are AUTHORED documents and are flattened before they run, so
`simulate(doc)` and `simulate(path_to_that_doc)` produce the same system —
including the flattener's namespaced state names (`"Chem.A"`, not `"A"`), which
is what `parameters`, `initial_conditions` and `result["…"]` are keyed by. Only
a `FlattenedSystem` skips the flattener, that being the type whose whole meaning
is "already flattened".

Keyword arguments
* `alg` — the ODE algorithm, e.g. `Tsit5()`. REQUIRED (the solve runs in the
  SciMLBase extension; EarthSciAST itself carries no solver, `[[library-exposes-rhs-not-solver]]`).
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
  refreshes in place at its cadence. The provider delivers the native forcing on
  the buffer's grid; any native→sim regrid is an in-model coupling expression
  the RHS evaluates (the obsolete `RegridApplier` seam was removed in v0.8.0).
* `reltol`, `abstol`, `saveat` — forwarded to the solver.
* `model_name` — select one model when the document holds several.
* `inspect::BuildInspection` — optional build-observability sink forwarded to
  `build_evaluator` (the materialized setup-time geometry arrays, the
  const-array registry, the resolved observed map). Never changes the run.
* `materialize_out::DiscreteMaterializer` — optional sink for the
  discrete-cadence materialization cut (the middle phase of the `const ⊏
  discrete ⊏ continuous` cadence partition; see
  [`DiscreteMaterializer`](@ref)). `simulate` always runs the cut, passing the
  supplied sink (reused, and thus inspectable by the caller) or a fresh
  internal one to `build_evaluator`; its `materialize!` is wired as the
  refresh callback's `post_refresh` hook so state-free derived fields over
  live forcing buffers recompute once per cadence boundary instead of on
  every step. With no discrete-materialize variables the sink stays empty and
  has no effect.

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
                  model_name::Union{Nothing,AbstractString} = nothing,
                  reltol::Float64 = DEFAULT_SIM_RELTOL,
                  abstol::Float64 = DEFAULT_SIM_ABSTOL,
                  saveat = nothing,
                  inspect::Union{Nothing,BuildInspection} = nothing,
                  materialize_out::Union{Nothing,DiscreteMaterializer} = nothing)
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
    merged_param = Dict{String,Any}(String(k) => v for (k, v) in param_arrays)
    discrete_providers = Dict{String,Any}()
    if providers !== nothing
        t0 = Float64(tspan[1])
        for (rawk, prov) in providers
            k = String(rawk)
            if provider_is_const(prov)
                merged_const[k] = _provider_const_field(provider_sample(prov, t0), k)
            else
                # DISCRETE: allocate a LIVE forcing buffer seeded at the initial tick
                # and register it in `param_arrays`. That makes the loader field a
                # `live_param`, so the setup partition (`_geometry_setup_vars`) taints
                # any in-model regrid over it: `F_tgt = A_ij ⊗ F_src / A_j` keeps its
                # overlap WEIGHTS at setup but stays a runtime observed / discrete-
                # materialized cache, instead of a build-once setup const where the
                # (still-unbound) live `F_src` would fail. The refresh callback then
                # rewrites this SAME buffer in place at each cadence tick.
                merged_param[k] = _provider_const_field(provider_sample(prov, t0), k)
                discrete_providers[k] = prov
            end
        end
    end

    # Discrete-cadence materialization sink (the middle cadence phase): opt IN so a
    # state-free derived field over a live forcing buffer (a regrid→physics stack) is
    # cut out of the per-step RHS into a cache filled once per refresh, not recomputed
    # on every continuous step. Empty (no discrete-materialize var) ⇒ no effect. A
    # caller-supplied `materialize_out` is reused (and thus inspectable), else fresh.
    dm = materialize_out === nothing ? DiscreteMaterializer() : materialize_out
    f!, u0, p, _tspan, var_map = build_evaluator(doc;
        model_name = model_name,
        parameter_overrides = overrides,
        const_arrays = merged_const,
        param_arrays = merged_param,
        inspect = inspect,
        materialize_out = dm)

    isempty(initial_conditions) || _apply_initial_conditions!(u0, var_map, initial_conditions)
    seed_ic! === nothing || seed_ic!(u0, var_map)

    cb = nothing
    tstops = Float64[]
    if !isempty(discrete_providers)
        file = coerce_esm_file(doc)
        model = _select_model(file, model_name)
        cb, tstops = build_refresh_callback(model;
            providers = discrete_providers,
            buffers = RefreshBuffers(merged_param),
            post_refresh = dm.materialize!)   # recompute discrete caches per boundary
    end

    return _simulate_solve(f!, u0, (Float64(tspan[1]), Float64(tspan[2])), p, alg, var_map;
                           callback = cb, tstops = tstops,
                           reltol = reltol, abstol = abstol, saveat = saveat)
end
