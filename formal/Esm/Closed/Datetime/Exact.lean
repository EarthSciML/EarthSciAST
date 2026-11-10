import Esm.Closed.Datetime.CalendarFacts

/-!
# The calendar fields of a time, in exact arithmetic

The reference functions the `lib/calendar.esm` templates are proven against
(`Esm/Closed/Datetime/TemplateAst.lean`). `t_utc` is a real number of seconds
since 1970-01-01T00:00:00Z. The calendar date is `⌊t / 86400⌋` days after
1970-01-01, the time-of-day is `t mod 86400` (floored, so in `[0, 86400)`), and
hour, minute and second come from `⌊time-of-day⌋` (ruling Q-3). Every field is
`overflow` when the year of `t` is outside Int32 (ruling Q-101); `julian_day`
is the standard Julian Date (ruling Q-99).

Everything is generic over an ordered field with a floor, so the same
definitions are theorems' subjects at `ℝ` and executable at `ℚ`.
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

/-- The integer-valued calendar fields, named by their `lib/calendar.esm` templates. -/
inductive IntFn where
  | year | month | day | hour | minute | second | dayOfYear | isLeapYear
deriving DecidableEq, Repr

/-- The name of each field's template in `lib/calendar.esm`. -/
def IntFn.name : IntFn → String
  | .year => "year"
  | .month => "month"
  | .day => "day"
  | .hour => "hour"
  | .minute => "minute"
  | .second => "second"
  | .dayOfYear => "day_of_year"
  | .isLeapYear => "is_leap_year"

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

/-- The reference result (ruling Q-101): when the year of `t` is outside Int32,
`overflow` whatever the field; else the exact value, under the Int32 result
rule (which every field then meets). -/
def IntFn.eval (f : IntFn) (t : K) : IntResult :=
  if YearInInt32 t then toInt32 (f.exact t) else .overflow

/-- `julian_day` (ruling Q-99): the standard Julian Date, as the exact real
value of the pinned expression on the exact split,
`(d + 2440588) + (time_of_day − 43200) / 86400`. It is `t / 86400 + 2440587.5`
(`julianDay_eq_standard`). -/
def julianDay (t : K) : K := ((dayNumber t + 2440588 : ℤ) : K) + (timeOfDay t - 43200) / 86400

/-- A real-valued calendar result. -/
inductive RealResult (K : Type*) where
  | ok (v : K)
  | overflow

/-- The reference `julian_day` at a finite `t`. -/
def julianDayEval (t : K) : RealResult K :=
  if YearInInt32 t then .ok (julianDay t) else .overflow

/-- The six calendar fields, year to second. -/
def fields (t : K) : ℤ × ℤ × ℤ × ℤ × ℤ × ℤ :=
  (IntFn.year.exact t, IntFn.month.exact t, IntFn.day.exact t,
    IntFn.hour.exact t, IntFn.minute.exact t, IntFn.second.exact t)

/-- The fields in lexicographic order. -/
def fieldsKey (t : K) : Lex (ℤ × Lex (ℤ × Lex (ℤ × Lex (ℤ × Lex (ℤ × ℤ))))) :=
  let f := fields t
  toLex (f.1, toLex (f.2.1, toLex (f.2.2.1, toLex (f.2.2.2.1, toLex (f.2.2.2.2.1, f.2.2.2.2.2)))))

end Esm.Closed.Datetime
