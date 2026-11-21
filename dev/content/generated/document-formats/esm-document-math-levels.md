---
title: "Parsing at a level, what may follow, and moving between levels"
type: lean
lean_module: "Esm.Document.Math.Levels"
weight: 36
---

<p class="lean-meta">Lean module <code>Esm.Document.Math.Levels</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/Levels.lean"><code>formal/Esm/Document/Math/Levels.lean</code></a> at <code>1b8dd9b3a909</code><br>Imports <a href="/generated/document-formats/esm-document-math-names"><code>Esm.Document.Math.Names</code></a></p>

`pLvl L` parses at precedence level `L` (`1` = an `or` chain … `9` = postfix, `10` =
a primary). `Fol sf L rest` says `rest` does not continue an expression parsed at
level `L`. [`lift`](/generated/document-formats/esm-document-math-roundtrip#Esm.Document.Math.lift) moves a parse at a tighter level to a looser one: the loops of the
levels in between stop at once.

<div class="lean-decl" id="Esm.Document.Math.conts">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.conts" title="Esm.Document.Math.conts"><code>conts</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/Levels.lean#L34-L43">source</a></div>

```lean
def conts (sf : Sf) (L : Nat) : Tok → Bool
```

`t` continues an expression parsed at level `L`.

</div>

<div class="lean-decl" id="Esm.Document.Math.Fol">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.Fol" title="Esm.Document.Math.Fol"><code>Fol</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/Levels.lean#L46-L47">source</a></div>

```lean
def Fol (sf : Sf) (L : Nat) (rest : List Tok) : Prop
```

`rest` does not continue an expression parsed at level `L`.

</div>

## No level starts with a binary `-` or a `not` it does not own

## Lifting a parse to a looser level

<div class="lean-decl lean-theorem" id="Esm.Document.Math.negTail_fol">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.negTail_fol" title="Esm.Document.Math.negTail_fol"><code>negTail_fol</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/Levels.lean#L149-L158">source</a></div>

```lean
theorem negTail_fol {sf : Sf} {L : Nat} {r : List Tok} (hr : Fol sf L r) (hL : L ≤ 5) :
    negTail r = none
```

Nothing that does not continue a level-5 parse starts with a number.

</div>

<p class="lean-meta">This module also proves 19 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/Levels.lean">the source</a>.</p>
