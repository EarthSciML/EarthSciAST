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

When [`simulate`](@ref) is run with streaming output `sinks`, the sink owns the
trajectory and the solver is told `save_everystep=false`, so `t`/`u` carry only
the start/end points (the full trajectory lives in the sink, not in RAM). A
no-sink run is unaffected — `u` holds every saved point as before.
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

struct SimulateError <: EarthSciASTError
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
function _prepare_run_doc(input; metaparameters::AbstractDict = Dict{String,Int}(),
                          base_path::AbstractString = pwd())
    if input isa AbstractString
        isfile(input) || throw(SimulateError("simulate: no such file '$input'"))
        input = load(input; metaparameters=metaparameters)
    end
    if input isa AbstractDict
        input = load(input; base_path=base_path, metaparameters=metaparameters)
    end
    # Capture the verbatim document-scoped `coordinates` registry (RFC §8.3) BEFORE
    # flattening drops it (it rides on `EsmFile`, not `FlattenedSystem`); re-inject
    # it into the run doc below so `derive_output_meta` can emit CF coordinates.
    run_coordinates = nothing
    if input isa EsmFile
        run_coordinates = input.coordinates
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
        doc = flattened_to_esm(input)
        # Re-attach the verbatim `coordinates` registry (captured pre-flatten) so the
        # streaming-output writer sees it (RFC §8.3). Document-scoped + un-namespaced,
        # like `index_sets`, so it drops straight onto the run doc.
        run_coordinates !== nothing && !isempty(run_coordinates) &&
            (doc["coordinates"] = run_coordinates)
        return doc
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
    isempty(ics) && return u0
    # esm-spec §6.6.2 keys `initial_conditions` by LOCAL variable name (`u`),
    # but every document front-door reaches the run through `flatten`, which
    # renames each state after its owning component (`M.u`) — so an EXACT-key
    # lookup missed the very spelling the spec tells authors to write, and a
    # test's `initial_conditions: {"u": 9.0}` died with "unknown state element
    # 'u'". Same defect as `parameter_overrides` had, on the state side; it
    # merely failed loudly instead of silently. Resolve the caller's key onto
    # the name the build uses with the SAME rules (build.jl
    # `_canonicalize_override_keys`): exact hit, else a dotted key whose
    # trailing segment is a state name, else a bare key that is the trailing
    # segment of exactly one — an ambiguous local name is rejected, never
    # guessed at.
    #
    # Two name spaces are tried in order: the ELEMENT names (`M.u`, `M.f[1]`),
    # then the array BASE names for the broadcast form (`M.f` sets every
    # `M.f[...]` cell). `_parse_cell_key` (tree_walk.jl) is the single inverse
    # of `_cell_key`'s "name[i,j]" element encoding.
    element_names = Set{String}(String(k) for k in keys(var_map))
    cells_of = Dict{String,Vector{Int}}()
    for (vname, idx) in var_map
        parsed = _parse_cell_key(String(vname))
        parsed === nothing && continue
        push!(get!(cells_of, parsed[1], Int[]), idx)
    end
    base_names = Set{String}(keys(cells_of))
    element_alias = _bare_alias_groups(element_names)
    base_alias = _bare_alias_groups(base_names)
    for (rawkey, value) in ics
        key = String(rawkey)
        v = Float64(value)
        resolved = _resolve_state_key(key, element_names, element_alias)
        if resolved !== nothing
            u0[var_map[resolved]] = v
            continue
        end
        resolved = _resolve_state_key(key, base_names, base_alias)
        if resolved !== nothing
            for idx in cells_of[resolved]
                u0[idx] = v
            end
            continue
        end
        throw(SimulateError("simulate: initial_conditions names unknown " *
                            "state element '$key'"))
    end
    return u0
end

# `bare trailing segment => every qualified name carrying it`, built once per
# name space so key resolution below stays O(1) per key.
function _bare_alias_groups(names::AbstractSet{String})
    groups = Dict{String,Vector{String}}()
    for n in names
        b = _bare_param_name(n)
        b == n && continue
        push!(get!(groups, b, String[]), n)
    end
    return groups
end

# Resolve ONE caller-spelled state key against a set of build-resolved names,
# by the esm-spec §6.6.2 precedence shared with `parameter_overrides`. Returns
# the resolved name, or `nothing` when the key designates none of them. An
# AMBIGUOUS bare name (the local name of two mounted components' states) raises
# its own diagnostic rather than being lumped in with "unknown" — silently
# binding one of the candidates would be a wrong answer, not a missing one.
function _resolve_state_key(key::AbstractString, names::AbstractSet{String},
                            alias::AbstractDict{String,Vector{String}})
    key in names && return String(key)
    bare = _bare_param_name(key)
    bare != key && bare in names && return bare
    cands = get(alias, String(key), nothing)
    cands === nothing && return nothing
    length(cands) == 1 && return cands[1]
    throw(SimulateError("simulate: initial_conditions names the ambiguous local " *
                        "state '$key' — $(length(cands)) states carry it " *
                        "($(join(sort(cands), ", "))). Qualify it with its owning " *
                        "component (esm-spec §6.6.2)."))
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

Parameter overrides split by CLASS (see [`parameter_classes`](@ref)):
`:numeric` ones may be passed to `simulate(prep, …; parameters = …)` and are
applied by swapping `p` at solve time (cheap, and AD-transparent — the SciML
`remake` shape). `:structural`, `:const_folded` and `:forcing` ones still throw:
their values were consumed at BUILD time (or never reach `p` at all), so call
`prepare` again to change them.
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
    output_meta::OutputMeta               # doc-derived output naming/CF metadata (RFC §7–§8)
    # The prepared (flattened, single-model) RUN DOCUMENT the evaluator was
    # built from — the carrier [`observed_field`](@ref) resolves shapes and
    # index sets against, so a caller can read build-time observeds through the
    # PUBLIC prepare surface instead of re-running the document pipeline.
    run_doc::Dict{String,Any}
    run_file::Base.RefValue{Any}          # lazy coerce_esm_file(run_doc) memo
    # The parameter PARTITION this build produced (see `parameter_classes`):
    # name → `:numeric` / `:structural` / `:const_folded` / `:forcing`. Derived
    # from what the build-time consumers actually READ, which is what decides
    # whether an override can ride `p` at solve time or needs a re-`prepare`.
    param_classes::Dict{String,Symbol}
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

# --------------------------------------------------------------------------- #
# Loader-discovered extents (esm-spec §8.9.4, CONFORMANCE_SPEC §5.5) — the
# pre-pass `prepare` runs before ANY load, because a discovered extent closes a
# metaparameter and metaparameters are bound at the loader API.
#
# Returns `(metaparameters, discovered)`: the caller's bindings PLUS whatever
# the loaders measured, and the sampled arrays themselves so the injection loop
# reuses them instead of re-reading (the 69 MB FF10 zip is decoded once).
# --------------------------------------------------------------------------- #
function _discover_loader_extents(providers, metaparameters::AbstractDict, t0::Float64)
    out = Dict{String,Int}(String(k) => Int(v) for (k, v) in metaparameters)
    discovered = Dict{String,Any}()
    providers === nothing && return out, discovered
    # `by` records which provider bound each metaparameter, so a disagreement
    # names BOTH sides. Sorted keys keep that naming deterministic.
    by = Dict{String,Tuple{Int,String}}()
    for rawk in sort!(String[String(k) for k in keys(providers)])
        prov = providers[rawk]
        mp = provider_extent_metaparameter(prov)
        mp === nothing && continue
        mp = String(mp)
        provider_is_gated(prov) && throw(SimulateError(
            "provider '$rawk' both GATES on a derived index set and declares the " *
            "extent metaparameter '$mp'; a gated slab's extent is the gating set's, " *
            "not a discovered one"))
        sample = provider_sample(prov, t0)
        field = _sample_field(sample, rawk)
        n = ndims(field) == 0 ? 1 : size(field, 1)
        if haskey(by, mp)
            prev, prevk = by[mp]
            prev == n || throw(SimulateError(
                "loader extent '$mp' is $prev from provider '$prevk' but $n from " *
                "'$rawk' — the loader's variables are not aligned on one record axis"))
        elseif haskey(out, mp) && out[mp] != n
            throw(SimulateError(
                "metaparameter '$mp' was closed at $(out[mp]) by the caller but " *
                "provider '$rawk' discovers $n records; drop the binding and let the " *
                "loader declare its own extent"))
        end
        by[mp] = (n, rawk)
        out[mp] = n
        discovered[rawk] = field
    end
    return out, discovered
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
  folding), which is why EVERY class of parameter can be set here — including
  the `:structural` ones a per-run override must refuse (see
  [`parameter_classes`](@ref)). A purely `:numeric` change need not come back
  through `prepare`: pass it to `simulate(prep, tspan; parameters = …)`, which
  swaps `p` instead of rebuilding. Keys may be spelled LOCALLY (`pert_amp`, the
  form esm-spec §6.6 pins for a test's `parameter_overrides`) or with the
  flattener's namespacing (`Chem.pert_amp`); both resolve to the same parameter.
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
* `base_path::AbstractString = pwd()` — the directory a native `Dict` input's
  relative `{ref}`s resolve against (a path input anchors them at its own
  directory). It matters now that `prepare` is the load site: handing it a
  parsed document used to be impossible when that document had refs.
* `metaparameters::AbstractDict` — binds the document's open metaparameters at
  the loader API (esm-spec §9.7.6 binding site 3), exactly as
  [`load`](@ref)`(path; metaparameters=…)` does. Pass them HERE rather than
  pre-`load`ing, so a loader that discovers its own extent can close one first
  (below); a caller binding that CONTRADICTS a discovered extent is an error.
* `model_name` — select one model when the document holds several.
* `inspect::BuildInspection` — optional build-observability sink.
* `materialize_out::DiscreteMaterializer` — optional discrete-cadence
  materialization sink (reused, and thus inspectable); else an internal one.

* `pushdown_rewrite::Bool = false` — opt in to the automatic projection-pushdown
  desugar ([`desugar_pushdown`](@ref)) at the PUBLIC entry point. The rewrite
  runs on the authored document BEFORE flattening (the pattern is authored in
  the un-namespaced model), and the engine then derives every provider gate
  from the rewrite's own `metadata.x_esd.pushdown` record: a `providers` entry
  that the document's coupling routes onto a rewritten array is DEFERRED and
  fetched pre-sliced to the invented support set — the caller hand-authors no
  gate dict and implements no `provider_gate_spec` (which still works, as the
  fallback, for providers outside the record's coupling scope).

**Loader-discovered extents** (esm-spec §8.9.4, CONFORMANCE_SPEC §5.5). A
provider reporting a [`provider_extent_metaparameter`](@ref) is sampled ONCE
here, ahead of everything else, and the length of its delivered record axis
binds that metaparameter for the load below — so `size: "N_REC"` is sized by the
data itself. That array is REUSED when the provider is injected (never sampled
twice); providers of one loader disagreeing on the count is an error naming
both, and a `metaparameters` binding contradicting the discovered value is an
error rather than a silent preference for either. Because the metaparameter must
still be OPEN, `input` must be a path or a native `Dict` — an already-`load`ed
`EsmFile` has closed it already, which is an error rather than a silent
fallback.

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
                 metaparameters::AbstractDict = Dict{String,Int}(),
                 base_path::AbstractString = pwd(),
                 inspect::Union{Nothing,BuildInspection} = nothing,
                 materialize_out::Union{Nothing,DiscreteMaterializer} = nothing,
                 pushdown_rewrite::Bool = false)
    # ---- extent discovery: a loader that measures its OWN record count ------
    # FIRST, because a discovered extent CLOSES a metaparameter and every load
    # below binds metaparameters at the loader API (esm-spec §9.7.6 site 3). The
    # sampled arrays are kept and reused at injection, so a 69 MB FF10 zip is
    # decoded once, not once here and again there.
    metaparams, discovered = _discover_loader_extents(providers, metaparameters,
                                                      Float64(sample_time))
    # `load` is where a metaparameter closes, so an ALREADY-loaded carrier has
    # closed them — silently ignoring a binding (the caller's or a loader's) is
    # exactly the failure this seam exists to prevent.
    if !isempty(metaparams) && !(input isa AbstractString || input isa AbstractDict)
        why = isempty(discovered) ? "" :
              string(". ", join(sort!(collect(keys(discovered))), ", "),
                     " DISCOVERED its own extent, which only a not-yet-loaded ",
                     "document can be sized by")
        throw(SimulateError(
            "prepare: metaparameters $(sort!(collect(keys(metaparams)))) must be bound " *
            "at the loader API, but `input` is a $(typeof(input)) whose metaparameters " *
            "are already closed — pass the path or the native Dict to prepare (and drop " *
            "the pre-`load`), or bind them in that `load` call instead" * why))
    end

    # ---- Phase 1 (clean consolidation): pushdown prepass, BEFORE flatten ----
    # The desugar must see the AUTHORED (namespaced-not-yet-flattened) model:
    # the flattener rewrites coupling-fed references in equations but not in the
    # variables' `expression` fields, so the pattern no longer matches
    # post-flatten. Running it here also puts the provenance record in hand
    # BEFORE the provider classification below needs it. `desugar_pushdown` is
    # idempotent (guarded on its own record), so the front door's own hook —
    # never triggered from here — stays safe for direct callers.
    pd_gates = Dict{String,Any}()
    pd_coupling = Pair{String,String}[]
    if pushdown_rewrite
        pfile = input isa EsmFile ? input :
                input isa AbstractString ?
                    (isfile(input) || throw(SimulateError("prepare: no such file '$input'"));
                     load(input; metaparameters=metaparams)) :
                input isa AbstractDict ? load(input; base_path=base_path,
                                              metaparameters=metaparams) :
                throw(SimulateError(
                    "prepare: pushdown_rewrite=true needs a path, native Dict, or " *
                    "EsmFile input — a FlattenedSystem is already past the rewrite point"))
        raw = serialize_esm_file(pfile)
        rewritten = desugar_pushdown(raw; model_name=model_name)
        if rewritten !== raw                       # the pattern matched
            pd_gates = _pushdown_provider_gates(rewritten, providers)
            pd_coupling = _pushdown_coupling_pairs(rewritten)
            input = rewritten
        else
            input = pfile                          # no re-load, no rewrite
        end
    end
    # A discovered extent and a record-derived gate are mutually exclusive: a
    # gated slab's extent belongs to the gating set, which value-invention has
    # not materialised yet. (The provider's OWN gate is caught in the pre-pass;
    # this catches the gate the rewrite record derives, which only exists now.)
    for k in keys(discovered)
        haskey(pd_gates, k) && throw(SimulateError(
            "provider '$k' both GATES on a derived index set and declares the extent " *
            "metaparameter '$(provider_extent_metaparameter(providers[k]))'; a gated " *
            "slab's extent is the gating set's, not a discovered one"))
    end
    doc = _prepare_run_doc(input; metaparameters=metaparams, base_path=base_path)

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
            pd_gate = get(pd_gates, k, nothing)
            if haskey(discovered, k)
                # Already materialized by the extent-discovery pre-pass; never
                # sampled twice.
                merged_const[k] = Array{Float64}(discovered[k])
            elseif pd_gate !== nothing
                # Phase 1: RECORD-DERIVED gate — the rewrite's own
                # `metadata.x_esd.pushdown.gated_select`, mapped onto this
                # provider through the document coupling. Takes precedence over
                # a provider-implemented `provider_gate_spec`.
                gated_providers[k] = (prov=prov, gate=pd_gate)
            elseif provider_is_gated(prov)
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

    # Phase 1: pushdown-path name aliasing. The build-front-door consumers that
    # run BEFORE the impl parse (`_derive_binning_coords`, value-invention,
    # `_observed_field`) read the flattened VARIABLES' expressions, which keep
    # namespaced pre-coupling names — inject the caller's/providers' arrays
    # under those spellings too (same objects, no copies).
    if pushdown_rewrite
        _inject_pushdown_aliases!(merged_const, doc, pd_coupling)
        _inject_pushdown_aliases!(merged_param, doc, pd_coupling)
    end

    # Discrete-cadence materialization sink (the middle cadence phase): opt IN so a
    # state-free derived field over a live forcing buffer (a regrid→physics stack) is
    # cut out of the per-step RHS into a cache filled once per refresh, not recomputed
    # on every continuous step. Empty (no discrete-materialize var) ⇒ no effect. A
    # caller-supplied `materialize_out` is reused (and thus inspectable), else fresh.
    dm = materialize_out === nothing ? DiscreteMaterializer() : materialize_out
    # The parameter partition sink (differentiability plan §3 Phase 5): the build
    # fills it with name → `:numeric` / `:structural` / `:const_folded` /
    # `:forcing`, derived from which names its BUILD-TIME consumers read. It is
    # what lets `simulate(prep, …; parameters = …)` accept the numeric half
    # instead of refusing every override.
    param_classes = Dict{String,Symbol}()
    f!, u0, p, _tspan, var_map = build_evaluator(doc;
        model_name = model_name,
        parameter_overrides = overrides,
        const_arrays = merged_const,
        param_arrays = merged_param,
        inspect = inspect,
        materialize_out = dm,
        _param_classes = param_classes,
        # Phase 2b Hook 2: deferred gated providers + the build-time sample tick.
        # The front door fetches these pre-sliced right after value-invention.
        _gated_providers = gated_providers,
        _sample_time = Float64(sample_time))

    return PreparedModel(f!, u0, p, var_map, merged_param, discrete_providers, dm,
                         Float64(sample_time), _doc_equation_count(doc),
                         Ref(Float64(sample_time)), Ref(false),
                         derive_output_meta(doc), doc, Ref{Any}(nothing),
                         param_classes)
end

"""
    observed_field(prep::PreparedModel, insp::BuildInspection, name) -> Array

Evaluate the state-free observed `name` at BUILD time through the prepared
document's own graph — the public face of the build-observability path
(`_observed_field`) for `prepare` callers. `insp` is the same
[`BuildInspection`](@ref) that was passed to [`prepare`](@ref) (it carries the
resolved observed definitions, const-array registry, and value-invention
extents this evaluation reads). `name` may be spelled with the flattener's
namespacing (`"ISRM.deathsK"`) or locally (`"deathsK"`, resolved against the
single run model's variable tails).

Throws a `SimulateError` when `name` is not a build-time-evaluable observed
(state-dependent, unsized axis, or not an observed at all).
"""
function observed_field(prep::PreparedModel, insp::BuildInspection,
                        name::AbstractString)
    if prep.run_file[] === nothing
        prep.run_file[] = coerce_esm_file(prep.run_doc)
    end
    file = prep.run_file[]::EsmFile
    (file.models !== nothing && !isempty(file.models)) || throw(SimulateError(
        "observed_field: prepared document has no model"))
    mname = String(first(keys(file.models)))
    v = String(name)
    fld = _observed_field(insp, file, mname, v)
    if fld === nothing && !occursin('.', v)
        # local spelling: resolve against the run model's variable tails.
        for k in keys(file.models[mname].variables)
            ks = String(k)
            (occursin('.', ks) && String(split(ks, '.')[end]) == v) || continue
            fld = _observed_field(insp, file, mname, ks)
            fld === nothing || break
        end
    end
    if fld === nothing
        # MATERIALIZED observeds. A body carrying a geometry leaf
        # (`polygon_intersection_area`, `intersect_polygon`) is materialized at
        # SETUP into `insp.setup_arrays` rather than left as a build-time
        # observed — and so, transitively, is everything downstream of it, since
        # a setup array is a build constant and its readers fold against it.
        # `_observed_field` looks only at the observed graph, so on a document
        # whose emissions come from an area overlap rather than a point
        # containment that is the WHOLE reported chain: the per-cell emissions,
        # the source-receptor contraction, the concentrations and the deaths all
        # became unreadable BY NAME, even though the build computed every one of
        # them. `const_arrays` is the same story one step earlier: a projected
        # coordinate (`X`, `Y`) is materialized ahead of value invention and
        # seeded there as a build constant, so it too is computed and unreadable.
        # The array the build itself used is the value; return it rather than
        # re-deriving it. Flattened in the same ROW-MAJOR cell order
        # `_observed_field` returns (`_state_cells`, the Python `np.ndindex` and
        # the Rust row-major enumeration all agree on it), so the two paths are
        # interchangeable at any rank.
        # The setup arrays are keyed by the name as the SETUP pass saw it — the
        # AUTHORED model's flattened name (`ISRM.E_PM25`) — while `mname` here
        # is the RUN document's single model, which flattening renamed
        # (`Flattened`). So resolve by tail as well, and only when it is
        # unambiguous: two models may carry the same local name, and answering
        # a bare `E_PM25` with an arbitrary one of them would be worse than
        # refusing.
        # GUARD: only an OBSERVED may be answered this way. `const_arrays` also
        # holds every array-valued PARAMETER, and quietly returning one of those
        # from `observed_field` would turn a wrong name into a plausible answer.
        obs = Set{String}(observed_unknowns(file.models[mname]))
        is_obs = any(k -> (String(k) == v || String(split(String(k), '.')[end]) == v)
                          && String(k) in obs, keys(file.models[mname].variables))
        is_obs || throw(SimulateError(
            "observed_field: '$name' is not a build-time-evaluable observed of the " *
            "prepared document"))
        arr = nothing
        for reg in (insp.setup_arrays, insp.const_arrays)
            arr = get(reg, mname * "." * v, get(reg, v, nothing))
            if arr === nothing
                hits = [k for k in keys(reg)
                        if occursin('.', k) && String(split(k, '.')[end]) == v]
                length(hits) == 1 && (arr = reg[first(hits)])
            end
            arr isa AbstractArray || (arr = nothing)
            arr === nothing || break
        end
        arr === nothing && throw(SimulateError(
            "observed_field: '$name' is not a build-time-evaluable observed of the " *
            "prepared document"))
        return ndims(arr) > 1 ? vec(permutedims(arr, reverse(1:ndims(arr)))) : vec(arr)
    end
    return fld[1]
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
    parameter_classes(prep::PreparedModel) -> Dict{String,Symbol}

The parameter partition of the build behind `prep` — `:numeric`, `:structural`,
`:const_folded`, `:forcing`. See the [`parameter_classes`](@ref) docstring on the
[`BuildInspection`](@ref) method for what each class means and how it is derived.
"""
parameter_classes(prep::PreparedModel) = prep.param_classes

# A readable name list for an error: a real model carries dozens of parameters
# and dumping all of them buries the diagnostic that matters.
function _elide_names(ns::AbstractVector{String}, n::Int = 12)
    length(ns) <= n && return join(ns, ", ")
    return join(ns[1:n], ", ") * ", … ($(length(ns)) total; see parameter_classes(prep))"
end

# One override's refusal message, naming the parameter AND its class AND why the
# class cannot ride `p`. Each class fails for a different reason, and saying
# which is the whole point of the partition: "parameters bake at prepare() time"
# was true of all of them and useful about none.
function _param_class_refusal(name::AbstractString, cls::Symbol)
    what = cls === :structural ?
        "STRUCTURAL: its value is read at BUILD time (setup geometry, " *
        "value-invention index-set extents, binning coordinates, ic() folds), " *
        "where it can decide the SHAPE of the problem — length(u0), the compiled " *
        "kernels. A value swapped into `p` at solve time would contradict the one " *
        "already baked into the build" :
      cls === :const_folded ?
        "CONST-FOLDED DATA: it is supplied as const data (a const provider / a " *
        "`const_arrays` entry), frozen into the build and inlined into the RHS, so " *
        "it never reaches the runtime `p` at all. An override here would be silently " *
        "ignored — and so is a derivative: ∂/∂(this) is an unconditional zero that a " *
        "finite-difference check on its declared default would CONFIRM" :
      cls === :forcing ?
        "LIVE FORCING DATA: it is bound to a forcing buffer that a discrete provider " *
        "rewrites in place at each refresh, so it never reaches the runtime `p`. " *
        "Change the provider or write the buffer" :
        "not a solve-time parameter of this build ($(cls))"
    fix = cls === :forcing ?
        "supply a different provider / write `prep.param_buffers[\"$name\"]`" :
        "call prepare(input; parameters = Dict(\"$name\" => …)) again — a " *
        "structural change is an explicit re-prepare, never something hidden " *
        "inside a `p` swap"
    return "simulate(prep::PreparedModel, …; parameters): '$name' is $what. " *
           "To change it, $fix."
end

"""
    remake_parameters(prep::PreparedModel, overrides) -> p

The parameter carrier `prep.p` with the `:numeric` `overrides` applied — the
value to hand to SciML's `remake(prob; p = …)`, and what
`simulate(prep, tspan; parameters = …)` builds internally.

```julia
prob = ODEProblem(prep.f!, copy(prep.u0), tspan, prep.p)
prob2 = remake(prob; p = remake_parameters(prep, Dict("Emis.scale" => 2.0)))
```

This is deliberately a `p` SWAP and nothing more: `remake` exists precisely so a
sensitivity analysis can vary `p` without rebuilding `f`, and overloading it to
re-run [`prepare`](@ref) would make gradients impossible by construction. So it
is cheap (a `NamedTuple` merge, no build), and AD-transparent — each override
keeps its own type, so a `ForwardDiff.Dual` handed in here stays a `Dual` in `p`
and `∂(solution)/∂(parameter)` flows through the same compiled RHS.

Only `:numeric` parameters can be swapped. A `:structural`, `:const_folded` or
`:forcing` override throws a [`SimulateError`](@ref) naming the parameter and its
class — changing one of those is an explicit re-`prepare`, because it changes the
build, not just a number the build reads. Keys may be spelled locally
(`"scale"`) or namespaced (`"NEIRegrid.scale"`), exactly as `prepare`'s
`parameters` are; an unknown or ambiguous key throws rather than being dropped.
"""
function remake_parameters(prep::PreparedModel, overrides::AbstractDict)
    isempty(overrides) && return prep.p
    classes = prep.param_classes
    pm = param_map(prep.p)
    names = Set{String}(keys(classes))
    union!(names, keys(pm))
    normalized, unknown, ambiguous =
        _canonicalize_override_keys(Any, names, overrides)
    isempty(unknown) || throw(SimulateError(
        "simulate/remake_parameters: no parameter named " *
        join(("'" * k * "'" for k in sort(unknown)), ", ") *
        " in the prepared model (keys may be local or namespaced; a name the " *
        "flattener's coupling rewired onto a loader variable is spelled by its " *
        "SURVIVING name). Known: " * _elide_names(sort(collect(names)))))
    isempty(ambiguous) || throw(SimulateError(
        "simulate/remake_parameters: ambiguous parameter key(s) " *
        join(("'" * k * "' (matches " * join(sort(v), ", ") * ")"
              for (k, v) in sort(collect(ambiguous), by = first)), "; ") *
        "; spell the namespaced name."))
    syms = Symbol[]
    vals = Any[]
    for name in sort(collect(keys(normalized)))
        cls = get(classes, name, haskey(pm, name) ? :numeric : :unclassified)
        cls === :numeric || throw(SimulateError(_param_class_refusal(name, cls)))
        # A `:numeric` parameter is by definition a slot of `p`; if it somehow is
        # not, refuse rather than silently drop the override.
        haskey(pm, name) || throw(SimulateError(
            "simulate/remake_parameters: '$name' classifies :numeric but is not a " *
            "slot of the prepared `p` — refusing to apply an override that would " *
            "have no effect (this is a build bug; please report it)."))
        push!(syms, Symbol(name))
        push!(vals, normalized[name])
    end
    # `merge` keeps the FIRST tuple's key order, which is the build's own
    # parameter order (`param_map`) and the order every `_NK_PARAM` node's `idx`
    # was minted against. Values keep their own types (a `Dual` stays a `Dual`).
    return merge(prep.p, NamedTuple{Tuple(syms)}(Tuple(vals)))
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

Streaming output (streaming-output-sinks RFC §16):
* `sinks` — a collection of objects implementing the Sink protocol
  ([`sink_output_times`](@ref) / [`sink_write!`](@ref) / …). When non-empty,
  [`build_output_callback`](@ref) wires a `PresetTimeCallback` that snapshots
  state at each sink's output anchors and pushes it to the sink, its tstops
  UNIONed with the refresh tstops and its callback composed with the refresh
  callback; the solve runs `save_everystep=false` so the sink — not RAM — owns the
  trajectory. Empty (the default) ⇒ the historical in-RAM path, byte-identical.
* `snapshot` — an `integrator -> StateSnapshot` (or `-> state-slabs`) function;
  defaults to the host-gather [`state_snapshot`](@ref).
* `pre_write` — a `() -> nothing` hook run at each output boundary BEFORE the
  snapshot, to freshen caller-named observed caches. Defaults to a no-op.

`parameters` accepts the `:numeric` half of the parameter partition (see
[`parameter_classes`](@ref)): those are scalars that live in the runtime `p`, so
an override is applied by swapping `p` for this run — cheap, and AD-transparent
(the SciML `remake` shape; see [`remake_parameters`](@ref)). The result is
identical to passing the same value to `prepare(input; parameters = …)`.

A `:structural`, `:const_folded` or `:forcing` override still throws a
[`SimulateError`](@ref) naming the parameter and its class: those values were
consumed at BUILD time (or never reach `p` at all), so honouring them here would
mean rebuilding — call `prepare` again.
"""
function simulate(prep::PreparedModel, tspan;
                  alg = nothing,
                  parameters::AbstractDict = Dict{String,Float64}(),
                  initial_conditions::AbstractDict = Dict{String,Float64}(),
                  seed_ic! = nothing,
                  reltol::Float64 = DEFAULT_SIM_RELTOL,
                  abstol::Float64 = DEFAULT_SIM_ABSTOL,
                  saveat = nothing,
                  sinks = [],
                  snapshot = state_snapshot,
                  pre_write = () -> nothing,
                  checkpoint_predicates = (),
                  checkpoint_sinks = nothing,
                  terminate_on_checkpoint::Bool = true)
    # Solve-time parameter overrides: the `:numeric` half rides `p` (validated +
    # merged here, never a rebuild), the rest is refused BY CLASS with a message
    # that says which class and why. `p_run === prep.p` when nothing is overridden,
    # so the no-override path is byte-identical to before.
    p_run = remake_parameters(prep, parameters)
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

    # Streaming output sinks (streaming-output-sinks RFC §16.5). When any sink is
    # present, build the output callback, UNION its output tstops into the refresh
    # tstops (so input-refresh and output-write stop the solver at the union of
    # their anchors, exactly as multiple providers' refresh times union), and pass
    # BOTH callbacks to the solve — the extension composes them into one
    # `CallbackSet` (SciMLBase is solver-adjacent, so the composition stays out of
    # this core file, `[[library-exposes-rhs-not-solver]]`). `save_everystep=false`
    # then tells the solver to stop accumulating the dense RAM trajectory — the sink
    # IS the trajectory store. With no sinks, `callback`/`tstops`/`save_everystep`
    # are byte-identical to before (single refresh callback or nothing, default
    # `save_everystep=true` ⇒ the extension leaves it unset).
    callbacks = Any[]
    cb === nothing || push!(callbacks, cb)
    save_everystep = true
    if !isempty(sinks)
        out_cb, out_tstops = build_output_callback(;
            sinks = sinks, snapshot = snapshot, pre_write = pre_write)
        tstops = _union_tstops(tstops, out_tstops)
        push!(callbacks, out_cb)
        save_everystep = false
    end

    # Predicate-driven checkpointing (streaming-output-sinks RFC §10, §16.7). When
    # `checkpoint_predicates` is non-empty, compose a `DiscreteCallback` that writes a
    # full-state checkpoint to `checkpoint_sinks` (default: `sinks`) + flushes the
    # durable barrier the instant any predicate (SLURM walltime, spot notice, custom)
    # fires, optionally terminating for a clean pre-preemption exit. Interval-only
    # checkpointing needs none of this — a checkpoint-profile sink's cadence rides the
    # ordinary output callback above.
    ck_sinks = checkpoint_sinks === nothing ? sinks : checkpoint_sinks
    if !isempty(checkpoint_predicates)
        ck_cb = build_checkpoint_callback(;
            sinks = ck_sinks, predicates = checkpoint_predicates, snapshot = snapshot,
            pre_write = pre_write, terminate_on_fire = terminate_on_checkpoint)
        push!(callbacks, ck_cb)
        save_everystep = false
    end

    callback = isempty(callbacks) ? nothing : Tuple(callbacks)

    # Sink lifecycle: open each sink (declares its store dims/coords/chunk-shard
    # grid ONCE) BEFORE the solve, and close each (flush + end-of-run manifest)
    # AFTER — in a `finally` so a solver error still finalizes a partially-written
    # store into a readable, restartable state. The per-tick `sink_write!` fires
    # from the output callback in between; `simulate` owns only open/close. The
    # lifecycle set is the UNION of the diagnostic and checkpoint sinks.
    all_sinks = _distinct_sinks(sinks, ck_sinks)
    isempty(all_sinks) || foreach(sink_open!, all_sinks)
    try
        return _simulate_solve(prep.f!, u0, (t0, Float64(tspan[2])), p_run, alg, prep.var_map;
                               callback = callback, tstops = tstops, save_everystep = save_everystep,
                               reltol = reltol, abstol = abstol, saveat = saveat)
    finally
        isempty(all_sinks) || foreach(sink_close!, all_sinks)
    end
end

# The distinct sinks across the diagnostic + checkpoint sets, by object identity —
# a sink that is BOTH a diagnostic and checkpoint target opens/closes exactly once.
function _distinct_sinks(sinks, ck_sinks)
    out = Any[]
    for s in sinks
        any(x -> x === s, out) || push!(out, s)
    end
    for s in ck_sinks
        any(x -> x === s, out) || push!(out, s)
    end
    return out
end

# Sorted, de-duplicated union of two tstop vectors — the refresh anchors and the
# output anchors merge into the single `tstops` the solver stops at (mirrors the
# per-provider / per-sink union inside build_refresh_callback / build_output_callback).
function _union_tstops(a::AbstractVector{Float64}, b::AbstractVector{Float64})
    out = Float64[]
    append!(out, a)
    append!(out, b)
    sort!(out)
    unique!(out)
    return out
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
  `parameter_overrides`). Keys may be spelled LOCALLY (`pert_amp`, the form
  esm-spec §6.6 pins for a test's `parameter_overrides`) or with the
  flattener's namespacing (`Chem.pert_amp`); both resolve. The resolved values
  also bind the BUILD-TIME evaluation scope (esm-spec §6.6.5): a
  coordinate-expression `ic` and an inline assertion `reference` see the
  override, not the declared default.
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
  scoped-reference `ic(Sys.sp) ~ Model.param` folds the seeded field into u0 and a
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
                  sinks = [],
                  snapshot = state_snapshot,
                  pre_write = () -> nothing,
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
                    reltol = reltol, abstol = abstol, saveat = saveat,
                    sinks = sinks, snapshot = snapshot, pre_write = pre_write)
end
