---
title: "Round trip, case by case: the and, or and * chains"
type: lean
lean_module: "Esm.Document.Math.Cases4"
weight: 25
---

<p class="lean-meta">Lean module <code>Esm.Document.Math.Cases4</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/Cases4.lean"><code>formal/Esm/Document/Math/Cases4.lean</code></a> at <code>1b8dd9b3a909</code><br>Imports <a href="/generated/document-formats/esm-document-math-cases3"><code>Esm.Document.Math.Cases3</code></a></p>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.sepChain">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.sepChain" title="Esm.Document.Math.sepChain"><code>sepChain</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/Cases4.lean#L12-L61">source</a></div>

```lean
theorem sepChain (c : Ctx) (L : Nat) (hL1 : 1 ≤ L) (hL : L ≤ 3) (sep : Kw) (o : String)
    (loop : Nat → List Json → List Tok → Option (Json × List Tok))
    (hstep : ∀ f acc r, loop (f + 1) acc (.kw sep :: r) =
      match pLvl c f (L + 1) r with | some (y, r') => loop f (acc ++ [y]) r' | none => none)
    (htop : ∀ f ts, pLvl c (f + 1) L ts =
      match pLvl c f (L + 1) ts with | some (x, r) => loop f [x] r | none => none)
    (hstop : ∀ f acc r, Fol c.sf L r → loop (f + 1) acc r = some (close o acc, r))
    (hsepF : ∀ r, Fol c.sf (L + 1) (.kw sep :: r))
    (xs : List Json) (hl : 2 ≤ xs.length) (hx : ∀ x ∈ xs, M c x) (rest : List Tok)
    (hr : Fol c.sf L rest) (f : Nat)
    (hf : need L (sepBy [.kw sep] (xs.map fun x => (pr c x).at c.sf (L + 1))).length ≤ f) :
    pLvl c f L (sepBy [.kw sep] (xs.map fun x => (pr c x).at c.sf (L + 1)) ++ rest) =
      some (node o xs, rest)
```

A chain `x₁ sep x₂ sep …` at level `L`, each operand at level `L + 1`, reads back.

</div>

<div class="lean-decl" id="Esm.Document.Math.mulBlocks">
<div class="lean-decl-head"><span class="lean-kind">def</span> <a class="lean-name" href="#Esm.Document.Math.mulBlocks" title="Esm.Document.Math.mulBlocks"><code>mulBlocks</code></a> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/Cases4.lean#L113-L115">source</a></div>

```lean
def mulBlocks (c : Ctx) (ys : List Json) : List (Json × List Tok)
```

The blocks after the first factor of a product.

</div>

<div class="lean-decl lean-theorem" id="Esm.Document.Math.factor_head">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.factor_head" title="Esm.Document.Math.factor_head"><code>factor_head</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/Cases4.lean#L124-L143">source</a></div>

```lean
theorem factor_head {c : Ctx} {a : Json} (ha : M c a) :
    ∃ t r, (pr c a).at c.sf 6 = t :: r ∧ atomStart t = true ∧ conts c.sf 6 t = false
```

A factor's tokens never start with what would end a product early or be read
otherwise after an operand.

</div>

<p class="lean-meta">This module also proves 4 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/formal/Esm/Document/Math/Cases4.lean">the source</a>.</p>
