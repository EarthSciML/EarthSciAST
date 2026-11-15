//! Lines of text, and the input decoding.
//!
//! Port of `formal/Esm/Document/Source/Lines.lean`.
//!
//! Not ported: `Source.heads`, `Source.endBol`. No executable path uses them;
//! only the Lean proofs do.

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
