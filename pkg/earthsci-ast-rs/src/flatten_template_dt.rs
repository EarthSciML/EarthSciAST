//! Flatten step 3a: right-hand-side structural time derivatives, resolved by
//! esm-spec §4.2's table, including those inside the bodies of the operator
//! definitions references name, without expanding anything (esm-spec §9.6.4
//! rule 3, "Time derivatives"; esm-libraries-spec §4.7.5 step 3a).
//!
//! At a call site, `D(x, t)` over a state is `x`'s tendency, over an observed
//! the total derivative of its definition (the chain rule, one level down),
//! over a time-invariant name or a literal `0`; `+`, `-`, `neg`, `*` and `/`
//! distribute by the sum, product and quotient rules. Anything else stays
//! standing, for the `unlowered_operator` gate.
//!
//! A definition's body may hold such a `D` too. A reference denotes its
//! expansion, so the resolution must equal the expansion's; it is computed in
//! the body, once per definition (and per `wrt` literal where `wrt` is a
//! parameter), never by substituting a body into a call site:
//!
//! * a PARAMETER `p` under a structural `D` resolves to a fresh parameter
//!   `p_dt`, which each reference binds to the resolution of `D(b)` for the
//!   `b` it binds to `p`, computed at the reference;
//! * a REFERENCE to `S` under a structural `D` resolves to a reference to
//!   `S`'s derivative entry `<S>.ddt` (the resolution of `D` of `S`'s whole
//!   body by this same rule), bound to the reference's bindings plus the
//!   `q_dt` the entry reads;
//! * every other name and literal resolves as at a call site.
//!
//! The resolved body replaces the definition's body in the flattened
//! registry, its `p_dt` parameters appended, and every reference to it gains
//! the `p_dt` bindings. Where the table answers nothing the `D` stays standing,
//! and a reference whose `p_dt` cannot be resolved keeps pointing at the
//! unresolved body (`<name>.unresolved` when other references resolve).
//!
//! While the walk runs a rewritten reference names a MARK instead of a
//! registry entry: which entry a resolved body lands in (in place, a variant,
//! `.unresolved`) depends on every reference the step reaches, so the names
//! are settled at the end ([`DtState::place`]) and the marks renamed.
//!
//! Mirrors the Julia reference `flatten_template_dt.jl` and flatten.jl's
//! `_resolve_rhs_time_derivatives!`.

use std::cell::RefCell;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::rc::Rc;

use indexmap::IndexMap;
use serde_json::Value;

use crate::flatten::{difference, is_zero, negate, product, quotient, sum, zero};
use crate::operator_refs::APPLY_OP;
use crate::types::{Expr, ExpressionNode};

const DT_MARK: &str = "\0dt\0";

/// What a mark stands for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Kind {
    /// The resolved body of one instance.
    Res,
    /// The unresolved body.
    Unres,
    /// The derivative entry.
    Ddt,
}

impl Kind {
    fn tag(self) -> &'static str {
        match self {
            Kind::Res => "res",
            Kind::Unres => "unres",
            Kind::Ddt => "ddt",
        }
    }
}

/// One registry entry as step 3a reads it.
#[derive(Debug)]
struct DtTemplate {
    name: String,
    decl: Value,
    params: Vec<String>,
    body: Expr,
    /// Parameters that sit in the `wrt` of a body `D` (directly, or forwarded
    /// to a nested reference's such parameter): the instance carries whether
    /// each is bound to `t`, which makes that `D` structural.
    wrt_params: Vec<String>,
    /// Whether the body holds a `D` that may be structural, or reaches a
    /// definition whose body does.
    dbearing: bool,
    /// Every name the body reads, and its parameters: a `p_dt` avoids them.
    reads: HashSet<String>,
    /// p -> p_dt, filled on first use.
    dtnames: RefCell<IndexMap<String, String>>,
}

impl DtTemplate {
    /// The derivative parameter of `p`: `_dt` appended, then `_` until it
    /// names no parameter, no name the body reads, and no derivative
    /// parameter already given to another parameter.
    fn dt_param_name(&self, p: &str) -> String {
        if let Some(n) = self.dtnames.borrow().get(p) {
            return n.clone();
        }
        let mut n = format!("{p}_dt");
        {
            let names = self.dtnames.borrow();
            while self.reads.contains(&n) || names.values().any(|v| *v == n) {
                n.push('_');
            }
        }
        self.dtnames.borrow_mut().insert(p.to_string(), n.clone());
        n
    }

    fn keystr(&self, key: &BTreeMap<String, bool>) -> String {
        self.wrt_params
            .iter()
            .map(|w| if key.get(w) == Some(&true) { 't' } else { 's' })
            .collect()
    }
}

/// The resolution of one body.
#[derive(Debug)]
struct DtResult {
    body: Expr,
    /// Parameters whose `p_dt` the body reads, in `params` order.
    needs: Vec<String>,
    /// Parameters read as `index(p, …)` under a `D`.
    indexed: HashSet<String>,
    changed: bool,
}

/// What a walk inside a body reads of its parameters' derivatives.
#[derive(Debug, Default)]
struct DtAcc {
    needs: HashSet<String>,
    indexed: HashSet<String>,
}

impl DtAcc {
    fn merge(&mut self, from: DtAcc) {
        self.needs.extend(from.needs);
        self.indexed.extend(from.indexed);
    }
}

/// The body a walk is in: its definition and its instance's `wrt` literals.
struct DtBody {
    tpl: Rc<DtTemplate>,
    key: BTreeMap<String, bool>,
}

type Bindings = HashMap<String, Expr>;

/// Step 3a's state over one flattened system (see the module docs).
pub(crate) struct DtState<'a> {
    tendency: HashMap<String, Expr>,
    definition: HashMap<String, Expr>,
    time_invariant: &'a HashSet<String>,
    reg: &'a IndexMap<String, Value>,
    tpl: HashMap<String, Option<Rc<DtTemplate>>>,
    tpl_busy: HashSet<String>,
    res: HashMap<(String, String), Option<Rc<DtResult>>>,
    ddt: HashMap<String, Option<Rc<DtResult>>>,
    unres: HashMap<String, Expr>,
    marks: HashMap<String, (Kind, String, String)>,
}

/// Whether a tendency is a lifted right-hand side: a `faq` with output
/// indices.
fn is_lifted_tendency(expr: &Expr) -> bool {
    matches!(expr, Expr::Operator(node)
        if node.op == "faq" && node.output_idx.as_ref().is_some_and(|o| !o.is_empty()))
}

/// `e` naming `name`, with bindings `b` when given.
fn with_name_bindings(e: &ExpressionNode, name: &str, b: Option<Bindings>) -> Expr {
    let mut out = e.clone();
    out.name = Some(name.to_string());
    if let Some(b) = b {
        out.bindings = Some(b);
    }
    Expr::operator(out)
}

fn op_node(op: &str, args: Vec<Expr>) -> Expr {
    Expr::operator(ExpressionNode {
        op: op.to_string(),
        args,
        ..Default::default()
    })
}

/// Every node of `e`, outermost first, bindings and every expression field
/// included.
fn all_nodes(e: &Expr, out: &mut Vec<Expr>) {
    out.push(e.clone());
    if let Expr::Operator(n) = e {
        n.for_each_child(&mut |c| all_nodes(c, out));
    }
}

impl<'a> DtState<'a> {
    /// The tables `equations` (left-hand side, right-hand side, the state a
    /// pointwise-lifted equation defines) give, or `None` when they define
    /// nothing to resolve against.
    pub(crate) fn build<'e>(
        equations: impl IntoIterator<Item = (&'e Expr, &'e Expr, Option<&'e str>)>,
        time_invariant: &'a HashSet<String>,
        reg: &'a IndexMap<String, Value>,
    ) -> Option<Self> {
        let mut tendency = HashMap::new();
        let mut definition = HashMap::new();
        for (lhs, rhs, lifted_target) in equations {
            match lhs {
                Expr::Operator(node) if crate::flatten::is_structural_time_derivative(node) => {
                    if let Some(Expr::Variable(name)) = node.args.first() {
                        tendency.insert(name.clone(), rhs.clone());
                    }
                }
                Expr::Variable(name) => {
                    definition.insert(name.clone(), rhs.clone());
                }
                _ => {
                    // A lifted state's tendency is its lifted right-hand
                    // side, the `faq` over its index sets.
                    if let Some(t) = lifted_target {
                        tendency.insert(t.to_string(), rhs.clone());
                    }
                }
            }
        }
        if tendency.is_empty() && definition.is_empty() {
            return None;
        }
        Some(DtState {
            tendency,
            definition,
            time_invariant,
            reg,
            tpl: HashMap::new(),
            tpl_busy: HashSet::new(),
            res: HashMap::new(),
            ddt: HashMap::new(),
            unres: HashMap::new(),
            marks: HashMap::new(),
        })
    }

    fn mark(&mut self, kind: Kind, name: &str, key: &str) -> String {
        let m = format!("{DT_MARK}{}\0{name}\0{key}", kind.tag());
        self.marks
            .entry(m.clone())
            .or_insert_with(|| (kind, name.to_string(), key.to_string()));
        m
    }

    /// The registry entry `name`, read once; `None` for a name the registry
    /// does not hold, a body that is not an Expression, or a reference cycle.
    fn template(&mut self, name: Option<&str>) -> Option<Rc<DtTemplate>> {
        let n = name?;
        if let Some(t) = self.tpl.get(n) {
            return t.clone();
        }
        if !self.reg.contains_key(n) || self.tpl_busy.contains(n) {
            return None;
        }
        self.tpl_busy.insert(n.to_string());
        let decl = self.reg[n].clone();
        let def = crate::operator_refs::Definition::from_json(n, &decl);
        let out = def.body.clone().map(|body| {
            let params = def.params.clone();
            let pset: HashSet<&str> = params.iter().map(String::as_str).collect();
            let mut wrt: Vec<String> = Vec::new();
            let mut dbearing = false;
            let mut reads: HashSet<String> = params.iter().cloned().collect();
            let mut nodes: Vec<Expr> = Vec::new();
            all_nodes(&body, &mut nodes);
            for x in &nodes {
                match x {
                    Expr::Variable(v) => {
                        reads.insert(v.clone());
                    }
                    Expr::Operator(node) if node.op == "D" => {
                        let w = node.wrt.as_deref();
                        if w.is_none() || w == Some("t") || w.is_some_and(|w| pset.contains(w)) {
                            dbearing = true;
                            if let Some(w) = w.filter(|w| pset.contains(w))
                                && !wrt.iter().any(|x| x == w)
                            {
                                wrt.push(w.to_string());
                            }
                        }
                    }
                    Expr::Operator(node) if node.op == APPLY_OP => {
                        let Some(inner) = self.template(node.name.as_deref()) else {
                            continue;
                        };
                        dbearing |= inner.dbearing;
                        let Some(b) = &node.bindings else { continue };
                        for w in &inner.wrt_params {
                            if let Some(Expr::Variable(v)) = b.get(w)
                                && pset.contains(v.as_str())
                                && !wrt.contains(v)
                            {
                                wrt.push(v.clone());
                            }
                        }
                    }
                    _ => {}
                }
            }
            wrt.sort();
            Rc::new(DtTemplate {
                name: n.to_string(),
                decl,
                params,
                body,
                wrt_params: wrt,
                dbearing,
                reads,
                dtnames: RefCell::default(),
            })
        });
        self.tpl_busy.remove(n);
        self.tpl.insert(n.to_string(), out.clone());
        out
    }

    /// The instance key of a reference to `tpl` with bindings `b`, read in
    /// `ctx`: for each `wrt` parameter, whether it is bound to `t` (directly,
    /// or through a parameter of the enclosing body bound to `t`).
    fn key(tpl: &DtTemplate, b: Option<&Bindings>, ctx: Option<&DtBody>) -> BTreeMap<String, bool> {
        tpl.wrt_params
            .iter()
            .map(|w| {
                let v = match b.and_then(|b| b.get(w)) {
                    Some(Expr::Variable(v)) => match ctx {
                        Some(c) if c.tpl.params.contains(v) => {
                            c.key.get(v).copied().unwrap_or(false)
                        }
                        _ => v == "t",
                    },
                    _ => false,
                };
                (w.clone(), v)
            })
            .collect()
    }

    /// A structural time derivative in `ctx`: a unary `D` whose `wrt` is
    /// absent or the time variable, or, in a body, a parameter its instance
    /// binds to `t`. A parameter named `t` is a parameter first.
    fn structural(e: &ExpressionNode, ctx: Option<&DtBody>) -> bool {
        if e.op != "D" || e.args.len() != 1 {
            return false;
        }
        if let (Some(c), Some(w)) = (ctx, e.wrt.as_deref())
            && c.tpl.params.iter().any(|p| p == w)
        {
            return c.key.get(w).copied().unwrap_or(false);
        }
        crate::flatten::is_structural_time_derivative(e)
    }

    /// `e` with every structural `D` resolved, read in `ctx` (a call site
    /// when `None`), and every reference re-pointed at the entry its instance
    /// resolves to, with the `p_dt` bindings that entry reads. `acc` collects
    /// the parameters of the body whose derivatives the result reads.
    fn rewrite(&mut self, e: &Expr, ctx: Option<&DtBody>, acc: &mut DtAcc, active: &mut Vec<String>) -> Expr {
        let Expr::Operator(node) = e else {
            return e.clone();
        };
        if Self::structural(node, ctx) {
            let mut sub = DtAcc::default();
            return match self.deriv(&node.args[0], ctx, &mut sub, active) {
                Some(out) => {
                    acc.merge(sub);
                    out
                }
                None => self.unresolve(e),
            };
        }
        if node.op == APPLY_OP {
            return self.reference(node, ctx, acc, active);
        }
        let mut changed = false;
        let out = node.map_children(&mut |c| {
            let r = self.rewrite(c, ctx, acc, active);
            changed |= r != *c;
            r
        });
        if changed { Expr::operator(out) } else { e.clone() }
    }

    /// A reference's bindings, each through `f`; `None` when none changed.
    fn map_bindings(b: Option<&Bindings>, mut f: impl FnMut(&Expr) -> Expr) -> Option<Bindings> {
        let b = b?;
        let mut out: Option<Bindings> = None;
        let mut keys: Vec<&String> = b.keys().collect();
        keys.sort();
        for k in keys {
            let v = &b[k];
            let r = f(v);
            if r != *v {
                out.get_or_insert_with(|| b.clone()).insert(k.clone(), r);
            }
        }
        out
    }

    /// The `p_dt` bindings a reference with bindings `b` gives the entry
    /// `res` reads, each the resolution of `D(b[p])` at the reference;
    /// `None` when one has no resolution.
    fn dt_bindings(
        &mut self,
        tpl: &DtTemplate,
        res: &DtResult,
        b: Option<&Bindings>,
        ctx: Option<&DtBody>,
        acc: &mut DtAcc,
        active: &mut Vec<String>,
    ) -> Option<Bindings> {
        let mut extra = HashMap::new();
        for p in &res.needs {
            let bp = b.and_then(|b| b.get(p))?;
            if res.indexed.contains(p) {
                // `index(p, …)` under a `D` resolves only for one cell of a
                // lifted state, so the binding must name one, or forward a
                // parameter of the enclosing body bound the same way.
                let Expr::Variable(v) = bp else { return None };
                match ctx {
                    Some(c) if c.tpl.params.contains(v) => {
                        acc.indexed.insert(v.clone());
                    }
                    _ => {
                        if !self.tendency.get(v).is_some_and(is_lifted_tendency) {
                            return None;
                        }
                    }
                }
            }
            let d = self.deriv(bp, ctx, acc, active)?;
            extra.insert(tpl.dt_param_name(p), d);
        }
        Some(extra)
    }

    fn merged(nb: Option<Bindings>, orig: Option<&Bindings>, extra: Bindings) -> Bindings {
        let mut out = nb.or_else(|| orig.cloned()).unwrap_or_default();
        out.extend(extra);
        out
    }

    /// A reference outside a structural `D`: its bindings rewritten, and its
    /// name the entry of its instance, with that entry's `p_dt` bindings.
    fn reference(
        &mut self,
        e: &ExpressionNode,
        ctx: Option<&DtBody>,
        acc: &mut DtAcc,
        active: &mut Vec<String>,
    ) -> Expr {
        let nb = Self::map_bindings(e.bindings.as_ref(), |v| self.rewrite(v, ctx, acc, active));
        let name = e.name.clone().unwrap_or_default();
        let keep = |nb: Option<Bindings>, n: &str| match nb {
            None if e.name.as_deref() == Some(n) => Expr::operator(e.clone()),
            nb => with_name_bindings(e, n, nb),
        };
        let Some(tpl) = self.template(e.name.as_deref()).filter(|t| t.dbearing) else {
            return keep(nb, &name);
        };
        let key = Self::key(&tpl, e.bindings.as_ref(), ctx);
        // `None`: the definition is being resolved, and its own resolution
        // reached it again (a cycle through names): it stays unresolved.
        let Some(res) = self.resolve(&tpl, &key) else {
            let m = self.mark(Kind::Unres, &tpl.name, "");
            return keep(nb, &m);
        };
        if !res.changed {
            return keep(nb, &name);
        }
        let mut sub = DtAcc::default();
        let Some(extra) = self.dt_bindings(&tpl, &res, e.bindings.as_ref(), ctx, &mut sub, active)
        else {
            let m = self.mark(Kind::Unres, &tpl.name, "");
            return keep(nb, &m);
        };
        acc.merge(sub);
        let m = self.mark(Kind::Res, &tpl.name, &tpl.keystr(&key));
        with_name_bindings(e, &m, Some(Self::merged(nb, e.bindings.as_ref(), extra)))
    }

    /// The body of `tpl` with its structural `D`s resolved in the instance
    /// `key`, once per definition and `wrt` literal; `None` while it is being
    /// resolved.
    fn resolve(&mut self, tpl: &Rc<DtTemplate>, key: &BTreeMap<String, bool>) -> Option<Rc<DtResult>> {
        let k = (tpl.name.clone(), tpl.keystr(key));
        if let Some(r) = self.res.get(&k) {
            return r.clone();
        }
        self.res.insert(k.clone(), None);
        let mut acc = DtAcc::default();
        let ctx = DtBody {
            tpl: Rc::clone(tpl),
            key: key.clone(),
        };
        let body = self.rewrite(&tpl.body, Some(&ctx), &mut acc, &mut Vec::new());
        let needs: Vec<String> = tpl
            .params
            .iter()
            .filter(|p| acc.needs.contains(*p))
            .cloned()
            .collect();
        let changed = body != tpl.body || !needs.is_empty();
        let r = Rc::new(DtResult {
            body,
            needs,
            indexed: acc.indexed,
            changed,
        });
        self.res.insert(k, Some(Rc::clone(&r)));
        Some(r)
    }

    /// The derivative entry of `tpl` (`<name>.ddt`): the resolution of `D`
    /// of its whole body, each parameter `q` resolving to `q_dt`. `None` when
    /// the table cannot answer (a `D` in the body among them).
    fn ddt(&mut self, tpl: &Rc<DtTemplate>) -> Option<Rc<DtResult>> {
        if let Some(r) = self.ddt.get(&tpl.name) {
            return r.clone();
        }
        self.ddt.insert(tpl.name.clone(), None);
        let mut acc = DtAcc::default();
        let ctx = DtBody {
            tpl: Rc::clone(tpl),
            key: tpl.wrt_params.iter().map(|w| (w.clone(), false)).collect(),
        };
        let d = self.deriv(&tpl.body, Some(&ctx), &mut acc, &mut Vec::new())?;
        let needs = tpl
            .params
            .iter()
            .filter(|p| acc.needs.contains(*p))
            .cloned()
            .collect();
        let r = Rc::new(DtResult {
            body: d,
            needs,
            indexed: acc.indexed,
            changed: true,
        });
        self.ddt.insert(tpl.name.clone(), Some(Rc::clone(&r)));
        Some(r)
    }

    /// d/dt of `e` read in `ctx`, or `None` when §4.2's table does not
    /// define it: a parameter of the body is its `p_dt`, a reference is a
    /// reference to its definition's derivative entry, and every other name
    /// or literal resolves as at a call site.
    fn deriv(&mut self, e: &Expr, ctx: Option<&DtBody>, acc: &mut DtAcc, active: &mut Vec<String>) -> Option<Expr> {
        let node = match e {
            Expr::Integer(_) | Expr::Number(_) => return Some(zero()),
            Expr::Variable(name) => {
                if let Some(c) = ctx
                    && c.tpl.params.contains(name)
                {
                    acc.needs.insert(name.clone());
                    return Some(Expr::Variable(c.tpl.dt_param_name(name)));
                }
                if active.iter().any(|n| n == name) {
                    // A cycle. Stop, and let the gate name it.
                    return None;
                }
                if let Some(f) = self.tendency.get(name).cloned() {
                    active.push(name.clone());
                    let out = self.rewrite(&f, None, &mut DtAcc::default(), active);
                    active.pop();
                    return Some(out);
                }
                if let Some(g) = self.definition.get(name).cloned() {
                    active.push(name.clone());
                    let out = self.deriv(&g, None, acc, active);
                    active.pop();
                    return out;
                }
                if self.time_invariant.contains(name) {
                    return Some(zero());
                }
                return None;
            }
            Expr::Operator(node) => node,
        };
        if node.op == APPLY_OP {
            return self.ddt_reference(node, ctx, acc, active);
        }
        let args = &node.args;
        if node.op == "index"
            && let Some(Expr::Variable(a1)) = args.first()
        {
            if let Some(c) = ctx
                && c.tpl.params.contains(a1)
            {
                // One cell of what the reference binds to `p`: resolvable
                // only for a lifted state, which the reference checks.
                acc.needs.insert(a1.clone());
                acc.indexed.insert(a1.clone());
                let mut a = vec![Expr::Variable(c.tpl.dt_param_name(a1))];
                a.extend(args[1..].iter().cloned());
                return Some(op_node("index", a));
            }
            if self.tendency.get(a1).is_some_and(is_lifted_tendency) {
                // One cell of a lifted state: that cell of its tendency.
                let whole = self.deriv(&args[0], ctx, acc, active)?;
                let mut a = vec![whole];
                a.extend(args[1..].iter().cloned());
                return Some(op_node("index", a));
            }
        }
        match node.op.as_str() {
            "+" => {
                let mut terms = Vec::with_capacity(args.len());
                for a in args {
                    terms.push(self.deriv(a, ctx, acc, active)?);
                }
                Some(sum(terms))
            }
            "-" if args.len() == 1 => Some(negate(self.deriv(&args[0], ctx, acc, active)?)),
            "-" if args.len() == 2 => {
                let a = self.deriv(&args[0], ctx, acc, active)?;
                let b = self.deriv(&args[1], ctx, acc, active)?;
                Some(difference(a, b))
            }
            "neg" if args.len() == 1 => Some(negate(self.deriv(&args[0], ctx, acc, active)?)),
            // Product rule over an n-ary `*`: one term per factor, that
            // factor differentiated and the others left alone.
            "*" => {
                let mut terms = Vec::with_capacity(args.len());
                for (i, a) in args.iter().enumerate() {
                    let da = self.deriv(a, ctx, acc, active)?;
                    if is_zero(&da) {
                        continue;
                    }
                    let mut factors = vec![da];
                    for (j, b) in args.iter().enumerate() {
                        if i != j {
                            factors.push(b.clone());
                        }
                    }
                    terms.push(product(factors));
                }
                Some(sum(terms))
            }
            "/" if args.len() == 2 => {
                let (u, v) = (&args[0], &args[1]);
                let du = self.deriv(u, ctx, acc, active)?;
                let dv = self.deriv(v, ctx, acc, active)?;
                if is_zero(&dv) {
                    return Some(quotient(du, v.clone()));
                }
                let num = difference(product(vec![du, v.clone()]), product(vec![u.clone(), dv]));
                Some(quotient(num, product(vec![v.clone(), v.clone()])))
            }
            _ => None,
        }
    }

    /// d/dt of a reference to `S`: a reference to `<S>.ddt` with the
    /// reference's bindings plus each `q_dt` the entry reads.
    fn ddt_reference(
        &mut self,
        e: &ExpressionNode,
        ctx: Option<&DtBody>,
        acc: &mut DtAcc,
        active: &mut Vec<String>,
    ) -> Option<Expr> {
        let tpl = self.template(e.name.as_deref())?;
        let r = self.ddt(&tpl)?;
        let nb = Self::map_bindings(e.bindings.as_ref(), |v| self.rewrite(v, ctx, acc, active));
        let extra = self.dt_bindings(&tpl, &r, e.bindings.as_ref(), ctx, acc, active)?;
        let m = self.mark(Kind::Ddt, &tpl.name, "");
        Some(with_name_bindings(
            e,
            &m,
            Some(Self::merged(nb, e.bindings.as_ref(), extra)),
        ))
    }

    /// `e` left as authored, every reference in it to a definition whose body
    /// holds a structural `D` (or reaches one) re-pointed at that
    /// definition's unresolved body.
    pub(crate) fn unresolve(&mut self, e: &Expr) -> Expr {
        let Expr::Operator(node) = e else {
            return e.clone();
        };
        if node.op == APPLY_OP {
            let nb = Self::map_bindings(node.bindings.as_ref(), |v| self.unresolve(v));
            let name = node.name.clone().unwrap_or_default();
            let target = match self.template(node.name.as_deref()) {
                Some(t) if t.dbearing => self.mark(Kind::Unres, &t.name, ""),
                _ => name.clone(),
            };
            if nb.is_none() && target == name {
                return e.clone();
            }
            return with_name_bindings(node, &target, nb);
        }
        let mut changed = false;
        let out = node.map_children(&mut |c| {
            let r = self.unresolve(c);
            changed |= r != *c;
            r
        });
        if changed { Expr::operator(out) } else { e.clone() }
    }

    /// The unresolved body of `tpl`: as registered, its references to
    /// definitions that change re-pointed at their own unresolved bodies.
    fn unres_body(&mut self, tpl: &DtTemplate) -> Expr {
        if let Some(b) = self.unres.get(&tpl.name) {
            return b.clone();
        }
        let b = self.unresolve(&tpl.body);
        self.unres.insert(tpl.name.clone(), b.clone());
        b
    }

    /// Whether step 3a can change `e`: it holds a `D`, or a reference to a
    /// definition whose body holds one.
    pub(crate) fn touches(&mut self, e: &Expr) -> bool {
        let Expr::Operator(node) = e else {
            return false;
        };
        if node.op == "D" {
            return true;
        }
        if node.op == APPLY_OP && self.template(node.name.as_deref()).is_some_and(|t| t.dbearing) {
            return true;
        }
        let mut found = false;
        node.for_each_child(&mut |c| {
            if !found {
                found = self.touches(c);
            }
        });
        found
    }

    /// `e`, a right-hand side (or one of its contributions) of the equation
    /// that defines `active`'s names, with its structural `D`s resolved.
    pub(crate) fn resolve_site(&mut self, e: &Expr, active: &mut Vec<String>) -> Expr {
        self.rewrite(e, None, &mut DtAcc::default(), active)
    }

    /// Every mark `e` names, appended to `out`.
    pub(crate) fn marks_in(e: &Expr, out: &mut Vec<String>) {
        if let Expr::Operator(node) = e {
            if node.op == APPLY_OP
                && let Some(n) = &node.name
                && n.starts_with(DT_MARK)
            {
                out.push(n.clone());
            }
            node.for_each_child(&mut |c| Self::marks_in(c, out));
        }
    }

    fn body_of(&mut self, m: &str) -> Expr {
        let (kind, t, k) = self.marks[m].clone();
        match kind {
            Kind::Res => self.res[&(t, k)].as_ref().expect("resolved").body.clone(),
            Kind::Ddt => self.ddt[&t].as_ref().expect("derived").body.clone(),
            Kind::Unres => {
                let tpl = self.tpl[&t].clone().expect("a definition");
                self.unres_body(&tpl)
            }
        }
    }

    /// A resolved body and its parameters, as canonical bytes (marks
    /// unrenamed: two instances that resolve alike name the same marks).
    fn canonical(&self, m: &str) -> String {
        let (_, t, k) = &self.marks[m];
        let r = self.res[&(t.clone(), k.clone())].as_ref().expect("resolved");
        let tpl = self.tpl[t].as_ref().expect("a definition");
        let names: Vec<Value> = r
            .needs
            .iter()
            .map(|p| Value::String(tpl.dt_param_name(p)))
            .collect();
        let body = serde_json::to_value(&r.body).unwrap_or(Value::Null);
        crate::lower_expression_templates::canonical_compact_value(&Value::Array(vec![
            Value::Array(names),
            body,
        ]))
    }

    /// Settle where each resolved body lives: the mark to entry-name map for
    /// the sites, and the flattened registry (the one this state reads)
    /// rewritten. Only what `roots` reach is registered; `None` when nothing
    /// is. Per definition:
    ///
    /// - one resolved body for every instance reached: it replaces the
    ///   definition's body under the same name, its `p_dt` parameters
    ///   appended to `params`;
    /// - several: each is registered as `<name>.variant<k>`, `k` in the order
    ///   of the bodies' canonical bytes, and the definition keeps its body for
    ///   the references that resolve nothing;
    /// - the unresolved body, when a reference still needs it and a resolved
    ///   one took the definition's name, as `<name>.unresolved`;
    /// - the derivative entry, as `<name>.ddt`.
    ///
    /// New names take `_` until they name no other entry. New entries follow
    /// their definition, in that order.
    pub(crate) fn place(
        &mut self,
        roots: Vec<String>,
    ) -> Option<(HashMap<String, String>, IndexMap<String, Value>)> {
        let mut reached: indexmap::IndexSet<String> = indexmap::IndexSet::new();
        let mut queue = roots;
        while let Some(m) = queue.pop() {
            if !reached.insert(m.clone()) {
                continue;
            }
            let b = self.body_of(&m);
            Self::marks_in(&b, &mut queue);
        }
        if reached.is_empty() {
            return None;
        }
        let mut bytpl: BTreeMap<String, Vec<String>> = BTreeMap::new();
        for m in &reached {
            bytpl.entry(self.marks[m].1.clone()).or_default().push(m.clone());
        }
        let mut taken: HashSet<String> = self.reg.keys().cloned().collect();
        let fresh = |taken: &mut HashSet<String>, mut n: String| {
            while taken.contains(&n) {
                n.push('_');
            }
            taken.insert(n.clone());
            n
        };
        let mut names: HashMap<String, String> = HashMap::new();
        let mut after: HashMap<String, Vec<(String, String)>> = HashMap::new();
        let mut replaced: HashMap<String, String> = HashMap::new();
        for (t, ms) in &bytpl {
            let of = |k: Kind| -> Vec<String> {
                ms.iter().filter(|m| self.marks[*m].0 == k).cloned().collect()
            };
            let mut res = of(Kind::Res);
            res.sort();
            let unres = of(Kind::Unres);
            let ddt = of(Kind::Ddt);
            let mut derived: Vec<(String, String)> = Vec::new();
            if !res.is_empty() {
                let canon: HashMap<String, String> =
                    res.iter().map(|m| (m.clone(), self.canonical(m))).collect();
                let mut distinct: Vec<String> = canon.values().cloned().collect();
                distinct.sort();
                distinct.dedup();
                if distinct.len() == 1 {
                    for m in &res {
                        names.insert(m.clone(), t.clone());
                    }
                    replaced.insert(t.clone(), res[0].clone());
                    for m in &unres {
                        let n = fresh(&mut taken, format!("{t}.unresolved"));
                        names.insert(m.clone(), n.clone());
                        derived.push((n, m.clone()));
                    }
                } else {
                    let mut vn: HashMap<String, String> = HashMap::new();
                    for (i, c) in distinct.iter().enumerate() {
                        vn.insert(c.clone(), fresh(&mut taken, format!("{t}.variant{}", i + 1)));
                    }
                    for c in &distinct {
                        let m = res.iter().find(|x| canon[*x] == *c).expect("a mark");
                        derived.push((vn[c].clone(), m.clone()));
                    }
                    for m in &res {
                        names.insert(m.clone(), vn[&canon[m]].clone());
                    }
                    for m in &unres {
                        names.insert(m.clone(), t.clone());
                    }
                }
            } else {
                for m in &unres {
                    names.insert(m.clone(), t.clone());
                }
            }
            for m in &ddt {
                let n = fresh(&mut taken, format!("{t}.ddt"));
                names.insert(m.clone(), n.clone());
                derived.push((n, m.clone()));
            }
            after.insert(t.clone(), derived);
        }

        let entry = |st: &mut Self, t: &str, m: &str| -> Value {
            let (kind, _, k) = st.marks[m].clone();
            let tpl = st.tpl[t].clone().expect("a definition");
            let r = match kind {
                Kind::Res => st.res[&(t.to_string(), k)].clone(),
                Kind::Ddt => st.ddt[t].clone(),
                Kind::Unres => None,
            };
            let mut params: Vec<Value> = tpl.params.iter().cloned().map(Value::String).collect();
            if let Some(r) = &r {
                params.extend(r.needs.iter().map(|p| Value::String(tpl.dt_param_name(p))));
            }
            let mut nd = tpl.decl.as_object().cloned().unwrap_or_default();
            nd.insert("params".to_string(), Value::Array(params));
            if kind == Kind::Ddt {
                // a derivative entry is reached by its references only
                nd.insert("reference_only".to_string(), Value::Bool(true));
            }
            let body = st.body_of(m);
            let body = crate::flatten_refs::rename_refs(&body, &names).unwrap_or(body);
            nd.insert(
                "body".to_string(),
                serde_json::to_value(&body).unwrap_or(Value::Null),
            );
            Value::Object(nd)
        };
        let mut out: IndexMap<String, Value> = IndexMap::new();
        let old: Vec<(String, Value)> = self.reg.iter().map(|(k, v)| (k.clone(), v.clone())).collect();
        for (n, decl) in old {
            let v = match replaced.get(&n).cloned() {
                Some(m) => entry(self, &n, &m),
                None => decl,
            };
            out.insert(n.clone(), v);
            for (dn, m) in after.get(&n).cloned().unwrap_or_default() {
                let v = entry(self, &n, &m);
                out.insert(dn, v);
            }
        }
        Some((names, out))
    }
}
