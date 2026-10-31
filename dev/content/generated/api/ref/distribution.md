---
title: "distribution"
description: "Stable type · Document types"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Document types](/generated/api/topics/document-types)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `Distribution` | not exported | `Distribution` | `Distribution` | `Distribution` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct Distribution
Distribution(kind::AbstractString; location, scale, cov, low, high)
```

```julia
Distribution
```

A parameter's value drawn from a probability distribution rather than fixed
(esm-spec §6.3, schema `Distribution`). The closed set is `normal`,
`lognormal`, and `uniform`.

The three kinds spell their parameters differently on the wire, so the struct
stores them by ROLE and the wire names are restored on emit:

| `kind` | `location` | `scale` | other |
|---|---|---|---|
| `normal` | `mean` | `std` | `cov` |
| `lognormal` | `mu` | `sigma` | `cov` |
| `uniform` | — | — | `low`, `high` |

A distribution is *univariate* when its location parameter is a number and
*multivariate* when it is an array, in which case `cov` gives the full
covariance matrix and the parameter's `shape` must agree. WHEN the value is
drawn is decided by the parameter's [`ParameterUpdate`](/generated/api/ref/parameter_update): with no update
it is sampled once at setup (`sampled_parameters`); with `kind: "wiener"` it is
resampled every step with √dt scaling (`brownian_parameters`).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/types.jl#L871)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this type.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class Distribution
Distribution(kind: Literal['normal', 'lognormal', 'uniform'], mean: float | list[float] | None = None, std: float | list[float] | None = None, mu: float | list[float] | None = None, sigma: float | list[float] | None = None, low: float | list[float] | None = None, high: float | list[float] | None = None, cov: list[list[float]] | None = None)
```

A parameter's value drawn from a probability distribution (esm-spec
§5.4 / §6.3). The closed set is `normal` / `lognormal` / `uniform`;
a binding implements exactly these and rejects anything else.

Univariate when the location parameter (`mean` / `mu` / `low`) is a
number, multivariate when it is an array — in which case the parameter's
`shape` must agree and `cov` gives the full covariance matrix. The
location/spread slots are spelled per kind (`mean`/`std` for normal,
`mu`/`sigma` for lognormal, `low`/`high` for uniform) and only the
slots belonging to `kind` are ever populated or emitted.

WHEN the value is drawn is decided by the parameter's `update`, and that
is the whole difference between the two uses: with NO update it is sampled
once at setup (the uncertainty-quantification / ensemble case); with
`update.kind == "wiener"` it is resampled every step with sqrt(dt) scaling
(the stochastic-process case that makes the model an SDE).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/esm_types.py#L324)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub enum Distribution {
    Normal { mean: DistributionParam, std: Option<DistributionParam>, cov: Option<CovarianceMatrix> },
    Lognormal { mu: DistributionParam, sigma: Option<DistributionParam>, cov: Option<CovarianceMatrix> },
    Uniform { low: DistributionParam, high: DistributionParam },
}

impl Distribution { pub fn kind(&self) -> &'static str }

impl Distribution { pub fn location(&self) -> &DistributionParam }

impl Distribution { pub fn is_multivariate(&self) -> bool }

impl Distribution { pub fn cov(&self) -> Option<&CovarianceMatrix> }
```

A parameter's value drawn from a probability distribution rather than fixed
(esm-spec §6.3, schema `Distribution`). The closed set is `normal`,
`lognormal`, `uniform` — bindings implement exactly these and reject
anything else.

Univariate when the location parameter is a number, multivariate when it is
an array — in which case `cov` gives the full covariance matrix and the
parameter's `shape` must agree.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/types/model.rs#L620) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.Distribution.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type Distribution struct {
	Kind string `json:"kind"`
	// normal
	Mean any `json:"mean,omitempty"`
	Std  any `json:"std,omitempty"`
	// lognormal
	Mu    any `json:"mu,omitempty"`
	Sigma any `json:"sigma,omitempty"`
	// uniform
	Low  any `json:"low,omitempty"`
	High any `json:"high,omitempty"`
	// Cov is the symmetric positive-semidefinite covariance matrix (row-major)
	// of a multivariate `normal` / `lognormal`. Mutually exclusive with
	// Std / Sigma.
	Cov [][]float64 `json:"cov,omitempty"`
}
```

Distribution is a parameter's value drawn from a closed set of probability distributions (esm-spec 6.3): `normal` (Mean + Std|Cov), `lognormal` (Mu + Sigma|Cov), or `uniform` (Low + High). A distribution is univariate when its location parameter is a number and multivariate when it is an array, in which case the parameter's `shape` must agree and Cov gives the full covariance matrix -- which is how 1.0.0 spells correlated noise, replacing the 0.x `correlation_group` tag that never carried a matrix.

The scalar-or-vector fields are `any` (float64 or \[\]any) because the schema admits both spellings at every one of them.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/types.go#L361) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#Distribution)

</div>

</div>
