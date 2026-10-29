import Esm.Units.Registry

/-!
# Algebra of units (esm-spec §4.8.1 "Scales are EXACT")

Units under multiplication form an abelian group up to agreement (equal
dimension and equal exact scale), rational powers obey the exponent laws, and
the real value of a scale is a positive homomorphism that agreement respects.
-/

namespace Esm.Units

namespace U

theorem agree_refl (u : U) : u.Agree u := rfl

theorem agree_symm {u v : U} (h : u.Agree v) : v.Agree u := h.symm

theorem agree_trans {u v w : U} (h₁ : u.Agree v) (h₂ : v.Agree w) : u.Agree w := h₁.trans h₂

theorem agree_iff (u v : U) : u.Agree v ↔ u.dim = v.dim ∧ Scale.exp u.scale = Scale.exp v.scale := by
  simp [Agree, val, Prod.ext_iff]

/-- Units form an abelian group under multiplication, up to agreement; and
agreement is a congruence for multiplication and rational powers. -/
theorem abelian_group :
    (∀ u v w : U, ((u.mul v).mul w).Agree (u.mul (v.mul w))) ∧
    (∀ u v : U, (u.mul v).Agree (v.mul u)) ∧
    (∀ u : U, (one.mul u).Agree u) ∧
    (∀ u : U, (u.mul u.inv).Agree one) ∧
    (∀ u u' v v' : U, u.Agree u' → v.Agree v' → (u.mul v).Agree (u'.mul v')) := by
  refine ⟨?_, ?_, ?_, ?_, ?_⟩
  · intro u v w; simp [Agree, add_assoc]
  · intro u v; simp [Agree, add_comm]
  · intro u; simp [Agree]
  · intro u; simp [Agree, inv]
  · intro u u' v v' h₁ h₂; simp only [Agree] at *; simp [h₁, h₂]

/-- Rational powers: the exponent laws hold exactly. -/
theorem rpow_laws :
    (∀ (u : U) (a b : ℚ), ((u.rpow a).rpow b).Agree (u.rpow (b * a))) ∧
    (∀ (u : U) (a b : ℚ), (u.rpow (a + b)).Agree ((u.rpow a).mul (u.rpow b))) ∧
    (∀ (u v : U) (q : ℚ), ((u.mul v).rpow q).Agree ((u.rpow q).mul (v.rpow q))) ∧
    (∀ u : U, (u.rpow 1).Agree u) ∧
    (∀ u : U, (u.rpow 0).Agree one) ∧
    (∀ (u u' : U) (q : ℚ), u.Agree u' → (u.rpow q).Agree (u'.rpow q)) := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩
  · intro u a b; simp [Agree, mul_smul]
  · intro u a b; simp [Agree, add_smul]
  · intro u v q; simp [Agree, smul_add]
  · intro u; simp [Agree]
  · intro u; simp [Agree]
  · intro u u' q h; simp only [Agree] at *; simp [h]

/-- The real value of a scale: positive, multiplicative, carries rational powers
to real powers, and agrees on agreeing units — so the exact representation
never separates two scales with the same exponent map, and composing scales
is exact. -/
theorem real_hom :
    (∀ s : Scale, 0 < Scale.real s) ∧
    (∀ s t : Scale, Scale.real (s ++ t) = Scale.real s * Scale.real t) ∧
    (∀ (s : Scale) (q : ℚ), Scale.real (Scale.rpow s q) = Scale.real s ^ (q : ℝ)) ∧
    (∀ u v : U, u.Agree v → Scale.real u.scale = Scale.real v.scale) :=
  ⟨Scale.real_pos, Scale.real_append, Scale.real_rpow,
    fun u v h => Scale.real_congr _ _ ((agree_iff u v).1 h).2⟩

end U

end Esm.Units
