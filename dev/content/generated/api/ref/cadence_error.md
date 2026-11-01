---
title: "cadence_error"
description: "Stable error · Runtime I/O"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** error · **Topic:** [Runtime I/O](/generated/api/topics/runtime-io)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | outside profile | `CadenceError` | `CadenceError` | `CadenceError` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this error.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">Not available in TypeScript. TypeScript is outside the runtime I/O capability profile (Julia, Python, Rust): data-source providers, refresh cadence, output sinks, checkpoints.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class CadenceError(EarthSciAstError)
```

A cadence-partition contract violation in a model or producer output.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/cadence.py#L150)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub type CadenceError = MessageError;
```

A cadence-partition contract violation in a fixture or producer output (a
wrong `expect_cadence`, a `CONTINUOUS` relational node, a `from_faq` cycle, a
float topology key, or a malformed node).

Alias of the shared `crate::error::MessageError` newtype; the public name and
its bare-`{0}` `Display` output are unchanged.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/cadence.rs#L37) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/type.CadenceError.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type CadenceError struct {
	Code    string
	Message string
}

func (e *CadenceError) DiagnosticCode() string

func (e *CadenceError) Error() string
```

CadenceError is a cadence-partition contract violation: an observed-definition cycle (§5.7.2), a failed `expect_cadence` assertion (§5.7.6 guard 3), or a relational node on the hot path (guard 2).

**Methods**

```go
func (e *CadenceError) DiagnosticCode() string
```

DiagnosticCode returns the stable diagnostic code (DiagnosticError).

```go
func (e *CadenceError) Error() string
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/cadence.go#L84) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CadenceError)

</div>

</div>
