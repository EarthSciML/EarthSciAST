//! Markdown documents: printing and parsing.
//!
//! Port of `formal/Esm/Document/Source/MarkdownDoc.lean`. The layers compose:
//! the skeleton (`to_doc` / `of_doc`), the math entries as LaTeX
//! (`raw_doc` / `cook_doc`), the construct sequence (`items` / `unitems`), and
//! the text (front matter, then the constructs separated by blank lines).

use super::equation::{eq_expr, eq_sides};
use super::items::{
    RItem, Spanned, ck_mx, cook_doc, cook_doc_blocks, items, mathify_doc, pr_mx, raw_doc, unitems,
};
use super::keys::Kvs;
use super::lines::decode_text;
use super::markdown::{
    DASHES, FENCE, Seg, attr_ok, is_block, item_ok, lex_spanned, name_latex, render, rxn_ok, tm_lex,
};
use super::multi_line::cook_rows;
use super::skeleton::{Caps, Eqn, MC, MR, Rxn, Tm, of_doc, to_doc};
use super::text::{blank, no_stop, split_line, string, until_stop};
use crate::document::json::Json;
use crate::document::math::expr::name_ok;
use crate::document::math::token::Sf;
use crate::document::math::{Sym, latex, parse_latex, print_latex};
use crate::document::strings::{esc_char, is_ident};
use crate::document::yaml;

// ## Equations in LaTeX

/// `Md.latexOf`: an equation's LaTeX under the symbol table `s`.
pub fn latex_of(s: &Sym, e: &Eqn) -> Vec<char> {
    print_latex(s, &eq_expr(e)).chars().collect()
}

/// `Md.prMd`: an equation's math text: its `_comment` as a LaTeX comment line,
/// then the equation.
pub fn pr_md(s: &Sym, e: &Eqn) -> String {
    let mut out = String::new();
    if let Some(c) = &e.comment {
        out.push_str("% ");
        out.push_str(c);
        out.push('\n');
    }
    out.extend(latex_of(s, e));
    out
}

/// `Md.envs`: the multi-line environments: `true` when all rows are one
/// equation.
pub const ENVS: &[(&str, bool)] = &[
    ("aligned", false),
    ("align", false),
    ("align*", false),
    ("gathered", false),
    ("split", true),
    ("multline", true),
    ("multline*", true),
];

/// `Md.isWsC`.
pub fn is_ws_c(c: char) -> bool {
    c == ' ' || c == '\n' || c == '\t'
}

/// `Md.envOf`: a display that is one multi-line environment: whether its rows
/// are one equation, and the environment's body.
pub fn env_of(body: &[char]) -> Option<(bool, Vec<char>)> {
    let start = body.iter().take_while(|&&c| is_ws_c(c)).count();
    let b = &body[start..];
    let end = b.len() - b.iter().rev().take_while(|&&c| is_ws_c(c)).count();
    let b = &b[..end];
    ENVS.iter().find_map(|(e, one)| {
        let o: Vec<char> = format!("\\begin{{{e}}}").chars().collect();
        let c: Vec<char> = format!("\\end{{{e}}}").chars().collect();
        if b.starts_with(&o) && b.ends_with(&c) {
            let n = b.len().saturating_sub(o.len() + c.len());
            Some((*one, b[o.len()..].iter().take(n).copied().collect()))
        } else {
            None
        }
    })
}

/// `Md.withComment`: the comment goes to the first equation of a display.
pub fn with_comment(c: Option<String>, mut es: Vec<Eqn>) -> Vec<Eqn> {
    if let Some(e) = es.first_mut() {
        e.comment = c;
    }
    es
}

/// `Md.oneMd`: one display in LaTeX: a multi-line environment, or one
/// equation.
pub fn one_md(s: &Sym, c: Option<String>, body: &[char]) -> Option<Vec<Eqn>> {
    match env_of(body) {
        Some((one, inner)) => latex::lex(&inner)
            .and_then(|ts| cook_rows(Sf::Latex, s, one, &ts))
            .map(|es| with_comment(c, es)),
        None => {
            let (l, r) = parse_latex(s, &string(body)).and_then(eq_sides)?;
            Some(vec![Eqn {
                comment: c,
                lhs: l,
                rhs: r,
            }])
        }
    }
}

/// `Md.ckMd`: read the math text of a display equation: an optional leading
/// comment line `% …`, then the equation.
pub fn ck_md(s: &Sym, raw: &str) -> Option<Vec<Eqn>> {
    let cs: Vec<char> = raw.chars().collect();
    match cs.as_slice() {
        ['%', ' ', r @ ..] => {
            let (c, rest) = split_line(r);
            one_md(s, Some(string(c)), rest)
        }
        _ => one_md(s, None, &cs),
    }
}

/// `Md.prMdx`: a math entry's text.
pub fn pr_mdx(s: &Sym, m: &MC) -> MR {
    pr_mx(&pr_md, &|s, j| print_latex(s, j), s, m)
}

/// `Md.ckMdx`: read a math entry's text.
pub fn ck_mdx(s: &Sym, m: &MR) -> Option<Vec<MC>> {
    ck_mx(&ck_md, &|s, raw| parse_latex(s, raw), s, m)
}

/// `Md.commentOK`.
pub fn comment_ok(c: &Option<String>) -> bool {
    match c {
        Some(c) => !c.contains('\n') && !c.contains('$'),
        None => true,
    }
}

// ## What Markdown spells natively

/// `Md.dqOK`: a string whose characters the YAML printer writes as themselves
/// and without `&`; any other value.
pub fn dq_ok(v: &Json) -> bool {
    match v {
        Json::Str(s) => s.chars().all(|c| {
            let mut e = Vec::new();
            esc_char(false, c, &mut e);
            e == [c] && c != '&'
        }),
        _ => true,
    }
}

/// `Md.capsMd`: the Markdown container's predicates.
pub struct CapsMd;

impl Caps for CapsMd {
    fn front_key(&self, _k: &str) -> bool {
        true
    }

    fn desc(&self, s: &str) -> bool {
        let mut t: Vec<char> = s.chars().collect();
        t.push('\n');
        ["", " ", "  ", "   "].iter().all(|ind| {
            let stop: Vec<char> = format!("{ind}{FENCE}").chars().collect();
            no_stop(&stop, &t)
        }) && !s.contains('\r')
    }

    fn comp_name(&self, n: &str) -> bool {
        !n.contains(']') && !n.contains('\n')
    }

    fn decl_name(&self, n: &str) -> bool {
        name_ok(n) && !name_latex(n).contains(&'$') && !n.contains(']') && !n.contains('\n')
    }

    fn attr(&self, a: &(String, Json)) -> bool {
        let k: Vec<char> = a.0.chars().collect();
        is_ident(&k) && dq_ok(&a.1)
    }

    fn eqn(&self, s: &Sym, e: &Eqn) -> bool {
        let l = latex_of(s, e);
        let p: Vec<char> = pr_md(s, e).chars().collect();
        comment_ok(&e.comment)
            && !l.contains(&'$')
            && !l.contains(&'\n')
            && l.first() != Some(&'%')
            && env_of(&l).is_none()
            && tm_lex(&p).is_none()
    }

    fn rxn(&self, s: &Sym, x: &Rxn<Json>) -> bool {
        rxn_ok(&Rxn {
            id: x.id.clone(),
            subs: x.subs.clone(),
            prods: x.prods.clone(),
            rate: print_latex(s, &x.rate),
            attrs: x.attrs.clone(),
        })
    }

    fn plot(&self, a: &[(String, Json)]) -> bool {
        a.iter().all(attr_ok) && a.iter().all(|kv| dq_ok(&kv.1))
    }

    fn tm(&self, s: &Sym, t: &Tm<Json>) -> bool {
        item_ok(&RItem::Tm(Tm {
            name: t.name.clone(),
            params: t.params.clone(),
            lhs: t.lhs.as_ref().map(|j| {
                print_latex(
                    &Sym {
                        names: s.names.clone(),
                        templates: vec![],
                    },
                    j,
                )
            }),
            body: print_latex(s, &t.body),
            attrs: t.attrs.clone(),
        })) && t.attrs.iter().all(|kv| dq_ok(&kv.1))
    }
}

/// `Md.frontMd`: the front matter.
pub fn front_md(front: &[(String, Json)]) -> Vec<char> {
    let mut out: Vec<char> = DASHES.chars().collect();
    out.push('\n');
    out.extend(yaml::encode(&Json::Obj(front.to_vec())));
    out.extend(DASHES.chars());
    out.push('\n');
    out
}

/// `Md.canonSegs`: each construct after a blank line, a declaration on a line
/// of its own.
pub fn canon_segs(its: Vec<RItem>) -> Vec<Seg> {
    let mut out = Vec::new();
    for it in its {
        let block = is_block(&it);
        out.push(Seg::Prose(vec!['\n']));
        out.push(Seg::Item(it));
        if !block {
            out.push(Seg::Prose(vec!['\n']));
        }
    }
    out
}

/// `Md.printMd`: print a document as Markdown.
pub fn print_md(d: &Json) -> String {
    let doc = to_doc(&CapsMd, d);
    let mut out = front_md(&doc.front);
    out.extend(render(&canon_segs(items(&mathify_doc(
        &|s, j| print_latex(s, j),
        &yaml::plain_math_ok,
        raw_doc(&pr_mdx, &doc),
    )))));
    string(&out)
}

/// `Md.lexDoc`: read the front matter and the constructs.
pub fn lex_doc(s: &[char]) -> Option<(Kvs, Vec<RItem>)> {
    lex_doc_spanned(s).map(|(kvs, its)| (kvs, its.into_iter().map(|(it, _)| it).collect()))
}

/// [`lex_doc`], with where in `s` each construct is written (not in Lean).
pub fn lex_doc_spanned(s: &[char]) -> Option<(Kvs, Vec<Spanned>)> {
    let ['-', '-', '-', '\n', r @ ..] = s else {
        return None;
    };
    let dashes: Vec<char> = DASHES.chars().collect();
    let (body, sl, rest) = until_stop(&dashes, r)?;
    if !blank(sl) {
        return None;
    }
    let base = s.len() - rest.len();
    match yaml::decode(&body) {
        Some(Json::Obj(kvs)) => lex_spanned(true, rest).map(|its| {
            let its = its
                .into_iter()
                .map(|(it, at)| (it, at.start + base..at.end + base))
                .collect();
            (kvs, its)
        }),
        _ => None,
    }
}

/// `Md.parseMd`: read a Markdown document, after `decodeText`.
pub fn parse_md(s: &str) -> Option<Json> {
    let cs: Vec<char> = s.chars().collect();
    let (front, its) = lex_doc(&decode_text(&cs))?;
    parse_items_md(front, its)
}

/// `Md.parseItemsMd`.
pub fn parse_items_md(front: Kvs, its: Vec<RItem>) -> Option<Json> {
    let r = unitems(front, its)?;
    let r = cook_doc_blocks(&|s, raw| parse_latex(s, raw), r)?;
    let d = cook_doc(&ck_mdx, &r)?;
    of_doc(&d)
}
