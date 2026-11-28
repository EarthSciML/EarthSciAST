---
title: "Julia extension seams"
description: "Julia's extension-tier names: documented, reachable, not portable."
type: "api"
---


Extension-tier names are part of this binding's documented surface but are not harmonized across bindings, and may change in a minor release ([API_SPEC.md §7](https://github.com/EarthSciML/EarthSciAST/blob/main/API_SPEC.md#7-extension-seams)).

155 names.

### `AbstractSink` {#x-abstractsink}

*type* · canonical name `abstract_sink`

```julia
abstract type AbstractSink
```

```julia
AbstractSink
```

Optional supertype for a streaming output sink. A sink is any object implementing
the Sink protocol ([`sink_output_times`](/generated/api/extension/julia#x-sink_output_times) / [`sink_open!`](/generated/api/extension/julia#x-sink_open) /
[`sink_write!`](/generated/api/extension/julia#x-sink_write) / [`sink_flush!`](/generated/api/extension/julia#x-sink_flush) / [`sink_close!`](/generated/api/extension/julia#x-sink_close)); it need
not subtype `AbstractSink` (the protocol dispatches structurally, mirroring how
the Provider protocol accepts any object). It exists as the declared element type
of [`esm_problem`](/generated/api/ref/esm_problem-function)'s `sinks` keyword and as an opt-in for concrete bindings.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/output_sinks.jl#L38)

### `adjacency` {#x-adjacency}

*function* · canonical name `adjacency`

```julia
adjacency(graph::Graph{N, E}, node::N) where {N, E}
```

Get all adjacent nodes (both predecessors and successors).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/graph.jl#L75)

### `any_of` {#x-any_of}

*function* · canonical name `any_of`

```julia
any_of(predicates...)
```

```julia
any_of(predicates...) -> () -> Bool
```

OR-compose checkpoint predicates (RFC §10): the returned zero-arg predicate fires
when ANY of `predicates` fires. Each argument is itself a `() -> Bool`. With no
arguments the result never fires (`false`, the identity for OR) — a predicate-free
checkpoint configuration contributes no just-in-time trigger. Predicates compose
freely with a fixed interval; a user on PBS / Kubernetes / a bespoke scheduler
passes their own `() -> Bool` with no library change.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/checkpoint.jl#L15)

### `assert_classification_partitions` {#x-assert_classification_partitions}

*function* · canonical name `assert_classification_partitions`

```julia
assert_classification_partitions(model::Model)
```

```julia
assert_classification_partitions(model::Model)
```

Check that the three unknown sets and the four parameter sets each partition
their side of the model's variables, throwing `ArgumentError` otherwise. The
spec states the partition property normatively, so it is asserted rather than
assumed; the conformance runner and `test/classification_test.jl` call it on
every fixture.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/classification.jl#L473)

### `AssertionStatus` {#x-assertionstatus}

*type* · canonical name `assertion_status`

```julia
struct AssertionStatus <: Enum
AssertionStatus(x::Integer)
```

```julia
AssertionStatus
```

Outcome status of one inline-test assertion: `PASS`, `FAIL` (value outside
tolerance), or `ERROR` (the load / compile / solve / sample raised).

`SKIP` is RESERVED and currently never produced: spec §6.6 defines no skip
semantics, and mapping missing prerequisites (e.g. Catalyst not loaded for a
ReactionSystem test) to `SKIP` instead of `ERROR` would silently weaken the
exit-code contract (`exit_code == 0` iff nothing failed or errored). It is
kept in the enum so downstream tooling can rely on the value once the spec
grows skip semantics.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/run_tests.jl#L47)

### `ASTExpr` {#x-astexpr}

*type* · canonical name `ast_expr`

```julia
abstract type ASTExpr
```

```julia
abstract type ASTExpr end
```

Abstract base type for all mathematical expressions in the ESM format.
Expressions can be numeric literals, variable references, or operator nodes.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/types.jl#L96)

### `broad_phase_candidates` {#x-broad_phase_candidates}

*function* · canonical name `broad_phase_candidates`

```julia
broad_phase_candidates(query_envs::AbstractVector, cell_envs::AbstractVector; eps)
```

```julia
broad_phase_candidates(query_envs, cell_envs; eps=0.0) -> Vector{Tuple{Int,Int}}
```

Return every `(qi, cj)` — 1-based positions in `query_envs` / `cell_envs` — whose
2D envelopes intersect after inflating BOTH outward by `eps`. Envelopes are
`(xmin, ymin, xmax, ymax)` 4-tuples (see file header). The result is sorted
ascending by `(qi, cj)` for determinism.

This is a CONSERVATIVE SUPERSET of true geometric overlaps: any pair of features
whose geometries actually overlap has intersecting envelopes and so appears here
(with `eps >= 0`). Missing a true overlap is impossible by construction — the
envelope of a geometry contains it.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/broad_phase.jl#L25)

### `build_checkpoint_callback` {#x-build_checkpoint_callback}

*function* · canonical name `build_checkpoint_callback`

```julia
build_checkpoint_callback(args...; kwargs...)
```

```julia
build_checkpoint_callback(; sinks, predicates, snapshot = state_snapshot,
                          pre_write = () -> nothing, terminate_on_fire = true)
    -> cb
```

Build the PREDICATE-driven checkpoint callback (RFC §10, §16.7): a `DiscreteCallback`
whose `condition` is the OR of `predicates` ([`any_of`](/generated/api/extension/julia#x-any_of)-style zero-arg
`() -> Bool`s, e.g. [`slurm_walltime_predicate`](/generated/api/extension/julia#x-slurm_walltime_predicate) /
[`spot_preemption_predicate`](/generated/api/extension/julia#x-spot_preemption_predicate)) and whose `affect!` snapshots the full state,
writes it to every sink in `sinks`, calls [`sink_flush!`](/generated/api/extension/julia#x-sink_flush) (the durable commit
barrier), and — when `terminate_on_fire` — `terminate!`s the integrator for a clean
pre-preemption exit. Compose the returned callback in the same `CallbackSet` as the
diagnostic output and input-refresh callbacks. Interval-only checkpointing needs no
predicate callback — a checkpoint-profile sink's `sink_output_times` already ride the
ordinary `PresetTimeCallback` cadence.

Requires `DiffEqCallbacks` + `SciMLBase` (the constructor is a package extension);
calling it without them throws [`OutputError`](/generated/api/ref/output_error).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/checkpoint.jl#L75)

### `build_output_callback` {#x-build_output_callback}

*function* · canonical name `build_output_callback`

```julia
build_output_callback(args...; kwargs...)
```

```julia
build_output_callback(; sinks, snapshot, pre_write = () -> nothing)
    -> (cb, tstops::Vector{Float64})
```

Build the streaming-output callback and its tstops, the output-side mirror of
[`build_refresh_callback`](/generated/api/extension/julia#x-build_refresh_callback). The callback reads only `sinks`, `snapshot`
and `pre_write`, never the model. The caller attaches it to their own problem:

```julia
cb, tstops = build_output_callback(; sinks = [my_sink], snapshot = state_snapshot)
prob = ODEProblem(f!, u0, tspan, p)              # USER's solver call
sol  = solve(prob, Tsit5(); callback = cb, tstops = tstops, save_everystep = false)
```

* `sinks` — a collection of objects implementing the Sink protocol
  ([`sink_output_times`](/generated/api/extension/julia#x-sink_output_times) / [`sink_write!`](/generated/api/extension/julia#x-sink_write) / …). Each has its OWN
  output cadence; multiple sinks with different cadences are first-class.
* `snapshot` — required: an `integrator -> snapshot` function returning a
  [`StateSnapshot`](/generated/api/extension/julia#x-statesnapshot) or, like [`state_snapshot`](/generated/api/extension/julia#x-state_snapshot), just its state
  slabs. A caller writing observed fields supplies one that captures its
  observed caches.
* `pre_write` — a `() -> nothing` hook the `affect!` calls at each output boundary
  BEFORE `snapshot(integrator)`, so the caller-named observed caches are fresh when
  the snapshot reads them. Defaults to a no-op.

`affect!` at each tick: run `pre_write()`, build the snapshot via
`snapshot(integrator)`, then for each sink whose `sink_output_times` contains the
tick, call `sink_write!(sink, snap)`.

`cb` is a `PresetTimeCallback`; `tstops` is the sorted, de-duplicated UNION of
every sink's [`sink_output_times`](/generated/api/extension/julia#x-sink_output_times), built as [`build_refresh_callback`](/generated/api/extension/julia#x-build_refresh_callback)
builds its tstops, so refresh and output compose in one `CallbackSet` (union
the two tstops).
Returns an empty-tstops no-op callback when every sink is predicate-only.

Requires `DiffEqCallbacks` and `SciMLBase` to be loaded (the constructor is a
package extension); calling it without them throws [`OutputError`](/generated/api/ref/output_error).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/output_sinks.jl#L223)

### `build_refresh_callback` {#x-build_refresh_callback}

*function* · canonical name `build_refresh_callback`

```julia
build_refresh_callback(args...; kwargs...)
```

```julia
build_refresh_callback(; providers, buffers, owner,
                       post_refresh = () -> nothing)
    -> (cb, tstops::Vector{Float64})
```

Build the discrete-cadence loader-refresh callback and its tstops. The callback
reads only the `providers` and `buffers` registries, never the model.
`esm_problem(…; providers)` composes it for a document's own discrete providers;
a caller who binds forcing buffers through `param_arrays` attaches it to the run:

```julia
forcing = Dict("wind" => zeros(nx, ny))
prob = esm_problem(doc, tspan; param_arrays = forcing, …)
cb, tstops = build_refresh_callback(;
    providers = Dict("wind" => wind_provider),   # var name => data Provider
    buffers   = RefreshBuffers(forcing),         # same array objects as param_arrays
    owner     = prob)                            # the build that reads them
sol = solve(prob, Tsit5(); callback = cb, tstops = tstops)
```

`providers` maps each forcing variable to a data provider (the
[`provider_refresh_times`](/generated/api/extension/julia#x-provider_refresh_times) / [`provider_is_const`](/generated/api/extension/julia#x-provider_is_const) /
[`provider_sample`](/generated/api/extension/julia#x-provider_sample) protocol). Several variables may share one provider
object; it is then sampled once per cadence boundary. The provider delivers the
forcing on the buffer's grid.

* Discrete providers (non-empty `provider_refresh_times`) are refreshed at each
  anchor: `affect!` samples and writes the buffer in place, then calls
  `u_modified!(integrator, true)` so an FSAL integrator recomputes its cached
  derivative from the new forcing (`u` itself is untouched).
* Const providers ([`provider_is_const`](/generated/api/extension/julia#x-provider_is_const)) contribute no tstops and are
  absent from the callback.

`owner` is the build that reads `buffers` (the Problem, or the
[`DiscreteMaterializer`](/generated/api/extension/julia#x-discretematerializer) its build filled); `affect!` announces each
boundary's writes to it with `notify_forcing_refresh!` so its memoized
values refill. With `owner = nothing` nothing is announced, and a value
memoized from the old forcing stays until `t` moves (time-cadence values) or for
good (discrete caches).

`post_refresh` is a `() -> nothing` hook `affect!` calls at each boundary after
the buffers are refreshed and announced and before `u_modified!`.
[`esm_problem`](/generated/api/ref/esm_problem-function) wires it to the [`DiscreteMaterializer`](/generated/api/extension/julia#x-discretematerializer)'s
`materialize!`, so a state-free derived field is recomputed once per boundary.
Defaults to a no-op.

`cb` is a `PresetTimeCallback`; `tstops` is the sorted, de-duplicated union of
the DISCRETE providers' refresh times. Returns an empty-tstops no-op callback
when every provider is CONST.

Requires `DiffEqCallbacks` and `SciMLBase` to be loaded (the constructor is a
package extension); calling it without them throws [`RefreshError`](/generated/api/extension/julia#x-refresherror).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/data_refresh.jl#L445)

### `build_zarr_sink` {#x-build_zarr_sink}

*function* · canonical name `build_zarr_sink`

```julia
build_zarr_sink(args...; kwargs...)
```

```julia
build_zarr_sink(source, base_url; output_times, kwargs...) -> sink
```

Construct a concrete Zarr [`streaming sink`](/generated/api/extension/julia#x-sink_output_times) writing to the
store at `base_url` (a `file://` URL or path). `source` is an [`EsmProblem`](/generated/api/ref/esm_problem-type)
(or a bare `var_map` dict); `output_times` are the solver-second anchors at which
the sink writes. The returned object implements the Sink protocol and is passed to
[`esm_problem`](/generated/api/ref/esm_problem-function)'s `sinks` keyword.

Requires `EarthSciIO` to be loaded (the concrete sink is in the
`EarthSciASTEarthSciIOExt` extension); calling it without EarthSciIO throws
[`OutputError`](/generated/api/ref/output_error).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/output_sinks.jl#L279)

### `BuildInspection` {#x-buildinspection}

*type* · canonical name `build_inspection`

```julia
mutable struct BuildInspection
BuildInspection(setup_arrays::Dict{String, Array{Float64}}, const_arrays::Dict{String, Any}, observed_exprs::Dict{String, ASTExpr}, params::Dict{String, Float64}, param_classes::Dict{String, Symbol}, recurrences::Vector{RecurrenceInfo}, compiler_report::CompilerReport, taken::Bool)
BuildInspection(setup_arrays, const_arrays, observed_exprs, params, param_classes, recurrences, compiler_report, taken)
BuildInspection()
```

```julia
BuildInspection()
```

Observability record for a build: pass one via [`esm_problem`](/generated/api/ref/esm_problem-function)'s
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
  declares — see [`parameter_classes`](/generated/api/extension/julia#x-parameter_classes). This is the build-level face of the same
  partition `parameter_classes(prob)` exposes on an `EsmProblem`.
* `recurrences::Vector{RecurrenceInfo}` — one [`RecurrenceInfo`](/generated/api/extension/julia#x-recurrenceinfo) per
  causal self-reference the build recognized (esm-spec §4.3.1.1): its axis,
  derived maximum lag, whether the lag was proved, and the sweep's size.
* `compiler_report::CompilerReport` — which tier every rule landed on (API_SPEC
  §5.8), the record [`compiler_report`](/generated/api/extension/julia#x-compiler_report) returns for this build. It is
  filled even when the build REFUSED, which leaves no Problem to read it off.

A record describes ONE build. It is filled when that build ends (a refused build
still fills `compiler_report`), and passing it to a second build raises an
`ArgumentError`. The entries are the build's own objects, not copies.

Filling the record never changes the build.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/tree_walk/build_records.jl#L234)

### `coerce_coupling_entry` {#x-coerce_coupling_entry}

*function* · canonical name `coerce_coupling_entry`

```julia
coerce_coupling_entry(data)
```

```julia
coerce_coupling_entry(data::Any) -> CouplingEntry
```

Coerce JSON data into concrete CouplingEntry subtype based on the 'type' field.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/parse.jl#L999)

### `coerce_solver` {#x-coerce_solver}

*function* · canonical name `coerce_solver`

```julia
coerce_solver(data)
```

```julia
coerce_solver(data) -> Union{Solver,Nothing}
```

Coerce the top-level `solver` block (esm-spec §2.2) into the typed
[`Solver`](/generated/api/ref/solver) carried on [`EsmFile`](/generated/api/ref/esm_file), or `nothing` when the document
declares none.

Field VALUES are not re-validated here — the schema already pins the two enums,
the two positive tolerances, the non-empty `external` string and the shape of
`time_span`, and this runs after schema validation. What it
does is keep absence distinguishable from any default: a missing key stays
`nothing` rather than acquiring a value the author never wrote.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/parse.jl#L709)

### `compiler` {#x-compiler}

*function* · canonical name `compiler`

```julia
compiler(prob::EsmProblem)
```

```julia
compiler(prob::EsmProblem) -> Symbol
```

The vocabulary value (API_SPEC §5.8) that BUILT this problem — what actually
ran, not what was asked for, which for a successful build are the same thing
because a compiler that cannot run a document refuses it rather than
substituting another.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/simulate.jl#L961)

### `compiler_report` {#x-compiler_report}

*function* · canonical name `compiler_report`

```julia
compiler_report(prob::EsmProblem)
compiler_report(insp::BuildInspection)
```

```julia
compiler_report(prob::EsmProblem) -> CompilerReport
```

Which tier every rule of this problem landed on, and the declines it collected
on the way (API_SPEC §5.8). Under [`compiler`](/generated/api/extension/julia#x-compiler)`(prob) === :native` this is
the cost story: affine versus generated code versus a whole-array form, and
which equations were scalarized per output cell at BUILD.

```julia
prob = esm_problem("model.esm", (0.0, 1.0))
compiler(prob)                       # :native
show(stdout, MIME"text/plain"(), compiler_report(prob))
```

The names and their meanings are stable; the record's shape is per-binding.

---

```julia
compiler_report(insp::BuildInspection) -> CompilerReport
```

The same record, off a build's [`BuildInspection`](/generated/api/extension/julia#x-buildinspection). A caller who passed
`inspect = insp` to [`esm_problem`](/generated/api/ref/esm_problem-function) reads it here — including after a
build that REFUSED, which is the case the partial record is most wanted for and
the one no Problem exists to carry.

This is the whole of what build observability answers about the compiler:
the tier every rule landed on, the declines it collected getting there, and the
build's cascade counters. `compiler_report(prob)` is the same object.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/simulate.jl#L971)

### `COMPILER_VOCABULARY` {#x-compiler_vocabulary}

*constant* · canonical name `compiler_vocabulary`

```julia
const COMPILER_VOCABULARY::NTuple{5, Symbol}
```

```julia
COMPILER_VOCABULARY
```

The closed set of `compiler` values (esm-libraries-spec §2.5.10), in the order
the spec lists them. A value outside it raises `compiler_unknown`; a value in
it that this binding cannot provide raises `compiler_unavailable`. Neither is
ever answered by building with a different compiler.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/compiler.jl#L16)

### `CompilerRuleRecord` {#x-compilerrulerecord}

*type* · canonical name `compiler_rule_record`

```julia
struct CompilerRuleRecord
CompilerRuleRecord(rule::String, kind::Symbol, tier::Symbol, declines::Vector{@NamedTuple{tier::Symbol, reason::Symbol, detail::String}})
CompilerRuleRecord(rule, kind, tier, declines)
CompilerRuleRecord(rule::AbstractString, kind::Symbol, tier::Symbol)
```

```julia
CompilerRuleRecord
```

One rule of one build: an equation, an observed, or a setup array, the tier it
landed on, and every decline it collected getting there.

* `rule` — the rule's identity, component-qualified the way the document spells
  it (a derivative target with its output axes, an observed's name, a setup
  array's name).
* `kind` — `:equation`, `:observed`, `:setup_array`, or `:rhs_program` for a
  compiler that emits ONE program for the whole assembled right-hand side
  (`:xla`) rather than lowering it rule by rule.
* `tier` — where it landed:
  - right-hand side: `:affine`, `:scan`, `:array_contraction_codegen`,
    `:empty_output` (an array equation over an empty output range: no cell to
    build or run), `:percell_build` (scalarized per output cell at BUILD, then
    compiled),
    `:codegen`, `:interpreter` (walked per cell as trees on every call);
    `:scalar_codegen` (a scalar equation emitted as generated code, with the
    other units of its structural class, by the scalar codegen tier) and
    `:scalar_loop_codegen` (the same, with a reduction kept as a runtime loop
    in that code); `:scalar` and `:scalar_loop` are those equations when the
    tier is off (`interpreter`) or could not model them: walked once per slot
    on every call by the scalar walker;
  - construction: `:setup_codegen` (filled through the right-hand-side cascade
    and emitted code, run once), `:setup_compiled` (compiled once, evaluated per
    cell),
    `:setup_loaded` (copied out of a supplied array), `:setup_constant`
    (evaluated once and filled), `:setup_percell` (resolved and compiled per
    cell), and `:discrete_percell` (a discrete-cadence field, resolved and
    compiled per cell at build and walked per cell at every data refresh;
    under `native` such a field is instead an `:observed` row on the
    right-hand-side tier its compiled fill landed on);
  - output time, added by `observed_field` the first time it reads a name:
    `:output_compiled_once` or `:output_percell`;
  - and, on the `:rhs_program` row an `:xla` build adds, `:xla_direct_cpu` /
    `:xla_direct_gpu`, which name the emitter and the device together.
  Under a strict compiler `:interpreter`, `:setup_percell`,
  `:discrete_percell` and `:output_percell` are refusals instead, and so is
  `:percell_build` in the in-place form, so a `native` report never shows them.
* `declines` — one `(tier, reason, detail)` named tuple for every tier that
  looked at this rule and passed, deepest last. `tier` names the tier
  (`:equality_scatter`, `:affine`, `:array_contraction`, …), `reason` is one
  of the closed vocabulary below, and `detail` is free text naming the
  construct (the operator, the variable, the error the body raised); it is
  `""` when the reason says it all. A strict refusal prints every decline
  with its detail.

Decline reasons (the closed vocabulary; [`_DECLINE_REASONS`] holds it with
the same words):

  - `:lhs_not_indexed_derivative` — the left-hand side is not `D(index(var, i…))`
  - `:lhs_subscript_count` — the left-hand side's subscripts do not match the output indices
  - `:no_output_index` — the equation has no output index
  - `:no_contracted_index` — the equation has no contracted index
  - `:range_not_unit_run` — an output range is empty or not a unit-step run
  - `:below_floor` — the contraction is shorter than the tier's length floor
  - `:tier_off` — the tier is off under this compiler
  - `:gated_reduction` — a contraction with a join gate, whose terms vary per output cell
  - `:filtered_reduction` — a contraction with a filter the tier cannot guard
  - `:ragged_contraction` — a contracted range that is not a constant dense range
  - `:contracted_axis_cut` — a contracted axis the box cut splits, so one fold cannot walk it in one piece
  - `:symbolic_body_did_not_lower` — the body does not resolve or compile with its indices kept symbolic
  - `:unsupported_op` — an operator the tier has no form for
  - `:unknown_kind` — a compiled node kind the tier has no form for
  - `:call_array_args` — a template call that passes arrays, in a context that has no array arguments (setup geometry)
  - `:call_array_forward` — a template call, inside another call's body, passing on an array that is not that body's own array argument
  - `:unknown_array` — a gather of a name that is not a known array
  - `:malformed_index` — an `index` node with no operand
  - `:subscript_rank_mismatch` — a gather whose subscript count is not the array's rank
  - `:subscript_not_static` — a subscript that is not an integer function of the loop indices and build-time tables
  - `:gathered_reduction_shape` — a gathered reduction whose output indices do not match its subscripts
  - `:region_value_shape` — a `makearray` region value whose rank does not match the region
  - `:region_multi_index` — a `makearray` region selected by a subscript of several loop indices
  - `:guarded_out_of_range` — a constant subscript out of range under a run-time guard
  - `:output_layout_not_affine` — the output cells' slots are not an affine function of the loop indices
  - `:subtree_table_declined` — a build-time-evaluable subtree that the compile-once evaluator declined
  - `:scatter_too_many_pinned_cells` — the equality filter pins more output cells than the scatter takes
  - `:scatter_ragged_or_empty` — a scatter whose contracted range is ragged or empty
  - `:scatter_ragged_reads_output` — a ragged scatter whose body reads its own output
  - `:budget` — the generated code would exceed its node budget
  - `:unsupported_desc` — an access descriptor the code generator has no form for
  - `:unsupported_bound` — a loop bound the code generator cannot write
  - `:foreign_scratch` — a read of a scratch buffer the generated function does not own
  - `:loopvar_out_of_scope` — a loop variable read outside the loop that binds it
  - `:loop_reentered` — a loop entered again inside its own body
  - `:lane_spec_on_scalar_spine` — a lane descriptor on a scalar spine
  - `:cached_scalar_slot` — a cached scalar slot the generated function cannot read

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/compiler.jl#L336)

### `ConditionTrigger` {#x-conditiontrigger}

*type* · canonical name `condition_trigger`

```julia
struct ConditionTrigger <: DiscreteEventTrigger
ConditionTrigger(expression::ASTExpr)
ConditionTrigger(expression)
```

```julia
ConditionTrigger(expression::ASTExpr)
```

Trigger based on boolean condition expression.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/types.jl#L542)

### `CouplingCallback` {#x-couplingcallback}

*type* · canonical name `coupling_callback`

```julia
struct CouplingCallback <: CouplingEntry
CouplingCallback(callback_id::String; config, description)
```

```julia
CouplingCallback <: CouplingEntry
```

Register a callback for simulation events.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/types.jl#L1739)

### `CouplingEvent` {#x-couplingevent}

*type* · canonical name `coupling_event`

```julia
struct CouplingEvent <: CouplingEntry
CouplingEvent(event_type::String, affects::Vector{AffectEquation}; name, conditions, trigger, affect_neg, root_find, reinitialize, description)
```

```julia
CouplingEvent <: CouplingEntry
```

Cross-system event involving variables from multiple coupled systems.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/types.jl#L1753)

### `CouplingOperatorApply` {#x-couplingoperatorapply}

*type* · canonical name `coupling_operator_apply`

```julia
struct CouplingOperatorApply <: CouplingEntry
CouplingOperatorApply(operator::String; description)
```

```julia
CouplingOperatorApply <: CouplingEntry
```

Register an operator (referenced by name) to run during simulation.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/types.jl#L1726)

### `CouplingOperatorCompose` {#x-couplingoperatorcompose}

*type* · canonical name `coupling_operator_compose`

```julia
struct CouplingOperatorCompose <: CouplingEntry
CouplingOperatorCompose(systems::Vector{String}; translate, description, lifting, require_match)
```

```julia
CouplingOperatorCompose <: CouplingEntry
```

Match LHS time derivatives and add RHS terms together.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/types.jl#L1648)

### `CouplingVariableMap` {#x-couplingvariablemap}

*type* · canonical name `coupling_variable_map`

```julia
struct CouplingVariableMap <: CouplingEntry
CouplingVariableMap(from::String, to::String, transform::Union{String, ASTExpr}; factor, description, lifting)
```

```julia
CouplingVariableMap <: CouplingEntry
```

Replace a parameter in one system with a variable from another, or — when
`transform` is an `ASTExpr` operator node rather than one of the named transform
strings — with a derived value computed from it (esm-spec §10.4: the target
parameter becomes an observed whose defining expression is the transform,
evaluated in the flattened coupled system's scope; §8.6/§10.5 regridding form).
An `ASTExpr` transform takes no `factor` (fold scaling into the expression).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/types.jl#L1693)

### `DimCoord` {#x-dimcoord}

*type* · canonical name `dim_coord`

```julia
struct DimCoord
DimCoord(name::String, values::Vector{Float64}, attrs::Dict{String, Any})
DimCoord(name, values, attrs)
```

```julia
DimCoord(name, values, attrs)
```

A CF **dimension coordinate** (§8.3): a 1-D coordinate variable named exactly like
its dimension, its monotonic `values`, and its CF `attrs` (`standard_name` /
`units` / `axis`). Emitted once at [`sink_open!`](/generated/api/extension/julia#x-sink_open). Auxiliary (unstructured /
curvilinear) coordinates — whose registry key differs from the dim name and whose
values come from a `source` array — are a later drop-in on the same registry; v1
emits inline-`values` dimension coordinates.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/output_plan.jl#L439)

### `discover_esm_files` {#x-discover_esm_files}

*function* · canonical name `discover_esm_files`

```julia
discover_esm_files(roots::AbstractVector{<:AbstractString}; root, exclude)
discover_esm_files(; kwargs...)
```

```julia
discover_esm_files(roots; root=esm_root(), exclude=nothing) -> Vector{String}
```

Recursively walk each directory in `roots` (relative to `root` if not
absolute) and return all `*.esm` paths in deterministic sorted order. Missing
roots are skipped silently.

`root` is the base directory against which relative `roots` and repo-relative
exclude patterns resolve; it defaults to this package's [`esm_root`](/generated/api/extension/julia#x-esm_root).
Pass it to walk a different repo (e.g. EarthSciModels) — do NOT overwrite
`esm_root()` itself.

`exclude` (or the `ESM_TESTS_EXCLUDE` env var, ";"- or ":"-separated) is a list
of substring patterns; any discovered file whose absolute or root-relative
path contains a pattern is dropped.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/run_tests.jl#L216)

### `DiscreteMaterializer` {#x-discretematerializer}

*type* · canonical name `discrete_materializer`

```julia
mutable struct DiscreteMaterializer
DiscreteMaterializer(caches::Dict{String, Array{Float64}}, materialize!::Function, refresh!::Function, var_order::Vector{String}, epoch::EarthSciAST._ForcingEpoch)
DiscreteMaterializer(caches, materialize!, refresh!, var_order, epoch)
DiscreteMaterializer()
```

```julia
DiscreteMaterializer()
```

The **discrete-cadence materialization** sink — the middle phase of the
three-phase cadence partition (`const ⊏ discrete ⊏ continuous`, `cadence.jl`).
[`esm_problem`](/generated/api/ref/esm_problem-function) ALWAYS makes the cut: it creates one of these when the
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
  [`esm_problem`](/generated/api/ref/esm_problem-function) wires it as the refresh callback's `post_refresh` hook.
* `refresh!::Function` — a `() -> nothing` closure that runs `materialize!` only
  when the build's forcing epoch has moved since the last fill, i.e. only after a
  forcing write announced with `notify_forcing_refresh!`. The in-place
  `f!` and [`observed_field`](/generated/api/ref/observed_field) call it themselves before reading the caches,
  so a direct write needs only the announcement. A caller that reads the caches
  through anything else — the out-of-place build product's
  [`forcing_buffers`](/generated/api/extension/julia#x-forcing_buffers), copied to a device by [`sync_forcing!`](/generated/api/extension/julia#x-sync_forcing) —
  calls `refresh!()` first.
* `var_order::Vector{String}` — the dependency order the fills run in.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/tree_walk/build_records.jl#L392)

### `emit_fragment` {#x-emit_fragment}

*function* · canonical name `emit_fragment`

```julia
emit_fragment(ir; eltype = ir.working_eltype, fold = :tree)
```

With Reactant loaded, create a host callable that emits a StableHLO fragment
into the caller's trace. Call it on traced arguments `(u, aux, p, t, forcing)`;
tile classes also take `origin` and lane targets take `cells`. If an output
kernel reads a time step, append `dt`. The fragment uses the IR's working
precision, including when `eltype` is supplied explicitly. Binary32 operations
and reductions accumulate in expression order. See the compiled backend
guide for layouts and precision.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/operator_ir.jl#L383)

### `equation_contributions` {#x-equation_contributions}

*function* · canonical name `equation_contributions`

```julia
equation_contributions(flat::FlattenedSystem)
```

```julia
equation_contributions(flat::FlattenedSystem) -> Vector{Vector{Contribution}}
```

The per-term provenance of `flat`: entry `i` is the ordered list of
contributions whose left-fold sum is `flat.equations[i]`'s right-hand side (its
`faq` body when the pointwise lift wrapped it). See esm-libraries-spec §4.7.5.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/term_provenance.jl#L74)

### `equation_unit_findings` {#x-equation_unit_findings}

*function* · canonical name `equation_unit_findings`

```julia
equation_unit_findings(eq::Equation, var_units::AbstractDict)
```

```julia
equation_unit_findings(eq::Equation, var_units::AbstractDict) -> Vector{String}
```

The PROVABLE dimensional inconsistencies of a derivative equation, if any: an
operator-rule mismatch inside either side, then the mismatch between the two
SIDES (the whole equation check site, esm-spec §4.8.4, §4.8.6), which
`validate` reports for every `D(u, t) = …` equation (see
[`model_unit_findings`](/generated/api/extension/julia#x-model_unit_findings)).

Scope, and why it is this narrow:

* **Only derivative equations are compared here.** An equation with a `D(u, t)`
  LHS states a rate law and its two sides must balance. A defining equation
  (`u = f(x)`) is checked against the declared units of `u` by
  [`model_unit_findings`](/generated/api/extension/julia#x-model_unit_findings), and an algebraic or implicit LHS
  (`H*H*SO4 = Ksp`) states a *constraint* that is not compared.

* **Expression-internal inconsistencies are NOT collected here.** They are
  checked on defining equations and on parameter `update` expressions (see
  [`model_unit_findings`](/generated/api/extension/julia#x-model_unit_findings)).

* **An undeclared time variable makes the time factor free.** `dim(D(u)) =
  dim(u)/dim(t)`. When the model never declares units for `wrt` (the usual case
  — `t` is rarely a declared variable), no particular time unit is asserted, so
  an inconsistency is only PROVABLE when `dim(u)/dim(rhs)` is not a power of the
  time dimension: no choice of time unit could reconcile the two. This is what
  makes `D(x) = -x` (x dimensionless — the elided unit rate constant, ubiquitous
  in the corpus) pass while `D(velocity[m/s]) = mass[kg]` still fails.
  When `wrt` IS declared, the strict comparison is used.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/units.jl#L2387)

### `ERROR` {#x-error}

*constant* · canonical name `error`

```julia
const ERROR::AssertionStatus
```

```julia
ERROR::AssertionStatus
```

The assertion could not be evaluated: loading, compiling, solving or sampling
the test raised. The result's `message` carries the error text. Counts against
the exit code exactly as [`FAIL`](/generated/api/extension/julia#x-fail) does.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/run_tests.jl#L79)

### `error_code` {#x-error_code}

*function* · canonical name `error_code`

```julia
error_code(e::EarthSciASTError)
```

```julia
error_code(e::EarthSciASTError) -> String
```

The diagnostic code `e` carries: a value of [`ERROR_CODES`](/generated/api/ref/error_codes) for a
failure the bindings share, an `E_TREEWALK_*` / `E_DIRECT_*` code for a
Julia-evaluator failure, or `""` when the failure has no code (a malformed JSON
text, a misuse of an editing function). Every exported error type stores it in
its FIRST field, `code`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/errors.jl#L63)

### `error_file` {#x-error_file}

*function* · canonical name `error_file`

```julia
error_file(e::EarthSciASTError)
```

```julia
error_file(e::EarthSciASTError) -> String
```

The canonical key (absolute path or URL) of the document `e` is about when a
load read more than one, `""` for the document the caller handed over.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/errors.jl#L91)

### `error_message` {#x-error_message}

*function* · canonical name `error_message`

```julia
error_message(e::EarthSciASTError)
error_message(e::FlattenError)
error_message(e::QualifiedReferenceError)
error_message(e::TreeWalkError)
error_message(e::EarthSciAST.DirectEmitError)
```

```julia
error_message(e::EarthSciASTError) -> String
```

The human-readable text of `e`, without its type name, code or location. Codes
and messages pinned by the conformance corpus are this text.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/errors.jl#L74)

### `error_path` {#x-error_path}

*function* · canonical name `error_path`

```julia
error_path(e::EarthSciASTError)
```

```julia
error_path(e::EarthSciASTError) -> String
```

The RFC 6901 pointer, into the document named by [`error_file`](/generated/api/extension/julia#x-error_file), of the
construct `e` is about; `""` when the failure has no single location.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/errors.jl#L83)

### `esm_path` {#x-esm_path}

*function* · canonical name `esm_path`

```julia
esm_path(parts::AbstractString...)
```

```julia
esm_path(parts...) -> String
```

Join `parts` onto `esm_root()`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/run_tests.jl#L33)

### `esm_root` {#x-esm_root}

*function* · canonical name `esm_root`

```julia
esm_root()
```

```julia
esm_root() -> String
```

Absolute path to the root of the package directory — the default base against
which relative `roots` and exclude patterns resolve.

> **Deprecated override pattern**
>
> Overwriting this method from a call site (defining your own `esm_root()`
> inside this module) to walk a different repo root is method-overwrite
> piracy and is deprecated. Pass the `root` keyword to
> [`discover_esm_files`](/generated/api/extension/julia#x-discover_esm_files) / [`run_esm_tests`](/generated/api/extension/julia#x-run_esm_tests) instead.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/run_tests.jl#L19)

### `evaluate_expr` {#x-evaluate_expr}

*function* · canonical name `evaluate_expr`

```julia
evaluate_expr(expr::ASTExpr, bindings::AbstractDict)
```

```julia
evaluate_expr(expr::ASTExpr, bindings::AbstractDict)::Float64
```

Evaluate a single AST expression at the supplied numeric `bindings` by
running it through the same compile + walker pipeline as
the evaluator build. All keys of `bindings` are exposed as readable
state variables; the special name `"t"` (if present) is bound to the
walker's time argument as well. Adding an op to the tree-walk evaluator
transparently extends this entry point — there is no separate dispatch
table.

Throws `UnboundVariableError` when `expr` references a name that is not
in `bindings` and is not the time variable; other failures surface as
[`TreeWalkError`](/generated/api/extension/julia#x-treewalkerror).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/tree_walk/build_front_doors.jl#L624)

### `EventType` {#x-eventtype}

*type* · canonical name `event_type`

```julia
abstract type EventType
```

```julia
abstract type EventType end
```

Abstract base type for all event types in the ESM format.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/types.jl#L528)

### `expand_flattened_refs` {#x-expand_flattened_refs}

*function* · canonical name `expand_flattened_refs`

```julia
expand_flattened_refs(flat::FlattenedSystem; memo)
```

```julia
expand_flattened_refs(flat::FlattenedSystem) -> FlattenedSystem
```

The shared "Expand at your boundary" utility for `FlattenedSystem` consumers
(esm-spec §9.6.4 rule 2, RFC out-of-line-expression-templates §7.7): expand
every surviving `apply_expression_template` reference against the merged
`template_registry`, returning an Expanded copy, bit-identical to the
Expand-at-load image. A no-op when the registry is empty (no references
survived). `flatten` ALWAYS carries references, so a consumer with no template
handling calls this at its entry — the ModelingToolkit `System` constructor does; the
tree-walk build does NOT (it expands at its own entry with site recording).

Expanded positions: the equations, the field initial conditions, every event
expression (conditions, condition triggers, affect right-hand sides), and each
variable's sites (update rules and expression bounds, `_map_variable_sites`)
in all three variable buckets; a bucket with no reference is kept as it is.
The three subset maps (`algebraic_variables`, `brownian_parameters`,
`discrete_parameters`) are re-read from the expanded buckets, so they hold the
same expanded variables.

`memo` is the shared expansion memo (`_expand_model_refs!`'s default):
structurally identical apply sites expand once and share the result. Pass `nothing` for the
per-site re-expansion. Sharing is safe here for the same reason it is in
`_expand_model_refs!` — the expanded set becomes a DAG, which is what interning
would produce one pass later anyway.

Not for build or analysis paths: esm-spec §9.6.4 rule 2 says builders,
evaluators and analyses SHOULD NOT expand references (they analyse and compile
each template once). This is an explicit expansion utility for tools and
interchange.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/flatten.jl#L1513)

### `expanded_file` {#x-expanded_file}

*function* · canonical name `expanded_file`

```julia
expanded_file(file::EsmFile)
```

```julia
expanded_file(file::EsmFile) -> EsmFile
```

The Option-A image of `file` (esm-spec §9.6.4): every surviving
`apply_expression_template` reference expanded into the component expressions,
and the per-component registries dropped, so `save`/`to_json` emit the fused
document rather than the reference-preserving one. The third half of the
public expansion seam — [`expanded_model`](/generated/api/extension/julia#x-expanded_model) gives one `Model`,
[`expand_flattened_refs`](/generated/api/extension/julia#x-expand_flattened_refs) a `FlattenedSystem`, this the whole document.

`flatten` and the build under `esm_problem` take the reference-preserving
file directly and expand at their own boundary, so this is for a consumer that
wants the expanded DOCUMENT: an emitter, a diff against a fused golden, a
reader with no template handling of its own. `file` is not modified, and a
file with no surviving references comes back by identity.

Not for build or analysis paths: esm-spec §9.6.4 rule 2 says builders,
evaluators and analyses SHOULD NOT expand references (they analyse and compile
each template once). This is an explicit expansion utility for tools and
interchange.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/templates/expand_typed.jl#L566)

### `expanded_model` {#x-expanded_model}

*function* · canonical name `expanded_model`

```julia
expanded_model(file::EsmFile)
expanded_model(file::EsmFile, model_name::Union{Nothing, AbstractString})
```

```julia
expanded_model(file::EsmFile, model_name=nothing) -> Model
```

A deep copy of the selected model with every surviving Option-B
`apply_expression_template` reference (esm-spec §9.6.4) expanded against the
document's `component_templates` — the same expansion `_build_evaluator`
performs before compiling, exposed as a public seam so downstream tools
(e.g. EarthSciASTDiff, which differentiates the tree) analyze the expressions
the evaluator compiles. The build goes on to rewrite this tree further without
changing its value (recurrence groups stacked, `broadcast` lowered, nested
reductions hoisted, subtrees interned), so the evaluator's own tree can differ
from this one in structure. `file` is not mutated.

Model selection matches the build's: `model_name = nothing`
selects the document's only model, or throws `E_TREEWALK_AMBIGUOUS_MODEL`
when there are several; an unknown name throws `E_TREEWALK_NO_MODEL`.
A document with no surviving references returns the plain copy.

Not for build or analysis paths: esm-spec §9.6.4 rule 2 says builders,
evaluators and analyses SHOULD NOT expand references (they analyse and compile
each template once). This is an explicit expansion utility for tools and
interchange.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/tree_walk/build_front_doors.jl#L282)

### `expression_from_json` {#x-expression_from_json}

*function* · canonical name `expression_from_json`

```julia
expression_from_json(data)
```

```julia
expression_from_json(data::Any) -> ASTExpr
```

Parse JSON data into an Expression (NumExpr, VarExpr, or OpExpr).
Handles the oneOf discriminated union based on JSON structure.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/parse.jl#L38)

### `expression_unit_findings` {#x-expression_unit_findings}

*function* · canonical name `expression_unit_findings`

```julia
expression_unit_findings(expr::ASTExpr, var_units::AbstractDict; dimensionless_literals)
```

```julia
expression_unit_findings(expr::ASTExpr, var_units::AbstractDict;
                         dimensionless_literals=false) -> Vector{String}
```

Every PROVABLE dimensional inconsistency inside `expr`, as human-readable
messages. Empty means "nothing provably wrong" — NOT "fully checked": an
expression whose dimensions are indeterminate (an undeclared variable, an
operator with no dimensional rule) yields no findings.

This is the silent, error-collecting counterpart of
[`get_expression_dimensions`](/generated/api/extension/julia#x-get_expression_dimensions) and the entry point the structural validator
builds on.

`dimensionless_literals = true` types a nonzero bare numeric literal (and a
`const` without `units`) as dimensionless at scale 1 instead of undeterminable
(esm-spec §4.8.6); zero stays neutral. Off by default: validity is decided by
the neutral-literal rule.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/units.jl#L2326)

### `FAIL` {#x-fail}

*constant* · canonical name `fail`

```julia
const FAIL::AssertionStatus
```

```julia
FAIL::AssertionStatus
```

The assertion ran and its sampled value is outside its resolved tolerance of
the expected value; the result's `message` carries the difference.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/run_tests.jl#L71)

### `final_state` {#x-final_state}

*function* · canonical name `final_state`

```julia
final_state(sol)
```

```julia
final_state(sol) -> Vector{Float64}
```

The final state vector of a solution (empty when the solve produced no points).

Works on any SciML solution — `sol.u[end]` as a dense `Vector{Float64}`,
which is the flat state vector `var_map` indexes.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/simulate.jl#L30)

### `forcing_buffer_index` {#x-forcing_buffer_index}

*function* · canonical name `forcing_buffer_index`

```julia
forcing_buffer_index(prob::EsmProblem)
forcing_buffer_index(f::EarthSciAST._OopRHS)
```

```julia
forcing_buffer_index(f) -> Dict{String,Int}
```

Name → position map for [`forcing_buffers`](/generated/api/extension/julia#x-forcing_buffers)`(f)`: `forcing_buffer_index(f)[name]`
is the index of buffer `name` in the buffers container (and in any aligned
container passed to the explicit-buffers form of a compiled RHS). Treat as
read-only.

---

```julia
forcing_buffer_index(prob::EsmProblem) -> Dict{String,Int}
```

Name → position in [`forcing_buffers`](/generated/api/extension/julia#x-forcing_buffers)`(prob)`, and in any container
aligned with it. Treat as read-only.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/tree_walk/oop.jl#L593)

### `forcing_buffers` {#x-forcing_buffers}

*function* · canonical name `forcing_buffers`

```julia
forcing_buffers(prob::EsmProblem)
forcing_buffers(f::EarthSciAST._OopRHS)
```

```julia
forcing_buffers(f) -> NamedTuple
```

The live forcing buffers of an out-of-place build product (the compiled
intermediate representation a backend lowers), as a NamedTuple in a STABLE order (buffer
names sorted): every `param_arrays` entry and every [`DiscreteMaterializer`](/generated/api/extension/julia#x-discretematerializer)
cache, each value the aliased flat host view of the exact array the build bound
— NOT a copy, so a discrete-cadence refresh writing the original array is
visible through this container. Position of a name is
[`forcing_buffer_index`](/generated/api/extension/julia#x-forcing_buffer_index)`(f)[name]`. Empty for a model with no live
forcing.

---

```julia
forcing_buffers(prob::EsmProblem) -> NamedTuple
```

The live forcing buffers of `prob`: every `param_arrays` entry and every
[`DiscreteMaterializer`](/generated/api/extension/julia#x-discretematerializer) cache the build bound, in a STABLE (name-sorted)
order, each value the ALIASED flat host view of the exact array the build bound
— not a copy, so a discrete-cadence refresh writing the original array is
visible through this container. Empty for a document with no live forcing.

The Problem publishes it whatever compiler built it. Position of a name is
[`forcing_buffer_index`](/generated/api/extension/julia#x-forcing_buffer_index)`(prob)[name]`, and
[`sync_forcing!`](/generated/api/extension/julia#x-sync_forcing) mirrors the container into a compiled program's device
arrays at a cadence boundary.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/tree_walk/oop.jl#L579)

### `forcing_epoch` {#x-forcing_epoch}

*function* · canonical name `forcing_epoch`

```julia
forcing_epoch(fs::ForcingSet)
```

```julia
forcing_epoch(fs::ForcingSet) -> UInt64
```

The set's epoch: unique in the process, never reused.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/rhs_program.jl#L241)

### `forcing_reach` {#x-forcing_reach}

*function* · canonical name `forcing_reach`

```julia
forcing_reach(ir::OperatorIR)
forcing_reach(ir::OperatorIR, origin)
```

```julia
forcing_reach(ir::OperatorIR[, origin])
```

The rectangular global-coordinate forcing windows of a tile, in
[`forcing_slots`](/generated/api/extension/julia#x-forcing_slots) order. Each entry is a vector of inclusive ranges, one
per source dimension, or `nothing` for an unused source. A source read at
addresses that cannot be bounded statically may require its whole extent.
Flatten each window column-major before passing it to a StableHLO fragment,
using an empty tensor for an unused source. For a tile class,
pass the actual owned-box origin to get that member's windows.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/operator_ir.jl#L359)

### `forcing_slots` {#x-forcing_slots}

*function* · canonical name `forcing_slots`

```julia
forcing_slots(ir::OperatorIR)
forcing_slots(x)
forcing_slots(ks::KernelSet)
```

```julia
forcing_slots(x) -> Vector{ForcingSlot}
```

The buffers a [`ForcingSet`](/generated/api/ref/forcing_set-type) of `x` (a program, a tile or a lane program)
holds, in ascending byte order of flattened name. A derived program has its
parent's slots.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/rhs_program.jl#L166)

### `GapReport` {#x-gapreport}

*type* · canonical name `gap_report`

```julia
struct GapReport
GapReport(bead_id::String, description::String, location::String)
GapReport(bead_id, description, location)
```

```julia
GapReport
```

Structured record of schema-gap constructs encountered while exporting an
MTK system to ESM. The migration tool uses these to attach `TODO_GAP`
notes and to emit `@warn`s listing the gaps, so callers know which constructs
need hand migration.

Each entry carries:
- `bead_id`: the gap's category (`"pde_domain"`, `"sde_noise_eqs"`,
  `"initialization_equations"`, `"unknown_operator"`, …; `"unknown"` for a
  construct that failed to serialize)
- `description`: human-readable one-liner (shown in warnings and JSON)
- `location`: location hint (variable or equation index) for the user

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/mtk_export.jl#L13)

### `gather_flat!` {#x-gather_flat}

*function* · canonical name `gather_flat`

```julia
gather_flat!(u::AbstractVector, g::VarGridding, grid::AbstractArray)
```

```julia
gather_flat!(u, g::VarGridding, grid) -> u
```

The inverse of [`scatter_grid!`](/generated/api/extension/julia#x-scatter_grid): read a variable's gridded `grid` back into
the flat state `u`, `u[flat_indices[k]] = grid[cart[k]]`. This is the restart-read
direction (streaming-output-sinks RFC §10, §16.7) — reconstruct a flat `u0` from a
checkpoint store's gridded arrays. `grid` must have size `Tuple(g.shape)`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/output_plan.jl#L184)

### `gather_lane_inputs!` {#x-gather_lane_inputs}

*function* · canonical name `gather_lane_inputs`

```julia
gather_lane_inputs!(li::EarthSciAST.LaneInputs, lp::EarthSciAST.LaneProgram, p, t, fs::ForcingSet, cells::AbstractMatrix, n::Integer)
```

```julia
gather_lane_inputs!(li::LaneInputs, lanes::LaneProgram, p, t, fs, cells, n) -> li
```

Fill `li` for the first `n` lanes of `cells` (an `Int32` `[D, L]` matrix, rows in
the program's lane-set order); lanes past `n` take lane `n`'s inputs. `li` must
come from [`lane_inputs`](/generated/api/extension/julia#x-lane_inputs)`(lanes, L)` and `fs` be a [`ForcingSet`](/generated/api/ref/forcing_set-type)
of `lanes`. A gather that throws leaves `li` holding no gather, so `rhs!`
refuses it until a gather finishes.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/range/lanes.jl#L968)

### `gather_lanes` {#x-gather_lanes}

*function* · canonical name `gather_lanes`

```julia
gather_lanes(ir, u, cells)
```

Within a Reactant trace, gather the writable blocks of the whole-domain state
`u` into the lane layout of `ir`. Cell coordinates are 1-based and may repeat.
`cells` is a traced input, so its range cannot be checked: a lane whose cell
lies outside the domain reads an unspecified element of `u`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/operator_ir.jl#L396)

### `get_expression_dimensions` {#x-get_expression_dimensions}

*function* · canonical name `get_expression_dimensions`

```julia
get_expression_dimensions(expr::ASTExpr, var_units::AbstractDict; dimensionless_literals)
```

Get the dimensions of an expression by propagating units through operations.

This performs dimensional analysis to determine the units that result from
evaluating an expression, assuming all variables have known units.

Returns `nothing` when the dimensions cannot be determined — for variables
absent from `var_units` (unknown, NOT assumed dimensionless), for operators
without a dimensional rule, and for a subtree that is provably inconsistent.
Because those three cases share one return value, `nothing` alone tells you
nothing about *validity*; any provable inconsistency found along the way is
reported here as a `@warn` and, for programmatic use, is available from
[`expression_unit_findings`](/generated/api/extension/julia#x-expression_unit_findings).

`dimensionless_literals` switches on the esm-spec §4.8.6 literal rule, as for
[`expression_unit_findings`](/generated/api/extension/julia#x-expression_unit_findings).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/units.jl#L2353)

### `has_spatial_derivative` {#x-has_spatial_derivative}

*function* · canonical name `has_spatial_derivative`

```julia
has_spatial_derivative(model::Model)
```

```julia
has_spatial_derivative(model::Model) -> Bool
```

True iff some equation of `model` contains a spatial derivative anywhere in its
LHS or RHS — a `D` whose `wrt` is present and is not `"t"` (esm-spec §6.3.1).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/classification.jl#L393)

### `has_time_derivative` {#x-has_time_derivative}

*function* · canonical name `has_time_derivative`

```julia
has_time_derivative(model::Model)
```

```julia
has_time_derivative(model::Model) -> Bool
```

True iff some equation of `model` contains a structural time derivative
(`D` with `wrt` `"t"` or absent) anywhere in its LHS or RHS.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/classification.jl#L402)

### `infer_array_shapes` {#x-infer_array_shapes}

*function* · canonical name `infer_array_shapes`

```julia
infer_array_shapes(equations::Vector{Equation})
```

```julia
infer_array_shapes(equations::Vector{Equation}) -> Dict{String, Vector{UnitRange{Int}}}
```

Walk every `faq`, `makearray`, and `index` node in the equation set and
compute, for each array-shaped variable, the union of ranges observed across
all references. The result maps variable name → per-axis `UnitRange{Int}`
vector (empty for scalar variables; one entry per dimension for array
variables). Only variables that actually appear inside an array operator get
a shape — scalar variables are absent from the result dict.

Semantics:
- For a `VarExpr` appearing as the first argument of an `index` node, each
  subsequent argument is an index expression (literal int, symbolic index
  name, or affine offset like `i+1`). The range of that index determines the
  variable's length on that axis. Affine offsets widen the required range
  (e.g. `u[i-1]` and `u[i+1]` in `i in 2:9` force `u` to span `1:10`).
- For a `faq`, its `output_idx` and `ranges` combined define the
  iteration space. Index names with no explicit range are left for
  inference from their usages inside the body.
- Conflicts: if a variable is referenced with inconsistent dimensionality
  across equations, this function raises a [`SimulateError`](/generated/api/ref/simulate_error) with code
  `array_shape_mismatch`.

This pass is deliberately standalone — it does not mutate `FlattenedSystem`.
It is called at ModelingToolkit build time from `ext/mtk_ext/variables.jl` so
scalar-only callers pay no cost.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/array_shape_inference.jl#L9)

### `infer_variable_units` {#x-infer_variable_units}

*function* · canonical name `infer_variable_units`

```julia
infer_variable_units(var_name::AbstractString, equations::Vector{Equation}, known_units::AbstractDict)
```

Infer appropriate units for a variable based on its usage in equations.

This can help suggest units when they are not explicitly specified.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/units.jl#L2941)

### `IntExpr` {#x-intexpr}

*type* · canonical name `int_expr`

```julia
struct IntExpr <: ASTExpr
IntExpr(value::Int64)
IntExpr(value)
```

```julia
IntExpr(value::Int64)
```

Integer numeric literal expression. Represents a JSON number whose
mathematical value is integral and `Int64`-representable, **regardless of how
the source document spelled the token** (`0.0` → `IntExpr(0)`, `2.5e1` →
`IntExpr(25)`; CONFORMANCE_SPEC §5.5.3.1 rules 1/3). The AST distinguishes
integer and float nodes: `IntExpr(1)` and `NumExpr(1.0)` are different values,
and canonicalization never auto-promotes one to the other (RFC §5.4.1); on the
wire an `IntExpr` serializes as an integer literal (no `.`/`e`).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/types.jl#L119)

### `ir_layout` {#x-ir_layout}

*function* · canonical name `ir_layout`

```julia
ir_layout(ir::OperatorIR)
```

The state, auxiliary and output layout of an [`operator_ir`](/generated/api/extension/julia#x-operator_ir) build.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/operator_ir.jl#L339)

### `is_literal` {#x-is_literal}

*function* · canonical name `is_literal`

```julia
is_literal(expr::ASTExpr)
```

```julia
is_literal(expr::ASTExpr)::Bool
```

True iff `expr` is a numeric literal (either integer or float node).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/expression.jl#L776)

### `is_valid_identifier` {#x-is_valid_identifier}

*function* · canonical name `is_valid_identifier`

```julia
is_valid_identifier(name::String)
```

```julia
is_valid_identifier(name::String) -> Bool
```

Check if a string is a valid identifier (letters, numbers, underscores, no leading digit).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/qualified_reference.jl#L209)

### `kernel!` {#x-kernel}

*function* · canonical name `kernel`

```julia
kernel!(out::AbstractVector, k::Kernel, ws::KernelWorkspace, u::AbstractVector, z::AbstractVector, p::AbstractVector, t, dt, fs::ForcingSet)
```

```julia
kernel!(out, k::Kernel, ws::KernelWorkspace, u, z, p, t, dt, fs::ForcingSet) -> out
```

Evaluate kernel `k` (API_SPEC §5.8, "The kernel ABI"): `u` and `z` in the
kernel set's layouts, `p` its parameter vector, `fs` a forcing set for its
slots; the kernel's `dt_params` read `dt`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/strip_expose.jl#L722)

### `kernel_layout` {#x-kernel_layout}

*function* · canonical name `kernel_layout`

```julia
kernel_layout(k::Kernel)
```

```julia
kernel_layout(k::Kernel) -> Vector{KernelBlock}
```

One block per output, in spec order; a map kernel's is the `u` layout.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/strip_expose.jl#L702)

### `kernel_workspace` {#x-kernel_workspace}

*function* · canonical name `kernel_workspace`

```julia
kernel_workspace(k::Kernel)
```

```julia
kernel_workspace(k::Kernel) -> KernelWorkspace
```

The buffers of [`kernel!`](/generated/api/extension/julia#x-kernel) on `k`, one per concurrent caller.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/strip_expose.jl#L709)

### `KernelOutputs` {#x-kerneloutputs}

*type* · canonical name `kernel_outputs`

```julia
struct KernelOutputs
KernelOutputs(spec::S, out_eltype) where {S}
KernelOutputs(spec; out_eltype)
```

```julia
KernelOutputs(spec; out_eltype = nothing)
```

A single [`compile_kernels`](/generated/api/ref/compile_kernels) specification for an output fragment.
Optionally cast the returned blocks to `Float16`, `Float32` or `Float64`.
With Reactant loaded, `BFloat16` is also supported.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/operator_ir.jl#L51)

### `lane_inputs` {#x-lane_inputs}

*function* · canonical name `lane_inputs`

```julia
lane_inputs(lp::EarthSciAST.LaneProgram, L::Integer)
```

```julia
lane_inputs(lanes::LaneProgram, L::Integer) -> LaneInputs
```

Buffers for the non-state inputs of an `L`-lane batch: each lane set's global
index and every pre-gathered array read. Fill them with
[`gather_lane_inputs!`](/generated/api/extension/julia#x-gather_lane_inputs).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/range/lanes.jl#L899)

### `lane_layout` {#x-lane_layout}

*function* · canonical name `lane_layout`

```julia
lane_layout(lp::EarthSciAST.LaneProgram)
```

```julia
lane_layout(lanes::LaneProgram) -> LaneLayout
```

The `u`/`aux` lane layout (API_SPEC §5.8, "Lanes"): element `e` of variable `v`
for lane `l` of an `L`-lane batch is at slot `(offset_v + e - 1)·L + l`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/range/lanes.jl#L883)

### `Lanes` {#x-lanes}

*type* · canonical name `lanes`

```julia
struct Lanes
Lanes(kind::Symbol, sets, capacity::Integer)
```

```julia
Lanes(kind, sets, capacity)
```

A fixed-capacity lane target for [`operator_ir`](/generated/api/extension/julia#x-operator_ir). The lane sets and kind
are those accepted by [`lanes`](/generated/api/ref/lanes).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/operator_ir.jl#L33)

### `literal_value` {#x-literal_value}

*function* · canonical name `literal_value`

```julia
literal_value(expr::NumExpr)
literal_value(expr::IntExpr)
```

```julia
literal_value(expr::ASTExpr)
```

Return the numeric value of a literal node, as `Float64`. Throws on non-literals.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/expression.jl#L783)

### `mass_action_rate` {#x-mass_action_rate}

*function* · canonical name `mass_action_rate`

```julia
mass_action_rate(reaction::Reaction, species::Vector{Species})
```

```julia
mass_action_rate(reaction::Reaction, species::Vector{Species}) -> ASTExpr
```

The mass-action rate law of `reaction` (esm-spec §7.4): its `rate`, the rate
coefficient `k`, times `∏ Sᵢ^nᵢ` over its substrates; the coefficient alone for
a source reaction (no substrates). `species` is not read.

**Examples**
```julia
# For reaction A + B -> C with rate="k":
# Returns: k * A * B
#
# For source reaction -> A with rate="k":
# Returns: k
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/reactions.jl#L142)

### `model_unit_findings` {#x-model_unit_findings}

*function* · canonical name `model_unit_findings`

```julia
model_unit_findings(model::Model; file, toplevel, indep)
```

```julia
model_unit_findings(model::Model; file=nothing, toplevel=nothing, indep="t") -> Vector{UnitFinding}
```

Every unit ERROR in `model`'s own sites (not its subsystems), each with a
`subpath` relative to the model's JSON pointer: the checker
`_component_unit_findings!` documents. A scoped reference (`sub.v`,
`Leaf.p`) has the units its target declares: relative to `model`'s own
subsystems always, and to the top-level models and reaction systems of `file`
when one is given (see `scoped_reference_units`); a caller checking
many components passes the document-wide map
`toplevel = _toplevel_scoped_units(file)` once instead. `indep` is the
document's independent variable.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/units.jl#L2783)

### `ModelVariableType` {#x-modelvariabletype}

*type* · canonical name `model_variable_type`

```julia
struct ModelVariableType <: Enum
ModelVariableType(x::Integer)
```

```julia
@enum ModelVariableType
```

The **two** declared variable types of esm 1.0.0 (esm-spec §6.3) — and there is
no third:

- `UnknownVariable`: a quantity the solver solves for. Its behaviour is stated
  by the model's `equations` and **nowhere else**; there is no `expression`
  field on a variable.
- `ParameterVariable`: a quantity supplied to the solver. Its value is
  `default` or a [`Distribution`](/generated/api/ref/distribution), optionally refreshed by a
  [`ParameterUpdate`](/generated/api/ref/parameter_update).

Everything else a solver needs is DERIVED, not declared. Which unknowns are ODE
states, observed, or algebraic follows from the equations; which parameters are
Brownian, discrete, sampled, or constant follows from `distribution` and
`update`. Ask those questions through the classification API of esm-spec
§6.3.1 — [`ode_states`](/generated/api/ref/ode_states), [`observed_unknowns`](/generated/api/ref/observed_unknowns),
[`algebraic_unknowns`](/generated/api/ref/algebraic_unknowns), [`is_ode_state`](/generated/api/ref/is_ode_state),
[`brownian_parameters`](/generated/api/ref/brownian_parameters), [`discrete_parameters`](/generated/api/ref/discrete_parameters),
[`sampled_parameters`](/generated/api/ref/sampled_parameters), [`constant_parameters`](/generated/api/ref/constant_parameters),
[`system_kind`](/generated/api/ref/system_kind-function) — never by reading a declared type.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/types.jl#L829)

### `mtk2esm` {#x-mtk2esm}

*function* · canonical name `mtk2esm`

```julia
mtk2esm(sys; kwargs...)
```

```julia
mtk2esm(sys; metadata=(;))
```

Export a ModelingToolkit system to an ESM-format `Dict{String,Any}` suitable
for JSON serialization. The concrete dispatch lives in
`EarthSciASTMTKExt` / `EarthSciASTCatalystExt`.

**Arguments**
- `sys`: an MTK `System` / `ODESystem` / `ReactionSystem` / `SDESystem` /
  `NonlinearSystem` / `PDESystem`, or a Catalyst `ReactionSystem`.

**Keyword arguments**
- `metadata`: NamedTuple-like of migration metadata. Recognized fields:
  `tags` (`Vector{String}`), `source_ref` (`String`), `description`
  (`String`), `authors` (`Vector{String}`), `version` (`String`),
  `name` (overrides `nameof(sys)`).

**Returns**
A `Dict{String,Any}` shaped like a full ESM file: `esm`, `metadata`, and
either `models.<name>` or `reaction_systems.<name>`. Any schema-gap
constructs produce `TODO_GAP` entries inside the emitted component's
`metadata.notes` field plus an `@warn` listing the gaps.

Raises a clear `ArgumentError` if the MTK/Catalyst extension hasn't been
loaded — the stub in `src/mtk_export.jl` has no way to walk an MTK system
on its own.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/mtk_export.jl#L34)

### `mtk2esm_gaps` {#x-mtk2esm_gaps}

*function* · canonical name `mtk2esm_gaps`

```julia
mtk2esm_gaps(sys)
```

```julia
mtk2esm_gaps(sys)
```

Internal helper: returns a `Vector{GapReport}` for any schema-gap constructs
found in `sys` without running the full export. Useful for pre-flight
checks. Extensions override this with concrete implementations.

Raises a clear `ArgumentError` if the MTK extension hasn't been loaded.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/mtk_export.jl#L75)

### `n_states` {#x-n_states}

*function* · canonical name `n_states`

```julia
n_states(x::Union{EarthSciAST.RhsProgram, EarthSciAST.TileProgram})
```

```julia
n_states(prog) -> Int
```

The length of `u` (API_SPEC §5.8, "States and parameters").

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/rhs_program.jl#L1345)

### `NumExpr` {#x-numexpr}

*type* · canonical name `num_expr`

```julia
struct NumExpr <: ASTExpr
NumExpr(value::Float64)
NumExpr(value)
```

```julia
NumExpr(value::Float64)
```

Floating-point numeric literal expression. Represents a JSON number whose
mathematical value is **non-integral** (or integral but not `Int64`-
representable): literal type is decided by *value*, not by the token's source
spelling (CONFORMANCE_SPEC §5.5.3.1 rules 1/3). A JSON number whose value is
integral and `Int64`-representable — however it was spelled (`1`, `1.0`,
`2.5e1`) — parses as an `IntExpr`, so `expression_from_json` never produces
`NumExpr(1.0)`; such a node can only be built directly in Julia code.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/types.jl#L104)

### `operator_ir` {#x-operator_ir}

*function* · canonical name `operator_ir`

```julia
operator_ir(prob::EsmProblem; select, target, outputs, unspecified_eltype)
operator_ir(prog::EarthSciAST.RhsProgram; target, unspecified_eltype)
```

```julia
operator_ir(prob; select = RhsSelection(), target = Whole(), outputs = :du, unspecified_eltype = Float64)
operator_ir(prog::RhsProgram; target = Whole(), unspecified_eltype = Float64)
```

Build the out-of-place tree-walk IR for a selected operator. Its state and
forcing tensors are described by [`ir_layout`](/generated/api/extension/julia#x-ir_layout), [`parameter_names`](/generated/api/ref/parameters)
and [`forcing_slots`](/generated/api/extension/julia#x-forcing_slots). With `outputs = KernelOutputs(spec)`, compile the
named kernel against the Problem, using its `u` and `z` inputs.
Set `unspecified_eltype = Float32` to build a binary32 fragment for a group
whose variables all resolve to Float32 under esm-spec §11.3.3.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/operator_ir.jl#L194)

### `OperatorIR` {#x-operatorir}

*type* · canonical name `operator_ir`

```julia
struct OperatorIR
OperatorIR(f::F, layout::L, maps::M, target::T, extra::E, params::Vector{String}, forcing::Vector{ForcingSlot}, kernel::K, working_eltype::Type{W}, binary64_keys::Vector{String}) where {F, L, M, T, E, K, W}
OperatorIR(f, layout, maps, target, extra, params, forcing)
OperatorIR(f, layout, maps, target, extra, params, forcing, kernel)
```

Host-side tree-walk IR and input layouts for [`emit_fragment`](/generated/api/extension/julia#x-emit_fragment).
`W` is the working precision, `Float32` or `Float64`. `binary64_keys` names
the declared-Float64 parameters a binary32 operator reads only as `==`/`!=`
operands; their comparisons run in binary64 (esm-spec §11.3.3 P8).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/operator_ir.jl#L70)

### `OpExpr` {#x-opexpr}

*type* · canonical name `op_expr`

```julia
mutable struct OpExpr <: ASTExpr
OpExpr(op::String, args::AbstractVector; kwargs...)
OpExpr(op::String, args::Vector{ASTExpr}; wrt, dim, int_var, lower, upper, output_idx, expr_body, reduce, semiring, ranges, regions, values, shape, perm, axis, fn, name, value, units, join, filter, join_gates, id, distinct, key, bindings, expect_cadence, attrs, template_origin)
```

```julia
OpExpr(op::String, args::Vector{ASTExpr}; kwargs...)
OpExpr(op::String, args::AbstractVector; kwargs...)
```

Operator expression node. `op` and `args` are positional; every other field is
an optional keyword (default `nothing`) that only some operators use. The
`AbstractVector` method converts `args` to `Vector{ASTExpr}`. Fields:
- `op`: operator name (e.g., "+", "*", "log", "D", "faq")
- `args`: vector of argument expressions
- `wrt`: variable name for differentiation (optional; for `D`)
- `dim`: dimension for spatial operators (optional; for `bc`, `integral`, user ops)
- `int_var`: integration variable name (optional; for `integral`, matches JSON field "var")
- `lower`: lower integration bound expression (optional; for `integral`)
- `upper`: upper integration bound expression (optional; for `integral`)
- `output_idx`: for `faq`, list of result index symbols (String) or literal
  singleton dimensions (Int 1). Mirrors SymbolicUtils.ArrayOp.output_idx.
- `expr_body`: for `faq`, the scalar body evaluated at each index point
  (a nested `ASTExpr` tree); the wire key is `"expr"`. Named `expr_body` so the
  field is not confused with Julia's own `Core.Expr`.
- `reduce`: for `faq`, the reduction operator applied to
  contracted indices (one of "+", "*", "max", "min"; default "+"). Names the
  semiring ⊕ only, for files that omit `semiring`.
- `semiring`: for `faq`, the named semiring `(⊕, ⊗)` with
  normative identity elements that parameterizes the reduction (closed registry:
  "sum_product", "max_product", "min_sum", "max_sum", "bool_and_or"). Absent ⇒
  "sum_product", the ordinary einsum semantics. When present it supersedes
  `reduce`; the ⊕/⊗ operators and both identities come from the registry table,
  never the file.
- `ranges`: for `faq`, map from index symbol name to iteration range
  (vector of 2 or 3 ints `[start, stop]` / `[start, step, stop]`).
- `regions`: for `makearray`, list of sub-region boxes, each a list of
  `[start, stop]` pairs per output dimension. A bound is normally an `Int`
  (metaparameters are folded on the raw tree before typed coercion,
  esm-spec §9.7.6), but the schema admits any `MetaparameterExpression`, so a
  bound MAY also be an `ASTExpr` — that is how a still-open bound such as
  `NLON - 1` survives the typed round-trip.
- `values`: for `makearray`, one sub-expression per entry in `regions`.
- `shape`: for `reshape`, target shape; entries are `Int` (concrete length)
  or `String` (symbolic dimension).
- `perm`: for `transpose`, optional 0-based axis permutation.
- `axis`: for `concat`, 0-based axis to concatenate along.
- `fn`: for `broadcast`, the scalar operator to apply element-wise.
- `name`: for `apply_expression_template`, the template name (esm-spec §9.6).
- `value`: for the `const` op, the inline literal value carried by this node.
  Any JSON value (number, integer, or nested array thereof); `args` MUST be
  empty for a const node.
- `units`: for `const`, the declared unit of `value` (esm-spec §4.8.5).
- `join`, `filter`: for `faq`, the equi-join clauses (each a list of
  `[left, right]` key-column pairs that must compare equal) and an optional
  boolean predicate; a combination for which the predicate is false contributes
  the additive identity.
- `join_gates`: internal, build-time resolution of `join`; never parsed or
  serialized.
- `id`: the node-local identifier a `kind: "derived"` index set names through
  `from_faq`.
- `distinct`, `key`: for a value-inventing `faq`, whether it produces a
  deduplicated index set, and the scalar integer key expression it emits per
  surviving index combination.
- `bindings`: for `apply_expression_template`, the parameter → argument
  expression map (esm-spec §9.6).
- `expect_cadence`: an optional author assertion of this node's cadence class
  (`"const"`, `"discrete"` or `"continuous"`); carried verbatim, and an error is
  raised only when the derived class disagrees.
- `attrs`: named scalar attributes of an open rewrite-target op (esm-spec
  §4.2), such as a custom scheme's parameters.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/types.jl#L283)

### `output_var_dims` {#x-output_var_dims}

*function* · canonical name `output_var_dims`

```julia
output_var_dims(g::VarGridding, time_dim::AbstractString)
```

```julia
output_var_dims(g::VarGridding, time_dim) -> Vector{String}
```

One variable's ON-DISK dimension list: the record axis first, then its spatial
axes. A scalar's dims are exactly `[time_dim]`. The single place this order is
decided — see the section comment above for why the record axis leads.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/output_plan.jl#L683)

### `param_map` {#x-param_map}

*function* · canonical name `param_map`

```julia
param_map(p::NamedTuple)
param_map(::Nothing)
```

```julia
param_map(p) -> Dict{String,Int}
```

Parameter NAME → its position in a parameter VECTOR, the `p`-side mirror of the
`var_map` an [`esm_problem`](/generated/api/ref/esm_problem-function) Problem carries for the state.

Take it from the Problem's `p`:

```julia
prob = esm_problem(doc, tspan)
pm = param_map(prob.p)             # "k_diff" => 1, "k_rxn" => 3, …
θ  = ComponentVector(prob.p)       # the same order, as an AbstractVector
prob.f!(du, u, θ, t)               # …and it is accepted as `p`
```

The Problem already carries `p`, so this is a FUNCTION OF `p` rather than a
second field that would have to be kept in step with it. That costs nothing
in fidelity: the order is the build's own (`param_names` is sorted, and the `p`
NamedTuple is built from it in that order), and `keys(p)` IS that order, so this
map and the `idx` baked into every `_NK_PARAM` node are the same numbering by
construction rather than by agreement.

A parameter-free model carries SciMLBase's `nothing` sentinel as `p` and maps to
the empty Dict.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/tree_walk/build_front_doors.jl#L127)

### `parameter_classes` {#x-parameter_classes}

*function* · canonical name `parameter_classes`

```julia
parameter_classes(prob::EsmProblem)
parameter_classes(insp::BuildInspection)
```

```julia
parameter_classes(x) -> Dict{String,Symbol}
```

Parameter NAME → what KIND of parameter it is in the build that produced `x`
(a [`BuildInspection`](/generated/api/extension/julia#x-buildinspection) or an `EsmProblem`). Four classes:

| class | where its value is consumed | overridable at solve time? |
|---|---|---|
| `:numeric` | the runtime `p` vector | **yes** — swap `p` (`remake`), differentiable |
| `:structural` | BUILD time (setup geometry, value-invention extents, binning coordinates, join key columns, `ic()` folds) | no — rebuild the problem |
| `:const_folded` | frozen into the build's const arrays and inlined into the RHS | no — rebuild with new data |
| `:forcing` | a live buffer a discrete provider rewrites in place | no — write the buffer |

The partition is **derived, not declared**: every one of these is spelled
`"type": "parameter"` in the document, so the discriminator is where the value is
CONSUMED. The build records the names its build-time consumers resolve (see the
`_record_param_read` seam) and anything they touched is `:structural` — by
construction, not by a second static reading of the document.

`:structural` is per NAME, not per use: a name read once at build stays
structural even when the RHS also reads it at runtime, because the value baked
into the build and the value in `p` would then disagree.

`:const_folded` deserves its own name rather than being folded into
`:structural`: differentiating w.r.t. one returns an unconditional ZERO, and a
finite-difference check on its declared default CONFIRMS that zero (perturbing
the default changes nothing either) — a wrong gradient and a wrong check
agreeing silently. It is refused explicitly, with its own message.

Like [`param_map`](/generated/api/extension/julia#x-param_map) this is a function of an artifact rather than an extra
return value. Pass `inspect = BuildInspection()` to `esm_problem`, or read it
off the `EsmProblem` that `esm_problem` returns.

```julia
prob = esm_problem("model.esm", tspan)
cls  = parameter_classes(prob)
θ    = [n for (n, c) in cls if c === :numeric]     # what a gradient may target
solve(remake(prob; p = Dict(θ[1] => 2.0)), Tsit5())
```

---

```julia
parameter_classes(prob::EsmProblem) -> Dict{String,Symbol}
```

The parameter partition of the build behind `prob` — `:numeric`, `:structural`,
`:const_folded`, `:forcing`. See the [`parameter_classes`](/generated/api/extension/julia#x-parameter_classes) docstring on the
[`BuildInspection`](/generated/api/extension/julia#x-buildinspection) method for what each class means and how it is derived.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/tree_walk/build_front_doors.jl#L158)

### `PARAMETER_UPDATE_KINDS` {#x-parameter_update_kinds}

*constant* · canonical name `parameter_update_kinds`

```julia
const PARAMETER_UPDATE_KINDS::NTuple{6, String}
```

```julia
PARAMETER_UPDATE_KINDS
```

The closed set of `update.kind` values (esm-spec §5.4). `wiener` takes no value
form and requires the parameter's `distribution`; the other five take exactly
one of `expression` / `from` / `handler`. `schedule`, `data`, and `remesh`
additionally require the parameter to declare a `shape`, because such a
parameter is a buffer refilled on a discrete cadence.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/types.jl#L766)

### `parameter_vector` {#x-parameter_vector}

*function* · canonical name `parameter_vector`

```julia
parameter_vector(x)
parameter_vector(x, overrides::AbstractDict)
parameter_vector(ks::KernelSet)
parameter_vector(ks::KernelSet, overrides::AbstractDict)
```

```julia
parameter_vector(prog, overrides = Dict()) -> Vector{Float64}
```

The parameter vector of `prog` in [`parameters`](/generated/api/ref/parameters) order: each entry the
override named for it, else its default. Strict: an override naming no
parameter, or a parameter with neither, is an error naming it.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/rhs_program.jl#L252)

### `ParameterVariable` {#x-parametervariable}

*type* · canonical name `parameter_variable`

```julia
const ParameterVariable::ModelVariableType
```

```julia
ParameterVariable::ModelVariableType
```

A variable supplied to the solver (wire spelling `"parameter"`, esm-spec §6.3):
its value is `default` or a [`Distribution`](/generated/api/ref/distribution), optionally refreshed by a
[`ParameterUpdate`](/generated/api/ref/parameter_update). Whether it is constant, sampled, discrete or
Brownian is derived from those fields; see [`constant_parameters`](/generated/api/ref/constant_parameters),
[`sampled_parameters`](/generated/api/ref/sampled_parameters), [`discrete_parameters`](/generated/api/ref/discrete_parameters) and
[`brownian_parameters`](/generated/api/ref/brownian_parameters), and [`parameters`](/generated/api/ref/parameters) for all of them.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/types.jl#L867)

### `parse_units` {#x-parse_units}

*function* · canonical name `parse_units`

```julia
parse_units(unit_str::AbstractString)
```

```julia
parse_units(unit_str) -> Union{Unitful.Units, Nothing}
```

Resolve a unit string against the ESM registry (esm-spec §4.8.1) using the ESM
grammar (§4.8.2):

    unit     := term (('*' | '/')? term)*
    term     := atom (('^' | '**') exponent)?
    exponent := '-'? (integer | decimal) | '(' '-'? integer '/' '-'? integer ')'
    atom     := '1' | symbol | '(' unit ')'

A symbol is a whole run of `[A-Za-z0-9_]` (or `%`) and must be a table key;
the only numeric atom is the literal `1`. Whitespace between terms is
multiplication (`"ppb^-1 s^-1"`); division is LEFT-associative (`"L/mol/s"` is
L·mol⁻¹·s⁻¹); parentheses group a compound denominator (`"J/(mol*K)"`). An
exponent may be RATIONAL — `"1/s^0.5"` is the noise intensity of an SDE.

Normalised before parsing: `µ`/`μ`→`u`, `°C`→`degC`, `°F`→`degF`, `Ω`→`Ohm`,
`·`/`⋅`→`*`, and superscript runs (`m²`, `cm³`, `m⁻³`) → `^n`. `""`, `"1"` and
`"dimensionless"` are the dimensionless unit.

The string is parsed once, by the parser the canonical spelling uses
(`_unit_factors`), and its factor list is resolved through the registry. A
string that is a single symbol to the first power (`"degC"`, `"(degC)"`) is the
registry entry itself, so a standalone affine unit keeps its identity; inside a
composition an affine unit is its absolute counterpart (`_linear`).

Returns `nothing` when the string does not parse or names a symbol outside the
registry. That is a DEFECT IN THE FILE, not a limit of the checker: the
structural validator promotes it to a hard `unit_parse_error` (§4.8.4). It is
silent here — the caller decides the severity.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/units.jl#L341)

### `parse_units_reason` {#x-parse_units_reason}

*function* · canonical name `parse_units_reason`

```julia
parse_units_reason(unit_str::AbstractString)
```

```julia
parse_units_reason(unit_str) -> Union{String, Nothing}
```

WHY [`parse_units`](/generated/api/extension/julia#x-parse_units) returned `nothing`, or `nothing` when it did not.

`parse_units` is deliberately silent — the caller owns the severity (§4.8.4) —
but one rejection has a reason an author cannot guess from the string: a
numeric SCALING FACTOR. `"(m/s)^-1/3"` LOOKS like a rational exponent and the
§4.8.2 grammar reads it as `((m/s)^-1)/3`. This accessor exists so that reason
can be surfaced and pinned (`tests/conformance/unit_registry`) without changing
the corpus-pinned `unit_parse_error` message text.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/units.jl#L323)

### `PASS` {#x-pass}

*constant* · canonical name `pass`

```julia
const PASS::AssertionStatus
```

```julia
PASS::AssertionStatus
```

The assertion's sampled value is within its resolved `rtol` / `atol` of the
expected value. An [`AssertionResult`](/generated/api/ref/assertion_result) with this status has
`r.passed == true`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/run_tests.jl#L62)

### `PeriodicTrigger` {#x-periodictrigger}

*type* · canonical name `periodic_trigger`

```julia
struct PeriodicTrigger <: DiscreteEventTrigger
PeriodicTrigger(period::Float64; phase)
```

```julia
PeriodicTrigger(period::Float64; phase = nothing)
```

Trigger that fires periodically.
- `period`: the wire `interval`, the time between firings
- `phase`: the wire `initial_offset`, the time offset of the first firing;
  `nothing` when the document does not write it (the schema default is 0), so
  an authored `0` is written back and an absent key stays absent

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/types.jl#L551)

### `predecessors` {#x-predecessors}

*function* · canonical name `predecessors`

```julia
predecessors(graph::Graph{N, E}, node::N) where {N, E}
```

Get nodes that point to this node, each ONCE.

Deduplicated: two parallel edges between the same pair (a pair of
`variable_map` couplings between the same two components, or two equations of
one model that read the same variable) name one predecessor, not two. This
returns a NODE SET, unlike [`adjacency`](/generated/api/extension/julia#x-adjacency), which pairs each neighbour with
the edge that reaches it and so legitimately repeats a neighbour per edge.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/graph.jl#L90)

### `PresetTimesTrigger` {#x-presettimestrigger}

*type* · canonical name `preset_times_trigger`

```julia
struct PresetTimesTrigger <: DiscreteEventTrigger
PresetTimesTrigger(times)
```

```julia
PresetTimesTrigger(times::Vector{Float64})
```

Trigger that fires at preset times.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/types.jl#L568)

### `provider_extent_metaparameter` {#x-provider_extent_metaparameter}

*function* · canonical name `provider_extent_metaparameter`

```julia
provider_extent_metaparameter(::Any)
provider_extent_metaparameter(p::EarthSciAST._RekeyedProvider)
```

```julia
provider_extent_metaparameter(provider) -> Union{Nothing,String}
```

The metaparameter this provider's own EXTENT binds (esm-spec §8.9.4), or
`nothing` (the default) for a provider whose size the document already knows.

A source whose record count is known only once it is read (a filtered record
table, say) declares `extent: {"metaparameter": "N_REC"}` on its loader.
[`esm_problem`](/generated/api/ref/esm_problem-function) samples such a provider once, before it closes
metaparameters (esm-spec §9.7.6), and the length of the delivered record axis
binds that metaparameter, so an index set declared `size: "N_REC"` is sized by
the data. Every provider naming the same metaparameter must report the same
count, and a caller binding that contradicts it is an error (CONFORMANCE_SPEC
§5.5).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/data_refresh.jl#L107)

### `provider_gate_spec` {#x-provider_gate_spec}

*function* · canonical name `provider_gate_spec`

```julia
provider_gate_spec(::Any)
provider_gate_spec(p::EarthSciAST._RekeyedProvider)
```

```julia
provider_gate_spec(provider) -> Union{Nothing,AbstractDict}
```

The projection-pushdown GATE for a deferred provider, or `nothing` (the default)
for an ordinary provider. A gated provider is not sampled whole by
[`esm_problem`](/generated/api/ref/esm_problem-function): its fetch waits until value invention has materialized
the gating derived set's members, which are then passed as a per-axis
`selection` ([`provider_sample`](/generated/api/extension/julia#x-provider_sample)) so only the compact slab is read.

The gate is `Dict("axes"=>[…], "applies_to"=>[names…])`, with one `axes` entry
per native array axis:

  * `"all"`                       → the whole axis;
  * `Dict("fixed"=>[i])`          → native 0-based index `i`, DROPPED (length-1);
  * `Dict("range"=>Dict("start"=>a, "stop"=>b, "step"=>s))`
                                  → the half-open 0-based window `[a, b)` by
                                    `s`, axis KEPT (`start`/`step` default 0/1);
  * `Dict("gated_by"=>"<set>")`   → the derived index set's materialised members
                                    (1-based), in the set's canonical order.

This is the loader `select` vocabulary of esm-spec §8.9.2, which
`desugar_pushdown` also generates. Only `gated_by` defers.
`applies_to` names the fetched variables to merge into `const_arrays`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/data_refresh.jl#L80)

### `provider_is_const` {#x-provider_is_const}

*function* · canonical name `provider_is_const`

```julia
provider_is_const(p)
provider_is_const(p::EarthSciAST._RekeyedProvider)
```

```julia
provider_is_const(provider) -> Bool
```

True if `provider`'s data is time-invariant (no cadence). CONST providers are
materialized once into `const_arrays` at `_build_evaluator` time and are absent
from the refresh callback. Defaults to "no refresh times"; a concrete impl may
override (e.g. EarthSciIO's `is_const`).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/data_refresh.jl#L57)

### `provider_is_gated` {#x-provider_is_gated}

*function* · canonical name `provider_is_gated`

```julia
provider_is_gated(p)
```

```julia
provider_is_gated(provider) -> Bool
```

True iff `provider` carries a projection-pushdown [`provider_gate_spec`](/generated/api/extension/julia#x-provider_gate_spec) —
i.e. its materialization must be DEFERRED past value-invention and delivered
pre-sliced to the compact derived axis, rather than pulled whole in the eager
const loop.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/data_refresh.jl#L189)

### `provider_refresh_times` {#x-provider_refresh_times}

*function* · canonical name `provider_refresh_times`

```julia
provider_refresh_times(p)
provider_refresh_times(p::EarthSciAST._RekeyedProvider)
```

```julia
provider_refresh_times(provider) -> AbstractVector{Float64}
```

The cadence anchors at which `provider`'s data changes, in solver time
(seconds on the integrator's `t` axis). Empty for a time-invariant
(CONST) provider — such a provider is materialized once and contributes no
tstops. Concrete impls live in the data binding (EarthSciIO) or a test mock.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/data_refresh.jl#L40)

### `provider_sample` {#x-provider_sample}

*function* · canonical name `provider_sample`

```julia
provider_sample(p, ::Real; selection)
provider_sample(p::EarthSciAST._RekeyedProvider, t::Real; selection)
```

```julia
provider_sample(provider, t::Real; selection=nothing) -> sample
```

The native-grid data for `provider` at cadence tick `t` (solver seconds). The
return value is an `AbstractDict` keyed by variable name, a bare `AbstractArray`
or a `Real` (a single-variable sample); see [`forcing_from_sample`](/generated/api/ref/forcing_from_sample).

`selection` is an optional per-axis projection pushdown: one positional entry
per native axis of the gated array(s). `nothing` (the default) samples the whole
array. Otherwise each entry is:

  * `Colon()`                         → the whole axis;
  * an `Integer i` (1-BASED)          → the single fixed index `i`;
  * an `AbstractVector{<:Integer}` (1-BASED) → that ordered list of indices.

The provider reads only the selected data. The gated axis of the returned array
is ordered exactly as the index vector (a permuted list yields permuted rows). A
`selection` may only be given to a provider whose
[`provider_supports_selection`](/generated/api/extension/julia#x-provider_supports_selection) is `true`; otherwise the binding errors.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/data_refresh.jl#L199)

### `provider_supports_selection` {#x-provider_supports_selection}

*function* · canonical name `provider_supports_selection`

```julia
provider_supports_selection(::Any)
provider_supports_selection(p::EarthSciAST._RekeyedProvider)
```

```julia
provider_supports_selection(provider) -> Bool
```

True if `provider` can honour a per-call `selection` (projection pushdown) in
[`provider_sample`](/generated/api/extension/julia#x-provider_sample) — i.e. it reads only the requested slice of the
native array rather than the whole thing. Defaults to `false`; the EarthSciIO
extension bridges it to `EarthSciIO.supports_selection`. A `selection` may be
handed only to a provider for which this is `true`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/data_refresh.jl#L68)

### `providers_from_document` {#x-providers_from_document}

*function* · canonical name `providers_from_document`

```julia
providers_from_document(doc; cache_root, loaders=nothing, url_overrides=Dict(),
                        substitutions=Dict(), window=nothing,
                        records_per_sample=Dict()) -> Dict{String,Any}
```

Construct the data providers a document declares: one provider per data-fed
parameter, drawn from a `data_sources.<name>` entry carrying a
`metadata.esio_format` ("zarr", "ff10", …). Each source is read by EarthSciIO's
`provider_from_esm` (EarthSciIO spec/esm-sources.md §3): its `url_template` and
`mirrors` are expanded at each file anchor, and a source with a `temporal` block
is time-varying on a calendar cadence (`P1M` is a calendar month). `doc` is a raw
document `Dict`, an `EsmFile`, or a path.

The result is keyed `"<ModelPath>.<param>"`, the consuming parameter's flattened
name (a source declares no variables of its own; a model reads a field by
declaring a parameter whose `update` names the source, esm-spec §8.5). These are
the `providers` keys [`esm_problem`](/generated/api/ref/esm_problem-function) takes.

Every provider runs on the model clock (esm-spec §2.2.7). Its time origin, the
UTC instant of model time 0, is the first of: the document's
`domain.temporal.reference_time`, its `domain.temporal.start` (each when a
non-empty string; an unreadable one raises `time_origin_invalid`, as
[`time_origin`](/generated/api/ref/time_origin) does), the start of `window`, the POSIX epoch. A sample at
model time `t` reads the instant `origin + t`, and
[`provider_refresh_times`](/generated/api/extension/julia#x-provider_refresh_times) reports anchors in model seconds. With no
`window`, the document's `solver.time_span` (as [`resolve_time_span`](/generated/api/ref/resolve_time_span)
reads it) supplies one; with neither, a time-varying provider is bounded only by
its own `temporal.end`.

A source declaring a `record_filter` or `codes` is a record table decoded once per
record anchor and shared by its parameters. A declared `select` names the
source's native per-record axes; a time-varying source applies it after slicing
the record and reports `provider_supports_selection == false`.

Keywords:
  * `cache_root` — root of the download cache (one subdirectory per loader).
  * `loaders` — restrict to these loader names (`nothing` = every loader with an
    `esio_format`).
  * `url_overrides` — loader name ⇒ URL template, replacing `url_template` and
    its mirrors. An empty entry is an error.
  * `substitutions` — loader name ⇒ `Dict(placeholder => value)`, binding the
    custom `{name}` placeholders a mount's `url_substitutions` left. An unbound
    placeholder is an error.
  * `window` — the run's `(start, stop)`, each a `DateTime` (UTC) or a finite
    number of Unix seconds, bounding each time-varying provider's refresh times.
    Anything else is an `ArgumentError`.
  * `records_per_sample` — consuming parameter key ⇒ 1 or 2. The count is fixed
    by the parameter's record shape (esm-spec §8.5.1): two when its declared
    `shape` (else that of its `param_to_var` targets) begins with an `interval`
    index set carrying `"records": true`, else one. An entry must equal that
    count. The deprecated `update.from.records_per_sample` /
    `temporal.records_per_sample` must agree with it too, and stand in for it
    only where the raw document cannot show the record shape (a target brought
    by a `coupling_import`). Every value must be the number 1 or 2 (`2.0` is 2;
    `1.5`, `"2"` and `true` are refused). With 2 the provider returns the record
    at or before `t` and the next one, stacked along the first dimension; 2 is
    refused on a time-invariant source and on a record table.

Implemented by the `EarthSciASTEarthSciIOExt` extension: load `EarthSciIO`
alongside EarthSciAST, or the call is a `MethodError`. `esio_format` goes
straight to EarthSciIO, whose format registry decides what is readable.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/data_refresh.jl#L125)

### `QualifiedReferenceError` {#x-qualifiedreferenceerror}

*error* · canonical name `qualified_reference_error`

```julia
struct QualifiedReferenceError <: EarthSciASTError
QualifiedReferenceError(message::AbstractString, reference::AbstractString, path::AbstractVector)
QualifiedReferenceError(message::AbstractString, reference::AbstractString, path::AbstractVector, code::AbstractString)
```

```julia
QualifiedReferenceError(message, reference, path, code = "")
```

Exception thrown when qualified reference resolution fails. Fields: `code`
(`invalid_reference_syntax`, `undefined_system` or `undefined_variable`),
`message`, the `reference` as written, and `path`, the system names resolved
before the failure.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/qualified_reference.jl#L4)

### `RecurrenceInfo` {#x-recurrenceinfo}

*type* · canonical name `recurrence_info`

```julia
struct RecurrenceInfo
RecurrenceInfo(var::String, axis::String, max_lag::Int64, lag_proven::Bool, slices::Int64, cells::Int64)
RecurrenceInfo(var, axis, max_lag, lag_proven, slices, cells)
```

```julia
RecurrenceInfo
```

A recognized causal self-reference (esm-spec §4.3.1.1), as reported in
[`BuildInspection`](/generated/api/extension/julia#x-buildinspection)`.recurrences`:

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/tree_walk/build_records.jl#L202)

### `ReferenceResolution` {#x-referenceresolution}

*type* · canonical name `reference_resolution`

```julia
struct ReferenceResolution
ReferenceResolution(variable_name::String, system_path::Vector{String}, system_type::Symbol, resolved_system::Union{Model, ReactionSystem})
ReferenceResolution(variable_name, system_path, system_type, resolved_system)
```

```julia
ReferenceResolution
```

Result of qualified reference resolution containing the resolved variable
and its location information.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/qualified_reference.jl#L25)

### `RefreshBuffers` {#x-refreshbuffers}

*type* · canonical name `refresh_buffers`

```julia
struct RefreshBuffers
RefreshBuffers(buffers::Dict{String, Array{Float64}})
RefreshBuffers(buffers)
RefreshBuffers(d::AbstractDict)
RefreshBuffers(pairs::Pair...)
```

```julia
RefreshBuffers(buffers::AbstractDict)
RefreshBuffers(pairs::Pair...)
```

Registry mapping a forcing variable name to its live buffer: the dense
`Array{Float64}` bound by reference through
`esm_problem(input, tspan; param_arrays = …)`. The refresh callback writes the
sampled forcing into these objects in place, so the right-hand side sees it on
its next evaluation. Each value must be a dense `Array{Float64}`
(`RefreshError` otherwise); pass the same dictionary you gave `param_arrays` so
the buffers are shared, not copied:

```julia
forcing = Dict("wind" => zeros(nx, ny))
prob = esm_problem(doc, tspan; param_arrays = forcing, …)
buffers = RefreshBuffers(forcing)   # same array objects — aliased, not copied
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/data_refresh.jl#L395)

### `RefreshError` {#x-refresherror}

*error* · canonical name `refresh_error`

```julia
struct RefreshError <: EarthSciASTError
RefreshError(msg::AbstractString)
RefreshError(msg::AbstractString, code::AbstractString)
```

```julia
RefreshError(msg, code = "")
```

Thrown by the data-refresh surface: an unimplemented Provider
protocol method, a buffer that is not a dense `Array{Float64}`, a
shape/length mismatch at refresh time, or a call to
[`build_refresh_callback`](/generated/api/extension/julia#x-build_refresh_callback) before the `DiffEqCallbacks` / `SciMLBase`
extension is loaded. Fields: `code` (an [`ERROR_CODES`](/generated/api/ref/error_codes) value, or `""`)
and `msg`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/data_refresh.jl#L16)

### `remake_parameters` {#x-remake_parameters}

*function* · canonical name `remake_parameters`

```julia
remake_parameters(prob::EsmProblem, overrides::AbstractDict)
```

```julia
remake_parameters(prob::EsmProblem, overrides) -> p
```

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
`:forcing` override throws a [`SimulateError`](/generated/api/ref/simulate_error) naming the parameter and its
class — changing one of those is an explicit rebuild, because it changes the
build, not just a number the build reads. Keys may be spelled locally
(`"scale"`) or namespaced (`"NEIRegrid.scale"`), exactly as `esm_problem`'s `p`
overrides are; an unknown or ambiguous key throws rather than being dropped.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/simulate.jl#L2091)

### `replace_forcing` {#x-replace_forcing}

*function* · canonical name `replace_forcing`

```julia
replace_forcing(fs::ForcingSet, slot::Integer, buf)
```

```julia
replace_forcing(fs::ForcingSet, slot::Integer, buf) -> ForcingSet
```

A new set with a new epoch: `fs` with its 1-based `slot` holding `buf`, every
other buffer shared. `fs` is unchanged.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/rhs_program.jl#L224)

### `resolve_qualified_reference` {#x-resolve_qualified_reference}

*function* · canonical name `resolve_qualified_reference`

```julia
resolve_qualified_reference(esm_file::EsmFile, reference::String)
```

```julia
resolve_qualified_reference(esm_file::EsmFile, reference::String) -> ReferenceResolution
```

Resolve a qualified reference string using hierarchical dot notation.

The reference string is split on dots to produce segments [s₁, s₂, …, sₙ].
The final segment sₙ is the variable name. The preceding segments [s₁, …, sₙ₋₁]
form a path through the subsystem hierarchy.

**Algorithm**
1. Split reference on "." to get segments
2. First segment must match a top-level system (models, reaction_systems)
3. Each subsequent segment must match a key in the parent system's subsystems map
4. Final segment is the variable name to resolve

**Examples**
- `"SuperFast.O3"` → Variable `O3` in top-level model `SuperFast`
- `"SuperFast.GasPhase.O3"` → Variable `O3` in subsystem `GasPhase` of model `SuperFast`
- `"Atmosphere.Chemistry.FastChem.NO2"` → Variable `NO2` in nested subsystems

**Throws**
- `QualifiedReferenceError` if reference cannot be resolved

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/qualified_reference.jl#L38)

### `rhs!` {#x-rhs}

*function* · canonical name `rhs`

```julia
rhs!(du::AbstractVector, lp::EarthSciAST.LaneProgram, ws::EarthSciAST.RhsWorkspace, u::AbstractVector, aux::AbstractVector, p, t::Real, fs::ForcingSet, cells::AbstractMatrix, n::Integer)
rhs!(du::AbstractVector, lp::EarthSciAST.LaneProgram, ws::EarthSciAST.RhsWorkspace, u::AbstractVector, aux::AbstractVector, p, t::Real, li::EarthSciAST.LaneInputs, cells::AbstractMatrix, n::Integer)
rhs!(du::AbstractVector, lp::EarthSciAST.LaneProgram, ws::EarthSciAST.RhsWorkspace, u::AbstractVector, aux::AbstractVector, p, ts::AbstractVector{<:Real}, fs::ForcingSet, cells::AbstractMatrix, n::Integer)
rhs!(du::AbstractVector, lp::EarthSciAST.LaneProgram, ws::EarthSciAST.RhsWorkspace, u::AbstractVector, aux::AbstractVector, p, ts::AbstractVector{<:Real}, li::EarthSciAST.LaneInputs, cells::AbstractMatrix, n::Integer)
rhs!(du::AbstractVector, x::Union{EarthSciAST.RhsProgram, EarthSciAST.TileProgram}, ws::EarthSciAST.RhsWorkspace, u::AbstractVector, aux::AbstractVector, p, t, fs::ForcingSet)
```

```julia
rhs!(du, x, ws, u, aux, p, t, fs::ForcingSet) -> du
```

Evaluate the program or tile `x` (API_SPEC §5.8): `u` and `aux` in
[`tile_layout`](/generated/api/extension/julia#x-tile_layout)`(x)`, `p` a vector in [`parameters`](/generated/api/ref/parameters) order or the
Problem's NamedTuple, `fs` a [`ForcingSet`](/generated/api/ref/forcing_set-type) of `x`, `ws` a
[`rhs_workspace`](/generated/api/extension/julia#x-rhs_workspace) of `x`. The result is a function of `(x, u, aux, p, t,
fs)`'s contents alone: bitwise the same on every workspace and thread, whatever
the workspace evaluated before. Writes only the owned rows of `du`; every other
element is left untouched. Reentrant across distinct workspaces, never
threaded internally, allocation-free in steady state. A buffer or a vector `p`
of the wrong length is a `DimensionMismatch`; a workspace or set of another
program an `ArgumentError`. A call that throws leaves the workspace usable: the
next call recomputes everything the failed one may have half written.

---

```julia
rhs!(du, lanes::LaneProgram, ws, u, aux, p, t, fs::ForcingSet, cells, n) -> du
rhs!(du, lanes::LaneProgram, ws, u, aux, p, t, li::LaneInputs, cells, n) -> du
```

Evaluate the first `n` lanes of an `L`-lane batch (API_SPEC §5.8, "Lanes"):
`u`, `aux`, `du` in [`lane_layout`](/generated/api/extension/julia#x-lane_layout), `cells` an `[D, L]` matrix of global
indices (rows in the lane-set order). The second form takes every pre-gathered
input from `li` ([`gather_lane_inputs!`](/generated/api/extension/julia#x-gather_lane_inputs)) instead of gathering it here,
and evaluates against the forcing set `li` was gathered from. Every per-call
buffer is the workspace's: reentrant across distinct workspaces.

---

```julia
rhs!(du, lanes::LaneProgram, ws, u, aux, p, ts::AbstractVector, fs::ForcingSet, cells, n) -> du
```

Each lane at its own time (U19): lane `l ≤ n` evaluates at `ts[l]`, and its
value equals the whole-domain program's at `cells[:, l]` and time `ts[l]`,
bit for bit, whatever the other lanes' times. `ts` holds at least `n` and at
most `L` times; a padding lane takes `ts[1]`.

One pass over the batch, whatever its times: the lane program reads `t` from a
lane buffer of times, and every 0-d observed that depends on `t` is computed
per lane (`_range_promote_model`). With equal times the call equals
the one-time call. An observed of `t` that carries no lane set is evaluated
once per call, at one time: when the state equations read one, the times of
lanes `1..n` must be equal, or the call throws an `ArgumentError` naming it.

---

```julia
rhs!(du, lanes::LaneProgram, ws, u, aux, p, ts::AbstractVector, li::LaneInputs, cells, n) -> du
```

The pre-gathered call ([`gather_lane_inputs!`](/generated/api/extension/julia#x-gather_lane_inputs)) with each lane at its
own time: as the call with a time per lane and a forcing set, every
non-state input taken from `li`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/rhs_program.jl#L1376)

### `rhs_workspace` {#x-rhs_workspace}

*function* · canonical name `rhs_workspace`

```julia
rhs_workspace(lp::EarthSciAST.LaneProgram)
rhs_workspace(x::Union{EarthSciAST.RhsProgram, EarthSciAST.TileProgram})
```

```julia
rhs_workspace(x) -> RhsWorkspace
```

The mutable state of [`rhs!`](/generated/api/extension/julia#x-rhs) on `x` (a program, a tile or a lane
program): a private instance of its compiled right-hand side — its own caches,
scratch and forcing buffers; the generated code and every read-only table are
the program's. One per concurrent caller; a workspace may move between threads
but serves one call at a time.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/rhs_program.jl#L1365)

### `row_major_flat_indices` {#x-row_major_flat_indices}

*function* · canonical name `row_major_flat_indices`

```julia
row_major_flat_indices(g::VarGridding)
```

```julia
row_major_flat_indices(g::VarGridding) -> Vector{Int}
```

`g`'s flat state indices re-expressed as a dense vector indexed by ROW-MAJOR
(C-order) offset within `g.shape`, with the column-major → row-major
transposition already applied — the layout a Zarr writer's buffer wants, and the
representation `earthsci-ast-rs`'s `VarGridding::flat_indices` stores natively.
Length is `prod(g.shape)` (1 for a scalar). Indices stay 1-based, as everywhere
else in Julia.

This is what lets the two bindings be compared on ONE representation in the
cross-language derivation corpus (`tests/conformance/output_derivation/`).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/output_plan.jl#L141)

### `run_esm_tests` {#x-run_esm_tests}

*function* · canonical name `run_esm_tests`

```julia
run_esm_tests(; ...)
run_esm_tests(roots::AbstractVector{<:AbstractString}; root, junit_xml, verbose, exclude, stiff_files, io)
run_esm_tests(roots::AbstractString...; kwargs...)
```

```julia
run_esm_tests(roots=DEFAULT_ROOTS; root=esm_root(), junit_xml=nothing,
              verbose=true, exclude=nothing,
              stiff_files=STIFF_SOLVER_OVERRIDE_FILENAMES,
              io::IO=stdout) -> (results, exit_code)
```

Walk each directory in `roots`, run every inline test in every `.esm` file
through the ModelingToolkit compiler ([`run_inline_tests`](/generated/api/ref/run_inline_tests) with
`compiler = :mtk`), and return `(results::Vector{AssertionResult},
exit_code::Int)` where `exit_code == 0` iff every assertion passed. Needs
`ModelingToolkit` and an OrdinaryDiffEq solver loaded.

`root` is the base directory against which relative `roots` (and exclude
patterns) resolve — pass it to walk a different repo instead of overwriting
`esm_root()`. Discovery finding zero files logs a `@warn` (a mis-rooted
invocation must not silently pass).

Prints a per-file summary table to `io` when `verbose=true`. When
`junit_xml` is a path, emits a junit-compatible XML report there.

`exclude` (or the `ESM_TESTS_EXCLUDE` env var) drops any `.esm` file whose
path contains one of the listed substrings.

`stiff_files` is a set/vector of `.esm` basenames to integrate with the stiff
Rosenbrock23 solver when the document declares no `solver.stiffness`; it
defaults to `STIFF_SOLVER_OVERRIDE_FILENAMES`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/run_tests.jl#L548)

### `scatter_grid!` {#x-scatter_grid}

*function* · canonical name `scatter_grid`

```julia
scatter_grid!(grid::AbstractArray, g::VarGridding, u::AbstractVector)
```

```julia
scatter_grid!(grid, g::VarGridding, u) -> grid
```

Scatter the flat state `u` into the pre-allocated gridded `grid` for variable
`g`: `grid[cart[k]] = u[flat_indices[k]]`. `grid` must have size `Tuple(g.shape)`
— for a scalar that is the 0-d `Array{Float64}(undef)`, whose single element
`CartesianIndex()` addresses.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/output_plan.jl#L169)

### `scatter_lanes` {#x-scatter_lanes}

*function* · canonical name `scatter_lanes`

```julia
scatter_lanes(ir, u, updates, cells)
```

Within a Reactant trace, return a fresh whole-domain state with the writable
lane blocks in `updates` replacing the cells selected by `cells`. The caller
supplies distinct cells. A lane whose cell lies outside the domain writes
nothing, so it cannot overwrite another variable's block.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/operator_ir.jl#L406)

### `seed_expression_ic!` {#x-seed_expression_ic}

*function* · canonical name `seed_expression_ic`

```julia
seed_expression_ic!(u0::Vector{Float64}, var_map::AbstractDict, var_name::AbstractString, expr::ASTExpr, coords)
```

```julia
seed_expression_ic!(u0, var_map, var_name, expr, coords) -> u0
```

Seed an array state's initial field from an expression evaluated over a grid —
the generic form of a domain-level `expression` initial condition (the Python
`_seed_expression_initial_conditions`). `coords` is an ordered collection of
`dim_name => coordinate_vector` pairs (one per array axis, in index order);
`expr` is evaluated at each grid node with the dimension names bound to the
node's coordinates and written into `u0` at `var_map["var_name[i,j,…]"]`.

Used to seed the level-set's signed-distance `psi` from the domain's declared
IC over the real (projected) fire grid — no per-cell loop in the runner.

`expr` is compiled ONCE with the dimension names bound as parameters and then
evaluated at each cell of `var_name` that `var_map` holds; the cells are read
off `var_map` itself, so no key is built per grid node. An expression the
compiler does not accept is evaluated per cell by `evaluate_expr` instead,
which a strict compiler plan in force refuses.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/simulate.jl#L405)

### `serialize_coupling_entry` {#x-serialize_coupling_entry}

*function* · canonical name `serialize_coupling_entry`

```julia
serialize_coupling_entry(entry::CouplingEntry)
```

```julia
serialize_coupling_entry(entry::CouplingEntry) -> Dict{String,Any}
```

Serialize CouplingEntry to JSON-compatible format based on concrete type.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/serialize.jl#L321)

### `SHAPE_REQUIRING_UPDATE_KINDS` {#x-shape_requiring_update_kinds}

*constant* · canonical name `shape_requiring_update_kinds`

```julia
const SHAPE_REQUIRING_UPDATE_KINDS::Tuple{String, String, String}
```

The update kinds that require the parameter to declare a `shape` (§5.4).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/types.jl#L780)

### `sink_close!` {#x-sink_close}

*function* · canonical name `sink_close`

```julia
sink_close!(s)
```

```julia
sink_close!(sink)
```

Finalize `sink`: flush, write the end-of-run manifest / consolidated metadata, and
release resources. Called once after the last [`sink_write!`](/generated/api/extension/julia#x-sink_write). Concrete impls
live in the data binding or a test mock.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/output_sinks.jl#L163)

### `sink_flush!` {#x-sink_flush}

*function* · canonical name `sink_flush`

```julia
sink_flush!(s)
```

```julia
sink_flush!(sink)
```

Durable barrier: make every record written so far durable (the checkpoint-boundary
commit). Concrete impls live in the data binding or a test mock.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/output_sinks.jl#L149)

### `sink_observed_names` {#x-sink_observed_names}

*function* · canonical name `sink_observed_names`

```julia
sink_observed_names(::Any)
```

```julia
sink_observed_names(sink) -> Vector{String}
```

The names of the observed/derived fields `sink` wants written alongside the state
— exactly the fields the output callback's `pre_write` hook must evaluate at each
output tick (the evaluator already produces them). Defaults to `String[]` (a
state-only sink). A concrete binding overrides it from its schema.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/output_sinks.jl#L189)

### `sink_open!` {#x-sink_open}

*function* · canonical name `sink_open`

```julia
sink_open!(s)
```

```julia
sink_open!(sink)
```

Open `sink` for writing against its OWN `OutputSchema` (declare dims / coordinates
/ variables / chunk-shard grid ONCE). Called before the first
[`sink_write!`](/generated/api/extension/julia#x-sink_write). Concrete impls live in the data binding or a test mock.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/output_sinks.jl#L113)

### `sink_output_times` {#x-sink_output_times}

*function* · canonical name `sink_output_times`

```julia
sink_output_times(s)
```

```julia
sink_output_times(sink) -> AbstractVector{Float64}
```

The output-cadence anchors at which `sink` writes a record, in solver time
(seconds on the integrator's `t` axis). May be empty (a predicate-only checkpoint
sink contributes no fixed tstops). The output-side mirror of
[`provider_refresh_times`](/generated/api/extension/julia#x-provider_refresh_times). Concrete impls live in the data binding
(EarthSciIO) or a test mock.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/output_sinks.jl#L96)

### `sink_supports_partial` {#x-sink_supports_partial}

*function* · canonical name `sink_supports_partial`

```julia
sink_supports_partial(::Any)
```

```julia
sink_supports_partial(sink) -> Bool
```

True if `sink` can accept a sub-slab (region) write — the write-side mirror of
[`provider_supports_selection`](/generated/api/extension/julia#x-provider_supports_selection), used for distributed shard-local output.
Defaults to `false`; nothing in this package issues a partial write. A
concrete binding overrides it.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/output_sinks.jl#L178)

### `sink_write!` {#x-sink_write}

*function* · canonical name `sink_write`

```julia
sink_write!(s, ::StateSnapshot; selection)
```

```julia
sink_write!(sink, snap::StateSnapshot; selection=nothing)
```

Persist one time record: scatter the [`StateSnapshot`](/generated/api/extension/julia#x-statesnapshot)'s state slabs and
observed arrays into `sink`'s gridded arrays. The output-side mirror of
[`provider_sample`](/generated/api/extension/julia#x-provider_sample).

`selection` is the write-side mirror of the Provider's read-side projection
pushdown: an optional per-axis sub-slab so a sink is handed only part of an axis
(distributed region writes). The output callback always passes
`selection === nothing`, since [`state_snapshot`](/generated/api/extension/julia#x-state_snapshot) delivers the whole state;
see [`sink_supports_partial`](/generated/api/extension/julia#x-sink_supports_partial). Concrete impls live in the data binding or a test mock.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/output_sinks.jl#L128)

### `SKIP` {#x-skip}

*constant* · canonical name `skip`

```julia
const SKIP::AssertionStatus
```

```julia
SKIP::AssertionStatus
```

Reserved; no runner produces it. See [`AssertionStatus`](/generated/api/extension/julia#x-assertionstatus).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/run_tests.jl#L88)

### `slurm_walltime_predicate` {#x-slurm_walltime_predicate}

*function* · canonical name `slurm_walltime_predicate`

```julia
slurm_walltime_predicate(; margin_seconds, clock, end_time_env)
```

```julia
slurm_walltime_predicate(; margin_seconds = 300, clock = EarthSciAST._unix_now,
                         end_time_env = "SLURM_JOB_END_TIME") -> () -> Bool
```

Built-in SLURM remaining-walltime checkpoint predicate (RFC §10): fires once the
job is within `margin_seconds` of its scheduled end, so a full-state checkpoint
lands before SLURM kills the job. Reads the job end time (Unix epoch seconds) from
the `end_time_env` environment variable; returns `false` when it is absent or
unparseable — i.e. not running under SLURM ⇒ never fires. `clock` (a `() -> Real`
Unix-seconds source) is injectable for testing.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/checkpoint.jl#L32)

### `solver_unknowns` {#x-solver_unknowns}

*function* · canonical name `solver_unknowns`

```julia
solver_unknowns(model::Model)
```

```julia
solver_unknowns(model::Model) -> Vector{String}
```

The unknowns that occupy a SOLVER SLOT — [`ode_states`](/generated/api/ref/ode_states) plus
[`algebraic_unknowns`](/generated/api/ref/algebraic_unknowns), sorted lexicographically. Equivalently, the
unknowns minus the observed ones, which are eliminable.

This is the set every partition, cell-enumeration, and live-state guard in the
tree-walk build wants: an algebraic unknown is solved for exactly like an ODE state (it just has no
time derivative), so treating only `ode_states` as "the states" drops a
declared, array-shaped algebraic unknown out of the partition it belongs to.
It is also the CONTINUOUS half of the cadence leaf-seed table
(CONFORMANCE_SPEC §5.7.2), which seeds both alike.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/classification.jl#L290)

### `spot_preemption_predicate` {#x-spot_preemption_predicate}

*function* · canonical name `spot_preemption_predicate`

```julia
spot_preemption_predicate(; poll)
```

```julia
spot_preemption_predicate(; poll) -> () -> Bool
```

Built-in cloud spot / preemptible-instance checkpoint predicate (RFC §10): fires
when the instance metadata service reports a pending termination notice. `poll` is
a `() -> Bool` performing the provider-specific metadata check (AWS
`/latest/meta-data/spot/instance-action`, GCP `preempted`, …) — REQUIRED and
supplied by the caller, so the core carries no HTTP/provider dependency and the
predicate stays testable. Combine with [`any_of`](/generated/api/extension/julia#x-any_of) and/or an interval.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/checkpoint.jl#L55)

### `state_layout` {#x-state_layout}

*function* · canonical name `state_layout`

```julia
state_layout(x::Union{EarthSciAST.RhsProgram, EarthSciAST.TileProgram})
state_layout(ks::KernelSet)
```

```julia
state_layout(prog) -> Vector{StateBlock}
```

The `u` blocks in flat-layout order (0-d states by sorted name, then arrays by
sorted name): name, 1-based offset, shape. Derived from
[`tile_layout`](/generated/api/extension/julia#x-tile_layout)`(prog)`; a tile's shapes are its storage box's.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/rhs_program.jl#L1352)

### `state_snapshot` {#x-state_snapshot}

*function* · canonical name `state_snapshot`

```julia
state_snapshot(integrator)
```

```julia
state_snapshot(integrator) -> Vector{Tuple{Array,Tuple{Vararg{UnitRange{Int}}}}}
```

Host-gather the integrator's state into the [`StateSnapshot`](/generated/api/extension/julia#x-statesnapshot) `state` shape:
one `(Array(integrator.u), (1:length(integrator.u),))` pair, the whole flat
state on the host at global offset 0. `Array(u)` gathers a device array to the
host and is a plain copy for a host array.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/output_sinks.jl#L204)

### `StateSnapshot` {#x-statesnapshot}

*type* · canonical name `state_snapshot`

```julia
struct StateSnapshot
StateSnapshot(t::Float64, state::Vector{Tuple{Array, Tuple{Vararg{UnitRange{Int64}}}}}, observed::Dict{String, Array})
StateSnapshot(t, state, observed)
```

```julia
StateSnapshot(t, state, observed)
```

One output record: the integrator state (and any caller-named observed/derived
fields) at solver time `t`, host-materialized, ready to scatter into a sink's
gridded arrays. Assembled once per output boundary by the output callback's
`affect!` and passed to [`sink_write!`](/generated/api/extension/julia#x-sink_write).

Fields (RFC §16.3):

* `t::Float64` — the solver time (seconds) of this record.
* `state::Vector{Tuple{Array,Tuple{Vararg{UnitRange{Int}}}}}` — the state as
  `(slab, global-range tuple)` pairs. [`state_snapshot`](/generated/api/extension/julia#x-state_snapshot) gives exactly one
  entry, `(Array(u), (1:length(u),))`, the whole flat state at offset 0; a
  sharded snapshot may give one slab per shard with its global range.
* `observed::Dict{String,Array}` — caller-named observed/derived arrays,
  host-materialized (empty unless a sink's schema names observed outputs; those
  names drive what `pre_write` evaluates — the evaluator already produces them).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/output_sinks.jl#L57)

### `StructuralError` {#x-structuralerror}

*type* · canonical name `structural_error`

```julia
struct StructuralError
StructuralError(path::AbstractString, message::AbstractString, error_type::AbstractString)
StructuralError(path::AbstractString, message::AbstractString, error_type::AbstractString, details::AbstractDict)
```

```julia
StructuralError
```

Represents a structural validation error with detailed information.
Contains path, message, error type, and machine-readable `details`.

`details` is the machine-readable half of the error. A conformance pin asserts
code, path and `details` under required-subset semantics (CONFORMANCE_SPEC
§7.1.2): every key the pin names must be present with the pinned value, and extra
keys are fine. It defaults to empty; a site that names a variable populates
`details["variable"]`, plus whatever else is locally meaningful.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/validation/records.jl#L24)

### `successors` {#x-successors}

*function* · canonical name `successors`

```julia
successors(graph::Graph{N, E}, node::N) where {N, E}
```

Get nodes that this node points to, each ONCE. See [`predecessors`](/generated/api/extension/julia#x-predecessors) for
why this deduplicates and [`adjacency`](/generated/api/extension/julia#x-adjacency) for why that one does not.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/graph.jl#L109)

### `sync_forcing!` {#x-sync_forcing}

*function* · canonical name `sync_forcing`

```julia
sync_forcing!(dest::NamedTuple, src::NamedTuple)
```

```julia
sync_forcing!(dest::NamedTuple, src::NamedTuple) -> dest
```

Copy every live forcing buffer in `src` into the same-named array of `dest`, in
place (`copyto!`; `dest`'s arrays are never rebound). When a right-hand side
was compiled through `direct_rhs_with_buffers` (Reactant extension) with device
arrays as its buffers argument, a `copyto!` into those arrays is seen by the
compiled program, so mirroring the refreshed host buffers into them at each
cadence boundary keeps the compiled forcing live without a retrace.

Wire it through [`build_refresh_callback`](/generated/api/extension/julia#x-build_refresh_callback)'s `post_refresh` hook (after
`materialize!`, when that is chained first):

```julia
prob = esm_problem(doc, tspan; param_arrays = forcing)
host = forcing_buffers(prob)                # aliased host buffers, stable order
dev  = map(Reactant.ConcreteRArray, host)   # the compiled program's inputs
cb, tstops = build_refresh_callback(;
    providers, buffers = RefreshBuffers(forcing), owner = prob,
    post_refresh = () -> sync_forcing!(dev, host))
```

A forcing write made outside that callback and announced with
`notify_forcing_refresh!` reaches the discrete caches only when something
refills them, so call the [`DiscreteMaterializer`](/generated/api/extension/julia#x-discretematerializer)'s `refresh!()` before
`sync_forcing!` copies them.

`src` is normally [`forcing_buffers`](/generated/api/extension/julia#x-forcing_buffers)`(prob)`; every key of `src` must be
in `dest` (else [`RefreshError`](/generated/api/extension/julia#x-refresherror)) and lengths must agree (`copyto!`
enforces it). `esm_problem(…; compiler = :xla)` does not do this wiring: it
refuses a document that binds live forcing.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/data_refresh.jl#L516)

### `tier_histogram` {#x-tier_histogram}

*function* · canonical name `tier_histogram`

```julia
tier_histogram(r::CompilerReport)
```

```julia
tier_histogram(report::CompilerReport) -> Vector{Pair{Symbol,Int}}
```

The report's rules folded into `tier => count`, ordered by descending count and
then by tier name, so two builds of the same document print the same line.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/compiler.jl#L420)

### `Tile` {#x-tile}

*type* · canonical name `tile`

```julia
struct Tile
Tile(decomposition::Decomposition, owned::O, storage::S, class::C) where {O, S, C}
Tile(dec::Decomposition; owned, storage)
Tile(dec::Decomposition, owned, storage)
```

```julia
Tile(decomposition; owned, storage)
```

A tile target for [`operator_ir`](/generated/api/extension/julia#x-operator_ir), with the same boxes as [`restrict`](/generated/api/ref/restrict).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/operator_ir.jl#L19)

### `tile_classes` {#x-tile_classes}

*function* · canonical name `tile_classes`

```julia
tile_classes(prob::EsmProblem, dec::Decomposition, tiles; outputs)
tile_classes(op::EarthSciAST.RhsProgram, dec::Decomposition, tiles)
```

```julia
tile_classes(op::RhsProgram, decomposition, tiles) -> Vector{Tile}
```

Group tiles with identical tile-local programs. Pass each input tile as a
`Tile` or a named tuple with `owned` and `storage` boxes. The returned targets
can be passed to [`operator_ir`](/generated/api/extension/julia#x-operator_ir) with the same selected operator. Tiles
whose lowered instructions cannot be compared safely form individual classes.

A class fragment takes a traced Int32 vector of the owned-box lower corners,
in decomposition axis order. Its input layouts are the representative tile's
layouts, translated to that origin. Use [`forcing_reach`](/generated/api/extension/julia#x-forcing_reach) with the
actual origin to obtain its forcing windows.

---

```julia
tile_classes(prob::EsmProblem, decomposition, tiles; outputs::KernelOutputs)
```

Group tiles of the standalone output kernel. Use the returned targets with
`operator_ir(prob; target, outputs)` and the same kernel specification.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/range/tile_classes.jl#L133)

### `tile_layout` {#x-tile_layout}

*function* · canonical name `tile_layout`

```julia
tile_layout(x::EarthSciAST.RhsProgram)
tile_layout(x::EarthSciAST.TileProgram)
```

```julia
tile_layout(x) -> TileLayout
```

The `u`/`aux` layout of a whole-domain program or a tile (API_SPEC §5.8,
"Layouts").

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/rhs_program.jl#L1326)

### `TreeWalkError` {#x-treewalkerror}

*error* · canonical name `tree_walk_error`

```julia
struct TreeWalkError <: EarthSciASTError
TreeWalkError(code::String, detail::String, rule::String)
TreeWalkError(code, detail, rule)
TreeWalkError(code, detail)
```

```julia
TreeWalkError
```

Raised when the walker encounters an operator or construct it cannot
evaluate. `code` is one of two families:

* an `E_TREEWALK_*` code from the bead's acceptance criterion — this
  evaluator's own build/eval failures; or
* the bare `unlowered_operator` code (esm-spec §4.2 / §9.6.8), thrown by
  `_compile_op` when a rewrite-target operator (an RHS-position `D`, or
  a user op) reaches evaluation without a discretization
  rule having lowered it. That code is DELIBERATELY not `E_TREEWALK_*`:
  it is the uniform cross-binding wire code every implementation surfaces
  for this pipeline violation, so it must not be renamed to match the
  local convention.

`detail` carries op name or variable name for diagnostics.

`rule` names the rule a `compiler_refused_rule` refusal is about (API_SPEC
§5.8), exactly as the refusal's message quotes it, so a caller reads it as a
field rather than out of the text; it is `""` for every other error.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/tree_walk/errors.jl#L11)

### `UnboundVariableError` {#x-unboundvariableerror}

*error* · canonical name `unbound_variable_error`

```julia
struct UnboundVariableError <: EarthSciASTError
UnboundVariableError(variable_name::AbstractString, message::AbstractString)
```

```julia
UnboundVariableError
```

Raised by [`evaluate_expr`](/generated/api/extension/julia#x-evaluate_expr) (the tree-walk evaluator entry point)
when an expression references a variable name that is not in the supplied
bindings. Defined here so it is in scope for callers that catch the
"binding not yet resolved" signal during iterated observed-variable
fixed-point passes.
Fields: `code` (always `E_TREEWALK_UNBOUND_VARIABLE`, the walker's code for
it), `variable_name` and `message`.

    UnboundVariableError(variable_name, message)

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/expression.jl#L715)

### `UNIT_DIMENSION_MISMATCH` {#x-unit_dimension_mismatch}

*constant* · canonical name `unit_dimension_mismatch`

```julia
const UNIT_DIMENSION_MISMATCH::String
```

```julia
UNIT_DIMENSION_MISMATCH::String
```

The [`UnitFinding`](/generated/api/ref/unit_finding) `code` for a PROVABLE dimensional inconsistency
(esm-spec §4.8.4), such as adding metres to seconds. Its value is
`"unit_inconsistency"`, the structural error the finding is reported as by
[`validate`](/generated/api/ref/validate).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/units.jl#L2522)

### `UNIT_PARSE_ERROR` {#x-unit_parse_error}

*constant* · canonical name `unit_parse_error`

```julia
const UNIT_PARSE_ERROR::String
```

```julia
UNIT_PARSE_ERROR::String
```

The [`UnitFinding`](/generated/api/ref/unit_finding) `code` for a declared unit string that does not parse
under the esm-spec §4.8.2 grammar or names a symbol outside the §4.8.1
registry. Its value is `"unit_parse_error"`, which is also the structural
error code [`validate`](/generated/api/ref/validate) reports it under.

A defect in the FILE, not a limit of the checker, so it is a hard error, never
a warning, and the unit is never coerced to dimensionless (which would turn off
every dimensional check downstream of it: a typo like `"m/s2"` would simply
disable the checker).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/units.jl#L2538)

### `UnknownVariable` {#x-unknownvariable}

*type* · canonical name `unknown_variable`

```julia
const UnknownVariable::ModelVariableType
```

```julia
UnknownVariable::ModelVariableType
```

A variable the solver solves for (wire spelling `"unknown"`, esm-spec §6.3).
Whether it is an ODE state, an observed or an algebraic unknown is derived from
the model's equations; see [`ode_states`](/generated/api/ref/ode_states), [`observed_unknowns`](/generated/api/ref/observed_unknowns)
and [`algebraic_unknowns`](/generated/api/ref/algebraic_unknowns), and [`unknowns`](/generated/api/ref/unknowns) for all of them.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/types.jl#L857)

### `validate_file_dimensions` {#x-validate_file_dimensions}

*function* · canonical name `validate_file_dimensions`

```julia
validate_file_dimensions(file::EsmFile)
```

Validate dimensions for all components in an ESM file.

Returns true if all models and reaction systems pass dimensional validation.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/units.jl#L2842)

### `validate_model_dimensions` {#x-validate_model_dimensions}

*function* · canonical name `validate_model_dimensions`

```julia
validate_model_dimensions(model::Model)
```

Validate dimensions for all equations and variable definitions in a model.

Returns true when nothing in the model or its subsystems is PROVABLY
dimensionally inconsistent.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/units.jl#L2807)

### `validate_reaction_rate_units` {#x-validate_reaction_rate_units}

*function* · canonical name `validate_reaction_rate_units`

```julia
validate_reaction_rate_units(rs::ReactionSystem, path::String; file, toplevel)
```

```julia
validate_reaction_rate_units(rs::ReactionSystem, path::String; file=nothing, toplevel=nothing) -> Vector{StructuralError}
```

Enforce the mass-action dimensional constraint from spec §7.4: for each reaction,
rate * prod(substrate^stoichiometry) must have dimensions of species/time. The
reference concentration unit is taken from the first substrate (matching TS/Python).

The check is skipped when the reference concentration unit is dimensionless
(mol/mol, ppm, …) because atmospheric-chemistry rate expressions commonly bake
a number-density factor into rate constants.

A scoped rate or substrate (`Sub.k`, `Other.A`) has the units its target
declares, with the precedence [`model_unit_findings`](/generated/api/extension/julia#x-model_unit_findings) uses: the system's
own names, then paths relative to its own subsystems, then the top-level
components of `file` (or the prebuilt `toplevel` map). Covers the system's
subsystems at any depth.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/validation/unit_checks.jl#L107)

### `validate_reaction_system_dimensions` {#x-validate_reaction_system_dimensions}

*function* · canonical name `validate_reaction_system_dimensions`

```julia
validate_reaction_system_dimensions(rxn_sys::ReactionSystem)
```

Validate dimensions for all reactions in a reaction system.

Enforces the mass-action dimensional constraint from spec §7.4 by delegating
to [`validate_reaction_rate_units`](/generated/api/extension/julia#x-validate_reaction_rate_units) in validation/unit_checks.jl — the single shared
implementation of the rule (also used by `validate_structural`) — so the two
entry points cannot drift apart. Each finding is logged as a warning; returns
`true` when no dimensional inconsistencies are found.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/units.jl#L2825)

### `validate_reference_syntax` {#x-validate_reference_syntax}

*function* · canonical name `validate_reference_syntax`

```julia
validate_reference_syntax(reference::String)
```

```julia
validate_reference_syntax(reference::String) -> Bool
```

Validate that a reference string follows proper dot notation syntax.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/qualified_reference.jl#L178)

### `VarExpr` {#x-varexpr}

*type* · canonical name `var_expr`

```julia
struct VarExpr <: ASTExpr
VarExpr(name::String)
VarExpr(name)
```

```julia
VarExpr(name::String)
```

Variable or parameter reference expression containing a name string.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/types.jl#L134)

### `Whole` {#x-whole}

*type* · canonical name `whole`

```julia
struct Whole
Whole()
```

A whole-domain target for [`operator_ir`](/generated/api/extension/julia#x-operator_ir).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/operator_ir.jl#L16)

### `write_junit_xml` {#x-write_junit_xml}

*function* · canonical name `write_junit_xml`

```julia
write_junit_xml(results::Vector{AssertionResult}, path::AbstractString; file)
```

```julia
write_junit_xml(results, path; file=nothing)
```

Emit a junit-compatible XML report covering every `AssertionResult`.

Each unique `(file, container, test_id)` becomes a `<testcase>`; one or more
failing assertions inside it produce `<failure>` / `<error>` children. The
testcase `time` attribute is the sum of its assertions' `duration_s` — each
assertion carries an even share of its test's wall time, so the sum is the
test's duration (no N-fold overcount).

`file`, when given, relabels every result's source file before grouping. A
[`run_inline_tests`](/generated/api/ref/run_inline_tests) run over documents loaded from PATHS fills `r.file`
itself, so a corpus batch needs nothing here; pass `file` when the documents
were handed over as in-memory `EsmFile`s (whose rows have no path to carry) and
one label fits the whole batch.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/run_tests.jl#L757)

### `z_layout` {#x-z_layout}

*function* · canonical name `z_layout`

```julia
z_layout(ks::KernelSet)
```

```julia
z_layout(ks::KernelSet) -> Vector{StateBlock}
```

The `z` layout every kernel of `ks` reads (empty when nothing algebraic was
stripped).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/strip_expose.jl#L689)

### `zarr_restart_state` {#x-zarr_restart_state}

*function* · canonical name `zarr_restart_state`

```julia
zarr_restart_state(args...; kwargs...)
```

```julia
zarr_restart_state(prep, base_url; kwargs...) -> (t0::Float64, u0::Vector{Float64})
```

Reconstruct a flat restart state from the last committed checkpoint in the Zarr
store at `base_url` (streaming-output-sinks RFC §10, §16.7): read the output
manifest for the last durable `t`, read each variable's gridded slab at that time
index through the `ZarrReader`, and [`gather_flat!`](/generated/api/extension/julia#x-gather_flat) it back into a flat `u0`
in the model's `var_map` order. Continue integrating a fresh run from `(t0, t_end)`
seeded with `u0` — a valid continuation consistent to solver tolerance (NOT
bit-identical; the integrator's internal cache is not checkpointed).

Requires `EarthSciIO` to be loaded (the reader/manifest live there); calling it
without EarthSciIO throws [`OutputError`](/generated/api/ref/output_error).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/output_sinks.jl#L300)
