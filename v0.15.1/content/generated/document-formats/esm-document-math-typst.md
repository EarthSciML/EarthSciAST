---
title: "Typst math: spelling and lexing of tokens"
type: lean
lean_module: "Esm.Document.Math.Typst"
weight: 10
---

<p class="lean-meta">Lean module <code>Esm.Document.Math.Typst</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Typst.lean"><code>formal/Esm/Document/Math/Typst.lean</code></a> at <code>86bed77c797f</code><br>Imports <a href="/generated/document-formats/esm-document-math-parse"><code>Esm.Document.Math.Parse</code></a>, <a href="/generated/document-formats/esm-document-math-surface"><code>Esm.Document.Math.Surface</code></a>, <a href="/generated/document-formats/esm-document-strings"><code>Esm.Document.Strings</code></a>, <a href="/generated/document-formats/esm-document-typstdict"><code>Esm.Document.TypstDict</code></a></p>

`render` spells a token list as Typst math; [`lex`](#Esm.Document.Math.Typst.lex) reads it back. Typst has one
parenthesis: the printer uses the grouping token `lpg` for every `(`, and the
renderer writes no space between a function name and its `(` (Typst calls a function
only then) and a space between an operand and a following `(` (juxtaposition).

Spellings: numbers in the canonical spelling, scientific ones as
`1.8 times 10^(-12)` (read back as one literal, with any spacing:
`1.8times 10^( -12 )` too; [`Esm.Document.Math.Surface`](/generated/document-formats/esm-document-math-surface)); names as `italic("…")`, formulas and
name subscripts as runs of adjacent `upright("…")` pieces each with an optional digit
subscript (`upright("CH")_2upright("O")`; a space between two pieces separates two
names); the scope dot as `"."` (a bare `.` after a Greek name is a symbol modifier in
Typst); call-form operators `op("…")`; text `"…"`; JSON values of an escape node as
`#` and the Typst value ([`Esm.Document.TypstDict`](/generated/document-formats/esm-document-typstdict)); a unit block
`thin upright("m") thin upright("s")^(-1)` after a number ([`Esm.Units.Typeset`](/generated/document-formats/esm-units-typeset)).

Accepted on input and never written: a bare `.` as the scope dot.

## Spelling

## Spacing

<div class="lean-decl" id="Esm.Document.Math.Typst.merges">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Typst.merges" title="Esm.Document.Math.Typst.merges"><code>merges</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Typst.lean#L90-L100">source</a></div>

```lean
def merges (t : Tok) (c : Char) : Bool
```

A space is needed between `t` and a following token starting with `c`.

</div>

<div class="lean-decl" id="Esm.Document.Math.Typst.callEnd">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Typst.callEnd" title="Esm.Document.Math.Typst.callEnd"><code>callEnd</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Typst.lean#L103-L106">source</a></div>

```lean
def callEnd (t : Tok) : Bool
```

`t` ends with a character after which `(` is a call parenthesis.

</div>

<div class="lean-decl" id="Esm.Document.Math.Typst.isHead">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Typst.isHead" title="Esm.Document.Math.Typst.isHead"><code>isHead</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Typst.lean#L126-L132">source</a></div>

```lean
def isHead : Tok → Bool
```

Function names: no space before their `(`.

</div>

<div class="lean-decl" id="Esm.Document.Math.Typst.sp">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Typst.sp" title="Esm.Document.Math.Typst.sp"><code>sp</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Typst.lean#L142-L143">source</a></div>

```lean
def sp (p : Option Tok) (t1 t2 : Tok) : Bool
```

No space before a call parenthesis, nor before the `[` of an index (`k[1]`).

</div>

## Lexing

<div class="lean-decl" id="Esm.Document.Math.Typst.idRun">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Typst.idRun" title="Esm.Document.Math.Typst.idRun"><code>idRun</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Typst.lean#L155-L157">source</a></div>

```lean
def idRun : List Char → List Char × List Char
```

The maximal run of identifier characters.

</div>

<div class="lean-decl" id="Esm.Document.Math.Typst.quotedArg">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Typst.quotedArg" title="Esm.Document.Math.Typst.quotedArg"><code>quotedArg</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Typst.lean#L169-L175">source</a></div>

```lean
def quotedArg (r : List Char) : Option (String × List Char)
```

`("…")` after a function name.

</div>

<div class="lean-decl" id="Esm.Document.Math.Typst.pieces">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Typst.pieces" title="Esm.Document.Math.Typst.pieces"><code>pieces</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Typst.lean#L178-L192">source</a></div>

```lean
def pieces : Nat → List Char → List (String × String) × List Char
```

Adjacent `upright("…")` pieces, each with an optional digit subscript.

</div>

<div class="lean-decl" id="Esm.Document.Math.Typst.sciExp">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Typst.sciExp" title="Esm.Document.Math.Typst.sciExp"><code>sciExp</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Typst.lean#L198-L218">source</a></div>

```lean
def sciExp (r : List Char) : Option (Int × List Char)
```

The scientific tail `times 10^exponent` after a mantissa (the exponent bare or in
parentheses), with any white space (none included) between its parts.

</div>

<div class="lean-decl" id="Esm.Document.Math.Typst.uprightE">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Typst.uprightE" title="Esm.Document.Math.Typst.uprightE"><code>uprightE</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Typst.lean#L230-L232">source</a></div>

```lean
def uprightE : List Char → Option (Tok × List Char)
```

`upright(e)`, Euler's number written without quotes (an accepted variant, read as
`upright("e")`; the printer always quotes).

</div>

<div class="lean-decl" id="Esm.Document.Math.Typst.lexIdent">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Typst.lexIdent" title="Esm.Document.Math.Typst.lexIdent"><code>lexIdent</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Typst.lean#L235-L262">source</a></div>

```lean
def lexIdent (cs : List Char) : Option (Tok × List Char)
```

One identifier-started token.

</div>

<div class="lean-decl" id="Esm.Document.Math.Typst.lexOne">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Typst.lexOne" title="Esm.Document.Math.Typst.lexOne"><code>lexOne</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Typst.lean#L267-L284">source</a></div>

```lean
def lexOne (prev : Option Char) (cs : List Char) : Option (Tok × List Char)
```

One token at the front of the input; `prev` is the character just before it, if no
space came between (`(` right after a name, a digit, `)` or `"` is a call
parenthesis).

</div>

<div class="lean-decl" id="Esm.Document.Math.Typst.lexAux">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Typst.lexAux" title="Esm.Document.Math.Typst.lexAux"><code>lexAux</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Typst.lean#L289-L298">source</a></div>

```lean
def lexAux : Nat → Option Char → List Char → Option (List Tok)
```

The tokens of the input; `prev` is the last character of the previous token's
spelling when no space came between (the canonical spelling: every token's input
spellings end in a character of the same kind for the call-parenthesis test).

</div>

<div class="lean-decl" id="Esm.Document.Math.Typst.lex">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Typst.lex" title="Esm.Document.Math.Typst.lex"><code>lex</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Typst.lean#L301">source</a></div>

```lean
def lex (cs : List Char) : Option (List Tok)
```

Read Typst math into tokens.

</div>
