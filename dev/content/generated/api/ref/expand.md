---
title: "expand"
description: "Stable function · Expressions"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Expressions](/generated/api/topics/expressions)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | not exported | `Expand` | not exported | `Expand` |


**Note:** spelling differs from the §2 rule: python=Expand (expected expand)


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this function.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this function.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
Expand(loaded: Any) -> Any
```

Public alias for [`expand_document`](/generated/api/ref/expand_document) using the spec's spelling
(esm-spec §9.6.4 rule 2). `Expand ∘ load` reproduces the Option-A form.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/lower_expression_templates.py#L1449)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this function.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func Expand(view map[string]any) map[string]any
```

Expand fully expands every surviving `apply_expression_template` reference in a loaded document by pure substitution to the acyclic fixpoint (esm-spec §9.6.4 rule 2), producing the Option-A image. Deterministic (the DAG is acyclic and substitution confluent) and NON-DESTRUCTIVE — `view` is deep copied first. Public alias mirroring the Julia `Expand`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/out_of_line_templates.go#L532) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#Expand)

</div>

</div>
