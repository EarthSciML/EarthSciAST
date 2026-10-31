---
title: "reject_template_imports_pre_v08"
description: "Stable function · Versions and migration"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Versions and migration](/generated/api/topics/versions)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `reject_template_imports_pre_v08` | `rejectTemplateImportsPreV08` | `reject_template_imports_pre_v08` | `reject_template_imports_pre_v08` | `RejectTemplateImportsPreV08` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
reject_template_imports_pre_v08(raw_data)
```

```julia
reject_template_imports_pre_v08(raw_data)
```

`expression_template_imports`, top-level `expression_templates`
(template-library files), and `metaparameters` arrive at `esm: 0.8.0`; files
declaring an earlier version that carry any of them are rejected with
`template_import_version_too_old` (esm-spec §9.6.5). Mirrors
[`reject_expression_templates_pre_v04`](/generated/api/ref/reject_expression_templates_pre_v04) for the §9.7 constructs.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/template_imports.jl#L56)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function rejectTemplateImportsPreV08(view: unknown): void
```

`expression_template_imports`, top-level `expression_templates`
(template-library files), and `metaparameters` arrive at `esm: 0.8.0`;
files declaring an earlier version that carry any of them are rejected
with `template_import_version_too_old` (esm-spec §9.6.5). Mirrors
`rejectExpressionTemplatesPreV04` for the §9.7 constructs.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-ts/src/template-imports.ts#L150)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
reject_template_imports_pre_v08(view: Any) -> None
```

Reject the §9.7 constructs in files declaring esm &lt; 0.8.0.

`expression_template_imports`, top-level `expression_templates`
(template-library files), and `metaparameters` arrive at `esm: 0.8.0`;
files declaring an earlier version that carry any of them are rejected with
`template_import_version_too_old` (esm-spec §9.6.5). Mirrors
[`reject_expression_templates_pre_v04`](/generated/api/ref/reject_expression_templates_pre_v04) for the §9.7 constructs.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/template_imports.py#L113)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn reject_template_imports_pre_v08(view: &Value) -> Result<(), ExpressionTemplateError>
```

`expression_template_imports`, top-level `expression_templates`
(template-library files), and `metaparameters` arrive at `esm: 0.8.0`;
files declaring an earlier version that carry any of them are rejected
with `template_import_version_too_old` (esm-spec §9.6.5). Mirrors
`reject_expression_templates_pre_v04` for the §9.7 constructs.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/template_imports.rs#L257) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.reject_template_imports_pre_v08.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func RejectTemplateImportsPreV08(view map[string]any) error
```

RejectTemplateImportsPreV08 rejects the §9.7 constructs in files declaring esm &lt; 0.8.0: `expression_template_imports`, top-level `expression_templates` (template-library files), and `metaparameters` arrive at esm 0.8.0; files declaring an earlier version that carry any of them are rejected with `template_import_version_too_old` (esm-spec §9.6.5). Mirrors RejectExpressionTemplatesPreV04 for the §9.7 constructs.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/template_version.go#L18) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#RejectTemplateImportsPreV08)

</div>

</div>
