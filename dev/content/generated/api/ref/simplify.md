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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/expression.jl#L622)

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
function simplify(expr: Expr): Expr
```

Simplify an expression using basic algebraic rules

**Parameters**

- `expr` — Expression to simplify

**Returns**

Simplified expression

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-ts/src/expression.ts#L114)

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
simplify(expr: Expr) -> Expr
```

Simplify an expression by performing constant folding and basic algebraic simplifications.

**Parameters**

- `expr` (`Expr`) — Expression to simplify

**Returns**

- `Expr` — Simplified expression

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/expression.py#L104)

**Example** (`simplify`)

```python
messy = ExprNode(op="+", args=[ExprNode(op="*", args=["x", 1]), 0])
assert earthsci_ast.simplify(messy) == "x"

folded = earthsci_ast.simplify(ExprNode(op="*", args=[2, 3, "x"]))
assert earthsci_ast.to_ascii(folded) == "x * 6"
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/python/expressions.py#L31-L35">docs/api/examples/python/expressions.py</a></p>

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
makearray `values`, `table_lookup` axes) — and operator nodes are rebuilt
with `crate::types::ExpressionNode::map_children`, so all node metadata
is preserved.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/expression.rs#L63) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.simplify.html)

**Example** (`evaluate`)

```rust
let expr = parse_expression("k * A - x")?;
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
assert_eq!(to_ascii(&simplify(&parse_expression("x * 1 + 0")?)), "x");
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/rust/expressions.rs#L36-L51">docs/api/examples/rust/expressions.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func Simplify(expr Expression) Expression
```

Simplify performs constant folding and basic algebraic simplification.

A typed-nil \*ExprNode is returned unchanged rather than dereferenced (audit no audit ID; found while fixing G3), matching Substitute/asExprNode.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/expression.go#L87) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#Simplify)

</div>

</div>
