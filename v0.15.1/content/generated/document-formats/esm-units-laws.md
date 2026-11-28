---
title: "Algebra of units (esm-spec §4.8.1 \"Scales are EXACT\")"
type: lean
lean_module: "Esm.Units.Laws"
weight: 74
---

<p class="lean-meta">Lean module <code>Esm.Units.Laws</code>, <a href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Units/Laws.lean"><code>formal/Esm/Units/Laws.lean</code></a> at <code>86bed77c797f</code><br>Imports <a href="/generated/document-formats/esm-units-registry"><code>Esm.Units.Registry</code></a></p>

Units under multiplication form an abelian group up to agreement (equal
dimension and equal exact scale), rational powers obey the exponent laws, and
the real value of a scale is a positive homomorphism that agreement respects.

<div class="lean-decl lean-theorem" id="Esm.Units.U.abelian_group">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.U.abelian_group" title="Esm.Units.U.abelian_group"><code>abelian_group</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Units/Laws.lean#L26-L37">source</a></div>

```lean
theorem abelian_group :
    (∀ u v w : U, ((u.mul v).mul w).Agree (u.mul (v.mul w))) ∧
    (∀ u v : U, (u.mul v).Agree (v.mul u)) ∧
    (∀ u : U, (one.mul u).Agree u) ∧
    (∀ u : U, (u.mul u.inv).Agree one) ∧
    (∀ u u' v v' : U, u.Agree u' → v.Agree v' → (u.mul v).Agree (u'.mul v'))
```

Units form an abelian group under multiplication, up to agreement; and
agreement is a congruence for multiplication and rational powers.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.U.rpow_laws">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.U.rpow_laws" title="Esm.Units.U.rpow_laws"><code>rpow_laws</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Units/Laws.lean#L40-L53">source</a></div>

```lean
theorem rpow_laws :
    (∀ (u : U) (a b : ℚ), ((u.rpow a).rpow b).Agree (u.rpow (b * a))) ∧
    (∀ (u : U) (a b : ℚ), (u.rpow (a + b)).Agree ((u.rpow a).mul (u.rpow b))) ∧
    (∀ (u v : U) (q : ℚ), ((u.mul v).rpow q).Agree ((u.rpow q).mul (v.rpow q))) ∧
    (∀ u : U, (u.rpow 1).Agree u) ∧
    (∀ u : U, (u.rpow 0).Agree one) ∧
    (∀ (u u' : U) (q : ℚ), u.Agree u' → (u.rpow q).Agree (u'.rpow q))
```

Rational powers: the exponent laws hold exactly.

</div>

<div class="lean-decl lean-theorem" id="Esm.Units.U.real_hom">
<div class="lean-decl-head"><span class="lean-kind">theorem</span> <a class="lean-name" href="#Esm.Units.U.real_hom" title="Esm.Units.U.real_hom"><code>real_hom</code></a> <span class="lean-badge lean-badge-proved" title="no sorry or admit in the proof or anywhere in the Lean package, and no axiom">proved</span> <a class="lean-src" href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Units/Laws.lean#L59-L65">source</a></div>

```lean
theorem real_hom :
    (∀ s : Scale, 0 < Scale.real s) ∧
    (∀ s t : Scale, Scale.real (s ++ t) = Scale.real s * Scale.real t) ∧
    (∀ (s : Scale) (q : ℚ), Scale.real (Scale.rpow s q) = Scale.real s ^ (q : ℝ)) ∧
    (∀ u v : U, u.Agree v → Scale.real u.scale = Scale.real v.scale)
```

The real value of a scale: positive, multiplicative, carries rational powers
to real powers, and agrees on agreeing units — so the exact representation
never separates two scales with the same exponent map, and composing scales
is exact.

</div>

<p class="lean-meta">This module also proves 4 lemmas without doc comments; they are in <a href="https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/formal/Esm/Units/Laws.lean">the source</a>.</p>
