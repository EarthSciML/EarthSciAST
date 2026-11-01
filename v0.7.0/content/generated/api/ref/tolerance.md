---
title: "tolerance"
description: "Stable type · Document types"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Document types](/generated/api/topics/document-types)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | not exported | not exported | `Tolerance` | `Tolerance` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this type.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this type.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

<p class="api-absent">Python does not export this type.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct Tolerance {
    pub abs: Option<f64>,
    pub rel: Option<f64>,
}
```

Numerical comparison tolerance used by inline model tests.

Either or both of `abs` / `rel` may be set. An assertion passes when any
set bound is satisfied:
`|actual - expected| <= abs`  OR
`|actual - expected| <= rel * max(|actual|, |expected|)`.

The relative bound is SYMMETRIC in `actual` and `expected` — its scale is
the larger of the two magnitudes, not `|expected|` alone (Julia `isapprox`;
esm-spec §6.6.3). `inline_tests::check_assertion` carries the full
predicate, whose finiteness clause precedes the tolerance test.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/types/analysis.rs#L18) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.Tolerance.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type Tolerance struct {
	Abs *float64 `json:"abs,omitempty"`
	Rel *float64 `json:"rel,omitempty"`
}
```

Tolerance is a numerical comparison tolerance. Any of Abs/Rel may be set; an assertion passes when any set bound is satisfied:

```text
|actual - expected| <= Abs   OR   |actual - expected| <= Rel * max(|actual|, |expected|)
```

The relative bound is SYMMETRIC in actual and expected -- its scale is the larger of the two magnitudes, not |expected| alone (Julia isapprox; esm-spec 6.6.3). Finiteness is judged before tolerance: a non-finite actual fails against every finite expected. Go has no simulator, so this binding never evaluates the predicate; the contract is recorded here so a future runner does not have to re-derive it.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/types.go#L582) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#Tolerance)

</div>

</div>
