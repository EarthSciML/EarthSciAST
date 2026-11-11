import Esm.Closed.Datetime.Calendar

/-!
# Facts about the integer calendar

These pin `Calendar.lean`'s formulas to the calendar rules: the year and month
lengths they imply, the inverse pair `civilFromDays`/`daysFromCivil`, ranges,
and lexicographic monotonicity.
-/

namespace Esm.Closed.Datetime

/-! ## Year and month lengths -/

theorem isLeapYear_iff (y : ℤ) :
    isLeapYear y = true ↔ (4 ∣ y ∧ ¬ 100 ∣ y) ∨ 400 ∣ y := by
  simp only [isLeapYear, Int.dvd_iff_emod_eq_zero]
  simp

theorem daysBeforeYear_zero : daysBeforeYear 0 = 0 := by decide

theorem daysBeforeYear_succ (y : ℤ) :
    daysBeforeYear (y + 1) = daysBeforeYear y + yearLength y := by
  unfold daysBeforeYear yearLength isLeapYear
  split_ifs with h <;> simp at h <;> omega

theorem daysBeforeYear_epoch : daysBeforeYear 1970 = epochOffset := by decide

theorem daysBeforeYear_bounds (y : ℤ) :
    146097 * y - 396 ≤ 400 * daysBeforeYear y ∧ 400 * daysBeforeYear y ≤ 146097 * y + 699 := by
  unfold daysBeforeYear; omega

theorem daysBeforeYear_strictMono {a b : ℤ} (h : a < b) : daysBeforeYear a < daysBeforeYear b := by
  unfold daysBeforeYear; omega

theorem daysBeforeYear_succ_le {a b : ℤ} (h : a < b) :
    daysBeforeYear (a + 1) ≤ daysBeforeYear b := by
  rcases (show a + 1 = b ∨ a + 1 < b by omega) with h' | h'
  · rw [h']
  · exact le_of_lt (daysBeforeYear_strictMono h')

theorem yearLength_eq (y : ℤ) : yearLength y = if isLeapYear y then 366 else 365 := rfl

theorem daysBeforeMonth_one (l : Bool) : daysBeforeMonth l 1 = 0 := by
  simp [daysBeforeMonth]

/-- The leap day as an integer. -/
theorem leapInt_bounds (l : Bool) : 0 ≤ (if l then (1 : ℤ) else 0) ∧ (if l then (1 : ℤ) else 0) ≤ 1 := by
  cases l <;> simp

/-- Each month's length is the gap between consecutive `daysBeforeMonth` values
(with `daysBeforeMonth l 13` the length of the year). -/
theorem monthLength_eq_sub (l : Bool) (m : ℤ) (h1 : 1 ≤ m) (h2 : m ≤ 12) :
    monthLength l m = daysBeforeMonth l (m + 1) - daysBeforeMonth l m := by
  have : m = 1 ∨ m = 2 ∨ m = 3 ∨ m = 4 ∨ m = 5 ∨ m = 6 ∨ m = 7 ∨ m = 8 ∨ m = 9 ∨ m = 10 ∨
      m = 11 ∨ m = 12 := by omega
  rcases this with h|h|h|h|h|h|h|h|h|h|h|h <;> subst h <;> cases l <;> decide

theorem daysBeforeMonth_succ (l : Bool) (m : ℤ) (h1 : 1 ≤ m) (h2 : m ≤ 11) :
    daysBeforeMonth l (m + 1) = daysBeforeMonth l m + monthLength l m := by
  rw [monthLength_eq_sub l m h1 (by omega)]; ring

theorem daysBeforeMonth_thirteen (y : ℤ) : daysBeforeMonth (isLeapYear y) 13 = yearLength y := by
  unfold yearLength; cases isLeapYear y <;> decide

/-- The twelve months fill the year exactly. -/
theorem daysBeforeMonth_twelve_add (y : ℤ) :
    daysBeforeMonth (isLeapYear y) 12 + monthLength (isLeapYear y) 12 = yearLength y := by
  rw [monthLength_eq_sub _ 12 (by norm_num) le_rfl, ← daysBeforeMonth_thirteen y]; ring

theorem monthLength_bounds (l : Bool) (m : ℤ) : 28 ≤ monthLength l m ∧ monthLength l m ≤ 31 := by
  unfold monthLength; split_ifs <;> cases l <;> simp_all

/-- `daysBeforeMonth` is monotone. -/
theorem daysBeforeMonth_mono (l : Bool) {m m' : ℤ} (h2 : m ≤ m') :
    daysBeforeMonth l m ≤ daysBeforeMonth l m' := by
  have := leapInt_bounds l
  unfold daysBeforeMonth; split_ifs <;> omega

/-- A month ends no later than any later month starts. -/
theorem daysBeforeMonth_add_le (l : Bool) {m m' : ℤ} (h1 : 1 ≤ m) (h2 : m < m') (h3 : m' ≤ 12) :
    daysBeforeMonth l m + monthLength l m ≤ daysBeforeMonth l m' := by
  rw [monthLength_eq_sub l m h1 (by omega)]
  have := daysBeforeMonth_mono l (show m + 1 ≤ m' by omega)
  omega

theorem daysBeforeMonth_add_le_year (y m : ℤ) (h1 : 1 ≤ m) (h3 : m ≤ 12) :
    daysBeforeMonth (isLeapYear y) m + monthLength (isLeapYear y) m ≤ yearLength y := by
  rw [monthLength_eq_sub _ m h1 h3, ← daysBeforeMonth_thirteen y]
  have := daysBeforeMonth_mono (isLeapYear y) (show m + 1 ≤ 13 by omega)
  omega

theorem daysBeforeMonth_nonneg (l : Bool) (m : ℤ) : 0 ≤ daysBeforeMonth l m := by
  have := leapInt_bounds l
  unfold daysBeforeMonth; split_ifs <;> omega

/-! ## `yearOfDays` and `monthOfDoy` -/

theorem yearOfDays_spec (n : ℤ) :
    daysBeforeYear (yearOfDays n) ≤ n + epochOffset ∧
      n + epochOffset < daysBeforeYear (yearOfDays n + 1) := by
  unfold yearOfDays
  simp only
  generalize hz : n + epochOffset = z
  generalize hq : (400 * z + 396) / 146097 = q
  have hq1 : 146097 * q ≤ 400 * z + 396 := by omega
  have hq2 : 400 * z + 396 < 146097 * (q + 1) := by omega
  have b0 := daysBeforeYear_bounds (q - 1)
  have b2 := daysBeforeYear_bounds (q + 1)
  split_ifs with h
  · exact ⟨h, by omega⟩
  · refine ⟨by omega, ?_⟩
    rw [show q - 1 + 1 = q by ring]; omega

/-- The year bracket determines the year. -/
theorem yearOfDays_eq {n y : ℤ} (h1 : daysBeforeYear y ≤ n + epochOffset)
    (h2 : n + epochOffset < daysBeforeYear (y + 1)) : yearOfDays n = y := by
  obtain ⟨s1, s2⟩ := yearOfDays_spec n
  rcases lt_trichotomy (yearOfDays n) y with h | h | h
  · have := daysBeforeYear_succ_le h; omega
  · exact h
  · have := daysBeforeYear_succ_le h; omega

theorem doy0OfDays_bounds (n : ℤ) :
    0 ≤ doy0OfDays n ∧ doy0OfDays n < yearLength (yearOfDays n) := by
  have := yearOfDays_spec n
  have := daysBeforeYear_succ (yearOfDays n)
  unfold doy0OfDays; omega

theorem monthOfDoy_spec (l : Bool) (doy0 : ℤ) (h0 : 0 ≤ doy0)
    (h1 : doy0 < daysBeforeMonth l 13) :
    1 ≤ monthOfDoy l doy0 ∧ monthOfDoy l doy0 ≤ 12 ∧
      daysBeforeMonth l (monthOfDoy l doy0) ≤ doy0 ∧
      doy0 < daysBeforeMonth l (monthOfDoy l doy0 + 1) := by
  have := leapInt_bounds l
  generalize hL : (if l then (1 : ℤ) else 0) = L at *
  unfold daysBeforeMonth at h1 ⊢
  unfold monthOfDoy
  simp only [hL] at h1 ⊢
  split_ifs <;> omega

theorem monthOfDoy_eq (l : Bool) {doy0 m : ℤ} (hm1 : 1 ≤ m) (hm2 : m ≤ 12)
    (h1 : daysBeforeMonth l m ≤ doy0) (h2 : doy0 < daysBeforeMonth l (m + 1)) :
    monthOfDoy l doy0 = m := by
  have := leapInt_bounds l
  generalize hL : (if l then (1 : ℤ) else 0) = L at *
  unfold daysBeforeMonth at h1 h2
  unfold monthOfDoy
  simp only [hL] at h1 h2 ⊢
  split_ifs at h1 h2 ⊢ <;> omega

/-! ## The inverse pair -/

theorem civilFromDays_valid (n : ℤ) : (civilFromDays n).Valid := by
  have hd := doy0OfDays_bounds n
  have hy := daysBeforeMonth_thirteen (yearOfDays n)
  have hm := monthOfDoy_spec (isLeapYear (yearOfDays n)) (doy0OfDays n) hd.1 (by omega)
  have hml := monthLength_eq_sub (isLeapYear (yearOfDays n))
    (monthOfDoy (isLeapYear (yearOfDays n)) (doy0OfDays n)) hm.1 hm.2.1
  unfold civilFromDays Date.Valid
  simp only
  omega

theorem daysFromCivil_civilFromDays (n : ℤ) : daysFromCivil (civilFromDays n) = n := by
  unfold daysFromCivil civilFromDays doy0OfDays
  simp only
  ring

/-- Bounds on the day count within its year, for a valid date. -/
theorem valid_doy_bounds {c : Date} (hc : c.Valid) :
    0 ≤ daysBeforeMonth (isLeapYear c.year) c.month + (c.day - 1) ∧
      daysBeforeMonth (isLeapYear c.year) c.month + (c.day - 1) < yearLength c.year := by
  obtain ⟨h1, h2, h3, h4⟩ := hc
  have := daysBeforeMonth_add_le_year c.year c.month h1 h2
  have := daysBeforeMonth_nonneg (isLeapYear c.year) c.month
  omega

theorem civilFromDays_daysFromCivil {c : Date} (hc : c.Valid) :
    civilFromDays (daysFromCivil c) = c := by
  obtain ⟨b1, b2⟩ := valid_doy_bounds hc
  obtain ⟨y, m, d⟩ := c
  obtain ⟨h1, h2, h3, h4⟩ := hc
  simp only at b1 b2 h1 h2 h3 h4
  have hs := daysBeforeYear_succ y
  have hy : yearOfDays (daysFromCivil ⟨y, m, d⟩) = y := by
    apply yearOfDays_eq <;> unfold daysFromCivil <;> simp only <;> omega
  have hdoy : doy0OfDays (daysFromCivil ⟨y, m, d⟩) = daysBeforeMonth (isLeapYear y) m + (d - 1) := by
    unfold doy0OfDays; rw [hy]; unfold daysFromCivil; ring
  have hml := monthLength_eq_sub (isLeapYear y) m h1 h2
  have hm : monthOfDoy (isLeapYear y) (daysBeforeMonth (isLeapYear y) m + (d - 1)) = m := by
    apply monthOfDoy_eq _ h1 h2 <;> omega
  unfold civilFromDays
  simp only [hy, hm, hdoy, Date.mk.injEq, true_and]
  omega

/-! ## Successor structure: the day count steps through the calendar -/

/-- Days of the month are consecutive day numbers. -/
theorem daysFromCivil_day_succ (y m d : ℤ) :
    daysFromCivil ⟨y, m, d + 1⟩ = daysFromCivil ⟨y, m, d⟩ + 1 := by
  unfold daysFromCivil; ring

/-- The first of the next month follows the last day of a month (January to
November). -/
theorem daysFromCivil_month_succ (y m : ℤ) (h1 : 1 ≤ m) (h2 : m ≤ 11) :
    daysFromCivil ⟨y, m + 1, 1⟩ = daysFromCivil ⟨y, m, monthLength (isLeapYear y) m⟩ + 1 := by
  unfold daysFromCivil; simp only; rw [daysBeforeMonth_succ _ _ h1 h2]; ring

/-- January 1 of the next year follows December 31. -/
theorem daysFromCivil_year_succ (y : ℤ) :
    daysFromCivil ⟨y + 1, 1, 1⟩ = daysFromCivil ⟨y, 12, 31⟩ + 1 := by
  have h := daysBeforeYear_succ y
  have h12 := daysBeforeMonth_twelve_add y
  have : monthLength (isLeapYear y) 12 = 31 := by unfold monthLength; simp
  unfold daysFromCivil; simp only [daysBeforeMonth_one]; omega

/-- Day 0 is 1970-01-01. -/
theorem daysFromCivil_epoch : daysFromCivil ⟨1970, 1, 1⟩ = 0 := by decide

/-! ## Lexicographic monotonicity -/

/-- The lexicographic key of a date. -/
def Date.key (c : Date) : Lex (ℤ × Lex (ℤ × ℤ)) := toLex (c.year, toLex (c.month, c.day))

theorem Date.key_lt_iff (c c' : Date) : c.key < c'.key ↔
    c.year < c'.year ∨ c.year = c'.year ∧ (c.month < c'.month ∨ c.month = c'.month ∧ c.day < c'.day) := by
  unfold Date.key; simp [Prod.Lex.toLex_lt_toLex]

theorem daysFromCivil_lt_of_key_lt {c c' : Date} (hc : c.Valid) (hc' : c'.Valid)
    (h : c.key < c'.key) : daysFromCivil c < daysFromCivil c' := by
  obtain ⟨b1, b2⟩ := valid_doy_bounds hc
  obtain ⟨b1', b2'⟩ := valid_doy_bounds hc'
  obtain ⟨h1, h2, h3, h4⟩ := hc
  obtain ⟨h1', h2', h3', h4'⟩ := hc'
  rcases (Date.key_lt_iff c c').mp h with hy | ⟨hy, hm | ⟨hm, hd⟩⟩
  · have := daysBeforeYear_succ_le hy
    have := daysBeforeYear_succ c.year
    unfold daysFromCivil; omega
  · have := daysBeforeMonth_add_le (isLeapYear c.year) h1 hm h2'
    unfold daysFromCivil; rw [← hy]; omega
  · unfold daysFromCivil; rw [← hy, ← hm]; omega

/-- Day numbers and dates are in the same order. -/
theorem civilFromDays_key_mono {n n' : ℤ} (h : n ≤ n') :
    (civilFromDays n).key ≤ (civilFromDays n').key := by
  by_contra hlt
  have := daysFromCivil_lt_of_key_lt (civilFromDays_valid n') (civilFromDays_valid n)
    (lt_of_not_ge hlt)
  rw [daysFromCivil_civilFromDays, daysFromCivil_civilFromDays] at this
  omega

end Esm.Closed.Datetime
