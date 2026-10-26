import Esm.Closed.Datetime.CalendarFacts

/-!
# The `datetime.*` functions in exact arithmetic (esm-spec §9.2)

`t_utc` is a real number of seconds since 1970-01-01T00:00:00Z. Per §9.2 and
ruling Q-3, the calendar date is `⌊t / 86400⌋` days after 1970-01-01, the
time-of-day is `t mod 86400` (floored, so in `[0, 86400)`), and hour, minute and
second come from `⌊time-of-day⌋`. Integer results are signed 32-bit, otherwise
`closed_function_overflow`.

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

/-- The result a binding must produce: the exact value if it fits in Int32,
else `closed_function_overflow`. -/
def IntFn.eval (f : IntFn) (t : K) : IntResult := toInt32 (f.exact t)

/-- `datetime.julian_day` as the spec's reference computation, in exact
arithmetic: the Fliegel–van Flandern JDN of the date, plus
`(time_of_day − 43200) / 86400`. -/
def julianDay (t : K) : K := (fvfJdn (dateOf t) : K) + (timeOfDay t - 43200) / 86400

/-- The six calendar fields, year to second. -/
def fields (t : K) : ℤ × ℤ × ℤ × ℤ × ℤ × ℤ :=
  (IntFn.year.exact t, IntFn.month.exact t, IntFn.day.exact t,
    IntFn.hour.exact t, IntFn.minute.exact t, IntFn.second.exact t)

/-- The fields in lexicographic order. -/
def fieldsKey (t : K) : Lex (ℤ × Lex (ℤ × Lex (ℤ × Lex (ℤ × Lex (ℤ × ℤ))))) :=
  let f := fields t
  toLex (f.1, toLex (f.2.1, toLex (f.2.2.1, toLex (f.2.2.2.1, toLex (f.2.2.2.2.1, f.2.2.2.2.2)))))

end Esm.Closed.Datetime
