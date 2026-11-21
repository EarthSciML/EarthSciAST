---
title: "apply_dae_contract"
description: "Stable function · Variable classification"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Variable classification](/generated/api/topics/classification)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | not exported | not exported | `apply_dae_contract` | `ApplyDAEContract` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this function.</p>

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
pub fn apply_dae_contract(esm: &mut EsmFile, dae_support: bool) -> Result<DaeInfo, DaeError>
```

Run the RFC §12 DAE binding contract on `esm` **in place** and
return the classification summary.

Behavior (rust strategy):

1. Classify every equation as `differential` (LHS is the STRUCTURAL time
   derivative — a `D` whose `wrt` is the literal `"t"` or absent, esm-spec
   §4.2) or `algebraic` (everything else — authored observed equations,
   explicit constraints, a SPATIAL `D`, etc). The axis is NOT resolved
   against `domain.independent_variable`; see `is_differential`.
2. If no algebraic equations exist, stamp
   `metadata.system_class = "ode"` and `metadata.dae_info` and return.
3. If `dae_support` is `false`, return `E_NO_DAE_SUPPORT` naming the
   first offending path.
4. Otherwise, run the trivial-factoring preprocessor: repeatedly
   pick any algebraic equation `lhs = Variable(v)` whose `rhs` does
   not reference `v`, substitute `v -> rhs` into every remaining
   equation (differential and algebraic), and drop the factored
   equation. Repeat until fixed point.
5. If algebraic equations remain (cyclic, implicit, or non-bare-LHS),
   return `E_NONTRIVIAL_DAE` naming every residual path.
6. Otherwise, stamp `metadata.system_class = "ode"`,
   `metadata.dae_info.algebraic_equation_count = 0`, and
   `metadata.dae_info.factored_equation_count = <count>`.

The input `esm` is mutated: factored algebraic equations are removed
and their substitutions applied to the remaining equations.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/dae.rs#L119) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.apply_dae_contract.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func ApplyDAEContract(file *ESMFile) (DAEInfo, error)
```

ApplyDAEContract applies the Go binding's trivial-DAE strategy to every applicable model in file (mutating each in place) and classifies the result.

Per docs/rfcs/dae-binding-strategies.md, when an ESM model contains algebraic equations alongside differential ones, ApplyDAEContract factors out equations of the form

```text
y ~ f(...)
```

where `y` is a plain variable that does not appear in `f` (acyclic). Such equations are symbolically substituted into every other equation (and into observed-variable expressions) and then removed from the model. The factoring runs to a fixed point so that chains like

```text
z ~ g(y); y ~ h(x); D(x) ~ F(y, z)
```

reduce to a pure ODE in `x`.

It returns a populated DAEInfo and, if any non-trivial algebraic equations remain after factoring, a \*RuleEngineError with code E\_NONTRIVIAL\_DAE whose message lists the residual equation paths and points the author at the Julia binding (full DAE via ModelingToolkit.jl) and RFC §12.

ApplyDAEContract does not run the RFC §11 discretization pipeline: it is intended to be composed with discretize() when that lands in Go, or called standalone by tools that need DAE factoring on an already discretized model. Models carrying an explicit non-ODE SystemKind ("nonlinear", "sde", "pde") are skipped — the DAE contract only applies to would-be ODE systems.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/dae.go#L80) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ApplyDAEContract)

</div>

</div>
