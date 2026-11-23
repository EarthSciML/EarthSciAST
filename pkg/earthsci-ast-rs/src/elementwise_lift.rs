//! Elementwise application of an operator definition over array arguments
//! (esm-spec §9.6.11), carried out as a per-cell lift, reading references
//! without expanding them.
//!
//! A definition written for scalar inputs — the `lib/interp.esm` lookups are
//! the motivating case — reads a scalar-role parameter inside a reduction body
//! (`faq` with no output index) or an `index` subscript. Bound to an array, by
//! the author or by a coupling that feeds an array into a parameter the
//! component declared scalar, the expansion would read a whole array where the
//! body needs one value. §9.6.11 gives the application its elementwise
//! meaning: it is evaluated once per element of the array argument.
//!
//! The rule applies to references (`apply_operator`) only: an equation whose
//! right-hand side holds, in elementwise position, a reference whose
//! expansion reads a shaped variable in a value position is rewritten into a
//! `faq` over the result's index sets. Its body is the right-hand side read at
//! the cell: each bare shaped read in elementwise position gathered at the
//! cell, aligned by index-set name (§4.3.4), and each reference kept a
//! reference, its bindings read at the cell by their parameters' ROLES.
//!
//! A parameter's role is decided once per definition, from the body alone
//! ([`EwContext::roles`]): one the body reads only in value positions has its
//! binding read at the cell; one it reads only whole (an `index` base, a
//! reduction's operand, a `D` operand) keeps its binding whole; one it reads
//! both ways (mixed), bound to an array, takes the definition's cellwise
//! variant `<name>.cellwise<k>`, whose fresh parameter `p_cell` stands at
//! `p`'s value positions ([`EwContext::cellwise`]). The variants are named
//! once every lift of a flatten is done ([`name_cellwise_variants`]). Nothing
//! is expanded.
//!
//! An equation with no such reference is left exactly as it was: a shaped
//! read an author wrote by hand in a reduction body or a subscript is never
//! given this meaning.
//!
//! Mirrors the Julia reference `elementwise_lift.jl` and `elementwise_refs.jl`.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::rc::Rc;

use indexmap::IndexMap;
use serde_json::Value;

use crate::binders::Binders;
use crate::operator_refs::APPLY_OP;
use crate::types::{Expr, ExpressionNode, Model, RangeSpec};

/// A parameter's role in its definition's body.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Role {
    /// Read only in value positions.
    Value,
    /// Read only whole.
    Array,
    /// Read both ways.
    Mixed,
    /// Not read.
    None,
}

/// Each parameter's role, and the free names the body reads in a value
/// position (through the references it makes), sorted.
#[derive(Debug)]
struct EwRoles {
    role: HashMap<String, Role>,
    free_value: Vec<String>,
}

impl EwRoles {
    fn of(&self, p: &str) -> Role {
        self.role.get(p).copied().unwrap_or(Role::None)
    }
}

type CellwiseMap = Rc<HashMap<String, String>>;

/// The definitions the lift reads references through, each analysed once,
/// and the registry the cellwise variants it makes are added to.
pub(crate) struct EwContext<'r> {
    registry: &'r mut IndexMap<String, Value>,
    bodies: HashMap<String, Option<Rc<(Vec<String>, Expr)>>>,
    roles: HashMap<String, Rc<EwRoles>>,
    names: HashMap<String, Rc<HashSet<String>>>,
    cellwise: HashMap<(String, Vec<String>), (String, CellwiseMap)>,
}

/// Whether `node` is a `faq` with no output index (a reduction to a scalar).
fn is_reduction(node: &ExpressionNode) -> bool {
    node.op == "faq" && node.output_idx.as_ref().is_none_or(|o| o.is_empty())
}

/// Whether `node` produces an array or reduces one: `faq` or `makearray`.
fn is_array_producer_op(node: &ExpressionNode) -> bool {
    matches!(node.op.as_str(), "faq" | "makearray")
}

/// `bound` plus the loop symbols a reduction `faq` binds.
fn reduction_bound(node: &ExpressionNode, bound: &BTreeSet<String>) -> BTreeSet<String> {
    let mut inner = bound.clone();
    node.for_each_binder(Binders::RANGES, |n| {
        inner.insert(n.to_string());
    });
    inner
}

/// A `const` array literal or a `reshape` result: an array with no index
/// sets.
fn is_anonymous_array(node: &ExpressionNode) -> bool {
    node.op == "reshape"
        || (node.op == "const" && node.value.as_ref().is_some_and(crate::ConstValue::is_array))
}

fn node_key(node: &std::sync::Arc<ExpressionNode>) -> usize {
    std::sync::Arc::as_ptr(node) as usize
}

impl<'r> EwContext<'r> {
    /// A context over `registry` (a flattened registry, or a component's).
    pub(crate) fn new(registry: &'r mut IndexMap<String, Value>) -> Self {
        EwContext {
            registry,
            bodies: HashMap::new(),
            roles: HashMap::new(),
            names: HashMap::new(),
            cellwise: HashMap::new(),
        }
    }

    /// The parameters and typed body of `name`.
    fn template(&mut self, name: &str) -> Option<Rc<(Vec<String>, Expr)>> {
        if let Some(t) = self.bodies.get(name) {
            return t.clone();
        }
        let t = self.registry.get(name).and_then(|decl| {
            let d = crate::operator_refs::Definition::from_json(name, decl);
            d.body.map(|b| Rc::new((d.params, b)))
        });
        self.bodies.insert(name.to_string(), t.clone());
        t
    }

    /// Each parameter's role in `name`'s body, and the free names it reads
    /// in a value position (memoized per definition).
    fn roles(&mut self, name: Option<&str>) -> Option<Rc<EwRoles>> {
        let name = name?;
        if let Some(r) = self.roles.get(name) {
            return Some(Rc::clone(r));
        }
        let t = self.template(name)?;
        let (params, body) = &*t;
        let pset: HashSet<String> = params.iter().cloned().collect();
        let mut acc = ClassifyAcc::default();
        self.classify(body, true, &BTreeSet::new(), &pset, &mut acc);
        let role = params
            .iter()
            .map(|p| {
                let v = acc.vals.contains(p);
                let a = acc.arrs.contains(p);
                let r = match (v, a) {
                    (true, true) => Role::Mixed,
                    (true, false) => Role::Value,
                    (false, true) => Role::Array,
                    (false, false) => Role::None,
                };
                (p.clone(), r)
            })
            .collect();
        let r = Rc::new(EwRoles {
            role,
            free_value: acc.free.into_iter().collect(),
        });
        self.roles.insert(name.to_string(), Rc::clone(&r));
        Some(r)
    }

    fn classify(
        &mut self,
        e: &Expr,
        val: bool,
        bound: &BTreeSet<String>,
        pset: &HashSet<String>,
        acc: &mut ClassifyAcc,
    ) {
        let node = match e {
            Expr::Variable(n) => {
                if bound.contains(n) {
                    return;
                }
                if pset.contains(n) {
                    if val {
                        acc.vals.insert(n.clone());
                    } else {
                        acc.arrs.insert(n.clone());
                    }
                } else if val {
                    acc.free.insert(n.clone());
                }
                return;
            }
            Expr::Operator(node) => node,
            _ => return,
        };
        if node.op == APPLY_OP {
            let r = self.roles(node.name.as_deref());
            let Some(b) = node.bindings.as_ref() else {
                if let Some(r) = r
                    && val
                {
                    for n in &r.free_value {
                        if !bound.contains(n) && !pset.contains(n) {
                            acc.free.insert(n.clone());
                        }
                    }
                }
                return;
            };
            let Some(r) = r else {
                for v in b.values() {
                    self.classify(v, false, bound, pset, acc);
                }
                return;
            };
            for (k, v) in b {
                let rk = r.of(k);
                if matches!(rk, Role::Value | Role::Mixed) {
                    self.classify(v, val, bound, pset, acc);
                }
                if matches!(rk, Role::Array | Role::Mixed) {
                    self.classify(v, false, bound, pset, acc);
                }
            }
            if val {
                for n in &r.free_value {
                    if !bound.contains(n) && !pset.contains(n) {
                        acc.free.insert(n.clone());
                    }
                }
            }
        } else if node.op == "index" {
            if let Some(a) = node.args.first() {
                self.classify(a, false, bound, pset, acc);
            }
            for a in node.args.iter().skip(1) {
                self.classify(a, val, bound, pset, acc);
            }
        } else if node.op == "const" || node.op == "reshape" {
            node.for_each_child(&mut |c| self.classify(c, false, bound, pset, acc));
        } else if is_array_producer_op(node) {
            if is_reduction(node) {
                let inner = reduction_bound(node, bound);
                if let Some(b) = &node.expr {
                    self.classify(b, val, &inner, pset, acc);
                }
                if let Some(f) = &node.filter {
                    self.classify(f, val, &inner, pset, acc);
                }
                for a in &node.args {
                    self.classify(a, false, &inner, pset, acc);
                }
            } else {
                node.for_each_child(&mut |c| self.classify(c, false, bound, pset, acc));
            }
        } else if crate::op_registry::is_elementwise_node(node) {
            for a in &node.args {
                self.classify(a, val, bound, pset, acc);
            }
        } else {
            node.for_each_child(&mut |c| self.classify(c, false, bound, pset, acc));
        }
    }

    /// Every name `name`'s expansion reads or binds that is not one of its
    /// parameters (memoized per definition).
    fn template_names(&mut self, name: &str) -> Rc<HashSet<String>> {
        if let Some(n) = self.names.get(name) {
            return Rc::clone(n);
        }
        let Some(t) = self.template(name) else {
            return Rc::new(HashSet::new());
        };
        let mut out = HashSet::new();
        self.used_names(&t.1, &mut out, &mut HashSet::new());
        for p in &t.0 {
            out.remove(p);
        }
        let out = Rc::new(out);
        self.names.insert(name.to_string(), Rc::clone(&out));
        out
    }

    /// Every name `e` reads or binds: variable references and, on every
    /// node, the symbols it binds, a range's `of` parents, `wrt` and `dim`,
    /// through every expression-bearing field; a reference contributes its
    /// expansion's names ([`Self::template_names`]) and its bindings'.
    fn used_names(&mut self, e: &Expr, out: &mut HashSet<String>, seen: &mut HashSet<usize>) {
        let node = match e {
            Expr::Variable(n) => {
                out.insert(n.clone());
                return;
            }
            Expr::Operator(node) => node,
            _ => return,
        };
        if !seen.insert(node_key(node)) {
            return;
        }
        if node.op == APPLY_OP
            && let Some(name) = node.name.as_deref()
            && self.template(name).is_some()
        {
            out.extend(self.template_names(name).iter().cloned());
            for v in node.bindings.iter().flat_map(|b| b.values()) {
                self.used_names(v, out, seen);
            }
            return;
        }
        node.for_each_binder(Binders::SCOPE, |n| {
            out.insert(n.to_string());
        });
        for spec in node.ranges.iter().flat_map(|r| r.values()) {
            if let RangeSpec::IndexSetRef { of: Some(of), .. } = spec {
                out.extend(of.iter().cloned());
            }
        }
        for name in [&node.wrt, &node.dim].into_iter().flatten() {
            out.insert(name.clone());
        }
        node.for_each_child(&mut |c| self.used_names(c, out, seen));
    }

    /// The cellwise variant of `name` for the names `split` (mixed
    /// parameters bound to arrays, and shaped free names the body reads in a
    /// value position): `name`'s parameters plus a fresh `x_cell` per split
    /// name, which replaces `x` in each of its value positions, through the
    /// references the body makes. Registered once per `(name, split)` under a
    /// placeholder name ([`cw_placeholder`]); [`name_cellwise_variants`] names
    /// it `<name>.cellwise<k>` once every lift is done.
    fn cellwise(&mut self, name: &str, split: &[String]) -> (String, CellwiseMap) {
        let key = (name.to_string(), split.to_vec());
        if let Some(hit) = self.cellwise.get(&key) {
            return hit.clone();
        }
        let t = self
            .template(name)
            .expect("a cellwise variant of a known definition");
        let (params, body) = &*t;
        let mut taken: HashSet<String> = params.iter().cloned().collect();
        taken.extend(self.template_names(name).iter().cloned());
        let mut m: HashMap<String, String> = HashMap::new();
        for x in split {
            let mut c = format!("{x}_cell");
            while taken.contains(&c) {
                c.push('_');
            }
            taken.insert(c.clone());
            m.insert(x.clone(), c);
        }
        let nbody = self.cell_subst(body, true, &BTreeSet::new(), &m);
        let mut decl = self.registry[name].as_object().cloned().unwrap_or_default();
        for f in ["match", "where", "priority"] {
            decl.shift_remove(f);
        }
        // reached by its references only (esm-spec §9.6.1)
        decl.insert("reference_only".to_string(), Value::Bool(true));
        let mut ps: Vec<Value> = params.iter().cloned().map(Value::String).collect();
        ps.extend(split.iter().map(|x| Value::String(m[x].clone())));
        decl.insert("params".to_string(), Value::Array(ps));
        decl.insert(
            "body".to_string(),
            serde_json::to_value(&nbody).unwrap_or(Value::Null),
        );
        let decl = Value::Object(decl);
        let canon = crate::lower_expression_templates::canonical_compact_value(&decl);
        let mut n = 0;
        let mut vn = cw_placeholder(name, split, n);
        while let Some(existing) = self.registry.get(&vn) {
            if crate::lower_expression_templates::canonical_compact_value(existing) == canon {
                break;
            }
            n += 1;
            vn = cw_placeholder(name, split, n);
        }
        if !self.registry.contains_key(&vn) {
            self.registry.insert(vn.clone(), decl);
        }
        let res = (vn, Rc::new(m));
        self.cellwise.insert(key, res.clone());
        res
    }

    /// `e` with each name of `m` replaced by its cellwise parameter in its
    /// value positions (`val`), through nested references by their roles.
    fn cell_subst(
        &mut self,
        e: &Expr,
        val: bool,
        bound: &BTreeSet<String>,
        m: &HashMap<String, String>,
    ) -> Expr {
        let node = match e {
            Expr::Variable(n) => {
                if val
                    && !bound.contains(n)
                    && let Some(c) = m.get(n)
                {
                    return Expr::Variable(c.clone());
                }
                return e.clone();
            }
            Expr::Operator(node) => node,
            _ => return e.clone(),
        };
        if !val {
            return e.clone();
        }
        if node.op == APPLY_OP {
            let Some(r) = self.roles(node.name.as_deref()) else {
                return e.clone();
            };
            let empty = HashMap::new();
            let b = node.bindings.as_ref().unwrap_or(&empty);
            let mut nb: HashMap<String, Expr> = HashMap::new();
            let mut split: Vec<String> = Vec::new();
            let mut cellb: HashMap<String, Expr> = HashMap::new();
            let mut keys: Vec<&String> = b.keys().collect();
            keys.sort();
            for k in keys {
                let v = &b[k];
                match r.of(k) {
                    Role::Value => {
                        nb.insert(k.clone(), self.cell_subst(v, true, bound, m));
                    }
                    Role::Mixed => {
                        nb.insert(k.clone(), v.clone());
                        let c = self.cell_subst(v, true, bound, m);
                        if c != *v {
                            split.push(k.clone());
                            cellb.insert(k.clone(), c);
                        }
                    }
                    _ => {
                        nb.insert(k.clone(), v.clone());
                    }
                }
            }
            for n in &r.free_value {
                if bound.contains(n) {
                    continue;
                }
                let Some(c) = m.get(n) else { continue };
                split.push(n.clone());
                cellb.insert(n.clone(), Expr::Variable(c.clone()));
            }
            if split.is_empty() {
                if nb == *b {
                    return e.clone();
                }
                let mut out = ExpressionNode::clone(node);
                out.bindings = Some(nb);
                return Expr::operator(out);
            }
            split.sort();
            let name = node.name.clone().unwrap_or_default();
            let (vn, im) = self.cellwise(&name, &split);
            for x in &split {
                nb.insert(im[x].clone(), cellb.remove(x).expect("a cell binding"));
            }
            let mut out = ExpressionNode::clone(node);
            out.name = Some(vn);
            out.bindings = Some(nb);
            return Expr::operator(out);
        }
        let mut out = ExpressionNode::clone(node);
        let mut changed = false;
        if node.op == "index" {
            for a in out.args.iter_mut().skip(1) {
                let r = self.cell_subst(a, true, bound, m);
                changed |= r != *a;
                *a = r;
            }
        } else if is_array_producer_op(node) {
            if !is_reduction(node) {
                return e.clone();
            }
            let inner = reduction_bound(node, bound);
            if let Some(b) = &node.expr {
                let r = self.cell_subst(b, true, &inner, m);
                changed |= r != **b;
                out.expr = Some(Box::new(r));
            }
            if let Some(f) = &node.filter {
                let r = self.cell_subst(f, true, &inner, m);
                changed |= r != **f;
                out.filter = Some(Box::new(r));
            }
        } else if crate::op_registry::is_elementwise_node(node) {
            for a in out.args.iter_mut() {
                let r = self.cell_subst(a, true, bound, m);
                changed |= r != *a;
                *a = r;
            }
        }
        if changed { Expr::operator(out) } else { e.clone() }
    }
}

/// What [`EwContext::classify`] collects of a body.
#[derive(Default)]
struct ClassifyAcc {
    /// Parameters read in a value position.
    vals: HashSet<String>,
    /// Parameters read whole.
    arrs: HashSet<String>,
    /// Free names read in a value position.
    free: BTreeSet<String>,
}

/// What [`walk`] reports.
enum Seen<'a> {
    /// A variable read by bare name in a value position; `inside` when the
    /// read is inside a reference (a binding read in a value position of its
    /// definition's body, or a name the body reads free there). Whether it is
    /// an array argument is the caller's to decide.
    Read { name: String, inside: bool },
    /// An anonymous array (a `const` array literal, a `reshape` result) in a
    /// value position inside a reference.
    Anonymous { node: &'a ExpressionNode },
}

type WalkSeen = HashSet<(usize, bool, Vec<String>)>;

/// Visit every value position of `expr` (esm-spec §9.6.11). Outside a
/// reference those are the operands of elementwise operators, the positions
/// the per-cell reading commutes with. Inside one they are also the body and
/// filter of a reduction `faq` and the subscripts of an `index`, where a
/// definition reads its scalar-role parameters: a reference is read through
/// its bindings, each where its parameter's role puts it, never expanded.
/// A name a reduction binds as a loop symbol is not a read. An `index` base
/// and every operand an op consumes whole are array positions, not visited.
/// Each node is visited once per `(bound, inside)`.
fn walk<'a>(
    ctx: &mut EwContext<'_>,
    expr: &'a Expr,
    bound: &BTreeSet<String>,
    inside: bool,
    seen: &mut WalkSeen,
    f: &mut dyn FnMut(Seen<'a>),
) {
    let node = match expr {
        Expr::Variable(n) => {
            if !bound.contains(n) {
                f(Seen::Read {
                    name: n.clone(),
                    inside,
                });
            }
            return;
        }
        Expr::Operator(node) => node,
        _ => return,
    };
    if !seen.insert((node_key(node), inside, bound.iter().cloned().collect())) {
        return;
    }
    if node.op == APPLY_OP {
        let Some(r) = ctx.roles(node.name.as_deref()) else {
            return;
        };
        if let Some(b) = &node.bindings {
            let mut keys: Vec<&String> = b.keys().collect();
            keys.sort();
            for k in keys {
                if matches!(r.of(k), Role::Value | Role::Mixed) {
                    walk(ctx, &b[k], bound, true, seen, f);
                }
            }
        }
        for n in &r.free_value {
            if !bound.contains(n) {
                f(Seen::Read {
                    name: n.clone(),
                    inside: true,
                });
            }
        }
        return;
    }
    match node.op.as_str() {
        "index" => {
            if inside {
                for a in node.args.iter().skip(1) {
                    walk(ctx, a, bound, true, seen, f);
                }
            }
        }
        "const" | "reshape" => {
            if inside && is_anonymous_array(node) {
                f(Seen::Anonymous { node });
            }
        }
        _ if is_array_producer_op(node) => {
            if inside && is_reduction(node) {
                let inner = reduction_bound(node, bound);
                if let Some(b) = &node.expr {
                    walk(ctx, b, &inner, true, seen, f);
                }
                if let Some(b) = &node.filter {
                    walk(ctx, b, &inner, true, seen, f);
                }
            }
        }
        _ if crate::op_registry::is_elementwise_node(node) => {
            for a in &node.args {
                walk(ctx, a, bound, inside, seen, f);
            }
        }
        _ => {}
    }
}

/// Every `(name, inside)` read [`walk`] reports for `expr`.
fn reads_of(ctx: &mut EwContext<'_>, expr: &Expr) -> Vec<(String, bool)> {
    let mut out = Vec::new();
    walk(
        ctx,
        expr,
        &BTreeSet::new(),
        false,
        &mut HashSet::new(),
        &mut |seen| {
            if let Seen::Read { name, inside } = seen {
                out.push((name, inside));
            }
        },
    );
    out
}

/// `array_shape_mismatch` when a reference in `rhs` reads an anonymous array
/// in a value position: it has no index sets, so nothing says which element
/// each cell reads (esm-spec §9.6.11).
fn refuse_anonymous_arrays(
    ctx: &mut EwContext<'_>,
    rhs: &Expr,
    lhs: &Expr,
) -> Result<(), String> {
    let mut found: Option<String> = None;
    walk(
        ctx,
        rhs,
        &BTreeSet::new(),
        false,
        &mut HashSet::new(),
        &mut |seen| {
            if let Seen::Anonymous { node } = seen {
                found.get_or_insert_with(|| node.op.clone());
            }
        },
    );
    let Some(op) = found else {
        return Ok(());
    };
    let lhs = match lhs {
        Expr::Variable(n) => n.clone(),
        other => other.to_string(),
    };
    Err(format!(
        "array_shape_mismatch: '{lhs}': a template application reads an anonymous array \
         (a `{op}` node) where its body reads a scalar; an array argument of an elementwise \
         application must be declared over index sets, so each cell knows which element it \
         reads (esm-spec §9.6.11)"
    ))
}

/// Lift every equation of `model` that applies a definition of `registry`
/// elementwise (see the module docs), and give each lifted variable that was
/// declared without a `shape` the index sets it was lifted over. Returns those
/// shapes, by variable name. A variable declared `shape: []` is a scalar and
/// is never lifted. A field initial condition `ic(x) = rhs` is lifted over
/// `x`'s declared shape. The cellwise variants the lift makes are added to
/// `registry` under placeholder names; [`name_cellwise_variants`] names them.
///
/// The shapes come from [`plan_elementwise_lift`], which decides them all
/// before anything is rewritten, so what a lifted body gathers does not
/// depend on the order of the equations.
///
/// # Errors
///
/// As [`plan_elementwise_lift`], and `array_shape_mismatch` when an array
/// read names an index set the lifted result is not shaped over. On an error
/// no equation is changed (cellwise variants already registered stay).
pub(crate) fn lift_elementwise_applications_with(
    model: &mut Model,
    registry: &mut IndexMap<String, Value>,
) -> Result<HashMap<String, Vec<String>>, String> {
    if !model
        .equations
        .iter()
        .any(|e| crate::operator_refs::has_reference(&e.rhs))
    {
        return Ok(HashMap::new());
    }
    let mut ctx = EwContext::new(registry);
    let LiftPlan {
        shapes,
        lifts,
        lifted,
    } = plan_elementwise_lift(model, &mut ctx)?;
    let mut rewritten: Vec<(usize, Expr)> = Vec::new();
    for (k, lift) in lifts.into_iter().enumerate() {
        let Some((lhs, axes)) = lift else { continue };
        let rhs = &model.equations[k].rhs;
        let loops = fresh_loops(&mut ctx, rhs, axes.len());
        let mut l = Lift::new(&mut ctx, &axes, &loops, &shapes, &lhs);
        let body = intern_tree(&l.at_cell(rhs, &BTreeSet::new(), false)?);
        let ranges: HashMap<String, RangeSpec> = loops
            .iter()
            .zip(&axes)
            .map(|(l, a)| {
                (
                    l.clone(),
                    RangeSpec::IndexSetRef {
                        from: a.clone(),
                        of: None,
                    },
                )
            })
            .collect();
        rewritten.push((
            k,
            Expr::operator(ExpressionNode {
                op: "faq".to_string(),
                args: Vec::new(),
                output_idx: Some(loops),
                ranges: Some(ranges),
                expr: Some(Box::new(body)),
                ..Default::default()
            }),
        ));
    }
    for (k, rhs) in rewritten {
        model.equations[k].rhs = rhs;
    }
    for (name, axes) in &lifted {
        if let Some(var) = model.variables.get_mut(name) {
            var.shape = Some(axes.clone());
        }
    }
    Ok(lifted)
}

/// [`lift_elementwise_applications_with`] against no registry: a reference
/// whose definition the lift cannot read is not lifted.
pub(crate) fn lift_elementwise_applications(
    model: &mut Model,
) -> Result<HashMap<String, Vec<String>>, String> {
    lift_elementwise_applications_with(model, &mut IndexMap::new())
}

/// What [`plan_elementwise_lift`] decides about a model, before anything is
/// rewritten.
#[derive(Debug, Clone, Default, PartialEq)]
pub(crate) struct LiftPlan {
    /// Every array variable, by name, as the lift reads it: the declared
    /// non-empty shapes, and the elementwise shape (§4.3.4) of each variable
    /// declared without a `shape` whose bare `x = …` definition is elementwise
    /// over shaped operands, lifted or not.
    pub(crate) shapes: HashMap<String, Vec<String>>,
    /// Per equation, in `model.equations` order: the name it defines (an
    /// initial condition's state) and the index sets its right-hand side is
    /// lifted over, or `None` when it is not lifted.
    pub(crate) lifts: Vec<Option<(String, Vec<String>)>>,
    /// The variables declared without a `shape` that a lift defines, with the
    /// index sets it defines them over.
    pub(crate) lifted: HashMap<String, Vec<String>>,
}

/// Decide, without rewriting anything, which equations of `model` the
/// elementwise lift rewrites and every shape it reads ([`LiftPlan`]).
///
/// The shape of a variable declared without one follows from the shapes of
/// the names its definition reads, so the definitions are resolved in
/// dependency order ([`crate::structural::dependency_first_order`]): each
/// after every definition it reads, whatever the order of the equations. Each
/// right-hand side is walked once. Errors are reported only against those
/// final shapes. A variable on a cycle of definitions (an algebraic loop,
/// which the build refuses on its own) is resolved with the definition that
/// closes the cycle read as unshaped.
///
/// # Errors
///
/// `array_shape_mismatch` (esm-spec §9.6.11, §4.3.4) when a lifted variable
/// declared without a `shape` has no one shape (its definition reads itself
/// through a cycle of definitions, or another equation also defines it), when
/// the index sets a right-hand side is lifted over name one index set twice,
/// and when a reference of any equation reads an anonymous array (a `const`
/// array literal, a `reshape` result) in a value position, which has no index
/// sets to align by.
fn plan_elementwise_lift(model: &Model, ctx: &mut EwContext<'_>) -> Result<LiftPlan, String> {
    let mut shapes: HashMap<String, Vec<String>> = model
        .variables
        .iter()
        .filter_map(|(n, v)| match &v.shape {
            Some(s) if !s.is_empty() => Some((n.clone(), s.clone())),
            _ => None,
        })
        .collect();
    for eq in &model.equations {
        refuse_anonymous_arrays(ctx, &eq.rhs, &eq.lhs)?;
    }
    let targets: Vec<Option<(String, bool)>> = model
        .equations
        .iter()
        .map(|eq| match &eq.lhs {
            Expr::Variable(n) => Some((n.clone(), false)),
            other => crate::flatten::extract_ic_target(other).map(|t| (t, true)),
        })
        .collect();
    let reads: Vec<Vec<(String, bool)>> = model
        .equations
        .iter()
        .map(|eq| reads_of(ctx, &eq.rhs))
        .collect();
    let mut def_of: HashMap<&str, usize> = HashMap::new();
    let mut defs: Vec<usize> = Vec::new();
    for (k, target) in targets.iter().enumerate() {
        let Some((name, false)) = target else {
            continue;
        };
        let undeclared = model.variables.get(name).is_none_or(|v| v.shape.is_none());
        if undeclared && !def_of.contains_key(name.as_str()) {
            def_of.insert(name.as_str(), defs.len());
            defs.push(k);
        }
    }
    let deps: Vec<Vec<usize>> = defs
        .iter()
        .map(|&k| {
            reads[k]
                .iter()
                .filter_map(|(n, _)| def_of.get(n.as_str()).copied())
                .collect()
        })
        .collect();
    for d in crate::structural::dependency_first_order(&deps) {
        let k = defs[d];
        let names: Vec<&str> = reads[k].iter().map(|(n, _)| n.as_str()).collect();
        if let Some(axes) = union_axes(&names, &shapes) {
            let (name, _) = targets[k].as_ref().expect("a definition has a target");
            shapes.insert(name.clone(), axes);
        }
    }
    let mut lifts: Vec<Option<(String, Vec<String>)>> = vec![None; model.equations.len()];
    let mut lifted: HashMap<String, Vec<String>> = HashMap::new();
    for (k, target) in targets.iter().enumerate() {
        let Some((lhs, is_ic)) = target else { continue };
        if !reads[k]
            .iter()
            .any(|(n, inside)| *inside && shapes.contains_key(n))
        {
            continue;
        }
        let declared = model.variables.get(lhs).and_then(|v| v.shape.as_ref());
        let axes = match declared {
            // `shape: []` declares a scalar (esm-spec §4.3.1): never lifted.
            Some(s) if s.is_empty() => continue,
            Some(s) => s.clone(),
            // An initial condition takes its state's declared shape only.
            None if *is_ic => continue,
            None => {
                let names: Vec<&str> = reads[k].iter().map(|(n, _)| n.as_str()).collect();
                let axes = union_axes(&names, &shapes)
                    .ok_or_else(|| format!("array_shape_mismatch: '{lhs}': no array operand"))?;
                if shapes.get(lhs) != Some(&axes) {
                    return Err(format!(
                        "array_shape_mismatch: '{lhs}': its elementwise application is over \
                         {axes:?}, but its definition reads itself through a cycle of \
                         definitions, or another equation also defines it, so it has no one \
                         shape (esm-spec §9.6.11)"
                    ));
                }
                axes
            }
        };
        if (1..axes.len()).any(|d| axes[..d].contains(&axes[d])) {
            return Err(format!(
                "array_shape_mismatch: '{lhs}': the elementwise application is over \
                 {axes:?}, which names one index set twice, so a read has no single \
                 axis to align to (esm-spec §9.6.11)"
            ));
        }
        if declared.is_none() {
            lifted.insert(lhs.clone(), axes.clone());
        }
        lifts[k] = Some((lhs.clone(), axes));
    }
    Ok(LiftPlan {
        shapes,
        lifts,
        lifted,
    })
}

/// `expr` with every structurally identical subtree one shared node, as load
/// interns a document ([`crate::intern`]): the native tape's value numbering
/// keys a node by its address, so the lifted body shares what it repeats.
fn intern_tree(expr: &Expr) -> Expr {
    fn go(e: &Expr, memo: &mut HashMap<*const ExpressionNode, Expr>) -> Expr {
        let Expr::Operator(node) = e else {
            return e.clone();
        };
        let key = std::sync::Arc::as_ptr(node);
        if let Some(hit) = memo.get(&key) {
            return hit.clone();
        }
        let out = Expr::operator(node.map_children(&mut |c| go(c, memo)));
        memo.insert(key, out.clone());
        out
    }
    let _intern = crate::intern::InternScope::new();
    go(expr, &mut HashMap::new())
}

/// The index sets an elementwise application over the shaped `reads` runs
/// over: the union of the reads' index sets, in order of first appearance
/// (§4.3.4). `None` when no read is shaped.
fn union_axes(reads: &[&str], shapes: &HashMap<String, Vec<String>>) -> Option<Vec<String>> {
    let mut out: Option<Vec<String>> = None;
    for s in reads.iter().filter_map(|n| shapes.get(*n)) {
        let acc = out.get_or_insert_with(Vec::new);
        for axis in s {
            if !acc.contains(axis) {
                acc.push(axis.clone());
            }
        }
    }
    out
}

/// `n` loop names that no name `expr` reads or binds uses (a reference's
/// expansion's names included, [`EwContext::used_names`]).
pub(crate) fn fresh_loops(ctx: &mut EwContext<'_>, expr: &Expr, n: usize) -> Vec<String> {
    let mut used: HashSet<String> = HashSet::new();
    ctx.used_names(expr, &mut used, &mut HashSet::new());
    let mut prefix = "_p".to_string();
    loop {
        let loops: Vec<String> = (0..n).map(|d| format!("{prefix}{d}")).collect();
        if loops.iter().all(|l| !used.contains(l)) {
            return loops;
        }
        prefix.insert(0, '_');
    }
}

/// One lift: the result's index sets and the loop symbol over each.
pub(crate) struct Lift<'c, 'r, 'a> {
    ctx: &'c mut EwContext<'r>,
    axes: &'a [String],
    loops: &'a [String],
    shapes: &'a HashMap<String, Vec<String>>,
    lhs: &'a str,
    memo: HashMap<(usize, bool, Vec<String>), Expr>,
}

impl<'c, 'r, 'a> Lift<'c, 'r, 'a> {
    /// A lift over `axes`, its loop symbols `loops`.
    pub(crate) fn new(
        ctx: &'c mut EwContext<'r>,
        axes: &'a [String],
        loops: &'a [String],
        shapes: &'a HashMap<String, Vec<String>>,
        lhs: &'a str,
    ) -> Self {
        Lift {
            ctx,
            axes,
            loops,
            shapes,
            lhs,
            memo: HashMap::new(),
        }
    }

    /// `expr` read at the current cell: every shaped read [`walk`] visits
    /// gathered at the loops its index sets name; a reference stays a
    /// reference, its bindings read at the cell by role. `inside` as for
    /// [`walk`].
    pub(crate) fn at_cell(
        &mut self,
        expr: &Expr,
        bound: &BTreeSet<String>,
        inside: bool,
    ) -> Result<Expr, String> {
        let node = match expr {
            Expr::Variable(n) if !bound.contains(n) => {
                return match self.shapes.get(n) {
                    Some(shape) if !shape.is_empty() => self.gather(n, shape),
                    _ => Ok(expr.clone()),
                };
            }
            Expr::Operator(node) => node,
            _ => return Ok(expr.clone()),
        };
        let key = (
            node_key(node),
            inside,
            bound.iter().cloned().collect::<Vec<_>>(),
        );
        if let Some(hit) = self.memo.get(&key) {
            return Ok(hit.clone());
        }
        let out = self.at_cell_op(expr, node, bound, inside)?;
        self.memo.insert(key, out.clone());
        Ok(out)
    }

    fn at_cell_op(
        &mut self,
        expr: &Expr,
        node: &ExpressionNode,
        bound: &BTreeSet<String>,
        inside: bool,
    ) -> Result<Expr, String> {
        if node.op == APPLY_OP {
            return self.reference(expr, node, bound);
        }
        let mut out = ExpressionNode::clone(node);
        match node.op.as_str() {
            "index" => {
                if !inside {
                    return Ok(expr.clone());
                }
                for a in out.args.iter_mut().skip(1) {
                    *a = self.at_cell(a, bound, true)?;
                }
            }
            _ if is_array_producer_op(node) => {
                if !(inside && is_reduction(node)) {
                    return Ok(expr.clone());
                }
                let inner = reduction_bound(node, bound);
                if let Some(b) = &node.expr {
                    out.expr = Some(Box::new(self.at_cell(b, &inner, true)?));
                }
                if let Some(b) = &node.filter {
                    out.filter = Some(Box::new(self.at_cell(b, &inner, true)?));
                }
            }
            _ if crate::op_registry::is_elementwise_node(node) => {
                for a in out.args.iter_mut() {
                    *a = self.at_cell(a, bound, inside)?;
                }
            }
            _ => return Ok(expr.clone()),
        }
        Ok(Expr::operator(out))
    }

    /// Whether `v`, read at a call site in a value position, reads a shaped
    /// name in a value position.
    fn reads_shaped(&mut self, v: &Expr, bound: &BTreeSet<String>) -> bool {
        let mut found = false;
        let shapes = self.shapes;
        walk(
            self.ctx,
            v,
            bound,
            true,
            &mut HashSet::new(),
            &mut |seen| {
                if let Seen::Read { name, .. } = seen
                    && shapes.get(&name).is_some_and(|s| !s.is_empty())
                {
                    found = true;
                }
            },
        );
        found
    }

    /// The reference `expr` read at the cell: each binding by its
    /// parameter's role, a mixed parameter bound to an array and a shaped
    /// free name through the cellwise variant.
    fn reference(
        &mut self,
        expr: &Expr,
        node: &ExpressionNode,
        bound: &BTreeSet<String>,
    ) -> Result<Expr, String> {
        let Some(r) = self.ctx.roles(node.name.as_deref()) else {
            return Ok(expr.clone());
        };
        let empty = HashMap::new();
        let b = node.bindings.as_ref().unwrap_or(&empty);
        let mut nb: HashMap<String, Expr> = HashMap::new();
        let mut split: Vec<String> = Vec::new();
        let mut cellb: HashMap<String, Expr> = HashMap::new();
        let mut keys: Vec<&String> = b.keys().collect();
        keys.sort();
        for k in keys {
            let v = &b[k];
            match r.of(k) {
                Role::Value => {
                    let c = self.at_cell(v, bound, true)?;
                    nb.insert(k.clone(), c);
                }
                Role::Mixed if self.reads_shaped(v, bound) => {
                    nb.insert(k.clone(), v.clone());
                    split.push(k.clone());
                    let c = self.at_cell(v, bound, true)?;
                    cellb.insert(k.clone(), c);
                }
                _ => {
                    nb.insert(k.clone(), v.clone());
                }
            }
        }
        for n in &r.free_value {
            if bound.contains(n) || self.shapes.get(n).is_none_or(|s| s.is_empty()) {
                continue;
            }
            split.push(n.clone());
            let c = self.at_cell(&Expr::Variable(n.clone()), bound, true)?;
            cellb.insert(n.clone(), c);
        }
        let mut out = ExpressionNode::clone(node);
        if !split.is_empty() {
            split.sort();
            let name = node.name.clone().unwrap_or_default();
            let (vn, m) = self.ctx.cellwise(&name, &split);
            for x in &split {
                nb.insert(m[x].clone(), cellb.remove(x).expect("a cell binding"));
            }
            out.name = Some(vn);
        }
        out.bindings = Some(nb);
        Ok(Expr::operator(out))
    }

    /// `index(name, …)` with each of `name`'s index sets read at the loop over
    /// the same index set of the result, so a read over a subset of the
    /// result's index sets replicates along the rest (§4.3.4). A shape that
    /// repeats an index set, or the result's own shape, is read positionally.
    fn gather(&self, name: &str, shape: &[String]) -> Result<Expr, String> {
        let mut args = Vec::with_capacity(shape.len() + 1);
        args.push(Expr::Variable(name.to_string()));
        let repeats = (1..shape.len()).any(|d| shape[..d].contains(&shape[d]));
        if repeats || shape == self.axes {
            args.extend(self.loops.iter().map(|l| Expr::Variable(l.clone())));
        } else {
            for axis in shape {
                let p = self.axes.iter().position(|a| a == axis);
                let unique = self.axes.iter().filter(|a| *a == axis).count() == 1;
                match p {
                    Some(p) if unique => args.push(Expr::Variable(self.loops[p].clone())),
                    _ => {
                        return Err(format!(
                            "array_shape_mismatch: '{}': '{name}' (shape {shape:?}) is an array \
                             argument of an elementwise application over {:?}, which is not \
                             shaped over its index set '{axis}' exactly once (esm-spec §9.6.11, \
                             §4.3.4)",
                            self.lhs, self.axes
                        ));
                    }
                }
            }
        }
        Ok(Expr::operator(ExpressionNode {
            op: "index".to_string(),
            args,
            ..Default::default()
        }))
    }
}

// ============================================================================
// Naming the cellwise variants (esm-spec §9.6.11; §9.6.4 rule 3, "Where the
// result lives")
// ============================================================================
//
// The lifts discover cellwise variants one equation at a time, so a variant's
// final name `<name>.cellwise<k>`, with `k` in the order of the canonical
// bytes of the bodies of all of `<name>`'s cellwise variants, is known only
// once every lift of a flatten is done. Until then a variant is registered
// under a placeholder that depends only on the variant (its definition, its
// split names, and a counter that separates distinct declarations for one
// split), so the placeholder, and hence the result, does not depend on
// discovery order. The placeholder's separators are control characters no
// document name contains.

const CW_OPEN: &str = "\x1fcellwise\x1f";
const CW_SEP: &str = "\x1f";
const CW_CLOSE: &str = "\x1e";

/// The placeholder name of `name`'s cellwise variant for `split`.
fn cw_placeholder(name: &str, split: &[String], n: usize) -> String {
    format!("{name}{CW_OPEN}{}{CW_SEP}{n}{CW_CLOSE}", split.join(CW_SEP))
}

/// `k`'s base when it is a final cellwise name `<base>.cellwise<digits>_*`.
fn final_cellwise_base(k: &str) -> Option<&str> {
    let t = k.trim_end_matches('_');
    let digits = t.len() - t.trim_end_matches(|c: char| c.is_ascii_digit()).len();
    if digits == 0 {
        return None;
    }
    let base = t[..t.len() - digits].strip_suffix(".cellwise")?;
    (!base.is_empty()).then_some(base)
}

/// Every reference name a raw JSON value holds.
fn raw_refs(x: &Value, acc: &mut BTreeSet<String>) {
    match x {
        Value::Object(o) => {
            if o.get("op").and_then(Value::as_str) == Some(APPLY_OP)
                && let Some(Value::String(n)) = o.get("name")
            {
                acc.insert(n.clone());
            }
            o.values().for_each(|v| raw_refs(v, acc));
        }
        Value::Array(a) => a.iter().for_each(|v| raw_refs(v, acc)),
        _ => {}
    }
}

/// A raw JSON value with each reference renamed through `ren`.
fn raw_rename(x: &Value, ren: &HashMap<String, String>) -> Value {
    let mut out = x.clone();
    if !ren.is_empty() {
        crate::lower_expression_templates::rename_apply_refs(&mut out, ren);
    }
    out
}

/// The final name of entry `n` while variants are being named (`None`: not
/// assigned yet).
fn final_of(
    n: &str,
    member_base: &HashMap<String, String>,
    derived: &HashMap<String, (String, String)>,
    assigned: &HashMap<String, String>,
) -> Option<String> {
    if member_base.contains_key(n) {
        assigned.get(n).cloned()
    } else if let Some((pre, rest)) = derived.get(n) {
        final_of(pre, member_base, derived, assigned).map(|f| f + rest)
    } else {
        Some(n.to_string())
    }
}

/// Give every cellwise variant in the flattened registry `reg` its final name
/// and return the renames (old to new) the expression sites still need. The
/// variants of definition `T` (placeholders, and entries an earlier pass
/// already named `T.cellwise<k>`) are named `<T'>.cellwise<k>`, `T'` being
/// `T`'s own final name, with `k = 1, 2, …` in the order of the variants'
/// bodies' canonical bytes (each body with its references already renamed;
/// ties by the whole declaration's bytes) and `_` appended until the name
/// names no other entry (esm-spec §9.6.11, §9.6.4 rule 3). Two variants with
/// the same declaration are one entry. The variants of a definition are named
/// after every variant their bodies reference, so the bytes compared hold
/// final names. An entry derived from a variant (`<variant>.ddt`,
/// `<variant>.variant<j>`) follows its variant's name. Renamed entries move to
/// the end of `reg`, in name order, each followed by the entries derived from
/// it; every body in `reg` is renamed. Mirrors the Julia reference
/// `_name_cellwise_variants!`.
pub(crate) fn name_cellwise_variants(
    reg: &mut IndexMap<String, Value>,
) -> HashMap<String, String> {
    let names: Vec<String> = reg.keys().cloned().collect();
    let mut member_base: HashMap<String, String> = HashMap::new();
    for k in &names {
        if k.ends_with(CW_CLOSE)
            && let Some(i) = k.rfind(CW_OPEN)
        {
            member_base.insert(k.clone(), k[..i].to_string());
        }
    }
    if member_base.is_empty() {
        return HashMap::new();
    }
    for k in &names {
        if member_base.contains_key(k) {
            continue;
        }
        if let Some(b) = final_cellwise_base(k)
            && reg.contains_key(b)
        {
            member_base.insert(k.clone(), b.to_string());
        }
    }
    // An entry derived from a variant: `<variant>.<rest>`, the longest variant.
    let mut derived: HashMap<String, (String, String)> = HashMap::new();
    for k in &names {
        if member_base.contains_key(k) {
            continue;
        }
        for (i, _) in k.rmatch_indices('.') {
            let pre = &k[..i];
            if member_base.contains_key(pre) {
                derived.insert(k.clone(), (pre.to_string(), k[i..].to_string()));
                break;
            }
        }
    }
    let mut assigned: HashMap<String, String> = HashMap::new();
    let mut groups: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for k in &names {
        if let Some(b) = member_base.get(k) {
            groups.entry(b.clone()).or_default().push(k.clone());
        }
    }
    let mut taken: HashSet<String> = names
        .iter()
        .filter(|k| !member_base.contains_key(*k) && !derived.contains_key(*k))
        .cloned()
        .collect();
    let refs: HashMap<String, BTreeSet<String>> = member_base
        .keys()
        .map(|k| {
            let mut acc = BTreeSet::new();
            if let Some(b) = reg[k].get("body") {
                raw_refs(b, &mut acc);
            }
            (k.clone(), acc)
        })
        .collect();
    let mut pending: Vec<String> = groups.keys().cloned().collect();
    while !pending.is_empty() {
        let mut progressed = false;
        for b in pending.clone() {
            let Some(nb) = final_of(&b, &member_base, &derived, &assigned) else {
                continue;
            };
            let ms = &groups[&b];
            if !ms.iter().all(|m| {
                refs[m]
                    .iter()
                    .all(|r| final_of(r, &member_base, &derived, &assigned).is_some())
            }) {
                continue;
            }
            let mut ren: HashMap<String, String> = HashMap::new();
            for m in ms {
                for r in &refs[m] {
                    let f = final_of(r, &member_base, &derived, &assigned).expect("final");
                    if f != *r {
                        ren.insert(r.clone(), f);
                    }
                }
            }
            let mut keyed: HashMap<String, (String, String)> = HashMap::new();
            for m in ms {
                let d = &reg[m];
                let body = raw_rename(d.get("body").unwrap_or(&Value::Null), &ren);
                let mut nd = d.as_object().cloned().unwrap_or_default();
                nd.insert("body".to_string(), body.clone());
                keyed.insert(
                    m.clone(),
                    (
                        crate::lower_expression_templates::canonical_compact_value(&body),
                        crate::lower_expression_templates::canonical_compact_value(
                            &Value::Object(nd),
                        ),
                    ),
                );
            }
            let mut distinct: Vec<(String, String)> = keyed.values().cloned().collect();
            distinct.sort();
            distinct.dedup();
            let mut fin: HashMap<(String, String), String> = HashMap::new();
            for (k, c) in distinct.into_iter().enumerate() {
                let mut vn = format!("{nb}.cellwise{}", k + 1);
                while taken.contains(&vn) {
                    vn.push('_');
                }
                taken.insert(vn.clone());
                fin.insert(c, vn);
            }
            for m in ms {
                assigned.insert(m.clone(), fin[&keyed[m]].clone());
            }
            pending.retain(|x| *x != b);
            progressed = true;
        }
        assert!(
            progressed,
            "cellwise variants reference each other in a cycle: {pending:?}"
        );
    }
    let mut renames: HashMap<String, String> = HashMap::new();
    for k in &names {
        if !(member_base.contains_key(k) || derived.contains_key(k)) {
            continue;
        }
        let f = final_of(k, &member_base, &derived, &assigned).expect("final");
        if f != *k {
            renames.insert(k.clone(), f);
        }
    }
    let old: IndexMap<String, Value> = std::mem::take(reg);
    let ren_decl = |d: &Value| -> Value {
        match d.get("body") {
            Some(b) => {
                let nb = raw_rename(b, &renames);
                if nb == *b {
                    return d.clone();
                }
                let mut nd = d.clone();
                nd["body"] = nb;
                nd
            }
            None => d.clone(),
        }
    };
    for (k, d) in &old {
        if member_base.contains_key(k) || derived.contains_key(k) {
            continue;
        }
        reg.insert(k.clone(), ren_decl(d));
    }
    let mut after: HashMap<String, Vec<String>> = HashMap::new();
    for k in &names {
        let Some((root, _)) = derived.get(k) else {
            continue;
        };
        let f = final_of(root, &member_base, &derived, &assigned).expect("final");
        after.entry(f).or_default().push(k.clone());
    }
    let mut firsts: BTreeMap<String, String> = BTreeMap::new();
    for k in &names {
        if member_base.contains_key(k) {
            firsts
                .entry(assigned[k].clone())
                .or_insert_with(|| k.clone());
        }
    }
    for (f, k) in &firsts {
        reg.insert(f.clone(), ren_decl(&old[k]));
        for d in after.get(f).into_iter().flatten() {
            let fk = final_of(d, &member_base, &derived, &assigned).expect("final");
            if !reg.contains_key(&fk) {
                reg.insert(fk, ren_decl(&old[d]));
            }
        }
    }
    renames
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn parse(json: &str) -> Expr {
        serde_json::from_str(json).expect("expr")
    }

    fn registry(v: Value) -> IndexMap<String, Value> {
        v.as_object()
            .unwrap()
            .iter()
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect()
    }

    /// The bracket count `linear` holds: `lev` read in a reduction body.
    fn count_registry() -> IndexMap<String, Value> {
        registry(json!({"count": {"params": ["lev"], "body": {
            "op": "faq", "args": [], "output_idx": [], "ranges": {"k": [1, 3]},
            "expr": {"op": "<=", "args": [{"op": "index", "args": ["ax", "k"]}, "lev"]}}}}))
    }

    #[test]
    fn only_a_reference_reads_inside_a_reduction() {
        let mut reg = count_registry();
        let mut ctx = EwContext::new(&mut reg);
        let shaped = |v: Vec<(String, bool)>| -> Vec<(String, bool)> {
            v.into_iter().filter(|(n, _)| n == "lev").collect()
        };
        // A reference reads `lev` where its body reads a scalar: the
        // application is elementwise.
        let r = parse(
            r#"{"op":"apply_operator","args":[],"name":"count","bindings":{"lev":"lev"}}"#,
        );
        assert_eq!(
            shaped(reads_of(&mut ctx, &r)),
            vec![("lev".to_string(), true)]
        );
        // The same reduction written by hand is not an application.
        let by_hand = parse(
            r#"{"op":"faq","args":[],"output_idx":[],"ranges":{"k":[1,3]},
                "expr":{"op":"<=","args":[{"op":"index","args":["ax","k"]},"lev"]}}"#,
        );
        assert!(shaped(reads_of(&mut ctx, &by_hand)).is_empty());
        // An elementwise read outside an application is ordinary broadcasting.
        assert_eq!(
            shaped(reads_of(&mut ctx, &parse(r#"{"op":"*","args":[2,"lev"]}"#))),
            vec![("lev".to_string(), false)]
        );
    }

    #[test]
    fn roles_are_read_from_the_body() {
        let mut reg = registry(json!({
            "mix": {"params": ["p"], "body": {"op": "/", "args": ["p",
                {"op": "faq", "args": [], "output_idx": [], "ranges": {"k": {"from": "c"}},
                 "reduce": "+", "expr": {"op": "index", "args": ["p", "k"]}}]}},
            "outer": {"params": ["a"], "body": {"op": "*", "args": [2,
                {"op": "apply_operator", "args": [], "name": "mix", "bindings": {"p": "a"}}]}}
        }));
        let mut ctx = EwContext::new(&mut reg);
        assert_eq!(ctx.roles(Some("mix")).unwrap().of("p"), Role::Mixed);
        assert_eq!(ctx.roles(Some("outer")).unwrap().of("a"), Role::Mixed);
    }

    #[test]
    fn an_anonymous_array_argument_is_refused() {
        let mut reg = count_registry();
        let mut ctx = EwContext::new(&mut reg);
        let rhs = parse(
            r#"{"op":"apply_operator","args":[],"name":"count",
                "bindings":{"lev":{"op":"const","args":[],"value":[1.0,2.0]}}}"#,
        );
        let err =
            refuse_anonymous_arrays(&mut ctx, &rhs, &Expr::Variable("y".into())).unwrap_err();
        assert!(err.starts_with("array_shape_mismatch: 'y'"), "{err}");
    }

    #[test]
    fn the_lifted_body_shares_its_repeated_subtrees() {
        let count = r#"{"op":"*","args":[{"op":"+","args":[1,"lev"]},"lev"]}"#;
        let e = parse(&format!(r#"{{"op":"+","args":[{count},{count}]}}"#));
        let Expr::Operator(n) = &e else { panic!() };
        let (Expr::Operator(a), Expr::Operator(b)) = (&n.args[0], &n.args[1]) else {
            panic!()
        };
        assert!(!std::sync::Arc::ptr_eq(a, b));
        let shapes: HashMap<String, Vec<String>> =
            [("lev".to_string(), vec!["c".to_string()])].into();
        let (axes, loops) = (vec!["c".to_string()], vec!["_p0".to_string()]);
        let mut reg = IndexMap::new();
        let mut ctx = EwContext::new(&mut reg);
        let mut l = Lift::new(&mut ctx, &axes, &loops, &shapes, "x");
        let body = intern_tree(&l.at_cell(&e, &BTreeSet::new(), true).expect("lift"));
        let Expr::Operator(n) = &body else { panic!() };
        let (Expr::Operator(a), Expr::Operator(b)) = (&n.args[0], &n.args[1]) else {
            panic!()
        };
        assert!(std::sync::Arc::ptr_eq(a, b));
    }

    #[test]
    fn loop_symbols_avoid_a_name_bound_in_any_field() {
        let rhs = parse(
            r#"{"op":"*","args":["rho",{"op":"integral","args":[1.0],"var":"_p0",
                "lower":0.0,"upper":1.0}]}"#,
        );
        let mut reg = IndexMap::new();
        let mut ctx = EwContext::new(&mut reg);
        assert_eq!(fresh_loops(&mut ctx, &rhs, 2), vec!["__p0", "__p1"]);
        assert_eq!(fresh_loops(&mut ctx, &parse(r#""rho""#), 1), vec!["_p0"]);
    }

    #[test]
    fn cellwise_variants_are_numbered_by_canonical_bytes_not_discovery_order() {
        let r = |n: &str, b: Value| json!({"op": "apply_operator", "args": [], "name": n, "bindings": b});
        let ph = |n: &str, split: &[&str]| {
            cw_placeholder(
                n,
                &split.iter().map(|s| s.to_string()).collect::<Vec<_>>(),
                0,
            )
        };
        let t = json!({"params": ["p", "q"], "body": {"op": "+", "args": ["p", "q"]}});
        let u = json!({"params": ["a"], "body": r("T", json!({"p": "a", "q": "a"}))});
        let vq = json!({"params": ["p", "q", "q_cell"], "body": {"op": "+", "args": ["p", "q_cell"]}});
        let vp = json!({"params": ["p", "q", "p_cell"], "body": {"op": "+", "args": ["p_cell", "q"]}});
        let vu = json!({"params": ["a", "a_cell"],
            "body": r(&ph("T", &["p"]), json!({"p": "a", "q": "a", "p_cell": "a_cell"}))});
        let variants = vec![
            (ph("U", &["a"]), vu),
            (ph("T", &["p"]), vp),
            (ph("T", &["q"]), vq),
            (
                format!("{}.ddt", ph("T", &["q"])),
                json!({"params": ["p", "q", "q_cell"], "body": 0}),
            ),
        ];
        let mut results = Vec::new();
        for vs in [variants.clone(), variants.into_iter().rev().collect()] {
            let mut reg: IndexMap<String, Value> = IndexMap::new();
            reg.insert("T".into(), t.clone());
            reg.insert("U".into(), u.clone());
            for (k, v) in vs {
                reg.insert(k, v);
            }
            let ren = name_cellwise_variants(&mut reg);
            results.push((reg, ren));
        }
        let ((reg1, ren1), (reg2, ren2)) = (&results[0], &results[1]);
        assert_eq!(ren1, ren2);
        assert_eq!(
            reg1.keys().collect::<Vec<_>>(),
            reg2.keys().collect::<Vec<_>>()
        );
        assert_eq!(reg1, reg2);
        assert_eq!(ren1[&ph("T", &["q"])], "T.cellwise1");
        assert_eq!(ren1[&ph("T", &["p"])], "T.cellwise2");
        assert_eq!(ren1[&ph("U", &["a"])], "U.cellwise1");
        assert_eq!(
            ren1[&format!("{}.ddt", ph("T", &["q"]))],
            "T.cellwise1.ddt"
        );
        assert_eq!(reg1["U.cellwise1"]["body"]["name"], "T.cellwise2");
        assert!(reg1.contains_key("T.cellwise1.ddt"));
        assert!(!reg1.keys().any(|k| k.contains('\x1f')));
    }

    /// `doc`'s one model flattened: `lhs`'s right-hand side.
    fn flat_rhs(doc: &Value, lhs: &str) -> Expr {
        let file = crate::parse::load_string(&doc.to_string()).expect("loads");
        let flat = crate::flatten::flatten(&file).expect("flattens");
        flat.equations
            .iter()
            .find(|e| matches!(&e.lhs, Expr::Variable(n) if n == lhs))
            .expect("defined")
            .rhs
            .clone()
    }

    fn probe_doc(variables: Value, rhs: Value, model: Value) -> Value {
        let mut m = json!({
            "variables": variables,
            "equations": [
                {"lhs": "y", "rhs": rhs},
                {"lhs": {"op": "D", "args": ["s"], "wrt": "t"}, "rhs": "y"}
            ]
        });
        if let (Some(m), Some(extra)) = (m.as_object_mut(), model.as_object()) {
            m.extend(extra.clone());
        }
        json!({
            "esm": "2.0.0", "metadata": {"name": "taa_probe"},
            "index_sets": {"c": {"kind": "interval", "size": 3},
                           "verts": {"kind": "interval", "size": 4},
                           "coord": {"kind": "interval", "size": 2}},
            "models": {"M": m}
        })
    }

    #[test]
    fn a_shaped_read_written_by_hand_is_not_lifted() {
        let doc = probe_doc(
            json!({
                "u": {"type": "parameter", "shape": ["c"], "default": [1.0, 2.0, 3.0]},
                "y": {"type": "unknown"}, "s": {"type": "unknown", "default": 0.0}}),
            json!({"op": "faq", "args": [], "output_idx": [],
                "ranges": {"k": {"from": "c"}}, "expr": "u"}),
            json!({}),
        );
        let after = flat_rhs(&doc, "M.y");
        let Expr::Operator(n) = &after else { panic!() };
        assert!(n.output_idx.as_ref().is_some_and(|o| o.is_empty()));
    }

    #[test]
    fn a_variable_declared_scalar_is_not_lifted() {
        // `shape: []` declares a scalar (esm-spec §4.3.1): its elementwise
        // application is left as written.
        let doc = probe_doc(
            json!({
                "u": {"type": "parameter", "shape": ["c"], "default": [1.0, 2.0, 3.0]},
                "y": {"type": "unknown", "shape": []},
                "s": {"type": "unknown", "default": 0.0}}),
            json!({"op": "apply_operator", "args": [], "name": "twice",
                "bindings": {"x": "u"}}),
            json!({"operators": {"twice": {"params": ["x"],
                "body": {"op": "*", "args": [2, "x"]}}}}),
        );
        let after = flat_rhs(&doc, "M.y");
        let Expr::Operator(n) = &after else {
            panic!("{after:?}")
        };
        assert_eq!(n.op, APPLY_OP, "flatten left the application as written");
    }

    #[test]
    fn an_operand_defined_after_its_reader_is_gathered() {
        // Issue #714: `y` applies a definition and also reads `k`, an unshaped
        // observed that is elementwise over `u` and is DEFINED AFTER `y`. The
        // lifted body must gather `k` at the cell, whatever the equation order.
        let doc = json!({
            "esm": "2.0.0", "metadata": {"name": "order_probe"},
            "index_sets": {"c": {"kind": "interval", "size": 3}},
            "models": {"M": {
                "variables": {
                    "u": {"type": "parameter", "shape": ["c"], "default": [1.0, 2.0, 3.0]},
                    "y": {"type": "unknown", "shape": ["c"]},
                    "k": {"type": "unknown"},
                    "s": {"type": "unknown", "default": 0.0}},
                "equations": [
                    {"lhs": "y", "rhs": {"op": "+", "args": [
                        {"op": "apply_operator", "args": [], "name": "twice",
                         "bindings": {"x": "u"}},
                        "k"]}},
                    {"lhs": "k", "rhs": {"op": "*", "args": [2, "u"]}},
                    {"lhs": {"op": "D", "args": ["s"], "wrt": "t"}, "rhs": 0.0}
                ],
                "operators": {"twice": {"params": ["x"],
                    "body": {"op": "*", "args": [2, "x"]}}}
            }}
        });
        let after = flat_rhs(&doc, "M.y");
        let Expr::Operator(n) = &after else {
            panic!("{after:?}")
        };
        assert_eq!(n.op, "faq");
        let body = serde_json::to_string(n.expr.as_deref().expect("body")).unwrap();
        assert!(
            body.contains(r#"{"op":"index","args":["M.k","#),
            "M.k is not gathered at the cell: {body}"
        );
    }

    /// `doc`'s model `M` as a single-model build sees it (its references
    /// kept, nothing flattened or lifted yet), the lift run on it against its
    /// own registry: what it lifted, and `<lhs>`'s right-hand side after.
    fn lift_model(doc: &Value, lhs: &str) -> (HashMap<String, Vec<String>>, Expr) {
        let file = crate::parse::load_string(&doc.to_string()).expect("loads");
        let mut model = file.models.as_ref().expect("models")["M"].clone();
        let mut reg = file.component_operators("models.M").to_json();
        let lifted = lift_elementwise_applications_with(&mut model, &mut reg).expect("lift");
        let rhs = model
            .equations
            .iter()
            .find(|e| matches!(&e.lhs, Expr::Variable(n) if n == lhs))
            .expect("defined")
            .rhs
            .clone();
        (lifted, rhs)
    }

    /// A one-model document over `c` (3) and `l` (2) with `variables`,
    /// `equations` (plus a trivial ODE) and the `twice` definition.
    fn order_doc(variables: Value, equations: &[Value]) -> Value {
        let mut variables = variables;
        variables["s"] = json!({"type": "unknown", "default": 0.0});
        let mut eqs = equations.to_vec();
        eqs.push(json!({"lhs": {"op": "D", "args": ["s"], "wrt": "t"}, "rhs": 0.0}));
        json!({
            "esm": "2.0.0", "metadata": {"name": "order_probe"},
            "index_sets": {"c": {"kind": "interval", "size": 3},
                           "l": {"kind": "interval", "size": 2}},
            "models": {"M": {
                "variables": variables,
                "equations": eqs,
                "operators": {"twice": {"params": ["x"],
                    "body": {"op": "*", "args": [2, "x"]}}}
            }}
        })
    }

    fn twice(x: &str) -> Value {
        json!({"op": "apply_operator", "args": [],
            "name": "twice", "bindings": {"x": x}})
    }

    /// A lifted right-hand side's `faq` body, serialized.
    fn lifted_body(after: &Expr) -> String {
        let Expr::Operator(n) = after else {
            panic!("{after:?}")
        };
        assert_eq!(n.op, "faq", "not lifted: {after:?}");
        serde_json::to_string(n.expr.as_deref().expect("body")).unwrap()
    }

    #[test]
    fn an_unlifted_operand_takes_the_shape_of_operands_defined_after_it() {
        let vars = json!({
            "u": {"type": "parameter", "shape": ["c"], "default": [1.0, 2.0, 3.0]},
            "v": {"type": "parameter", "shape": ["c", "l"], "default": 1.0},
            "y": {"type": "unknown", "shape": ["c", "l"]},
            "k": {"type": "unknown"},
            "w": {"type": "unknown"}});
        let eqs = [
            json!({"lhs": "y", "rhs": {"op": "+", "args": [twice("u"), "k"]}}),
            json!({"lhs": "k", "rhs": {"op": "*", "args": ["u", "w"]}}),
            json!({"lhs": "w", "rhs": {"op": "*", "args": [2, "v"]}}),
        ];
        let orders = [
            [0, 1, 2],
            [0, 2, 1],
            [1, 0, 2],
            [1, 2, 0],
            [2, 0, 1],
            [2, 1, 0],
        ];
        let mut bodies = Vec::new();
        for order in orders {
            let ordered: Vec<Value> = order.iter().map(|&i| eqs[i].clone()).collect();
            let (_, after) = lift_model(&order_doc(vars.clone(), &ordered), "y");
            let body = lifted_body(&after);
            assert!(
                body.contains(r#"{"op":"index","args":["k","_p0","_p1"]}"#),
                "order {order:?}: k is not gathered over [c, l]: {body}"
            );
            bodies.push(body);
        }
        assert!(bodies.windows(2).all(|w| w[0] == w[1]), "{bodies:?}");
    }

    #[test]
    fn provisional_shapes_do_not_refuse_a_valid_document() {
        let vars = json!({
            "Z": {"type": "parameter", "shape": ["l"], "default": [1.0, 2.0]},
            "u": {"type": "parameter", "shape": ["c"], "default": [1.0, 2.0, 3.0]},
            "v": {"type": "parameter", "shape": ["c", "l"], "default": 1.0},
            "Y": {"type": "unknown"},
            "X": {"type": "unknown"},
            "w": {"type": "unknown"}});
        let eqs = [
            json!({"lhs": "Y", "rhs": {"op": "+", "args": [twice("X"), "Z"]}}),
            json!({"lhs": "X", "rhs": {"op": "+", "args": [twice("u"), "w"]}}),
            json!({"lhs": "w", "rhs": {"op": "*", "args": [2, "v"]}}),
        ];
        let (lifted, after) = lift_model(&order_doc(vars, &eqs), "Y");
        let cl = vec!["c".to_string(), "l".to_string()];
        assert_eq!(lifted.get("Y"), Some(&cl), "{lifted:?}");
        assert_eq!(lifted.get("X"), Some(&cl), "{lifted:?}");
        let body = lifted_body(&after);
        assert!(
            body.contains(r#"{"op":"index","args":["X","_p0","_p1"]}"#),
            "{body}"
        );
        assert!(
            body.contains(r#"{"op":"index","args":["Z","_p1"]}"#),
            "{body}"
        );
    }

    #[test]
    fn a_lifted_chain_in_reverse_order_is_lifted_link_by_link() {
        let vars = json!({
            "u": {"type": "parameter", "shape": ["c"], "default": [1.0, 2.0, 3.0]},
            "a1": {"type": "unknown"}, "a2": {"type": "unknown"}, "a3": {"type": "unknown"}});
        let eqs = [
            json!({"lhs": "a3", "rhs": twice("a2")}),
            json!({"lhs": "a2", "rhs": twice("a1")}),
            json!({"lhs": "a1", "rhs": twice("u")}),
        ];
        let (lifted, after) = lift_model(&order_doc(vars, &eqs), "a3");
        let c = vec!["c".to_string()];
        for name in ["a1", "a2", "a3"] {
            assert_eq!(lifted.get(name), Some(&c), "{name}: {lifted:?}");
        }
        let body = lifted_body(&after);
        assert!(
            body.contains(r#"{"op":"index","args":["a2","_p0"]}"#),
            "{body}"
        );
    }

    #[test]
    fn disjoint_array_arguments_span_their_union_in_order_of_first_appearance() {
        let shapes: HashMap<String, Vec<String>> = [
            ("a".to_string(), vec!["x".to_string()]),
            ("b".to_string(), vec!["y".to_string()]),
            ("s".to_string(), vec!["z".to_string()]),
            (
                "w".to_string(),
                vec!["x".to_string(), "y".to_string(), "z".to_string()],
            ),
        ]
        .into();
        let axes = |v: &[&str]| Some(v.iter().map(|a| a.to_string()).collect::<Vec<_>>());
        assert_eq!(union_axes(&["a", "b"], &shapes), axes(&["x", "y"]));
        assert_eq!(union_axes(&["b", "a"], &shapes), axes(&["y", "x"]));
        assert_eq!(union_axes(&["s", "w"], &shapes), axes(&["z", "x", "y"]));
        assert_eq!(union_axes(&["w", "s"], &shapes), axes(&["x", "y", "z"]));
        assert_eq!(union_axes(&["k"], &shapes), None);
    }
}
