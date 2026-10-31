---
title: "to_latex"
description: "Stable function · Display"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Display](/generated/api/topics/display)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `to_latex` | `toLatex` | `to_latex` | `to_latex` | `ToLatex` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
to_latex(target)
to_latex(::Nothing)
to_latex(target::Real)
to_latex(target::String)
to_latex(target::ASTExpr)
to_latex(target::Equation)
to_latex(target::Model)
to_latex(target::ReactionSystem)
to_latex(target::EsmFile)
```

```julia
to_latex(target) -> String
```

Format `target` as LaTeX mathematical notation
(`\frac{\partial N}{\partial t} = -\lambda \cdot N`). Accepts the same
domain as [`to_unicode`](/generated/api/ref/to_unicode) and [`to_ascii`](/generated/api/ref/to_ascii), with the same handling of
bare names, non-finite numbers and containers (a container renders as its
plain-text summary). Any other type throws an `ArgumentError`.

**Examples**
```julia
to_latex(parse_equation("D(N) = -lambda * N"))
# "\frac{\partial N}{\partial t} = -\lambda \cdot N"
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/display.jl#L1727)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/julia/documents.jl#L72-L79">docs/api/examples/julia/documents.jl</a></p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function toLatex(expr: Expr | Equation | Model | ReactionSystem | Reaction | EsmFile): string
```

Format an expression as LaTeX mathematical notation

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-ts/src/pretty-print.ts#L909)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/typescript/display.ts#L9-L21">docs/api/examples/typescript/display.ts</a></p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
to_latex(target: Expr | Equation | Model | ReactionSystem | EsmFile) -> str
```

Format target as LaTeX mathematical notation.

**Parameters**

- `target` (`Expr | Equation | Model | ReactionSystem | EsmFile`) — Expression, equation, model, reaction system, or ESM file to format

**Returns**

- `str` — LaTeX string representation

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/display.py#L844)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/python/documents.py#L97-L106">docs/api/examples/python/documents.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn to_latex<T: TextRenderable + ?Sized>(target: &T) -> String
```

Render `target` as LaTeX. See [`to_unicode`](/generated/api/ref/to_unicode) for the accepted domain.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/display.rs#L1741) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.to_latex.html)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/rust/display.rs#L8-L23">docs/api/examples/rust/display.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func ToLatex(target Expression) string
```

ToLatex converts an expression, equation or container to a LaTeX string with chemical subscripts and operator precedence.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/display.go#L57) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ToLatex)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/go/display_test.go#L13-L24">docs/api/examples/go/display_test.go</a></p>

</div>

</div>
