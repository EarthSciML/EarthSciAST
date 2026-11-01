---
title: "to_ascii"
description: "Stable function · Display"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Display](/generated/api/topics/display)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `to_ascii` | `toAscii` | `to_ascii` | `to_ascii` | `ToASCII` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
to_ascii(target)
to_ascii(::Nothing)
to_ascii(target::Real)
to_ascii(target::String)
to_ascii(target::ASTExpr)
to_ascii(target::Equation)
to_ascii(target::Model)
to_ascii(target::ReactionSystem)
to_ascii(target::EsmFile)
```

```julia
to_ascii(target) -> String
```

Format target as plain ASCII mathematical notation.

Provides plain ASCII output for expressions, equations, models, reaction systems,
and ESM files. Uses standard ASCII operators (*, /, ^) and function call notation
for mathematical functions.

**Arguments**
- `target`: Expression, equation, model, reaction system, or ESM file to format

**Returns**
- Plain ASCII string representation (no Unicode symbols)

**Examples**
```julia
expr = OpExpr("*", [VarExpr("x"), NumExpr(2.0)])
to_ascii(expr)  # Returns "x * 2"

eq = Equation(VarExpr("y"), OpExpr("+", [VarExpr("x"), NumExpr(1.0)]))
to_ascii(eq)   # Returns "y = x + 1"
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/display.jl#L1628)

**Example** (`display`)

```julia
decay_eq = model.equations[1]
println(to_unicode(decay_eq))
@assert to_unicode(decay_eq) == "∂N/∂t = (−λ)·N"
@assert to_latex(decay_eq) == raw"\frac{\partial N}{\partial t} = (-\lambda) \cdot N"
@assert to_ascii(decay_eq) == "D(N)/Dt = (-lambda) * N"

# Expressions display the same way.
@assert to_unicode(model.equations[2].rhs) == "ln(2)/λ"
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/julia/documents.jl#L72-L79">docs/api/examples/julia/documents.jl</a></p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function toAscii(expr: Expr | Equation | Model | ReactionSystem | Reaction | EsmFile): string
```

Format an expression as plain ASCII text

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/pretty-print.ts#L918)

**Example** (`display`)

```typescript
const model = loadPath(fixture('decay.esm')).models!.Decay
const [decay, halfLife] = model.equations

assert.equal(toUnicode(decay), '∂N/∂t = (−λ)·N')
assert.equal(toLatex(decay), '\\frac{\\partial N}{\\partial t} = (-\\lambda) \\cdot N')
assert.equal(toAscii(decay), 'D(N)/Dt = (-lambda) * N')

// A single expression renders the same way.
assert.equal(toUnicode(halfLife.rhs), 'ln(2)/λ')

// So does a whole model: a summary line followed by its equations.
assert.equal(toUnicode(model).split('\n').length, 3)
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/typescript/display.ts#L9-L21">docs/api/examples/typescript/display.ts</a></p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
to_ascii(target: Expr | Equation | Model | ReactionSystem | EsmFile) -> str
```

Format target as plain ASCII mathematical notation.

**Parameters**

- `target` (`Expr | Equation | Model | ReactionSystem | EsmFile`) — Expression, equation, model, reaction system, or ESM file to format

**Returns**

- `str` — Plain ASCII string representation (no Unicode symbols)

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/display.py#L857)

**Example** (`display`)

```python
decay_eq, half_life_eq = model.equations
print(earthsci_ast.to_unicode(decay_eq))
print(earthsci_ast.to_latex(decay_eq))
print(earthsci_ast.to_ascii(half_life_eq))
assert earthsci_ast.to_unicode(decay_eq) == "∂N/∂t = (−λ)·N"
assert earthsci_ast.to_latex(decay_eq) == r"\frac{\partial N}{\partial t} = (-\lambda) \cdot N"
assert earthsci_ast.to_ascii(half_life_eq) == "half_life = log(2) / lambda"

# A whole model renders as a one-line summary.
assert earthsci_ast.to_unicode(model) == "Model: Decay (1 state, 1 parameter, 1 observed, 2 equations)"
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/python/documents.py#L97-L106">docs/api/examples/python/documents.py</a></p>

**Example** (`expressions`)

```python
# An expression is a number, a variable name, or an operator node.
exchange = ExprNode(op="*", args=["k", ExprNode(op="-", args=["T_wall", "T_air"])])
assert earthsci_ast.free_variables(exchange) == {"k", "T_wall", "T_air"}

# Text parses to the same tree that to_ascii prints.
parsed = earthsci_ast.parse_expression("k * (T_wall - T_air)")
assert earthsci_ast.to_ascii(parsed) == earthsci_ast.to_ascii(exchange)

# Substitution replaces names with numbers or with other expressions.
fixed = earthsci_ast.substitute(exchange, {"k": 0.05, "T_wall": ExprNode(op="+", args=["T0", 10])})
assert earthsci_ast.to_ascii(fixed) == "0.05 * (T0 + 10 - T_air)"
assert earthsci_ast.free_variables(fixed) == {"T0", "T_air"}
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/python/expressions.py#L8-L19">docs/api/examples/python/expressions.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn to_ascii<T: TextRenderable + ?Sized>(target: &T) -> String
```

Render `target` as plain ASCII. See [`to_unicode`](/generated/api/ref/to_unicode) for the accepted domain.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/display.rs#L2031) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.to_ascii.html)

**Example** (`display`)

```rust
let doc = load_path(fixture("decay.esm"))?;
let model = &doc.models.as_ref().unwrap()["Decay"];
let decay = &model.equations[0];

let unicode = to_unicode(decay);
let latex = to_latex(decay);
let ascii = to_ascii(decay);
println!("{unicode}\n{latex}\n{ascii}");
assert_eq!(ascii, "D(N)/Dt = (-lambda) * N");
assert!(unicode.contains('λ'));
assert!(latex.contains("\\lambda"));

// The same functions take a single expression, or a whole model (which
// renders a summary).
assert_eq!(to_ascii(&model.equations[1].rhs), "log(2) / lambda");
assert!(to_unicode(model).contains("half_life"));
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/rust/display.rs#L8-L23">docs/api/examples/rust/display.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func ToASCII(target Expression) string
```

ToASCII converts an expression, equation or container to a plain-text string using the ascii render format (function-call notation, no Unicode symbols in the operator layer).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/display.go#L64) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ToASCII)

**Example** (`display`)

```go
doc, err := esm.LoadPath(fixture("decay.esm"))
if err != nil {
	log.Fatal(err)
}
model := doc.Models["Decay"]
decay := model.Equations[0]
fmt.Println(esm.ToUnicode(decay))
fmt.Println(esm.ToLatex(decay))
fmt.Println(esm.ToASCII(decay))

// A single expression renders the same way.
fmt.Println(esm.ToUnicode(model.Equations[1].RHS))
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/go/display_test.go#L13-L24">docs/api/examples/go/display_test.go</a></p>

**Example** (`expressions`)

```go
parsed, err := esm.ParseExpression("k * (T_wall - T_air)")
if err != nil {
	log.Fatal(err)
}
fmt.Println(sortedKeys(esm.FreeVariables(parsed)))

// The same tree, built directly: an operator node is an ExprNode, a
// variable is a string and a number is a float64.
built := esm.ExprNode{Op: "*", Args: []any{
	"k",
	esm.ExprNode{Op: "-", Args: []any{"T_wall", "T_air"}},
}}
fmt.Println(esm.ToASCII(built) == esm.ToASCII(parsed))

substituted, err := esm.Substitute(parsed, map[string]esm.Expression{
	"T_wall": 290.0,
	"k":      esm.ExprNode{Op: "/", Args: []any{1.0, "tau"}},
})
if err != nil {
	log.Fatal(err)
}
fmt.Println(esm.ToASCII(substituted))
fmt.Println(sortedKeys(esm.FreeVariables(substituted)))

value, err := esm.Evaluate(substituted, map[string]float64{"tau": 20, "T_air": 280})
if err != nil {
	log.Fatal(err)
}
fmt.Println(value)
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/go/expressions_test.go#L14-L42">docs/api/examples/go/expressions_test.go</a></p>

**Example** (`flatten`)

```go
doc, err := esm.LoadPath(fixture("coupled.esm"))
if err != nil {
	log.Fatal(err)
}
flat, err := esm.Flatten(doc)
if err != nil {
	log.Fatal(err)
}
for _, v := range flat.StateVariables {
	fmt.Println("state:", v.Name)
}
for _, v := range flat.Parameters {
	fmt.Println("parameter:", v.Name)
}
for _, eq := range flat.Equations {
	fmt.Println(esm.ToASCII(eq.LHS), "=", esm.ToASCII(eq.RHS))
}
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/go/flatten_test.go#L14-L30">docs/api/examples/go/flatten_test.go</a></p>

**Example** (`inspect`)

```go
doc, err := esm.LoadPath(fixture("decay.esm"))
if err != nil {
	log.Fatal(err)
}
for _, name := range sortedKeys(doc.Models) {
	model := doc.Models[name]
	fmt.Println(name, sortedKeys(model.Variables))

	fmt.Println("ODE states:", esm.ODEStates(&model))
	fmt.Println("observed:", esm.ObservedUnknowns(&model))
	fmt.Println("algebraic:", esm.AlgebraicUnknowns(&model))
	fmt.Println("constant parameters:", esm.ConstantParameters(&model))

	fmt.Println(esm.IsODEState(&model, "N"), esm.IsODEState(&model, "half_life"))
	if def, ok := esm.ObservedDefinition(&model, "half_life"); ok {
		fmt.Println("half_life =", esm.ToASCII(def))
	}
}
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/go/inspect_test.go#L14-L31">docs/api/examples/go/inspect_test.go</a></p>

**Example** (`reactions`)

```go
doc, err := esm.LoadPath(fixture("ozone.esm"))
if err != nil {
	log.Fatal(err)
}
system := doc.ReactionSystems["Ozone"]
odes, err := esm.DeriveODEs(&system)
if err != nil {
	log.Fatal(err)
}
for _, eq := range odes.Equations {
	fmt.Println(esm.ToASCII(eq.LHS), "=", esm.ToASCII(eq.RHS))
}

// One row per species, one column per reaction.
fmt.Println(esm.StoichiometricMatrix(&system))
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/go/reactions_test.go#L13-L27">docs/api/examples/go/reactions_test.go</a></p>

</div>

</div>
