---
title: "solution"
description: "Stable type · Simulation"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Simulation](/generated/api/topics/simulation)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | outside profile | `Solution` | `Solution` | outside profile |


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
class Solution
Solution(t: np.ndarray, y: np.ndarray, vars: list[str], retcode: ReturnCode, message: str = '', nfev: int = 0, njev: int = 0, nlu: int = 0, events: list[np.ndarray] | None = None, merged_renames: dict[str, str] = dict())
Solution.__getitem__(key: str | int) -> np.ndarray
Solution.resolve_name(name: str) -> str
Solution.__contains__(name: object) -> bool
Solution.keys() -> list[str]
Solution.get(name: str, default: Any = None) -> Any
Solution.plot(variables: list[str] | None = None, **kwargs)
```

What [`earthsci_ast.problem.solve`](/generated/api/ref/solve) returns.

Indexed **by variable name** (esm-libraries-spec §2.5.7): `sol["Chem.O3"]`
is that variable's trajectory over `t`. The flattened state ordering
is an implementation detail coupling can change, so the positional
`y` / `vars` pair remains available but is not the documented
path.

`retcode` is the run's outcome. `message`, `nfev`,
`njev` and `nlu` are informative extras (§2.5.3 permits solver
statistics beside the code); `message` carries the solver's or the
failure's own prose and is a diagnostic, never the channel a caller decides
success on.

**Members**

- `__getitem__` — `sol[name]` — the named variable's trajectory; `sol[i]` — row i.
- `resolve_name` — `name`, or the survivor it was merged into (issue #230).
- `keys` — The variable names this solution is indexed by.
- `plot` — Plot simulation results using matplotlib.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/simulation_common.py#L93)

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

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct Solution {
    pub time: Vec<f64>,
    pub state: Vec<Vec<f64>>,
    pub state_variable_names: Vec<String>,
    pub retcode: ReturnCode,
    pub metadata: SolutionMetadata,
}

impl Solution { pub fn get(&self, name: &str) -> Option<&[f64]> }

impl Solution { pub fn index_of(&self, name: &str) -> Option<usize> }

impl Solution { pub fn variable(&self, name: &str) -> Result<&[f64], SimulateError> }

impl Solution { pub fn at(&self, name: &str, k: usize) -> Option<f64> }

impl Solution { pub fn final_value(&self, name: &str) -> Option<f64> }

impl Solution { pub fn variable_names(&self) -> &[String] }
```

A simulation result.

`state[i][k]` is the value of state variable `state_variable_names[i]` at
time `time[k]`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/simulate/api.rs#L360) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.Solution.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Not available in Go. Go is outside the simulation capability profile (Julia, Python, Rust): build an RHS and integrate it; TypeScript and Go are deliberately non-simulating.</p>

</div>

</div>
