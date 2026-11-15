//! Text scanning shared by the containers: prefixes, lines, and fenced bodies
//! ended by a closing line.
//!
//! Port of `formal/Esm/Document/Source/Text.lean`.

/// `Source.pre`: `p` is a prefix of `s`.
pub fn pre(p: &[char], s: &[char]) -> bool {
    s.starts_with(p)
}

/// `Source.hasSub`: `p` occurs in `s`.
pub fn has_sub(p: &[char], s: &[char]) -> bool {
    (0..=s.len()).any(|i| pre(p, &s[i..]))
}

/// `Source.splitLine`: the first line (without its newline) and the text after
/// it.
pub fn split_line(s: &[char]) -> (&[char], &[char]) {
    match s.iter().position(|&c| c == '\n') {
        Some(i) => (&s[..i], &s[i + 1..]),
        None => (s, &[]),
    }
}

/// `Source.noStop`: no line of `s` starts with `stop`.
pub fn no_stop(stop: &[char], mut s: &[char]) -> bool {
    while !s.is_empty() {
        if pre(stop, s) {
            return false;
        }
        s = split_line(s).1;
    }
    true
}

/// `Source.untilStop`: lines up to the first one that starts with `stop`: the
/// lines before it (each with its newline), the rest of the closing line, and
/// the text after the closing line.
///
/// The Lean fuel is dropped: every caller gives at least one unit per line.
pub fn until_stop<'a>(
    stop: &[char],
    mut s: &'a [char],
) -> Option<(Vec<char>, &'a [char], &'a [char])> {
    let mut body = Vec::new();
    loop {
        if s.is_empty() {
            return None;
        }
        if pre(stop, s) {
            let (a, b) = split_line(&s[stop.len()..]);
            return Some((body, a, b));
        }
        let (line, rest) = split_line(s);
        body.extend_from_slice(line);
        body.push('\n');
        s = rest;
    }
}

/// `l.all (· == ' ')`.
pub fn blank(l: &[char]) -> bool {
    l.iter().all(|&c| c == ' ')
}

/// `t.takeWhile p` and `t.drop (t.takeWhile p).length`.
pub fn take_while(t: &[char], p: impl Fn(char) -> bool) -> (&[char], &[char]) {
    let n = t.iter().take_while(|&&c| p(c)).count();
    t.split_at(n)
}

/// [`pre`] with an ASCII spelling as the prefix (no allocation).
pub fn pre_s(p: &str, s: &[char]) -> bool {
    p.len() <= s.len() && p.chars().zip(s).all(|(a, &b)| a == b)
}

/// `after` (Reaction.lean) with an ASCII spelling as the prefix.
pub fn after_s<'a>(p: &str, s: &'a [char]) -> Option<&'a [char]> {
    if pre_s(p, s) {
        Some(&s[p.len()..])
    } else {
        None
    }
}

/// `String.ofList`.
pub fn string(cs: &[char]) -> String {
    cs.iter().collect()
}
