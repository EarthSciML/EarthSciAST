//! Operator references: the one shared layer every part of this crate that
//! reads expressions goes through to see an `apply_operator` node
//! (esm-spec §9.6.4).
//!
//! A loaded document keeps every reference (`{"op": "apply_operator",
//! "name": N, "bindings": {p: e, …}}`) as it is: load resolves imports,
//! renames and metaparameters and runs the §9.6.3 fixpoint, but it never
//! substitutes a body into a call site (§9.6.4 rule 1). `flatten` carries the
//! references too, with every body closed over the names it reads (§9.6.4 rule
//! 7) and the components' registries merged into one
//! ([`crate::FlattenedSystem::template_registry`]).
//!
//! A reference denotes its expansion (§9.6.4 rule 2), but nothing in this
//! crate builds that expansion: an analysis, a validator or a compiler reads a
//! reference through this module, which gives it
//!
//! * the typed definition the reference names ([`OperatorRegistry`],
//!   [`Definition`]), from a component's registry
//!   ([`crate::EsmFile::component_operators`]) or from the flattened one
//!   ([`crate::FlattenedSystem::operators`]);
//! * the reference itself as a typed view ([`Reference`], [`reference`]);
//! * per-definition facts computed once from the body alone
//!   ([`Definition::param_roles`], [`Definition::callees`],
//!   [`Definition::body_binders`]);
//! * the transitive set of definitions a set of expressions reaches
//!   ([`OperatorRegistry::reachable`]), each visited once;
//! * a memo table for analyses that are a function of a definition and the
//!   shape of what a reference binds ([`InstanceMemo`]), so a definition is
//!   analysed once per instance, not once per call site.
//!
//! Nothing here, and nothing that uses it, expands a reference.

use std::cell::RefCell;
use std::collections::{BTreeSet, HashMap, HashSet};
use std::hash::Hash;
use std::rc::Rc;
use std::sync::{Arc, OnceLock};

use indexmap::{IndexMap, IndexSet};
use serde_json::Value;

use crate::binders::Binders;
use crate::types::{Expr, ExpressionNode};

/// The `op` of a reference (esm-spec §9.6.2).
pub const APPLY_OP: &str = "apply_operator";

/// One registry entry as the typed layer reads it (esm-spec §9.6.1).
#[derive(Debug)]
pub struct Definition {
    /// The registry name references use.
    pub name: String,
    /// The formal parameters, in declared order. In a flattened registry the
    /// trailing ones are the body's free names, made explicit (§9.6.4 rule 7).
    pub params: Vec<String>,
    /// The body, typed. `None` when the entry has no body that is an
    /// Expression (a malformed entry the loader's checks report).
    pub body: Option<Expr>,
    /// The defined operator the entry defines (`defines`), if any.
    pub defines: Option<String>,
    /// The unit expression over the params (`units`), if any (§9.6.12).
    pub units: Option<Expr>,
    /// `reference_only: true` (§9.6.1).
    pub reference_only: bool,
    /// Whether the entry is a `match` rule (not referenceable by a call by
    /// name unless a firing wrote a reference to it).
    pub is_rule: bool,
    /// The entry exactly as the registry holds it on the wire.
    pub raw: Value,
    /// The fixed unit expression of `partial` (`[f]/[wrt]`) or `integral`
    /// (`[f]·[var]`) over the params, when the entry defines one of them by a
    /// `match` rule (esm-spec §4.2, §9.6.12 "Units"): read off its `match`, or,
    /// for a rule a firing materialized without its `match`, the expression
    /// the load kept for it. `None` for every other entry.
    pub fixed_units: Option<Expr>,
    facts: OnceLock<BodyFacts>,
    reads: OnceLock<DefinitionReads>,
    literals: OnceLock<HashSet<String>>,
}

/// What the expansion of a reference to a definition reads from the
/// reference's site (esm-spec §9.6.4 rule 2), computed once per definition
/// through the bodies it references ([`Definition::reads`]).
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct DefinitionReads {
    /// The params whose binding the expansion reads as a value: a param the
    /// body reads as a variable leaf, directly or in a binding a nested
    /// reference reads. A param spelled only in a scalar field, a `ranges`
    /// bound or a region bound (a literal of the instance) is not read, nor
    /// is one the body never mentions.
    pub params: BTreeSet<String>,
    /// The names the expansion reads free: the body's own free names, and
    /// those of the definitions it references, less any a loop symbol of an
    /// enclosing body captures. Read in the scope of the reference's site
    /// (empty in a flattened registry, whose bodies are closed).
    pub free: BTreeSet<String>,
    /// Every loop symbol the body binds anywhere: a name in a binding the
    /// expansion reads is captured by it there (read wide, as Julia's
    /// `_tpl_scope_binders`).
    pub binders: BTreeSet<String>,
    /// The names the body, or a body it references, spells as a bare `index`
    /// subscript (`index(f, i, j)`): a check that takes every bare subscript
    /// of an expression for a binder in scope throughout it (as the
    /// undeclared-name check does) reads these as bound at the site.
    pub index_subscripts: BTreeSet<String>,
    /// The names the expansion reads as the base of an `index` (`index(a,
    /// …)`): free names, and params whose binding is substituted there (the
    /// reference's binding, when it is a bare name, is then read as one).
    /// Through the bodies it references, a param forwarded as a bare name to
    /// a callee's index base counts.
    pub index_bases: BTreeSet<String>,
    /// [`Self::index_bases`] restricted to the reads with a subscript that is
    /// not a bare name: a read that may be offset along an axis.
    pub offset_index_bases: BTreeSet<String>,
}

/// What a body says about its parameters and the names it binds, computed
/// once per definition ([`Definition::param_roles`] and friends).
#[derive(Debug, Default)]
struct BodyFacts {
    roles: HashMap<String, ParamRole>,
    callees: Vec<String>,
    binders: HashSet<String>,
    free: BTreeSet<String>,
}

/// Where a parameter occurs in its definition's body.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ParamRole {
    /// Read as an operand (a variable-reference position).
    pub operand: bool,
    /// Spelled in a scalar field (`wrt`, `dim`, `semiring`, …), a `ranges`
    /// bound or `from`, or a `makearray` region bound: the literal bound to it
    /// is part of the instance (§9.6.4 rule 3).
    pub literal: bool,
    /// Passed on as a binding of a nested reference.
    pub forwarded: bool,
}

impl Definition {
    /// The typed entry `name` of a registry, from its wire form.
    pub fn from_json(name: &str, raw: &Value) -> Definition {
        let obj = raw.as_object();
        let get = |k: &str| obj.and_then(|o| o.get(k)).filter(|v| !v.is_null());
        let params = get("params")
            .and_then(Value::as_array)
            .map(|a| {
                a.iter()
                    .filter_map(|p| p.as_str().map(str::to_string))
                    .collect()
            })
            .unwrap_or_default();
        let parse =
            |v: Option<&Value>| v.and_then(|b| serde_json::from_value::<Expr>(b.clone()).ok());
        Definition {
            name: name.to_string(),
            params,
            body: parse(get("body")),
            defines: get("defines").and_then(Value::as_str).map(str::to_string),
            units: parse(get("units")),
            reference_only: get("reference_only").and_then(Value::as_bool) == Some(true),
            is_rule: get("match").is_some(),
            fixed_units: fixed_units_json(raw).and_then(|v| serde_json::from_value(v).ok()),
            raw: raw.clone(),
            facts: OnceLock::new(),
            reads: OnceLock::new(),
            literals: OnceLock::new(),
        }
    }

    /// The literal params ([`Self::is_literal_param`]), and with them every
    /// param the body passes, as a bare name, to a literal param of a
    /// definition it references: its value lands in that literal position,
    /// so it is part of the instance too.
    fn literal_params(&self, registry: &OperatorRegistry) -> &HashSet<String> {
        self.literals.get_or_init(|| {
            let mut out: HashSet<String> = self
                .params
                .iter()
                .filter(|p| self.is_literal_param(p))
                .cloned()
                .collect();
            if let Some(body) = &self.body {
                for_each_reference(body, &mut |r| {
                    let Some(callee) = registry.resolve(&r) else {
                        return;
                    };
                    for (q, b) in r.bindings {
                        if let Expr::Variable(p) = b
                            && self.params.contains(p)
                            && callee.literal_params(registry).contains(q)
                        {
                            out.insert(p.clone());
                        }
                    }
                });
            }
            out
        })
    }

    /// What a reference to this definition reads from its site
    /// ([`DefinitionReads`]); `registry` is the one this definition is in,
    /// where its callees resolve. Computed once.
    pub fn reads(&self, registry: &OperatorRegistry) -> &DefinitionReads {
        self.reads.get_or_init(|| {
            let mut out = DefinitionReads {
                binders: self.body_binders().iter().cloned().collect(),
                ..Default::default()
            };
            if let Some(body) = &self.body {
                let params: HashSet<&str> = self.params.iter().map(String::as_str).collect();
                body_reads(body, &params, registry, &mut Vec::new(), &mut out);
            }
            out
        })
    }

    /// The literals a reference binds to this definition's literal params
    /// (§9.6.4 rule 3: they are part of the instance), each a name or a
    /// number spelled as a string. A binding that is a name the enclosing
    /// instance `outer` binds as a literal reads through it. A literal param
    /// bound to anything else is left out.
    pub fn instance_literals(
        &self,
        r: &Reference<'_>,
        outer: &InstanceLiterals,
        registry: &OperatorRegistry,
    ) -> InstanceLiterals {
        let mut out = InstanceLiterals::new();
        for p in &self.params {
            if !self.is_literal_param(p) && !self.literal_params(registry).contains(p) {
                continue;
            }
            let lit = match r.binding(p) {
                Some(Expr::Variable(s)) => outer.get(s).cloned().unwrap_or_else(|| s.clone()),
                Some(Expr::Integer(i)) => i.to_string(),
                Some(Expr::Number(n)) => n.to_string(),
                _ => continue,
            };
            out.insert(p.clone(), lit);
        }
        out
    }

    /// The body of the instance whose literal params are bound to `literals`:
    /// each literal param, where it sits in a scalar field (`wrt`, `dim`,
    /// `var`, `reduce`, `semiring`, `fn`), a `ranges` `from` / `of`, or an
    /// `enum` argument, replaced by its literal; every other position (operand
    /// reads above all) untouched. This is the per-instance specialization of
    /// esm-spec §9.6.4 rule 3, made once per instance; no binding of an
    /// operand is substituted. `None` when the definition has no body.
    pub fn instance_body(&self, literals: &InstanceLiterals) -> Option<Expr> {
        let body = self.body.as_ref()?;
        if literals.is_empty() {
            return Some(body.clone());
        }
        Some(specialize(body, literals, &mut Vec::new()))
    }

    fn facts(&self) -> &BodyFacts {
        self.facts.get_or_init(|| {
            let mut f = BodyFacts::default();
            if let Some(body) = &self.body {
                let params: HashSet<&str> = self.params.iter().map(String::as_str).collect();
                body_facts(body, &params, &HashSet::new(), &mut f);
            }
            f
        })
    }

    /// Where each parameter occurs in the body (absent: never read).
    pub fn param_roles(&self) -> &HashMap<String, ParamRole> {
        &self.facts().roles
    }

    /// The names of the definitions the body references, in first-reach
    /// order, each once.
    pub fn callees(&self) -> &[String] {
        &self.facts().callees
    }

    /// Every loop symbol the body binds anywhere (`ranges` keys,
    /// `output_idx` entries, `integral` variables). A name a reference binds
    /// that the body binds as a loop symbol is that loop symbol where the
    /// body reads it (a binding is substituted into the body), so an
    /// evaluator reads such a binding inside the body's loop.
    pub fn body_binders(&self) -> &HashSet<String> {
        &self.facts().binders
    }

    /// The names the body reads free: not a parameter, not a loop symbol it
    /// binds. Empty for every body of a flattened registry (§9.6.4 rule 7
    /// closes them); in a component's registry they are read in the scope
    /// of the reference's site.
    pub fn free_names(&self) -> &BTreeSet<String> {
        &self.facts().free
    }

    /// Whether `p` is a parameter whose bound literal is part of the
    /// instance ([`ParamRole::literal`]).
    pub fn is_literal_param(&self, p: &str) -> bool {
        self.param_roles().get(p).is_some_and(|r| r.literal)
    }
}

/// Walk a body for [`BodyFacts`]. `bound` holds the loop symbols in scope.
fn body_facts(e: &Expr, params: &HashSet<&str>, bound: &HashSet<String>, f: &mut BodyFacts) {
    let Expr::Operator(node) = e else {
        if let Expr::Variable(n) = e {
            if bound.contains(n) {
                return;
            }
            if params.contains(n.as_str()) {
                f.roles.entry(n.clone()).or_default().operand = true;
            } else if !n.starts_with('\0') {
                f.free.insert(n.clone());
            }
        }
        return;
    };
    // Scalar fields, `ranges` bounds and `from`, and region bounds: a
    // parameter spelled there is a literal of the instance.
    let mut literal = |s: &str| {
        if params.contains(s) && !bound.contains(s) {
            f.roles.entry(s.to_string()).or_default().literal = true;
        }
    };
    for s in [
        &node.wrt,
        &node.dim,
        &node.int_var,
        &node.reduce,
        &node.semiring,
        &node.broadcast_fn,
    ]
    .into_iter()
    .flatten()
    {
        literal(s);
    }
    if let Some(ranges) = &node.ranges
        && let Ok(Value::Object(m)) = serde_json::to_value(ranges)
    {
        for v in m.values() {
            json_strings(v, &mut literal);
        }
    }
    if let Some(regions) = &node.regions
        && let Ok(v) = serde_json::to_value(regions)
    {
        json_strings(&v, &mut literal);
    }
    if node.op == "enum" {
        for a in &node.args {
            if let Expr::Variable(s) = a {
                literal(s);
            }
        }
    }
    if node.op == APPLY_OP {
        if let Some(n) = &node.name
            && !f.callees.contains(n)
        {
            f.callees.push(n.clone());
        }
        if let Some(b) = &node.bindings {
            for v in b.values() {
                if let Expr::Variable(s) = v
                    && params.contains(s.as_str())
                    && !bound.contains(s)
                {
                    f.roles.entry(s.clone()).or_default().forwarded = true;
                }
            }
        }
    }
    let here = node.binders(Binders::SCOPE);
    f.binders.extend(here.iter().map(|s| s.to_string()));
    let inner_owned;
    let inner = if here.is_empty() {
        bound
    } else {
        let mut b = bound.clone();
        b.extend(here.into_iter().map(str::to_string));
        inner_owned = b;
        &inner_owned
    };
    node.for_each_child(&mut |c| body_facts(c, params, inner, f));
}

/// Call `f` on every string in a JSON value.
fn json_strings(v: &Value, f: &mut impl FnMut(&str)) {
    match v {
        Value::String(s) => f(s),
        Value::Array(a) => a.iter().for_each(|x| json_strings(x, f)),
        Value::Object(m) => m.values().for_each(|x| json_strings(x, f)),
        _ => {}
    }
}

/// The literal value of each literal param of a definition instance
/// ([`Definition::instance_literals`]).
pub type InstanceLiterals = std::collections::BTreeMap<String, String>;

/// The fixed unit expression of a registry entry, wire form
/// ([`Definition::fixed_units`]).
fn fixed_units_json(raw: &Value) -> Option<Value> {
    if let Some(kept) = crate::lower_expression_templates::kept_fixed_units_json(raw) {
        return Some(kept.clone());
    }
    let m = raw.get("match")?.as_object()?;
    let (axis, op) = match m.get("op")?.as_str()? {
        "partial" => ("wrt", "/"),
        "integral" => ("var", "*"),
        _ => return None,
    };
    let first = m.get("args")?.as_array()?.first()?.clone();
    let ax = m.get(axis)?.clone();
    Some(serde_json::json!({"op": op, "args": [first, ax]}))
}

/// Walk a body for [`DefinitionReads`]. `bound` holds the loop symbols in
/// scope (the body's own, and those of the bodies a binding is read in).
fn body_reads(
    e: &Expr,
    params: &HashSet<&str>,
    registry: &OperatorRegistry,
    bound: &mut Vec<String>,
    out: &mut DefinitionReads,
) {
    let node = match e {
        Expr::Variable(n) => {
            if !bound.iter().any(|b| b == n) {
                if params.contains(n.as_str()) {
                    out.params.insert(n.clone());
                } else if !n.starts_with('\0') {
                    out.free.insert(n.clone());
                }
            }
            return;
        }
        Expr::Operator(node) => node,
        _ => return,
    };
    if node.op == "index" {
        out.index_subscripts
            .extend(node.args.iter().skip(1).filter_map(|a| match a {
                Expr::Variable(s) => Some(s.clone()),
                _ => None,
            }));
        if let Some(Expr::Variable(base)) = node.args.first()
            && !bound.iter().any(|b| b == base)
        {
            out.index_bases.insert(base.clone());
            if node.args[1..]
                .iter()
                .any(|a| !matches!(a, Expr::Variable(_)))
            {
                out.offset_index_bases.insert(base.clone());
            }
        }
    }
    if let Some(r) = reference_node(node) {
        match registry.resolve(&r) {
            Some(callee) => {
                let cr = callee.reads(registry);
                for n in &cr.free {
                    if !bound.iter().any(|b| b == n) {
                        out.free.insert(n.clone());
                    }
                }
                out.index_subscripts
                    .extend(cr.index_subscripts.iter().cloned());
                // The callee's index bases, read here: its free ones as they
                // are, its params through the bare names bound to them.
                for (set, mine) in [
                    (&cr.index_bases, &mut out.index_bases),
                    (&cr.offset_index_bases, &mut out.offset_index_bases),
                ] {
                    for n in set {
                        let here = if callee.params.contains(n) {
                            match r.binding(n) {
                                Some(Expr::Variable(b)) => b,
                                _ => continue,
                            }
                        } else {
                            n
                        };
                        if !bound.iter().any(|b| b == here) {
                            mine.insert(here.clone());
                        }
                    }
                }
                let depth = bound.len();
                bound.extend(cr.binders.iter().cloned());
                let mut keys: Vec<&String> = r.bindings.keys().collect();
                keys.sort();
                for k in keys.into_iter().filter(|k| cr.params.contains(*k)) {
                    body_reads(&r.bindings[k], params, registry, bound, out);
                }
                bound.truncate(depth);
            }
            // An unresolved reference (the load's checks report it): every
            // binding counts as read.
            None => r
                .bindings
                .values()
                .for_each(|b| body_reads(b, params, registry, bound, out)),
        }
        return;
    }
    let depth = bound.len();
    node.for_each_binder(Binders::SCOPE, |n| bound.push(n.to_string()));
    node.for_each_child(&mut |c| body_reads(c, params, registry, bound, out));
    bound.truncate(depth);
}

/// [`Definition::instance_body`]'s walk. `bound` holds the loop symbols in
/// scope, which shadow a param of the same name. A `ranges` bound naming a
/// literal param takes its literal; a range whose two bounds are then
/// integers is the interval they give.
fn specialize(e: &Expr, lits: &InstanceLiterals, bound: &mut Vec<String>) -> Expr {
    let Expr::Operator(node) = e else {
        return e.clone();
    };
    let lit = |s: &String, bound: &Vec<String>| -> Option<String> {
        if bound.contains(s) {
            None
        } else {
            lits.get(s).cloned()
        }
    };
    let depth = bound.len();
    node.for_each_binder(Binders::SCOPE, |n| bound.push(n.to_string()));
    let mut out = node.map_children(&mut |c| specialize(c, lits, bound));
    for f in [
        &mut out.wrt,
        &mut out.dim,
        &mut out.int_var,
        &mut out.reduce,
        &mut out.semiring,
        &mut out.broadcast_fn,
    ] {
        if let Some(v) = f.as_ref().and_then(|s| lit(s, bound)) {
            *f = Some(v);
        }
    }
    if let Some(ranges) = out.ranges.as_mut() {
        use crate::types::{RangeBound, RangeSpec};
        for spec in ranges.values_mut() {
            match spec {
                RangeSpec::IndexSetRef { from, of } => {
                    if let Some(v) = lit(from, bound) {
                        *from = v;
                    }
                    for o in of.iter_mut().flatten() {
                        if let Some(v) = lit(o, bound) {
                            *o = v;
                        }
                    }
                }
                RangeSpec::Symbolic(ends) => {
                    for end in ends.iter_mut() {
                        if let RangeBound::Name(n) = end
                            && let Some(v) = lit(n, bound)
                        {
                            *end = match v.parse::<i64>() {
                                Ok(i) => RangeBound::Int(i),
                                Err(_) => RangeBound::Name(v),
                            };
                        }
                    }
                    if let [RangeBound::Int(lo), RangeBound::Int(hi)] = ends {
                        *spec = RangeSpec::Interval([*lo, *hi]);
                    }
                }
                _ => {}
            }
        }
    }
    if out.op == "enum" {
        for a in out.args.iter_mut() {
            if let Expr::Variable(s) = a
                && let Some(v) = lit(s, bound)
            {
                *a = Expr::Variable(v);
            }
        }
    }
    bound.truncate(depth);
    Expr::operator(out)
}

/// A registry of operator definitions: a component's (§9.6.4 rule 5) or a
/// flattened system's merged one (rule 7), in registry order. Cheap to clone.
#[derive(Debug, Clone, Default)]
pub struct OperatorRegistry {
    entries: Arc<IndexMap<String, Arc<Definition>>>,
    instance: Arc<OnceLock<InstanceParams>>,
    captured: Arc<OnceLock<HashMap<String, HashSet<String>>>>,
    instances: Arc<std::sync::Mutex<InstanceCache>>,
}

/// The instances of a registry made so far, by definition name and literals.
type InstanceCache = HashMap<(String, InstanceLiterals), Arc<Instance>>;

/// One definition instance (esm-spec §9.6.4 rule 3): a definition with the
/// literals its literal params are bound to, and the body of that instance
/// ([`Definition::instance_body`]). Made once per registry and instance
/// ([`OperatorRegistry::instances`]).
#[derive(Debug)]
pub struct Instance {
    /// The definition.
    pub definition: Arc<Definition>,
    /// What its literal params are bound to.
    pub literals: InstanceLiterals,
    /// Its body with those literals in their literal positions (the literal
    /// `0` when the definition has no body).
    pub body: Expr,
}

impl OperatorRegistry {
    /// A registry from its wire form (an `operators` block, or a flattened
    /// `template_registry`).
    pub fn from_json<'a>(entries: impl IntoIterator<Item = (&'a String, &'a Value)>) -> Self {
        OperatorRegistry {
            entries: Arc::new(
                entries
                    .into_iter()
                    .map(|(k, v)| (k.clone(), Arc::new(Definition::from_json(k, v))))
                    .collect(),
            ),
            instance: Arc::default(),
            captured: Arc::default(),
            instances: Default::default(),
        }
    }

    /// Every definition instance `roots` reach (esm-spec §9.6.4 rule 3): the
    /// references in them, and those in the instance bodies they name,
    /// transitively, each instance once, in first-reach order. A reference
    /// the registry does not resolve is skipped (the load reports it). An
    /// analysis that reads a definition's literal positions (an index set a
    /// `ranges` entry names, a `wrt`) walks these bodies, once per instance,
    /// and reports what it finds at the reference's site.
    pub fn instances<'a>(&self, roots: impl IntoIterator<Item = &'a Expr>) -> Vec<Arc<Instance>> {
        let mut seen = HashSet::new();
        let mut out = Vec::new();
        for e in roots {
            self.collect_instances(e, &InstanceLiterals::new(), &mut seen, &mut out);
        }
        out
    }

    fn collect_instances(
        &self,
        e: &Expr,
        outer: &InstanceLiterals,
        seen: &mut HashSet<(String, InstanceLiterals)>,
        out: &mut Vec<Arc<Instance>>,
    ) {
        let mut found = Vec::new();
        for_each_reference(e, &mut |r| {
            if let Some(d) = self.resolve(&r) {
                found.push((Arc::clone(d), d.instance_literals(&r, outer, self)));
            }
        });
        for (d, lits) in found {
            let key = (d.name.clone(), lits);
            if !seen.insert(key.clone()) {
                continue;
            }
            let inst = self.instance(d, key);
            out.push(Arc::clone(&inst));
            self.collect_instances(&inst.body, &inst.literals, seen, out);
        }
    }

    /// The instance `key` of `d`, made once.
    fn instance(&self, d: Arc<Definition>, key: (String, InstanceLiterals)) -> Arc<Instance> {
        if let Some(i) = self
            .instances
            .lock()
            .ok()
            .and_then(|m| m.get(&key).cloned())
        {
            return i;
        }
        let body = d.instance_body(&key.1).unwrap_or(Expr::Integer(0));
        let inst = Arc::new(Instance {
            definition: d,
            literals: key.1.clone(),
            body,
        });
        if let Ok(mut m) = self.instances.lock() {
            return Arc::clone(m.entry(key).or_insert(inst));
        }
        inst
    }

    /// The definition `name`, if the registry holds it.
    pub fn get(&self, name: &str) -> Option<&Arc<Definition>> {
        self.entries.get(name)
    }

    /// The definition a reference names.
    pub fn resolve(&self, r: &Reference<'_>) -> Option<&Arc<Definition>> {
        self.get(r.name)
    }

    /// Every entry, in registry order.
    pub fn iter(&self) -> impl Iterator<Item = (&String, &Arc<Definition>)> {
        self.entries.iter()
    }

    /// The number of entries.
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// Whether the registry is empty.
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// The registry in its wire form, entries in registry order.
    pub fn to_json(&self) -> IndexMap<String, Value> {
        self.entries
            .iter()
            .map(|(k, d)| (k.clone(), d.raw.clone()))
            .collect()
    }

    /// The names of every definition `roots` reach: the references in them,
    /// and through the bodies of the definitions they name, transitively.
    /// In first-reach order (a depth-first walk of `roots` in order), each
    /// name once; each body is walked once. A name the registry does not hold
    /// is listed (so a caller can report it) but not walked.
    pub fn reachable<'a>(&self, roots: impl IntoIterator<Item = &'a Expr>) -> IndexSet<String> {
        let mut out = IndexSet::new();
        for e in roots {
            let mut found = Vec::new();
            for_each_reference(e, &mut |r| found.push(r.name.to_string()));
            for n in found {
                self.reach(n, &mut out);
            }
        }
        out
    }

    fn reach(&self, name: String, out: &mut IndexSet<String>) {
        if !out.insert(name.clone()) {
            return;
        }
        if let Some(d) = self.get(&name) {
            for c in d.callees() {
                self.reach(c.clone(), out);
            }
        }
    }
}

/// A reference node, typed: the definition it names and what it binds.
#[derive(Debug, Clone, Copy)]
pub struct Reference<'a> {
    /// The node itself.
    pub node: &'a ExpressionNode,
    /// The registry name it references.
    pub name: &'a str,
    /// What it binds to each parameter (empty map when it binds nothing).
    pub bindings: &'a HashMap<String, Expr>,
}

impl<'a> Reference<'a> {
    /// The expression bound to `param`, if any.
    pub fn binding(&self, param: &str) -> Option<&'a Expr> {
        self.bindings.get(param)
    }
}

fn empty_bindings() -> &'static HashMap<String, Expr> {
    static EMPTY: OnceLock<HashMap<String, Expr>> = OnceLock::new();
    EMPTY.get_or_init(HashMap::new)
}

/// `e` as a reference, when it is one.
pub fn reference(e: &Expr) -> Option<Reference<'_>> {
    match e {
        Expr::Operator(node) => reference_node(node),
        _ => None,
    }
}

/// `node` as a reference, when it is one.
pub fn reference_node(node: &ExpressionNode) -> Option<Reference<'_>> {
    if node.op != APPLY_OP {
        return None;
    }
    Some(Reference {
        node,
        name: node.name.as_deref()?,
        bindings: node.bindings.as_ref().unwrap_or_else(|| empty_bindings()),
    })
}

/// Whether `e` holds a reference anywhere (bindings included).
pub fn has_reference(e: &Expr) -> bool {
    match e {
        Expr::Operator(node) => node.op == APPLY_OP || node.any_child(&mut has_reference),
        _ => false,
    }
}

/// Call `f` on every reference in `e`, outermost first, including references
/// nested in other references' bindings. Does not enter bodies.
pub fn for_each_reference<'a>(e: &'a Expr, f: &mut impl FnMut(Reference<'a>)) {
    if let Expr::Operator(node) = e {
        if let Some(r) = reference_node(node) {
            f(r);
        }
        node.for_each_child(&mut |c| for_each_reference(c, f));
    }
}

/// Call `f` on every name `e` reads as a value in its own scope (a variable
/// leaf that no enclosing node of `e` binds as a loop symbol), seeing each
/// reference as its expansion reads it (esm-spec §9.6.4 rule 2): a reference
/// `registry` resolves reads the bindings its definition reads
/// ([`DefinitionReads::params`]; a name in one that the body binds as a loop
/// symbol is captured there, as substitution would), and the names its
/// bodies read free ([`DefinitionReads::free`]), in the scope of its site. A
/// reference `registry` does not resolve reads every binding: in a flattened
/// system, whose bodies are closed, that is exactly what it reads. A name is
/// visited once per occurrence, in walk order.
pub fn for_each_site_read(e: &Expr, registry: &OperatorRegistry, f: &mut impl FnMut(&str)) {
    site_reads_walk(e, registry, &mut Vec::new(), f);
}

/// The names `e` reads at its site ([`for_each_site_read`]), sorted.
pub fn site_reads(e: &Expr, registry: &OperatorRegistry) -> BTreeSet<String> {
    let mut out = BTreeSet::new();
    for_each_site_read(e, registry, &mut |n| {
        if !out.contains(n) {
            out.insert(n.to_string());
        }
    });
    out
}

fn site_reads_walk(
    e: &Expr,
    registry: &OperatorRegistry,
    bound: &mut Vec<String>,
    f: &mut impl FnMut(&str),
) {
    let node = match e {
        Expr::Variable(n) => {
            if !bound.iter().any(|b| b == n) {
                f(n);
            }
            return;
        }
        Expr::Operator(node) => node,
        _ => return,
    };
    if let Some(r) = reference_node(node)
        && let Some(def) = registry.resolve(&r)
    {
        let reads = def.reads(registry);
        for n in &reads.free {
            if !bound.iter().any(|b| b == n) {
                f(n);
            }
        }
        let depth = bound.len();
        bound.extend(reads.binders.iter().cloned());
        let mut keys: Vec<&String> = r.bindings.keys().collect();
        keys.sort();
        for k in keys.into_iter().filter(|k| reads.params.contains(*k)) {
            site_reads_walk(&r.bindings[k], registry, bound, f);
        }
        bound.truncate(depth);
        return;
    }
    let depth = bound.len();
    node.for_each_binder(Binders::SCOPE, |n| bound.push(n.to_string()));
    node.for_each_child(&mut |c| site_reads_walk(c, registry, bound, f));
    bound.truncate(depth);
}

/// A memo of an analysis that is a function of a definition and a key
/// describing what a reference binds (its instance, §9.6.4 rule 3, or any
/// coarser or finer description the analysis needs): computed once per
/// `(definition, key)`, then reused at every reference with that key.
///
/// The analysis reads the definition's body with its parameters standing for
/// whatever the key says about the bindings; it never substitutes a binding
/// into the body.
pub struct InstanceMemo<K, T> {
    map: RefCell<HashMap<(String, K), Rc<T>>>,
}

impl<K, T> Default for InstanceMemo<K, T> {
    fn default() -> Self {
        InstanceMemo {
            map: RefCell::new(HashMap::new()),
        }
    }
}

impl<K: Hash + Eq + Clone, T> InstanceMemo<K, T> {
    /// An empty memo.
    pub fn new() -> Self {
        Self::default()
    }

    /// The analysis of `definition` under `key`, computed by `analyse` the
    /// first time this pair is asked for. `analyse` may itself ask this memo
    /// about other definitions (the reference graph is acyclic, §9.7.3).
    pub fn get_or_compute(&self, definition: &str, key: &K, analyse: impl FnOnce() -> T) -> Rc<T> {
        let k = (definition.to_string(), key.clone());
        if let Some(v) = self.map.borrow().get(&k) {
            return Rc::clone(v);
        }
        let v = Rc::new(analyse());
        self.map.borrow_mut().insert(k, Rc::clone(&v));
        v
    }

    /// How many `(definition, key)` pairs have been analysed.
    pub fn len(&self) -> usize {
        self.map.borrow().len()
    }

    /// Whether nothing has been analysed yet.
    pub fn is_empty(&self) -> bool {
        self.map.borrow().is_empty()
    }
}

/// The parameters whose bound value is part of an instance of each
/// definition (esm-spec §9.6.4 rule 3), computed once per registry
/// ([`OperatorRegistry::instance_params`]).
type InstanceParams = HashMap<String, Vec<String>>;

/// Where the parameters of one definition sit in its body ON THE WIRE: a
/// literal position is any string that is not an Expression leaf (a scalar
/// field, a `ranges` bound or `from`, an `output_idx` entry, a region bound, a
/// `join` column, an `enum` argument). Read from the wire form because a body
/// whose `ranges` bound names a parameter (`[1, "n"]`) is not a typed
/// Expression until that bound is a literal.
#[derive(Default)]
struct WireRoles {
    literal: HashSet<String>,
    /// `(callee, callee parameter, the parameters its binding reads)`.
    forwards: Vec<(String, String, HashSet<String>)>,
}

fn wire_roles(body: &Value, params: &HashSet<&str>) -> WireRoles {
    fn names(v: &Value, params: &HashSet<&str>, out: &mut HashSet<String>) {
        match v {
            Value::String(s) if params.contains(s.as_str()) => {
                out.insert(s.clone());
            }
            Value::Array(a) => a.iter().for_each(|x| names(x, params, out)),
            Value::Object(m) => {
                let apply = m.get("op").and_then(Value::as_str) == Some(APPLY_OP);
                for (k, x) in m {
                    if !(apply && k == "name") && k != "op" {
                        names(x, params, out);
                    }
                }
            }
            _ => {}
        }
    }
    fn walk(v: &Value, expr_pos: bool, params: &HashSet<&str>, r: &mut WireRoles) {
        match v {
            Value::String(s) if !expr_pos && params.contains(s.as_str()) => {
                r.literal.insert(s.clone());
            }
            Value::Array(a) => a.iter().for_each(|x| walk(x, expr_pos, params, r)),
            Value::Object(m) => {
                let op = m.get("op").and_then(Value::as_str);
                if op.is_none() {
                    m.values().for_each(|x| walk(x, false, params, r));
                    return;
                }
                for (k, x) in m {
                    match k.as_str() {
                        "op" | "value" => {}
                        "name" if op == Some(APPLY_OP) => {}
                        "args" => walk(x, op != Some("enum"), params, r),
                        "values" | "lower" | "upper" | "expr" | "filter" | "key" => {
                            walk(x, true, params, r)
                        }
                        "bindings" => {
                            let callee = m.get("name").and_then(Value::as_str);
                            if let Value::Object(b) = x {
                                for (bp, bv) in b {
                                    walk(bv, true, params, r);
                                    if let Some(c) = callee {
                                        let mut read = HashSet::new();
                                        names(bv, params, &mut read);
                                        if !read.is_empty() {
                                            r.forwards.push((c.to_string(), bp.clone(), read));
                                        }
                                    }
                                }
                            }
                        }
                        _ => walk(x, false, params, r),
                    }
                }
            }
            _ => {}
        }
    }
    let mut r = WireRoles::default();
    walk(body, true, params, &mut r);
    r
}

impl Definition {
    /// The body on the wire (`None` when the entry has none).
    pub fn raw_body(&self) -> Option<&Value> {
        self.raw.get("body").filter(|b| !b.is_null())
    }
}

impl OperatorRegistry {
    /// The parameters of `name` whose bound value is part of the instance a
    /// reference names (esm-spec §9.6.4 rule 3), in declared order: those
    /// spelled in a literal position of the body on the wire (a scalar field,
    /// a `ranges` bound or `from`, an `output_idx` entry, a region bound, a
    /// `join` column, an `enum` argument), and those read by a binding the
    /// body gives such a parameter of a definition it references
    /// (transitively). Empty for an unknown name.
    ///
    /// An instance is a definition plus the values bound to these
    /// parameters; [`Instances`] specializes the body once per instance.
    pub fn instance_params(&self, name: &str) -> &[String] {
        let all = self.instance.get_or_init(|| {
            let mut out: InstanceParams = HashMap::new();
            let mut visiting = HashSet::new();
            for n in self.entries.keys() {
                self.instance_params_of(n, &mut out, &mut visiting);
            }
            out
        });
        all.get(name).map(Vec::as_slice).unwrap_or(&[])
    }

    fn instance_params_of(
        &self,
        name: &str,
        out: &mut InstanceParams,
        visiting: &mut HashSet<String>,
    ) {
        if out.contains_key(name) || !visiting.insert(name.to_string()) {
            return;
        }
        let Some(d) = self.get(name) else {
            return;
        };
        let params: HashSet<&str> = d.params.iter().map(String::as_str).collect();
        let roles = d
            .raw_body()
            .map(|b| wire_roles(b, &params))
            .unwrap_or_default();
        let mut lit = roles.literal;
        for (callee, cp, read) in &roles.forwards {
            self.instance_params_of(callee, out, visiting);
            if out.get(callee).is_some_and(|ps| ps.contains(cp)) {
                lit.extend(read.iter().cloned());
            }
        }
        let ordered = d
            .params
            .iter()
            .filter(|p| lit.contains(*p))
            .cloned()
            .collect();
        out.insert(name.to_string(), ordered);
    }
}

/// Every loop symbol bound anywhere in a body on the wire: `ranges` keys,
/// `output_idx` entries and `integral` variables (`var`).
fn wire_binders(v: &Value, out: &mut HashSet<String>) {
    match v {
        Value::Array(a) => a.iter().for_each(|x| wire_binders(x, out)),
        Value::Object(m) => {
            if m.get("op").is_some() {
                if let Some(Value::Object(r)) = m.get("ranges") {
                    out.extend(r.keys().cloned());
                }
                if let Some(Value::Array(o)) = m.get("output_idx") {
                    out.extend(o.iter().filter_map(Value::as_str).map(str::to_string));
                }
                if let Some(Value::String(iv)) = m.get("var") {
                    out.insert(iv.clone());
                }
            }
            m.values().for_each(|x| wire_binders(x, out));
        }
        _ => {}
    }
}

impl OperatorRegistry {
    /// The loop symbols a binding of a reference to `name` may read as the
    /// body's own (esm-spec §9.6.4: a binding is read where the body reads its
    /// parameter, so a name it reads that the body binds there is that loop
    /// symbol, as in the expansion): every loop symbol bound anywhere in the
    /// body of `name` or of a definition it references, transitively. Empty
    /// for an unknown name.
    pub fn captured_symbols(&self, name: &str) -> &HashSet<String> {
        static EMPTY: OnceLock<HashSet<String>> = OnceLock::new();
        let all = self.captured.get_or_init(|| {
            let mut out: HashMap<String, HashSet<String>> = HashMap::new();
            for n in self.entries.keys() {
                let mut set = HashSet::new();
                for r in self.reach_from(n) {
                    if let Some(b) = self.get(&r).and_then(|d| d.raw_body()) {
                        wire_binders(b, &mut set);
                    }
                }
                out.insert(n.clone(), set);
            }
            out
        });
        all.get(name)
            .unwrap_or_else(|| EMPTY.get_or_init(HashSet::new))
    }

    /// `name` and every definition its body reaches, each once.
    fn reach_from(&self, name: &str) -> IndexSet<String> {
        let mut out = IndexSet::new();
        self.reach(name.to_string(), &mut out);
        out
    }
}

/// `body` (a definition's body on the wire) with every string spelling one of
/// `literals`' parameters replaced by its bound value, exactly where
/// expansion would substitute it (everywhere but a nested reference's `name`
/// and object keys): the body of one instance (esm-spec §9.6.4 rule 3). Only
/// the instance parameters are replaced; every other parameter stays a name
/// the evaluator reads through the reference's bindings.
pub fn specialize_body(body: &Value, literals: &HashMap<String, Value>) -> Value {
    match body {
        Value::String(s) => literals.get(s).cloned().unwrap_or_else(|| body.clone()),
        Value::Array(a) => Value::Array(a.iter().map(|x| specialize_body(x, literals)).collect()),
        Value::Object(m) => {
            let apply = m.get("op").and_then(Value::as_str) == Some(APPLY_OP);
            Value::Object(
                m.iter()
                    .map(|(k, x)| {
                        let v = if (apply && k == "name") || k == "op" {
                            x.clone()
                        } else {
                            specialize_body(x, literals)
                        };
                        (k.clone(), v)
                    })
                    .collect(),
            )
        }
        _ => body.clone(),
    }
}

/// One instance of a definition: the definition and its body specialized to
/// the values a reference binds to its instance parameters
/// ([`OperatorRegistry::instance_params`]).
#[derive(Debug)]
pub struct CallInstance {
    /// The definition.
    pub definition: Arc<Definition>,
    /// The specialized body, typed, with every build pass of the
    /// [`Instances`] applied.
    pub body: Expr,
    /// The instance parameters, in declared order.
    pub instance_params: Vec<String>,
    binders: OnceLock<HashSet<String>>,
}

impl CallInstance {
    /// Whether `name` is a parameter of the definition this instantiates.
    pub fn is_param(&self, name: &str) -> bool {
        self.definition.params.iter().any(|p| p == name)
    }

    /// Every loop symbol the instance body binds anywhere (`ranges` keys,
    /// `output_idx` entries, `integral` variables). A binding is read where
    /// the body reads its parameter, so a name a binding reads that the body
    /// binds is that loop symbol (the capture expansion has).
    pub fn binders(&self) -> &HashSet<String> {
        self.binders.get_or_init(|| {
            let mut out = HashSet::new();
            crate::binders::collect_binders(&self.body, Binders::SCOPE, &mut out);
            out
        })
    }
}

/// Why a reference names no instance.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InstanceError {
    /// The registry holds no definition of that name.
    Unknown(String),
    /// The definition has no body.
    NoBody(String),
    /// The reference binds no value to an instance parameter.
    Unbound { name: String, param: String },
    /// The specialized body is not an Expression.
    Malformed { name: String, why: String },
    /// A build pass refused the instance body.
    Rewrite { name: String, why: String },
}

impl std::fmt::Display for InstanceError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            InstanceError::Unknown(n) => write!(f, "operator reference `{n}` names no definition"),
            InstanceError::NoBody(n) => write!(f, "operator `{n}` has no body"),
            InstanceError::Unbound { name, param } => write!(
                f,
                "operator reference `{name}` binds nothing to parameter `{param}`"
            ),
            InstanceError::Rewrite { name, why } => write!(f, "operator `{name}`: {why}"),
            InstanceError::Malformed { name, why } => {
                write!(
                    f,
                    "operator `{name}`: the instance body is not an Expression: {why}"
                )
            }
        }
    }
}

/// A definition name and the wire text of the values bound to its instance
/// parameters: the key of one [`CallInstance`].
type CallKey = (String, Vec<String>);

/// A reference node (held so its address is never reused) and its instance.
type NodeInstance = (Arc<ExpressionNode>, Arc<CallInstance>);

/// A build pass over one expression, applied to each instance body
/// ([`Instances::with_rewrite`]).
pub type BodyRewrite = Arc<dyn Fn(&mut Expr) -> Result<(), String> + Send + Sync>;

/// The instances a set of references name, each specialized once
/// (esm-spec §9.6.4 rule 3), over one registry. Shared by every evaluation of
/// a build; thread-safe.
#[derive(Default)]
pub struct Instances {
    registry: OperatorRegistry,
    by_key: std::sync::Mutex<HashMap<CallKey, Arc<CallInstance>>>,
    /// Per reference node: the node (held so its address is never reused) and
    /// its instance.
    by_node: std::sync::Mutex<HashMap<usize, NodeInstance>>,
    /// Body rewrites the build applies to every instance body (see
    /// [`Instances::with_rewrite`]).
    rewrites: Vec<BodyRewrite>,
}

impl std::fmt::Debug for Instances {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Instances")
            .field("registry", &self.registry)
            .field("rewrites", &self.rewrites.len())
            .finish_non_exhaustive()
    }
}

impl Instances {
    /// The instances of `registry`'s definitions, none specialized yet.
    pub fn new(registry: OperatorRegistry) -> Self {
        Instances {
            registry,
            ..Default::default()
        }
    }

    /// The shared empty set: an evaluation where no reference can occur.
    pub fn empty() -> &'static Instances {
        static EMPTY: OnceLock<Instances> = OnceLock::new();
        EMPTY.get_or_init(Instances::default)
    }

    /// The registry the references resolve against.
    pub fn registry(&self) -> &OperatorRegistry {
        &self.registry
    }

    /// These instances with `rewrite` applied to every instance body after
    /// the ones before it: a build pass that rewrites each expression of the
    /// system on its own (resolving an index-set range, lowering a `join`)
    /// rewrites each instance body once the same way. Clears what was
    /// specialized.
    pub fn with_rewrite(
        mut self,
        rewrite: impl Fn(&mut Expr) -> Result<(), String> + Send + Sync + 'static,
    ) -> Self {
        self.rewrites.push(Arc::new(rewrite));
        self.by_key = Default::default();
        self.by_node = Default::default();
        self
    }

    /// The instance reference `r` names.
    pub fn instance(&self, r: &Reference<'_>) -> Result<Arc<CallInstance>, InstanceError> {
        let d = self
            .registry
            .get(r.name)
            .ok_or_else(|| InstanceError::Unknown(r.name.to_string()))?;
        let ips = self.registry.instance_params(r.name);
        let mut key = Vec::with_capacity(ips.len());
        let mut lits = HashMap::with_capacity(ips.len());
        for p in ips {
            let b = r.binding(p).ok_or_else(|| InstanceError::Unbound {
                name: r.name.to_string(),
                param: p.clone(),
            })?;
            let v = serde_json::to_value(b).unwrap_or(Value::Null);
            key.push(v.to_string());
            lits.insert(p.clone(), v);
        }
        let k = (r.name.to_string(), key);
        if let Some(i) = self.by_key.lock().ok().and_then(|m| m.get(&k).cloned()) {
            return Ok(i);
        }
        let raw = d
            .raw_body()
            .ok_or_else(|| InstanceError::NoBody(r.name.to_string()))?;
        let mut body: Expr = match (lits.is_empty(), &d.body) {
            (true, Some(b)) => b.clone(),
            _ => serde_json::from_value(specialize_body(raw, &lits)).map_err(|e| {
                InstanceError::Malformed {
                    name: r.name.to_string(),
                    why: e.to_string(),
                }
            })?,
        };
        for rw in &self.rewrites {
            rw(&mut body).map_err(|why| InstanceError::Rewrite {
                name: r.name.to_string(),
                why,
            })?;
        }
        let inst = Arc::new(CallInstance {
            definition: Arc::clone(d),
            body,
            instance_params: ips.to_vec(),
            binders: OnceLock::new(),
        });
        if let Ok(mut m) = self.by_key.lock() {
            m.insert(k, Arc::clone(&inst));
        }
        Ok(inst)
    }

    /// [`Self::instance`] of the reference node `node`, remembered per node.
    pub fn instance_of_node(
        &self,
        node: &Arc<ExpressionNode>,
    ) -> Result<Arc<CallInstance>, InstanceError> {
        let addr = Arc::as_ptr(node) as usize;
        if let Some((_, i)) = self.by_node.lock().ok().and_then(|m| m.get(&addr).cloned()) {
            return Ok(i);
        }
        let r = reference_node(node).ok_or_else(|| InstanceError::Unknown(node.op.clone()))?;
        let i = self.instance(&r)?;
        if let Ok(mut m) = self.by_node.lock() {
            m.insert(addr, (Arc::clone(node), Arc::clone(&i)));
        }
        Ok(i)
    }

    /// Every instance `roots` reach, each once: the references in `roots`
    /// and, through each instance body, the references it holds. Stops at the
    /// first reference that names no instance.
    pub fn reachable<'a>(
        &self,
        roots: impl IntoIterator<Item = &'a Expr>,
    ) -> Result<Vec<Arc<CallInstance>>, InstanceError> {
        let mut seen: HashSet<usize> = HashSet::new();
        let mut out = Vec::new();
        let mut stack: Vec<Expr> = roots.into_iter().cloned().collect();
        stack.reverse();
        while let Some(e) = stack.pop() {
            let mut found: Vec<Arc<CallInstance>> = Vec::new();
            let mut err = None;
            for_each_reference(&e, &mut |r| {
                if err.is_none() {
                    match self.instance(&r) {
                        Ok(i) => found.push(i),
                        Err(x) => err = Some(x),
                    }
                }
            });
            if let Some(x) = err {
                return Err(x);
            }
            for i in found.into_iter().rev() {
                if seen.insert(Arc::as_ptr(&i) as usize) {
                    stack.push(i.body.clone());
                    out.push(i);
                }
            }
        }
        Ok(out)
    }
}

impl crate::EsmFile {
    /// The operator registry of component `component` (`"models.<name>"` or
    /// `"reaction_systems.<name>"`), as load materialized it (esm-spec §9.6.4
    /// rule 5: the entries it authors, then the closure of what its references
    /// name). The references in that component's expressions resolve against
    /// it. Empty when the component has no registry.
    pub fn component_operators(&self, component: &str) -> OperatorRegistry {
        self.component_templates
            .as_ref()
            .and_then(|ct| ct.get(component))
            .and_then(Value::as_object)
            .map(OperatorRegistry::from_json)
            .unwrap_or_default()
    }
}

impl crate::FlattenedSystem {
    /// The flattened system's merged operator registry, typed (esm-spec §9.6.4
    /// rule 7): every reference in the flattened equations, initial
    /// conditions, events and variable fields resolves against it, and every
    /// body in it is closed (it reads only its parameters).
    pub fn operators(&self) -> OperatorRegistry {
        OperatorRegistry::from_json(self.template_registry.iter())
    }
}

/// Where a walk that reads through references is: inside the body of a
/// definition a reference names, each parameter standing for the
/// reference's binding, read in the frame the reference sits in (the root
/// frame is a call site). A walk enters a body in a new frame
/// ([`Frame::enter`]) and resolves a parameter leaf through it
/// ([`Frame::leaf`]): the walk reads exactly what the expansion holds at that
/// position, and nothing is substituted. Frames are cheap to clone.
#[derive(Debug, Clone, Default)]
pub struct Frame(Option<Rc<FrameInner>>);

#[derive(Debug)]
struct FrameInner {
    bindings: HashMap<String, (Expr, Frame)>,
}

impl Frame {
    /// The frame of a call site.
    pub fn root() -> Frame {
        Frame(None)
    }

    /// The frame of the body of `def`, entered through the reference `r`
    /// read in `self`: each parameter stands for its binding, read in `self`.
    pub fn enter(&self, r: &Reference<'_>, def: &Definition) -> Frame {
        let bindings = def
            .params
            .iter()
            .filter_map(|p| r.binding(p).map(|b| (p.clone(), (b.clone(), self.clone()))))
            .collect();
        Frame(Some(Rc::new(FrameInner { bindings })))
    }

    /// The variable leaf `name` read in this frame: a parameter reads as its
    /// binding in the binding's own frame, followed through parameters bound
    /// to bare names; any other name is itself, in this frame.
    pub fn leaf(&self, name: &str) -> (Expr, Frame) {
        let mut frame = self.clone();
        let mut name = name.to_string();
        loop {
            let got = frame
                .0
                .as_ref()
                .and_then(|f| f.bindings.get(&name))
                .cloned();
            let Some((x, f)) = got else {
                return (Expr::Variable(name), frame);
            };
            match x {
                Expr::Variable(v) => {
                    name = v;
                    frame = f;
                }
                other => return (other, f),
            }
        }
    }

    /// An identity for this frame, for memo keys (`0` for the root).
    pub fn id(&self) -> usize {
        self.0.as_ref().map_or(0, |f| Rc::as_ptr(f) as usize)
    }
}

impl OperatorRegistry {
    /// Visit every operator node `e` holds, read in `frame`, walking
    /// through references into the bodies of the definitions they name
    /// (each in its own [`Frame`]) and through parameter leaves into the
    /// bindings they stand for. A reference node itself is visited before its
    /// body; `f` returning `false` stops the walk below that node. Each node
    /// is visited once per frame. A reference to a definition the registry
    /// does not hold is visited but not entered.
    pub fn walk_through(
        &self,
        e: &Expr,
        frame: &Frame,
        f: &mut impl FnMut(&Arc<ExpressionNode>, &Frame) -> bool,
    ) {
        let mut seen = HashSet::new();
        self.walk_rec(e, frame, f, &mut seen);
    }

    fn walk_rec(
        &self,
        e: &Expr,
        frame: &Frame,
        f: &mut impl FnMut(&Arc<ExpressionNode>, &Frame) -> bool,
        seen: &mut HashSet<(usize, usize)>,
    ) {
        match e {
            Expr::Variable(v) => {
                let (x, fr) = frame.leaf(v);
                if !matches!(x, Expr::Variable(_)) {
                    self.walk_rec(&x, &fr, f, seen);
                }
            }
            Expr::Operator(node) => {
                if !seen.insert((Arc::as_ptr(node) as usize, frame.id())) {
                    return;
                }
                if !f(node, frame) {
                    return;
                }
                if let Some(r) = reference_node(node) {
                    if let Some(def) = self.resolve(&r)
                        && let Some(body) = &def.body
                    {
                        let inner = frame.enter(&r, def);
                        self.walk_rec(body, &inner, f, seen);
                    }
                    return;
                }
                node.for_each_child(&mut |c| self.walk_rec(c, frame, f, seen));
            }
            _ => {}
        }
    }

    /// The expression a reference read in `frame` denotes at its root, when
    /// that is an operator node: its definition's body, through references
    /// the body is and parameters bound to references, with the frame it is
    /// read in. `None` for a definition the registry does not hold.
    pub fn denoted_root(&self, node: &ExpressionNode, frame: &Frame) -> Option<(Expr, Frame)> {
        self.denoted_root_at(node, frame, 0)
    }

    fn denoted_root_at(
        &self,
        node: &ExpressionNode,
        frame: &Frame,
        depth: usize,
    ) -> Option<(Expr, Frame)> {
        if depth > 64 {
            return None;
        }
        let r = reference_node(node)?;
        let def = self.resolve(&r)?;
        let mut fr = frame.enter(&r, def);
        let mut x = def.body.clone()?;
        loop {
            match &x {
                Expr::Variable(v) => {
                    let (y, f2) = fr.leaf(v);
                    if matches!(y, Expr::Variable(_)) {
                        return Some((y, f2));
                    }
                    x = y;
                    fr = f2;
                }
                Expr::Operator(n) if n.op == APPLY_OP => {
                    return self.denoted_root_at(n, &fr, depth + 1);
                }
                _ => return Some((x, fr)),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn reg(v: Value) -> OperatorRegistry {
        OperatorRegistry::from_json(v.as_object().unwrap())
    }

    #[test]
    fn roles_callees_and_reach() {
        let r = reg(json!({
            "lap": {"params": ["u", "d"], "body": {"op": "D", "args": [{"op": "D", "args": ["u"], "wrt": "d"}], "wrt": "d"}},
            "twice": {"params": ["x"], "body": {"op": "apply_operator", "args": [], "name": "lap",
                "bindings": {"u": "x", "d": "x"}}},
            "sum": {"params": ["a"], "body": {"op": "faq", "args": [], "output_idx": [],
                "ranges": {"k": {"from": "a"}}, "expr": {"op": "index", "args": ["v", "k"]}}}
        }));
        let lap = r.get("lap").unwrap();
        assert!(lap.param_roles()["u"].operand);
        assert!(lap.param_roles()["d"].literal && !lap.param_roles()["d"].operand);
        let twice = r.get("twice").unwrap();
        assert_eq!(twice.callees(), ["lap"]);
        assert!(twice.param_roles()["x"].forwarded);
        let sum = r.get("sum").unwrap();
        assert!(sum.is_literal_param("a"));
        assert!(sum.body_binders().contains("k"));
        assert_eq!(sum.free_names().iter().collect::<Vec<_>>(), ["v"]);
        let e: Expr = serde_json::from_value(json!({"op": "+", "args": [
            {"op": "apply_operator", "args": [], "name": "twice", "bindings": {"x": "y"}}, 1]}))
        .unwrap();
        let reached: Vec<_> = r.reachable([&e]).into_iter().collect();
        assert_eq!(reached, ["twice", "lap"]);
        assert!(has_reference(&e));
    }

    #[test]
    fn a_parameter_named_range_bound_parses() {
        let r = reg(json!({
            "argmin": {"params": ["v", "n"], "body": {"op": "faq", "args": [], "output_idx": [],
                "ranges": {"k": [1, "n"]}, "reduce": "min", "expr": {"op": "index", "args": ["v", "k"]}}}
        }));
        let d = r.get("argmin").unwrap();
        assert!(d.body.is_some());
        assert!(d.is_literal_param("n"));
        assert!(d.param_roles()["v"].operand);
        let back = serde_json::to_value(d.body.as_ref().unwrap()).unwrap();
        assert_eq!(back["ranges"]["k"], json!([1, "n"]));
    }

    #[test]
    fn reads_instances_and_site_reads() {
        let r = reg(json!({
            "total": {"params": ["v", "S"], "body": {"op": "faq", "args": ["v"], "output_idx": [],
                "reduce": "+", "ranges": {"k": {"from": "S"}},
                "expr": {"op": "*", "args": [{"op": "index", "args": ["v", "k"]}, "w"]}}},
            "first": {"params": ["v", "n"], "body": {"op": "faq", "args": ["v"], "output_idx": [],
                "reduce": "+", "ranges": {"k": [1, "n"]}, "expr": {"op": "index", "args": ["v", "k"]}}},
            "outer": {"params": ["a", "T"], "body": {"op": "apply_operator", "args": [], "name": "total",
                "bindings": {"v": "a", "S": "T"}}},
            "pd": {"params": ["f", "x"], "match": {"op": "partial", "args": ["f"], "wrt": "x"},
                "body": {"op": "*", "args": [2, "f"]}}
        }));
        let total = r.get("total").unwrap();
        let reads = total.reads(&r);
        // `S` is a literal (an index-set name), `w` a free name, `k` a loop symbol.
        assert_eq!(reads.params.iter().collect::<Vec<_>>(), ["v"]);
        assert_eq!(reads.free.iter().collect::<Vec<_>>(), ["w"]);
        assert!(reads.binders.contains("k") && reads.index_subscripts.contains("k"));
        let outer = r.get("outer").unwrap().reads(&r);
        assert_eq!(outer.params.iter().collect::<Vec<_>>(), ["a"]);
        assert_eq!(outer.free.iter().collect::<Vec<_>>(), ["w"]);
        // A ranges bound naming a param is read off the wire.
        assert_eq!(
            r.get("first")
                .unwrap()
                .reads(&r)
                .params
                .iter()
                .collect::<Vec<_>>(),
            ["v"]
        );

        let e: Expr = serde_json::from_value(json!({"op": "+", "args": [
            {"op": "apply_operator", "args": [], "name": "outer", "bindings": {"a": "y", "T": "cells"}},
            {"op": "apply_operator", "args": [], "name": "first", "bindings": {"v": "y", "n": 3}}]}))
        .unwrap();
        assert_eq!(
            site_reads(&e, &r).into_iter().collect::<Vec<_>>(),
            ["w", "y"]
        );
        let insts = r.instances([&e]);
        let names: Vec<_> = insts.iter().map(|i| i.definition.name.as_str()).collect();
        assert_eq!(names, ["outer", "total", "first"]);
        // The literal `cells` reached `total` through `outer`'s forwarded `T`.
        assert_eq!(
            insts[1].literals.get("S").map(String::as_str),
            Some("cells")
        );
        let body = serde_json::to_value(&insts[1].body).unwrap();
        assert_eq!(body["ranges"]["k"]["from"], "cells");
        assert_eq!(body["expr"]["args"][0]["args"][0], "v");
        let body = serde_json::to_value(&insts[2].body).unwrap();
        assert_eq!(body["ranges"]["k"], json!([1, 3]));
        // Made once per instance.
        assert!(Arc::ptr_eq(&insts[1], &r.instances([&e])[1]));
        // The fixed unit of a `partial` rule, read off its `match`.
        let fixed =
            serde_json::to_value(r.get("pd").unwrap().fixed_units.as_ref().unwrap()).unwrap();
        assert_eq!(fixed, json!({"op": "/", "args": ["f", "x"]}));
    }

    #[test]
    fn memo_analyses_once() {
        let m: InstanceMemo<u8, usize> = InstanceMemo::new();
        let mut calls = 0;
        for _ in 0..3 {
            m.get_or_compute("lap", &1, || {
                calls += 1;
                7
            });
        }
        assert_eq!(calls, 1);
        assert_eq!(m.len(), 1);
    }

    #[test]
    fn instances_specialize_literal_params_once() {
        let r = reg(json!({
            "sum_to": {"params": ["v", "n"], "body": {"op": "faq", "args": [], "output_idx": [],
                "ranges": {"k": [1, "n"]}, "expr": {"op": "index", "args": ["v", "k"]}}},
            "outer": {"params": ["w", "m"], "body": {"op": "apply_operator", "args": [],
                "name": "sum_to", "bindings": {"v": "w", "n": "m"}}}
        }));
        // `n` sits in a range bound; `m` is forwarded into it.
        assert_eq!(r.instance_params("sum_to"), ["n"]);
        assert_eq!(r.instance_params("outer"), ["m"]);
        assert!(r.captured_symbols("outer").contains("k"));
        let inst = Instances::new(r);
        let call = |n: i64| -> Expr {
            serde_json::from_value(json!({"op": "apply_operator", "args": [], "name": "outer",
                "bindings": {"w": "x", "m": n}}))
            .unwrap()
        };
        let (a, b, c) = (call(3), call(3), call(4));
        let ia = inst.instance(&reference(&a).unwrap()).unwrap();
        let ib = inst.instance(&reference(&b).unwrap()).unwrap();
        let ic = inst.instance(&reference(&c).unwrap()).unwrap();
        assert!(Arc::ptr_eq(&ia, &ib));
        assert!(!Arc::ptr_eq(&ia, &ic));
        // The forwarded literal reached the nested reference; `w` stays a name.
        let nested = reference(&ia.body).unwrap();
        assert_eq!(nested.binding("n"), Some(&Expr::Integer(3)));
        assert_eq!(nested.binding("v"), Some(&Expr::Variable("w".into())));
        let reached = inst.reachable([&a]).unwrap();
        assert_eq!(reached.len(), 2);
    }
}
