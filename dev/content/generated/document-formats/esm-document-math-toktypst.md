---
title: "The Typst printer writes only Typst tokens, in lexable order"
type: lean
lean_module: "Esm.Document.Math.TokTypst"
weight: 46
---

<p class="lean-meta">Lean module <code>Esm.Document.Math.TokTypst</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/TokTypst.lean"><code>formal/Esm/Document/Math/TokTypst.lean</code></a> at <code>9c3b4aa7587e</code><br>Imports <a href="/generated/document-formats/esm-document-math-lextypst"><code>Esm.Document.Math.LexTypst</code></a>, <a href="/generated/document-formats/esm-document-math-toklatex"><code>Esm.Document.Math.TokLatex</code></a></p>

Every token of a printed well-formed expression is a Typst token ([`tokOK`](/generated/document-formats/esm-document-math-lextypst#Esm.Document.Math.Typst.tokOK)), every call
parenthesis follows a name-like token, and no unit block follows a unit block
([`Adj`](/generated/document-formats/esm-document-math-lextypst#Esm.Document.Math.Typst.Adj)), so the Typst lexer lemma applies to the printer's output.

<div class="lean-decl" id="Esm.Document.Math.Typst.Nice">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Typst.Nice" title="Esm.Document.Math.Typst.Nice"><code>Nice</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/TokTypst.lean#L20">source</a></div>

```lean
def Nice (ts : List Tok) : Prop
```

A list that may follow anything: it does not start with a call parenthesis or a
unit block.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.Typst.good_times">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.Typst.good_times" title="Esm.Document.Math.Typst.good_times"><code>good_times</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/TokTypst.lean#L56-L61">source</a></div>

```lean
theorem good_times {B : List Tok} (hB : Good (.kw .lbk :: B)) : Good (.kw .times :: .kw .lbk :: B)
```

`times` and the bracket after it.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.Typst.good_times_tok">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.Typst.good_times_tok" title="Esm.Document.Math.Typst.good_times_tok"><code>good_times_tok</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/TokTypst.lean#L64-L70">source</a></div>

```lean
theorem good_times_tok {u : Tok} {B : List Tok} (hB : Good (u :: B)) (hu : startsNum [u] = false)
    (hlp : u ≠ .kw .lp) : Good (.kw .times :: u :: B)
```

`times` before a list that does not start with a number (the operand of a curl).

</div>

<div class="lean-decl" id="Esm.Document.Math.TokTypst.L126">
<div class="lean-decl-head"><span class="lean-kind">macro</span> <a class="lean-name" href="#Esm.Document.Math.TokTypst.L126">¶</a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/TokTypst.lean#L126-L142">source</a></div>

```lean
macro "gok" : tactic
```

Close `Good`, [`Nice`](#Esm.Document.Math.Typst.Nice) and fact goals about a printed template from the pieces in
the context.

</div>

## Names

## Printer pieces

<div class="lean-decl" id="Esm.Document.Math.TokTypst.L451">
<div class="lean-decl-head"><span class="lean-kind">macro</span> <a class="lean-name" href="#Esm.Document.Math.TokTypst.L451">¶</a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/TokTypst.lean#L451">source</a></div>

```lean
macro "fixed" : tactic
```

The fixed tokens of a printed template.

</div>

## Reductions

<div class="lean-decl lean-theorem" id="Esm.Document.Math.Typst.good_close">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.Typst.good_close" title="Esm.Document.Math.Typst.good_close"><code>good_close</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/TokTypst.lean#L506-L509">source</a></div>

```lean
theorem good_close {A : List Tok} {k : Kw} (hk : kwOK k = true) (hl : k ≠ .lp) (hA : Good A) (hn : Nice A) :
    Good (A ++ [.kw k]) ∧ Nice (A ++ [.kw k])
```

The list `toks ++ [closer]` for a list that is good and nice.

</div>

## Block assembly

## The induction

<div class="lean-decl lean-theorem" id="Esm.Document.Math.Typst.good_at">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.Typst.good_at" title="Esm.Document.Math.Typst.good_at"><code>good_at</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/TokTypst.lean#L1198-L1207">source</a></div>

```lean
theorem good_at (S : Sym) (x : Json) (hx : isE x = true) (L : Nat) :
    Good ((pr ⟨.typst, S⟩ x).at .typst L) ∧ Nice ((pr ⟨.typst, S⟩ x).at .typst L) ∧
      (pr ⟨.typst, S⟩ x).at .typst L ≠ []
```

A well-formed expression's tokens at any level are good, nice and not empty.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.Typst.good_rowToks">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.Typst.good_rowToks" title="Esm.Document.Math.Typst.good_rowToks"><code>good_rowToks</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/TokTypst.lean#L1210-L1248">source</a></div>

```lean
theorem good_rowToks (c : Ctx) (hc : c.sf = .typst) (P : Json → Out) (kv : String × Json)
    (hQ : ∀ a b, kv.2 = .arr [a, b] →
      (Good ((P a).at .typst 4) ∧ Nice ((P a).at .typst 4) ∧ (P a).at .typst 4 ≠ []) ∧
      (Good ((P b).at .typst 4) ∧ Nice ((P b).at .typst 4) ∧ (P b).at .typst 4 ≠ [])) :
    Good (rowToks c P kv) ∧ Nice (rowToks c P kv)
```

A range row's tokens are good and nice.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.Typst.print_ok">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.Typst.print_ok" title="Esm.Document.Math.Typst.print_ok"><code>print_ok</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/TokTypst.lean#L1260-L1289">source</a></div>

```lean
theorem print_ok (S : Sym) (e : Json) (he : isE e = true) :
    (∀ t ∈ print .typst S e, tokOK t ∨ t = .kw .times) ∧ Adj (print .typst S e) ∧
      ∀ r, print .typst S e ≠ .kw .lp :: r
```

Every token the Typst printer writes for a well-formed expression is a Typst token,
in an order the Typst lexer reads back.

</div>

<p class="lean-meta">This module also proves 56 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/TokTypst.lean">the source</a>.</p>
