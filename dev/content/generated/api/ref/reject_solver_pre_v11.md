---
title: "reject_solver_pre_v11"
description: "Stable function · Versions and migration"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Versions and migration](/generated/api/topics/versions)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `reject_solver_pre_v11` | `rejectSolverPreV11` | `reject_solver_pre_v11` | `reject_solver_pre_v11` | `RejectSolverPreV11` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
reject_solver_pre_v11(raw_data)
```

```julia
reject_solver_pre_v11(raw_data)
```

Reject a top-level `solver` block in a file declaring `esm` &lt; 1.1.0.

The block arrives at `esm: 1.1.0`; a document declaring an earlier version that
carries one is rejected with `solver_version_too_old` (esm-spec §2.2.4).
Mirrors [`reject_template_imports_pre_v08`](/generated/api/ref/reject_template_imports_pre_v08).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/solver.jl#L21)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function rejectSolverPreV11(view: unknown): void
```

Reject a top-level `solver` block in a file declaring esm &lt; 1.1.0.

The block arrives at `esm: 1.1.0`; a document declaring an earlier version
that carries one is rejected with `solver_version_too_old` (esm-spec
§2.2.4). Mirrors `rejectTemplateImportsPreV08`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/solver.ts#L63)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
reject_solver_pre_v11(view: Any) -> None
```

Reject a top-level `solver` block in a file declaring esm &lt; 1.1.0.

The block arrives at `esm: 1.1.0`; a document declaring an earlier
version that carries one is rejected with `solver_version_too_old`
(esm-spec §2.2.4). Mirrors [`reject_template_imports_pre_v08`](/generated/api/ref/reject_template_imports_pre_v08).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/solver.py#L91)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn reject_solver_pre_v11(view: &Value) -> Result<(), DiagnosticError>
```

Reject a top-level `solver` block in a file declaring esm &lt; 1.1.0.

The block arrives at `esm: 1.1.0`; a document declaring an earlier version
that carries one is rejected with `solver_version_too_old` (esm-spec
§2.2.4). Mirrors [`crate::template_imports::reject_template_imports_pre_v08`](/generated/api/ref/reject_template_imports_pre_v08).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/solver.rs#L30) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.reject_solver_pre_v11.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func RejectSolverPreV11(view map[string]any) error
```

RejectSolverPreV11 rejects a top-level `solver` block in files declaring esm &lt; 1.1.0. The block arrives at esm 1.1.0; a document declaring an earlier version that carries one is rejected with `solver_version_too_old` (esm-spec §2.2.4, §2.2.5). Mirrors RejectTemplateImportsPreV08.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/solver.go#L65) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#RejectSolverPreV11)

</div>

</div>
