"""
Typeset unit spellings: LaTeX and Typst, with no unit package.

Port of `formal/Esm/Units/Typeset.lean` (Rust `document::math::units`).
"""
module MUnits

using ..DJson

"""`Esm.Units.Factor`: a unit symbol and its (signed, rational) exponent."""
const Factor = Tuple{String, Rational{BigInt}}

end # module MUnits
