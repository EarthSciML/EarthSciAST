---
title: "The LaTeX lexer lemma"
type: lean
lean_module: "Esm.Document.Math.LexLatex"
weight: 37
---

<p class="lean-meta">Lean module <code>Esm.Document.Math.LexLatex</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/LexLatex.lean"><code>formal/Esm/Document/Math/LexLatex.lean</code></a> at <code>5af01ca9d41a</code><br>Imports <a href="/generated/document-formats/esm-document-math-latex"><code>Esm.Document.Math.Latex</code></a>, <a href="/generated/document-formats/esm-document-math-induct"><code>Esm.Document.Math.Induct</code></a></p>

Every list of LaTeX tokens ([`tokOK`](#Esm.Document.Math.Latex.tokOK)) reads back from its rendering: `lex (render ts) =
some ts`. The proof goes token by token: each token reads back from its spelling
whatever follows it, as long as what follows does not extend it ([`Sep`](#Esm.Document.Math.Latex.Sep)), and the
renderer writes a space exactly where a following token would extend the previous
one.

## Characters

## Balanced raw text

## JSON strings

## Numbers

<div class="lean-decl" id="Esm.Document.Math.Latex.spOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Latex.spOK" title="Esm.Document.Math.Latex.spOK"><code>spOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/LexLatex.lean#L375-L378">source</a></div>

```lean
def spOK : List Char → Bool
```

A spelling [`skipSp`](/generated/document-formats/esm-document-math-latex#Esm.Document.Math.Latex.skipSp) stops at: its first character is not white space and not `\`,
or it is `\` followed by something other than a spacing command.

</div>

<div class="lean-decl" id="Esm.Document.Math.Latex.clash">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Latex.clash" title="Esm.Document.Math.Latex.clash"><code>clash</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/LexLatex.lean#L399-L401">source</a></div>

```lean
def clash : List Char → List Char → Bool
```

Two spellings differ within the first one's length.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.Latex.sciExp_pre">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.Latex.sciExp_pre" title="Esm.Document.Math.Latex.sciExp_pre"><code>sciExp_pre</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/LexLatex.lean#L414-L416">source</a></div>

```lean
theorem sciExp_pre (P Y : List Char) (h1 : spOK P = true) (h2 : clash "\\times".toList P = true) :
    sciExp (P ++ Y) = none
```

No scientific tail after a spelling that [`skipSp`](/generated/document-formats/esm-document-math-latex#Esm.Document.Math.Latex.skipSp) stops at and that is not `\times`.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.Latex.sciExp_none">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.Latex.sciExp_none" title="Esm.Document.Math.Latex.sciExp_none"><code>sciExp_none</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/LexLatex.lean#L424-L425">source</a></div>

```lean
theorem sciExp_none {Z : List Char} (h : dropP "\\times".toList (skipSp Z) = none) : sciExp Z = none
```

No scientific tail where `\times` does not come first.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.Latex.sciExp_tail">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.Latex.sciExp_tail" title="Esm.Document.Math.Latex.sciExp_tail"><code>sciExp_tail</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/LexLatex.lean#L443-L467">source</a></div>

```lean
theorem sciExp_tail (e : Int) (X : List Char) :
    sciExp (timesTen ++ (Number.printInt e ++ '}' :: X)) = some (e, X)
```

The printed scientific tail reads back as its exponent.

</div>

<div class="lean-decl" id="Esm.Document.Math.Latex.NumSep">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Latex.NumSep" title="Esm.Document.Math.Latex.NumSep"><code>NumSep</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/LexLatex.lean#L470">source</a></div>

```lean
def NumSep (X : List Char) : Prop
```

What may follow a number: nothing that extends it, and not a scientific tail.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.Latex.lexSigned_num">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.Latex.lexSigned_num" title="Esm.Document.Math.Latex.lexSigned_num"><code>lexSigned_num</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/LexLatex.lean#L491-L497">source</a></div>

```lean
theorem lexSigned_num (n : JNum) (hn : n.WF) (X : List Char)
    (h : lexNum sciExp (numChars n ++ X) = some (.num n, X)) :
    lexSigned sciExp (numChars n ++ X) = some (.num n, X)
```

A number token reads back with its sign: a printed `-` starts a negative number.

</div>

## Character classes

<div class="lean-decl lean-theorem" id="Esm.Document.Math.Latex.letter_facts">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.Latex.letter_facts" title="Esm.Document.Math.Latex.letter_facts"><code>letter_facts</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/LexLatex.lean#L521-L538">source</a></div>

```lean
theorem letter_facts {c : Char} (h : isLetter c = true) :
    isDig c = false ∧ c ≠ '\\' ∧ c ≠ '"' ∧ c ≠ '-' ∧ c ≠ ' ' ∧ c ≠ '\n' ∧ c ≠ '\t' ∧ c ≠ '\r' ∧
      c ≠ ';' ∧ c ≠ ':' ∧ c ≠ '!'
```

A letter is none of the characters the lexer dispatches on.

</div>

## Greek names

## Tokens

<div class="lean-decl" id="Esm.Document.Math.Latex.kwOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Latex.kwOK" title="Esm.Document.Math.Latex.kwOK"><code>kwOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/LexLatex.lean#L571-L574">source</a></div>

```lean
def kwOK : Kw → Bool
```

LaTeX keywords: the ones with a LaTeX spelling, except `\times`, which the printer
never writes (it would run into the `\times 10^{…}` of a scientific number).

</div>

<div class="lean-decl" id="Esm.Document.Math.Latex.tokOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Latex.tokOK" title="Esm.Document.Math.Latex.tokOK"><code>tokOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/LexLatex.lean#L577-L588">source</a></div>

```lean
def tokOK : Tok → Prop
```

The LaTeX tokens: what the LaTeX printer writes.

</div>

<div class="lean-decl" id="Esm.Document.Math.Latex.Sep">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Latex.Sep" title="Esm.Document.Math.Latex.Sep"><code>Sep</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/LexLatex.lean#L591-L592">source</a></div>

```lean
def Sep (t : Tok) (X : List Char) : Prop
```

What may follow the spelling of `t`: nothing that extends it.

</div>

## Spaces

## One token

## Token lists

<div class="lean-decl lean-theorem" id="Esm.Document.Math.Latex.lex_render">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.Latex.lex_render" title="Esm.Document.Math.Latex.lex_render"><code>lex_render</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/LexLatex.lean#L1558-L1562">source</a></div>

```lean
theorem lex_render (ts : List Tok) (h : ∀ t ∈ ts, tokOK t) : lex (render ts) = some ts
```

The LaTeX lexer lemma: a list of LaTeX tokens reads back from its rendering.

</div>

<p class="lean-meta">This module also proves 72 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/LexLatex.lean">the source</a>.</p>
