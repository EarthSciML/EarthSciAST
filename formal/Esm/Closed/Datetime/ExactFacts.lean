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

/-- The year of `t` is an Int32 exactly on
[-2147483648-01-01T00:00:00Z, 2147483648-01-01T00:00:00Z). -/
theorem yearInInt32_iff (t : ℝ) :
    YearInInt32 t ↔ 86400 * (daysFromCivil ⟨int32Min, 1, 1⟩ : ℝ) ≤ t ∧
      t < 86400 * (daysFromCivil ⟨int32Max + 1, 1, 1⟩ : ℝ) := by
  have h1 := yearOfDays_lt_iff (dayNumber t) int32Min
  have h2 := yearOfDays_lt_iff (dayNumber t) (int32Max + 1)
  have h3 := dayNumber_lt_iff t (daysFromCivil ⟨int32Min, 1, 1⟩)
  have h4 := dayNumber_lt_iff t (daysFromCivil ⟨int32Max + 1, 1, 1⟩)
  have hy : IntFn.year.exact t = yearOfDays (dayNumber t) := rfl
  unfold YearInInt32
  rw [hy]
  constructor
  · rintro ⟨a, b⟩
    refine ⟨not_lt.mp fun h => ?_, ?_⟩
    · have := h1.mpr (h3.mpr h); omega
    · by_contra h
      have : ¬ dayNumber t < daysFromCivil ⟨int32Max + 1, 1, 1⟩ := fun h' => h (h4.mp h')
      have : ¬ yearOfDays (dayNumber t) < int32Max + 1 := fun h' => this (h2.mp h')
      omega
  · rintro ⟨a, b⟩
    constructor
    · by_contra h
      have := h3.mp (h1.mp (by omega))
      linarith
    · by_contra h
      have h' : ¬ yearOfDays (dayNumber t) < int32Max + 1 := by omega
      exact h' (h2.mpr (h4.mpr b))

/-- §9.2 as ruled in Q-101: every `datetime.*` function, `julian_day` included,
raises `closed_function_overflow` exactly when the year of `t` is outside Int32
(i.e. outside [-2147483648-01-01, 2147483648-01-01)), and otherwise returns its
exact value — every other integer field then fits in Int32. -/
theorem overflow_year_rule (f : IntFn) (t : ℝ) :
    (f.eval t = .overflow ↔ ¬ YearInInt32 t) ∧
    (YearInInt32 t → f.eval t = .ok (f.exact t)) ∧
    (julianDayEval t = .overflow ↔ ¬ YearInInt32 t) ∧
    (YearInInt32 t → julianDayEval t = .ok (julianDay t)) ∧
    (YearInInt32 t ↔ 86400 * (daysFromCivil ⟨int32Min, 1, 1⟩ : ℝ) ≤ t ∧
      t < 86400 * (daysFromCivil ⟨int32Max + 1, 1, 1⟩ : ℝ)) := by
  have hfit : YearInInt32 t → int32Min ≤ f.exact t ∧ f.exact t ≤ int32Max := by
    intro hy
    obtain ⟨hm, hd, hh, hmi, hs, hdoy, hl⟩ := ranges t
    cases f
    · exact hy
    all_goals (unfold int32Min int32Max; omega)
  refine ⟨?_, ?_, ?_, ?_, yearInInt32_iff t⟩
  · unfold IntFn.eval
    by_cases hy : YearInInt32 t
    · simp only [hy, ↓reduceIte, toInt32, hfit hy, and_self, not_true_eq_false, iff_false]
      exact fun h => nomatch h
    · simp [hy]
  · intro hy
    unfold IntFn.eval toInt32
    simp [hy, hfit hy]
  · unfold julianDayEval
    by_cases hy : YearInInt32 t
    · simp only [hy, ↓reduceIte, not_true_eq_false, iff_false]
      exact fun h => nomatch h
    · simp [hy]
  · intro hy
    unfold julianDayEval
    simp [hy]

/-- §9.2 as ruled in Q-100: a NaN or ±∞ `t` raises `closed_function_overflow`
in every `datetime.*` function; a finite one is evaluated as above. -/
theorem nonfinite_overflow (f : IntFn) :
    (∀ t : ℝ, f.evalTime (.finite t) = f.eval t ∧ julianDayEvalTime (.finite t) = julianDayEval t) ∧
    f.evalTime (.nan : Time ℝ) = .overflow ∧ f.evalTime (.posInf : Time ℝ) = .overflow ∧
    f.evalTime (.negInf : Time ℝ) = .overflow ∧
    julianDayEvalTime (.nan : Time ℝ) = .overflow ∧ julianDayEvalTime (.posInf : Time ℝ) = .overflow ∧
    julianDayEvalTime (.negInf : Time ℝ) = .overflow :=
  ⟨fun _ => ⟨rfl, rfl⟩, rfl, rfl, rfl, rfl, rfl, rfl⟩

/-- The first instant of year 2147483648 (one past Int32 max), as a day number. -/
theorem civil_int32_end : civilFromDays 784351576777 = ⟨2147483648, 1, 1⟩ := by decide

/-- At the first instant of year 2147483648, `datetime.month` is 1 (a small
Int32) and still overflows. -/
theorem month_overflows_at_int32_end :
    IntFn.month.eval ((86400 : ℝ) * (784351576777 : ℤ)) = .overflow ∧
      IntFn.month.exact ((86400 : ℝ) * (784351576777 : ℤ)) = 1 := by
  have hn : dayNumber ((86400 : ℝ) * ((784351576777 : ℤ) : ℝ)) = 784351576777 := by
    unfold dayNumber; rw [mul_div_cancel_left₀ _ (by norm_num), Int.floor_intCast]
  have hd : dateOf ((86400 : ℝ) * ((784351576777 : ℤ) : ℝ)) = ⟨2147483648, 1, 1⟩ := by
    unfold dateOf; rw [hn, civil_int32_end]
  have hy : ¬ YearInInt32 ((86400 : ℝ) * ((784351576777 : ℤ) : ℝ)) := by
    unfold YearInInt32; rw [IntFn.exact_year, hd]; unfold int32Max; norm_num
  refine ⟨?_, ?_⟩
  · unfold IntFn.eval; rw [ite_cond_eq_false _ _ (eq_false hy)]
  · rw [IntFn.exact_month, hd]

/-- Retired by ruling Q-101: the overflow is no longer decided by each field's
own value. -/
theorem overflow_iff_refuted :
    ¬ ∀ (f : IntFn) (t : ℝ),
      f.eval t = .overflow ↔ ¬ (int32Min ≤ f.exact t ∧ f.exact t ≤ int32Max) := by
  intro h
  obtain ⟨h1, h2⟩ := month_overflows_at_int32_end
  have := (h .month ((86400 : ℝ) * (784351576777 : ℤ))).mp h1
  rw [h2] at this
  exact this ⟨by unfold int32Min; omega, by unfold int32Max; omega⟩

/-- Retired by ruling Q-101: `datetime.year` is not the only function that
overflows. -/
theorem overflow_only_year_refuted :
    ¬ ∀ (f : IntFn) (t : ℝ),
      (f ≠ .year → f.eval t = .ok (f.exact t)) ∧
      (IntFn.year.eval t = .overflow ↔
        t < 86400 * (daysFromCivil ⟨int32Min, 1, 1⟩ : ℝ) ∨
          86400 * (daysFromCivil ⟨int32Max + 1, 1, 1⟩ : ℝ) ≤ t) := by
  intro h
  obtain ⟨h1, -⟩ := month_overflows_at_int32_end
  have := (h .month ((86400 : ℝ) * (784351576777 : ℤ))).1 (by decide)
  rw [h1] at this
  exact nomatch this

/-- `datetime.julian_day` is the standard Julian Date for every `t` (ruling
Q-99). -/
theorem julianDay_eq_standard (t : ℝ) : julianDay t = t / 86400 + 2440587.5 := by
  unfold julianDay timeOfDay; push_cast; ring

/-- §9.2's informative note: on and after -4800-03-01 the Fliegel–van Flandern
computation is the standard continuous Julian Date, `t / 86400 + 2440587.5`. -/
theorem fvfJulianDay_eq_of_ge (t : ℝ) (h : 86400 * (daysFromCivil fvfFirstDate : ℝ) ≤ t) :
    fvfJulianDay t = t / 86400 + 2440587.5 := by
  have hn := (le_dayNumber_iff t _).mpr h
  have hv := civilFromDays_valid (dayNumber t)
  have he := fvfJdn_eq hv (by rw [daysFromCivil_civilFromDays]; exact hn)
  rw [daysFromCivil_civilFromDays] at he
  unfold fvfJulianDay dateOf timeOfDay
  rw [he]; push_cast; ring

/-- Unrestricted, it is false: on -4800-02-29 the FvF formula (as published,
with truncating division) is one day ahead. -/
theorem fvfJulianDay_ne_standard : ¬ ∀ t : ℝ, fvfJulianDay t = t / 86400 + 2440587.5 := by
  intro h
  have ht := h (86400 * (-2472633 : ℤ))
  have hn : dayNumber ((86400 : ℝ) * ((-2472633 : ℤ) : ℝ)) = -2472633 := by
    unfold dayNumber; rw [mul_div_cancel_left₀ _ (by norm_num), Int.floor_intCast]
  have hc : civilFromDays (-2472633) = ⟨-4800, 2, 29⟩ := by decide
  have hj : fvfJdn ⟨-4800, 2, 29⟩ = -32044 := by decide
  unfold fvfJulianDay dateOf timeOfDay at ht
  rw [hn, hc, hj] at ht
  push_cast at ht
  norm_num at ht

end Esm.Closed.Datetime
