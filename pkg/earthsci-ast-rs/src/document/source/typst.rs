//! The Typst container: markup plus the functions of the `esm` Typst package.
//!
//! Port of `formal/Esm/Document/Source/Typst.lean` (namespace `Source.Typ`).
//! The lexer reads a construct where one starts at the beginning of a line (a
//! declaration anywhere) and otherwise drops one character of prose. The Lean
//! fuel (the input length plus one, tripled for values) is never exhausted,
//! since every step consumes a character, so the port loops without it.
//!
//! Not ported: `Typ.segItems`, `Typ.eqnLabeled`, the `Seg.labeled` piece. No
//! executable path uses them; only the Lean proofs do.

use super::items::{RItem, Spanned};
use super::keys::Kvs;
use super::reaction::{RSurf, after, id_char, id_ok, p_piece, p_side, side_ok, side_txt};
use super::skeleton::{DKind, Decl, Kind, Role, Rxn, Tm};
use super::text::{after_s, blank, has_sub, pre_s, split_line, string, take_while};
use crate::document::json::Json;
use crate::document::math::expr::{jwf, name_ok};
use crate::document::math::{Sym, parse_typst, print_typst};
use crate::document::strings::{bare_key, is_ident, parse_quoted, quote, read_ident};
use crate::document::typst_dict;

// ## Spellings

pub const O_DESC: &str = "#description";
pub const O_BLOCK: &str = "#esm-block(";
pub const O_MODEL: &str = "#model(";
pub const O_RS: &str = "#reaction-system(";
pub const O_EQ: &str = "$ ";
pub const O_VAR: &str = "#var(";
pub const O_PARAM: &str = "#param(";
pub const O_SPECIES: &str = "#species(";
pub const O_CE: &str = "#ce[";
pub const O_RXN: &str = "#reaction(";
pub const O_INIT: &str = "#initialization[";
pub const O_CONS: &str = "#constraints[";
pub const O_PLOT: &str = "#plot(";
pub const O_SUB: &str = "#subsystem(";
pub const O_TMPL: &str = "#template(";
pub const O_RULE: &str = "#rule(";

/// `Typ.oRole`.
pub fn o_role(r: Role) -> &'static str {
    match r {
        Role::Init => O_INIT,
        Role::Cons => O_CONS,
        Role::Eqn => O_EQ,
    }
}

/// `Typ.header`: the header's first line and the start of its second.
pub const HEADER: &str = "#import \"@preview/esm:0.1.0\": *\n#show: esm-document.with(";

fn push_s(out: &mut Vec<char>, s: &str) {
    out.extend(s.chars());
}

// ## Description text
//
// A description is written verbatim as Typst markup, `#description[…]`, when
// `verb_ok` says that markup is safe to typeset, and as a Typst string,
// `#description("…")`, otherwise (`Typ.itemT`). The reader reads a content
// block as Typst does: a backslash escapes the next character and brackets nest.

/// `Typ.alnumA`: an ASCII letter or digit.
fn alnum_a(c: Option<&char>) -> bool {
    c.is_some_and(|c| c.is_ascii_alphanumeric())
}

/// `Typ.verbOK`: whether a description is written verbatim: none of
/// `# $ @ \ < * ~`, none of the sequences `//`, `/*`, `--`, `-?`, `...` (a
/// comment, or a Typst shorthand that would typeset differently from the
/// text), every `_` between two ASCII letters or digits, balanced brackets
/// outside backtick raw spans, none inside one, and every raw span closed.
pub fn verb_ok(cs: &[char]) -> bool {
    let mut depth = 0usize;
    let mut raw = false;
    for (i, &c) in cs.iter().enumerate() {
        let next = cs.get(i + 1).copied();
        match c {
            '#' | '$' | '@' | '\\' | '<' | '*' | '~' => return false,
            '/' if matches!(next, Some('/' | '*')) => return false,
            '-' if matches!(next, Some('-' | '?')) => return false,
            '.' if next == Some('.') && cs.get(i + 2) == Some(&'.') => return false,
            '_' if !(i > 0 && alnum_a(cs.get(i - 1)) && alnum_a(cs.get(i + 1))) => return false,
            '`' => raw = !raw,
            '[' | ']' if raw => return false,
            '[' => depth += 1,
            ']' => match depth.checked_sub(1) {
                Some(d) => depth = d,
                None => return false,
            },
            _ => {}
        }
    }
    depth == 0 && !raw
}

/// `Typ.readVerb 0 false`: the text of a content block up to the `]` that
/// closes it, as Typst reads it: outside a backtick raw span a backslash
/// escapes the next character (`\u{…}` is a code point) and brackets nest;
/// inside one every character is literal.
pub fn read_verb(mut s: &[char]) -> Option<(Vec<char>, &[char])> {
    let mut out = Vec::new();
    let mut depth = 0usize;
    let mut raw = false;
    loop {
        match s {
            [] => return None,
            ['`', r @ ..] => {
                out.push('`');
                raw = !raw;
                s = r;
            }
            [c, r @ ..] if raw => {
                out.push(*c);
                s = r;
            }
            [']', r @ ..] if depth == 0 => return Some((out, r)),
            ['\\', 'u', '{', r @ ..] => {
                let (c, r) = unicode_esc(r)?;
                out.push(c);
                s = r;
            }
            ['\\', c, r @ ..] => {
                out.push(*c);
                s = r;
            }
            [c, r @ ..] => {
                match c {
                    ']' => depth -= 1,
                    '[' => depth += 1,
                    _ => {}
                }
                out.push(*c);
                s = r;
            }
        }
    }
}

/// `Typ.readVerb`'s `\u{…}`: one or more hex digits then `}`, a Unicode
/// scalar value.
fn unicode_esc(s: &[char]) -> Option<(char, &[char])> {
    let n = s.iter().take_while(|c| c.is_ascii_hexdigit()).count();
    if n == 0 || s.get(n) != Some(&'}') {
        return None;
    }
    let v = u32::from_str_radix(&string(&s[..n]), 16).ok()?;
    char::from_u32(v).map(|c| (c, &s[n + 1..]))
}

/// `Typ.argT`: `key: value`.
pub fn arg_t(a: &(String, Json), out: &mut Vec<char>) {
    out.extend(a.0.chars());
    out.extend([':', ' ']);
    out.extend(typst_dict::encode(&a.1));
}

/// `Typ.pArg`: one named argument at its key.
pub fn p_arg(s: &[char]) -> Option<((String, Json), &[char])> {
    let (id, rest) = read_ident(s);
    let k = string(id);
    if !is_ident(id) || typst_dict::reserved(&k) {
        return None;
    }
    match rest {
        [':', ' ', u @ ..] => typst_dict::p_val(u).map(|(v, r)| ((k, v), r)),
        _ => None,
    }
}

/// `Typ.pArgsMore`: `, key: value` repeated, up to `)`.
pub fn p_args_more(mut s: &[char]) -> Option<(Kvs, &[char])> {
    let mut out = Vec::new();
    loop {
        match s {
            [')', r @ ..] => return Some((out, r)),
            [',', ' ', r @ ..] => {
                let (a, r1) = p_arg(r)?;
                out.push(a);
                s = r1;
            }
            _ => return None,
        }
    }
}

/// `Typ.pArgsFirst`: arguments directly after `(`.
pub fn p_args_first(s: &[char]) -> Option<(Kvs, &[char])> {
    match s {
        [')', r @ ..] => Some((vec![], r)),
        _ => {
            let (a, r) = p_arg(s)?;
            p_args_more(r).map(|(mut as_, r1)| {
                as_.insert(0, a);
                (as_, r1)
            })
        }
    }
}

/// `Typ.argsMoreT`: each `, key: value`.
pub fn args_more_t(as_: &[(String, Json)], out: &mut Vec<char>) {
    for a in as_ {
        out.extend([',', ' ']);
        arg_t(a, out);
    }
}

/// `Typ.argsFirstT`: arguments directly after `(`.
pub fn args_first_t(as_: &[(String, Json)], out: &mut Vec<char>) {
    if let [a, rest @ ..] = as_ {
        arg_t(a, out);
        args_more_t(rest, out);
    }
}

/// `Typ.argOK`: an identifier key that is not a keyword, and a well-formed
/// value.
pub fn arg_ok(a: &(String, Json)) -> bool {
    bare_key(typst_dict::reserved, &a.0) && jwf(&a.1)
}

// ## Constructs

/// `Typ.nameTyp`: a name as Typst math under the empty symbol table.
pub fn name_typ(n: &str) -> Vec<char> {
    print_typst(&Sym::default(), &Json::str(n))
        .chars()
        .collect()
}

/// `Typ.dkw`.
pub fn dkw(k: DKind) -> &'static str {
    match k {
        DKind::Var => O_VAR,
        DKind::Param => O_PARAM,
        DKind::Species => O_SPECIES,
        DKind::Sub => O_SUB,
    }
}

/// `Typ.declT`: `#var($N$, default: 100)`.
pub fn decl_t(d: &Decl) -> Vec<char> {
    let mut out: Vec<char> = dkw(d.kind).chars().collect();
    out.push('$');
    out.extend(name_typ(&d.name));
    out.push('$');
    args_more_t(&d.attrs, &mut out);
    out.push(')');
    out
}

/// `Typ.lineEnd`: the rest of a construct's line must be blank.
pub fn line_end(t: &[char]) -> Option<&[char]> {
    let (l, r) = split_line(t);
    blank(l).then_some(r)
}

// ## Reactions

/// `Typ.typR`: Typst math under the empty symbol table.
pub const TYP_R: RSurf = RSurf {
    pm: |s| parse_typst(&Sym::default(), s),
    prm: |j| print_typst(&Sym::default(), j).chars().collect(),
    empty: &['e', 'm', 'p', 't', 'y', 's', 'e', 't'],
};

/// `Typ.arrowL`.
pub const ARROW_L: &str = " ->[$";
/// `Typ.arrowR`.
pub const ARROW_R: &str = "] ";

/// `Typ.coreT`: the sides and the rate over the arrow.
pub fn core_t(x: &Rxn<String>) -> Vec<char> {
    let mut out = side_txt(&TYP_R, &x.subs);
    push_s(&mut out, ARROW_L);
    out.extend(x.rate.chars());
    out.push('$');
    push_s(&mut out, ARROW_R);
    out.extend(side_txt(&TYP_R, &x.prods));
    out
}

/// `Typ.rxnT`: `#ce[…] <id>`, or `#reaction(…)[#ce[…]] <id>`.
pub fn rxn_t(x: &Rxn<String>) -> Vec<char> {
    let mut out = Vec::new();
    if x.attrs.is_empty() {
        push_s(&mut out, O_CE);
        out.extend(core_t(x));
        out.extend([']', ' ', '<']);
    } else {
        push_s(&mut out, O_RXN);
        args_first_t(&x.attrs, &mut out);
        push_s(&mut out, ")[#ce[");
        out.extend(core_t(x));
        out.extend([']', ']', ' ', '<']);
    }
    out.extend(x.id.chars());
    out.extend(['>', '\n']);
    out
}

/// The pieces `coreAt` reads: subs, rate, prods, and the text after.
type Core<'a> = (
    Option<Vec<super::skeleton::Term>>,
    &'a [char],
    Option<Vec<super::skeleton::Term>>,
    &'a [char],
);

/// `Typ.coreAt`.
pub fn core_at(u: &[char]) -> Option<Core<'_>> {
    let (subs, u1) = p_side(&TYP_R, u)?;
    let u2 = after_s(ARROW_L, u1)?;
    let (rate, u2b) = p_piece(u2)?;
    let u3 = after_s(ARROW_R, u2b)?;
    let (prods, u4) = p_side(&TYP_R, u3)?;
    Some((subs, rate, prods, u4))
}

/// `Typ.labelAt`: the label `<id>` and the end of the line.
pub fn label_at(u: &[char]) -> Option<(String, &[char])> {
    let ['<', v @ ..] = u else { return None };
    match take_while(v, id_char) {
        (id, ['>', w @ ..]) => {
            if id.is_empty() {
                None
            } else {
                line_end(w).map(|r| (string(id), r))
            }
        }
        _ => None,
    }
}

/// `Typ.ceAt`: a reaction after `#ce[`.
pub fn ce_at(u: &[char]) -> Option<(RItem, &[char])> {
    let (subs, rate, prods, u4) = core_at(u)?;
    let u5 = after_s("] ", u4)?;
    label_at(u5).map(|(id, r)| {
        (
            RItem::Rxn(Rxn {
                id,
                subs,
                prods,
                rate: string(rate),
                attrs: vec![],
            }),
            r,
        )
    })
}

/// `Typ.rxnAtT`: a reaction after `#reaction(`.
pub fn rxn_at_t(u: &[char]) -> Option<(RItem, &[char])> {
    let (as_, u1) = p_args_first(u)?;
    let u2 = after_s("[#ce[", u1)?;
    let (subs, rate, prods, u4) = core_at(u2)?;
    let u5 = after_s("]] ", u4)?;
    label_at(u5).map(|(id, r)| {
        (
            RItem::Rxn(Rxn {
                id,
                subs,
                prods,
                rate: string(rate),
                attrs: as_,
            }),
            r,
        )
    })
}

// ## Templates and rules

pub const TM_OP: &str = "op(";
pub const TM_PAR: &str = ")(";
pub const TM_DEF_T: &str = ") := ";
pub const SEP_D: &str = ", $";

/// `Typ.paramsT`.
pub fn params_t(ps: &[String], out: &mut Vec<char>) {
    for (i, p) in ps.iter().enumerate() {
        if i > 0 {
            out.extend([',', ' ']);
        }
        out.extend(name_typ(p));
    }
}

/// `Typ.tmRawT`: the math text of a template display (one line).
pub fn tm_raw_t(t: &Tm<String>) -> Vec<char> {
    let mut out: Vec<char> = TM_OP.chars().collect();
    out.extend(quote(true, &t.name));
    push_s(&mut out, TM_PAR);
    params_t(&t.params, &mut out);
    push_s(&mut out, TM_DEF_T);
    out.extend(t.body.chars());
    out
}

/// `Typ.nameLenT`: the length of a parameter name's Typst math: up to the
/// first `,` or `)` outside parentheses and string literals.
pub fn name_len_t(s: &[char]) -> usize {
    let (mut d, mut q, mut n, mut i) = (0usize, false, 0usize, 0usize);
    while i < s.len() {
        let c = s[i];
        if q {
            if c == '\\' {
                if i + 1 < s.len() {
                    n += 2;
                    i += 2;
                } else {
                    return n + 1;
                }
            } else {
                n += 1;
                q = c != '"';
                i += 1;
            }
        } else if c == '"' {
            n += 1;
            q = true;
            i += 1;
        } else if c == '(' {
            n += 1;
            d += 1;
            i += 1;
        } else if c == ')' {
            if d == 0 {
                return n;
            }
            n += 1;
            d -= 1;
            i += 1;
        } else if c == ',' && d == 0 {
            return n;
        } else {
            n += 1;
            i += 1;
        }
    }
    n
}

/// `Typ.pNameT`: a parameter name in a template header.
pub fn p_name_t(s: &[char]) -> Option<(String, &[char])> {
    let k = name_len_t(s).min(s.len());
    match parse_typst(&Sym::default(), &string(&s[..k])) {
        Some(Json::Str(n)) => Some((n, &s[k..])),
        _ => None,
    }
}

/// `Typ.pParamsT`: the parameters up to `) := `.
pub fn p_params_t(mut s: &[char]) -> Option<(Vec<String>, &[char])> {
    let mut out = Vec::new();
    loop {
        if let Some(r) = after_s(TM_DEF_T, s) {
            return Some((out, r));
        }
        let (n, r) = p_name_t(s)?;
        out.push(n);
        if let Some(r1) = after_s(TM_DEF_T, r) {
            return Some((out, r1));
        }
        match r {
            [',', ' ', r1 @ ..] => s = r1,
            _ => return None,
        }
    }
}

/// `Typ.tmLexT`: read the math text of a display as a template: its name,
/// parameters and body text.
pub fn tm_lex_t(raw: &[char]) -> Option<(String, Vec<String>, Vec<char>)> {
    let u = after_s(TM_OP, raw)?;
    let (n, u1) = parse_quoted(true, u)?;
    let u2 = after_s(TM_PAR, u1)?;
    p_params_t(u2).map(|(ps, b)| (n, ps, b.to_vec()))
}

/// `Typ.itemT`: the text of a construct.
pub fn item_t(it: &RItem) -> Vec<char> {
    let mut out = Vec::new();
    match it {
        RItem::Desc(s) => {
            push_s(&mut out, O_DESC);
            let cs: Vec<char> = s.chars().collect();
            if verb_ok(&cs) {
                out.push('[');
                out.extend(cs);
                out.extend([']', '\n']);
            } else {
                out.push('(');
                out.extend(quote(true, s));
                out.extend([')', '\n']);
            }
        }
        RItem::Block(k, v) => {
            push_s(&mut out, O_BLOCK);
            out.extend(quote(true, k));
            out.extend([',', ' ']);
            out.extend(typst_dict::encode(v));
            out.extend([')', '\n']);
        }
        RItem::Comp(k, n) => {
            push_s(&mut out, if *k == Kind::Model { O_MODEL } else { O_RS });
            out.extend(quote(true, n));
            out.extend([')', '\n']);
        }
        RItem::Decl(d) => {
            if d.kind == DKind::Sub {
                push_s(&mut out, O_SUB);
                out.extend(quote(true, &d.name));
                args_more_t(&d.attrs, &mut out);
                out.extend([')', '\n']);
            } else {
                out = decl_t(d);
            }
        }
        RItem::Eqn(raw) => {
            push_s(&mut out, O_EQ);
            out.extend(raw.chars());
            out.extend([' ', '$', '\n']);
        }
        RItem::Eqx(r, raw) => {
            push_s(&mut out, o_role(*r));
            push_s(&mut out, O_EQ);
            out.extend(raw.chars());
            out.extend([' ', '$', ']', '\n']);
        }
        RItem::Rxn(x) => out = rxn_t(x),
        RItem::Plot(a) => {
            push_s(&mut out, O_PLOT);
            args_first_t(a, &mut out);
            out.extend([')', '\n']);
        }
        RItem::Tm(t) => match &t.lhs {
            Some(l) => {
                push_s(&mut out, O_RULE);
                out.extend(quote(true, &t.name));
                push_s(&mut out, SEP_D);
                out.extend(l.chars());
                out.push('$');
                push_s(&mut out, SEP_D);
                out.extend(t.body.chars());
                out.push('$');
                args_more_t(&t.attrs, &mut out);
                out.extend([')', '\n']);
            }
            None => {
                if t.attrs.is_empty() {
                    push_s(&mut out, O_EQ);
                    out.extend(tm_raw_t(t));
                    out.extend([' ', '$', '\n']);
                } else {
                    push_s(&mut out, O_TMPL);
                    args_first_t(&t.attrs, &mut out);
                    out.extend([')', '[']);
                    push_s(&mut out, O_EQ);
                    out.extend(tm_raw_t(t));
                    out.extend([' ', '$', ']', '\n']);
                }
            }
        },
    }
    out
}

/// `Typ.labelOK`: nothing, or `<id>`, with spaces around.
pub fn label_ok(sl: &[char]) -> bool {
    let (_, t) = take_while(sl, |c| c == ' ');
    match t {
        [] => true,
        ['<', r @ ..] => {
            matches!(r, [inner @ .., '>'] if !inner.contains(&'>') && !inner.contains(&'<'))
        }
        _ => false,
    }
}

// ## The lexer

/// `Typ.descOpen`: a description opener, `#description[` or `#description(`
/// (a line such as `#description-note[…]` is prose).
pub fn desc_open(s: &[char]) -> bool {
    pre_s(O_DESC, s) && matches!(s.get(O_DESC.len()), Some('[' | '('))
}

/// `Typ.blockOpen`.
pub fn block_open(s: &[char]) -> bool {
    desc_open(s)
        || [
            O_BLOCK, O_MODEL, O_RS, O_EQ, O_CE, O_RXN, O_INIT, O_CONS, O_PLOT, O_SUB, O_TMPL,
            O_RULE,
        ]
        .iter()
        .any(|o| pre_s(o, s))
}

/// `Typ.declOpen`.
pub fn decl_open(s: &[char]) -> bool {
    pre_s(O_VAR, s) || pre_s(O_PARAM, s) || pre_s(O_SPECIES, s)
}

/// `Typ.descAt`: a description after `#description`: a content block, or a
/// string in parentheses.
pub fn desc_at(u: &[char]) -> Option<(RItem, &[char])> {
    match u {
        ['[', v @ ..] => {
            let (t, r) = read_verb(v)?;
            line_end(r).map(|r1| (RItem::Desc(string(&t)), r1))
        }
        ['(', v @ ..] => match parse_quoted(true, v)? {
            (t, [')', r @ ..]) => line_end(r).map(|r1| (RItem::Desc(t), r1)),
            _ => None,
        },
        _ => None,
    }
}

/// `Typ.blockAtT`: a path block after `#esm-block(`.
pub fn block_at_t(u: &[char]) -> Option<(RItem, &[char])> {
    match parse_quoted(true, u) {
        Some((k, [',', ' ', w @ ..])) => match typst_dict::p_val(w) {
            Some((v, [')', r @ ..])) => line_end(r).map(|r1| (RItem::Block(k, v), r1)),
            _ => None,
        },
        _ => None,
    }
}

/// `Typ.compAt`.
pub fn comp_at(k: Kind, u: &[char]) -> Option<(RItem, &[char])> {
    match parse_quoted(true, u) {
        Some((n, [')', r @ ..])) => line_end(r).map(|r1| (RItem::Comp(k, n), r1)),
        _ => None,
    }
}

/// `Typ.dispItem`: a template when the display reads as one, else an
/// equation.
pub fn disp_item(raw: &[char]) -> RItem {
    match tm_lex_t(raw) {
        Some((n, ps, b)) => RItem::Tm(Tm {
            name: n,
            params: ps,
            lhs: None,
            body: string(&b),
            attrs: vec![],
        }),
        None => RItem::Eqn(string(raw)),
    }
}

/// `Typ.eqAt`: a display after its `$ `.
pub fn eq_at(u: &[char]) -> Option<(RItem, &[char])> {
    match take_while(u, |c| c != '$') {
        (body, ['$', r @ ..]) => {
            let (l, rest) = split_line(r);
            match body {
                [b @ .., ' '] if label_ok(l) => Some((disp_item(b), rest)),
                _ => None,
            }
        }
        _ => None,
    }
}

/// `Typ.tmplAtT`: a template with other fields, after `#template(`.
pub fn tmpl_at_t(u: &[char]) -> Option<(RItem, &[char])> {
    let (as_, u1) = p_args_first(u)?;
    let u2 = after(&['[', '$', ' '], u1)?;
    match p_piece(u2)? {
        ([b @ .., ' '], [']', r @ ..]) => {
            let (n, ps, bd) = tm_lex_t(b)?;
            line_end(r).map(|r1| {
                (
                    RItem::Tm(Tm {
                        name: n,
                        params: ps,
                        lhs: None,
                        body: string(&bd),
                        attrs: as_,
                    }),
                    r1,
                )
            })
        }
        _ => None,
    }
}

/// `Typ.ruleAtT`: a rule, after `#rule(`.
pub fn rule_at_t(u: &[char]) -> Option<(RItem, &[char])> {
    let (n, r) = parse_quoted(true, u)?;
    let r1 = after_s(SEP_D, r)?;
    let (l, r2) = p_piece(r1)?;
    let r3 = after_s(SEP_D, r2)?;
    let (b, r4) = p_piece(r3)?;
    let (as_, r5) = p_args_more(r4)?;
    line_end(r5).map(|r6| {
        (
            RItem::Tm(Tm {
                name: n,
                params: vec![],
                lhs: Some(string(l)),
                body: string(b),
                attrs: as_,
            }),
            r6,
        )
    })
}

/// `Typ.eqxAt`: an equation in a container after its opener: `$ … $]`.
pub fn eqx_at(ro: Role, u: &[char]) -> Option<(RItem, &[char])> {
    let v = after_s(O_EQ, u)?;
    match p_piece(v)? {
        ([b @ .., ' '], [']', r @ ..]) => line_end(r).map(|r1| (RItem::Eqx(ro, string(b)), r1)),
        _ => None,
    }
}

/// `Typ.subAtT`: a subsystem directive after `#subsystem(`.
pub fn sub_at_t(u: &[char]) -> Option<(RItem, &[char])> {
    let (n, r) = parse_quoted(true, u)?;
    let (a, r1) = p_args_more(r)?;
    line_end(r1).map(|r2| {
        (
            RItem::Decl(Decl {
                kind: DKind::Sub,
                name: n,
                attrs: a,
            }),
            r2,
        )
    })
}

/// `Typ.plotAtT`: a plot directive after `#plot(`.
pub fn plot_at_t(u: &[char]) -> Option<(RItem, &[char])> {
    let (a, r) = p_args_first(u)?;
    line_end(r).map(|r1| (RItem::Plot(a), r1))
}

/// `Typ.blockAt`: read the block construct that starts here.
pub fn block_at(s: &[char]) -> Option<(RItem, &[char])> {
    let d = |o: &str| &s[o.len()..];
    if pre_s(O_DESC, s) {
        desc_at(d(O_DESC))
    } else if pre_s(O_BLOCK, s) {
        block_at_t(d(O_BLOCK))
    } else if pre_s(O_MODEL, s) {
        comp_at(Kind::Model, d(O_MODEL))
    } else if pre_s(O_RS, s) {
        comp_at(Kind::Rs, d(O_RS))
    } else if pre_s(O_CE, s) {
        ce_at(d(O_CE))
    } else if pre_s(O_RXN, s) {
        rxn_at_t(d(O_RXN))
    } else if pre_s(O_INIT, s) {
        eqx_at(Role::Init, d(O_INIT))
    } else if pre_s(O_CONS, s) {
        eqx_at(Role::Cons, d(O_CONS))
    } else if pre_s(O_PLOT, s) {
        plot_at_t(d(O_PLOT))
    } else if pre_s(O_SUB, s) {
        sub_at_t(d(O_SUB))
    } else if pre_s(O_TMPL, s) {
        tmpl_at_t(d(O_TMPL))
    } else if pre_s(O_RULE, s) {
        rule_at_t(d(O_RULE))
    } else {
        eq_at(s.get(O_EQ.len()..).unwrap_or(&[]))
    }
}

/// `Typ.declBody`: a declaration after its opener.
pub fn decl_body(k: DKind, s: &[char]) -> Option<(RItem, &[char])> {
    let ['$', t @ ..] = s else { return None };
    match take_while(t, |c| c != '$') {
        (name, ['$', u @ ..]) => match parse_typst(&Sym::default(), &string(name)) {
            Some(Json::Str(n)) => p_args_more(u).map(|(a, r)| {
                (
                    RItem::Decl(Decl {
                        kind: k,
                        name: n,
                        attrs: a,
                    }),
                    r,
                )
            }),
            _ => None,
        },
        _ => None,
    }
}

/// `Typ.declAt`.
pub fn decl_at(s: &[char]) -> Option<(RItem, &[char])> {
    if pre_s(O_VAR, s) {
        decl_body(DKind::Var, &s[O_VAR.len()..])
    } else if pre_s(O_PARAM, s) {
        decl_body(DKind::Param, &s[O_PARAM.len()..])
    } else {
        decl_body(DKind::Species, s.get(O_SPECIES.len()..).unwrap_or(&[]))
    }
}

/// `Typ.lex`: the constructs of a text, skipping prose one character at a
/// time. Each construct comes with the range of `s` it is written in (Lean's
/// `lex` returns the constructs alone).
pub fn lex_spanned(mut bol: bool, mut s: &[char]) -> Option<Vec<Spanned>> {
    let len = s.len();
    let at = |s: &[char], rest: &[char]| (len - s.len())..(len - rest.len());
    let mut out = Vec::new();
    while let [c, r @ ..] = s {
        if bol && block_open(s) {
            let (it, rest) = block_at(s)?;
            out.push((it, at(s, rest)));
            s = rest;
            bol = true;
        } else if decl_open(s) {
            let (it, rest) = decl_at(s)?;
            out.push((it, at(s, rest)));
            s = rest;
            bol = false;
        } else {
            bol = *c == '\n';
            s = r;
        }
    }
    Some(out)
}

// ## What each construct needs to read back

/// `Typ.typsiumOK`: no `//` or `/*` in the chemistry.
pub fn typsium_ok(x: &Rxn<String>) -> bool {
    let mut t = side_txt(&TYP_R, &x.subs);
    t.extend(x.rate.chars());
    t.extend(side_txt(&TYP_R, &x.prods));
    !has_sub(&['/', '/'], &t) && !has_sub(&['/', '*'], &t)
}

/// `Typ.rxnOK`: a reaction the Typst syntax can hold.
pub fn rxn_ok(x: &Rxn<String>) -> bool {
    side_ok(&TYP_R, &x.subs)
        && side_ok(&TYP_R, &x.prods)
        && !x.rate.contains('$')
        && !x.rate.contains('\n')
        && id_ok(&x.id)
        && x.attrs.iter().all(arg_ok)
        && typsium_ok(x)
}

/// `Typ.declOK`.
pub fn decl_ok(d: &Decl) -> bool {
    name_ok(&d.name) && !name_typ(&d.name).contains(&'$') && d.attrs.iter().all(arg_ok)
}

/// `Typ.Seg`: a piece of a Typst document.
#[derive(Clone, Debug, PartialEq)]
pub enum Seg {
    Item(RItem),
    Prose(Vec<char>),
}

/// `Typ.segText`.
pub fn seg_text(s: &Seg) -> Vec<char> {
    match s {
        Seg::Item(it) => item_t(it),
        Seg::Prose(p) => p.clone(),
    }
}

/// `Typ.render`.
pub fn render(segs: &[Seg]) -> Vec<char> {
    segs.iter().flat_map(seg_text).collect()
}

/// `Typ.isBlock`.
pub fn is_block(it: &RItem) -> bool {
    match it {
        RItem::Decl(d) => d.kind == DKind::Sub,
        _ => true,
    }
}

/// `Typ.itemOK`: what each construct's content must satisfy for its text to
/// read back.
pub fn item_ok(it: &RItem) -> bool {
    match it {
        RItem::Desc(_) | RItem::Comp(..) => true,
        RItem::Block(_, v) => v.wfmb(),
        RItem::Decl(d) => {
            if d.kind == DKind::Sub {
                d.attrs.iter().all(arg_ok)
            } else {
                decl_ok(d)
            }
        }
        RItem::Eqn(raw) => {
            let rc: Vec<char> = raw.chars().collect();
            !raw.contains('$') && tm_lex_t(&rc).is_none()
        }
        RItem::Eqx(r, raw) => *r != Role::Eqn && !raw.contains('$'),
        RItem::Rxn(x) => rxn_ok(x),
        RItem::Plot(a) => a.iter().all(arg_ok),
        RItem::Tm(t) => {
            t.attrs.iter().all(arg_ok)
                && match &t.lhs {
                    Some(l) => !l.contains('$') && !t.body.contains('$') && t.params.is_empty(),
                    None => {
                        let raw = tm_raw_t(t);
                        !raw.contains(&'$')
                            && tm_lex_t(&raw)
                                == Some((
                                    t.name.clone(),
                                    t.params.clone(),
                                    t.body.chars().collect(),
                                ))
                    }
                }
        }
    }
}
