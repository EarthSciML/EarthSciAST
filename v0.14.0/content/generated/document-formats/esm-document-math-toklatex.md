---
title: "The LaTeX printer writes only LaTeX tokens"
type: lean
lean_module: "Esm.Document.Math.TokLatex"
weight: 45
---

<p class="lean-meta">Lean module <code>Esm.Document.Math.TokLatex</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/TokLatex.lean"><code>formal/Esm/Document/Math/TokLatex.lean</code></a> at <code>ffd5aee2f868</code><br>Imports <a href="/generated/document-formats/esm-document-math-lexlatex"><code>Esm.Document.Math.LexLatex</code></a></p>

Every token of a printed well-formed expression is a LaTeX token ([`tokOK`](/generated/document-formats/esm-document-math-lexlatex#Esm.Document.Math.Latex.tokOK)), so the
LaTeX lexer lemma applies to the printer's output.

<div class="lean-decl" id="Esm.Document.Math.Latex.TL">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Latex.TL" title="Esm.Document.Math.Latex.TL"><code>TL</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/TokLatex.lean#L16-L18">source</a></div>

```lean
def TL : List Tok → Prop
```

Every `\times` is followed by a bracket, within the list: the printer writes `\times`
only between the bound pairs of a region.

</div>

<div class="lean-decl" id="Esm.Document.Math.Latex.AllOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Latex.AllOK" title="Esm.Document.Math.Latex.AllOK"><code>AllOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/TokLatex.lean#L21">source</a></div>

```lean
def AllOK (ts : List Tok) : Prop
```

What the printer writes: LaTeX tokens, and `\times` before a bracket.

</div>

<div class="lean-decl" id="Esm.Document.Math.TokLatex.L91">
<div class="lean-decl-head"><span class="lean-kind">macro</span> <a class="lean-name" href="#Esm.Document.Math.TokLatex.L91">¶</a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/TokLatex.lean#L91-L105">source</a></div>

```lean
macro "aok" : tactic
```

Close a goal `AllOK [fixed tokens and pieces]` from the pieces in the context.

</div>

## Names

## JSON

## Printer pieces

## Reductions

## Block assembly

## The induction

<div class="lean-decl lean-theorem" id="Esm.Document.Math.Latex.print_allOK">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.Latex.print_allOK" title="Esm.Document.Math.Latex.print_allOK"><code>print_allOK</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/TokLatex.lean#L678-L680">source</a></div>

```lean
theorem print_allOK (S : Sym) (e : Json) (he : isE e = true) : AllOK (print .latex S e)
```

The LaTeX printer writes LaTeX tokens, and `\times` only before a bracket.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.Latex.print_tokL">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.Latex.print_tokL" title="Esm.Document.Math.Latex.print_tokL"><code>print_tokL</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/TokLatex.lean#L684-L685">source</a></div>

```lean
theorem print_tokL (S : Sym) (e : Json) (he : isE e = true) : TokL (print .latex S e)
```

Every token the LaTeX printer writes for a well-formed expression is a LaTeX token or a
`\times` the lexer lemma allows.

</div>

<p class="lean-meta">This module also proves 44 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/TokLatex.lean">the source</a>.</p>
