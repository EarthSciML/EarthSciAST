---
title: "substitute"
description: "Stable function · Expressions"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Expressions](/generated/api/topics/expressions)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `substitute` | `substitute` | `substitute` | `substitute` | `Substitute` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
substitute(expr::NumExpr, bindings::Dict{String, ASTExpr})
substitute(expr::IntExpr, bindings::Dict{String, ASTExpr})
substitute(expr::VarExpr, bindings::Dict{String, ASTExpr})
substitute(expr::OpExpr, bindings::Dict{String, ASTExpr})
```

```julia
substitute(expr::ASTExpr, bindings::Dict{String,ASTExpr})::ASTExpr
```

Replace every variable named in `bindings` with its replacement expression,
throughout `expr` (including faq bodies, filter predicates, integral bounds and
every other sub-expression a node carries). A variable not in `bindings` is
left unchanged. Substitution is single-pass: a replacement is inserted as is
and never substituted again. Returns a new expression; `expr` is not modified.

`bindings` must have value type `ASTExpr` exactly: a `Dict("x" => NumExpr(2.0))`
is a `Dict{String,NumExpr}` and has no method, so build it as
`Dict{String,ASTExpr}(...)`.

**Examples**
```julia
names = ["k", "k0", "T_wall", "T_air"]
e = expression_from_json(parse_math("k (T_(upright("wall")) - T_(upright("air")))", names, :typst))
bindings = Dict{String,ASTExpr}("T_wall" => NumExpr(300.5),
                                "k" => expression_from_json(parse_math("2 italic("k0")", names, :typst)))
substitute(e, bindings)  # shows as Typst math: (2 italic("k0")) (300.5 - T_(upright("air")))
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/expression.jl#L525)

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
function substitute(expr: Expr, bindings: Record<string, Expr>, context?: SubstitutionContext): Expr
```

Recursively substitute variable references in an expression with bound expressions.
Handles scoped references (Model.Subsystem.var) by splitting on '.' and matching
path through system hierarchy per format spec Section 4.3.

NOTE: when a `context` is supplied, any dotted reference NOT covered by
`bindings` is resolved through the file hierarchy and replaced with the
referenced variable's DECLARED DEFAULT VALUE. Callers that only want to
rename/replace bound names must omit `context`.

**Parameters**

- `expr` — Expression to substitute into
- `bindings` — Variable name to expression mappings
- `context` — Optional context; enables default-value inlining for
    scoped references (see note above)

**Returns**

New expression with substitutions applied (immutable)

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/earthsci-ast-ts/src/substitute.ts#L35)

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
substitute(expr: Expr, bindings: dict[str, Expr]) -> Expr
```

Recursively substitute variables in an expression with their bindings.

**Parameters**

- `expr` (`Expr`) — Expression to perform substitutions on
- `bindings` (`dict[str, Expr]`) — Dictionary mapping variable names to replacement expressions

**Returns**

- `Expr` — Expression with variables substituted

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/earthsci-ast-py/src/earthsci_ast/substitute.py#L48)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/docs/api/examples/python/expressions.py#L9-L18">docs/api/examples/python/expressions.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn substitute(expr: &Expr, substitutions: &HashMap<String, Expr>) -> Expr
```

Substitute variables in an expression, returning a new expression.

Traverses the full expression tree — including aggregate/faq bodies,
`filter` predicates, integral bounds and makearray `values` — and preserves
all operator-node metadata.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/earthsci-ast-rs/src/substitute.rs#L175) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.substitute.html)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/docs/api/examples/rust/expressions.rs#L21-L44">docs/api/examples/rust/expressions.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func Substitute(expr Expression, bindings map[string]Expression) (Expression, error)
```

Substitute performs variable substitution in expressions. expr: the expression to substitute into bindings: map from variable names to replacement expressions

Substitution is SINGLE-PASS (non-transitive), per the normative contract in CONFORMANCE\_SPEC.md §2.2.3 rule 1: a binding's replacement is inserted verbatim and is NOT itself re-substituted. Given {x -&gt; y, y -&gt; x}, substituting "x" yields "y". This is what guarantees termination for self-referential and mutually-referential binding sets without any cycle detection, and it is what makes a binding map usable as a simultaneous RENAME map (edit.go's renameRawExpr): {a -&gt; b, b -&gt; c} renames a to b, not to c.

The error return is retained for signature stability across the package's substitution family; single-pass substitution over a decoded expression has no failure mode of its own.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/earthsci-ast-go/pkg/esm/substitute.go#L24) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#Substitute)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/docs/api/examples/go/expressions_test.go#L16-L55">docs/api/examples/go/expressions_test.go</a></p>

</div>

</div>
