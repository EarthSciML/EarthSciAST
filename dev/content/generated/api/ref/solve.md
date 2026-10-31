---
title: "solve"
description: "Stable function · Simulation"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Simulation](/generated/api/topics/simulation)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | outside profile | `solve` | `solve` | outside profile |


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
solve(prob: EsmProblem | EnsembleProblem, *, alg: str = DEFAULT_ALG, abstol: float | None = None, reltol: float | None = None, saveat: Any = None, callback: Any = None, maxiters: int | None = None, trajectories: int | None = None) -> Solution | list[Solution]
```

Run `prob` to completion and return its [`Solution`](/generated/api/ref/solution).

The vocabulary is SciML's, not SciPy's (API_SPEC §4): `alg` (not
`method`), `abstol` (not `atol`), `reltol` (not `rtol`), `saveat`
(not `t_eval`). The defaults — `reltol=1e-4`, `abstol=1e-6` — are the
canonical cross-binding ones, so Julia, Python and Rust solving the same
document with default options produce comparable trajectories. Pass an
explicit tolerance when accuracy matters.

**Parameters**

- `prob` (`EsmProblem | EnsembleProblem`) — The [`EsmProblem`](/generated/api/ref/esm_problem-type) to run, or an [`EnsembleProblem`](/generated/api/ref/ensemble_problem) (in which
  case `trajectories` is required and a `list` of solutions comes
  back).
- `alg` (`str`) — The solver algorithm. This binding's ecosystem has no first-class
  algorithm object, so a SciPy method name is accepted (§2.5.3).
- `abstol`, `reltol` — Absolute and relative INTEGRATION tolerances. `None` (the default)
  means "not given" and resolves per esm-spec §2.2.2, most-specific
  first: an explicit argument here, then the document's
  `solver.abstol` / `solver.reltol` (§2.2), then the binding default
  (`abstol` 1e-6, `reltol` 1e-4). The two resolve independently, so a
  document declaring only `reltol` leaves `abstol` on the default.

  These are a different quantity from the `tolerance` object an
  assertion is COMPARED at (§6.6.4), which resolves on its own chain.
- `saveat` (`Any`) — Output times: an explicit sequence, or a scalar output STEP measured
  from `tspan[0]`. `None` keeps the dense uniform default grid.
- `callback` (`Any`) — REPLACES the EsmProblem's callback set entirely — it does not append or
  merge (§2.5.4). To extend it, compose explicitly with
  `callbacks(prob) + extra`.
- `maxiters` (`int | None`) — Budget of right-hand-side evaluations. When spent, the run stops and
  reports `ReturnCode.MaxIters`. `None` (the default) is
  unbudgeted.

**Returns**

- `Solution` — Indexed by variable NAME, carrying a
  [`ReturnCode`](/generated/api/ref/return_code). A failure that the
  solver or the model reports comes back as a non-`Success` code, not an
  exception, so interactive workflows can branch on it; a dimensionality
  violation still raises.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/problem.py#L1949)

**Example** (`simulate`)

```python
doc = earthsci_ast.load_path(FIXTURES / "decay.esm")
prob = earthsci_ast.esm_problem(doc, (0.0, 10.0))

half_life = math.log(2) / 0.1
sol = earthsci_ast.solve(prob, saveat=[0.0, half_life, 10.0])
assert sol.retcode == earthsci_ast.ReturnCode.Success

# A solution is indexed by variable name.
n = sol["N"]
print("N at t = 0, ln 2 / λ, 10:", n)
assert math.isclose(n[1], 50.0, rel_tol=1e-3)
assert math.isclose(n[-1], 100.0 * math.exp(-1.0), rel_tol=1e-3)

# Observed variables are read the same way.
assert math.isclose(sol["half_life"][-1], half_life, rel_tol=1e-9)
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/python/simulate.py#L12-L26">docs/api/examples/python/simulate.py</a></p>

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/python/simulate.py#L57-L64">docs/api/examples/python/simulate.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn solve(prob: &EsmProblem, opts: &SolveOptions) -> Result<Solution, SimulateError>
```

Run `prob` to completion (§2.5.3).

`opts` carries only per-run knobs: `alg`, `abstol`, `reltol`, `saveat`,
`callback`, `maxiters`. The result carries a
[`retcode`](/generated/api/ref/return_code) — a caller distinguishes "ran to `tspan.1`"
from "stopped early, here is why" without parsing prose.

**`opts.callback` REPLACES the EsmProblem's callback set entirely.** It does
not append, merge or wrap. To extend rather than replace, read the set back
with [`callbacks`](/generated/api/ref/callbacks) and [`compose`](/generated/api/ref/compose) explicitly. See §2.5.4 for why
replacement is the safe default.

**`opts.output_observed` adds rows.** A [`Solution`](/generated/api/ref/solution) carries state rows by
default; a name listed there is appended as extra rows in the flat cell-key
spelling the state uses, which is what [`crate::derive_output_plan`](/generated/api/ref/derive_output_plan) needs
to write that field alongside the state (RFC decision 8).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/problem.rs#L4110) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.solve.html)

**Example** (`simulate`)

```rust
let path = fixture("decay.esm");
let prob = esm_problem(path.as_path(), (0.0, 10.0), ProblemOptions::default())?;

// Sample the solution at t = ln 2 / λ, one half-life in.
let lambda = 0.1_f64;
let t_half = 2.0_f64.ln() / lambda;
let opts = SolveOptions {
    saveat: Some(vec![0.0, t_half]),
    ..Default::default()
};
let sol = solve(&prob, &opts)?;
assert_eq!(sol.retcode, ReturnCode::Success);

// States are read by name; a bare name resolves when it is unique.
let n = sol.get("N").expect("N is a state");
assert!((n[0] - 100.0).abs() < 1e-9);
assert!((n[1] - 50.0).abs() < 1e-3, "N(ln 2 / λ) = {}", n[1]);

// half_life is an observed: computed from the solution, not stored in it.
let half_life = observed_trajectory(&prob, &sol, "half_life")?;
assert!(half_life.iter().all(|h| (h - t_half).abs() < 1e-9));
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/rust/simulate.rs#L13-L33">docs/api/examples/rust/simulate.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Not available in Go. Go is outside the simulation capability profile (Julia, Python, Rust): build an RHS and integrate it; TypeScript and Go are deliberately non-simulating.</p>

</div>

</div>
