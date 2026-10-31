---
title: "validate_equation_dimensions"
description: "Stable function · Units"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Units](/generated/api/topics/units)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `validate_equation_dimensions` | not exported | not exported | `validate_equation_dimensions` | `ValidateEquationDimensions` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
validate_equation_dimensions(eq::Equation, var_units::AbstractDict)
```

Validate that an equation is dimensionally consistent.

Checks that both sides are internally consistent and that the left-hand side and
right-hand side have the same dimensions. Returns `false` only for a PROVABLE
inconsistency; an equation whose dimensions cannot be determined is skipped
(counted consistent), because a validator must not fail what it cannot prove.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/units.jl#L2098)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this function.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

<p class="api-absent">Python does not export this function.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn validate_equation_dimensions(eq: &Equation, env: &HashMap<String, Unit>) -> Result<(), UnitError>
```

Validate that an equation's LHS and RHS have matching dimensions.

Returns `Ok(())` when both sides propagate to dimensionally-equal units,
and a [`UnitError`](/generated/api/extension/rust#x-uniterror) with a descriptive message otherwise. Propagation
errors from either side are surfaced verbatim.

This is the single-outcome view. Validation uses
[`check_equation_dimensions`](/generated/api/extension/rust#x-check_equation_dimensions), which reports EVERY finding and separates
provable mismatches from undeterminable dimensions.

A time derivative `D(x)/Dt` whose `t` declares no units has an
undeterminable left-hand side (esm-spec §4.8.4), so the full comparison is
skipped and the weaker rule applies: if no time unit can reconcile the two
sides, the result is `UnitError::DimensionMismatch`; if one can, it is
`UnitError::UnknownUnit` ("skipped"), not `Ok(())`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/units.rs#L2061) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.validate_equation_dimensions.html)

**Example** (`validate_equation_dimensions`)

```rust
let doc = load_path(fixture("decay.esm"))?;
let model = &doc.models.as_ref().unwrap()["Decay"];
let (env, failures) = build_unit_env(&model.variables);
assert!(failures.is_empty());

// half_life = log(2) / lambda: seconds on both sides.
validate_equation_dimensions(&model.equations[1], &env)?;
// half_life is in s but lambda is in 1/s.
let wrong = parse_equation("half_life = lambda")?;
let err = validate_equation_dimensions(&wrong, &env).unwrap_err();
println!("{err}");
assert!(err.to_string().contains("mismatch"));
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/rust/units.rs#L21-L32">docs/api/examples/rust/units.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func ValidateEquationDimensions(eq *Equation, env map[string]Unit, path string) *UnitWarning
```

ValidateEquationDimensions checks that the LHS and RHS of an equation have the same dimension. It returns a non-nil UnitWarning iff a concrete inconsistency was detected. Missing annotations are treated as "unknown" and do NOT produce a warning (matching the Python/Julia best-effort semantics).

The reported Path is the EQUATION pointer (`/models/<M>/equations/<i>`) for every finding, including one discovered inside the LHS or RHS. That is the pointer tests/invalid/expected\_errors.json pins and the one TypeScript emits; the previous `/lhs` and `/rhs` suffixes pointed at no schema node and did not match the corpus.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/units.go#L2631) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ValidateEquationDimensions)

</div>

</div>
