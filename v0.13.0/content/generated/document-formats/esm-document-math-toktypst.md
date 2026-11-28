---
title: "The Typst printer writes only Typst tokens, in lexable order"
type: lean
lean_module: "Esm.Document.Math.TokTypst"
weight: 45
---

<p class="lean-meta">Lean module <code>Esm.Document.Math.TokTypst</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/TokTypst.lean"><code>formal/Esm/Document/Math/TokTypst.lean</code></a> at <code>5af01ca9d41a</code><br>Imports <a href="/generated/document-formats/esm-document-math-lextypst"><code>Esm.Document.Math.LexTypst</code></a>, <a href="/generated/document-formats/esm-document-math-toklatex"><code>Esm.Document.Math.TokLatex</code></a></p>

Every token of a printed well-formed expression is a Typst token ([`tokOK`](/generated/document-formats/esm-document-math-lextypst#Esm.Document.Math.Typst.tokOK)), every call
parenthesis follows a name-like token, and no unit block follows a unit block
([`Adj`](/generated/document-formats/esm-document-math-lextypst#Esm.Document.Math.Typst.Adj)), so the Typst lexer lemma applies to the printer's output.

<div class="lean-decl" id="Esm.Document.Math.Typst.Nice">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Typst.Nice" title="Esm.Document.Math.Typst.Nice"><code>Nice</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/TokTypst.lean#L20">source</a></div>

```lean
def Nice (ts : List Tok) : Prop
```

A list that may follow anything: it does not start with a call parenthesis or a
unit block.

</div>

<div class="lean-decl" id="Esm.Document.Math.TokTypst.L103">
<div class="lean-decl-head"><span class="lean-kind">macro</span> <a class="lean-name" href="#Esm.Document.Math.TokTypst.L103">¶</a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/TokTypst.lean#L103-L119">source</a></div>

```lean
macro "gok" : tactic
```

Close `Good`, [`Nice`](#Esm.Document.Math.Typst.Nice) and fact goals about a printed template from the pieces in
the context.

</div>

## Names

## Printer pieces

<div class="lean-decl" id="Esm.Document.Math.TokTypst.L401">
<div class="lean-decl-head"><span class="lean-kind">macro</span> <a class="lean-name" href="#Esm.Document.Math.TokTypst.L401">¶</a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/TokTypst.lean#L401">source</a></div>

```lean
macro "fixed" : tactic
```

The fixed tokens of a printed template.

</div>

## Reductions

## The induction

<div class="lean-decl lean-theorem" id="Esm.Document.Math.Typst.print_ok">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.Typst.print_ok" title="Esm.Document.Math.Typst.print_ok"><code>print_ok</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/TokTypst.lean#L961-L973">source</a></div>

```lean
theorem print_ok (S : Sym) (e : Json) (he : isE e = true) :
    (∀ t ∈ print .typst S e, tokOK t) ∧ Adj (print .typst S e) ∧ ∀ r, print .typst S e ≠ .kw .lp :: r
```

Every token the Typst printer writes for a well-formed expression is a Typst token,
in an order the Typst lexer reads back.

</div>

<p class="lean-meta">This module also proves 41 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/TokTypst.lean">the source</a>.</p>
