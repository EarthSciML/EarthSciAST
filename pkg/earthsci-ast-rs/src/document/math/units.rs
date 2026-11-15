//! Typeset unit spellings: LaTeX and Typst, with no unit package.
//!
//! Port of `formal/Esm/Units/Typeset.lean`, with the `Esm.Units` helpers it
//! uses (`numFactors`, `denFactors` from Factors.lean, `digs`, `symOK` from
//! Canonical.lean, `isIdent`, `isDigitC` from Grammar.lean).
//!
//! **LaTeX**: the canonical spelling's layout inside `\mathrm{…}`: numerator
//! factors joined by `\,`, a denominator after `/` (parenthesized when it has
//! more than one factor), exponents as braced superscripts, `_` and `%` escaped.
//!
//! **Typst**: one `upright("sym")^(exp)` per factor with its signed exponent,
//! factors separated by ` thin `.
//!
//! The Lean parser `pSepBy` carries fuel equal to the input length, which every
//! caller gives and which is never exhausted (each item consumes a character);
//! the port loops without it.
//!
//! Not ported: `Esm.Units.typst`, `Esm.Units.parseTypst`. No executable path
//! uses them; only the Lean proofs do.

use num_bigint::BigInt;
use num_rational::BigRational;
use num_traits::{One, Signed, Zero};

/// `Esm.Units.Factor`: a unit symbol and its (signed, rational) exponent.
pub type Factor = (String, BigRational);

/// `Esm.Units.isDigitC`.
pub fn is_digit_c(c: char) -> bool {
    c.is_ascii_digit()
}

/// `Esm.Units.isIdent`: characters that may occur in a symbol run.
pub fn is_ident(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '_'
}

/// `Esm.Units.numFactors`: the factors with a positive exponent.
pub fn num_factors(l: &[Factor]) -> Vec<Factor> {
    l.iter().filter(|f| f.1.is_positive()).cloned().collect()
}

/// `Esm.Units.denFactors`: the factors with a nonpositive exponent.
pub fn den_factors(l: &[Factor]) -> Vec<Factor> {
    l.iter().filter(|f| !f.1.is_positive()).cloned().collect()
}

/// `Esm.Units.symRunB` (Canonical.lean).
pub fn sym_run_b(s: &str) -> bool {
    !s.is_empty() && s.chars().all(is_ident) && !s.chars().all(is_digit_c)
}

/// `Esm.Units.symOK` (Canonical.lean): `%`, or a symbol run, and not
/// `dimensionless`.
pub fn sym_ok(s: &str) -> bool {
    (s == "%" || sym_run_b(s)) && s != "dimensionless"
}

/// `Esm.Units.digs`: the decimal digits of `n` (empty for `0`).
pub fn digs(n: &BigInt) -> Vec<char> {
    if n.is_zero() {
        Vec::new()
    } else {
        n.to_string().chars().collect()
    }
}

/// `Esm.Units.pDigits`: a nonempty digit run and its value.
pub fn p_digits(cs: &[char]) -> Option<(BigInt, &[char])> {
    let n = cs.iter().take_while(|&&c| is_digit_c(c)).count();
    if n == 0 {
        return None;
    }
    let mut v = BigInt::zero();
    for &c in &cs[..n] {
        v = v * 10 + BigInt::from(c as u32 - 48);
    }
    Some((v, &cs[n..]))
}

/// `Esm.Units.joinWith`.
pub fn join_with(pr: impl Fn(&Factor) -> Vec<char>, sep: &[char], l: &[Factor]) -> Vec<char> {
    let mut out = Vec::new();
    for (i, f) in l.iter().enumerate() {
        if i > 0 {
            out.extend_from_slice(sep);
        }
        out.extend(pr(f));
    }
    out
}

/// `Esm.Units.pSepBy`: items read by `pf`, separated by `sep` (fuel dropped,
/// see the module doc).
pub fn p_sep_by<'a>(
    pf: impl Fn(&'a [char]) -> Option<(Factor, &'a [char])>,
    sep: &[char],
    cs: &'a [char],
) -> Option<(Vec<Factor>, &'a [char])> {
    let mut out = Vec::new();
    let mut cs = cs;
    loop {
        let (f, r) = pf(cs)?;
        out.push(f);
        match r.strip_prefix(sep) {
            None => return Some((out, r)),
            Some(r2) => cs = r2,
        }
    }
}

/// `p / d` as Lean's rational division (`x / 0 = 0`).
fn ratio(p: BigRational, d: BigInt) -> BigRational {
    if d.is_zero() {
        BigRational::zero()
    } else {
        p / BigRational::from_integer(d)
    }
}

fn rat(p: BigInt) -> BigRational {
    BigRational::from_integer(p)
}

// ## LaTeX

/// `Esm.Units.latexSym`: `_` and `%` escaped with a backslash.
pub fn latex_sym(cs: &[char]) -> Vec<char> {
    let mut out = Vec::new();
    for &c in cs {
        if c == '_' || c == '%' {
            out.push('\\');
        }
        out.push(c);
    }
    out
}

/// `Esm.Units.latexExp`: a positive exponent as a braced superscript (nothing
/// for 1).
pub fn latex_exp(q: &BigRational) -> Vec<char> {
    if q.is_one() {
        return Vec::new();
    }
    let mut out = vec!['^', '{'];
    out.extend(digs(&q.numer().abs()));
    if !q.is_integer() {
        out.push('/');
        out.extend(digs(q.denom()));
    }
    out.push('}');
    out
}

/// `Esm.Units.latexFactor`: one factor, with the absolute value of its exponent.
pub fn latex_factor(f: &Factor) -> Vec<char> {
    let cs: Vec<char> = f.0.chars().collect();
    let mut out = latex_sym(&cs);
    out.extend(latex_exp(&f.1.abs()));
    out
}

/// `Esm.Units.latexSep`.
pub const LATEX_SEP: &[char] = &['\\', ','];

/// `Esm.Units.latexBody`: the body of `\mathrm{…}`.
pub fn latex_body(l: &[Factor]) -> Vec<char> {
    let nf = num_factors(l);
    let mut out = if nf.is_empty() {
        vec!['1']
    } else {
        join_with(latex_factor, LATEX_SEP, &nf)
    };
    let df = den_factors(l);
    match df.as_slice() {
        [] => {}
        [g] => {
            out.push('/');
            out.extend(latex_factor(g));
        }
        den => {
            out.push('/');
            out.push('(');
            out.extend(join_with(latex_factor, LATEX_SEP, den));
            out.push(')');
        }
    }
    out
}

/// `Esm.Units.mathrmOpen`.
pub const MATHRM_OPEN: &[char] = &['\\', 'm', 'a', 't', 'h', 'r', 'm', '{'];

/// `Esm.Units.latex`: the LaTeX form of a canonical factor list.
pub fn latex(l: &[Factor]) -> Vec<char> {
    let mut out = MATHRM_OPEN.to_vec();
    out.extend(latex_body(l));
    out.push('}');
    out
}

/// `Esm.Units.pLSym`: identifier characters, `%`, and the escapes `\_`, `\%`.
pub fn p_l_sym(cs: &[char]) -> (Vec<char>, &[char]) {
    let mut out = Vec::new();
    let mut cs = cs;
    loop {
        match cs {
            [c, r @ ..] if is_ident(*c) || *c == '%' => {
                out.push(*c);
                cs = r;
            }
            ['\\', d, r @ ..] if *d == '_' || *d == '%' => {
                out.push(*d);
                cs = r;
            }
            _ => return (out, cs),
        }
    }
}

/// `Esm.Units.pLExp`: a braced superscript, or nothing (exponent 1).
pub fn p_l_exp(cs: &[char]) -> Option<(BigRational, &[char])> {
    match cs {
        ['^', '{', r @ ..] => match p_digits(r) {
            Some((p, ['}', r2 @ ..])) => Some((rat(p), r2)),
            Some((p, ['/', r2 @ ..])) => match p_digits(r2) {
                Some((d, ['}', r3 @ ..])) => Some((ratio(rat(p), d), r3)),
                _ => None,
            },
            _ => None,
        },
        _ => Some((BigRational::one(), cs)),
    }
}

/// `Esm.Units.pLFactor`.
pub fn p_l_factor(cs: &[char]) -> Option<(Factor, &[char])> {
    let (s, r) = p_l_sym(cs);
    if s.is_empty() {
        return None;
    }
    let (q, r2) = p_l_exp(r)?;
    Some(((s.into_iter().collect(), q), r2))
}

/// `Esm.Units.pLDen`: a LaTeX denominator (after the `/`).
pub fn p_l_den(r: &[char]) -> Option<Vec<Factor>> {
    if r.first() == Some(&'(') {
        match p_sep_by(p_l_factor, LATEX_SEP, &r[1..]) {
            Some((den, [')'])) => Some(den),
            _ => None,
        }
    } else {
        match p_sep_by(p_l_factor, LATEX_SEP, r) {
            Some((den, [])) if den.len() == 1 => Some(den),
            _ => None,
        }
    }
}

/// `Esm.Units.parseLatex`: a LaTeX unit back to its two-sided factor list.
pub fn parse_latex(s: &[char]) -> Option<Vec<Factor>> {
    let body = s.strip_prefix(MATHRM_OPEN)?;
    if body.last() != Some(&'}') {
        return None;
    }
    let b = &body[..body.len() - 1];
    let (num, rest) = p_sep_by(p_l_factor, LATEX_SEP, b)?;
    let num = if num.len() == 1 && num[0].0 == "1" && num[0].1.is_one() {
        Vec::new()
    } else {
        num
    };
    match rest {
        [] => Some(num),
        ['/', r @ ..] => p_l_den(r).map(|den| {
            let mut out = num;
            out.extend(den.into_iter().map(|(s, q)| (s, -q)));
            out
        }),
        _ => None,
    }
}

// ## Typst

/// `Esm.Units.uprightOpen`.
pub const UPRIGHT_OPEN: &[char] = &['u', 'p', 'r', 'i', 'g', 'h', 't', '(', '"'];
/// `Esm.Units.uprightClose`.
pub const UPRIGHT_CLOSE: &[char] = &['"', ')'];
/// `Esm.Units.thinSep`.
pub const THIN_SEP: &[char] = &[' ', 't', 'h', 'i', 'n', ' '];

/// `Esm.Units.typstExp`: a signed exponent: nothing for 1, `^n`, `^(-n)`,
/// `^(p\/q)`, `^(-p\/q)`.
pub fn typst_exp(q: &BigRational) -> Vec<char> {
    if q.is_one() {
        return Vec::new();
    }
    let n = digs(&q.numer().abs());
    if q.is_integer() {
        if q.is_positive() {
            let mut out = vec!['^'];
            out.extend(n);
            out
        } else {
            let mut out = vec!['^', '(', '-'];
            out.extend(n);
            out.push(')');
            out
        }
    } else {
        let mut out = vec!['^', '('];
        if q.is_negative() {
            out.push('-');
        }
        out.extend(n);
        out.extend(['\\', '/']);
        out.extend(digs(q.denom()));
        out.push(')');
        out
    }
}

/// `Esm.Units.typstFactor`: `upright("sym")` and its signed exponent.
pub fn typst_factor(f: &Factor) -> Vec<char> {
    let mut out = UPRIGHT_OPEN.to_vec();
    out.extend(f.0.chars());
    out.extend_from_slice(UPRIGHT_CLOSE);
    out.extend(typst_exp(&f.1));
    out
}

/// `Esm.Units.pTParen`: after `^(`: `'-'? digits (')' | '\/' digits ')')`.
pub fn p_t_paren(cs: &[char]) -> Option<(BigRational, &[char])> {
    let neg = cs.first() == Some(&'-');
    let cs2 = if neg { &cs[1..] } else { cs };
    let (p, r) = p_digits(cs2)?;
    let sp = if neg { -rat(p) } else { rat(p) };
    match r {
        [')', r2 @ ..] => Some((sp, r2)),
        ['\\', '/', r2 @ ..] => match p_digits(r2) {
            Some((d, [')', r3 @ ..])) => Some((ratio(sp, d), r3)),
            _ => None,
        },
        _ => None,
    }
}

/// `Esm.Units.pTExp`: an optional exponent (none means 1).
pub fn p_t_exp(cs: &[char]) -> Option<(BigRational, &[char])> {
    match cs {
        ['^', r @ ..] => match r {
            ['(', r2 @ ..] => p_t_paren(r2),
            [_, ..] => p_digits(r).map(|(p, r2)| (rat(p), r2)),
            [] => None,
        },
        _ => Some((BigRational::one(), cs)),
    }
}

/// `Esm.Units.pTFactor`.
pub fn p_t_factor(cs: &[char]) -> Option<(Factor, &[char])> {
    let r = cs.strip_prefix(UPRIGHT_OPEN)?;
    let n = r.iter().take_while(|&&c| c != '"').count();
    let (sym, rest) = r.split_at(n);
    let r2 = rest.strip_prefix(UPRIGHT_CLOSE)?;
    let (q, r3) = p_t_exp(r2)?;
    Some(((sym.iter().collect(), q), r3))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn f(s: &str, p: i64, q: i64) -> Factor {
        (s.to_string(), BigRational::new(p.into(), q.into()))
    }

    #[test]
    fn latex_and_typst_round_trip() {
        let l = vec![
            f("cm", 3, 1),
            f("short_ton", 1, 3),
            f("K", -1, 1),
            f("mol", -1, 2),
        ];
        let lx: String = latex(&l).into_iter().collect();
        assert_eq!(lx, "\\mathrm{cm^{3}\\,short\\_ton^{1/3}/(K\\,mol^{1/2})}");
        assert_eq!(parse_latex(&latex(&l)), Some(l.clone()));
    }
}
