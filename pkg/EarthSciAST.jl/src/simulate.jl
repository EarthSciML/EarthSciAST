# ===========================================================================
# ESMProblem — the ESM simulation Problem, and its SciML plumbing.
#
# esm-libraries-spec §2.5: a run is TWO steps, one noun and one verb.
#
#     prob = esm_problem(input, tspan; p, u0, providers, …)   # build once
#     sol  = solve(prob, alg; abstol, reltol, saveat, …)      # run per knob set
#
# Construction absorbs the whole deterministic-per-document pipeline (load →
# flatten → shape transforms → pushdown rewrite → value invention → the gated
# fetch of provider data → `build_evaluator`), plus the run wiring that belongs
# to the DOCUMENT rather than to a particular run: the initial state, the
# data-refresh callback, the output-sink callback and the checkpoint callback.
# `solve` varies only the per-run knobs.
#
# The `simulate` / `prepare` pair this replaces conflated the two — and had
# grown a second, `prepare`-shaped entry point next to `simulate` precisely
# because callers needed the split. `ESMProblem` IS the `PreparedModel`
# concept under the canonical name, with the run knobs it was missing.
#
# `[[library-exposes-rhs-not-solver]]`: EarthSciAST never depends on a solver.
# Everything here — coerce → build_evaluator → seed → compose callbacks — is
# solver-free, so CONSTRUCTING an `ESMProblem` needs no SciMLBase and no
# OrdinaryDiffEq (§2.5.9). The `ODEProblem` + `solve` live in a SciMLBase
# package EXTENSION (EarthSciASTSimulateExt), which specializes
# `SciMLBase.__init` / `SciMLBase.__solve` on `ESMProblem` so the STANDARD
# SciML entry points — `solve`, `init`, `step!`, `solve!`, `remake`,
# `EnsembleProblem` — work on it directly. A solution is therefore a real
# `ODESolution`: its `retcode` is a real `SciMLBase.ReturnCode`, and it is
# indexed BY NAME through SymbolicIndexingInterface (§2.5.7):
#
#     sol[Symbol("Chem.A")]        # that state element's trajectory
#     sol.retcode == ReturnCode.Success
# ===========================================================================

"""
    final_state(sol) -> Vector{Float64}

The final state vector of a solution (empty when the solve produced no points).

Works on any SciML solution — `sol.u[end]` as a dense `Vector{Float64}`,
which is the flat state vector `var_map` indexes.
"""
final_state(sol) = isempty(sol.u) ? Float64[] : Vector{Float64}(sol.u[end])


struct SimulateError <: EarthSciASTError
    msg::String
end
Base.showerror(io::IO, e::SimulateError) = print(io, "SimulateError: ", e.msg)

# --------------------------------------------------------------------------- #
# Default solver tolerances. Shared with the SciMLBase solve extension
# (ext/EarthSciASTSimulateExt.jl), which references these consts instead of
# duplicating the literals; they are what `solve(prob, alg)` uses when the
# caller names no `reltol` / `abstol`.
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
        input = load_path(input; metaparameters=metaparameters)
    end
    if input isa AbstractDict
        input = load_document(input; base_path=base_path, metaparameters=metaparameters)
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
# Callback composition seam — the `CallbackSet` constructor lives in
# EarthSciASTSimulateExt (SciMLBase), exactly like the callback CONSTRUCTORS
# live in the DiffEqCallbacks extensions. A problem with zero or one callback
# composes without SciMLBase at all; two or more can only have come from those
# extensions, so SciMLBase is loaded by then and the extension method wins.
# --------------------------------------------------------------------------- #
function _callback_set end
_callback_set(cbs) = throw(SimulateError(
    "composing $(length(cbs)) problem-level callbacks needs the SciMLBase extension; " *
    "add `using SciMLBase` so EarthSciASTSimulateExt is active"))

_compose_callbacks(cbs::AbstractVector) =
    isempty(cbs) ? nothing : length(cbs) == 1 ? cbs[1] : _callback_set(cbs)

# --------------------------------------------------------------------------- #
# Internal solve bridge, for the CORE-RESIDENT callers that have to run a
# problem themselves — today only the inline-test engine (`run_pde_tests`),
# which lives in this package and is handed an `alg` by its caller. It is NOT a
# second public entry point beside `solve`: the extension implements it BY
# calling `SciMLBase.solve(prob, alg; …)`, so there is exactly one solve path.
# --------------------------------------------------------------------------- #
function _solve_problem end
_solve_problem(prob, alg; kwargs...) = throw(SimulateError(
    alg === nothing ?
    "solving an ESMProblem needs an ODE algorithm: pass `alg = Tsit5()` " *
    "(and `using OrdinaryDiffEqTsit5`)" :
    "solving an ESMProblem needs the SciMLBase extension; add `using SciMLBase` " *
    "plus a solver (e.g. OrdinaryDiffEqTsit5) so EarthSciASTSimulateExt is active"))

# --------------------------------------------------------------------------- #
# ESMProblem — the run-ready artifact, built exactly once per document.
#
# Everything deterministic-per-document (load → flatten → shape transforms →
# flattened_to_esm → build_evaluator) plus the run wiring that belongs to the
# document (the seeded initial state, the refresh / output / checkpoint
# callbacks) is done HERE, once. `solve(prob, alg; …)` then only varies the
# per-run knobs, and `remake(prob; p, u0, tspan)` substitutes without redoing
# anything the substitution cannot have invalidated.
# --------------------------------------------------------------------------- #

"""
    ESMProblem

The ESM simulation problem: the compiled tree-walk RHS `f!`, the seeded initial
state `u0`, the integration interval `tspan`, the parameter carrier `p`, the
`var_map`, the live forcing buffers, the discrete-provider/refresh scaffolding,
and the problem's own callback set — everything deterministic per document,
built exactly once by [`esm_problem`](@ref).

```julia
using EarthSciAST, OrdinaryDiffEqTsit5
prob = esm_problem("model.esm", (0.0, 1.0); p = Dict("M.k" => 2.5))
sol  = solve(prob, Tsit5())
sol.retcode                     # SciMLBase.ReturnCode.Success
sol[Symbol("M.y")]              # that state element's trajectory, BY NAME
prob2 = remake(prob; tspan = (0.0, 5.0))   # no re-load / re-flatten / re-build
```

Snapshot semantics: the input document is fully parsed and compiled at
construction, so mutations to the input (e.g. editing the `Dict` you passed)
afterwards are NOT seen. Forcing arrays (`const_arrays` / `param_arrays`) are
the exception by design: they are captured BY REFERENCE (the live-buffer
refresh contract), not copied.

Repeated runs are independent: `u0` is copied per run, and discrete forcing
buffers are re-seeded from their providers at each run's `t0` (with the
[`DiscreteMaterializer`](@ref) caches recomputed) whenever a previous run may
have refreshed them or the start time changed.

Parameter overrides split by CLASS (see [`parameter_classes`](@ref)):
`:numeric` ones may be passed to `remake(prob; p = …)` and are applied by
swapping `p` (cheap, and AD-transparent — no rebuild). `:structural`,
`:const_folded` and `:forcing` ones throw: their values were consumed at BUILD
time (or never reach `p` at all), so call [`esm_problem`](@ref) again.

Fields are an extension seam, not stable API; `var_map`, `p`, `u0`, `tspan`
and `output_meta` are the ones downstream code reads.
"""
struct ESMProblem
    f!::Function                          # compiled tree-walk RHS (in-place)
    u0::Vector{Float64}                   # seeded initial state; COPIED per run
    tspan::Tuple{Float64,Float64}         # integration interval
    p::Any                                # parameter NamedTuple (or nothing)
    var_map::Dict{String,Int}             # state-element name → flat index
    param_buffers::Dict{String,Any}       # live forcing buffers, aliased into f!
    discrete_providers::Dict{String,Any}  # forcing var → DISCRETE data Provider
    dm::DiscreteMaterializer              # discrete-cadence cache sink (may be empty)
    n_equations::Int                      # flattened equation count (display only)
    buffer_time::Base.RefValue{Float64}   # t the discrete buffers currently hold
    dirty::Base.RefValue{Bool}            # true once a run may have refreshed them
    output_meta::OutputMeta               # doc-derived output naming/CF metadata (RFC §7–§8)
    # The prepared (flattened, single-model) RUN DOCUMENT the evaluator was
    # built from — the carrier [`observed_field`](@ref) resolves shapes and
    # index sets against, so a caller can read build-time observeds through the
    # PUBLIC problem surface instead of re-running the document pipeline.
    run_doc::Dict{String,Any}
    run_file::Base.RefValue{Any}          # lazy coerce_esm_file(run_doc) memo
    # The parameter PARTITION this build produced (see `parameter_classes`):
    # name → `:numeric` / `:structural` / `:const_folded` / `:forcing`. Derived
    # from what the build-time consumers actually READ, which is what decides
    # whether an override can ride `p` at solve time or needs a rebuild.
    param_classes::Dict{String,Symbol}
    # Build observability, owned by the PROBLEM (§5.8: `observed_field(prob,
    # name)` is two arguments). The caller no longer threads a `BuildInspection`
    # through construction and back into the accessor; one is always allocated
    # here, and a caller that wants to inspect it passes its own via `inspect`.
    inspection::BuildInspection
    # The problem's callback set (§2.5.4). Composed at CONSTRUCTION from the
    # data-refresh, output-sink and checkpoint callbacks, because a callback
    # that refreshes provider buffers or writes an output stream belongs to the
    # document, not to a particular run's tolerances. `solve(prob; callback=…)`
    # REPLACES it entirely; read it back with [`callbacks`](@ref) to extend.
    callback::Any
    tstops::Vector{Float64}               # refresh ∪ output anchors
    save_everystep::Bool                  # false once a sink owns the trajectory
    sinks::Vector{Any}                    # diagnostic sinks
    lifecycle_sinks::Vector{Any}          # distinct sinks to open!/close! per run
    symcache::Base.RefValue{Any}          # lazy SymbolicIndexingInterface cache
end

function Base.show(io::IO, prob::ESMProblem)
    np = prob.p === nothing ? 0 : length(prob.p)
    print(io, "ESMProblem(", length(prob.u0), " state elements, ",
          prob.n_equations, " equations, ", np, " parameters, tspan=", prob.tspan)
    isempty(prob.discrete_providers) ||
        print(io, ", ", length(prob.discrete_providers), " discrete forcings")
    prob.callback === nothing || print(io, ", callbacks")
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
    esm_problem(input, tspan; p=Dict(), u0=nothing, kwargs...) -> ESMProblem

Build the ESM simulation problem for `input` over `tspan = (t0, t1)` — the one
noun of esm-libraries-spec §2.5. Construction runs everything deterministic per
document ONCE (coerce `input` to a runnable document: load → flatten → shape
transforms; materialize provider fields; build the tree-walk evaluator; seed the
initial state; compose the problem's callbacks) and returns an
[`ESMProblem`](@ref) that `solve` integrates as often as you like.

`input` may be a path to an `.esm` file, a native ESM `Dict`, a loaded
[`EsmFile`](@ref), or a [`FlattenedSystem`](@ref). The first three are AUTHORED
documents and are FLATTENED, so every name below (and every solution index) is
the flattener's namespaced one — `"Chem.A"`, not `"A"`. Only a
`FlattenedSystem` skips the flattener, that being the type whose whole meaning
is "already flattened". **Snapshot semantics**: the document is fully parsed
here, so mutating `input` afterwards does not affect the problem (forcing arrays
are aliased by design; see [`ESMProblem`](@ref)).

Stable keyword arguments (API_SPEC §5.8 — the bindings that fix a DOCUMENT):

* `p::AbstractDict` — parameter overrides. Baked into the build (they feed
  build-time constant folding), which is why EVERY class of parameter can be set
  here — including the `:structural` ones a `remake` must refuse (see
  [`parameter_classes`](@ref)). A purely `:numeric` change need not rebuild:
  pass it to `remake(prob; p = …)`, which swaps `p`. Keys may be spelled LOCALLY
  (`pert_amp`, the form esm-spec §6.6 pins for a test's `parameter_overrides`)
  or with the flattener's namespacing (`Chem.pert_amp`); both resolve to the
  same parameter. The resolved values also bind the BUILD-TIME evaluation scope
  (esm-spec §6.6.5): a coordinate-expression `ic` and an inline assertion
  `reference` see the override, not the declared default.
* `u0` — the initial state. Either an `AbstractDict` of per-element or broadcast
  overrides applied on top of the document's own initial conditions (keys spelled
  `"M.y"`, `"M.f[1,2]"`, or a bare array name `"M.f"` broadcasting one value over
  every cell), or an `AbstractVector` replacing the seeded vector outright.
* `providers::AbstractDict` — `<Loader>.<var> => data Provider`, the loaded-data
  injection seam. CONST providers ([`provider_is_const`](@ref)) are materialized
  once at build time into `const_arrays` under their loader variable name — so a
  scoped-reference `ic(Sys.sp) ~ Model.param` folds the seeded field into `u0`
  and a loader→consumer `variable_map` binding resolves the consumer gather from
  it. DISCRETE providers get a live buffer plus a [`build_refresh_callback`](@ref)
  on the problem, so their forcing refreshes in place at its cadence.
* `model_name` — select one model when the document holds several.
* `metaparameters::AbstractDict` — binds the document's open metaparameters at
  the loader API (esm-spec §9.7.6 binding site 3), exactly as
  [`load_path`](@ref)`(path; metaparameters=…)` does. Pass them HERE rather than
  pre-`load`ing, so a loader that discovers its own extent can close one first
  (below); a caller binding that CONTRADICTS a discovered extent is an error.
* `base_path::AbstractString = pwd()` — the directory a native `Dict` input's
  relative `{ref}`s resolve against (a path input anchors them at its own
  directory).
* `sample_time::Real = tspan[1]` — the `t` at which providers are sampled for
  the build. A CONST provider is time-invariant by contract; DISCRETE buffers
  seeded here are re-seeded at each run's `t0` anyway.

Julia extension-seam keywords (§2.5.2 explicitly allows these; NOT stable API):
`const_arrays`, `param_arrays` (forwarded to [`build_evaluator`](@ref) — the
regridder source polygons and the live forcing buffers), `inspect` (share the
problem's [`BuildInspection`](@ref) with the caller), `materialize_out` (a
caller-owned [`DiscreteMaterializer`](@ref)), `pushdown_rewrite`, `seed_ic!`
(an `(u0, var_map) -> nothing` hook for array ICs that need grid geometry; runs
after `u0`, see [`seed_expression_ic!`](@ref)), and the streaming-output set
`sinks` / `snapshot` / `pre_write` / `checkpoint_predicates` /
`checkpoint_sinks` / `terminate_on_checkpoint`.

`pushdown_rewrite::Bool = false` opts in to the automatic projection-pushdown
desugar ([`desugar_pushdown`](@ref)) at the PUBLIC entry point. The rewrite runs
on the authored document BEFORE flattening (the pattern is authored in the
un-namespaced model), and the engine then derives every provider gate from the
rewrite's own `metadata.x_esd.pushdown` record: a `providers` entry that the
document's coupling routes onto a rewritten array is DEFERRED and fetched
pre-sliced to the invented support set — the caller hand-authors no gate dict.

**Callbacks** (§2.5.4). A discrete provider contributes a refresh callback, a
non-empty `sinks` an output callback, and non-empty `checkpoint_predicates` a
checkpoint callback; they are composed into ONE callback set on the problem.
Read it back with [`callbacks`](@ref). A `callback` argument to `solve`
REPLACES it entirely — it does not append, merge, or wrap:

```julia
solve(prob, Tsit5(); callback = CallbackSet(callbacks(prob), my_extra))
```

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

Per-RUN knobs (`alg`, `abstol`, `reltol`, `saveat`, `callback`, `maxiters`)
belong to `solve(prob, alg; …)`; §2.5.9 keeps the solver out of construction, so
this call needs neither SciMLBase nor an OrdinaryDiffEq package.
"""
function esm_problem(input, tspan;
                     p::AbstractDict = Dict{String,Float64}(),
                     u0 = nothing,
                     providers::Union{Nothing,AbstractDict} = nothing,
                     model_name::Union{Nothing,AbstractString} = nothing,
                     metaparameters::AbstractDict = Dict{String,Int}(),
                     base_path::AbstractString = pwd(),
                     sample_time::Union{Nothing,Real} = nothing,
                     # ---- Julia extension seam (§2.5.2) ----
                     const_arrays::AbstractDict = Dict{String,Any}(),
                     param_arrays::AbstractDict = Dict{String,Any}(),
                     inspect::Union{Nothing,BuildInspection} = nothing,
                     materialize_out::Union{Nothing,DiscreteMaterializer} = nothing,
                     pushdown_rewrite::Bool = false,
                     seed_ic! = nothing,
                     sinks = (),
                     snapshot = state_snapshot,
                     pre_write = () -> nothing,
                     checkpoint_predicates = (),
                     checkpoint_sinks = nothing,
                     terminate_on_checkpoint::Bool = true)
    span = (Float64(tspan[1]), Float64(tspan[2]))
    t_sample = sample_time === nothing ? span[1] : Float64(sample_time)
    # ---- extent discovery: a loader that measures its OWN record count ------
    # FIRST, because a discovered extent CLOSES a metaparameter and every load
    # below binds metaparameters at the loader API (esm-spec §9.7.6 site 3). The
    # sampled arrays are kept and reused at injection, so a 69 MB FF10 zip is
    # decoded once, not once here and again there.
    metaparams, discovered = _discover_loader_extents(providers, metaparameters, t_sample)
    # `load` is where a metaparameter closes, so an ALREADY-loaded carrier has
    # closed them — silently ignoring a binding (the caller's or a loader's) is
    # exactly the failure this seam exists to prevent.
    if !isempty(metaparams) && !(input isa AbstractString || input isa AbstractDict)
        why = isempty(discovered) ? "" :
              string(". ", join(sort!(collect(keys(discovered))), ", "),
                     " DISCOVERED its own extent, which only a not-yet-loaded ",
                     "document can be sized by")
        throw(SimulateError(
            "esm_problem: metaparameters $(sort!(collect(keys(metaparams)))) must be bound " *
            "at the loader API, but `input` is a $(typeof(input)) whose metaparameters " *
            "are already closed — pass the path or the native Dict to esm_problem (and drop " *
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
                    (isfile(input) || throw(SimulateError("esm_problem: no such file '$input'"));
                     load_path(input; metaparameters=metaparams)) :
                input isa AbstractDict ? load_document(input; base_path=base_path,
                                                       metaparameters=metaparams) :
                throw(SimulateError(
                    "esm_problem: pushdown_rewrite=true needs a path, native Dict, or " *
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

    overrides = Dict{String,Float64}(String(k) => Float64(v) for (k, v) in p)

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
                merged_const[k] = _provider_const_field(provider_sample(prov, t_sample), k)
            else
                # DISCRETE: allocate a LIVE forcing buffer seeded at the initial tick
                # and register it in `param_arrays`. That makes the loader field a
                # `live_param`, so the setup partition (`_geometry_setup_vars`) taints
                # any in-model regrid over it: `F_tgt = A_ij ⊗ F_src / A_j` keeps its
                # overlap WEIGHTS at setup but stays a runtime observed / discrete-
                # materialized cache, instead of a build-once setup const where the
                # (still-unbound) live `F_src` would fail. The refresh callback then
                # rewrites this SAME buffer in place at each cadence tick.
                merged_param[k] = _provider_const_field(provider_sample(prov, t_sample), k)
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
    # Build observability is a CONSTRUCTION-time seam now (§5.8): the problem
    # always owns a `BuildInspection`, so `observed_field(prob, name)` is two
    # arguments. A caller that wants to read the sink itself passes its own.
    insp = inspect === nothing ? BuildInspection() : inspect
    # The parameter partition sink (differentiability plan §3 Phase 5): the build
    # fills it with name → `:numeric` / `:structural` / `:const_folded` /
    # `:forcing`, derived from which names its BUILD-TIME consumers read. It is
    # what lets `remake(prob; p = …)` accept the numeric half instead of refusing
    # every override.
    param_classes = Dict{String,Symbol}()
    f!, u0_built, p_built, _tspan, var_map = build_evaluator(doc;
        model_name = model_name,
        parameter_overrides = overrides,
        const_arrays = merged_const,
        param_arrays = merged_param,
        inspect = insp,
        materialize_out = dm,
        _param_classes = param_classes,
        # Phase 2b Hook 2: deferred gated providers + the build-time sample tick.
        # The front door fetches these pre-sliced right after value-invention.
        _gated_providers = gated_providers,
        _sample_time = t_sample)

    # ---- initial state: the document's own ICs, then the caller's -----------
    u0_run = _seed_u0(u0_built, var_map, u0, seed_ic!)

    # ---- the problem's callback set (§2.5.4) --------------------------------
    # Composed HERE, at construction, because a callback that refreshes provider
    # buffers or writes an output stream belongs to the DOCUMENT, not to a
    # particular run's tolerances. `solve(prob; callback=…)` replaces the whole
    # set; `callbacks(prob)` reads it back so a caller can extend explicitly.
    cbs = Any[]
    tstops = Float64[]
    if !isempty(discrete_providers)
        cb, ts = build_refresh_callback(;
            providers = discrete_providers,
            buffers = RefreshBuffers(merged_param),
            post_refresh = dm.materialize!)   # recompute discrete caches per boundary
        push!(cbs, cb)
        tstops = _union_tstops(tstops, ts)
    end
    # Streaming output sinks (streaming-output-sinks RFC §16.5). When any sink is
    # present, build the output callback and UNION its output tstops into the
    # refresh tstops (so input-refresh and output-write stop the solver at the
    # union of their anchors). `save_everystep=false` then tells the solver to
    # stop accumulating the dense RAM trajectory — the sink IS the trajectory
    # store. With no sinks nothing here fires and the solve is unchanged.
    sink_vec = collect(Any, sinks)
    save_everystep = true
    if !isempty(sink_vec)
        out_cb, out_tstops = build_output_callback(;
            sinks = sink_vec, snapshot = snapshot, pre_write = pre_write)
        tstops = _union_tstops(tstops, out_tstops)
        push!(cbs, out_cb)
        save_everystep = false
    end
    # Predicate-driven checkpointing (streaming-output-sinks RFC §10, §16.7). When
    # `checkpoint_predicates` is non-empty, compose a `DiscreteCallback` that writes a
    # full-state checkpoint to `checkpoint_sinks` (default: `sinks`) + flushes the
    # durable barrier the instant any predicate (SLURM walltime, spot notice, custom)
    # fires, optionally terminating for a clean pre-preemption exit. Interval-only
    # checkpointing needs none of this — a checkpoint-profile sink's cadence rides the
    # ordinary output callback above.
    ck_vec = checkpoint_sinks === nothing ? sink_vec : collect(Any, checkpoint_sinks)
    if !isempty(collect(Any, checkpoint_predicates))
        ck_cb = build_checkpoint_callback(;
            sinks = ck_vec, predicates = checkpoint_predicates, snapshot = snapshot,
            pre_write = pre_write, terminate_on_fire = terminate_on_checkpoint)
        push!(cbs, ck_cb)
        save_everystep = false
    end

    return ESMProblem(f!, u0_run, span, p_built, var_map, merged_param,
                      discrete_providers, dm, _doc_equation_count(doc),
                      Ref(t_sample), Ref(false), derive_output_meta(doc), doc,
                      Ref{Any}(nothing), param_classes, insp,
                      _compose_callbacks(cbs), tstops, save_everystep,
                      sink_vec, _distinct_sinks(sink_vec, ck_vec), Ref{Any}(nothing))
end

# The seeded initial state: the build's own `u0`, then the caller's `u0`
# argument (a Dict of per-element / broadcast overrides, or a whole vector),
# then the `seed_ic!` hook. Always a fresh vector — the build's `u0` is never
# mutated, so `remake(prob; u0 = …)` cannot disturb the problem it came from.
function _seed_u0(u0_built::Vector{Float64}, var_map::AbstractDict, u0, seed_ic!)
    out = copy(u0_built)
    if u0 isa AbstractDict
        isempty(u0) || _apply_initial_conditions!(out, var_map, u0)
    elseif u0 isa AbstractVector
        length(u0) == length(out) || throw(SimulateError(
            "u0 has $(length(u0)) elements but the flattened state vector has " *
            "$(length(out)); pass a Dict of named overrides to set a subset"))
        out = collect(Float64, u0)
    elseif u0 !== nothing
        throw(SimulateError(
            "u0 must be an AbstractDict of named overrides or an AbstractVector " *
            "replacing the whole state, got a $(typeof(u0))"))
    end
    seed_ic! === nothing || seed_ic!(out, var_map)
    return out
end

"""
    observed_field(prob::ESMProblem, name) -> Array

Evaluate the state-free observed `name` at BUILD time through the problem's own
graph — the public face of the build-observability path (`_observed_field`).

Two arguments (API_SPEC §5.8): build observability moved to a construction-time
seam, so the caller no longer threads the same [`BuildInspection`](@ref) through
the build and back into this accessor — the problem owns one. Pass your own via
`esm_problem(...; inspect = insp)` if you also want to read the sink directly.

`name` may be spelled with the flattener's namespacing (`"ISRM.deathsK"`) or
locally (`"deathsK"`, resolved against the single run model's variable tails).

Throws a `SimulateError` when `name` is not a build-time-evaluable observed
(state-dependent, unsized axis, or not an observed at all).
"""
function observed_field(prob::ESMProblem, name::AbstractString)
    insp = prob.inspection
    if prob.run_file[] === nothing
        prob.run_file[] = coerce_esm_file(prob.run_doc)
    end
    file = prob.run_file[]::EsmFile
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
# discrete-materialized caches, so every run starts from freshly initialized
# refresh state — a previous run's callback mutates the buffers in place, and a
# different start time needs a different initial tick. Skipped when the buffers
# are pristine and already hold the sample at t0 (the first solve of a problem
# built at that t0 — no double sample). Called from the solve/init seam, which
# is the only place that knows a run is starting.
function _prepare_run!(prob::ESMProblem, t0::Float64)
    isempty(prob.discrete_providers) && return nothing
    if prob.dirty[] || prob.buffer_time[] != t0
        for (k, prov) in prob.discrete_providers
            buf = prob.param_buffers[k]::Array{Float64}
            _write_forcing!(buf, k, provider_sample(prov, t0))
        end
        prob.dm.materialize!()   # discrete caches must see the re-seeded buffers
        prob.buffer_time[] = t0
    end
    prob.dirty[] = true          # this run's refresh callback will mutate them
    return nothing
end

"""
    parameter_classes(prob::ESMProblem) -> Dict{String,Symbol}

The parameter partition of the build behind `prob` — `:numeric`, `:structural`,
`:const_folded`, `:forcing`. See the [`parameter_classes`](@ref) docstring on the
[`BuildInspection`](@ref) method for what each class means and how it is derived.
"""
parameter_classes(prob::ESMProblem) = prob.param_classes

# A readable name list for an error: a real model carries dozens of parameters
# and dumping all of them buries the diagnostic that matters.
function _elide_names(ns::AbstractVector{String}, n::Int = 12)
    length(ns) <= n && return join(ns, ", ")
    return join(ns[1:n], ", ") * ", … ($(length(ns)) total; see parameter_classes(prep))"
end

# One override's refusal message, naming the parameter AND its class AND why the
# class cannot ride `p`. Each class fails for a different reason, and saying
# which is the whole point of the partition: "parameters bake at build time"
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
        "supply a different provider / write `prob.param_buffers[\"$name\"]`" :
        "call esm_problem(input, tspan; p = Dict(\"$name\" => …)) again — a " *
        "structural change is an explicit rebuild, never something hidden " *
        "inside a `p` swap"
    return "remake(prob::ESMProblem; p): '$name' is $what. " *
           "To change it, $fix."
end

"""
    remake_parameters(prob::ESMProblem, overrides) -> p

The parameter carrier `prob.p` with the `:numeric` `overrides` applied — the
value `remake(prob; p = overrides)` installs, exposed on its own as a tier-2
extension seam for callers that drive `SciMLBase.remake` on their own problem.

```julia
prob2 = remake(prob; p = Dict("Emis.scale" => 2.0))          # the stable path
p2    = remake_parameters(prob, Dict("Emis.scale" => 2.0))   # the seam
```

This is deliberately a `p` SWAP and nothing more: `remake` exists precisely so a
sensitivity analysis can vary `p` without rebuilding `f`, and overloading it to
re-run the build would make gradients impossible by construction. So it is cheap
(a `NamedTuple` merge, no build), and AD-transparent — each override keeps its
own type, so a `ForwardDiff.Dual` handed in here stays a `Dual` in `p` and
`∂(solution)/∂(parameter)` flows through the same compiled RHS.

Only `:numeric` parameters can be swapped. A `:structural`, `:const_folded` or
`:forcing` override throws a [`SimulateError`](@ref) naming the parameter and its
class — changing one of those is an explicit rebuild, because it changes the
build, not just a number the build reads. Keys may be spelled locally
(`"scale"`) or namespaced (`"NEIRegrid.scale"`), exactly as `esm_problem`'s `p`
overrides are; an unknown or ambiguous key throws rather than being dropped.
"""
function remake_parameters(prob::ESMProblem, overrides::AbstractDict)
    isempty(overrides) && return prob.p
    classes = prob.param_classes
    pm = param_map(prob.p)
    names = Set{String}(keys(classes))
    union!(names, keys(pm))
    normalized, unknown, ambiguous =
        _canonicalize_override_keys(Any, names, overrides)
    isempty(unknown) || throw(SimulateError(
        "remake(prob; p): no parameter named " *
        join(("'" * k * "'" for k in sort(unknown)), ", ") *
        " in the problem (keys may be local or namespaced; a name the " *
        "flattener's coupling rewired onto a loader variable is spelled by its " *
        "SURVIVING name). Known: " * _elide_names(sort(collect(names)))))
    isempty(ambiguous) || throw(SimulateError(
        "remake(prob; p): ambiguous parameter key(s) " *
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
            "remake(prob; p): '$name' classifies :numeric but is not a " *
            "slot of the problem's `p` — refusing to apply an override that would " *
            "have no effect (this is a build bug; please report it)."))
        push!(syms, Symbol(name))
        push!(vals, normalized[name])
    end
    # `merge` keeps the FIRST tuple's key order, which is the build's own
    # parameter order (`param_map`) and the order every `_NK_PARAM` node's `idx`
    # was minted against. Values keep their own types (a `Dual` stays a `Dual`).
    return merge(prob.p, NamedTuple{Tuple(syms)}(Tuple(vals)))
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

# Sentinel for "the caller did not pass `callback`" — `nothing` is a MEANINGFUL
# value there (§2.5.4: an explicit `callback` replaces the problem's set, and
# replacing it with nothing is exactly how a caller drops it).
struct _KeepCallbacks end
const _KEEP_CALLBACKS = _KeepCallbacks()

"""
    callbacks(prob::ESMProblem)

The problem's own callback set — the composition of its data-refresh, output-sink
and checkpoint callbacks, or `nothing` when it has none.

Stable API in every simulation-capable binding, for one reason (§2.5.4): a
`callback` argument to `solve` **REPLACES** this set entirely — it does not
append, merge, or wrap. Silent composition is the more dangerous default (two
callbacks both writing output, or both mutating the same buffer, produce a wrong
run rather than an error), so a caller who wants to EXTEND reads the set back
and composes explicitly:

```julia
solve(prob, Tsit5(); callback = CallbackSet(callbacks(prob), my_extra_callback))
```
"""
callbacks(prob::ESMProblem) = prob.callback

"""
    remake(prob::ESMProblem; p, u0, tspan, callback) -> ESMProblem

A NEW problem with the named substitutions applied and everything else SHARED
(esm-libraries-spec §2.5.5). It does not mutate `prob`, and it does not redo the
parts of construction the substitution cannot have invalidated: a changed
parameter value does not re-fetch provider data and does not recompile the
right-hand side.

* `p` — an `AbstractDict` of overrides (resolved and class-checked by
  [`remake_parameters`](@ref)) or a ready-made parameter carrier to install
  verbatim.
* `u0` — an `AbstractDict` of per-element / broadcast overrides applied on top of
  this problem's seeded state, or an `AbstractVector` replacing it outright.
  Always applied to a COPY, so `prob`'s own `u0` is untouched.
* `tspan` — a new `(t0, t1)`.
* `callback` — replace the problem's callback set (§2.5.4). Omit to keep it.

Refusal behaviour is preserved from `remake_parameters`: a substitution the
problem cannot honour without a rebuild raises, naming the parameter AND the
class that makes it un-substitutable (`:structural`, `:const_folded`,
`:forcing`), rather than silently rebuilding or silently ignoring it.

`EarthSciAST.remake` and `SciMLBase.remake` are the same function on an
`ESMProblem`: the SciMLBase extension forwards the canonical spelling here, so
`remake(prob; …)` works from a session that has `using OrdinaryDiffEq` without
EarthSciAST exporting a second `remake` into the conflict.
"""
function remake(prob::ESMProblem; p = nothing, u0 = nothing, tspan = nothing,
                callback = _KEEP_CALLBACKS)
    p_new = p === nothing ? prob.p :
            p isa AbstractDict ? remake_parameters(prob, p) : p
    u0_new = u0 === nothing ? copy(prob.u0) :
             _seed_u0(prob.u0, prob.var_map, u0, nothing)
    span = tspan === nothing ? prob.tspan : (Float64(tspan[1]), Float64(tspan[2]))
    cb = callback === _KEEP_CALLBACKS ? prob.callback : callback
    # The symbol cache is a function of `var_map` and the `p` NAMES, neither of
    # which a Dict-driven swap can change — so it is shared. A verbatim carrier
    # could carry different names, so that path gets a fresh (lazy) slot.
    sc = (p === nothing || p isa AbstractDict) ? prob.symcache : Ref{Any}(nothing)
    return ESMProblem(prob.f!, u0_new, span, p_new, prob.var_map,
                      prob.param_buffers, prob.discrete_providers, prob.dm,
                      prob.n_equations, prob.buffer_time, prob.dirty,
                      prob.output_meta, prob.run_doc, prob.run_file,
                      prob.param_classes, prob.inspection, cb, prob.tstops,
                      prob.save_everystep, prob.sinks, prob.lifecycle_sinks, sc)
end
