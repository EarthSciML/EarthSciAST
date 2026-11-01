---
title: "declared_system_kind"
description: "Stable function · Variable classification"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Variable classification](/generated/api/topics/classification)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `declared_system_kind` | `declaredSystemKind` | `declared_system_kind` | not exported | `DeclaredSystemKind` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
declared_system_kind(model::Model)
```

```julia
declared_system_kind(model::Model) -> Union{String,Nothing}
```

The `system_kind` the model DECLARES, verbatim, or `nothing` when the field is
absent. No derivation happens here: this is the raw field read, the question
`validate` asks when it needs to know whether the author committed to a kind at
all.

Contrast [`system_kind`](/generated/api/ref/system_kind-function), which ignores the field and derives the kind
from the equations and parameters, and [`effective_system_kind`](/generated/api/ref/effective_system_kind), which
composes the two.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/classification.jl#L425)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function declaredSystemKind(model: Model): SystemKind | null
```

The model's explicit `system_kind` field, or `null` when absent.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/classification.ts#L361)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
declared_system_kind(model: Any) -> str | None
```

The model's explicit `system_kind` field, or None when absent. Compare
against [`system_kind`](/generated/api/ref/system_kind-function) to detect `system_kind_mismatch`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/classification.py#L547)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this function.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func DeclaredSystemKind(model *Model) *string
```

DeclaredSystemKind returns the model's EXPLICIT `system_kind` field, or nil when the document declares none.

It is the third of the three distinct questions the §6.3.1 system-kind family answers, and the only one that can say "the document did not say" (API\_SPEC.md §8 item 11): SystemKind always derives an answer, and EffectiveSystemKind always produces one. Comparing this against SystemKind is what detects `system_kind_mismatch`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/classify.go#L208) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#DeclaredSystemKind)

</div>

</div>
