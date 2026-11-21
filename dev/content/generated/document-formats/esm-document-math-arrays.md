---
title: "Round trip, case by case: constant arrays"
type: lean
lean_module: "Esm.Document.Math.Arrays"
weight: 20
---

<p class="lean-meta">Lean module <code>Esm.Document.Math.Arrays</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/Arrays.lean"><code>formal/Esm/Document/Math/Arrays.lean</code></a> at <code>1b8dd9b3a909</code><br>Imports <a href="/generated/document-formats/esm-document-math-derivs"><code>Esm.Document.Math.Derivs</code></a></p>

A column for rank 1 and a matrix of at least two columns, LaTeX `bmatrix` (a matrix of
more than [`bmatCols`](/generated/document-formats/esm-document-math-print#Esm.Document.Math.bmatCols) columns `\left[\begin{array}{c…c} … \end{array}\right]`), Typst
`vec(…)` / `mat(…)`, with units after them as for a scalar.

<div class="lean-decl" id="Esm.Document.Math.AOK">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.AOK" title="Esm.Document.Math.AOK"><code>AOK</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/Arrays.lean#L61-L64">source</a></div>

```lean
def AOK : AForm → Prop
```

What a printed array shape guarantees.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.pPrim_arr">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.pPrim_arr" title="Esm.Document.Math.pPrim_arr"><code>pPrim_arr</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/Arrays.lean#L170-L231">source</a></div>

```lean
theorem pPrim_arr (c : Ctx) (af : AForm) (haf : AOK af) (rest : List Tok) (f : Nat) :
    pPrim c (f + 1) (arrToks c.sf af ++ rest) = constTail af.json rest
```

The array tokens read back as the array, whatever follows them.

</div>

<p class="lean-meta">This module also proves 14 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/Arrays.lean">the source</a>.</p>
