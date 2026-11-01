---
title: "operator_compose_require_match_error"
description: "Stable error · Flatten"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** error · **Topic:** [Flatten](/generated/api/topics/flatten)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `OperatorComposeRequireMatchError` | `OperatorComposeRequireMatchError` | `OperatorComposeRequireMatchError` | not exported | `OperatorComposeRequireMatchError` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct OperatorComposeRequireMatchError <: EarthSciASTError
OperatorComposeRequireMatchError(details::String)
OperatorComposeRequireMatchError(details)
```

```julia
OperatorComposeRequireMatchError
```

Raised when an `operator_compose` entry declares `require_match: true` and one of
`systems[2]`'s equations found no equation of `systems[1]` to land on
(esm-libraries-spec §4.7.1 step 5).

Step 5 otherwise preserves an unmatched equation unchanged, and a PARTIAL
shortfall is only a warning by default; `require_match` is the author's opt-in to
make it fatal. A PARTIAL match raises here — there is no "some is enough" reading
an author could rely on.

Fields:
- `details::String`: the entry, the merge tally, and the unmatched dependent
  variables.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/flatten_errors.jl#L60)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
class OperatorComposeRequireMatchError extends FlattenError
new OperatorComposeRequireMatchError(message: string): OperatorComposeRequireMatchError
```

An `operator_compose` entry declared `require_match: true` and one of
`systems[1]`'s equations found no equation of `systems[0]` to land on
(esm-libraries-spec §4.7.1 step 5).

Step 5 otherwise preserves an unmatched equation unchanged, and a PARTIAL
shortfall is only a warning by default; `require_match` is the author's opt-in
to make it fatal. A PARTIAL match throws here — there is no "some is enough"
reading an author could rely on.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/flatten.ts#L188)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class OperatorComposeRequireMatchError(FlattenError)
```

An `operator_compose` entry declared `require_match` and did not match.

esm-libraries-spec §4.7.1 step 5: `require_match: true` says the
`systems[1]` equations are CONTRIBUTIONS and every one of them must land on
an equation of `systems[0]`. Step 5 otherwise preserves an unmatched
equation unchanged, and a PARTIAL shortfall is only a warning by default;
this is the author's opt-in to make it fatal.

A PARTIAL match raises here. There is no "some is enough" reading an author
could rely on: the seven-of-twelve-species case is exactly the defect the
flag exists to catch.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/flatten.py#L117)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this error.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type OperatorComposeRequireMatchError struct {
	// A and B are the entry's two systems, Systems[0] and Systems[1].
	A, B string
	// Unmatched names the dependent variables that found no counterpart, in
	// document order.
	Unmatched []string
	Message   string
}

func (e *OperatorComposeRequireMatchError) DiagnosticCode() string

func (e *OperatorComposeRequireMatchError) Error() string
```

OperatorComposeRequireMatchError reports that an `operator_compose` entry declared `require_match: true` and one of Systems\[1\]'s equations found no equation of Systems\[0\] to land on (esm-libraries-spec §4.7.1 step 5).

Step 5 otherwise preserves an unmatched equation unchanged, and a PARTIAL shortfall is only a warning by default; `require_match` is the author's opt-in to make it fatal. A PARTIAL match fails here — there is no "some is enough" reading an author could rely on.

**Methods**

```go
func (e *OperatorComposeRequireMatchError) DiagnosticCode() string
```

DiagnosticCode returns the stable diagnostic code (DiagnosticError).

```go
func (e *OperatorComposeRequireMatchError) Error() string
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/flatten.go#L167) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#OperatorComposeRequireMatchError)

</div>

</div>
