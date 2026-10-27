import Esm.Closed.Datetime.CalendarFacts

/-!
# The `datetime.*` functions in exact arithmetic (esm-spec §9.2)

`t_utc` is a real number of seconds since 1970-01-01T00:00:00Z. Per §9.2 and
ruling Q-3, the calendar date is `⌊t / 86400⌋` days after 1970-01-01, the
time-of-day is `t mod 86400` (floored, so in `[0, 86400)`), and hour, minute and
second come from `⌊time-of-day⌋`. Every function raises
`closed_function_overflow` when the year of `t` is outside Int32 (ruling
Q-101) and when `t` is NaN or ±Inf (ruling Q-100, modelled by `Time`);
`julian_day` is the standard Julian Date (ruling Q-99).

Everything is generic over an ordered field with a floor, so the same
definitions are theorems' subjects at `ℝ` and executable at `ℚ` (the adapter
runs them at `ℚ` on the exact value of the binary64 input).
-/

namespace Esm.Closed.Datetime

variable {K : Type*} [Field K] [LinearOrder K] [IsStrictOrderedRing K] [FloorRing K]

/-- The day number: `⌊t / 86400⌋`. -/
def dayNumber (t : K) : ℤ := ⌊t / 86400⌋

/-- Time of day in seconds, `t mod 86400` with floored division. -/
def timeOfDay (t : K) : K := t - 86400 * dayNumber t

/-- Whole seconds since midnight, `⌊time-of-day⌋` (ruling Q-3). -/
def secondOfDay (t : K) : ℤ := ⌊timeOfDay t⌋

/-- The calendar date of `t`. -/
def dateOf (t : K) : Date := civilFromDays (dayNumber t)

/-- The integer-valued `datetime.*` functions. -/
inductive IntFn where
  | year | month | day | hour | minute | second | dayOfYear | isLeapYear
deriving DecidableEq, Repr

/-- The spec name of each function. -/
def IntFn.name : IntFn → String
  | .year => "datetime.year"
  | .month => "datetime.month"
  | .day => "datetime.day"
  | .hour => "datetime.hour"
  | .minute => "datetime.minute"
  | .second => "datetime.second"
  | .dayOfYear => "datetime.day_of_year"
  | .isLeapYear => "datetime.is_leap_year"

/-- The exact integer value of each function, before the 32-bit check. -/
def IntFn.exact : IntFn → K → ℤ
  | .year, t => (dateOf t).year
  | .month, t => (dateOf t).month
  | .day, t => (dateOf t).day
  | .hour, t => secondOfDay t / 3600
  | .minute, t => secondOfDay t % 3600 / 60
  | .second, t => secondOfDay t % 60
  | .dayOfYear, t => dayOfYearOfDays (dayNumber t)
  | .isLeapYear, t => if Datetime.isLeapYear (dateOf t).year then 1 else 0

/-- The year of `t` is a signed 32-bit integer. -/
def YearInInt32 (t : K) : Prop :=
  int32Min ≤ IntFn.year.exact t ∧ IntFn.year.exact t ≤ int32Max

instance (t : K) : Decidable (YearInInt32 t) := by unfold YearInInt32; infer_instance

/-- The result a binding must produce (§9.2, ruling Q-101): when the year of
`t` is outside Int32, `closed_function_overflow` whatever the field; else the
exact value, under §9.2's Int32 result rule (which every field then meets). -/
def IntFn.eval (f : IntFn) (t : K) : IntResult :=
  if YearInInt32 t then toInt32 (f.exact t) else .overflow

/-- `datetime.julian_day` (ruling Q-99): the standard Julian Date, as the exact
real value of the expression §9.2 pins on the exact split,
`(d + 2440588) + (time_of_day − 43200) / 86400`. It is `t / 86400 + 2440587.5`
(`julianDay_eq_standard`). -/
def julianDay (t : K) : K := ((dayNumber t + 2440588 : ℤ) : K) + (timeOfDay t - 43200) / 86400

/-- §9.2's informative note: the Fliegel–van Flandern JDN of the date, plus
`(time_of_day − 43200) / 86400`, in exact arithmetic. It is the Julian Date
from -4800-03-01 on (`fvfJulianDay_eq_of_ge`) and not before
(`fvfJulianDay_ne_standard`). -/
def fvfJulianDay (t : K) : K := (fvfJdn (dateOf t) : K) + (timeOfDay t - 43200) / 86400

/-- A real-valued closed-function result. -/
inductive RealResult (K : Type*) where
  | ok (v : K)
  | overflow

/-- What a binding must produce for `datetime.julian_day` at a finite `t`. -/
def julianDayEval (t : K) : RealResult K :=
  if YearInInt32 t then .ok (julianDay t) else .overflow

/-- A binary64 `t_utc` as §9.2 sees it: a finite value, NaN or ±∞. -/
inductive Time (K : Type*) where
  | finite (t : K)
  | nan
  | posInf
  | negInf

/-- An integer `datetime.*` function on any binary64 input (ruling Q-100: a
non-finite `t` raises `closed_function_overflow`). -/
def IntFn.evalTime (f : IntFn) : Time K → IntResult
  | .finite t => f.eval t
  | _ => .overflow

/-- `datetime.julian_day` on any binary64 input. -/
def julianDayEvalTime : Time K → RealResult K
  | .finite t => julianDayEval t
  | _ => .overflow

/-- The six calendar fields, year to second. -/
def fields (t : K) : ℤ × ℤ × ℤ × ℤ × ℤ × ℤ :=
  (IntFn.year.exact t, IntFn.month.exact t, IntFn.day.exact t,
    IntFn.hour.exact t, IntFn.minute.exact t, IntFn.second.exact t)

/-- The fields in lexicographic order. -/
def fieldsKey (t : K) : Lex (ℤ × Lex (ℤ × Lex (ℤ × Lex (ℤ × Lex (ℤ × ℤ))))) :=
  let f := fields t
  toLex (f.1, toLex (f.2.1, toLex (f.2.2.1, toLex (f.2.2.2.1, toLex (f.2.2.2.2.1, f.2.2.2.2.2)))))

end Esm.Closed.Datetime
