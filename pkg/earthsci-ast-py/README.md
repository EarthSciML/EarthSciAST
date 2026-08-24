# ESM Format - Python Package

A Python package for handling Earth System Model serialization and mathematical
expressions.

## Installation

```bash
pip install -e .
```

## Features

- Type definitions for mathematical expressions and equations
- Model variable and equation representations
- Chemical species and reaction system modeling
- Event system for continuous and discrete events
- Data loading and mathematical operators
- Coupling between model components
- Computational domain and solver specifications
- Comprehensive metadata support

## Usage

```python
from earthsci_ast import Expr, Model, Species, Reaction

# Create mathematical expressions
expr = ExprNode(op="+", args=[1, 2])

# Define model variables
var = ModelVariable(type="state", units="kg/m^3", description="Concentration")

# Build models
model = Model(name="MyModel")
```

## Simulation interface contract

The Python binding's simulation surface is one noun and one verb —
`esm_problem(input, tspan, ...)` builds, `solve(prob, ...)` runs
(esm-libraries-spec §2.5). There is no `simulate()`: it conflated the
per-document build with the per-run integration, and is deleted.

This is **not** a 0-D-only ODE solver. It is a runner for the post-discretize
canonical AST: spatial dimensions are folded into array dimensions, and the
only independent variable that remains at run time is `t`. Once a system has been discretized, the binding
evaluates `arrayop`-rich ASTs end-to-end (reshape / transpose / concat /
broadcast / index / elementwise stencils), so PDEs, 2-D and 3-D grids, and
mixed ODE/algebraic systems are all in scope.

### What `esm_problem()` accepts

`esm_problem(input, tspan, ...)` enforces a single rule on its input:

- `flat.independent_variables == ['t']`.

If any spatial independent variable is still present (`x`, `y`, `z`, or any
named axis other than `t`), `esm_problem()` raises
`UnsupportedDimensionalityError` (`problem.py` — the dimensionality guard).

This rejection is **not** a tier limit — it is an interface contract. The
contract is: if your system has a spatial axis, **discretize it first**.

### What "discretize" means here

Spatial discretization is expressed as **template expressions** —
`expression_templates` carrying `match` rewrite rules, applied via
`apply_expression_template`. A continuous-form ESM document — equations using
`grad`, `div`, `laplacian`, `flux_1d_ppm`, and the rest of the spatial-operator
vocabulary — carries the discretization templates (authored inline or imported
from a discretization template library such as the EarthSciDiscretizations
catalog) that rewrite those operators into the canonical post-discretize form:

- spatial operators are replaced with explicit stencils built from `arrayop`,
  `index`, and the elementwise op set;
- the spatial axis becomes an array dimension on each state variable;
- the only remaining independent variable is `t`.

As of schema v0.8.0 this is **not** a separate external pass: the binding runs
the template rewrite itself, at load time (the §9.6 rewrite fixpoint), and
Python, Julia, and Rust all do it identically. The discretized document is what
`esm_problem()` consumes. Inside the Python binding, the array-op path is
`_simulate_with_numpy` in `simulation_array.py` (delegates to the NumPy AST
interpreter in `numpy_interpreter.py`). It walks the AST per cell against a flat
state vector and integrates with SciPy's `solve_ivp`. The interpreter has been
exercised at scales up to ~10⁶ cells.

> The `discretize` function exported from `earthsci_ast` itself
> (`from earthsci_ast import discretize`) handles only the RFC §12 DAE
> binding contract — algebraic-equation factoring, not spatial discretization.
> Spatial discretization is a template-expression rewrite the binding applies
> at load, before you build a Problem.

### What you do not do

- You do **not** write the PDE form (with `grad` / `div` / `laplacian`)
  directly into a fixture and build a Problem from it. That fails the
  guard.
- You do **not** need a separate "PDE backend" — the same `esm_problem()` /
  `solve()` pair handles 0-D ODEs, mixed ODE/algebraic systems, and post-discretize
  PDEs of arbitrary dimensionality, because the post-discretize AST is
  uniform in shape regardless of the original spatial topology.

### Worked example: 1-D advection (post-discretize)

This example uses an already-discretized document (assume the discretization
templates have already been applied) and shows the shape `esm_problem()`
actually consumes. The model
is a 1-D diffusion stencil on a 10-cell grid where the spatial axis has
been folded into the array index of `u`:

```python
import json
from earthsci_ast import ReturnCode, esm_problem, solve
from earthsci_ast.parse import load

# Load a post-discretize PDE fixture. The 1-D spatial axis has been folded
# into the array dimension of u, so `independent_variables == ['t']`.
file = load("tests/fixtures/arrayop/03_1d_stencil_mass_conservation.esm")

# A delta spike at u[5]; everything else zero.
u0 = {f"u[{i}]": (1.0 if i == 5 else 0.0) for i in range(1, 11)}

prob = esm_problem(file, (0.0, 0.5), u0=u0)
sol = solve(prob, alg="RK45")

assert sol.retcode is ReturnCode.Success
# A solution is indexed BY NAME: sol["Diff1D.u[5]"] is that cell's trajectory.
# sol.vars still lists "Diff1D.u[1]" .. "Diff1D.u[10]" and sol.y is the
# positional block, shape (n_vars, n_times). Mass should be conserved to
# interior tolerance: sum_i u[i](t) ≈ sum_i u[i](0) = 1.0.
```

Inside the fixture, the interior stencil is an `arrayop` over `i in 2..9`
with body `u[i-1] - 2*u[i] + u[i+1]`, plus scalar boundary equations for
`u[1]` and `u[10]`. That is the canonical post-discretize shape: every
spatial term is an explicit `arrayop`, no `grad` / `div` / `laplacian`
nodes survive. The full pipeline for a user-authored continuous PDE is:

```
.esm (continuous form + discretization templates, with grad/div/laplacian)
  → load-time template rewrite (§9.6 fixpoint lowers spatial ops to arrayop stencils)
  → earthsci_ast.esm_problem() / solve()  (NumPy interpreter integrates with SciPy)
```

For more end-to-end discretized fixtures, see
`tests/fixtures/arrayop/` (1-D, 2-D, makearray, reshape, transpose,
concat, broadcast); `tests/test_arrayop_simulation.py` runs every
fixture's declared assertions through `esm_problem()` / `solve()` and is the
conformance contract for the array-op path.

### Vocabulary

`solve` takes the SciML spellings in every binding (API_SPEC §4), not SciPy's:
`alg` (not `method`), `abstol` (not `atol`), `reltol` (not `rtol`), `saveat`
(not `t_eval`). Defaults are `reltol=1e-10`, `abstol=1e-14`. A run reports
`sol.retcode`, a `ReturnCode` — `Success`, `MaxIters`, `Unstable`,
`Terminated`, `Failure` — never a boolean beside a sentence.

Other verbs on the same noun: `remake(prob, p=..., u0=..., tspan=...)` rebuilds
a Problem with substitutions and shares everything the substitution cannot have
invalidated; `callbacks(prob)` reads back the Problem's callback set (a
`callback` passed to `solve` REPLACES it, so this is how you extend it);
`init` / `step` / `solve_all` expose the stepping lifecycle; `EnsembleProblem`
sweeps a family; `observed_field(prob, name)` reads a build-time observed.

The solver is optional (esm-libraries-spec §2.5.9): `pip install
earthsci-ast[simulate]`. Building a Problem never needs SciPy — only `solve`,
`init`, `step` and `solve_all` do.

## Development

Install development dependencies:

```bash
pip install -e .[dev]
```

Run tests:

```bash
pytest
```
