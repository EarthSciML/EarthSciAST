---
title: "Round trip, case by case: atoms, prefix operators, functions"
type: lean
lean_module: "Esm.Document.Math.Cases1"
weight: 22
---

<p class="lean-meta">Lean module <code>Esm.Document.Math.Cases1</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Cases1.lean"><code>formal/Esm/Document/Math/Cases1.lean</code></a> at <code>ffd5aee2f868</code><br>Imports <a href="/generated/document-formats/esm-document-math-main"><code>Esm.Document.Math.Main</code></a></p>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.child1">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.child1" title="Esm.Document.Math.child1"><code>child1</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Cases1.lean#L15-L19">source</a></div>

```lean
theorem child1 {c : Ctx} {a : Json} (h : M c a) (rest : List Tok) (hr : Fol c.sf 1 rest) (f : Nat)
    (hf : need 1 ((pr c a).at c.sf 1).length ≤ f) :
    pOr c f ((pr c a).at c.sf 1 ++ rest) = some (a, rest)
```

A child's tokens for level 1 read back before a closing token.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.pItems_list">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.pItems_list" title="Esm.Document.Math.pItems_list"><code>pItems_list</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Cases1.lean#L87-L148">source</a></div>

```lean
theorem pItems_list (c : Ctx) (L : Nat) (hL : L = 1 ∨ L = 4) (closer : Tok)
    (hcl : ∀ r, Fol c.sf L (closer :: r)) (hcc : closer ≠ .kw .comma) :
    ∀ (xs : List Json), xs ≠ [] → (∀ x ∈ xs, M c x) → ∀ rest f,
      need 1 (sepBy [.kw .comma] (xs.map fun x => (pr c x).at c.sf L)).length + 2 ≤ f →
      pItems c f L (sepBy [.kw .comma] (xs.map fun x => (pr c x).at c.sf L) ++ closer :: rest) =
        some (xs, closer :: rest)
```

A comma-separated list of printed expressions at level `L` reads back.

</div>

## Assembling the induction facts

<div class="lean-decl lean-theorem" id="Esm.Document.Math.M_of">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.M_of" title="Esm.Document.Math.M_of"><code>M_of</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Cases1.lean#L185-L190">source</a></div>

```lean
theorem M_of (c : Ctx) (e : Json) (h0 : P0 c e) (hh : HeadOK c (pr c e).toks)
    (hl1 : 1 ≤ (pr c e).lvl) (hl : (pr c e).lvl ≤ 10) (hlvl : (pr c e).lvl ≠ 4)
    (hacc : addAcc e = [e]) (hcrow : (pr c e).crow = (pr c e).toks ++ [.kw .amp, .txt "otherwise"]) :
    M c e
```

The facts for an expression printed with the generic `crow` and not a `+` chain.

</div>

<p class="lean-meta">This module also proves 12 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/formal/Esm/Document/Math/Cases1.lean">the source</a>.</p>
