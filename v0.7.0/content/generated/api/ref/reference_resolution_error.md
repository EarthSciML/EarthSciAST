---
title: "reference_resolution_error"
description: "Stable error · Graphs"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** error · **Topic:** [Graphs](/generated/api/topics/graphs)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `ReferenceResolutionError` | `ReferenceResolutionError` | `ReferenceResolutionError` | `ReferenceError`, `ReferenceResolutionError` | `ReferenceResolutionError` |


**Note:** spelling differs from the §2 rule: rust=ReferenceError (expected ReferenceResolutionError); multiple spellings exported by: rust


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct ReferenceResolutionError <: EarthSciASTError
ReferenceResolutionError(code::String, message::String, cycle::Union{Nothing, Vector{String}})
ReferenceResolutionError(code, message, cycle)
ReferenceResolutionError(code::AbstractString, message::AbstractString)
```

```julia
ReferenceResolutionError(code, message[, cycle])
```

A reference could not be resolved, or the reference graph has a cycle. Carries a
stable `code` (one of the `E_REF_*` constants) so callers and the cross-binding
conformance suite can assert on the failure mode, and a human-readable
`message`. For a cycle, `cycle` holds the offending vertex-key path.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/reference_graph.jl#L56)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
class ReferenceResolutionError extends EsmDiagnosticError
new ReferenceResolutionError(code: string, message: string, cycle?: string[]): ReferenceResolutionError
readonly ReferenceResolutionError.prototype.cycle: string[] | undefined
```

A reference could not be resolved, or the reference graph has a cycle.

Carries the stable `code` (one of the `E_REF_*` constants above) so callers
and the cross-binding conformance suite can assert on the failure mode. For a
cycle, `cycle` holds the offending vertex-key path.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-ts/src/reference-resolution.ts#L60)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class ReferenceResolutionError(EarthSciAstError)
ReferenceResolutionError(code: str, message: str, cycle: list[str] | None = None)
```

A reference could not be resolved, or the reference graph has a cycle.

Carries a stable `code` (one of the `E_REF_*` constants) so callers and
the cross-binding conformance suite can assert on the failure mode, and a
human-readable `message`. For a cycle, `cycle` holds the offending path.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/reference_resolution.py#L68)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

Exported as `ReferenceError` and `ReferenceResolutionError`. Both names refer to the same operation.

**`ReferenceError`**

```rust
pub type ReferenceError = ReferenceResolutionError;
```

**Deprecated** since 0.2.0: renamed to `ReferenceResolutionError` (API_SPEC.md §8 item 10)

Deprecated alias of [`ReferenceResolutionError`](/generated/api/ref/reference_resolution_error).

API_SPEC.md §8 item 10: Julia, Python and Go all raise
`ReferenceResolutionError`; this binding alone spelled it `ReferenceError`.
The canonical spelling is now `ReferenceResolutionError`; this alias is kept
for one minor per API_SPEC.md §10 and will be removed at the next major.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/reference_resolution.rs#L58) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/type.ReferenceError.html)

**`ReferenceResolutionError`**

```rust
pub enum ReferenceResolutionError {
    UndeclaredIndexSet { name: String, index: String, node: String, model: String, path: String },
    UnknownFaqNode { index_set: String, from_faq: String, model: String },
    DuplicateNodeId { id: String, model: String, path: String, first: String },
    UnresolvedJoinFactor { factor: String, node: String, model: String, path: String },
    ReferenceCycle { path: Vec<String> },
}
```

A reference could not be resolved, or the reference graph has a cycle.

Variant names are deliberately cross-language-compatible so the Julia,
Python, and Rust bindings report the same failure mode under the same name
(mirrors the `E_REF_*` codes in the Python binding).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/reference_resolution.rs#L66) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.ReferenceResolutionError.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type ReferenceResolutionError struct {
	Code    string
	Message string
	Cycle   []string
}

func (e *ReferenceResolutionError) DiagnosticCode() string

func (e *ReferenceResolutionError) Error() string
```

ReferenceResolutionError reports that a reference could not be resolved, or that the reference graph has a cycle.

It carries a stable Code (one of the CodeRef\* constants) so callers and the cross-binding conformance suite can assert on the failure mode, and a human-readable Message. For a cycle, Cycle holds the offending vertex-key path. All five bindings call it `ReferenceResolutionError`.

**Methods**

```go
func (e *ReferenceResolutionError) DiagnosticCode() string
```

DiagnosticCode exposes the stable code, matching the convention of EvaluationError / ExpressionTemplateError elsewhere in this package.

```go
func (e *ReferenceResolutionError) Error() string
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/reference_graph.go#L73) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ReferenceResolutionError)

</div>

</div>
