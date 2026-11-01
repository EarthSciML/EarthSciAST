---
title: "to_unicode"
description: "Stable function · Display"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Display](/generated/api/topics/display)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `to_unicode` | `toUnicode` | `to_unicode` | `to_unicode` | `ToUnicode` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
to_unicode(target)
to_unicode(::Nothing)
to_unicode(target::Real)
to_unicode(target::String)
to_unicode(target::ASTExpr)
to_unicode(target::Equation)
to_unicode(target::Model)
to_unicode(target::ReactionSystem)
to_unicode(target::EsmFile)
```

```julia
to_unicode(target) -> String
```

Format `target` as Unicode mathematical notation (`∂N/∂t = −λ·N`). Parallel
to [`to_ascii`](/generated/api/ref/to_ascii) and [`to_latex`](/generated/api/ref/to_latex) across the same domain —
`Nothing`, `Real`, `String`, `ASTExpr`, `Equation`, and the three containers
`Model` / `ReactionSystem` / `EsmFile` — following the cross-binding rendering
contract (tests/display/RENDERING_CONTRACT.md, API_SPEC.md §8 item 18).

A bare `String` is a variable or species name: Greek-letter names become their
symbols and chemical formulas get subscripts; `"Infinity"`, `"-Infinity"` and
`"NaN"` render as the non-finite numbers they name. A container has no
mathematical form, so all three renderers return the same plain-text summary,
such as `Model(3 variables, 2 equations)`. Any other type throws an
`ArgumentError`.

**Examples**
```julia
to_unicode(parse_equation("D(N) = -lambda * N"))  # "∂N/∂t = −λ·N"
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/display.jl#L1690)

**Example** (`display`)

```julia
decay_eq = model.equations[1]
println(to_unicode(decay_eq))
@assert to_unicode(decay_eq) == "∂N/∂t = (−λ)·N"
@assert to_latex(decay_eq) == raw"\frac{\partial N}{\partial t} = (-\lambda) \cdot N"
@assert to_ascii(decay_eq) == "D(N)/Dt = (-lambda) * N"

# Expressions display the same way.
@assert to_unicode(model.equations[2].rhs) == "ln(2)/λ"
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/docs/api/examples/julia/documents.jl#L72-L79">docs/api/examples/julia/documents.jl</a></p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function toUnicode(expr: Expr | Equation | Model | ReactionSystem | Reaction | EsmFile): string
```

Format an expression as Unicode mathematical notation

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-ts/src/pretty-print.ts#L900)

**Example** (`display`)

```typescript
const model = loadPath(fixture('decay.esm')).models!.Decay
const [decay, halfLife] = model.equations

assert.equal(toUnicode(decay), '∂N/∂t = (−λ)·N')
assert.equal(toLatex(decay), '\\frac{\\partial N}{\\partial t} = (-\\lambda) \\cdot N')
assert.equal(toAscii(decay), 'D(N)/Dt = (-lambda) * N')

// A single expression renders the same way.
assert.equal(toUnicode(halfLife.rhs), 'ln(2)/λ')

// So does a whole model: a summary line followed by its equations.
assert.equal(toUnicode(model).split('\n').length, 3)
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/docs/api/examples/typescript/display.ts#L9-L21">docs/api/examples/typescript/display.ts</a></p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
to_unicode(target: Expr | Equation | Model | ReactionSystem | EsmFile) -> str
```

Format target as Unicode mathematical notation with chemical subscripts.

**Parameters**

- `target` (`Expr | Equation | Model | ReactionSystem | EsmFile`) — Expression, equation, model, reaction system, or ESM file to format

**Returns**

- `str` — Unicode string representation

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/display.py#L831)

**Example** (`display`)

```python
decay_eq, half_life_eq = model.equations
print(earthsci_ast.to_unicode(decay_eq))
print(earthsci_ast.to_latex(decay_eq))
print(earthsci_ast.to_ascii(half_life_eq))
assert earthsci_ast.to_unicode(decay_eq) == "∂N/∂t = (−λ)·N"
assert earthsci_ast.to_latex(decay_eq) == r"\frac{\partial N}{\partial t} = (-\lambda) \cdot N"
assert earthsci_ast.to_ascii(half_life_eq) == "half_life = log(2) / lambda"

# A whole model renders as a one-line summary.
assert earthsci_ast.to_unicode(model) == "Model: Decay (1 state, 1 parameter, 1 observed, 2 equations)"
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/docs/api/examples/python/documents.py#L97-L106">docs/api/examples/python/documents.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn to_unicode<T: TextRenderable + ?Sized>(target: &T) -> String
```

Render `target` as Unicode mathematical notation.

Accepts the full display domain (API_SPEC.md §8 item 18): an [`Expr`](/generated/api/ref/expr), an
[`Equation`](/generated/api/ref/equation), or a [`Model`](/generated/api/ref/model) / [`ReactionSystem`](/generated/api/ref/reaction_system) / [`EsmFile`](/generated/api/ref/esm_file) summary.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/display.rs#L1736) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.to_unicode.html)

**Example** (`display`)

```rust
let doc = load_path(fixture("decay.esm"))?;
let model = &doc.models.as_ref().unwrap()["Decay"];
let decay = &model.equations[0];

let unicode = to_unicode(decay);
let latex = to_latex(decay);
let ascii = to_ascii(decay);
println!("{unicode}\n{latex}\n{ascii}");
assert_eq!(ascii, "D(N)/Dt = (-lambda) * N");
assert!(unicode.contains('λ'));
assert!(latex.contains("\\lambda"));

// The same functions take a single expression, or a whole model (which
// renders a summary).
assert_eq!(to_ascii(&model.equations[1].rhs), "log(2) / lambda");
assert!(to_unicode(model).contains("half_life"));
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/docs/api/examples/rust/display.rs#L8-L23">docs/api/examples/rust/display.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func ToUnicode(target Expression) string
```

ToUnicode converts an expression, equation or container to a Unicode string with chemical subscripts and operator precedence.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/display.go#L51) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ToUnicode)

**Example** (`display`)

```go
doc, err := esm.LoadPath(fixture("decay.esm"))
if err != nil {
	log.Fatal(err)
}
model := doc.Models["Decay"]
decay := model.Equations[0]
fmt.Println(esm.ToUnicode(decay))
fmt.Println(esm.ToLatex(decay))
fmt.Println(esm.ToASCII(decay))

// A single expression renders the same way.
fmt.Println(esm.ToUnicode(model.Equations[1].RHS))
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/docs/api/examples/go/display_test.go#L13-L24">docs/api/examples/go/display_test.go</a></p>

</div>

</div>
