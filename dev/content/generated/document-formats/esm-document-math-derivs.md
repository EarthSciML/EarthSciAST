---
title: "Round trip, case by case: derivatives and quantities"
type: lean
lean_module: "Esm.Document.Math.Derivs"
weight: 31
---

<p class="lean-meta">Lean module <code>Esm.Document.Math.Derivs</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/Derivs.lean"><code>formal/Esm/Document/Math/Derivs.lean</code></a> at <code>9c3b4aa7587e</code><br>Imports <a href="/generated/document-formats/esm-document-math-templates"><code>Esm.Document.Math.Templates</code></a></p>

## Generic steps

<div class="lean-decl lean-theorem" id="Esm.Document.Math.headA_us">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.headA_us" title="Esm.Document.Math.headA_us"><code>headA_us</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/Derivs.lean#L64-L70">source</a></div>

```lean
theorem headA_us {c : Ctx} {a : Json} (ha : M c a) (L : Nat) :
    ∀ t r, (pr c a).at c.sf L = t :: r → t ≠ .kw .us
```

A printed expression never starts with `_`.

</div>

## The time derivative

## The spatial derivative `partial`

## `partial` with trailing operands: `\\partial_{x}(u, a, b)`

## The `\nabla` forms

<div class="lean-decl lean-theorem" id="Esm.Document.Math.nabArg9_read">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Document.Math.nabArg9_read" title="Esm.Document.Math.nabArg9_read"><code>nabArg9_read</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/Derivs.lean#L336-L354">source</a></div>

```lean
theorem nabArg9_read {c : Ctx} {a : Json} (ha : M c a) (n : NabK) (rest : List Tok) (hr : Fol c.sf 9 rest)
    (g : Nat) (hg : need 9 (nabArg9 c.sf n ((pr c a).at c.sf 9)).length ≤ g) :
    pPost c g (nabArg9 c.sf n ((pr c a).at c.sf 9) ++ rest) = some (a, rest)
```

An operand of a `\nabla` form that is not itself one reads back at level 9.

</div>

## Quantities

<p class="lean-meta">This module also proves 28 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/formal/Esm/Document/Math/Derivs.lean">the source</a>.</p>
