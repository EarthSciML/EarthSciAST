---
title: "print_math"
description: "Stable function · Display"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Display](/generated/api/topics/display)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `print_math` | `printMath` | `print_math` | `print_math` | `PrintMath` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
print_math(expr, names, format::Symbol)
```

```julia
print_math(expr, names, format::Symbol) -> String
```

Print one expression, or one equation, as math under a set of declared names:
LaTeX for `:markdown` (Lean `Math.printLatex`), Typst math for `:typst`
(`Math.printTypst`).

`expr` is a decoded ESM expression (a number, a name or an operator node) or an
equation, an object with `lhs` and `rhs` (other fields, such as `_comment`, are
not printed), which prints as its two sides around `=` as in a document
(`Source.eqExpr`). A typed [`ASTExpr`](/generated/api/extension/julia#x-astexpr) or [`Equation`](/generated/api/ref/equation) is printed
through its serialized form. `names` (any collection of strings) plays the part of the
variables a component declares: a name in it prints in its declared shape, and
the printer avoids spellings that would collide with it. The result is what a
document display holds, without its delimiters; it is meant for showing one
expression outside a document, so no template is in scope.

```julia
julia> print_math(Dict("lhs" => "y", "rhs" => Dict("op" => "+", "args" => ["a", "T"])), ["a", "T", "y"], :typst)
"y = a + T"
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/document_format.jl#L60)

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
function printMath(expr: unknown, names: readonly string[], format: DocumentFormat): string
```

Print one expression, or one equation, as math under a set of declared names:
LaTeX for `'markdown'` (`Math.printLatex`), Typst math for `'typst'`
(`Math.printTypst`).

`expr` is an ESM expression (a number, a name or an operator node) or an
equation, an object with `lhs` and `rhs` (other fields, such as `_comment`,
are not printed), which prints as its two sides around `=` as in a document.
`names` plays the part of the variables a component declares: a name in it
prints in its declared shape, and the printer avoids spellings that would
collide with it. The result is what a document display holds, without its
delimiters; no template is in scope.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/earthsci-ast-ts/src/document/index.ts#L116)

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

**Example** (`flatten`)

```typescript
const doc = loadPath(fixture('coupled.esm'))
const flat = flatten(doc)

// Variables are namespaced by the system that declared them.
assert.deepEqual(Object.keys(flat.stateVariables), ['Heater.T', 'Box.T_air'])
assert.deepEqual(Object.keys(flat.parameters), ['Heater.rate', 'Box.k'])
assert.equal(flat.stateVariables['Box.T_air'].units, 'K')

// The `param_to_var` variable_map replaces the box's wall-temperature
// parameter with the heater's temperature: `Box.T_wall` is gone from the
// parameters above, and the box equation reads `Heater.T` in its place.
// LaTeX prints the dotted names more readably than Typst does.
const equations = flat.equations.map((eq) => {
  const sides = { lhs: eq.lhs, rhs: eq.rhs }
  return printMath(sides, expressionNames(sides), 'markdown')
})
assert.deepEqual(equations, [
  '\\frac{\\mathrm{d} \\mathit{Heater}.T}{\\mathrm{d} t} = \\mathit{Heater}.\\mathit{rate}',
  '\\frac{\\mathrm{d} \\mathit{Box}.T_{\\mathrm{air}}}{\\mathrm{d} t} = ' +
    '\\mathit{Box}.k \\left(\\mathit{Heater}.T - \\mathit{Box}.T_{\\mathrm{air}}\\right)',
])
assert.deepEqual(
  flat.equations.map((eq) => eq.sourceSystem),
  ['Heater', 'Box'],
)
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/docs/api/examples/typescript/flatten.ts#L9-L33">docs/api/examples/typescript/flatten.ts</a></p>

**Example** (`inspect`)

```typescript
const doc = loadPath(fixture('decay.esm'))
assert.deepEqual(Object.keys(doc.models ?? {}), ['Decay'])
const model = doc.models!.Decay
assert.ok(!('ref' in model)) // narrows away an unresolved `{ ref }` mount

// The document declares only `unknown` and `parameter`; everything else is derived.
assert.deepEqual(Object.keys(model.variables), ['N', 'lambda', 'half_life'])
assert.deepEqual(unknowns(model), ['N', 'half_life'])
assert.deepEqual(parameters(model), ['lambda'])

// N has a time derivative; half_life is defined by an explicit equation.
assert.deepEqual(odeStates(model), ['N'])
assert.deepEqual(observedUnknowns(model), ['half_life'])
assert.deepEqual(algebraicUnknowns(model), [])
assert.equal(isOdeState(model, 'N'), true)
assert.deepEqual(constantParameters(model), ['lambda'])
assert.equal(systemKind(model), 'ode')

// Each observed's defining expression:
const defs = observedDefinitions(model)
const halfLife = defs.get('half_life')!
assert.equal(printMath(halfLife, expressionNames(halfLife), 'typst'), 'ln(2)/lambda')
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/docs/api/examples/typescript/inspect.ts#L22-L43">docs/api/examples/typescript/inspect.ts</a></p>

**Example** (`reactions`)

```typescript
const doc = loadPath(fixture('ozone.esm'))
const system = doc.reaction_systems!.Ozone
assert.ok(!('ref' in system)) // narrows away an unresolved `{ ref }` mount

// Mass-action kinetics: one ODE per species.
const odes = deriveOdes(system)
assert.deepEqual(odeStates(odes).sort(), ['NO', 'NO2', 'O3'])
// Printed as LaTeX, which spells chemical names more readably than Typst does.
assert.deepEqual(
  odes.equations.map((eq) => printMath(eq, expressionNames(eq), 'markdown')),
  [
    '\\frac{\\mathrm{d} \\mathrm{O_{3}}}{\\mathrm{d} t} = ' +
      '-1 \\left(\\mathit{k1} \\mathrm{NO} \\mathrm{O_{3}}\\right) + \\mathit{jNO2} \\mathrm{NO_{2}}',
    '\\frac{\\mathrm{d} \\mathrm{NO}}{\\mathrm{d} t} = ' +
      '-1 \\left(\\mathit{k1} \\mathrm{NO} \\mathrm{O_{3}}\\right) + \\mathit{jNO2} \\mathrm{NO_{2}}',
    '\\frac{\\mathrm{d} \\mathrm{NO_{2}}}{\\mathrm{d} t} = ' +
      '\\mathit{k1} \\mathrm{NO} \\mathrm{O_{3}} + -1 \\left(\\mathit{jNO2} \\mathrm{NO_{2}}\\right)',
  ],
)

// Net stoichiometry: rows are species, columns are reactions.
const { matrix, species, reactions } = stoichiometricMatrix(system)
assert.deepEqual(species, ['O3', 'NO', 'NO2'])
assert.deepEqual(reactions, ['R1', 'R2'])
assert.deepEqual(matrix, [
  [-1, 1],
  [-1, 1],
  [1, -1],
])
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/docs/api/examples/typescript/reactions.ts#L9-L37">docs/api/examples/typescript/reactions.ts</a></p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
print_math(expr: Any, names: Iterable[str], format: DocumentFormat | str) -> str
```

Print one expression, or one equation, as math under a set of declared
names: LaTeX for `"markdown"` (`Math.printLatex`), Typst math for
`"typst"` (`Math.printTypst`).

`expr` is an ESM expression (a number, a name or an operator node) or an
equation, a dict with `lhs` and `rhs` (other fields, such as
`_comment`, are not printed), which prints as its two sides around `=`
as in a document (`Source.eqExpr`). `names` plays the part of the
variables a component declares: a name in it prints in its declared shape,
and the printer avoids spellings that would collide with it. The result is
what a document display holds, without its delimiters; it is meant for
showing one expression outside a document, so no template is in scope.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/earthsci-ast-py/src/earthsci_ast/document/__init__.py#L133)

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

**Example** (`parse_math`)

```python
# Math reads into the JSON form of an expression, under the names it uses:
# LaTeX with "markdown", Typst math with "typst". It is the inverse of print_math.
names = ["k", "T_wall", "T_air"]
latex = r"k \left(T_{\mathrm{wall}} - T_{\mathrm{air}}\right)"
read = earthsci_ast.parse_math(latex, names, "markdown")
assert read == {"op": "*", "args": ["k", {"op": "-", "args": ["T_wall", "T_air"]}]}
assert earthsci_ast.print_math(read, names, "markdown") == latex
print(earthsci_ast.print_math(read, names, "typst"))

# Text whose top is `=` reads as an equation.
eq = earthsci_ast.parse_math("(dif x)/(dif t) = -k x", ["x", "k"], "typst")
assert eq == {
    "lhs": {"op": "D", "args": ["x"], "wrt": "t"},
    "rhs": {"op": "-", "args": [{"op": "*", "args": ["k", "x"]}]},
}
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/docs/api/examples/python/expressions.py#L23-L37">docs/api/examples/python/expressions.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn print_math(expr: &Value, names: &[String], format: DocumentFormat) -> String
```

Print one expression, or one equation, as math under a set of declared
names: LaTeX for `DocumentFormat::Markdown` (`Math.printLatex`), Typst
math for `DocumentFormat::Typst` (`Math.printTypst`).

`expr` is an ESM expression (a number, a name or an operator node) or an
equation, an object with `lhs` and `rhs` (other fields, such as
`_comment`, are not printed), which prints as its two sides around `=` as
in a document (`Source.eqExpr`). `names` plays the part of
the variables a component declares: a name in it prints in its declared
shape, and the printer avoids spellings that would collide with it. The
result is what a document display holds, without its delimiters; it is
meant for showing one expression outside a document, so no template is in
scope.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/earthsci-ast-rs/src/document/mod.rs#L97) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.print_math.html)

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

**Example** (`flatten`)

```rust
let doc = load_path(fixture("coupled.esm"))?;
let flat = flatten(&doc)?;

// Every name is namespaced by its model.
let states: Vec<&String> = flat.state_variables.keys().collect();
let params: Vec<&String> = flat.parameters.keys().collect();
println!("states: {states:?}\nparameters: {params:?}");
assert_eq!(states, ["Heater.T", "Box.T_air"]);
assert!(flat.parameters.contains_key("Heater.rate") && flat.parameters.contains_key("Box.k"));

// The param_to_var coupling replaces the box's wall-temperature
// parameter Box.T_wall with the heater's state Heater.T: the parameter
// is gone, and the box's equation reads Heater.T instead.
assert!(!flat.parameters.contains_key("Box.T_wall"));
// LaTeX prints the dotted names more readably than Typst does.
let latex: Vec<String> = flat
    .equations
    .iter()
    .map(|eq| {
        let eq = serde_json::to_value(eq).unwrap();
        print_math(&eq, &expression_names(&eq), DocumentFormat::Markdown)
    })
    .collect();
for eq in &latex {
    println!("{eq}");
}
assert_eq!(latex.len(), 2);
assert_eq!(
    latex[1],
    r"\frac{\mathrm{d} \mathit{Box}.T_{\mathrm{air}}}{\mathrm{d} t} = \mathit{Box}.k \left(\mathit{Heater}.T - \mathit{Box}.T_{\mathrm{air}}\right)"
);
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/docs/api/examples/rust/flatten.rs#L8-L38">docs/api/examples/rust/flatten.rs</a></p>

**Example** (`reactions`)

```rust
let doc = load_path(fixture("ozone.esm"))?;
let system = &doc.reaction_systems.as_ref().unwrap()["Ozone"];

// derive_odes turns the reactions into an ordinary model: one
// differential equation per species, with mass-action rate laws.
let model = derive_odes(system)?;
// Print them as LaTeX, which spells chemical names more readably than
// Typst does.
let latex: Vec<String> = model
    .equations
    .iter()
    .map(|eq| {
        let eq = serde_json::to_value(eq).unwrap();
        print_math(&eq, &expression_names(&eq), DocumentFormat::Markdown)
    })
    .collect();
for eq in &latex {
    println!("{eq}");
}
let mut states = ode_states(&model);
states.sort();
assert_eq!(states, ["NO", "NO2", "O3"]);
assert_eq!(
    latex[2],
    r"\frac{\mathrm{d} \mathrm{NO_{2}}}{\mathrm{d} t} = \mathit{k1} \mathrm{NO} \mathrm{O_{3}} + -1 \left(\mathit{jNO2} \mathrm{NO_{2}}\right)"
);
assert_eq!(model.equations.len(), 3);
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/docs/api/examples/rust/reactions.rs#L11-L37">docs/api/examples/rust/reactions.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func PrintMath(expr any, names []string, f DocumentFormat) string
```

PrintMath prints one expression, or one equation, as math under a set of declared names: LaTeX for DocumentMarkdown (Lean `Math.printLatex`), Typst math for DocumentTypst (`Math.printTypst`).

expr is a decoded ESM expression (a number, a name or an operator node) or an equation, an object with `lhs` and `rhs` (other fields, such as `_comment`, are not printed), which prints as its two sides around `=` as in a document (`Source.eqExpr`). names plays the part of the variables a component declares: a name in it prints in its declared shape, and the printer avoids spellings that would collide with it. The result is what a document display holds, without its delimiters; it is meant for showing one expression outside a document, so no template is in scope.

expr may also be, or hold at any depth (an equation map whose `rhs` is an ExprNode), one of this package's typed values (an ExprNode, an Equation, a pointer to one), which prints as its JSON encoding does.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/earthsci-ast-go/pkg/esm/document_format.go#L102) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#PrintMath)

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

**Example** (`flatten`)

```go
doc, err := esm.LoadPath(fixture("coupled.esm"))
if err != nil {
	log.Fatal(err)
}
flat, err := esm.Flatten(doc)
if err != nil {
	log.Fatal(err)
}
for _, v := range flat.StateVariables {
	fmt.Println("state:", v.Name)
}
for _, v := range flat.Parameters {
	fmt.Println("parameter:", v.Name)
}
for _, eq := range flat.Equations {
	fmt.Println(eq.LHSString(), "=", eq.RHSString())
}
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/docs/api/examples/go/flatten_test.go#L14-L30">docs/api/examples/go/flatten_test.go</a></p>

**Example** (`inspect`)

```go
doc, err := esm.LoadPath(fixture("decay.esm"))
if err != nil {
	log.Fatal(err)
}
for _, name := range sortedKeys(doc.Models) {
	model := doc.Models[name]
	fmt.Println(name, sortedKeys(model.Variables))

	fmt.Println("ODE states:", esm.ODEStates(&model))
	fmt.Println("observed:", esm.ObservedUnknowns(&model))
	fmt.Println("algebraic:", esm.AlgebraicUnknowns(&model))
	fmt.Println("constant parameters:", esm.ConstantParameters(&model))

	fmt.Println(esm.IsODEState(&model, "N"), esm.IsODEState(&model, "half_life"))
	if def, ok := esm.ObservedDefinition(&model, "half_life"); ok {
		fmt.Println("half_life =", esm.PrintMath(def, esm.ExpressionNames(def), esm.DocumentTypst))
	}
}
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/docs/api/examples/go/inspect_test.go#L14-L31">docs/api/examples/go/inspect_test.go</a></p>

**Example** (`reactions`)

```go
doc, err := esm.LoadPath(fixture("ozone.esm"))
if err != nil {
	log.Fatal(err)
}
system := doc.ReactionSystems["Ozone"]
odes, err := esm.DeriveODEs(&system)
if err != nil {
	log.Fatal(err)
}
for _, eq := range odes.Equations {
	fmt.Println(esm.PrintMath(eq, esm.ExpressionNames(eq), esm.DocumentTypst))
}

// One row per species, one column per reaction.
fmt.Println(esm.StoichiometricMatrix(&system))
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/docs/api/examples/go/reactions_test.go#L13-L27">docs/api/examples/go/reactions_test.go</a></p>

</div>

</div>
