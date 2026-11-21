---
title: "operator_compose_ambiguous_bare_name_error"
description: "Stable error · Flatten"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** error · **Topic:** [Flatten](/generated/api/topics/flatten)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `OperatorComposeAmbiguousBareNameError` | `OperatorComposeAmbiguousBareNameError` | `OperatorComposeAmbiguousBareNameError` | not exported | `OperatorComposeAmbiguousBareNameError` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct OperatorComposeAmbiguousBareNameError <: EarthSciASTError
OperatorComposeAmbiguousBareNameError(details::String)
OperatorComposeAmbiguousBareNameError(details)
```

```julia
OperatorComposeAmbiguousBareNameError
```

Raised when the bare-name fallback would unify two STATE variables and the
document has not said which spelling survives (esm-libraries-spec §4.7.1 step 3).

The fallback binds `A.x` to `B.x` on the strength of a shared local name alone.
When both are states, each carries its own INITIAL CONDITION, and the merge has
to delete one of them — so the choice decides which IC the flattened system
integrates from. Nothing in the document expresses that choice, and picking one
silently is how flipping the entry's `systems` order came to change the answer.

So it is refused. The author says what they mean with `translate`, which names
the surviving spelling outright, or with `require_match`.

A match where only ONE side is a state is NOT ambiguous: the other carries no
initial condition, so the state is the owner and the merge renames onto it.

Fields:
- `details::String`: the entry and the two spellings it tried to unify.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/flatten_errors.jl#L82)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
class OperatorComposeAmbiguousBareNameError extends FlattenError
new OperatorComposeAmbiguousBareNameError(message: string): OperatorComposeAmbiguousBareNameError
```

The bare-name fallback would unify two STATE variables and the document has
not said which spelling survives (esm-libraries-spec §4.7.1 step 3).

The fallback binds `A.x` to `B.x` on the strength of a shared local name alone.
When both are states, each carries its own INITIAL CONDITION, and the merge has
to delete one of them — so the choice decides which IC the flattened system
integrates from. Nothing in the document expresses that choice, and picking one
silently is how flipping the entry's `systems` order came to change the answer.

A match where only ONE side is a state is NOT ambiguous: the other carries no
initial condition, so the state is the owner and the merge renames onto it.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-ts/src/flatten.ts#L208)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class OperatorComposeAmbiguousBareNameError(FlattenError)
```

A bare-name match unified two STATES and the document did not say which survives.

esm-libraries-spec §4.7.1 step 3. The bare-name fallback binds `A.x` to
`B.x` on the strength of a shared local name alone. When both are state
variables, each carries its own INITIAL CONDITION, and the merge has to
delete one of them -- so the choice decides which IC the flattened system
integrates from. Nothing in the document expresses that choice, and picking
one silently is how flipping the entry's `systems` order came to change the
answer.

So it is refused. The author says what they mean with `translate`, which
names the surviving spelling outright, or with `require_match`.

A match where only ONE side is a state is NOT ambiguous: the other carries no
initial condition, so the state is the owner and the merge renames onto it.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/flatten.py#L134)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this error.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type OperatorComposeAmbiguousBareNameError struct {
	// A and B are the entry's two systems, Systems[0] and Systems[1].
	A, B string
	// BDep and TargetDep are the two spellings the fallback tried to unify.
	BDep, TargetDep string
	Message         string
}

func (e *OperatorComposeAmbiguousBareNameError) DiagnosticCode() string

func (e *OperatorComposeAmbiguousBareNameError) Error() string
```

OperatorComposeAmbiguousBareNameError reports that the bare-name fallback would unify two STATE variables and the document has not said which spelling survives (esm-libraries-spec §4.7.1 step 3).

The fallback binds `A.x` to `B.x` on the strength of a shared local name alone. When both are states, each carries its own INITIAL CONDITION, and the merge has to delete one of them — so the choice decides which IC the flattened system integrates from. Nothing in the document expresses that choice, and picking one silently is how flipping the entry's `systems` order came to change the answer.

A match where only ONE side is a state is NOT ambiguous: the other carries no initial condition, so the state is the owner and the merge renames onto it.

**Methods**

```go
func (e *OperatorComposeAmbiguousBareNameError) DiagnosticCode() string
```

DiagnosticCode returns the stable diagnostic code (DiagnosticError).

```go
func (e *OperatorComposeAmbiguousBareNameError) Error() string
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/flatten.go#L142) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#OperatorComposeAmbiguousBareNameError)

</div>

</div>
