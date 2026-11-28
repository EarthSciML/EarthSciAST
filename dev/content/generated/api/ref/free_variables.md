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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/EarthSciAST.jl/src/expression.jl#L582)

**Example** (`expressions`)

```julia
# Read Typst math (or LaTeX, with :markdown) under the names it uses; the
# result is the expression's JSON form, which `expression_from_json` types.
names = ["k", "x", "y"]
expr = expression_from_json(parse_math("k x + y", names, :typst))
built = OpExpr("+", [OpExpr("*", [VarExpr("k"), VarExpr("x")]), VarExpr("y")])
@assert canonical_json(expr) == canonical_json(built)
# An expression shows as its Typst math.
@assert string(expr) == "k x + y"

@assert free_variables(expr) == Set(["k", "x", "y"])

# `substitute` takes a Dict{String,ASTExpr}: give the value type explicitly.
two_x = expression_from_json(parse_math("2 x", names, :typst))
replaced = substitute(expr, Dict{String, ASTExpr}("y" => two_x))
@assert string(replaced) == "k x + 2 x"
@assert free_variables(replaced) == Set(["k", "x"])

# Constant subexpressions fold away.
folded = simplify(expression_from_json(parse_math("x (1 + 1)", names, :typst)))
@assert string(folded) == "x dot 2"

# Text whose top is `=` reads as an equation, `lhs` and `rhs`.
eq = parse_math("(dif x)/(dif t) = -k x", names, :typst)
@assert string(expression_from_json(eq["rhs"])) == "-k x"
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/docs/api/examples/julia/expressions.jl#L5-L28">docs/api/examples/julia/expressions.jl</a></p>

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

  - `aggregate{args:['A'], expr:{*:['A','w']}}` → `['A']`  (missed `w`)
  - `integral{lower:'a', upper:{+:['b',1]}}` → missed `a`, `b`

`graph.ts` builds the dependency DAG from this, so every one of those misses
was a silently-absent edge.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-ts/src/expression.ts#L45)

**Example** (`expressions`)

```typescript
// Expressions are plain JSON trees; build one directly ...
const built: Expr = { op: '*', args: ['k', { op: '-', args: ['T_wall', 'T_air'] }] }

// ... or read one from LaTeX ('markdown') or Typst math, under the names it
// uses: the inverse of `printMath`.
const names = ['k', 'T_wall', 'T_air']
const latex = 'k \\left(T_{\\mathrm{wall}} - T_{\\mathrm{air}}\\right)'
const parsed = parseMath(latex, names, 'markdown') as Expr
assert.deepEqual(parsed, built)
assert.equal(printMath(parsed, names, 'markdown'), latex)
assert.deepEqual([...freeVariables(parsed)].sort(), ['T_air', 'T_wall', 'k'])
assert.equal(contains(parsed, 'T_wall'), true)

// Substitution is single-pass and returns a new tree.
const bound = substitute(parsed, { T_wall: 300, k: 0.05 })
assert.deepEqual(bound, { op: '*', args: [0.05, { op: '-', args: [300, 'T_air'] }] })
assert.deepEqual([...freeVariables(bound)], ['T_air'])
assert.equal(simplify(substitute(parsed, { T_wall: 300, T_air: 300 })), 0)

// Text whose top is `=` reads as an equation.
const eq = parseMath('(dif T_(upright("air")))/(dif t) = k (T_(upright("wall")) - T_(upright("air")))', names, 'typst') as {
  lhs: Expr
  rhs: Expr
}
assert.deepEqual(eq.rhs, built)

// Text that is not math raises a diagnostic error.
assert.throws(() => parseMath('k \\left(T_{\\mathrm{wall}}', names, 'markdown'), EsmDiagnosticError)
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/docs/api/examples/typescript/expressions.ts#L15-L42">docs/api/examples/typescript/expressions.ts</a></p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
free_variables(expr: Expr) -> set[str]
```

Extract all free variables from an expression.

Traverses the full canonical child set (`.expr_walk`), so variables
hidden in aggregate bodies, `filter` predicates, integral bounds,
or `makearray` values are all found. `wrt` and
`dim` are not children (they bind/label, they do not reference values)
and are not collected.

**Parameters**

- `expr` (`Expr`) — Expression to analyze

**Returns**

- `set[str]` — Set of variable names found in the expression

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-py/src/earthsci_ast/expression.py#L24)

**Example** (`expressions`)

```python
# An expression is a number, a variable name, or an operator node.
exchange = ExprNode(op="*", args=["k", ExprNode(op="-", args=["T_wall", "T_air"])])
assert earthsci_ast.free_variables(exchange) == {"k", "T_wall", "T_air"}

# Substitution replaces names with numbers or with other expressions.
fixed = earthsci_ast.substitute(exchange, {"k": 0.05, "T_wall": ExprNode(op="+", args=["T0", 10])})
assert fixed == ExprNode(
    op="*", args=[0.05, ExprNode(op="-", args=[ExprNode(op="+", args=["T0", 10]), "T_air"])]
)
assert earthsci_ast.free_variables(fixed) == {"T0", "T_air"}
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/docs/api/examples/python/expressions.py#L9-L18">docs/api/examples/python/expressions.py</a></p>

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/expression.rs#L15) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.free_variables.html)

**Example** (`expressions`)

```rust
// Read Typst math (or LaTeX, with DocumentFormat::Markdown) under the
// names it uses: the inverse of print_math.
let names = ["k".to_string(), "A".to_string(), "x".to_string()];
let value = parse_math("k A - x", &names, DocumentFormat::Typst)?;
let rate: Expr = serde_json::from_value(value)?;
assert_eq!(rate.to_string(), "k A - x");

// Text whose top is `=` reads as an equation.
let value = parse_math("(dif x)/(dif t) = k A - x", &names, DocumentFormat::Typst)?;
let eq: Equation = serde_json::from_value(value)?;
assert_eq!(eq.lhs.to_string(), "(dif x)/(dif t)");

let mut free: Vec<String> = free_variables(&rate).into_iter().collect();
free.sort();
assert_eq!(free, ["A", "k", "x"]);

// Replace `k` with `2 j`.
let subs = HashMap::from([("k".to_string(), read("2 j", &["j"]))]);
let replaced = substitute(&rate, &subs);
assert_eq!(replaced.to_string(), "(2 j) A - x");

// Expressions are also plain Rust values.
let one = Expr::Variable("x".to_string());
assert_eq!(one.to_string(), "x");
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/docs/api/examples/rust/expressions.rs#L21-L44">docs/api/examples/rust/expressions.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func FreeVariables(expr Expression) map[string]bool
```

FreeVariables returns the set of all variable names that appear in an expression, including those reachable ONLY through a sidecar (non-`args`) field — an aggregate's `expr`/`filter`/`key`/`join`, an integral's `lower`/`upper`, a makearray's `values`, an apply\_operator's `bindings`, … The walk is the shared field-preserving one (mapExprChildren), so a name can never again hide from it in a field the walker was not taught about (audit G1 — and G2, where a false-negative Contains made the DAE contract delete a still-referenced equation).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-go/pkg/esm/expression.go#L37) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#FreeVariables)

**Example** (`expressions`)

```go
read, err := esm.ParseMath(`k \left(T_{\mathrm{wall}} - T_{\mathrm{air}}\right)`,
	[]string{"k", "T_wall", "T_air"}, esm.DocumentMarkdown)
if err != nil {
	log.Fatal(err)
}
// ParseMath returns the decoded JSON tree; UnmarshalExpression makes it
// this package's Expression.
blob, err := json.Marshal(read)
if err != nil {
	log.Fatal(err)
}
parsed, err := esm.UnmarshalExpression(blob)
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
fmt.Println(reflect.DeepEqual(built, parsed))

substituted, err := esm.Substitute(parsed, map[string]esm.Expression{
	"T_wall": 290.0,
	"k":      esm.ExprNode{Op: "/", Args: []any{1.0, "tau"}},
})
if err != nil {
	log.Fatal(err)
}
fmt.Println(esm.PrintMath(substituted, esm.ExpressionNames(substituted), esm.DocumentTypst))
fmt.Println(sortedKeys(esm.FreeVariables(substituted)))

value, err := esm.Evaluate(substituted, map[string]float64{"tau": 20, "T_air": 280})
if err != nil {
	log.Fatal(err)
}
fmt.Println(value)
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/docs/api/examples/go/expressions_test.go#L16-L55">docs/api/examples/go/expressions_test.go</a></p>

</div>

</div>
