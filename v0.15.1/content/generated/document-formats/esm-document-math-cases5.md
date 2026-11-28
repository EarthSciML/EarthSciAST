---
title: "Round trip, case by case: fractions, powers, cases, initial conditions, indices, calls"
type: lean
lean_module: "Esm.Document.Math.Cases5"
weight: 26
---

<p class="lean-meta">Lean module <code>Esm.Document.Math.Cases5</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Cases5.lean"><code>formal/Esm/Document/Math/Cases5.lean</code></a> at <code>86bed77c797f</code><br>Imports <a href="/generated/document-formats/esm-document-math-cases4"><code>Esm.Document.Math.Cases4</code></a></p>

## Lists

<div class="lean-decl lean-theorem" id="Esm.Document.Math.pList_list">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.pList_list" title="Esm.Document.Math.pList_list"><code>pList_list</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Cases5.lean#L26-L46">source</a></div>

```lean
theorem pList_list (c : Ctx) (closer : Tok) (hcl : ∀ r, Fol c.sf 1 (closer :: r))
    (hcc : closer ≠ .kw .comma)
    (hcl' : closer = .kw .rp ∨ closer = .kw .rpg ∨ closer = .kw .rb ∨ closer = .kw .rbk)
    (xs : List Json) (hx : ∀ x ∈ xs, M c x) (rest : List Tok) (f : Nat)
    (hf : need 1 (sepBy [.kw .comma] (xs.map fun x => (pr c x).at c.sf 1)).length + 3 ≤ f) :
    pList c f 1 (sepBy [.kw .comma] (xs.map fun x => (pr c x).at c.sf 1) ++ closer :: rest) =
      some (xs, closer :: rest)
```

A possibly empty comma list of children at level 1 before a closing token.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.pCallItems_list">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.pCallItems_list" title="Esm.Document.Math.pCallItems_list"><code>pCallItems_list</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Cases5.lean#L49-L92">source</a></div>

```lean
theorem pCallItems_list (c : Ctx) (closer : Tok) (hcl : ∀ r, Fol c.sf 4 (closer :: r))
    (hcc : closer ≠ .kw .comma) (hce : closer ≠ .kw .eq) :
    ∀ (xs : List Json), xs ≠ [] → (∀ x ∈ xs, M c x) → ∀ rest f,
      need 1 (sepBy [.kw .comma] (xs.map fun x => (pr c x).at c.sf 4)).length + 2 ≤ f →
      pCallItems c f (sepBy [.kw .comma] (xs.map fun x => (pr c x).at c.sf 4) ++ closer :: rest) =
        some (xs.map CallArg.pos, closer :: rest)
```

Call arguments at level 4, positional.

</div>

<p class="lean-meta">This module also proves 3 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Document/Math/Cases5.lean">the source</a>.</p>
