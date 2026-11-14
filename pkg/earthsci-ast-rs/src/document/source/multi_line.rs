//! Multi-line equations (accepted input variants): rows split at top-level
//! line breaks, cells at the first top-level `&`.
//!
//! Port of `formal/Esm/Document/Source/MultiLine.lean`. The reader works on
//! the math tokens, so rows and cells are found by token and depth.

use super::equation::eq_sides;
use super::skeleton::Eqn;
use crate::document::math::token::{Kw, Sf, Tok};
use crate::document::math::{Sym, parse_toks};

/// `Source.delta`: how a token changes the delimiter depth.
pub fn delta(t: &Tok) -> i64 {
    match t {
        Tok::Kw(Kw::Lp | Kw::Lpg | Kw::Lb | Kw::Lbk | Kw::Bcases | Kw::Bmat | Kw::Lbkg) => 1,
        Tok::Kw(Kw::Rp | Kw::Rpg | Kw::Rb | Kw::Rbk | Kw::Ecases | Kw::Emat | Kw::Rbkg) => -1,
        _ => 0,
    }
}

/// `Source.isKw`.
pub fn is_kw(k: Kw, t: &Tok) -> bool {
    matches!(t, Tok::Kw(k2) if *k2 == k)
}

/// `Source.cut`: cut at the first `k` at depth 0 (starting at depth `d`).
pub fn cut(k: Kw, mut d: i64, ts: &[Tok]) -> (&[Tok], Option<&[Tok]>) {
    for (i, t) in ts.iter().enumerate() {
        if d == 0 && is_kw(k, t) {
            return (&ts[..i], Some(&ts[i + 1..]));
        }
        d += delta(t);
    }
    (ts, None)
}

/// `Source.noTop`.
#[allow(dead_code)] // only the Lean proofs use it
pub fn no_top(k: Kw, mut d: i64, ts: &[Tok]) -> bool {
    for t in ts {
        if d == 0 && is_kw(k, t) {
            return false;
        }
        d += delta(t);
    }
    d == 0
}

/// `Source.splitAll`: split at every top-level `k`. (Fuel dropped: callers
/// give the token count, and every split consumes a token.)
pub fn split_all(k: Kw, mut ts: &[Tok]) -> Vec<Vec<Tok>> {
    let mut out = Vec::new();
    loop {
        match cut(k, 0, ts) {
            (a, Some(r)) => {
                out.push(a.to_vec());
                ts = r;
            }
            (_, None) => {
                out.push(ts.to_vec());
                return out;
            }
        }
    }
}

/// `Source.group`: rows into equations (`one`: all rows are one equation).
pub fn group(one: bool, rows: Vec<Vec<Tok>>) -> Option<Vec<Vec<Tok>>> {
    // `acc` is kept in reading order; Lean's head is our last element.
    let mut acc: Vec<Vec<Tok>> = Vec::new();
    for row in rows {
        match cut(Kw::Amp, 0, &row) {
            (l, None) => {
                if l.is_empty() {
                    continue;
                }
                if one {
                    match acc.last_mut() {
                        None => acc.push(l.to_vec()),
                        Some(cur) => cur.extend_from_slice(l),
                    }
                } else {
                    acc.push(l.to_vec());
                }
            }
            (l, Some(r)) => {
                if cut(Kw::Amp, 0, r).1.is_some() {
                    return None;
                }
                if l.is_empty() && !one {
                    match (acc.last_mut(), r) {
                        (None, _) => return None,
                        (_, [Tok::Kw(Kw::Eq), ..]) => return None,
                        (Some(cur), _) => cur.extend_from_slice(r),
                    }
                } else if one {
                    match acc.last_mut() {
                        None => {
                            let mut v = l.to_vec();
                            v.extend_from_slice(r);
                            acc.push(v);
                        }
                        Some(cur) => {
                            cur.extend_from_slice(l);
                            cur.extend_from_slice(r);
                        }
                    }
                } else {
                    let mut v = l.to_vec();
                    v.extend_from_slice(r);
                    acc.push(v);
                }
            }
        }
    }
    Some(acc)
}

/// `Source.cookRows`: read the rows of a multi-line display into equations.
pub fn cook_rows(sf: Sf, s: &Sym, one: bool, ts: &[Tok]) -> Option<Vec<Eqn>> {
    let eqs = group(one, split_all(Kw::Nl, ts))?;
    eqs.iter()
        .map(|t| {
            parse_toks(sf, s, t).and_then(eq_sides).map(|(l, r)| Eqn {
                comment: None,
                lhs: l,
                rhs: r,
            })
        })
        .collect()
}

/// `Source.joinRows`.
#[allow(dead_code)] // only the Lean proofs use it
pub fn join_rows(rows: &[Vec<Tok>]) -> Vec<Tok> {
    let mut out = Vec::new();
    for (i, r) in rows.iter().enumerate() {
        if i > 0 {
            out.push(Tok::Kw(Kw::Nl));
        }
        out.extend(r.iter().cloned());
    }
    out
}
