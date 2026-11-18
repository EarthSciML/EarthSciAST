//! Expressions as JSON values, and the symbol table.
//!
//! Port of `formal/Esm/Document/Math/Expr.lean`. An expression is the JSON value
//! at an expression position (spec §4.1): a number, a name (dot-separated
//! identifier segments), or a node (`op`, `args` and any other fields).
//! [`is_e`] is the well-formedness check; [`Sym`] is what a document declares.
//!
//! Not ported: `Math.joinDots`. No executable path uses it; only the Lean
//! proofs do.

use crate::document::json::{JNum, Json, dec_int, in_int64, keys_distinct};

// ## Characters (`Math.isLetter` …): ASCII only.

/// `Math.isLetter`.
pub fn is_letter(c: char) -> bool {
    c.is_ascii_alphabetic()
}
/// `Math.isUpper`.
pub fn is_upper(c: char) -> bool {
    c.is_ascii_uppercase()
}
/// `Math.isLower`.
pub fn is_lower(c: char) -> bool {
    c.is_ascii_lowercase()
}
/// `Math.isDig`.
pub fn is_dig(c: char) -> bool {
    c.is_ascii_digit()
}
/// `Math.isIdStart`.
pub fn is_id_start(c: char) -> bool {
    is_letter(c) || c == '_'
}
/// `Math.isIdChar`.
pub fn is_id_char(c: char) -> bool {
    is_letter(c) || is_dig(c) || c == '_'
}

// ## Names

/// `Math.splitDots`: split at every `.` (an empty input is one empty segment).
pub fn split_dots(cs: &[char]) -> Vec<Vec<char>> {
    cs.split(|&c| c == '.').map(|s| s.to_vec()).collect()
}

/// `Math.segOK`: an identifier segment `[A-Za-z_][A-Za-z0-9_]*`.
pub fn seg_ok(cs: &[char]) -> bool {
    match cs {
        [] => false,
        [c, r @ ..] => is_id_start(*c) && r.iter().all(|&d| is_id_char(d)),
    }
}

/// `Math.nameOK`: dot-separated identifier segments.
pub fn name_ok(s: &str) -> bool {
    let cs: Vec<char> = s.chars().collect();
    split_dots(&cs).iter().all(|seg| seg_ok(seg))
}

/// `Math.greek`: the Greek letter names that are a LaTeX command and a Typst
/// symbol.
pub const GREEK: &[&str] = &[
    "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa",
    "lambda", "mu", "nu", "xi", "pi", "rho", "sigma", "tau", "upsilon", "phi", "chi", "psi",
    "omega", "Gamma", "Delta", "Theta", "Lambda", "Xi", "Pi", "Sigma", "Upsilon", "Phi", "Psi",
    "Omega",
];

/// `Math.isGreek`.
pub fn is_greek(s: &[char]) -> bool {
    let s: String = s.iter().collect();
    GREEK.contains(&s.as_str())
}

/// `Math.isSingle`: one letter, or a Greek letter name.
pub fn is_single(s: &[char]) -> bool {
    match s {
        [c] => is_letter(*c),
        _ => is_greek(s),
    }
}

/// `Math.elements`: the element symbols a chemical-formula name is built from.
pub const ELEMENTS: &[&str] = &[
    "H", "He", "Li", "Be", "B", "C", "N", "O", "F", "Ne", "Na", "Mg", "Al", "Si", "P", "S", "Cl",
    "Ar", "K", "Ca", "Ti", "Cr", "Mn", "Fe", "Co", "Ni", "Cu", "Zn", "Br", "Kr", "Ag", "Sn", "I",
    "Xe", "Hg", "Pb", "Rn",
];

/// `Math.digRun`: the maximal run of digits at the front.
pub fn dig_run(cs: &[char]) -> (&[char], &[char]) {
    let n = cs.iter().take_while(|&&c| is_dig(c)).count();
    cs.split_at(n)
}

/// `Math.letRun`: the maximal run of letters at the front.
pub fn let_run(cs: &[char]) -> (&[char], &[char]) {
    let n = cs.iter().take_while(|&&c| is_letter(c)).count();
    cs.split_at(n)
}

/// `Math.pieces`: a run of letters and the run of digits after it, repeatedly.
/// `CH2O` is `[("CH", "2"), ("O", "")]`.
pub fn pieces(s: &[char]) -> Vec<(Vec<char>, Vec<char>)> {
    let mut out = Vec::new();
    let mut cs = s;
    for _ in 0..s.len() {
        if cs.is_empty() {
            break;
        }
        let (a, r) = let_run(cs);
        let (b, r) = dig_run(r);
        if a.is_empty() {
            break;
        }
        out.push((a.to_vec(), b.to_vec()));
        cs = r;
    }
    out
}

/// `Math.elemToks`: an uppercase letter, then an optional lowercase one,
/// greedily.
pub fn elem_toks(cs: &[char]) -> Option<Vec<String>> {
    let mut out = Vec::new();
    let mut cs = cs;
    loop {
        match cs {
            [] => return Some(out),
            [c, d, r @ ..] => {
                if is_upper(*c) && is_lower(*d) {
                    out.push([*c, *d].iter().collect());
                    cs = r;
                } else if is_upper(*c) {
                    out.push(c.to_string());
                    cs = &cs[1..];
                } else {
                    return None;
                }
            }
            [c] => {
                if is_upper(*c) {
                    out.push(c.to_string());
                    return Some(out);
                }
                return None;
            }
        }
    }
}

/// `Math.isFormula`: letters and digits only, read as element symbols and
/// counts, starting with an element, with at least two tokens.
pub fn is_formula(s: &[char]) -> bool {
    if !s.iter().all(|&c| is_letter(c) || is_dig(c)) {
        return false;
    }
    if !matches!(s.first(), Some(&c) if is_upper(c)) {
        return false;
    }
    let ps = pieces(s);
    let flat: Vec<char> = ps
        .iter()
        .flat_map(|(a, b)| a.iter().chain(b).copied())
        .collect();
    if flat != s {
        return false;
    }
    let all_elems = ps.iter().all(|(a, _)| match elem_toks(a) {
        Some(ts) => ts.iter().all(|t| ELEMENTS.contains(&t.as_str())),
        None => false,
    });
    if !all_elems {
        return false;
    }
    let count: usize = ps
        .iter()
        .map(|(a, b)| elem_toks(a).map_or(0, |ts| ts.len()) + usize::from(!b.is_empty()))
        .sum();
    2 <= count
}

/// `Math.subParts`: the subscripted shape `b_r` (a single letter or Greek name,
/// `_`, a nonempty rest). Returns the base and the rest.
pub fn sub_parts(s: &[char]) -> Option<(Vec<char>, Vec<char>)> {
    let i = s.iter().position(|&c| c == '_')?;
    let (b, rest) = (&s[..i], &s[i + 1..]);
    if is_single(b) && !rest.is_empty() {
        Some((b.to_vec(), rest.to_vec()))
    } else {
        None
    }
}

// ## Numbers and JSON well-formedness, as checks

/// `Math.int64OK`.
pub fn int64_ok(z: i128) -> bool {
    in_int64(z)
}

/// `Math.numOK`: `JNum.WF` as a check.
pub fn num_ok(n: &JNum) -> bool {
    match n {
        JNum::Int(z) => int64_ok(*z),
        JNum::Dec { neg, digits, e10 } => {
            !digits.is_empty()
                && digits.iter().all(|&d| d < 10)
                && digits.first() != Some(&0)
                && digits.last() != Some(&0)
                && match dec_int(*neg, digits, *e10) {
                    Some(Some(z)) => !int64_ok(z),
                    _ => true,
                }
        }
    }
}

/// `Math.keysSorted`: object keys strictly increasing.
pub fn keys_sorted(kvs: &[(String, Json)]) -> bool {
    kvs.windows(2).all(|w| w[0].0 < w[1].0)
}

/// `Math.jwf`: `Json.WF` as a check.
pub fn jwf(j: &Json) -> bool {
    match j {
        Json::Num(n) => num_ok(n),
        Json::Arr(xs) => xs.iter().all(jwf),
        Json::Obj(kvs) => keys_distinct(kvs) && kvs.iter().all(|(_, v)| jwf(v)),
        _ => true,
    }
}

// ## Operators

/// `Math.removedOps`: spec §4.2 "Removed ops", refused by name.
pub const REMOVED_OPS: &[&str] = &[
    "arrayop",
    "aggregate",
    "fn",
    "table_lookup",
    "skolem",
    "rank",
    "argmin",
    "argmax",
    "polygon_intersection_area",
    "intersect_polygon",
    "grad",
    "div",
    "laplacian",
];

/// `Math.deprecatedOps`: read in the call form and rewritten, never printed.
pub fn is_deprecated_op(o: &str) -> bool {
    crate::op_registry::deprecated_op(o).is_some()
}

/// `Math.opOK`: `[A-Za-z_][A-Za-z0-9_.]*` or `[-+*/^<>=!]+`.
pub fn op_ok(s: &str) -> bool {
    let cs: Vec<char> = s.chars().collect();
    match cs.as_slice() {
        [] => false,
        [c, r @ ..] => {
            (is_id_start(*c) && r.iter().all(|&d| is_id_char(d) || d == '.'))
                || cs.iter().all(|d| "-+*/^<>=!".contains(*d))
        }
    }
}

/// `Math.look`: the value of key `k`.
pub fn look<'a>(k: &str, kvs: &'a [(String, Json)]) -> Option<&'a Json> {
    kvs.iter().find(|(k2, _)| k2 == k).map(|(_, v)| v)
}

/// `Math.opFieldOK`: an `op` that is neither removed nor deprecated.
pub fn op_field_ok(kvs: &[(String, Json)]) -> bool {
    match look("op", kvs) {
        Some(Json::Str(o)) => {
            op_ok(o) && !REMOVED_OPS.contains(&o.as_str()) && !is_deprecated_op(o)
        }
        _ => false,
    }
}

/// `Math.hasArgs`.
pub fn has_args(kvs: &[(String, Json)]) -> bool {
    look("args", kvs).is_some()
}

/// `Math.isE`: a well-formed expression (canonical form).
pub fn is_e(e: &Json) -> bool {
    match e {
        Json::Num(n) => num_ok(n),
        Json::Str(s) => name_ok(s),
        Json::Obj(kvs) => {
            keys_sorted(kvs)
                && op_field_ok(kvs)
                && has_args(kvs)
                && kvs.iter().all(|(k, v)| {
                    if k == "args" {
                        match v {
                            Json::Arr(xs) => xs.iter().all(is_e),
                            _ => false,
                        }
                    } else {
                        k == "op" || jwf(v)
                    }
                })
        }
        _ => false,
    }
}

/// `Math.Sym`: the names a document declares and the parameter list of every
/// template in scope.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Sym {
    pub names: Vec<String>,
    pub templates: Vec<(String, Vec<String>)>,
}
