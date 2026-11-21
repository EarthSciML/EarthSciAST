---
title: "Hand-written input"
type: lean
lean_module: "Esm.Document.Math.HandWritten"
weight: 16
---

<p class="lean-meta">Lean module <code>Esm.Document.Math.HandWritten</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/HandWritten.lean"><code>formal/Esm/Document/Math/HandWritten.lean</code></a> at <code>1b8dd9b3a909</code><br>Imports <a href="/generated/document-formats/esm-document-math-roundtriplatex"><code>Esm.Document.Math.RoundTripLatex</code></a>, <a href="/generated/document-formats/esm-document-math-roundtriptypst"><code>Esm.Document.Math.RoundTripTypst</code></a></p>

The round-trip theorems cover what the printer writes; these checks cover spellings a
person writes and the printer never does: binary minus without spaces, scientific
literals spaced any way, `\,` between names, the italic-d derivative against declared
names, field keys with LaTeX-special characters, and JSON strings. Each is evaluated by
the kernel.

<div class="lean-decl" id="Esm.Document.Math.HandWritten.reads">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.HandWritten.reads" title="Esm.Document.Math.HandWritten.reads"><code>reads</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/HandWritten.lean#L19-L22">source</a></div>

```lean
def reads (o : Option Json) (e : Json) : Bool
```

The parse is `e`.

</div>

## Binary minus and negative literals

<div class="lean-decl" id="Esm.Document.Math.HandWritten.L45">
<div class="lean-decl-head"><span class="lean-kind">example</span> <a class="lean-name" href="#Esm.Document.Math.HandWritten.L45">¶</a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/HandWritten.lean#L45">source</a></div>

```lean
example : reads (parseLatex S "k-0") (node "-" [k, int 0]) = true
```

`-0` is a minus sign and `0`: the literal has no sign to carry.

</div>

## Scientific literals

<div class="lean-decl" id="Esm.Document.Math.HandWritten.L67">
<div class="lean-decl-head"><span class="lean-kind">example</span> <a class="lean-name" href="#Esm.Document.Math.HandWritten.L67">¶</a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/HandWritten.lean#L67-L68">source</a></div>

```lean
example : reads (parseLatex S "3 \\times 10^{n}") (node "*" [int 3, node "^" [int 10, .str "n"]]) = true
```

A non-integer exponent is not the literal shape: an ordinary product.

</div>

## The thin space

## The italic-d derivative and declared names

<div class="lean-decl" id="Esm.Document.Math.HandWritten.L96">
<div class="lean-decl-head"><span class="lean-kind">example</span> <a class="lean-name" href="#Esm.Document.Math.HandWritten.L96">¶</a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/HandWritten.lean#L96">source</a></div>

```lean
example : reads (parseLatex Sd "\\frac{dx}{dt}") (dNode x "t") = true
```

Neither `dx` nor `dt` declared: the derivative of `x`.

</div>

<div class="lean-decl" id="Esm.Document.Math.HandWritten.L100">
<div class="lean-decl-head"><span class="lean-kind">example</span> <a class="lean-name" href="#Esm.Document.Math.HandWritten.L100">¶</a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/HandWritten.lean#L100-L101">source</a></div>

```lean
example : reads (parseLatex Sdx "\\frac{dx}{dt}") (node "/" [.str "dx", .str "dt"]) = true
```

`dx` and `dt` declared: the declared whole words win, a quotient.

</div>

<div class="lean-decl" id="Esm.Document.Math.HandWritten.L105">
<div class="lean-decl-head"><span class="lean-kind">example</span> <a class="lean-name" href="#Esm.Document.Math.HandWritten.L105">¶</a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/HandWritten.lean#L105">source</a></div>

```lean
example : (parseLatex Sdx1 "\\frac{dx}{dt}").isNone = true
```

Only `dx` declared: no derivative, and `dt` is unknown, so the input is refused.

</div>

## Field keys

<div class="lean-decl" id="Esm.Document.Math.HandWritten.L110">
<div class="lean-decl-head"><span class="lean-kind">example</span> <a class="lean-name" href="#Esm.Document.Math.HandWritten.L110">¶</a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/HandWritten.lean#L110-L111">source</a></div>

```lean
example : Latex.render (keyToks .latex "a%b$") = "\\mathrm{a{\\char037}b{\\char036}}".toList
```

A key with LaTeX-special characters prints with each written `{\char NNN}`.

</div>

<div class="lean-decl" id="Esm.Document.Math.HandWritten.L114">
<div class="lean-decl-head"><span class="lean-kind">example</span> <a class="lean-name" href="#Esm.Document.Math.HandWritten.L114">¶</a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/HandWritten.lean#L114-L115">source</a></div>

```lean
example : reads (parseLatex S "\\operatorname{foo}(x; \\mathrm{a{\\char037}b} = 1)")
    (mkNode "foo" [x] [("a%b", int 1)]) = true
```

And reads back.

</div>

<div class="lean-decl" id="Esm.Document.Math.HandWritten.oddKey">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.HandWritten.oddKey" title="Esm.Document.Math.HandWritten.oddKey"><code>oddKey</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/HandWritten.lean#L119">source</a></div>

```lean
def oddKey : Json
```

A node whose field key is not an identifier prints in the escape form, where the key
is a JSON string with `%` and `$` as `\uXXXX`: no raw `%` or `$` reaches the LaTeX.

</div>

## JSON strings render in KaTeX's text mode

<div class="lean-decl" id="Esm.Document.Math.HandWritten.strOp">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.HandWritten.strOp" title="Esm.Document.Math.HandWritten.strOp"><code>strOp</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/HandWritten.lean#L128">source</a></div>

```lean
def strOp : Json
```

An open operator with a string field holding braces.

</div>

<div class="lean-decl" id="Esm.Document.Math.HandWritten.L132">
<div class="lean-decl-head"><span class="lean-kind">example</span> <a class="lean-name" href="#Esm.Document.Math.HandWritten.L132">¶</a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/HandWritten.lean#L132-L133">source</a></div>

```lean
example : printLatex S strOp = "\\operatorname{myop}(k; \\mathrm{s} = \\text{\"a\\{b\\}\"})"
```

The string prints inside `\text{"…"}` with the braces escaped, not as `\u007B`, which
KaTeX refuses in math mode ("accent \u works only in text mode").

</div>

<div class="lean-decl" id="Esm.Document.Math.HandWritten.oddStr">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.HandWritten.oddStr" title="Esm.Document.Math.HandWritten.oddStr"><code>oddStr</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/HandWritten.lean#L139">source</a></div>

```lean
def oddStr : Json
```

Every other awkward character is `{\char NNN}`: `$`, `%`, `~`, `\`, a line break, a
non-ASCII letter, and (seven digits) a character above 999. No `$` or line break reaches
the LaTeX, and it reads back.

</div>

<div class="lean-decl" id="Esm.Document.Math.HandWritten.L147">
<div class="lean-decl-head"><span class="lean-kind">example</span> <a class="lean-name" href="#Esm.Document.Math.HandWritten.L147">¶</a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/HandWritten.lean#L147-L148">source</a></div>

```lean
example : reads (parseLatex S "\\operatorname{myop}(k; \\mathrm{s} = \"a\\u007Bb\\u007D\")") strOp = true
```

The earlier spelling, the string double-quoted with JSON escapes in math mode, still
reads.

</div>

## Array notation (2026-11-15)

<div class="lean-decl" id="Esm.Document.Math.HandWritten.L154">
<div class="lean-decl-head"><span class="lean-kind">example</span> <a class="lean-name" href="#Esm.Document.Math.HandWritten.L154">¶</a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/HandWritten.lean#L154">source</a></div>

```lean
example : reads (parseLatex S "\\operatorname{dlon}") (tNode "dlon" []) = true
```

A bare `\operatorname{n}` is a template applied with no bindings; with `()` it is an
open operator with no operands.

</div>

<div class="lean-decl" id="Esm.Document.Math.HandWritten.L160">
<div class="lean-decl-head"><span class="lean-kind">example</span> <a class="lean-name" href="#Esm.Document.Math.HandWritten.L160">¶</a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/HandWritten.lean#L160-L161">source</a></div>

```lean
example : reads (parseLatex S "a \\times [x + 1]") (node "*" [a, node "+" [x, int 1]]) = true
```

`\times [` outside a region is still a product with a bracket group.

</div>

<div class="lean-decl" id="Esm.Document.Math.HandWritten.table">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.HandWritten.table" title="Esm.Document.Math.HandWritten.table"><code>table</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/HandWritten.lean#L168-L169">source</a></div>

```lean
def table : Json
```

A `makearray` table, the region product spaced any way.

</div>

<div class="lean-decl" id="Esm.Document.Math.HandWritten.filtSet">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.HandWritten.filtSet" title="Esm.Document.Math.HandWritten.filtSet"><code>filtSet</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/HandWritten.lean#L179-L181">source</a></div>

```lean
def filtSet : Json
```

A lone equality filter followed by a superscript set is the filter, not a dense range.

</div>
