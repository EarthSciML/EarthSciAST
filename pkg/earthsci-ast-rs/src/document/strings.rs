//! Lexical pieces shared by the YAML and Typst codecs.
//!
//! Port of `formal/Esm/Document/Strings.lean`: double-quoted strings with
//! JSON-style escapes (YAML writes the hex escape `\uXXXX`, Typst `\u{XXXX}`;
//! `braces` selects the Typst spelling), bare identifier keys, and the
//! characters a number or a key never starts with.

/// `Strings.hexChar`: a lowercase hex digit.
pub fn hex_char(d: u32) -> char {
    if d < 10 {
        char::from_u32(48 + d).unwrap()
    } else {
        char::from_u32(87 + d).unwrap()
    }
}

/// `Strings.hexVal`: the value of a hex digit (either case).
pub fn hex_val(c: char) -> Option<u32> {
    match c {
        '0'..='9' => Some(c as u32 - 48),
        'a'..='f' => Some(c as u32 - 87),
        'A'..='F' => Some(c as u32 - 55),
        _ => None,
    }
}

/// `Strings.hex4`.
pub fn hex4(n: u32) -> [char; 4] {
    [
        hex_char(n / 4096 % 16),
        hex_char(n / 256 % 16),
        hex_char(n / 16 % 16),
        hex_char(n % 16),
    ]
}

/// `Strings.hex4Val`.
pub fn hex4_val(a: char, b: char, c: char, d: char) -> Option<u32> {
    Some(hex_val(a)? * 4096 + hex_val(b)? * 256 + hex_val(c)? * 16 + hex_val(d)?)
}

/// `Strings.needsHex`: characters written as a hex escape.
pub fn needs_hex(c: char) -> bool {
    let n = c as u32;
    n < 0x20
        || n == 0x7F
        || (0x80..=0x9F).contains(&n)
        || n == 0x2028
        || n == 0x2029
        || n == 0xFEFF
        || n == 0xFFFE
        || n == 0xFFFF
}

/// `Strings.escChar`.
pub fn esc_char(braces: bool, c: char, out: &mut Vec<char>) {
    match c {
        '"' => out.extend(['\\', '"']),
        '\\' => out.extend(['\\', '\\']),
        '\n' => out.extend(['\\', 'n']),
        '\t' => out.extend(['\\', 't']),
        '\r' => out.extend(['\\', 'r']),
        c if needs_hex(c) => {
            out.extend(['\\', 'u']);
            if braces {
                out.push('{');
                out.extend(hex4(c as u32));
                out.push('}');
            } else {
                out.extend(hex4(c as u32));
            }
        }
        c => out.push(c),
    }
}

/// `Strings.escape`: the escaped characters of a string, without the quotes.
pub fn escape(braces: bool, cs: &[char]) -> Vec<char> {
    let mut out = Vec::with_capacity(cs.len());
    for &c in cs {
        esc_char(braces, c, &mut out);
    }
    out
}

/// `Strings.quote`: a double-quoted string literal.
pub fn quote(braces: bool, s: &str) -> Vec<char> {
    let cs: Vec<char> = s.chars().collect();
    let mut out = vec!['"'];
    out.extend(escape(braces, &cs));
    out.push('"');
    out
}

/// `Strings.unquoteBody`: the characters up to the closing quote, and what
/// follows it.
pub fn unquote_body(braces: bool, mut input: &[char]) -> Option<(Vec<char>, &[char])> {
    let mut out = Vec::new();
    loop {
        match input {
            [] => return None,
            ['"', r @ ..] => return Some((out, r)),
            ['\\', '"', r @ ..] => {
                out.push('"');
                input = r;
            }
            ['\\', '\\', r @ ..] => {
                out.push('\\');
                input = r;
            }
            ['\\', 'n', r @ ..] => {
                out.push('\n');
                input = r;
            }
            ['\\', 't', r @ ..] => {
                out.push('\t');
                input = r;
            }
            ['\\', 'r', r @ ..] => {
                out.push('\r');
                input = r;
            }
            ['\\', 'u', '{', a, b, c, d, '}', r @ ..] if braces => {
                out.push(char_of(hex4_val(*a, *b, *c, *d)?)?);
                input = r;
            }
            ['\\', 'u', '{', _, _, _, _, '}', ..] => return None,
            ['\\', 'u', a, b, c, d, r @ ..] => {
                if braces {
                    return None;
                }
                out.push(char_of(hex4_val(*a, *b, *c, *d)?)?);
                input = r;
            }
            ['\\', ..] => return None,
            [c, r @ ..] => {
                out.push(*c);
                input = r;
            }
        }
    }
}

/// Lean's `Char.ofNat`: a surrogate code point becomes `'\0'`.
pub fn char_of(n: u32) -> Option<char> {
    Some(char::from_u32(n).unwrap_or('\0'))
}

/// `Strings.parseQuoted`.
pub fn parse_quoted(braces: bool, input: &[char]) -> Option<(String, &[char])> {
    match input {
        ['"', r @ ..] => unquote_body(braces, r).map(|(cs, r)| (cs.into_iter().collect(), r)),
        _ => None,
    }
}

/// `Strings.isIdentStart` (ASCII letters, as Lean's `Char.isAlpha`).
pub fn is_ident_start(c: char) -> bool {
    c.is_ascii_alphabetic() || c == '_'
}

/// `Strings.isIdentChar`.
pub fn is_ident_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '_'
}

/// `Strings.isIdent`: `[A-Za-z_][A-Za-z0-9_]*`.
pub fn is_ident(cs: &[char]) -> bool {
    match cs {
        [] => false,
        [c, r @ ..] => is_ident_start(*c) && r.iter().all(|&d| is_ident_char(d)),
    }
}

/// `Strings.readIdent`: the maximal run of identifier characters at the front.
pub fn read_ident(input: &[char]) -> (&[char], &[char]) {
    let n = input.iter().take_while(|&&c| is_ident_char(c)).count();
    input.split_at(n)
}

/// `Strings.spaces`.
pub fn spaces(n: usize) -> Vec<char> {
    vec![' '; n]
}

/// `Strings.bareKey`: a key prints bare when it is an identifier and not one of
/// the codec's reserved words.
pub fn bare_key(reserved: impl Fn(&str) -> bool, k: &str) -> bool {
    let cs: Vec<char> = k.chars().collect();
    is_ident(&cs) && !reserved(k)
}

/// `Strings.printKey`.
pub fn print_key(braces: bool, reserved: impl Fn(&str) -> bool, k: &str) -> Vec<char> {
    if bare_key(reserved, k) {
        k.chars().collect()
    } else {
        quote(braces, k)
    }
}

/// `Strings.parseKey`: quoted, or an identifier that is not a reserved word.
pub fn parse_key(
    braces: bool,
    reserved: impl Fn(&str) -> bool,
    input: &[char],
) -> Option<(String, &[char])> {
    match input {
        [] => None,
        ['"', ..] => parse_quoted(braces, input),
        [c, ..] if is_ident_start(*c) => {
            let (id, r) = read_ident(input);
            let id: String = id.iter().collect();
            if reserved(&id) { None } else { Some((id, r)) }
        }
        _ => None,
    }
}

/// `Strings.nonKeyHeads`.
// Ported with the module; nothing outside the Lean proofs calls it yet.
#[allow(dead_code)]
pub const NON_KEY_HEADS: &[char] = &[')', ':', '-', '?', ' ', '\n', '\t', '\r'];

/// `Strings.nonNumHeads`.
// Ported with the module; nothing outside the Lean proofs calls it yet.
#[allow(dead_code)]
pub const NON_NUM_HEADS: &[char] = &[
    '(', ')', '"', 'n', 't', 'f', ':', '[', '{', '?', ' ', '\n', '\t', '\r',
];
