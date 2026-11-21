---
title: "The LaTeX printer writes only LaTeX tokens"
type: lean
lean_module: "Esm.Document.Math.TokLatex"
weight: 44
---

<p class="lean-meta">Lean module <code>Esm.Document.Math.TokLatex</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/TokLatex.lean"><code>formal/Esm/Document/Math/TokLatex.lean</code></a> at <code>5af01ca9d41a</code><br>Imports <a href="/generated/document-formats/esm-document-math-lexlatex"><code>Esm.Document.Math.LexLatex</code></a></p>

Every token of a printed well-formed expression is a LaTeX token ([`tokOK`](/generated/document-formats/esm-document-math-lexlatex#Esm.Document.Math.Latex.tokOK)), so the
LaTeX lexer lemma applies to the printer's output.

<div class="lean-decl" id="Esm.Document.Math.TokLatex.L55">
<div class="lean-decl-head"><span class="lean-kind">macro</span> <a class="lean-name" href="#Esm.Document.Math.TokLatex.L55">¶</a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/TokLatex.lean#L55-L59">source</a></div>

```lean
macro "aok" : tactic
```

Close a goal `AllOK [fixed tokens and pieces]` from the pieces in the context.

</div>

## Names

## JSON

## Printer pieces

## Reductions

## The induction

<div class="lean-decl lean-theorem" id="Esm.Document.Math.Latex.print_tokOK">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.Latex.print_tokOK" title="Esm.Document.Math.Latex.print_tokOK"><code>print_tokOK</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/TokLatex.lean#L557-L559">source</a></div>

```lean
theorem print_tokOK (S : Sym) (e : Json) (he : isE e = true) : ∀ t ∈ print .latex S e, tokOK t
```

Every token the LaTeX printer writes for a well-formed expression is a LaTeX token.

</div>

<p class="lean-meta">This module also proves 34 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/5af01ca9d41a19cc4d40a3b6068e1e1fb16501bb/formal/Esm/Document/Math/TokLatex.lean">the source</a>.</p>
