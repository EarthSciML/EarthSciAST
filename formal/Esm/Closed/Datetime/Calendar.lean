import Mathlib.Tactic

/-!
# The proleptic-Gregorian calendar over ℤ (esm-spec §9.2, `datetime.*`)

Everything here is integer arithmetic and executable; the adapter runs these
definitions directly. Years are astronomical (`0` = 1 BC, `-1` = 2 BC, the ISO
8601 convention the spec names). Day numbers count days since 1970-01-01.

The definitions are written to be checked by eye against the calendar rules:
`daysBeforeYear` counts days from 0000-01-01 using the leap rule's three
divisibility counts, and `daysBeforeMonth` is the running total of month
lengths. The theorems in `Esm.Closed.Datetime.CalendarFacts` then pin them to
the rules independently of the formulas: year lengths, month lengths, the
inverse pair, and so on.
-/

namespace Esm.Closed.Datetime

/-- The Gregorian leap-year rule: divisible by 4, except centuries not
divisible by 400. -/
def isLeapYear (y : ℤ) : Bool := (y % 4 == 0 && y % 100 != 0) || y % 400 == 0

/-- Days in year `y`. -/
def yearLength (y : ℤ) : ℤ := if isLeapYear y then 366 else 365

/-- Days in month `m` (1 = January) of a year that is (`leap`) or is not a leap
year. Only meaningful for `1 ≤ m ≤ 12`. -/
def monthLength (leap : Bool) (m : ℤ) : ℤ :=
  if m = 2 then (if leap then 29 else 28)
  else if m = 4 ∨ m = 6 ∨ m = 9 ∨ m = 11 then 30
  else 31

/-- Days of the year before the first of month `m` (`1 ≤ m ≤ 12`). From March
on, the month lengths repeat 31, 30, 31, 30, 31 every five months, and
`(153 (m - 3) + 2) / 5` is their running total (0, 31, 61, 92, 122, 153, 184,
214, 245, 275 for March … December).
`CalendarFacts.daysBeforeMonth_succ` checks it against `monthLength`. -/
def daysBeforeMonth (leap : Bool) (m : ℤ) : ℤ :=
  if m ≤ 1 then 0
  else if m = 2 then 31
  else 59 + (if leap then 1 else 0) + (153 * (m - 3) + 2) / 5

/-- Days from 0000-01-01 to `y`-01-01 (negative for `y < 0`): 365 per year plus
one per leap year in `[0, y)`, counted as multiples of 4, minus multiples of
100, plus multiples of 400 (`⌈y/k⌉ = ⌊(y+k-1)/k⌋`; the count is signed for
`y < 0`). -/
def daysBeforeYear (y : ℤ) : ℤ := 365 * y + (y + 3) / 4 - (y + 99) / 100 + (y + 399) / 400

/-- Days from 0000-01-01 to 1970-01-01. -/
def epochOffset : ℤ := 719528

/-- A calendar date. -/
structure Date where
  year : ℤ
  month : ℤ
  day : ℤ
deriving DecidableEq, Repr

/-- A month and day that exist in that year. -/
def Date.Valid (c : Date) : Prop :=
  1 ≤ c.month ∧ c.month ≤ 12 ∧ 1 ≤ c.day ∧ c.day ≤ monthLength (isLeapYear c.year) c.month

instance (c : Date) : Decidable c.Valid := by unfold Date.Valid; infer_instance

/-- Day number (days since 1970-01-01) of a date. -/
def daysFromCivil (c : Date) : ℤ :=
  daysBeforeYear c.year + daysBeforeMonth (isLeapYear c.year) c.month + (c.day - 1) - epochOffset

/-- The year containing day number `n`. `daysBeforeYear y` is within a day or so
of `146097 y / 400`, so `y0` below is the year or the year after; one comparison
picks. (`CalendarFacts.yearOfDays_spec` proves the result is the year whose
first day is at or before `n` and whose successor's is after.) -/
def yearOfDays (n : ℤ) : ℤ :=
  let z := n + epochOffset
  let y0 := (400 * z + 396) / 146097
  if daysBeforeYear y0 ≤ z then y0 else y0 - 1

/-- The month containing zero-based day-of-year `doy0`: January, February,
or the inverse of `daysBeforeMonth`'s March-on pattern. -/
def monthOfDoy (leap : Bool) (doy0 : ℤ) : ℤ :=
  let l : ℤ := if leap then 1 else 0
  if doy0 < 31 then 1
  else if doy0 < 59 + l then 2
  else (5 * (doy0 - 59 - l) + 2) / 153 + 3

/-- Zero-based day of the year of day number `n`. -/
def doy0OfDays (n : ℤ) : ℤ := n + epochOffset - daysBeforeYear (yearOfDays n)

/-- The date of day number `n`. -/
def civilFromDays (n : ℤ) : Date :=
  let y := yearOfDays n
  let doy0 := doy0OfDays n
  let m := monthOfDoy (isLeapYear y) doy0
  ⟨y, m, doy0 - daysBeforeMonth (isLeapYear y) m + 1⟩

/-- One-based day of the year of day number `n` (1 = January 1). -/
def dayOfYearOfDays (n : ℤ) : ℤ := doy0OfDays n + 1

/-- The Fliegel–van Flandern (1968) Julian Day Number of a Gregorian date, as
published: FORTRAN integer division, which truncates toward zero
(`Int.tdiv`). -/
def fvfJdn (c : Date) : ℤ :=
  let a := Int.tdiv (c.month - 14) 12
  Int.tdiv (1461 * (c.year + 4800 + a)) 4
    + Int.tdiv (367 * (c.month - 2 - 12 * a)) 12
    - Int.tdiv (3 * Int.tdiv (c.year + 4900 + a) 100) 4
    + c.day - 32075

/-! ## The signed 32-bit result rule (`closed_function_overflow`) -/

def int32Min : ℤ := -2147483648
def int32Max : ℤ := 2147483647

/-- An integer-valued closed-function result. -/
inductive IntResult where
  | ok (v : ℤ)
  | overflow
deriving DecidableEq, Repr

/-- §9.2: every integer output is signed 32-bit; a result outside that range
raises `closed_function_overflow`. -/
def toInt32 (v : ℤ) : IntResult :=
  if int32Min ≤ v ∧ v ≤ int32Max then .ok v else .overflow

end Esm.Closed.Datetime
