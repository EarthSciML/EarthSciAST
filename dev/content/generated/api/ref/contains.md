---
title: "contains"
description: "Stable function · Expressions"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Expressions](/generated/api/topics/expressions)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | `contains` | `contains` | `contains` | `Contains` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this function.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function contains(expr: Expr, varName: string): boolean
```

Check if an expression contains a specific variable

**Parameters**

- `expr` — Expression to search
- `varName` — Variable name to look for

**Returns**

True if the variable appears in the expression

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/expression.ts#L89)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/typescript/expressions.ts#L16-L34">docs/api/examples/typescript/expressions.ts</a></p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
contains(expr: Expr, var_name: str) -> bool
```

Check if an expression contains a specific variable.

**Parameters**

- `expr` (`Expr`) — Expression to search in
- `var_name` (`str`) — Variable name to look for

**Returns**

- `bool` — True if variable is found, False otherwise

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/expression.py#L90)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn contains(expr: &Expr, var_name: &str) -> bool
```

Check if an expression contains a specific variable

**Arguments**

* `expr` - The expression to search
* `var_name` - The variable name to look for

**Returns**

* `true` if the variable is found, `false` otherwise

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/expression.rs#L47) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.contains.html)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/rust/expressions.rs#L36-L51">docs/api/examples/rust/expressions.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func Contains(expr Expression, varName string) bool
```

Contains checks if a specific variable appears anywhere in an expression.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/expression.go#L78) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#Contains)

</div>

</div>
