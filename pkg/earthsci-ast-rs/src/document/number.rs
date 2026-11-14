//! The canonical number spelling (CONFORMANCE §5.5.3.1).
//!
//! Port of `formal/Esm/Document/Number.lean` (and `Esm.digitChar` from
//! `formal/Esm/Digits.lean`).
//!
//! * An integer prints plainly, `-` for a negative one.
//! * A decimal prints its digits positionally when its decimal exponent is in
//!   `[-4, 5]`, and otherwise as `d.f…e<exp>` with at least one fraction digit.
//!
//! [`parse`] reads any decimal spelling and returns the canonical number;
//! [`parse_raw`] reads the token as written.
//!
//! Lean's integers are unbounded; here a digit run whose value does not fit in
//! `i128` is not a number token (it has no canonical form either way, since it
//! is outside `Int64`). The only reading that differs is a mantissa of more
//! than 38 digits in a scientific literal, which no document writes.

use super::json::{JNum, dec_int, digits_val, in_int64};

/// `Esm.digitChar`.
pub fn digit_char(d: u8) -> char {
    char::from(b'0' + d)
}

/// `Number.charDigit`.
pub fn char_digit(c: char) -> u8 {
    (c as u32 - 48) as u8
}

/// `Number.natDigits`: the decimal digits, `[0]` for zero.
pub fn nat_digits(n: u128) -> Vec<u8> {
    if n == 0 {
        return vec![0];
    }
    n.to_string().bytes().map(|b| b - b'0').collect()
}

/// `Number.leadZero`.
pub fn lead_zero(ip: &[u8]) -> bool {
    ip.len() > 1 && ip.first() == Some(&0)
}

/// `Number.printNat`.
pub fn print_nat(n: u128) -> Vec<char> {
    nat_digits(n).into_iter().map(digit_char).collect()
}

/// `Number.printInt`.
pub fn print_int(z: i128) -> Vec<char> {
    let mut out = Vec::new();
    if z < 0 {
        out.push('-');
    }
    out.extend(print_nat(z.unsigned_abs()));
    out
}

/// `Number.readDigits`: the maximal run of digit characters at the front.
pub fn read_digits(input: &[char]) -> (Vec<u8>, &[char]) {
    let n = input.iter().take_while(|c| c.is_ascii_digit()).count();
    (
        input[..n].iter().map(|&c| char_digit(c)).collect(),
        &input[n..],
    )
}

/// `Number.parseNat`.
pub fn parse_nat(input: &[char]) -> Option<(i128, &[char])> {
    let (ds, r) = read_digits(input);
    if ds.is_empty() {
        return None;
    }
    Some((digits_val(&ds)?, r))
}

/// `Number.parseInt`: an optional `-`, then digits.
pub fn parse_int(input: &[char]) -> Option<(i128, &[char])> {
    match input {
        ['-', r @ ..] => parse_nat(r).map(|(n, r)| (-n, r)),
        _ => parse_nat(input),
    }
}

/// `Number.fracDigits`.
pub fn frac_digits(fp: &[u8]) -> Vec<u8> {
    if fp.is_empty() { vec![0] } else { fp.to_vec() }
}

/// `Number.decBody`: the unsigned spelling of `d₁.d₂… × 10^e10`.
pub fn dec_body(ds: &[u8], e10: i64) -> Vec<char> {
    if !(-4..=5).contains(&e10) {
        match ds {
            [] => vec![],
            [d, fp @ ..] => {
                let mut out = vec![digit_char(*d), '.'];
                out.extend(frac_digits(fp).into_iter().map(digit_char));
                out.push('e');
                out.extend(print_int(e10 as i128));
                out
            }
        }
    } else if e10 < 0 {
        let mut out = vec!['0', '.'];
        out.extend(std::iter::repeat_n('0', (-e10 - 1) as usize));
        out.extend(ds.iter().map(|&d| digit_char(d)));
        out
    } else {
        let k = (e10 + 1) as usize;
        let mut out: Vec<char> = ds.iter().take(k).map(|&d| digit_char(d)).collect();
        out.extend(std::iter::repeat_n('0', k.saturating_sub(ds.len())));
        out.push('.');
        let rest = if ds.len() > k { &ds[k..] } else { &[][..] };
        out.extend(frac_digits(rest).into_iter().map(digit_char));
        out
    }
}

/// `Number.print`: the canonical spelling of a number.
pub fn print(n: &JNum) -> Vec<char> {
    match n {
        JNum::Int(z) => print_int(*z),
        JNum::Dec { neg, digits, e10 } => {
            let mut out = if *neg { vec!['-'] } else { vec![] };
            out.extend(dec_body(digits, *e10));
            out
        }
    }
}

/// [`print`] as a `String`.
pub fn print_string(n: &JNum) -> String {
    print(n).into_iter().collect()
}

/// `Number.mkDec`: the decimal with digits `ds` (leading and trailing zeros
/// dropped) whose first listed digit sits at decimal exponent `e10`.
pub fn mk_dec(neg: bool, ds: &[u8], e10: i64) -> JNum {
    let lead = ds.iter().take_while(|&&d| d == 0).count();
    let mut core: Vec<u8> = ds[lead..].to_vec();
    while core.last() == Some(&0) {
        core.pop();
    }
    JNum::Dec {
        neg,
        digits: core,
        e10: e10 - lead as i64,
    }
}

/// `Number.finishDec`: an optional `e` exponent after the fraction digits.
pub fn finish_dec<'a>(neg: bool, ds: &[u8], e10: i64, r: &'a [char]) -> Option<(JNum, &'a [char])> {
    match r {
        ['e', r4 @ ..] => parse_int(r4).and_then(|(x, rest)| {
            let x = i64::try_from(x).ok()?;
            Some((mk_dec(neg, ds, e10.checked_add(x)?), rest))
        }),
        _ => Some((mk_dec(neg, ds, e10), r)),
    }
}

/// `Number.afterInt`.
pub fn after_int<'a>(neg: bool, ip: &[u8], r: &'a [char]) -> Option<(JNum, &'a [char])> {
    match r {
        ['.', r2 @ ..] => {
            let (q, rest) = read_digits(r2);
            if q.is_empty() {
                None
            } else {
                let mut ds = ip.to_vec();
                ds.extend(q);
                finish_dec(neg, &ds, ip.len() as i64 - 1, rest)
            }
        }
        _ => {
            let v = digits_val(ip)?;
            Some((JNum::Int(if neg { -v } else { v }), r))
        }
    }
}

/// `Number.parseRaw`: a number token as written, not yet canonical.
pub fn parse_raw(input: &[char]) -> Option<(JNum, &[char])> {
    let (neg, s) = match input {
        ['-', r @ ..] => (true, r),
        r => (false, r),
    };
    let (p, rest) = read_digits(s);
    if p.is_empty() || lead_zero(&p) {
        None
    } else {
        after_int(neg, &p, rest)
    }
}

/// `Number.canonize`.
pub fn canonize(n: JNum) -> JNum {
    match n {
        JNum::Dec { ref digits, .. } if digits.is_empty() => JNum::Int(0),
        JNum::Dec { neg, digits, e10 } => match dec_int(neg, &digits, e10) {
            Some(Some(z)) if in_int64(z) => JNum::Int(z),
            _ => JNum::Dec { neg, digits, e10 },
        },
        n => n,
    }
}

/// `Number.parse`: a number token, in canonical form.
pub fn parse(input: &[char]) -> Option<(JNum, &[char])> {
    let (n, r) = parse_raw(input)?;
    let c = canonize(n);
    if c.wfb() { Some((c, r)) } else { None }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(s: &str) -> String {
        let cs: Vec<char> = s.chars().collect();
        print_string(&parse(&cs).unwrap().0)
    }

    #[test]
    fn spellings() {
        assert_eq!(p("1.0"), "1");
        assert_eq!(p("1.0e0"), "1");
        assert_eq!(p("2.50"), "2.5");
        assert_eq!(p("0.000123456"), "0.000123456");
        assert_eq!(p("999999.5"), "999999.5");
        assert_eq!(p("1.0e-9"), "1.0e-9");
        assert_eq!(p("1000000.5"), "1.0000005e6");
        assert_eq!(p("1.0e19"), "1.0e19");
        assert!(parse(&"007".chars().collect::<Vec<_>>()).is_none());
        assert!(parse(&"9223372036854775808".chars().collect::<Vec<_>>()).is_none());
    }
}
