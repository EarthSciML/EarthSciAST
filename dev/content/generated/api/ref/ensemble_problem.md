---
title: "ensemble_problem"
description: "Stable type · Simulation"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Simulation](/generated/api/topics/simulation)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | outside profile | `EnsembleProblem` | `EnsembleProblem` | outside profile |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this type.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">Not available in TypeScript. TypeScript is outside the simulation capability profile (Julia, Python, Rust): build an RHS and integrate it; TypeScript and Go are deliberately non-simulating.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class EnsembleProblem
EnsembleProblem(prob: EsmProblem, rewrite: Callable[[EsmProblem, int], EsmProblem | None] | None = None)
EnsembleProblem.problem_for(i: int) -> EsmProblem
EnsembleProblem.solve(trajectories: int | None = None, **kwargs: Any) -> list[Solution]
```

A [`EsmProblem`](/generated/api/ref/esm_problem-type) plus a per-trajectory rewrite (esm-libraries-spec §2.5.8).

This is the canonical form for a parameter sweep, Monte Carlo over declared
distributions, and perturbed initial conditions:

```python
ens = EnsembleProblem(prob, lambda p, i: remake(p, p={"k1": ks[i]}))
sols = solve(ens, trajectories=len(ks))
```

`rewrite(prob, i)` returns the EsmProblem for trajectory `i` (0-based) —
ordinarily via [`remake`](/generated/api/ref/remake), so the family shares one build. A rewrite
that returns `None` runs the base EsmProblem unchanged.

**Members**

- `problem_for` — The EsmProblem for trajectory `i`.
- `solve` — Solve the family, returning one [`Solution`](/generated/api/ref/solution) per trajectory.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/problem.py#L2592)

**Example** (`ensemble_problem`)

```python
rates = [0.1, 0.2, 0.3]
ensemble = earthsci_ast.EnsembleProblem(
    prob, lambda p, i: earthsci_ast.remake(p, p={"lambda": rates[i]})
)
runs = earthsci_ast.solve(ensemble, trajectories=len(rates), saveat=[10.0])
finals = [run["N"][-1] for run in runs]
for rate, final in zip(rates, finals):
    assert math.isclose(final, 100.0 * math.exp(-rate * 10.0), rel_tol=1e-3)
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/python/simulate.py#L57-L64">docs/api/examples/python/simulate.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct EnsembleProblem<'a> {
    /* private fields */
}

impl<'a> EnsembleProblem<'a> { pub fn new(prob: &'a EsmProblem, trajectories: usize, rewrite: impl Fn(&EsmProblem, usize) -> Result<Remake, SimulateError> + 'a) -> Self }

impl<'a> EnsembleProblem<'a> { pub fn problem(&self) -> &EsmProblem }

impl<'a> EnsembleProblem<'a> { pub fn trajectories(&self) -> usize }

impl<'a> EnsembleProblem<'a> { pub fn trajectory(&self, i: usize) -> Result<EsmProblem, SimulateError> }
```

A EsmProblem plus a per-trajectory rewrite, and the family it stands for
(§2.5.8) — the canonical form for parameter sweeps, Monte Carlo over
declared distributions, and perturbed initial conditions.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/problem.rs#L1667) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.EnsembleProblem.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Not available in Go. Go is outside the simulation capability profile (Julia, Python, Rust): build an RHS and integrate it; TypeScript and Go are deliberately non-simulating.</p>

</div>

</div>
