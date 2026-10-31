---
title: "free_variables"
description: "Stable function · Expressions"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Expressions](/generated/api/topics/expressions)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `free_variables` | `freeVariables` | `free_variables` | `free_variables` | `FreeVariables` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
free_variables(expr::NumExpr)
free_variables(expr::IntExpr)
free_variables(expr::VarExpr)
free_variables(expr::OpExpr)
```

```julia
free_variables(expr::ASTExpr)::Set{String}
```

Extract all free (unbound) variable names from an expression.
Returns a set of variable names that appear in the expression.

**Examples**
```julia
x = VarExpr("x")
y = VarExpr("y")
sum_expr = OpExpr("+", [x, y])
vars = free_variables(sum_expr)  # Set(["x", "y"])

nested = OpExpr("*", [OpExpr("+", [x, NumExpr(1.0)]), y])
vars = free_variables(nested)  # Set(["x", "y"])
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/expression.jl#L466)

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
function freeVariables(expr: Expr): Set<string>
```

Extract all variable references from an expression.

Routes through `forEachChild` — the ONE walker — so every
expression-bearing field is seen, not just `args`. Walking `args` alone made
whole sidecar subtrees invisible:

  - `table_lookup{axes:{temp:'T_air'}}`      → `[]`      (missed `T_air`)
  - `aggregate{args:['A'], expr:{*:['A','w']}}` → `['A']`  (missed `w`)
  - `integral{lower:'a', upper:{+:['b',1]}}` → missed `a`, `b`

`graph.ts` builds the dependency DAG from this, so every one of those misses
was a silently-absent edge.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-ts/src/expression.ts#L46)

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
free_variables(expr: Expr) -> set[str]
```

Extract all free variables from an expression.

Traverses the full canonical child set (`.expr_walk`), so variables
hidden in aggregate bodies, `filter` predicates, integral bounds,
`makearray` values, or `table_lookup` axes are all found. `wrt` and
`dim` are not children (they bind/label, they do not reference values)
and are not collected.

**Parameters**

- `expr` (`Expr`) — Expression to analyze

**Returns**

- `set[str]` — Set of variable names found in the expression

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/expression.py#L31)

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
pub fn free_variables(expr: &Expr) -> HashSet<String>
```

Extract all free variables from an expression

**Arguments**

* `expr` - The expression to analyze

**Returns**

* Set of variable names referenced in the expression

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/expression.rs#L15) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.free_variables.html)

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
func FreeVariables(expr Expression) map[string]bool
```

FreeVariables returns the set of all variable names that appear in an expression, including those reachable ONLY through a sidecar (non-`args`) field — an aggregate's `expr`/`filter`/`key`/`join`, an integral's `lower`/`upper`, a table\_lookup's `axes`, a makearray's `values`, an apply\_expression\_template's `bindings`, … The walk is the shared field-preserving one (mapExprChildren), so a name can never again hide from it in a field the walker was not taught about (audit G1 — and G2, where a false-negative Contains made the DAE contract delete a still-referenced equation).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/expression.go#L37) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#FreeVariables)

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
