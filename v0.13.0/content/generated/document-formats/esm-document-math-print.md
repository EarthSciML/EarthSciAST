---
title: "The printer: expressions to tokens"
type: lean
lean_module: "Esm.Document.Math.Print"
weight: 13
---

<p class="lean-meta">Lean module <code>Esm.Document.Math.Print</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean"><code>formal/Esm/Document/Math/Print.lean</code></a> at <code>5af01ca9d41a</code><br>Imports <a href="/generated/document-formats/esm-document-math-surface"><code>Esm.Document.Math.Surface</code></a></p>

`pa c L e` prints the expression `e` for a position that needs precedence level at
least `L`, adding grouping parentheses when `e`'s own level is lower. The levels,
loosest first (spec §4.1.1, [`Notation.precedence`](/generated/document-formats/esm-document-notation#Esm.Document.Notation.precedence)):

| level | construct |
|---|---|
| 1 | `or` chain |
| 2 | `and` chain |
| 3 | a comparison |
| 4 | `+` chain, binary `-` |
| 5 | `*` chain (juxtaposition, `\cdot` before a factor that starts with a digit or sign), unary `-` |
| 6 | `not`; a derivative applied to a parenthesized operand |
| 7 | Typst fraction `a/b` and Typst `(dif N)/(dif t)`; a negative literal and a quantity (as the base of a power or an index they are parenthesized, and as a Typst fraction operand) |
| 8 | power |
| 9 | index (subscript or brackets) |
| 10 | atoms: names, numbers, groups, function forms, LaTeX fractions, cases, calls, escapes |

Operands of an n-ary chain are printed one level tighter, so a nested chain of the
same operator keeps its parentheses and the JSON tree is kept exactly (the parser
flattens a chain into one node). Binary `-` takes its left operand at its own level
(`a + b - c`), its right operand one tighter.

Which notation a node gets is decided from its exact JSON shape; anything without a
native or call notation prints in the generic escape form, which every node has.

## Text pieces

<div class="lean-decl" id="Esm.Document.Math.escSet">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.escSet" title="Esm.Document.Math.escSet"><code>escSet</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L40">source</a></div>

```lean
def escSet (c : Char) : Bool
```

The characters escaped by a backslash inside `\mathit{}`, `\operatorname{}`,
`\esm{}` and a name subscript's `\mathrm{}`.

</div>

<div class="lean-decl" id="Esm.Document.Math.escT">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.escT" title="Esm.Document.Math.escT"><code>escT</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L43-L45">source</a></div>

```lean
def escT : List Char → List Char
```

Escape the text of `\mathit{}` and the like.

</div>

<div class="lean-decl" id="Esm.Document.Math.unescT">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.unescT" title="Esm.Document.Math.unescT"><code>unescT</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L48-L51">source</a></div>

```lean
def unescT : List Char → List Char
```

Undo [`escT`](#Esm.Document.Math.escT).

</div>

<div class="lean-decl" id="Esm.Document.Math.keySpecial">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.keySpecial" title="Esm.Document.Math.keySpecial"><code>keySpecial</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L72-L73">source</a></div>

```lean
def keySpecial (c : Char) : Bool
```

Characters of a field key written as `{\char NNN}` (three decimal digits) in LaTeX:
they would end a Markdown math span (`$`), start a comment (`%`), be read as an alignment
tab (`&`), a macro parameter (`#`), a space (`~`), a superscript (`^`) or a control
sequence (`\`). With `_`, `{`, `}` written `\_`, `\{`, `\}`, a key is as safe inside
`\mathrm{}` as a JSON string value is (`Esm.Document.Math.Latex.quoteL`).

</div>

<div class="lean-decl" id="Esm.Document.Math.dig3">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.dig3" title="Esm.Document.Math.dig3"><code>dig3</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L76-L77">source</a></div>

```lean
def dig3 (n : Nat) : List Char
```

Three decimal digits.

</div>

<div class="lean-decl" id="Esm.Document.Math.escK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.escK" title="Esm.Document.Math.escK"><code>escK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L80-L84">source</a></div>

```lean
def escK : List Char → List Char
```

Escape a field key for `\mathrm{}`.

</div>

<div class="lean-decl" id="Esm.Document.Math.unescK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.unescK" title="Esm.Document.Math.unescK"><code>unescK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L87-L92">source</a></div>

```lean
def unescK : List Char → List Char
```

Undo [`escK`](#Esm.Document.Math.escK).

</div>

<div class="lean-decl" id="Esm.Document.Math.natChars">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.natChars" title="Esm.Document.Math.natChars"><code>natChars</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L115">source</a></div>

```lean
def natChars (n : Nat) : List Char
```

The digits of a natural number.

</div>

## The printing context

<div class="lean-decl" id="Esm.Document.Math.grp">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.grp" title="Esm.Document.Math.grp"><code>grp</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L124-L125">source</a></div>

```lean
def grp (sf : Sf) (ts : List Tok) : List Tok
```

Grouping parentheses.

</div>

<div class="lean-decl" id="Esm.Document.Math.rpG">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.rpG" title="Esm.Document.Math.rpG"><code>rpG</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L128">source</a></div>

```lean
def rpG (sf : Sf) : Tok
```

The closing token of a grouping parenthesis.

</div>

<div class="lean-decl" id="Esm.Document.Math.sepBy">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.sepBy" title="Esm.Document.Math.sepBy"><code>sepBy</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L131-L134">source</a></div>

```lean
def sepBy (sep : List Tok) : List (List Tok) → List Tok
```

Items joined by a separator.

</div>

## Names

<div class="lean-decl" id="Esm.Document.Math.baseTok">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.baseTok" title="Esm.Document.Math.baseTok"><code>baseTok</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L139-L142">source</a></div>

```lean
def baseTok (g : List Char) : Tok
```

A single letter or a Greek name as a token.

</div>

<div class="lean-decl" id="Esm.Document.Math.subTxt">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.subTxt" title="Esm.Document.Math.subTxt"><code>subTxt</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L145-L148">source</a></div>

```lean
def subTxt (sf : Sf) (r : List Char) : List Tok
```

The subscript text of a name: upright.

</div>

<div class="lean-decl" id="Esm.Document.Math.formulaRaw">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.formulaRaw" title="Esm.Document.Math.formulaRaw"><code>formulaRaw</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L151-L152">source</a></div>

```lean
def formulaRaw (g : List Char) : List Char
```

The raw `\mathrm{}` content of a formula: counts as `_{n}`.

</div>

<div class="lean-decl" id="Esm.Document.Math.formTok">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.formTok" title="Esm.Document.Math.formTok"><code>formTok</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L155-L158">source</a></div>

```lean
def formTok (sf : Sf) (g : List Char) : Tok
```

A formula name.

</div>

<div class="lean-decl" id="Esm.Document.Math.segToks">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.segToks" title="Esm.Document.Math.segToks"><code>segToks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L161-L165">source</a></div>

```lean
def segToks (sf : Sf) (g : List Char) : List Tok
```

One segment of a name, by its shape.

</div>

<div class="lean-decl" id="Esm.Document.Math.explicitName">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.explicitName" title="Esm.Document.Math.explicitName"><code>explicitName</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L170-L171">source</a></div>

```lean
def explicitName (S : Sym) (s : String) : Bool
```

A name never prints bare where the parser would read it otherwise: an undeclared
`e` (bare `e^{x}` reads as `exp`) and an undeclared `d` (bare `\frac{d N}{d t}` reads
as a derivative) print in the explicit form.

</div>

<div class="lean-decl" id="Esm.Document.Math.plainLast">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.plainLast" title="Esm.Document.Math.plainLast"><code>plainLast</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L179-L182">source</a></div>

```lean
def plainLast (s : String) : Bool
```

The last segment of a name prints with no subscript, so an index subscript may
follow it.

</div>

## JSON inside escape nodes (LaTeX)

## Operator tables

<div class="lean-decl" id="Esm.Document.Math.fnKw">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.fnKw" title="Esm.Document.Math.fnKw"><code>fnKw</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L216-L218">source</a></div>

```lean
def fnKw : List (String × Kw)
```

Unary functions with a native spelling, and their keyword.

</div>

<div class="lean-decl" id="Esm.Document.Math.cmpKw">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.cmpKw" title="Esm.Document.Math.cmpKw"><code>cmpKw</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L221-L222">source</a></div>

```lean
def cmpKw : List (String × Kw)
```

Comparisons and their token.

</div>

<div class="lean-decl" id="Esm.Document.Math.callOps">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.callOps" title="Esm.Document.Math.callOps"><code>callOps</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L225">source</a></div>

```lean
def callOps : List String
```

Core operators in the call form.

</div>

<div class="lean-decl" id="Esm.Document.Math.reservedOpn">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.reservedOpn" title="Esm.Document.Math.reservedOpn"><code>reservedOpn</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L228">source</a></div>

```lean
def reservedOpn : List String
```

Names `\operatorname{…}` never means a template or an open operator by.

</div>

<div class="lean-decl" id="Esm.Document.Math.coreOps">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.coreOps" title="Esm.Document.Math.coreOps"><code>coreOps</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L231-L239">source</a></div>

```lean
def coreOps : List String
```

`coreOpNames` of `Notation`.

</div>

<div class="lean-decl" id="Esm.Document.Math.opnOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.opnOK" title="Esm.Document.Math.opnOK"><code>opnOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L242-L245">source</a></div>

```lean
def opnOK (s : String) : Bool
```

A name `\operatorname{…}` can carry: identifier characters and dots.

</div>

<div class="lean-decl" id="Esm.Document.Math.keyOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.keyOK" title="Esm.Document.Math.keyOK"><code>keyOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L248">source</a></div>

```lean
def keyOK (s : String) : Bool
```

A field key printed upright in a call: an identifier.

</div>

<div class="lean-decl" id="Esm.Document.Math.insKV">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.insKV" title="Esm.Document.Math.insKV"><code>insKV</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L251-L253">source</a></div>

```lean
def insKV (kv : String × Json) : List (String × Json) → List (String × Json)
```

Sorted insertion by key.

</div>

<div class="lean-decl" id="Esm.Document.Math.fieldsOf">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.fieldsOf" title="Esm.Document.Math.fieldsOf"><code>fieldsOf</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L256-L257">source</a></div>

```lean
def fieldsOf (kvs : List (String × Json)) : List (String × Json)
```

The fields of a node other than `op` and `args`.

</div>

<div class="lean-decl" id="Esm.Document.Math.mkNode">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.mkNode" title="Esm.Document.Math.mkNode"><code>mkNode</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L260-L261">source</a></div>

```lean
def mkNode (o : String) (as : List Json) (fs : List (String × Json)) : Json
```

A node from its operator, operands and other fields (sorted keys).

</div>

<div class="lean-decl" id="Esm.Document.Math.node">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.node" title="Esm.Document.Math.node"><code>node</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L264">source</a></div>

```lean
def node (o : String) (as : List Json) : Json
```

The plain two-field node.

</div>

<div class="lean-decl" id="Esm.Document.Math.simpleTok">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.simpleTok" title="Esm.Document.Math.simpleTok"><code>simpleTok</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L273-L278">source</a></div>

```lean
def simpleTok : Tok → Bool
```

Typst exponent and subscript tokens that need no parentheses: a nonnegative number
in positional spelling, a letter, a Greek name.

</div>

<div class="lean-decl" id="Esm.Document.Math.tparams">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.tparams" title="Esm.Document.Math.tparams"><code>tparams</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L285-L286">source</a></div>

```lean
def tparams (S : Sym) (n : String) : Option (List String)
```

The template parameter list, when the symbol table knows it.

</div>

<div class="lean-decl" id="Esm.Document.Math.positional">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.positional" title="Esm.Document.Math.positional"><code>positional</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L290-L295">source</a></div>

```lean
def positional (S : Sym) (n : String) (bs : List (String × Json)) : Option (List String)
```

Positional template arguments: the table knows the parameters, they are distinct,
and the bindings bind exactly them.

</div>

<div class="lean-decl" id="Esm.Document.Math.rawB">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.rawB" title="Esm.Document.Math.rawB"><code>rawB</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L298-L304">source</a></div>

```lean
def rawB : Nat → List Char → Option (List Char × List Char)
```

Balanced text up to the `}` that closes depth 0; `\x` is one unit.

</div>

<div class="lean-decl" id="Esm.Document.Math.balOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.balOK" title="Esm.Document.Math.balOK"><code>balOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L308">source</a></div>

```lean
def balOK (raw : List Char) : Bool
```

Raw text that [`rawB`](#Esm.Document.Math.rawB) reads back whole (the LaTeX lexer reads `\mathrm{…}` and
`\text{…}` contents with [`rawB`](#Esm.Document.Math.rawB)).

</div>

<div class="lean-decl" id="Esm.Document.Math.factorsOf">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.factorsOf" title="Esm.Document.Math.factorsOf"><code>factorsOf</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L311-L314">source</a></div>

```lean
def factorsOf (u : String) : List Esm.Units.Factor
```

The two-sided factor list of a units string (`[]` when it does not parse).

</div>

<div class="lean-decl" id="Esm.Document.Math.unitsOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.unitsOK" title="Esm.Document.Math.unitsOK"><code>unitsOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L319-L325">source</a></div>

```lean
def unitsOK (sf : Sf) (u : String) : Bool
```

The units of a quantity print typeset when the string is the canonical spelling of
a non-dimensionless unit whose typeset form reads back (Phase 1: every canonical unit
does).

</div>

## The printer

<div class="lean-decl" id="Esm.Document.Math.wrap">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.wrap" title="Esm.Document.Math.wrap"><code>wrap</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L330-L331">source</a></div>

```lean
def wrap (sf : Sf) (L : Nat) (p : Nat × List Tok) : List Tok
```

Wrap a printed form for a position needing level `L`.

</div>

<div class="lean-decl" id="Esm.Document.Math.mulToks">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.mulToks" title="Esm.Document.Math.mulToks"><code>mulToks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L334-L336">source</a></div>

```lean
def mulToks : List (List Tok) → List Tok
```

A `*` chain: juxtaposition, `\cdot` before a factor that starts with a number.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.sizeOf_lt_arr">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.sizeOf_lt_arr" title="Esm.Document.Math.sizeOf_lt_arr"><code>sizeOf_lt_arr</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L339-L342">source</a></div>

```lean
theorem sizeOf_lt_arr {a : Json} {as : List Json} (h : a ∈ as) :
    sizeOf a < sizeOf (Json.arr as)
```

Size bookkeeping for the recursion.

</div>

<div class="lean-decl" id="Esm.Document.Math.OpK">
<div class="lean-decl-head"><span class="lean-kind">inductive</span> <a class="lean-name" href="#Esm.Document.Math.OpK" title="Esm.Document.Math.OpK"><code>OpK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L375-L378">source</a></div>

```lean
inductive OpK where
  | minus | div | pow | lnot | tru | fls | ite | ic | index
  | cmp (k : Kw) | un (k : Kw) | plus | times | land | lor | mm (k : Kw) | call | other
  deriving DecidableEq
```

How a plain node (`op` and `args` only) prints, by its operator.

</div>

<div class="lean-decl" id="Esm.Document.Math.unKw">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.unKw" title="Esm.Document.Math.unKw"><code>unKw</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L381-L382">source</a></div>

```lean
def unKw : List (String × Kw)
```

Unary functions with a native spelling: their keyword (`log10` is `\log_{10}`).

</div>

<div class="lean-decl" id="Esm.Document.Math.kindTable">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.kindTable" title="Esm.Document.Math.kindTable"><code>kindTable</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L385-L388">source</a></div>

```lean
def kindTable : List (String × OpK)
```

The plain-node operators with their own notation.

</div>

<div class="lean-decl" id="Esm.Document.Math.Out">
<div class="lean-decl-head"><span class="lean-kind">structure</span> <a class="lean-name" href="#Esm.Document.Math.Out" title="Esm.Document.Math.Out"><code>Out</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L400-L403">source</a></div>

```lean
structure Out where
  lvl : Nat
  toks : List Tok
  crow : List Tok
```

The printed form of an expression and its level. `crow` is the form as the last
rows of a `cases` block: an `ifelse` chain contributes its rows, anything else is the
`otherwise` row.

</div>

<div class="lean-decl" id="Esm.Document.Math.escToks">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.escToks" title="Esm.Document.Math.escToks"><code>escToks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L412-L418">source</a></div>

```lean
def escToks (sf : Sf) (o : String) (fs : List (String × Json)) (args : List (List Tok)) :
    List Tok
```

The escape form: LaTeX `\esm{op}{fields}{args}` with the fields as JSON, Typst
`esm.node("op", #(fields), args)`.

</div>

<div class="lean-decl" id="Esm.Document.Math.lpC">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.lpC" title="Esm.Document.Math.lpC"><code>lpC</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L421">source</a></div>

```lean
def lpC (_sf : Sf) : Tok
```

The call parenthesis `(` (LaTeX `(`, Typst `(` right after a name).

</div>

<div class="lean-decl" id="Esm.Document.Math.callToks">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.callToks" title="Esm.Document.Math.callToks"><code>callToks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L424-L425">source</a></div>

```lean
def callToks (sf : Sf) (head : List Tok) (args : List (List Tok)) : List Tok
```

A call: `name(args)` with call parentheses.

</div>

<div class="lean-decl" id="Esm.Document.Math.unToks">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.unToks" title="Esm.Document.Math.unToks"><code>unToks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L428-L436">source</a></div>

```lean
def unToks (sf : Sf) (k : Kw) (t : List Tok) : List Tok
```

A unary function applied to the printed operand `t`.

</div>

<div class="lean-decl" id="Esm.Document.Math.caseRow">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.caseRow" title="Esm.Document.Math.caseRow"><code>caseRow</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L439-L440">source</a></div>

```lean
def caseRow (sf : Sf) (v cnd : List Tok) : List Tok
```

One cases row, `value & \text{if } condition`, then the row break.

</div>

<div class="lean-decl" id="Esm.Document.Math.icTail">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.icTail" title="Esm.Document.Math.icTail"><code>icTail</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L448-L451">source</a></div>

```lean
def icTail (sf : Sf) : List Tok
```

`t_{0}` in an initial condition `N(t_{0})`.

</div>

<div class="lean-decl" id="Esm.Document.Math.subList">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.subList" title="Esm.Document.Math.subList"><code>subList</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L454-L460">source</a></div>

```lean
def subList (sf : Sf) (simp : Option Tok) (args : List (List Tok)) : List Tok
```

A subscript list: LaTeX `_{a, b}`; Typst `_a` for one simple token, else `_(a, b)`.

</div>

<div class="lean-decl" id="Esm.Document.Math.simpleE">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.simpleE" title="Esm.Document.Math.simpleE"><code>simpleE</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L465-L471">source</a></div>

```lean
def simpleE (c : Ctx) : Json → Option Tok
```

The one token a Typst exponent or subscript may be written as without
parentheses: a nonnegative number in positional spelling, or a one-letter or Greek
name.

</div>

<div class="lean-decl" id="Esm.Document.Math.subOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.subOK" title="Esm.Document.Math.subOK"><code>subOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L481-L489">source</a></div>

```lean
def subOK (S : Sym) (base : Json) (is : List Json) : Bool
```

The index prints with a subscript unless the base is not a plain name, or the
subscript would collide with a name: one formula-shaped name (it would read as the
upright subscript of a name), or one digit literal `n` when `base_n` is declared
(`k_{1}` would look like the name `k_1`; decision 5).

</div>

<div class="lean-decl" id="Esm.Document.Math.subPat4">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.subPat4" title="Esm.Document.Math.subPat4"><code>subPat4</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L492-L495">source</a></div>

```lean
def subPat4 (sf : Sf) : Tok → Tok → Tok → Tok → Bool
```

Four tokens of an upright name subscript.

</div>

<div class="lean-decl" id="Esm.Document.Math.subPat">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.subPat" title="Esm.Document.Math.subPat"><code>subPat</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L498-L500">source</a></div>

```lean
def subPat (sf : Sf) : List Tok → Bool
```

An upright name subscript: a name before it would read it as part of the name.

</div>

<div class="lean-decl" id="Esm.Document.Math.inlineD">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.inlineD" title="Esm.Document.Math.inlineD"><code>inlineD</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L504">source</a></div>

```lean
def inlineD (o : Out) : Bool
```

Derivative operand printed inline (`\frac{\mathrm{d} N}{\mathrm{d} t}`) when it is
postfix-level or tighter, and not a negative literal.

</div>

<div class="lean-decl" id="Esm.Document.Math.keyToks">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.keyToks" title="Esm.Document.Math.keyToks"><code>keyToks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L507-L510">source</a></div>

```lean
def keyToks (sf : Sf) (k : String) : List Tok
```

A field key, upright.

</div>

<div class="lean-decl" id="Esm.Document.Math.jsonVal">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.jsonVal" title="Esm.Document.Math.jsonVal"><code>jsonVal</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L513-L516">source</a></div>

```lean
def jsonVal (sf : Sf) (v : Json) : List Tok
```

A field value that is not an expression, as JSON.

</div>

<div class="lean-decl" id="Esm.Document.Math.openToks">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.openToks" title="Esm.Document.Math.openToks"><code>openToks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L519-L521">source</a></div>

```lean
def openToks (sf : Sf) (o : String) (args fields : List (List Tok)) : List Tok
```

The open-operator call: positional operands, then `;` and the fields.

</div>

<div class="lean-decl" id="Esm.Document.Math.dTime">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.dTime" title="Esm.Document.Math.dTime"><code>dTime</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L524-L535">source</a></div>

```lean
def dTime (sf : Sf) (a : Out) : Out
```

The time derivative.

</div>

<div class="lean-decl" id="Esm.Document.Math.dSpace">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.dSpace" title="Esm.Document.Math.dSpace"><code>dSpace</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L538-L549">source</a></div>

```lean
def dSpace (sf : Sf) (w : List Tok) (a : Out) : Out
```

The spatial derivative along the axis printed `w`.

</div>

<div class="lean-decl" id="Esm.Document.Math.dCall">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.dCall" title="Esm.Document.Math.dCall"><code>dCall</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L552-L555">source</a></div>

```lean
def dCall (sf : Sf) (w : List Tok) (args : List (List Tok)) : List Tok
```

A spatial derivative with trailing operands: `\operatorname{D}_{x}(u, a, b)`.

</div>

<div class="lean-decl" id="Esm.Document.Math.qtyToks">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.qtyToks" title="Esm.Document.Math.qtyToks"><code>qtyToks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L559">source</a></div>

```lean
def qtyToks (n : JNum) (l : List Esm.Units.Factor) : List Tok
```

The quantity `3\,\mathrm{m/s}` / `3 thin upright("m") thin upright("s")^(-1)`: the
number, then the unit as one token.

</div>

## Constant arrays

<div class="lean-decl" id="Esm.Document.Math.numsOf">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.numsOf" title="Esm.Document.Math.numsOf"><code>numsOf</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L564-L567">source</a></div>

```lean
def numsOf : List Json → Option (List JNum)
```

The entries of a list that are all well-formed numbers.

</div>

<div class="lean-decl" id="Esm.Document.Math.rowsOf">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.rowsOf" title="Esm.Document.Math.rowsOf"><code>rowsOf</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L570-L576">source</a></div>

```lean
def rowsOf : List Json → Option (List (List JNum))
```

The rows of a list of number lists.

</div>

<div class="lean-decl" id="Esm.Document.Math.AForm">
<div class="lean-decl-head"><span class="lean-kind">inductive</span> <a class="lean-name" href="#Esm.Document.Math.AForm" title="Esm.Document.Math.AForm"><code>AForm</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L579-L581">source</a></div>

```lean
inductive AForm where
  | col (ns : List JNum)
  | mat (rs : List (List JNum))
```

The two array shapes with a native spelling.

</div>

<div class="lean-decl" id="Esm.Document.Math.arrForm">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.arrForm" title="Esm.Document.Math.arrForm"><code>arrForm</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L586-L597">source</a></div>

```lean
def arrForm : Json → Option AForm
```

A constant array printed natively: a column for rank 1, or a matrix of at least
two columns (a single-column matrix would print like a column), at most 16 entries,
every entry a well-formed number.

</div>

<div class="lean-decl" id="Esm.Document.Math.arrToks">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.arrToks" title="Esm.Document.Math.arrToks"><code>arrToks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L606-L615">source</a></div>

```lean
def arrToks (sf : Sf) : AForm → List Tok
```

The array: LaTeX `bmatrix`, Typst `vec(…)` / `mat(…)`.

</div>

<div class="lean-decl" id="Esm.Document.Math.unitToks">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.unitToks" title="Esm.Document.Math.unitToks"><code>unitToks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L618">source</a></div>

```lean
def unitToks (l : List Esm.Units.Factor) : List Tok
```

The unit after a number or an array.

</div>

## Reductions (`faq`)

<div class="lean-decl" id="Esm.Document.Math.jbeq">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.jbeq" title="Esm.Document.Math.jbeq"><code>jbeq</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L624-L631">source</a></div>

```lean
def jbeq : Json → Json → Bool
```

Equality of JSON values as a check.

</div>

<div class="lean-decl" id="Esm.Document.Math.idxBase">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.idxBase" title="Esm.Document.Math.idxBase"><code>idxBase</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L645-L648">source</a></div>

```lean
def idxBase (kvs : List (String × Json)) : Option String
```

The array an `index` node reads, when it names one.

</div>

<div class="lean-decl" id="Esm.Document.Math.basesJ">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.basesJ" title="Esm.Document.Math.basesJ"><code>basesJ</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L652-L658">source</a></div>

```lean
def basesJ : Json → List String → List String
```

The arrays an expression indexes, in first-use order (appended to `acc`).

</div>

<div class="lean-decl" id="Esm.Document.Math.RedK">
<div class="lean-decl-head"><span class="lean-kind">inductive</span> <a class="lean-name" href="#Esm.Document.Math.RedK" title="Esm.Document.Math.RedK"><code>RedK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L672-L674">source</a></div>

```lean
inductive RedK where
  | sum | prod | max | min
  deriving DecidableEq
```

The reductions with a native spelling.

</div>

<div class="lean-decl" id="Esm.Document.Math.FaqForm">
<div class="lean-decl-head"><span class="lean-kind">structure</span> <a class="lean-name" href="#Esm.Document.Math.FaqForm" title="Esm.Document.Math.FaqForm"><code>FaqForm</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L687-L693">source</a></div>

```lean
structure FaqForm where
  red : RedK
  marked : Bool
  out : List Json
  ranges : List (String × Json)
  expr : Json
  filter : Option Json
```

A `faq` node with a native spelling, by its parts. `marked`: `args` lists the arrays
the body indexes (otherwise it is empty).

</div>

<div class="lean-decl" id="Esm.Document.Math.faqCand">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.faqCand" title="Esm.Document.Math.faqCand"><code>faqCand</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L702-L718">source</a></div>

```lean
def faqCand (kvs : List (String × Json)) : Option FaqForm
```

The parts a `faq` node would have.

</div>

<div class="lean-decl" id="Esm.Document.Math.faqForm">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.faqForm" title="Esm.Document.Math.faqForm"><code>faqForm</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L723-L726">source</a></div>

```lean
def faqForm (kvs : List (String × Json)) : Option FaqForm
```

The parts of a `faq` node, when it is exactly the node they rebuild: no semiring,
join, distinct or key, `reduce` absent or `*`, `max`, `min`, `ranges` absent or not
empty, `args` empty or the arrays the body indexes.

</div>

<div class="lean-decl" id="Esm.Document.Math.rangeOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.rangeOK" title="Esm.Document.Math.rangeOK"><code>rangeOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L729-L734">source</a></div>

```lean
def rangeOK : Json → Bool
```

A range a row can spell: `[a, b]`, `{"from": S}` or `{"from": S, "of": [i, …]}`.

</div>

<div class="lean-decl" id="Esm.Document.Math.outOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.outOK" title="Esm.Document.Math.outOK"><code>outOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L740-L744">source</a></div>

```lean
def outOK (j : Json) : Bool
```

An output entry: a name, or the singleton dimension `1`.

</div>

<div class="lean-decl" id="Esm.Document.Math.occursJ">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.occursJ" title="Esm.Document.Math.occursJ"><code>occursJ</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L748-L752">source</a></div>

```lean
def occursJ (k : String) : Json → Bool
```

A bare name occurs in an expression.

</div>

<div class="lean-decl" id="Esm.Document.Math.faqOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.faqOK" title="Esm.Document.Math.faqOK"><code>faqOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L764-L769">source</a></div>

```lean
def faqOK (F : FaqForm) : Bool
```

The conditions under which the native spelling reads back.

</div>

<div class="lean-decl" id="Esm.Document.Math.rowToks">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.rowToks" title="Esm.Document.Math.rowToks"><code>rowToks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L772-L779">source</a></div>

```lean
def rowToks (c : Ctx) (P : Json → Out) (kv : String × Json) : List Tok
```

A range row: `a \le k \le b`, `k \in S`, `k \in S(i, j)`.

</div>

<div class="lean-decl" id="Esm.Document.Math.redRanges">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.redRanges" title="Esm.Document.Math.redRanges"><code>redRanges</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L782-L783">source</a></div>

```lean
def redRanges (F : FaqForm) : List (String × Json)
```

The reduced ranges: those of indices that are not output indices.

</div>

<div class="lean-decl" id="Esm.Document.Math.subRows">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.subRows" title="Esm.Document.Math.subRows"><code>subRows</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L786-L787">source</a></div>

```lean
def subRows (c : Ctx) (P : Json → Out) (F : FaqForm) : List (List Tok)
```

The rows of the subscript: the reduced ranges, then the filter.

</div>

<div class="lean-decl" id="Esm.Document.Math.headToks">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.headToks" title="Esm.Document.Math.headToks"><code>headToks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L790-L793">source</a></div>

```lean
def headToks (sf : Sf) (F : FaqForm) : List Tok
```

The operator, marked when `args` is listed.

</div>

<div class="lean-decl" id="Esm.Document.Math.subToksL">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.subToksL" title="Esm.Document.Math.subToksL"><code>subToksL</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L796-L805">source</a></div>

```lean
def subToksL (c : Ctx) (P : Json → Out) (F : FaqForm) : List Tok
```

The LaTeX subscript: none, one row, a lone dense range `_{k=a}^{b}`, or `\substack`.

</div>

<div class="lean-decl" id="Esm.Document.Math.subToksT">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.subToksT" title="Esm.Document.Math.subToksT"><code>subToksT</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L808-L811">source</a></div>

```lean
def subToksT (c : Ctx) (P : Json → Out) (F : FaqForm) : List Tok
```

The Typst subscript: rows in `_( … )`, stacked with `\`.

</div>

<div class="lean-decl" id="Esm.Document.Math.redToks">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.redToks" title="Esm.Document.Math.redToks"><code>redToks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L819-L820">source</a></div>

```lean
def redToks (c : Ctx) (P : Json → Out) (F : FaqForm) : List Tok
```

The reduction: operator, subscript, body at level 5.

</div>

<div class="lean-decl" id="Esm.Document.Math.entryToks">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.entryToks" title="Esm.Document.Math.entryToks"><code>entryToks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L823-L829">source</a></div>

```lean
def entryToks (c : Ctx) (P : Json → Out) (F : FaqForm) (j : Json) : List Tok
```

An output entry: its range row when it has one.

</div>

<div class="lean-decl" id="Esm.Document.Math.faqOut">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.faqOut" title="Esm.Document.Math.faqOut"><code>faqOut</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L832-L839">source</a></div>

```lean
def faqOut (c : Ctx) (P : Json → Out) (F : FaqForm) : Out
```

The native `faq`: the reduction, wrapped with its output indices when it has some.

</div>

<div class="lean-decl" id="Esm.Document.Math.faqSubs">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.faqSubs" title="Esm.Document.Math.faqSubs"><code>faqSubs</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L842-L844">source</a></div>

```lean
def faqSubs (F : FaqForm) : List Json
```

The sub-expressions a native `faq` prints.

</div>

<div class="lean-decl" id="Esm.Document.Math.tableP">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.tableP" title="Esm.Document.Math.tableP"><code>tableP</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L847-L850">source</a></div>

```lean
def tableP (t : List (Json × Out)) (x : Json) : Out
```

A printer given by a table of printed sub-expressions.

</div>

<div class="lean-decl" id="Esm.Document.Math.tnameOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.tnameOK" title="Esm.Document.Math.tnameOK"><code>tnameOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L951">source</a></div>

```lean
def tnameOK (n : String) : Bool
```

A template the call form can name: an identifier that is not a reserved operator
name.

</div>

<div class="lean-decl" id="Esm.Document.Math.pr">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pr" title="Esm.Document.Math.pr"><code>pr</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L954-L1084">source</a></div>

```lean
def pr (c : Ctx) (e : Json) : Out
```

The printer.

</div>

<div class="lean-decl" id="Esm.Document.Math.pa">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pa" title="Esm.Document.Math.pa"><code>pa</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L1087">source</a></div>

```lean
def pa (c : Ctx) (L : Nat) (e : Json) : List Tok
```

The tokens of an expression for a position needing level `L`.

</div>

<div class="lean-decl" id="Esm.Document.Math.print">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.print" title="Esm.Document.Math.print"><code>print</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean#L1090">source</a></div>

```lean
def print (sf : Sf) (S : Sym) (e : Json) : List Tok
```

The tokens of a whole expression.

</div>

<p class="lean-meta">This module also proves 18 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/Print.lean">the source</a>.</p>
