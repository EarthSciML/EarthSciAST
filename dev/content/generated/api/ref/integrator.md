---
title: "integrator"
description: "Stable type · Simulation"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Simulation](/generated/api/topics/simulation)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | outside profile | `Integrator` | `Integrator` | outside profile |


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
class Integrator
Integrator(prob: EsmProblem, *, alg: str = DEFAULT_ALG, abstol: float | None = None, reltol: float | None = None, callback: Any = None, maxiters: int | None = None)
Integrator.t: float  # property
Integrator.u: np.ndarray  # property
Integrator.__getitem__(key: str | int) -> Any
Integrator.step() -> ReturnCode | None
Integrator.solve() -> Solution
Integrator.solution() -> Solution
Integrator.__iter__() -> Integrator
```

A stepping integrator over a [`EsmProblem`](/generated/api/ref/esm_problem-type) (esm-libraries-spec §2.5.6).

Build one with [`init`](/generated/api/ref/init), advance it with [`step`](/generated/api/ref/step) (or
`Integrator.step`), and run it out with [`solve_all`](/generated/api/extension/python#x-solve_all). This is the
same lifecycle [`solve`](/generated/api/ref/solve) performs internally, exposed for callers that
need to interleave their own work with the integration — a coupling driver
in a host model, an interactive session, a progress UI.

Python has no `!` convention, so the spec's `step!` / `solve!` are
spelled [`step`](/generated/api/ref/step) / [`solve_all`](/generated/api/extension/python#x-solve_all); both mutate the integrator, as
their Julia twins do. An Integrator is also iterable, yielding `(t, u)`
after each accepted step:

```python
for t, u in init(prob):
    ...
```

`u` is the current state vector; `__getitem__` indexes it BY NAME
(§2.5.7), as a [`Solution`](/generated/api/ref/solution) does.

`abstol` / `reltol` resolve on the esm-spec §2.2.2 chain — call site,
then the document's `solver` block, then the binding default — the same
chain [`solve`](/generated/api/ref/solve) runs, because it belongs to a document being integrated
rather than to one entry point. The resolved values are readable back as
`abstol` / `reltol`.

**Members**

- `t` — The current time.
- `u` — The current state vector.
- `__getitem__` — `integrator[name]` — the named variable's current value.
- `step` — Advance one accepted solver step.
- `solve` — Run to completion from wherever the integrator stands, and return the accumulated [`Solution`](/generated/api/ref/solution). This is the spec's `solve!`.
- `solution` — The trajectory accumulated so far, as a [`Solution`](/generated/api/ref/solution).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/problem.py#L2337)

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
pub struct Integrator<'a> {
    /* private fields */
}

impl Integrator<'_> { pub fn t(&self) -> f64 }

impl Integrator<'_> { pub fn retcode(&self) -> ReturnCode }

impl Integrator<'_> { pub fn u(&self) -> &HashMap<String, f64> }

impl Integrator<'_> { pub fn step(&mut self) -> Result<StepStatus, SimulateError> }

impl Integrator<'_> { pub fn solve_to_completion(&mut self) -> Result<Solution, SimulateError> }
```

A stepping integrator (§2.5.6) — the same lifecycle [`solve`](/generated/api/ref/solve) performs
internally, exposed for callers that need to interleave their own work with
the integration: the coupling driver in a host model, an interactive
session, a progress UI.

**What a "step" is here**

`Integrator::step` advances to the next entry of the **output grid**, not
to the next internal solver step. Each advance runs the configured
algorithm over `[t_now, t_next]` from the current state, exactly the way the
array runtime's segmented provider-refresh driver already advances across a
refresh boundary. That means the adaptive controller restarts at every
interleave point, so a run stepped in N pieces is not step-for-step
identical to the same run solved in one call — it is the same trajectory to
tolerance, at some extra cost per boundary. Choose the grid accordingly:
coarse when you only need to interleave, fine when you need control.

(`diffsol`'s solver borrows its `OdeSolverProblem`, so a EsmProblem-owning
integrator that also owns a live solver would be self-referential. Restarting
per grid interval is the safe-Rust way to expose the lifecycle, and it is
the mechanism already in production here for segmented refresh.)

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/problem.rs#L4588) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.Integrator.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Not available in Go. Go is outside the simulation capability profile (Julia, Python, Rust): build an RHS and integrate it; TypeScript and Go are deliberately non-simulating.</p>

</div>

</div>
