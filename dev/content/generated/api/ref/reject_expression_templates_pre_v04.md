---
title: "reject_expression_templates_pre_v04"
description: "Stable function · Versions and migration"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Versions and migration](/generated/api/topics/versions)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `reject_expression_templates_pre_v04` | `rejectExpressionTemplatesPreV04` | `reject_expression_templates_pre_v04` | not exported | `RejectExpressionTemplatesPreV04` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
reject_expression_templates_pre_v04(raw_data)
```

```julia
reject_expression_templates_pre_v04(raw_data)
```

Reject `expression_templates` blocks and `apply_expression_template` ops in
files declaring `esm` &lt; 0.4.0. Mirrors the equivalent TS / Python / Rust /
Go checks for cross-binding-uniform diagnostics.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/lower_expression_templates.jl#L1621)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function rejectExpressionTemplatesPreV04(view: unknown): void
```

Reject `apply_expression_template` and `expression_templates` in files
declaring `esm` &lt; 0.4.0. Operates on the pre-coercion JSON view.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/lower-expression-templates.ts#L1438)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
reject_expression_templates_pre_v04(view: Any) -> None
```

Reject template constructs in files declaring esm &lt; 0.4.0.

Mirrors the equivalent TS / Julia / Rust / Go checks for
cross-binding-uniform diagnostics.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/lower_expression_templates.py#L939)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this function.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func RejectExpressionTemplatesPreV04(view map[string]any) error
```

RejectExpressionTemplatesPreV04 rejects `expression_templates` blocks and `apply_expression_template` ops in files declaring `esm` &lt; 0.4.0. Mirrors the equivalent TS / Python / Julia / Rust checks.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/lower_expression_templates.go#L1290) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#RejectExpressionTemplatesPreV04)

</div>

</div>
