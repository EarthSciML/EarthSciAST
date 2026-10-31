---
title: "effective_system_kind"
description: "Stable function · Variable classification"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Variable classification](/generated/api/topics/classification)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `effective_system_kind` | `effectiveSystemKind` | `effective_system_kind` | not exported | `EffectiveSystemKind` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
effective_system_kind(model::Model)
```

```julia
effective_system_kind(model::Model) -> String
```

[`declared_system_kind`](/generated/api/ref/declared_system_kind) when the model declares one, otherwise the
derived [`system_kind`](/generated/api/ref/system_kind-function). This is the question a caller choosing a solver
actually asks — the declaration wins, because an author who wrote it down meant
it, and `validate` separately reports a `system_kind_mismatch` when the two
disagree (API_SPEC.md §8 item 11).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/classification.jl#L439)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function effectiveSystemKind(model: Model): SystemKind
```

The kind a caller choosing a solver actually asks for: the DECLARED
`system_kind` when the document states one, otherwise the DERIVED kind.

API_SPEC.md §8 item 11 rules the family as three distinct questions plus this
one composition — [`systemKind`](/generated/api/ref/system_kind-function) derives, [`declaredSystemKind`](/generated/api/ref/declared_system_kind)
reads the field, and this composes them as `declared ?? derived`. It never
returns `null`: an undeclared model still has a derived kind. Matches Go's
`EffectiveSystemKind`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-ts/src/classification.ts#L375)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
effective_system_kind(model: Any) -> str
```

The kind a caller choosing a solver should act on: the declared
`system_kind` field when the document states one, otherwise the §6.3.1
derivation.

This is the composition `declared ?? derived` of the other two members of
the family (API_SPEC.md §8 item 11) — the third of three distinct questions:

* [`system_kind`](/generated/api/ref/system_kind-function) — what the model's CONTENT implies (always answers);
* [`declared_system_kind`](/generated/api/ref/declared_system_kind) — what the document SAYS, or `None`;
* [`effective_system_kind`](/generated/api/ref/effective_system_kind) — what to actually DO (always answers).

It deliberately does not diagnose disagreement between the two: a declared
field that contradicts the derivation is reported as
`system_kind_mismatch` by [`validate`](/generated/api/ref/validate), and a
caller that has already validated its document wants one answer, not a
second copy of the check.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/classification.py#L554)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this function.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func EffectiveSystemKind(model *Model) string
```

EffectiveSystemKind is what a consumer choosing a solver should branch on: the DECLARED `system_kind` when the model carries one, and the SystemKind derivation otherwise (esm-spec §6.3.1, "a binding uses the derivation when the field is absent") — i.e. `declared ?? derived`. The two are checked against each other by the structural validator, which reports `system_kind_mismatch` when a present field contradicts the derivation — so by the time a document validates, the two agree.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/classify.go#L222) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#EffectiveSystemKind)

</div>

</div>
