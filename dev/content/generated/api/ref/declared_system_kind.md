---
title: "declared_system_kind"
description: "Stable function · Variable classification"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Variable classification](/generated/api/topics/classification)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `declared_system_kind` | `declaredSystemKind` | `declared_system_kind` | `declared_system_kind` | `DeclaredSystemKind` |


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
absent. A declared `"pde"` (deprecated at esm 2.4.0 and ignored, with the
load-time warning `deprecated_system_kind`) counts as absent, so it is
`nothing` too. No derivation happens here: this is the raw field read, the question
`validate` asks when it needs to know whether the author committed to a kind at
all.

Contrast [`system_kind`](/generated/api/ref/system_kind-function), which ignores the field and derives the kind
from the equations and parameters, and [`effective_system_kind`](/generated/api/ref/effective_system_kind), which
composes the two.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/EarthSciAST.jl/src/classification.jl#L440)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function declaredSystemKind(model: Model): SystemKind | null
```

The model's explicit `system_kind` field, or `null` when absent. The
deprecated value `"pde"` (esm 2.4.0) counts as absent: the loader warns
`deprecated_system_kind` and the model is treated as its derived kind.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-ts/src/classification.ts#L332)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
declared_system_kind(model: Any) -> str | None
```

The model's explicit `system_kind` field, or None when absent. Compare
against [`system_kind`](/generated/api/ref/system_kind-function) to detect `system_kind_mismatch`.

The deprecated value `"pde"` counts as absent (esm 2.4.0): it returns
None, so it never reports a mismatch and never overrides the derivation.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-py/src/earthsci_ast/classification.py#L721)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn declared_system_kind(model: &Model) -> Option<&str>
```

The model's explicit `system_kind` field, or `None` when absent. Compare
it with [`system_kind`](/generated/api/ref/system_kind-function) to detect `system_kind_mismatch` (esm-spec §6.3.1).
A declared `"pde"` (deprecated at esm 2.4.0, warned
`deprecated_system_kind` at load) counts as absent: `None`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/classification.rs#L870) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.declared_system_kind.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func DeclaredSystemKind(model *Model) *string
```

DeclaredSystemKind returns the model's EXPLICIT `system_kind` field, or nil when the document declares none.

It is the third of the three distinct questions the §6.3.1 system-kind family answers, and the only one that can say "the document did not say" (API\_SPEC.md §8 item 11): SystemKind always derives an answer, and EffectiveSystemKind always produces one. Comparing this against SystemKind is what detects `system_kind_mismatch`.

A declared "pde" counts as ABSENT: the kind was dropped at esm 2.4.0, so the value is deprecated and ignored (a load warns `deprecated_system_kind`), and the model is treated as its derived kind.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-go/pkg/esm/classify.go#L205) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#DeclaredSystemKind)

</div>

</div>
