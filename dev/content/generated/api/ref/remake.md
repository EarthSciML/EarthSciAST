---
title: "remake"
description: "Stable function · Simulation"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Simulation](/generated/api/topics/simulation)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | outside profile | `remake` | `remake` | outside profile |


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
remake(prob: EsmProblem, *, p: dict[str, float] | None = None, u0: dict[str, float] | None = None, tspan: tuple[float, float] | None = None) -> EsmProblem
```

A NEW EsmProblem with the named substitutions applied, everything else shared.

It never mutates `prob`, and it never redoes the parts of construction the
substitution cannot have invalidated: the flattened system is shared (so the
SymPy lambdify cache carries over), the materialized provider arrays are
shared (a changed parameter never re-fetches a provider), and the
loader-invariant build products — the value-invention join buffers and the
conservative-regrid geometry — are shared through the parent's static cache.

`tspan`-only substitution rebinds nothing at all: the compiled right-hand
side does not depend on the interval, so the new EsmProblem reuses it verbatim.

A substitution the EsmProblem cannot honour without a rebuild RAISES, naming
the parameter and the class that makes it un-substitutable, rather than
silently rebuilding or silently ignoring it.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/problem.py#L2192)

**Example** (`remake`)

```python
# A new parameter value reuses the same build.
faster = earthsci_ast.remake(prob, p={"lambda": 0.2})
sol2 = earthsci_ast.solve(faster, saveat=[10.0])
assert math.isclose(sol2["N"][-1], 100.0 * math.exp(-2.0), rel_tol=1e-3)
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/python/simulate.py#L37-L40">docs/api/examples/python/simulate.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn remake(prob: &EsmProblem, changes: &Remake) -> Result<EsmProblem, SimulateError>
```

A NEW EsmProblem with `changes` applied and everything else shared (§2.5.5).

Does not mutate `prob`, and does not redo the parts of construction the
substitution cannot have invalidated: the compiled right-hand side, the
build-time fields and the materialized provider data are shared by `Rc`, not
rebuilt. A changed parameter value does not re-fetch provider data or
recompile.

**Refusal is deliberate.** A substitution the EsmProblem cannot honour without
a rebuild raises `SimulateError::UnsubstitutableBinding`, naming the
binding and the class that makes it un-substitutable, rather than silently
rebuilding or silently ignoring it. Two classes refuse: a parameter that was
baked into the build (it is a load-time constant of the compiled RHS, not a
solver input), and a name that is not a parameter of the compiled system at
all.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/problem.rs#L1572) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.remake.html)

**Example** (`remake`)

```rust
// A new problem with a different parameter value; the compiled
// right-hand side is shared, not rebuilt.
let faster = remake(
    &prob,
    &Remake {
        p: HashMap::from([("lambda".to_string(), 0.2)]),
        ..Default::default()
    },
)?;
let sol = solve(&faster, &opts)?;
let n = sol.get("N").unwrap();
assert!((n[1] - 25.0).abs() < 1e-3, "N = {}", n[1]);
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/rust/simulate.rs#L37-L48">docs/api/examples/rust/simulate.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Not available in Go. Go is outside the simulation capability profile (Julia, Python, Rust): build an RHS and integrate it; TypeScript and Go are deliberately non-simulating.</p>

</div>

</div>
