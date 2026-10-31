---
title: "return_code"
description: "Stable type · Simulation"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Simulation](/generated/api/topics/simulation)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | outside profile | `ReturnCode` | `ReturnCode` | outside profile |


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
class ReturnCode(str, Enum)
ReturnCode.Success = 'Success'
ReturnCode.MaxIters = 'MaxIters'
ReturnCode.Unstable = 'Unstable'
ReturnCode.Terminated = 'Terminated'
ReturnCode.Failure = 'Failure'
```

The SciML `ReturnCode` vocabulary (API_SPEC §4, esm-libraries-spec
§2.5.3), which is how a run reports its outcome in every simulating
binding.

A caller distinguishes "ran to `tspan[1]`" from
"stopped early, here is why" by comparing `retcode`, never by reading
prose.

* `Success` — the integration reached the end of `tspan`.
* `MaxIters` — the `maxiters` budget on right-hand-side evaluations ran
  out first.
* `Unstable` — the trajectory left the domain the model can evaluate
  (a non-finite derivative or state).
* `Terminated` — a continuous event stopped the run early.
* `Failure` — the solver, the build, or the model reported an error.

Subclassing `str` keeps a code printable and JSON-serializable
(`str(ReturnCode.Success) == "ReturnCode.Success"`, `.value == "Success"`) without making it a bare string at comparison sites.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/simulation_common.py#L64)

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
pub enum ReturnCode {
    Success,
    MaxIters,
    Unstable,
    Terminated,
    Failure,
}

impl ReturnCode { pub fn is_success(self) -> bool }

impl ReturnCode { pub fn name(self) -> &'static str }
```

Why a solve stopped — the SciML `ReturnCode` vocabulary
(`esm-libraries-spec.md` §2.5.3).

This REPLACES reading [`SolutionMetadata`](/generated/api/extension/rust#x-solutionmetadata)'s step and evaluation counters as
a proxy for whether a run finished. The counters remain, as informative
statistics; the answer to "did it reach `tspan.1`" is this enum and nothing
else, and a caller never has to parse an error message to get it.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/simulate/api.rs#L15) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.ReturnCode.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Not available in Go. Go is outside the simulation capability profile (Julia, Python, Rust): build an RHS and integrate it; TypeScript and Go are deliberately non-simulating.</p>

</div>

</div>
