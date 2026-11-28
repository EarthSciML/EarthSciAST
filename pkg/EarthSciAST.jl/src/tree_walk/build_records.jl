# tree_walk/build_records.jl — the records a build hands back: `BuildInspection`, `BuildProducts`,
# `DiscreteMaterializer`, `RecurrenceInfo` and the per-Problem observed memo; and
# `_CompileScope`, what one build stage resolves and compiles against; and the
# records the build phases hand one another.

# The start-of-run scope the `ic` right-hand sides were evaluated in
# (build_initial_state.jl): `t0`, the scalars and the arrays, and whether the
# initial state depends on the start.
struct _IcStart
    t0::Float64
    scalars::Dict{String, Float64}
    arrays::Dict{String, Any}
    reads_start::Bool
end

# What evaluating the `ic` right-hand sides at a start of the run needs, and
# nothing more of the build: worked out once, at construction, from the model
# and the build's scopes, and kept by a Problem whose initial state moves with
# its start (`_IcReseed`), so it holds the cone the `ic`s read rather than the
# build environment it was taken from.
struct _IcPlan
    # The `ic` right-hand sides: scalar targets, and array ones with `t` bound
    # to the start (`_ic_bind_start_time`).
    scalar_ics::Vector{Tuple{String, ASTExpr}}
    field_ics::Vector{Tuple{String, ASTExpr}}
    # The scalar parameters, at their values for this build.
    params::Dict{String, Float64}
    # The build's arrays the cone reads, and the data-fed parameters it reads
    # at their construction-time value (the ones `ic_data` does not replace).
    arrays::Dict{String, Any}
    live::Dict{String, Any}
    scalar_live::Set{String}
    # The observeds the cone reads, in dependency order: name, body with `t`
    # bound, and its extents (`nothing` for a scalar one).
    order::Vector{Tuple{String, ASTExpr, Union{Nothing, Vector{Int}}}}
    # The unknowns a scalar `ic` right-hand side reads, for its diagnostic.
    unknowns::Set{String}
    reads_start::Bool
end


# ---- The phase records ----
#
# What each build phase hands the next (build_pipeline.jl). Phase 1
# (`_build_lower_and_classify`) classifies the variables, phase 2
# (`_build_partition_and_materialize`) partitions them and rewrites the
# equation stream, phase 3 (`_build_state_layout`) lays out the state, and
# phase 4 compiles against all three.

# Phase 1: the pre-lowered equations and which mechanism owns each array
# observed that carries no ODE partition slot.
struct _VariableClasses
    equations::Vector{Equation}
    # Elementwise array observeds folded into their readers.
    folded_array_obs::Set{String}
    # Build-once setup arrays, with their definitions.
    geom_setup_vars::Set{String}
    geom_defs::Dict{String, ASTExpr}
    # Array observeds inlined into their readers: live-field geometry ones and
    # promoted ones.
    geom_inline_vars::Set{String}
    array_inline_vars::Set{String}
    # Array observeds filled into a cache once per forcing refresh.
    discrete_vars::Set{String}
    # Array observeds whose value is build-time data, with that data.
    const_obs_vars::Set{String}
    const_obs_arrays::Dict{String, Array{Float64}}
    # The promoted array observeds filled into a buffer per right-hand-side
    # call (a subset of `array_inline_vars`, recurrences included); phase 3
    # narrows it to the ones whose extents resolve.
    mat_array_vars::Set{String}
    # Gated live-field geometry observeds moved onto the buffered path.
    gated_geom_vars::Set{String}
end

# The mechanism that owns `name` when it carries no ODE partition slot, by the
# order in which the build settles ownership; `nothing` for a variable the
# partition places (a state, a scalar parameter or observed, or an array
# parameter backed by data). `vi_vars` are the value-invention outputs, which
# are materialized at setup before the build runs.
function _partition_owner(cls::_VariableClasses, vi_vars::Set{String}, name::String)
    name in vi_vars && return :value_invention
    name in cls.geom_setup_vars && return :setup_array
    name in cls.geom_inline_vars && return :inlined_geometry
    name in cls.array_inline_vars && return :inlined_array
    name in cls.discrete_vars && return :discrete_cache
    name in cls.folded_array_obs && return :folded_observed
    name in cls.const_obs_vars && return :const_data
    return nothing
end

# Phase 2: the ODE partition, the parameter scope, the setup arrays and the
# rewritten equation stream.
struct _EquationPartition
    param_names::Vector{String}
    observed_names::Vector{String}
    state_var_names::Set{String}
    param_scope::Dict{String, Float64}
    geom_setup_arrays::Dict{String, AbstractArray{Float64}}
    derived_extents::Dict{String, Int}
    equations::Vector{Equation}
    discrete_defs::Dict{String, ASTExpr}
    eq_ics::Dict{String, Float64}
    field_ics::Vector{Tuple{String, ASTExpr}}
    ic_start::_IcStart
    ic_plan::_IcPlan
    # The initialization system (esm-spec §11.4.3), its seeds range-resolved.
    ic_system::_IcSystem
end

# Phase 3: the state layout, the initial state and the parameter tuple.
struct _StatePlan{P, R}
    u0::Vector{Float64}
    p::P
    # The ODE layout (the public `var_map`), each array state's cell bounds, and
    # each scalar parameter's position in `p`.
    var_map::StateLayout
    array_var_info::Dict{String, Tuple{Vector{Int}, Vector{Int}}}
    param_index::Dict{Symbol, Int}
    # The layout extended with one block per materialized array observed, and
    # those observeds' extents.
    var_map_ext::StateLayout
    array_var_info_ext::Dict{String, Tuple{Vector{Int}, Vector{Int}}}
    mat_dims::Dict{String, Vector{Int}}
    # The initial state at another start of the run (`_IcReseed`), or
    # `nothing` when it does not depend on the start.
    ic_reseed::R
end
_n_states(L::_StatePlan) = length(L.var_map)
_n_total(L::_StatePlan) = length(L.var_map_ext)

# `parts` with its equation stream replaced (a range-restricted program clips it).
_with_equations(parts::_EquationPartition, equations::Vector{Equation}) =
    _EquationPartition(
    parts.param_names, parts.observed_names, parts.state_var_names, parts.param_scope,
    parts.geom_setup_arrays, parts.derived_extents, equations,
    parts.discrete_defs, parts.eq_ics, parts.field_ics, parts.ic_start, parts.ic_plan,
    parts.ic_system
)

# The observed substitution split (`_split_observed_and_derivatives`): the
# derivative equations, each inlined observed's definition with every observed
# it reads substituted (`resolved`) and as authored (`raw`), and the
# definitions of the materialized array observeds (`materialized`).
struct _ObservedSplit
    derivatives::Vector{Equation}
    resolved::Dict{String, ASTExpr}
    raw::Dict{String, ASTExpr}
    materialized::Dict{String, ASTExpr}
end

"""
    _CompileScope

What an expression resolves (`_resolve_in`) and compiles (`_compile_in`) against
in one build stage: each array's cell bounds (`array_var_info`) and the slot
layout (`var_map`), the build-time arrays (`const_registry`), the live forcing
buffers and discrete caches (`pgather`, name => `_PGatherArray`), and each scalar
parameter's position in `p` (`param_index`). A build makes two: the state-only
scope, which construction-time fills and output-time reads use, and the
right-hand side's, whose layout adds a block per materialized array observed
(`_extend_scope`).
"""
struct _CompileScope{L <: AbstractDict{String, Int}, C <: AbstractDict, G <: AbstractDict}
    array_var_info::Dict{String, Tuple{Vector{Int}, Vector{Int}}}
    var_map::L
    const_registry::C
    pgather::G
    param_index::Dict{Symbol, Int}
end

# A resolve against `s`, with no names bound.
_resolve_ctx(s::_CompileScope, memo = nothing) =
    _ResolveCtx(s.array_var_info, s.var_map, s.const_registry, s.pgather, memo)

# `e` with its index operations resolved to slot, const and buffer reads.
_resolve_in(s::_CompileScope, e::ASTExpr, memo = nothing) = _resolve_indices(e, _resolve_ctx(s, memo))

# `e`, already resolved, compiled to a `_Node`.
_compile_in(s::_CompileScope, e::ASTExpr, memo = nothing) =
    _compile(e, s.var_map, s.param_index, memo)

# `s` with one block per `name => (lo, hi)` of `blocks` laid out after its slots.
function _extend_scope(s::_CompileScope, blocks::Vector{Pair{String, Tuple{Vector{Int}, Vector{Int}}}})
    isempty(blocks) && return s
    avi = copy(s.array_var_info)
    for (name, box) in blocks
        avi[name] = box
    end
    return _CompileScope(
        avi, _layout_extend(s.var_map, blocks), s.const_registry, s.pgather, s.param_index
    )
end

# One `observed_field` answer: the forcing epoch it was computed at
# (`_epoch_value`, cadence_stamp.jl) and the field. The field is state-free, so it moves only
# when a live buffer is refreshed in place. Kept per Problem (and shared by its
# `remake`s, which share its build).
struct _ObservedMemo
    epoch::UInt64
    value::Any
end

"""
    RecurrenceInfo

A recognized causal self-reference (esm-spec §4.3.1.1), as reported in
[`BuildInspection`](@ref)`.recurrences`:

* `var` — the (flattened) variable the recurrence defines;
* `axis` — the output index symbol the sweep folds along, ascending;
* `max_lag` — the largest lag along `axis` over the self-reads whose lag has a
  static upper bound, derived from the reads. A read whose lag has none (a
  parameter-valued offset, say) adds nothing, so `max_lag` bounds EVERY read
  only when `lag_proven` is `true`; when it is `false` the value is a bound over
  the bounded reads alone (0 if there are none), not the recurrence's lag;
* `lag_proven` — whether every self-read was proved strictly earlier at build.
  When `false`, some read's lag can be 0 or less for some value of a symbol, and
  the fail-closed self-read (`E_TREEWALK_RECUR_UNAVAILABLE`) rules those cells
  out at run time — typically a guard means they are never evaluated;
* `slices` — the number of positions along `axis`, each a slice the sweep
  completes before the next;
* `cells` — the number of cells the sweep publishes.

No evaluation rule depends on any of these.
"""
struct RecurrenceInfo
    var::String
    axis::String
    max_lag::Int
    lag_proven::Bool
    slices::Int
    cells::Int
end

"""
    BuildInspection()

Observability record for a build: pass one via [`esm_problem`](@ref)'s
`inspect` keyword and the build fills it with named BUILD-TIME products that
are otherwise internal to the evaluator closure:

* `setup_arrays::Dict{String,Array{Float64}}` — the materialized setup-time
  geometry arrays (RFC §8.1 / esm-spec §8.6.1), keyed by (flattened) observed
  name: the per-pair overlap-area matrix `A_ij`, its row-sums `A_j`, the
  normalized weights, and every other build-once geometry-derived array
  observed. This is the official inspection surface for conformance runners
  that gate per-pair regridding values (CONFORMANCE_SPEC §5.8) — the arrays
  are deliberately absent from the ODE partition, so no state/observed
  read can reach them.
* `const_arrays::Dict{String,Any}` — the full const-array registry as
  registered for the build: caller-supplied arrays, `const`-op array
  observeds, keyed-factor aliases and materialized setup arrays.
* `observed_exprs::Dict{String,ASTExpr}` — the resolved observed substitution
  map (post index-set-range resolution and observed-into-observed inlining),
  exactly as inlined into the compiled RHS.
* `params::Dict{String,Float64}` — the resolved SCALAR parameter values (the
  model defaults with any `parameter_overrides` applied), keyed by the
  (flattened) parameter name exactly as it appears in a compiled expression
  (`"Flattened.k"`). These are load-time CONSTANTS, so binding them into a
  build-time cellwise evaluation (`evaluate_cellwise`, §6.6.5 observed/
  reference assertions, `ic` seeding) is sound and determinism-safe — unlike
  STATE, which stays out of scope. Array-backed parameters live on
  `const_arrays`, not here (the scalar map stays homogeneous `Float64`).
* `param_classes::Dict{String,Symbol}` — the PARTITION of the declared
  parameters into `:numeric` (a scalar that lands in the runtime `p`),
  `:structural` (read at BUILD time, so its value can decide the shape of the
  problem), `:const_folded` (const data frozen into the build, never in `p`)
  and `:forcing` (a live buffer a discrete provider rewrites, never in `p`).
  Derived from what the build actually read, not from what the document
  declares — see [`parameter_classes`](@ref). This is the build-level face of the same
  partition `parameter_classes(prob)` exposes on an `EsmProblem`.
* `recurrences::Vector{RecurrenceInfo}` — one [`RecurrenceInfo`](@ref) per
  causal self-reference the build recognized (esm-spec §4.3.1.1): its axis,
  derived maximum lag, whether the lag was proved, and the sweep's size.
* `compiler_report::CompilerReport` — which tier every rule landed on (API_SPEC
  §5.8), the record [`compiler_report`](@ref) returns for this build. It is
  filled even when the build REFUSED, which leaves no Problem to read it off.

A record describes ONE build. It is filled when that build ends (a refused build
still fills `compiler_report`), and passing it to a second build raises an
`ArgumentError`. The entries are the build's own objects, not copies.

Filling the record never changes the build.
"""
mutable struct BuildInspection
    setup_arrays::Dict{String, Array{Float64}}
    const_arrays::Dict{String, Any}
    observed_exprs::Dict{String, ASTExpr}
    params::Dict{String, Float64}
    param_classes::Dict{String, Symbol}
    recurrences::Vector{RecurrenceInfo}
    compiler_report::CompilerReport
    # Whether a build has taken this record; a second one refuses it.
    taken::Bool
end
BuildInspection() = BuildInspection(
    Dict{String, Array{Float64}}(), Dict{String, Any}(), Dict{String, ASTExpr}(),
    Dict{String, Float64}(), Dict{String, Symbol}(), RecurrenceInfo[],
    CompilerReport(:native), false
)

# Claim `insp` for one build, refusing a record an earlier build took.
function _take_inspection!(insp::BuildInspection)
    insp.taken && throw(
        ArgumentError(
            "this BuildInspection already describes an earlier build; pass a fresh " *
                "BuildInspection() to each esm_problem call"
        )
    )
    insp.taken = true
    return insp
end

# Point the caller's record at what the build produced.
function _publish_inspection!(insp::BuildInspection, products)
    insp.setup_arrays = products.setup_arrays
    insp.const_arrays = products.const_arrays
    insp.observed_exprs = products.observed_exprs
    insp.params = products.params
    insp.param_classes = products.param_classes
    insp.recurrences = products.recurrences
    insp.compiler_report = products.compiler_report
    return insp
end

"""
    BuildProducts()

Everything one build produced besides the right-hand side, owned by the build
and by the `EsmProblem` made from it. Not exported: [`BuildInspection`](@ref)
is the public view of the first seven fields, and `EarthSciAST.Internal.build`
returns the whole record in its report.

The fields [`BuildInspection`](@ref) documents (`setup_arrays`, `const_arrays`,
`observed_exprs`, `params`, `param_classes`, `recurrences`, `compiler_report`),
and:

* `observed_defs` — each observed's definition BEFORE observed-into-observed
  substitution, so a build-time field evaluation (`_observed_field`) can
  materialize each producer once in dependency order and let its readers
  gather the buffer, instead of re-running the whole producer chain per output
  cell. Independent of the right-hand side's factoring, whose roots are the
  `D`/`ic` equations: a model with no state has no such roots.
* `derived_extents` — the extents of data-derived index sets (value
  invention), keyed by producer id, without which an observed shaped on a
  derived axis cannot be materialized.
* `forcing_buffers`, `forcing_buffer_index` — the live forcing buffers the
  build bound, in the name-sorted order a compiled backend's buffers argument
  is aligned with, and name → position. Filled by every build form.
* `unvalued_slots` — the state slots nothing in the document gave a starting
  value; the build writes 0.0 there as a placeholder and `esm_problem` refuses
  any the caller's `u0` does not cover (esm-spec §11.4).
* `ic_reseed` — `(t0, data) -> u0`, the initial state at another start of the
  run (esm-spec §11.4.2), or `nothing` when it does not depend on the start.
* `observed_ctx` — what the compiled observed program (`observed_program.jl`)
  compiles an output-time read against.
* `stats` — the emitted right-hand side's structural counts (kernels, CSE and
  prelude slots, scan folds, factored observeds); empty until the build ends.
* `kernels` — the access kernels the right-hand side carries, after the class
  merge.
* `forcing_epoch` — the build's forcing epoch (cadence_stamp.jl), the counter
  [`notify_forcing_refresh!`](@ref) bumps; the `DiscreteMaterializer` the build
  filled carries the same one.
"""
mutable struct BuildProducts
    setup_arrays::Dict{String, Array{Float64}}
    const_arrays::Dict{String, Any}
    observed_exprs::Dict{String, ASTExpr}
    params::Dict{String, Float64}
    param_classes::Dict{String, Symbol}
    recurrences::Vector{RecurrenceInfo}
    compiler_report::CompilerReport
    observed_defs::Dict{String, ASTExpr}
    derived_extents::Dict{String, Int}
    forcing_buffers::NamedTuple
    forcing_buffer_index::Dict{String, Int}
    unvalued_slots::Vector{Int}
    ic_reseed::Any
    observed_ctx::Any
    stats::NamedTuple
    kernels::AbstractVector
    forcing_epoch::_ForcingEpoch
    # What the strip class `initialization` took (`_StrippedInitialization`),
    # or `nothing`.
    ic_stripped::Any
end
BuildProducts() = BuildProducts(
    Dict{String, Array{Float64}}(), Dict{String, Any}(), Dict{String, ASTExpr}(),
    Dict{String, Float64}(), Dict{String, Symbol}(), RecurrenceInfo[],
    CompilerReport(:native),
    Dict{String, ASTExpr}(), Dict{String, Int}(),
    NamedTuple(), Dict{String, Int}(),
    Int[], nothing, nothing, NamedTuple(), Any[], _new_forcing_epoch(), nothing
)

"""
    DiscreteMaterializer()

The **discrete-cadence materialization** sink — the middle phase of the
three-phase cadence partition (`const ⊏ discrete ⊏ continuous`, `cadence.jl`).
[`esm_problem`](@ref) ALWAYS makes the cut: it creates one of these when the
`materialize_out` keyword is not given, and passing your own only makes it
inspectable. An internal build without the keyword makes no cut,
so its discrete-cadence derived fields stay inlined into the per-step RHS.

Under `compiler = :native` each field's fill is one whole-array kernel, compiled
once through the same cascade as the right-hand side and run into the cache at
every refill; its compiler-report row is an `:observed` row named after the
field, carrying the tier the cascade landed it on, and a fill the cascade cannot
compile is refused by name. `compiler = :interpreter` resolves, compiles and
walks every cell instead (`:discrete_percell`), the oracle the compiled fill is
checked against bit for bit.

A derived ARRAY observed whose value depends (transitively) on a live
`param_arrays` forcing buffer but NOT on any continuous `state` (nor the
independent variable `t`) changes only at the discrete refresh cadence. Inlining
it into the hot RHS recomputes the whole met→physics stack every step — and, for
a deep chain (a regrid feeding the Rothermel fire-physics), collapses into an
enormous per-cell expression the compiler cannot lower in bounded time. The cut
materializes each such field ONCE PER REFRESH into a dense cache buffer that the
hot RHS gathers via the existing zero-alloc `_NK_PARAM_GATHER` path — exactly as
it gathers a raw forcing buffer. The build fills it:

* `caches::Dict{String,Array{Float64}}` — var name → its cache buffer (the SAME
  object aliased into `pgather`, captured by reference; a `materialize!` write
  shows through to the RHS with zero reallocation).
* `materialize!::Function` — a `() -> nothing` closure that recomputes every
  cache from the (already-refreshed) raw forcing buffers + const arrays + upstream
  caches, in dependency order, unconditionally. `_build_evaluator` runs it ONCE at
  build (so u0 seeding and the first RHS evaluation read valid caches), and
  [`esm_problem`](@ref) wires it as the refresh callback's `post_refresh` hook.
* `refresh!::Function` — a `() -> nothing` closure that runs `materialize!` only
  when the build's forcing epoch has moved since the last fill, i.e. only after a
  forcing write announced with [`notify_forcing_refresh!`](@ref). The in-place
  `f!` and [`observed_field`](@ref) call it themselves before reading the caches,
  so a direct write needs only the announcement. A caller that reads the caches
  through anything else — the out-of-place build product's
  [`forcing_buffers`](@ref), copied to a device by [`sync_forcing!`](@ref) —
  calls `refresh!()` first.
* `var_order::Vector{String}` — the dependency order the fills run in.
"""
mutable struct DiscreteMaterializer
    caches::Dict{String, Array{Float64}}
    materialize!::Function
    refresh!::Function
    var_order::Vector{String}
    # The forcing epoch of the build this sink belongs to (cadence_stamp.jl):
    # bumped by `materialize!` and by a refresh of any buffer the build reads.
    epoch::_ForcingEpoch
end
DiscreteMaterializer() =
    DiscreteMaterializer(
    Dict{String, Array{Float64}}(), () -> nothing, () -> nothing, String[],
    _new_forcing_epoch()
)
