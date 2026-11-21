---
title: "LaTeX math: spelling and lexing of tokens"
type: lean
lean_module: "Esm.Document.Math.Latex"
weight: 9
---

<p class="lean-meta">Lean module <code>Esm.Document.Math.Latex</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Latex.lean"><code>formal/Esm/Document/Math/Latex.lean</code></a> at <code>ffd5aee2f868</code><br>Imports <a href="/generated/document-formats/esm-document-math-parse"><code>Esm.Document.Math.Parse</code></a>, <a href="/generated/document-formats/esm-document-math-surface"><code>Esm.Document.Math.Surface</code></a>, <a href="/generated/document-formats/esm-document-strings"><code>Esm.Document.Strings</code></a></p>

[`render`](#Esm.Document.Math.Latex.render) spells a token list as LaTeX math; [`lex`](#Esm.Document.Math.Latex.lex) reads it back. Between two tokens
the renderer writes a space where the reader needs one (`needSpace`: a control word
or a letter before a letter, a number before a digit, `.` or `e`, a `-` before a
digit) and where it reads better (around binary operators, after commas, between
juxtaposed factors); the reader skips spaces. [`lex_render`](/generated/document-formats/esm-document-math-lexlatex#Esm.Document.Math.Latex.lex_render) is the lexer lemma:
every token list whose tokens are LaTeX tokens ([`tokOK`](/generated/document-formats/esm-document-math-lexlatex#Esm.Document.Math.Latex.tokOK)) reads back.

Spellings: numbers in the canonical spelling, scientific ones as
`1.8 \times 10^{-12}` (read back as one literal, with any spacing: `1.8\times10^{-12}`
too; [`Esm.Document.Math.Surface`](/generated/document-formats/esm-document-math-surface)); a quantity's unit as `\,\mathrm{…}` right after the
number, one token; `\mathit{…}`, `\operatorname{…}` and
`\esm{…}` hold their text with `\`, `{`, `}`, `_`, `^` escaped by a backslash;
`\mathrm{…}` and `\text{…}` hold raw balanced text; a JSON string (inside an escape
node's fields) is `\text{"…"}`, its characters spelled by [`escS`](#Esm.Document.Math.Latex.escS) (`_`, `{`, `}` with a
backslash, any character that is not plain printable ASCII as `{\char NNN}`), so it renders in
KaTeX's text mode and is safe inside a Markdown math span. The earlier spelling, the string
double-quoted with JSON escapes in math mode, is still read.

Accepted on input and never written: `\leq`, `\geq`, `\neq`, `\times` (outside a region), `\bigl(`,
`\bigr)`, the spacing commands `\;`, `\:`, `\!`, `\ `, `\quad`, `\qquad` and `\,` (skipped
like spaces; `\,` is the unit separator only right before a `\mathrm{…}` that spells a
unit), and JSON numbers with an `e` exponent.

## Spelling

<div class="lean-decl" id="Esm.Document.Math.Latex.specials">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Latex.specials" title="Esm.Document.Math.Latex.specials"><code>specials</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Latex.lean#L39">source</a></div>

```lean
def specials : List Char
```

Characters of a JSON string written as a hex escape in LaTeX.

</div>

<div class="lean-decl" id="Esm.Document.Math.Latex.escCharB">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Latex.escCharB" title="Esm.Document.Math.Latex.escCharB"><code>escCharB</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Latex.lean#L42-L43">source</a></div>

```lean
def escCharB (c : Char) : List Char
```

The JSON escape of one character, with the specials as hex escapes.

</div>

<div class="lean-decl" id="Esm.Document.Math.Latex.escCharL">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Latex.escCharL" title="Esm.Document.Math.Latex.escCharL"><code>escCharL</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Latex.lean#L47-L48">source</a></div>

```lean
def escCharL (c : Char) : List Char
```

The LaTeX spelling of one character of a JSON string: `_` as `\_` (so a renderer
that typesets the string does not read a subscript), otherwise [`escCharB`](#Esm.Document.Math.Latex.escCharB).

</div>

<div class="lean-decl" id="Esm.Document.Math.Latex.fixUs">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Latex.fixUs" title="Esm.Document.Math.Latex.fixUs"><code>fixUs</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Latex.lean#L52-L57">source</a></div>

```lean
def fixUs : List Char → List Char
```

Undo the `\_` of [`escCharL`](#Esm.Document.Math.Latex.escCharL) up to the closing quote, leaving the other escapes and
everything after the quote alone.

</div>

<div class="lean-decl" id="Esm.Document.Math.Latex.strPlain">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Latex.strPlain" title="Esm.Document.Math.Latex.strPlain"><code>strPlain</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Latex.lean#L63-L65">source</a></div>

```lean
def strPlain (c : Char) : Bool
```

A character of a JSON string written as itself inside `\text{…}`: printable ASCII
other than the characters TeX reads specially ([`keySpecial`](/generated/document-formats/esm-document-math-print#Esm.Document.Math.keySpecial), `_`, `{`, `}`).

</div>

<div class="lean-decl" id="Esm.Document.Math.Latex.dig7">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Latex.dig7" title="Esm.Document.Math.Latex.dig7"><code>dig7</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Latex.lean#L68-L71">source</a></div>

```lean
def dig7 (n : Nat) : List Char
```

Seven decimal digits.

</div>

<div class="lean-decl" id="Esm.Document.Math.Latex.escS">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Latex.escS" title="Esm.Document.Math.Latex.escS"><code>escS</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Latex.lean#L77-L83">source</a></div>

```lean
def escS : List Char → List Char
```

The spelling of a JSON string's characters inside `\text{"…"}`: a plain character as
itself, `_`, `{`, `}` with a backslash, and every other character as `{\char NNN}` (three
decimal digits below 1000, seven above). Every character renders in KaTeX's text mode,
none is `$` or a line break, and the braces balance.

</div>

<div class="lean-decl" id="Esm.Document.Math.Latex.unescS">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Latex.unescS" title="Esm.Document.Math.Latex.unescS"><code>unescS</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Latex.lean#L86-L95">source</a></div>

```lean
def unescS : List Char → List Char
```

Undo [`escS`](#Esm.Document.Math.Latex.escS).

</div>

<div class="lean-decl" id="Esm.Document.Math.Latex.strL">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Latex.strL" title="Esm.Document.Math.Latex.strL"><code>strL</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Latex.lean#L98">source</a></div>

```lean
def strL (s : String) : List Char
```

A JSON string in LaTeX: `\text{"…"}`, the characters spelled by [`escS`](#Esm.Document.Math.Latex.escS).

</div>

<div class="lean-decl" id="Esm.Document.Math.Latex.textTok">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Latex.textTok" title="Esm.Document.Math.Latex.textTok"><code>textTok</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Latex.lean#L101-L104">source</a></div>

```lean
def textTok (raw : List Char) : Tok
```

The token of `\text{raw}`: a JSON string when the text is double-quoted, else text.

</div>

## Spacing

<div class="lean-decl" id="Esm.Document.Math.Latex.endsAlpha">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Latex.endsAlpha" title="Esm.Document.Math.Latex.endsAlpha"><code>endsAlpha</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Latex.lean#L160-L165">source</a></div>

```lean
def endsAlpha : Tok → Bool
```

`t` ends with letters a following letter would extend: a letter, a bare word, a
Greek name or a control word.

</div>

<div class="lean-decl" id="Esm.Document.Math.Latex.merges">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Latex.merges" title="Esm.Document.Math.Latex.merges"><code>merges</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Latex.lean#L168-L171">source</a></div>

```lean
def merges (t : Tok) (c : Char) : Bool
```

A space is needed between `t` and a following token starting with `c`.

</div>

<div class="lean-decl" id="Esm.Document.Math.Latex.atomEnd">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Latex.atomEnd" title="Esm.Document.Math.Latex.atomEnd"><code>atomEnd</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Latex.lean#L179-L185">source</a></div>

```lean
def atomEnd : Tok → Bool
```

Tokens that end an operand.

</div>

<div class="lean-decl" id="Esm.Document.Math.Latex.pretty">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Latex.pretty" title="Esm.Document.Math.Latex.pretty"><code>pretty</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Latex.lean#L190-L196">source</a></div>

```lean
def pretty (p : Option Tok) (t1 t2 : Tok) : Bool
```

Spacing for reading: around binary operators (a `-` after an operand is binary),
after commas, colons and semicolons, and between juxtaposed operands (not before a call
parenthesis, and not before the `[` of an index, `k[1]`).

</div>

<div class="lean-decl" id="Esm.Document.Math.Latex.render">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Latex.render" title="Esm.Document.Math.Latex.render"><code>render</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Latex.lean#L206">source</a></div>

```lean
def render (ts : List Tok) : List Char
```

The LaTeX spelling of a token list.

</div>

## Lexing

<div class="lean-decl" id="Esm.Document.Math.Latex.ctrlKw">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Latex.ctrlKw" title="Esm.Document.Math.Latex.ctrlKw"><code>ctrlKw</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Latex.lean#L211-L219">source</a></div>

```lean
def ctrlKw : List (String × Kw)
```

Control words that are keywords, with the variants read on input.

</div>

<div class="lean-decl" id="Esm.Document.Math.Latex.ctrlTok">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Latex.ctrlTok" title="Esm.Document.Math.Latex.ctrlTok"><code>ctrlTok</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Latex.lean#L222-L269">source</a></div>

```lean
def ctrlTok (w : String) (r : List Char) : Option (Tok × List Char)
```

After a control word: its token.

</div>

<div class="lean-decl" id="Esm.Document.Math.Latex.isWsL">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Latex.isWsL" title="Esm.Document.Math.Latex.isWsL"><code>isWsL</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Latex.lean#L272">source</a></div>

```lean
def isWsL (c : Char) : Bool
```

White space.

</div>

<div class="lean-decl" id="Esm.Document.Math.Latex.skipSp">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Latex.skipSp" title="Esm.Document.Math.Latex.skipSp"><code>skipSp</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Latex.lean#L275-L283">source</a></div>

```lean
def skipSp : List Char → List Char
```

Skip white space and the two-character spacing commands, inside a scientific tail.

</div>

<div class="lean-decl" id="Esm.Document.Math.Latex.sciExp">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Latex.sciExp" title="Esm.Document.Math.Latex.sciExp"><code>sciExp</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Latex.lean#L287-L307">source</a></div>

```lean
def sciExp (r : List Char) : Option (Int × List Char)
```

The scientific tail `\times 10^{exponent}` after a mantissa, with any spacing (none
included) between its parts.

</div>

<div class="lean-decl" id="Esm.Document.Math.Latex.unitTok">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Latex.unitTok" title="Esm.Document.Math.Latex.unitTok"><code>unitTok</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Latex.lean#L310-L316">source</a></div>

```lean
def unitTok (r : List Char) : Option (List Esm.Units.Factor × List Char)
```

After `\,`: a unit `\mathrm{…}`, with white space between.

</div>

<div class="lean-decl" id="Esm.Document.Math.Latex.lexOne">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Latex.lexOne" title="Esm.Document.Math.Latex.lexOne"><code>lexOne</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Latex.lean#L327-L347">source</a></div>

```lean
def lexOne (cs : List Char) : Option (Tok × List Char)
```

One token at the front of the input.

</div>

<div class="lean-decl" id="Esm.Document.Math.Latex.skipWs">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Latex.skipWs" title="Esm.Document.Math.Latex.skipWs"><code>skipWs</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Latex.lean#L350-L364">source</a></div>

```lean
def skipWs : Nat → List Char → List Char
```

Skip spaces and the spacing commands (`\,` too, unless a unit follows it).

</div>

<div class="lean-decl" id="Esm.Document.Math.Latex.lex">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Latex.lex" title="Esm.Document.Math.Latex.lex"><code>lex</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Latex.lean#L377">source</a></div>

```lean
def lex (cs : List Char) : Option (List Tok)
```

Read LaTeX math into tokens.

</div>
