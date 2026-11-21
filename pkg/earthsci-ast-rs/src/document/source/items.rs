//! The skeleton as a sequence of constructs.
//!
//! Port of `formal/Esm/Document/Source/Items.lean`. [`items`] lists the
//! constructs of a skeleton in the printer's order; [`unitems`] reads a
//! construct sequence back. Math entries are held as the container's math text
//! at this layer; [`raw_doc`] prints them under each component's symbol table
//! and [`cook_doc`] reads them back.

use super::keys::Kvs;
use super::skeleton::{
    COMP_EXPR_PATHS, Comp, Decl, Doc, Eqn, Kind, MC, MR, Mx, PathSeg, Role, Rxn, TOP_EXPR_PATHS,
    Tm, is_math_field, sym_for, top_sym,
};
use crate::document::json::{Json, math_ok};
use crate::document::math::Sym;
use crate::document::math::expr::is_e;

/// `Source.RItem`: one construct of a document. An equation is its math text,
/// uninterpreted; so is a reaction's rate.
#[derive(Clone, Debug, PartialEq)]
pub enum RItem {
    Desc(String),
    Block(String, Json),
    Comp(Kind, String),
    Decl(Decl),
    Eqn(String),
    Eqx(Role, String),
    Rxn(Rxn<String>),
    Plot(Kvs),
    Tm(Tm<String>),
}

/// A construct and the range of characters it is written in (not in Lean:
/// the readers record it so a document's constructs can be traced back to
/// their source, [`super::sources`]).
pub type Spanned = (RItem, std::ops::Range<usize>);

/// `Source.mItem`: the construct of a math entry.
pub fn m_item(m: &MR) -> RItem {
    match m {
        Mx::Eq(Role::Eqn, raw) => RItem::Eqn(raw.clone()),
        Mx::Eq(r, raw) => RItem::Eqx(*r, raw.clone()),
        Mx::Rxn(x) => RItem::Rxn(x.clone()),
        Mx::Plot(a) => RItem::Plot(a.clone()),
        Mx::Tm(t) => RItem::Tm(t.clone()),
    }
}

/// `Source.compItems`: the constructs of a component section.
pub fn comp_items(c: &Comp<MR>, out: &mut Vec<RItem>) {
    out.push(RItem::Comp(c.kind, c.name.clone()));
    out.extend(c.desc.iter().map(|s| RItem::Desc(s.clone())));
    out.extend(c.decls.iter().map(|d| RItem::Decl(d.clone())));
    out.extend(c.math.iter().map(m_item));
    out.extend(
        c.math_blocks
            .iter()
            .map(|(k, v)| RItem::Block(k.clone(), v.clone())),
    );
    out.extend(
        c.blocks
            .iter()
            .map(|(k, v)| RItem::Block(k.clone(), v.clone())),
    );
}

/// `Source.items`: the constructs of a skeleton, in the printer's order.
pub fn items(d: &Doc<MR>) -> Vec<RItem> {
    let mut out: Vec<RItem> = d.desc.iter().map(|s| RItem::Desc(s.clone())).collect();
    out.extend(
        d.blocks
            .iter()
            .map(|(k, v)| RItem::Block(k.clone(), v.clone())),
    );
    out.extend(d.math.iter().map(m_item));
    for c in &d.comps {
        comp_items(c, &mut out);
    }
    out
}

/// `Comp.fresh`.
pub fn comp_fresh(k: Kind, n: String) -> Comp<MR> {
    Comp {
        kind: k,
        name: n,
        desc: None,
        decls: vec![],
        math: vec![],
        math_blocks: vec![],
        blocks: vec![],
    }
}

/// `Source.addTo`: add a construct to a component section; a second
/// description is refused.
pub fn add_to(c: &mut Comp<MR>, it: RItem) -> Option<()> {
    match it {
        RItem::Desc(s) => {
            if c.desc.is_some() {
                return None;
            }
            c.desc = Some(s);
        }
        RItem::Block(k, v) => {
            if is_math_field(&k) {
                c.math_blocks.push((k, v));
            } else {
                c.blocks.push((k, v));
            }
        }
        RItem::Decl(d) => c.decls.push(d),
        RItem::Eqn(r) => c.math.push(Mx::Eq(Role::Eqn, r)),
        RItem::Eqx(ro, r) => c.math.push(Mx::Eq(ro, r)),
        RItem::Rxn(x) => c.math.push(Mx::Rxn(x)),
        RItem::Plot(a) => c.math.push(Mx::Plot(a)),
        RItem::Tm(t) => c.math.push(Mx::Tm(t)),
        RItem::Comp(..) => return None,
    }
    Some(())
}

/// `Source.St`: the reader's state.
#[derive(Default)]
pub struct St {
    pub desc: Option<String>,
    pub blocks: Kvs,
    pub math: Vec<MR>,
    pub comps: Vec<Comp<MR>>,
    pub cur: Option<Comp<MR>>,
}

/// `Source.step`: read one construct. Before the first directive only a
/// description, blocks and templates are allowed.
pub fn step(st: &mut St, it: RItem) -> Option<()> {
    if let RItem::Comp(k, n) = it {
        st.comps.extend(st.cur.take());
        st.cur = Some(comp_fresh(k, n));
        return Some(());
    }
    match &mut st.cur {
        Some(c) => add_to(c, it),
        None => match it {
            RItem::Desc(s) => {
                if st.desc.is_some() {
                    return None;
                }
                st.desc = Some(s);
                Some(())
            }
            RItem::Block(k, v) => {
                st.blocks.push((k, v));
                Some(())
            }
            RItem::Tm(t) => {
                st.math.push(Mx::Tm(t));
                Some(())
            }
            _ => None,
        },
    }
}

/// `Source.unitems`: read a construct sequence (with the front matter) into a
/// skeleton.
pub fn unitems(front: Kvs, its: Vec<RItem>) -> Option<Doc<MR>> {
    let mut st = St::default();
    for it in its {
        step(&mut st, it)?;
    }
    let mut comps = st.comps;
    comps.extend(st.cur);
    Some(Doc {
        front,
        desc: st.desc,
        blocks: st.blocks,
        math: st.math,
        comps,
    })
}

/// `Source.rawDoc`: every math entry printed under its symbol table.
pub fn raw_doc(pr: &dyn Fn(&Sym, &MC) -> MR, d: &Doc<MC>) -> Doc<MR> {
    let ts = top_sym(d);
    Doc {
        front: d.front.clone(),
        desc: d.desc.clone(),
        blocks: d.blocks.clone(),
        math: d.math.iter().map(|m| pr(&ts, m)).collect(),
        comps: d
            .comps
            .iter()
            .map(|c| {
                let s = sym_for(d, c);
                c.map_math(|_, m| pr(&s, m))
            })
            .collect(),
    }
}

// ## Expressions inside path blocks
//
// `COMP_EXPR_PATHS` and `TOP_EXPR_PATHS` list the expression-valued fields of
// path blocks. The printer turns a value there into a math leaf (`Json::Math`)
// when it is a well-formed expression whose math text the container can
// delimit (`math_ok`); the reader reads every math leaf back, wherever it is.

/// Paths, as `Notation.Seg` lists.
type Paths<'a> = Vec<&'a [PathSeg]>;

/// `Source.stepKey`: the paths below the entry `k` of an object (or below an
/// element, `None`).
pub fn step_key<'a>(k: Option<&str>, ps: &[&'a [PathSeg]]) -> Paths<'a> {
    ps.iter()
        .filter_map(|p| match p.split_first() {
            Some((PathSeg::Any, q)) => Some(q),
            Some((PathSeg::Key(k1), q)) if Some(*k1) == k => Some(q),
            _ => None,
        })
        .collect()
}

/// `Source.atPaths`: `leaf` applied to every value of `v` at one of the paths
/// `ps` (the shortest first: a value at a path is not looked into); every other
/// value as it is.
pub fn at_paths(leaf: &dyn Fn(&Json) -> Json, ps: &[&[PathSeg]], v: &Json) -> Json {
    if ps.iter().any(|p| p.is_empty()) {
        return leaf(v);
    }
    match v {
        Json::Arr(xs) => {
            let q = step_key(None, ps);
            Json::Arr(xs.iter().map(|x| at_paths(leaf, &q, x)).collect())
        }
        Json::Obj(kvs) => Json::Obj(
            kvs.iter()
                .map(|(k, x)| (k.clone(), at_paths(leaf, &step_key(Some(k), ps), x)))
                .collect(),
        ),
        _ => v.clone(),
    }
}

/// `Source.mathLeaf`: a value at an expression path: its math text, when it is
/// a well-formed expression whose text a container can delimit; otherwise the
/// value.
pub fn math_leaf(pr_r: &dyn Fn(&Sym, &Json) -> String, s: &Sym, v: &Json) -> Json {
    if is_e(v) {
        let t = pr_r(s, v);
        if math_ok(&t) {
            return Json::Math(t);
        }
    }
    v.clone()
}

/// `Source.mathify`: print a section's path blocks: every expression at one of
/// the paths `ps` (keyed by the block's key) as math under the symbol table
/// `s`.
pub fn mathify(pr_r: &dyn Fn(&Sym, &Json) -> String, s: &Sym, ps: &[&[PathSeg]], bs: &Kvs) -> Kvs {
    let leaf = |v: &Json| math_leaf(pr_r, s, v);
    bs.iter()
        .map(|(k, v)| (k.clone(), at_paths(&leaf, &step_key(Some(k), ps), v)))
        .collect()
}

/// `Source.cookV`: every math leaf of a value read back with `ck`.
pub fn cook_v(ck: &dyn Fn(&str) -> Option<Json>, v: &Json) -> Option<Json> {
    match v {
        Json::Math(t) => ck(t),
        Json::Arr(xs) => xs
            .iter()
            .map(|x| cook_v(ck, x))
            .collect::<Option<Vec<_>>>()
            .map(Json::Arr),
        Json::Obj(kvs) => cook_o(ck, kvs).map(Json::Obj),
        _ => Some(v.clone()),
    }
}

/// `Source.cookO`.
pub fn cook_o(ck: &dyn Fn(&str) -> Option<Json>, kvs: &Kvs) -> Option<Kvs> {
    kvs.iter()
        .map(|(k, v)| cook_v(ck, v).map(|y| (k.clone(), y)))
        .collect()
}

/// `Source.cookBlocks`: read a section's path blocks: every math leaf,
/// wherever it is, read back as an expression under the symbol table `s`.
pub fn cook_blocks(ck_r: &dyn Fn(&Sym, &str) -> Option<Json>, s: &Sym, bs: &Kvs) -> Option<Kvs> {
    cook_o(&|t| ck_r(s, t), bs)
}

/// `Source.mathifyDoc`: print the path blocks of a skeleton: each section's
/// under its symbol table (a component's, or the document's for the top-level
/// blocks).
pub fn mathify_doc(pr_r: &dyn Fn(&Sym, &Json) -> String, d: &Doc<MR>) -> Doc<MR> {
    let blocks = mathify(pr_r, &top_sym(d), TOP_EXPR_PATHS, &d.blocks);
    let comps = d
        .comps
        .iter()
        .map(|c| Comp {
            blocks: mathify(pr_r, &sym_for(d, c), COMP_EXPR_PATHS, &c.blocks),
            ..c.clone()
        })
        .collect();
    Doc {
        blocks,
        comps,
        ..d.clone()
    }
}

/// `Source.cookDocBlocks`: read the path blocks of a skeleton: every math leaf
/// of a section's blocks under the section's symbol table.
pub fn cook_doc_blocks(ck_r: &dyn Fn(&Sym, &str) -> Option<Json>, d: &Doc<MR>) -> Option<Doc<MR>> {
    let blocks = cook_blocks(ck_r, &top_sym(d), &d.blocks)?;
    let comps = d
        .comps
        .iter()
        .map(|c| {
            cook_blocks(ck_r, &sym_for(d, c), &c.blocks).map(|b| Comp {
                blocks: b,
                ..c.clone()
            })
        })
        .collect::<Option<Vec<_>>>()?;
    Some(Doc {
        blocks,
        comps,
        ..d.clone()
    })
}

/// `Source.cookComp`: read a component's math entries under its symbol table;
/// one math text may hold several equations. Also returns how many entries
/// each math text read as (Lean's `cookComp` returns the component alone).
pub fn cook_comp_counted(
    ck: &dyn Fn(&Sym, &MR) -> Option<Vec<MC>>,
    d: &Doc<MR>,
    c: &Comp<MR>,
) -> Option<(Comp<MC>, Vec<usize>)> {
    let s = sym_for(d, c);
    let mut math = Vec::new();
    let mut counts = Vec::with_capacity(c.math.len());
    for m in &c.math {
        let ms = ck(&s, m)?;
        counts.push(ms.len());
        math.extend(ms);
    }
    Some((
        Comp {
            kind: c.kind,
            name: c.name.clone(),
            desc: c.desc.clone(),
            decls: c.decls.clone(),
            math,
            math_blocks: c.math_blocks.clone(),
            blocks: c.blocks.clone(),
        },
        counts,
    ))
}

/// `Source.cookDoc`: read every math entry of a skeleton.
pub fn cook_doc(ck: &dyn Fn(&Sym, &MR) -> Option<Vec<MC>>, d: &Doc<MR>) -> Option<Doc<MC>> {
    cook_doc_counted(ck, d).map(|(d, _)| d)
}

/// How many entries each math entry of a skeleton read as: the top-level
/// templates, then each component's math entries.
pub struct Counts {
    pub top: Vec<usize>,
    pub comps: Vec<Vec<usize>>,
}

/// [`cook_doc`], with the [`Counts`] (not in Lean).
pub fn cook_doc_counted(
    ck: &dyn Fn(&Sym, &MR) -> Option<Vec<MC>>,
    d: &Doc<MR>,
) -> Option<(Doc<MC>, Counts)> {
    let ts = top_sym(d);
    let mut rm = Vec::new();
    let mut top = Vec::with_capacity(d.math.len());
    for m in &d.math {
        let ms = ck(&ts, m)?;
        top.push(ms.len());
        rm.extend(ms);
    }
    let (cs, comps): (Vec<_>, Vec<_>) = d
        .comps
        .iter()
        .map(|c| cook_comp_counted(ck, d, c))
        .collect::<Option<Vec<_>>>()?
        .into_iter()
        .unzip();
    Some((
        Doc {
            front: d.front.clone(),
            desc: d.desc.clone(),
            blocks: d.blocks.clone(),
            math: rm,
            comps: cs,
        },
        Counts { top, comps },
    ))
}

/// `Source.prMx`: a math entry's text, from the equation and expression
/// printers.
pub fn pr_mx(
    pr_e: &dyn Fn(&Sym, &Eqn) -> String,
    pr_r: &dyn Fn(&Sym, &Json) -> String,
    s: &Sym,
    m: &MC,
) -> MR {
    match m {
        Mx::Eq(r, e) => Mx::Eq(*r, pr_e(s, e)),
        Mx::Rxn(x) => Mx::Rxn(Rxn {
            id: x.id.clone(),
            subs: x.subs.clone(),
            prods: x.prods.clone(),
            rate: pr_r(s, &x.rate),
            attrs: x.attrs.clone(),
        }),
        Mx::Plot(a) => Mx::Plot(a.clone()),
        Mx::Tm(t) => {
            let sc = t.scope(s);
            Mx::Tm(Tm {
                name: t.name.clone(),
                params: t.params.clone(),
                lhs: t.lhs.as_ref().map(|l| pr_r(&t.mscope(s), l)),
                body: pr_r(&sc, &t.body),
                attrs: t.attrs.clone(),
            })
        }
    }
}

/// `Source.ckMx`: read a math entry's text back.
pub fn ck_mx(
    ck_e: &dyn Fn(&Sym, &str) -> Option<Vec<Eqn>>,
    ck_r: &dyn Fn(&Sym, &str) -> Option<Json>,
    s: &Sym,
    m: &MR,
) -> Option<Vec<MC>> {
    match m {
        Mx::Eq(r, raw) => ck_e(s, raw).map(|es| es.into_iter().map(|e| Mx::Eq(*r, e)).collect()),
        Mx::Rxn(x) => ck_r(s, &x.rate).map(|j| {
            vec![Mx::Rxn(Rxn {
                id: x.id.clone(),
                subs: x.subs.clone(),
                prods: x.prods.clone(),
                rate: j,
                attrs: x.attrs.clone(),
            })]
        }),
        Mx::Plot(a) => Some(vec![Mx::Plot(a.clone())]),
        Mx::Tm(t) => {
            let sc = t.scope(s);
            let lhs = match &t.lhs {
                None => None,
                Some(l) => Some(ck_r(&t.mscope(s), l)?),
            };
            let body = ck_r(&sc, &t.body)?;
            Some(vec![Mx::Tm(Tm {
                name: t.name.clone(),
                params: t.params.clone(),
                lhs,
                body,
                attrs: t.attrs.clone(),
            })])
        }
    }
}
