---
title: "flattened_equation"
description: "Stable type · Flatten"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Flatten](/generated/api/topics/flatten)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | `FlattenedEquation` | `FlattenedEquation` | not exported | `FlattenedEquation` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this type.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
interface FlattenedEquation {
    lhs: Expression;
    rhs: Expression;
    sourceSystem: string;
    contributions: Contribution[];
    lifted?: boolean;
}
```

A single equation of the flattened system, with dot-namespaced Expression
TREES.

`lhs` / `rhs` are canonical Expression ASTs — what every other binding
carries and what the shared corpus pins. A caller that wants text calls
`printMath` on them.

**Properties**

- `lhs` — Dot-namespaced LHS, e.g. `D(Atmos.O3, t)` or a bare `Atmos.total`.
- `rhs` — Dot-namespaced RHS, with coupling contributions merged in.
- `sourceSystem` — The equation's SLOT OWNER: the component whose equation list it sits in,
  which decides what a later `operator_compose` entry can see (§4.7.1 step 4).
  It is not provenance — a composed equation has one slot owner and several
  authors; `FlattenedEquation.contributions` records those.
- `contributions` — Per-term provenance (esm-libraries-spec §4.7.5): the ordered summands of the
  right-hand side, each with the component or coupling entry that authored
  it. The body (`rhs`, or the `faq` body when `FlattenedEquation.lifted`)
  is the LEFT fold of their expressions.
- `lifted` — True when the pointwise lift (esm-spec §10.5) wrapped the equation in an
  `faq` over the grid; the contributions then sum to `rhs.expr`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/earthsci-ast-ts/src/flatten.ts#L386)

**Example** (`flatten`)

```typescript
const doc = loadPath(fixture('coupled.esm'))
const flat = flatten(doc)

// Variables are namespaced by the system that declared them.
assert.deepEqual(Object.keys(flat.stateVariables), ['Heater.T', 'Box.T_air'])
assert.deepEqual(Object.keys(flat.parameters), ['Heater.rate', 'Box.k'])
assert.equal(flat.stateVariables['Box.T_air'].units, 'K')

// The `param_to_var` variable_map replaces the box's wall-temperature
// parameter with the heater's temperature: `Box.T_wall` is gone from the
// parameters above, and the box equation reads `Heater.T` in its place.
// LaTeX prints the dotted names more readably than Typst does.
const equations = flat.equations.map((eq) => {
  const sides = { lhs: eq.lhs, rhs: eq.rhs }
  return printMath(sides, expressionNames(sides), 'markdown')
})
assert.deepEqual(equations, [
  '\\frac{\\mathrm{d} \\mathit{Heater}.T}{\\mathrm{d} t} = \\mathit{Heater}.\\mathit{rate}',
  '\\frac{\\mathrm{d} \\mathit{Box}.T_{\\mathrm{air}}}{\\mathrm{d} t} = ' +
    '\\mathit{Box}.k \\left(\\mathit{Heater}.T - \\mathit{Box}.T_{\\mathrm{air}}\\right)',
])
assert.deepEqual(
  flat.equations.map((eq) => eq.sourceSystem),
  ['Heater', 'Box'],
)
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/docs/api/examples/typescript/flatten.ts#L9-L33">docs/api/examples/typescript/flatten.ts</a></p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class FlattenedEquation
FlattenedEquation(lhs: Expr, rhs: Expr, source_system: str, contributions: list[Contribution] = list(), lifted: bool = False)
FlattenedEquation.body: Expr  # property
```

An equation in the flattened system, with namespaced Expr trees.

`contributions` is the equation's per-term provenance (esm-libraries-spec
§4.7.5): the ordered summands of the right-hand side, each with the
component or coupling entry that authored it. `body` (`rhs`, or the
`faq` body when the pointwise lift wrapped the equation) is the left fold
of their expressions. Flatten fills it at every step; an equation built
without it gets one contribution with no origins, which says "provenance
unknown" rather than inventing an author.

`source_system` is the equation's SLOT OWNER — the component whose
equation list it sits in, which decides what a later `operator_compose`
entry can see (§4.7.1 step 4). It is not provenance: a composed equation has
one slot owner and several authors.

`lifted` is True when the pointwise lift (esm-spec §10.5) wrapped the
equation in an `faq` over the grid; `body` is then `rhs.expr`.

**Members**

- `body` — The sum the contributions stand for: `rhs`, or the `faq` body of a lifted equation.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/earthsci-ast-py/src/earthsci_ast/flatten.py#L466)

**Example** (`flatten`)

```python
coupled = earthsci_ast.load_path(FIXTURES / "coupled.esm")
flat = earthsci_ast.flatten(coupled)

# Every name is now qualified by the model it came from.
assert list(flat.state_variables) == ["Heater.T", "Box.T_air"]
assert {"Heater.rate", "Box.k"} <= set(flat.parameters)
for name, var in flat.state_variables.items():
    print(f"{name}: {var.units}, default {var.default}")

heater, box = flat.equations
assert heater.lhs == ExprNode(op="D", args=["Heater.T"], wrt="t")
assert heater.rhs == "Heater.rate"

# The param_to_var variable_map replaced the box's wall-temperature parameter
# with the heater's temperature: it is gone from the equations AND from the
# parameters.
assert box.rhs == ExprNode(op="*", args=["Box.k", ExprNode(op="-", args=["Heater.T", "Box.T_air"])])
assert "Box.T_wall" not in earthsci_ast.free_variables(box.rhs)
assert "Box.T_wall" not in flat.parameters
assert flat.metadata.source_systems == ["Heater", "Box"]
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/docs/api/examples/python/flatten.py#L12-L31">docs/api/examples/python/flatten.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this type.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type FlattenedEquation struct {
	LHS           Expression
	RHS           Expression
	SourceSystem  string
	Contributions []Contribution
	Lifted        bool
}

func (e FlattenedEquation) Body() Expression

func (e FlattenedEquation) LHSString() string

func (e FlattenedEquation) RHSString() string
```

FlattenedEquation is a single equation of the flattened system, with dot-namespaced Expression TREES on both sides.

LHSString and RHSString show a side as Typst math (PrintMath).

SourceSystem is the equation's SLOT OWNER: the component whose equation list it sits in, which decides what a later operator\_compose entry can see (esm-libraries-spec §4.7.1 step 4). It is not provenance — a composed equation has one slot owner and several authors; Contributions records those.

Contributions is the equation's per-term provenance (esm-libraries-spec §4.7.5): the ordered summands of the right-hand side, each with the component or coupling entry that authored it. Body() — RHS, or the `faq` body when Lifted — is the LEFT fold of their expressions.

Lifted is true when the pointwise lift (esm-spec §10.5) wrapped the equation in an `faq` over the grid.

**Methods**

```go
func (e FlattenedEquation) Body() Expression
```

Body is the sum the contributions stand for: RHS, or the `faq` body when the pointwise lift wrapped the equation (Lifted).

```go
func (e FlattenedEquation) LHSString() string
```

LHSString shows the equation's left-hand side as Typst math under its own names (PrintMath, ExpressionNames).

```go
func (e FlattenedEquation) RHSString() string
```

RHSString shows the equation's right-hand side as Typst math under its own names (PrintMath, ExpressionNames).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/earthsci-ast-go/pkg/esm/flatten.go#L401) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#FlattenedEquation)

</div>

</div>
