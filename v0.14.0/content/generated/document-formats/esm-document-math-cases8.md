---
title: "Round trip, case by case: fractions, powers, cases"
type: lean
lean_module: "Esm.Document.Math.Cases8"
weight: 29
---

<p class="lean-meta">Lean module <code>Esm.Document.Math.Cases8</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Cases8.lean"><code>formal/Esm/Document/Math/Cases8.lean</code></a> at <code>ffd5aee2f868</code><br>Imports <a href="/generated/document-formats/esm-document-math-cases7"><code>Esm.Document.Math.Cases7</code></a></p>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.pFracL_quot">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.pFracL_quot" title="Esm.Document.Math.pFracL_quot"><code>pFracL_quot</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Cases8.lean#L17-L35">source</a></div>

```lean
theorem pFracL_quot (c : Ctx) (a b : Json) (ha : M c a) (hb : M c b) (rest : List Tok) (f : Nat)
    (hf : need 1 (((pr c a).at c.sf 1).length + ((pr c b).at c.sf 1).length + 3) + 1 ≤ f) :
    pFracL c (f + 1) ((pr c a).at c.sf 1 ++ .kw .rb :: .kw .lb :: ((pr c b).at c.sf 1 ++ .kw .rb :: rest)) =
      some (node "/" [a, b], rest)
```

After `\frac{`: an ordinary quotient.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.M_pow_of">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.M_pow_of" title="Esm.Document.Math.M_pow_of"><code>M_pow_of</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Cases8.lean#L107-L128">source</a></div>

```lean
theorem M_pow_of (c : Ctx) (a b : Json) (ha : M c a) (EX : List Tok)
    (hex : ∀ rest g, 30 * EX.length + 30 ≤ g → pExpo c g (EX ++ rest) = some (b, rest))
    (hpr : pr c (node "^" [a, b]) = mkOut c.sf 8 ((pr c a).at c.sf 9 ++ .kw .caret :: EX)) :
    M c (node "^" [a, b])
```

The power, once the exponent's tokens `EX` are known to read back.

</div>

<p class="lean-meta">This module also proves 5 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Cases8.lean">the source</a>.</p>
