import Esm.Units.Typeset

/-!
# Closed examples of the canonical unit spelling

Tests, not properties: the theorems quantifying over all inputs are in
`Esm.Units.Canonical` and `Esm.Units.Typeset`. Each example is checked by the kernel.
-/

namespace Esm.Units.CanonicalExamples

open Esm.Units

/-- The normalized factor list of a unit string (empty when it does not parse). -/
def factorsOf (s : String) : List Factor :=
  match parseChars s.toList with
  | .ok e => norm e.factors
  | .error _ => []

/-! ## Spellings that canonicalize alike -/

example : canon "m*h/(mi*s)" = "h*m/(mi*s)" := by decide +kernel
example : canon "m h/(mi s)" = "h*m/(mi*s)" := by decide +kernel
example : canon "m·h/(mi·s)" = "h*m/(mi*s)" := by decide +kernel
example : canon "J/mol/K" = "J/(K*mol)" := by decide +kernel
example : canon "J/(mol*K)" = "J/(K*mol)" := by decide +kernel
example : canon "kg*m^2/s^2" = "kg*m^2/s^2" := by decide +kernel
example : canon "kg * m / s ^ 2" = "kg*m/s^2" := by decide +kernel
example : canon "molec/cm^3" = "molec/cm^3" := by decide +kernel
example : canon "cm^3 molec^-1 s^-1" = "cm^3/(molec*s)" := by decide +kernel
example : canon "cm^3/molec/s" = "cm^3/(molec*s)" := by decide +kernel

/-! ## Rational exponents, `%`, kept symbols -/

example : canon "(m/s)^(-1/3)" = "s^(1/3)/m^(1/3)" := by decide +kernel
example : canon "1/s^0.5" = "1/s^(1/2)" := by decide +kernel
example : canon "m^(4/2)" = "m^2" := by decide +kernel
example : canon "%" = "%" := by decide +kernel
example : canon "%/h" = "%/h" := by decide +kernel
example : canon "ppm" = "ppm" := by decide +kernel
example : canon "km/h" = "km/h" := by decide +kernel
example : canon "µg/m³" = "ug/m^3" := by decide +kernel

/-! ## The dimensionless spellings, cancellation, and unparseable strings -/

example : canon "" = "1" := by decide +kernel
example : canon "1" = "1" := by decide +kernel
example : canon "dimensionless" = "1" := by decide +kernel
example : canon "dimensionless/s" = "1/s" := by decide +kernel
example : canon "mol/mol" = "1" := by decide +kernel
example : canon "g/hp-hr" = "g/hp-hr" := by decide +kernel
example : canon "1000/s" = "1000/s" := by decide +kernel
example : canon " " = " " := by decide +kernel

/-! ## Typeset forms -/

example : latex (factorsOf "J/mol/K") = "\\mathrm{J/(K\\,mol)}" := by decide +kernel
example : latex (factorsOf "kg*m^2/s^2") = "\\mathrm{kg\\,m^{2}/s^{2}}" := by decide +kernel
example : latex (factorsOf "(m/s)^(-1/3)") = "\\mathrm{s^{1/3}/m^{1/3}}" := by decide +kernel
example : latex (factorsOf "short_ton/yr") = "\\mathrm{short\\_ton/yr}" := by decide +kernel
example : latex (factorsOf "%/h") = "\\mathrm{\\%/h}" := by decide +kernel
example : latex (factorsOf "1/s") = "\\mathrm{1/s}" := by decide +kernel
example : typst (factorsOf "cm^3 molec^-1 s^-1") =
    "upright(\"cm\")^3 thin upright(\"molec\")^(-1) thin upright(\"s\")^(-1)" := by decide +kernel
example : typst (factorsOf "molec/cm^3") = "upright(\"molec\") thin upright(\"cm\")^(-3)" := by
  decide +kernel
example : typst (factorsOf "(m/s)^(-1/3)") = "upright(\"s\")^(1\\/3) thin upright(\"m\")^(-1\\/3)" := by
  decide +kernel
example : typst (factorsOf "ppm") = "upright(\"ppm\")" := by decide +kernel
example : typst (factorsOf "") = "1" := by decide +kernel
example : parseTypst "upright(\"m\") thin upright(\"s\")^(-1)" = some (factorsOf "m/s") := by
  decide +kernel
example : parseLatex "\\mathrm{m/s}" = some (factorsOf "m/s") := by decide +kernel

end Esm.Units.CanonicalExamples
