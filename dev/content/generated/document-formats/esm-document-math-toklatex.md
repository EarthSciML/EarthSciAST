---
title: "The LaTeX printer writes only LaTeX tokens"
type: lean
lean_module: "Esm.Document.Math.TokLatex"
weight: 45
---

<p class="lean-meta">Lean module <code>Esm.Document.Math.TokLatex</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/TokLatex.lean"><code>formal/Esm/Document/Math/TokLatex.lean</code></a> at <code>9c3b4aa7587e</code><br>Imports <a href="/generated/document-formats/esm-document-math-lexlatex"><code>Esm.Document.Math.LexLatex</code></a></p>

Every token of a printed well-formed expression is a LaTeX token ([`tokOK`](/generated/document-formats/esm-document-math-lexlatex#Esm.Document.Math.Latex.tokOK)), so the
LaTeX lexer lemma applies to the printer's output.

<div class="lean-decl" id="Esm.Document.Math.Latex.TL">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Latex.TL" title="Esm.Document.Math.Latex.TL"><code>TL</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/TokLatex.lean#L17-L19">source</a></div>

```lean
def TL : List Tok → Prop
```

Every `\times` is followed, within the list, by a token that is not a number: the printer
writes `\times` between the bound pairs of a region (before a bracket) and after the
`\nabla` of a curl (before an operand that does not start with a number).

</div>

<div class="lean-decl" id="Esm.Document.Math.Latex.AllOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Latex.AllOK" title="Esm.Document.Math.Latex.AllOK"><code>AllOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/TokLatex.lean#L22">source</a></div>

```lean
def AllOK (ts : List Tok) : Prop
```

What the printer writes: LaTeX tokens, and `\times` before a token that is not a number.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.Latex.allOK_times_tok">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.Latex.allOK_times_tok" title="Esm.Document.Math.Latex.allOK_times_tok"><code>allOK_times_tok</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/TokLatex.lean#L67-L73">source</a></div>

```lean
theorem allOK_times_tok {u : Tok} {r : List Tok} (hr : AllOK (u :: r)) (hu : startsNum [u] = false) :
    AllOK (.kw .times :: u :: r)
```

`\times` before a list that does not start with a number.

</div>

<div class="lean-decl" id="Esm.Document.Math.TokLatex.L101">
<div class="lean-decl-head"><span class="lean-kind">macro</span> <a class="lean-name" href="#Esm.Document.Math.TokLatex.L101">¶</a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/TokLatex.lean#L101-L115">source</a></div>

```lean
macro "aok" : tactic
```

Close a goal `AllOK [fixed tokens and pieces]` from the pieces in the context.

</div>

## Names

## JSON

<div class="lean-decl lean-theorem" id="Esm.Document.Math.Latex.setToks_latex">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.Latex.setToks_latex" title="Esm.Document.Math.Latex.setToks_latex"><code>setToks_latex</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/TokLatex.lean#L233-L235">source</a></div>

```lean
theorem setToks_latex (c : Ctx) (hc : c.sf = .latex) (s : String) : setToks c s = nameToks c s
```

LaTeX sets no set name upright: a set prints as a name.

</div>

## Printer pieces

## Reductions

## Block assembly

## The induction

<div class="lean-decl lean-theorem" id="Esm.Document.Math.Latex.allOK_pa">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.Latex.allOK_pa" title="Esm.Document.Math.Latex.allOK_pa"><code>allOK_pa</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/TokLatex.lean#L744-L747">source</a></div>

```lean
theorem allOK_pa (S : Sym) (e : Json) (he : isE e = true) (L : Nat) :
    AllOK ((pr ⟨.latex, S⟩ e).at .latex L)
```

The LaTeX printer writes LaTeX tokens, and `\times` only before a bracket.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.Latex.allOK_rowToks">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.Latex.allOK_rowToks" title="Esm.Document.Math.Latex.allOK_rowToks"><code>allOK_rowToks</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/TokLatex.lean#L750-L771">source</a></div>

```lean
theorem allOK_rowToks (c : Ctx) (hc : c.sf = .latex) (P : Json → Out) (kv : String × Json)
    (hQ : ∀ a b, kv.2 = .arr [a, b] → AllOK ((P a).at .latex 4) ∧ AllOK ((P b).at .latex 4)) :
    AllOK (rowToks c P kv)
```

A range row's tokens are LaTeX tokens.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.Latex.print_tokL">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.Latex.print_tokL" title="Esm.Document.Math.Latex.print_tokL"><code>print_tokL</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/TokLatex.lean#L798-L799">source</a></div>

```lean
theorem print_tokL (S : Sym) (e : Json) (he : isE e = true) : TokL (print .latex S e)
```

Every token the LaTeX printer writes for a well-formed expression is a LaTeX token or a
`\times` the lexer lemma allows.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.Latex.pa_tokL">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.Latex.pa_tokL" title="Esm.Document.Math.Latex.pa_tokL"><code>pa_tokL</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/TokLatex.lean#L803-L804">source</a></div>

```lean
theorem pa_tokL (S : Sym) (e : Json) (he : isE e = true) : TokL (pa ⟨.latex, S⟩ 1 e)
```

The same for an expression printed whole as an expression ([`pa`](/generated/document-formats/esm-document-math-print#Esm.Document.Math.pa)), an `==` at its top
included.

</div>

<p class="lean-meta">This module also proves 46 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/TokLatex.lean">the source</a>.</p>
