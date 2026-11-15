//! Reaction sides, shared by the containers.
//!
//! Port of `formal/Esm/Document/Source/Reaction.lean`. A side is the empty-set
//! symbol as math for an empty side, otherwise its terms separated by ` + `; a
//! term is its coefficient as math and a space (left out when it is 1), then
//! the species, bare when formula-shaped and otherwise its name as math under
//! the empty symbol table.

use super::skeleton::Term;
use super::text::{pre, take_while};
use crate::document::json::{JNum, Json};
use crate::document::math::expr::{is_dig, is_formula, is_letter, name_ok, num_ok};
use crate::document::strings::is_ident_char;

/// `Source.RSurf`: how a math piece prints and reads back (under the empty
/// symbol table), and the content of the empty-set piece.
pub struct RSurf {
    pub pm: fn(&str) -> Option<Json>,
    pub prm: fn(&Json) -> Vec<char>,
    pub empty: &'static [char],
}

/// `Source.isAlnumC`.
pub fn is_alnum_c(c: char) -> bool {
    is_letter(c) || is_dig(c)
}

/// `Source.speciesTxt`.
pub fn species_txt(r: &RSurf, n: &str, out: &mut Vec<char>) {
    let cs: Vec<char> = n.chars().collect();
    if is_formula(&cs) {
        out.extend(cs);
    } else {
        out.push('$');
        out.extend((r.prm)(&Json::str(n)));
        out.push('$');
    }
}

/// `Source.termTxt`.
pub fn term_txt(r: &RSurf, t: &Term, out: &mut Vec<char>) {
    if t.coef != JNum::Int(1) {
        out.push('$');
        out.extend((r.prm)(&Json::Num(t.coef.clone())));
        out.extend(['$', ' ']);
    }
    species_txt(r, &t.species, out);
}

/// `Source.termsTxt`.
pub fn terms_txt(r: &RSurf, ts: &[Term], out: &mut Vec<char>) {
    for (i, t) in ts.iter().enumerate() {
        if i > 0 {
            out.extend([' ', '+', ' ']);
        }
        term_txt(r, t, out);
    }
}

/// `Source.sideTxt`.
pub fn side_txt(r: &RSurf, s: &Option<Vec<Term>>) -> Vec<char> {
    let mut out = Vec::new();
    match s {
        None => {
            out.push('$');
            out.extend_from_slice(r.empty);
            out.push('$');
        }
        Some(ts) => terms_txt(r, ts, &mut out),
    }
    out
}

/// `Source.termOK`.
pub fn term_ok(r: &RSurf, t: &Term) -> bool {
    let sp: Vec<char> = t.species.chars().collect();
    let ps = (r.prm)(&Json::str(t.species.clone()));
    name_ok(&t.species)
        && (is_formula(&sp) || (!ps.contains(&'$') && ps != r.empty))
        && (t.coef == JNum::Int(1) || {
            let pc = (r.prm)(&Json::Num(t.coef.clone()));
            num_ok(&t.coef) && !pc.contains(&'$') && pc != r.empty
        })
}

/// `Source.sideLen`.
#[allow(dead_code)] // only the Lean proofs use it
pub fn side_len(s: &Option<Vec<Term>>) -> usize {
    s.as_ref().map_or(0, Vec::len)
}

/// `Source.sideOK`.
pub fn side_ok(r: &RSurf, s: &Option<Vec<Term>>) -> bool {
    match s {
        None => true,
        Some(ts) => !ts.is_empty() && ts.iter().all(|t| term_ok(r, t)),
    }
}

/// `Source.after`: the text after the prefix `p`, when it is one.
pub fn after<'a>(p: &[char], s: &'a [char]) -> Option<&'a [char]> {
    if pre(p, s) { Some(&s[p.len()..]) } else { None }
}

/// `Source.idChar`.
pub fn id_char(c: char) -> bool {
    is_ident_char(c) || c == '-' || c == '.' || c == ':'
}

/// `Source.idOK`: a reaction id the containers spell as a label.
pub fn id_ok(i: &str) -> bool {
    !i.is_empty() && i.chars().all(id_char)
}

/// `Source.pPiece`: the text up to the next `$`, and the text after it.
pub fn p_piece(t: &[char]) -> Option<(&[char], &[char])> {
    match take_while(t, |c| c != '$') {
        (p, ['$', r @ ..]) => Some((p, r)),
        _ => None,
    }
}

fn s_of(cs: &[char]) -> String {
    cs.iter().collect()
}

/// `Source.pSpecies`: a math piece holding a name, or a bare run of letters
/// and digits.
pub fn p_species<'a>(r: &RSurf, s: &'a [char]) -> Option<(String, &'a [char])> {
    match s {
        ['$', t @ ..] => {
            let (p, rest) = p_piece(t)?;
            match (r.pm)(&s_of(p)) {
                Some(Json::Str(n)) => Some((n, rest)),
                _ => None,
            }
        }
        _ => {
            let (a, rest) = take_while(s, is_alnum_c);
            if a.is_empty() {
                None
            } else {
                Some((s_of(a), rest))
            }
        }
    }
}

/// `Source.pTerm`.
pub fn p_term<'a>(r: &RSurf, s: &'a [char]) -> Option<(Term, &'a [char])> {
    match s {
        ['$', t @ ..] => {
            let (p, rest) = p_piece(t)?;
            match (r.pm)(&s_of(p)) {
                Some(Json::Num(c)) => match rest {
                    [' ', r2 @ ..] => p_species(r, r2).map(|(n, r3)| {
                        (
                            Term {
                                species: n,
                                coef: c,
                            },
                            r3,
                        )
                    }),
                    _ => None,
                },
                Some(Json::Str(n)) => Some((
                    Term {
                        species: n,
                        coef: JNum::Int(1),
                    },
                    rest,
                )),
                _ => None,
            }
        }
        _ => p_species(r, s).map(|(n, r2)| {
            (
                Term {
                    species: n,
                    coef: JNum::Int(1),
                },
                r2,
            )
        }),
    }
}

/// `Source.pTerms`: terms separated by ` + `. (Fuel dropped: every term
/// consumes characters.)
pub fn p_terms<'a>(r: &RSurf, mut s: &'a [char]) -> Option<(Vec<Term>, &'a [char])> {
    let mut out = Vec::new();
    loop {
        let (t, rest) = p_term(r, s)?;
        out.push(t);
        if pre(&[' ', '+', ' '], rest) {
            s = &rest[3..];
        } else {
            return Some((out, rest));
        }
    }
}

/// `Source.pSide`: the empty-set piece, or terms.
pub fn p_side<'a>(r: &RSurf, s: &'a [char]) -> Option<(Option<Vec<Term>>, &'a [char])> {
    match s {
        ['$', t @ ..] => {
            let (p, rest) = p_piece(t)?;
            if p == r.empty {
                Some((None, rest))
            } else {
                p_terms(r, s).map(|(ts, r2)| (Some(ts), r2))
            }
        }
        _ => p_terms(r, s).map(|(ts, r2)| (Some(ts), r2)),
    }
}
