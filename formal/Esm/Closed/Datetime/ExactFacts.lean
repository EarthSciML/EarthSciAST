import Esm.Closed.Datetime.Exact
import Mathlib.Basic.Real.Basic

/-!
# Properties of the exact `datetime.*` functions

The registry (`formal/properties/closed-datetime.json`) cites the `ℝ`-valued
theorems in the last section; the generic lemmas above them are the proofs.
-/

namespace Esm.Closed.Datetime

set_option linter.unusedSectionVars false

section Generic

variable {K : Type*} [Field K] [LinearOrder K] [IsStrictOrderedRing K] [FloorRing K]

@[simp] theorem IntFn.exact_year (t : K) : IntFn.year.exact t = (dateOf t).year := rfl
@[simp] theorem IntFn.exact_month (t : K) : IntFn.month.exact t = (dateOf t).month := rfl
@[simp] theorem IntFn.exact_day (t : K) : IntFn.day.exact t = (dateOf t).day := rfl
@[simp] theorem IntFn.exact_hour (t : K) : IntFn.hour.exact t = secondOfDay t / 3600 := rfl
@[simp] theorem IntFn.exact_minute (t : K) : IntFn.minute.exact t = secondOfDay t % 3600 / 60 := rfl
@[simp] theorem IntFn.exact_second (t : K) : IntFn.second.exact t = secondOfDay t % 60 := rfl
@[simp] theorem IntFn.exact_dayOfYear (t : K) :
    IntFn.dayOfYear.exact t = dayOfYearOfDays (dayNumber t) := rfl
@[simp] theorem IntFn.exact_isLeapYear (t : K) :
    IntFn.isLeapYear.exact t = if Datetime.isLeapYear (dateOf t).year then 1 else 0 := rfl

theorem timeOfDay_bounds (t : K) : 0 ≤ timeOfDay t ∧ timeOfDay t < 86400 := by
  have h1 := Int.floor_le (t / 86400)
  have h2 := Int.lt_floor_add_one (t / 86400)
  unfold timeOfDay dayNumber
  constructor
  · have := mul_le_mul_of_nonneg_left h1 (by norm_num : (0 : K) ≤ 86400)
    rw [mul_div_cancel₀ _ (by norm_num)] at this; linarith
  · have := mul_lt_mul_of_pos_left h2 (by norm_num : (0 : K) < 86400)
    rw [mul_div_cancel₀ _ (by norm_num)] at this; linarith

theorem secondOfDay_bounds (t : K) : 0 ≤ secondOfDay t ∧ secondOfDay t ≤ 86399 := by
  obtain ⟨h0, h1⟩ := timeOfDay_bounds t
  unfold secondOfDay
  constructor
  · exact Int.floor_nonneg.mpr h0
  · have : ⌊timeOfDay t⌋ < 86400 := Int.floor_lt.mpr (by exact_mod_cast h1)
    omega

/-- `⌊time-of-day⌋ = ⌊t⌋ - 86400 ⌊t/86400⌋`: flooring the time of day is the
same as flooring `t` first. -/
theorem secondOfDay_eq (t : K) : secondOfDay t = ⌊t⌋ - 86400 * dayNumber t := by
  unfold secondOfDay timeOfDay
  rw [show t - 86400 * (dayNumber t : K) = t + ((-(86400 * dayNumber t) : ℤ) : K) by push_cast; ring,
    Int.floor_add_intCast]
  ring

theorem dayNumber_mono {t t' : K} (h : t ≤ t') : dayNumber t ≤ dayNumber t' :=
  Int.floor_mono (div_le_div_of_nonneg_right h (by norm_num))

theorem dayNumber_lt_iff (t : K) (n : ℤ) : dayNumber t < n ↔ t < 86400 * n := by
  unfold dayNumber
  rw [Int.floor_lt, div_lt_iff₀ (by norm_num : (0 : K) < 86400), mul_comm]

theorem le_dayNumber_iff (t : K) (n : ℤ) : n ≤ dayNumber t ↔ 86400 * (n : K) ≤ t := by
  rw [← not_lt, dayNumber_lt_iff, not_lt]

theorem hms_key_mono {s s' : ℤ} (h : s ≤ s') :
    toLex (s / 3600, toLex (s % 3600 / 60, s % 60)) ≤
      toLex (s' / 3600, toLex (s' % 3600 / 60, s' % 60)) := by
  simp only [Prod.Lex.toLex_le_toLex]
  omega

theorem Date.key_injective {c c' : Date} (h : c.key = c'.key) : c = c' := by
  unfold Date.key at h
  simp only [EmbeddingLike.apply_eq_iff_eq, Prod.mk.injEq] at h
  cases c; cases c'; simp_all

theorem civilFromDays_key_strictMono {n n' : ℤ} (h : n < n') :
    (civilFromDays n).key < (civilFromDays n').key := by
  refine lt_of_le_of_ne (civilFromDays_key_mono h.le) fun he => ?_
  have := congrArg daysFromCivil (Date.key_injective he)
  rw [daysFromCivil_civilFromDays, daysFromCivil_civilFromDays] at this
  omega

theorem fieldsKey_mono {t t' : K} (h : t ≤ t') : fieldsKey t ≤ fieldsKey t' := by
  have hn := dayNumber_mono h
  have hk := fun (c c' : Date) => Date.key_lt_iff c c'
  unfold fieldsKey fields
  simp only [IntFn.exact_year, IntFn.exact_month, IntFn.exact_day, IntFn.exact_hour,
    IntFn.exact_minute, IntFn.exact_second, dateOf, Prod.Lex.toLex_le_toLex]
  rcases hn.lt_or_eq with hlt | heq
  · have := (Date.key_lt_iff _ _).mp (civilFromDays_key_strictMono hlt)
    rcases this with h1 | ⟨h1, h2 | ⟨h2, h3⟩⟩
    · exact Or.inl h1
    · exact Or.inr ⟨h1, Or.inl h2⟩
    · exact Or.inr ⟨h1, Or.inr ⟨h2, Or.inl h3⟩⟩
  · have hs : secondOfDay t ≤ secondOfDay t' := by
      rw [secondOfDay_eq, secondOfDay_eq, heq]
      have := Int.floor_mono h
      omega
    have := hms_key_mono hs
    simp only [Prod.Lex.toLex_le_toLex] at this
    rw [heq]
    right; refine ⟨rfl, Or.inr ⟨rfl, Or.inr ⟨rfl, this⟩⟩⟩

theorem yearOfDays_lt_iff (n Y : ℤ) : yearOfDays n < Y ↔ n < daysFromCivil ⟨Y, 1, 1⟩ := by
  obtain ⟨h1, h2⟩ := yearOfDays_spec n
  unfold daysFromCivil
  simp only [daysBeforeMonth_one]
  constructor
  · intro h
    have := daysBeforeYear_succ_le h
    omega
  · intro h
    by_contra hge
    rcases (not_lt.mp hge).lt_or_eq with hlt | heq
    · have := daysBeforeYear_strictMono hlt; omega
    · rw [← heq] at h1; omega

end Generic

/-! ## The registry's statements, at `K = ℝ` -/

/-- Every integer function's output lies in its stated range (§9.2 table). -/
theorem ranges (t : ℝ) :
    (1 ≤ IntFn.month.exact t ∧ IntFn.month.exact t ≤ 12) ∧
    (1 ≤ IntFn.day.exact t ∧
      IntFn.day.exact t ≤ monthLength (isLeapYear (IntFn.year.exact t)) (IntFn.month.exact t) ∧
      IntFn.day.exact t ≤ 31) ∧
    (0 ≤ IntFn.hour.exact t ∧ IntFn.hour.exact t ≤ 23) ∧
    (0 ≤ IntFn.minute.exact t ∧ IntFn.minute.exact t ≤ 59) ∧
    (0 ≤ IntFn.second.exact t ∧ IntFn.second.exact t ≤ 59) ∧
    (1 ≤ IntFn.dayOfYear.exact t ∧ IntFn.dayOfYear.exact t ≤ yearLength (IntFn.year.exact t) ∧
      IntFn.dayOfYear.exact t ≤ 366) ∧
    (IntFn.isLeapYear.exact t = 0 ∨ IntFn.isLeapYear.exact t = 1) := by
  have hv := civilFromDays_valid (dayNumber t)
  have hs := secondOfDay_bounds t
  have hd := doy0OfDays_bounds (dayNumber t)
  have hml := monthLength_bounds (isLeapYear (civilFromDays (dayNumber t)).year)
    (civilFromDays (dayNumber t)).month
  have hyl : yearLength (yearOfDays (dayNumber t)) ≤ 366 := by unfold yearLength; split_ifs <;> omega
  have hy : (civilFromDays (dayNumber t)).year = yearOfDays (dayNumber t) := rfl
  obtain ⟨h1, h2, h3, h4⟩ := hv
  simp only [IntFn.exact_year, IntFn.exact_month, IntFn.exact_day, IntFn.exact_hour,
    IntFn.exact_minute, IntFn.exact_second, IntFn.exact_dayOfYear, IntFn.exact_isLeapYear,
    dateOf, dayOfYearOfDays]
  simp only [hy] at h4 hml ⊢
  refine ⟨⟨h1, h2⟩, ⟨h3, h4, by omega⟩, ⟨by omega, by omega⟩, ⟨by omega, by omega⟩,
    ⟨by omega, by omega⟩, ⟨by omega, by omega, by omega⟩, ?_⟩
  split_ifs <;> simp

/-- The floor-divmod by 86400: `t = 86400 · day + tod` with `0 ≤ tod < 86400`. -/
theorem divmod (t : ℝ) :
    t = 86400 * dayNumber t + timeOfDay t ∧ 0 ≤ timeOfDay t ∧ timeOfDay t < 86400 := by
  refine ⟨by unfold timeOfDay; ring, timeOfDay_bounds t⟩

/-- The decomposition round-trips: date and time of day give back `⌊t⌋`. -/
theorem roundtrip (t : ℝ) :
    86400 * daysFromCivil ⟨IntFn.year.exact t, IntFn.month.exact t, IntFn.day.exact t⟩ +
      3600 * IntFn.hour.exact t + 60 * IntFn.minute.exact t + IntFn.second.exact t = ⌊t⌋ := by
  have hs := secondOfDay_eq t
  have hb := secondOfDay_bounds t
  have : daysFromCivil ⟨IntFn.year.exact t, IntFn.month.exact t, IntFn.day.exact t⟩ = dayNumber t :=
    daysFromCivil_civilFromDays _
  rw [this]
  simp only [IntFn.exact_hour, IntFn.exact_minute, IntFn.exact_second]
  omega

/-- The integer outputs are monotone in `t`, in lexicographic order of
(year, month, day, hour, minute, second). -/
theorem fields_mono (t t' : ℝ) (h : t ≤ t') : fieldsKey t ≤ fieldsKey t' := fieldsKey_mono h

/-- day_of_year agrees with month and day, and counts from January 1. -/
theorem dayOfYear_agrees (t : ℝ) :
    IntFn.dayOfYear.exact t =
        daysBeforeMonth (isLeapYear (IntFn.year.exact t)) (IntFn.month.exact t) + IntFn.day.exact t ∧
      IntFn.dayOfYear.exact t = dayNumber t - daysFromCivil ⟨IntFn.year.exact t, 1, 1⟩ + 1 := by
  simp only [IntFn.exact_year, IntFn.exact_month, IntFn.exact_day, IntFn.exact_dayOfYear,
    dateOf, dayOfYearOfDays, civilFromDays, daysFromCivil, doy0OfDays, daysBeforeMonth_one]
  constructor <;> ring

/-- is_leap_year is 1 exactly when the year of `t` has 366 days, i.e. when it
has a February 29; and that is the Gregorian divisibility rule. -/
theorem isLeapYear_agrees (t : ℝ) :
    (IntFn.isLeapYear.exact t = 1 ↔
      daysFromCivil ⟨IntFn.year.exact t + 1, 1, 1⟩ - daysFromCivil ⟨IntFn.year.exact t, 1, 1⟩ = 366) ∧
    (IntFn.isLeapYear.exact t = 1 ↔ (Date.Valid ⟨IntFn.year.exact t, 2, 29⟩)) ∧
    (IntFn.isLeapYear.exact t = 1 ↔
      (4 ∣ IntFn.year.exact t ∧ ¬ 100 ∣ IntFn.year.exact t) ∨ 400 ∣ IntFn.year.exact t) := by
  generalize hy : IntFn.year.exact t = y
  have hl : IntFn.isLeapYear.exact t = if isLeapYear y then 1 else 0 := by
    rw [← hy]; rfl
  rw [hl]
  have hs := daysBeforeYear_succ y
  unfold daysFromCivil
  simp only [daysBeforeMonth_one]
  refine ⟨?_, ?_, ?_⟩
  · unfold yearLength at hs; split_ifs at hs ⊢ <;> simp <;> omega
  · unfold Date.Valid monthLength; split_ifs <;> simp_all
  · rw [← isLeapYear_iff]; split_ifs <;> simp_all

/-- The civil date of a day number and the day number of a valid date are
inverse. -/
theorem civil_days_inverse :
    (∀ n : ℤ, daysFromCivil (civilFromDays n) = n ∧ (civilFromDays n).Valid) ∧
      ∀ c : Date, c.Valid → civilFromDays (daysFromCivil c) = c :=
  ⟨fun n => ⟨daysFromCivil_civilFromDays n, civilFromDays_valid n⟩,
    fun _ hc => civilFromDays_daysFromCivil hc⟩

/-- The day count steps through the proleptic-Gregorian calendar from
1970-01-01: consecutive days, month lengths, years of 365 or 366 days. -/
theorem calendar_steps :
    daysFromCivil ⟨1970, 1, 1⟩ = 0 ∧
    (∀ y m d : ℤ, daysFromCivil ⟨y, m, d + 1⟩ = daysFromCivil ⟨y, m, d⟩ + 1) ∧
    (∀ y m : ℤ, 1 ≤ m → m ≤ 11 →
      daysFromCivil ⟨y, m + 1, 1⟩ = daysFromCivil ⟨y, m, monthLength (isLeapYear y) m⟩ + 1) ∧
    (∀ y : ℤ, daysFromCivil ⟨y + 1, 1, 1⟩ = daysFromCivil ⟨y, 12, 31⟩ + 1) ∧
    (∀ (l : Bool) (m : ℤ), monthLength l m =
      if m = 2 then (if l then 29 else 28) else if m = 4 ∨ m = 6 ∨ m = 9 ∨ m = 11 then 30 else 31) ∧
    (∀ y : ℤ, yearLength y = if (4 ∣ y ∧ ¬ 100 ∣ y) ∨ 400 ∣ y then 366 else 365) := by
  refine ⟨daysFromCivil_epoch, daysFromCivil_day_succ, daysFromCivil_month_succ,
    daysFromCivil_year_succ, fun _ _ => rfl, fun y => ?_⟩
  simp only [yearLength, ← isLeapYear_iff]

/-- §9.2's overflow rule: each integer function raises `closed_function_overflow`
exactly when its exact value is outside Int32. -/
theorem overflow_iff (f : IntFn) (t : ℝ) :
    f.eval t = .overflow ↔ ¬ (int32Min ≤ f.exact t ∧ f.exact t ≤ int32Max) := by
  unfold IntFn.eval toInt32
  split_ifs with h <;> simp [h]

/-- Only `datetime.year` can overflow, and it does exactly outside
[-2147483648-01-01, 2147483648-01-01). -/
theorem overflow_only_year (f : IntFn) (t : ℝ) :
    (f ≠ .year → f.eval t = .ok (f.exact t)) ∧
    (IntFn.year.eval t = .overflow ↔
      t < 86400 * (daysFromCivil ⟨int32Min, 1, 1⟩ : ℝ) ∨
        86400 * (daysFromCivil ⟨int32Max + 1, 1, 1⟩ : ℝ) ≤ t) := by
  constructor
  · intro hf
    obtain ⟨hm, hd, hh, hmi, hs, hdoy, hl⟩ := ranges t
    have hr : int32Min ≤ f.exact t ∧ f.exact t ≤ int32Max := by
      unfold int32Min int32Max
      cases f <;> first | exact absurd rfl hf | omega
    unfold IntFn.eval toInt32
    simp [hr]
  · rw [overflow_iff]
    have h1 := yearOfDays_lt_iff (dayNumber t) int32Min
    have h2 := yearOfDays_lt_iff (dayNumber t) (int32Max + 1)
    have h3 := dayNumber_lt_iff t (daysFromCivil ⟨int32Min, 1, 1⟩)
    have h4 := dayNumber_lt_iff t (daysFromCivil ⟨int32Max + 1, 1, 1⟩)
    have hy : IntFn.year.exact t = yearOfDays (dayNumber t) := rfl
    rw [hy]
    constructor
    · intro h
      rcases (show yearOfDays (dayNumber t) < int32Min ∨ ¬ yearOfDays (dayNumber t) < int32Max + 1 by
        omega) with h' | h'
      · exact Or.inl (h3.mp (h1.mp h'))
      · exact Or.inr (not_lt.mp fun h'' => h' (h2.mpr (h4.mpr h'')))
    · rintro (h | h)
      · have := h1.mpr (h3.mpr h); omega
      · have : ¬ yearOfDays (dayNumber t) < int32Max + 1 := fun h' => absurd (h4.mp (h2.mp h')) (not_lt.mpr h)
        omega

/-- On and after -4800-03-01 the spec's reference julian_day is the standard
continuous Julian Date, `t / 86400 + 2440587.5`. -/
theorem julianDay_eq_of_ge (t : ℝ) (h : 86400 * (daysFromCivil fvfFirstDate : ℝ) ≤ t) :
    julianDay t = t / 86400 + 2440587.5 := by
  have hn := (le_dayNumber_iff t _).mpr h
  have hv := civilFromDays_valid (dayNumber t)
  have he := fvfJdn_eq hv (by rw [daysFromCivil_civilFromDays]; exact hn)
  rw [daysFromCivil_civilFromDays] at he
  unfold julianDay dateOf timeOfDay
  rw [he]; push_cast; ring

/-- Unrestricted, it is false: on -4800-02-29 the FvF formula (as published,
with truncating division) is one day ahead. -/
theorem julianDay_ne_standard : ¬ ∀ t : ℝ, julianDay t = t / 86400 + 2440587.5 := by
  intro h
  have ht := h (86400 * (-2472633 : ℤ))
  have hn : dayNumber ((86400 : ℝ) * ((-2472633 : ℤ) : ℝ)) = -2472633 := by
    unfold dayNumber; rw [mul_div_cancel_left₀ _ (by norm_num), Int.floor_intCast]
  have hc : civilFromDays (-2472633) = ⟨-4800, 2, 29⟩ := by decide
  have hj : fvfJdn ⟨-4800, 2, 29⟩ = -32044 := by decide
  unfold julianDay dateOf timeOfDay at ht
  rw [hn, hc, hj] at ht
  push_cast at ht
  norm_num at ht

end Esm.Closed.Datetime
