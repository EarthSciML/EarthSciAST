//! Typeset unit spellings: LaTeX and Typst, with no unit package.
//!
//! Port of `formal/Esm/Units/Typeset.lean`.

use num_rational::BigRational;

/// `Esm.Units.Factor`: a unit symbol and its (signed, rational) exponent.
pub type Factor = (String, BigRational);
