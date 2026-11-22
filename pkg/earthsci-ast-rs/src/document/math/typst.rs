//! Typst math: spelling and lexing of tokens.
//!
//! Port of `formal/Esm/Document/Math/Typst.lean`. Typst has one parenthesis:
//! the lexer reads `(` right after a name, a digit, `)` or `"` as a call
//! parenthesis and any other `(` as a grouping one; the renderer writes no
//! space between a function name and its `(` and a space between an operand
//! and a following grouping `(`.
//!
//! The Lean lexer (`lexAux`, `pieces`, `pSepBy`) carries fuel equal to the
//! input length, never exhausted (every step consumes a character); the port
//! loops without it.
//!
//! Not ported: `Typst.isHead`. No executable path uses it; only the Lean proofs
//! do.

use super::expr::{dig_run, is_dig, is_greek, is_letter};
use super::parse::atom_start;
use super::surface::{drop_p, is_bin, lex_signed, sci_split};
use super::token::{Kw, Tok};
use super::units::{self, Factor};
use crate::document::json::JNum;
use crate::document::{number, strings, typst_dict};

// ## Spelling

/// `Typst.timesTen`.
pub const TIMES_TEN: &str = " times 10^";

/// `Typst.numChars`.
pub fn num_chars(n: &JNum) -> Vec<char> {
    match sci_split(n) {
        Some((m, e)) => {
            let mut out = m;
            out.extend(TIMES_TEN.chars());
            if e < 0 {
                out.push('(');
                out.extend(number::print_int(e as i128));
                out.push(')');
            } else {
                out.extend(number::print_int(e as i128));
            }
            out
        }
        None => number::print(n),
    }
}

/// `Typst.kwChars`.
pub fn kw_chars(k: Kw) -> &'static str {
    match k {
        Kw::Plus => "+",
        Kw::Minus => "-",
        Kw::Eq => "=",
        Kw::Ne => "!=",
        Kw::Lt => "<",
        Kw::Gt => ">",
        Kw::Le => "<=",
        Kw::Ge => ">=",
        Kw::Land => "and",
        Kw::Lor => "or",
        Kw::Lnot => "not",
        Kw::Cdot => "dot",
        Kw::Times => "times",
        Kw::Slash => "/",
        Kw::Caret => "^",
        Kw::Us => "_",
        Kw::Lp | Kw::Lpg => "(",
        Kw::Rp => ")",
        Kw::Lbk => "[",
        Kw::Rbk => "]",
        Kw::Comma => ",",
        Kw::Semi => ";",
        Kw::Colon => ":",
        Kw::Amp => "&",
        Kw::Sdot => "\".\"",
        Kw::Sqrt => "sqrt",
        Kw::Exp => "exp",
        Kw::Ln => "ln",
        Kw::Log => "log",
        Kw::Sin => "sin",
        Kw::Cos => "cos",
        Kw::Tan => "tan",
        Kw::Asin => "arcsin",
        Kw::Acos => "arccos",
        Kw::Atan => "arctan",
        Kw::Sinh => "sinh",
        Kw::Cosh => "cosh",
        Kw::Tanh => "tanh",
        Kw::Min => "min",
        Kw::Max => "max",
        Kw::Abs => "abs",
        Kw::Floor => "floor",
        Kw::Ceil => "ceil",
        Kw::Pdiff => "partial",
        Kw::Nabla => "nabla",
        Kw::Dif => "dif",
        Kw::Cases => "cases",
        Kw::Esmnode => "esm.node",
        Kw::Vec => "vec",
        Kw::Mat => "mat",
        Kw::Sum => "sum",
        Kw::Prod => "product",
        Kw::Inn => "in",
        Kw::Limits => "limits",
        Kw::Lr => "lr",
        Kw::Nl => "\\",
        Kw::Lset => "{",
        Kw::Rset => "}",
        Kw::Rpg
        | Kw::Lb
        | Kw::Rb
        | Kw::Frac
        | Kw::Labs
        | Kw::Rabs
        | Kw::Lfloor
        | Kw::Rfloor
        | Kw::Lceil
        | Kw::Rceil
        | Kw::Dotacc
        | Kw::Bcases
        | Kw::Ecases
        | Kw::Bmat
        | Kw::Emat
        | Kw::Substack
        | Kw::Lbkg
        | Kw::Rbkg
        | Kw::LimitsL
        | Kw::Barr
        | Kw::Earr => "",
    }
}

/// `Typst.pieceChars`.
pub fn piece_chars(p: &(String, String)) -> Vec<char> {
    let mut out: Vec<char> = "upright(".chars().collect();
    out.extend(strings::quote(true, &p.0));
    out.push(')');
    if !p.1.is_empty() {
        out.push('_');
        out.extend(p.1.chars());
    }
    out
}

/// `Typst.unitChars`.
pub fn unit_chars(l: &[Factor]) -> Vec<char> {
    let mut out: Vec<char> = "thin ".chars().collect();
    out.extend(units::join_with(units::typst_factor, units::THIN_SEP, l));
    out
}

/// `Typst.tokChars`.
pub fn tok_chars(t: &Tok) -> Vec<char> {
    let call = |head: &str, s: &str| {
        let mut out: Vec<char> = head.chars().collect();
        out.extend(strings::quote(true, s));
        out.push(')');
        out
    };
    match t {
        Tok::Num(n) => num_chars(n),
        Tok::Letter(c) => vec![*c],
        Tok::Greek(g) => g.chars().collect(),
        Tok::Word(s) => s.chars().collect(),
        Tok::It(s) => call("italic(", s),
        Tok::Ups(ps) => ps.iter().flat_map(piece_chars).collect(),
        Tok::Opn(s) => call("op(", s),
        Tok::Txt(s) => strings::quote(true, s),
        Tok::Code(j) => std::iter::once('#').chain(typst_dict::encode(j)).collect(),
        Tok::Units(l) => unit_chars(l),
        Tok::Kw(k) => kw_chars(*k).chars().collect(),
        Tok::Rm(_) | Tok::Jstr(_) | Tok::Esc(_) | Tok::Carr(_) => vec![],
    }
}

// ## Spacing

/// `Typst.isIdC`.
pub fn is_id_c(c: char) -> bool {
    is_letter(c) || is_dig(c)
}

/// `Typst.merges`: a space is needed between `t` and a following token
/// starting with `c`.
pub fn merges(t: &Tok, c: char) -> bool {
    tok_chars(t)
        .last()
        .is_some_and(|&d| is_letter(d) && is_id_c(c))
        || (matches!(t, Tok::Num(_)) && (is_id_c(c) || c == '.'))
        || (matches!(t, Tok::Kw(Kw::Minus)) && is_dig(c))
        || (matches!(t, Tok::Ups(_)) && (is_dig(c) || c == 'u' || c == '_'))
        || (matches!(t, Tok::Code(_)) && is_id_c(c))
        || (matches!(t, Tok::Units(_)) && (is_dig(c) || c == '^'))
        || (matches!(t, Tok::Kw(Kw::Lt | Kw::Gt)) && c == '=')
        || (matches!(t, Tok::Kw(Kw::Slash)) && c == '/')
}

/// `Typst.callEnd`: `t` ends with a character after which `(` is a call
/// parenthesis.
pub fn call_end(t: &Tok) -> bool {
    tok_chars(t)
        .last()
        .is_some_and(|&d| is_id_c(d) || d == ')' || d == '"')
}

/// `Typst.needSpace`.
pub fn need_space(t1: &Tok, t2: &Tok) -> bool {
    match t2 {
        Tok::Kw(Kw::Lpg) => call_end(t1),
        Tok::Kw(Kw::Lp) => false,
        _ => match tok_chars(t2).first() {
            Some(&c) => merges(t1, c),
            None => false,
        },
    }
}

/// `Typst.atomEnd`.
pub fn atom_end(t: &Tok) -> bool {
    match t {
        Tok::Num(_)
        | Tok::Letter(_)
        | Tok::Greek(_)
        | Tok::Word(_)
        | Tok::It(_)
        | Tok::Ups(_)
        | Tok::Txt(_)
        | Tok::Code(_)
        | Tok::Units(_) => true,
        Tok::Kw(k) => matches!(k, Kw::Rp | Kw::Rbk),
        _ => false,
    }
}

/// `Typst.pretty`.
pub fn pretty(p: Option<&Tok>, t1: &Tok, t2: &Tok) -> bool {
    is_bin(t1)
        || is_bin(t2)
        || matches!(t1, Tok::Kw(Kw::Comma | Kw::Colon | Kw::Semi))
        || (matches!(t2, Tok::Kw(Kw::Minus)) && atom_end(t1))
        || (matches!(t1, Tok::Kw(Kw::Minus)) && p.is_some_and(atom_end))
        || (atom_end(t1) && atom_start(t2))
        || matches!(t2, Tok::Units(_))
}

/// `Typst.sp`: no space before a call parenthesis, nor before the `[` of an
/// index.
pub fn sp(p: Option<&Tok>, t1: &Tok, t2: &Tok) -> bool {
    need_space(t1, t2)
        || (pretty(p, t1, t2)
            && !matches!(t2, Tok::Kw(Kw::Lp))
            && !(matches!(t2, Tok::Kw(Kw::Lbk)) && atom_end(t1)))
}

/// `Typst.render` (`renderAux`).
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

/// `Typst.idRun`: the maximal run of identifier characters.
pub fn id_run(cs: &[char]) -> (&[char], &[char]) {
    let n = cs.iter().take_while(|&&c| is_id_c(c)).count();
    cs.split_at(n)
}

/// `Typst.identKw`.
pub const IDENT_KW: &[(&str, Kw)] = &[
    ("and", Kw::Land),
    ("or", Kw::Lor),
    ("not", Kw::Lnot),
    ("dot", Kw::Cdot),
    ("times", Kw::Times),
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
    ("abs", Kw::Abs),
    ("floor", Kw::Floor),
    ("ceil", Kw::Ceil),
    ("partial", Kw::Pdiff),
    ("nabla", Kw::Nabla),
    ("dif", Kw::Dif),
    ("cases", Kw::Cases),
    ("vec", Kw::Vec),
    ("mat", Kw::Mat),
    ("sum", Kw::Sum),
    ("product", Kw::Prod),
    ("in", Kw::Inn),
    ("limits", Kw::Limits),
    ("lr", Kw::Lr),
];

/// `Typst.quotedArg`: `("…")` after a function name.
pub fn quoted_arg(r: &[char]) -> Option<(String, &[char])> {
    match r {
        ['(', r1 @ ..] => match strings::parse_quoted(true, r1) {
            Some((s, [')', r2 @ ..])) => Some((s, r2)),
            _ => None,
        },
        _ => None,
    }
}

/// `Typst.pieces`: adjacent `upright("…")` pieces, each with an optional digit
/// subscript.
pub fn upright_pieces(cs: &[char]) -> (Vec<(String, String)>, &[char]) {
    let upright: Vec<char> = "upright".chars().collect();
    let mut out = Vec::new();
    let mut cs = cs;
    loop {
        let Some(r) = drop_p(&upright, cs) else {
            return (out, cs);
        };
        let Some((s, r1)) = quoted_arg(r) else {
            return (out, cs);
        };
        let (d, rest): (&[char], &[char]) = match r1 {
            ['_', r2 @ ..] => {
                let (q, r3) = dig_run(r2);
                if q.is_empty() { (&[], r1) } else { (q, r3) }
            }
            _ => (&[], r1),
        };
        out.push((s, d.iter().collect()));
        cs = rest;
    }
}

/// `Typst.isWsT`.
pub fn is_ws_t(c: char) -> bool {
    matches!(c, ' ' | '\n' | '\t' | '\r')
}

fn skip(cs: &[char]) -> &[char] {
    let n = cs.iter().take_while(|&&c| is_ws_t(c)).count();
    &cs[n..]
}

/// `Typst.sciExp`: the scientific tail `times 10^exponent` after a mantissa
/// (the exponent bare or in parentheses), with any white space between its
/// parts.
pub fn sci_exp(r: &[char]) -> Option<(i128, &[char])> {
    let times: Vec<char> = "times".chars().collect();
    let r1 = drop_p(&times, skip(r))?;
    if r1.first().is_some_and(|&c| is_id_c(c)) {
        return None;
    }
    let r2 = drop_p(&['1', '0'], skip(r1))?;
    let ['^', r3 @ ..] = skip(r2) else {
        return None;
    };
    match skip(r3) {
        ['(', r4 @ ..] => {
            let (z, r5) = number::parse_int(skip(r4))?;
            match skip(r5) {
                [')', r6 @ ..] => Some((z, r6)),
                _ => None,
            }
        }
        r4 => number::parse_int(r4),
    }
}

/// `Typst.punct`.
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
        ')' => Kw::Rp,
        '[' => Kw::Lbk,
        ']' => Kw::Rbk,
        ',' => Kw::Comma,
        ';' => Kw::Semi,
        ':' => Kw::Colon,
        '&' => Kw::Amp,
        '.' => Kw::Sdot,
        '\\' => Kw::Nl,
        '{' => Kw::Lset,
        '}' => Kw::Rset,
        _ => return None,
    })
}

/// `Typst.uprightE`: `upright(e)`, Euler's number written without quotes.
pub fn upright_e(cs: &[char]) -> Option<(Tok, &[char])> {
    match cs {
        ['(', 'e', ')', r @ ..] => Some((Tok::Ups(vec![("e".into(), String::new())]), r)),
        _ => None,
    }
}

/// `Typst.lexIdent`: one identifier-started token.
pub fn lex_ident(cs: &[char]) -> Option<(Tok, &[char])> {
    let (w, rest) = id_run(cs);
    let ws: String = w.iter().collect();
    match ws.as_str() {
        "upright" => match upright_e(rest) {
            Some(q) => Some(q),
            None => match upright_pieces(cs) {
                (ps, _) if ps.is_empty() => None,
                (ps, r) => Some((Tok::Ups(ps), r)),
            },
        },
        "italic" => quoted_arg(rest).map(|(s, r)| (Tok::It(s), r)),
        "op" => quoted_arg(rest).map(|(s, r)| (Tok::Opn(s), r)),
        "thin" => match rest {
            [' ', r @ ..] => units::p_sep_by(units::p_t_factor, units::THIN_SEP, r)
                .map(|(l, r2)| (Tok::Units(l), r2)),
            _ => None,
        },
        "esm" => {
            let node: Vec<char> = ".node".chars().collect();
            drop_p(&node, rest).map(|r| (Tok::Kw(Kw::Esmnode), r))
        }
        _ => match IDENT_KW.iter().find(|p| p.0 == ws) {
            Some(p) => Some((Tok::Kw(p.1), rest)),
            None => {
                if is_greek(w) {
                    Some((Tok::Greek(ws), rest))
                } else {
                    match w {
                        [c] => Some((Tok::Letter(*c), rest)),
                        _ => Some((Tok::Word(ws), rest)),
                    }
                }
            }
        },
    }
}

/// `Typst.lexOne`: one token at the front of the input; `prev` is the
/// character just before it, if no space came between.
pub fn lex_one(prev: Option<char>, cs: &[char]) -> Option<(Tok, &[char])> {
    match cs {
        ['(', r @ ..] => match prev {
            Some(d) if is_id_c(d) || d == ')' || d == '"' => Some((Tok::Kw(Kw::Lp), r)),
            _ => Some((Tok::Kw(Kw::Lpg), r)),
        },
        ['"', ..] => strings::parse_quoted(true, cs).map(|(s, r)| {
            if s == "." {
                (Tok::Kw(Kw::Sdot), r)
            } else {
                (Tok::Txt(s), r)
            }
        }),
        ['#', r @ ..] => typst_dict::p_val(r).map(|(v, r2)| (Tok::Code(v), r2)),
        ['<', '=', r @ ..] => Some((Tok::Kw(Kw::Le), r)),
        ['>', '=', r @ ..] => Some((Tok::Kw(Kw::Ge), r)),
        ['!', '=', r @ ..] => Some((Tok::Kw(Kw::Ne), r)),
        [c, r @ ..] => {
            if is_dig(*c) || (*c == '-' && r.first().is_some_and(|&d| is_dig(d))) {
                lex_signed(sci_exp, cs)
            } else if is_letter(*c) {
                lex_ident(cs)
            } else {
                punct(*c).map(|k| (Tok::Kw(k), r))
            }
        }
        [] => None,
    }
}

/// `Typst.lex`: read Typst math into tokens (`lexAux`). `prev` is the last
/// character of the previous token's canonical spelling when no space came
/// between.
pub fn lex(cs: &[char]) -> Option<Vec<Tok>> {
    lex_at(cs).ok().map(|(toks, _)| toks)
}

/// [`lex`], with the character offset in `cs` where each token starts; on a
/// refusal, the offset where no token reads.
pub fn lex_at(cs: &[char]) -> Result<(Vec<Tok>, Vec<usize>), usize> {
    let mut out = Vec::new();
    let mut starts = Vec::new();
    let mut prev: Option<char> = None;
    let mut rest = cs;
    loop {
        let prev2 = if rest.first().is_some_and(|&c| is_ws_t(c)) {
            None
        } else {
            prev
        };
        let cs2 = skip(rest);
        let at = cs.len() - cs2.len();
        if cs2.is_empty() {
            return Ok((out, starts));
        }
        let (t, r) = lex_one(prev2, cs2).ok_or(at)?;
        prev = tok_chars(&t).last().copied();
        out.push(t);
        starts.push(at);
        rest = r;
    }
}
