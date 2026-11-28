---
title: "Which operator a printer kind stands for"
type: lean
lean_module: "Esm.Document.Math.Kinds"
weight: 35
---

<p class="lean-meta">Lean module <code>Esm.Document.Math.Kinds</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/Kinds.lean"><code>formal/Esm/Document/Math/Kinds.lean</code></a> at <code>9c3b4aa7587e</code><br>Imports <a href="/generated/document-formats/esm-document-math-roundtrip"><code>Esm.Document.Math.RoundTrip</code></a></p>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.kindOf_table">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.kindOf_table" title="Esm.Document.Math.kindOf_table"><code>kindOf_table</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/Kinds.lean#L25-L35">source</a></div>

```lean
theorem kindOf_table {o : String} {k : OpK} (h : kindOf o = k)
    (hk : ∀ k', k ≠ .cmp k') (hu : ∀ k', k ≠ .un k') (hc : k ≠ .call) (hother : k ≠ .other) :
    (o, k) ∈ kindTable
```

A kind from the table names the operator the table gives it.

</div>

<p class="lean-meta">This module also proves 19 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/Kinds.lean">the source</a>.</p>
