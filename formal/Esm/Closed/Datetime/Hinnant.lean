import Esm.Closed.Datetime.CalendarFacts

/-!
# Howard Hinnant's `civil_from_days` is `civilFromDays`

`lib/calendar.esm` computes the date of a day number with Hinnant's
era-of-400-years algorithm (eras of 146097 days, the year starting on March 1,
every integer division a floor). `hinnant` below is that algorithm over ℤ,
step for step; `hinnant_eq` proves it equals `Calendar.lean`'s
`civilFromDays` for every day number, so the template theorems can work with
Hinnant's steps while the result is the model's calendar.

The proof: `yoeOf` (Hinnant's year of the era) is the year whose March-based
start is at or before the day of the era and whose successor's is after
(`yoeOf_spec`, by cases on the year: 400 `omega` calls); from that the date is
valid and `daysFromCivil` takes it back to the day number, and
`civilFromDays_daysFromCivil` closes.
-/

namespace Esm.Closed.Datetime

/-- Days from March 1 of year 0 of an era to March 1 of year `y` of it, as
`lib/calendar.esm` writes it (no 400-year term: `y ≤ 399` there). -/
def eraStart (y : ℤ) : ℤ := 365 * y + y / 4 - y / 100

/-- The same count with the 400-year term, so that `fullStart 400 = 146097`
closes the era. Equal to `eraStart` on `[0, 399]`. -/
def fullStart (y : ℤ) : ℤ := 365 * y + y / 4 - y / 100 + y / 400

theorem eraStart_eq_full {y : ℤ} (h0 : 0 ≤ y) (h1 : y ≤ 399) : eraStart y = fullStart y := by
  unfold eraStart fullStart; omega

/-- Hinnant's year of the era of the day of the era `doe`. -/
def yoeOf (doe : ℤ) : ℤ := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365

set_option maxHeartbeats 8000000 in
/-- `yoeOf` inverts `fullStart` on each year of the era. -/
theorem yoeOf_fullStart (y doy : ℤ) (hy0 : 0 ≤ y) (hy1 : y ≤ 399) (hd0 : 0 ≤ doy)
    (hd1 : fullStart y + doy < fullStart (y + 1)) : yoeOf (fullStart y + doy) = y := by
  unfold yoeOf
  unfold fullStart at hd1 ⊢
  interval_cases y <;> omega

theorem fullStart_cover (k : ℕ) (hk : k ≤ 400) (doe : ℤ) (h0 : 0 ≤ doe)
    (h1 : doe < fullStart k) :
    ∃ y : ℤ, 0 ≤ y ∧ y < k ∧ fullStart y ≤ doe ∧ doe < fullStart (y + 1) := by
  induction k with
  | zero =>
    exfalso
    have : fullStart ((0 : ℕ) : ℤ) = 0 := by decide
    omega
  | succ k ih =>
    by_cases h : doe < fullStart k
    · obtain ⟨y, a, b, c, d⟩ := ih (by omega) h
      exact ⟨y, a, by omega, c, d⟩
    · exact ⟨k, by omega, by omega, by omega, by push_cast at h1; exact h1⟩

/-- Hinnant's year of the era is the March-based year containing `doe`. -/
theorem yoeOf_spec (doe : ℤ) (h0 : 0 ≤ doe) (h1 : doe < 146097) :
    0 ≤ yoeOf doe ∧ yoeOf doe ≤ 399 ∧ eraStart (yoeOf doe) ≤ doe ∧
      doe < fullStart (yoeOf doe + 1) := by
  obtain ⟨y, a, b, c, d⟩ := fullStart_cover 400 le_rfl doe h0
    (by have : fullStart ((400 : ℕ) : ℤ) = 146097 := by decide
        omega)
  have := yoeOf_fullStart y (doe - fullStart y) a (by omega) (by omega) (by omega)
  rw [show fullStart y + (doe - fullStart y) = doe by ring] at this
  rw [this, eraStart_eq_full a (by omega)]; exact ⟨a, by omega, c, d⟩

/-- Howard Hinnant's `civil_from_days` (day number since 1970-01-01), in the
order `lib/calendar.esm` writes it. -/
def hinnant (n : ℤ) : Date :=
  let z := n + 719468
  let era := z / 146097
  let doe := z - 146097 * era
  let yoe := yoeOf doe
  let doy := doe - eraStart yoe
  let mp := (5 * doy + 2) / 153
  ⟨yoe + 400 * era + (if 306 ≤ doy then 1 else 0), mp + (if mp < 10 then 3 else -9),
    doy - (153 * mp + 2) / 5 + 1⟩

theorem isLeapYear_eq_decide (y : ℤ) :
    isLeapYear y = decide ((4 ∣ y ∧ ¬ 100 ∣ y) ∨ 400 ∣ y) := by
  rw [Bool.eq_iff_iff, isLeapYear_iff]; simp

/-! The calendar counts against the era counts. -/

theorem daysBeforeYear_add_400 (y k : ℤ) :
    daysBeforeYear (y + 400 * k) = daysBeforeYear y + 146097 * k := by
  unfold daysBeforeYear; omega

theorem isLeapYear_add_400 (y k : ℤ) : isLeapYear (y + 400 * k) = isLeapYear y := by
  rw [isLeapYear_eq_decide, isLeapYear_eq_decide]
  simp only [decide_eq_decide]
  omega

/-- January 1 of year `y` plus January, February and the leap day is March 1:
`fullStart y + 60` days after 0000-01-01. -/
theorem daysBeforeYear_march (y : ℤ) :
    daysBeforeYear y + 59 + (if isLeapYear y then 1 else 0) = fullStart y + 60 := by
  rw [isLeapYear_eq_decide]
  unfold daysBeforeYear fullStart
  simp only [decide_eq_true_eq]
  split_ifs <;> omega

/-- January 1 of year `y + 1` is 306 days after March 1 of year `y`. -/
theorem daysBeforeYear_succ_march (y : ℤ) : daysBeforeYear (y + 1) = fullStart y + 366 := by
  unfold daysBeforeYear fullStart; omega

/-- The March-based year `y` has a leap day exactly when the civil year `y + 1`
is a leap year. -/
theorem fullStart_succ_sub (y : ℤ) :
    fullStart (y + 1) - fullStart y = 365 + (if isLeapYear (y + 1) then 1 else 0) := by
  rw [isLeapYear_eq_decide]
  unfold fullStart
  simp only [decide_eq_true_eq]
  split_ifs <;> omega

set_option maxHeartbeats 4000000 in
/-- The date Hinnant's steps produce from a day of the era and its year of
the era is valid, and `daysFromCivil` takes it back to the day number. -/
theorem hinnant_step (n era doe yoe doy mp : ℤ) (ys : fullStart yoe ≤ doe) (ye : doe < fullStart (yoe + 1))
    (hdoe : n + 719468 = doe + 146097 * era) (hdoy : doe - fullStart yoe = doy)
    (hmp : (5 * doy + 2) / 153 = mp) (hmp0 : 0 ≤ mp) (hmp1 : mp ≤ 11) :
    (Date.Valid ⟨yoe + 400 * era + (if 306 ≤ doy then 1 else 0),
      mp + (if mp < 10 then 3 else -9), doy - (153 * mp + 2) / 5 + 1⟩) ∧
    daysFromCivil ⟨yoe + 400 * era + (if 306 ≤ doy then 1 else 0),
      mp + (if mp < 10 then 3 else -9), doy - (153 * mp + 2) / 5 + 1⟩ = n := by
  have hj : (if 306 ≤ doy then (1 : ℤ) else 0) = if mp < 10 then 0 else 1 := by
    split_ifs <;> omega
  have hy : yoe + 400 * era + (if 306 ≤ doy then 1 else 0) =
      (yoe + if mp < 10 then 0 else 1) + 400 * era := by rw [hj]; ring
  have a2 := fullStart_succ_sub yoe
  simp only [Date.Valid, daysFromCivil, hy, daysBeforeYear_add_400, isLeapYear_add_400,
    epochOffset]
  by_cases hm : mp < 10
  · have a0 := daysBeforeYear_march yoe
    simp only [hm, ↓reduceIte, add_zero]
    generalize isLeapYear yoe = L at a0 ⊢
    generalize daysBeforeYear yoe = B at a0 ⊢
    generalize fullStart yoe = E0 at a0 a2 ys hdoy ⊢
    generalize fullStart (yoe + 1) = E1 at a2 ye ⊢
    have : mp ≤ 9 := by omega
    interval_cases mp <;> cases L <;>
      simp only [daysBeforeMonth, monthLength, Bool.false_eq_true, ↓reduceIte] at a0 a2 ⊢ <;>
      split_ifs <;> omega
  · have a1 := daysBeforeYear_succ_march yoe
    simp only [hm, ↓reduceIte]
    generalize isLeapYear (yoe + 1) = L at a2 ⊢
    generalize daysBeforeYear (yoe + 1) = B at a1 ⊢
    generalize fullStart yoe = E0 at a1 a2 ys hdoy ⊢
    generalize fullStart (yoe + 1) = E1 at a2 ye ⊢
    have : 10 ≤ mp := by omega
    interval_cases mp <;> cases L <;>
      simp only [daysBeforeMonth, monthLength, Bool.false_eq_true, ↓reduceIte] at a2 ⊢ <;>
      split_ifs <;> omega

theorem hinnant_valid_days (n : ℤ) :
    (hinnant n).Valid ∧ daysFromCivil (hinnant n) = n := by
  have hz0 : 0 ≤ (n + 719468) - 146097 * ((n + 719468) / 146097) := by omega
  have hz1 : (n + 719468) - 146097 * ((n + 719468) / 146097) < 146097 := by omega
  have hs := yoeOf_spec _ hz0 hz1
  generalize hD : (n + 719468) - 146097 * ((n + 719468) / 146097) = D at hs hz0 hz1
  generalize hY : yoeOf D = Y at hs
  obtain ⟨y0, y1, ys, ye⟩ := hs
  rw [eraStart_eq_full y0 y1] at ys
  have hmp0 : 0 ≤ (5 * (D - fullStart Y) + 2) / 153 := by omega
  have hmp1 : (5 * (D - fullStart Y) + 2) / 153 ≤ 11 := by
    have := fullStart_succ_sub Y
    split_ifs at this <;> omega
  have := hinnant_step n ((n + 719468) / 146097) D Y _ _ ys ye (by omega) rfl rfl hmp0 hmp1
  unfold hinnant
  simp only [hD, hY, eraStart_eq_full y0 y1]
  exact this

/-- Hinnant's algorithm is the model's calendar, for every day number. -/
theorem hinnant_eq (n : ℤ) : hinnant n = civilFromDays n := by
  obtain ⟨hv, hd⟩ := hinnant_valid_days n
  rw [← civilFromDays_daysFromCivil hv, hd]

end Esm.Closed.Datetime
