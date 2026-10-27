import Esm.Closed.Datetime.Binary64

/-!
# The binary64 time of day and julian_day (esm-spec §9.2)

* `fTimeOfDay_eq`: the binary64 remainder `t ⊖ 86400 ⊗ d` is exact for every
  double `|t| ≤ 2^59` outside `(-43200, 0)`;
* `fSecondOfDay_ne`: inside that interval it is not, and `⌊tod⌋` can be a
  second late (`t = -1 - 2^-52` gives 86399, the exact value is 86398);
* `fJulianDay_err`: the binary64 julian_day §9.2 pins is within one ulp of
  the exact Julian Date, for every double `|t| ≤ 2^59`;
* `fFvfJulianDay_err`: so is the informative Fliegel–van Flandern
  computation, of the exact value of its own formula.
-/

namespace Esm.Closed.Datetime

open Esm.F64

set_option linter.unusedSectionVars false

variable {K : Type*} [Field K] [LinearOrder K] [IsStrictOrderedRing K] [FloorRing K]

private lemma two_zpow_pos' (e : ℤ) : (0 : K) < 2 ^ e := zpow_pos two_pos e

private lemma two_zpow_le' {a b : ℤ} (h : a ≤ b) : (2 : K) ^ a ≤ 2 ^ b :=
  zpow_le_zpow_right₀ one_le_two h

theorem band_lt_one : (43200 : K) * 2 ^ (-1074 : ℤ) < 1 := by
  have : (2 : K) ^ (-1074 : ℤ) ≤ 2 ^ (-17 : ℤ) := two_zpow_le' (by norm_num)
  have : (43200 : K) * 2 ^ (-17 : ℤ) < 1 := by norm_num
  nlinarith [two_zpow_pos' (K := K) (-1074)]

theorem dayNumber_bounds (t : K) :
    86400 * (dayNumber t : K) ≤ t ∧ t < 86400 * ((dayNumber t : K) + 1) := by
  constructor
  · exact (le_dayNumber_iff t _).mp le_rfl
  · have := (dayNumber_lt_iff t (dayNumber t + 1)).mp (by omega)
    push_cast at this; exact this

/-- For `|t| ≤ 2^59`, `86400 · ⌊t/86400⌋ = 675 d · 2^7` with `|675 d| < 2^53`. -/
theorem dayNumber_small {t : K} (hb : |t| ≤ 2 ^ (59 : ℤ)) : |675 * dayNumber t| < 2 ^ 53 := by
  obtain ⟨h1, h2⟩ := dayNumber_bounds t
  have e : (2 : K) ^ (59 : ℤ) = ((576460752303423488 : ℤ) : K) := by norm_num
  rw [e, abs_le] at hb
  have a1 : ((86400 * dayNumber t : ℤ) : K) ≤ ((576460752303423488 : ℤ) : K) := by
    push_cast; linarith
  have a2 : ((-576460752303423488 : ℤ) : K) < ((86400 * (dayNumber t + 1) : ℤ) : K) := by
    push_cast; linarith
  have b1 : 86400 * dayNumber t ≤ 576460752303423488 := by exact_mod_cast a1
  have b2 : -576460752303423488 < 86400 * (dayNumber t + 1) := by exact_mod_cast a2
  rw [abs_lt]; constructor <;> omega

theorem repr_86400_mul {d : ℤ} (h : |675 * d| < 2 ^ 53) : Repr ((86400 : K) * d) :=
  ⟨675 * d, 7, h, by norm_num, by push_cast; norm_num; ring⟩

/-! ## The time of day -/

theorem fTimeOfDay_eq {t : K} (ht : Repr t) (hb : |t| ≤ 2 ^ (59 : ℤ))
    (hneg : ¬ (-43200 < t ∧ t < 0)) : fTimeOfDay t = timeOfDay t := by
  have h60 : |t| < 2 ^ (60 : ℤ) := lt_of_le_of_lt hb (zpow_lt_zpow_right₀ one_lt_two (by norm_num))
  have hband : ¬ (-(43200 * 2 ^ (-1074 : ℤ)) ≤ t ∧ t < 0) := by
    rintro ⟨h1, h2⟩
    have : (2 : K) ^ (-1074 : ℤ) < 1 := by
      have := zpow_lt_zpow_right₀ (one_lt_two (α := K)) (show (-1074 : ℤ) < 0 by norm_num)
      rwa [zpow_zero] at this
    exact hneg ⟨by nlinarith, h2⟩
  have hd := fDayNumber_eq ht h60 hband
  unfold fTimeOfDay timeOfDay fsub fmul
  rw [hd]
  set d := dayNumber t with hdd
  have hm : Repr ((86400 : K) * d) := repr_86400_mul (dayNumber_small hb)
  rw [rn_of_repr hm]
  obtain ⟨b1, b2⟩ := dayNumber_bounds t
  rw [← hdd] at b1 b2
  rcases lt_trichotomy d 0 with hlt | heq | hgt
  · -- `d ≤ -1`, and `t ≤ -43200`: Sterbenz on the negated pair.
    have hdK : (d : K) ≤ -1 := by exact_mod_cast (show d ≤ -1 by omega)
    have htle : t ≤ -43200 := by
      by_contra hc
      exact hneg ⟨lt_of_not_ge hc, by nlinarith⟩
    have hx : Repr (-t) := repr_neg ht
    have hy : Repr (-((86400 : K) * d)) := repr_neg hm
    have hs := rn_sub_sterbenz hx hy (by
      rcases (show d = -1 ∨ d ≤ -2 by omega) with h | h
      · rw [h] at b1 b2 ⊢; push_cast; linarith
      · have : (d : K) ≤ -2 := by exact_mod_cast h
        nlinarith) (by nlinarith)
    have : t - 86400 * (d : K) = -(-t - -((86400 : K) * d)) := by ring
    rw [this, rn_neg, hs]
  · rw [heq]; simp only [Int.cast_zero, mul_zero, sub_zero]; exact rn_of_repr ht
  · have hdK : (1 : K) ≤ d := by exact_mod_cast (show 1 ≤ d by omega)
    exact rn_sub_sterbenz ht hm (by nlinarith) (by nlinarith)

/-- Inside `(-43200, 0)` the binary64 remainder can round up to the next whole
second: at `t = -1 - 2^-52` (1969-12-31T23:59:58.99…), `86400 + t` rounds to
86399, so `⌊tod⌋` reads 23:59:59. -/
theorem fSecondOfDay_ne :
    ¬ ∀ t : ℝ, IsF64 t → |t| ≤ 2 ^ (59 : ℤ) → fSecondOfDay t = secondOfDay t := by
  intro h
  set t : ℝ := -1 - 2 ^ (-52 : ℤ) with ht
  have hrepr : Repr t := ⟨-(2 ^ 52 + 1), -52, by norm_num, by norm_num, by rw [ht]; norm_num⟩
  have htneg : t < 0 := by rw [ht]; norm_num
  have hF : IsF64 t := ⟨hrepr, by
    rw [abs_of_neg htneg, ht, maxFinite, show (971 : ℤ) = ((971 : ℕ) : ℤ) by norm_num, zpow_natCast]
    have : (2 : ℝ) ^ 1 ≤ 2 ^ 971 := pow_le_pow_right₀ (by norm_num) (by norm_num)
    norm_num at this ⊢
    generalize (2 : ℝ) ^ 971 = X at *
    linarith⟩
  have hb : |t| ≤ 2 ^ (59 : ℤ) := by rw [abs_of_neg htneg, ht]; norm_num
  have h1 := h t hF hb
  have hday : dayNumber t = -1 := by
    unfold dayNumber; rw [Int.floor_eq_iff, ht]; norm_num
  have hband : ¬ (-(43200 * 2 ^ (-1074 : ℤ)) ≤ t ∧ t < 0) := by
    rintro ⟨h2, -⟩; rw [ht] at h2
    have := band_lt_one (K := ℝ); have := two_zpow_pos' (K := ℝ) (-52); linarith
  have hfd : fDayNumber t = -1 := by
    rw [fDayNumber_eq hrepr (lt_of_le_of_lt hb (by norm_num)) hband, hday]
  have hsec : secondOfDay t = 86398 := by
    unfold secondOfDay timeOfDay; rw [hday, Int.floor_eq_iff, ht]; norm_num
  set x : ℝ := t - 86400 * (-1 : ℤ) with hx
  have hxv : x = 86399 - 2 ^ (-52 : ℤ) := by rw [hx, ht]; push_cast; ring
  have hxpos : 0 < x := by rw [hxv]; norm_num
  have hfe : fexp x = -36 := by
    have hb1 : (2 : ℝ) ^ (16 : ℤ) ≤ |x| := by rw [abs_of_pos hxpos, hxv]; norm_num
    have hb2 : |x| < (2 : ℝ) ^ ((16 : ℤ) + 1) := by rw [abs_of_pos hxpos, hxv]; norm_num
    rw [fexp_of_binade hb1 hb2 (by norm_num)]; norm_num
  have hfl : ⌊x / 2 ^ fexp x⌋ = 86399 * 2 ^ 36 - 1 := by
    rw [hfe, Int.floor_eq_iff, hxv]; norm_num
  have hrne : rne (x / 2 ^ fexp x) = 86399 * 2 ^ 36 - 1 + 1 :=
    rne_of_gt_half hfl (by rw [hfe, hxv]; norm_num)
  have hm : fmul (86400 : ℝ) ((-1 : ℤ) : ℝ) = 86400 * (-1 : ℤ) := by
    unfold fmul; exact rn_of_repr (repr_86400_mul (by norm_num))
  have hfs : fSecondOfDay t = 86399 := by
    unfold fSecondOfDay fTimeOfDay fsub
    rw [hfd, hm, ← hx, rn_eq, hrne, hfe, Int.floor_eq_iff]; norm_num
  rw [hfs, hsec] at h1
  norm_num at h1

/-! ## julian_day -/

theorem civil_zero_jdn : fvfJdn (civilFromDays 0) = 2440588 := by decide
theorem civil_neg_one_jdn : fvfJdn (civilFromDays (-1)) = 2440587 := by decide

/-- The exponent of a double with `|t| ≥ 2^16` is at least `-36`. -/
theorem fexp_ge_of_ge {t : K} (h : 2 ^ (16 : ℤ) ≤ |t|) : -36 ≤ fexp t := by
  have h0 : 0 < |t| := lt_of_lt_of_le (two_zpow_pos' 16) h
  rw [fexp_of_normal ((two_zpow_le' (by norm_num)).trans h)]
  have := (Int.zpow_le_iff_le_log (b := 2) (x := 16) (by norm_num) h0).1 (by exact_mod_cast h)
  omega

/-- `tod - 43200` is a double when `t` is a double with `2^16 ≤ |t| ≤ 2^59`. -/
theorem repr_tod_sub {t : K} (ht : Repr t) (h16 : 2 ^ (16 : ℤ) ≤ |t|) (hb : |t| ≤ 2 ^ (59 : ℤ)) :
    F64.Repr (timeOfDay t - 43200) := by
  obtain ⟨n, hn⟩ := repr_iff.mp ht
  set E := fexp t with hE
  have hE1 : -36 ≤ E := fexp_ge_of_ge h16
  have hE2 : E ≤ 7 := by
    by_contra hc
    have := two_zpow_le_of_fexp (x := t) (by omega)
    rw [← hE] at this
    have := two_zpow_le' (K := K) (show (60 : ℤ) ≤ E + 52 by omega)
    have := zpow_lt_zpow_right₀ (one_lt_two (α := K)) (show (59 : ℤ) < 60 by norm_num)
    linarith
  set e := min E 6 with he
  set d := dayNumber t with hdd
  set M : ℤ := n * 2 ^ (E - e).toNat - 675 * (2 * d + 1) * 2 ^ (6 - e).toNat with hM
  have hval : timeOfDay t - 43200 = (M : K) * 2 ^ e := by
    unfold timeOfDay
    nth_rewrite 1 [hn]
    rw [hM]
    push_cast
    rw [sub_mul, mul_assoc, mul_assoc, ← zpow_natCast, ← zpow_natCast, ← zpow_add₀ two_ne_zero,
      ← zpow_add₀ two_ne_zero, Int.toNat_of_nonneg (by omega), Int.toNat_of_nonneg (by omega),
      show E - e + e = E by ring, show 6 - e + e = (6 : ℤ) by ring, ← hdd]
    norm_num; ring
  refine ⟨M, e, ?_, by omega, hval⟩
  -- `|M| · 2^e = |tod - 43200| ≤ 43200` and `2^e ≥ 2^-36`.
  obtain ⟨t1, t2⟩ := timeOfDay_bounds t
  have habs : |(M : K)| * 2 ^ e ≤ 43200 := by
    rw [← abs_of_pos (two_zpow_pos' (K := K) e), ← abs_mul, ← hval, abs_le]
    constructor <;> linarith
  have he36 : (2 : K) ^ (-36 : ℤ) ≤ 2 ^ e := two_zpow_le' (by omega)
  have : |(M : K)| * 2 ^ (-36 : ℤ) ≤ 43200 :=
    le_trans (mul_le_mul_of_nonneg_left he36 (abs_nonneg _)) habs
  have : |(M : K)| ≤ 43200 * 2 ^ (36 : ℤ) := by
    rw [show (2 : K) ^ (-36 : ℤ) = (2 ^ (36 : ℤ))⁻¹ by rw [zpow_neg]] at this
    rwa [← div_eq_mul_inv, div_le_iff₀ (two_zpow_pos' _)] at this
  have hc : ((|M| : ℤ) : K) < ((2 ^ 53 : ℤ) : K) := by
    push_cast
    have : (43200 : K) * 2 ^ (36 : ℤ) < 2 ^ 53 := by norm_num
    linarith
  exact_mod_cast hc

theorem fFvfJulianDay_err {t : K} (ht : Repr t) (hb : |t| ≤ 2 ^ (59 : ℤ)) :
    |fFvfJulianDay t - fvfJulianDay t| ≤ ulp (fvfJulianDay t) := by
  unfold fFvfJulianDay fadd
  apply abs_rn_sub_le_ulp
  have h60 : |t| < 2 ^ (60 : ℤ) := lt_of_le_of_lt hb (zpow_lt_zpow_right₀ one_lt_two (by norm_num))
  set J := fvfJulianDay t with hJ
  set dF := fDayNumber t with hdF
  set d := dayNumber t with hd
  set AF := fvfJdn (civilFromDays dF) with hAF
  set s := t - 86400 * (dF : K) with hs
  -- The binary64 day differs from the exact one only in the underflow band.
  have hcases : (dF = d) ∨ (d = -1 ∧ dF = 0 ∧ |t| < 1) := by
    by_cases hB : -(43200 * 2 ^ (-1074 : ℤ)) ≤ t ∧ t < 0
    · right
      have h1 := fDayNumber_band hB.1 hB.2
      have hd1 : d = -1 := by
        rw [hd]; unfold dayNumber; rw [Int.floor_eq_iff]; push_cast
        constructor
        · rw [le_div_iff₀ (by norm_num)]
          have : (43200 : K) * 2 ^ (-1074 : ℤ) ≤ 86400 := by
            have := zpow_lt_zpow_right₀ (one_lt_two (α := K)) (show (-1074 : ℤ) < 0 by norm_num)
            rw [zpow_zero] at this; linarith
          linarith [hB.1]
        · rw [div_lt_iff₀ (by norm_num)]; linarith [hB.2]
      refine ⟨hd1, by rw [hdF, h1, ← hd, hd1]; norm_num, ?_⟩
      rw [abs_lt]; constructor
      · have : (43200 : K) * 2 ^ (-1074 : ℤ) < 1 := by
          have : (2 : K) ^ (-1074 : ℤ) ≤ 2 ^ (-17 : ℤ) := two_zpow_le' (by norm_num)
          have : (43200 : K) * 2 ^ (-17 : ℤ) < 1 := by norm_num
          nlinarith [two_zpow_pos' (K := K) (-1074)]
        linarith [hB.1]
      · linarith [hB.2]
    · left; exact fDayNumber_eq ht h60 hB
  -- The JDN as a double is exact.
  have hAFsmall : |(AF : ℤ)| ≤ 2 ^ 53 := by
    have hn := fvfJdn_near (civilFromDays_valid dF)
    rw [daysFromCivil_civilFromDays] at hn
    have : |675 * dF| < 2 ^ 53 := by
      rcases hcases with h | ⟨-, h, -⟩
      · rw [h]; exact dayNumber_small hb
      · rw [h]; norm_num
    rw [abs_le] at hn ⊢; rw [abs_lt] at this
    constructor <;> omega
  rw [rn_of_repr (repr_intCast hAFsmall)]
  -- `J = AF + (s - 43200) / 86400` in both cases.
  have hJs : J = AF + (s - 43200) / 86400 := by
    rw [hJ]; unfold fvfJulianDay timeOfDay dateOf
    rcases hcases with h | ⟨h1, h2, -⟩
    · rw [hAF, hs, h]
    · rw [hAF, hs, ← hd, h1, h2, civil_zero_jdn, civil_neg_one_jdn]; push_cast; ring
  -- `86400 ⊗ dF` is exact, and `|s| < 2^17`.
  have hm : fmul (86400 : K) (dF : K) = 86400 * dF := by
    unfold fmul; apply rn_of_repr; apply repr_86400_mul
    rcases hcases with h | ⟨-, h, -⟩
    · rw [h]; exact dayNumber_small hb
    · rw [h]; norm_num
  have hsb : |s| < 2 ^ (17 : ℤ) := by
    rcases hcases with h | ⟨-, h, ht1⟩
    · rw [hs, h]
      obtain ⟨a, b⟩ := timeOfDay_bounds t
      unfold timeOfDay at a b
      rw [abs_lt]; constructor <;> norm_num <;> linarith
    · rw [hs, h]; simp only [Int.cast_zero, mul_zero, sub_zero]
      exact lt_trans ht1 (by norm_num)
  have htodF : fTimeOfDay t = rn s := by unfold fTimeOfDay fsub; rw [hm]
  rw [htodF]
  simp only [fsub]
  set todF := rn s with htod
  set w := todF - 43200 with hw
  set u := rn w with hu
  set z := u / 86400 with hz
  -- Branch on the size of `J`.
  by_cases hJ8 : 8 ≤ |J|
  · -- Crude bounds on each rounding.
    have e1 : |todF - s| ≤ 2 ^ (-37 : ℤ) := by
      have := abs_rn_sub_le s
      have := ulp_le hsb (by norm_num)
      have : (2 : K) ^ ((17 : ℤ) - 53) = 2 * 2 ^ (-37 : ℤ) := by norm_num
      linarith
    have htodb : |todF| ≤ 2 ^ (17 : ℤ) := by
      have hr : Repr ((2 : K) ^ (17 : ℤ)) := ⟨1, 17, by norm_num, by norm_num, by simp⟩
      rw [abs_lt] at hsb; rw [abs_le]; constructor
      · rw [← rn_of_repr (repr_neg hr)]; exact rn_mono (by linarith)
      · rw [← rn_of_repr hr, htod]; exact rn_mono hsb.2.le
    have hwb : |w| < 2 ^ (18 : ℤ) := by
      rw [hw]; rw [abs_le] at htodb; rw [abs_lt]
      have : (2 : K) ^ (18 : ℤ) = 2 ^ (17 : ℤ) + 131072 := by norm_num
      constructor <;> linarith [htodb.1, htodb.2]
    have e2 : |u - w| ≤ 2 ^ (-36 : ℤ) := by
      have := abs_rn_sub_le w
      have := ulp_le hwb (by norm_num)
      have : (2 : K) ^ ((18 : ℤ) - 53) = 2 * 2 ^ (-36 : ℤ) := by norm_num
      rw [hu]; linarith
    have hub : |u| ≤ 2 ^ (18 : ℤ) := by
      have hr : Repr ((2 : K) ^ (18 : ℤ)) := ⟨1, 18, by norm_num, by norm_num, by simp⟩
      rw [abs_lt] at hwb; rw [abs_le]; constructor
      · rw [← rn_of_repr (repr_neg hr)]; exact rn_mono (by linarith)
      · rw [← rn_of_repr hr, hu]; exact rn_mono hwb.2.le
    have hzb : |z| < 2 ^ (3 : ℤ) := by
      rw [hz, abs_div, abs_of_pos (by norm_num : (0 : K) < 86400), div_lt_iff₀ (by norm_num)]
      have : (2 : K) ^ (18 : ℤ) < 2 ^ (3 : ℤ) * 86400 := by norm_num
      linarith
    have e3 : |fdiv u 86400 - z| ≤ 2 ^ (-51 : ℤ) := by
      unfold fdiv
      have := abs_rn_sub_le z
      have := ulp_le hzb (by norm_num)
      have : (2 : K) ^ ((3 : ℤ) - 53) = 2 * 2 ^ (-51 : ℤ) := by norm_num
      rw [← hz]; linarith
    -- `ulp J ≥ 2^-49`.
    have hulpJ : (2 : K) ^ (-49 : ℤ) ≤ ulp J := by
      unfold ulp
      apply two_zpow_le'
      by_contra hc
      have := abs_lt_fexp J
      have := two_zpow_le' (K := K) (show fexp J + 53 ≤ 3 by omega)
      have : (2 : K) ^ (3 : ℤ) = 8 := by norm_num
      linarith
    have hsplit : (AF : K) + fdiv u 86400 - J =
        (fdiv u 86400 - z) + (u - w) / 86400 + (todF - s) / 86400 := by
      rw [hJs, hz, hw]; ring
    rw [hsplit]
    have h86 : (0 : K) < 86400 := by norm_num
    have k1 : |(u - w) / 86400| ≤ 2 ^ (-36 : ℤ) / 86400 := by
      rw [abs_div, abs_of_pos h86]; exact div_le_div_of_nonneg_right e2 h86.le
    have k2 : |(todF - s) / 86400| ≤ 2 ^ (-37 : ℤ) / 86400 := by
      rw [abs_div, abs_of_pos h86]; exact div_le_div_of_nonneg_right e1 h86.le
    have num : (2 : K) ^ (-51 : ℤ) + 2 ^ (-36 : ℤ) / 86400 + 2 ^ (-37 : ℤ) / 86400 ≤
        2 ^ (-49 : ℤ) / 2 := by norm_num
    calc |(fdiv u 86400 - z) + (u - w) / 86400 + (todF - s) / 86400|
        ≤ |fdiv u 86400 - z| + |(u - w) / 86400| + |(todF - s) / 86400| := abs_add_three _ _ _
      _ ≤ 2 ^ (-51 : ℤ) + 2 ^ (-36 : ℤ) / 86400 + 2 ^ (-37 : ℤ) / 86400 := by gcongr
      _ ≤ 2 ^ (-49 : ℤ) / 2 := num
      _ ≤ ulp J / 2 := by gcongr
  · -- `|J| < 8`: then `|t| ≥ 86400`, the remainder and `tod - 43200` are exact.
    have hJ8' : |J| < 8 := lt_of_not_ge hJ8
    have ht86 : 86400 ≤ |t| := by
      by_contra hc
      have hc' := lt_of_not_ge hc
      have hdd : d = -1 ∨ d = 0 := by
        obtain ⟨b1, b2⟩ := dayNumber_bounds t
        rw [← hd] at b1 b2
        rw [abs_lt] at hc'
        have : (-2 : K) < d := by nlinarith
        have : (d : K) < 1 := by nlinarith
        have : -2 < d := by exact_mod_cast ‹(-2 : K) < d›
        have : d < 1 := by exact_mod_cast ‹(d : K) < 1›
        omega
      obtain ⟨a, b⟩ := timeOfDay_bounds t
      have hJv : J = fvfJdn (civilFromDays d) + (timeOfDay t - 43200) / 86400 := by
        rw [hJ]; rfl
      rw [abs_lt] at hJ8'
      rcases hdd with h | h <;> rw [h] at hJv
      · rw [civil_neg_one_jdn] at hJv; push_cast at hJv
        have : (-43200 : K) / 86400 ≤ (timeOfDay t - 43200) / 86400 :=
          div_le_div_of_nonneg_right (by linarith) (by norm_num)
        norm_num at this; linarith
      · rw [civil_zero_jdn] at hJv; push_cast at hJv
        have : (-43200 : K) / 86400 ≤ (timeOfDay t - 43200) / 86400 :=
          div_le_div_of_nonneg_right (by linarith) (by norm_num)
        norm_num at this; linarith
    have hnotneg : ¬ (-43200 < t ∧ t < 0) := by
      rintro ⟨h1, h2⟩; rw [abs_of_neg h2] at ht86; linarith
    have hdeq : dF = d := by
      rcases hcases with h | ⟨-, -, h⟩
      · exact h
      · exfalso; linarith
    have htodeq : todF = timeOfDay t := by
      have h := fTimeOfDay_eq ht hb hnotneg; rw [htodF] at h; exact h
    have h16 : (2 : K) ^ (16 : ℤ) ≤ |t| := le_trans (by norm_num) ht86
    have hueq : u = timeOfDay t - 43200 := by
      rw [hu, hw, htodeq]; exact rn_of_repr (repr_tod_sub ht h16 hb)
    have hJz : J = AF + z := by
      rw [hJs, hz, hueq]; unfold timeOfDay; rw [hs, hdeq]
    rw [hJz, show (AF : K) + fdiv u 86400 - (AF + z) = rn z - z by unfold fdiv; rw [← hz]; ring]
    have hz1 : |z| ≤ 1 / 2 := by
      obtain ⟨a, b⟩ := timeOfDay_bounds t
      rw [hz, hueq, abs_le]; constructor
      · rw [le_div_iff₀ (by norm_num)]; linarith
      · rw [div_le_iff₀ (by norm_num)]; linarith
    have hulp : ulp z ≤ ulp ((AF : K) + z) := by
      by_cases hA : AF = 0
      · rw [hA]; simp
      · apply ulp_mono
        have : (1 : K) ≤ |(AF : K)| := by
          have : 1 ≤ |AF| := Int.one_le_abs hA
          exact_mod_cast this
        have := abs_sub_abs_le_abs_sub (AF : K) (-z)
        rw [abs_neg, sub_neg_eq_add] at this
        linarith
    have := abs_rn_sub_le z
    linarith


/-! ## julian_day as §9.2 pins it (ruling Q-99) -/

/-- `tod - 43200 = (s - 43200) + (t - ⌊t⌋)`: the split the binary64 formula
is evaluated from. -/
theorem timeOfDay_sub_eq (t : K) :
    timeOfDay t - 43200 = ((secondOfDay t - 43200 : ℤ) : K) + (t - ⌊t⌋) := by
  rw [secondOfDay_eq]; unfold timeOfDay; push_cast; ring

/-- `t - ⌊t⌋` is a double when `t` is a double with `2^16 ≤ |t|`. -/
theorem repr_frac {t : K} (ht : Repr t) (h16 : 2 ^ (16 : ℤ) ≤ |t|) :
    F64.Repr (t - ⌊t⌋) := by
  obtain ⟨n, hn⟩ := repr_iff.mp ht
  set E := fexp t with hE
  have hE1 : -36 ≤ E := fexp_ge_of_ge h16
  set e := min E 0 with he
  set M : ℤ := n * 2 ^ (E - e).toNat - ⌊t⌋ * 2 ^ (-e).toNat with hM
  have hval : t - ⌊t⌋ = (M : K) * 2 ^ e := by
    nth_rewrite 1 [hn]
    rw [hM]
    push_cast
    rw [sub_mul, mul_assoc, mul_assoc, ← zpow_natCast, ← zpow_natCast, ← zpow_add₀ two_ne_zero,
      ← zpow_add₀ two_ne_zero, Int.toNat_of_nonneg (by omega), Int.toNat_of_nonneg (by omega),
      show E - e + e = E by ring, show -e + e = (0 : ℤ) by ring, zpow_zero, mul_one]
  refine ⟨M, e, ?_, by omega, hval⟩
  have hf0 : 0 ≤ t - ⌊t⌋ := by have := Int.floor_le t; linarith
  have hf1 : t - ⌊t⌋ < 1 := by have := Int.lt_floor_add_one t; linarith
  have habs : |(M : K)| * 2 ^ e < 1 := by
    rw [← abs_of_pos (two_zpow_pos' (K := K) e), ← abs_mul, ← hval, abs_of_nonneg hf0]
    exact hf1
  have he36 : (2 : K) ^ (-36 : ℤ) ≤ 2 ^ e := two_zpow_le' (by omega)
  have : |(M : K)| * 2 ^ (-36 : ℤ) < 1 :=
    lt_of_le_of_lt (mul_le_mul_of_nonneg_left he36 (abs_nonneg _)) habs
  have : |(M : K)| < 2 ^ (36 : ℤ) := by
    rw [show (2 : K) ^ (-36 : ℤ) = (2 ^ (36 : ℤ))⁻¹ by rw [zpow_neg]] at this
    rwa [← div_eq_mul_inv, div_lt_iff₀ (two_zpow_pos' _), one_mul] at this
  have hc : ((|M| : ℤ) : K) < ((2 ^ 53 : ℤ) : K) := by
    push_cast
    have : (2 : K) ^ (36 : ℤ) < 2 ^ 53 := by norm_num
    linarith
  exact_mod_cast hc

/-- The binary64 julian_day §9.2 pins is within one ulp of the exact Julian
Date, for every double `|t| ≤ 2^59`. -/
theorem fJulianDay_err {t : K} (ht : Repr t) (hb : |t| ≤ 2 ^ (59 : ℤ)) :
    |fJulianDay t - julianDay t| ≤ ulp (julianDay t) := by
  unfold fJulianDay fadd
  apply abs_rn_sub_le_ulp
  set J := julianDay t with hJ
  set d := dayNumber t with hd
  set S : ℤ := secondOfDay t - 43200 with hS
  set f : K := t - ⌊t⌋ with hf
  -- The two integers convert to doubles exactly.
  have hdsmall := dayNumber_small hb
  rw [← hd] at hdsmall
  have hD : rn (((d + 2440588 : ℤ)) : K) = ((d + 2440588 : ℤ) : K) := by
    apply rn_of_repr; apply repr_intCast
    rw [abs_lt] at hdsmall; rw [abs_le]; constructor <;> omega
  have hSb : |S| ≤ 43200 := by
    have := secondOfDay_bounds t; rw [hS, abs_le]; constructor <;> omega
  have hSr : rn ((S : ℤ) : K) = S := by
    apply rn_of_repr; apply repr_intCast
    rw [abs_le] at hSb ⊢; constructor <;> omega
  rw [hD, hSr]
  have hJs : J = ((d + 2440588 : ℤ) : K) + ((S : K) + f) / 86400 := by
    rw [hJ, hS, hf]; unfold julianDay; rw [timeOfDay_sub_eq]
  have hf0 : 0 ≤ f := by have := Int.floor_le t; rw [hf]; linarith
  have hf1 : f < 1 := by have := Int.lt_floor_add_one t; rw [hf]; linarith
  have hSK : |(S : K)| ≤ 43200 := by exact_mod_cast hSb
  simp only [fsub, fdiv]
  set fF := rn f with hfF
  set w := (S : K) + fF with hw
  set u := rn w with hu
  set z := u / 86400 with hz
  by_cases hJ8 : 8 ≤ |J|
  · -- Crude bounds on each rounding.
    have hfb : |f| < 2 ^ (0 : ℤ) := by rw [abs_of_nonneg hf0]; simpa using hf1
    have e1 : |fF - f| ≤ 2 ^ (-54 : ℤ) := by
      have := abs_rn_sub_le f
      have := ulp_le hfb (by norm_num)
      have : (2 : K) ^ ((0 : ℤ) - 53) = 2 * 2 ^ (-54 : ℤ) := by norm_num
      rw [hfF]; linarith
    have hfFb : |fF| ≤ 1 := by
      have hr : Repr (1 : K) := ⟨1, 0, by norm_num, by norm_num, by simp⟩
      rw [abs_le]; constructor
      · have : (0 : K) ≤ fF := by rw [hfF]; exact rn_nonneg hf0
        linarith
      · rw [← rn_of_repr hr, hfF]; exact rn_mono hf1.le
    have hwb : |w| < 2 ^ (16 : ℤ) := by
      rw [hw]; rw [abs_le] at hfFb hSK; rw [abs_lt]
      have : (2 : K) ^ (16 : ℤ) = 65536 := by norm_num
      constructor <;> linarith [hfFb.1, hfFb.2, hSK.1, hSK.2]
    have e2 : |u - w| ≤ 2 ^ (-38 : ℤ) := by
      have := abs_rn_sub_le w
      have := ulp_le hwb (by norm_num)
      have : (2 : K) ^ ((16 : ℤ) - 53) = 2 * 2 ^ (-38 : ℤ) := by norm_num
      rw [hu]; linarith
    have hub : |u| ≤ 2 ^ (16 : ℤ) := by
      have hr : Repr ((2 : K) ^ (16 : ℤ)) := ⟨1, 16, by norm_num, by norm_num, by simp⟩
      rw [abs_lt] at hwb; rw [abs_le]; constructor
      · rw [← rn_of_repr (repr_neg hr)]; exact rn_mono (by linarith)
      · rw [← rn_of_repr hr, hu]; exact rn_mono hwb.2.le
    have hzb : |z| < 2 ^ (0 : ℤ) := by
      rw [hz, abs_div, abs_of_pos (by norm_num : (0 : K) < 86400), div_lt_iff₀ (by norm_num)]
      have : (2 : K) ^ (16 : ℤ) < 2 ^ (0 : ℤ) * 86400 := by norm_num
      linarith
    have e3 : |rn z - z| ≤ 2 ^ (-54 : ℤ) := by
      have := abs_rn_sub_le z
      have := ulp_le hzb (by norm_num)
      have : (2 : K) ^ ((0 : ℤ) - 53) = 2 * 2 ^ (-54 : ℤ) := by norm_num
      linarith
    -- `ulp J ≥ 2^-49`.
    have hulpJ : (2 : K) ^ (-49 : ℤ) ≤ ulp J := by
      unfold ulp
      apply two_zpow_le'
      by_contra hc
      have := abs_lt_fexp J
      have := two_zpow_le' (K := K) (show fexp J + 53 ≤ 3 by omega)
      have : (2 : K) ^ (3 : ℤ) = 8 := by norm_num
      linarith
    have hsplit : ((d + 2440588 : ℤ) : K) + rn z - J =
        (rn z - z) + (u - w) / 86400 + (fF - f) / 86400 := by
      rw [hJs, hz, hw]; ring
    rw [hsplit]
    have h86 : (0 : K) < 86400 := by norm_num
    have k1 : |(u - w) / 86400| ≤ 2 ^ (-38 : ℤ) / 86400 := by
      rw [abs_div, abs_of_pos h86]; exact div_le_div_of_nonneg_right e2 h86.le
    have k2 : |(fF - f) / 86400| ≤ 2 ^ (-54 : ℤ) / 86400 := by
      rw [abs_div, abs_of_pos h86]; exact div_le_div_of_nonneg_right e1 h86.le
    have num : (2 : K) ^ (-54 : ℤ) + 2 ^ (-38 : ℤ) / 86400 + 2 ^ (-54 : ℤ) / 86400 ≤
        2 ^ (-49 : ℤ) / 2 := by norm_num
    calc |(rn z - z) + (u - w) / 86400 + (fF - f) / 86400|
        ≤ |rn z - z| + |(u - w) / 86400| + |(fF - f) / 86400| := abs_add_three _ _ _
      _ ≤ 2 ^ (-54 : ℤ) + 2 ^ (-38 : ℤ) / 86400 + 2 ^ (-54 : ℤ) / 86400 := by gcongr
      _ ≤ 2 ^ (-49 : ℤ) / 2 := num
      _ ≤ ulp J / 2 := by gcongr
  · -- `|J| < 8`: then `t < -2^16`, and `t - ⌊t⌋` and `(s - 43200) + (t - ⌊t⌋)`
    -- are exact.
    have hJ8' : |J| < 8 := lt_of_not_ge hJ8
    have hJv : J = t / 86400 + 2440587.5 := by
      rw [hJ]; unfold julianDay timeOfDay; push_cast; ring
    have h16 : (2 : K) ^ (16 : ℤ) ≤ |t| := by
      rw [abs_lt, hJv] at hJ8'
      have : t < -(2 ^ (16 : ℤ)) := by
        have : (2 : K) ^ (16 : ℤ) = 65536 := by norm_num
        rw [this]
        have := hJ8'.2
        have h' : t / 86400 < -2440579.5 := by linarith
        rw [div_lt_iff₀ (by norm_num)] at h'
        linarith
      rw [abs_of_neg (by have := two_zpow_pos' (K := K) 16; linarith)]
      linarith
    have hfeq : fF = f := by rw [hfF]; exact rn_of_repr (repr_frac ht h16)
    have hweq : u = (S : K) + f := by
      rw [hu, hw, hfeq]
      apply rn_of_repr
      rw [hS, hf, ← timeOfDay_sub_eq]
      exact repr_tod_sub ht h16 hb
    have hJz : J = ((d + 2440588 : ℤ) : K) + z := by rw [hJs, hz, hweq]
    rw [hJz, show ((d + 2440588 : ℤ) : K) + rn z - (((d + 2440588 : ℤ) : K) + z) = rn z - z by ring]
    have hz1 : |z| ≤ 1 / 2 := by
      have hw' : (S : K) + f = timeOfDay t - 43200 := by rw [hS, hf, timeOfDay_sub_eq]
      obtain ⟨a, b⟩ := timeOfDay_bounds t
      rw [hz, hweq, hw', abs_le]; constructor
      · rw [le_div_iff₀ (by norm_num)]; linarith
      · rw [div_le_iff₀ (by norm_num)]; linarith
    have hulp : ulp z ≤ ulp (((d + 2440588 : ℤ) : K) + z) := by
      by_cases hA : d + 2440588 = 0
      · rw [hA]; simp
      · apply ulp_mono
        have : (1 : K) ≤ |((d + 2440588 : ℤ) : K)| := by
          have : 1 ≤ |d + 2440588| := Int.one_le_abs hA
          exact_mod_cast this
        have := abs_sub_abs_le_abs_sub (((d + 2440588 : ℤ) : K)) (-z)
        rw [abs_neg, sub_neg_eq_add] at this
        linarith
    have := abs_rn_sub_le z
    linarith

end Esm.Closed.Datetime
