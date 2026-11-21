---
title: "Round trip, case by case: literals, prefix and infix operators"
type: lean
lean_module: "Esm.Document.Math.Cases3"
weight: 24
---

<p class="lean-meta">Lean module <code>Esm.Document.Math.Cases3</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Cases3.lean"><code>formal/Esm/Document/Math/Cases3.lean</code></a> at <code>ffd5aee2f868</code><br>Imports <a href="/generated/document-formats/esm-document-math-loops"><code>Esm.Document.Math.Loops</code></a></p>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.grp_child">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.grp_child" title="Esm.Document.Math.grp_child"><code>grp_child</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Cases3.lean#L71-L83">source</a></div>

```lean
theorem grp_child {c : Ctx} {a : Json} (ha : M c a) (L : Nat) (h1 : 1 ≤ L) (h10 : L ≤ 10)
    (rest : List Tok) (hr : Fol c.sf L rest) (f : Nat)
    (hf : need L ((pr c a).toks.length + 2) ≤ f) :
    pLvl c f L (grp c.sf (pr c a).toks ++ rest) = some (a, rest)
```

A child in parentheses reads back at any level.

</div>

<div class="lean-decl" id="Esm.Document.Math.sepBlocks">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.sepBlocks" title="Esm.Document.Math.sepBlocks"><code>sepBlocks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Cases3.lean#L177-L178">source</a></div>

```lean
def sepBlocks (sep : Tok) (c : Ctx) (L : Nat) (ys : List Json) : List (Json × List Tok)
```

The blocks after the first operand of a chain with a separator token.

</div>

<p class="lean-meta">This module also proves 18 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Cases3.lean">the source</a>.</p>
