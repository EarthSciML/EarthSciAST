---
title: "The loops of the level parsers: stopping and running through a chain"
type: lean
lean_module: "Esm.Document.Math.Loops"
weight: 39
---

<p class="lean-meta">Lean module <code>Esm.Document.Math.Loops</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/Loops.lean"><code>formal/Esm/Document/Math/Loops.lean</code></a> at <code>9c3b4aa7587e</code><br>Imports <a href="/generated/document-formats/esm-document-math-cases2"><code>Esm.Document.Math.Cases2</code></a></p>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.chain">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.chain" title="Esm.Document.Math.chain"><code>chain</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/Loops.lean#L82-L104">source</a></div>

```lean
theorem chain {α : Type} (loop : Nat → List Json → List Tok → Option α) (Q : List Tok → Prop)
    (W : Json × List Tok → Nat) (rest : List Tok) (hQr : Q rest) :
    ∀ (bs : List (Json × List Tok)), (∀ p ∈ bs, ∀ r, Q (p.2 ++ r)) →
      (∀ p ∈ bs, ∀ f acc r, Q r → W p ≤ f →
        loop (f + 1) acc (p.2 ++ r) = loop f (acc ++ [p.1]) r) →
      ∀ (acc : List Json) (f : Nat), (∀ p ∈ bs, W p + bs.length ≤ f) → bs.length ≤ f →
      loop f acc ((bs.flatMap Prod.snd) ++ rest) = loop (f - bs.length) (acc ++ bs.map Prod.fst) rest
```

A chain of blocks, each of which one loop step consumes (with fuel at least `W` of it).

</div>

<p class="lean-meta">This module also proves 9 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/Loops.lean">the source</a>.</p>
