---
title: "float_key_error"
description: "Stable error · Relational keys and geometry"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** error · **Topic:** [Relational keys and geometry](/generated/api/topics/relational)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | not exported | `FloatKeyError` | `FloatKeyError` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this error.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this error.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class FloatKeyError(EarthSciAstError)
```

Raised when a relational key contains a floating-point component.

Violates `CONFORMANCE_SPEC.md` §5.5.1 rule 1 ("floats are forbidden in
keys"). Normalise the value to an integer / categorical ID before the
build-time relational pre-pass.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/relational.py#L102)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct FloatKeyError(pub String);
```

Raised when a relational key contains a floating-point (or otherwise
non-integer / out-of-domain) component, violating `CONFORMANCE_SPEC.md`
§5.5.1 rule 1 ("floats are forbidden in keys"). Normalise the value to an
integer / categorical ID before the build-time pre-pass.

In Rust rule 1 is enforced *by construction* — [`Key`](/generated/api/extension/rust#x-key) simply has no float
variant — so this error only arises at the untyped JSON boundary
(`Key::try_from_json`), the analogue of the Julia/Python reference's
per-primitive `assert_key` runtime check.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/relational.rs#L85) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.FloatKeyError.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this error.</p>

</div>

</div>
