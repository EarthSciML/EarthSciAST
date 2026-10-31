---
title: "canonicalize_error"
description: "Stable error · Document I/O"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** error · **Topic:** [Document I/O](/generated/api/topics/document-io)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `CanonicalizeError` | `CanonicalizeError` | not exported | `CanonicalizeError` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct CanonicalizeError <: EarthSciASTError
CanonicalizeError(code::String, message::String)
CanonicalizeError(code, message)
```

```julia
CanonicalizeError(code::String, message::String)
```

Error raised by [`canonicalize`](/generated/api/ref/canonicalize) / [`canonical_json`](/generated/api/ref/canonical_json). The `code`
field carries a stable error code:

- `E_CANONICAL_NONFINITE`, `E_CANONICAL_DIVBY_ZERO` — the RFC §5.4.6 / §5.4.7
  cross-language codes.
- `E_CANONICAL_UNSUPPORTED_FIELD` — Julia-local: the node carries an
  expression field outside the RFC-pinned emissible set (`op`/`args`/`wrt`/
  `dim`/`fn`/`name`/`value`), so no faithful canonical JSON exists (see
  [`canonical_json`](/generated/api/ref/canonical_json)).
- `E_CANONICAL_BAD_CONST` — Julia-local: a `const`-op `value` payload of an
  unsupported Julia type reached the canonical emitter (internal misuse, not
  an authoring error).
- `E_CANONICAL_BAD_NODE` — Julia-local: an `ASTExpr` subtype unknown to the
  canonical emitter reached `_emit_json` (defensively unreachable for the four
  concrete node types; internal misuse, not an authoring error).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/canonicalize.jl#L9)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
class CanonicalizeError extends EsmDiagnosticError
new CanonicalizeError(code: string, message?: string): CanonicalizeError
readonly CanonicalizeError.prototype.code: string
```

Canonical-form error carrying a stable RFC §5.4.6 / §5.4.7 `code` string
(`E_CANONICAL_NONFINITE`, `E_CANONICAL_DIVBY_ZERO`).

Defined here — the lowest module in the canonical-form stack — so that both
this module's serializer and `canonicalize.ts` can share ONE nonfinite error
type (`CanonicalNonfiniteError` extends it) without an import cycle.
`canonicalize.ts` re-exports this class under the same name, so consumers may
keep importing `CanonicalizeError` from either module.

**Members**

- `code` — Stable RFC §5.4.6 / §5.4.7 error code.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-ts/src/numeric-literal.ts#L348)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

<p class="api-absent">Python does not export this error.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub enum CanonicalizeError {
    NonFinite,
    DivByZero,
    UnsupportedField(String),
}
```

Errors raised during canonicalization (per RFC §5.4.6 / §5.4.7).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/canonicalize.rs#L13) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.CanonicalizeError.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this error.</p>

</div>

</div>
