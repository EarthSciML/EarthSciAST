//! The document skeleton: front matter, description, path blocks, and one
//! section per model or reaction system, with the path-keyed fallback for every
//! field without a native surface.
//!
//! Port of `formal/Esm/Document/Source/Skeleton.lean`. The mapping is total:
//! every field a container cannot spell natively falls back to a block keyed by
//! its JSON path relative to the enclosing section. [`Caps`] are the
//! container's predicates saying which values it spells natively.
//!
//! Not ported: `Source.canonVal`, `Source.tmKeys`, `Source.tmWF`,
//! `Source.mathWF`. No executable path uses them; only the Lean proofs do.

use super::keys::{Kvs, at_, join_field, pick_one, sort_keys, split_opt};
use crate::document::json::{JNum, Json};
use crate::document::math::Sym;
use crate::document::math::expr::{is_e, jwf, keys_sorted, look};

// ## The canonical form of a document

/// `Source.sortedDeep`: every object, at every depth, has strictly increasing
/// keys.
pub fn sorted_deep(j: &Json) -> bool {
    match j {
        Json::Obj(kvs) => keys_sorted(kvs) && kvs.iter().all(|(_, v)| sorted_deep(v)),
        Json::Arr(xs) => xs.iter().all(sorted_deep),
        _ => true,
    }
}

/// `Source.canonDoc`: a JSON object, well formed, with sorted keys at every
/// depth.
pub fn canon_doc(j: &Json) -> bool {
    matches!(j, Json::Obj(_)) && jwf(j) && sorted_deep(j)
}

/// `Source.Kind`: a model or a reaction system.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Model,
    Rs,
}

/// `Source.DKind`: the declaration directives (`Sub`: a subsystem included by
/// reference).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DKind {
    Var,
    Param,
    Species,
    Sub,
}

/// `Source.Decl`: the directive, the declared name, and the other fields of
/// the declared object as attributes.
#[derive(Clone, Debug, PartialEq)]
pub struct Decl {
    pub kind: DKind,
    pub name: String,
    pub attrs: Kvs,
}

/// `Source.Eqn`: `lhs = rhs`, with its optional `_comment`.
#[derive(Clone, Debug, PartialEq)]
pub struct Eqn {
    pub comment: Option<String>,
    pub lhs: Json,
    pub rhs: Json,
}

/// `Source.Role`: the field an equation belongs to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Role {
    Eqn,
    Init,
    Cons,
}

impl Role {
    /// `Role.field`.
    pub fn field(self) -> &'static str {
        match self {
            Role::Eqn => "equations",
            Role::Init => "initialization_equations",
            Role::Cons => "constraint_equations",
        }
    }
}

/// `Source.Term`: a species and its stoichiometric coefficient.
#[derive(Clone, Debug, PartialEq)]
pub struct Term {
    pub species: String,
    pub coef: JNum,
}

/// `Source.Rxn`: a reaction's `id`, sides (`None` for an empty side), rate (`R`:
/// the expression, or its math text) and other fields.
#[derive(Clone, Debug, PartialEq)]
pub struct Rxn<R> {
    pub id: String,
    pub subs: Option<Vec<Term>>,
    pub prods: Option<Vec<Term>>,
    pub rate: R,
    pub attrs: Kvs,
}

/// `Source.Tm`: an entry of `expression_templates`: a template (`lhs = None`)
/// or a rewrite rule (`lhs = Some(match)`).
#[derive(Clone, Debug, PartialEq)]
pub struct Tm<R> {
    pub name: String,
    pub params: Vec<String>,
    pub lhs: Option<R>,
    pub body: R,
    pub attrs: Kvs,
}

/// `Source.Mx`: a list entry of a component.
#[derive(Clone, Debug, PartialEq)]
pub enum Mx<A, R> {
    Eq(Role, A),
    Rxn(Rxn<R>),
    Plot(Kvs),
    Tm(Tm<R>),
}

/// `Source.MC`: a math entry as read.
pub type MC = Mx<Eqn, Json>;
/// `Source.MR`: a math entry as the container's text.
pub type MR = Mx<String, String>;

impl<A, R> Mx<A, R> {
    /// `Mx.field`.
    pub fn field(&self) -> &'static str {
        match self {
            Mx::Eq(r, _) => r.field(),
            Mx::Rxn(_) => "reactions",
            Mx::Plot(_) => "analyses",
            Mx::Tm(_) => "operators",
        }
    }

    /// `Mx.key`.
    pub fn key(&self) -> &str {
        match self {
            Mx::Tm(t) => &t.name,
            _ => "",
        }
    }

    /// `Mx.head`: the symbol-table entry of a template or rule.
    pub fn head(&self) -> Option<(String, Vec<String>)> {
        match self {
            Mx::Tm(t) => Some((t.name.clone(), t.ps())),
            _ => None,
        }
    }
}

/// `Source.mathFields`.
pub const MATH_FIELDS: &[&str] = &[
    "analyses",
    "constraint_equations",
    "equations",
    "operators",
    "initialization_equations",
    "reactions",
];

/// `k ∈ mathFields`.
pub fn is_math_field(k: &str) -> bool {
    MATH_FIELDS.contains(&k)
}

/// `Source.Comp`: one component section.
#[derive(Clone, Debug, PartialEq)]
pub struct Comp<A> {
    pub kind: Kind,
    pub name: String,
    pub desc: Option<String>,
    pub decls: Vec<Decl>,
    pub math: Vec<A>,
    pub math_blocks: Kvs,
    pub blocks: Kvs,
}

/// `Source.Doc`: a document skeleton.
#[derive(Clone, Debug, PartialEq)]
pub struct Doc<A> {
    pub front: Kvs,
    pub desc: Option<String>,
    pub blocks: Kvs,
    pub math: Vec<A>,
    pub comps: Vec<Comp<A>>,
}

impl<A> Comp<A> {
    /// `Comp.mapMath`.
    pub fn map_math<B>(&self, f: impl Fn(&Comp<A>, &A) -> B) -> Comp<B> {
        Comp {
            kind: self.kind,
            name: self.name.clone(),
            desc: self.desc.clone(),
            decls: self.decls.clone(),
            math: self.math.iter().map(|m| f(self, m)).collect(),
            math_blocks: self.math_blocks.clone(),
            blocks: self.blocks.clone(),
        }
    }
}

// ## The symbol table of a component

/// `Source.keysOf`.
pub fn keys_of(v: Option<&Json>) -> Vec<String> {
    match v {
        Some(Json::Obj(kvs)) => kvs.iter().map(|kv| kv.0.clone()).collect(),
        _ => vec![],
    }
}

/// `Source.strsOf`.
pub fn strs_of(v: Option<&Json>) -> Vec<String> {
    match v {
        Some(Json::Arr(xs)) => xs
            .iter()
            .filter_map(|x| match x {
                Json::Str(s) => Some(s.clone()),
                _ => None,
            })
            .collect(),
        _ => vec![],
    }
}

/// `Source.templatesOf`.
pub fn templates_of(v: Option<&Json>) -> Vec<(String, Vec<String>)> {
    match v {
        Some(Json::Obj(kvs)) => kvs
            .iter()
            .filter_map(|(k, v)| match v {
                Json::Obj(t) => Some((k.clone(), strs_of(look("params", t)))),
                _ => None,
            })
            .collect(),
        _ => vec![],
    }
}

impl<R> Tm<R> {
    /// `Tm.ps`: a template's header parameters; a rule's `params` attribute.
    pub fn ps(&self) -> Vec<String> {
        match self.lhs {
            None => self.params.clone(),
            Some(_) => strs_of(look("params", &self.attrs)),
        }
    }

    /// `Tm.scope`: the table around it, with the parameters declared.
    pub fn scope(&self, s: &Sym) -> Sym {
        let mut names = s.names.clone();
        names.extend(self.ps());
        Sym {
            names,
            templates: s.templates.clone(),
        }
    }
    /// `Tm.mscope`: the symbol table a rule's `match` pattern is read under: its
    /// body's, with no templates. A pattern never applies a template (spec
    /// §9.7.3), so an operator in it named like a template in scope (a rule is
    /// in scope under its own name) reads as that operator, in the call form.
    pub fn mscope(&self, s: &Sym) -> Sym {
        Sym {
            names: self.scope(s).names,
            templates: vec![],
        }
    }
}

/// `Source.rootTs`.
pub fn root_ts<A, R>(root: &[(String, Json)], rm: &[Mx<A, R>]) -> Vec<(String, Vec<String>)> {
    let mut out = templates_of(look("operators", root));
    out.extend(rm.iter().filter_map(Mx::head));
    out
}

/// `Source.compTs`.
pub fn comp_ts<A, R>(c: &Comp<Mx<A, R>>) -> Vec<(String, Vec<String>)> {
    let mut out = templates_of(look("operators", &c.math_blocks));
    out.extend(c.math.iter().filter_map(Mx::head));
    out
}

/// `Source.symWith`.
pub fn sym_with<A>(
    root: &[(String, Json)],
    rt: &[(String, Vec<String>)],
    c: &Comp<A>,
    ct: Vec<(String, Vec<String>)>,
) -> Sym {
    let mut names: Vec<String> = c
        .decls
        .iter()
        .filter(|d| d.kind != DKind::Sub)
        .map(|d| d.name.clone())
        .collect();
    names.extend(keys_of(look("variables", &c.blocks)));
    names.extend(keys_of(look("species", &c.blocks)));
    names.extend(keys_of(look("parameters", &c.blocks)));
    names.extend(keys_of(look("index_sets", root)));
    let mut templates = rt.to_vec();
    templates.extend(ct);
    Sym { names, templates }
}

/// `Source.symFor`: the symbol table of a component.
pub fn sym_for<A, R>(d: &Doc<Mx<A, R>>, c: &Comp<Mx<A, R>>) -> Sym {
    sym_with(&d.blocks, &root_ts(&d.blocks, &d.math), c, comp_ts(c))
}

/// `Source.topSym`: the symbol table of the top-level templates.
pub fn top_sym<A, R>(d: &Doc<Mx<A, R>>) -> Sym {
    Sym {
        names: keys_of(look("index_sets", &d.blocks)),
        templates: root_ts(&d.blocks, &d.math),
    }
}

/// `Source.Caps`: what a container spells natively.
pub trait Caps {
    /// A front-matter key.
    fn front_key(&self, k: &str) -> bool;
    /// A description text.
    fn desc(&self, s: &str) -> bool;
    /// A component name in its directive.
    fn comp_name(&self, n: &str) -> bool;
    /// A declared name (printed as math).
    fn decl_name(&self, n: &str) -> bool;
    /// A declaration attribute.
    fn attr(&self, a: &(String, Json)) -> bool;
    /// An equation under the component's symbol table.
    fn eqn(&self, s: &Sym, e: &Eqn) -> bool;
    /// A reaction under the component's symbol table.
    fn rxn(&self, s: &Sym, x: &Rxn<Json>) -> bool;
    /// The fields of a plot directive.
    fn plot(&self, a: &[(String, Json)]) -> bool;
    /// A template or rule, under its body's symbol table.
    fn tm(&self, s: &Sym, t: &Tm<Json>) -> bool;

    /// `Caps.item`: a list entry the container spells.
    fn item(&self, s: &Sym, m: &MC) -> bool {
        match m {
            Mx::Eq(_, e) => self.eqn(s, e),
            Mx::Rxn(x) => self.rxn(s, x),
            Mx::Plot(a) => self.plot(a),
            Mx::Tm(t) => self.tm(&t.scope(s), t),
        }
    }
}

// ## Equations and the other math entries

fn obj(kvs: &[(&str, Json)]) -> Json {
    Json::Obj(
        kvs.iter()
            .map(|(k, v)| (k.to_string(), v.clone()))
            .collect(),
    )
}

/// `Source.eqnJson`.
pub fn eqn_json(e: &Eqn) -> Json {
    match &e.comment {
        Some(c) => obj(&[
            ("_comment", Json::Str(c.clone())),
            ("lhs", e.lhs.clone()),
            ("rhs", e.rhs.clone()),
        ]),
        None => obj(&[("lhs", e.lhs.clone()), ("rhs", e.rhs.clone())]),
    }
}

/// `Source.eqnOf`: exactly the keys `lhs`, `rhs` and optionally a string
/// `_comment`, both sides well-formed expressions.
pub fn eqn_of(v: &Json) -> Option<Eqn> {
    let Json::Obj(kvs) = v else { return None };
    match kvs.as_slice() {
        [(c, Json::Str(cm)), (l, lv), (r, rv)] if c == "_comment" && l == "lhs" && r == "rhs" => {
            (is_e(lv) && is_e(rv)).then(|| Eqn {
                comment: Some(cm.clone()),
                lhs: lv.clone(),
                rhs: rv.clone(),
            })
        }
        [(l, lv), (r, rv)] if l == "lhs" && r == "rhs" => (is_e(lv) && is_e(rv)).then(|| Eqn {
            comment: None,
            lhs: lv.clone(),
            rhs: rv.clone(),
        }),
        _ => None,
    }
}

/// `Source.termJson`.
pub fn term_json(t: &Term) -> Json {
    obj(&[
        ("species", Json::Str(t.species.clone())),
        ("stoichiometry", Json::Num(t.coef.clone())),
    ])
}

/// `Source.termOf`.
pub fn term_of(v: &Json) -> Option<Term> {
    let Json::Obj(kvs) = v else { return None };
    match kvs.as_slice() {
        [(a, Json::Str(s)), (b, Json::Num(n))] if a == "species" && b == "stoichiometry" => {
            Some(Term {
                species: s.clone(),
                coef: n.clone(),
            })
        }
        _ => None,
    }
}

/// `Source.sideJson`.
pub fn side_json(s: &Option<Vec<Term>>) -> Json {
    match s {
        None => Json::Null,
        Some(ts) => Json::Arr(ts.iter().map(term_json).collect()),
    }
}

/// `Source.sideOf`: `null`, or a non-empty array of terms.
pub fn side_of(v: &Json) -> Option<Option<Vec<Term>>> {
    match v {
        Json::Null => Some(None),
        Json::Arr(xs) if !xs.is_empty() => {
            xs.iter().map(term_of).collect::<Option<Vec<_>>>().map(Some)
        }
        _ => None,
    }
}

/// `Source.rxnKeys`.
pub const RXN_KEYS: &[&str] = &["id", "products", "rate", "substrates"];

/// `Source.rxnJson`.
pub fn rxn_json(x: &Rxn<Json>) -> Json {
    let mut kvs = vec![
        ("id".to_string(), Json::Str(x.id.clone())),
        ("products".to_string(), side_json(&x.prods)),
        ("rate".to_string(), x.rate.clone()),
        ("substrates".to_string(), side_json(&x.subs)),
    ];
    kvs.extend(x.attrs.iter().cloned());
    Json::Obj(sort_keys(kvs))
}

/// `Source.rxnOf`: checked by printing it back.
pub fn rxn_of(v: &Json) -> Option<Rxn<Json>> {
    let Json::Obj(kvs) = v else { return None };
    let id = look("id", kvs);
    let s = look("substrates", kvs).and_then(side_of);
    let p = look("products", kvs).and_then(side_of);
    let r = look("rate", kvs);
    match (id, s, p, r) {
        (Some(Json::Str(i)), Some(s), Some(p), Some(r)) => {
            let x = Rxn {
                id: i.clone(),
                subs: s,
                prods: p,
                rate: r.clone(),
                attrs: kvs
                    .iter()
                    .filter(|kv| !RXN_KEYS.contains(&kv.0.as_str()))
                    .cloned()
                    .collect(),
            };
            (rxn_json(&x) == *v && is_e(r)).then_some(x)
        }
        _ => None,
    }
}

/// `Source.plotJson`.
pub fn plot_json(attrs: &[(String, Json)]) -> Json {
    Json::Obj(sort_keys(
        attrs
            .iter()
            .map(|(k, v)| {
                if k == "plot" {
                    ("plots".to_string(), Json::Arr(vec![v.clone()]))
                } else {
                    (k.clone(), v.clone())
                }
            })
            .collect(),
    ))
}

/// `Source.plotOf`: an analysis with exactly one plot and no `plot` field,
/// checked by printing it back.
pub fn plot_of(v: &Json) -> Option<Kvs> {
    let Json::Obj(kvs) = v else { return None };
    match (look("plots", kvs), look("plot", kvs)) {
        (Some(Json::Arr(ps)), None) if ps.len() == 1 => {
            let a: Kvs = kvs
                .iter()
                .map(|(k, x)| {
                    if k == "plots" {
                        ("plot".to_string(), ps[0].clone())
                    } else {
                        (k.clone(), x.clone())
                    }
                })
                .collect();
            (plot_json(&a) == *v).then_some(a)
        }
        _ => None,
    }
}

/// `Source.tmJson`.
pub fn tm_json(t: &Tm<Json>) -> Json {
    let mut kvs = match &t.lhs {
        None => vec![
            ("body".to_string(), t.body.clone()),
            (
                "params".to_string(),
                Json::Arr(t.params.iter().map(|p| Json::Str(p.clone())).collect()),
            ),
        ],
        Some(m) => vec![
            ("body".to_string(), t.body.clone()),
            ("match".to_string(), m.clone()),
        ],
    };
    kvs.extend(t.attrs.iter().cloned());
    Json::Obj(sort_keys(kvs))
}

/// `Source.strList`: the string entries of a list, when every entry is a
/// string.
pub fn str_list(xs: &[Json]) -> Option<Vec<String>> {
    xs.iter()
        .map(|x| match x {
            Json::Str(s) => Some(s.clone()),
            _ => None,
        })
        .collect()
}

/// `Source.tmOf`: the template or rule an entry of `expression_templates` is,
/// checked by printing it back.
pub fn tm_of(n: &str, v: &Json) -> Option<Tm<Json>> {
    let Json::Obj(kvs) = v else { return None };
    match (look("body", kvs), look("match", kvs), look("params", kvs)) {
        (Some(b), None, Some(Json::Arr(ps))) => {
            let ps2 = str_list(ps)?;
            let t = Tm {
                name: n.to_string(),
                params: ps2,
                lhs: None,
                body: b.clone(),
                attrs: kvs
                    .iter()
                    .filter(|kv| kv.0 != "body" && kv.0 != "params")
                    .cloned()
                    .collect(),
            };
            (tm_json(&t) == *v && is_e(b)).then_some(t)
        }
        (Some(b), Some(m), _) => {
            let t = Tm {
                name: n.to_string(),
                params: vec![],
                lhs: Some(m.clone()),
                body: b.clone(),
                attrs: kvs
                    .iter()
                    .filter(|kv| kv.0 != "body" && kv.0 != "match")
                    .cloned()
                    .collect(),
            };
            (tm_json(&t) == *v && is_e(b) && is_e(m)).then_some(t)
        }
        _ => None,
    }
}

/// `Source.itemJson`.
pub fn item_json(m: &MC) -> Json {
    match m {
        Mx::Eq(_, e) => eqn_json(e),
        Mx::Rxn(x) => rxn_json(x),
        Mx::Plot(a) => plot_json(a),
        Mx::Tm(t) => tm_json(t),
    }
}

/// `Source.fieldJson`: an object keyed by the entries' names for
/// `expression_templates`, a list otherwise.
pub fn field_json(f: &str, ms: &[&MC]) -> Json {
    if f == "operators" {
        Json::Obj(
            ms.iter()
                .map(|m| (m.key().to_string(), item_json(m)))
                .collect(),
        )
    } else {
        Json::Arr(ms.iter().map(|m| item_json(m)).collect())
    }
}

/// `Source.roleOf`.
pub fn role_of(f: &str) -> Option<Role> {
    [Role::Eqn, Role::Init, Role::Cons]
        .into_iter()
        .find(|r| r.field() == f)
}

/// `Source.itemOf`.
pub fn item_of(f: &str, v: &Json) -> Option<MC> {
    if f == "reactions" {
        rxn_of(v).map(Mx::Rxn)
    } else if f == "analyses" {
        plot_of(v).map(Mx::Plot)
    } else {
        role_of(f).and_then(|r| eqn_of(v).map(|e| Mx::Eq(r, e)))
    }
}

/// `Source.tmItem`.
pub fn tm_item(kv: &(String, Json)) -> Option<MC> {
    tm_of(&kv.0, &kv.1).map(Mx::Tm)
}

/// `Source.mathOf`: the entries of a math field, when all of them print
/// natively.
pub fn math_of(caps: &dyn Caps, s: &Sym, f: &str, v: &Json) -> Option<Vec<MC>> {
    let ms: Vec<MC> = match v {
        Json::Arr(xs) if !xs.is_empty() => {
            if f == "operators" {
                return None;
            }
            xs.iter().map(|x| item_of(f, x)).collect::<Option<_>>()?
        }
        Json::Obj(kvs) if !kvs.is_empty() => {
            if f != "operators" {
                return None;
            }
            kvs.iter().map(tm_item).collect::<Option<_>>()?
        }
        _ => return None,
    };
    ms.iter().all(|m| caps.item(s, m)).then_some(ms)
}

/// `Source.descOf`.
pub fn desc_of(caps: &dyn Caps, v: Option<&Json>) -> Option<String> {
    match v {
        Some(Json::Str(s)) if caps.desc(s) => Some(s.clone()),
        _ => None,
    }
}

/// `Source.metaOf`: `metadata` printed in the front matter: the front-matter
/// entries and the description.
pub fn meta_of(caps: &dyn Caps, v: Option<&Json>) -> Option<(Kvs, Option<String>)> {
    match v {
        Some(Json::Obj(kvs))
            if !kvs.is_empty()
                && look("esm", kvs).is_none()
                && kvs.iter().all(|kv| caps.front_key(&kv.0)) =>
        {
            let d = desc_of(caps, look("description", kvs));
            let es = kvs
                .iter()
                .filter(|kv| !(kv.0 == "description" && d.is_some()))
                .cloned()
                .collect();
            Some((es, d))
        }
        _ => None,
    }
}

/// `Source.pickVar`: a model variable as a declaration.
pub fn pick_var(caps: &dyn Caps, n: &str, v: &Json) -> Option<Decl> {
    if !caps.decl_name(n) {
        return None;
    }
    let Json::Obj(kvs) = v else { return None };
    let without_type = || -> Kvs { kvs.iter().filter(|kv| kv.0 != "type").cloned().collect() };
    let mk = |kind, attrs: Kvs| {
        attrs.iter().all(|a| caps.attr(a)).then(|| Decl {
            kind,
            name: n.to_string(),
            attrs,
        })
    };
    match look("type", kvs) {
        Some(Json::Str(t)) if t == "parameter" => mk(DKind::Param, without_type()),
        Some(Json::Str(t)) if t == "unknown" => mk(DKind::Var, without_type()),
        Some(_) => mk(DKind::Var, kvs.clone()),
        None => None,
    }
}

/// `Source.pickPlain`: a reaction-system species or parameter as a
/// declaration of kind `k`.
pub fn pick_plain(caps: &dyn Caps, k: DKind, n: &str, v: &Json) -> Option<Decl> {
    if !caps.decl_name(n) {
        return None;
    }
    match v {
        Json::Obj(kvs) if kvs.iter().all(|a| caps.attr(a)) => Some(Decl {
            kind: k,
            name: n.to_string(),
            attrs: kvs.clone(),
        }),
        _ => None,
    }
}

/// `Source.pickSub`: a subsystem included by reference.
pub fn pick_sub(caps: &dyn Caps, n: &str, v: &Json) -> Option<Decl> {
    match v {
        Json::Obj(kvs) if look("ref", kvs).is_some() => pick_plain(caps, DKind::Sub, n, v),
        _ => None,
    }
}

/// The pickers of `Source.declFields`.
#[derive(Clone, Copy, Debug)]
pub enum Picker {
    Var,
    Plain(DKind),
    Sub,
}

impl Picker {
    /// Apply the picker.
    pub fn pick(self, caps: &dyn Caps, n: &str, v: &Json) -> Option<Decl> {
        match self {
            Picker::Var => pick_var(caps, n, v),
            Picker::Plain(k) => pick_plain(caps, k, n, v),
            Picker::Sub => pick_sub(caps, n, v),
        }
    }
}

/// `Source.declFields`: the declaration fields of a component kind, with their
/// pickers.
pub fn decl_fields(k: Kind) -> &'static [(&'static str, Picker)] {
    match k {
        Kind::Model => &[("variables", Picker::Var), ("subsystems", Picker::Sub)],
        Kind::Rs => &[
            ("species", Picker::Plain(DKind::Species)),
            ("parameters", Picker::Plain(DKind::Param)),
            ("subsystems", Picker::Sub),
        ],
    }
}

/// `Source.declField`.
pub fn decl_field(k: Kind, d: DKind) -> Option<&'static str> {
    match (k, d) {
        (Kind::Model, DKind::Var) | (Kind::Model, DKind::Param) => Some("variables"),
        (Kind::Model, DKind::Species) => None,
        (Kind::Rs, DKind::Species) => Some("species"),
        (Kind::Rs, DKind::Param) => Some("parameters"),
        (Kind::Rs, DKind::Var) => None,
        (_, DKind::Sub) => Some("subsystems"),
    }
}

/// `Source.backDecl`: the entry a declaration stands for.
pub fn back_decl(k: Kind, d: &Decl) -> Option<(String, Json)> {
    let has_type = d.attrs.iter().any(|kv| kv.0 == "type");
    let with = |t: &str| {
        let mut a = vec![("type".to_string(), Json::str(t))];
        a.extend(d.attrs.iter().cloned());
        Json::Obj(sort_keys(a))
    };
    match (k, d.kind) {
        (Kind::Model, DKind::Param) => {
            if has_type {
                None
            } else {
                Some((d.name.clone(), with("parameter")))
            }
        }
        (Kind::Model, DKind::Var) => {
            if has_type {
                Some((d.name.clone(), Json::Obj(sort_keys(d.attrs.clone()))))
            } else {
                Some((d.name.clone(), with("unknown")))
            }
        }
        (Kind::Rs, DKind::Species) | (Kind::Rs, DKind::Param) | (_, DKind::Sub) => {
            Some((d.name.clone(), Json::Obj(sort_keys(d.attrs.clone()))))
        }
        _ => None,
    }
}

/// `Source.compBlock`: where an entry of a component goes when it is not a
/// native surface.
pub fn comp_block(
    caps: &dyn Caps,
    k: Kind,
    desc: &Option<String>,
    kv: &(String, Json),
) -> Option<(String, Json)> {
    if kv.0 == "description" {
        if desc.is_some() {
            None
        } else {
            Some(kv.clone())
        }
    } else if is_math_field(&kv.0) {
        None
    } else {
        match decl_fields(k).iter().find(|f| f.0 == kv.0) {
            Some((_, p)) => split_opt(|n, v| p.pick(caps, n, v), Some(&kv.1))
                .1
                .map(|r| (kv.0.clone(), r)),
            None => Some(kv.clone()),
        }
    }
}

/// `Source.compBase`: a component before its equations are decided.
pub fn comp_base(caps: &dyn Caps, k: Kind, name: &str, kvs: &[(String, Json)]) -> Comp<MC> {
    let desc = desc_of(caps, look("description", kvs));
    let decls = decl_fields(k)
        .iter()
        .flat_map(|(f, p)| split_opt(|n, v| p.pick(caps, n, v), look(f, kvs)).0)
        .collect();
    let blocks = kvs
        .iter()
        .filter_map(|kv| comp_block(caps, k, &desc, kv))
        .collect();
    Comp {
        kind: k,
        name: name.to_string(),
        desc,
        decls,
        math: vec![],
        math_blocks: vec![],
        blocks,
    }
}

/// `Source.mathPart`: one math field of a component: its entries when every
/// one prints natively under `s`, else its block.
pub fn math_part(
    caps: &dyn Caps,
    s: &Sym,
    kvs: &[(String, Json)],
    f: &str,
) -> (Vec<MC>, Option<(String, Json)>) {
    match look(f, kvs) {
        None => (vec![], None),
        Some(v) => match math_of(caps, s, f, v) {
            Some(ms) => (ms, None),
            None => (vec![], Some((f.to_string(), v.clone()))),
        },
    }
}

/// `Source.compSym`.
pub fn comp_sym(
    root: &[(String, Json)],
    rt: &[(String, Vec<String>)],
    k: Kind,
    caps: &dyn Caps,
    name: &str,
    kvs: &[(String, Json)],
) -> Sym {
    sym_with(
        root,
        rt,
        &comp_base(caps, k, name, kvs),
        templates_of(look("operators", kvs)),
    )
}

/// `Source.compOf`: a component, with its math fields decided.
pub fn comp_of(
    caps: &dyn Caps,
    root: &[(String, Json)],
    rt: &[(String, Vec<String>)],
    k: Kind,
    name: &str,
    kvs: &[(String, Json)],
) -> Comp<MC> {
    let mut c = comp_base(caps, k, name, kvs);
    let s = comp_sym(root, rt, k, caps, name, kvs);
    for f in MATH_FIELDS {
        let (ms, b) = math_part(caps, &s, kvs, f);
        c.math.extend(ms);
        c.math_blocks.extend(b);
    }
    c
}

/// `Source.pickComp`.
pub fn pick_comp(caps: &dyn Caps, n: &str, v: &Json) -> Option<(String, Kvs)> {
    match v {
        Json::Obj(kvs) if caps.comp_name(n) => Some((n.to_string(), kvs.clone())),
        _ => None,
    }
}

/// `Source.topSymOf`.
pub fn top_sym_of(kvs: &[(String, Json)]) -> Sym {
    Sym {
        names: keys_of(look("index_sets", kvs)),
        templates: templates_of(look("operators", kvs)),
    }
}

/// `Source.topMath`: the top-level templates, when every one prints natively.
pub fn top_math(caps: &dyn Caps, kvs: &[(String, Json)]) -> Option<Vec<MC>> {
    look("operators", kvs).and_then(|v| math_of(caps, &top_sym_of(kvs), "operators", v))
}

/// `Source.rootBlock`.
pub fn root_block(caps: &dyn Caps, tn: bool, kv: &(String, Json)) -> Option<(String, Json)> {
    let k = kv.0.as_str();
    if k == "esm" {
        None
    } else if k == "metadata" {
        if meta_of(caps, Some(&kv.1)).is_some() {
            None
        } else {
            Some(kv.clone())
        }
    } else if k == "models" || k == "reaction_systems" {
        split_opt(|n, v| pick_comp(caps, n, v), Some(&kv.1))
            .1
            .map(|r| (kv.0.clone(), r))
    } else if k == "operators" && tn {
        None
    } else {
        Some(kv.clone())
    }
}

/// `Source.rootBlocks`.
pub fn root_blocks(caps: &dyn Caps, tn: bool, kvs: &[(String, Json)]) -> Kvs {
    kvs.iter()
        .filter_map(|kv| root_block(caps, tn, kv))
        .collect()
}

/// `Source.toDoc`: the skeleton of a document.
pub fn to_doc(caps: &dyn Caps, d: &Json) -> Doc<MC> {
    let Json::Obj(kvs) = d else {
        return Doc {
            front: vec![],
            desc: None,
            blocks: vec![],
            math: vec![],
            comps: vec![],
        };
    };
    let m = meta_of(caps, look("metadata", kvs));
    let tm = top_math(caps, kvs);
    let blocks = root_blocks(caps, tm.is_some(), kvs);
    let rt = templates_of(look("operators", kvs));
    let comps = |k: Kind, f: &str| -> Vec<Comp<MC>> {
        split_opt(|n, v| pick_comp(caps, n, v), look(f, kvs))
            .0
            .into_iter()
            .map(|(n, ckvs)| comp_of(caps, &blocks, &rt, k, &n, &ckvs))
            .collect()
    };
    let mut cs = comps(Kind::Model, "models");
    cs.extend(comps(Kind::Rs, "reaction_systems"));
    let mut front = at_("esm", kvs);
    let desc = m.as_ref().and_then(|p| p.1.clone());
    if let Some((es, _)) = m {
        front.extend(es);
    }
    Doc {
        front,
        desc,
        blocks,
        math: tm.unwrap_or_default(),
        comps: cs,
    }
}

// ## From a skeleton back to the document

/// `Source.optKv`.
pub fn opt_kv(k: &str, v: Option<Json>) -> Kvs {
    match v {
        Some(v) => vec![(k.to_string(), v)],
        None => vec![],
    }
}

/// `Source.mathKv`: one rebuilt math field.
pub fn math_kv(c: &Comp<MC>, f: &str) -> Option<Kvs> {
    let ms: Vec<&MC> = c.math.iter().filter(|m| m.field() == f).collect();
    let bs = at_(f, &c.math_blocks);
    match (ms.is_empty(), bs.as_slice()) {
        (true, []) => Some(vec![]),
        (true, [(_, v)]) => Some(vec![(f.to_string(), v.clone())]),
        (false, []) => Some(vec![(f.to_string(), field_json(f, &ms))]),
        _ => None,
    }
}

/// `Source.mathKvs`.
pub fn math_kvs(c: &Comp<MC>) -> Option<Kvs> {
    let mut out = Vec::new();
    for f in MATH_FIELDS {
        out.extend(math_kv(c, f)?);
    }
    Some(out)
}

/// `Source.declFieldNames`.
pub fn decl_field_names(k: Kind) -> &'static [&'static str] {
    match k {
        Kind::Model => &["variables", "subsystems"],
        Kind::Rs => &["species", "parameters", "subsystems"],
    }
}

/// `Source.declKv`.
pub fn decl_kv(k: Kind, c: &Comp<MC>, f: &str) -> Option<Kvs> {
    let r = pick_one(f, &c.blocks)?;
    let ds: Vec<&Decl> = c
        .decls
        .iter()
        .filter(|d| decl_field(k, d.kind) == Some(f))
        .collect();
    let v = join_field(|d: &&Decl| back_decl(k, d), &ds, r)?;
    Some(opt_kv(f, v))
}

/// `Source.declKvs`: a declaration of a kind the component does not have is
/// refused.
pub fn decl_kvs(k: Kind, c: &Comp<MC>) -> Option<Kvs> {
    if !c.decls.iter().all(|d| decl_field(k, d.kind).is_some()) {
        return None;
    }
    let mut out = Vec::new();
    for f in decl_field_names(k) {
        out.extend(decl_kv(k, c, f)?);
    }
    Some(out)
}

/// `Source.ofComp`: a component rebuilt from its section.
pub fn of_comp(c: &Comp<MC>) -> Option<Json> {
    let ds = decl_kvs(c.kind, c)?;
    let es = math_kvs(c)?;
    let names = decl_field_names(c.kind);
    let mut kvs = opt_kv("description", c.desc.clone().map(Json::Str));
    kvs.extend(ds);
    kvs.extend(es);
    kvs.extend(
        c.blocks
            .iter()
            .filter(|kv| !names.contains(&kv.0.as_str()))
            .cloned(),
    );
    Some(Json::Obj(sort_keys(kvs)))
}

/// `Source.backComp`.
pub fn back_comp(c: &Comp<MC>) -> Option<(String, Json)> {
    of_comp(c).map(|v| (c.name.clone(), v))
}

/// `Source.ofDoc`: a document rebuilt from its skeleton, checked to be
/// canonical.
pub fn of_doc(d: &Doc<MC>) -> Option<Json> {
    let esm_kv = at_("esm", &d.front);
    let mut meta_es: Kvs = d.front.iter().filter(|kv| kv.0 != "esm").cloned().collect();
    meta_es.extend(opt_kv("description", d.desc.clone().map(Json::Str)));
    let meta_kv = if meta_es.is_empty() {
        vec![]
    } else {
        vec![("metadata".to_string(), Json::Obj(sort_keys(meta_es)))]
    };
    let mr = pick_one("models", &d.blocks)?;
    let ms: Vec<&Comp<MC>> = d.comps.iter().filter(|c| c.kind == Kind::Model).collect();
    let models = join_field(|c: &&Comp<MC>| back_comp(c), &ms, mr)?;
    let rr = pick_one("reaction_systems", &d.blocks)?;
    let rs: Vec<&Comp<MC>> = d.comps.iter().filter(|c| c.kind == Kind::Rs).collect();
    let rss = join_field(|c: &&Comp<MC>| back_comp(c), &rs, rr)?;
    let tkv = if d.math.is_empty() {
        vec![]
    } else {
        let refs: Vec<&MC> = d.math.iter().collect();
        vec![("operators".to_string(), field_json("operators", &refs))]
    };
    let mut kvs = esm_kv;
    kvs.extend(meta_kv);
    kvs.extend(opt_kv("models", models));
    kvs.extend(opt_kv("reaction_systems", rss));
    kvs.extend(tkv);
    kvs.extend(
        d.blocks
            .iter()
            .filter(|kv| kv.0 != "models" && kv.0 != "reaction_systems")
            .cloned(),
    );
    let doc = Json::Obj(sort_keys(kvs));
    canon_doc(&doc).then_some(doc)
}
