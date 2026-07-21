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
        # esm-spec §9.6.4 Option B: `flatten` ALWAYS carries surviving
        # `apply_expression_template` references into the FlattenedSystem; they
        # ride to the tree-walk build boundary below. Under
        # `ESS_TEMPLATE_REF_DISABLE=1` load already expanded, so none exist.
        input = flatten(input)
    end
    if input isa FlattenedSystem
        # Surviving references are THE behavior: they ride through
        # `flattened_to_esm` to the build boundary, where `_build_evaluator_impl`
        # expands them with SITE RECORDING — the SINGLE evaluator-side expansion
        # point — and the affine-stencil compile-once tier factors each body once
        # per (use site, region class) instead of fusing it into every branch
        # spine (RFC out-of-line-expression-templates step c; ~50x fewer
        # node-lowerings on the ESD PPM stack). The downstream shape transforms
        # below only inspect equation LHS / infer shapes from already-shaped
        # operands, so a surviving `apply_expression_template` node rides through
        # them untouched.
        #
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

# --------------------------------------------------------------------------- #
# PreparedModel — preparation as a first-class cached artifact.
#
# Everything deterministic-per-document (load → flatten → shape transforms →
# flattened_to_esm → build_evaluator) historically re-ran on EVERY simulate call
# and dominated wall-time. `prepare` runs it ONCE and returns this artifact;
# `simulate(prep, tspan; …)` then only varies tspan/solver/saveat per call.
# --------------------------------------------------------------------------- #

"""
    PreparedModel

The cached, run-ready artifact returned by [`prepare`](@ref): the compiled
tree-walk RHS `f!`, the baseline initial state `u0`, the parameter carrier `p`,
the `var_map`, the live forcing buffers, and the discrete-provider/refresh
scaffolding — everything deterministic per document, built exactly once.

Run it with `simulate(prep, tspan; alg = …)`, as many times as you like:

```julia
prep = prepare("model.esm"; parameters = Dict("M.k" => 2.5))
r1 = simulate(prep, (0.0, 1.0); alg = Tsit5())
r2 = simulate(prep, (0.0, 5.0); alg = Tsit5())   # no re-load / re-flatten / re-build
```

Snapshot semantics: the input document is fully parsed and compiled at
`prepare` time, so mutations to the input (e.g. editing the `Dict` you passed)
after `prepare` returns are NOT seen by later `simulate(prep, …)` calls.
Forcing arrays (`const_arrays` / `param_arrays`) are the exception by design:
they are captured BY REFERENCE (the live-buffer refresh contract), not copied.

Repeated runs are independent: `u0` is copied per run (per-run
`initial_conditions` / `seed_ic!` never leak into the next run), and discrete
forcing buffers are re-seeded from their providers at each run's `t0` (with the
[`DiscreteMaterializer`](@ref) caches recomputed) whenever a previous run may
have refreshed them or the start time changed.

Parameter overrides are baked in at `prepare` time — they participate in
build-time constant folding (setup geometry, value-invention extents, binning
coordinates, `ic()` folds) — so `simulate(prep, …; parameters = …)` throws;
call `prepare` again to change them.
"""
struct PreparedModel
    f!::Function                          # compiled tree-walk RHS (in-place)
    u0::Vector{Float64}                   # baseline initial state; COPIED per run
    p::Any                                # parameter NamedTuple (or nothing)
    var_map::Dict{String,Int}             # state-element name → flat index
    param_buffers::Dict{String,Any}       # live forcing buffers, aliased into f!
    discrete_providers::Dict{String,Any}  # forcing var → DISCRETE data Provider
    dm::DiscreteMaterializer              # discrete-cadence cache sink (may be empty)
    seed_time::Float64                    # t the providers were sampled at build
    n_equations::Int                      # flattened equation count (display only)
    buffer_time::Base.RefValue{Float64}   # t the discrete buffers currently hold
    dirty::Base.RefValue{Bool}            # true once a run may have refreshed them
end

function Base.show(io::IO, prep::PreparedModel)
    np = prep.p === nothing ? 0 : length(prep.p)
    print(io, "PreparedModel(", length(prep.u0), " state elements, ",
          prep.n_equations, " equations, ", np, " parameters")
    isempty(prep.discrete_providers) ||
        print(io, ", ", length(prep.discrete_providers), " discrete forcings")
    print(io, "; tree-walk :inplace)")
end

# Equation count of the prepared (flattened, single-model) run document —
# display metadata only, read off the doc `prepare` already holds.
function _doc_equation_count(doc::AbstractDict)
    n = 0
    models = get(doc, "models", nothing)
    models isa AbstractDict || return n
    for (_, m) in models
        m isa AbstractDict || continue
        eqs = get(m, "equations", nothing)
        eqs isa AbstractVector && (n += length(eqs))
    end
    return n
end

"""
    prepare(input; parameters=Dict(), kwargs...) -> PreparedModel

Run everything deterministic-per-document ONCE — coerce `input` to a runnable
document (load → flatten → shape transforms), materialize provider fields, and
build the tree-walk evaluator — and return a [`PreparedModel`](@ref) that
[`simulate`](@ref) can integrate repeatedly without re-preparing.

`input` may be a path to an `.esm` file, a native ESM `Dict`, a loaded
[`EsmFile`](@ref), or a [`FlattenedSystem`](@ref) — the same carriers
`simulate(input, tspan; …)` accepts, with the same flattening/namespacing
semantics. **Snapshot semantics**: the document is fully parsed here, so
mutating `input` after `prepare` returns does not affect the prepared model
(forcing arrays are aliased by design; see [`PreparedModel`](@ref)).

Keyword arguments (the BUILD-time subset of `simulate`'s keywords):
* `parameters::AbstractDict` — parameter overrides (→ `build_evaluator`'s
  `parameter_overrides`). Baked into the build (they feed build-time constant
  folding), which is why they belong here and not on the per-run call.
* `const_arrays`, `param_arrays` — forwarded to `build_evaluator` (the regridder
  source polygons and the live forcing buffers).
* `providers::AbstractDict` — `<Loader>.<var> => data Provider`. CONST providers
  ([`provider_is_const`](@ref)) are materialized once into `const_arrays` under
  their loader variable name; DISCRETE providers get a live buffer seeded at
  `sample_time` (and re-seeded at each run's `t0`) plus refresh-callback wiring
  at simulate time.
* `sample_time::Real = 0.0` — the `t` at which providers are sampled for the
  build. A CONST provider is time-invariant by contract, so the default is
  normally fine; DISCRETE buffers seeded here are re-seeded at each run's `t0`
  anyway. (`simulate(input, tspan; …)` passes `tspan[1]`.)
* `model_name` — select one model when the document holds several.
* `inspect::BuildInspection` — optional build-observability sink.
* `materialize_out::DiscreteMaterializer` — optional discrete-cadence
  materialization sink (reused, and thus inspectable); else an internal one.

Per-RUN knobs (`alg`, `initial_conditions`, `seed_ic!`, `reltol`, `abstol`,
`saveat`) belong to `simulate(prep, tspan; …)`.
"""
function prepare(input;
                 parameters::AbstractDict = Dict{String,Float64}(),
                 const_arrays::AbstractDict = Dict{String,Any}(),
                 param_arrays::AbstractDict = Dict{String,Any}(),
                 providers::Union{Nothing,AbstractDict} = nothing,
                 model_name::Union{Nothing,AbstractString} = nothing,
                 sample_time::Real = 0.0,
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
    # Phase 2b Hook 2: GATED providers are DEFERRED — not pulled whole here, but
    # stashed and fetched pre-sliced after value-invention (the const-tier
    # dependency edge). A provider is gated when it reports a `provider_gate_spec`
    # (the runner sets it from the loader's `gated_select`; a mock carries it).
    gated_providers = Dict{String,Any}()
    if providers !== nothing
        t0 = Float64(sample_time)
        for (rawk, prov) in providers
            k = String(rawk)
            if provider_is_gated(prov)
                # Defer: value-invention must derive the gating set's members
                # before we know which rows to fetch. Bundle the gate spec so the
                # build resolves the selection without re-consulting the provider.
                gated_providers[k] = (prov=prov, gate=provider_gate_spec(prov))
            elseif provider_is_const(prov)
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
        materialize_out = dm,
        # Phase 2b Hook 2: deferred gated providers + the build-time sample tick.
        # The front door fetches these pre-sliced right after value-invention.
        _gated_providers = gated_providers,
        _sample_time = Float64(sample_time))

    return PreparedModel(f!, u0, p, var_map, merged_param, discrete_providers, dm,
                         Float64(sample_time), _doc_equation_count(doc),
                         Ref(Float64(sample_time)), Ref(false))
end

# Re-seed the DISCRETE forcing buffers at the run's t0 and recompute the
# discrete-materialized caches, so every `simulate(prep, …)` run starts from
# freshly initialized refresh state — a previous run's callback mutates the
# buffers in place, and a different start time needs a different initial tick.
# Skipped when the buffers are pristine and already hold the sample at t0 (the
# first run of the delegating `simulate(input, tspan)` path — no double sample).
function _reseed_discrete!(prep::PreparedModel, t0::Float64)
    isempty(prep.discrete_providers) && return nothing
    (prep.dirty[] || prep.buffer_time[] != t0) || return nothing
    for (k, prov) in prep.discrete_providers
        buf = prep.param_buffers[k]::Array{Float64}
        _write_forcing!(buf, k, provider_sample(prov, t0))
    end
    prep.dm.materialize!()   # discrete caches must see the re-seeded buffers
    prep.buffer_time[] = t0
    prep.dirty[] = false
    return nothing
end

"""
    simulate(prep::PreparedModel, tspan; alg, kwargs...) -> SimulationResult

Integrate an already-[`prepare`](@ref)d model over `tspan = (t0, t1)` — the
load/flatten/build pipeline is SKIPPED entirely; only the per-run knobs vary.

Keyword arguments: `alg` (REQUIRED, e.g. `Tsit5()`), `initial_conditions`,
`seed_ic!`, `reltol`, `abstol`, `saveat` — exactly as on
`simulate(input, tspan; …)`. Per-run IC overrides apply to a COPY of the
prepared `u0`, so repeated runs are independent; discrete forcing buffers are
re-seeded at this run's `t0` when needed (see [`PreparedModel`](@ref)).

`parameters` is NOT accepted here (non-empty throws [`SimulateError`](@ref)):
overrides are baked into the evaluator at `prepare` time because they feed
build-time constant folding. Call `prepare(input; parameters = …)` instead.
"""
function simulate(prep::PreparedModel, tspan;
                  alg = nothing,
                  parameters::AbstractDict = Dict{String,Float64}(),
                  initial_conditions::AbstractDict = Dict{String,Float64}(),
                  seed_ic! = nothing,
                  reltol::Float64 = DEFAULT_SIM_RELTOL,
                  abstol::Float64 = DEFAULT_SIM_ABSTOL,
                  saveat = nothing)
    isempty(parameters) || throw(SimulateError(
        "simulate(prep::PreparedModel, …): parameter overrides are baked into the " *
        "evaluator at prepare() time (they feed build-time constant folding: setup " *
        "geometry, value-invention extents, binning coordinates, ic() folds). " *
        "Call prepare(input; parameters = …) to change them."))
    t0 = Float64(tspan[1])
    _reseed_discrete!(prep, t0)

    u0 = copy(prep.u0)   # per-run copy: IC overrides must not leak across runs
    isempty(initial_conditions) || _apply_initial_conditions!(u0, prep.var_map, initial_conditions)
    seed_ic! === nothing || seed_ic!(u0, prep.var_map)

    cb = nothing
    tstops = Float64[]
    if !isempty(prep.discrete_providers)
        cb, tstops = build_refresh_callback(;
            providers = prep.discrete_providers,
            buffers = RefreshBuffers(prep.param_buffers),
            post_refresh = prep.dm.materialize!)   # recompute discrete caches per boundary
        prep.dirty[] = true   # the solve will mutate the buffers at each anchor
    end

    return _simulate_solve(prep.f!, u0, (t0, Float64(tspan[2])), prep.p, alg, prep.var_map;
                           callback = cb, tstops = tstops,
                           reltol = reltol, abstol = abstol, saveat = saveat)
end

"""
    simulate(input, tspan; alg, kwargs...) -> SimulationResult

Run an ESM model end to end: coerce `input` to a runnable document, build the
tree-walk evaluator, seed initial conditions, wire any discrete-cadence data
providers, and integrate over `tspan = (t0, t1)`.

This one-call form is [`prepare`](@ref) + `simulate(prep, tspan; …)` fused: it
re-prepares on every call. Running the same document repeatedly? `prepare` once
and reuse the [`PreparedModel`](@ref) — model preparation/build has historically
dominated `simulate` wall-time.

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
    # BUILD-time knobs go to `prepare` (providers sampled at this run's t0, the
    # historical behavior); per-RUN knobs ride the PreparedModel method. The
    # first run at t0 == sample_time skips the discrete re-seed, so the one-call
    # path samples each provider exactly once — same as the pre-cache pipeline.
    prep = prepare(input;
                   parameters = parameters,
                   const_arrays = const_arrays,
                   param_arrays = param_arrays,
                   providers = providers,
                   model_name = model_name,
                   sample_time = tspan[1],
                   inspect = inspect,
                   materialize_out = materialize_out)
    return simulate(prep, tspan;
                    alg = alg,
                    initial_conditions = initial_conditions,
                    seed_ic! = seed_ic!,
                    reltol = reltol, abstol = abstol, saveat = saveat)
end
