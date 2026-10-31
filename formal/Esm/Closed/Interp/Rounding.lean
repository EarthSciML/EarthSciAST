import Esm.Float64

/-!
# Rounding claims of §9.2 `interp.linear` / `interp.bilinear` in binary64

Against the binary64 model of `Esm/Float64.lean` (finite values, round to
nearest even, no NaN/∞/signed zero/overflow). The pinned blend of §9.2 is

```
w      = (x − aᵢ) ⊘ (aᵢ₊₁ − aᵢ)          -- weight64
result = tᵢ ⊕ (w ⊗ (tᵢ₊₁ ⊖ tᵢ))          -- blend64
```

and the only operation an FMA can fuse is the last multiply-add:
`fma(w, tᵢ₊₁ ⊖ tᵢ, tᵢ)` (`blendFMA`). Results:

* `blend_fma_le_two_ulp` (Q-6): `|blend64 − blendFMA| ≤ 2 · ulp(max(|tᵢ|, |tᵢ₊₁|))`
  for every weight in `[0, 1]`, and `linear_fma_le_two_ulp` for the pinned
  weight of a query in its cell. `blend_fma_two_ulp_attained`: the constant 2 is
  attained, so it is the least integer constant.
* `linear_fma_rel_refuted`: the spec's `rel: 4e-16` relaxation does not bound the
  FMA difference (cancellation: pinned 0, FMA `2^-54`).
* `blend64_w_zero`: `w = 0` gives `tᵢ` exactly (the spec's endpoint claim, w = 0).
* `blend64_w_one_refuted`: `w = 1` does NOT give `tᵢ₊₁` exactly
  (`1 ⊕ (1 ⊗ (2^-60 ⊖ 1)) = 0`); `blend64_w_one_sterbenz` (exact when
  `tᵢ/2 ≤ tᵢ₊₁ ≤ 2tᵢ`) and `blend64_w_one_le` (`≤ 3/2 ulp`) are what holds.

Concrete counterexamples are computed at `K = ℚ` (where the model is
computable) and transferred to `ℝ` by `rn_ratCast`.
-/

namespace Esm.Closed.Rounding

open Esm.F64

set_option linter.unusedSectionVars false

section Generic

variable {K : Type*} [Field K] [LinearOrder K] [IsStrictOrderedRing K] [FloorRing K]

/-- The pinned weight `(x ⊖ lo) ⊘ (hi ⊖ lo)`. -/
def weight64 (x lo hi : K) : K := fdiv (fsub x lo) (fsub hi lo)

/-- The pinned blend `t ⊕ (w ⊗ (u ⊖ t))`. -/
def blend64 (t u w : K) : K := fadd t (fmul w (fsub u t))

/-- The FMA blend `fma(w, u ⊖ t, t)`. -/
def blendFMA (t u w : K) : K := ffma w (fsub u t) t

end Generic

/-! ## From ℚ to ℝ -/

theorem log2_ratCast (q : ℚ) : Int.log 2 (q : ℝ) = Int.log 2 q := by
  rcases le_or_gt q 0 with hq | hq
  · rw [Int.log_of_right_le_zero _ hq, Int.log_of_right_le_zero _ (by exact_mod_cast hq)]
  · have hr : (0 : ℝ) < q := by exact_mod_cast hq
    set k := Int.log 2 q
    have h1 : (2 : ℚ) ^ k ≤ q := by simpa using Int.zpow_log_le_self (b := 2) (by norm_num) hq
    have h2 : q < (2 : ℚ) ^ (k + 1) := by simpa using Int.lt_zpow_succ_log_self (b := 2) (by norm_num) q
    have h1' : ((2 : ℕ) : ℝ) ^ k ≤ (q : ℝ) := by
      have := (Rat.cast_le (K := ℝ)).mpr h1; push_cast at this ⊢; exact this
    have h2' : (q : ℝ) < ((2 : ℕ) : ℝ) ^ (k + 1) := by
      have := (Rat.cast_lt (K := ℝ)).mpr h2; push_cast at this ⊢; exact this
    have a := (Int.zpow_le_iff_le_log (by norm_num) hr).mp h1'
    have b := (Int.lt_zpow_iff_log_lt (by norm_num) hr).mp h2'
    omega

theorem fexp_ratCast (q : ℚ) : fexp (q : ℝ) = fexp q := by
  unfold fexp
  have : ((q : ℝ) = 0) ↔ q = 0 := Rat.cast_eq_zero
  by_cases h : q = 0
  · simp [h]
  · rw [ite_eq_right (by exact_mod_cast h), ite_eq_right h, ← Rat.cast_abs, log2_ratCast]

theorem rne_ratCast (q : ℚ) : rne (q : ℝ) = rne q := by
  unfold rne
  rw [Rat.floor_cast]
  have e : (q : ℝ) - (⌊q⌋ : ℝ) = ((q - ⌊q⌋ : ℚ) : ℝ) := by push_cast; ring_nf
  have h1 : ((q : ℝ) - ⌊q⌋ < 1 / 2) ↔ (q - ⌊q⌋ < 1 / 2) := by
    rw [e, show (1 / 2 : ℝ) = ((1 / 2 : ℚ) : ℝ) by norm_num, Rat.cast_lt]
  have h2 : (1 / 2 < (q : ℝ) - ⌊q⌋) ↔ (1 / 2 < q - ⌊q⌋) := by
    rw [e, show (1 / 2 : ℝ) = ((1 / 2 : ℚ) : ℝ) by norm_num, Rat.cast_lt]
  by_cases a : q - ⌊q⌋ < 1 / 2
  · rw [ite_eq_left (h1.mpr a), ite_eq_left a]
  · rw [ite_eq_right (fun h => a (h1.mp h)), ite_eq_right a]
    by_cases b : 1 / 2 < q - ⌊q⌋
    · rw [ite_eq_left (h2.mpr b), ite_eq_left b]
    · rw [ite_eq_right (fun h => b (h2.mp h)), ite_eq_right b]

theorem rn_ratCast (q : ℚ) : rn (q : ℝ) = ((rn q : ℚ) : ℝ) := by
  unfold rn
  rw [fexp_ratCast]
  have : (q : ℝ) / 2 ^ fexp q = ((q / 2 ^ fexp q : ℚ) : ℝ) := by push_cast; ring_nf
  rw [this, rne_ratCast]
  push_cast; ring_nf

theorem ulp_ratCast (q : ℚ) : ulp (q : ℝ) = ((ulp q : ℚ) : ℝ) := by
  unfold ulp; rw [fexp_ratCast]; push_cast; ring_nf

theorem weight64_ratCast (x lo hi : ℚ) :
    weight64 (x : ℝ) lo hi = ((weight64 x lo hi : ℚ) : ℝ) := by
  simp only [weight64, fdiv, fsub]
  rw [← Rat.cast_sub, rn_ratCast, ← Rat.cast_sub, rn_ratCast, ← Rat.cast_div, rn_ratCast]

theorem blend64_ratCast (t u w : ℚ) :
    blend64 (t : ℝ) u w = ((blend64 t u w : ℚ) : ℝ) := by
  simp only [blend64, fadd, fmul, fsub]
  rw [← Rat.cast_sub, rn_ratCast, ← Rat.cast_mul, rn_ratCast, ← Rat.cast_add, rn_ratCast]

theorem blendFMA_ratCast (t u w : ℚ) :
    blendFMA (t : ℝ) u w = ((blendFMA t u w : ℚ) : ℝ) := by
  simp only [blendFMA, ffma, fsub]
  rw [← Rat.cast_sub, rn_ratCast, ← Rat.cast_mul, ← Rat.cast_add, rn_ratCast]

/-! ## Facts at one magnitude -/

section Bound

/-- A nonnegative double `M` is at most `2^(e+53) − 2^e`, `e = fexp M`. -/
theorem repr_le_top {M : ℝ} (hM : Repr M) (h0 : 0 ≤ M) :
    M ≤ 2 ^ (fexp M + 53) - 2 ^ fexp M := by
  obtain ⟨n, hn⟩ := repr_iff.mp hM
  have hlt := abs_lt_fexp M
  rw [abs_of_nonneg h0] at hlt
  have hp : (0 : ℝ) < 2 ^ fexp M := zpow_pos two_pos _
  have e53 : (2 : ℝ) ^ (fexp M + 53) = 2 ^ 53 * 2 ^ fexp M := by
    rw [zpow_add₀ two_ne_zero]; norm_num; ring
  have hlt' : (n : ℝ) * 2 ^ fexp M < 2 ^ 53 * 2 ^ fexp M := by rw [← e53, ← hn]; exact hlt
  have hn' : (n : ℝ) < 2 ^ 53 := lt_of_mul_lt_mul_right hlt' hp.le
  have hi : n ≤ 2 ^ 53 - 1 := by
    have : n < 2 ^ 53 := by exact_mod_cast hn'
    omega
  have hi' : (n : ℝ) ≤ 2 ^ 53 - 1 := by exact_mod_cast hi
  calc M = n * 2 ^ fexp M := hn
    _ ≤ (2 ^ 53 - 1) * 2 ^ fexp M := mul_le_mul_of_nonneg_right hi' hp.le
    _ = _ := by rw [e53]; ring

/-- Below `2^(e+53)` in magnitude, rounding errs by at most `2^e / 2`. -/
theorem abs_rn_sub_le_of_le {a : ℝ} {e : ℤ} (he : -1074 ≤ e) (ha : |a| ≤ 2 ^ (e + 53)) :
    |rn a - a| ≤ 2 ^ e / 2 := by
  rcases ha.lt_or_eq with h | h
  · have hu := ulp_le (k := e + 53) h (by omega)
    rw [show e + 53 - 53 = e by ring] at hu
    exact (abs_rn_sub_le a).trans (by linarith)
  · have hr : Repr a := by
      rcases (abs_eq (zpow_pos two_pos _).le).mp h with h' | h'
      · exact ⟨1, e + 53, by norm_num, by omega, by rw [h']; simp⟩
      · exact ⟨-1, e + 53, by norm_num, by omega, by rw [h']; simp⟩
    rw [rn_of_repr hr, sub_self, abs_zero]
    exact div_nonneg (zpow_pos two_pos _).le (by norm_num)

/-- Just above `B = 2^(e+53)` (within one `2^e`), rounding returns `B`: the
grid there has spacing `2^(e+1)` and the tie at `B + 2^e` goes to the even `B`. -/
theorem rn_of_top {a : ℝ} {e : ℤ} (he : -1074 ≤ e) (h1 : 2 ^ (e + 53) ≤ a)
    (h2 : a ≤ 2 ^ (e + 53) + 2 ^ e) : rn a = 2 ^ (e + 53) := by
  have hB : Repr ((2 : ℝ) ^ (e + 53)) := ⟨1, e + 53, by norm_num, by omega, by simp⟩
  apply le_antisymm
  · have hc : fexp ((2 : ℝ) ^ (e + 53) + 2 ^ e) = e + 1 := by
      apply le_antisymm
      · apply fexp_le _ (by omega)
        rw [abs_of_pos (by positivity)]
        have : (2 : ℝ) ^ (e + 1 + 53) = 2 * 2 ^ (e + 53) := by
          rw [show e + 1 + 53 = (e + 53) + 1 by ring, zpow_add_one₀ two_ne_zero]; ring
        rw [this]
        have : (2 : ℝ) ^ e < 2 ^ (e + 53) :=
          zpow_lt_zpow_right₀ (by norm_num) (by omega)
        linarith
      · have h0 : fexp ((2 : ℝ) ^ (e + 53)) = e + 1 := by
          have hl : Int.log 2 |(2 : ℝ) ^ (e + 53)| = e + 53 := by
            rw [abs_of_pos (zpow_pos two_pos _)]
            have := Int.log_zpow (R := ℝ) (b := 2) (by norm_num) (e + 53)
            simpa using this
          simp only [fexp, (zpow_pos (two_pos (α := ℝ)) (e + 53)).ne', ite_false, hl]
          omega
        rw [← h0]
        apply fexp_mono
        rw [abs_of_pos (by positivity), abs_of_pos (by positivity)]
        linarith [zpow_pos (two_pos (α := ℝ)) e]
    have htop : rn ((2 : ℝ) ^ (e + 53) + 2 ^ e) = 2 ^ (e + 53) := by
      rw [rn_eq, hc]
      have hq : ((2 : ℝ) ^ (e + 53) + 2 ^ e) / 2 ^ (e + 1) = (2 ^ 52 : ℤ) + 1 / 2 := by
        rw [show e + 53 = (e + 1) + 52 by ring, zpow_add₀ two_ne_zero,
          show e = (e + 1) - 1 by ring, zpow_sub₀ two_ne_zero]
        field_simp
        push_cast
        ring
      have hr : rne (((2 ^ 52 : ℤ) : ℝ) + 1 / 2) = 2 ^ 52 := by
        unfold rne
        have hf : ⌊((2 ^ 52 : ℤ) : ℝ) + 1 / 2⌋ = 2 ^ 52 := by
          rw [Int.floor_eq_iff]; push_cast; constructor <;> norm_num
        rw [hf]
        norm_num
      rw [hq, hr]
      have : (2 : ℝ) ^ (e + 53) = 2 ^ 52 * 2 ^ (e + 1) := by
        rw [show e + 53 = 52 + (e + 1) by ring, zpow_add₀ two_ne_zero]; norm_num
      rw [this]; push_cast; ring
    calc rn a ≤ rn ((2 : ℝ) ^ (e + 53) + 2 ^ e) := rn_mono h2
      _ = _ := htop
  · calc (2 : ℝ) ^ (e + 53) = rn (2 ^ (e + 53)) := (rn_of_repr hB).symm
      _ ≤ rn a := rn_mono h1

/-- Rounding `s` equals rounding `s` clamped into `[-B, B]`, when `s` is at
most `2^e` outside it. -/
theorem rn_clamp {s : ℝ} {e : ℤ} (he : -1074 ≤ e) (hs : |s| ≤ 2 ^ (e + 53) + 2 ^ e) :
    rn s = rn (max (-(2 ^ (e + 53))) (min s (2 ^ (e + 53)))) := by
  have hB : Repr ((2 : ℝ) ^ (e + 53)) := ⟨1, e + 53, by norm_num, by omega, by simp⟩
  rw [abs_le] at hs
  by_cases h1 : (2 : ℝ) ^ (e + 53) < s
  · rw [min_eq_right h1.le, max_eq_right (by linarith [zpow_pos (two_pos (α := ℝ)) (e + 53)]),
      rn_of_repr hB]
    exact rn_of_top he h1.le hs.2
  · by_cases h2 : s < -(2 ^ (e + 53))
    · rw [min_eq_left (by linarith), max_eq_left h2.le, rn_neg, rn_of_repr hB]
      have := rn_of_top (a := -s) he (by linarith) (by linarith)
      rw [← neg_neg s, rn_neg, this]
    · rw [min_eq_left (not_lt.mp h1), max_eq_right (not_lt.mp h2)]

/-- **Q-6.** For doubles `t, u` and any weight `w ∈ [0, 1]`, the pinned blend
and the FMA blend differ by at most `2 · ulp(max(|t|, |u|))`. -/
theorem blend_fma_le_two_ulp (t u w : ℝ) (ht : Repr t) (hu : Repr u) (hw0 : 0 ≤ w)
    (hw1 : w ≤ 1) : |blend64 t u w - blendFMA t u w| ≤ 2 * ulp (max |t| |u|) := by
  set M := max |t| |u| with hMdef
  set e := fexp M
  have he : -1074 ≤ e := fexp_ge M
  have hg : ulp M = 2 ^ e := rfl
  set g : ℝ := 2 ^ e
  set B : ℝ := 2 ^ (e + 53)
  have hgpos : 0 < g := zpow_pos two_pos _
  have hBg : B = 2 ^ 53 * g := by
    simp only [B, g]; rw [zpow_add₀ two_ne_zero]; norm_num; ring
  have hM0 : 0 ≤ M := le_max_of_le_left (abs_nonneg t)
  have hMr : Repr M := by
    rcases max_choice |t| |u| with h | h <;> rw [hMdef, h]
    · rcases abs_choice t with h' | h' <;> rw [h']
      exacts [ht, repr_neg ht]
    · rcases abs_choice u with h' | h' <;> rw [h']
      exacts [hu, repr_neg hu]
  have hMB : M ≤ B - g := repr_le_top hMr hM0
  have htM : |t| ≤ M := le_max_left _ _
  have huM : |u| ≤ M := le_max_right _ _
  -- (b) the difference u - t rounds with error ≤ g
  have hut : |u - t| ≤ 2 * M := by
    calc |u - t| ≤ |u| + |t| := abs_sub _ _
      _ ≤ 2 * M := by linarith
  have hd : |rn (u - t) - (u - t)| ≤ g := by
    have hu' := ulp_le (x := u - t) (k := e + 54) (by
      rw [show e + 54 = (e + 53) + 1 by ring, zpow_add_one₀ two_ne_zero]
      change |u - t| < B * 2; linarith) (by omega)
    have : (2 : ℝ) ^ (e + 54 - 53) = 2 * g := by
      rw [show e + 54 - 53 = e + 1 by ring, zpow_add_one₀ two_ne_zero]; ring
    rw [this] at hu'
    linarith [abs_rn_sub_le (u - t)]
  set d := rn (u - t)
  -- (c) the product rounds with error ≤ g
  have hdabs : |d| ≤ 2 * M + g := by
    have := abs_sub_abs_le_abs_sub d (u - t); linarith
  have hp : |rn (w * d) - w * d| ≤ g := by
    have hpw : |w * d| ≤ |d| := by
      rw [abs_mul, abs_of_nonneg hw0]; exact mul_le_of_le_one_left (abs_nonneg _) hw1
    have hu' := ulp_le (x := w * d) (k := e + 54) (by
      rw [show e + 54 = (e + 53) + 1 by ring, zpow_add_one₀ two_ne_zero]
      change |w * d| < B * 2; linarith) (by omega)
    have : (2 : ℝ) ^ (e + 54 - 53) = 2 * g := by
      rw [show e + 54 - 53 = e + 1 by ring, zpow_add_one₀ two_ne_zero]; ring
    rw [this] at hu'
    linarith [abs_rn_sub_le (w * d)]
  -- (d) the exact FMA argument is within M + g ≤ B
  set s1 := t + w * d
  set s0 := t + rn (w * d)
  have hconv : |t + w * (u - t)| ≤ M := by
    have : t + w * (u - t) = (1 - w) * t + w * u := by ring
    rw [this]
    calc |(1 - w) * t + w * u| ≤ |(1 - w) * t| + |w * u| := abs_add_le _ _
      _ = (1 - w) * |t| + w * |u| := by
        rw [abs_mul, abs_mul, abs_of_nonneg (by linarith : (0 : ℝ) ≤ 1 - w), abs_of_nonneg hw0]
      _ ≤ (1 - w) * M + w * M := by
        gcongr
      _ = M := by ring
  have hs1 : |s1| ≤ B := by
    have : s1 = (t + w * (u - t)) + w * (d - (u - t)) := by simp only [s1]; ring
    have hw' : |w * (d - (u - t))| ≤ g := by
      rw [abs_mul, abs_of_nonneg hw0]
      exact (mul_le_of_le_one_left (abs_nonneg _) hw1).trans hd
    rw [this]
    calc _ ≤ |t + w * (u - t)| + |w * (d - (u - t))| := abs_add_le _ _
      _ ≤ M + g := add_le_add hconv hw'
      _ ≤ B := by linarith
  have h01 : |s0 - s1| ≤ g := by
    have : s0 - s1 = rn (w * d) - w * d := by simp only [s0, s1]; ring
    rw [this]; exact hp
  -- (g) clamp s0 into [-B, B] without changing its rounding
  have hs0 : |s0| ≤ B + g := by
    have := abs_sub_abs_le_abs_sub s0 s1; linarith
  set c := max (-B) (min s0 B)
  have hrc : rn s0 = rn c := rn_clamp he hs0
  have hc : |c| ≤ B := by
    rw [abs_le]; constructor
    · exact le_max_left _ _
    · exact max_le (by linarith [zpow_pos (two_pos (α := ℝ)) (e + 53)]) (min_le_right _ _)
  have hcs : |c - s1| ≤ g := by
    rw [abs_le] at hs1 h01 ⊢
    constructor
    · simp only [c]
      rcases le_total s0 B with h | h
      · rw [min_eq_left h]
        rcases le_total (-B) s0 with h' | h'
        · rw [max_eq_right h']; linarith
        · rw [max_eq_left h']; linarith
      · rw [min_eq_right h, max_eq_right (by linarith)]; linarith
    · simp only [c]
      rcases le_total s0 B with h | h
      · rw [min_eq_left h]
        rcases le_total (-B) s0 with h' | h'
        · rw [max_eq_right h']; linarith
        · rw [max_eq_left h']; linarith
      · rw [min_eq_right h, max_eq_right (by linarith)]; linarith
  have ec := abs_rn_sub_le_of_le he hc
  have e1 := abs_rn_sub_le_of_le he hs1
  -- assemble
  have hr0 : blend64 t u w = rn s0 := rfl
  have hr1 : blendFMA t u w = rn s1 := by
    show rn (w * rn (u - t) + t) = rn (t + w * rn (u - t)); rw [add_comm]
  rw [hr0, hr1, hrc, hg]
  calc |rn c - rn s1| = |(rn c - c) + (c - s1) + (s1 - rn s1)| := by ring_nf
    _ ≤ |rn c - c| + |c - s1| + |s1 - rn s1| := abs_add_three _ _ _
    _ ≤ g / 2 + g + g / 2 := by
      rw [abs_sub_comm s1]; linarith
    _ = 2 * g := by ring

/-- The pinned weight of a query in its cell lies in `[0, 1]`. -/
theorem weight64_mem (x lo hi : ℝ) (h1 : lo ≤ x) (h2 : x ≤ hi) :
    0 ≤ weight64 x lo hi ∧ weight64 x lo hi ≤ 1 := by
  have r0 : rn (0 : ℝ) = 0 := rn_of_repr repr_zero
  have r1 : rn (1 : ℝ) = 1 := by
    have := rn_of_repr (repr_intCast (K := ℝ) (n := 1) (by norm_num)); simpa using this
  have ha : 0 ≤ fsub x lo := by rw [fsub, ← r0]; exact rn_mono (by linarith)
  have hab : fsub x lo ≤ fsub hi lo := rn_mono (by linarith)
  unfold weight64 fdiv
  rcases (ha.trans hab).lt_or_eq with hb | hb
  · constructor
    · rw [← r0]; exact rn_mono (div_nonneg ha hb.le)
    · rw [← r1]; exact rn_mono ((div_le_one hb).mpr hab)
  · rw [← hb, div_zero, r0]; norm_num

/-- **Q-6**, for `interp.linear` / each blend of `interp.bilinear`: a query `x`
in the cell `[lo, hi]` (pinned weight), table values `t, u` doubles: the FMA
result is within `2 · ulp(max(|t|, |u|))` of the pinned non-FMA result. -/
theorem linear_fma_le_two_ulp (t u x lo hi : ℝ) (ht : Repr t) (hu : Repr u)
    (h1 : lo ≤ x) (h2 : x ≤ hi) :
    |blend64 t u (weight64 x lo hi) - blendFMA t u (weight64 x lo hi)| ≤
      2 * ulp (max |t| |u|) := by
  obtain ⟨w0, w1⟩ := weight64_mem x lo hi h1 h2
  exact blend_fma_le_two_ulp t u _ ht hu w0 w1

/-- The constant 2 is attained: `interp.linear([t, u], [0, 1], 0.75)` with
`t = −(2^53 − 1)·2^-55`, `u = (2^53 − 3)·2^-54` differs between the pinned and
FMA evaluations by exactly `2 · ulp(max(|t|, |u|))`. -/
theorem blend_fma_two_ulp_attained :
    ∃ t u x lo hi : ℝ, Repr t ∧ Repr u ∧ Repr x ∧ Repr lo ∧ Repr hi ∧ lo ≤ x ∧ x ≤ hi ∧
      |blend64 t u (weight64 x lo hi) - blendFMA t u (weight64 x lo hi)| =
        2 * ulp (max |t| |u|) := by
  refine ⟨((-(2 ^ 53 - 1) / 2 ^ 55 : ℚ) : ℝ), (((2 ^ 53 - 3) / 2 ^ 54 : ℚ) : ℝ),
    ((3 / 4 : ℚ) : ℝ), ((0 : ℚ) : ℝ), ((1 : ℚ) : ℝ), ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  · exact ⟨-(2 ^ 53 - 1), -55, by norm_num, by norm_num, by push_cast; ring⟩
  · exact ⟨2 ^ 53 - 3, -54, by norm_num, by norm_num, by push_cast; ring⟩
  · exact ⟨3, -2, by norm_num, by norm_num, by push_cast; ring⟩
  · exact ⟨0, 0, by norm_num, by norm_num, by push_cast; ring⟩
  · exact ⟨1, 0, by norm_num, by norm_num, by push_cast; ring⟩
  · norm_num
  · norm_num
  · rw [weight64_ratCast, blend64_ratCast, blendFMA_ratCast, ← Rat.cast_abs, ← Rat.cast_abs,
      ← Rat.cast_max, ulp_ratCast, ← Rat.cast_sub, ← Rat.cast_abs]
    have : |blend64 (-(2 ^ 53 - 1) / 2 ^ 55 : ℚ) ((2 ^ 53 - 3) / 2 ^ 54)
          (weight64 (3 / 4) 0 1) -
        blendFMA (-(2 ^ 53 - 1) / 2 ^ 55 : ℚ) ((2 ^ 53 - 3) / 2 ^ 54) (weight64 (3 / 4) 0 1)| =
        2 * ulp (max |(-(2 ^ 53 - 1) / 2 ^ 55 : ℚ)| |((2 ^ 53 - 3) / 2 ^ 54 : ℚ)|) := by
      decide +kernel
    rw [this]; push_cast; ring

/-- The spec's mixed-FMA relaxation `{ abs: 0, rel: 4e-16 }`, as a claim about
`interp.linear`: the FMA result is within `4e-16 · |pinned|` of the pinned one.
-/
def RelClaim : Prop :=
  ∀ t u x lo hi : ℝ, Repr t → Repr u → Repr x → Repr lo → Repr hi → lo ≤ x → x ≤ hi →
    |blendFMA t u (weight64 x lo hi) - blend64 t u (weight64 x lo hi)| ≤
      4e-16 * |blend64 t u (weight64 x lo hi)|

/-- The relaxation fails by cancellation: `interp.linear([1, −2], [0, 3], 1)`
is `0` pinned (the exact value) and `2^-54` with FMA. -/
theorem linear_fma_rel_refuted : ¬ RelClaim := by
  intro h
  have hc := h ((1 : ℚ) : ℝ) ((-2 : ℚ) : ℝ) ((1 : ℚ) : ℝ) ((0 : ℚ) : ℝ) ((3 : ℚ) : ℝ)
    ⟨1, 0, by norm_num, by norm_num, by push_cast; ring⟩
    ⟨-2, 0, by norm_num, by norm_num, by push_cast; ring⟩
    ⟨1, 0, by norm_num, by norm_num, by push_cast; ring⟩
    ⟨0, 0, by norm_num, by norm_num, by push_cast; ring⟩
    ⟨3, 0, by norm_num, by norm_num, by push_cast; ring⟩ (by norm_num) (by norm_num)
  rw [weight64_ratCast, blend64_ratCast, blendFMA_ratCast] at hc
  have e0 : blend64 (1 : ℚ) (-2) (weight64 1 0 3) = 0 := by decide +kernel
  have e1 : blendFMA (1 : ℚ) (-2) (weight64 1 0 3) = 1 / 2 ^ 54 := by decide +kernel
  rw [e0, e1] at hc
  norm_num at hc

/-! ## The endpoint claims -/

/-- §9.2 "w = 0 ⇒ result = tᵢ exactly" holds in binary64 (signed zero aside). -/
theorem blend64_w_zero (t u : ℝ) (ht : Repr t) : blend64 t u 0 = t := by
  simp only [blend64, fadd, fmul, zero_mul, rn_of_repr repr_zero, add_zero, rn_of_repr ht]

/-- A query on the cell's left knot has pinned weight exactly 0. -/
theorem weight64_at_lo (lo hi : ℝ) : weight64 lo lo hi = 0 := by
  simp only [weight64, fdiv, fsub, sub_self, rn_of_repr repr_zero, zero_div]

/-- The spec's "w = 1 ⇒ result = tᵢ₊₁" as an exactness claim. -/
def WOneExact : Prop := ∀ t u : ℝ, Repr t → Repr u → blend64 t u 1 = u

/-- Refuted: `1 ⊕ (1 ⊗ (2^-60 ⊖ 1)) = 0`, not `2^-60` (the subtraction rounds
to `−1`). -/
theorem blend64_w_one_refuted : ¬ WOneExact := by
  intro h
  have hc := h ((1 : ℚ) : ℝ) ((1 / 2 ^ 60 : ℚ) : ℝ)
    ⟨1, 0, by norm_num, by norm_num, by push_cast; ring⟩
    ⟨1, -60, by norm_num, by norm_num, by push_cast; ring⟩
  rw [show (1 : ℝ) = ((1 : ℚ) : ℝ) by norm_num, blend64_ratCast] at hc
  have e : blend64 (1 : ℚ) (1 / 2 ^ 60) 1 = 0 := by decide +kernel
  rw [e] at hc
  norm_num at hc

/-- What holds at w = 1: exactness when `tᵢ₊₁ − tᵢ` is exact (Sterbenz,
`tᵢ/2 ≤ tᵢ₊₁ ≤ 2 tᵢ`). -/
theorem blend64_w_one_sterbenz (t u : ℝ) (ht : Repr t) (hu : Repr u) (h1 : t / 2 ≤ u)
    (h2 : u ≤ 2 * t) : blend64 t u 1 = u := by
  have hd := rn_sub_sterbenz hu ht h1 h2
  simp only [blend64, fsub, fmul, fadd, hd, one_mul]
  rw [show t + (u - t) = u by ring, rn_of_repr hu]

/-- What holds at w = 1 in general: within `3/2 · ulp(max(|tᵢ|, |tᵢ₊₁|))` of
`tᵢ₊₁`. -/
theorem blend64_w_one_le (t u : ℝ) (ht : Repr t) (hu : Repr u) :
    |blend64 t u 1 - u| ≤ 3 / 2 * ulp (max |t| |u|) := by
  set M := max |t| |u| with hMdef
  set e := fexp M
  have he : -1074 ≤ e := fexp_ge M
  set g : ℝ := 2 ^ e
  have hM0 : 0 ≤ M := le_max_of_le_left (abs_nonneg t)
  have hMr : Repr M := by
    rcases max_choice |t| |u| with h | h <;> rw [hMdef, h]
    · rcases abs_choice t with h' | h' <;> rw [h']
      exacts [ht, repr_neg ht]
    · rcases abs_choice u with h' | h' <;> rw [h']
      exacts [hu, repr_neg hu]
  have hMB : M ≤ 2 ^ (e + 53) - g := repr_le_top hMr hM0
  have hgpos : 0 < g := zpow_pos two_pos _
  have hut : |u - t| ≤ 2 * M := by
    calc |u - t| ≤ |u| + |t| := abs_sub _ _
      _ ≤ 2 * M := by linarith [le_max_left |t| |u|, le_max_right |t| |u|]
  have hd : |rn (u - t) - (u - t)| ≤ g := by
    have hu' := ulp_le (x := u - t) (k := e + 54) (by
      rw [show e + 54 = (e + 53) + 1 by ring, zpow_add_one₀ two_ne_zero]; linarith) (by omega)
    have : (2 : ℝ) ^ (e + 54 - 53) = 2 * g := by
      rw [show e + 54 - 53 = e + 1 by ring, zpow_add_one₀ two_ne_zero]; ring
    rw [this] at hu'
    linarith [abs_rn_sub_le (u - t)]
  have hs : |t + rn (u - t)| ≤ 2 ^ (e + 53) := by
    have : t + rn (u - t) = u + (rn (u - t) - (u - t)) := by ring
    rw [this]
    calc _ ≤ |u| + |rn (u - t) - (u - t)| := abs_add_le _ _
      _ ≤ M + g := add_le_add (le_max_right _ _) hd
      _ ≤ _ := by linarith
  have e1 := abs_rn_sub_le_of_le he hs
  have hb : blend64 t u 1 = rn (t + rn (u - t)) := by
    simp only [blend64, fadd, fmul, fsub, one_mul, rn_of_repr (repr_rn (u - t))]
  rw [hb]
  have hg : ulp M = g := rfl
  rw [hg]
  calc |rn (t + rn (u - t)) - u|
      = |(rn (t + rn (u - t)) - (t + rn (u - t))) + (rn (u - t) - (u - t))| := by ring_nf
    _ ≤ |rn (t + rn (u - t)) - (t + rn (u - t))| + |rn (u - t) - (u - t)| := abs_add_le _ _
    _ ≤ g / 2 + g := add_le_add e1 hd
    _ = 3 / 2 * g := by ring

end Bound

end Esm.Closed.Rounding
