---
title: "expression_names"
description: "Stable function · Display"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Display](/generated/api/topics/display)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `expression_names` | `expressionNames` | `expression_names` | `expression_names` | `ExpressionNames` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
expression_names(expr)
```

```julia
expression_names(expr) -> Vector{String}
```

The variable names an expression or an equation uses, in order of first use:
its string leaves under `lhs`, `rhs` and `args`. These are the `names` to give
[`print_math`](/generated/api/ref/print_math) to show an expression on its own, with its names declared.

`expr` is a decoded ESM expression or equation (the value `print_math` takes),
or a typed [`ASTExpr`](/generated/api/extension/julia#x-astexpr) or [`Equation`](/generated/api/ref/equation).

```julia
julia> expression_names(Dict("lhs" => "y", "rhs" => Dict("op" => "*", "args" => ["k", "y"])))
2-element Vector{String}:
 "y"
 "k"
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/expression.jl#L1145)

**Example** (`display`)

```julia
# print_math takes an expression or equation in its JSON form, as in the
# decoded document, and the names it may use: a run of letters is one name
# only when it is declared.
decoded = JSON3.read(to_json(doc), Dict{String, Any})
decay_eq = decoded["models"]["Decay"]["equations"][1]
names = expression_names(decay_eq)
@assert names == ["N", "lambda"]
println(print_math(decay_eq, names, :markdown))
@assert print_math(decay_eq, names, :markdown) == raw"\frac{\mathrm{d} N}{\mathrm{d} t} = \left(-\lambda\right) N"
@assert print_math(decay_eq, names, :typst) == "(dif N)/(dif t) = (-lambda) N"

# `show` of a typed expression or equation is its Typst math.
@assert string(model.equations[1]) == "(dif N)/(dif t) = (-lambda) N"
@assert string(model.equations[2].rhs) == "ln(2)/lambda"
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/docs/api/examples/julia/documents.jl#L73-L86">docs/api/examples/julia/documents.jl</a></p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function expressionNames(expr: unknown): string[]
```

The variable names an expression or an equation uses, in order of first use:
its string leaves under `lhs`, `rhs` and `args`. These are the `names` to
give [`printMath`](/generated/api/ref/print_math) to show an expression on its own, with its names
declared.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/earthsci-ast-ts/src/document/index.ts#L138)

**Example** (`display`)

```typescript
const model = loadPath(fixture('decay.esm')).models!.Decay
const [decay, halfLife] = model.equations

// printMath takes an expression or equation and the names it may use: a run
// of letters is one name only when it is declared.
const names = expressionNames(decay)
assert.deepEqual(names, ['N', 'lambda'])
assert.equal(printMath(decay, names, 'markdown'), '\\frac{\\mathrm{d} N}{\\mathrm{d} t} = \\left(-\\lambda\\right) N')
assert.equal(printMath(decay, names, 'typst'), '(dif N)/(dif t) = (-lambda) N')

// A single expression prints the same way.
assert.equal(printMath(halfLife.rhs, expressionNames(halfLife.rhs), 'typst'), 'ln(2)/lambda')
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/docs/api/examples/typescript/display.ts#L9-L21">docs/api/examples/typescript/display.ts</a></p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
expression_names(expr: Any) -> list[str]
```

The variable names an expression or an equation uses, in order of first
use: its string leaves under `lhs`, `rhs` and `args`. These are the
`names` to give [`print_math`](/generated/api/ref/print_math) to show an expression on its own, with
its names declared.

`expr` is an expression or equation in its JSON form (a number, a str, a
list or a dict).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/earthsci-ast-py/src/earthsci_ast/document/__init__.py#L161)

**Example** (`display`)

```python
# print_math takes an expression or equation in its JSON form, as in the
# decoded document, and the names it may use: a run of letters is one name
# only when it is declared.
decoded = json.loads(earthsci_ast.to_json(doc))
decay_eq, half_life_eq = decoded["models"]["Decay"]["equations"]
names = earthsci_ast.expression_names(decay_eq)
assert names == ["N", "lambda"]
print(earthsci_ast.print_math(decay_eq, names, "markdown"))
print(earthsci_ast.print_math(decay_eq, names, "typst"))
assert earthsci_ast.print_math(decay_eq, names, "markdown") == (
    r"\frac{\mathrm{d} N}{\mathrm{d} t} = \left(-\lambda\right) N"
)
assert earthsci_ast.print_math(decay_eq, names, "typst") == "(dif N)/(dif t) = (-lambda) N"

# LaTeX spells a multi-letter name more readably than Typst does.
half_life_names = earthsci_ast.expression_names(half_life_eq)
assert earthsci_ast.print_math(half_life_eq, half_life_names, "markdown") == (
    r"\mathit{half\_life} = \frac{\ln(2)}{\lambda}"
)
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/docs/api/examples/python/documents.py#L97-L115">docs/api/examples/python/documents.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn expression_names(expr: &Value) -> Vec<String>
```

The variable names an expression or an equation uses, in order of first
use: its string leaves under `lhs`, `rhs` and `args`, and a reference's
`bindings` values. These are the
`names` to give [`print_math`](/generated/api/ref/print_math) to show an expression on its own, with its
names declared.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/earthsci-ast-rs/src/document/mod.rs#L128) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.expression_names.html)

**Example** (`display`)

```rust
let doc = load_path(fixture("decay.esm"))?;
let model = &doc.models.as_ref().unwrap()["Decay"];

// print_math takes the JSON form of an expression or equation, and the
// names it may use: a run of letters is one name only when declared.
let decay = serde_json::to_value(&model.equations[0])?;
let names = expression_names(&decay);
assert_eq!(names, ["N", "lambda"]);

let latex = print_math(&decay, &names, DocumentFormat::Markdown);
let typst = print_math(&decay, &names, DocumentFormat::Typst);
println!("{latex}\n{typst}");
assert_eq!(
    latex,
    r"\frac{\mathrm{d} N}{\mathrm{d} t} = \left(-\lambda\right) N"
);
assert_eq!(typst, "(dif N)/(dif t) = (-lambda) N");

// An expression prints the same way, and `Display` is its Typst math.
let rhs = &model.equations[1].rhs;
assert_eq!(rhs.to_string(), "ln(2)/lambda");
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/docs/api/examples/rust/display.rs#L8-L28">docs/api/examples/rust/display.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func ExpressionNames(expr any) []string
```

ExpressionNames returns the variable names an expression or an equation uses, in order of first use: its string leaves under `lhs`, `rhs` and `args`. These are the names to give PrintMath to show an expression on its own, with its names declared. expr is a decoded expression or equation, or one of this package's typed values (ExprNode, Equation, ...).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/earthsci-ast-go/pkg/esm/document_format.go#L112) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ExpressionNames)

**Example** (`display`)

```go
doc, err := esm.LoadPath(fixture("decay.esm"))
if err != nil {
	log.Fatal(err)
}
model := doc.Models["Decay"]
decay := model.Equations[0]
names := esm.ExpressionNames(decay)
fmt.Println(names)
fmt.Println(esm.PrintMath(decay, names, esm.DocumentMarkdown))
fmt.Println(esm.PrintMath(decay, names, esm.DocumentTypst))

// A single expression prints the same way.
rhs := model.Equations[1].RHS
fmt.Println(esm.PrintMath(rhs, esm.ExpressionNames(rhs), esm.DocumentTypst))
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/docs/api/examples/go/display_test.go#L13-L26">docs/api/examples/go/display_test.go</a></p>

</div>

</div>
