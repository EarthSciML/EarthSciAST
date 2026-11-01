---
title: "dae_info"
description: "Stable type · Variable classification"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Variable classification](/generated/api/topics/classification)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | not exported | not exported | `DaeInfo` | `DAEInfo` |


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
pub struct DaeInfo {
    pub algebraic_equation_count: usize,
    pub per_model: HashMap<String, usize>,
    pub factored_equation_count: Option<usize>,
}
```

Summary of DAE classification stamped onto `metadata.dae_info` by
`discretize()` per RFC §12.

`algebraic_equation_count` is the post-`discretize()` total across all
models; `per_model` breaks it down by model name. `factored_equation_count`
is rust-binding-specific — it reports the number of trivially
substitutable algebraic equations the preprocessor eliminated before
classification (see `docs/rfcs/dae-binding-strategies.md`). `0` on
bindings that do not perform trivial factoring.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/types/document.rs#L378) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.DaeInfo.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type DAEInfo struct {
	// SystemClass is "ode" if ApplyDAEContract succeeded with no
	// residual algebraic equations, else "dae".
	SystemClass string
	// AlgebraicEquationCount is the number of algebraic equations
	// remaining after trivial factoring, summed across models.
	AlgebraicEquationCount int
	// TrivialFactoredCount is the number of algebraic equations
	// substituted out and removed during factoring.
	TrivialFactoredCount int
	// PerModel maps model name to residual algebraic equation count.
	PerModel map[string]int
	// PerModelFactored maps model name to equations factored out.
	PerModelFactored map[string]int
}
```

DAEInfo records the outcome of ApplyDAEContract on an ESMFile.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/dae.go#L36) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#DAEInfo)

</div>

</div>
