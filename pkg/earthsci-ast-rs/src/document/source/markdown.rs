//! The Markdown container: CommonMark with `$…$` / `$$…$$` LaTeX math, fenced
//! blocks, YAML front matter and remark directives.
//!
//! Port of `formal/Esm/Document/Source/Markdown.lean` (namespace
//! `Source.Md`). The lexer reads a construct where one starts and otherwise
//! drops one character of prose; a code span is skipped whole. The Lean
//! functions carry fuel that the document reader gives as the input length
//! plus one, and every step consumes a character, so the port loops without
//! it.
//!
//! Not ported: `Md.segItems`, `Md.eqnLabeled`, `Md.dispTxt`, `Md.kindWord`,
//! `Md.colText`, `Md.cellText`, `Md.rowText`, `Md.tableText`, the `Seg.labeled`
//! and `Seg.code` pieces. No executable path uses them; only the Lean proofs
//! do.

use super::items::{RItem, Spanned};
use super::keys::Kvs;
use super::reaction::{RSurf, id_char, id_ok, p_piece, p_side, side_ok, side_txt};
use super::skeleton::{DKind, Decl, Kind, Role, Rxn, Tm};
use super::text::{
    after_s, blank, has_sub, no_stop, pre, pre_s, split_line, string, take_while, until_stop,
};
use crate::document::json::Json;
use crate::document::math::expr::name_ok;
use crate::document::math::{Sym, esc_t, parse_latex, print_latex, raw_b, unesc_t};
use crate::document::strings::{
    esc_char, hex4, is_ident, parse_key, parse_quoted, print_key, read_ident,
};
use crate::document::yaml;

// ## Spellings

/// `Md.fenceEsm`.
pub const FENCE_ESM: &str = "```esm:";
/// `Md.fence`.
pub const FENCE: &str = "```";
/// `Md.dd`.
pub const DD: &str = "$$";
/// `Md.dModel`.
pub const D_MODEL: &str = "::model[";
/// `Md.dRs`.
pub const D_RS: &str = "::reaction-system[";
/// `Md.dashes`.
pub const DASHES: &str = "---";
/// `Md.descInfo`.
pub const DESC_INFO: &str = "description";
/// `Md.dPlot`.
pub const D_PLOT: &str = "::plot{";
/// `Md.dRxn`.
pub const D_RXN: &str = "$$\\ce{";
/// `Md.dInit`.
pub const D_INIT: &str = ":::initialization";
/// `Md.dCons`.
pub const D_CONS: &str = ":::constraints";
/// `Md.dEnd`.
pub const D_END: &str = ":::";
/// `Md.dSub`.
pub const D_SUB: &str = "::subsystem[";

/// `Md.dRole`.
pub fn d_role(r: Role) -> &'static str {
    match r {
        Role::Init => D_INIT,
        Role::Cons => D_CONS,
        Role::Eqn => D_END,
    }
}

/// `Md.dkw`: the directive keyword of a declaration.
pub fn dkw(k: DKind) -> &'static str {
    match k {
        DKind::Var => "var",
        DKind::Param => "param",
        DKind::Species => "species",
        DKind::Sub => "subsystem",
    }
}

fn push_s(out: &mut Vec<char>, s: &str) {
    out.extend(s.chars());
}

// ## Path-block keys

/// `Md.escKey`: the JSON escape, and the backtick as ```.
pub fn esc_key(c: char, out: &mut Vec<char>) {
    if c == '`' {
        out.extend(['\\', 'u']);
        out.extend(hex4(c as u32));
    } else {
        esc_char(false, c, out);
    }
}

/// `Md.keyMd`: a path block's key in the fence's info string.
pub fn key_md(k: &str) -> Vec<char> {
    let kc: Vec<char> = k.chars().collect();
    if is_ident(&kc) && k != DESC_INFO {
        kc
    } else {
        let mut out = vec!['"'];
        for c in kc {
            esc_key(c, &mut out);
        }
        out.push('"');
        out
    }
}

/// `Md.parseKeyMd`: a path block's key from the whole info string.
pub fn parse_key_md(info: &[char]) -> Option<String> {
    match info {
        ['"', ..] => match parse_quoted(false, info) {
            Some((k, [])) => Some(k),
            _ => None,
        },
        _ => {
            if is_ident(info) && string(info) != DESC_INFO {
                Some(string(info))
            } else {
                None
            }
        }
    }
}

// ## Declarations

/// `Md.nameLatex`: a declared name as LaTeX math under the empty symbol table.
pub fn name_latex(n: &str) -> Vec<char> {
    print_latex(&Sym::default(), &Json::str(n))
        .chars()
        .collect()
}

// ## Attribute values: YAML scalars and flow collections

/// `Md.flow`: a value as a YAML scalar or flow collection.
pub fn flow(v: &Json, out: &mut Vec<char>) {
    match v {
        Json::Arr(xs) if !xs.is_empty() => {
            out.push('[');
            for (i, x) in xs.iter().enumerate() {
                if i > 0 {
                    out.extend([',', ' ']);
                }
                flow(x, out);
            }
            out.push(']');
        }
        Json::Obj(kvs) if !kvs.is_empty() => {
            out.push('{');
            for (i, (k, x)) in kvs.iter().enumerate() {
                if i > 0 {
                    out.extend([',', ' ']);
                }
                out.extend(print_key(false, yaml::reserved, k));
                out.extend([':', ' ']);
                flow(x, out);
            }
            out.push('}');
        }
        v => out.extend(yaml::inline(v)),
    }
}

/// [`flow`] as a new vector.
pub fn flow_v(v: &Json) -> Vec<char> {
    let mut out = Vec::new();
    flow(v, &mut out);
    out
}

/// `Md.pFlow`: a flow collection at `[` or `{`, else a scalar.
pub fn p_flow(s: &[char]) -> Option<(Json, &[char])> {
    let _nest = crate::document::limits::Nest::enter()?;
    match s {
        [] => None,
        ['[', r @ ..] => {
            if let [']', r1 @ ..] = r {
                return Some((Json::Arr(vec![]), r1));
            }
            let (x, r1) = p_flow(r)?;
            p_items_f(r1).map(|(mut xs, r2)| {
                xs.insert(0, x);
                (Json::Arr(xs), r2)
            })
        }
        ['{', r @ ..] => {
            if let ['}', r1 @ ..] = r {
                return Some((Json::Obj(vec![]), r1));
            }
            let (e, r1) = p_entry_f(r)?;
            p_entries_f(r1).map(|(mut es, r2)| {
                es.insert(0, e);
                (Json::Obj(es), r2)
            })
        }
        _ => yaml::p_inline(s),
    }
}

/// `Md.pItemsF`: the elements after the first, each after `, `, up to `]`.
pub fn p_items_f(mut s: &[char]) -> Option<(Vec<Json>, &[char])> {
    let mut out = Vec::new();
    loop {
        match s {
            [']', r @ ..] => return Some((out, r)),
            [',', ' ', r @ ..] => {
                let (x, r1) = p_flow(r)?;
                out.push(x);
                s = r1;
            }
            _ => return None,
        }
    }
}

/// `Md.pEntryF`: one entry, `key: value`.
pub fn p_entry_f(s: &[char]) -> Option<((String, Json), &[char])> {
    match parse_key(false, yaml::reserved, s) {
        Some((k, [':', ' ', r @ ..])) => p_flow(r).map(|(v, r1)| ((k, v), r1)),
        _ => None,
    }
}

/// `Md.pEntriesF`: the entries after the first, each after `, `, up to `}`.
pub fn p_entries_f(mut s: &[char]) -> Option<(Kvs, &[char])> {
    let mut out = Vec::new();
    loop {
        match s {
            ['}', r @ ..] => return Some((out, r)),
            [',', ' ', r @ ..] => {
                let (e, r1) = p_entry_f(r)?;
                out.push(e);
                s = r1;
            }
            _ => return None,
        }
    }
}

/// `Md.isColl`.
pub fn is_coll(v: &Json) -> bool {
    matches!(v, Json::Arr(_) | Json::Obj(_))
}

/// `Md.sqEsc`: `'` as `&#39;` and `&` as `&amp;`.
pub fn sq_esc(cs: &[char]) -> Vec<char> {
    let mut out = Vec::with_capacity(cs.len());
    for &c in cs {
        match c {
            '\'' => push_s(&mut out, "&#39;"),
            '&' => push_s(&mut out, "&amp;"),
            c => out.push(c),
        }
    }
    out
}

/// `Md.sqUnesc`: undo `sqEsc`.
pub fn sq_unesc(mut cs: &[char]) -> Vec<char> {
    let mut out = Vec::with_capacity(cs.len());
    loop {
        match cs {
            ['&', '#', '3', '9', ';', r @ ..] => {
                out.push('\'');
                cs = r;
            }
            ['&', 'a', 'm', 'p', ';', r @ ..] => {
                out.push('&');
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

/// `Md.attrVal`: a scalar as its YAML, a list or object single-quoted.
pub fn attr_val(v: &Json) -> Vec<char> {
    if is_coll(v) {
        let mut out = vec!['\''];
        out.extend(sq_esc(&flow_v(v)));
        out.push('\'');
        out
    } else {
        flow_v(v)
    }
}

/// `Md.attrMd`: `key=value`.
pub fn attr_md(a: &(String, Json), out: &mut Vec<char>) {
    out.extend(a.0.chars());
    out.push('=');
    out.extend(attr_val(&a.1));
}

/// `Md.attrsMd`: the attributes, separated by spaces.
pub fn attrs_md(attrs: &[(String, Json)], out: &mut Vec<char>) {
    for (i, a) in attrs.iter().enumerate() {
        if i > 0 {
            out.push(' ');
        }
        attr_md(a, out);
    }
}

/// `Md.declMd`: `:var[$N$]{default=100 units="mol"}`.
pub fn decl_md(d: &Decl) -> Vec<char> {
    let mut out = vec![':'];
    push_s(&mut out, dkw(d.kind));
    out.extend(['[', '$']);
    out.extend(name_latex(&d.name));
    out.extend(['$', ']', '{']);
    attrs_md(&d.attrs, &mut out);
    out.push('}');
    out
}

/// `Md.pQuoted`: a single-quoted value after its opening quote.
pub fn p_quoted(u: &[char]) -> Option<(Json, &[char])> {
    match take_while(u, |c| c != '\'') {
        (inner, ['\'', r @ ..]) => {
            let y = sq_unesc(inner);
            match p_flow(&y) {
                Some((v, [])) => Some((v, r)),
                _ => None,
            }
        }
        _ => None,
    }
}

/// `Md.pAttr`: one attribute.
pub fn p_attr(s: &[char]) -> Option<((String, Json), &[char])> {
    let (id, rest) = read_ident(s);
    if !is_ident(id) {
        return None;
    }
    let k = string(id);
    match rest {
        ['=', '\'', u @ ..] => p_quoted(u).map(|(v, r)| ((k, v), r)),
        ['=', u @ ..] => p_flow(u).map(|(v, r)| ((k, v), r)),
        _ => None,
    }
}

/// `Md.pAttrsMore`: the attributes after the first, each after a space, up to
/// the closing brace.
pub fn p_attrs_more(mut s: &[char]) -> Option<(Kvs, &[char])> {
    let mut out = Vec::new();
    loop {
        match s {
            ['}', r @ ..] => return Some((out, r)),
            [' ', r @ ..] => {
                let (a, r1) = p_attr(r)?;
                out.push(a);
                s = r1;
            }
            _ => return None,
        }
    }
}

/// `Md.pAttrs`: the attributes after the opening brace, up to the closing one.
pub fn p_attrs(s: &[char]) -> Option<(Kvs, &[char])> {
    match s {
        ['}', r @ ..] => Some((vec![], r)),
        _ => {
            let (a, r) = p_attr(s)?;
            p_attrs_more(r).map(|(mut as_, r1)| {
                as_.insert(0, a);
                (as_, r1)
            })
        }
    }
}

/// `Md.declBody`: a declaration after its `[`.
pub fn decl_body(k: DKind, s: &[char]) -> Option<(RItem, &[char])> {
    let ['$', t @ ..] = s else { return None };
    match take_while(t, |c| c != '$') {
        (name, ['$', ']', '{', u @ ..]) => match parse_latex(&Sym::default(), &string(name)) {
            Some(Json::Str(n)) => p_attrs(u).map(|(a, r)| {
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

// ## Block constructs

/// `Md.fenceItem`: a fenced block's construct, from its info string and body.
pub fn fence_item(info: &[char], body: &[char]) -> Option<RItem> {
    if string(info) == DESC_INFO {
        match body {
            [b @ .., '\n'] => Some(RItem::Desc(string(b))),
            _ => None,
        }
    } else {
        let k = parse_key_md(info)?;
        yaml::decode(body).map(|v| RItem::Block(k, v))
    }
}

/// `Md.labelOK`: nothing, or `{#id}`, with spaces around.
pub fn label_ok(sl: &[char]) -> bool {
    let (_, t) = take_while(sl, |c| c == ' ');
    match t {
        [] => true,
        ['{', '#', r @ ..] => matches!(r, [inner @ .., '}'] if !inner.contains(&'}')),
        _ => false,
    }
}

/// `Md.fenceAt`: a fenced block after ```` ```esm: ````.
pub fn fence_at(u: &[char]) -> Option<(RItem, &[char])> {
    let (info, after) = split_line(u);
    let fence: Vec<char> = FENCE.chars().collect();
    let (body, sl, rest) = until_stop(&fence, after)?;
    if blank(sl) {
        fence_item(info, &body).map(|it| (it, rest))
    } else {
        None
    }
}

// ## Templates and rules

/// `Md.dTmpl`.
pub const D_TMPL: &str = ":::template{";
/// `Md.dRuleC`.
pub const D_RULE_C: &str = ":::rule{";
/// `Md.tmHeadL`.
pub const TM_HEAD_L: &str = "\\operatorname{";
/// `Md.tmDef`.
pub const TM_DEF: &str = ") \\coloneqq ";
/// `Md.ruleHeadL`.
pub const RULE_HEAD_L: &str = "\\text{rule } \\operatorname{";
/// `Md.ruleSep`.
pub const RULE_SEP: &str = ": \\; ";
/// `Md.ruleArrow`.
pub const RULE_ARROW: &str = " \\Rightarrow ";

/// `Md.paramsTxt`: the parameters of a template header, separated by `, `.
pub fn params_txt(ps: &[String], out: &mut Vec<char>) {
    for (i, p) in ps.iter().enumerate() {
        if i > 0 {
            out.extend([',', ' ']);
        }
        out.extend(name_latex(p));
    }
}

/// `Md.tmRaw`: the math text of a template or rule display (one line).
pub fn tm_raw(t: &Tm<String>) -> Vec<char> {
    let name: Vec<char> = t.name.chars().collect();
    let mut out = Vec::new();
    match &t.lhs {
        None => {
            push_s(&mut out, TM_HEAD_L);
            out.extend(esc_t(&name));
            out.extend(['}', '(']);
            params_txt(&t.params, &mut out);
            push_s(&mut out, TM_DEF);
            out.extend(t.body.chars());
        }
        Some(l) => {
            push_s(&mut out, RULE_HEAD_L);
            out.extend(esc_t(&name));
            out.push('}');
            push_s(&mut out, RULE_SEP);
            out.extend(l.chars());
            push_s(&mut out, RULE_ARROW);
            out.extend(t.body.chars());
        }
    }
    out
}

/// `Md.pName`: one parameter, up to the next `,` or `)`.
pub fn p_name(s: &[char]) -> Option<(String, &[char])> {
    let (a, rest) = take_while(s, |c| c != ',' && c != ')');
    match parse_latex(&Sym::default(), &string(a)) {
        Some(Json::Str(n)) => Some((n, rest)),
        _ => None,
    }
}

/// `Md.pParams`: the parameters after `(`, up to `) \coloneqq `.
pub fn p_params(mut s: &[char]) -> Option<(Vec<String>, &[char])> {
    let mut out = Vec::new();
    loop {
        if let Some(r) = after_s(TM_DEF, s) {
            return Some((out, r));
        }
        let (n, r) = p_name(s)?;
        out.push(n);
        if let Some(r1) = after_s(TM_DEF, r) {
            return Some((out, r1));
        }
        match r {
            [',', ' ', r1 @ ..] => s = r1,
            _ => return None,
        }
    }
}

/// `Md.splitAt`: split at the first occurrence of `sep`.
pub fn split_at<'a>(sep: &str, s: &'a [char]) -> Option<(&'a [char], &'a [char])> {
    (0..s.len())
        .find(|&i| pre_s(sep, &s[i..]))
        .map(|i| (&s[..i], &s[i + sep.len()..]))
}

/// The pieces `tmLex` reads: name, parameters, a rule's left-hand side, body.
pub type TmLex = (String, Vec<String>, Option<Vec<char>>, Vec<char>);

/// `Md.tmLex`: read the math text of a display as a template or rule.
pub fn tm_lex(raw: &[char]) -> Option<TmLex> {
    match after_s(RULE_HEAD_L, raw) {
        Some(u) => {
            let (nm, u1) = raw_b(0, u)?;
            let u2 = after_s(RULE_SEP, u1)?;
            split_at(RULE_ARROW, u2)
                .map(|(l, b)| (string(&unesc_t(&nm)), vec![], Some(l.to_vec()), b.to_vec()))
        }
        None => {
            let u = after_s(TM_HEAD_L, raw)?;
            match raw_b(0, u)? {
                (nm, ['(', u1 @ ..]) => {
                    p_params(u1).map(|(ps, b)| (string(&unesc_t(&nm)), ps, None, b.to_vec()))
                }
                _ => None,
            }
        }
    }
}

/// `Md.mathAt`: a display after its opening `$$`: a template or rule when its
/// math reads as one, otherwise an equation (optionally labelled).
pub fn math_at(u: &[char]) -> Option<(RItem, &[char])> {
    let (first, after) = split_line(u);
    if !blank(first) {
        return None;
    }
    let dd: Vec<char> = DD.chars().collect();
    let (body, sl, rest) = until_stop(&dd, after)?;
    let [b @ .., '\n'] = body.as_slice() else {
        return None;
    };
    match tm_lex(b) {
        Some((n, ps, l, bd)) => blank(sl).then(|| {
            (
                RItem::Tm(Tm {
                    name: n,
                    params: ps,
                    lhs: l.map(|l| string(&l)),
                    body: string(&bd),
                    attrs: vec![],
                }),
                rest,
            )
        }),
        None => label_ok(sl).then(|| (RItem::Eqn(string(b)), rest)),
    }
}

/// `Md.tmContAt`: a template or rule with other fields, after `:::template{`
/// or `:::rule{`.
pub fn tm_cont_at(u: &[char]) -> Option<(RItem, &[char])> {
    let (as_, r) = p_attrs(u)?;
    let ['\n', r1 @ ..] = r else { return None };
    if !pre_s(DD, r1) {
        return None;
    }
    match math_at(&r1[2..])? {
        (RItem::Tm(mut t), r2) => {
            let (l, r3) = split_line(r2.get(3..).unwrap_or(&[]));
            if pre_s(D_END, r2) && blank(l) {
                t.attrs = as_;
                Some((RItem::Tm(t), r3))
            } else {
                None
            }
        }
        _ => None,
    }
}

/// `Md.dirAt`: a component directive after its `[`.
pub fn dir_at(k: Kind, u: &[char]) -> Option<(RItem, &[char])> {
    match take_while(u, |c| c != ']' && c != '\n') {
        (name, [']', t @ ..]) => {
            let (l, r) = split_line(t);
            blank(l).then(|| (RItem::Comp(k, string(name)), r))
        }
        _ => None,
    }
}

// ## Reactions

/// `Md.latexR`: LaTeX under the empty symbol table.
pub const LATEX_R: RSurf = RSurf {
    pm: |s| parse_latex(&Sym::default(), s),
    prm: |j| print_latex(&Sym::default(), j).chars().collect(),
    empty: &['\\', 'v', 'a', 'r', 'n', 'o', 't', 'h', 'i', 'n', 'g'],
};

/// `Md.arrowL`.
pub const ARROW_L: &str = " ->[{$";
/// `Md.arrowR`.
pub const ARROW_R: &str = "}] ";
/// `Md.rxnEnd`.
pub const RXN_END: &str = "}$$ {#";

/// `Md.rxnBody`: the text of a reaction line after `$$\ce{`.
pub fn rxn_body(x: &Rxn<String>) -> Vec<char> {
    let mut out = side_txt(&LATEX_R, &x.subs);
    push_s(&mut out, ARROW_L);
    out.extend(x.rate.chars());
    out.push('$');
    push_s(&mut out, ARROW_R);
    out.extend(side_txt(&LATEX_R, &x.prods));
    push_s(&mut out, RXN_END);
    out.extend(x.id.chars());
    for b in &x.attrs {
        out.push(' ');
        attr_md(b, &mut out);
    }
    out.extend(['}', '\n']);
    out
}

/// `Md.rxnAt`: a reaction line after its `$$\ce{`.
pub fn rxn_at(u: &[char]) -> Option<(RItem, &[char])> {
    let (subs, u1) = p_side(&LATEX_R, u)?;
    let u2 = after_s(ARROW_L, u1)?;
    let (rate, u2b) = p_piece(u2)?;
    let u3 = after_s(ARROW_R, u2b)?;
    let (prods, u4) = p_side(&LATEX_R, u3)?;
    let u5 = after_s(RXN_END, u4)?;
    let (id, u5b) = take_while(u5, id_char);
    let (attrs, u6) = p_attrs_more(u5b)?;
    let (l, r) = split_line(u6);
    if id.is_empty() || !blank(l) {
        return None;
    }
    Some((
        RItem::Rxn(Rxn {
            id: string(id),
            subs,
            prods,
            rate: string(rate),
            attrs,
        }),
        r,
    ))
}

/// `Md.subAt`: a subsystem directive after its `::subsystem[`.
pub fn sub_at(u: &[char]) -> Option<(RItem, &[char])> {
    match take_while(u, |c| c != ']' && c != '\n') {
        (name, [']', '{', v @ ..]) => {
            let (a, r) = p_attrs(v)?;
            let (l, r1) = split_line(r);
            blank(l).then(|| {
                (
                    RItem::Decl(Decl {
                        kind: DKind::Sub,
                        name: string(name),
                        attrs: a,
                    }),
                    r1,
                )
            })
        }
        _ => None,
    }
}

/// `Md.plotAt`: a plot directive after its `::plot{`.
pub fn plot_at(u: &[char]) -> Option<(RItem, &[char])> {
    let (a, r) = p_attrs(u)?;
    let (l, r1) = split_line(r);
    blank(l).then_some((RItem::Plot(a), r1))
}

// ## Containers of initialization equations and constraints

/// `Md.contBody`: the displays of a container, up to its closing `:::` line;
/// blank lines between them are skipped.
pub fn cont_body(ro: Role, mut s: &[char]) -> Option<(Vec<RItem>, &[char])> {
    let mut out = Vec::new();
    loop {
        if pre_s(D_END, s) {
            let (l, r) = split_line(&s[3..]);
            return blank(l).then_some((out, r));
        } else if pre_s(DD, s) {
            match math_at(&s[2..]) {
                Some((RItem::Eqn(raw), r)) => {
                    out.push(RItem::Eqx(ro, raw));
                    s = r;
                }
                _ => return None,
            }
        } else if let ['\n', r @ ..] = s {
            s = r;
        } else {
            return None;
        }
    }
}

/// `Md.contOpen`: a container starts here.
pub fn cont_open(s: &[char]) -> bool {
    pre_s(D_INIT, s) || pre_s(D_CONS, s)
}

/// `Md.contAt`: a container, at its opening line.
pub fn cont_at(s: &[char]) -> Option<(Vec<RItem>, &[char])> {
    let (ro, n) = if pre_s(D_INIT, s) {
        (Role::Init, D_INIT.len())
    } else {
        (Role::Cons, D_CONS.len())
    };
    let (l, r) = split_line(s.get(n..).unwrap_or(&[]));
    if blank(l) { cont_body(ro, r) } else { None }
}

// ## The lexer

/// `Md.blockOpen`: a block construct starts here.
pub fn block_open(s: &[char]) -> bool {
    pre_s(FENCE_ESM, s)
        || pre_s(DD, s)
        || pre_s(D_MODEL, s)
        || pre_s(D_RS, s)
        || pre_s(D_PLOT, s)
        || pre_s(D_SUB, s)
        || pre_s(D_TMPL, s)
        || pre_s(D_RULE_C, s)
}

/// `Md.declOpen`: a declaration starts here.
pub fn decl_open(s: &[char]) -> bool {
    pre_s(":var[", s) || pre_s(":param[", s) || pre_s(":species[", s)
}

/// `Md.blockAt`: read the block construct that starts here.
pub fn block_at(s: &[char]) -> Option<(RItem, &[char])> {
    let d = |n: usize| s.get(n..).unwrap_or(&[]);
    if pre_s(FENCE_ESM, s) {
        fence_at(d(7))
    } else if pre_s(D_RXN, s) {
        rxn_at(d(6))
    } else if pre_s(DD, s) {
        math_at(d(2))
    } else if pre_s(D_MODEL, s) {
        dir_at(Kind::Model, d(8))
    } else if pre_s(D_PLOT, s) {
        plot_at(d(7))
    } else if pre_s(D_SUB, s) {
        sub_at(d(12))
    } else if pre_s(D_TMPL, s) {
        tm_cont_at(d(12))
    } else if pre_s(D_RULE_C, s) {
        tm_cont_at(d(8))
    } else {
        dir_at(Kind::Rs, d(18))
    }
}

/// `Md.declAt`: read the declaration that starts here.
pub fn decl_at(s: &[char]) -> Option<(RItem, &[char])> {
    let d = |n: usize| s.get(n..).unwrap_or(&[]);
    if pre_s(":var[", s) {
        decl_body(DKind::Var, d(5))
    } else if pre_s(":param[", s) {
        decl_body(DKind::Param, d(7))
    } else {
        decl_body(DKind::Species, d(9))
    }
}

// ## The declarations table (an accepted input variant)

/// `Md.tableOpen`.
pub const TABLE_OPEN: &str = "| decl | name |";

/// `Md.trimCell`: a cell without its surrounding spaces.
pub fn trim_cell(s: &str) -> String {
    s.trim_matches(' ').to_string()
}

/// `Md.headerCells`: the line split at `|`, each cell trimmed.
pub fn header_cells(s: &[char]) -> Vec<String> {
    let line = string(take_while(s, |c| c != '\n').0);
    line.split('|').map(trim_cell).collect()
}

/// `Md.rateTable`: a line starting with `|` that has a cell `rate`.
pub fn rate_table(s: &[char]) -> bool {
    pre(&['|'], s) && header_cells(s).iter().any(|c| c == "rate")
}

/// `Md.pCols`: the attribute columns of the header, up to its newline.
pub fn p_cols(mut s: &[char]) -> Option<(Vec<String>, &[char])> {
    let mut out = Vec::new();
    loop {
        match s {
            ['\n', r @ ..] => return Some((out, r)),
            [' ', r @ ..] => {
                let (id, rest) = read_ident(r);
                if !is_ident(id) {
                    return None;
                }
                match rest {
                    [' ', '|', u @ ..] => {
                        out.push(string(id));
                        s = u;
                    }
                    _ => return None,
                }
            }
            _ => return None,
        }
    }
}

/// `Md.pCell`: ` value |`, or ` |` when the attribute is absent.
pub fn p_cell(s: &[char]) -> Option<(Option<Json>, &[char])> {
    match s {
        [' ', '|', r @ ..] => Some((None, r)),
        [' ', r @ ..] => match p_flow(r) {
            Some((v, [' ', '|', r1 @ ..])) => Some((Some(v), r1)),
            _ => None,
        },
        _ => None,
    }
}

/// `Md.pCells`: the cells of a row, one per attribute column.
pub fn p_cells<'a>(cols: &[String], mut s: &'a [char]) -> Option<(Kvs, &'a [char])> {
    let mut out = Vec::new();
    for k in cols {
        let (v, r) = p_cell(s)?;
        if let Some(v) = v {
            out.push((k.clone(), v));
        }
        s = r;
    }
    Some((out, s))
}

/// `Md.kindOf`: the directive keyword of a row.
pub fn kind_of(w: &[char]) -> Option<DKind> {
    match string(w).as_str() {
        "var" => Some(DKind::Var),
        "param" => Some(DKind::Param),
        "species" => Some(DKind::Species),
        "subsystem" => Some(DKind::Sub),
        _ => None,
    }
}

/// `Md.pRow`: `| var | $N$ |` and the cells, then a newline.
pub fn p_row<'a>(cols: &[String], s: &'a [char]) -> Option<(Decl, &'a [char])> {
    let ['|', ' ', r @ ..] = s else { return None };
    let (w, rest) = read_ident(r);
    let k = kind_of(w)?;
    let [' ', '|', ' ', '$', u @ ..] = rest else {
        return None;
    };
    let (name, ['$', ' ', '|', v @ ..]) = take_while(u, |c| c != '$') else {
        return None;
    };
    let Some(Json::Str(n)) = parse_latex(&Sym::default(), &string(name)) else {
        return None;
    };
    match p_cells(cols, v)? {
        (a, ['\n', r1 @ ..]) => Some((
            Decl {
                kind: k,
                name: n,
                attrs: a,
            },
            r1,
        )),
        _ => None,
    }
}

/// `Md.pRows`: the rows, as long as lines start with `| `.
pub fn p_rows<'a>(cols: &[String], mut s: &'a [char]) -> Option<(Vec<Decl>, &'a [char])> {
    let mut out = Vec::new();
    while pre(&['|', ' '], s) {
        let (d, r) = p_row(cols, s)?;
        out.push(d);
        s = r;
    }
    Some((out, s))
}

/// `Md.sepOK`: the separator row.
pub fn sep_ok(l: &[char]) -> bool {
    l.iter()
        .all(|&c| c == '|' || c == '-' || c == ' ' || c == ':')
}

/// `Md.tableAt`: a declarations table, at its `| decl | name |`.
pub fn table_at(s: &[char]) -> Option<(Vec<RItem>, &[char])> {
    let (cols, r) = p_cols(s.get(TABLE_OPEN.len()..).unwrap_or(&[]))?;
    let (l, r1) = split_line(r);
    if !sep_ok(l) {
        return None;
    }
    p_rows(&cols, r1).map(|(ds, r2)| (ds.into_iter().map(RItem::Decl).collect(), r2))
}

// ## Code spans

/// `Md.afterRun`: the text after the first occurrence of `n` backticks.
pub fn after_run(n: usize, s: &[char]) -> Option<&[char]> {
    (0..s.len())
        .find(|&i| s.len() - i >= n && s[i..i + n].iter().all(|&c| c == '`'))
        .map(|i| &s[i + n..])
}

/// `Md.skipCode`: the text after the code span that starts here.
pub fn skip_code(s: &[char]) -> &[char] {
    let (run, rest) = take_while(s, |c| c == '`');
    after_run(run.len(), rest).unwrap_or(rest)
}

/// `Md.lex`: the constructs of a text, skipping prose one character at a time
/// and code spans whole. A malformed construct is an error. Each construct
/// comes with the range of `s` it is written in (Lean's `lex` returns the
/// constructs alone); the constructs of a table or a container share its
/// range.
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
        } else if bol && pre_s(TABLE_OPEN, s) {
            let (its, rest) = table_at(s)?;
            out.extend(its.into_iter().map(|it| (it, at(s, rest))));
            s = rest;
            bol = true;
        } else if bol && cont_open(s) {
            let (its, rest) = cont_at(s)?;
            out.extend(its.into_iter().map(|it| (it, at(s, rest))));
            s = rest;
            bol = true;
        } else if bol && rate_table(s) {
            return None;
        } else if *c == '`' {
            s = skip_code(s);
            bol = false;
        } else {
            bol = *c == '\n';
            s = r;
        }
    }
    Some(out)
}

// ## What each construct needs to read back

/// `Md.attrOK`.
pub fn attr_ok(a: &(String, Json)) -> bool {
    let k: Vec<char> = a.0.chars().collect();
    is_ident(&k) && crate::document::math::expr::jwf(&a.1)
}

/// `Md.declOK`.
pub fn decl_ok(d: &Decl) -> bool {
    name_ok(&d.name) && !name_latex(&d.name).contains(&'$') && d.attrs.iter().all(attr_ok)
}

/// `Md.mhchemOK`: no escaped brace anywhere inside `\ce{…}`.
pub fn mhchem_ok(x: &Rxn<String>) -> bool {
    let mut t = side_txt(&LATEX_R, &x.subs);
    t.extend(x.rate.chars());
    t.extend(side_txt(&LATEX_R, &x.prods));
    !has_sub(&['\\', '{'], &t) && !has_sub(&['\\', '}'], &t)
}

/// `Md.rxnOK`: a reaction the Markdown syntax can hold.
pub fn rxn_ok(x: &Rxn<String>) -> bool {
    side_ok(&LATEX_R, &x.subs)
        && side_ok(&LATEX_R, &x.prods)
        && !x.rate.contains('$')
        && !x.rate.contains('\n')
        && id_ok(&x.id)
        && x.attrs.iter().all(attr_ok)
        && mhchem_ok(x)
}

/// `Md.subMd`.
pub fn sub_md(d: &Decl) -> Vec<char> {
    let mut out: Vec<char> = D_SUB.chars().collect();
    out.extend(d.name.chars());
    out.extend([']', '{']);
    attrs_md(&d.attrs, &mut out);
    out.extend(['}', '\n']);
    out
}

/// `Md.subOK`.
pub fn sub_ok(d: &Decl) -> bool {
    !d.name.contains(']') && !d.name.contains('\n') && d.attrs.iter().all(attr_ok)
}

/// `Md.itemMd`: the text of a construct.
pub fn item_md(it: &RItem) -> Vec<char> {
    let mut out = Vec::new();
    match it {
        RItem::Desc(s) => {
            push_s(&mut out, FENCE_ESM);
            push_s(&mut out, DESC_INFO);
            out.push('\n');
            out.extend(s.chars());
            out.push('\n');
            push_s(&mut out, FENCE);
            out.push('\n');
        }
        RItem::Block(k, v) => {
            push_s(&mut out, FENCE_ESM);
            out.extend(key_md(k));
            out.push('\n');
            out.extend(yaml::encode(v));
            push_s(&mut out, FENCE);
            out.push('\n');
        }
        RItem::Comp(k, n) => {
            push_s(&mut out, if *k == Kind::Model { D_MODEL } else { D_RS });
            out.extend(n.chars());
            out.extend([']', '\n']);
        }
        RItem::Decl(d) => {
            out = if d.kind == DKind::Sub {
                sub_md(d)
            } else {
                decl_md(d)
            };
        }
        RItem::Eqn(raw) => {
            push_s(&mut out, DD);
            out.push('\n');
            out.extend(raw.chars());
            out.push('\n');
            push_s(&mut out, DD);
            out.push('\n');
        }
        RItem::Eqx(r, raw) => {
            push_s(&mut out, d_role(*r));
            out.push('\n');
            push_s(&mut out, DD);
            out.push('\n');
            out.extend(raw.chars());
            out.push('\n');
            push_s(&mut out, DD);
            out.push('\n');
            push_s(&mut out, D_END);
            out.push('\n');
        }
        RItem::Rxn(x) => {
            push_s(&mut out, D_RXN);
            out.extend(rxn_body(x));
        }
        RItem::Plot(a) => {
            push_s(&mut out, D_PLOT);
            attrs_md(a, &mut out);
            out.extend(['}', '\n']);
        }
        RItem::Tm(t) => {
            if t.attrs.is_empty() {
                push_s(&mut out, DD);
                out.push('\n');
                out.extend(tm_raw(t));
                out.push('\n');
                push_s(&mut out, DD);
                out.push('\n');
            } else {
                push_s(&mut out, if t.lhs.is_none() { D_TMPL } else { D_RULE_C });
                attrs_md(&t.attrs, &mut out);
                out.extend(['}', '\n']);
                push_s(&mut out, DD);
                out.push('\n');
                out.extend(tm_raw(t));
                out.push('\n');
                push_s(&mut out, DD);
                out.push('\n');
                push_s(&mut out, D_END);
                out.push('\n');
            }
        }
    }
    out
}

/// `Md.Seg`: a piece of a Markdown document.
#[derive(Clone, Debug, PartialEq)]
pub enum Seg {
    Item(RItem),
    Prose(Vec<char>),
}

/// `Md.segText`.
pub fn seg_text(s: &Seg) -> Vec<char> {
    match s {
        Seg::Item(it) => item_md(it),
        Seg::Prose(p) => p.clone(),
    }
}

/// `Md.render`: the text of a document body.
pub fn render(segs: &[Seg]) -> Vec<char> {
    segs.iter().flat_map(seg_text).collect()
}

/// `Md.isBlock`: a construct that must start a line (all but declarations).
pub fn is_block(it: &RItem) -> bool {
    match it {
        RItem::Decl(d) => d.kind == DKind::Sub,
        _ => true,
    }
}

fn with_nl(s: &str) -> Vec<char> {
    let mut v: Vec<char> = s.chars().collect();
    v.push('\n');
    v
}

/// `Md.itemOK`: what each construct's content must satisfy for its text to
/// read back.
pub fn item_ok(it: &RItem) -> bool {
    let fence: Vec<char> = FENCE.chars().collect();
    let dd: Vec<char> = DD.chars().collect();
    match it {
        RItem::Desc(s) => no_stop(&fence, &with_nl(s)),
        RItem::Block(_, v) => v.wfmb(),
        RItem::Comp(_, n) => !n.contains(']') && !n.contains('\n'),
        RItem::Decl(d) => {
            if d.kind == DKind::Sub {
                sub_ok(d)
            } else {
                decl_ok(d)
            }
        }
        RItem::Eqn(raw) => {
            let rc: Vec<char> = raw.chars().collect();
            no_stop(&dd, &with_nl(raw)) && tm_lex(&rc).is_none()
        }
        RItem::Eqx(r, raw) => {
            let rc: Vec<char> = raw.chars().collect();
            *r != Role::Eqn && no_stop(&dd, &with_nl(raw)) && tm_lex(&rc).is_none()
        }
        RItem::Rxn(x) => rxn_ok(x),
        RItem::Plot(a) => a.iter().all(attr_ok),
        RItem::Tm(t) => {
            let raw = tm_raw(t);
            let mut rn = raw.clone();
            rn.push('\n');
            no_stop(&dd, &rn)
                && !raw.contains(&'\n')
                && tm_lex(&raw)
                    == Some((
                        t.name.clone(),
                        t.params.clone(),
                        t.lhs.as_ref().map(|l| l.chars().collect()),
                        t.body.chars().collect(),
                    ))
                && t.attrs.iter().all(attr_ok)
        }
    }
}
