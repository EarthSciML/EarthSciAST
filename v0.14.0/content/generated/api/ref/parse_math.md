---
title: "parse_math"
description: "Stable function · Expressions"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Expressions](/generated/api/topics/expressions)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `parse_math` | `parseMath` | `parse_math` | `parse_math` | `ParseMath` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
parse_math(text::AbstractString, names, format::Symbol)
```

```julia
parse_math(text::AbstractString, names, format::Symbol)
```

Read one expression, or one equation, written as math under a set of declared
names: LaTeX for `:markdown` (Lean `Math.parseLatex`), Typst math for `:typst`
(`Math.parseTypst`). The inverse of [`print_math`](/generated/api/ref/print_math):
`parse_math(print_math(e, names, f), names, f)` is `e` in canonical form.

`text` is what a document display holds, without its delimiters. Text whose top
is `=` reads as an equation, an `OrderedDict` with `lhs` and `rhs`, as a display
does (`Source.eqSides`); any other text reads as an expression (a number, a name
or an operator node, decoded as [`parse_markdown`](/generated/api/ref/parse_markdown) decodes a document).
`names` (any collection of strings) plays the part of the variables a component
declares: it decides how a run of letters reads (in LaTeX, `RT` is the name `RT`
when it is declared, the product of `R` and `T` when they are). No template is
in scope.

Throws a [`ParseError`](/generated/api/ref/parse_error) whose `code` is `"removed_op"` when the math uses
an operator removed from the format (esm-spec §4.2), and `"parse_error"` for
any other text that is not math, and for one past a bound of the reader (nested
too deeply, or holding a number beyond the binary64 range).

```julia
parse_math("y = 2 k", ["k", "y"], :typst)
# OrderedDict("lhs" => "y", "rhs" => OrderedDict("args" => Any[2, "k"], "op" => "*"))
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/pkg/EarthSciAST.jl/src/document_format.jl#L143)

**Example** (`edit`)

```julia
doc = load_path(joinpath(FIXTURES, "decay.esm"))
model = doc.models["Decay"]

# Edits return a new Model; the original is left alone.
decayed = ModelVariable(
    UnknownVariable; default = 0.0, units = "mol",
    description = "Amount that has decayed"
)
edited = add_variable(model, "decayed", decayed)
# The new equation, read from Typst math under the names it uses.
eq = parse_math("(dif italic(\"decayed\"))/(dif t) = lambda N", ["decayed", "lambda", "N"], :typst)
edited = add_equation(edited, Equation(expression_from_json(eq["lhs"]), expression_from_json(eq["rhs"])))
@assert ode_states(model) == ["N"]
@assert ode_states(edited) == ["N", "decayed"]

doc.models["Decay"] = edited
@assert validate(doc).is_valid

json = to_json(doc)
@assert occursin("\"decayed\"", json)

path = joinpath(mktempdir(), "decay_edited.esm")
write_path(doc, path)
reloaded = load_path(path)
@assert sort(ode_states(reloaded.models["Decay"])) == ["N", "decayed"]
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/docs/api/examples/julia/editing.jl#L7-L31">docs/api/examples/julia/editing.jl</a></p>

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/docs/api/examples/julia/expressions.jl#L5-L28">docs/api/examples/julia/expressions.jl</a></p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function parseMath(text: string, names: readonly string[], format: DocumentFormat, options?: ParseDocumentOptions): unknown
```

Read one expression, or one equation, written as math under a set of
declared names: LaTeX for `'markdown'` (`Math.parseLatex`), Typst math for
`'typst'` (`Math.parseTypst`). The inverse of [`printMath`](/generated/api/ref/print_math):
`parseMath(printMath(e, names, f), names, f)` is `e` in canonical form.

`text` is what a document display holds, without its delimiters. Text whose
top is `=` reads as an equation, an object with `lhs` and `rhs`, as a display
does (`Source.eqSides`); any other text reads as an expression. `names` plays
the part of the variables a component declares: it decides how a run of
letters reads (in LaTeX, `RT` is the name `RT` when it is declared, the
product of `R` and `T` when they are). No template is in scope. Numbers come
back as the document readers give them (see [`ParseDocumentOptions`](/generated/api/extension/typescript#x-parsedocumentoptions)).

**Throws**

- [`EsmDiagnosticError`](/generated/api/extension/typescript#x-esmdiagnosticerror) — with code `removed_op` when the math uses an
    operator removed from the format (esm-spec §4.2), and `parse_error` for any
    other text that is not math, and for one past a bound of the reader
    (`limits.ts`): nested too deeply, or holding a number beyond the binary64
    range.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/pkg/earthsci-ast-ts/src/document/index.ts#L180)

**Example** (`edit`)

```typescript
const doc = loadPath(fixture('decay.esm'))
const model = doc.models!.Decay
assert.ok(!('ref' in model)) // narrows away an unresolved `{ ref }` mount

// Edits never mutate: each returns a new model.
const withVar = addVariable(model, 'fraction', {
  type: 'unknown',
  units: '1',
  description: 'Fraction of the initial amount remaining',
})
// The new equation, read from Typst math under the names it uses.
const fraction = parseMath('fraction = N/100', ['fraction', 'N'], 'typst') as Equation
const edited = addEquation(withVar, fraction)
assert.equal(model.equations.length, 2)
assert.equal(edited.equations.length, 3)
assert.deepEqual(observedUnknowns(edited), ['fraction', 'half_life'])

const newDoc = { ...doc, models: { ...doc.models, Decay: edited } }

// `toJson` returns the text; `writePath` writes it and returns nothing.
const json = toJson(newDoc)
const reloaded = loadString(json).models!.Decay
assert.match(json, /"fraction"/)

const outPath = join(outDir, 'decay_edited.esm')
writePath(newDoc, outPath)
assert.equal(readFileSync(outPath, 'utf8'), json)
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/docs/api/examples/typescript/edit.ts#L23-L50">docs/api/examples/typescript/edit.ts</a></p>

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/docs/api/examples/typescript/expressions.ts#L15-L42">docs/api/examples/typescript/expressions.ts</a></p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
parse_math(text: str, names: Iterable[str], format: DocumentFormat | str) -> Any
```

Read one expression, or one equation, written as math under a set of
declared names: LaTeX for `"markdown"` (`Math.parseLatex`), Typst math
for `"typst"` (`Math.parseTypst`). The inverse of [`print_math`](/generated/api/ref/print_math):
`parse_math(print_math(e, names, f), names, f)` is `e` in canonical form.

`text` is what a document display holds, without its delimiters. Text whose
top is `=` reads as an equation, a dict with `lhs` and `rhs`, as a
display does (`Source.eqSides`); any other text reads as an expression (a
number, a name or an operator node, in canonical form). `names` plays the
part of the variables a component declares: it decides how a run of letters
reads (in LaTeX, `RT` is the name `RT` when it is declared, the product
of `R` and `T` when they are). No template is in scope.

Raises `ParseError` whose `code` is
`removed_op` when the math uses an operator removed from the format (spec
§4.2), and `parse_error` for any other text that is not math, and for one
past a bound of the reader (`.limits`): nested too deeply, or holding a
number beyond the binary64 range.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/pkg/earthsci-ast-py/src/earthsci_ast/document/__init__.py#L250)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/docs/api/examples/python/expressions.py#L23-L37">docs/api/examples/python/expressions.py</a></p>

**Example** (`parse_math_error`)

```python
try:
    earthsci_ast.parse_math(r"k \left(T - ", ["k", "T"], "markdown")
except ParseError as exc:
    print("parse error:", exc)
    assert exc.code == "parse_error"
else:
    raise AssertionError("an unbalanced parenthesis should not parse")
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/docs/api/examples/python/expressions.py#L57-L63">docs/api/examples/python/expressions.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn parse_math(text: &str, names: &[String], format: DocumentFormat) -> Result<Value, MathError>
```

Read one expression, or one equation, written as math under a set of
declared names: LaTeX for `DocumentFormat::Markdown` (`Math.parseLatex`),
Typst math for `DocumentFormat::Typst` (`Math.parseTypst`). The inverse
of [`print_math`](/generated/api/ref/print_math): `parse_math(&print_math(e, names, f), names, f)` is `e`
in canonical form.

`text` is what a document display holds, without its delimiters. Text
whose top is `=` reads as an equation, an object with `lhs` and `rhs`, as
a display does (`Source.eqSides`); any other text reads as an expression.
`names` plays the part of the variables a component declares: it decides
how a run of letters reads (in LaTeX, `RT` is the name `RT` when it is
declared, the product of `R` and `T` when they are). No template is in
scope.

**Errors**

A [`MathError`](/generated/api/extension/rust#x-matherror) with code `removed_op` when the math uses an operator
removed from the format (spec §4.2), and `parse_error` for any other text
that is not math, with where in the text reading went wrong, and for one
past a bound of the Rust reader (`limits`): nested too deeply, or
holding a number beyond the binary64 range.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/pkg/earthsci-ast-rs/src/document/mod.rs#L196) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.parse_math.html)

**Example** (`edit`)

```rust
let mut doc = load_path(fixture("decay.esm"))?;
let model = &doc.models.as_ref().unwrap()["Decay"];

// Track the decay product M. Edits return a new model; the input is
// left unchanged.
let product = ModelVariable {
    var_type: VariableType::Unknown,
    units: Some("mol".to_string()),
    default: Some(0.0.into()),
    description: Some("Amount produced".to_string()),
    default_units: None,
    element_type: None,
    shape: None,
    location: None,
    distribution: None,
    update: None,
    lb: None,
    ub: None,
};
let model = add_variable(model, "M", product)?;
// The new equation, read from Typst math under the names it uses.
let names = ["M", "N", "lambda"].map(String::from);
let eq = parse_math("(dif M)/(dif t) = lambda N", &names, DocumentFormat::Typst)?;
let model = add_equation(&model, serde_json::from_value::<Equation>(eq)?)?;
assert_eq!(model.variables.len(), 4);
assert_eq!(model.equations.len(), 3);

// Adding a name that is already declared is an error.
assert!(add_variable(&model, "N", model.variables["N"].clone()).is_err());

doc.models.as_mut().unwrap().insert("Decay".to_string(), model);

let json = to_json(&doc)?;
assert!(json.contains("\"M\""));

let out = std::env::temp_dir().join("decay_with_product.esm");
write_path(&doc, &out)?;
let reread = load_string(&std::fs::read_to_string(&out)?)?;
assert_eq!(reread.models.as_ref().unwrap()["Decay"].variables.len(), 4);
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/docs/api/examples/rust/edit.rs#L12-L50">docs/api/examples/rust/edit.rs</a></p>

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/docs/api/examples/rust/expressions.rs#L21-L44">docs/api/examples/rust/expressions.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func ParseMath(text string, names []string, format DocumentFormat) (any, error)
```

ParseMath reads one expression, or one equation, written as math under a set of declared names: LaTeX for DocumentMarkdown (Lean `Math.parseLatex`), Typst math for DocumentTypst (`Math.parseTypst`). It is the inverse of PrintMath: ParseMath(PrintMath(e, names, f), names, f) is e in canonical form (CanonicalizeDocument), the value PrintMath takes.

text is what a document display holds, without its delimiters. Text whose top is `=` reads as an equation, a map with `lhs` and `rhs`, as a display does (`Source.eqSides`); any other text reads as an expression. names plays the part of the variables a component declares: it decides how a run of letters reads (in LaTeX, `RT` is the name `RT` when it is declared, the product of `R` and `T` when they are). No template is in scope.

A text that is not math returns a \*DocumentFormatError with code `removed_op` when it uses an operator removed from the format (esm-spec §4.2), and `parse_error` for any other text, and for one past a bound of the reader, as ParseMarkdown: nested too deeply, or holding a number beyond the binary64 range.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/pkg/earthsci-ast-go/pkg/esm/document_format.go#L157) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ParseMath)

**Example** (`edit`)

```go
doc, err := esm.LoadPath(fixture("decay.esm"))
if err != nil {
	log.Fatal(err)
}

units, desc := "mol", "Amount decayed so far"
model := esm.AddVariable(doc.Models["Decay"], "decayed", esm.ModelVariable{
	Type: "unknown", Units: &units, Description: &desc,
})
// Typst math under the names it uses; an `=` at the top makes it an
// equation, a map with `lhs` and `rhs`.
read, err := esm.ParseMath("decayed = 100 - N", []string{"decayed", "N"}, esm.DocumentTypst)
if err != nil {
	log.Fatal(err)
}
sides := read.(map[string]any)
model = esm.AddEquation(model, esm.Equation{LHS: sides["lhs"], RHS: sides["rhs"]})
doc.Models["Decay"] = model
fmt.Println(len(model.Equations), esm.Validate(doc).IsValid)

text, err := esm.ToJSON(doc)
if err != nil {
	log.Fatal(err)
}
fmt.Println(strings.Contains(text, `"decayed"`))

path := filepath.Join(dir, "decay-edited.esm")
if err := esm.WritePath(doc, path); err != nil {
	log.Fatal(err)
}
reread, err := esm.LoadPath(path)
if err != nil {
	log.Fatal(err)
}
fmt.Println(sortedKeys(reread.Models["Decay"].Variables))
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/docs/api/examples/go/edit_test.go#L23-L57">docs/api/examples/go/edit_test.go</a></p>

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/docs/api/examples/go/expressions_test.go#L16-L55">docs/api/examples/go/expressions_test.go</a></p>

</div>

</div>
