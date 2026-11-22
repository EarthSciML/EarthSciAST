//! The YAML subset of front matter and container bodies.
//!
//! Port of `formal/Esm/Document/Yaml.lean`. The printed text is block-style
//! YAML 1.2:
//!
//! * a non-empty object is one `key: value` line per entry, a non-empty array
//!   one `- item` line per element, at the current indentation;
//! * a scalar, `[]` or `{}` follows its `key: ` or `- ` on the same line;
//! * a non-empty container under a key starts on the next line, two spaces
//!   deeper; a non-empty object as an array element starts on the `- ` line,
//!   its other entries aligned with its first key; a non-empty array as an
//!   element starts on the next line, two spaces deeper.
//!
//! Strings are always double-quoted with JSON-style escapes, so a math leaf
//! (path blocks only, `Source.mathify`) is the plain scalar `$…$`, its text up
//! to the next `$` (`Json.mathOK`); the printer makes one only of text that is
//! [`plain_math_ok`], which every YAML 1.2 parser reads as that string. A key
//! is bare when it is an identifier and not one of YAML's special plain
//! scalars in any letter case; a key longer than 1024 characters uses the
//! explicit `? "key"` form. The reader accepts only this layout and
//! well-formed values.
//!
//! The Lean readers carry fuel (`4 * length + 4`) for termination only; every
//! two nested calls consume a character, so the port recurses without it.

use super::json::{Json, math_ok, p_math};
use super::number;
use super::source::keys::Kvs;
use super::strings::{
    is_ident_start, needs_hex, parse_key, parse_quoted, print_key, quote, spaces,
};

/// `Yaml.plainMathOK`: math text YAML holds as the plain scalar `$…$`, which a
/// YAML 1.2 parser reads as that string: [`math_ok`], and no `: ` (a mapping
/// indicator), no ` #` (a comment) and no character of `needs_hex`. The
/// Markdown printer leaves any other expression in its block as JSON.
pub fn plain_math_ok(s: &str) -> bool {
    math_ok(s) && !s.chars().any(needs_hex) && !s.contains(": ") && !s.contains(" #")
}

/// `Yaml.specialWords`.
pub const SPECIAL_WORDS: &[&str] = &["true", "false", "null", "yes", "no", "on", "off", "y", "n"];

/// `Yaml.reserved`: a key equal (in any ASCII letter case) to a special plain
/// scalar.
pub fn reserved(k: &str) -> bool {
    let lower: String = k.chars().map(|c| c.to_ascii_lowercase()).collect();
    SPECIAL_WORDS.contains(&lower.as_str())
}

/// `Yaml.longKey`.
pub fn long_key(k: &str) -> bool {
    1024 < print_key(false, reserved, k).len()
}

/// `Yaml.keyPart`: the key of an entry at indentation `m`, up to its `:`.
pub fn key_part(m: usize, k: &str, out: &mut Vec<char>) {
    if long_key(k) {
        out.extend(['?', ' ']);
        out.extend(quote(false, k));
        out.push('\n');
        out.extend(spaces(m));
    } else {
        out.extend(print_key(false, reserved, k));
    }
}

/// `Yaml.inline`: the one-line spelling of a scalar or an empty container.
pub fn inline(v: &Json) -> Vec<char> {
    match v {
        Json::Null => "null".chars().collect(),
        Json::Bool(true) => "true".chars().collect(),
        Json::Bool(false) => "false".chars().collect(),
        Json::Num(n) => number::print(n),
        Json::Str(s) => quote(false, s),
        Json::Math(s) => {
            let mut out = vec!['$'];
            out.extend(s.chars());
            out.push('$');
            out
        }
        Json::Arr(_) => vec!['[', ']'],
        Json::Obj(_) => vec!['{', '}'],
    }
}

/// The scalar case of `itemBody`/`valBody`: ` value` and the newline.
fn inline_line(v: &Json, out: &mut Vec<char>) {
    out.push(' ');
    out.extend(inline(v));
    out.push('\n');
}

/// `Yaml.encItems`: the lines of a non-empty array at indentation `m`.
pub fn enc_items(m: usize, vs: &[Json], out: &mut Vec<char>) {
    for v in vs {
        out.extend(spaces(m));
        out.push('-');
        item_body(m, v, out);
    }
}

/// `Yaml.itemBody`: what follows the `-` of an array element.
pub fn item_body(m: usize, v: &Json, out: &mut Vec<char>) {
    match v {
        Json::Arr(xs) if !xs.is_empty() => {
            out.push('\n');
            enc_items(m + 2, xs, out);
        }
        Json::Obj(kvs) if !kvs.is_empty() => {
            let (k, v) = &kvs[0];
            out.push(' ');
            key_part(m + 2, k, out);
            out.push(':');
            val_body(m + 2, v, out);
            enc_entries(m + 2, &kvs[1..], out);
        }
        v => inline_line(v, out),
    }
}

/// `Yaml.encEntries`: the lines of a non-empty object at indentation `m`.
pub fn enc_entries(m: usize, es: &[(String, Json)], out: &mut Vec<char>) {
    for (k, v) in es {
        out.extend(spaces(m));
        key_part(m, k, out);
        out.push(':');
        val_body(m, v, out);
    }
}

/// `Yaml.valBody`: what follows the `:` of an entry whose key is at
/// indentation `m`.
pub fn val_body(m: usize, v: &Json, out: &mut Vec<char>) {
    match v {
        Json::Arr(xs) if !xs.is_empty() => {
            out.push('\n');
            enc_items(m + 2, xs, out);
        }
        Json::Obj(kvs) if !kvs.is_empty() => {
            out.push('\n');
            enc_entries(m + 2, kvs, out);
        }
        v => inline_line(v, out),
    }
}

/// `Yaml.encode`: the canonical YAML spelling of a value.
pub fn encode(v: &Json) -> Vec<char> {
    let mut out = Vec::new();
    match v {
        Json::Arr(xs) if !xs.is_empty() => enc_items(0, xs, &mut out),
        Json::Obj(kvs) if !kvs.is_empty() => enc_entries(0, kvs, &mut out),
        v => {
            out.extend(inline(v));
            out.push('\n');
        }
    }
    out
}

// ## Reader

/// `Yaml.dropSp`: drop exactly `n` leading spaces.
pub fn drop_sp(n: usize, l: &[char]) -> Option<&[char]> {
    if l.len() >= n && l[..n].iter().all(|&c| c == ' ') {
        Some(&l[n..])
    } else {
        None
    }
}

/// `Yaml.parseKeyAt`: an explicit `? "key"` line followed by the indentation
/// of the `:` line, or a plain key.
pub fn parse_key_at(m: usize, input: &[char]) -> Option<(String, &[char])> {
    match input {
        [] => None,
        ['?', r @ ..] => match r {
            [' ', r1 @ ..] => match parse_quoted(false, r1) {
                Some((k, ['\n', r2 @ ..])) => drop_sp(m, r2).map(|r3| (k, r3)),
                _ => None,
            },
            _ => None,
        },
        _ => parse_key(false, reserved, input),
    }
}

/// `Yaml.pInline`: a scalar or an empty container.
pub fn p_inline(input: &[char]) -> Option<(Json, &[char])> {
    match input {
        [] => None,
        ['n', r @ ..] => match r {
            ['u', 'l', 'l', r1 @ ..] => Some((Json::Null, r1)),
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
        ['[', r @ ..] => match r {
            [']', r1 @ ..] => Some((Json::Arr(vec![]), r1)),
            _ => None,
        },
        ['{', r @ ..] => match r {
            ['}', r1 @ ..] => Some((Json::Obj(vec![]), r1)),
            _ => None,
        },
        ['"', ..] => parse_quoted(false, input).map(|(s, r)| (Json::Str(s), r)),
        ['$', r @ ..] => p_math(r),
        _ => number::parse(input).map(|(n, r)| (Json::Num(n), r)),
    }
}

/// `Yaml.pScalarLine`: a scalar and the end of its line.
pub fn p_scalar_line(input: &[char]) -> Option<(Json, &[char])> {
    match p_inline(input) {
        Some((v, ['\n', r @ ..])) => Some((v, r)),
        _ => None,
    }
}

/// `Yaml.isItemLine`.
pub fn is_item_line(m: usize, input: &[char]) -> bool {
    matches!(drop_sp(m, input), Some(['-', ..]))
}

/// `Yaml.isEntryLine`.
pub fn is_entry_line(m: usize, input: &[char]) -> bool {
    match drop_sp(m, input) {
        Some([c, ..]) => *c == '"' || *c == '?' || is_ident_start(*c),
        _ => false,
    }
}

/// `Yaml.pItems`: array elements at indentation `m`.
pub fn p_items(m: usize, mut input: &[char]) -> Option<(Vec<Json>, &[char])> {
    let mut out = Vec::new();
    while is_item_line(m, input) {
        let (v, r) = p_item_body(m, &input[m + 1..])?;
        out.push(v);
        input = r;
    }
    Some((out, input))
}

/// `Yaml.pItemBody`: after the `-` of an element at indentation `m`.
pub fn p_item_body(m: usize, input: &[char]) -> Option<(Json, &[char])> {
    let _nest = super::limits::Nest::enter()?;
    match input {
        ['\n', r @ ..] => p_items(m + 2, r).map(|(xs, r)| (Json::Arr(xs), r)),
        [' ', r @ ..] => match p_entry(m + 2, r) {
            Some((e, r1)) => p_entries(m + 2, r1).map(|(mut es, r2)| {
                es.insert(0, e);
                (Json::Obj(es), r2)
            }),
            None => p_scalar_line(r),
        },
        _ => None,
    }
}

/// `Yaml.pEntries`: object entries at indentation `m`.
pub fn p_entries(m: usize, mut input: &[char]) -> Option<(Kvs, &[char])> {
    let mut out = Vec::new();
    while is_entry_line(m, input) {
        let (e, r) = p_entry(m, &input[m..])?;
        out.push(e);
        input = r;
    }
    Some((out, input))
}

/// `Yaml.pEntry`: one entry, at its key.
pub fn p_entry(m: usize, input: &[char]) -> Option<((String, Json), &[char])> {
    match parse_key_at(m, input) {
        Some((k, [':', r @ ..])) => p_val_body(m, r).map(|(v, r)| ((k, v), r)),
        _ => None,
    }
}

/// `Yaml.pValBody`: after the `:` of an entry whose key is at indentation `m`.
pub fn p_val_body(m: usize, input: &[char]) -> Option<(Json, &[char])> {
    let _nest = super::limits::Nest::enter()?;
    match input {
        [' ', r @ ..] => p_scalar_line(r),
        ['\n', r @ ..] => {
            if is_item_line(m + 2, r) {
                p_items(m + 2, r).map(|(xs, r)| (Json::Arr(xs), r))
            } else {
                p_entries(m + 2, r).map(|(es, r)| (Json::Obj(es), r))
            }
        }
        _ => None,
    }
}

/// `Yaml.topIsArray`.
pub fn top_is_array(input: &[char]) -> bool {
    is_item_line(0, input) && matches!(input, [_, d, ..] if *d == ' ' || *d == '\n')
}

/// `Yaml.pTop`: an array, an object, or one scalar line.
pub fn p_top(input: &[char]) -> Option<(Json, &[char])> {
    if top_is_array(input) {
        p_items(0, input).map(|(xs, r)| (Json::Arr(xs), r))
    } else {
        match p_entry(0, input) {
            Some((e, r)) => p_entries(0, r).map(|(mut es, r)| {
                es.insert(0, e);
                (Json::Obj(es), r)
            }),
            None => p_scalar_line(input),
        }
    }
}

/// `Yaml.decode`: all of the input consumed, and the value well formed (math
/// leaves allowed, `Json.WFm`).
pub fn decode(s: &[char]) -> Option<Json> {
    match p_top(s) {
        Some((v, [])) if v.wfmb() => Some(v),
        _ => None,
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
    fn round_trips() {
        for t in [
            "a: 1\nb:\n  - 1\n  - c: \"x\"\n    d: []\n  -\n    - null\n\"y es\": {}\n\"Yes\": true\n",
            "- 1\n- \"a\\u0001\"\n",
            "1.0e-9\n",
            "\"s\"\n",
            "{}\n",
            "a:\n  - $x + 1$\n",
        ] {
            assert_eq!(rt(t), t);
        }
    }

    #[test]
    fn refusals() {
        for t in [
            "a: $$\n",
            "a: $x\\$\n",
            "a: 1\na: 2\n",
            "yes: 1\n",
            "a: 01\n",
            "a:  1\n",
            "a: 1",
        ] {
            let cs: Vec<char> = t.chars().collect();
            assert!(decode(&cs).is_none(), "{t:?}");
        }
    }

    #[test]
    fn long_key_explicit_form() {
        let k = "x".repeat(1100);
        let v = Json::Obj(vec![(
            "a".into(),
            Json::Obj(vec![(k.clone(), Json::int(1))]),
        )]);
        let text: String = encode(&v).into_iter().collect();
        assert_eq!(text, format!("a:\n  ? \"{k}\"\n  : 1\n"));
        let cs: Vec<char> = text.chars().collect();
        assert_eq!(decode(&cs), Some(v));
    }
}
