---
title: "step"
description: "Stable function · Simulation"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Simulation](/generated/api/topics/simulation)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | outside profile | `step` | `step` | outside profile |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this function.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">Not available in TypeScript. TypeScript is outside the simulation capability profile (Julia, Python, Rust): build an RHS and integrate it; TypeScript and Go are deliberately non-simulating.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
step(integrator: Integrator) -> ReturnCode | None
```

Advance `integrator` one accepted step — the spec's `step!`.

Python has no `!` convention for a mutating function, so the bang is
dropped; the function mutates its argument exactly as the Julia twin does.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/problem.py#L2569)

**Example** (`integrator`)

```python
integ = earthsci_ast.init(prob)
earthsci_ast.step(integ)
assert 0.0 < integ.t < 10.0
assert integ["N"] < 100.0

rest = earthsci_ast.solve_all(integ)
assert rest.retcode == earthsci_ast.ReturnCode.Success
assert rest.t[-1] == 10.0
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/python/simulate.py#L45-L52">docs/api/examples/python/simulate.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn step(integrator: &mut Integrator<'_>) -> Result<StepStatus, SimulateError>
```

Advance `integrator` by one grid point (§2.5.6's `step!`).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/problem.rs#L4592) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.step.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Not available in Go. Go is outside the simulation capability profile (Julia, Python, Rust): build an RHS and integrate it; TypeScript and Go are deliberately non-simulating.</p>

</div>

</div>
