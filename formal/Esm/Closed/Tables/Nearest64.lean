import Esm.Closed.Tables
import Esm.Closed.Interp.Rounding

/-!
# Is the §9.5.3 `nearest` lowering truly nearest in binary64? (Q-13)

The lowering compares `A[hi] ⊖ x < x ⊖ A[lo]` with the two subtractions rounded
to binary64 (`j` = the first knot `≥ x`, `lo = j − 1`, `hi = min(j, N − 1)`,
0-based here). Q-13 rules "the true nearest knot, ties low".

* `nearest64_not_exact`: REFUTED for every finite query. On the axis `[−1, 1]`
  at `x = 2^-60` the upper knot is strictly nearer (`1 − 2^-60 < 1 + 2^-60`),
  but both differences round to `1`, the comparison is false, and the lower
  knot is chosen.
* `nearest64_spec`, the weakest true version: the lowering picks the true
  nearest knot, except that when the upper bracketing knot is strictly nearer
  it may pick the lower one — and only when the two exact distances differ by
  at most `ulp(x − A[lo])` (the larger distance's ulp). It never errs the other
  way (rounding is monotone).
-/

namespace Esm.Closed.Tables

open Esm.F64 Esm.Closed.Rounding

noncomputable section

/-- The lower bracketing knot (0-based). -/
def nlo (a : List ℝ) (x : ℝ) : ℕ := a.findIdx (fun b => decide (x ≤ b)) - 1

/-- The upper bracketing knot (0-based). -/
def nhi (a : List ℝ) (x : ℝ) : ℕ := min (a.findIdx (fun b => decide (x ≤ b))) (a.length - 1)

/-- The knot the §9.5.3 tree selects, its subtractions in binary64. -/
def nearest64 (a : List ℝ) (x : ℝ) : ℕ :=
  if fsub (a.getD (nhi a x) 0) x < fsub x (a.getD (nlo a x) 0) then nhi a x else nlo a x

/-- Exact `nearest` in the bracket form (`nearestIdx_bracket`). -/
theorem nearestIdx_eq (a : List ℝ) (hr : a.Pairwise (· < ·)) (hn : 2 ≤ a.length) (x : ℝ) :
    nearestIdx a x =
      if a.getD (nhi a x) 0 - x < x - a.getD (nlo a x) 0 then nhi a x else nlo a x :=
  nearestIdx_bracket a hr hn x

theorem nlo_le_nhi (a : List ℝ) (hn : 2 ≤ a.length) (x : ℝ) : nlo a x ≤ nhi a x := by
  have := List.findIdx_le_length (p := fun b => decide (x ≤ b)) (xs := a)
  simp only [nlo, nhi]; omega

/-- **Q-13, the weakest true version.** The binary64 lowering picks the true
nearest knot (least argmin of the exact distance), or else the lower bracketing
knot when the upper one is strictly nearer by at most one ulp of the larger
distance. -/
theorem nearest64_spec (a : List ℝ) (hr : a.Pairwise (· < ·)) (hn : 2 ≤ a.length) (x : ℝ) :
    nearest64 a x = nearestIdx a x ∨
      (nearest64 a x = nlo a x ∧ nearestIdx a x = nhi a x ∧
        0 < (x - a.getD (nlo a x) 0) - (a.getD (nhi a x) 0 - x) ∧
        (x - a.getD (nlo a x) 0) - (a.getD (nhi a x) 0 - x) ≤ ulp (x - a.getD (nlo a x) 0)) := by
  rw [nearestIdx_eq a hr hn x]
  unfold nearest64 fsub
  set d1 := a.getD (nhi a x) 0 - x
  set d2 := x - a.getD (nlo a x) 0
  have hsum : 0 ≤ d1 + d2 := by
    have hle := nlo_le_nhi a hn x
    have : a.getD (nlo a x) 0 ≤ a.getD (nhi a x) 0 :=
      pw_getD_le hr (by simp only [nhi]; omega) hle
    simp only [d1, d2]; linarith
  by_cases hc : d1 < d2
  · by_cases hrn : rn d1 < rn d2
    · left; simp [hc, hrn]
    · right
      simp only [hc, hrn, ↓reduceIte, true_and]
      have hm := rn_mono hc.le
      have heq : rn d1 = rn d2 := le_antisymm hm (not_lt.mp hrn)
      have habs : |d1| ≤ |d2| := by
        rw [abs_of_pos (by linarith : 0 < d2), abs_le]; constructor <;> linarith
      have hu : ulp d1 ≤ ulp d2 := zpow_le_zpow_right₀ (by norm_num) (fexp_mono habs)
      have e1 := abs_rn_sub_le d1
      have e2 := abs_rn_sub_le d2
      rw [abs_le] at e1 e2
      refine ⟨by linarith, ?_⟩
      linarith [heq]
  · left
    have hrn : ¬ rn d1 < rn d2 := fun h => hc (by
      by_contra h'; exact absurd (rn_mono (not_lt.mp h')) (not_le.mpr h))
    simp [hc, hrn]

/-- The claim Q-13 makes of the §9.5.3 tree: for every strictly increasing
axis of doubles and every double query, the binary64 comparison selects the
true nearest knot. -/
def NearestExactClaim : Prop :=
  ∀ (a : List ℝ) (x : ℝ), a.Pairwise (· < ·) → 2 ≤ a.length → (∀ b ∈ a, Repr b) → Repr x →
    nearest64 a x = nearestIdx a x

/-- Refuted: axis `[−1, 1]`, query `2^-60`. The upper knot is strictly
nearer, but `1 ⊖ 2^-60 = 1 = 2^-60 ⊖ (−1)`, so the tree returns the lower one. -/
theorem nearest64_not_exact : ¬ NearestExactClaim := by
  intro h
  have hx : Repr ((1 / 2 ^ 60 : ℚ) : ℝ) := ⟨1, -60, by norm_num, by norm_num, by push_cast; ring⟩
  have hc := h [-1, 1] ((1 / 2 ^ 60 : ℚ) : ℝ) (by simp) (by simp)
    (by
      intro b hb
      simp only [List.mem_cons, List.not_mem_nil, or_false] at hb
      rcases hb with rfl | rfl
      · exact ⟨-1, 0, by norm_num, by norm_num, by simp⟩
      · exact ⟨1, 0, by norm_num, by norm_num, by simp⟩) hx
  have hpos : (0 : ℝ) < ((1 / 2 ^ 60 : ℚ) : ℝ) := by positivity
  have hle1 : ((1 / 2 ^ 60 : ℚ) : ℝ) ≤ 1 := by
    have : ((1 / 2 ^ 60 : ℚ) : ℝ) = 1 / 2 ^ 60 := by push_cast; ring
    rw [this]; norm_num
  have hj : [(-1 : ℝ), 1].findIdx (fun b => decide (((1 / 2 ^ 60 : ℚ) : ℝ) ≤ b)) = 1 := by
    have d1 : decide (((1 / 2 ^ 60 : ℚ) : ℝ) ≤ -1) = false :=
      decide_eq_false (not_le.mpr (by linarith))
    have d2 : decide (((1 / 2 ^ 60 : ℚ) : ℝ) ≤ 1) = true := decide_eq_true hle1
    rw [List.findIdx_cons, List.findIdx_cons, d1, d2]
    rfl
  have hlo : nlo [-1, 1] ((1 / 2 ^ 60 : ℚ) : ℝ) = 0 := by simp only [nlo, hj]
  have hhi : nhi [-1, 1] ((1 / 2 ^ 60 : ℚ) : ℝ) = 1 := by simp only [nhi, hj]; rfl
  rw [nearestIdx_eq _ (by simp) (by simp)] at hc
  unfold nearest64 fsub at hc
  rw [hlo, hhi] at hc
  simp only [List.getD_cons_zero, List.getD_cons_succ] at hc
  have r1 : rn ((1 : ℝ) - ((1 / 2 ^ 60 : ℚ) : ℝ)) = 1 := by
    rw [show (1 : ℝ) - ((1 / 2 ^ 60 : ℚ) : ℝ) = ((1 - 1 / 2 ^ 60 : ℚ) : ℝ) by push_cast; ring,
      rn_ratCast]
    have : rn (1 - 1 / 2 ^ 60 : ℚ) = 1 := by decide +kernel
    rw [this]; norm_num
  have r2 : rn (((1 / 2 ^ 60 : ℚ) : ℝ) - -1) = 1 := by
    rw [show ((1 / 2 ^ 60 : ℚ) : ℝ) - -1 = ((1 / 2 ^ 60 + 1 : ℚ) : ℝ) by push_cast; ring,
      rn_ratCast]
    have : rn (1 / 2 ^ 60 + 1 : ℚ) = 1 := by decide +kernel
    rw [this]; norm_num
  rw [r1, r2] at hc
  have : (1 : ℝ) - ((1 / 2 ^ 60 : ℚ) : ℝ) < ((1 / 2 ^ 60 : ℚ) : ℝ) - -1 := by linarith
  rw [ite_eq_right (lt_irrefl 1), ite_eq_left this] at hc
  exact absurd hc (by norm_num)

end

end Esm.Closed.Tables
