---
title: "simplify"
description: "Stable function · Expressions"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Expressions](/generated/api/topics/expressions)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `simplify` | `simplify` | `simplify` | `simplify` | `Simplify` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
simplify(expr::NumExpr)
simplify(expr::IntExpr)
simplify(expr::VarExpr)
simplify(expr::OpExpr)
```

```julia
simplify(expr::ASTExpr)::ASTExpr
```

Perform constant folding and algebraic simplification on an expression.
Returns a new simplified ASTExpr object (non-mutating).

**Simplification Rules**
- Constant folding: `2 + 3` → `5`
- Additive identity: `x + 0` → `x`, `0 + x` → `x`
- Multiplicative identity: `x * 1` → `x`, `1 * x` → `x`
- Multiplicative zero: `x * 0` → `0`, `0 * x` → `0`
- Exponentiation: `x^0` → `1`, `x^1` → `x`

**Examples**
```julia
# Constant folding
expr = OpExpr("+", [NumExpr(2.0), NumExpr(3.0)])
result = simplify(expr)  # NumExpr(5.0)

# Identity elimination
expr = OpExpr("*", [VarExpr("x"), NumExpr(1.0)])
result = simplify(expr)  # VarExpr("x")
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/expression.jl#L740)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/docs/api/examples/julia/expressions.jl#L5-L28">docs/api/examples/julia/expressions.jl</a></p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function simplify(expr: Expr): Expr
```

Simplify an expression using basic algebraic rules

**Parameters**

- `expr` — Expression to simplify

**Returns**

Simplified expression

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/earthsci-ast-ts/src/expression.ts#L113)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/docs/api/examples/typescript/expressions.ts#L15-L42">docs/api/examples/typescript/expressions.ts</a></p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
simplify(expr: Expr) -> Expr
```

Simplify an expression by performing constant folding and basic algebraic simplifications.

**Parameters**

- `expr` (`Expr`) — Expression to simplify

**Returns**

- `Expr` — Simplified expression

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/earthsci-ast-py/src/earthsci_ast/expression.py#L97)

**Example** (`simplify`)

```python
messy = ExprNode(op="+", args=[ExprNode(op="*", args=["x", 1]), 0])
assert earthsci_ast.simplify(messy) == "x"

folded = earthsci_ast.simplify(ExprNode(op="*", args=[2, 3, "x"]))
assert folded == ExprNode(op="*", args=["x", 6])
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/docs/api/examples/python/expressions.py#L42-L46">docs/api/examples/python/expressions.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn simplify(expr: &Expr) -> Expr
```

Simplify an expression (basic symbolic simplification).

Applies constant folding and the identity/absorbing-element rules for
binary `+`, `*`, and `^`. Children are simplified first — including
sidecar expressions (aggregate bodies, `filter`, integral bounds,
makearray `values`) — and operator nodes are rebuilt
with `crate::types::ExpressionNode::map_children`, so all node metadata
is preserved.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/earthsci-ast-rs/src/expression.rs#L63) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.simplify.html)

**Example** (`evaluate`)

```rust
let expr = read("k A - x", &["k", "A", "x"]);
let bindings = HashMap::from([
    ("k".to_string(), 2.0),
    ("A".to_string(), 3.0),
    ("x".to_string(), 1.0),
]);
assert_eq!(evaluate(&expr, &bindings), Ok(5.0));

// A missing binding is reported by name, not guessed.
let partial = HashMap::from([("k".to_string(), 2.0)]);
let mut unbound = evaluate(&expr, &partial).unwrap_err();
unbound.sort();
assert_eq!(unbound, ["A", "x"]);

assert!(contains(&expr, "A") && !contains(&expr, "B"));
// simplify folds numbers: with k = 2 and A = 3, k A is 6.
let numbers = HashMap::from([
    ("k".to_string(), Expr::Number(2.0)),
    ("A".to_string(), Expr::Number(3.0)),
]);
assert_eq!(simplify(&substitute(&expr, &numbers)).to_string(), "6 - x");
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/docs/api/examples/rust/expressions.rs#L48-L68">docs/api/examples/rust/expressions.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func Simplify(expr Expression) Expression
```

Simplify performs constant folding and basic algebraic simplification.

A typed-nil \*ExprNode is returned unchanged rather than dereferenced (audit no audit ID; found while fixing G3), matching Substitute/asExprNode.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/earthsci-ast-go/pkg/esm/expression.go#L87) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#Simplify)

</div>

</div>
