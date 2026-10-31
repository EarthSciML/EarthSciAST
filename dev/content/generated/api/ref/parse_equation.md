---
title: "parse_equation"
description: "Stable function · Expressions"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Expressions](/generated/api/topics/expressions)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `parse_equation` | `parseEquation` | `parse_equation` | `parse_equation` | `ParseEquation` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
parse_equation(src::AbstractString)
```

```julia
parse_equation(src::AbstractString) -> Equation
```

Parse `lhs = rhs` into an [`Equation`](/generated/api/ref/equation). The top-level separator is a LONE
`=`; `==` (and `>=`/`<=`/`!=`) remain comparison operators within either side,
and a template binding's `=` inside `name<…>` is not a separator either.

Throws [`ExpressionParseError`](/generated/api/ref/expression_parse_error) when there is no top-level lone `=`, or
when either side fails to parse.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/parse_expression_text.jl#L1280)

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
function parseEquation(src: string): Equation
```

Parse `lhs = rhs` into an `Equation`. The top-level separator is a LONE
`=`; `==` (and `>=`/`<=`/`!=`) remain comparison operators within either side.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-ts/src/parse-expression.ts#L1083)

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
parse_equation(src: str) -> Equation
```

Parse `lhs = rhs` into an [`Equation`](/generated/api/ref/equation).

The top-level separator is a LONE `=`; `==` (and `>=` / `<=` / `!=`)
remain comparison operators within either side, and an `=` inside a template
application `name<k = v>`, a call's `axis=0`, an aggregate `key=` /
`join(a=b)` / `[semiring=…]` clause, or any bracketed group is not a
separator either.

**Raises**

- [`ExpressionParseError`](/generated/api/ref/expression_parse_error) — when there is no top-level lone `=`, or when
  either side fails to parse.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/parse_expression.py#L1078)

**Example** (`parse_equation`)

```python
eq = earthsci_ast.parse_equation("D(x, t) = -k * x")
assert isinstance(eq, Equation)
assert earthsci_ast.to_ascii(eq) == "D(x)/Dt = -k * x"
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/python/expressions.py#L24-L26">docs/api/examples/python/expressions.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn parse_equation(src: &str) -> Result<Equation, ExpressionParseError>
```

Parse `lhs = rhs` into an [`Equation`](/generated/api/ref/equation). The top-level separator is a LONE
`=`; `==` (and `>=`/`<=`/`!=`) remain comparison operators within either side.

**Errors**

Returns an [`ExpressionParseError`](/generated/api/ref/expression_parse_error) when there is no top-level lone `=`, or
when either side fails to parse.

**Examples**

```rust
use earthsci_ast::parse_equation;
use earthsci_ast::to_ascii;

let eq = parse_equation("D(x)/Dt = k * A - x")?;
assert_eq!(to_ascii(&eq.lhs), "D(x)/Dt");
assert_eq!(to_ascii(&eq.rhs), "k * A - x");
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/parse_expression.rs#L1619) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.parse_equation.html)

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
func ParseEquation(src string) (*Equation, error)
```

ParseEquation parses `lhs = rhs` into an Equation. The top-level separator is a LONE `=`; `==` (and `>=` / `<=` / `!=`) remain comparison operators within either side.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/parse_expression.go#L1434) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ParseEquation)

**Example** (`edit`)

```go
doc, err := esm.LoadPath(fixture("decay.esm"))
if err != nil {
	log.Fatal(err)
}

units, desc := "mol", "Amount decayed so far"
model := esm.AddVariable(doc.Models["Decay"], "decayed", esm.ModelVariable{
	Type: "unknown", Units: &units, Description: &desc,
})
eq, err := esm.ParseEquation("decayed = 100 - N")
if err != nil {
	log.Fatal(err)
}
model = esm.AddEquation(model, *eq)
doc.Models["Decay"] = model
fmt.Println(len(model.Equations), esm.Validate(doc).IsValid)

text, err := esm.ToJSON(doc)
if err != nil {
	log.Fatal(err)
}
fmt.Println(strings.Contains(text, `"decayed"`))

path := filepath.Join(dir, "decay-edited.esm")
if err := esm.WritePath(doc, path); err != nil {
	log.Fatal(err)
}
reread, err := esm.LoadPath(path)
if err != nil {
	log.Fatal(err)
}
fmt.Println(sortedKeys(reread.Models["Decay"].Variables))
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/go/edit_test.go#L23-L54">docs/api/examples/go/edit_test.go</a></p>

</div>

</div>
