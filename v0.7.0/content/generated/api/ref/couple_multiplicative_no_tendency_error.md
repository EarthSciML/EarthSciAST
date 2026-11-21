---
title: "couple_multiplicative_no_tendency_error"
description: "Stable error · Flatten"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** error · **Topic:** [Flatten](/generated/api/topics/flatten)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | `CoupleMultiplicativeNoTendencyError` | `CoupleMultiplicativeNoTendencyError` | not exported | `CoupleMultiplicativeNoTendencyError` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this error.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
class CoupleMultiplicativeNoTendencyError extends FlattenError
new CoupleMultiplicativeNoTendencyError(message: string): CoupleMultiplicativeNoTendencyError
```

A `couple` connector equation with `transform: "multiplicative"` targets
something with no tendency to multiply.

esm-spec §10.3 and esm-libraries-spec §4.7.2 define `multiplicative` against
the target's EXISTING ODE right-hand side. When `to` names a parameter, an
observed, an algebraic unknown, or an undefined name, there is no `D(to)` and
the operation has no meaning.

Silently dropping the connector equation — what this binding did before — is
the one outcome a coupling mis-specification must not have: the document
declares a coupling and the flattened system carries no trace of it.

`additive` has no counterpart error because zero is the additive identity, so
an additive term against an absent tendency simply becomes the tendency.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-ts/src/flatten.ts#L151)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class CoupleMultiplicativeNoTendencyError(FlattenError)
```

A `multiplicative` connector transform targets something with no tendency.

esm-spec §10.3 and esm-libraries-spec §4.7.2 define `multiplicative`
against the target's EXISTING ODE right-hand side. When `to` names a
parameter, an observed, an algebraic unknown, or an undefined name, there is
no `D(to)` to multiply and the operation has no meaning.

Silently dropping the connector equation -- what this binding did before --
is the one outcome a coupling mis-specification must not have: the document
declares a coupling and the flattened system carries no trace of it.

`additive` has no counterpart error because zero is the additive identity,
so an additive term against an absent tendency simply becomes the tendency.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/flatten.py#L81)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this error.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type CoupleMultiplicativeNoTendencyError struct {
	// Target is the connector equation's `to` scoped reference.
	Target  string
	Message string
}

func (e *CoupleMultiplicativeNoTendencyError) DiagnosticCode() string

func (e *CoupleMultiplicativeNoTendencyError) Error() string
```

CoupleMultiplicativeNoTendencyError reports that a `couple` connector equation applies the `multiplicative` transform to a target with no `D(to)` equation in the flattened system (esm-spec §10.3, esm-libraries-spec §4.7.2).

Both sections define `multiplicative` against the target's EXISTING ODE right-hand side. When `to` names a parameter, an observed, an algebraic unknown, or a name nothing defines, there is no tendency to multiply and the operation has no meaning — so the entry is rejected rather than dropped.

`additive` has no counterpart error: zero is the additive identity, so an additive term against an absent tendency simply becomes the tendency.

**Methods**

```go
func (e *CoupleMultiplicativeNoTendencyError) DiagnosticCode() string
```

DiagnosticCode returns the stable diagnostic code (DiagnosticError).

```go
func (e *CoupleMultiplicativeNoTendencyError) Error() string
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/flatten.go#L84) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CoupleMultiplicativeNoTendencyError)

</div>

</div>
