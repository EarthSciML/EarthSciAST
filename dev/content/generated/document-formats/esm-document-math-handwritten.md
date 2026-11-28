---
title: "Hand-written input"
type: lean
lean_module: "Esm.Document.Math.HandWritten"
weight: 16
---

<p class="lean-meta">Lean module <code>Esm.Document.Math.HandWritten</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/HandWritten.lean"><code>formal/Esm/Document/Math/HandWritten.lean</code></a> at <code>9c3b4aa7587e</code><br>Imports <a href="/generated/document-formats/esm-document-math-roundtriplatex"><code>Esm.Document.Math.RoundTripLatex</code></a>, <a href="/generated/document-formats/esm-document-math-roundtriptypst"><code>Esm.Document.Math.RoundTripTypst</code></a></p>

The round-trip theorems cover what the printer writes; these checks cover spellings a
person writes and the printer never does: binary minus without spaces, scientific
literals spaced any way, `\,` between names, the italic-d derivative against declared
names, field keys with LaTeX-special characters, and JSON strings. Each is evaluated by
the kernel.

<div class="lean-decl" id="Esm.Document.Math.HandWritten.reads">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.HandWritten.reads" title="Esm.Document.Math.HandWritten.reads"><code>reads</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/HandWritten.lean#L19-L22">source</a></div>

```lean
def reads (o : Option Json) (e : Json) : Bool
```

The parse is `e`.

</div>

## Binary minus and negative literals

<div class="lean-decl" id="Esm.Document.Math.HandWritten.L45">
<div class="lean-decl-head"><span class="lean-kind">example</span> <a class="lean-name" href="#Esm.Document.Math.HandWritten.L45">¶</a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/HandWritten.lean#L45">source</a></div>

```lean
example : reads (parseLatex S "k-0") (node "-" [k, int 0]) = true
```

`-0` is a minus sign and `0`: the literal has no sign to carry.

</div>

## Scientific literals

<div class="lean-decl" id="Esm.Document.Math.HandWritten.L67">
<div class="lean-decl-head"><span class="lean-kind">example</span> <a class="lean-name" href="#Esm.Document.Math.HandWritten.L67">¶</a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/HandWritten.lean#L67-L68">source</a></div>

```lean
example : reads (parseLatex S "3 \\times 10^{n}") (node "*" [int 3, node "^" [int 10, .str "n"]]) = true
```

A non-integer exponent is not the literal shape: an ordinary product.

</div>

## The thin space

## The italic-d derivative and declared names

## Operators in the source formats (esm-spec §1.2, esm 2.4.0)

<div class="lean-decl" id="Esm.Document.Math.HandWritten.L94">
<div class="lean-decl-head"><span class="lean-kind">example</span> <a class="lean-name" href="#Esm.Document.Math.HandWritten.L94">¶</a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/HandWritten.lean#L94">source</a></div>

```lean
example : reads (parseLatex S "\\frac{\\partial x}{\\partial a}") (pNode x "a") = true
```

A derivative along an axis other than `t` is `partial`, whichever differential writes it.

</div>

<div class="lean-decl" id="Esm.Document.Math.HandWritten.L97">
<div class="lean-decl-head"><span class="lean-kind">example</span> <a class="lean-name" href="#Esm.Document.Math.HandWritten.L97">¶</a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/HandWritten.lean#L97">source</a></div>

```lean
example : reads (parseLatex S "\\frac{\\partial x}{\\partial t}") (dNode x "t") = true
```

Along `t`, `\\partial` reads as the time derivative `D`.

</div>

<div class="lean-decl" id="Esm.Document.Math.HandWritten.L99">
<div class="lean-decl-head"><span class="lean-kind">example</span> <a class="lean-name" href="#Esm.Document.Math.HandWritten.L99">¶</a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/HandWritten.lean#L99">source</a></div>

```lean
example : reads (parseLatex S "\\partial_{a}(x, k)") (dCallNode "a" [x, k]) = true
```

The trailing-operand form, and the earlier `\\operatorname{D}_{x}` spelling of it.

</div>

<div class="lean-decl" id="Esm.Document.Math.HandWritten.L104">
<div class="lean-decl-head"><span class="lean-kind">example</span> <a class="lean-name" href="#Esm.Document.Math.HandWritten.L104">¶</a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/HandWritten.lean#L104">source</a></div>

```lean
example : reads (parseLatex S "\\nabla x") (node "grad" [x]) = true
```

The four `\\nabla` forms, told apart by what follows `\\nabla`.

</div>

<div class="lean-decl" id="Esm.Document.Math.HandWritten.L113">
<div class="lean-decl-head"><span class="lean-kind">example</span> <a class="lean-name" href="#Esm.Document.Math.HandWritten.L113">¶</a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/HandWritten.lean#L113-L114">source</a></div>

```lean
example : reads (parseLatex S "\\nabla \\cdot \\nabla x") (node "div" [node "grad" [x]]) = true
```

Trees, not identities: `\\nabla \\cdot \\nabla x` is `div(grad(x))`.

</div>

<div class="lean-decl" id="Esm.Document.Math.HandWritten.L116">
<div class="lean-decl-head"><span class="lean-kind">example</span> <a class="lean-name" href="#Esm.Document.Math.HandWritten.L116">¶</a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/HandWritten.lean#L116-L117">source</a></div>

```lean
example : reads (parseLatex S "\\nabla x \\cdot k") (node "*" [node "grad" [x], k]) = true
```

The operand is read at the level of a power base: `\\nabla x k` is a product with `grad(x)`.

</div>

<div class="lean-decl" id="Esm.Document.Math.HandWritten.L119">
<div class="lean-decl-head"><span class="lean-kind">example</span> <a class="lean-name" href="#Esm.Document.Math.HandWritten.L119">¶</a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/HandWritten.lean#L119">source</a></div>

```lean
example : (parseLatex S "\\nabla x^{2}").isNone = true
```

`\\nabla x^{2}` is refused: the operand of a `\\nabla` form is not a power.

</div>

<div class="lean-decl" id="Esm.Document.Math.HandWritten.L126">
<div class="lean-decl-head"><span class="lean-kind">example</span> <a class="lean-name" href="#Esm.Document.Math.HandWritten.L126">¶</a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/HandWritten.lean#L126">source</a></div>

```lean
example : reads (parseLatex Sd "\\frac{dx}{dt}") (dNode x "t") = true
```

Neither `dx` nor `dt` declared: the derivative of `x`.

</div>

<div class="lean-decl" id="Esm.Document.Math.HandWritten.L130">
<div class="lean-decl-head"><span class="lean-kind">example</span> <a class="lean-name" href="#Esm.Document.Math.HandWritten.L130">¶</a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/HandWritten.lean#L130-L131">source</a></div>

```lean
example : reads (parseLatex Sdx "\\frac{dx}{dt}") (node "/" [.str "dx", .str "dt"]) = true
```

`dx` and `dt` declared: the declared whole words win, a quotient.

</div>

<div class="lean-decl" id="Esm.Document.Math.HandWritten.L135">
<div class="lean-decl-head"><span class="lean-kind">example</span> <a class="lean-name" href="#Esm.Document.Math.HandWritten.L135">¶</a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/HandWritten.lean#L135">source</a></div>

```lean
example : (parseLatex Sdx1 "\\frac{dx}{dt}").isNone = true
```

Only `dx` declared: no derivative, and `dt` is unknown, so the input is refused.

</div>

## Field keys

<div class="lean-decl" id="Esm.Document.Math.HandWritten.L140">
<div class="lean-decl-head"><span class="lean-kind">example</span> <a class="lean-name" href="#Esm.Document.Math.HandWritten.L140">¶</a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/HandWritten.lean#L140-L141">source</a></div>

```lean
example : Latex.render (keyToks .latex "a%b$") = "\\mathrm{a{\\char037}b{\\char036}}".toList
```

A key with LaTeX-special characters prints with each written `{\char NNN}`.

</div>

<div class="lean-decl" id="Esm.Document.Math.HandWritten.L144">
<div class="lean-decl-head"><span class="lean-kind">example</span> <a class="lean-name" href="#Esm.Document.Math.HandWritten.L144">¶</a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/HandWritten.lean#L144-L145">source</a></div>

```lean
example : reads (parseLatex S "\\operatorname{foo}(x; \\mathrm{a{\\char037}b} = 1)")
    (mkNode "foo" [x] [("a%b", int 1)]) = true
```

And reads back.

</div>

<div class="lean-decl" id="Esm.Document.Math.HandWritten.oddKey">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.HandWritten.oddKey" title="Esm.Document.Math.HandWritten.oddKey"><code>oddKey</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/HandWritten.lean#L149">source</a></div>

```lean
def oddKey : Json
```

A node whose field key is not an identifier prints in the escape form, where the key
is a JSON string with `%` and `$` as `\uXXXX`: no raw `%` or `$` reaches the LaTeX.

</div>

## JSON strings render in KaTeX's text mode

<div class="lean-decl" id="Esm.Document.Math.HandWritten.strOp">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.HandWritten.strOp" title="Esm.Document.Math.HandWritten.strOp"><code>strOp</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/HandWritten.lean#L158">source</a></div>

```lean
def strOp : Json
```

An open operator with a string field holding braces.

</div>

<div class="lean-decl" id="Esm.Document.Math.HandWritten.L162">
<div class="lean-decl-head"><span class="lean-kind">example</span> <a class="lean-name" href="#Esm.Document.Math.HandWritten.L162">¶</a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/HandWritten.lean#L162-L163">source</a></div>

```lean
example : printLatex S strOp = "\\operatorname{myop}(k; \\mathrm{s} = \\text{\"a\\{b\\}\"})"
```

The string prints inside `\text{"…"}` with the braces escaped, not as `\u007B`, which
KaTeX refuses in math mode ("accent \u works only in text mode").

</div>

<div class="lean-decl" id="Esm.Document.Math.HandWritten.oddStr">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.HandWritten.oddStr" title="Esm.Document.Math.HandWritten.oddStr"><code>oddStr</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/HandWritten.lean#L169">source</a></div>

```lean
def oddStr : Json
```

Every other awkward character is `{\char NNN}`: `$`, `%`, `~`, `\`, a line break, a
non-ASCII letter, and (seven digits) a character above 999. No `$` or line break reaches
the LaTeX, and it reads back.

</div>

<div class="lean-decl" id="Esm.Document.Math.HandWritten.L177">
<div class="lean-decl-head"><span class="lean-kind">example</span> <a class="lean-name" href="#Esm.Document.Math.HandWritten.L177">¶</a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/HandWritten.lean#L177-L178">source</a></div>

```lean
example : reads (parseLatex S "\\operatorname{myop}(k; \\mathrm{s} = \"a\\u007Bb\\u007D\")") strOp = true
```

The earlier spelling, the string double-quoted with JSON escapes in math mode, still
reads.

</div>

## Array notation (2026-11-15)

<div class="lean-decl" id="Esm.Document.Math.HandWritten.L184">
<div class="lean-decl-head"><span class="lean-kind">example</span> <a class="lean-name" href="#Esm.Document.Math.HandWritten.L184">¶</a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/HandWritten.lean#L184">source</a></div>

```lean
example : reads (parseLatex S "\\operatorname{dlon}") (tNode "dlon" []) = true
```

A bare `\operatorname{n}` is a template applied with no bindings; with `()` it is an
open operator with no operands.

</div>

<div class="lean-decl" id="Esm.Document.Math.HandWritten.L190">
<div class="lean-decl-head"><span class="lean-kind">example</span> <a class="lean-name" href="#Esm.Document.Math.HandWritten.L190">¶</a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/HandWritten.lean#L190-L191">source</a></div>

```lean
example : reads (parseLatex S "a \\times [x + 1]") (node "*" [a, node "+" [x, int 1]]) = true
```

`\times [` outside a region is still a product with a bracket group.

</div>

<div class="lean-decl" id="Esm.Document.Math.HandWritten.table">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.HandWritten.table" title="Esm.Document.Math.HandWritten.table"><code>table</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/HandWritten.lean#L198-L199">source</a></div>

```lean
def table : Json
```

A `makearray` table, the region product spaced any way.

</div>

<div class="lean-decl" id="Esm.Document.Math.HandWritten.filtSet">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.HandWritten.filtSet" title="Esm.Document.Math.HandWritten.filtSet"><code>filtSet</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/HandWritten.lean#L209-L211">source</a></div>

```lean
def filtSet : Json
```

A lone equality filter followed by a superscript set is the filter, not a dense range.

</div>
