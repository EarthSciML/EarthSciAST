---
title: "The Typst lexer lemma"
type: lean
lean_module: "Esm.Document.Math.LexTypst"
weight: 38
---

<p class="lean-meta">Lean module <code>Esm.Document.Math.LexTypst</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/LexTypst.lean"><code>formal/Esm/Document/Math/LexTypst.lean</code></a> at <code>1b8dd9b3a909</code><br>Imports <a href="/generated/document-formats/esm-document-math-typst"><code>Esm.Document.Math.Typst</code></a>, <a href="/generated/document-formats/esm-document-math-lexlatex"><code>Esm.Document.Math.LexLatex</code></a></p>

Every list of Typst tokens ([`tokOK`](#Esm.Document.Math.Typst.tokOK)) in which each call parenthesis follows a token
after which `(` is a call parenthesis (`CallOK`) reads back from its rendering. The
proof goes token by token, as for LaTeX; the one Typst-specific step is the
parenthesis: the lexer tells a call `(` from a grouping `(` by the character before
it, and the renderer writes a space before a grouping `(` exactly when that
character would make it a call.

## Tokens

<div class="lean-decl" id="Esm.Document.Math.Typst.kwOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Typst.kwOK" title="Esm.Document.Math.Typst.kwOK"><code>kwOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/LexTypst.lean#L24-L28">source</a></div>

```lean
def kwOK : Kw → Bool
```

Typst keywords: the ones with a Typst spelling, except `times`, which the printer
writes only before a bracket ([`Adj`](#Esm.Document.Math.Typst.Adj): after a number, `times 10^…` would be its scientific
tail).

</div>

<div class="lean-decl" id="Esm.Document.Math.Typst.tokOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Typst.tokOK" title="Esm.Document.Math.Typst.tokOK"><code>tokOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/LexTypst.lean#L31-L42">source</a></div>

```lean
def tokOK : Tok → Prop
```

The Typst tokens: what the Typst printer writes.

</div>

<div class="lean-decl" id="Esm.Document.Math.Typst.Sep">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Typst.Sep" title="Esm.Document.Math.Typst.Sep"><code>Sep</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/LexTypst.lean#L53-L55">source</a></div>

```lean
def Sep (t : Tok) (X : List Char) : Prop
```

What may follow the spelling of `t`: nothing that extends it.

</div>

## Characters

## Dispatch

<div class="lean-decl lean-theorem" id="Esm.Document.Math.Typst.lexOne_word">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.Typst.lexOne_word" title="Esm.Document.Math.Typst.lexOne_word"><code>lexOne_word</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/LexTypst.lean#L571-L583">source</a></div>

```lean
theorem lexOne_word (prev : Option Char) (s : String) (hs : s = "delim" ∨ s = "augment") (X : List Char)
    (hX : ∀ c ∈ X.head?, isIdC c = false) : lexOne prev (s.toList ++ X) = some (.word s, X)
```

An identifier the lexer reads as one word: the named arguments of the `makearray`
table head.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.Typst.lexOne_times">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.Typst.lexOne_times" title="Esm.Document.Math.Typst.lexOne_times"><code>lexOne_times</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/LexTypst.lean#L586-L594">source</a></div>

```lean
theorem lexOne_times (prev : Option Char) (X : List Char) (hX : ∀ c ∈ X.head?, merges (.kw .times) c = false) :
    lexOne prev (tokChars (.kw .times) ++ X) = some (.kw .times, X)
```

`times`: read as the keyword (the printer writes it before a bracket).

</div>

## Numbers

<div class="lean-decl lean-theorem" id="Esm.Document.Math.Typst.sciExp_head">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.Typst.sciExp_head" title="Esm.Document.Math.Typst.sciExp_head"><code>sciExp_head</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/LexTypst.lean#L602-L604">source</a></div>

```lean
theorem sciExp_head (c : Char) (r : List Char) (h1 : isWsT c = false) (h2 : c ≠ 't') :
    sciExp (c :: r) = none
```

No scientific tail where `times` does not come first.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.Typst.sciExp_tail">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.Typst.sciExp_tail" title="Esm.Document.Math.Typst.sciExp_tail"><code>sciExp_tail</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/LexTypst.lean#L613-L654">source</a></div>

```lean
theorem sciExp_tail (e : Int) (X : List Char) (hX : Number.NumStop X) :
    sciExp (timesTen ++ ((if e < 0 then '(' :: Number.printInt e ++ [')'] else Number.printInt e) ++ X)) =
      some (e, X)
```

The printed scientific tail reads back as its exponent.

</div>

## Identifier tokens

## Upright pieces

## One token

## Heads

## What may follow a number or a unit block

## Token lists

<div class="lean-decl" id="Esm.Document.Math.Typst.Adj">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Typst.Adj" title="Esm.Document.Math.Typst.Adj"><code>Adj</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/LexTypst.lean#L1151-L1155">source</a></div>

```lean
def Adj : List Tok → Prop
```

Neighbouring tokens: a call parenthesis follows a token after which `(` is a call
parenthesis, and a unit block never follows a unit block.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.Typst.noGlue_times">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.Typst.noGlue_times" title="Esm.Document.Math.Typst.noGlue_times"><code>noGlue_times</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/LexTypst.lean#L1167-L1172">source</a></div>

```lean
theorem noGlue_times (S W : List Char) (hS : S = [] ∨ S = [' ']) :
    sciExp (tokChars (.kw .times) ++ (S ++ '[' :: W)) = none ∧
      (' ' :: (tokChars (.kw .times) ++ (S ++ '[' :: W))).dropPrefix? Esm.Units.thinSep = none
```

`times` before a bracket: no scientific tail, no unit separator.

</div>

<div class="lean-decl" id="Esm.Document.Math.Typst.HC">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Typst.HC" title="Esm.Document.Math.Typst.HC"><code>HC</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/LexTypst.lean#L1175-L1177">source</a></div>

```lean
def HC (t : Tok) (S : List Char) (prev : Option Char) : Prop
```

What the lexer needs to tell the first token's parenthesis right.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.Typst.lex_render">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.Typst.lex_render" title="Esm.Document.Math.Typst.lex_render"><code>lex_render</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/LexTypst.lean#L1415-L1421">source</a></div>

```lean
theorem lex_render (ts : List Tok) (h : ∀ t ∈ ts, tokOK t ∨ t = .kw .times) (ha : Adj ts)
    (hfirst : ∀ r, ts ≠ .kw .lp :: r) : lex (render ts) = some ts
```

The Typst lexer lemma: a list of Typst tokens (and `times` before a bracket) whose
call parentheses each follow a name-like token, and whose unit blocks are not adjacent,
reads back from its rendering.

</div>

<p class="lean-meta">This module also proves 39 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/LexTypst.lean">the source</a>.</p>
