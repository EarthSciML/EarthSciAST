import Esm.Units.Rat

/-!
# The unit registry table (esm-spec §4.8.1)

The flat table, exactly as written in §4.8.1: a symbol is in it, spelled exactly,
or it does not resolve. Each entry is built from the scale the spec STATES for it,
so the identities in `Esm.Units.Identities` are checks of the table rather than
restatements — with three exceptions, where the spec states the scale AS a
product: `hp` (`550 × 0.3048 × 0.45359237 × 9.80665`), `psi`
(`0.45359237 × 9.80665 / 0.0254²`) and `Torr` (`101325/760`). Their identities
confirm only that those products agree with the `ft`, `lb` and `atm` entries;
the independent check on `hp` is its binary64 fold (`hp_fold_left_to_right`).

Scales the spec does not state are the SI definitions the symbol names (`km` is
1000 m, `bar` is 10⁵ Pa, …), except for three choices recorded as questions in
the phase-1 report: `cal` (thermochemical 4.184 J — the spec names no
calorie), and the scales of the mixing ratios `ppm`/`ppb`/`ppt` (the spec calls
them dimensionless and gives no scale; `ppt` is read as 10⁻¹², parts per
trillion), each matching every binding.
-/

namespace Esm.Units

/-- A dimension from its eight exponents, in axis order. -/
def D (m kg s mol K A cd rad : ℚ) : Dim
  | .m => m | .kg => kg | .s => s | .mol => mol
  | .K => K | .A => A | .cd => cd | .rad => rad

/-- A registry entry: a dimension and an exact positive rational scale. -/
def mk (d : Dim) (q : ℚ) : U := ⟨d, Scale.ofRat q⟩

/-- A registry entry with a power of π in its scale. -/
def mkPi (d : Dim) (q : ℚ) (k : ℚ) : U := ⟨d, Scale.ofRat q ++ Scale.pi k⟩

namespace Dims
def dimless : Dim := D 0 0 0 0 0 0 0 0
def len : Dim := D 1 0 0 0 0 0 0 0
def mass : Dim := D 0 1 0 0 0 0 0 0
def time : Dim := D 0 0 1 0 0 0 0 0
def amount : Dim := D 0 0 0 1 0 0 0 0
def temp : Dim := D 0 0 0 0 1 0 0 0
def current : Dim := D 0 0 0 0 0 1 0 0
def lum : Dim := D 0 0 0 0 0 0 1 0
def angle : Dim := D 0 0 0 0 0 0 0 1
def solidAngle : Dim := D 0 0 0 0 0 0 0 2
def freq : Dim := D 0 0 (-1) 0 0 0 0 0
def vol : Dim := D 3 0 0 0 0 0 0 0
def conc : Dim := D (-3) 0 0 1 0 0 0 0
def force : Dim := D 1 1 (-2) 0 0 0 0 0
def pressure : Dim := D (-1) 1 (-2) 0 0 0 0 0
def energy : Dim := D 2 1 (-2) 0 0 0 0 0
def power : Dim := D 2 1 (-3) 0 0 0 0 0
def charge : Dim := D 0 0 1 0 0 1 0 0
def voltage : Dim := D 2 1 (-3) 0 0 (-1) 0 0
def resistance : Dim := D 2 1 (-3) 0 0 (-2) 0 0
def capacitance : Dim := D (-2) (-1) 4 0 0 2 0 0
def fluxDensity : Dim := D 0 1 (-2) 0 0 (-1) 0 0
def column : Dim := D (-2) 0 0 0 0 0 0 0
end Dims

open Dims in
/-- The §4.8.1 table, group by group, in the spec's order. -/
def table : List (String × U) := [
  -- SI base
  ("m", mk len 1), ("kg", mk mass 1), ("s", mk time 1), ("mol", mk amount 1),
  ("K", mk temp 1), ("A", mk current 1), ("cd", mk lum 1), ("rad", mk angle 1),
  -- Mass
  ("g", mk mass (1 / 1000)), ("mg", mk mass (1 / 10 ^ 6)), ("ug", mk mass (1 / 10 ^ 9)),
  ("lb", mk mass 0.45359237), ("short_ton", mk mass 907.18474), ("tonne", mk mass 1000),
  -- Length
  ("dm", mk len (1 / 10)), ("cm", mk len (1 / 100)), ("mm", mk len (1 / 1000)),
  ("um", mk len (1 / 10 ^ 6)), ("nm", mk len (1 / 10 ^ 9)), ("km", mk len 1000),
  ("ft", mk len 0.3048), ("mi", mk len 1609.344),
  -- Time
  ("ms", mk time (1 / 1000)), ("us", mk time (1 / 10 ^ 6)), ("ns", mk time (1 / 10 ^ 9)),
  ("min", mk time 60), ("h", mk time 3600), ("hr", mk time 3600), ("day", mk time 86400),
  ("yr", mk time 31557600), ("year", mk time 31557600),
  -- Volume
  ("L", mk vol (1 / 1000)), ("l", mk vol (1 / 1000)), ("mL", mk vol (1 / 10 ^ 6)),
  ("gal", mk vol 0.003785411784),
  -- Amount
  ("kmol", mk amount 1000), ("mmol", mk amount (1 / 1000)), ("umol", mk amount (1 / 10 ^ 6)),
  ("nmol", mk amount (1 / 10 ^ 9)), ("M", mk conc 1000),
  -- Derived
  ("Hz", mk freq 1), ("N", mk force 1), ("Pa", mk pressure 1), ("J", mk energy 1),
  ("kJ", mk energy 1000), ("cal", mk energy 4.184), ("kcal", mk energy 4184),
  ("W", mk power 1), ("kW", mk power 1000), ("MW", mk power (10 ^ 6)),
  ("hp", mk power (550 * 0.3048 * 0.45359237 * 9.80665)),
  -- Pressure
  ("atm", mk pressure 101325), ("uatm", mk pressure 0.101325), ("bar", mk pressure (10 ^ 5)),
  ("hPa", mk pressure 100), ("kPa", mk pressure 1000), ("mbar", mk pressure 100),
  ("Torr", mk pressure (101325 / 760)), ("mmHg", mk pressure 133.322387415),
  ("inHg", mk pressure 3386.388640341),
  ("psi", mk pressure (0.45359237 * 9.80665 / 0.0254 ^ 2)),
  -- Energy
  ("erg", mk energy (1 / 10 ^ 7)), ("BTU", mk energy 1055.05585262),
  ("Wh", mk energy 3600), ("kWh", mk energy (36 * 10 ^ 5)),
  -- Electromagnetic
  ("C", mk charge 1), ("V", mk voltage 1), ("Ohm", mk resistance 1),
  ("F", mk capacitance 1), ("T", mk fluxDensity 1),
  -- Temperature / angle
  ("degC", mk temp 1), ("degF", mk temp (5 / 9)), ("deg", mkPi angle (1 / 180) 1),
  -- Solid angle
  ("sr", mk solidAngle 1),
  -- Mixing ratios (dimensionless)
  ("ppm", mk dimless (1 / 10 ^ 6)), ("ppb", mk dimless (1 / 10 ^ 9)), ("ppt", mk dimless (1 / 10 ^ 12)),
  ("ppmv", mk dimless (1 / 10 ^ 6)), ("ppbv", mk dimless (1 / 10 ^ 9)), ("pptv", mk dimless (1 / 10 ^ 12)),
  -- Fractions (dimensionless)
  ("%", mk dimless (1 / 100)), ("psu", mk dimless 1),
  -- Counts (dimensionless)
  ("molec", mk dimless 1), ("molecule", mk dimless 1), ("individuals", mk dimless 1),
  ("vehicles", mk dimless 1), ("units", mk dimless 1), ("count", mk dimless 1),
  -- Column amount
  ("Dobson", mk column 2.6867e20), ("DU", mk column 2.6867e20),
  -- Long-form aliases
  ("meter", mk len 1), ("meters", mk len 1), ("hour", mk time 3600),
  ("Celsius", mk temp 1), ("percent", mk dimless (1 / 100)),
  ("degree", mkPi angle (1 / 180) 1), ("degrees", mkPi angle (1 / 180) 1),
  -- Dimensionless spellings
  ("", mk dimless 1), ("1", mk dimless 1), ("dimensionless", mk dimless 1)
]

/-- The table's keys. -/
def keys : List String := table.map Prod.fst

/-- Look a symbol up, exactly as spelled. -/
def lookup (s : String) : Option U := table.lookup s

/-- The table entry for a key (dimensionless 1 for a non-key; used only on keys). -/
def sym (s : String) : U := (lookup s).getD U.one

theorem lookup_isSome_iff_aux (l : List (String × U)) (s : String) :
    (l.lookup s).isSome ↔ s ∈ l.map Prod.fst := by
  induction l with
  | nil => simp
  | cons x t ih =>
    obtain ⟨k, u⟩ := x
    by_cases h : s = k
    · subst h; simp [List.lookup]
    · have : (s == k) = false := by simpa using h
      simp [List.lookup, this, ih, h]

/-- The table is flat: a symbol resolves iff it is a key exactly as spelled. -/
theorem lookup_isSome_iff (s : String) : (lookup s).isSome ↔ s ∈ keys :=
  lookup_isSome_iff_aux table s

end Esm.Units
