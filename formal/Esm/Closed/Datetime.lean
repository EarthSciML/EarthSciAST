import Esm.Closed.Datetime.Calendar
import Esm.Closed.Datetime.CalendarFacts
import Esm.Closed.Datetime.Exact
import Esm.Closed.Datetime.ExactFacts
import Esm.Closed.Datetime.Binary64
import Esm.Closed.Datetime.Binary64Julian
import Esm.Closed.Datetime.FloatImpl

/-!
# `datetime.*` (esm-spec §9.2)

* `Calendar`, `CalendarFacts`: the proleptic-Gregorian calendar over ℤ;
* `Exact`, `ExactFacts`: the functions of a real `t_utc`, as ruled in Q-3;
* `Binary64`, `Binary64Julian`: the spec's binary64 pipeline against the exact
  model, in the `Esm.F64` rounding model.

This file restates the binary64 results at `ℝ` for the property registry.
-/

namespace Esm.Closed.Datetime

open Esm.F64

/-- Claim (a): `⌊t ⊘ 86400⌋ = ⌊t / 86400⌋` for every double `|t| < 2^60`
outside the underflow band. -/
theorem fDayNumber_exact (t : ℝ) (ht : IsF64 t) (hb : |t| < 2 ^ (60 : ℤ))
    (hband : ¬ (-(43200 * 2 ^ (-1074 : ℤ)) ≤ t ∧ t < 0)) : fDayNumber t = dayNumber t :=
  fDayNumber_eq ht.1 hb hband

/-- In the underflow band the binary64 floor is day 0 instead of day -1. -/
theorem fDayNumber_underflow (t : ℝ) (h1 : -(43200 * 2 ^ (-1074 : ℤ)) ≤ t) (h2 : t < 0) :
    fDayNumber t = dayNumber t + 1 :=
  fDayNumber_band h1 h2

/-- The binary64 floor-divmod gives the exact (day, time of day) pair, so the
exact integer outputs, for every double `|t| ≤ 2^59` outside `(-43200, 0)`. -/
theorem fDivmod_exact (t : ℝ) (ht : IsF64 t) (hb : |t| ≤ 2 ^ (59 : ℤ))
    (hneg : ¬ (-43200 < t ∧ t < 0)) :
    fDayNumber t = dayNumber t ∧ fTimeOfDay t = timeOfDay t ∧ fSecondOfDay t = secondOfDay t := by
  have hband : ¬ (-(43200 * 2 ^ (-1074 : ℤ)) ≤ t ∧ t < 0) := by
    rintro ⟨h1, h2⟩
    have : (43200 : ℝ) * 2 ^ (-1074 : ℤ) < 43200 := by
      have := band_lt_one (K := ℝ); linarith
    exact hneg ⟨by linarith, h2⟩
  have htod := fTimeOfDay_eq ht.1 hb hneg
  refine ⟨fDayNumber_eq ht.1 (lt_of_le_of_lt hb (by norm_num)) hband, htod, ?_⟩
  unfold fSecondOfDay secondOfDay; rw [htod]

/-- §9.2's "a single floor-divmod by 86400 … guarantees … zero ulp drift on
the integer outputs", read for the binary64 floor-divmod, is false: inside
`(-43200, 0)` the remainder rounds (see `fSecondOfDay_ne`). -/
theorem fDivmod_not_exact :
    ¬ ∀ t : ℝ, IsF64 t → |t| ≤ 2 ^ (59 : ℤ) →
      fDayNumber t = dayNumber t ∧ fSecondOfDay t = secondOfDay t :=
  fun h => fSecondOfDay_ne fun t ht hb => (h t ht hb).2

/-- Claim (b): the spec's binary64 julian_day is within one ulp of the exact
value of its formula, for every double `|t| ≤ 2^59`. -/
theorem fJulianDay_within_ulp (t : ℝ) (ht : IsF64 t) (hb : |t| ≤ 2 ^ (59 : ℤ)) :
    |fJulianDay t - julianDay t| ≤ ulp (julianDay t) :=
  fJulianDay_err ht.1 hb

end Esm.Closed.Datetime
