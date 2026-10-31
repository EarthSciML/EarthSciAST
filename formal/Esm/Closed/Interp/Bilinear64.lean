import Esm.Closed.Interp.Rounding

/-!
# Q-6 for `interp.bilinear`: FMA versus the pinned order, composed

§9.2 bilinear is two x-blends and one y-blend, each `t + w·(u − t)`. The pinned
(non-FMA) evaluation rounds every operation; an FMA evaluation fuses each
blend's multiply-add. With `M` the largest corner magnitude and `g = ulp M`:

* `bilinear64_err`: the pinned result is within `11/2 · g` of the exact
  bilinear value (exact arithmetic on the same weights);
* `bilinearFMA_err`: the FMA result is within `3 · g` of it;
* `bilinear_fma_le`: so the two differ by at most `17/2 · ulp M`.

A randomized search found differences of `4 · ulp M`, so the least constant
lies in `[4, 17/2]`; the gap is not closed here.
-/

namespace Esm.Closed.Rounding

open Esm.F64

set_option linter.unusedSectionVars false

/-- The pinned binary64 bilinear blend of a cell's corners at weights `wx, wy`. -/
noncomputable def bilinear64 (t00 t10 t01 t11 wx wy : ℝ) : ℝ :=
  blend64 (blend64 t00 t10 wx) (blend64 t01 t11 wx) wy

/-- The same with every blend fused. -/
noncomputable def bilinearFMA (t00 t10 t01 t11 wx wy : ℝ) : ℝ :=
  blendFMA (blendFMA t00 t10 wx) (blendFMA t01 t11 wx) wy

/-- The exact bilinear value. -/
def bilinearR (t00 t10 t01 t11 wx wy : ℝ) : ℝ :=
  let r0 := t00 + wx * (t10 - t00)
  let r1 := t01 + wx * (t11 - t01)
  r0 + wy * (r1 - r0)

section Stage

variable {e : ℤ} (he : -1074 ≤ e)
include he

theorem err_2B {a : ℝ} (ha : |a| ≤ 2 * 2 ^ (e + 53)) : |rn a - a| ≤ 2 ^ e := by
  have h := abs_rn_sub_le_of_le (e := e + 1) (by omega) (by
    rw [show e + 1 + 53 = (e + 53) + 1 by ring, zpow_add_one₀ two_ne_zero]; linarith)
  rw [zpow_add_one₀ two_ne_zero] at h; linarith

theorem mag_rn {a : ℝ} {k : ℤ} (hk : -1074 ≤ k) (ha : |a| ≤ 2 ^ k) : |rn a| ≤ 2 ^ k := by
  have hB : Repr ((2 : ℝ) ^ k) := ⟨1, k, by norm_num, hk, by simp⟩
  rw [abs_le] at ha ⊢
  constructor
  · have := rn_mono ha.1; rw [rn_neg, rn_of_repr hB] at this; exact this
  · have := rn_mono ha.2; rw [rn_of_repr hB] at this; exact this

theorem conv_le {t u w L : ℝ} (ht : |t| ≤ L) (hu : |u| ≤ L) (hw0 : 0 ≤ w) (hw1 : w ≤ 1) :
    |t + w * (u - t)| ≤ L := by
  have : t + w * (u - t) = (1 - w) * t + w * u := by ring
  rw [this]
  calc |(1 - w) * t + w * u| ≤ |(1 - w) * t| + |w * u| := abs_add_le _ _
    _ = (1 - w) * |t| + w * |u| := by
      rw [abs_mul, abs_mul, abs_of_nonneg (by linarith : (0 : ℝ) ≤ 1 - w), abs_of_nonneg hw0]
    _ ≤ (1 - w) * L + w * L := by gcongr
    _ = L := by ring

/-- One blend with inputs bounded by `B = 2^(e+53)`: the subtraction errs by
`≤ g`, the pinned pre-rounding sum by `≤ 2g`, the FMA argument by `≤ g`. -/
theorem stage (t u w : ℝ) (ht : |t| ≤ 2 ^ (e + 53)) (hu : |u| ≤ 2 ^ (e + 53))
    (hw0 : 0 ≤ w) (hw1 : w ≤ 1) :
    |(t + rn (w * rn (u - t))) - (t + w * (u - t))| ≤ 2 * 2 ^ e ∧
      |(w * rn (u - t) + t) - (t + w * (u - t))| ≤ 2 ^ e := by
  have hut : |u - t| ≤ 2 * 2 ^ (e + 53) := by
    calc |u - t| ≤ |u| + |t| := abs_sub _ _
      _ ≤ _ := by linarith
  have hd := err_2B he hut
  have hdm : |rn (u - t)| ≤ 2 * 2 ^ (e + 53) := by
    have := mag_rn he (a := u - t) (k := e + 54) (by omega) (by
      rw [show e + 54 = (e + 53) + 1 by ring, zpow_add_one₀ two_ne_zero]; linarith)
    rw [show e + 54 = (e + 53) + 1 by ring, zpow_add_one₀ two_ne_zero] at this; linarith
  have hp : |rn (w * rn (u - t)) - w * rn (u - t)| ≤ 2 ^ e := by
    apply err_2B he
    rw [abs_mul, abs_of_nonneg hw0]
    exact (mul_le_of_le_one_left (abs_nonneg _) hw1).trans hdm
  have hwd : |w * (rn (u - t) - (u - t))| ≤ 2 ^ e := by
    rw [abs_mul, abs_of_nonneg hw0]
    exact (mul_le_of_le_one_left (abs_nonneg _) hw1).trans hd
  constructor
  · have : (t + rn (w * rn (u - t))) - (t + w * (u - t)) =
        (rn (w * rn (u - t)) - w * rn (u - t)) + w * (rn (u - t) - (u - t)) := by ring
    rw [this]
    calc _ ≤ |rn (w * rn (u - t)) - w * rn (u - t)| + |w * (rn (u - t) - (u - t))| :=
          abs_add_le _ _
      _ ≤ _ := by linarith
  · have : (w * rn (u - t) + t) - (t + w * (u - t)) = w * (rn (u - t) - (u - t)) := by ring
    rw [this]; exact hwd

/-- A rounded value `rn s` with `s` within `δ ≤ g` of some `V`, `|V| ≤ B − (g − δ)`…
the clamp form: if `|s| ≤ B + g` and `|V| ≤ B`, then `|rn s − V| ≤ g/2 + |s − V|`
and `|rn s| ≤ B`. -/
theorem round_near {s V : ℝ} (hs : |s| ≤ 2 ^ (e + 53) + 2 ^ e) (hV : |V| ≤ 2 ^ (e + 53)) :
    |rn s - V| ≤ 2 ^ e / 2 + |s - V| ∧ |rn s| ≤ 2 ^ (e + 53) := by
  set B : ℝ := 2 ^ (e + 53)
  set c := max (-B) (min s B)
  have hrc : rn s = rn c := rn_clamp he hs
  have hBpos : 0 < B := zpow_pos two_pos _
  have hc : |c| ≤ B := by
    rw [abs_le]; constructor
    · exact le_max_left _ _
    · exact max_le (by linarith) (min_le_right _ _)
  have hcV : |c - V| ≤ |s - V| := by
    rw [abs_le] at hV
    simp only [c]
    rcases le_total s B with h | h
    · rw [min_eq_left h]
      rcases le_total (-B) s with h' | h'
      · rw [max_eq_right h']
      · rw [max_eq_left h', abs_of_nonpos (by linarith), abs_of_nonpos (by linarith)]; linarith
    · rw [min_eq_right h, max_eq_right (by linarith), abs_of_nonneg (by linarith),
        abs_of_nonneg (by linarith)]; linarith
  refine ⟨?_, by rw [hrc]; exact mag_rn he (by omega) hc⟩
  rw [hrc]
  calc |rn c - V| = |(rn c - c) + (c - V)| := by ring_nf
    _ ≤ |rn c - c| + |c - V| := abs_add_le _ _
    _ ≤ _ := add_le_add (abs_rn_sub_le_of_le he hc) hcV

end Stage

/-- The pinned bilinear blend is within `11/2 · ulp M` of the exact value, and
the FMA blend within `3 · ulp M`, for double corners and weights in `[0, 1]`. -/
theorem bilinear_errs (t00 t10 t01 t11 wx wy : ℝ) (h00 : Repr t00) (h10 : Repr t10)
    (h01 : Repr t01) (h11 : Repr t11) (hx0 : 0 ≤ wx) (hx1 : wx ≤ 1) (hy0 : 0 ≤ wy)
    (hy1 : wy ≤ 1) :
    let M := max (max |t00| |t10|) (max |t01| |t11|)
    |bilinear64 t00 t10 t01 t11 wx wy - bilinearR t00 t10 t01 t11 wx wy| ≤ 11 / 2 * ulp M ∧
      |bilinearFMA t00 t10 t01 t11 wx wy - bilinearR t00 t10 t01 t11 wx wy| ≤ 3 * ulp M := by
  intro M
  set e := fexp M
  have he : -1074 ≤ e := fexp_ge M
  set g : ℝ := 2 ^ e
  set B : ℝ := 2 ^ (e + 53)
  have hg : ulp M = g := rfl
  have hgpos : 0 < g := zpow_pos two_pos _
  have hM0 : 0 ≤ M := le_max_of_le_left (le_max_of_le_left (abs_nonneg _))
  have habs : ∀ x : ℝ, Repr x → Repr |x| := fun x hx => by
    rcases abs_choice x with h | h <;> rw [h]
    exacts [hx, repr_neg hx]
  have hMr : Repr M := by
    simp only [M]
    rcases max_choice (max |t00| |t10|) (max |t01| |t11|) with h | h <;> rw [h]
    · rcases max_choice |t00| |t10| with h' | h' <;> rw [h']
      exacts [habs _ h00, habs _ h10]
    · rcases max_choice |t01| |t11| with h' | h' <;> rw [h']
      exacts [habs _ h01, habs _ h11]
  have hMB : M ≤ B - g := repr_le_top hMr hM0
  have a00 : |t00| ≤ M := le_max_of_le_left (le_max_left _ _)
  have a10 : |t10| ≤ M := le_max_of_le_left (le_max_right _ _)
  have a01 : |t01| ≤ M := le_max_of_le_right (le_max_left _ _)
  have a11 : |t11| ≤ M := le_max_of_le_right (le_max_right _ _)
  -- a row: pinned within 5/2 g, FMA within 3/2 g, both bounded by B
  have row : ∀ t u : ℝ, |t| ≤ M → |u| ≤ M →
      (|blend64 t u wx - (t + wx * (u - t))| ≤ 5 / 2 * g ∧ |blend64 t u wx| ≤ B) ∧
      (|blendFMA t u wx - (t + wx * (u - t))| ≤ 3 / 2 * g ∧ |blendFMA t u wx| ≤ B) := by
    intro t u ht hu
    obtain ⟨s0, s1⟩ := stage he t u wx (by linarith) (by linarith) hx0 hx1
    have hV := conv_le he ht hu hx0 hx1
    have hs0 : |t + rn (wx * rn (u - t))| ≤ B + g := by
      have := abs_sub_abs_le_abs_sub (t + rn (wx * rn (u - t))) (t + wx * (u - t)); linarith
    have hs1 : |wx * rn (u - t) + t| ≤ B + g := by
      have := abs_sub_abs_le_abs_sub (wx * rn (u - t) + t) (t + wx * (u - t)); linarith
    obtain ⟨r0, m0⟩ := round_near he hs0 (by linarith : |t + wx * (u - t)| ≤ B)
    obtain ⟨r1, m1⟩ := round_near he hs1 (by linarith : |t + wx * (u - t)| ≤ B)
    exact ⟨⟨by unfold blend64 fadd fmul fsub; linarith, m0⟩,
      ⟨by unfold blendFMA ffma fsub; linarith, m1⟩⟩
  obtain ⟨⟨p0, mp0⟩, ⟨f0, mf0⟩⟩ := row t00 t10 a00 a10
  obtain ⟨⟨p1, mp1⟩, ⟨f1, mf1⟩⟩ := row t01 t11 a01 a11
  -- the y-blend moves row errors by a convex combination
  have prop : ∀ R0 R1 V0 V1 δ : ℝ, |R0 - V0| ≤ δ → |R1 - V1| ≤ δ →
      |(R0 + wy * (R1 - R0)) - (V0 + wy * (V1 - V0))| ≤ δ := by
    intro R0 R1 V0 V1 δ h0 h1
    have : (R0 + wy * (R1 - R0)) - (V0 + wy * (V1 - V0)) =
        (1 - wy) * (R0 - V0) + wy * (R1 - V1) := by ring
    rw [this]
    calc _ ≤ |(1 - wy) * (R0 - V0)| + |wy * (R1 - V1)| := abs_add_le _ _
      _ = (1 - wy) * |R0 - V0| + wy * |R1 - V1| := by
        rw [abs_mul, abs_mul, abs_of_nonneg (by linarith : (0 : ℝ) ≤ 1 - wy), abs_of_nonneg hy0]
      _ ≤ (1 - wy) * δ + wy * δ := by gcongr
      _ = δ := by ring
  rw [hg]
  constructor
  · -- pinned y-blend of the pinned rows
    set R0 := blend64 t00 t10 wx
    set R1 := blend64 t01 t11 wx
    obtain ⟨sy, -⟩ := stage he R0 R1 wy mp0 mp1 hy0 hy1
    have hVy := conv_le he mp0 mp1 hy0 hy1
    have hsy : |R0 + rn (wy * rn (R1 - R0))| ≤ 2 * B := by
      have := abs_sub_abs_le_abs_sub (R0 + rn (wy * rn (R1 - R0))) (R0 + wy * (R1 - R0))
      have : (2 : ℝ) * g ≤ B := by
        simp only [g, B]; rw [zpow_add₀ two_ne_zero]
        have : (2 : ℝ) ≤ 2 ^ (53 : ℤ) := by norm_num
        nlinarith [zpow_pos (two_pos (α := ℝ)) e]
      linarith
    have ey := err_2B he hsy
    have pr := prop R0 R1 _ _ (5 / 2 * g) p0 p1
    unfold bilinear64 bilinearR
    simp only
    change |rn (R0 + rn (wy * rn (R1 - R0))) - _| ≤ _
    calc _ = |(rn (R0 + rn (wy * rn (R1 - R0))) - (R0 + rn (wy * rn (R1 - R0))))
          + ((R0 + rn (wy * rn (R1 - R0))) - (R0 + wy * (R1 - R0)))
          + ((R0 + wy * (R1 - R0)) - ((t00 + wx * (t10 - t00)) +
              wy * ((t01 + wx * (t11 - t01)) - (t00 + wx * (t10 - t00)))))| := by ring_nf
      _ ≤ _ := abs_add_three _ _ _
      _ ≤ g + 2 * g + 5 / 2 * g := by linarith
      _ = 11 / 2 * g := by ring
  · -- FMA y-blend of the FMA rows
    set R0 := blendFMA t00 t10 wx
    set R1 := blendFMA t01 t11 wx
    obtain ⟨-, sy⟩ := stage he R0 R1 wy mf0 mf1 hy0 hy1
    have hVy := conv_le he mf0 mf1 hy0 hy1
    have hsy : |wy * rn (R1 - R0) + R0| ≤ B + g := by
      have := abs_sub_abs_le_abs_sub (wy * rn (R1 - R0) + R0) (R0 + wy * (R1 - R0)); linarith
    obtain ⟨ry, -⟩ := round_near he hsy hVy
    have pr := prop R0 R1 _ _ (3 / 2 * g) f0 f1
    unfold bilinearFMA bilinearR
    simp only
    change |rn (wy * rn (R1 - R0) + R0) - _| ≤ _
    calc _ = |(rn (wy * rn (R1 - R0) + R0) - (R0 + wy * (R1 - R0)))
          + ((R0 + wy * (R1 - R0)) - ((t00 + wx * (t10 - t00)) +
              wy * ((t01 + wx * (t11 - t01)) - (t00 + wx * (t10 - t00)))))| := by ring_nf
      _ ≤ _ := abs_add_le _ _
      _ ≤ (g / 2 + g) + 3 / 2 * g := by linarith
      _ = 3 * g := by ring

/-- **Q-6 for `interp.bilinear`.** For double corners and weights in `[0, 1]`
(the pinned binary64 weights of a query in its cell are, `weight64_mem`), the
all-FMA and the pinned evaluations differ by at most `17/2 · ulp(max |corner|)`. -/
theorem bilinear_fma_le (t00 t10 t01 t11 wx wy : ℝ) (h00 : Repr t00) (h10 : Repr t10)
    (h01 : Repr t01) (h11 : Repr t11) (hx0 : 0 ≤ wx) (hx1 : wx ≤ 1) (hy0 : 0 ≤ wy)
    (hy1 : wy ≤ 1) :
    |bilinear64 t00 t10 t01 t11 wx wy - bilinearFMA t00 t10 t01 t11 wx wy| ≤
      17 / 2 * ulp (max (max |t00| |t10|) (max |t01| |t11|)) := by
  obtain ⟨a, b⟩ := bilinear_errs t00 t10 t01 t11 wx wy h00 h10 h01 h11 hx0 hx1 hy0 hy1
  have := abs_sub_le (bilinear64 t00 t10 t01 t11 wx wy) (bilinearR t00 t10 t01 t11 wx wy)
    (bilinearFMA t00 t10 t01 t11 wx wy)
  rw [abs_sub_comm (bilinearR _ _ _ _ _ _)] at this
  linarith

end Esm.Closed.Rounding
