---
title: "The Typst container"
type: lean
lean_module: "Esm.Document.Source.Typst"
weight: 60
---

<p class="lean-meta">Lean module <code>Esm.Document.Source.Typst</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Typst.lean"><code>formal/Esm/Document/Source/Typst.lean</code></a> at <code>1b8dd9b3a909</code><br>Imports <a href="/generated/document-formats/esm-document-source-reaction"><code>Esm.Document.Source.Reaction</code></a>, <a href="/generated/document-formats/esm-document-source-equation"><code>Esm.Document.Source.Equation</code></a></p>

An ESM document in Typst is markup plus the functions of an `esm` Typst package:

```
#import "@preview/esm:0.1.0": *
#show: esm-document.with(esm: "2.3.0", name: "Decay")

#description[First\-order radioactive decay.]

#model("Decay")

#var($N$, default: 100, units: "mol")

$ (dif N)/(dif t) = -lambda N $
```

The constructs ([`Esm.Document.Source.RItem`](/generated/document-formats/esm-document-source-items#Esm.Document.Source.RItem)), and where they may appear:

* the header: the `#import` line, then `#show: esm-document.with(…)` with the
  front-matter entries as named arguments (values in the Typst value syntax,
  [`Esm.Document.TypstDict`](/generated/document-formats/esm-document-typstdict));
* at the start of a line: `#description[…]` (the text with Typst's markup characters
  escaped by a backslash), `#esm-block("key", value)` (a path block), `#model("Name")`
  or `#reaction-system("Name")`, and a display equation `$ … $` (optionally followed by
  a label `<eq-x>`, which is discarded);
* at the start of a line: a reaction, `#ce[…] <id>` on one line, in typsium
  ([`Esm.Document.Source.Reaction`](/generated/document-formats/esm-document-source-reaction)) with the rate as Typst math over the arrow,
  `->[$k$]`, and the reaction's `id` as the label; a reaction with other fields is
  wrapped as `#reaction(key: value, …)[#ce[…]] <id>`;
* at the start of a line: `#initialization[$ … $]` or `#constraints[$ … $]`, an
  initialization equation or a constraint;
* at the start of a line: `#subsystem("Name", ref: "…", …)`, a subsystem included by
  reference;
* at the start of a line: a template, `$ op("f")(a, b) := body $` (wrapped as
  `#template(key: value, …)[$ … $]` with other fields), or a rule,
  `#rule("r", $lhs$, $rhs$, key: value, …)`;
* at the start of a line: `#plot(key: value, …)`, an analysis with exactly one plot: the
  analysis's fields, the plot as the argument `plot`;
* anywhere: a declaration `#var($N$, …)`, `#param(…)` or `#species(…)`, the name in
  Typst math and the attributes as named arguments.

Everything else is prose, which the parser skips, so the parse depends only on the
sequence of constructs ([`lex_render`](#Esm.Document.Source.Typ.lex_render)). Prose may not contain a declaration opener
(`#var(`, `#param(`, `#species(`), nor start a line with a block opener; in particular
a line starting with `$ ` is always a model equation, so outside a model it rejects the
file. Conversely a model equation must start its line: display math `$ … $` after other
text on a line is prose (Typst typesets it, but it is not part of the model). Raw text
(`` `…` ``) is not skipped whole: a declaration opener inside it is still read.

The reader first drops a leading byte-order mark and, when the first line ends in CRLF,
reads every CRLF as LF ([`decodeText`](/generated/document-formats/esm-document-source-lines#Esm.Document.Source.decodeText)).

## Spellings

<div class="lean-decl" id="Esm.Document.Source.Typ.oRole">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.oRole" title="Esm.Document.Source.Typ.oRole"><code>oRole</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Typst.lean#L92-L95">source</a></div>

```lean
def oRole : Role → List Char
```

The opener of the equation container of a role.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.header">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.header" title="Esm.Document.Source.Typ.header"><code>header</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Typst.lean#L97">source</a></div>

```lean
def header : List Char
```

The header's first line and the start of its second.

</div>

## Description text

<div class="lean-decl" id="Esm.Document.Source.Typ.mustEsc">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.mustEsc" title="Esm.Document.Source.Typ.mustEsc"><code>mustEsc</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Typst.lean#L104-L107">source</a></div>

```lean
def mustEsc (bol : Bool) (c : Char) (next : Option Char) : Bool
```

Whether a character of a description is written escaped: Typst's markup characters
always; `=`, `-` and `+` at the start of a line (a heading or a list item); `/` before
`/` or `*` (a comment).

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.escT">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.escT" title="Esm.Document.Source.Typ.escT"><code>escT</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Typst.lean#L110-L112">source</a></div>

```lean
def escT : Bool → List Char → List Char
```

A description's text in a content block.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.readEsc">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.readEsc" title="Esm.Document.Source.Typ.readEsc"><code>readEsc</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Typst.lean#L115-L120">source</a></div>

```lean
def readEsc : List Char → Option (List Char × List Char)
```

The text of a content block up to its unescaped `]`.

</div>

## Named arguments

<div class="lean-decl" id="Esm.Document.Source.Typ.argT">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.argT" title="Esm.Document.Source.Typ.argT"><code>argT</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Typst.lean#L139">source</a></div>

```lean
def argT (a : String × Json) : List Char
```

`key: value`.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.pArg">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.pArg" title="Esm.Document.Source.Typ.pArg"><code>pArg</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Typst.lean#L142-L147">source</a></div>

```lean
def pArg (F : Nat) (s : List Char) : Option ((String × Json) × List Char)
```

One named argument at its key.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.pArgsMore">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.pArgsMore" title="Esm.Document.Source.Typ.pArgsMore"><code>pArgsMore</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Typst.lean#L150-L154">source</a></div>

```lean
def pArgsMore (F : Nat) : Nat → List Char → Option (List (String × Json) × List Char)
```

`, key: value` repeated, up to `)`.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.pArgsFirst">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.pArgsFirst" title="Esm.Document.Source.Typ.pArgsFirst"><code>pArgsFirst</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Typst.lean#L157-L159">source</a></div>

```lean
def pArgsFirst (F f : Nat) : List Char → Option (List (String × Json) × List Char)
```

Arguments directly after `(`.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.argsMoreT">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.argsMoreT" title="Esm.Document.Source.Typ.argsMoreT"><code>argsMoreT</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Typst.lean#L162">source</a></div>

```lean
def argsMoreT (as : List (String × Json)) : List Char
```

Arguments after a first positional one: each `, key: value`.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.argsFirstT">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.argsFirstT" title="Esm.Document.Source.Typ.argsFirstT"><code>argsFirstT</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Typst.lean#L165-L167">source</a></div>

```lean
def argsFirstT : List (String × Json) → List Char
```

Arguments directly after `(`.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.argOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.argOK" title="Esm.Document.Source.Typ.argOK"><code>argOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Typst.lean#L170">source</a></div>

```lean
def argOK (a : String × Json) : Bool
```

A named argument Typst can carry: an identifier key that is not a keyword.

</div>

## Constructs

<div class="lean-decl" id="Esm.Document.Source.Typ.declT">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.declT" title="Esm.Document.Source.Typ.declT"><code>declT</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Typst.lean#L183">source</a></div>

```lean
def declT (d : Decl) : List Char
```

`#var($N$, default: 100)`.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.lineEnd">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.lineEnd" title="Esm.Document.Source.Typ.lineEnd"><code>lineEnd</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Typst.lean#L186-L187">source</a></div>

```lean
def lineEnd (t : List Char) : Option (List Char)
```

The rest of a construct's line must be blank.

</div>

## Reactions

<div class="lean-decl" id="Esm.Document.Source.Typ.typR">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.typR" title="Esm.Document.Source.Typ.typR"><code>typR</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Typst.lean#L192">source</a></div>

```lean
def typR : RSurf
```

The math surface of reaction sides: Typst math under the empty symbol table.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.coreT">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.coreT" title="Esm.Document.Source.Typ.coreT"><code>coreT</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Typst.lean#L198-L199">source</a></div>

```lean
def coreT (x : Rxn String) : List Char
```

The chemistry of a reaction: the sides and the rate over the arrow.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.rxnT">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.rxnT" title="Esm.Document.Source.Typ.rxnT"><code>rxnT</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Typst.lean#L203-L207">source</a></div>

```lean
def rxnT (x : Rxn String) : List Char
```

A reaction line: `#ce[…] <id>`, or `#reaction(…)[#ce[…]] <id>` with its other
fields.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.coreAt">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.coreAt" title="Esm.Document.Source.Typ.coreAt"><code>coreAt</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Typst.lean#L210-L226">source</a></div>

```lean
def coreAt (F : Nat) (u : List Char) :
    Option (Option (List Term) × List Char × Option (List Term) × List Char)
```

The chemistry of a reaction: subs, rate, prods, and the text after the products.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.labelAt">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.labelAt" title="Esm.Document.Source.Typ.labelAt"><code>labelAt</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Typst.lean#L229-L237">source</a></div>

```lean
def labelAt (u : List Char) : Option (String × List Char)
```

The label `<id>` and the end of the line.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.ceAt">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.ceAt" title="Esm.Document.Source.Typ.ceAt"><code>ceAt</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Typst.lean#L240-L246">source</a></div>

```lean
def ceAt (F : Nat) (u : List Char) : Option (RItem × List Char)
```

A reaction after `#ce[`.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.rxnAtT">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.rxnAtT" title="Esm.Document.Source.Typ.rxnAtT"><code>rxnAtT</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Typst.lean#L249-L261">source</a></div>

```lean
def rxnAtT (F : Nat) (u : List Char) : Option (RItem × List Char)
```

A reaction after `#reaction(`.

</div>

## Templates and rules

A template is a display whose math starts with its header, `$ op("f")(a, b) := body $`;
with other fields it is wrapped, `#template(key: value, …)[$ op("f")(a, b) := body $]`. A
rule is `#rule("r", $lhs$, $rhs$, key: value, …)`. The header (the name, the parameters
as names under the empty symbol table) is read here, by the lexer; only the body and
the left-hand side are math.

<div class="lean-decl" id="Esm.Document.Source.Typ.tmRawT">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.tmRawT" title="Esm.Document.Source.Typ.tmRawT"><code>tmRawT</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Typst.lean#L281-L282">source</a></div>

```lean
def tmRawT (t : Tm String) : List Char
```

The math text of a template display (one line).

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.nameLenT">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.nameLenT" title="Esm.Document.Source.Typ.nameLenT"><code>nameLenT</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Typst.lean#L287-L303">source</a></div>

```lean
def nameLenT : Nat → Bool → List Char → Nat
```

The length of a parameter name's Typst math: up to the first `,` or `)` outside
parentheses and string literals, since a name prints with both (`italic("Ea")`,
`A_(upright("pre"))`). `d` is the parenthesis depth, `q` whether inside a string.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.pNameT">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.pNameT" title="Esm.Document.Source.Typ.pNameT"><code>pNameT</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Typst.lean#L306-L309">source</a></div>

```lean
def pNameT (s : List Char) : Option (String × List Char)
```

A parameter name in a template header, read as Typst math.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.tmLexT">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.tmLexT" title="Esm.Document.Source.Typ.tmLexT"><code>tmLexT</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Typst.lean#L328-L337">source</a></div>

```lean
def tmLexT (raw : List Char) : Option (String × List String × List Char)
```

Read the math text of a display as a template: its name, parameters and body text.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.itemT">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.itemT" title="Esm.Document.Source.Typ.itemT"><code>itemT</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Typst.lean#L340-L358">source</a></div>

```lean
def itemT : RItem → List Char
```

The text of a construct.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.eqnLabeled">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.eqnLabeled" title="Esm.Document.Source.Typ.eqnLabeled"><code>eqnLabeled</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Typst.lean#L361-L362">source</a></div>

```lean
def eqnLabeled (raw : String) (label : List Char) : List Char
```

A display equation with a label after it (` <eq-x>`).

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.labelOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.labelOK" title="Esm.Document.Source.Typ.labelOK"><code>labelOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Typst.lean#L365-L369">source</a></div>

```lean
def labelOK (sl : List Char) : Bool
```

A label after a display equation: nothing, or `<id>`, with spaces around.

</div>

## The lexer

<div class="lean-decl" id="Esm.Document.Source.Typ.dispItem">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.dispItem" title="Esm.Document.Source.Typ.dispItem"><code>dispItem</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Typst.lean#L398-L401">source</a></div>

```lean
def dispItem (raw : List Char) : RItem
```

A display's construct from its math text: a template when it reads as one, else an
equation.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.tmplAtT">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.tmplAtT" title="Esm.Document.Source.Typ.tmplAtT"><code>tmplAtT</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Typst.lean#L412-L426">source</a></div>

```lean
def tmplAtT (F : Nat) (u : List Char) : Option (RItem × List Char)
```

A template with other fields, after `#template(`.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.ruleAtT">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.ruleAtT" title="Esm.Document.Source.Typ.ruleAtT"><code>ruleAtT</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Typst.lean#L429-L448">source</a></div>

```lean
def ruleAtT (F : Nat) (u : List Char) : Option (RItem × List Char)
```

A rule, after `#rule(`.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.eqxAt">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.eqxAt" title="Esm.Document.Source.Typ.eqxAt"><code>eqxAt</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Typst.lean#L451-L459">source</a></div>

```lean
def eqxAt (ro : Role) (u : List Char) : Option (RItem × List Char)
```

An equation in a container after its opener: `$ … $]`.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.subAtT">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.subAtT" title="Esm.Document.Source.Typ.subAtT"><code>subAtT</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Typst.lean#L462-L468">source</a></div>

```lean
def subAtT (F : Nat) (u : List Char) : Option (RItem × List Char)
```

A subsystem directive after `#subsystem(`.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.plotAtT">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.plotAtT" title="Esm.Document.Source.Typ.plotAtT"><code>plotAtT</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Typst.lean#L471-L474">source</a></div>

```lean
def plotAtT (F : Nat) (u : List Char) : Option (RItem × List Char)
```

A plot directive after `#plot(`.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.lex">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.lex" title="Esm.Document.Source.Typ.lex"><code>lex</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Typst.lean#L508-L516">source</a></div>

```lean
def lex : Nat → Bool → List Char → Option (List RItem)
```

**The Typst lexer**: the constructs of a text, skipping prose one character at a
time.

</div>

## Reading back the pieces

<div class="lean-decl lean-theorem" id="Esm.Document.Source.Typ.size_le_argT">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.Typ.size_le_argT" title="Esm.Document.Source.Typ.size_le_argT"><code>size_le_argT</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Typst.lean#L541-L543">source</a></div>

```lean
theorem size_le_argT (a : String × Json) : a.2.size ≤ (argT a).length
```

The fuel the value reader needs, bounded by the text.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.typsiumOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.typsiumOK" title="Esm.Document.Source.Typ.typsiumOK"><code>typsiumOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Typst.lean#L604-L606">source</a></div>

```lean
def typsiumOK (x : Rxn String) : Bool
```

What typsium and the Typst parser read as written inside `#ce[…]`: no `//` or `/*`,
which would open a comment and swallow the rest of the line.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.rxnOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.rxnOK" title="Esm.Document.Source.Typ.rxnOK"><code>rxnOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Typst.lean#L610-L612">source</a></div>

```lean
def rxnOK (x : Rxn String) : Bool
```

A reaction the Typst syntax can hold: sides the side syntax holds, a rate on one line
without `$`, an id label, named arguments Typst can carry, and nothing typsium misreads.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.declOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.declOK" title="Esm.Document.Source.Typ.declOK"><code>declOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Typst.lean#L615">source</a></div>

```lean
def declOK (d : Decl) : Bool
```

A declaration the Typst syntax can hold.

</div>

## Documents, prose and validity

<div class="lean-decl" id="Esm.Document.Source.Typ.Seg">
<div class="lean-decl-head"><span class="lean-kind">inductive</span> <a class="lean-name" href="#Esm.Document.Source.Typ.Seg" title="Esm.Document.Source.Typ.Seg"><code>Seg</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Typst.lean#L662-L665">source</a></div>

```lean
inductive Seg where
  | item (it : RItem)
  | labeled (raw : String) (label : List Char)
  | prose (p : List Char)
```

A piece of a Typst document: a construct, a labelled equation, or prose.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.itemOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.itemOK" title="Esm.Document.Source.Typ.itemOK"><code>itemOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Typst.lean#L685-L697">source</a></div>

```lean
def itemOK : RItem → Bool
```

What each construct's content must satisfy for its text to read back.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.Inert">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.Inert" title="Esm.Document.Source.Typ.Inert"><code>Inert</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Typst.lean#L700-L703">source</a></div>

```lean
def Inert : Bool → List Char → List Char → Prop
```

Prose that the lexer skips.

</div>

## Lexing, construct by construct

### Containers

### Subsystems

### Plots

### Templates and rules

### Reactions

<div class="lean-decl lean-theorem" id="Esm.Document.Source.Typ.lex_render">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.Typ.lex_render" title="Esm.Document.Source.Typ.lex_render"><code>lex_render</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Typst.lean#L1170-L1244">source</a></div>

```lean
theorem lex_render : ∀ (segs : List Seg) (bol : Bool), Valid bol segs →
    ∀ f, (render segs).length < f → lex f bol (render segs) = some (segItems segs)
```

**The Typst lexer reads back every valid document body**: exactly its constructs,
whatever prose surrounds them and whatever labels the equations carry.

</div>

<p class="lean-meta">This module also proves 49 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Source/Typst.lean">the source</a>.</p>
