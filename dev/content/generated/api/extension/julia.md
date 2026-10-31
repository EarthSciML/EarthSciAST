---
title: "Julia extension seams"
description: "Julia's extension-tier names: documented, reachable, not portable."
type: "api"
---


Extension-tier names are part of this binding's documented surface but are not harmonized across bindings, and may change in a minor release ([API_SPEC.md §7](https://github.com/EarthSciML/EarthSciAST/blob/main/API_SPEC.md#7-extension-seams)).

141 names.

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/data_output.jl#L56)

### `adjacency` {#x-adjacency}

*function* · canonical name `adjacency`

```julia
adjacency(graph::Graph{N, E}, node::N) where {N, E}
```

Get all adjacent nodes (both predecessors and successors).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/graph.jl#L75)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/data_output.jl#L1088)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/classification.jl#L455)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/run_tests.jl#L59)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/types.jl#L56)

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

This `(AbstractVector, AbstractVector)` method is the dependency-free brute-force
reference. Loading `GeometryOps` (+ `GeoInterface`, `SortTileRecursiveTree`,
`Extents`) adds a fast `(AbstractVector, <spatial index>)` method — see
[`build_spatial_index`](/generated/api/extension/julia#x-build_spatial_index) — that returns an identical vector.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/broad_phase.jl#L40)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/data_output.jl#L1148)

### `build_evaluator` {#x-build_evaluator}

*function* · canonical name `build_evaluator`

```julia
build_evaluator(input, args...; kwargs...)
```

```julia
build_evaluator(input; kwargs...) -> (f!, u0, p, tspan, var_map)
```

**Deprecated (API_SPEC §8 item 23, §10).** Removed in the next minor version.
Use [`esm_problem`](/generated/api/ref/esm_problem-function).

`build_evaluator` was the extension seam under the runners, never stable API,
and a caller had to reassemble a run out of its five-tuple by hand. The Problem
absorbs the whole pipeline — load → flatten → shape transforms → value
invention → gated fetch → compile → seed → callbacks — and hangs what used to
come off the evaluator on itself instead:

| was | is |
|---|---|
| `f!, u0, p, tspan, var_map = build_evaluator(doc)` | `prob = esm_problem(doc, tspan)`, then `prob.f!`, `prob.u0`, `prob.p`, `prob.tspan`, `prob.var_map` |
| `build_evaluator(doc; form = :oop)` + a compiled backend | `esm_problem(doc, tspan; compiler = :xla)` — the Problem's `f!` IS the compiled StableHLO program |
| `forcing_buffers(f)` / `forcing_buffer_index(f)` | [`forcing_buffers`](/generated/api/extension/julia#x-forcing_buffers)`(prob)` / [`forcing_buffer_index`](/generated/api/extension/julia#x-forcing_buffer_index)`(prob)` |
| `insp = BuildInspection(); build_evaluator(doc; inspect = insp); insp.compiler_report` | [`compiler_report`](/generated/api/extension/julia#x-compiler_report)`(prob)` |

The keyword arguments are unchanged, so a call that cannot yet move — one that
builds from a bare `Model`, or one that wants the out-of-place compiled
intermediate representation to lower itself — keeps working through this alias
in the meantime.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/deprecated.jl#L12)

### `build_output_callback` {#x-build_output_callback}

*function* · canonical name `build_output_callback`

```julia
build_output_callback(args...; kwargs...)
```

```julia
build_output_callback(; sinks, snapshot = state_snapshot,
                      pre_write = () -> nothing)
    -> (cb, tstops::Vector{Float64})
```

Build the streaming-output callback and its tstops, WITHOUT embedding a solver
(`[[library-exposes-rhs-not-solver]]`) — the output-side mirror of
[`build_refresh_callback`](/generated/api/extension/julia#x-build_refresh_callback). The callback is a pure function of the `sinks`
and the `snapshot`/`pre_write` seams; it never reads the model. The caller attaches
it to their own problem:

```julia
cb, tstops = build_output_callback(; sinks = [my_sink])
prob = ODEProblem(f!, u0, tspan, p)              # USER's solver call
sol  = solve(prob, Tsit5(); callback = cb, tstops = tstops, save_everystep = false)
```

* `sinks` — a collection of objects implementing the Sink protocol
  ([`sink_output_times`](/generated/api/extension/julia#x-sink_output_times) / [`sink_write!`](/generated/api/extension/julia#x-sink_write) / …). Each has its OWN
  output cadence; multiple sinks with different cadences are first-class.
* `snapshot` — an `integrator -> StateSnapshot` function. Defaults to
  [`state_snapshot`](/generated/api/extension/julia#x-state_snapshot) wrapped to also fold in the observed caches; a caller
  supplies one that captures its observed caches when writing observed fields.
* `pre_write` — a `() -> nothing` hook the `affect!` calls at each output boundary
  BEFORE `snapshot(integrator)`, so the caller-named observed caches are fresh when
  the snapshot reads them. Defaults to a no-op.

`affect!` at each tick: run `pre_write()`, build the snapshot via
`snapshot(integrator)`, then for each sink whose `sink_output_times` contains the
tick, call `sink_write!(sink, snap)`.

`cb` is a `PresetTimeCallback`; `tstops` is the sorted, de-duplicated UNION of
every sink's [`sink_output_times`](/generated/api/extension/julia#x-sink_output_times) — the identical construction
[`build_refresh_callback`](/generated/api/extension/julia#x-build_refresh_callback) uses for provider refresh times, so **input
refresh and output write compose in one `CallbackSet`** (union the two tstops).
Returns an empty-tstops no-op callback when every sink is predicate-only.

Requires `DiffEqCallbacks` and `SciMLBase` to be loaded (the constructor is a
package extension); calling it without them throws [`OutputError`](/generated/api/ref/output_error).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/data_output.jl#L257)

### `build_refresh_callback` {#x-build_refresh_callback}

*function* · canonical name `build_refresh_callback`

```julia
build_refresh_callback(args...; kwargs...)
```

```julia
build_refresh_callback(; providers, buffers,
                       post_refresh = () -> nothing)
    -> (cb, tstops::Vector{Float64})
```

Build the discrete-cadence loader-refresh callback and its tstops, WITHOUT
embedding a solver (`[[library-exposes-rhs-not-solver]]`). The callback is a
pure function of the `providers` and `buffers` registries — it never reads the
model (the forcing names and cadences live entirely in those two arguments).
`esm_problem(…; providers)` composes it for a document's own discrete providers;
a caller who binds forcing buffers through `param_arrays` instead attaches it
to the run:

```julia
forcing = Dict("wind" => zeros(nx, ny))
prob = esm_problem(doc, tspan; param_arrays = forcing, …)
cb, tstops = build_refresh_callback(;
    providers = Dict("wind" => wind_provider),   # var name => data Provider
    buffers   = RefreshBuffers(forcing))         # same array objects as param_arrays
sol = solve(prob, Tsit5(); callback = cb, tstops = tstops)
```

`providers` maps each forcing variable to a data provider (the
[`provider_refresh_times`](/generated/api/extension/julia#x-provider_refresh_times) / [`provider_is_const`](/generated/api/extension/julia#x-provider_is_const) /
[`provider_sample`](/generated/api/extension/julia#x-provider_sample) protocol). Several variables may share one provider
object; it is then sampled once per cadence boundary. The provider delivers the
native forcing on the buffer's grid; any native→sim regrid is an ordinary
in-model coupling expression the RHS evaluates, not a refresh-time transform.

* **DISCRETE** providers (non-empty `provider_refresh_times`) are refreshed at
  each anchor: `affect!` samples and writes the buffer in place, then
  calls `u_modified!(integrator, true)`. The forcing lives in `p`, so changing it
  changes `f(u, p, t)` even though `u` is untouched; `true` forces an FSAL
  integrator (Tsit5, …) to recompute its cached derivative from the refreshed
  buffer instead of reusing the stale pre-refresh one for a stage. It does NOT
  reset `u` or the trajectory — only the derivative cache. Dependent/observed
  variables need no separate refresh — they are RHS expressions over the buffers,
  so they recompute automatically on the next step.
* **CONST** providers ([`provider_is_const`](/generated/api/extension/julia#x-provider_is_const)) are materialized once into
  `const_arrays` at build time; they contribute no tstops and are
  absent from the callback.

`post_refresh` is a `() -> nothing` hook the `affect!` calls at each boundary
AFTER the raw forcing buffers are refreshed and BEFORE `u_modified!` — the
discrete-cadence materialization seam (the middle phase of the `const ⊏ discrete
⊏ continuous` cadence partition). [`esm_problem`](/generated/api/ref/esm_problem-function) wires it to the
[`DiscreteMaterializer`](/generated/api/extension/julia#x-discretematerializer)'s `materialize!` so a state-free derived field (a
regrid→physics stack over the forcing) is recomputed once per boundary into its
cache buffer instead of on every continuous step. Defaults to a no-op.

`cb` is a `PresetTimeCallback`; `tstops` is the sorted, de-duplicated union of
the DISCRETE providers' refresh times. Returns an empty-tstops no-op callback
when every provider is CONST.

Requires `DiffEqCallbacks` and `SciMLBase` to be loaded (the constructor is a
package extension); calling it without them throws [`RefreshError`](/generated/api/extension/julia#x-refresherror).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/data_refresh.jl#L356)

### `build_spatial_index` {#x-build_spatial_index}

*function* · canonical name `build_spatial_index`

```julia
build_spatial_index(cell_envs; eps=0.0) -> <spatial index>
```

Build a spatial index over `cell_envs` (envelopes inflated outward by `eps`) for
the fast [`broad_phase_candidates`](/generated/api/extension/julia#x-broad_phase_candidates) path. Only available when the
`EarthSciASTGeometryOpsExt` extension is loaded (needs `GeometryOps`,
`SortTileRecursiveTree`, `Extents`); the returned index is passed as the second
argument to `broad_phase_candidates`, which must be called with the SAME `eps`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/broad_phase.jl#L60)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/data_output.jl#L1034)

### `BuildInspection` {#x-buildinspection}

*type* · canonical name `build_inspection`

```julia
mutable struct BuildInspection
BuildInspection(setup_arrays::Dict{String, Array{Float64}}, const_arrays::Dict{String, Any}, observed_exprs::Dict{String, ASTExpr}, params::Dict{String, Float64}, observed_defs::Dict{String, ASTExpr}, derived_extents::Dict{String, Int64}, param_classes::Dict{String, Symbol}, compiler_report::CompilerReport, forcing_buffers::NamedTuple, forcing_buffer_index::Dict{String, Int64}, observed_memo::Dict{Tuple{Base.RefValue{Any}, String}, EarthSciAST._ObservedMemo}, observed_lock::ReentrantLock, observed_build::Base.RefValue{Any}, observed_ctx, observed_ctxs::WeakKeyDict{Base.RefValue{Any}, Any}, unvalued_slots::Vector{Int64}, program_seed)
BuildInspection(setup_arrays, const_arrays, observed_exprs, params, observed_defs, derived_extents, param_classes, compiler_report, forcing_buffers, forcing_buffer_index, observed_memo, observed_lock, observed_build, observed_ctx, observed_ctxs, unvalued_slots, program_seed)
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
  observeds, keyed-factor aliases, materialized clip rings and setup arrays.
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

Filling the record never changes the build: the returned
`(f!, u0, p, tspan, var_map)` is identical with or without `inspect`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/tree_walk/build.jl#L20)

### `coerce_coupling_entry` {#x-coerce_coupling_entry}

*function* · canonical name `coerce_coupling_entry`

```julia
coerce_coupling_entry(data)
```

```julia
coerce_coupling_entry(data::Any) -> CouplingEntry
```

Coerce JSON data into concrete CouplingEntry subtype based on the 'type' field.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/parse.jl#L1192)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/parse.jl#L839)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/simulate.jl#L911)

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

The same record, off a build's inspection sink. A caller who passed
`inspect = insp` to [`esm_problem`](/generated/api/ref/esm_problem-function) reads it here — including after a
build that REFUSED, which is the case the partial record is most wanted for and
the one no Problem exists to carry.

This is the whole of what build observability answers about the compiler:
the tier every rule landed on, the declines it collected getting there, and the
build's cascade counters. `compiler_report(prob)` is the same object.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/simulate.jl#L921)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/compiler.jl#L19)

### `CompilerRuleRecord` {#x-compilerrulerecord}

*type* · canonical name `compiler_rule_record`

```julia
struct CompilerRuleRecord
CompilerRuleRecord(rule::String, kind::Symbol, tier::Symbol, declines::Vector{Pair{Symbol, Symbol}})
CompilerRuleRecord(rule, kind, tier, declines)
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
* `declines` — `tier => reason` for every tier that looked at this rule and
  passed, deepest reason last.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/compiler.jl#L229)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/types.jl#L743)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/types.jl#L1919)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/types.jl#L1933)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/types.jl#L1906)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/types.jl#L1828)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/types.jl#L1873)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/data_output.jl#L774)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/run_tests.jl#L203)

### `DiscreteMaterializer` {#x-discretematerializer}

*type* · canonical name `discrete_materializer`

```julia
mutable struct DiscreteMaterializer
DiscreteMaterializer(caches::Dict{String, Array{Float64}}, materialize!::Function, var_order::Vector{String}, epoch::EarthSciAST._ForcingEpoch)
DiscreteMaterializer(caches, materialize!, var_order, epoch)
DiscreteMaterializer()
```

```julia
DiscreteMaterializer()
```

The **discrete-cadence materialization** sink — the middle phase of the
three-phase cadence partition (`const ⊏ discrete ⊏ continuous`, `cadence.jl`).
[`esm_problem`](/generated/api/ref/esm_problem-function) ALWAYS makes the cut: it creates one of these when the
`materialize_out` keyword is not given, and passing your own only makes it
inspectable. A direct `build_evaluator` call without the keyword makes no cut,
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
  caches, in dependency order. `build_evaluator` runs it ONCE at build (so u0
  seeding and the first RHS evaluation read valid caches); the caller re-runs it
  after each in-place forcing refresh. [`esm_problem`](/generated/api/ref/esm_problem-function) wires it as the
  refresh callback's `post_refresh` hook automatically.
* `var_order::Vector{String}` — the dependency order the fills run in.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/tree_walk/build.jl#L155)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/term_provenance.jl#L74)

### `equation_unit_findings` {#x-equation_unit_findings}

*function* · canonical name `equation_unit_findings`

```julia
equation_unit_findings(eq::Equation, var_units::AbstractDict)
```

```julia
equation_unit_findings(eq::Equation, var_units::AbstractDict) -> Vector{String}
```

The PROVABLE dimensional inconsistency of a derivative equation's two SIDES, if
any: the comparison half of the equation check site (esm-spec §4.8.4, §4.8.6),
which `validate` reports for every `D(u, t) = …` equation (see
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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/units.jl#L1998)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/run_tests.jl#L91)

### `esm_path` {#x-esm_path}

*function* · canonical name `esm_path`

```julia
esm_path(parts::AbstractString...)
```

```julia
esm_path(parts...) -> String
```

Join `parts` onto `esm_root()`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/run_tests.jl#L45)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/run_tests.jl#L31)

### `evaluate_closed_function_ad` {#x-evaluate_closed_function_ad}

*function* · canonical name `evaluate_closed_function_ad`

```julia
evaluate_closed_function_ad(name::String, args::AbstractVector)
```

```julia
evaluate_closed_function_ad(name::String, args::AbstractVector) -> Any
```

The eltype-generic twin of [`evaluate_closed_function`](/generated/api/ref/evaluate_closed_function), for callers whose
argument values may be AD dual numbers (`ForwardDiff.Dual`). Same registry, same
diagnostics, same values — it only drops the `Float64` pinning.

WHY THIS IS A SEPARATE FUNCTION, and not just a relaxed `evaluate_closed_function`:
`evaluate_closed_function` must infer as the CONCRETE `Union{Float64,Int32}`. It
is called from the `:fn` arm of the tree-walk's `_eval_node_op`, and Julia infers
that function's return type as the union over ALL of its arms — so if this
registry widened to `Any`, the `:fn` arm would drag `_eval_node_op` (and with it
the whole recursive RHS walk) down to `Any` and cost EVERY model — even ones with
no `fn` node at all — its zero-allocation property. Pinning the float-returning
arms to `::Float64` is what holds that line, and a dual cannot survive the pin.

So the split is deliberate: the `Float64` solve path keeps the pinned registry and
its inference, and the AD path — which is already boxing duals anyway — takes this
one. Callers select between them on the COMPILE-TIME value type (`T === Float64`),
so the branch folds away and the `Float64` path never even compiles this call.

Beyond the three float-returning functions, the CALENDAR fields are handled
here too — not because a `Dual` needs it (the pinned registry takes its primal
and returns `Int32` quite happily) but because a value type that cannot reach
`Float64` at all has no `Int32` to be given. A traced number is exactly that,
and returning the argument's own type is what keeps the decomposition inside
the traced program. `interp.searchsorted` still falls through: its `Int32`
index is a build-time table position, not a value the traced program computes.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/registered_functions.jl#L329)

### `evaluate_expr` {#x-evaluate_expr}

*function* · canonical name `evaluate_expr`

```julia
evaluate_expr(expr::ASTExpr, bindings::AbstractDict; registered_functions)
```

```julia
evaluate_expr(expr::ASTExpr, bindings::AbstractDict;
              registered_functions::AbstractDict=Dict{String,Function}())::Float64
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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/tree_walk/build.jl#L8534)

### `EventType` {#x-eventtype}

*type* · canonical name `event_type`

```julia
abstract type EventType
```

```julia
abstract type EventType end
```

Abstract base type for all event types in the ESM format.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/types.jl#L729)

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
every surviving `apply_expression_template` reference in the flattened
equations and observed expressions against the merged `template_registry`,
returning an Expanded copy, bit-identical to the Expand-at-load image. A no-op
when the registry is empty (no references survived). `flatten` ALWAYS carries
references, so a consumer with no template handling calls this at its entry —
the MTK `System`/`PDESystem` constructors do; the tree-walk build
does NOT (it expands at its own entry with site recording, the compile-once
tier).

Every expression-bearing position ON A VARIABLE is expanded too, not only the
equations. In esm 1.0.0 an observed unknown's body is its defining EQUATION, so
the declaration itself carries no expression; what remains on a variable is a
parameter update's `when` trigger and its `expression` value form (esm-spec
§5.4). The flattener namespaces those for every variable before partitioning it
into `state_variables` / `parameters` / `observed_variables`, so any of the
three buckets can legally carry an `apply_expression_template` inside an
`update`. Expanding only the equations left an Option-B node in a parameter's
update for a consumer that had been promised an Option-A image.

`memo` is the shared expansion memo (`_expand_model_refs!`'s default, ~34% of
build wall time on the 7×7×7 transport fixture when absent): structurally
identical apply sites expand once and share the result. Pass `nothing` for the
per-site re-expansion. Sharing is safe here for the same reason it is in
`_expand_model_refs!` — the expanded set becomes a DAG, which is what interning
would produce one pass later anyway.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/lower_expression_templates.jl#L2202)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/lower_expression_templates.jl#L2093)

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
document's `component_templates` — the same expansion `build_evaluator`
performs before compiling, exposed as a public seam so downstream tools
(e.g. EarthSciASTDiff, which differentiates the tree) analyze the SAME tree
the evaluator compiles. `file` is not mutated.

Model selection matches the build's: `model_name = nothing`
selects the document's only model, or throws `E_TREEWALK_AMBIGUOUS_MODEL`
when there are several; an unknown name throws `E_TREEWALK_NO_MODEL`.
A document with no surviving references returns the plain copy.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/tree_walk/build.jl#L7862)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/parse.jl#L66)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/units.jl#L1937)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/run_tests.jl#L83)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/simulate.jl#L36)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/tree_walk/oop.jl#L834)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/tree_walk/oop.jl#L820)

### `forcing_epoch` {#x-forcing_epoch}

*function* · canonical name `forcing_epoch`

```julia
forcing_epoch(fs::ForcingSet)
```

```julia
forcing_epoch(fs::ForcingSet) -> UInt64
```

The set's epoch: unique in the process, never reused.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/rhs_program.jl#L228)

### `forcing_slots` {#x-forcing_slots}

*function* · canonical name `forcing_slots`

```julia
forcing_slots(x)
```

```julia
forcing_slots(x) -> Vector{ForcingSlot}
```

The buffers a [`ForcingSet`](/generated/api/ref/forcing_set-type) of `x` (a program, a tile or a lane program)
holds, in ascending byte order of flattened name. A derived program has its
parent's slots.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/rhs_program.jl#L153)

### `format_expression_ascii` {#x-format_expression_ascii}

*function* · canonical name `format_expression_ascii`

```julia
format_expression_ascii(expr::ASTExpr)
```

```julia
format_expression_ascii(expr::ASTExpr) -> String
```

Format an expression as plain ASCII mathematical notation.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/display.jl#L747)

### `format_node_label` {#x-format_node_label}

*function* · canonical name `format_node_label`

```julia
format_node_label(name::String)
```

```julia
format_node_label(name::String) -> String
```

Format node label with chemical subscript rendering if applicable.
Detects chemical formulas and applies subscript formatting.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/graph.jl#L715)

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
notes and to emit `@warn`s listing the gap IDs so callers know which
downstream beads must land before their model can be migrated cleanly.

Each entry carries:
- `bead_id`: the upstream bead tracking the gap (or `"unknown"`)
- `description`: human-readable one-liner (shown in warnings and JSON)
- `location`: location hint (variable or equation index) for the user

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/mtk_export.jl#L16)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/data_output.jl#L487)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/range_restricted.jl#L3275)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/units.jl#L1964)

### `has_spatial_derivative` {#x-has_spatial_derivative}

*function* · canonical name `has_spatial_derivative`

```julia
has_spatial_derivative(model::Model)
```

```julia
has_spatial_derivative(model::Model) -> Bool
```

True iff some equation of `model` contains a spatial derivative anywhere in its
LHS or RHS — a `D` whose `wrt` is present and is not `"t"`, or a `grad` / `div`
/ `laplacian` sugar op (esm-spec §6.3.1).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/classification.jl#L373)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/classification.jl#L383)

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
  across equations, this function raises an `ArgumentError`.

This pass is deliberately standalone — it does not mutate `FlattenedSystem`.
It is called at MTK build time from `ext/EarthSciASTMTKExt.jl` so
scalar-only callers pay no cost.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/array_shape_inference.jl#L10)

### `infer_variable_units` {#x-infer_variable_units}

*function* · canonical name `infer_variable_units`

```julia
infer_variable_units(var_name::AbstractString, equations::Vector{Equation}, known_units::AbstractDict)
```

Infer appropriate units for a variable based on its usage in equations.

This can help suggest units when they are not explicitly specified.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/units.jl#L2579)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/types.jl#L79)

### `is_literal` {#x-is_literal}

*function* · canonical name `is_literal`

```julia
is_literal(expr::ASTExpr)
```

```julia
is_literal(expr::ASTExpr)::Bool
```

True iff `expr` is a numeric literal (either integer or float node).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/expression.jl#L658)

### `is_valid_identifier` {#x-is_valid_identifier}

*function* · canonical name `is_valid_identifier`

```julia
is_valid_identifier(name::String)
```

```julia
is_valid_identifier(name::String) -> Bool
```

Check if a string is a valid identifier (letters, numbers, underscores, no leading digit).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/types.jl#L2715)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/range_restricted.jl#L3206)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/range_restricted.jl#L3190)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/expression.jl#L665)

### `mass_action_rate` {#x-mass_action_rate}

*function* · canonical name `mass_action_rate`

```julia
mass_action_rate(reaction::Reaction, species::Vector{Species})
```

```julia
mass_action_rate(reaction::Reaction, species::Vector{Species}) -> ASTExpr
```

Compute the mass action rate expression for a reaction.

Uses standard mass action kinetics: `rate = k * ∏[reactants]^stoichiometry`.

Per `esm-spec.md` §7.4 the `reaction.rate` field is the rate **coefficient**
(`k`, possibly a temperature-dependent expression). The full rate law is
always `k · ∏ Sᵢ^nᵢ` — the runner unconditionally multiplies the coefficient
by the substrate product. Source reactions (no substrates) return the
coefficient unchanged.

**Arguments**
- `reaction::Reaction`: The reaction to compute the rate for
- `species::Vector{Species}`: All species in the system (unused by this
  helper; retained for API stability and future validation)

**Returns**
- `ASTExpr`: Mass action rate expression

**Examples**
```julia
# For reaction A + B -> C with rate="k":
# Returns: k * A * B
#
# For source reaction -> A with rate="k":
# Returns: k
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/reactions.jl#L181)

### `model_unit_findings` {#x-model_unit_findings}

*function* · canonical name `model_unit_findings`

```julia
model_unit_findings(model::Model; file, toplevel)
```

```julia
model_unit_findings(model::Model; file=nothing, toplevel=nothing) -> Vector{UnitFinding}
```

Every units finding in `model`. A scoped reference (`sub.v`, `Leaf.p`) has the
units its target declares: relative to `model`'s own subsystems always, and to
the top-level models and reaction systems of `file` (the `EsmFile` holding
`model`) when one is given — see `scoped_reference_units`. A caller
checking many components of one document passes the document-wide part,
`toplevel = _toplevel_scoped_units(file)`, built once, in place of `file`.
Callers prefix their JSON pointer and promote
each finding to a structural error under its own code; see
`validate_model_unit_consistency` in validate.jl, the single structural caller.

Five families are checked:

1. **Unresolvable unit strings** (`unit_parse_error`) — a `units` or
   `default_units` string that does not resolve against the registry.
2. **Declared vs default units** — a parameter whose `default` is supplied in
   `default_units` that are not the same unit as its declared `units`.
3. **Observed-variable defining expressions** — an inconsistency *inside* the
   expression-bearing fields of a parameter's `update` (§5.4) — the `when`
   trigger and the `expression` value form.
4. **Equations** — the two-sided balance of a derivative equation.
5. **Defining equations** — an inconsistency inside a bare-variable-LHS
   equation's right-hand side, and the defined variable's declared units against
   the dimension that right-hand side actually has (esm-spec §6.3.1). It
   reports at the DEFINED VARIABLE's pointer, which is where the shared corpus
   pins it.

Subsystems are NOT recursed here (the caller owns path construction and does the
recursion), keeping this function's pointers purely model-local.

Iteration over `model.variables` is sorted by name so the finding order is
deterministic regardless of Dict hashing.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/units.jl#L2184)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/types.jl#L1018)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/mtk_export.jl#L35)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/mtk_export.jl#L76)

### `n_states` {#x-n_states}

*function* · canonical name `n_states`

```julia
n_states(x::Union{EarthSciAST.RhsProgram, EarthSciAST.TileProgram})
```

```julia
n_states(prog) -> Int
```

The length of `u` (API_SPEC §5.8, "States and parameters").

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/range_restricted.jl#L751)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/types.jl#L64)

### `OpExpr` {#x-opexpr}

*type* · canonical name `op_expr`

```julia
mutable struct OpExpr <: ASTExpr
OpExpr(op::String, args::Vector{ASTExpr}; wrt, dim, int_var, lower, upper, output_idx, expr_body, reduce, semiring, ranges, regions, values, shape, perm, axis, fn, name, value, units, table, table_axes, output, join, filter, join_gates, id, manifold, distinct, key, arg, bindings, label, expect_cadence, attrs, handler_id)
OpExpr(op::String, args::AbstractVector; kwargs...)
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
- `dim`: dimension for spatial operators (optional; for `grad`, `div`)
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
  semiring ⊕ only; it is the shorthand retained for files that omit `semiring`
  (RFC semiring-faq-unified-ir §5.1).
- `semiring`: for `faq`, the named semiring `(⊕, ⊗)` with
  normative identity elements that parameterizes the reduction (closed registry:
  "sum_product", "max_product", "min_sum", "max_sum", "bool_and_or"). Absent ⇒
  "sum_product", the ordinary einsum semantics. When present it supersedes
  `reduce`; the ⊕/⊗ operators and BOTH identities come from the registry table,
  never the file (RFC §5.1).
- `ranges`: for `faq`, map from index symbol name to iteration range
  (vector of 2 or 3 ints `[start, stop]` / `[start, step, stop]`).
- `regions`: for `makearray`, list of sub-region boxes, each a list of
  `[start, stop]` pairs per output dimension. A bound is normally an `Int`
  (metaparameters are folded on the raw tree before typed coercion,
  esm-spec §9.7.6), but the schema admits any `MetaparameterExpression`, so a
  bound MAY also be an `ASTExpr` — that is how a still-open bound such as
  `NLON - 1` survives `parse_expression` of the text form
  `makearray([2:NLON - 1, …] = …)`.
- `values`: for `makearray`, one sub-expression per entry in `regions`.
- `shape`: for `reshape`, target shape; entries are `Int` (concrete length)
  or `String` (symbolic dimension).
- `perm`: for `transpose`, optional 0-based axis permutation.
- `axis`: for `concat`, 0-based axis to concatenate along.
- `fn`: for `broadcast`, the scalar operator to apply element-wise.
- `name`: for the `fn` op, the dotted module path of a function in the closed
  function registry (esm-spec §9.2). The set of valid `name` values is fixed by
  the spec version; bindings MUST reject unknown names with diagnostic
  `unknown_closed_function`.
- `value`: for the `const` op, the inline literal value carried by this node.
  Any JSON value (number, integer, or nested array thereof); `args` MUST be
  empty for a const node.
- `label`: optional documentary relation tag for a `skolem` node (e.g. "edge",
  "bin", "pair") — the human-facing name of the relation the emitted key belongs
  to. Purely documentary: it is NOT part of the emitted key (it renders as a
  trailing `label=L` named argument); `args` are the pure key components.
- `units`: for `const`, the declared unit of `value` (esm-spec §4.8.5).
- `table`, `table_axes`, `output`: for `table_lookup` (esm-spec §9.5), the
  `function_tables` entry id, the per-axis input-coordinate expressions (wire
  key `"axes"`; `args` MUST be empty), and, for a multi-output table, the
  output selector (a 0-based integer or an output name).
- `join`, `filter`: for `faq`, the equi-join clauses (each a list of
  `[left, right]` key-column pairs that must compare equal) and an optional
  boolean predicate; a combination for which the predicate is false contributes
  the additive identity.
- `join_gates`: internal, build-time resolution of `join`; never parsed or
  serialized.
- `id`, `manifold`: for `intersect_polygon`, the node-local identifier a
  `kind: "derived"` index set names through `from_faq`, and the geometry
  interpretation (`"planar"`, `"spherical"` or `"geodesic"`; required).
- `distinct`, `key`: for a value-inventing `faq`, whether it produces a
  deduplicated index set, and the `skolem` key expression it emits per
  surviving index combination.
- `arg`: for `argmin` / `argmax`, the index symbol whose value at the optimum
  is returned.
- `bindings`: for `apply_expression_template`, the parameter → argument
  expression map (esm-spec §9.6).
- `expect_cadence`: an optional author assertion of this node's cadence class
  (`"const"`, `"discrete"` or `"continuous"`); carried verbatim, and an error is
  raised only when the derived class disagrees.
- `attrs`: named scalar attributes of an open rewrite-target op (esm-spec
  §4.2), such as a custom scheme's parameters.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/types.jl#L243)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/data_output.jl#L1018)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/tree_walk/build.jl#L7745)

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
`_PARAM_READS` seam) and anything they touched is `:structural` — by
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
`build_evaluator` return value: the 5-tuple has hundreds of destructuring call
sites. Pass `inspect = BuildInspection()` to `build_evaluator` / `esm_problem`,
or read it off the `EsmProblem` that `esm_problem` returns.

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/tree_walk/build.jl#L7776)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/types.jl#L956)

### `parameter_vector` {#x-parameter_vector}

*function* · canonical name `parameter_vector`

```julia
parameter_vector(x)
parameter_vector(x, overrides::AbstractDict)
```

```julia
parameter_vector(prog, overrides = Dict()) -> Vector{Float64}
```

The parameter vector of `prog` in [`parameters`](/generated/api/ref/parameters) order: each entry the
override named for it, else its default. Strict: an override naming no
parameter, or a parameter with neither, is an error naming it.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/rhs_program.jl#L239)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/types.jl#L1056)

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
the only numeric atom is the literal `1`. Whitespace between terms is multiplication (`"ppb^-1 s^-1"`); division is
LEFT-associative (`"L/mol/s"` is L·mol⁻¹·s⁻¹); parentheses group a compound
denominator (`"J/(mol*K)"`). An exponent may be RATIONAL — `"1/s^0.5"` is the
noise intensity of an SDE and is in the corpus.

Normalised before parsing: `µ`/`μ`→`u`, `°C`→`degC`, `°F`→`degF`, `Ω`→`Ohm`,
`·`/`⋅`→`*`, and superscript runs (`m²`, `cm³`, `m⁻³`) → `^n`. `""`, `"1"` and
`"dimensionless"` are the dimensionless unit.

Returns `nothing` when the string does not parse or names a symbol outside the
registry. That is a DEFECT IN THE FILE, not a limit of the checker: the
structural validator promotes it to a hard `unit_parse_error` (§4.8.4). It is
therefore silent here — the caller decides the severity, and an incomplete
registry must be fixed by extending the registry, never by downgrading this to
a warning.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/units.jl#L544)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/units.jl#L517)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/run_tests.jl#L74)

### `PeriodicTrigger` {#x-periodictrigger}

*type* · canonical name `periodic_trigger`

```julia
struct PeriodicTrigger <: DiscreteEventTrigger
PeriodicTrigger(period::Float64; phase)
```

```julia
PeriodicTrigger(period::Float64, phase::Float64)
```

Trigger that fires periodically.
- `period`: time interval between triggers
- `phase`: time offset for first trigger

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/types.jl#L752)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/graph.jl#L90)

### `PresetTimesTrigger` {#x-presettimestrigger}

*type* · canonical name `preset_times_trigger`

```julia
struct PresetTimesTrigger <: DiscreteEventTrigger
PresetTimesTrigger(times::Vector{Float64})
PresetTimesTrigger(times)
```

```julia
PresetTimesTrigger(times::Vector{Float64})
```

Trigger that fires at preset times.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/types.jl#L767)

### `provider_extent_metaparameter` {#x-provider_extent_metaparameter}

*function* · canonical name `provider_extent_metaparameter`

```julia
provider_extent_metaparameter(::Any)
```

```julia
provider_extent_metaparameter(provider) -> Union{Nothing,String}
```

The metaparameter this provider's own EXTENT binds (esm-spec §8.9.4), or
`nothing` (the default) for a provider whose size the document already knows.

A source whose record count is not knowable until it is read — an FF10 point
inventory, whose surviving-row count depends on its own `codes` map and
`record_filter` — declares `extent: {"metaparameter": "N_REC"}` on its loader.
[`esm_problem`](/generated/api/ref/esm_problem-function) then samples such a provider ONCE, BEFORE it closes
metaparameters at the loader API (esm-spec §9.7.6 binding site 3), and the
length of the delivered record axis binds that metaparameter — so an index set
declared `size: "N_REC"` is sized by the data instead of by a caller who counted
the rows and passed the number in.

Every provider naming the same metaparameter MUST agree on the count; that
agreement is also the alignment check across one table's columns. A caller
binding of the same metaparameter that CONTRADICTS the discovered value is an
error rather than a silent preference for either (CONFORMANCE_SPEC §5.5).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/data_refresh.jl#L139)

### `provider_gate_spec` {#x-provider_gate_spec}

*function* · canonical name `provider_gate_spec`

```julia
provider_gate_spec(::Any)
```

```julia
provider_gate_spec(provider) -> Union{Nothing,AbstractDict}
```

The projection-pushdown GATE for a deferred provider, or `nothing` (the default)
for an ordinary provider. A non-`nothing` gate marks `provider` as GATED: the
eager const-materialization loop in [`esm_problem`](/generated/api/ref/esm_problem-function) SKIPS it (it is not pulled
whole), and the build defers its fetch until value-invention has materialised the
gating derived set's members — then pushes that set down as a per-axis
`selection` ([`provider_sample`](/generated/api/extension/julia#x-provider_sample)) and fetches only the compact slab.

The gate is `Dict("axes"=>[…], "applies_to"=>[names…])`, mirroring the `.esm`
`data_sources.<name>.metadata.x_esd.gated_select` field (which the runner reads
to construct the gated provider — `format`/gating live at provider creation, not
in the 0.8.0 source schema). Each entry of `axes` is one per NATIVE array axis:

  * `"all"`                       → the whole axis;
  * `Dict("fixed"=>[i])`          → native 0-based index `i`, DROPPED (length-1);
  * `Dict("range"=>Dict("start"=>a, "stop"=>b, "step"=>s))`
                                  → the half-open 0-based window `[a, b)` by
                                    `s`, axis KEPT (`start`/`step` default 0/1);
  * `Dict("gated_by"=>"<set>")`   → the derived index set's materialised members
                                    (1-based), in the set's canonical order.

This is ONE vocabulary with the loader `select` of esm-spec §8.9.2 — the
spelling an author writes and the spelling `desugar_pushdown` generates are the
same thing (CONFORMANCE_SPEC §5.5). Only `gated_by` defers.

`applies_to` names the fetched variables to merge into `const_arrays`. Defaults
to `nothing`; a mock or the EarthSciIO binding overrides it.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/data_refresh.jl#L106)

### `provider_is_const` {#x-provider_is_const}

*function* · canonical name `provider_is_const`

```julia
provider_is_const(p)
```

```julia
provider_is_const(provider) -> Bool
```

True if `provider`'s data is time-invariant (no cadence). CONST providers are
materialized once into `const_arrays` at `build_evaluator` time and are absent
from the refresh callback. Defaults to "no refresh times"; a concrete impl may
override (e.g. EarthSciIO's `is_const`).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/data_refresh.jl#L80)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/data_refresh.jl#L199)

### `provider_refresh_times` {#x-provider_refresh_times}

*function* · canonical name `provider_refresh_times`

```julia
provider_refresh_times(p)
```

```julia
provider_refresh_times(provider) -> AbstractVector{Float64}
```

The cadence anchors at which `provider`'s data changes, in solver time
(seconds on the integrator's `t` axis). Empty for a time-invariant
(CONST) provider — such a provider is materialized once and contributes no
tstops. Concrete impls live in the data binding (EarthSciIO) or a test mock.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/data_refresh.jl#L64)

### `provider_sample` {#x-provider_sample}

*function* · canonical name `provider_sample`

```julia
provider_sample(p, ::Real; selection)
```

```julia
provider_sample(provider, t::Real; selection=nothing) -> sample
```

The native-grid data for `provider` at cadence tick `t` (solver seconds). The
return value is opaque to EarthSciAST — it is handed straight to the forcing-write seam
(`_write_forcing!`), which extracts a named variable from it.
For the EarthSciIO provider this is `refresh(p, t)` returning a `NativeDataset`;
for a mock it can be any per-variable container (e.g. a `Dict{String,Vector}`).

`selection` is an optional, provider-NEUTRAL per-axis projection pushdown: one
positional entry per NATIVE axis of the gated array(s). `selection===nothing`
(the default) samples the whole array — identical to the pre-pushdown behaviour,
so every existing 2-arg caller is unchanged. When supplied each entry is:

  * `Colon()`                         → the whole axis;
  * an `Integer i` (1-BASED)          → the single fixed index `i`;
  * an `AbstractVector{<:Integer}` (1-BASED) → that ordered list of indices.

The binding translates this to its native selection (the EarthSciIO extension
maps 1-based → 0-based and calls the zarr reader's `select`), fetching ONLY the
intersecting data. The gated axis of the returned array is ordered EXACTLY as the
index vector (a permuted list yields permuted rows — order is load-bearing, not
sorted). A `selection` may only be given to a provider whose
[`provider_supports_selection`](/generated/api/extension/julia#x-provider_supports_selection) is `true`; otherwise the binding errors.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/data_refresh.jl#L209)

### `provider_supports_selection` {#x-provider_supports_selection}

*function* · canonical name `provider_supports_selection`

```julia
provider_supports_selection(::Any)
```

```julia
provider_supports_selection(provider) -> Bool
```

True if `provider` can honour a per-call `selection` (projection pushdown) in
[`provider_sample`](/generated/api/extension/julia#x-provider_sample) — i.e. it reads only the requested slice of the
native array rather than the whole thing. Defaults to `false`; the data binding
overrides it (the EarthSciIO extension bridges to `EarthSciIO.supports_selection`,
true for a store-backed zarr provider, false for a whole-file reader). A caller
that wants to push a `selection` down MUST gate on this: handing a `selection`
to a provider that returns `false` is a clear error (the fall-back-to-full-then-
slice path, if any, belongs to the build side, not to `provider_sample`).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/data_refresh.jl#L91)

### `providers_from_document` {#x-providers_from_document}

*function* · canonical name `providers_from_document`

```julia
providers_from_document(doc; cache_root, loaders=nothing, url_overrides=Dict()) -> Dict{String,Any}
```

Construct the data providers a document DECLARES: one CONST provider per
data-fed PARAMETER, drawn from a `data_sources.<name>` entry carrying a
`metadata.esio_format` ("zarr", "ff10", …).

Keyed `"<ModelPath>.<param>"` — the CONSUMING parameter's flattened name, not
`"<Loader>.<var>"`. esm 1.0.0 moved the binding from the source to the consumer:
a source declares no variables of its own, so there is no loader-side name left
to key on; a model reads a field by declaring a parameter whose `update` names
the source and binds a `file_variable` (esm-spec §8.5). These are exactly the
`providers` keys [`esm_problem`](/generated/api/ref/esm_problem-function) consumes (and, with `pushdown_rewrite=true`,
gates from the rewrite record). `doc` is a raw document `Dict`, an `EsmFile`, or
a path.

Keywords:
  * `cache_root` — filesystem root for the download cache (per-loader subdir).
  * `loaders` — restrict to these loader names (`nothing` = every loader with
    an `esio_format`). Lets a runner exclude a loader whose format the reader
    stack cannot construct yet (the FF10-in-zip EGU case until Phase 2) and
    slot it in later without an API change.
  * `url_overrides` — loader name ⇒ URL, replacing `source.url_template`
    (e.g. a local mirror of a live store).

Implemented by the EarthSciIO extension — load `EarthSciIO` alongside
EarthSciAST so the `EarthSciASTEarthSciIOExt` extension defines the method
(without it the call is a `MethodError`; this generic deliberately carries no
fallback so the extension's method is an addition, not an overwrite). The
construction is format-agnostic: `esio_format` goes straight to
`EarthSciIO.const_provider(...; format=...)`, whose registry decides what is
readable. Selection capability (projection pushdown) is the provider's own
(`provider_supports_selection`), so a zarr-store loader produced here is
directly compatible with the gated-deferral path.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/data_refresh.jl#L162)

### `QualifiedReferenceError` {#x-qualifiedreferenceerror}

*error* · canonical name `qualified_reference_error`

```julia
struct QualifiedReferenceError <: EarthSciASTError
QualifiedReferenceError(message::String, reference::String, path::Vector{String})
QualifiedReferenceError(message, reference, path)
```

```julia
QualifiedReferenceError
```

Exception thrown when qualified reference resolution fails.
Contains detailed error information.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/types.jl#L2515)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/types.jl#L2530)

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

Registry mapping a forcing variable name to its live buffer — the dense
`Array{Float64}` bound BY REFERENCE through
`esm_problem(input, tspan; param_arrays = …)` (ess-14f.3). The refresh callback's
`affect!` writes the freshly sampled forcing into these exact objects in place, so the RHS
(which gathers the same aliased storage via `_NK_PARAM_GATHER`) sees the update
on its next evaluation.

Each value MUST be a dense `Array{Float64}`, matching the `param_arrays`
invariant — pass the SAME dictionary you gave `param_arrays` (or its values) so
the buffers are shared, not copied:

```julia
forcing = Dict("wind" => zeros(nx, ny))
prob = esm_problem(doc, tspan; param_arrays = forcing, …)
buffers = RefreshBuffers(forcing)   # same array objects — aliased, not copied
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/data_refresh.jl#L304)

### `RefreshError` {#x-refresherror}

*error* · canonical name `refresh_error`

```julia
struct RefreshError <: EarthSciASTError
RefreshError(msg::String)
RefreshError(msg)
```

```julia
RefreshError(msg)
```

Thrown by the data-refresh surface: an unimplemented Provider
protocol method, a buffer that is not a dense `Array{Float64}`, a
shape/length mismatch at refresh time, or a call to
[`build_refresh_callback`](/generated/api/extension/julia#x-build_refresh_callback) before the `DiffEqCallbacks` / `SciMLBase`
extension is loaded.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/data_refresh.jl#L34)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/simulate.jl#L2128)

### `render_chemical_formula` {#x-render_chemical_formula}

*function* · canonical name `render_chemical_formula`

```julia
render_chemical_formula(formula::String)
```

```julia
render_chemical_formula(formula::String) -> String
```

Convert chemical formula to format with subscripts for visualization.

Thin wrapper over display.jl's element-aware
`format_chemical_subscripts` (`:unicode` form), so graph exports render
species exactly like the display formatters: digits become subscripts only when
they follow a recognized chemical element symbol.

**Examples**
```julia
render_chemical_formula("CO2") # "CO₂"
render_chemical_formula("H2SO4") # "H₂SO₄"
render_chemical_formula("CH3OH") # "CH₃OH"
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/graph.jl#L695)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/rhs_program.jl#L211)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/types.jl#L2543)

### `rhs!` {#x-rhs}

*function* · canonical name `rhs`

```julia
rhs!(du::AbstractVector, x::Union{EarthSciAST.RhsProgram, EarthSciAST.TileProgram}, ws::EarthSciAST.RhsWorkspace, u::AbstractVector, aux::AbstractVector, p, t, fs::ForcingSet)
rhs!(du::AbstractVector, lp::EarthSciAST.LaneProgram, ws::EarthSciAST.RhsWorkspace, u::AbstractVector, aux::AbstractVector, p, t, fs::ForcingSet, cells::AbstractMatrix, n::Integer)
rhs!(du::AbstractVector, lp::EarthSciAST.LaneProgram, ws::EarthSciAST.RhsWorkspace, u::AbstractVector, aux::AbstractVector, p, t, li::EarthSciAST.LaneInputs, cells::AbstractMatrix, n::Integer)
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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/range_restricted.jl#L835)

### `rhs_workspace` {#x-rhs_workspace}

*function* · canonical name `rhs_workspace`

```julia
rhs_workspace(x::EarthSciAST.TileProgram)
rhs_workspace(x::EarthSciAST.RhsProgram)
rhs_workspace(lp::EarthSciAST.LaneProgram)
```

```julia
rhs_workspace(x) -> RhsWorkspace
```

The mutable state of [`rhs!`](/generated/api/extension/julia#x-rhs) on `x` (a program, a tile or a lane
program): a private instance of its compiled right-hand side — its own caches,
scratch and forcing buffers; the generated code and every read-only table are
the program's. One per concurrent caller; a workspace may move between threads
but serves one call at a time.

A workspace of a whole-domain program made after the program was decomposed
([`halo`](/generated/api/ref/halo) or [`restrict`](/generated/api/ref/restrict)) evaluates it through the code its tiles
share (the program's tile over its whole domain), so the program and its tiles
compile one right-hand side; the values are the same.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/range_restricted.jl#L771)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/data_output.jl#L444)

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

Walk each directory in `roots`, run every inline test in every `.esm` file,
and return `(results::Vector{AssertionResult}, exit_code::Int)` where
`exit_code == 0` iff every assertion passed.

`root` is the base directory against which relative `roots` (and exclude
patterns) resolve — pass it to walk a different repo instead of overwriting
`esm_root()`. Discovery finding zero files logs a `@warn` (a mis-rooted
invocation must not silently pass).

Prints a per-file summary table to `io` when `verbose=true`. When
`junit_xml` is a path, emits a junit-compatible XML report there.

`exclude` (or the `ESM_TESTS_EXCLUDE` env var) drops any `.esm` file whose
path contains one of the listed substrings.

`stiff_files` is a set/vector of `.esm` basenames to integrate with the stiff
Rosenbrock23 solver instead of the default non-stiff Tsit5; it defaults to
`STIFF_SOLVER_OVERRIDE_FILENAMES` (currently just the known-stiff `pollu.esm`).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/run_tests.jl#L976)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/data_output.jl#L472)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/simulate.jl#L584)

### `serialize_coupling_entry` {#x-serialize_coupling_entry}

*function* · canonical name `serialize_coupling_entry`

```julia
serialize_coupling_entry(entry::CouplingEntry)
```

```julia
serialize_coupling_entry(entry::CouplingEntry) -> Dict{String,Any}
```

Serialize CouplingEntry to JSON-compatible format based on concrete type.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/serialize.jl#L338)

### `SHAPE_REQUIRING_UPDATE_KINDS` {#x-shape_requiring_update_kinds}

*constant* · canonical name `shape_requiring_update_kinds`

```julia
const SHAPE_REQUIRING_UPDATE_KINDS::Tuple{String, String, String}
```

The update kinds that require the parameter to declare a `shape` (§5.4).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/types.jl#L970)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/data_output.jl#L184)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/data_output.jl#L170)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/data_output.jl#L211)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/data_output.jl#L133)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/data_output.jl#L116)

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
Defaults to `false`; it is INERT in v1 (host-gather is a single whole-state write)
and becomes load-bearing with the deferred Reactant shard-local phase. A concrete
binding overrides it.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/data_output.jl#L199)

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
(distributed region writes). It is INERT in v1 (host-gather delivers the whole
state as a single offset-0 slab, `selection===nothing`); it becomes live with the
deferred Reactant shard-local [`state_snapshot`](/generated/api/extension/julia#x-state_snapshot) + [`sink_supports_partial`](/generated/api/extension/julia#x-sink_supports_partial).
Concrete impls live in the data binding or a test mock.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/data_output.jl#L148)

### `SKIP` {#x-skip}

*constant* · canonical name `skip`

```julia
const SKIP::AssertionStatus
```

```julia
SKIP::AssertionStatus
```

Reserved; no runner produces it. See [`AssertionStatus`](/generated/api/extension/julia#x-assertionstatus).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/run_tests.jl#L100)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/data_output.jl#L1105)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/classification.jl#L260)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/data_output.jl#L1128)

### `state_layout` {#x-state_layout}

*function* · canonical name `state_layout`

```julia
state_layout(x::Union{EarthSciAST.RhsProgram, EarthSciAST.TileProgram})
```

```julia
state_layout(prog) -> Vector{StateBlock}
```

The `u` blocks in flat-layout order (0-d states by sorted name, then arrays by
sorted name): name, 1-based offset, shape. Derived from
[`tile_layout`](/generated/api/extension/julia#x-tile_layout)`(prog)`; a tile's shapes are its storage box's.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/range_restricted.jl#L758)

### `state_snapshot` {#x-state_snapshot}

*function* · canonical name `state_snapshot`

```julia
state_snapshot(integrator)
```

```julia
state_snapshot(integrator) -> Vector{Tuple{Array,Tuple{Vararg{UnitRange{Int}}}}}
```

Host-gather the integrator's state into the [`StateSnapshot`](/generated/api/extension/julia#x-statesnapshot) `state` shape:
in v1 exactly one `(Array(integrator.u), (1:length(integrator.u),))` pair — the
whole flat state materialized on the host at global offset 0. `Array(u)` triggers
XLA's gather to host under a replicated/single-host Reactant tier and is a plain
copy on the CPU tree-walk path, so this one impl is correct at any scale that fits
one host's write bandwidth.

This is the mirror of what the INPUT side already does when it materializes host
forcing buffers. The multi-slab (shard-local) return — each device's local shard
with its global range, no global gather — is the deferred Reactant drop-in; adding
it changes only this function, not the sink or the callback.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/data_output.jl#L231)

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
  `(slab, global-range tuple)` pairs. In v1 (host-gather) this is exactly ONE
  entry, `(Array(u), (1:length(u),))` — the whole flat state at offset 0. The
  vector-of-slabs shape is what lets the deferred Reactant shard-local
  [`state_snapshot`](/generated/api/extension/julia#x-state_snapshot) return each rank's addressable shard with its GLOBAL
  range instead of a gathered whole, with no change to the sink or the callback.
* `observed::Dict{String,Array}` — caller-named observed/derived arrays,
  host-materialized (empty unless a sink's schema names observed outputs; those
  names drive what `pre_write` evaluates — the evaluator already produces them).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/data_output.jl#L75)

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

`details` is the MACHINE-READABLE half of the error, and Julia was the only
binding without it (CONFORMANCE_SPEC row (j)). A conformance pin asserts code,
path AND `details` under REQUIRED-SUBSET semantics (§7.1.2): every key the pin
names must be present with the pinned value, and extra keys are fine. Without the
field Julia cannot satisfy the 134 pins that carry one — it would be red in the
harness for a structural reason rather than a real disagreement.

It defaults to empty, so the three-positional-argument construction used
throughout keeps working; sites that name a variable populate `details["variable"]`
(the settled spelling), plus whatever else is locally meaningful.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/validate.jl#L22)

### `SubsystemRef` {#x-subsystemref}

*type* · canonical name `subsystem_ref`

```julia
struct SubsystemRef <: EarthSciAST.SubsystemNode
SubsystemRef(ref::String, bindings::Dict{String, Int64}, expression_template_imports::Vector{Any}, index_set_rename::Union{Nothing, OrderedCollections.OrderedDict{String, String}})
SubsystemRef(ref, bindings, expression_template_imports, index_set_rename)
SubsystemRef(ref::AbstractString, bindings::AbstractDict, injected::AbstractVector)
SubsystemRef(ref::AbstractString, bindings::AbstractDict)
SubsystemRef(ref::AbstractString)
```

```julia
SubsystemRef(ref::String)
SubsystemRef(ref::String, bindings::Dict{String,Int})
```

Unresolved reference to an external ESM file used as a subsystem (esm-spec §4.7).
Produced by `coerce_model` for a `{"ref": "..."}` subsystem entry and replaced
in place by `resolve_subsystem_refs!` with the loaded `Model`.
A `SubsystemRef` only survives parsing when references are not resolved (e.g.
`load_string` without a base path); `load_path` always resolves them.
`bindings` closes the referenced document's open metaparameters at this edge
(esm-spec §9.7.6 binding site 3 — e.g. a convergence wrapper instantiating a
problem file at a given size). `expression_template_imports` are the raw
§9.7.2 import entries injected into the REFERENCED component's own template
scope (esm-spec §9.7.10 form A — assembler-chosen discretization for a mounted
PDE leaf); they are threaded into the referenced document's load and consumed by
the §9.6.3 fixpoint, so a resolved subsystem round-trips as the lowered inline
component and the field does not survive `parse → emit`.
`index_set_rename` translates the mounted document's index-set names into the
mounting document's vocabulary at load (esm-spec §4.7 "Mount-edge index-set
renaming") — the §9.7.7 renaming mechanism at a component-mount edge, restricted
to index sets. Like the two fields above it is consumed at the mount and does not
survive `parse → emit`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/types.jl#L1632)

### `successors` {#x-successors}

*function* · canonical name `successors`

```julia
successors(graph::Graph{N, E}, node::N) where {N, E}
```

Get nodes that this node points to, each ONCE. See [`predecessors`](/generated/api/extension/julia#x-predecessors) for
why this deduplicates and [`adjacency`](/generated/api/extension/julia#x-adjacency) for why that one does not.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/graph.jl#L109)

### `sync_forcing!` {#x-sync_forcing}

*function* · canonical name `sync_forcing`

```julia
sync_forcing!(dest::NamedTuple, src::NamedTuple)
```

```julia
sync_forcing!(dest::NamedTuple, src::NamedTuple) -> dest
```

Copy every live forcing buffer in `src` into the same-named array of `dest`, in
place (`copyto!` element copy — `dest`'s arrays are never rebound). The refresh
hook for a compiled out-of-place RHS: when the RHS was `@compile`d through the
explicit-buffers form (`direct_rhs_with_buffers`, in the Reactant extension)
with device arrays (`Reactant.ConcreteRArray`s) as its buffers argument, those
arrays are real XLA inputs, and a `copyto!` into them between calls IS seen by
the already-compiled program — so mirroring the freshly refreshed host buffers
into them at each cadence boundary keeps the compiled forcing live, with no
retrace and no reallocation.

Wire it through [`build_refresh_callback`](/generated/api/extension/julia#x-build_refresh_callback)'s `post_refresh` hook, which
runs at each cadence boundary AFTER the host buffers are refreshed (and after
the [`DiscreteMaterializer`](/generated/api/extension/julia#x-discretematerializer) caches are refilled, when `post_refresh`
chains `materialize!` first):

```julia
prob = esm_problem(doc, tspan; param_arrays = forcing)
host = forcing_buffers(prob)                # aliased host buffers, stable order
dev  = map(Reactant.ConcreteRArray, host)   # the compiled program's inputs
cb, tstops = build_refresh_callback(;
    providers, buffers = RefreshBuffers(forcing),
    post_refresh = () -> sync_forcing!(dev, host))
```

`src` is normally [`forcing_buffers`](/generated/api/extension/julia#x-forcing_buffers)`(prob)`; any NamedTuple pair works
as long as every key of `src` is present in `dest` and shapes/lengths agree
(`copyto!` enforces length). Missing keys throw [`RefreshError`](/generated/api/extension/julia#x-refresherror).

THE COMPILED SIDE OF THIS IS NOT WIRED TO `esm_problem` YET, which is why the
snippet above stops at the buffers: `esm_problem(…; compiler = :xla)` REFUSES a
document that binds live forcing, by name, rather than bake the build-time
values into the program as constants. Composing that refresh — this
`post_refresh` hook, chained after the [`DiscreteMaterializer`](/generated/api/extension/julia#x-discretematerializer) fill — is
what the refusal is waiting on.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/data_refresh.jl#L430)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/compiler.jl#L302)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/range_restricted.jl#L732)

### `TreeWalkError` {#x-treewalkerror}

*error* · canonical name `tree_walk_error`

```julia
struct TreeWalkError <: EarthSciASTError
TreeWalkError(code::String, detail::String)
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
  `grad`/`div`/`laplacian`) reaches evaluation without a discretization
  rule having lowered it. That code is DELIBERATELY not `E_TREEWALK_*`:
  it is the uniform cross-binding wire code every implementation surfaces
  for this pipeline violation, so it must not be renamed to match the
  local convention.

`detail` carries op name or variable name for diagnostics.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/tree_walk/errors.jl#L11)

### `UnboundVariableError` {#x-unboundvariableerror}

*error* · canonical name `unbound_variable_error`

```julia
struct UnboundVariableError <: EarthSciASTError
UnboundVariableError(variable_name::String, message::String)
UnboundVariableError(variable_name, message)
```

```julia
UnboundVariableError
```

Raised by [`evaluate_expr`](/generated/api/extension/julia#x-evaluate_expr) (the tree-walk evaluator entry point)
when an expression references a variable name that is not in the supplied
bindings. Defined here so it is in scope for callers that catch the
"binding not yet resolved" signal during iterated observed-variable
fixed-point passes.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/expression.jl#L601)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/units.jl#L2132)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/units.jl#L2142)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/types.jl#L1046)

### `validate_file_dimensions` {#x-validate_file_dimensions}

*function* · canonical name `validate_file_dimensions`

```julia
validate_file_dimensions(file::EsmFile)
```

Validate dimensions for all components in an ESM file.

Returns true if all models and reaction systems pass dimensional validation.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/units.jl#L2390)

### `validate_model_dimensions` {#x-validate_model_dimensions}

*function* · canonical name `validate_model_dimensions`

```julia
validate_model_dimensions(model::Model)
```

Validate dimensions for all equations and variable definitions in a model.

Returns true when nothing in the model is PROVABLY dimensionally inconsistent.
Recurses into model subsystems.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/units.jl#L2353)

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
components of `file` (or the prebuilt `toplevel` map).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/validate.jl#L3630)

### `validate_reaction_system_dimensions` {#x-validate_reaction_system_dimensions}

*function* · canonical name `validate_reaction_system_dimensions`

```julia
validate_reaction_system_dimensions(rxn_sys::ReactionSystem)
```

Validate dimensions for all reactions in a reaction system.

Enforces the mass-action dimensional constraint from spec §7.4 by delegating
to [`validate_reaction_rate_units`](/generated/api/extension/julia#x-validate_reaction_rate_units) in validate.jl — the single shared
implementation of the rule (also used by `validate_structural`) — so the two
entry points cannot drift apart. Each finding is logged as a warning; returns
`true` when no dimensional inconsistencies are found.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/units.jl#L2373)

### `validate_reference_syntax` {#x-validate_reference_syntax}

*function* · canonical name `validate_reference_syntax`

```julia
validate_reference_syntax(reference::String)
```

```julia
validate_reference_syntax(reference::String) -> Bool
```

Validate that a reference string follows proper dot notation syntax.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/types.jl#L2684)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/types.jl#L94)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/run_tests.jl#L1169)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/data_output.jl#L1055)
