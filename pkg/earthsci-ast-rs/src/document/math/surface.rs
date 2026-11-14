//! Pieces the LaTeX and Typst spellings share: literal prefixes, binary
//! operator tokens, and the reading of numbers (a JSON spelling, or a
//! scientific literal `mantissa × 10^exponent` whose tail each surface reads
//! with its own `sciExp`).
//!
//! Port of `formal/Esm/Document/Math/Surface.lean`.

use super::token::{Kw, Tok};
use crate::document::json::JNum;
use crate::document::number;

/// `Math.dropP`: strip a literal prefix.
pub fn drop_p<'a>(p: &[char], cs: &'a [char]) -> Option<&'a [char]> {
    cs.strip_prefix(p)
}

/// `Math.isBin`: the binary operator tokens.
pub fn is_bin(t: &Tok) -> bool {
    matches!(
        t,
        Tok::Kw(
            Kw::Plus
                | Kw::Eq
                | Kw::Ne
                | Kw::Lt
                | Kw::Gt
                | Kw::Le
                | Kw::Ge
                | Kw::Land
                | Kw::Lor
                | Kw::Cdot
                | Kw::Times
                | Kw::Amp
                | Kw::Nl
                | Kw::Inn
        )
    )
}

/// `Math.sciSplit`: the mantissa (with its sign) and exponent of a number
/// printed in scientific notation.
pub fn sci_split(n: &JNum) -> Option<(Vec<char>, i64)> {
    match n {
        JNum::Dec { neg, digits, e10 } => match digits.as_slice() {
            [d, fp @ ..] if *e10 < -4 || 5 < *e10 => {
                let mut m = if *neg { vec!['-'] } else { vec![] };
                m.push(number::digit_char(*d));
                m.push('.');
                m.extend(number::frac_digits(fp).into_iter().map(number::digit_char));
                Some((m, *e10))
            }
            _ => None,
        },
        _ => None,
    }
}

/// `Math.negNum`: a number below zero.
pub fn neg_num(n: &JNum) -> bool {
    match n {
        JNum::Int(z) => *z < 0,
        JNum::Dec { neg, .. } => *neg,
    }
}

/// `Math.sciNum`: the value of a mantissa times `10^z`, in canonical form.
///
/// Lean's exponents are unbounded; a decimal exponent outside `i64` gives
/// `None` here (Lean would build that decimal), which no document writes.
pub fn sci_num(n0: &JNum, z: i128) -> Option<JNum> {
    let m = match n0 {
        JNum::Dec { neg, digits, e10 } => {
            let e = i64::try_from((*e10 as i128).checked_add(z)?).ok()?;
            number::canonize(JNum::Dec {
                neg: *neg,
                digits: digits.clone(),
                e10: e,
            })
        }
        JNum::Int(i) => {
            let ds = number::nat_digits(i.unsigned_abs());
            let e = i64::try_from((ds.len() as i128 - 1).checked_add(z)?).ok()?;
            number::canonize(number::mk_dec(*i < 0, &ds, e))
        }
    };
    if m.wfb() { Some(m) } else { None }
}

/// `Math.lexNum`: a number: its JSON spelling, or a decimal mantissa followed
/// by a scientific tail that `sci_exp` reads.
pub fn lex_num<'a>(
    sci_exp: impl Fn(&'a [char]) -> Option<(i128, &'a [char])>,
    cs: &'a [char],
) -> Option<(Tok, &'a [char])> {
    let (n0, r) = number::parse_raw(cs)?;
    let plain = || number::parse(cs).map(|(n, r)| (Tok::Num(n), r));
    match sci_exp(r) {
        Some((z, r3)) => match sci_num(&n0, z) {
            Some(m) => Some((Tok::Num(m), r3)),
            None => plain(),
        },
        None => plain(),
    }
}

/// `Math.lexSigned`: a number where `-` starts it only when the value is below
/// zero (otherwise the `-` is a minus sign of its own).
pub fn lex_signed<'a>(
    sci_exp: impl Fn(&'a [char]) -> Option<(i128, &'a [char])>,
    cs: &'a [char],
) -> Option<(Tok, &'a [char])> {
    match cs {
        ['-', r @ ..] => match lex_num(sci_exp, cs) {
            Some((Tok::Num(m), r2)) => {
                if neg_num(&m) {
                    Some((Tok::Num(m), r2))
                } else {
                    Some((Tok::Kw(Kw::Minus), r))
                }
            }
            _ => None,
        },
        _ => lex_num(sci_exp, cs),
    }
}
