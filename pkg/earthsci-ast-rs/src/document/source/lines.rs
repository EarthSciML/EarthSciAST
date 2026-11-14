//! Lines of text, and the input decoding.
//!
//! Port of `formal/Esm/Document/Source/Lines.lean`.

/// `Source.heads`: the characters that start a line of `s` (the first one when
/// `s` starts at the beginning of a line, `bol`).
#[allow(dead_code)] // only the Lean proofs use it
pub fn heads(bol: bool, s: &[char]) -> Vec<char> {
    let mut out = Vec::new();
    let mut b = bol;
    for &c in s {
        if b {
            out.push(c);
        }
        b = c == '\n';
    }
    out
}

/// `Source.endBol`: whether the text after `s` starts at the beginning of a
/// line.
#[allow(dead_code)] // only the Lean proofs use it
pub fn end_bol(bol: bool, s: &[char]) -> bool {
    match s.last() {
        None => bol,
        Some(&c) => c == '\n',
    }
}

/// `Source.dropBOM`.
pub fn drop_bom(s: &[char]) -> &[char] {
    match s {
        ['\u{FEFF}', r @ ..] => r,
        _ => s,
    }
}

/// `Source.firstCRLF`: whether the first line ends in CRLF.
pub fn first_crlf(s: &[char]) -> bool {
    for (i, &c) in s.iter().enumerate() {
        if c == '\n' {
            return false;
        }
        if c == '\r' && s.get(i + 1) == Some(&'\n') {
            return true;
        }
    }
    false
}

/// `Source.unCRLF`: every CRLF as LF.
pub fn un_crlf(s: &[char]) -> Vec<char> {
    let mut out = Vec::with_capacity(s.len());
    for (i, &c) in s.iter().enumerate() {
        if !(c == '\r' && s.get(i + 1) == Some(&'\n')) {
            out.push(c);
        }
    }
    out
}

/// `Source.decodeText`: no byte-order mark, and LF line endings when the first
/// line ends in CRLF.
pub fn decode_text(s: &[char]) -> Vec<char> {
    let d = drop_bom(s);
    if first_crlf(d) {
        un_crlf(d)
    } else {
        d.to_vec()
    }
}
