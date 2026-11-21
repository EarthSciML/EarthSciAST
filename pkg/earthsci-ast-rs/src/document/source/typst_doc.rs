//! Typst documents: printing and parsing.
//!
//! Port of `formal/Esm/Document/Source/TypstDoc.lean`, composed exactly as the
//! Markdown documents ([`super::markdown_doc`]).

use super::equation::{eq_expr, eq_sides};
use super::items::{
    RItem, Spanned, ck_mx, cook_doc, cook_doc_blocks, items, mathify_doc, pr_mx, raw_doc, unitems,
};
use super::keys::Kvs;
use super::lines::decode_text;
use super::markdown_doc::{comment_ok, with_comment};
use super::multi_line::cook_rows;
use super::skeleton::{Caps, Eqn, MC, MR, Rxn, Tm, of_doc, to_doc};
use super::text::{pre, pre_s, split_line, string};
use super::typst::{
    HEADER, Seg, arg_ok, args_first_t, is_block, item_ok, lex_spanned, line_end, name_typ,
    p_args_first, render, rxn_ok, tm_lex_t,
};
use crate::document::json::Json;
use crate::document::math::expr::name_ok;
use crate::document::math::token::Sf;
use crate::document::math::{Sym, parse_typst, print_typst, typst};
use crate::document::strings::bare_key;
use crate::document::typst_dict;

/// `Typ.typOf`: an equation's Typst math under the symbol table `s`.
pub fn typ_of(s: &Sym, e: &Eqn) -> Vec<char> {
    print_typst(s, &eq_expr(e)).chars().collect()
}

/// `Typ.prT`: its `_comment` as a `//` comment line, then the equation.
pub fn pr_t(s: &Sym, e: &Eqn) -> String {
    let mut out = String::new();
    if let Some(c) = &e.comment {
        out.push_str("// ");
        out.push_str(c);
        out.push('\n');
    }
    out.extend(typ_of(s, e));
    out
}

/// `Typ.oneT`: one equation, or several rows separated by `\` with `&`
/// alignment.
pub fn one_t(s: &Sym, c: Option<String>, body: &[char]) -> Option<Vec<Eqn>> {
    match parse_typst(s, &string(body)).and_then(eq_sides) {
        Some((l, r)) => Some(vec![Eqn {
            comment: c,
            lhs: l,
            rhs: r,
        }]),
        None => typst::lex(body)
            .and_then(|ts| cook_rows(Sf::Typst, s, false, &ts))
            .map(|es| with_comment(c, es)),
    }
}

/// `Typ.ckT`: read the math text of a display equation.
pub fn ck_t(s: &Sym, raw: &str) -> Option<Vec<Eqn>> {
    let cs: Vec<char> = raw.chars().collect();
    match cs.as_slice() {
        ['/', '/', ' ', r @ ..] => {
            let (c, rest) = split_line(r);
            one_t(s, Some(string(c)), rest)
        }
        _ => one_t(s, None, &cs),
    }
}

/// `Typ.prTx`.
pub fn pr_tx(s: &Sym, m: &MC) -> MR {
    pr_mx(&pr_t, &|s, j| print_typst(s, j), s, m)
}

/// `Typ.ckTx`.
pub fn ck_tx(s: &Sym, m: &MR) -> Option<Vec<MC>> {
    ck_mx(&ck_t, &|s, raw| parse_typst(s, raw), s, m)
}

/// `Typ.capsT`: the Typst container's predicates.
pub struct CapsT;

impl Caps for CapsT {
    fn front_key(&self, k: &str) -> bool {
        bare_key(typst_dict::reserved, k)
    }

    fn desc(&self, _s: &str) -> bool {
        true
    }

    fn comp_name(&self, _n: &str) -> bool {
        true
    }

    fn decl_name(&self, n: &str) -> bool {
        name_ok(n) && !name_typ(n).contains(&'$')
    }

    fn attr(&self, a: &(String, Json)) -> bool {
        bare_key(typst_dict::reserved, &a.0)
    }

    fn eqn(&self, s: &Sym, e: &Eqn) -> bool {
        let t = typ_of(s, e);
        let p: Vec<char> = pr_t(s, e).chars().collect();
        comment_ok(&e.comment)
            && !t.contains(&'$')
            && !pre(&['/', '/'], &t)
            && tm_lex_t(&p).is_none()
    }

    fn rxn(&self, s: &Sym, x: &Rxn<Json>) -> bool {
        rxn_ok(&Rxn {
            id: x.id.clone(),
            subs: x.subs.clone(),
            prods: x.prods.clone(),
            rate: print_typst(s, &x.rate),
            attrs: x.attrs.clone(),
        })
    }

    fn plot(&self, a: &[(String, Json)]) -> bool {
        a.iter().all(arg_ok)
    }

    fn tm(&self, s: &Sym, t: &Tm<Json>) -> bool {
        item_ok(&RItem::Tm(Tm {
            name: t.name.clone(),
            params: t.params.clone(),
            lhs: t.lhs.as_ref().map(|j| {
                print_typst(
                    &Sym {
                        names: s.names.clone(),
                        templates: vec![],
                    },
                    j,
                )
            }),
            body: print_typst(s, &t.body),
            attrs: t.attrs.clone(),
        }))
    }
}

/// `Typ.headerT`.
pub fn header_t(front: &[(String, Json)]) -> Vec<char> {
    let mut out: Vec<char> = HEADER.chars().collect();
    args_first_t(front, &mut out);
    out.extend([')', '\n']);
    out
}

/// `Typ.canonSegs`: each construct after a blank line.
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

/// `Typ.printTyp`: print a document as Typst.
pub fn print_typ(d: &Json) -> String {
    let doc = to_doc(&CapsT, d);
    let mut out = header_t(&doc.front);
    out.extend(render(&canon_segs(items(&mathify_doc(
        &|s, j| print_typst(s, j),
        &raw_doc(&pr_tx, &doc),
    )))));
    string(&out)
}

/// `Typ.lexDoc`: read the header and the constructs.
pub fn lex_doc(s: &[char]) -> Option<(Kvs, Vec<RItem>)> {
    lex_doc_spanned(s).map(|(kvs, its)| (kvs, its.into_iter().map(|(it, _)| it).collect()))
}

/// [`lex_doc`], with where in `s` each construct is written (not in Lean).
pub fn lex_doc_spanned(s: &[char]) -> Option<(Kvs, Vec<Spanned>)> {
    if !pre_s(HEADER, s) {
        return None;
    }
    let (front, r) = p_args_first(&s[HEADER.chars().count()..])?;
    let r1 = line_end(r)?;
    let base = s.len() - r1.len();
    lex_spanned(true, r1).map(|its| {
        let its = its
            .into_iter()
            .map(|(it, at)| (it, at.start + base..at.end + base))
            .collect();
        (front, its)
    })
}

/// `Typ.parseTyp`: read a Typst document, after `decodeText`.
pub fn parse_typ(s: &str) -> Option<Json> {
    let cs: Vec<char> = s.chars().collect();
    let (front, its) = lex_doc(&decode_text(&cs))?;
    parse_items_t(front, its)
}

/// `Typ.parseItemsT`.
pub fn parse_items_t(front: Kvs, its: Vec<RItem>) -> Option<Json> {
    let r = unitems(front, its)?;
    let r = cook_doc_blocks(&|s, raw| parse_typst(s, raw), &r)?;
    let d = cook_doc(&ck_tx, &r)?;
    of_doc(&d)
}
