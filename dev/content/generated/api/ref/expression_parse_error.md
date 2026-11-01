---
title: "expression_parse_error"
description: "Stable error · Expressions"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** error · **Topic:** [Expressions](/generated/api/topics/expressions)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `ExpressionParseError` | `ExpressionParseError` | `ExpressionParseError` | `ExpressionParseError` | `ExpressionParseError` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct ExpressionParseError <: EarthSciASTError
ExpressionParseError(msg::String, pos::Int64)
ExpressionParseError(msg, pos)
```

```julia
ExpressionParseError(msg, pos)
```

Thrown when an expression string cannot be parsed by [`parse_expression`](/generated/api/ref/parse_expression)
or [`parse_equation`](/generated/api/ref/parse_equation).

- `msg`: human-readable diagnostic.
- `pos`: 0-based CHARACTER offset into the source where parsing failed
  (matching the `pos` field of the TypeScript reference implementation).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/parse_expression_text.jl#L60)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
class ExpressionParseError extends EsmDiagnosticError
new ExpressionParseError(message: string, pos: number): ExpressionParseError
```

Thrown when an expression string cannot be parsed.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/parse-expression.ts#L54)

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
class ExpressionParseError(EarthSciAstError, ValueError)
ExpressionParseError(message: str, pos: int)
```

Raised when an expression string cannot be parsed.

Subclasses `ValueError` as well as [`EarthSciAstError`](/generated/api/ref/earth_sci_ast_error),
matching the convention of `ParseError`, so callers
that `except ValueError` around an authoring call still catch it.

:ivar pos: 0-based character offset into the source where parsing failed.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/parse_expression.py#L86)

**Example** (`expression_parse_error`)

```python
try:
    earthsci_ast.parse_expression("k * (T_wall - ")
except earthsci_ast.ExpressionParseError as exc:
    print("parse error:", exc)
else:
    raise AssertionError("an unbalanced parenthesis should not parse")
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/python/expressions.py#L46-L51">docs/api/examples/python/expressions.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct ExpressionParseError {
    pub message: String,
    pub pos: usize,
}
```

Returned when an expression string cannot be parsed.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/parse_expression.rs#L50) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.ExpressionParseError.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type ExpressionParseError struct {
	Message string
	Pos     int
}

func (e *ExpressionParseError) Error() string
```

ExpressionParseError reports that an expression string could not be parsed. Pos is a 0-based RUNE offset into the source (not a byte offset — names such as `∂u_∂z` and `∇phi` are legal identifiers). Callers should match it with errors.As.

**Methods**

```go
func (e *ExpressionParseError) Error() string
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/parse_expression.go#L65) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ExpressionParseError)

</div>

</div>
