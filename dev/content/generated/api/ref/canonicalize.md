---
title: "canonicalize"
description: "Stable function · Document I/O"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Document I/O](/generated/api/topics/document-io)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `canonicalize` | `canonicalize` | not exported | `canonicalize` | `Canonicalize` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
canonicalize(e::IntExpr)
canonicalize(e::NumExpr)
canonicalize(e::VarExpr)
canonicalize(e::OpExpr)
```

```julia
canonicalize(expr::ASTExpr) -> ASTExpr
```

Canonicalize an expression tree per discretization RFC §5.4. Returns a new
tree; the input is not mutated. Throws [`CanonicalizeError`](/generated/api/ref/canonicalize_error) for
NaN/Inf or `0/0`.

Field handling (cross-binding parity): like the TypeScript (`{...node}`),
Python (`dataclasses.replace`), and Rust (`node.clone()`) canonicalizers,
every `OpExpr` field is PRESERVED on the rebuilt node (via `reconstruct`),
and canonicalization recurses into `args` only — sub-expressions carried by
aggregate fields (`expr_body`, `filter`, `lower`/`upper`, `values`,
`table_axes`, …) pass through verbatim, exactly as in the other bindings.
RFC §5.4 pins rewrite rules only for the scalar arithmetic subset
(`+ * - / neg`); all other ops are structure-preserving pass-throughs.
Emission of such aggregate-carrying nodes is the restricted step — see
[`canonical_json`](/generated/api/ref/canonical_json).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/canonicalize.jl#L36)

**Example** (`canonicalize`)

```julia
# The canonical form orders commutative arguments and drops identities, so two
# spellings of the same expression compare equal.
a = canonicalize(parse_expression("b + a + 0"))
b = canonicalize(parse_expression("a + b"))
@assert to_ascii(a) == to_ascii(b) == "a + b"
@assert canonical_json(a) == canonical_json(b) == """{"args":["a","b"],"op":"+"}"""
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/julia/expressions.jl#L27-L32">docs/api/examples/julia/expressions.jl</a></p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function canonicalize(expr: Expr): Expr
```

Canonicalize an expression tree per RFC §5.4. Input is not mutated.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-ts/src/canonicalize.ts#L117)

**Example** (`canonicalize`)

```typescript
const a = parseExpression('b + a*2 + 0')
const b = parseExpression('0 + 2*a + b')

// Operands are ordered and identities dropped.
assert.equal(toAscii(canonicalize(a)), 'b + 2 * a')
assert.deepEqual(canonicalize(a), canonicalize(b))

// The canonical JSON text is a stable key for hashing or comparison.
assert.equal(canonicalJson(a), canonicalJson(b))
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/typescript/canonicalize.ts#L6-L14">docs/api/examples/typescript/canonicalize.ts</a></p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

<p class="api-absent">Python does not export this function.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn canonicalize(expr: &Expr) -> Result<Expr, CanonicalizeError>
```

Canonicalize an [`Expr`](/generated/api/ref/expr) tree per RFC §5.4. Returns a new tree; input is not mutated.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/canonicalize.rs#L45) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.canonicalize.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func Canonicalize(expr Expression) (Expression, error)
```

Canonicalize applies RFC §5.4 canonical form to an expression tree.

Returns ErrCanonicalNonFinite if the tree contains NaN or ±Inf, and ErrCanonicalDivByZero for 0/0. Input is not mutated; callers receive a new tree built from the same leaf values.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/canonicalize.go#L32) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#Canonicalize)

</div>

</div>
