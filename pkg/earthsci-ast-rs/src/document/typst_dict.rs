//! The Typst value codec: a JSON value as a Typst code-mode value.
//!
//! Port of `formal/Esm/Document/TypstDict.lean`.
//!
//! * `none`, `true`, `false`; numbers in the canonical spelling, except `-2^63`,
//!   printed `(-9223372036854775807 - 1)` because Typst reads the literal
//!   `-9223372036854775808` as a float;
//! * strings with Typst escapes (`\u{XXXX}`);
//! * arrays `(a, b)`, `()` empty; dictionaries `(key: v, "quoted key": v)`,
//!   `(:)` empty. A key is bare when it is an identifier and not a Typst keyword;
//! * a math leaf `$…$`, Typst math content: its text up to the next `$`
//!   (`Json.mathOK`). Only a path block holds one (`Source.mathify`).
//!
//! The canonical layout is one element per line, each indented two spaces deeper
//! than the opening line and followed by `,`. The reader skips whitespace
//! between tokens, accepts a trailing comma or none, and rejects a one-element
//! array without its comma (Typst reads `(x)` as `x`).
//!
//! The Lean readers carry fuel for termination; the fuel `decode` (and the
//! Typst math lexer) gives is never exhausted, since every three nested calls
//! consume a character, so the port recurses without it.

use super::json::{JNum, Json, p_math};
use super::number;
use super::strings::{parse_key, parse_quoted, print_key, quote, spaces};

/// `TypstDict.keywords`: Typst keywords, which cannot be bare dictionary keys.
pub const KEYWORDS: &[&str] = &[
    "none", "auto", "true", "false", "not", "and", "or", "let", "set", "show", "if", "else", "for",
    "in", "while", "break", "continue", "return", "import", "include", "context", "as", "_",
];

/// `TypstDict.reserved`.
pub fn reserved(k: &str) -> bool {
    KEYWORDS.contains(&k)
}

/// `TypstDict.int64Min`.
const INT64_MIN: i128 = i64::MIN as i128;

/// `TypstDict.minLit`: the first operand of the `-2^63` expression.
const MIN_LIT: &str = "-9223372036854775807";

/// `TypstDict.printNum`.
pub fn print_num(n: &JNum) -> Vec<char> {
    if *n == JNum::Int(INT64_MIN) {
        "(-9223372036854775807 - 1)".chars().collect()
    } else {
        number::print(n)
    }
}

/// `TypstDict.enc`: the canonical print of a value whose first line is
/// indented by `m` spaces (the indentation itself is not printed).
pub fn enc(m: usize, v: &Json, out: &mut Vec<char>) {
    match v {
        Json::Null => out.extend("none".chars()),
        Json::Bool(true) => out.extend("true".chars()),
        Json::Bool(false) => out.extend("false".chars()),
        Json::Num(n) => out.extend(print_num(n)),
        Json::Str(s) => out.extend(quote(true, s)),
        Json::Math(s) => {
            out.push('$');
            out.extend(s.chars());
            out.push('$');
        }
        Json::Arr(xs) if xs.is_empty() => out.extend(['(', ')']),
        Json::Arr(xs) => {
            out.extend(['(', '\n']);
            for x in xs {
                out.extend(spaces(m + 2));
                enc(m + 2, x, out);
                out.extend([',', '\n']);
            }
            out.extend(spaces(m));
            out.push(')');
        }
        Json::Obj(kvs) if kvs.is_empty() => out.extend(['(', ':', ')']),
        Json::Obj(kvs) => {
            out.extend(['(', '\n']);
            for (k, x) in kvs {
                out.extend(spaces(m + 2));
                out.extend(print_key(true, reserved, k));
                out.extend([':', ' ']);
                enc(m + 2, x, out);
                out.extend([',', '\n']);
            }
            out.extend(spaces(m));
            out.push(')');
        }
    }
}

/// `TypstDict.encode`: the canonical Typst spelling of a value.
pub fn encode(v: &Json) -> Vec<char> {
    let mut out = Vec::new();
    enc(0, v, &mut out);
    out
}

/// `TypstDict.isWs`.
pub fn is_ws(c: char) -> bool {
    matches!(c, ' ' | '\n' | '\t' | '\r')
}

/// `TypstDict.skipWs`.
pub fn skip_ws(r: &[char]) -> &[char] {
    let n = r.iter().take_while(|&&c| is_ws(c)).count();
    &r[n..]
}

/// `TypstDict.isEntry`: the input starts with a key and a colon.
pub fn is_entry(input: &[char]) -> bool {
    match parse_key(true, reserved, input) {
        Some((_, r)) => matches!(skip_ws(r), [':', ..]),
        None => false,
    }
}

/// `TypstDict.Next`: what follows one element.
enum Next {
    /// `,` and another element.
    More,
    /// `)`, after a `,` (`true`) or directly.
    Close(bool),
}

/// `TypstDict.pNext`.
fn p_next(r: &[char]) -> Option<(Next, &[char])> {
    match skip_ws(r) {
        [',', r1 @ ..] => match skip_ws(r1) {
            [')', r2 @ ..] => Some((Next::Close(true), r2)),
            r2 => Some((Next::More, r2)),
        },
        [')', r1 @ ..] => Some((Next::Close(false), r1)),
        _ => None,
    }
}

/// `TypstDict.pMin`: after `(` and any whitespace, the rest of
/// `(-9223372036854775807 - 1)`.
fn p_min(r: &[char]) -> Option<&[char]> {
    let lit: Vec<char> = MIN_LIT.chars().collect();
    let r1 = r.strip_prefix(lit.as_slice())?;
    let ['-', r2 @ ..] = skip_ws(r1) else {
        return None;
    };
    let ['1', r3 @ ..] = skip_ws(r2) else {
        return None;
    };
    let [')', r4 @ ..] = skip_ws(r3) else {
        return None;
    };
    Some(r4)
}

/// `TypstDict.pVal`: a value, at its first character.
pub fn p_val(input: &[char]) -> Option<(Json, &[char])> {
    let _nest = super::limits::Nest::enter()?;
    match input {
        [] => None,
        ['(', r @ ..] => match p_min(skip_ws(r)) {
            Some(r1) => Some((Json::Num(JNum::Int(INT64_MIN)), r1)),
            None => p_paren(skip_ws(r)),
        },
        ['"', ..] => parse_quoted(true, input).map(|(s, r)| (Json::Str(s), r)),
        ['$', r @ ..] => p_math(r),
        ['n', r @ ..] => match r {
            ['o', 'n', 'e', r1 @ ..] => Some((Json::Null, r1)),
            _ => None,
        },
        ['t', r @ ..] => match r {
            ['r', 'u', 'e', r1 @ ..] => Some((Json::Bool(true), r1)),
            _ => None,
        },
        ['f', r @ ..] => match r {
            ['a', 'l', 's', 'e', r1 @ ..] => Some((Json::Bool(false), r1)),
            _ => None,
        },
        _ => number::parse(input).map(|(n, r)| (Json::Num(n), r)),
    }
}

/// `TypstDict.pParen`: after `(` and any whitespace.
fn p_paren(input: &[char]) -> Option<(Json, &[char])> {
    match input {
        [] => None,
        [')', r @ ..] => Some((Json::Arr(vec![]), r)),
        [':', r @ ..] => match skip_ws(r) {
            [')', r1 @ ..] => Some((Json::Obj(vec![]), r1)),
            _ => None,
        },
        _ if is_entry(input) => p_entries(input).map(|(kvs, r)| (Json::Obj(kvs), r)),
        _ => p_items(input).map(|(xs, r)| (Json::Arr(xs), r)),
    }
}

/// `TypstDict.pItems`: array elements; the first needs a `,` after it even
/// when it is the last.
fn p_items(mut input: &[char]) -> Option<(Vec<Json>, &[char])> {
    let mut out = Vec::new();
    let mut first = true;
    loop {
        let (v, r) = p_val(input)?;
        out.push(v);
        match p_next(r)? {
            (Next::Close(comma), r1) => {
                return if first && !comma {
                    None
                } else {
                    Some((out, r1))
                };
            }
            (Next::More, r1) => {
                input = r1;
                first = false;
            }
        }
    }
}

/// Dictionary entries, in order.
type Entries = Vec<(String, Json)>;

/// `TypstDict.pEntries`: dictionary entries, at the first key.
fn p_entries(mut input: &[char]) -> Option<(Entries, &[char])> {
    let mut out = Vec::new();
    loop {
        let (k, r) = parse_key(true, reserved, input)?;
        let [':', r1 @ ..] = skip_ws(r) else {
            return None;
        };
        let (v, r2) = p_val(skip_ws(r1))?;
        out.push((k, v));
        match p_next(r2)? {
            (Next::Close(_), r3) => return Some((out, r3)),
            (Next::More, r3) => input = r3,
        }
    }
}

/// `TypstDict.decode`: whitespace, the value, whitespace, end of input. The
/// value must be well formed, math leaves allowed (`Json.WFm`).
#[cfg_attr(not(test), allow(dead_code))]
pub fn decode(s: &[char]) -> Option<Json> {
    let (v, r) = p_val(skip_ws(s))?;
    if skip_ws(r).is_empty() && v.wfmb() {
        Some(v)
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rt(text: &str) -> String {
        let cs: Vec<char> = text.chars().collect();
        encode(&decode(&cs).expect("decodes")).into_iter().collect()
    }

    #[test]
    fn round_trip() {
        assert_eq!(
            rt("(a: 1, \"b c\": (1,), d: (:), e: ())"),
            "(\n  a: 1,\n  \"b c\": (\n    1,\n  ),\n  d: (:),\n  e: (),\n)"
        );
        assert_eq!(
            rt("( -9223372036854775807 - 1 )"),
            "(-9223372036854775807 - 1)"
        );
        let one: Vec<char> = "(1)".chars().collect();
        assert!(decode(&one).is_none());
        let kw: Vec<char> = "(none: 1)".chars().collect();
        assert!(decode(&kw).is_none());
        assert_eq!(rt("(a: $x + 1$)"), "(\n  a: $x + 1$,\n)");
        let empty: Vec<char> = "(a: $$)".chars().collect();
        assert!(decode(&empty).is_none());
    }
}
