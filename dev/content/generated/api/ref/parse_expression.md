---
title: "parse_expression"
description: "Stable function · Expressions"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Expressions](/generated/api/topics/expressions)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `parse_expression` | `parseExpression` | `parse_expression` | `parse_expression` | `ParseExpression` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
parse_expression(src::AbstractString)
```

```julia
parse_expression(src::AbstractString) -> ASTExpr
```

Parse a single expression string in the INFIX TEXT form into an AST expression —
the inverse of [`to_ascii`](/generated/api/ref/to_ascii). Throws [`ExpressionParseError`](/generated/api/ref/expression_parse_error) on
malformed input or an operator with no text surface yet.

The JSON (wire → typed IR) decoder is a different entry point,
[`expression_from_json`](/generated/api/extension/julia#x-expression_from_json).

**Examples**
```julia
parse_expression("k1 * NO2 * O2 - k2 * O3")
parse_expression("D(O3)/Dt")
parse_expression("sum[i] (u[i, k]) where {i in cells, k in edges_of_cell(i)}")
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/parse_expression_text.jl#L1260)

**Example** (`expressions`)

```julia
# Parse from text, or build the tree directly.
expr = parse_expression("k * x + y")
built = OpExpr("+", [OpExpr("*", [VarExpr("k"), VarExpr("x")]), VarExpr("y")])
@assert to_ascii(expr) == to_ascii(built) == "k * x + y"

@assert free_variables(expr) == Set(["k", "x", "y"])

# `substitute` takes a Dict{String,ASTExpr}: give the value type explicitly.
replaced = substitute(expr, Dict{String, ASTExpr}("y" => parse_expression("2 * x")))
@assert to_ascii(replaced) == "k * x + 2 * x"
@assert free_variables(replaced) == Set(["k", "x"])

# Constant subexpressions fold away.
@assert to_ascii(simplify(parse_expression("x * (1 + 1)"))) == "x * 2"

# An equation parses the same way, with D(x, t) for a time derivative.
eq = parse_equation("D(x, t) = -k * x")
@assert eq isa Equation
@assert to_unicode(eq) == "∂x/∂t = −k·x"
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/julia/expressions.jl#L5-L23">docs/api/examples/julia/expressions.jl</a></p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function parseExpression(src: string): Expr
```

Parse a single expression string into an AST expression — the inverse of
[`toAscii`](/generated/api/ref/to_ascii). Throws [`ExpressionParseError`](/generated/api/ref/expression_parse_error) on malformed input or an
operator with no text surface yet.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-ts/src/parse-expression.ts#L1075)

**Example** (`expressions`)

```typescript
// Expressions are plain JSON trees; build one directly ...
const built: Expr = { op: '*', args: ['k', { op: '-', args: ['T_wall', 'T_air'] }] }

// ... or parse the text form, which is the inverse of `toAscii`.
const parsed = parseExpression('k * (T_wall - T_air)')
assert.deepEqual(parsed, built)
assert.deepEqual([...freeVariables(parsed)].sort(), ['T_air', 'T_wall', 'k'])
assert.equal(contains(parsed, 'T_wall'), true)

// Substitution is single-pass and returns a new tree.
const bound = substitute(parsed, { T_wall: 300, k: 0.05 })
assert.equal(toAscii(bound), '0.05 * (300 - T_air)')
assert.deepEqual([...freeVariables(bound)], ['T_air'])
assert.equal(toAscii(simplify(substitute(parsed, { T_wall: 300, T_air: 300 }))), '0')

const eq = parseEquation('D(T_air) = k * (T_wall - T_air)')
assert.deepEqual(eq.rhs, built)

assert.throws(() => parseExpression('k * (T_wall'), ExpressionParseError)
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/typescript/expressions.ts#L16-L34">docs/api/examples/typescript/expressions.ts</a></p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
parse_expression(src: str) -> Expr
```

Parse a single expression string into an AST expression — the inverse of
[`to_ascii`](/generated/api/ref/to_ascii).

Operator nodes come back in their JSON `dict` form (see the module
docstring); numbers and bare references come back as `int` / `float` /
`str`.

**Raises**

- [`ExpressionParseError`](/generated/api/ref/expression_parse_error) — on malformed input, or on an operator that has
  no text surface yet (`table_lookup` / `broadcast` / `enum` /
  `intersect_polygon`).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/parse_expression.py#L1063)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/python/expressions.py#L8-L19">docs/api/examples/python/expressions.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn parse_expression(src: &str) -> Result<Expr, ExpressionParseError>
```

Parse a single expression string into an AST expression — the inverse of
[`crate::display::to_ascii`](/generated/api/ref/to_ascii).

**Errors**

Returns an [`ExpressionParseError`](/generated/api/ref/expression_parse_error) on malformed input, or on an operator
that has no text surface yet (`table_lookup` in its CALL spelling — the
bracket form `visc[T=temp]` parses — `broadcast`, and `enum`).

**Examples**

```rust
use earthsci_ast::parse_expression;
use earthsci_ast::to_ascii;

let e = parse_expression("k1 * NO2 * O2 - k2 * O3")?;
assert_eq!(to_ascii(&e), "k1 * NO2 * O2 - k2 * O3");
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/parse_expression.rs#L1596) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.parse_expression.html)

**Example** (`expressions`)

```rust
// Parse the text form (the same syntax `to_ascii` prints) ...
let rate = parse_expression("k * A - x")?;
assert_eq!(to_ascii(&rate), "k * A - x");

// ... or a whole equation.
let eq = parse_equation("D(x)/Dt = k * A - x")?;
assert_eq!(to_ascii(&eq.lhs), "D(x)/Dt");

let mut names: Vec<String> = free_variables(&rate).into_iter().collect();
names.sort();
assert_eq!(names, ["A", "k", "x"]);

// Replace `k` with `2 * j`.
let subs = HashMap::from([("k".to_string(), parse_expression("2 * j")?)]);
let replaced = substitute(&rate, &subs);
assert_eq!(to_ascii(&replaced), "2 * j * A - x");

// Expressions are also plain Rust values.
let one = Expr::Variable("x".to_string());
assert_eq!(to_ascii(&one), "x");
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/rust/expressions.rs#L13-L32">docs/api/examples/rust/expressions.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func ParseExpression(src string) (Expression, error)
```

ParseExpression parses a single expression string into an AST expression — the inverse of ToASCII. It returns an error wrapping \*ExpressionParseError on malformed input or on an operator with no text surface yet.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/parse_expression.go#L1423) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ParseExpression)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/go/expressions_test.go#L14-L42">docs/api/examples/go/expressions_test.go</a></p>

</div>

</div>
