//! LaTeX math: spelling and lexing of tokens.
//!
//! Port of `formal/Esm/Document/Math/Latex.lean`. [`render`] spells a token
//! list as LaTeX math, writing a space between two tokens where the reader
//! needs one (`needSpace`) and where it reads better (`pretty`); [`lex`] reads
//! it back, skipping spaces and the spacing commands.
//!
//! The Lean lexer (`lexAux`, `skipWs`) carries fuel equal to the input length
//! plus one, never exhausted (every step consumes a character); the port loops
//! without it.
//!
//! Not ported: `Latex.specials`, `Latex.escCharB`, `Latex.escCharL`,
//! `Latex.quoteL`. No executable path uses them; only the Lean proofs do.

use super::parse::{atom_start, units_of_raw};
use super::print::{char_digit_nat, char_of_nat, dig3, esc_t, key_special, raw_b, unesc_t};
use super::surface::{drop_p, is_bin, lex_signed, sci_split};
use super::token::{Kw, Tok};
use super::units::{self, Factor};
use crate::document::json::JNum;
use crate::document::math::expr::{is_dig, is_greek, is_letter, let_run};
use crate::document::{number, strings};

// ## Spelling

/// `Latex.fixUs`: undo the `\_` of `escCharL` up to the closing quote.
pub fn fix_us(cs: &[char]) -> Vec<char> {
    let mut out = Vec::with_capacity(cs.len());
    let mut cs = cs;
    loop {
        match cs {
            ['\\', '_', r @ ..] => {
                out.push('_');
                cs = r;
            }
            ['\\', c, r @ ..] => {
                out.push('\\');
                out.push(*c);
                cs = r;
            }
            ['"', ..] => {
                out.extend_from_slice(cs);
                return out;
            }
            [c, r @ ..] => {
                out.push(*c);
                cs = r;
            }
            [] => return out,
        }
    }
}

/// `Latex.strPlain`: a character of a JSON string written as itself inside
/// `\text{…}`.
pub fn str_plain(c: char) -> bool {
    let n = c as u32;
    (32..=126).contains(&n) && !key_special(c) && c != '_' && c != '{' && c != '}'
}

/// `Latex.dig7`: seven decimal digits.
pub fn dig7(n: u32) -> [char; 7] {
    let d = |p: u32| number::digit_char((n / p % 10) as u8);
    [
        d(1_000_000),
        d(100_000),
        d(10_000),
        d(1000),
        d(100),
        d(10),
        d(1),
    ]
}

/// `Latex.escS`: the spelling of a JSON string's characters inside
/// `\text{"…"}`.
pub fn esc_s(cs: &[char]) -> Vec<char> {
    let mut out = Vec::new();
    for &c in cs {
        if str_plain(c) {
            out.push(c);
        } else if c == '_' || c == '{' || c == '}' {
            out.push('\\');
            out.push(c);
        } else if (c as u32) < 1000 {
            out.extend("{\\char".chars());
            out.extend(dig3(c as u32));
            out.push('}');
        } else {
            out.extend("{\\char".chars());
            out.extend(dig7(c as u32));
            out.push('}');
        }
    }
    out
}

/// `Latex.unescS`: undo [`esc_s`].
pub fn unesc_s(cs: &[char]) -> Vec<char> {
    let mut out = Vec::new();
    let mut cs = cs;
    let d = |c: &char| char_digit_nat(*c);
    loop {
        match cs {
            ['{', '\\', 'c', 'h', 'a', 'r', a, b, e, '}', r @ ..] => {
                out.push(char_of_nat(100 * d(a) + 10 * d(b) + d(e)));
                cs = r;
            }
            [
                '{',
                '\\',
                'c',
                'h',
                'a',
                'r',
                a1,
                a2,
                a3,
                a4,
                a5,
                a6,
                a7,
                '}',
                r @ ..,
            ] => {
                out.push(char_of_nat(
                    1_000_000 * d(a1)
                        + 100_000 * d(a2)
                        + 10_000 * d(a3)
                        + 1000 * d(a4)
                        + 100 * d(a5)
                        + 10 * d(a6)
                        + d(a7),
                ));
                cs = r;
            }
            ['\\', c, r @ ..] => {
                out.push(*c);
                cs = r;
            }
            [c, r @ ..] => {
                out.push(*c);
                cs = r;
            }
            [] => return out,
        }
    }
}

/// `Latex.strL`: a JSON string in LaTeX: `\text{"…"}`.
pub fn str_l(s: &str) -> Vec<char> {
    let cs: Vec<char> = s.chars().collect();
    let mut out: Vec<char> = "\\text{\"".chars().collect();
    out.extend(esc_s(&cs));
    out.push('"');
    out.push('}');
    out
}

/// `Latex.textTok`: the token of `\text{raw}`: a JSON string when the text is
/// double-quoted, else text.
pub fn text_tok(raw: &[char]) -> Tok {
    match raw {
        ['"', q @ ..] if q.last() == Some(&'"') => {
            Tok::Jstr(unesc_s(&q[..q.len() - 1]).into_iter().collect())
        }
        _ => Tok::Txt(raw.iter().collect()),
    }
}

/// `Latex.timesTen`.
pub const TIMES_TEN: &str = " \\times 10^{";

/// `Latex.numChars`.
pub fn num_chars(n: &JNum) -> Vec<char> {
    match sci_split(n) {
        Some((m, e)) => {
            let mut out = m;
            out.extend(TIMES_TEN.chars());
            out.extend(number::print_int(e as i128));
            out.push('}');
            out
        }
        None => number::print(n),
    }
}

/// `Latex.kwChars`.
pub fn kw_chars(k: Kw) -> &'static str {
    match k {
        Kw::Plus => "+",
        Kw::Minus => "-",
        Kw::Eq => "=",
        Kw::Ne => "\\ne",
        Kw::Lt => "<",
        Kw::Gt => ">",
        Kw::Le => "\\le",
        Kw::Ge => "\\ge",
        Kw::Land => "\\land",
        Kw::Lor => "\\lor",
        Kw::Lnot => "\\lnot",
        Kw::Cdot => "\\cdot",
        Kw::Times => "\\times",
        Kw::Slash => "/",
        Kw::Caret => "^",
        Kw::Us => "_",
        Kw::Lp => "(",
        Kw::Rp => ")",
        Kw::Lpg => "\\left(",
        Kw::Rpg => "\\right)",
        Kw::Lb => "{",
        Kw::Rb => "}",
        Kw::Lbk => "[",
        Kw::Rbk => "]",
        Kw::Comma => ",",
        Kw::Semi => ";",
        Kw::Colon => ":",
        Kw::Amp => "&",
        Kw::Nl => "\\\\",
        Kw::Sdot => ".",
        Kw::Frac => "\\frac",
        Kw::Sqrt => "\\sqrt",
        Kw::Exp => "\\exp",
        Kw::Ln => "\\ln",
        Kw::Log => "\\log",
        Kw::Sin => "\\sin",
        Kw::Cos => "\\cos",
        Kw::Tan => "\\tan",
        Kw::Asin => "\\arcsin",
        Kw::Acos => "\\arccos",
        Kw::Atan => "\\arctan",
        Kw::Sinh => "\\sinh",
        Kw::Cosh => "\\cosh",
        Kw::Tanh => "\\tanh",
        Kw::Min => "\\min",
        Kw::Max => "\\max",
        Kw::Labs => "\\left|",
        Kw::Rabs => "\\right|",
        Kw::Lfloor => "\\lfloor",
        Kw::Rfloor => "\\rfloor",
        Kw::Lceil => "\\lceil",
        Kw::Rceil => "\\rceil",
        Kw::Pdiff => "\\partial",
        Kw::Nabla => "\\nabla",
        Kw::Dotacc => "\\dot",
        Kw::Bcases => "\\begin{cases}",
        Kw::Ecases => "\\end{cases}",
        Kw::Bmat => "\\begin{bmatrix}",
        Kw::Emat => "\\end{bmatrix}",
        Kw::Sum => "\\sum",
        Kw::Prod => "\\prod",
        Kw::Inn => "\\in",
        Kw::Substack => "\\substack",
        Kw::LimitsL => "\\limits",
        Kw::Lbkg => "\\left[",
        Kw::Rbkg => "\\right]",
        Kw::Barr => "\\begin{array}{l|l}",
        Kw::Earr => "\\end{array}",
        Kw::Lset => "\\{",
        Kw::Rset => "\\}",
        Kw::Abs
        | Kw::Floor
        | Kw::Ceil
        | Kw::Dif
        | Kw::Cases
        | Kw::Esmnode
        | Kw::Vec
        | Kw::Mat
        | Kw::Lr
        | Kw::Limits => "",
    }
}

/// `Latex.tokChars`.
pub fn tok_chars(t: &Tok) -> Vec<char> {
    let wrap = |open: &str, body: Vec<char>| {
        let mut out: Vec<char> = open.chars().collect();
        out.extend(body);
        out.push('}');
        out
    };
    let esc = |s: &str| esc_t(&s.chars().collect::<Vec<_>>());
    match t {
        Tok::Num(n) => num_chars(n),
        Tok::Letter(c) => vec![*c],
        Tok::Greek(g) => std::iter::once('\\').chain(g.chars()).collect(),
        Tok::Word(s) => s.chars().collect(),
        Tok::It(s) => wrap("\\mathit{", esc(s)),
        Tok::Rm(raw) => wrap("\\mathrm{", raw.chars().collect()),
        Tok::Opn(s) => wrap("\\operatorname{", esc(s)),
        Tok::Txt(s) => wrap("\\text{", s.chars().collect()),
        Tok::Jstr(s) => str_l(s),
        Tok::Esc(o) => wrap("\\esm{", esc(o)),
        Tok::Units(l) => wrap("\\,\\mathrm{", units::latex_body(l)),
        Tok::Kw(k) => kw_chars(*k).chars().collect(),
        Tok::Carr(n) => {
            let mut out: Vec<char> = "\\begin{array}{".chars().collect();
            out.extend(std::iter::repeat_n('c', *n));
            out.push('}');
            out
        }
        Tok::Ups(_) | Tok::Code(_) => vec![],
    }
}

// ## Spacing

/// `Latex.endsAlpha`: `t` ends with letters a following letter would extend.
pub fn ends_alpha(t: &Tok) -> bool {
    match t {
        Tok::Letter(_) | Tok::Word(_) | Tok::Greek(_) => true,
        Tok::Kw(k) => kw_chars(*k).chars().last().is_some_and(is_letter),
        _ => false,
    }
}

/// `Latex.merges`: a space is needed between `t` and a following token starting
/// with `c`.
pub fn merges(t: &Tok, c: char) -> bool {
    (ends_alpha(t) && is_letter(c))
        || (matches!(t, Tok::Num(_)) && (is_dig(c) || c == '.' || c == 'e'))
        || (matches!(t, Tok::Kw(Kw::Minus)) && is_dig(c))
}

/// `Latex.needSpace`.
pub fn need_space(t1: &Tok, t2: &Tok) -> bool {
    match tok_chars(t2).first() {
        Some(&c) => merges(t1, c),
        None => false,
    }
}

/// `Latex.atomEnd`: tokens that end an operand.
pub fn atom_end(t: &Tok) -> bool {
    match t {
        Tok::Num(_)
        | Tok::Letter(_)
        | Tok::Greek(_)
        | Tok::Word(_)
        | Tok::It(_)
        | Tok::Rm(_)
        | Tok::Ups(_)
        | Tok::Txt(_)
        | Tok::Jstr(_)
        | Tok::Code(_)
        | Tok::Units(_) => true,
        Tok::Kw(k) => matches!(
            k,
            Kw::Rp | Kw::Rpg | Kw::Rb | Kw::Rbk | Kw::Rabs | Kw::Rfloor | Kw::Rceil | Kw::Ecases
        ),
        _ => false,
    }
}

/// `Latex.pretty`: spacing for reading.
pub fn pretty(p: Option<&Tok>, t1: &Tok, t2: &Tok) -> bool {
    is_bin(t1)
        || is_bin(t2)
        || matches!(t1, Tok::Kw(Kw::Comma | Kw::Colon | Kw::Semi))
        || (matches!(t2, Tok::Kw(Kw::Minus)) && atom_end(t1))
        || (matches!(t1, Tok::Kw(Kw::Minus)) && p.is_some_and(atom_end))
        || (atom_end(t1) && atom_start(t2) && !matches!(t2, Tok::Kw(Kw::Lp | Kw::Lbk)))
        || matches!(t1, Tok::Kw(Kw::Barr))
        || matches!(t2, Tok::Kw(Kw::Earr))
}

/// `Latex.sp`.
pub fn sp(p: Option<&Tok>, t1: &Tok, t2: &Tok) -> bool {
    need_space(t1, t2) || pretty(p, t1, t2)
}

/// `Latex.render`: the LaTeX spelling of a token list (`renderAux`).
pub fn render(ts: &[Tok]) -> Vec<char> {
    let mut out = Vec::new();
    for (i, t) in ts.iter().enumerate() {
        out.extend(tok_chars(t));
        if let Some(t2) = ts.get(i + 1) {
            let p = if i == 0 { None } else { ts.get(i - 1) };
            if sp(p, t, t2) {
                out.push(' ');
            }
        }
    }
    out
}

// ## Lexing

/// `Latex.ctrlKw`: control words that are keywords, with the variants read on
/// input.
pub const CTRL_KW: &[(&str, Kw)] = &[
    ("ne", Kw::Ne),
    ("neq", Kw::Ne),
    ("le", Kw::Le),
    ("leq", Kw::Le),
    ("ge", Kw::Ge),
    ("geq", Kw::Ge),
    ("land", Kw::Land),
    ("lor", Kw::Lor),
    ("lnot", Kw::Lnot),
    ("cdot", Kw::Cdot),
    ("times", Kw::Times),
    ("frac", Kw::Frac),
    ("sqrt", Kw::Sqrt),
    ("exp", Kw::Exp),
    ("ln", Kw::Ln),
    ("log", Kw::Log),
    ("sin", Kw::Sin),
    ("cos", Kw::Cos),
    ("tan", Kw::Tan),
    ("arcsin", Kw::Asin),
    ("arccos", Kw::Acos),
    ("arctan", Kw::Atan),
    ("sinh", Kw::Sinh),
    ("cosh", Kw::Cosh),
    ("tanh", Kw::Tanh),
    ("min", Kw::Min),
    ("max", Kw::Max),
    ("lfloor", Kw::Lfloor),
    ("rfloor", Kw::Rfloor),
    ("lceil", Kw::Lceil),
    ("rceil", Kw::Rceil),
    ("partial", Kw::Pdiff),
    ("nabla", Kw::Nabla),
    ("dot", Kw::Dotacc),
    ("sum", Kw::Sum),
    ("prod", Kw::Prod),
    ("in", Kw::Inn),
    ("substack", Kw::Substack),
    ("limits", Kw::LimitsL),
];

fn chars(s: &str) -> Vec<char> {
    s.chars().collect()
}

/// `Latex.carrTok`: after `\begin{array}{`: one or more `c` then `}`, the
/// column spec of a wide constant matrix.
pub fn carr_tok(r: &[char]) -> Option<(Tok, &[char])> {
    let n = r.iter().take_while(|&&c| c == 'c').count();
    match &r[n..] {
        ['}', r2 @ ..] if n > 0 => Some((Tok::Carr(n), r2)),
        _ => None,
    }
}

/// `Latex.ctrlTok`: after a control word: its token.
pub fn ctrl_tok<'a>(w: &str, r: &'a [char]) -> Option<(Tok, &'a [char])> {
    if ["mathit", "mathrm", "operatorname", "text", "esm"].contains(&w) {
        match r {
            ['{', r2 @ ..] => raw_b(0, r2).map(|(raw, rest)| {
                let s: String = raw.iter().collect();
                let u: String = unesc_t(&raw).into_iter().collect();
                let t = match w {
                    "mathit" => Tok::It(u),
                    "mathrm" => Tok::Rm(s),
                    "operatorname" => Tok::Opn(u),
                    "text" => text_tok(&raw),
                    _ => Tok::Esc(u),
                };
                (t, rest)
            }),
            _ => None,
        }
    } else if ["left", "bigl", "Bigl"].contains(&w) {
        match r {
            ['(', r2 @ ..] => Some((Tok::Kw(Kw::Lpg), r2)),
            ['[', r2 @ ..] => Some((Tok::Kw(if w == "left" { Kw::Lbkg } else { Kw::Lbk }), r2)),
            ['|', r2 @ ..] => {
                if w == "left" {
                    Some((Tok::Kw(Kw::Labs), r2))
                } else {
                    None
                }
            }
            _ => None,
        }
    } else if ["right", "bigr", "Bigr"].contains(&w) {
        match r {
            [')', r2 @ ..] => Some((Tok::Kw(Kw::Rpg), r2)),
            [']', r2 @ ..] => Some((Tok::Kw(if w == "right" { Kw::Rbkg } else { Kw::Rbk }), r2)),
            ['|', r2 @ ..] => {
                if w == "right" {
                    Some((Tok::Kw(Kw::Rabs), r2))
                } else {
                    None
                }
            }
            _ => None,
        }
    } else if w == "begin" {
        match drop_p(&chars("{cases}"), r) {
            Some(r2) => Some((Tok::Kw(Kw::Bcases), r2)),
            None => match drop_p(&chars("{bmatrix}"), r) {
                Some(r2) => Some((Tok::Kw(Kw::Bmat), r2)),
                None => match drop_p(&chars("{array}{l|l}"), r) {
                    Some(r2) => Some((Tok::Kw(Kw::Barr), r2)),
                    None => drop_p(&chars("{array}{"), r).and_then(carr_tok),
                },
            },
        }
    } else if w == "end" {
        match drop_p(&chars("{cases}"), r) {
            Some(r2) => Some((Tok::Kw(Kw::Ecases), r2)),
            None => match drop_p(&chars("{bmatrix}"), r) {
                Some(r2) => Some((Tok::Kw(Kw::Emat), r2)),
                None => drop_p(&chars("{array}"), r).map(|r2| (Tok::Kw(Kw::Earr), r2)),
            },
        }
    } else if is_greek(&chars(w)) {
        Some((Tok::Greek(w.to_string()), r))
    } else {
        CTRL_KW.iter().find(|p| p.0 == w).map(|p| (Tok::Kw(p.1), r))
    }
}

/// `Latex.isWsL`: white space.
pub fn is_ws_l(c: char) -> bool {
    matches!(c, ' ' | '\n' | '\t' | '\r')
}

/// `Latex.skipSp`: skip white space and the two-character spacing commands,
/// inside a scientific tail.
pub fn skip_sp(cs: &[char]) -> &[char] {
    let mut cs = cs;
    loop {
        match cs {
            [c, r @ ..] if is_ws_l(*c) => cs = r,
            ['\\', ';' | ':' | '!' | ' ' | ',', r @ ..] => cs = r,
            _ => return cs,
        }
    }
}

/// `Latex.sciExp`: the scientific tail `\times 10^{exponent}` after a mantissa,
/// with any spacing between its parts.
pub fn sci_exp(r: &[char]) -> Option<(i128, &[char])> {
    let r1 = drop_p(&chars("\\times"), skip_sp(r))?;
    if r1.first().is_some_and(|&c| is_letter(c)) {
        return None;
    }
    let r2 = drop_p(&['1', '0'], skip_sp(r1))?;
    let ['^', r3 @ ..] = skip_sp(r2) else {
        return None;
    };
    let ['{', r4 @ ..] = skip_sp(r3) else {
        return None;
    };
    let (z, r5) = number::parse_int(skip_sp(r4))?;
    match skip_sp(r5) {
        ['}', r6 @ ..] => Some((z, r6)),
        _ => None,
    }
}

/// `Latex.unitTok`: after `\,`: a unit `\mathrm{…}`, with white space between.
pub fn unit_tok(r: &[char]) -> Option<(Vec<Factor>, &[char])> {
    let n = r.iter().take_while(|&&c| is_ws_l(c)).count();
    let r1 = drop_p(units::MATHRM_OPEN, &r[n..])?;
    let (raw, r2) = raw_b(0, r1)?;
    units_of_raw(&raw).map(|l| (l, r2))
}

/// `Latex.punct`.
pub fn punct(c: char) -> Option<Kw> {
    Some(match c {
        '+' => Kw::Plus,
        '-' => Kw::Minus,
        '=' => Kw::Eq,
        '<' => Kw::Lt,
        '>' => Kw::Gt,
        '/' => Kw::Slash,
        '^' => Kw::Caret,
        '_' => Kw::Us,
        '(' => Kw::Lp,
        ')' => Kw::Rp,
        '{' => Kw::Lb,
        '}' => Kw::Rb,
        '[' => Kw::Lbk,
        ']' => Kw::Rbk,
        ',' => Kw::Comma,
        ';' => Kw::Semi,
        ':' => Kw::Colon,
        '&' => Kw::Amp,
        '.' => Kw::Sdot,
        _ => return None,
    })
}

/// `Latex.lexOne`: one token at the front of the input.
pub fn lex_one(cs: &[char]) -> Option<(Tok, &[char])> {
    match cs {
        ['\\', c, r @ ..] => {
            if is_letter(*c) {
                let (w, rest) = let_run(&cs[1..]);
                let w: String = w.iter().collect();
                ctrl_tok(&w, rest)
            } else if *c == ',' {
                unit_tok(r).map(|(l, r2)| (Tok::Units(l), r2))
            } else if *c == '\\' {
                Some((Tok::Kw(Kw::Nl), r))
            } else if *c == '{' {
                Some((Tok::Kw(Kw::Lset), r))
            } else if *c == '}' {
                Some((Tok::Kw(Kw::Rset), r))
            } else {
                None
            }
        }
        ['"', r @ ..] => {
            // `fixUs` changes nothing after the closing quote, so the rest is
            // the input's own suffix of the same length.
            let fixed = fix_us(r);
            let (body, rest) = strings::unquote_body(false, &fixed)?;
            let n = rest.len();
            Some((Tok::Jstr(body.into_iter().collect()), &r[r.len() - n..]))
        }
        [c, r @ ..] => {
            if is_dig(*c) || (*c == '-' && r.first().is_some_and(|&d| is_dig(d))) {
                lex_signed(sci_exp, cs)
            } else if is_letter(*c) {
                let (w, rest) = let_run(cs);
                match w {
                    [x] => Some((Tok::Letter(*x), rest)),
                    _ => Some((Tok::Word(w.iter().collect()), rest)),
                }
            } else {
                punct(*c).map(|k| (Tok::Kw(k), r))
            }
        }
        [] => None,
    }
}

/// `Latex.skipWs`: skip spaces and the spacing commands (`\,` too, unless a
/// unit follows it).
pub fn skip_ws(cs: &[char]) -> &[char] {
    let mut cs = cs;
    loop {
        match cs {
            [c, r @ ..] if is_ws_l(*c) => cs = r,
            ['\\', d, r2 @ ..] => {
                if matches!(d, ';' | ':' | '!' | ' ') {
                    cs = r2;
                } else if *d == ',' {
                    if unit_tok(r2).is_some() {
                        return cs;
                    }
                    cs = r2;
                } else {
                    let (w, rest) = let_run(&cs[1..]);
                    if w == ['q', 'u', 'a', 'd'] || w == ['q', 'q', 'u', 'a', 'd'] {
                        cs = rest;
                    } else {
                        return cs;
                    }
                }
            }
            _ => return cs,
        }
    }
}

/// `Latex.lex`: read LaTeX math into tokens (`lexAux`).
pub fn lex(cs: &[char]) -> Option<Vec<Tok>> {
    lex_at(cs).ok().map(|(toks, _)| toks)
}

/// [`lex`], with the character offset in `cs` where each token starts; on a
/// refusal, the offset where no token reads.
pub fn lex_at(cs: &[char]) -> Result<(Vec<Tok>, Vec<usize>), usize> {
    let mut out = Vec::new();
    let mut starts = Vec::new();
    let mut rest = cs;
    loop {
        let cs2 = skip_ws(rest);
        let at = cs.len() - cs2.len();
        if cs2.is_empty() {
            return Ok((out, starts));
        }
        let (t, r) = lex_one(cs2).ok_or(at)?;
        out.push(t);
        starts.push(at);
        rest = r;
    }
}
