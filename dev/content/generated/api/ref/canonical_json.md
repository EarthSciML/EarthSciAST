---
title: "canonical_json"
description: "Stable function · Document I/O"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Document I/O](/generated/api/topics/document-io)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `canonical_json` | `canonicalJson` | not exported | `canonical_json` | `CanonicalJSON` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
canonical_json(expr::ASTExpr)
```

```julia
canonical_json(expr::ASTExpr) -> String
```

Emit the canonical on-wire JSON form of an expression per RFC §5.4.6: keys
sorted, no extraneous whitespace, shortest round-trip floats with trailing-`.0`
disambiguation for integer-valued magnitudes, exponent-form (`1e25`, `5e-324`)
outside `[1e-6, 1e21)`, signed zero preserved.

Emissible node fields: every binding (TS/Python/Rust/Julia) serializes exactly
`op`, `args`, `wrt`, `dim`, `fn`, `name`, `value` — the field set the
cross-language canonical fixtures (`tests/conformance/canonical/`) pin.
A node carrying any OTHER set field (aggregate `expr_body`/`ranges`/
`output_idx`/`semiring`, `table`/`table_axes`/`output`, `join`/`filter`,
geometry `id`/`manifold`, …) has NO faithful canonical JSON in this format:
emitting only the pinned fields would make structurally-different aggregates
byte-identical (the defect class behind the `fn` bc-node bug). Rather than
emit ambiguous bytes — or diverge unilaterally from the other bindings by
emitting more fields — such nodes throw
`CanonicalizeError("E_CANONICAL_UNSUPPORTED_FIELD", …)`. The one in-package
caller (tree-walk CSE `_cse_key`) treats any `CanonicalizeError` as "decline
sharing", which is exactly the safe behavior.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/canonicalize.jl#L285)

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
function canonicalJson(expr: Expr): string
```

Emit canonical on-wire JSON per §5.4.6 (sorted keys, no whitespace).

FAIL-CLOSED (matching the Julia reference): `canonicalize` PRESERVES every
node field, then this validates the canonicalized tree and throws
`E_CANONICAL_UNSUPPORTED_FIELD` if any node carries an own key (with a defined
value) outside the emissible ∪ tolerated set. A node carrying a non-emissible
aggregate/geometry field has NO faithful canonical JSON — emitting only the
pinned fields would collapse structurally-different nodes to identical bytes.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-ts/src/canonicalize.ts#L149)

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
pub fn canonical_json(expr: &Expr) -> Result<String, CanonicalizeError>
```

Emit the canonical on-wire JSON form of an expression (§5.4.6).

Calls `canonicalize` first, then serializes with sorted keys, no extraneous
whitespace, and the strict number formatting of §5.4.6.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/canonicalize.rs#L63) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.canonical_json.html)

**Example** (`canonical_json`)

```rust
// Two spellings of the same sum serialize identically once canonicalized.
let a = canonical_json(&parse_expression("x + y + 1")?)?;
let b = canonical_json(&parse_expression("1 + y + x")?)?;
assert_eq!(a, b);
println!("{a}");
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/rust/expressions.rs#L55-L59">docs/api/examples/rust/expressions.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func CanonicalJSON(expr Expression) ([]byte, error)
```

CanonicalJSON emits the canonical on-wire JSON form of an expression per §5.4.6: keys sorted, no extraneous whitespace, shortest-round-trip float literals with trailing-`.0` disambiguation for integer-valued floats, and strict lowercase-e exponent notation without a leading `+`.

The input is canonicalized first; pass an already-canonical tree for a no-op canonicalization pass.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/canonicalize.go#L436) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CanonicalJSON)

</div>

</div>
