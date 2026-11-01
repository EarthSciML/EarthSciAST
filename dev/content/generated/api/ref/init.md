---
title: "init"
description: "Stable function · Simulation"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Simulation](/generated/api/topics/simulation)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | outside profile | `init` | `init` | outside profile |


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
init(prob: EsmProblem, *, alg: str = DEFAULT_ALG, abstol: float | None = None, reltol: float | None = None, callback: Any = None, maxiters: int | None = None) -> Integrator
```

Build a stepping [`Integrator`](/generated/api/ref/integrator) over `prob` (esm-libraries-spec §2.5.6).

`abstol` / `reltol` resolve on the esm-spec §2.2.2 chain, exactly as
[`solve`](/generated/api/ref/solve)'s do: `None` (the default) means "not given", so the
document's `solver.abstol` / `solver.reltol` are used, falling through
per field to the binding defaults (`abstol` 1e-6, `reltol` 1e-4). An
explicit argument here wins outright. The chain runs wherever a document is
integrated, so stepping honours the document as solving does.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/problem.py#L2546)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/python/simulate.py#L45-L52">docs/api/examples/python/simulate.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn init<'a>(prob: &'a EsmProblem, opts: &SolveOptions) -> Result<Integrator<'a>, SimulateError>
```

Build a stepping integrator for `prob` (§2.5.6).

The step grid is `opts.saveat` when the caller supplied one, else 100 evenly
spaced points across `tspan`.

The esm-spec §2.2.2 tolerance chain runs HERE, not only at `solve`: the
integrator this returns carries the document's `solver.abstol` / `reltol`
whenever the caller named none, so stepping a document honours its declared
numerics exactly as solving it does.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/problem.rs#L4634) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.init.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Not available in Go. Go is outside the simulation capability profile (Julia, Python, Rust): build an RHS and integrate it; TypeScript and Go are deliberately non-simulating.</p>

</div>

</div>
