# Getting Started with ESM Format in Python

The Python implementation provides scientific computing integration with NumPy,
SciPy, SymPy, and matplotlib, making it suitable for data analysis,
visualization, and numerical modeling workflows.

## Installation

### From PyPI
```bash
pip install earthsci-ast
```

### Development Installation
```bash
git clone https://github.com/EarthSciML/EarthSciAST.git
cd EarthSciAST/pkg/earthsci-ast-py
pip install -e .
```

### With Optional Dependencies

The base install is the **format** library — parse, validate, serialize,
display, canonicalize, graph, edit, flatten — and pulls in no netCDF or solver
stack. The heavier tiers are opt-in:

```bash
# Gridded / static data readers (xarray + netcdf4)
pip install "earthsci-ast[data]"

# ODE solver behind `solve` (scipy)
pip install "earthsci-ast[simulate]"

# Solution.plot (matplotlib)
pip install "earthsci-ast[plot]"

# Spherical / geodesic clipping (spherely)
pip install "earthsci-ast[geometry]"
```

## Core Capabilities

- ✅ Parse, serialize, validate ESM files
- ✅ Mathematical expression manipulation
- ✅ Unit checking and dimensional analysis
- ✅ SymPy integration for symbolic computation
- ✅ Simulation of ODE and post-discretize PDE systems (NumPy + SciPy)
- ✅ Matplotlib visualization
- ✅ Jupyter notebook integration

## Basic Usage

### Loading and Validating ESM Files

```python
from earthsci_ast import load_path, load_string, write_path, validate

# From a file
esm_file = load_path("model.esm")

# From a JSON string
esm_file = load_string(json_string)

# Inspect the document
print(f"Models: {list(esm_file.models)}")
model = esm_file.models["ExponentialDecay"]
print(f"Variables: {list(model.variables)}")
print(f"Equations: {len(model.equations)}")

# Validate
result = validate(esm_file)
if result.is_valid:
    print("Valid")
else:
    for err in result.schema_errors + result.structural_errors:
        print(f"error: {err}")

# Unit findings are warnings, not errors — they never make a file invalid
for w in result.unit_warnings:
    print(f"units: {w.message}")

# Write back out
write_path(esm_file, "output.esm")
```

`load_path` also accepts `metaparameters=` (to close a metaparameterized
document) and `base_path=` (to resolve `$ref` targets from another directory).

### Working with Expressions

Expressions are built from `ExprNode`, whose `args` are nested `ExprNode`s,
variable-name strings, or numbers:

```python
from earthsci_ast import (
    ExprNode, to_unicode, to_latex, to_ascii,
    free_variables, contains, simplify, substitute,
)

expr = ExprNode(op="*", args=["k", "A", "B"])

print(to_unicode(expr))              # k·A·B
print(to_latex(expr))                # k \cdot A \cdot B
print(sorted(free_variables(expr)))  # ['A', 'B', 'k']
print(contains(expr, "A"))           # True

# Substitution takes name -> expression
bound = substitute(expr, {"k": 2})
print(to_unicode(bound))             # 2·A·B

print(to_unicode(simplify(ExprNode(op="+", args=["x", 0]))))
```

To parse infix source text, use `parse_expression`. It returns the raw
dictionary form of the node, which the renderers accept directly; wrap it in
`ExprNode(**…)` before passing it to the analysis helpers:

```python
from earthsci_ast import parse_expression, ExprNode, free_variables, to_unicode

raw = parse_expression("k * A * B")     # {'op': '*', 'args': ['k', 'A', 'B']}
print(to_unicode(raw))                  # k·A·B

expr = ExprNode(**raw)
print(sorted(free_variables(expr)))     # ['A', 'B', 'k']
```

## Simulation

The simulation surface is one noun and one verb: `esm_problem(...)` builds,
`solve(...)` runs. Requires the `[simulate]` extra.

```python
from earthsci_ast import esm_problem, solve

prob = esm_problem("simple_ode.esm", (0.0, 10.0))
sol = solve(prob, saveat=[0.0, 5.0, 10.0])

print(sol.retcode)          # ReturnCode.Success
print(sol.t)                # [ 0.  5. 10.]
print(sol.vars)             # ['ExponentialDecay.N']
print(sol.get("ExponentialDecay.N"))
print(sol.y.shape)          # (n_variables, n_timepoints)
```

`esm_problem` accepts overrides for parameters and initial conditions, plus the
metaparameters and data providers a document needs:

```python
prob = esm_problem(
    "model.esm",
    (0.0, 86400.0),
    p={"k_decay": 0.05},
    u0={"N": 100.0},
    model_name="ExponentialDecay",
)
sol = solve(prob, alg="LSODA", abstol=1e-8, reltol=1e-6)
```

### What `esm_problem` accepts

`esm_problem` enforces one rule: the flattened system's independent variables
must be exactly `['t']`. A document still carrying a spatial axis (`x`, `y`,
`z`, …) raises `UnsupportedDimensionalityError`.

This is an interface contract, not a tier limit — **discretize the spatial axes
first**. Discretization is expressed as `expression_templates` carrying `match`
rewrite rules, and the binding applies them at load time. Once discretized, the
same `esm_problem` / `solve` pair handles 0-D ODEs, mixed ODE/algebraic
systems, and PDEs of any dimensionality, because the post-discretize AST has
the same shape regardless of the original topology.

### Working with the results as arrays

`sol.t` and `sol.y` are plain NumPy arrays, so the whole SciPy/NumPy toolkit
applies directly:

```python
import numpy as np
from earthsci_ast import esm_problem, solve

sol = solve(esm_problem("model.esm", (0.0, 3600.0)))

series = sol.get("ExponentialDecay.N")
print("mean:", np.mean(series))
print("final:", series[-1])
print("half-life crossing:", sol.t[np.argmax(series < series[0] / 2)])
```

### Parameter sweeps

There is no dedicated sweep helper — build one problem per sample:

```python
import numpy as np
from earthsci_ast import esm_problem, solve

results = {}
for k in np.linspace(0.01, 0.10, 10):
    sol = solve(esm_problem("model.esm", (0.0, 3600.0), p={"k_decay": float(k)}))
    results[k] = sol.get("ExponentialDecay.N")[-1]

for k, final in results.items():
    print(f"k={k:.3f} -> {final:.4f}")
```

## SymPy Integration

### Symbolic Computation

```python
import sympy as sp
from earthsci_ast import ExprNode, to_sympy, from_sympy, to_unicode

expr = ExprNode(op="*", args=["k", "A", "B"])
sym = to_sympy(expr)
print(sym)                       # A*B*k
print(sp.expand(sym * 2))

# And back into ESM form
print(to_unicode(from_sympy(sp.simplify(sym))))
```

`to_sympy` accepts an optional `symbol_map` if you need to control how names
become SymPy symbols.

### Jacobian Matrix Generation

`jacobian(model)` differentiates the model's ODE right-hand sides with respect
to its ODE states and returns a SymPy matrix:

```python
from earthsci_ast import Model, ModelVariable, Equation, ExprNode, jacobian, ode_states

model = Model(
    name="Lotka",
    variables={
        "x": ModelVariable(type="unknown", units="1", description="prey"),
        "y": ModelVariable(type="unknown", units="1", description="predator"),
        "a": ModelVariable(type="parameter", units="1/s", default=1.1),
        "b": ModelVariable(type="parameter", units="1/s", default=0.4),
    },
    equations=[
        Equation(
            lhs=ExprNode(op="D", args=["x"], wrt="t"),
            rhs=ExprNode(op="-", args=[ExprNode(op="*", args=["a", "x"]),
                                       ExprNode(op="*", args=["b", "x", "y"])]),
        ),
        Equation(
            lhs=ExprNode(op="D", args=["y"], wrt="t"),
            rhs=ExprNode(op="-", args=[ExprNode(op="*", args=["b", "x", "y"]),
                                       ExprNode(op="*", args=["a", "y"])]),
        ),
    ],
)

print(ode_states(model))   # ['x', 'y']
print(jacobian(model))     # Matrix([[a - b*y, -b*x], [b*y, -a + b*x]])
```

`jacobian` requires every equation in the model to be differentiable, so a
model that also carries `ic` (initial-condition) equations must have them
filtered out first.

## Visualization with Matplotlib

### Time Series Plotting

A `Solution` plots itself (requires the `[plot]` extra):

```python
from earthsci_ast import esm_problem, solve

sol = solve(esm_problem("model.esm", (0.0, 3600.0)))
sol.plot()                                    # every variable
sol.plot(variables=["ExponentialDecay.N"])    # a subset
```

For full control, drive matplotlib directly off the arrays:

```python
import matplotlib.pyplot as plt
from earthsci_ast import esm_problem, solve

sol = solve(esm_problem("model.esm", (0.0, 3600.0)))

fig, ax = plt.subplots(figsize=(8, 4))
for name in sol.vars:
    ax.plot(sol.t, sol.get(name), label=name)
ax.set_xlabel("time (s)")
ax.set_ylabel("value")
ax.legend()
fig.tight_layout()
fig.savefig("timeseries.png", dpi=150)
```

### Visualizing model structure

`component_graph` returns the coupling graph, which renders to Mermaid, DOT, or
JSON — useful for embedding a diagram in a notebook or a report:

```python
from earthsci_ast import load_path, component_graph, to_mermaid, to_dot

graph = component_graph(load_path("coupled.esm"))
print(to_mermaid(graph))
print(to_dot(graph))
```

## Jupyter Notebook Integration

### Interactive Model Exploration

`to_latex` output renders directly in a notebook, and `ipywidgets` gives you a
parameter slider over the same `esm_problem` / `solve` pair:

```python
from IPython.display import Math, display
from earthsci_ast import load_path, to_latex

esm_file = load_path("model.esm")
model = esm_file.models["ExponentialDecay"]
for eq in model.equations:
    display(Math(f"{to_latex(eq.lhs)} = {to_latex(eq.rhs)}"))
```

```python
import ipywidgets as widgets
import matplotlib.pyplot as plt
from earthsci_ast import esm_problem, solve

def run(k_decay=0.05, hours=1.0):
    sol = solve(esm_problem("model.esm", (0.0, hours * 3600.0), p={"k_decay": k_decay}))
    plt.figure(figsize=(8, 4))
    for name in sol.vars:
        plt.plot(sol.t, sol.get(name), label=name)
    plt.xlabel("time (s)"); plt.legend(); plt.show()

widgets.interact(run, k_decay=(0.01, 0.20, 0.01), hours=(0.5, 24.0, 0.5))
```

### Comparing model versions

```python
import matplotlib.pyplot as plt
from earthsci_ast import esm_problem, solve

versions = {"v1.0": "model_v1.esm", "v1.1": "model_v1.1.esm"}
fig, ax = plt.subplots(figsize=(8, 4))
for label, path in versions.items():
    sol = solve(esm_problem(path, (0.0, 3600.0)))
    ax.plot(sol.t, sol.get(sol.vars[0]), label=label)
ax.legend(); ax.set_xlabel("time (s)")
plt.show()
```

## Unit Testing and Validation

### PyTest Integration

```python
import pytest
from earthsci_ast import load_path, validate, validate_units, esm_problem, solve


@pytest.fixture
def esm_file():
    return load_path("tests/fixtures/model.esm")


def test_document_is_valid(esm_file):
    result = validate(esm_file)
    assert result.is_valid, result.schema_errors + result.structural_errors


def test_units_are_consistent(esm_file):
    report = validate_units(esm_file)
    assert report.is_valid, [f.message for f in report.findings]


def test_solution_conserves_mass():
    sol = solve(esm_problem("tests/fixtures/model.esm", (0.0, 100.0)))
    assert sol.retcode.name == "Success"
    total = sum(sol.get(name) for name in sol.vars)
    assert abs(total[-1] - total[0]) < 1e-6
```

### Round-trip property testing

Serialization must be lossless, which is a natural property test:

```python
from earthsci_ast import load_path, to_json, load_string


def test_round_trip_is_lossless():
    original = load_path("tests/fixtures/model.esm")
    again = load_string(to_json(original))
    assert to_json(again) == to_json(original)
```

## Performance Notes

- **Load once, reuse.** `load_path` parses and resolves references; hold the
  resulting `EsmFile` rather than re-reading the file per operation.
- **Build once, solve many.** `esm_problem` does the flattening, discretization
  rewrite, and code preparation. For a sweep, rebuild only when the *structure*
  changes — parameter and initial-condition overrides are arguments to
  `esm_problem`, so they are cheap relative to re-parsing.
- **`cse=True`** (the default on `esm_problem`) eliminates common
  subexpressions in the right-hand side; leave it on unless you are debugging.
- **Stay in NumPy.** `sol.y` is a single array; prefer vectorized operations
  over per-timestep Python loops.

## Next Steps

- Read the [format specification](https://github.com/EarthSciML/EarthSciAST/blob/main/esm-spec.md)
  for the authoritative definition
- Browse the [examples](../../examples/)
- See the [troubleshooting guide](../../troubleshooting/) when something fails
- Check the [Python package README](https://github.com/EarthSciML/EarthSciAST/blob/main/pkg/earthsci-ast-py/README.md)
  for the simulation-interface contract in full

## Common Patterns

### Model Factory

```python
from earthsci_ast import Model, ModelVariable, Equation, ExprNode


def decay_model(name: str, rate: float) -> Model:
    return Model(
        name=name,
        variables={
            "N": ModelVariable(type="unknown", units="mol", description="amount"),
            "k": ModelVariable(type="parameter", units="1/s", default=rate),
        },
        equations=[
            Equation(
                lhs=ExprNode(op="D", args=["N"], wrt="t"),
                rhs=ExprNode(op="-", args=[ExprNode(op="*", args=["k", "N"])]),
            )
        ],
    )
```

### Data Pipeline Integration

```python
from pathlib import Path
import pandas as pd
from earthsci_ast import esm_problem, solve


def run_to_dataframe(path: Path, tspan, **overrides) -> pd.DataFrame:
    sol = solve(esm_problem(str(path), tspan, **overrides))
    return pd.DataFrame({name: sol.get(name) for name in sol.vars}, index=sol.t)


df = run_to_dataframe(Path("model.esm"), (0.0, 3600.0), p={"k_decay": 0.05})
df.to_csv("results.csv")
```
