---
title: "operator_compose_no_merge_error"
description: "Stable error · Flatten"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** error · **Topic:** [Flatten](/generated/api/topics/flatten)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `OperatorComposeNoMergeError` | `OperatorComposeNoMergeError` | `OperatorComposeNoMergeError` | not exported | `OperatorComposeNoMergeError` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct OperatorComposeNoMergeError <: EarthSciASTError
OperatorComposeNoMergeError(details::String)
OperatorComposeNoMergeError(details)
```

```julia
OperatorComposeNoMergeError
```

Raised when an `operator_compose` entry merges NOTHING (esm-libraries-spec §4.7.1
step 5).

An entry that matches nothing is indistinguishable from an entry that is not
there: the operator integrates a private, decoupled system from its own defaults,
the other system receives no contribution at all, and the only evidence is a
state count one too high. That is the one outcome a coupling mis-specification
must not have, so it is refused rather than reported.

An operator that genuinely contributes only states of its own — a transport
operator whose single equation defines its own wind field, say — says so with
`require_match: false`, and is then permitted.

Fields:
- `details::String`: the entry, the merge tally, and the unmatched dependent
  variables.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/flatten_errors.jl#L34)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
class OperatorComposeNoMergeError extends FlattenError
new OperatorComposeNoMergeError(message: string): OperatorComposeNoMergeError
```

An `operator_compose` entry merged NOTHING (esm-libraries-spec §4.7.1 step 5).

Such an entry is indistinguishable from one that is not there: the operator
integrates a private, decoupled system from its own defaults, the other system
receives no contribution at all, and the only evidence is a state count one too
high. That is the one outcome a coupling mis-specification must not have, so it
is refused rather than reported.

An operator that genuinely contributes only states of its own — a transport
operator whose single equation defines its own wind field, say — says so with
`require_match: false`, and is then permitted.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/flatten.ts#L171)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class OperatorComposeNoMergeError(FlattenError)
```

An `operator_compose` entry merged NOTHING (esm-libraries-spec §4.7.1 step 5).

An entry that matches nothing is indistinguishable from an entry that is not
there: the operator integrates a private, decoupled system from its own
defaults, the other system receives no contribution at all, and the only
evidence is a state count one too high. That is the one outcome a coupling
mis-specification must not have, so it is refused rather than reported.

An operator that genuinely contributes only states of its own -- a transport
operator whose single equation defines its own wind field, say -- says so
with `require_match: false`, and is then permitted.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/flatten.py#L100)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this error.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type OperatorComposeNoMergeError struct {
	// A and B are the entry's two systems, Systems[0] and Systems[1].
	A, B string
	// Unmatched names the dependent variables that found no counterpart, in
	// document order.
	Unmatched []string
	Message   string
}

func (e *OperatorComposeNoMergeError) DiagnosticCode() string

func (e *OperatorComposeNoMergeError) Error() string
```

OperatorComposeNoMergeError reports that an `operator_compose` entry merged NOTHING (esm-libraries-spec §4.7.1 step 5).

Such an entry is indistinguishable from one that is not there: the operator integrates a private, decoupled system from its own defaults, the other system receives no contribution at all, and the only evidence is a state count one too high. That is the one outcome a coupling mis-specification must not have, so it is refused rather than reported.

An operator that genuinely contributes only states of its own — a transport operator whose single equation defines its own wind field, say — says so with `require_match: false`, and is then permitted.

**Methods**

```go
func (e *OperatorComposeNoMergeError) DiagnosticCode() string
```

DiagnosticCode returns the stable diagnostic code (DiagnosticError).

```go
func (e *OperatorComposeNoMergeError) Error() string
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/flatten.go#L111) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#OperatorComposeNoMergeError)

</div>

</div>
