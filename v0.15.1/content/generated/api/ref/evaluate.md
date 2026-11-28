---
title: "evaluate"
description: "Stable function · Expressions"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Expressions](/generated/api/topics/expressions)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | not exported | `evaluate` | `evaluate` | `Evaluate` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this function.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this function.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
evaluate(expr: Expr, bindings: dict[str, float]) -> float
```

Evaluate a scalar AST expression against a dict of float variable bindings.

This is the official ESS Python runner entry point (the public API
imported as `from earthsci_ast import evaluate`). It wraps
`eval_expr` with an empty-state `EvalContext` so callers
don't need to construct one themselves.

`bindings` maps free-variable names to their numeric values. The
special key `"t"` supplies the simulation time (defaults to `0.0`
if absent). Returns the scalar result as a Python `float`.
Raises `NumpyInterpreterError` if any variable in `expr` is
not in `bindings`. The whole expression is walked first
(`refuse_unevaluable_operators`), so an operator this interpreter
cannot evaluate is refused before any of it is evaluated.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/earthsci-ast-py/src/earthsci_ast/numpy_interpreter.py#L5179)

**Example** (`evaluate`)

```python
line = ExprNode(op="+", args=[ExprNode(op="*", args=[2, "x"]), 1])
assert earthsci_ast.evaluate(line, {"x": 3.0}) == 7.0
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/docs/api/examples/python/expressions.py#L51-L52">docs/api/examples/python/expressions.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn evaluate(expr: &Expr, bindings: &HashMap<String, f64>) -> Result<f64, Vec<String>>
```

Evaluate a scalar AST expression against a map of float variable bindings.

This is the official ESS Rust runner entry point (the public API exported
as `earthsci_ast::evaluate`). The array runtime's per-cell oracle — the
binding's one interpreter — does the evaluation, so a single expression
means here exactly what it means inside a simulated model.

`bindings` maps free-variable names to their `f64` values. The special
key `"t"` supplies the simulation time (defaults to `0.0` if absent).
Returns `Ok(f64)` on success, or `Err(Vec<String>)` listing unbound
variable names if any variable in `expr` is missing from `bindings`, or
carrying the diagnostic (`unlowered_operator` / `unevaluable_operator`, with
the op named) for an operator this evaluator cannot evaluate — including the
array and tensor ops, which have no value over scalar bindings.
That check runs over the whole expression before any of it is evaluated
(esm-spec §9.6.6). Genuine MATH errors (division by zero, the log of a
non-positive number) are not errors: they come back as `NaN` or `±inf` in
the `Ok` branch, which is the answer.

An operator reference (`apply_operator`, esm-spec §9.6.4) names a
definition in a registry, and this function has none: an expression
holding one (any expression of a loaded document that calls a
definition) is refused as `unevaluable_operator`, naming the reference. Evaluate it
with [`evaluate_with_operators`](/generated/api/extension/rust#x-evaluate_with_operators), passing the registry it resolves
against: the component's (`crate::EsmFile::component_operators`) for an
expression of a loaded document, the flattened system's
(`crate::FlattenedSystem::operators`) for a flattened one.

**Examples**

```rust
use earthsci_ast::{Expr, evaluate};
use std::collections::HashMap;

let expr = Expr::Variable("x".to_string());
let mut bindings = HashMap::new();
bindings.insert("x".to_string(), 3.14_f64);
let result = evaluate(&expr, &bindings).unwrap();
assert!((result - 3.14).abs() < 1e-10);
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/earthsci-ast-rs/src/expression.rs#L175) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.evaluate.html)

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
func Evaluate(expr Expression, bindings map[string]float64) (float64, error)
```

Evaluate numerically evaluates an expression with variable bindings.

A boolean leaf reduces to the evaluator's float encoding (1.0 / 0.0), so a literal predicate such as `and(true, false)` is evaluable. A typed-nil \*ExprNode is reported as an error rather than dereferenced (no audit ID; found while fixing G3).

The whole expression is walked BEFORE any of it is evaluated (esm-spec §9.6.6): an operator this evaluator cannot evaluate is refused up front with `unlowered_operator` or `unevaluable_operator`, including one sitting in an `ifelse` branch that evaluation would not have taken.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/earthsci-ast-go/pkg/esm/expression.go#L584) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#Evaluate)

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
