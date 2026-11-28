---
title: "The printer: expressions to tokens"
type: lean
lean_module: "Esm.Document.Math.Print"
weight: 13
---

<p class="lean-meta">Lean module <code>Esm.Document.Math.Print</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean"><code>formal/Esm/Document/Math/Print.lean</code></a> at <code>ffd5aee2f868</code><br>Imports <a href="/generated/document-formats/esm-document-math-surface"><code>Esm.Document.Math.Surface</code></a>, <a href="/generated/document-formats/esm-document-notation"><code>Esm.Document.Notation</code></a></p>

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
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.escSet" title="Esm.Document.Math.escSet"><code>escSet</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L41">source</a></div>

```lean
def escSet (c : Char) : Bool
```

The characters escaped by a backslash inside `\mathit{}`, `\operatorname{}`,
`\esm{}` and a name subscript's `\mathrm{}`.

</div>

<div class="lean-decl" id="Esm.Document.Math.escT">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.escT" title="Esm.Document.Math.escT"><code>escT</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L44-L46">source</a></div>

```lean
def escT : List Char → List Char
```

Escape the text of `\mathit{}` and the like.

</div>

<div class="lean-decl" id="Esm.Document.Math.unescT">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.unescT" title="Esm.Document.Math.unescT"><code>unescT</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L49-L52">source</a></div>

```lean
def unescT : List Char → List Char
```

Undo [`escT`](#Esm.Document.Math.escT).

</div>

<div class="lean-decl" id="Esm.Document.Math.keySpecial">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.keySpecial" title="Esm.Document.Math.keySpecial"><code>keySpecial</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L73-L74">source</a></div>

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
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.dig3" title="Esm.Document.Math.dig3"><code>dig3</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L77-L78">source</a></div>

```lean
def dig3 (n : Nat) : List Char
```

Three decimal digits.

</div>

<div class="lean-decl" id="Esm.Document.Math.escK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.escK" title="Esm.Document.Math.escK"><code>escK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L81-L85">source</a></div>

```lean
def escK : List Char → List Char
```

Escape a field key for `\mathrm{}`.

</div>

<div class="lean-decl" id="Esm.Document.Math.unescK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.unescK" title="Esm.Document.Math.unescK"><code>unescK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L88-L93">source</a></div>

```lean
def unescK : List Char → List Char
```

Undo [`escK`](#Esm.Document.Math.escK).

</div>

<div class="lean-decl" id="Esm.Document.Math.natChars">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.natChars" title="Esm.Document.Math.natChars"><code>natChars</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L116">source</a></div>

```lean
def natChars (n : Nat) : List Char
```

The digits of a natural number.

</div>

## The printing context

<div class="lean-decl" id="Esm.Document.Math.grp">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.grp" title="Esm.Document.Math.grp"><code>grp</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L125-L126">source</a></div>

```lean
def grp (sf : Sf) (ts : List Tok) : List Tok
```

Grouping parentheses.

</div>

<div class="lean-decl" id="Esm.Document.Math.rpG">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.rpG" title="Esm.Document.Math.rpG"><code>rpG</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L129">source</a></div>

```lean
def rpG (sf : Sf) : Tok
```

The closing token of a grouping parenthesis.

</div>

<div class="lean-decl" id="Esm.Document.Math.sepBy">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.sepBy" title="Esm.Document.Math.sepBy"><code>sepBy</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L132-L135">source</a></div>

```lean
def sepBy (sep : List Tok) : List (List Tok) → List Tok
```

Items joined by a separator.

</div>

## Names

<div class="lean-decl" id="Esm.Document.Math.baseTok">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.baseTok" title="Esm.Document.Math.baseTok"><code>baseTok</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L140-L143">source</a></div>

```lean
def baseTok (g : List Char) : Tok
```

A single letter or a Greek name as a token.

</div>

<div class="lean-decl" id="Esm.Document.Math.subTxt">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.subTxt" title="Esm.Document.Math.subTxt"><code>subTxt</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L146-L149">source</a></div>

```lean
def subTxt (sf : Sf) (r : List Char) : List Tok
```

The subscript text of a name: upright.

</div>

<div class="lean-decl" id="Esm.Document.Math.formulaRaw">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.formulaRaw" title="Esm.Document.Math.formulaRaw"><code>formulaRaw</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L152-L153">source</a></div>

```lean
def formulaRaw (g : List Char) : List Char
```

The raw `\mathrm{}` content of a formula: counts as `_{n}`.

</div>

<div class="lean-decl" id="Esm.Document.Math.formTok">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.formTok" title="Esm.Document.Math.formTok"><code>formTok</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L156-L159">source</a></div>

```lean
def formTok (sf : Sf) (g : List Char) : Tok
```

A formula name.

</div>

<div class="lean-decl" id="Esm.Document.Math.segToks">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.segToks" title="Esm.Document.Math.segToks"><code>segToks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L162-L166">source</a></div>

```lean
def segToks (sf : Sf) (g : List Char) : List Tok
```

One segment of a name, by its shape.

</div>

<div class="lean-decl" id="Esm.Document.Math.explicitName">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.explicitName" title="Esm.Document.Math.explicitName"><code>explicitName</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L171-L172">source</a></div>

```lean
def explicitName (S : Sym) (s : String) : Bool
```

A name never prints bare where the parser would read it otherwise: an undeclared
`e` (bare `e^{x}` reads as `exp`) and an undeclared `d` (bare `\frac{d N}{d t}` reads
as a derivative) print in the explicit form.

</div>

<div class="lean-decl" id="Esm.Document.Math.plainLast">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.plainLast" title="Esm.Document.Math.plainLast"><code>plainLast</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L180-L183">source</a></div>

```lean
def plainLast (s : String) : Bool
```

The last segment of a name prints with no subscript, so an index subscript may
follow it.

</div>

## JSON inside escape nodes (LaTeX)

## Operator tables

<div class="lean-decl" id="Esm.Document.Math.fnKw">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.fnKw" title="Esm.Document.Math.fnKw"><code>fnKw</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L217-L219">source</a></div>

```lean
def fnKw : List (String × Kw)
```

Unary functions with a native spelling, and their keyword.

</div>

<div class="lean-decl" id="Esm.Document.Math.cmpKw">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.cmpKw" title="Esm.Document.Math.cmpKw"><code>cmpKw</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L222-L223">source</a></div>

```lean
def cmpKw : List (String × Kw)
```

Comparisons and their token.

</div>

<div class="lean-decl" id="Esm.Document.Math.callOps">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.callOps" title="Esm.Document.Math.callOps"><code>callOps</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L226">source</a></div>

```lean
def callOps : List String
```

Core operators in the call form.

</div>

<div class="lean-decl" id="Esm.Document.Math.fieldCallOps">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.fieldCallOps" title="Esm.Document.Math.fieldCallOps"><code>fieldCallOps</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L230">source</a></div>

```lean
def fieldCallOps : List String
```

Core operators with no notation of their own that print in the call form, their
fields as named arguments after `;` (when no field annotates the node).

</div>

<div class="lean-decl" id="Esm.Document.Math.reservedOpn">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.reservedOpn" title="Esm.Document.Math.reservedOpn"><code>reservedOpn</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L233">source</a></div>

```lean
def reservedOpn : List String
```

Names `\operatorname{…}` never means a template or an open operator by.

</div>

<div class="lean-decl" id="Esm.Document.Math.coreOps">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.coreOps" title="Esm.Document.Math.coreOps"><code>coreOps</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L236-L244">source</a></div>

```lean
def coreOps : List String
```

`coreOpNames` of `Notation`.

</div>

<div class="lean-decl" id="Esm.Document.Math.opnOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.opnOK" title="Esm.Document.Math.opnOK"><code>opnOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L247-L250">source</a></div>

```lean
def opnOK (s : String) : Bool
```

A name `\operatorname{…}` can carry: identifier characters and dots.

</div>

<div class="lean-decl" id="Esm.Document.Math.annotKeys">
<div class="lean-decl-head"><span class="lean-kind">abbrev</span> <a class="lean-name" href="#Esm.Document.Math.annotKeys" title="Esm.Document.Math.annotKeys"><code>annotKeys</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L253">source</a></div>

```lean
abbrev annotKeys : List String
```

The fields that annotate a node.

</div>

<div class="lean-decl" id="Esm.Document.Math.callFormOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.callFormOK" title="Esm.Document.Math.callFormOK"><code>callFormOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L257-L258">source</a></div>

```lean
def callFormOK (o : String) (fs : List (String × Json)) : Bool
```

An operator prints in the call form: an open operator, or a core operator of
[`fieldCallOps`](#Esm.Document.Math.fieldCallOps) none of whose fields annotates it.

</div>

<div class="lean-decl" id="Esm.Document.Math.mathKeys">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.mathKeys" title="Esm.Document.Math.mathKeys"><code>mathKeys</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L262">source</a></div>

```lean
def mathKeys : List String
```

The fields of a core operator in the call form that hold an expression; the others
print as JSON, even a string that is a name.

</div>

<div class="lean-decl" id="Esm.Document.Math.mathField">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.mathField" title="Esm.Document.Math.mathField"><code>mathField</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L267-L268">source</a></div>

```lean
def mathField (o : String) (kv : String × Json) : Bool
```

A field of a call-form node prints as math: its value is an expression and, for a
core operator, the field holds one. An open operator's fields are all read as math when
they can be.

</div>

<div class="lean-decl" id="Esm.Document.Math.keyOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.keyOK" title="Esm.Document.Math.keyOK"><code>keyOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L274">source</a></div>

```lean
def keyOK (s : String) : Bool
```

A field key printed upright in a call: an identifier.

</div>

<div class="lean-decl" id="Esm.Document.Math.insKV">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.insKV" title="Esm.Document.Math.insKV"><code>insKV</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L277-L279">source</a></div>

```lean
def insKV (kv : String × Json) : List (String × Json) → List (String × Json)
```

Sorted insertion by key.

</div>

<div class="lean-decl" id="Esm.Document.Math.fieldsOf">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.fieldsOf" title="Esm.Document.Math.fieldsOf"><code>fieldsOf</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L282-L283">source</a></div>

```lean
def fieldsOf (kvs : List (String × Json)) : List (String × Json)
```

The fields of a node other than `op` and `args`.

</div>

<div class="lean-decl" id="Esm.Document.Math.mkNode">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.mkNode" title="Esm.Document.Math.mkNode"><code>mkNode</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L286-L287">source</a></div>

```lean
def mkNode (o : String) (as : List Json) (fs : List (String × Json)) : Json
```

A node from its operator, operands and other fields (sorted keys).

</div>

<div class="lean-decl" id="Esm.Document.Math.node">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.node" title="Esm.Document.Math.node"><code>node</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L290">source</a></div>

```lean
def node (o : String) (as : List Json) : Json
```

The plain two-field node.

</div>

<div class="lean-decl" id="Esm.Document.Math.simpleTok">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.simpleTok" title="Esm.Document.Math.simpleTok"><code>simpleTok</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L299-L304">source</a></div>

```lean
def simpleTok : Tok → Bool
```

Typst exponent and subscript tokens that need no parentheses: a nonnegative number
in positional spelling, a letter, a Greek name.

</div>

<div class="lean-decl" id="Esm.Document.Math.tparams">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.tparams" title="Esm.Document.Math.tparams"><code>tparams</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L311-L312">source</a></div>

```lean
def tparams (S : Sym) (n : String) : Option (List String)
```

The template parameter list, when the symbol table knows it.

</div>

<div class="lean-decl" id="Esm.Document.Math.positional">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.positional" title="Esm.Document.Math.positional"><code>positional</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L316-L321">source</a></div>

```lean
def positional (S : Sym) (n : String) (bs : List (String × Json)) : Option (List String)
```

Positional template arguments: the table knows the parameters, they are distinct,
and the bindings bind exactly them.

</div>

<div class="lean-decl" id="Esm.Document.Math.rawB">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.rawB" title="Esm.Document.Math.rawB"><code>rawB</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L324-L330">source</a></div>

```lean
def rawB : Nat → List Char → Option (List Char × List Char)
```

Balanced text up to the `}` that closes depth 0; `\x` is one unit.

</div>

<div class="lean-decl" id="Esm.Document.Math.balOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.balOK" title="Esm.Document.Math.balOK"><code>balOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L334">source</a></div>

```lean
def balOK (raw : List Char) : Bool
```

Raw text that [`rawB`](#Esm.Document.Math.rawB) reads back whole (the LaTeX lexer reads `\mathrm{…}` and
`\text{…}` contents with [`rawB`](#Esm.Document.Math.rawB)).

</div>

<div class="lean-decl" id="Esm.Document.Math.factorsOf">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.factorsOf" title="Esm.Document.Math.factorsOf"><code>factorsOf</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L337-L340">source</a></div>

```lean
def factorsOf (u : String) : List Esm.Units.Factor
```

The two-sided factor list of a units string (`[]` when it does not parse).

</div>

<div class="lean-decl" id="Esm.Document.Math.unitsOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.unitsOK" title="Esm.Document.Math.unitsOK"><code>unitsOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L345-L351">source</a></div>

```lean
def unitsOK (sf : Sf) (u : String) : Bool
```

The units of a quantity print typeset when the string is the canonical spelling of
a non-dimensionless unit whose typeset form reads back (Phase 1: every canonical unit
does).

</div>

## The printer

<div class="lean-decl" id="Esm.Document.Math.wrap">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.wrap" title="Esm.Document.Math.wrap"><code>wrap</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L356-L357">source</a></div>

```lean
def wrap (sf : Sf) (L : Nat) (p : Nat × List Tok) : List Tok
```

Wrap a printed form for a position needing level `L`.

</div>

<div class="lean-decl" id="Esm.Document.Math.mulToks">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.mulToks" title="Esm.Document.Math.mulToks"><code>mulToks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L360-L362">source</a></div>

```lean
def mulToks : List (List Tok) → List Tok
```

A `*` chain: juxtaposition, `\cdot` before a factor that starts with a number.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.sizeOf_lt_arr">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.sizeOf_lt_arr" title="Esm.Document.Math.sizeOf_lt_arr"><code>sizeOf_lt_arr</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L365-L368">source</a></div>

```lean
theorem sizeOf_lt_arr {a : Json} {as : List Json} (h : a ∈ as) :
    sizeOf a < sizeOf (Json.arr as)
```

Size bookkeeping for the recursion.

</div>

<div class="lean-decl" id="Esm.Document.Math.OpK">
<div class="lean-decl-head"><span class="lean-kind">inductive</span> <a class="lean-name" href="#Esm.Document.Math.OpK" title="Esm.Document.Math.OpK"><code>OpK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L401-L404">source</a></div>

```lean
inductive OpK where
  | minus | div | pow | lnot | tru | fls | ite | ic | index
  | cmp (k : Kw) | un (k : Kw) | plus | times | land | lor | mm (k : Kw) | call | other
  deriving DecidableEq
```

How a plain node (`op` and `args` only) prints, by its operator.

</div>

<div class="lean-decl" id="Esm.Document.Math.unKw">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.unKw" title="Esm.Document.Math.unKw"><code>unKw</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L407-L408">source</a></div>

```lean
def unKw : List (String × Kw)
```

Unary functions with a native spelling: their keyword (`log10` is `\log_{10}`).

</div>

<div class="lean-decl" id="Esm.Document.Math.kindTable">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.kindTable" title="Esm.Document.Math.kindTable"><code>kindTable</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L411-L414">source</a></div>

```lean
def kindTable : List (String × OpK)
```

The plain-node operators with their own notation.

</div>

<div class="lean-decl" id="Esm.Document.Math.Out">
<div class="lean-decl-head"><span class="lean-kind">structure</span> <a class="lean-name" href="#Esm.Document.Math.Out" title="Esm.Document.Math.Out"><code>Out</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L426-L429">source</a></div>

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
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.escToks" title="Esm.Document.Math.escToks"><code>escToks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L438-L444">source</a></div>

```lean
def escToks (sf : Sf) (o : String) (fs : List (String × Json)) (args : List (List Tok)) :
    List Tok
```

The escape form: LaTeX `\esm{op}{fields}{args}` with the fields as JSON, Typst
`esm.node("op", #(fields), args)`.

</div>

<div class="lean-decl" id="Esm.Document.Math.lpC">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.lpC" title="Esm.Document.Math.lpC"><code>lpC</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L447">source</a></div>

```lean
def lpC (_sf : Sf) : Tok
```

The call parenthesis `(` (LaTeX `(`, Typst `(` right after a name).

</div>

<div class="lean-decl" id="Esm.Document.Math.callToks">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.callToks" title="Esm.Document.Math.callToks"><code>callToks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L450-L451">source</a></div>

```lean
def callToks (sf : Sf) (head : List Tok) (args : List (List Tok)) : List Tok
```

A call: `name(args)` with call parentheses.

</div>

<div class="lean-decl" id="Esm.Document.Math.unToks">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.unToks" title="Esm.Document.Math.unToks"><code>unToks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L454-L462">source</a></div>

```lean
def unToks (sf : Sf) (k : Kw) (t : List Tok) : List Tok
```

A unary function applied to the printed operand `t`.

</div>

<div class="lean-decl" id="Esm.Document.Math.caseRow">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.caseRow" title="Esm.Document.Math.caseRow"><code>caseRow</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L465-L466">source</a></div>

```lean
def caseRow (sf : Sf) (v cnd : List Tok) : List Tok
```

One cases row, `value & \text{if } condition`, then the row break.

</div>

<div class="lean-decl" id="Esm.Document.Math.icTail">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.icTail" title="Esm.Document.Math.icTail"><code>icTail</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L474-L477">source</a></div>

```lean
def icTail (sf : Sf) : List Tok
```

`t_{0}` in an initial condition `N(t_{0})`.

</div>

<div class="lean-decl" id="Esm.Document.Math.subList">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.subList" title="Esm.Document.Math.subList"><code>subList</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L480-L486">source</a></div>

```lean
def subList (sf : Sf) (simp : Option Tok) (args : List (List Tok)) : List Tok
```

A subscript list: LaTeX `_{a, b}`; Typst `_a` for one simple token, else `_(a, b)`.

</div>

<div class="lean-decl" id="Esm.Document.Math.simpleE">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.simpleE" title="Esm.Document.Math.simpleE"><code>simpleE</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L491-L497">source</a></div>

```lean
def simpleE (c : Ctx) : Json → Option Tok
```

The one token a Typst exponent or subscript may be written as without
parentheses: a nonnegative number in positional spelling, or a one-letter or Greek
name.

</div>

<div class="lean-decl" id="Esm.Document.Math.subOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.subOK" title="Esm.Document.Math.subOK"><code>subOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L507-L515">source</a></div>

```lean
def subOK (S : Sym) (base : Json) (is : List Json) : Bool
```

The index prints with a subscript unless the base is not a plain name, or the
subscript would collide with a name: one formula-shaped name (it would read as the
upright subscript of a name), or one digit literal `n` when `base_n` is declared
(`k_{1}` would look like the name `k_1`; decision 5).

</div>

<div class="lean-decl" id="Esm.Document.Math.subPat4">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.subPat4" title="Esm.Document.Math.subPat4"><code>subPat4</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L518-L521">source</a></div>

```lean
def subPat4 (sf : Sf) : Tok → Tok → Tok → Tok → Bool
```

Four tokens of an upright name subscript.

</div>

<div class="lean-decl" id="Esm.Document.Math.subPat">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.subPat" title="Esm.Document.Math.subPat"><code>subPat</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L524-L526">source</a></div>

```lean
def subPat (sf : Sf) : List Tok → Bool
```

An upright name subscript: a name before it would read it as part of the name.

</div>

<div class="lean-decl" id="Esm.Document.Math.inlineD">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.inlineD" title="Esm.Document.Math.inlineD"><code>inlineD</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L530">source</a></div>

```lean
def inlineD (o : Out) : Bool
```

Derivative operand printed inline (`\frac{\mathrm{d} N}{\mathrm{d} t}`) when it is
postfix-level or tighter, and not a negative literal.

</div>

<div class="lean-decl" id="Esm.Document.Math.keyToks">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.keyToks" title="Esm.Document.Math.keyToks"><code>keyToks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L533-L536">source</a></div>

```lean
def keyToks (sf : Sf) (k : String) : List Tok
```

A field key, upright.

</div>

<div class="lean-decl" id="Esm.Document.Math.jsonVal">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.jsonVal" title="Esm.Document.Math.jsonVal"><code>jsonVal</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L539-L542">source</a></div>

```lean
def jsonVal (sf : Sf) (v : Json) : List Tok
```

A field value that is not an expression, as JSON.

</div>

<div class="lean-decl" id="Esm.Document.Math.openToks">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.openToks" title="Esm.Document.Math.openToks"><code>openToks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L545-L547">source</a></div>

```lean
def openToks (sf : Sf) (o : String) (args fields : List (List Tok)) : List Tok
```

The open-operator call: positional operands, then `;` and the fields.

</div>

<div class="lean-decl" id="Esm.Document.Math.dTime">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.dTime" title="Esm.Document.Math.dTime"><code>dTime</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L550-L561">source</a></div>

```lean
def dTime (sf : Sf) (a : Out) : Out
```

The time derivative.

</div>

<div class="lean-decl" id="Esm.Document.Math.dSpace">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.dSpace" title="Esm.Document.Math.dSpace"><code>dSpace</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L564-L575">source</a></div>

```lean
def dSpace (sf : Sf) (w : List Tok) (a : Out) : Out
```

The spatial derivative along the axis printed `w`.

</div>

<div class="lean-decl" id="Esm.Document.Math.dCall">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.dCall" title="Esm.Document.Math.dCall"><code>dCall</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L578-L581">source</a></div>

```lean
def dCall (sf : Sf) (w : List Tok) (args : List (List Tok)) : List Tok
```

A spatial derivative with trailing operands: `\operatorname{D}_{x}(u, a, b)`.

</div>

<div class="lean-decl" id="Esm.Document.Math.qtyToks">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.qtyToks" title="Esm.Document.Math.qtyToks"><code>qtyToks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L585">source</a></div>

```lean
def qtyToks (n : JNum) (l : List Esm.Units.Factor) : List Tok
```

The quantity `3\,\mathrm{m/s}` / `3 thin upright("m") thin upright("s")^(-1)`: the
number, then the unit as one token.

</div>

## Constant arrays

<div class="lean-decl" id="Esm.Document.Math.numsOf">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.numsOf" title="Esm.Document.Math.numsOf"><code>numsOf</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L590-L593">source</a></div>

```lean
def numsOf : List Json → Option (List JNum)
```

The entries of a list that are all well-formed numbers.

</div>

<div class="lean-decl" id="Esm.Document.Math.rowsOf">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.rowsOf" title="Esm.Document.Math.rowsOf"><code>rowsOf</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L596-L602">source</a></div>

```lean
def rowsOf : List Json → Option (List (List JNum))
```

The rows of a list of number lists.

</div>

<div class="lean-decl" id="Esm.Document.Math.AForm">
<div class="lean-decl-head"><span class="lean-kind">inductive</span> <a class="lean-name" href="#Esm.Document.Math.AForm" title="Esm.Document.Math.AForm"><code>AForm</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L605-L607">source</a></div>

```lean
inductive AForm where
  | col (ns : List JNum)
  | mat (rs : List (List JNum))
```

The two array shapes with a native spelling.

</div>

<div class="lean-decl" id="Esm.Document.Math.arrForm">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.arrForm" title="Esm.Document.Math.arrForm"><code>arrForm</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L612-L623">source</a></div>

```lean
def arrForm : Json → Option AForm
```

A constant array printed natively: a column for rank 1, or a matrix of at least
two columns (a single-column matrix would print like a column), of any size, every entry
a well-formed number.

</div>

<div class="lean-decl" id="Esm.Document.Math.bmatCols">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.bmatCols" title="Esm.Document.Math.bmatCols"><code>bmatCols</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L632">source</a></div>

```lean
def bmatCols : Nat
```

The most columns a LaTeX `bmatrix` takes (amsmath's `MaxMatrixCols`).

</div>

<div class="lean-decl" id="Esm.Document.Math.arrToks">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.arrToks" title="Esm.Document.Math.arrToks"><code>arrToks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L636-L649">source</a></div>

```lean
def arrToks (sf : Sf) : AForm → List Tok
```

The array: LaTeX `bmatrix`, or for a matrix wider than [`bmatCols`](#Esm.Document.Math.bmatCols)
`\left[\begin{array}{c…c} … \end{array}\right]`; Typst `vec(…)` / `mat(…)`.

</div>

<div class="lean-decl" id="Esm.Document.Math.unitToks">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.unitToks" title="Esm.Document.Math.unitToks"><code>unitToks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L652">source</a></div>

```lean
def unitToks (l : List Esm.Units.Factor) : List Tok
```

The unit after a number or an array.

</div>

## Reductions (`faq`)

<div class="lean-decl" id="Esm.Document.Math.jbeq">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.jbeq" title="Esm.Document.Math.jbeq"><code>jbeq</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L658-L665">source</a></div>

```lean
def jbeq : Json → Json → Bool
```

Equality of JSON values as a check.

</div>

<div class="lean-decl" id="Esm.Document.Math.idxBase">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.idxBase" title="Esm.Document.Math.idxBase"><code>idxBase</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L679-L682">source</a></div>

```lean
def idxBase (kvs : List (String × Json)) : Option String
```

The array an `index` node reads, when it names one.

</div>

<div class="lean-decl" id="Esm.Document.Math.basesJ">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.basesJ" title="Esm.Document.Math.basesJ"><code>basesJ</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L686-L692">source</a></div>

```lean
def basesJ : Json → List String → List String
```

The arrays an expression indexes, in first-use order (appended to `acc`).

</div>

<div class="lean-decl" id="Esm.Document.Math.RedK">
<div class="lean-decl-head"><span class="lean-kind">inductive</span> <a class="lean-name" href="#Esm.Document.Math.RedK" title="Esm.Document.Math.RedK"><code>RedK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L706-L708">source</a></div>

```lean
inductive RedK where
  | sum | prod | max | min
  deriving DecidableEq
```

The reductions with a native spelling.

</div>

<div class="lean-decl" id="Esm.Document.Math.FaqForm">
<div class="lean-decl-head"><span class="lean-kind">structure</span> <a class="lean-name" href="#Esm.Document.Math.FaqForm" title="Esm.Document.Math.FaqForm"><code>FaqForm</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L722-L729">source</a></div>

```lean
structure FaqForm where
  red : RedK
  marked : Bool
  out : List Json
  ranges : List (String × Json)
  expr : Json
  filter : Option Json
  set : List String
```

A `faq` node with a native spelling, by its parts. `marked`: `args` lists the arrays
the body indexes; otherwise `args` is `set` (empty, or names printed as a superscript
set).

</div>

<div class="lean-decl" id="Esm.Document.Math.FaqForm.args">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.FaqForm.args" title="Esm.Document.Math.FaqForm.args"><code>FaqForm.args</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L732-L733">source</a></div>

```lean
def FaqForm.args (F : FaqForm) : List Json
```

The `args` of a native `faq`.

</div>

<div class="lean-decl" id="Esm.Document.Math.FaqForm.sup">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.FaqForm.sup" title="Esm.Document.Math.FaqForm.sup"><code>FaqForm.sup</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L736">source</a></div>

```lean
def FaqForm.sup (F : FaqForm) : List String
```

The names a superscript set shows: `set` when `args` is not the body's arrays.

</div>

<div class="lean-decl" id="Esm.Document.Math.strsOf">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.strsOf" title="Esm.Document.Math.strsOf"><code>strsOf</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L745-L748">source</a></div>

```lean
def strsOf : List Json → Option (List String)
```

The strings of a list of JSON values, when they are all strings.

</div>

<div class="lean-decl" id="Esm.Document.Math.faqCand">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.faqCand" title="Esm.Document.Math.faqCand"><code>faqCand</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L751-L771">source</a></div>

```lean
def faqCand (kvs : List (String × Json)) : Option FaqForm
```

The parts a `faq` node would have.

</div>

<div class="lean-decl" id="Esm.Document.Math.faqForm">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.faqForm" title="Esm.Document.Math.faqForm"><code>faqForm</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L776-L779">source</a></div>

```lean
def faqForm (kvs : List (String × Json)) : Option FaqForm
```

The parts of a `faq` node, when it is exactly the node they rebuild: no semiring,
join, distinct or key, `reduce` absent or `*`, `max`, `min`, `ranges` absent or not
empty, `args` empty, the arrays the body indexes, or other names.

</div>

<div class="lean-decl" id="Esm.Document.Math.rangeOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.rangeOK" title="Esm.Document.Math.rangeOK"><code>rangeOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L782-L787">source</a></div>

```lean
def rangeOK : Json → Bool
```

A range a row can spell: `[a, b]`, `{"from": S}` or `{"from": S, "of": [i, …]}`.

</div>

<div class="lean-decl" id="Esm.Document.Math.outOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.outOK" title="Esm.Document.Math.outOK"><code>outOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L793-L797">source</a></div>

```lean
def outOK (j : Json) : Bool
```

An output entry: a name, or the singleton dimension `1`.

</div>

<div class="lean-decl" id="Esm.Document.Math.occursJ">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.occursJ" title="Esm.Document.Math.occursJ"><code>occursJ</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L801-L805">source</a></div>

```lean
def occursJ (k : String) : Json → Bool
```

A bare name occurs in an expression.

</div>

<div class="lean-decl" id="Esm.Document.Math.faqOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.faqOK" title="Esm.Document.Math.faqOK"><code>faqOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L817-L823">source</a></div>

```lean
def faqOK (F : FaqForm) : Bool
```

The conditions under which the native spelling reads back.

</div>

<div class="lean-decl" id="Esm.Document.Math.rowToks">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.rowToks" title="Esm.Document.Math.rowToks"><code>rowToks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L826-L833">source</a></div>

```lean
def rowToks (c : Ctx) (P : Json → Out) (kv : String × Json) : List Tok
```

A range row: `a \le k \le b`, `k \in S`, `k \in S(i, j)`.

</div>

<div class="lean-decl" id="Esm.Document.Math.redRanges">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.redRanges" title="Esm.Document.Math.redRanges"><code>redRanges</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L836-L837">source</a></div>

```lean
def redRanges (F : FaqForm) : List (String × Json)
```

The reduced ranges: those of indices that are not output indices.

</div>

<div class="lean-decl" id="Esm.Document.Math.subRows">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.subRows" title="Esm.Document.Math.subRows"><code>subRows</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L840-L841">source</a></div>

```lean
def subRows (c : Ctx) (P : Json → Out) (F : FaqForm) : List (List Tok)
```

The rows of the subscript: the reduced ranges, then the filter.

</div>

<div class="lean-decl" id="Esm.Document.Math.headToks">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.headToks" title="Esm.Document.Math.headToks"><code>headToks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L844-L847">source</a></div>

```lean
def headToks (sf : Sf) (F : FaqForm) : List Tok
```

The operator, marked when `args` is listed.

</div>

<div class="lean-decl" id="Esm.Document.Math.subToksL">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.subToksL" title="Esm.Document.Math.subToksL"><code>subToksL</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L851-L860">source</a></div>

```lean
def subToksL (c : Ctx) (P : Json → Out) (F : FaqForm) : List Tok
```

The LaTeX subscript: none, one row, a lone dense range `_{k=a}^{b}` (not when `args`
is a superscript set), or `\substack`.

</div>

<div class="lean-decl" id="Esm.Document.Math.subToksT">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.subToksT" title="Esm.Document.Math.subToksT"><code>subToksT</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L863-L866">source</a></div>

```lean
def subToksT (c : Ctx) (P : Json → Out) (F : FaqForm) : List Tok
```

The Typst subscript: rows in `_( … )`, stacked with `\`.

</div>

<div class="lean-decl" id="Esm.Document.Math.supToks">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.supToks" title="Esm.Document.Math.supToks"><code>supToks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L874-L877">source</a></div>

```lean
def supToks (c : Ctx) (ns : List String) : List Tok
```

The superscript set of names: LaTeX `^{\{f, g\}}`, Typst `^({f, g})`.

</div>

<div class="lean-decl" id="Esm.Document.Math.supT">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.supT" title="Esm.Document.Math.supT"><code>supT</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L880-L881">source</a></div>

```lean
def supT (c : Ctx) (F : FaqForm) : List Tok
```

The `args` set of a `faq`, as a superscript, when it is one.

</div>

<div class="lean-decl" id="Esm.Document.Math.redToks">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.redToks" title="Esm.Document.Math.redToks"><code>redToks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L885-L886">source</a></div>

```lean
def redToks (c : Ctx) (P : Json → Out) (F : FaqForm) : List Tok
```

The reduction: operator, subscript, the superscript set (on the operator only when
there are no output indices), body at level 5.

</div>

<div class="lean-decl" id="Esm.Document.Math.entryToks">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.entryToks" title="Esm.Document.Math.entryToks"><code>entryToks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L889-L895">source</a></div>

```lean
def entryToks (c : Ctx) (P : Json → Out) (F : FaqForm) (j : Json) : List Tok
```

An output entry: its range row when it has one.

</div>

<div class="lean-decl" id="Esm.Document.Math.faqOut">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.faqOut" title="Esm.Document.Math.faqOut"><code>faqOut</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L901-L910">source</a></div>

```lean
def faqOut (c : Ctx) (P : Json → Out) (F : FaqForm) : Out
```

The native `faq`: the reduction, wrapped with its output indices when it has some.
A superscript set goes on the bracket, before its subscript (it renders the same either
way; written first, a reader meets it right after the bracket); the form is then a power's
level (a power of it, or an index into it, is parenthesized: no double superscript).

</div>

<div class="lean-decl" id="Esm.Document.Math.faqSubs">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.faqSubs" title="Esm.Document.Math.faqSubs"><code>faqSubs</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L913-L915">source</a></div>

```lean
def faqSubs (F : FaqForm) : List Json
```

The sub-expressions a native `faq` prints.

</div>

<div class="lean-decl" id="Esm.Document.Math.tableP">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.tableP" title="Esm.Document.Math.tableP"><code>tableP</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L918-L921">source</a></div>

```lean
def tableP (t : List (Json × Out)) (x : Json) : Out
```

A printer given by a table of printed sub-expressions.

</div>

## Block assembly (`makearray`)

<div class="lean-decl" id="Esm.Document.Math.MkForm">
<div class="lean-decl-head"><span class="lean-kind">structure</span> <a class="lean-name" href="#Esm.Document.Math.MkForm" title="Esm.Document.Math.MkForm"><code>MkForm</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L1024-L1027">source</a></div>

```lean
structure MkForm where
  out : List String
  regions : List (List (Json × Json))
  values : List Json
```

A `makearray` node with a native spelling, by its parts: the output indices (empty
when the node has no `output_idx`), and the regions with their values.

</div>

<div class="lean-decl" id="Esm.Document.Math.pairsOf">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pairsOf" title="Esm.Document.Math.pairsOf"><code>pairsOf</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L1039-L1042">source</a></div>

```lean
def pairsOf : List Json → Option (List (Json × Json))
```

The bound pairs of a region.

</div>

<div class="lean-decl" id="Esm.Document.Math.regionsOf">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.regionsOf" title="Esm.Document.Math.regionsOf"><code>regionsOf</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L1045-L1051">source</a></div>

```lean
def regionsOf : List Json → Option (List (List (Json × Json)))
```

The regions of a `regions` list.

</div>

<div class="lean-decl" id="Esm.Document.Math.mkCand">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.mkCand" title="Esm.Document.Math.mkCand"><code>mkCand</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L1054-L1065">source</a></div>

```lean
def mkCand (kvs : List (String × Json)) : Option MkForm
```

The parts a `makearray` node would have.

</div>

<div class="lean-decl" id="Esm.Document.Math.mkForm">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.mkForm" title="Esm.Document.Math.mkForm"><code>mkForm</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L1069-L1072">source</a></div>

```lean
def mkForm (kvs : List (String × Json)) : Option MkForm
```

The parts of a `makearray` node, when it is exactly the node they rebuild: `args`
empty, `regions` and `values`, and an `output_idx` of names or none.

</div>

<div class="lean-decl" id="Esm.Document.Math.mkOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.mkOK" title="Esm.Document.Math.mkOK"><code>mkOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L1077-L1080">source</a></div>

```lean
def mkOK (M : MkForm) : Bool
```

The conditions under which the native spelling reads back: one value per region, at
least one region, each region a nonempty list of bound pairs, values and bounds
expressions, output indices names.

</div>

<div class="lean-decl" id="Esm.Document.Math.mkSubs">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.mkSubs" title="Esm.Document.Math.mkSubs"><code>mkSubs</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L1083-L1084">source</a></div>

```lean
def mkSubs (M : MkForm) : List Json
```

The sub-expressions a native `makearray` prints.

</div>

<div class="lean-decl" id="Esm.Document.Math.cellSep">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.cellSep" title="Esm.Document.Math.cellSep"><code>cellSep</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L1087-L1089">source</a></div>

```lean
def cellSep : Sf → Kw
```

The cell separator, the row separator and the closing token of the table.

</div>

<div class="lean-decl" id="Esm.Document.Math.pairToks">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pairToks" title="Esm.Document.Math.pairToks"><code>pairToks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L1095-L1096">source</a></div>

```lean
def pairToks (c : Ctx) (P : Json → Out) (p : Json × Json) : List Tok
```

A bound pair: `a, b` (its brackets are written around it).

</div>

<div class="lean-decl" id="Esm.Document.Math.regToks">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.regToks" title="Esm.Document.Math.regToks"><code>regToks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L1099-L1102">source</a></div>

```lean
def regToks (c : Ctx) (P : Json → Out) : List (Json × Json) → List Tok
```

A region: `[a, b] \times [c, d]`, one bound pair per dimension.

</div>

<div class="lean-decl" id="Esm.Document.Math.mkRow">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.mkRow" title="Esm.Document.Math.mkRow"><code>mkRow</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L1105-L1106">source</a></div>

```lean
def mkRow (c : Ctx) (P : Json → Out) (vr : Json × List (Json × Json)) : List Tok
```

A row of the table: the value, then the region it fills.

</div>

<div class="lean-decl" id="Esm.Document.Math.matHead">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.matHead" title="Esm.Document.Math.matHead"><code>matHead</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L1109-L1111">source</a></div>

```lean
def matHead : List Tok
```

The Typst table head: `mat(delim: "[", augment: #1,`.

</div>

<div class="lean-decl" id="Esm.Document.Math.mkSub">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.mkSub" title="Esm.Document.Math.mkSub"><code>mkSub</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L1114-L1118">source</a></div>

```lean
def mkSub (c : Ctx) (out : List String) : List Tok
```

The output indices as the bracket's subscript.

</div>

<div class="lean-decl" id="Esm.Document.Math.mkOutT">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.mkOutT" title="Esm.Document.Math.mkOutT"><code>mkOutT</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L1123-L1127">source</a></div>

```lean
def mkOutT (c : Ctx) (P : Json → Out) (M : MkForm) : Out
```

The native `makearray`: a bracketed two-column table, value then region, one row per
region in order; LaTeX `\left[\begin{array}{l|l} v & [a, b] \\ … \end{array}\right]`, Typst
`mat(delim: "[", augment: #1, v, [a, b]; …)`; the output indices as its subscript.

</div>

<div class="lean-decl" id="Esm.Document.Math.tnameOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.tnameOK" title="Esm.Document.Math.tnameOK"><code>tnameOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L1175">source</a></div>

```lean
def tnameOK (n : String) : Bool
```

A template the call form can name: an identifier that is not a reserved operator
name.

</div>

<div class="lean-decl" id="Esm.Document.Math.bareOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.bareOK" title="Esm.Document.Math.bareOK"><code>bareOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L1179">source</a></div>

```lean
def bareOK (S : Sym) (n : String) : Bool
```

A bare `\operatorname{n}` is a template applied with no bindings, unless a template
`n` with no parameters is in scope (that application prints `\operatorname{n}()`).

</div>

<div class="lean-decl" id="Esm.Document.Math.nativeK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.nativeK" title="Esm.Document.Math.nativeK"><code>nativeK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L1183-L1191">source</a></div>

```lean
def nativeK (sf : Sf) (kvs : List (String × Json)) : Bool
```

The node has a native spelling the printer writes before the call form: a `faq`,
a `makearray`, a constant array or a quantity.

</div>

<div class="lean-decl" id="Esm.Document.Math.fieldsOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.fieldsOK" title="Esm.Document.Math.fieldsOK"><code>fieldsOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L1194-L1195">source</a></div>

```lean
def fieldsOK (fs : List (String × Json)) : Bool
```

Fields a node can carry: distinct keys, none of them `op` or `args`.

</div>

<div class="lean-decl" id="Esm.Document.Math.callCond">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.callCond" title="Esm.Document.Math.callCond"><code>callCond</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L1201-L1202">source</a></div>

```lean
def callCond (c : Ctx) (o : String) (kvs : List (String × Json)) : Bool
```

The node with operator `o` prints in the call form (its field keys aside): the call
form fits it ([`callFormOK`](#Esm.Document.Math.callFormOK)), `o` is a name `\operatorname{…}` holds, no template `o`
is in scope, and it has no native spelling. The reader accepts the call form with
fields only for such a node.

</div>

<div class="lean-decl" id="Esm.Document.Math.pr">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pr" title="Esm.Document.Math.pr"><code>pr</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L1205-L1345">source</a></div>

```lean
def pr (c : Ctx) (e : Json) : Out
```

The printer.

</div>

<div class="lean-decl" id="Esm.Document.Math.pa">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pa" title="Esm.Document.Math.pa"><code>pa</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L1348">source</a></div>

```lean
def pa (c : Ctx) (L : Nat) (e : Json) : List Tok
```

The tokens of an expression for a position needing level `L`.

</div>

<div class="lean-decl" id="Esm.Document.Math.print">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.print" title="Esm.Document.Math.print"><code>print</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean#L1351">source</a></div>

```lean
def print (sf : Sf) (S : Sym) (e : Json) : List Tok
```

The tokens of a whole expression.

</div>

<p class="lean-meta">This module also proves 22 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Print.lean">the source</a>.</p>
