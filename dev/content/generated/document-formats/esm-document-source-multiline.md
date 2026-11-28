---
title: "Multi-line equations (accepted input variants)"
type: lean
lean_module: "Esm.Document.Source.MultiLine"
weight: 57
---

<p class="lean-meta">Lean module <code>Esm.Document.Source.MultiLine</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/MultiLine.lean"><code>formal/Esm/Document/Source/MultiLine.lean</code></a> at <code>9c3b4aa7587e</code><br>Imports <a href="/generated/document-formats/esm-document-source-equation"><code>Esm.Document.Source.Equation</code></a>, <a href="/generated/document-formats/esm-document-math-induct"><code>Esm.Document.Math.Induct</code></a></p>

The printer writes one equation per display. On input, one display may hold several
equations, or one equation over several lines (`Notation.variants`):

* rows separated by a top-level line break (LaTeX `\\` inside `aligned`, Typst `\`);
* in a row, the first top-level `&` splits a left cell from the rest; a row with
  something before its `&` starts a new equation, a row with an empty left cell
  continues the previous one (`&\quad + k_{2} B`), and a continuation starting with its
  own `=` is refused (an equation has one top-level `=`);
* in `split` and `multline`, all rows are one equation;
* line breaks and `&` nested inside a delimiter (`cases`, a matrix, parentheses) never
  split anything.

The reader works on the math tokens (`Esm.Document.Math.Tok`), after the lexer, so the
rows and cells are found by token and depth, not by text. [`cookRows_layout`](#Esm.Document.Source.cookRows_layout) is the
normalization lemma: an equation laid out over aligned rows, the pieces of its canonical
tokens separated by `&` and line breaks, reads back as the equation itself.

## Depth and top-level cuts

<div class="lean-decl" id="Esm.Document.Source.delta">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.delta" title="Esm.Document.Source.delta"><code>delta</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/MultiLine.lean#L32-L36">source</a></div>

```lean
def delta : Tok → Int
```

How a token changes the delimiter depth.

</div>

<div class="lean-decl" id="Esm.Document.Source.isKw">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.isKw" title="Esm.Document.Source.isKw"><code>isKw</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/MultiLine.lean#L39-L41">source</a></div>

```lean
def isKw (k : Kw) : Tok → Bool
```

The token is the keyword `k`.

</div>

<div class="lean-decl" id="Esm.Document.Source.cut">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.cut" title="Esm.Document.Source.cut"><code>cut</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/MultiLine.lean#L45-L49">source</a></div>

```lean
def cut (k : Kw) : Int → List Tok → List Tok × Option (List Tok)
```

Cut at the first `k` at depth 0: the tokens before it and, if there is one, the
tokens after it. `d` is the depth at the start.

</div>

<div class="lean-decl" id="Esm.Document.Source.noTop">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.noTop" title="Esm.Document.Source.noTop"><code>noTop</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/MultiLine.lean#L52-L54">source</a></div>

```lean
def noTop (k : Kw) : Int → List Tok → Bool
```

No `k` at depth 0, and the depth comes back to 0 at the end: a piece of a row.

</div>

<div class="lean-decl" id="Esm.Document.Source.splitAll">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.splitAll" title="Esm.Document.Source.splitAll"><code>splitAll</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/MultiLine.lean#L75-L80">source</a></div>

```lean
def splitAll (k : Kw) : Nat → List Tok → List (List Tok)
```

All the pieces between top-level `k`s.

</div>

## Rows into equations

<div class="lean-decl" id="Esm.Document.Source.group">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.group" title="Esm.Document.Source.group"><code>group</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/MultiLine.lean#L103-L125">source</a></div>

```lean
def group (one : Bool) : List (List Tok) → List (List Tok) → Option (List (List Tok))
```

Rows into equations' tokens: a row with a left cell starts an equation (its `&`
dropped), a row with an empty left cell continues the last one; `split` and `multline`
(`one`) make all rows one equation. Refused: a continuation with no equation before it,
one that starts with `=`, and a second top-level `&` in a row. `acc` holds the equations
so far, the last first.

</div>

<div class="lean-decl" id="Esm.Document.Source.cookRows">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.cookRows" title="Esm.Document.Source.cookRows"><code>cookRows</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/MultiLine.lean#L128-L130">source</a></div>

```lean
def cookRows (sf : Sf) (S : Sym) (one : Bool) (ts : List Tok) : Option (List Eqn)
```

**Read the rows of a multi-line display** (tokens) into equations.

</div>

## The normalization lemma

<div class="lean-decl" id="Esm.Document.Source.Layout">
<div class="lean-decl-head"><span class="lean-kind">structure</span> <a class="lean-name" href="#Esm.Document.Source.Layout" title="Esm.Document.Source.Layout"><code>Layout</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/MultiLine.lean#L136-L139">source</a></div>

```lean
structure Layout where
  l : List Tok
  r : List Tok
  more : List (List Tok)
```

An aligned layout of one equation's tokens: the left cell, then the right parts of
its first row and of each continuation row.

</div>

<div class="lean-decl" id="Esm.Document.Source.Layout.toks">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Layout.toks" title="Esm.Document.Source.Layout.toks"><code>Layout.toks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/MultiLine.lean#L142">source</a></div>

```lean
def Layout.toks (L : Layout) : List Tok
```

The tokens the layout lays out.

</div>

<div class="lean-decl" id="Esm.Document.Source.Layout.rows">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Layout.rows" title="Esm.Document.Source.Layout.rows"><code>Layout.rows</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/MultiLine.lean#L145-L146">source</a></div>

```lean
def Layout.rows (L : Layout) : List (List Tok)
```

The layout's rows: `l & r`, then `& r'` for each continuation.

</div>

<div class="lean-decl" id="Esm.Document.Source.Layout.OK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.Layout.OK" title="Esm.Document.Source.Layout.OK"><code>Layout.OK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/MultiLine.lean#L150-L152">source</a></div>

```lean
def Layout.OK (L : Layout) : Prop
```

A layout the reader splits back: every piece is free of top-level `&` and line
breaks, the left cell is not empty, and no continuation starts with `=`.

</div>

<div class="lean-decl" id="Esm.Document.Source.joinRows">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.joinRows" title="Esm.Document.Source.joinRows"><code>joinRows</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/MultiLine.lean#L172-L174">source</a></div>

```lean
def joinRows : List (List Tok) → List Tok
```

The tokens of rows joined by line breaks.

</div>

<div class="lean-decl" id="Esm.Document.Source.rowsToks">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Source.rowsToks" title="Esm.Document.Source.rowsToks"><code>rowsToks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/MultiLine.lean#L177">source</a></div>

```lean
def rowsToks (Ls : List Layout) : List Tok
```

The token stream of a display laid out over aligned rows.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.cookRows_layout">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.cookRows_layout" title="Esm.Document.Source.cookRows_layout"><code>cookRows_layout</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/MultiLine.lean#L231-L267">source</a></div>

```lean
theorem cookRows_layout (sf : Sf) (S : Sym) (Ls : List Layout) (es : List Eqn)
    (hL : ∀ L ∈ Ls, L.OK) (hne : Ls ≠ [])
    (h : List.Forall₂ (fun L e => L.toks = print sf S (eqExpr e) ∧ isE e.lhs = true ∧
      isE e.rhs = true) Ls es) :
    cookRows sf S false (rowsToks Ls) = some (es.map (fun e => ⟨none, e.lhs, e.rhs⟩))
```

**Multi-line equations read as the equations they lay out.** If each equation's
canonical tokens are laid out over aligned rows (a left cell, `&`, the rest, then
continuation rows `& …`), with no top-level `&` or line break inside a piece, the rows
read back as exactly those equations.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Source.mem_rowsToks">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Source.mem_rowsToks" title="Esm.Document.Source.mem_rowsToks"><code>mem_rowsToks</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/MultiLine.lean#L270-L297">source</a></div>

```lean
theorem mem_rowsToks {Ls : List Layout} {t : Tok} (h : t ∈ rowsToks Ls) :
    t = .kw .amp ∨ t = .kw .nl ∨ ∃ L ∈ Ls, t ∈ L.toks
```

Every token of a layout's display is a token of an equation, `&`, or a line break.

</div>

<p class="lean-meta">This module also proves 9 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Source/MultiLine.lean">the source</a>.</p>
