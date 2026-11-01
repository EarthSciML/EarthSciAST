---
title: "reject_solver_time_span_pre_v13"
description: "Stable function · Other"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Other](/generated/api/topics/other)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `reject_solver_time_span_pre_v13` | `rejectSolverTimeSpanPreV13` | `reject_solver_time_span_pre_v13` | `reject_solver_time_span_pre_v13` | `RejectSolverTimeSpanPreV13` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
reject_solver_time_span_pre_v13(raw_data)
```

```julia
reject_solver_time_span_pre_v13(raw_data)
```

Reject `solver.time_span` in a file declaring `esm` &lt; 1.3.0.

The field arrives at `esm: 1.3.0`; a document declaring an earlier version whose
`solver` block carries it is rejected with `solver_time_span_version_too_old`
at `/solver/time_span` (esm-spec §2.2.4 requirement 4). Runs before schema
validation, beside [`reject_solver_external_pre_v13`](/generated/api/ref/reject_solver_external_pre_v13).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/solver.jl#L200)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function rejectSolverTimeSpanPreV13(view: unknown): void
```

Reject `solver.time_span` in a file declaring esm &lt; 1.3.0.

`time_span` arrives at `esm: 1.3.0`; a 1.1.0 or 1.2.0 document whose `solver`
block carries it is rejected with `solver_time_span_version_too_old` at
`/solver/time_span` (esm-spec §2.2.4 requirement 4), before schema
validation. Below 1.1.0 the whole block is refused first, by
[`rejectSolverPreV11`](/generated/api/ref/reject_solver_pre_v11).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-ts/src/solver.ts#L209)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
reject_solver_time_span_pre_v13(view: Any) -> None
```

Reject `solver.time_span` in a file declaring esm &lt; 1.3.0.

The field arrives at `esm: 1.3.0`; an earlier document whose `solver`
block carries it is rejected with `solver_time_span_version_too_old` at
`/solver/time_span` (esm-spec §2.2.4 requirement 4), before schema
validation. A document below 1.1.0 never reaches this gate:
[`reject_solver_pre_v11`](/generated/api/ref/reject_solver_pre_v11) refuses its whole block first.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/solver.py#L145)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn reject_solver_time_span_pre_v13(view: &Value) -> Result<(), DiagnosticError>
```

Reject `solver.time_span` in a file declaring esm &lt; 1.3.0.

The field arrives at `esm: 1.3.0`, after the block itself, so it carries
its own code (esm-spec §2.2.4 requirement 4). A 1.1.0 or 1.2.0 document
whose block has no `time_span` stays valid. Below 1.1.0 the whole block is
already refused by [`reject_solver_pre_v11`](/generated/api/ref/reject_solver_pre_v11), which runs first. Reads the
ROOT's block only: a mounted document's `solver` block does not cross the
mount edge (§4.7).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/solver.rs#L268) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.reject_solver_time_span_pre_v13.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func RejectSolverTimeSpanPreV13(view map[string]any) error
```

RejectSolverTimeSpanPreV13 rejects `solver.time_span` in files declaring esm &lt; 1.3.0 with `solver_time_span_version_too_old` at `/solver/time_span` (esm-spec §2.2.4 requirement 4). A 1.1.0 or 1.2.0 document whose `solver` block carries no `time_span` stays valid. Below 1.1.0 the whole block is already refused by RejectSolverPreV11, which runs first.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/solver_time_span.go#L86) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#RejectSolverTimeSpanPreV13)

</div>

</div>
