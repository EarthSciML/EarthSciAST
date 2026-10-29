import Esm.Units.GrammarLaws

/-! Concrete checks of the §4.8.2 grammar on the spec's own example strings
(tests, not properties: the kernel evaluates normalisation, lexing and parsing). -/

namespace Esm.Units.Examples

open Esm.Units

/-- Normalise, lex and parse (no table lookup). -/
def parseChars (cs : List Char) : Except Err UExpr := lex (normalize cs) >>= parse

-- `*` and `/` are one level, left to right
example : parseChars "J/mol*K".toList = .ok (.mul (.div (.sym "J") (.sym "mol")) (.sym "K")) := by
  decide +kernel
example : parseChars "kg/m*s".toList = .ok (.mul (.div (.sym "kg") (.sym "m")) (.sym "s")) := by
  decide +kernel
example : parseChars "L/mol/s".toList = .ok (.div (.div (.sym "L") (.sym "mol")) (.sym "s")) := by
  decide +kernel
-- parentheses for a compound denominator
example : parseChars "J/(mol*K)".toList =
    .ok (.div (.sym "J") (.mul (.sym "mol") (.sym "K"))) := by decide +kernel
-- whitespace is multiplication
example : parseChars "ppb^-1 s^-1".toList =
    .ok (.mul (.pow (.sym "ppb") (-1)) (.pow (.sym "s") (-1))) := by decide +kernel
-- the leading 1, and decimal and rational exponents
example : parseChars "1/s^0.5".toList = .ok (.div .one (.pow (.sym "s") (1 / 2))) := by
  decide +kernel
example : parseChars "(m/s)^(-1/3)".toList =
    .ok (.pow (.div (.sym "m") (.sym "s")) (-1 / 3)) := by decide +kernel
-- scaling factors
example : parseChars "(m/s)^-1/3".toList = .error (.scalingFactor "3") := by decide +kernel
example : parseChars "1000/s".toList = .error (.scalingFactor "1000") := by decide +kernel
example : parseChars "0.5 m".toList = .error (.scalingFactor "0.5") := by decide +kernel
-- a digit run joined to a symbol is a different symbol
example : parseChars "cm3".toList = .ok (.sym "cm3") := by decide +kernel
example : parseChars "m/s2".toList = .ok (.div (.sym "m") (.sym "s2")) := by decide +kernel
-- `%` is a symbol token
example : parseChars "%/h".toList = .ok (.div (.sym "%") (.sym "h")) := by decide +kernel
-- Unicode normalisation
example : parseChars "W/m²".toList = .ok (.div (.sym "W") (.pow (.sym "m") 2)) := by
  decide +kernel
example : parseChars "s⁻¹".toList = .ok (.pow (.sym "s") (-1)) := by decide +kernel
example : parseChars "J/(kg·K)".toList =
    .ok (.div (.sym "J") (.mul (.sym "kg") (.sym "K"))) := by decide +kernel
example : parseChars "kg⋅m/s".toList = .ok (.div (.mul (.sym "kg") (.sym "m")) (.sym "s")) := by
  decide +kernel
example : parseChars "µg/m^3".toList = .ok (.div (.sym "ug") (.pow (.sym "m") 3)) := by
  decide +kernel
example : parseChars "μg/m^3".toList = .ok (.div (.sym "ug") (.pow (.sym "m") 3)) := by
  decide +kernel
example : parseChars "°C/min".toList = .ok (.div (.sym "degC") (.sym "min")) := by
  decide +kernel
example : parseChars "Ω*m".toList = .ok (.mul (.sym "Ohm") (.sym "m")) := by decide +kernel
example : parseChars "\u2126*m".toList = .ok (.mul (.sym "Ohm") (.sym "m")) := by decide +kernel

end Esm.Units.Examples
