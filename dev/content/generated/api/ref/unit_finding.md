---
title: "unit_finding"
description: "Stable type · Units"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Units](/generated/api/topics/units)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `UnitFinding` | not exported | `UnitFinding` | `UnitFinding` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct UnitFinding
UnitFinding(subpath::String, message::String, code::String)
UnitFinding(subpath, message, code)
```

```julia
UnitFinding
```

A units finding: `subpath` RELATIVE to the owning model's JSON pointer (e.g.
`"equations/0"`, `"variables/invalid_sum"`), a human-readable `message`, and the
esm-spec §4.8.4 severity `code`.

Both codes are HARD ERRORS — the type exists to distinguish *why* the file is
wrong, not to distinguish an error from a warning. An UNDETERMINABLE dimension
is never a finding at all: it is reported by returning `nothing` from the
engine, and the enclosing check is skipped.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/units.jl#L2114)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this type.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class UnitFinding
UnitFinding(code: str, message: str, lhs_units: str = '', rhs_units: str = '')
```

One coded dimensional-analysis finding.

Carries the `code` decided at the raise site alongside the prose, so
[`validate`](/generated/api/ref/validate) can build a
[`UnitWarning`](/generated/api/ref/unit_warning) without parsing the message.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/units.py#L1120)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct UnitFinding {
    pub severity: UnitSeverity,
    pub message: String,
}

impl UnitFinding { pub fn is_error(&self) -> bool }

impl UnitFinding { pub fn code(&self) -> &'static str }
```

A single dimensional finding produced while propagating an expression.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/units.rs#L498) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.UnitFinding.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this type.</p>

</div>

</div>
