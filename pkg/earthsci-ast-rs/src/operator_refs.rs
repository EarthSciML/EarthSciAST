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
    wire_literals: OnceLock<HashSet<String>>,
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
        let parse = |v: Option<&Value>| v.and_then(|b| serde_json::from_value::<Expr>(b.clone()).ok());
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
            wire_literals: OnceLock::new(),
        }
    }

    /// Every loop symbol the wire body binds anywhere
    /// ([`Self::body_binders`], read off the wire so a body that is no typed
    /// Expression has them too).
    fn body_binders_wire(&self) -> Vec<String> {
        fn walk(v: &Value, out: &mut Vec<String>) {
            match v {
                Value::Array(a) => a.iter().for_each(|x| walk(x, out)),
                Value::Object(m) => {
                    if m.get("op").is_some() {
                        out.extend(wire_binders(m));
                    }
                    m.values().for_each(|x| walk(x, out));
                }
                _ => {}
            }
        }
        let mut out = Vec::new();
        if let Some(b) = self.wire_body() {
            walk(b, &mut out);
        }
        out
    }

    /// The body on the wire, if the entry has one.
    fn wire_body(&self) -> Option<&Value> {
        self.raw.get("body").filter(|b| !b.is_null())
    }

    /// The params spelled in a literal position of the body on the wire (any
    /// string that is not an Expression leaf: a scalar field, a `ranges` bound
    /// or `from`, a region bound, an `enum` argument). Read from the wire
    /// because a body whose `ranges` bound names a param (`[1, "n"]`) is no
    /// typed Expression until that bound is a literal.
    fn literal_params(&self) -> &HashSet<String> {
        self.wire_literals.get_or_init(|| {
            let params: HashSet<&str> = self.params.iter().map(String::as_str).collect();
            let mut out = HashSet::new();
            if let Some(b) = self.wire_body() {
                wire_walk(b, true, &mut |s, expr_pos| {
                    if !expr_pos && params.contains(s) {
                        out.insert(s.to_string());
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
                binders: self.body_binders_wire().into_iter().collect(),
                ..Default::default()
            };
            if let Some(body) = self.wire_body() {
                wire_index_subscripts(body, registry, &mut out.index_subscripts);
            }
            if let Some(body) = self.wire_body() {
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
    pub fn instance_literals(&self, r: &Reference<'_>, outer: &InstanceLiterals) -> InstanceLiterals {
        let mut out = InstanceLiterals::new();
        for p in &self.params {
            if !self.is_literal_param(p) && !self.literal_params().contains(p) {
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
        if literals.is_empty() {
            return self.body.clone();
        }
        let mut wire = self.wire_body()?.clone();
        specialize(&mut wire, literals, true);
        serde_json::from_value(wire).ok()
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
    for s in [&node.wrt, &node.dim, &node.int_var, &node.reduce, &node.semiring, &node.broadcast_fn]
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

/// The loop symbols a wire node binds (`ranges` keys, `output_idx` entries,
/// an `integral`'s `var`).
fn wire_binders(m: &serde_json::Map<String, Value>) -> Vec<String> {
    let mut out = Vec::new();
    if let Some(Value::Object(r)) = m.get("ranges") {
        out.extend(r.keys().cloned());
    }
    if let Some(Value::Array(o)) = m.get("output_idx") {
        out.extend(o.iter().filter_map(Value::as_str).map(str::to_string));
    }
    if let Some(Value::String(v)) = m.get("var") {
        out.push(v.clone());
    }
    out
}

/// Whether the field `k` of a node with op `op` holds Expressions.
fn wire_expr_field(op: &str, k: &str) -> bool {
    match k {
        "args" => op != "enum",
        "values" | "lower" | "upper" | "expr" | "filter" | "key" => true,
        "bindings" => op == APPLY_OP,
        _ => false,
    }
}

/// Call `f` on every string of a wire body with whether it sits in an
/// Expression position (a variable leaf) or a literal one.
fn wire_walk(v: &Value, expr_pos: bool, f: &mut impl FnMut(&str, bool)) {
    match v {
        Value::String(s) => f(s, expr_pos),
        Value::Array(a) => a.iter().for_each(|x| wire_walk(x, expr_pos, f)),
        Value::Object(m) => {
            let Some(op) = m.get("op").and_then(Value::as_str) else {
                m.values().for_each(|x| wire_walk(x, false, f));
                return;
            };
            for (k, x) in m {
                match k.as_str() {
                    "op" | "value" | "units" | "description" => {}
                    "name" if op == APPLY_OP => {}
                    "bindings" if op == APPLY_OP => {
                        if let Value::Object(b) = x {
                            b.values().for_each(|y| wire_walk(y, true, f));
                        }
                    }
                    _ => wire_walk(x, wire_expr_field(op, k), f),
                }
            }
        }
        _ => {}
    }
}

/// The bare `index` subscripts of a wire body and of the bodies it
/// references ([`DefinitionReads::index_subscripts`]).
fn wire_index_subscripts(v: &Value, registry: &OperatorRegistry, out: &mut BTreeSet<String>) {
    match v {
        Value::Array(a) => a.iter().for_each(|x| wire_index_subscripts(x, registry, out)),
        Value::Object(m) => {
            let op = m.get("op").and_then(Value::as_str);
            if op == Some("index")
                && let Some(Value::Array(args)) = m.get("args")
            {
                out.extend(args.iter().skip(1).filter_map(Value::as_str).map(str::to_string));
            }
            if op == Some(APPLY_OP)
                && let Some(d) = m.get("name").and_then(Value::as_str).and_then(|n| registry.get(n))
            {
                out.extend(d.reads(registry).index_subscripts.iter().cloned());
            }
            m.values().for_each(|x| wire_index_subscripts(x, registry, out));
        }
        _ => {}
    }
}

/// Walk a wire body for [`DefinitionReads`]. `bound` holds the loop symbols
/// in scope (the body's own, and those of the bodies a binding is read in).
fn body_reads(
    v: &Value,
    params: &HashSet<&str>,
    registry: &OperatorRegistry,
    bound: &mut Vec<String>,
    out: &mut DefinitionReads,
) {
    let leaf = |n: &str, bound: &Vec<String>, out: &mut DefinitionReads| {
        if bound.iter().any(|b| b == n) {
            return;
        }
        if params.contains(n) {
            out.params.insert(n.to_string());
        } else if !n.starts_with('\0') {
            out.free.insert(n.to_string());
        }
    };
    match v {
        Value::String(n) => leaf(n, bound, out),
        Value::Array(a) => a.iter().for_each(|x| body_reads(x, params, registry, bound, out)),
        Value::Object(m) => {
            let Some(op) = m.get("op").and_then(Value::as_str) else {
                return;
            };
            let bindings = m.get("bindings").and_then(Value::as_object);
            if op == APPLY_OP {
                let callee = m
                    .get("name")
                    .and_then(Value::as_str)
                    .and_then(|n| registry.get(n));
                let Some(bindings) = bindings else { return };
                match callee {
                    Some(callee) => {
                        let cr = callee.reads(registry);
                        for n in &cr.free {
                            if !bound.iter().any(|b| b == n) {
                                out.free.insert(n.clone());
                            }
                        }
                        let depth = bound.len();
                        bound.extend(cr.binders.iter().cloned());
                        let mut keys: Vec<&String> = bindings.keys().collect();
                        keys.sort();
                        for k in keys.into_iter().filter(|k| cr.params.contains(*k)) {
                            body_reads(&bindings[k], params, registry, bound, out);
                        }
                        bound.truncate(depth);
                    }
                    // An unresolved reference (the load's checks report it):
                    // every binding counts as read.
                    None => bindings
                        .values()
                        .for_each(|b| body_reads(b, params, registry, bound, out)),
                }
                return;
            }
            let depth = bound.len();
            bound.extend(wire_binders(m));
            for (k, x) in m {
                if wire_expr_field(op, k) {
                    body_reads(x, params, registry, bound, out);
                }
            }
            bound.truncate(depth);
        }
        _ => {}
    }
}

/// [`Definition::instance_body`]'s walk over the wire body: every string in a
/// literal position that names a literal param becomes its literal (a number
/// where it is numeric, so a `ranges` bound `[1, "n"]` becomes `[1, 4]`).
fn specialize(v: &mut Value, lits: &InstanceLiterals, expr_pos: bool) {
    match v {
        Value::String(s) => {
            if !expr_pos && let Some(l) = lits.get(s.as_str()) {
                *v = match l.parse::<i64>() {
                    Ok(i) => Value::from(i),
                    Err(_) => Value::String(l.clone()),
                };
            }
        }
        Value::Array(a) => a.iter_mut().for_each(|x| specialize(x, lits, expr_pos)),
        Value::Object(m) => {
            let Some(op) = m.get("op").and_then(Value::as_str).map(str::to_string) else {
                m.values_mut().for_each(|x| specialize(x, lits, false));
                return;
            };
            for (k, x) in m.iter_mut() {
                match k.as_str() {
                    "op" | "value" | "units" | "description" => {}
                    "name" if op == APPLY_OP => {}
                    "bindings" if op == APPLY_OP => {
                        if let Value::Object(b) = x {
                            b.values_mut().for_each(|y| specialize(y, lits, true));
                        }
                    }
                    // A scalar field holds a name, never a number.
                    "wrt" | "dim" | "var" | "reduce" | "semiring" | "fn" => {
                        if let Value::String(s) = x
                            && let Some(l) = lits.get(s.as_str())
                        {
                            *s = l.clone();
                        }
                    }
                    _ => specialize(x, lits, wire_expr_field(&op, k)),
                }
            }
        }
        _ => {}
    }
}

/// A registry of operator definitions: a component's (§9.6.4 rule 5) or a
/// flattened system's merged one (rule 7), in registry order. Cheap to clone.
#[derive(Debug, Clone, Default)]
pub struct OperatorRegistry {
    entries: Arc<IndexMap<String, Arc<Definition>>>,
    instances: Arc<std::sync::Mutex<HashMap<(String, InstanceLiterals), Arc<Instance>>>>,
}

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
                found.push((Arc::clone(d), d.instance_literals(&r, outer)));
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
        if let Some(i) = self.instances.lock().ok().and_then(|m| m.get(&key).cloned()) {
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
            {"op": "apply_operator", "args": [], "name": "twice", "bindings": {"x": "y"}}, 1]})).unwrap();
        let reached: Vec<_> = r.reachable([&e]).into_iter().collect();
        assert_eq!(reached, ["twice", "lap"]);
        assert!(has_reference(&e));
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
}
