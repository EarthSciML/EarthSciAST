---
title: "The parser: tokens to expressions"
type: lean
lean_module: "Esm.Document.Math.Parse"
weight: 14
---

<p class="lean-meta">Lean module <code>Esm.Document.Math.Parse</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean"><code>formal/Esm/Document/Math/Parse.lean</code></a> at <code>ffd5aee2f868</code><br>Imports <a href="/generated/document-formats/esm-document-math-print"><code>Esm.Document.Math.Print</code></a></p>

Recursive descent with one function per precedence level ([`Esm.Document.Math.Print`](/generated/document-formats/esm-document-math-print)
lists the levels), each taking fuel. The `+`, `*`, `and` and `or` chains are read
into one n-ary node; binary `-`, the comparisons and the Typst fraction `/` group to
the left; unary `-` takes a whole product (`-a b` is `-(a b)`, spec §4.1.1); `^` takes
a postfix-level base and one exponent.

Accepted variants are read here too (the printer never writes them), each with a
lemma in [`Esm.Document.Math.Variants`](/generated/document-formats/esm-document-math-variants).

## Small pieces

<div class="lean-decl" id="Esm.Document.Math.close">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.close" title="Esm.Document.Math.close"><code>close</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L27-L29">source</a></div>

```lean
def close (o : String) : List Json → Json
```

Close an n-ary chain: one operand is itself, more make a node.

</div>

<div class="lean-decl" id="Esm.Document.Math.cmpOf">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.cmpOf" title="Esm.Document.Math.cmpOf"><code>cmpOf</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L32-L39">source</a></div>

```lean
def cmpOf : Kw → Option String
```

The comparison a token spells.

</div>

<div class="lean-decl" id="Esm.Document.Math.fnOf">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.fnOf" title="Esm.Document.Math.fnOf"><code>fnOf</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L42-L54">source</a></div>

```lean
def fnOf : Kw → Option String
```

The unary function a keyword spells.

</div>

<div class="lean-decl" id="Esm.Document.Math.atomStart">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.atomStart" title="Esm.Document.Math.atomStart"><code>atomStart</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L58-L68">source</a></div>

```lean
def atomStart : Tok → Bool
```

Tokens that can start an operand of a product: juxtaposition continues a product
when the next token is one of these.

</div>

<div class="lean-decl" id="Esm.Document.Math.isLp">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.isLp" title="Esm.Document.Math.isLp"><code>isLp</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L71-L73">source</a></div>

```lean
def isLp : Tok → Bool
```

An opening parenthesis: `(` or `\left(`; the parser reads them alike.

</div>

<div class="lean-decl" id="Esm.Document.Math.isRp">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.isRp" title="Esm.Document.Math.isRp"><code>isRp</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L76-L78">source</a></div>

```lean
def isRp : Tok → Bool
```

The closing token of a group: `)` or `\right)`.

</div>

## Names

<div class="lean-decl" id="Esm.Document.Math.decodeFormula">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.decodeFormula" title="Esm.Document.Math.decodeFormula"><code>decodeFormula</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L83">source</a></div>

```lean
def decodeFormula (raw : List Char) : List Char
```

The name a formula token spells, if it is formula-shaped.

</div>

<div class="lean-decl" id="Esm.Document.Math.subOrPlain">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.subOrPlain" title="Esm.Document.Math.subOrPlain"><code>subOrPlain</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L100-L104">source</a></div>

```lean
def subOrPlain (sf : Sf) (b : List Char) (r : List Tok) : List Char × List Tok
```

A single letter or Greek base, then an optional upright name subscript.

</div>

<div class="lean-decl" id="Esm.Document.Math.pSeg">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pSeg" title="Esm.Document.Math.pSeg"><code>pSeg</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L107-L112">source</a></div>

```lean
def pSeg (sf : Sf) : List Tok → Option (List Char × List Tok)
```

One name segment.

</div>

<div class="lean-decl" id="Esm.Document.Math.pNameLoop">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pNameLoop" title="Esm.Document.Math.pNameLoop"><code>pNameLoop</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L115-L121">source</a></div>

```lean
def pNameLoop (sf : Sf) : Nat → List Char → List Tok → Option (List Char × List Tok)
```

A name: segments joined by the scope dot.

</div>

## JSON inside LaTeX escape nodes

## Negative literals after an operand

<div class="lean-decl" id="Esm.Document.Math.negTok">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.negTok" title="Esm.Document.Math.negTok"><code>negTok</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L171-L173">source</a></div>

```lean
def negTok : Tok → Bool
```

A negative literal token.

</div>

<div class="lean-decl" id="Esm.Document.Math.negate">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.negate" title="Esm.Document.Math.negate"><code>negate</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L176-L178">source</a></div>

```lean
def negate : JNum → JNum
```

The number with the opposite sign.

</div>

<div class="lean-decl" id="Esm.Document.Math.negTail">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.negTail" title="Esm.Document.Math.negTail"><code>negTail</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L184-L186">source</a></div>

```lean
def negTail : List Tok → Option (List Tok)
```

A negative literal right after an operand (`k-1`, `k -1`) is a binary minus and a
positive number: the tokens with the sign moved off the number, when the number without
its sign has a canonical form (the negation of `-2^63` has none, so that spelling is
refused after an operand).

</div>

## Expressions

<div class="lean-decl" id="Esm.Document.Math.mkNodeP">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.mkNodeP" title="Esm.Document.Math.mkNodeP"><code>mkNodeP</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L191">source</a></div>

```lean
def mkNodeP (o : String) (as : List Json) (fs : List (String × Json)) : Json
```

Rebuild a node with fields: `op` and `args` go back to their sorted places.

</div>

<div class="lean-decl" id="Esm.Document.Math.CallArg">
<div class="lean-decl-head"><span class="lean-kind">inductive</span> <a class="lean-name" href="#Esm.Document.Math.CallArg" title="Esm.Document.Math.CallArg"><code>CallArg</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L194-L196">source</a></div>

```lean
inductive CallArg where
  | pos (v : Json)
  | named (k : String) (v : Json)
```

What [`pCallArgs`](#Esm.Document.Math.pCallArgs) read: positional arguments, or named ones.

</div>

<div class="lean-decl" id="Esm.Document.Math.sortKV">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.sortKV" title="Esm.Document.Math.sortKV"><code>sortKV</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L209-L211">source</a></div>

```lean
def sortKV : List (String × Json) → List (String × Json)
```

Sort bindings by key (insertion).

</div>

<div class="lean-decl" id="Esm.Document.Math.unitsOfRaw">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.unitsOfRaw" title="Esm.Document.Math.unitsOfRaw"><code>unitsOfRaw</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L214-L215">source</a></div>

```lean
def unitsOfRaw (raw : String) : Option (List Esm.Units.Factor)
```

The unit a LaTeX `\mathrm{…}` after a number spells.

</div>

<div class="lean-decl" id="Esm.Document.Math.qty">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.qty" title="Esm.Document.Math.qty"><code>qty</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L218-L219">source</a></div>

```lean
def qty (n : JNum) (l : List Esm.Units.Factor) : Json
```

A quantity node.

</div>

<div class="lean-decl" id="Esm.Document.Math.dNode">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.dNode" title="Esm.Document.Math.dNode"><code>dNode</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L222">source</a></div>

```lean
def dNode (x : Json) (w : String) : Json
```

A derivative node.

</div>

<div class="lean-decl" id="Esm.Document.Math.tNode">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.tNode" title="Esm.Document.Math.tNode"><code>tNode</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L225-L226">source</a></div>

```lean
def tNode (n : String) (bs : List (String × Json)) : Json
```

A template application node.

</div>

<div class="lean-decl" id="Esm.Document.Math.constNode">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.constNode" title="Esm.Document.Math.constNode"><code>constNode</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L229-L231">source</a></div>

```lean
def constNode (v : Json) : Option String → Json
```

A constant node: the value, and the units when there are some.

</div>

<div class="lean-decl" id="Esm.Document.Math.pCells">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pCells" title="Esm.Document.Math.pCells"><code>pCells</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L234-L237">source</a></div>

```lean
def pCells (sep : Kw) : List Tok → Option (List JNum × List Tok)
```

Numbers separated by `sep`, up to the first other token.

</div>

<div class="lean-decl" id="Esm.Document.Math.pGrid">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pGrid" title="Esm.Document.Math.pGrid"><code>pGrid</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L240-L247">source</a></div>

```lean
def pGrid (csep rsep close : Kw) : Nat → List Tok → Option (List (List JNum) × List Tok)
```

Rows of numbers: cells separated by `csep`, rows by `rsep`, closed by [`close`](#Esm.Document.Math.close).

</div>

<div class="lean-decl" id="Esm.Document.Math.gridJson">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.gridJson" title="Esm.Document.Math.gridJson"><code>gridJson</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L250-L252">source</a></div>

```lean
def gridJson (rows : List (List JNum)) : Json
```

A LaTeX `bmatrix`: one cell per row is a column (rank 1).

</div>

<div class="lean-decl" id="Esm.Document.Math.constTail">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.constTail" title="Esm.Document.Math.constTail"><code>constTail</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L255-L258">source</a></div>

```lean
def constTail (v : Json) (r : List Tok) : Option (Json × List Tok)
```

The unit after an array, if any.

</div>

<div class="lean-decl" id="Esm.Document.Math.icTailP">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.icTailP" title="Esm.Document.Math.icTailP"><code>icTailP</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L261-L267">source</a></div>

```lean
def icTailP (sf : Sf) : List Tok → Option (List Tok)
```

The `ic` tail `(t_{0})` / `(t_0)`.

</div>

<div class="lean-decl" id="Esm.Document.Math.jsonStart">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.jsonStart" title="Esm.Document.Math.jsonStart"><code>jsonStart</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L270-L272">source</a></div>

```lean
def jsonStart : List Tok → Bool
```

A LaTeX field value that is JSON starts with `{`, `[`, a string or a word.

</div>

<div class="lean-decl" id="Esm.Document.Math.keyOf">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.keyOf" title="Esm.Document.Math.keyOf"><code>keyOf</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L275-L279">source</a></div>

```lean
def keyOf (c : Ctx) (ts : List Tok) : Option (String × List Tok)
```

A field key: LaTeX `\mathrm{key} =`, Typst `upright("key") =`.

</div>

<div class="lean-decl" id="Esm.Document.Math.dCallNode">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.dCallNode" title="Esm.Document.Math.dCallNode"><code>dCallNode</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L282-L283">source</a></div>

```lean
def dCallNode (w : String) (xs : List Json) : Json
```

A spatial derivative with trailing operands.

</div>

<div class="lean-decl" id="Esm.Document.Math.eulerHead">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.eulerHead" title="Esm.Document.Math.eulerHead"><code>eulerHead</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L287-L291">source</a></div>

```lean
def eulerHead (c : Ctx) : List Tok → Bool
```

The input starts with Euler's number raised to a power: an upright `e`, or an
italic `e` when no variable `e` is declared.

</div>

<div class="lean-decl" id="Esm.Document.Math.pNamePrim">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pNamePrim" title="Esm.Document.Math.pNamePrim"><code>pNamePrim</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L294-L300">source</a></div>

```lean
def pNamePrim (c : Ctx) (ts : List Tok) : Option (Json × List Tok)
```

A name, or an initial condition `N(t_{0})`.

</div>

<div class="lean-decl" id="Esm.Document.Math.pWord">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pWord" title="Esm.Document.Math.pWord"><code>pWord</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L304-L309">source</a></div>

```lean
def pWord (c : Ctx) (w : String) (r : List Tok) : Option (Json × List Tok)
```

A bare run of letters (`RT`): the declared name when only it is declared, the
product of its letters when only they are, refused otherwise (ambiguous or unknown).

</div>

<div class="lean-decl" id="Esm.Document.Math.dName">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.dName" title="Esm.Document.Math.dName"><code>dName</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L313-L324">source</a></div>

```lean
def dName (c : Ctx) (k : Kw) : List Tok → Option (String × List Tok)
```

`d` then a name, up to a closing token `k`: `dN}` (a run of letters that is not
itself a declared name) or `d N}`.

</div>

<div class="lean-decl" id="Esm.Document.Math.pItalicD">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pItalicD" title="Esm.Document.Math.pItalicD"><code>pItalicD</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L330-L341">source</a></div>

```lean
def pItalicD (c : Ctx) (r : List Tok) : Option (Json × List Tok)
```

The italic-d derivative variant, when no variable `d` is declared and neither
`dN` nor `dt` written as one word is a declared name (a declared whole word wins, as in
[`pWord`](#Esm.Document.Math.pWord): `\frac{dx}{dt}` with `dx` and `dt` declared is their quotient): LaTeX
`\frac{dN}{dt}` after `\frac{`, Typst `(d N)/(d t)` after the first `(`.

</div>

<div class="lean-decl" id="Esm.Document.Math.isKw">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.isKw" title="Esm.Document.Math.isKw"><code>isKw</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L344-L346">source</a></div>

```lean
def isKw (k : Kw) : Tok → Bool
```

The token is the keyword `k`.

</div>

<div class="lean-decl" id="Esm.Document.Math.Row">
<div class="lean-decl-head"><span class="lean-kind">inductive</span> <a class="lean-name" href="#Esm.Document.Math.Row" title="Esm.Document.Math.Row"><code>Row</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L350-L352">source</a></div>

```lean
inductive Row where
  | rng (k : String) (v : Json)
  | filt (x : Json)
```

A row of a reduction's subscript, or an output entry: a range, or an expression
(the filter, or a bare output entry).

</div>

<div class="lean-decl" id="Esm.Document.Math.pRedHead">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pRedHead" title="Esm.Document.Math.pRedHead"><code>pRedHead</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L363-L369">source</a></div>

```lean
def pRedHead (sf : Sf) : List Tok → Option (RedK × Bool × List Tok)
```

The operator of a reduction and whether it is marked (`args` listed): LaTeX
`\sum\limits`, Typst `limits(sum)`.

</div>

<div class="lean-decl" id="Esm.Document.Math.pNames">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pNames" title="Esm.Document.Math.pNames"><code>pNames</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L372-L378">source</a></div>

```lean
def pNames (sf : Sf) : Nat → List Tok → Option (List String × List Tok)
```

Names separated by commas.

</div>

<div class="lean-decl" id="Esm.Document.Math.rowParts">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.rowParts" title="Esm.Document.Math.rowParts"><code>rowParts</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L381-L385">source</a></div>

```lean
def rowParts : List Row → Option (List (String × Json) × Option Json)
```

The ranges and the filter of a list of rows: ranges, then at most one filter, last.

</div>

<div class="lean-decl" id="Esm.Document.Math.entryParts">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.entryParts" title="Esm.Document.Math.entryParts"><code>entryParts</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L388-L393">source</a></div>

```lean
def entryParts : List Row → Option (List Json × List (String × Json))
```

The output entries of a list of entry rows, with their ranges.

</div>

<div class="lean-decl" id="Esm.Document.Math.withOut">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.withOut" title="Esm.Document.Math.withOut"><code>withOut</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L396-L397">source</a></div>

```lean
def withOut (F : FaqForm) (outs : List Json) (ors : List (String × Json)) : FaqForm
```

The node an output form reads: the reduction's parts with the output entries.

</div>

<div class="lean-decl" id="Esm.Document.Math.withSup">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.withSup" title="Esm.Document.Math.withSup"><code>withSup</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L401-L402">source</a></div>

```lean
def withSup (F : FaqForm) (st : List String) : FaqForm
```

The superscript set read after the output entries (the reduction inside the bracket
carries none, [`bracketSetOK`](#Esm.Document.Math.bracketSetOK)).

</div>

<div class="lean-decl" id="Esm.Document.Math.bracketSetOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.bracketSetOK" title="Esm.Document.Math.bracketSetOK"><code>bracketSetOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L407-L408">source</a></div>

```lean
def bracketSetOK (F : FaqForm) (st : List String) : Bool
```

The sets of an output form as the printer writes them: none on the reduction inside
the bracket (the printer writes the set on the bracket), and none at all when the
operator is marked (`args` lists the body's arrays).

</div>

<div class="lean-decl" id="Esm.Document.Math.pSup">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pSup" title="Esm.Document.Math.pSup"><code>pSup</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L412-L422">source</a></div>

```lean
def pSup (sf : Sf) (r : List Tok) : Option (List String × List Tok)
```

The superscript set of a reduction or of an output form, if there is one: LaTeX
`^{\{f, g\}}`, Typst `^({f, g})`.

</div>

<div class="lean-decl" id="Esm.Document.Math.mkTail">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.mkTail" title="Esm.Document.Math.mkTail"><code>mkTail</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L426-L437">source</a></div>

```lean
def mkTail (sf : Sf) (rows : List (Json × List (Json × Json))) (r : List Tok) : Option (Json × List Tok)
```

The `makearray` node of a table read back, with its subscript of output indices if
one follows.

</div>

<div class="lean-decl" id="Esm.Document.Math.pOr">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pOr" title="Esm.Document.Math.pOr"><code>pOr</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L441-L446">source</a></div>

```lean
def pOr (c : Ctx) : Nat → List Tok → Option (Json × List Tok)
```

Level 1: an `or` chain.

</div>

<div class="lean-decl" id="Esm.Document.Math.pAnd">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pAnd" title="Esm.Document.Math.pAnd"><code>pAnd</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L457-L462">source</a></div>

```lean
def pAnd (c : Ctx) : Nat → List Tok → Option (Json × List Tok)
```

Level 2: an `and` chain.

</div>

<div class="lean-decl" id="Esm.Document.Math.pCmp">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pCmp" title="Esm.Document.Math.pCmp"><code>pCmp</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L474-L479">source</a></div>

```lean
def pCmp (c : Ctx) : Nat → List Tok → Option (Json × List Tok)
```

Level 3: one comparison (comparisons do not chain: `a \le k \le b` is a range row of a
reduction, never an expression).

</div>

<div class="lean-decl" id="Esm.Document.Math.pAdd">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pAdd" title="Esm.Document.Math.pAdd"><code>pAdd</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L494-L499">source</a></div>

```lean
def pAdd (c : Ctx) : Nat → List Tok → Option (Json × List Tok)
```

Level 4: `+` chains and binary `-`, including a negative literal right after an
operand ([`negTail`](#Esm.Document.Math.negTail)). `x :: acc` is the pending `+` chain.

</div>

<div class="lean-decl" id="Esm.Document.Math.pMul">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pMul" title="Esm.Document.Math.pMul"><code>pMul</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L522-L531">source</a></div>

```lean
def pMul (c : Ctx) : Nat → List Tok → Option (Json × List Tok)
```

Level 5: unary minus, and `*` chains (juxtaposition, `\cdot`, `\times`; LaTeX inline
`/` groups to the left). A negative literal never continues a product by juxtaposition
(`k -1` is `k - 1`); after `\cdot` it is a factor (`k \cdot -1`).

</div>

<div class="lean-decl" id="Esm.Document.Math.pNot">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pNot" title="Esm.Document.Math.pNot"><code>pNot</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L558-L564">source</a></div>

```lean
def pNot (c : Ctx) : Nat → List Tok → Option (Json × List Tok)
```

Level 6: `not`.

</div>

<div class="lean-decl" id="Esm.Document.Math.pFrac">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pFrac" title="Esm.Document.Math.pFrac"><code>pFrac</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L567-L572">source</a></div>

```lean
def pFrac (c : Ctx) : Nat → List Tok → Option (Json × List Tok)
```

Level 7: the Typst fraction, grouping to the left.

</div>

<div class="lean-decl" id="Esm.Document.Math.pPow">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pPow" title="Esm.Document.Math.pPow"><code>pPow</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L585-L594">source</a></div>

```lean
def pPow (c : Ctx) : Nat → List Tok → Option (Json × List Tok)
```

Level 8: a power.

</div>

<div class="lean-decl" id="Esm.Document.Math.pExpo">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pExpo" title="Esm.Document.Math.pExpo"><code>pExpo</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L597-L610">source</a></div>

```lean
def pExpo (c : Ctx) : Nat → List Tok → Option (Json × List Tok)
```

An exponent: LaTeX `{…}`; Typst `(…)` or one simple token.

</div>

<div class="lean-decl" id="Esm.Document.Math.pPost">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pPost" title="Esm.Document.Math.pPost"><code>pPost</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L613-L618">source</a></div>

```lean
def pPost (c : Ctx) : Nat → List Tok → Option (Json × List Tok)
```

Level 9: postfix index, `_{…}` or `[…]`.

</div>

<div class="lean-decl" id="Esm.Document.Math.pList">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pList" title="Esm.Document.Math.pList"><code>pList</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L648-L655">source</a></div>

```lean
def pList (c : Ctx) : Nat → Nat → List Tok → Option (List Json × List Tok)
```

A comma-separated list of expressions at level `L` (1 or 4), possibly empty when
the next token closes it.

</div>

<div class="lean-decl" id="Esm.Document.Math.pLv">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pLv" title="Esm.Document.Math.pLv"><code>pLv</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L666-L668">source</a></div>

```lean
def pLv (c : Ctx) : Nat → Nat → List Tok → Option (Json × List Tok)
```

Parse at level 1 or level 4.

</div>

<div class="lean-decl" id="Esm.Document.Math.pCallArgs">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pCallArgs" title="Esm.Document.Math.pCallArgs"><code>pCallArgs</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L671-L675">source</a></div>

```lean
def pCallArgs (c : Ctx) : Nat → List Tok → Option (List CallArg × List Tok)
```

Call arguments at level 4: each positional, or `name = value`.

</div>

<div class="lean-decl" id="Esm.Document.Math.pFields">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pFields" title="Esm.Document.Math.pFields"><code>pFields</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L691-L700">source</a></div>

```lean
def pFields (c : Ctx) : Nat → List Tok → Option (List (String × Json) × List Tok)
```

Open-operator fields after `;`: `key = value`, the value as math or as JSON.

</div>

<div class="lean-decl" id="Esm.Document.Math.pVal">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pVal" title="Esm.Document.Math.pVal"><code>pVal</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L703-L711">source</a></div>

```lean
def pVal (c : Ctx) : Nat → List Tok → Option (Json × List Tok)
```

A field value: JSON (LaTeX JSON tokens, Typst `#value`) or an expression.

</div>

<div class="lean-decl" id="Esm.Document.Math.pOpn">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pOpn" title="Esm.Document.Math.pOpn"><code>pOpn</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L715-L754">source</a></div>

```lean
def pOpn (c : Ctx) : Nat → String → List Tok → Option (Json × List Tok)
```

`\operatorname{n}(…)`: a call-form core operator, a deprecated one (rewritten), a
template (by the symbol table, positional or named), or an open operator.

</div>

<div class="lean-decl" id="Esm.Document.Math.pDCall">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pDCall" title="Esm.Document.Math.pDCall"><code>pDCall</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L757-L778">source</a></div>

```lean
def pDCall (c : Ctx) : Nat → List Tok → Option (Json × List Tok)
```

`\operatorname{D}_{x}(u, a, b)` after the `_`.

</div>

<div class="lean-decl" id="Esm.Document.Math.pPrim">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pPrim" title="Esm.Document.Math.pPrim"><code>pPrim</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L781-L927">source</a></div>

```lean
def pPrim (c : Ctx) : Nat → List Tok → Option (Json × List Tok)
```

A primary.

</div>

<div class="lean-decl" id="Esm.Document.Math.pEulerExp">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pEulerExp" title="Esm.Document.Math.pEulerExp"><code>pEulerExp</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L930-L935">source</a></div>

```lean
def pEulerExp (c : Ctx) : Nat → List Tok → Option (Json × List Tok)
```

`\exp` written as a power of e.

</div>

<div class="lean-decl" id="Esm.Document.Math.pRange">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pRange" title="Esm.Document.Math.pRange"><code>pRange</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L938-L957">source</a></div>

```lean
def pRange (c : Ctx) : Nat → List Tok → Option (Row × List Tok)
```

A range row: `k \in S`, `k \in S(i, j)`, `a \le k \le b`.

</div>

<div class="lean-decl" id="Esm.Document.Math.pRow">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pRow" title="Esm.Document.Math.pRow"><code>pRow</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L961-L966">source</a></div>

```lean
def pRow (c : Ctx) : Nat → (Tok → Bool) → List Tok → Option (Row × List Tok)
```

A row ending at a token `isEnd` accepts: an expression read whole first (it never
reads a range row whole: a range row has `\in` or a second `\le`), else a range.

</div>

<div class="lean-decl" id="Esm.Document.Math.pRows">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pRows" title="Esm.Document.Math.pRows"><code>pRows</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L969-L976">source</a></div>

```lean
def pRows (c : Ctx) : Nat → Kw → Kw → List Tok → Option (List Row × List Tok)
```

Rows separated by `sep`, up to [`close`](#Esm.Document.Math.close) (consumed).

</div>

<div class="lean-decl" id="Esm.Document.Math.pRedBody">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pRedBody" title="Esm.Document.Math.pRedBody"><code>pRedBody</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L980-L1019">source</a></div>

```lean
def pRedBody (c : Ctx) : Nat → RedK → Bool → List Tok → Option (FaqForm × List Tok)
```

A reduction after its operator: the subscript rows (LaTeX: one row, a lone dense
range `k=a` with `^{b}`, or `\substack`; Typst: rows in `_( … )`), then the body.

</div>

<div class="lean-decl" id="Esm.Document.Math.pRed">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pRed" title="Esm.Document.Math.pRed"><code>pRed</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L1022-L1061">source</a></div>

```lean
def pRed (c : Ctx) : Nat → List Tok → Option (Json × List Tok)
```

A rank-0 reduction, or a reduction wrapped with its output entries.

</div>

<div class="lean-decl" id="Esm.Document.Math.pFn1">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pFn1" title="Esm.Document.Math.pFn1"><code>pFn1</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L1064-L1069">source</a></div>

```lean
def pFn1 (c : Ctx) : Nat → String → List Tok → Option (Json × List Tok)
```

`f(x)` after the opening parenthesis.

</div>

<div class="lean-decl" id="Esm.Document.Math.pFracL">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pFracL" title="Esm.Document.Math.pFracL"><code>pFracL</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L1072-L1100">source</a></div>

```lean
def pFracL (c : Ctx) : Nat → List Tok → Option (Json × List Tok)
```

After `\frac{`: a time or spatial derivative, the italic-d variant, or a quotient.

</div>

<div class="lean-decl" id="Esm.Document.Math.pDT">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pDT" title="Esm.Document.Math.pDT"><code>pDT</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L1103-L1120">source</a></div>

```lean
def pDT (c : Ctx) : Nat → Kw → List Tok → Option (Json × List Tok)
```

`(dif N)/(dif t)` and `(partial u)/(partial x)` after the first `(dif` / `(partial`.

</div>

<div class="lean-decl" id="Esm.Document.Math.pDApply">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pDApply" title="Esm.Document.Math.pDApply"><code>pDApply</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L1123-L1129">source</a></div>

```lean
def pDApply (c : Ctx) : Nat → String → List Tok → Option (Json × List Tok)
```

A derivative operator applied to a parenthesized operand.

</div>

<div class="lean-decl" id="Esm.Document.Math.pCases">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pCases" title="Esm.Document.Math.pCases"><code>pCases</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L1133-L1149">source</a></div>

```lean
def pCases (c : Ctx) : Nat → List Tok → Option (Json × List Tok)
```

`cases` rows: `value & if cond` then a row break, ending with `value & otherwise`;
a chain re-nests to the right.

</div>

<div class="lean-decl" id="Esm.Document.Math.pPair">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pPair" title="Esm.Document.Math.pPair"><code>pPair</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L1152-L1160">source</a></div>

```lean
def pPair (c : Ctx) : Nat → List Tok → Option ((Json × Json) × List Tok)
```

A bound pair after its `[`: `a, b]`.

</div>

<div class="lean-decl" id="Esm.Document.Math.pRegTail">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pRegTail" title="Esm.Document.Math.pRegTail"><code>pRegTail</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L1163-L1169">source</a></div>

```lean
def pRegTail (c : Ctx) : Nat → List Tok → Option (List (Json × Json) × List Tok)
```

The further bound pairs of a region, each after `\times [`.

</div>

<div class="lean-decl" id="Esm.Document.Math.pMkRows">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pMkRows" title="Esm.Document.Math.pMkRows"><code>pMkRows</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L1173-L1188">source</a></div>

```lean
def pMkRows (c : Ctx) : Nat → Kw → Kw → Kw → List Tok → Option (List (Json × List (Json × Json)) × List Tok)
```

The rows of a `makearray` table: a value, the cell separator `csep`, a region; rows
separated by `rsep`, up to [`close`](#Esm.Document.Math.close) (consumed).

</div>

<div class="lean-decl" id="Esm.Document.Math.pEscArgs">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.pEscArgs" title="Esm.Document.Math.pEscArgs"><code>pEscArgs</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Parse.lean#L1191-L1198">source</a></div>

```lean
def pEscArgs (c : Ctx) : Nat → List Tok → Option (List Json × List Tok)
```

Typst escape arguments: `, a` repeated, then `)`.

</div>
