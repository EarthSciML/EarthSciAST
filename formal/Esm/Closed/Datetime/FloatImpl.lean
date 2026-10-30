import Esm.Closed.Datetime.Calendar

/-!
# `datetime.*` on Lean's `Float` (executable; nothing here is proven)

The spec's binary64 pipeline, written with Lean's `Float` (a C `double`) and
following `Binary64.lean`'s `fDayNumber`, `fTimeOfDay` and `fJulianDay`
operation for operation (the integer day number and second of the day of
`fJulianDay` are computed exactly here, as the bindings do). The adapter runs it next to the `Esm.F64` model
evaluated at `ℚ` and reports any difference: that is the differential test
connecting the two.
-/

namespace Esm.Closed.Datetime.FloatImpl

/-- A finite `Float` as an exact rational, from its bits (`none` for ±∞/NaN). -/
def toRat (x : Float) : Option ℚ :=
  let b := x.toBits
  let neg := (b >>> 63) == 1
  let e := ((b >>> 52) &&& 0x7FF).toNat
  let m := (b &&& 0xFFFFFFFFFFFFF).toNat
  if e == 0x7FF then none
  else
    let mag : ℚ := if e == 0 then (m : ℚ) / 2 ^ 1074
      else ((2 ^ 52 + m : ℕ) : ℚ) * (2 : ℚ) ^ ((e : ℤ) - 1075)
    some (if neg then -mag else mag)

/-- `⌊t ⊘ 86400⌋` (as an integer; the floor of a finite double is exact). -/
def dayNumber (t : Float) : Option ℤ := (toRat (t / 86400.0).floor).map (fun q => ⌊q⌋)

/-- `t ⊖ 86400 ⊗ d`. -/
def timeOfDay (t : Float) : Float := t - 86400.0 * (t / 86400.0).floor

/-- `⌊tod⌋`. -/
def secondOfDay (t : Float) : Option ℤ := (toRat (timeOfDay t)).map (fun q => ⌊q⌋)

/-- `(d + 2440588) ⊕ (((s − 43200) ⊕ (t ⊖ ⌊t⌋)) ⊘ 86400)` on the exact split
of `⌊t⌋` (`Binary64.lean`'s `fJulianDay`); `none` for a non-finite `t`. -/
def julianDay (t : Float) : Option Float :=
  (toRat t.floor).map fun w =>
    let s : ℤ := ⌊w⌋
    let d : ℤ := ⌊(s : ℚ) / 86400⌋
    Float.ofInt (d + 2440588) + (Float.ofInt (s - 86400 * d - 43200) + (t - t.floor)) / 86400.0

end Esm.Closed.Datetime.FloatImpl
