---
title: "The Typst container"
type: lean
lean_module: "Esm.Document.Source.Typst"
weight: 60
---

<p class="lean-meta">Lean module <code>Esm.Document.Source.Typst</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean"><code>formal/Esm/Document/Source/Typst.lean</code></a> at <code>9c3b4aa7587e</code><br>Imports <a href="/generated/document-formats/esm-document-source-reaction"><code>Esm.Document.Source.Reaction</code></a>, <a href="/generated/document-formats/esm-document-source-equation"><code>Esm.Document.Source.Equation</code></a></p>

An ESM document in Typst is markup plus the functions of an `esm` Typst package:

```
#import "@preview/esm:0.1.0": *
#show: esm-document.with(esm: "2.4.0", name: "Decay")

#description[First-order radioactive decay.]

#model("Decay")

#var($N$, default: 100, units: "mol")

$ (dif N)/(dif t) = -lambda N $
```

The constructs ([`Esm.Document.Source.RItem`](/generated/document-formats/esm-document-source-items#Esm.Document.Source.RItem)), and where they may appear:

* the header: the `#import` line, then `#show: esm-document.with(…)` with the
  front-matter entries as named arguments (values in the Typst value syntax,
  [`Esm.Document.TypstDict`](/generated/document-formats/esm-document-typstdict));
* at the start of a line: `#description[…]` (the text verbatim, as Typst markup, when
  that is safe to typeset, [`verbOK`](#Esm.Document.Source.Typ.verbOK)) or `#description("…")` (the text as a Typst string),
  `#esm-block("key", value)` (a path block), `#model("Name")`
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
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.oRole" title="Esm.Document.Source.Typ.oRole"><code>oRole</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L93-L96">source</a></div>

```lean
def oRole : Role → List Char
```

The opener of the equation container of a role.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.header">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.header" title="Esm.Document.Source.Typ.header"><code>header</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L98">source</a></div>

```lean
def header : List Char
```

The header's first line and the start of its second.

</div>

## Description text

A description is written verbatim, as Typst markup in a content block
(`#description[…]`), when that markup is safe to typeset ([`verbOK`](#Esm.Document.Source.Typ.verbOK)); otherwise it is a
Typst string, `#description("…")`, which typesets as plain text. So a description
written for Typst (backticks for code, a `-` list) keeps its markup, and one written as
plain text with `a * b` or `$5` in it still compiles. "Safe" is a syntactic test that
every description of the corpus it holds for compiles (decided 2026-11-25): none of
`#`, `$`, `@`, `\`, `<`, `*`, `~`, none of `//`, `/*` (a comment) or `--`, `-?`, `...`
(shorthands that typeset differently from the text), every `_` between two ASCII
letters or digits, balanced brackets outside backtick raw spans and none inside one,
and every raw span closed.

The reader reads a content block as Typst does: inside a backtick raw span every
character is literal; outside one a backslash escapes the character after it
(`\u{…}` is a code point) and brackets nest. So an earlier document, which wrote every
description with its markup characters escaped (`First\-order`), reads as it did.

<div class="lean-decl" id="Esm.Document.Source.Typ.alnumA">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.alnumA" title="Esm.Document.Source.Typ.alnumA"><code>alnumA</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L119">source</a></div>

```lean
def alnumA (c : Char) : Bool
```

An ASCII letter or digit.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.noSeq">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.noSeq" title="Esm.Document.Source.Typ.noSeq"><code>noSeq</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L122-L129">source</a></div>

```lean
def noSeq : List Char → Bool
```

No `//` or `/*` (a Typst comment), and none of the shorthands `--`, `-?` and `...`.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.usOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.usOK" title="Esm.Document.Source.Typ.usOK"><code>usOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L132-L135">source</a></div>

```lean
def usOK : Option Char → List Char → Bool
```

Every `_` between two ASCII letters or digits (`p`: the character before).

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.bal">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.bal" title="Esm.Document.Source.Typ.bal"><code>bal</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L140-L149">source</a></div>

```lean
def bal : Nat → Bool → List Char → Bool
```

The brackets balance outside backtick raw spans, from depth `d` (`raw`: inside a raw
span, which every backtick opens or closes); no bracket is inside a raw span, and the
last raw span closes.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.verbOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.verbOK" title="Esm.Document.Source.Typ.verbOK"><code>verbOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L152-L154">source</a></div>

```lean
def verbOK (s : List Char) : Bool
```

Whether a description is written verbatim (above).

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.readVerb">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.readVerb" title="Esm.Document.Source.Typ.readVerb"><code>readVerb</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L160-L170">source</a></div>

```lean
def readVerb : Nat → Bool → List Char → Option (List Char × List Char)
```

The text of a content block from depth `d` (`raw`: inside a backtick raw span) up to
the `]` that closes it: a raw span's characters as they are, and outside one each
backslash escape read as the character it escapes.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.readUni">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.readUni" title="Esm.Document.Source.Typ.readUni"><code>readUni</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L174-L179">source</a></div>

```lean
def readUni : Nat → Option Nat → List Char → Option (List Char × List Char)
```

A content block after `\u{` (`n`: the value of the hex digits so far): one or more
hex digits, then `}`, a Unicode scalar value.

</div>

## Named arguments

<div class="lean-decl" id="Esm.Document.Source.Typ.argT">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.argT" title="Esm.Document.Source.Typ.argT"><code>argT</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L221">source</a></div>

```lean
def argT (a : String × Json) : List Char
```

`key: value`.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.pArg">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.pArg" title="Esm.Document.Source.Typ.pArg"><code>pArg</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L224-L229">source</a></div>

```lean
def pArg (F : Nat) (s : List Char) : Option ((String × Json) × List Char)
```

One named argument at its key.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.pArgsMore">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.pArgsMore" title="Esm.Document.Source.Typ.pArgsMore"><code>pArgsMore</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L232-L236">source</a></div>

```lean
def pArgsMore (F : Nat) : Nat → List Char → Option (List (String × Json) × List Char)
```

`, key: value` repeated, up to `)`.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.pArgsFirst">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.pArgsFirst" title="Esm.Document.Source.Typ.pArgsFirst"><code>pArgsFirst</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L239-L241">source</a></div>

```lean
def pArgsFirst (F f : Nat) : List Char → Option (List (String × Json) × List Char)
```

Arguments directly after `(`.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.argsMoreT">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.argsMoreT" title="Esm.Document.Source.Typ.argsMoreT"><code>argsMoreT</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L244">source</a></div>

```lean
def argsMoreT (as : List (String × Json)) : List Char
```

Arguments after a first positional one: each `, key: value`.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.argsFirstT">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.argsFirstT" title="Esm.Document.Source.Typ.argsFirstT"><code>argsFirstT</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L247-L249">source</a></div>

```lean
def argsFirstT : List (String × Json) → List Char
```

Arguments directly after `(`.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.argOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.argOK" title="Esm.Document.Source.Typ.argOK"><code>argOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L252">source</a></div>

```lean
def argOK (a : String × Json) : Bool
```

A named argument Typst can carry: an identifier key that is not a keyword.

</div>

## Constructs

<div class="lean-decl" id="Esm.Document.Source.Typ.declT">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.declT" title="Esm.Document.Source.Typ.declT"><code>declT</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L265">source</a></div>

```lean
def declT (d : Decl) : List Char
```

`#var($N$, default: 100)`.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.lineEnd">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.lineEnd" title="Esm.Document.Source.Typ.lineEnd"><code>lineEnd</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L268-L269">source</a></div>

```lean
def lineEnd (t : List Char) : Option (List Char)
```

The rest of a construct's line must be blank.

</div>

## Reactions

<div class="lean-decl" id="Esm.Document.Source.Typ.typR">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.typR" title="Esm.Document.Source.Typ.typR"><code>typR</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L274">source</a></div>

```lean
def typR : RSurf
```

The math surface of reaction sides: Typst math under the empty symbol table.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.coreT">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.coreT" title="Esm.Document.Source.Typ.coreT"><code>coreT</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L280-L281">source</a></div>

```lean
def coreT (x : Rxn String) : List Char
```

The chemistry of a reaction: the sides and the rate over the arrow.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.rxnT">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.rxnT" title="Esm.Document.Source.Typ.rxnT"><code>rxnT</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L285-L289">source</a></div>

```lean
def rxnT (x : Rxn String) : List Char
```

A reaction line: `#ce[…] <id>`, or `#reaction(…)[#ce[…]] <id>` with its other
fields.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.coreAt">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.coreAt" title="Esm.Document.Source.Typ.coreAt"><code>coreAt</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L292-L308">source</a></div>

```lean
def coreAt (F : Nat) (u : List Char) :
    Option (Option (List Term) × List Char × Option (List Term) × List Char)
```

The chemistry of a reaction: subs, rate, prods, and the text after the products.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.labelAt">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.labelAt" title="Esm.Document.Source.Typ.labelAt"><code>labelAt</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L311-L319">source</a></div>

```lean
def labelAt (u : List Char) : Option (String × List Char)
```

The label `<id>` and the end of the line.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.ceAt">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.ceAt" title="Esm.Document.Source.Typ.ceAt"><code>ceAt</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L322-L328">source</a></div>

```lean
def ceAt (F : Nat) (u : List Char) : Option (RItem × List Char)
```

A reaction after `#ce[`.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.rxnAtT">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.rxnAtT" title="Esm.Document.Source.Typ.rxnAtT"><code>rxnAtT</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L331-L343">source</a></div>

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
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.tmRawT" title="Esm.Document.Source.Typ.tmRawT"><code>tmRawT</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L363-L364">source</a></div>

```lean
def tmRawT (t : Tm String) : List Char
```

The math text of a template display (one line).

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.nameLenT">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.nameLenT" title="Esm.Document.Source.Typ.nameLenT"><code>nameLenT</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L369-L385">source</a></div>

```lean
def nameLenT : Nat → Bool → List Char → Nat
```

The length of a parameter name's Typst math: up to the first `,` or `)` outside
parentheses and string literals, since a name prints with both (`italic("Ea")`,
`A_(upright("pre"))`). `d` is the parenthesis depth, `q` whether inside a string.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.pNameT">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.pNameT" title="Esm.Document.Source.Typ.pNameT"><code>pNameT</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L388-L391">source</a></div>

```lean
def pNameT (s : List Char) : Option (String × List Char)
```

A parameter name in a template header, read as Typst math.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.tmLexT">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.tmLexT" title="Esm.Document.Source.Typ.tmLexT"><code>tmLexT</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L410-L419">source</a></div>

```lean
def tmLexT (raw : List Char) : Option (String × List String × List Char)
```

Read the math text of a display as a template: its name, parameters and body text.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.descBody">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.descBody" title="Esm.Document.Source.Typ.descBody"><code>descBody</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L423-L425">source</a></div>

```lean
def descBody (s : String) : List Char
```

A description after `#description`: verbatim in a content block when [`verbOK`](#Esm.Document.Source.Typ.verbOK),
else a Typst string in parentheses.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.itemT">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.itemT" title="Esm.Document.Source.Typ.itemT"><code>itemT</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L428-L446">source</a></div>

```lean
def itemT : RItem → List Char
```

The text of a construct.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.eqnLabeled">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.eqnLabeled" title="Esm.Document.Source.Typ.eqnLabeled"><code>eqnLabeled</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L449-L450">source</a></div>

```lean
def eqnLabeled (raw : String) (label : List Char) : List Char
```

A display equation with a label after it (` <eq-x>`).

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.labelOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.labelOK" title="Esm.Document.Source.Typ.labelOK"><code>labelOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L453-L457">source</a></div>

```lean
def labelOK (sl : List Char) : Bool
```

A label after a display equation: nothing, or `<id>`, with spaces around.

</div>

## The lexer

<div class="lean-decl" id="Esm.Document.Source.Typ.descOpen">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.descOpen" title="Esm.Document.Source.Typ.descOpen"><code>descOpen</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L463">source</a></div>

```lean
def descOpen (s : List Char) : Bool
```

A description opener, `#description[` or `#description(` (a line such as
`#description-note[…]` is prose).

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.descAt">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.descAt" title="Esm.Document.Source.Typ.descAt"><code>descAt</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L473-L479">source</a></div>

```lean
def descAt : List Char → Option (RItem × List Char)
```

A description after `#description`: a content block, or a string in parentheses.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.dispItem">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.dispItem" title="Esm.Document.Source.Typ.dispItem"><code>dispItem</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L496-L499">source</a></div>

```lean
def dispItem (raw : List Char) : RItem
```

A display's construct from its math text: a template when it reads as one, else an
equation.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.tmplAtT">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.tmplAtT" title="Esm.Document.Source.Typ.tmplAtT"><code>tmplAtT</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L510-L524">source</a></div>

```lean
def tmplAtT (F : Nat) (u : List Char) : Option (RItem × List Char)
```

A template with other fields, after `#template(`.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.ruleAtT">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.ruleAtT" title="Esm.Document.Source.Typ.ruleAtT"><code>ruleAtT</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L527-L546">source</a></div>

```lean
def ruleAtT (F : Nat) (u : List Char) : Option (RItem × List Char)
```

A rule, after `#rule(`.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.eqxAt">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.eqxAt" title="Esm.Document.Source.Typ.eqxAt"><code>eqxAt</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L549-L557">source</a></div>

```lean
def eqxAt (ro : Role) (u : List Char) : Option (RItem × List Char)
```

An equation in a container after its opener: `$ … $]`.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.subAtT">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.subAtT" title="Esm.Document.Source.Typ.subAtT"><code>subAtT</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L560-L566">source</a></div>

```lean
def subAtT (F : Nat) (u : List Char) : Option (RItem × List Char)
```

A subsystem directive after `#subsystem(`.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.plotAtT">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.plotAtT" title="Esm.Document.Source.Typ.plotAtT"><code>plotAtT</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L569-L572">source</a></div>

```lean
def plotAtT (F : Nat) (u : List Char) : Option (RItem × List Char)
```

A plot directive after `#plot(`.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.lex">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.lex" title="Esm.Document.Source.Typ.lex"><code>lex</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L606-L614">source</a></div>

```lean
def lex : Nat → Bool → List Char → Option (List RItem)
```

**The Typst lexer**: the constructs of a text, skipping prose one character at a
time.

</div>

## Reading back the pieces

<div class="lean-decl lean-theorem" id="Esm.Document.Source.Typ.size_le_argT">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.Typ.size_le_argT" title="Esm.Document.Source.Typ.size_le_argT"><code>size_le_argT</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L639-L641">source</a></div>

```lean
theorem size_le_argT (a : String × Json) : a.2.size ≤ (argT a).length
```

The fuel the value reader needs, bounded by the text.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.typsiumOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.typsiumOK" title="Esm.Document.Source.Typ.typsiumOK"><code>typsiumOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L702-L704">source</a></div>

```lean
def typsiumOK (x : Rxn String) : Bool
```

What typsium and the Typst parser read as written inside `#ce[…]`: no `//` or `/*`,
which would open a comment and swallow the rest of the line.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.rxnOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.rxnOK" title="Esm.Document.Source.Typ.rxnOK"><code>rxnOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L708-L710">source</a></div>

```lean
def rxnOK (x : Rxn String) : Bool
```

A reaction the Typst syntax can hold: sides the side syntax holds, a rate on one line
without `$`, an id label, named arguments Typst can carry, and nothing typsium misreads.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.declOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.declOK" title="Esm.Document.Source.Typ.declOK"><code>declOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L713">source</a></div>

```lean
def declOK (d : Decl) : Bool
```

A declaration the Typst syntax can hold.

</div>

## Documents, prose and validity

<div class="lean-decl" id="Esm.Document.Source.Typ.Seg">
<div class="lean-decl-head"><span class="lean-kind">inductive</span> <a class="lean-name" href="#Esm.Document.Source.Typ.Seg" title="Esm.Document.Source.Typ.Seg"><code>Seg</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L760-L763">source</a></div>

```lean
inductive Seg where
  | item (it : RItem)
  | labeled (raw : String) (label : List Char)
  | prose (p : List Char)
```

A piece of a Typst document: a construct, a labelled equation, or prose.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.itemOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.itemOK" title="Esm.Document.Source.Typ.itemOK"><code>itemOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L783-L795">source</a></div>

```lean
def itemOK : RItem → Bool
```

What each construct's content must satisfy for its text to read back.

</div>

<div class="lean-decl" id="Esm.Document.Source.Typ.Inert">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Typ.Inert" title="Esm.Document.Source.Typ.Inert"><code>Inert</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L798-L801">source</a></div>

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
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.Typ.lex_render" title="Esm.Document.Source.Typ.lex_render"><code>lex_render</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean#L1296-L1370">source</a></div>

```lean
theorem lex_render : ∀ (segs : List Seg) (bol : Bool), Valid bol segs →
    ∀ f, (render segs).length < f → lex f bol (render segs) = some (segItems segs)
```

**The Typst lexer reads back every valid document body**: exactly its constructs,
whatever prose surrounds them and whatever labels the equations carry.

</div>

<p class="lean-meta">This module also proves 51 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/Typst.lean">the source</a>.</p>
