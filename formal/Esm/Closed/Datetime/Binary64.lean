import Esm.Closed.Datetime.ExactFacts
import Esm.Float64

/-!
# `datetime.*` in binary64 (esm-spec §9.2 rounding claims)

§9.2 has bindings take `t_utc` as a binary64 and do "a single floor-divmod by
86400" before exact integer arithmetic, and says the result is exact on the
integer outputs and within 1 ulp on `julian_day`. This module writes that
binary64 pipeline in the `Esm.F64` model, operation for operation:

* `fDayNumber t = ⌊t ⊘ 86400⌋`;
* `fTimeOfDay t = t ⊖ (86400 ⊗ d)`, the remainder of the floor-divmod;
* `fJulianDay t = JDN ⊕ ((tod ⊖ 43200) ⊘ 86400)`, the spec's reference
  computation with the JDN rounded to a double first.

and compares it with the exact model (`Exact.lean`).
-/

namespace Esm.Closed.Datetime

open Esm.F64

set_option linter.unusedSectionVars false

variable {K : Type*} [Field K] [LinearOrder K] [IsStrictOrderedRing K] [FloorRing K]

/-! ## The binary64 pipeline -/

/-- `⌊t ⊘ 86400⌋`. -/
def fDayNumber (t : K) : ℤ := ⌊fdiv t 86400⌋

/-- `t ⊖ (86400 ⊗ d)`: the floor-divmod remainder computed in binary64. -/
def fTimeOfDay (t : K) : K := fsub t (fmul 86400 (fDayNumber t : K))

/-- `⌊tod⌋` from the binary64 remainder. -/
def fSecondOfDay (t : K) : ℤ := ⌊fTimeOfDay t⌋

/-- The spec's julian_day reference computation in binary64. -/
def fJulianDay (t : K) : K :=
  fadd (rn (fvfJdn (civilFromDays (fDayNumber t)) : K)) (fdiv (fsub (fTimeOfDay t) 43200) 86400)

/-! ## Helpers about the binary64 model -/

private lemma two_zpow_pos' (e : ℤ) : (0 : K) < 2 ^ e := zpow_pos two_pos e

private lemma two_zpow_lt {a b : ℤ} (h : a < b) : (2 : K) ^ a < 2 ^ b :=
  zpow_lt_zpow_right₀ one_lt_two h

private lemma two_zpow_le {a b : ℤ} (h : a ≤ b) : (2 : K) ^ a ≤ 2 ^ b :=
  zpow_le_zpow_right₀ one_le_two h

theorem ulp_neg (x : K) : ulp (-x) = ulp x := by
  simp [ulp, fexp, abs_neg]

theorem ulp_mono {x y : K} (h : |x| ≤ |y|) : ulp x ≤ ulp y := two_zpow_le (fexp_mono h)

/-- The exponent from a binade: `2^k ≤ |x| < 2^(k+1)` (normal) gives
`fexp x = k - 52`. -/
theorem fexp_of_binade {x : K} {k : ℤ} (h1 : 2 ^ k ≤ |x|) (h2 : |x| < 2 ^ (k + 1))
    (hk : -1022 ≤ k) : fexp x = k - 52 := by
  have hx : 0 < |x| := lt_of_lt_of_le (two_zpow_pos' k) h1
  rw [fexp_of_normal ((two_zpow_le hk).trans h1)]
  have a := (Int.zpow_le_iff_le_log (b := 2) (by norm_num) hx).1 (by simpa using h1)
  have b := (Int.lt_zpow_iff_log_lt (b := 2) (by norm_num) hx).1 (by simpa using h2)
  omega

theorem rne_of_lt_half {r : K} {k : ℤ} (hk : ⌊r⌋ = k) (h : r - k < 1 / 2) : rne r = k := by
  unfold rne; rw [hk, if_pos h]

theorem rne_of_gt_half {r : K} {k : ℤ} (hk : ⌊r⌋ = k) (h : 1 / 2 < r - k) : rne r = k + 1 := by
  unfold rne; rw [hk, if_neg (not_lt.mpr h.le), if_pos h]

/-- Rounding twice the distance: if `x` is within half an ulp of `J`, `rn x` is
within one ulp of `J`. (Across a power of two the half-ulp bound on `rn x - x`
alone would give one and a half.) -/
theorem abs_rn_sub_le_ulp {J x : K} (h : |x - J| ≤ ulp J / 2) : |rn x - J| ≤ ulp J := by
  -- Reduce to `0 ≤ J`.
  wlog hJ : 0 ≤ J generalizing J x
  · have h' : |-x - -J| ≤ ulp (-J) / 2 := by
      rw [ulp_neg, show -x - -J = -(x - J) by ring, abs_neg]; exact h
    have := this h' (by linarith)
    rwa [rn_neg, ulp_neg, show -rn x - -J = -(rn x - J) by ring, abs_neg] at this
  set g := ulp J with hg
  have hgp : 0 < g := ulp_pos J
  have hP : |J| < 2 ^ (fexp J + 53) := abs_lt_fexp J
  rw [abs_of_nonneg hJ] at hP
  have hx := abs_le.mp h
  by_cases hxP : |x| < 2 ^ (fexp J + 53)
  · have hux : ulp x ≤ g := two_zpow_le (fexp_le hxP (fexp_ge J))
    have := abs_rn_sub_le x
    calc |rn x - J| = |(rn x - x) + (x - J)| := by ring_nf
      _ ≤ |rn x - x| + |x - J| := abs_add_le _ _
      _ ≤ g := by linarith
  · -- `x` is at or above the power of two `P` just above `J`; it rounds to `P`.
    obtain ⟨F, hF⟩ : ∃ F : ℤ, fexp J = F - 1 := ⟨fexp J + 1, by ring⟩
    have hPF : (2 : K) ^ (fexp J + 53) = 2 ^ (F + 52) := by
      rw [hF, show F - 1 + 53 = F + 52 by ring]
    have hgF : g = 2 ^ (F - 1) := by rw [hg, ulp, hF]
    have hg2 : g / 2 < 2 ^ (F + 52) := by
      rw [hgF]
      have := two_zpow_lt (K := K) (show F - 1 < F + 52 by omega)
      linarith
    have hxge : 2 ^ (F + 52) ≤ x := by
      rw [← hPF]
      rcases le_or_gt 0 x with h0 | h0
      · rw [abs_of_nonneg h0] at hxP; linarith
      · exfalso; rw [abs_of_neg h0] at hxP; rw [← hPF] at hg2; linarith
    have hxle : x ≤ 2 ^ (F + 52) + g / 2 := by rw [← hPF]; linarith
    have hPrepr : Repr ((2 : K) ^ (F + 52)) :=
      ⟨1, F + 52, by norm_num, by have := fexp_ge J; omega, by simp⟩
    have hlow : 2 ^ (F + 52) ≤ rn x := by
      rw [← rn_of_repr hPrepr]; exact rn_mono hxge
    -- `rn (P + g/2) = P`.
    set y := (2 : K) ^ (F + 52) + g / 2 with hy
    have hy0 : 0 < y := by rw [hy]; positivity
    have hfy : fexp y = F := by
      apply le_antisymm
      · apply fexp_le _ (by have := fexp_ge J; omega)
        rw [abs_of_pos hy0, hy]
        have : (2 : K) ^ (F + 53) = 2 * 2 ^ (F + 52) := by
          rw [show F + 53 = (F + 52) + 1 by ring, zpow_add_one₀ two_ne_zero, mul_comm]
        rw [this]; linarith
      · have hPy : fexp ((2 : K) ^ (F + 52)) ≤ fexp y := by
          apply fexp_mono
          rw [abs_of_pos (two_zpow_pos' _), abs_of_pos hy0, hy]; linarith
        by_contra hlt
        have h1 : fexp ((2 : K) ^ (F + 52)) ≤ F - 1 := by omega
        have := abs_lt_fexp ((2 : K) ^ (F + 52))
        rw [abs_of_pos (two_zpow_pos' _)] at this
        have := two_zpow_le (K := K) (show fexp ((2 : K) ^ (F + 52)) + 53 ≤ F + 52 by omega)
        linarith
    have hry : rn y = 2 ^ (F + 52) := by
      have hdiv : y / 2 ^ fexp y = (2 ^ 52 : ℤ) + 1 / 4 := by
        rw [hfy, hy, hgF, add_div]
        have e1 : (2 : K) ^ (F + 52) / 2 ^ F = 2 ^ (52 : ℤ) := by
          rw [← zpow_sub₀ two_ne_zero, show F + 52 - F = (52 : ℤ) by ring]
        have e2 : (2 : K) ^ (F - 1) / 2 / 2 ^ F = 1 / 4 := by
          rw [div_div, show (2 : K) * 2 ^ F = 2 ^ (F + 1) by
            rw [zpow_add_one₀ two_ne_zero, mul_comm], ← zpow_sub₀ two_ne_zero,
            show F - 1 - (F + 1) = (-2 : ℤ) by ring]
          norm_num
        rw [e1, e2]; push_cast; norm_num
      have hfl : ⌊y / 2 ^ fexp y⌋ = 2 ^ 52 := by
        rw [hdiv, Int.floor_eq_iff]; push_cast; constructor <;> linarith
      rw [rn_eq, rne_of_lt_half hfl (by rw [hdiv]; push_cast; norm_num), hfy,
        show F + 52 = F + ((52 : ℕ) : ℤ) by norm_num, zpow_add₀ two_ne_zero, zpow_natCast]
      push_cast; ring
    have hhigh : rn x ≤ 2 ^ (F + 52) := by rw [← hry]; exact rn_mono hxle
    have : rn x = 2 ^ (F + 52) := le_antisymm hhigh hlow
    rw [this, abs_le]; rw [← hPF] at hxge ⊢; constructor <;> linarith

/-! ## (a) The binary64 floor of `t / 86400` -/

/-- The floor of the binary64 quotient is the exact floor for every double `t`
with `|t| < 2^60`, except the negative `t` so small that `t / 86400`
underflows to zero: `-43200 · 2^-1074 ≤ t < 0`. -/
theorem fDayNumber_eq {t : K} (ht : Repr t) (hb : |t| < 2 ^ (60 : ℤ))
    (hband : ¬ (-(43200 * 2 ^ (-1074 : ℤ)) ≤ t ∧ t < 0)) : fDayNumber t = dayNumber t := by
  unfold fDayNumber dayNumber fdiv
  set q := t / 86400 with hq
  have h86 : (0 : K) < 86400 := by norm_num
  have h2_16 : (2 : K) ^ (16 : ℤ) < 86400 := by norm_num
  have h2_17 : (86400 : K) < 2 ^ (17 : ℤ) := by norm_num
  have hfl1 := Int.floor_le q
  have hfl2 := Int.lt_floor_add_one q
  have hqabs : |q| = |t| / 86400 := by rw [hq, abs_div, abs_of_pos h86]
  apply floor_rn_eq
  · -- `|⌊q⌋| ≤ 2^53`
    have : |q| < 2 ^ (53 : ℤ) := by
      rw [hqabs, div_lt_iff₀ h86]
      have : (2 : K) ^ (60 : ℤ) ≤ 2 ^ (53 : ℤ) * 86400 := by norm_num
      linarith
    have h1 := (abs_lt.mp this)
    have : ((-(2 ^ 53) : ℤ) : K) < ⌊q⌋ + 1 := by push_cast; norm_num at h1 ⊢; linarith
    have : (⌊q⌋ : K) < ((2 ^ 53 : ℤ) : K) := by push_cast; norm_num at h1 ⊢; linarith
    rw [abs_le]; constructor
    · have : (-(2 ^ 53) : ℤ) < ⌊q⌋ + 1 := by exact_mod_cast ‹((-(2 ^ 53) : ℤ) : K) < ⌊q⌋ + 1›
      omega
    · have : ⌊q⌋ < (2 ^ 53 : ℤ) := by exact_mod_cast ‹(⌊q⌋ : K) < ((2 ^ 53 : ℤ) : K)›
      omega
  · obtain ⟨n, hn⟩ := repr_iff.mp ht
    set E := fexp t with hE
    by_cases hEb : -1058 ≤ E
    · -- The gap `86400 (⌊q⌋ + 1) - t` is a positive multiple of `2^E` and `E ≤ 7`.
      have hE7 : E ≤ 7 := by
        by_contra hc
        have : -1074 < E := by omega
        have := two_zpow_le_of_fexp this
        have := two_zpow_le (K := K) (show (60 : ℤ) ≤ E + 52 by omega)
        rw [← hE] at *; linarith
      have hulp : ulp q ≤ 2 ^ (E - 16) := by
        have := ulp_le (x := q) (k := E + 37) ?_ (by omega)
        · simpa [show E + 37 - 53 = E - 16 by ring] using this
        rw [hqabs, div_lt_iff₀ h86]
        have h1 := abs_lt_fexp t
        rw [← hE] at h1
        have : (2 : K) ^ (E + 53) = 2 ^ (E + 37) * 2 ^ (16 : ℤ) := by
          rw [← zpow_add₀ two_ne_zero]; ring_nf
        rw [this] at h1
        have := mul_lt_mul_of_pos_left h2_16 (two_zpow_pos' (K := K) (E + 37))
        linarith
      -- 86400 = 675 · 2^(7-E) · 2^E
      have hc : (86400 : K) = ((675 * 2 ^ (7 - E).toNat : ℤ) : K) * 2 ^ E := by
        push_cast
        rw [mul_assoc, ← zpow_natCast, ← zpow_add₀ two_ne_zero, Int.toNat_of_nonneg (by omega)]
        ring_nf; norm_num
      set k : ℤ := 675 * 2 ^ (7 - E).toNat * (⌊q⌋ + 1) - n with hk
      have hgap : 86400 * ((⌊q⌋ : K) + 1) - t = (k : K) * 2 ^ E := by
        rw [hk, hn, hc]; push_cast; ring
      have hpos : 0 < 86400 * ((⌊q⌋ : K) + 1) - t := by
        have : t < 86400 * ((⌊q⌋ : K) + 1) := by
          rw [hq] at hfl2; rwa [div_lt_iff₀ h86, mul_comm] at hfl2
        linarith
      have hk1 : 1 ≤ k := by
        have : (0 : K) < k := by
          rw [hgap] at hpos; exact pos_of_mul_pos_left hpos (two_zpow_pos' E).le
        exact_mod_cast this
      have hk1' : (1 : K) ≤ k := by exact_mod_cast hk1
      have : (⌊q⌋ : K) + 1 - q = (k : K) * 2 ^ E / 86400 := by
        rw [← hgap, hq]; field_simp
      rw [this]
      have : (2 : K) ^ (E - 16) / 2 < 2 ^ E / 86400 := by
        rw [div_lt_div_iff₀ two_pos h86]
        have : (2 : K) ^ E = 2 ^ (E - 16) * 2 ^ (16 : ℤ) := by
          rw [← zpow_add₀ two_ne_zero]; ring_nf
        rw [this]
        have := two_zpow_pos' (K := K) (E - 16)
        nlinarith
      have : (2 : K) ^ E / 86400 ≤ k * 2 ^ E / 86400 := by
        apply div_le_div_of_nonneg_right _ h86.le
        nlinarith [two_zpow_pos' (K := K) E]
      linarith
    · -- Tiny `t`: `|t| < 2^-1005`.
      have htiny : |t| < 2 ^ (-1005 : ℤ) := by
        have := abs_lt_fexp t
        rw [← hE] at this
        exact lt_of_lt_of_le this (two_zpow_le (by omega))
      have hqtiny : |q| < 2 ^ (-1021 : ℤ) := by
        rw [hqabs, div_lt_iff₀ h86]
        have : (2 : K) ^ (-1005 : ℤ) ≤ 2 ^ (-1021 : ℤ) * 86400 := by
          rw [show (-1005 : ℤ) = -1021 + 16 by norm_num, zpow_add₀ two_ne_zero]
          have := two_zpow_pos' (K := K) (-1021)
          nlinarith
        linarith
      have hq1 : |q| < 1 / 2 := lt_of_lt_of_le hqtiny (by
        rw [show (1 : K) / 2 = 2 ^ (-1 : ℤ) by norm_num]; exact two_zpow_le (by norm_num))
      rcases le_or_gt 0 t with h0 | h0
      · have hq0 : 0 ≤ q := div_nonneg h0 h86.le
        have hfq : ⌊q⌋ = 0 := by
          rw [Int.floor_eq_iff]; rw [abs_of_nonneg hq0] at hq1; constructor <;> push_cast <;> linarith
        have hu : ulp q ≤ 2 ^ (-53 : ℤ) := ulp_le (k := 0) (by
          rw [zpow_zero]; linarith [abs_nonneg q]) (by norm_num)
        rw [hfq, Int.cast_zero]
        rw [abs_of_nonneg hq0] at hq1
        have : (2 : K) ^ (-53 : ℤ) ≤ 2 ^ (-1 : ℤ) := two_zpow_le (by norm_num)
        rw [show (2 : K) ^ (-1 : ℤ) = 1 / 2 by norm_num] at this
        generalize (2 : K) ^ (-53 : ℤ) = X at *
        generalize ulp q = U at *
        linarith
      · have hq0 : q < 0 := div_neg_of_neg_of_pos h0 h86
        have hfq : ⌊q⌋ = -1 := by
          rw [Int.floor_eq_iff]; rw [abs_of_neg hq0] at hq1; constructor <;> push_cast <;> linarith
        have hu : ulp q ≤ 2 ^ (-1074 : ℤ) := by
          have := ulp_le (k := -1021) hqtiny (by norm_num); simpa using this
        rw [hfq]; push_cast
        have : t < -(43200 * 2 ^ (-1074 : ℤ)) := by
          by_contra hc; exact hband ⟨not_lt.mp hc, h0⟩
        have : q < -(2 ^ (-1074 : ℤ) / 2) := by
          rw [hq, div_lt_iff₀ h86]; linarith
        linarith

/-- In the underflow band the binary64 floor is one day late (`t / 86400`
rounds to zero, whose floor is day 0, while `⌊t / 86400⌋ = -1`). -/
theorem fDayNumber_band {t : K} (h1 : -(43200 * 2 ^ (-1074 : ℤ)) ≤ t) (h2 : t < 0) :
    fDayNumber t = dayNumber t + 1 := by
  have h86 : (0 : K) < 86400 := by norm_num
  set q := t / 86400 with hq
  have hq0 : q < 0 := div_neg_of_neg_of_pos h2 h86
  have hql : -(2 ^ (-1074 : ℤ) / 2) ≤ q := by
    rw [hq, le_div_iff₀ h86]; linarith
  have hsmall : (2 : K) ^ (-1074 : ℤ) / 2 < 1 := by
    have := two_zpow_lt (K := K) (show (-1074 : ℤ) < 0 by norm_num)
    rw [zpow_zero] at this; linarith
  have hday : dayNumber t = -1 := by
    unfold dayNumber; rw [Int.floor_eq_iff]; push_cast
    constructor <;> linarith
  have hqabs : |q| < 2 ^ (-1021 : ℤ) := by
    rw [abs_of_neg hq0]
    have := two_zpow_lt (K := K) (show (-1074 : ℤ) < -1021 by norm_num)
    have := two_zpow_pos' (K := K) (-1074)
    linarith
  have hfe : fexp q = -1074 := le_antisymm (by
    have := fexp_le (x := q) (e := -1074) (by simpa using hqabs) (le_refl _); exact this) (fexp_ge q)
  have hr : ⌊q / 2 ^ fexp q⌋ = -1 := by
    rw [hfe, Int.floor_eq_iff, div_lt_iff₀ (two_zpow_pos' _), le_div_iff₀ (two_zpow_pos' _)]
    push_cast; constructor <;> nlinarith [two_zpow_pos' (K := K) (-1074)]
  have hrne : rne (q / 2 ^ fexp q) = 0 := by
    unfold rne; rw [hr]
    have hge : 1 / 2 ≤ q / 2 ^ fexp q - ((-1 : ℤ) : K) := by
      rw [hfe]; push_cast
      have : -(1 / 2) ≤ q / 2 ^ (-1074 : ℤ) := by
        rw [le_div_iff₀ (two_zpow_pos' _)]; linarith
      linarith
    simp only [not_lt.mpr hge, ite_false]
    split_ifs <;> simp_all
  unfold fDayNumber fdiv
  rw [hday, ← hq, rn_eq, hrne]; simp

/-- Above `2^60` the floor can be off: `t = 86400 · (2^44 + 1) - 128` is a
double (a multiple of `2^8` below `2^61`) whose quotient rounds up to the
integer `2^44 + 1`. -/
theorem fDayNumber_ne_large :
    ¬ ∀ t : ℝ, IsF64 t → |t| < 2 ^ (61 : ℤ) → fDayNumber t = dayNumber t := by
  intro h
  set t : ℝ := 86400 * (2 ^ 44 + 1) - 128 with ht
  have htpos : 0 < t := by rw [ht]; norm_num
  have hrepr : IsF64 t := by
    refine ⟨⟨(675 * (2 ^ 44 + 1) - 1) / 2, 8, by norm_num, by norm_num, ?_⟩, ?_⟩
    · rw [ht]; norm_num
    · rw [abs_of_pos htpos, ht, maxFinite, show (971 : ℤ) = ((971 : ℕ) : ℤ) by norm_num,
        zpow_natCast]
      have : (2 : ℝ) ^ 10 ≤ 2 ^ 971 := pow_le_pow_right₀ (by norm_num) (by norm_num)
      norm_num at this ⊢
      generalize (2 : ℝ) ^ 971 = X at *
      linarith
  have hlt : |t| < 2 ^ (61 : ℤ) := by rw [abs_of_pos htpos, ht]; norm_num
  have := h t hrepr hlt
  set q : ℝ := t / 86400 with hq
  have hqpos : 0 < q := by rw [hq]; positivity
  have hday : dayNumber t = 2 ^ 44 := by
    unfold dayNumber; rw [Int.floor_eq_iff, ← hq, hq, ht]; norm_num
  have hfe : fexp q = -8 := by
    have hb1 : (2 : ℝ) ^ (44 : ℤ) ≤ |q| := by rw [abs_of_pos hqpos, hq, ht]; norm_num
    have hb2 : |q| < (2 : ℝ) ^ ((44 : ℤ) + 1) := by rw [abs_of_pos hqpos, hq, ht]; norm_num
    rw [fexp_of_binade hb1 hb2 (by norm_num)]; norm_num
  have hfl : ⌊q / 2 ^ fexp q⌋ = 256 * (2 ^ 44 + 1) - 1 := by
    rw [hfe, Int.floor_eq_iff, hq, ht]; norm_num
  have hrne : rne (q / 2 ^ fexp q) = 256 * (2 ^ 44 + 1) - 1 + 1 :=
    rne_of_gt_half hfl (by rw [hfe, hq, ht]; norm_num)
  have hf : fDayNumber t = 2 ^ 44 + 1 := by
    unfold fDayNumber fdiv
    rw [← hq, rn_eq, hrne, hfe, Int.floor_eq_iff]; norm_num
  rw [hf, hday] at this
  norm_num at this

end Esm.Closed.Datetime
