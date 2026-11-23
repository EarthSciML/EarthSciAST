use super::*;
use crate::json_visit::JsonPath;
/// Pointer-keyed identity set for seen-pruned walks over shared DAGs. Retains
/// an `Rc` handle to every member for the same reason [`PtrMemo`] does: a freed
/// node's address can be recycled by a later allocation, and a false "already
/// seen" hit would silently prune an unvisited subtree from a validating walk.
#[derive(Default)]
pub(super) struct PtrSet {
    set: std::collections::HashMap<*const SNode, Sv>,
}

impl PtrSet {
    /// Insert `node`; returns `true` if it was not already present.
    pub(super) fn insert(&mut self, node: &Sv) -> bool {
        self.set.insert(Rc::as_ptr(node), node.clone()).is_none()
    }
}
/// True iff `node` contains, anywhere within it, an object whose `op`
/// satisfies `pred`. [`direct_t_op`] is this with the tier-**T** predicate.
fn direct_op(node: &Sv, seen: &mut PtrSet, pred: &dyn Fn(&str) -> bool) -> bool {
    match &**node {
        SNode::Arr(items) => {
            if !seen.insert(node) {
                return false;
            }
            items.iter().any(|c| direct_op(c, seen, pred))
        }
        SNode::Obj(fields) => {
            if !seen.insert(node) {
                return false;
            }
            if let Some(op) = obj_op(fields)
                && pred(op)
            {
                return true;
            }
            fields.iter().any(|(_, v)| direct_op(v, seen, pred))
        }
        _ => false,
    }
}

/// Collect the `name`s of every `apply_expression_template` node in a shared
/// DAG (document order), seen-pruned.
pub(super) fn collect_apply_names_sv(node: &Sv, out: &mut Vec<String>, seen: &mut PtrSet) {
    match &**node {
        SNode::Arr(items) => {
            if !seen.insert(node) {
                return;
            }
            for c in items {
                collect_apply_names_sv(c, out, seen);
            }
        }
        SNode::Obj(fields) => {
            if !seen.insert(node) {
                return;
            }
            if obj_op(fields) == Some(APPLY_OP)
                && let Some(SNode::Str(nm)) = obj_get(fields, "name").map(|v| &**v)
            {
                out.push(nm.clone());
            }
            for (_, v) in fields {
                collect_apply_names_sv(v, out, seen);
            }
        }
        _ => {}
    }
}

/// Template name → decl object (shared node) registry.
pub(super) type Named = std::collections::HashMap<String, Sv>;

/// The `body` field of a template decl, or `Null` when absent.
pub(super) fn decl_body(decl: &Sv) -> Sv {
    match &**decl {
        SNode::Obj(fields) => obj_get(fields, "body")
            .cloned()
            .unwrap_or_else(|| Rc::new(SNode::Null)),
        _ => Rc::new(SNode::Null),
    }
}

/// True iff `decl` (a template decl node) carries a `match` field.
pub(super) fn decl_has_match(decl: &Sv) -> bool {
    matches!(&**decl, SNode::Obj(fields) if obj_get(fields, "match").is_some())
}

/// Generic transitive-reachability over the `apply_expression_template`
/// body-reference DAG, behind [`enum_bearing_templates`]. For every template in `named` the flag is
/// `true` iff `direct_pred` holds on the template's own body, OR —
/// transitively through the §9.7.3-checked acyclic reference DAG — the template
/// reaches another template whose body satisfies `direct_pred`. Memoized DFS
/// with a defensive in-progress guard against any cycle the checker somehow
/// missed, so it terminates on every input. `direct_pred` inspects only a
/// single body (no ref-following); the transitive step is this walk.
pub(super) fn transitive_reachable(
    named: &Named,
    direct_pred: impl Fn(&Sv) -> bool,
) -> std::collections::HashMap<String, bool> {
    fn visit(
        name: &str,
        named: &Named,
        flag: &mut std::collections::HashMap<String, bool>,
        inprogress: &mut std::collections::HashSet<String>,
        direct_pred: &impl Fn(&Sv) -> bool,
    ) -> bool {
        if let Some(v) = flag.get(name) {
            return *v;
        }
        // Defensive against a cycle the checker somehow missed.
        if inprogress.contains(name) {
            return false;
        }
        let Some(decl) = named.get(name) else {
            flag.insert(name.to_string(), false);
            return false;
        };
        inprogress.insert(name.to_string());
        let body = decl_body(decl);
        let mut res = direct_pred(&body);
        if !res {
            let mut refs = Vec::new();
            collect_apply_names_sv(&body, &mut refs, &mut PtrSet::default());
            for r in refs {
                if named.contains_key(&r) && visit(&r, named, flag, inprogress, direct_pred) {
                    res = true;
                    break;
                }
            }
        }
        inprogress.remove(name);
        flag.insert(name.to_string(), res);
        res
    }
    let mut flag: std::collections::HashMap<String, bool> = std::collections::HashMap::new();
    let mut inprogress: std::collections::HashSet<String> = std::collections::HashSet::new();
    for name in named.keys() {
        visit(name, named, &mut flag, &mut inprogress, &direct_pred);
    }
    flag
}

/// For every template in `templates`, whether its body can still produce an
/// `enum` op: one written in its own body (anywhere, including inside nested
/// references' `bindings`), or in a template it references, transitively. The
/// template import edge uses this to find the library calls that bind an
/// `enum` parameter (esm-spec §9.3, §9.7.5). Mirrors the Julia reference
/// `_transitive_op_flags(named, op -> op == "enum")`.
pub(crate) fn enum_bearing_templates(
    templates: &Map<String, Value>,
) -> std::collections::HashMap<String, bool> {
    let named = build_named(templates);
    let is_enum = |op: &str| op == "enum";
    transitive_reachable(&named, |body| {
        direct_op(body, &mut PtrSet::default(), &is_enum)
    })
}

/// Maximum number of productive rewrite passes before a file is rejected as
/// non-converging (esm-spec §9.6.3, diagnostic `rewrite_rule_nonterminating`).
/// Pinned identically across all bindings so the accept/reject decision — and
/// the resulting fixpoint — is byte-identical everywhere.
pub(super) const MAX_REWRITE_PASSES: usize = 64;

/// An auto-applied rewrite rule: an `expression_templates` entry that carries
/// a `match` pattern (esm-spec §9.6). Named templates *without* a `match` are
/// expanded only by explicit `apply_expression_template`; those with a `match`
/// fire wherever the pattern structurally matches a node.
#[derive(Clone)]
struct MatchRule {
    /// Template id (for diagnostics).
    name: String,
    /// Metavariable names (wildcards in `pattern`, slots in `body`), as a
    /// set for O(1) membership checks in `try_match` — precomputed once at
    /// registration ([`collect_match_rules`]) instead of per rule per node.
    param_set: std::collections::HashSet<String>,
    /// `params` in declared order: the keys of the reference a firing writes
    /// (esm-spec §9.6.3 constraint 7).
    param_list: Vec<String>,
    /// The pattern Expression a node is matched against. Patterns are small
    /// and never composed, so the owned view is kept.
    pattern: Value,
    /// The rule's RAW (uninlined, Option B) body as a shared DAG: only its
    /// shape matters to a firing (a leaf body is written as the leaf).
    body: Sv,
    /// Selection precedence (esm-spec §9.6.3): higher fires first; ties break by
    /// declaration order. Absent ⇒ `0`.
    priority: i64,
    /// Registered static match-scoping constraints (esm-spec §9.6.1): param →
    /// required shape (ordered index-set names). `None` when the rule carries
    /// no `where` block. Checked as part of match eligibility.
    where_c: Option<std::collections::BTreeMap<String, Vec<String>>>,
    /// The definition's position in its block (1-based), the last component
    /// of the §9.6.3 selection key.
    decl_index: usize,
}

impl MatchRule {
    /// The §9.6.3 selection key: highest `priority` first, then a definition
    /// carrying a `where` before one without (esm 2.4.0), then declaration
    /// order. Mirrors the Julia reference `_selection_key`.
    fn selection_key(&self) -> (std::cmp::Reverse<i64>, u8, usize) {
        (
            std::cmp::Reverse(self.priority),
            u8::from(self.where_c.is_none()),
            self.decl_index,
        )
    }
}

/// Is `op` a core operator (esm-spec §4.2: the closed, evaluable set every
/// binding's evaluator implements)? Every other `op` names a defined operator,
/// given by definitions (§9.6.12). The reference node `apply_operator` is
/// neither: it names a definition, not an operator. Mirrors the Julia
/// reference `_is_core_op`.
pub(crate) fn is_core_operator(op: &str) -> bool {
    op != APPLY_OP && crate::op_registry::CoreOp::from_name(op).is_some()
}

/// The root `op` of a definition's `match`, when it is a string.
pub(super) fn match_root_op(decl: &Map<String, Value>) -> Option<&str> {
    decl.get("match")?.as_object()?.get("op")?.as_str()
}

/// The defined operator an `operators` entry is a definition of (esm-spec
/// §9.6.1 `defines`): its written `defines`; else the root `op` of its `match`
/// when that is not a core operator; else its key. Mirrors the Julia reference
/// `_definition_defines`.
pub(crate) fn definition_defines(name: &str, decl: &Value) -> String {
    let Some(obj) = decl.as_object() else {
        return name.to_string();
    };
    if let Some(d) = obj.get("defines").and_then(Value::as_str) {
        return d.to_string();
    }
    match match_root_op(obj) {
        Some(r) if !is_core_operator(r) => r.to_string(),
        _ => name.to_string(),
    }
}

/// esm-spec §9.6.12 "Core names are reserved": a definition whose `defines`,
/// written or inferred, is a core operator's name is
/// `operator_defines_core_op`. A rule whose `match` is rooted at a core
/// operator defines no callable name, so its `defines` is provenance only and
/// is not checked. Mirrors the Julia reference `_check_defines_not_core`.
fn check_defines_not_core(
    name: &str,
    decl: &Value,
    scope: &str,
) -> Result<(), ExpressionTemplateError> {
    // A `reference_only` definition is reached by no call (esm-spec §9.6.1).
    if is_reference_only(decl) {
        return Ok(());
    }
    if let Some(obj) = decl.as_object()
        && match_root_op(obj).is_some_and(is_core_operator)
    {
        return Ok(());
    }
    let d = definition_defines(name, decl);
    if is_core_operator(&d) {
        return Err(err(
            codes::OPERATOR_DEFINES_CORE_OP,
            format!(
                "{scope}.operators.{name}: defines the core operator '{d}'; a definition may \
                 not define a core operator's name (esm-spec §9.6.12, \"Core names are \
                 reserved\")"
            ),
        ));
    }
    Ok(())
}

/// Whether an `operators` entry is `reference_only` (esm-spec §9.6.1): reached
/// by explicit references only, never by a call of the operator it defines.
pub(crate) fn is_reference_only(decl: &Value) -> bool {
    decl.get("reference_only") == Some(&Value::Bool(true))
}

/// Whether a node is a call shape a match-less definition can bind: an `op`
/// and `args`, no other field (esm-spec §9.6.3 constraint 2).
fn only_op_args(fields: &[(String, Sv)]) -> bool {
    fields.iter().all(|(k, _)| k == "op" || k == "args")
}

/// How the rewrite engine sees a template body it rewrites for one template
/// instance (esm-spec §9.6.4 rule 3): `params` — the template's parameters,
/// each a leaf; `lit` — the literal the instance binds to each parameter in a
/// structural position (a scalar field, a `ranges` bound or `from`, an `enum`
/// argument); `entries` — each parameter's instance entry
/// ([`instance_entry`]), which a `where` `shape` constraint reads. Mirrors the
/// Julia reference `_BodyView`.
pub(super) struct BodyView {
    pub(super) params: std::collections::HashSet<String>,
    pub(super) lit: std::collections::HashMap<String, Sv>,
    pub(super) entries: std::collections::HashMap<String, String>,
}

/// One component's rewrite state (esm-spec §9.6.3, §9.6.4 rule 3): `named` —
/// every template declaration keyed by name (the registry references resolve
/// against; rule 3 adds its variants here); `rules` — the auto-applied rules
/// pre-sorted into §9.6.3 selection order; `shape_env` — the component's static
/// shape environment for `where` constraints; `enums` — the document's `enums`
/// block, for the per-instance `enum` lowering of rule 3; `depth` — the rewrite
/// depth of each reference a firing wrote (the pass that wrote it), by node
/// identity; a reference the author wrote has depth 0 and no entry. This is
/// also everything needed to rewrite a coupling `variable_map` transform
/// against the RECEIVING component (esm-spec §10.4). Mirrors the Julia
/// reference `_Lowering`.
pub(super) struct Lowering {
    pub(super) named: Named,
    rules: Vec<MatchRule>,
    /// Match-less definitions by the defined operator they define, each list
    /// in §9.6.3 selection order (esm 2.4.0: a call of a defined operator by
    /// name resolves to one of its definitions).
    call_rules: std::collections::HashMap<String, Vec<MatchRule>>,
    /// The operand count each definition of each defined operator takes,
    /// with the definition's name (esm-spec §9.6.12 "Arity").
    arities: Arities,
    /// The owners of the entries subsystems brought ([`Owners`]).
    owners: Owners,
    /// The subsystem paths (`""`: the component itself) whose positions the
    /// rewrite is at: a definition resolves a call, and counts for its
    /// arity, only when one of its owners encloses one of them.
    call_scope: std::cell::RefCell<Vec<String>>,
    shape_env: std::collections::BTreeMap<String, Vec<String>>,
    pub(super) enums: Option<Value>,
    pub(super) scope: String,
    depth: std::cell::RefCell<PtrMemo<usize>>,
}

/// Per defined operator, the operand count each of its definitions takes and
/// the definition's name.
type Arities = std::collections::HashMap<String, Vec<(usize, String)>>;

impl Lowering {
    /// The rewrite depth recorded for the reference `n` (the pass that wrote
    /// it), or `None` for a reference the author wrote.
    pub(super) fn depth_of(&self, n: &Sv) -> Option<usize> {
        self.depth.borrow().get(n).copied()
    }

    fn set_depth(&self, n: &Sv, d: usize) {
        self.depth.borrow_mut().insert(n, d);
    }

    /// The component's static shape environment.
    pub(super) fn shape_env(&self) -> &std::collections::BTreeMap<String, Vec<String>> {
        &self.shape_env
    }

    /// Whether any definition can fire at a node: a `match` rule, or a
    /// match-less definition callable by its operator's name.
    pub(super) fn has_rules(&self) -> bool {
        !self.rules.is_empty() || !self.call_rules.is_empty()
    }

    /// Whether the definition `name` is in scope for a call at the current
    /// call scope (esm-spec §4.7, §9.6.12): it is the component's own, or a
    /// subsystem that owns it encloses the call.
    fn callable_here(&self, name: &str) -> bool {
        let Some(owners) = self.owners.get(name) else {
            return true;
        };
        let scope = self.call_scope.borrow();
        owners.iter().any(|o| {
            o.is_empty()
                || scope.iter().any(|s| {
                    s.strip_prefix(o.as_str())
                        .is_some_and(|rest| rest.is_empty() || rest.starts_with('.'))
                })
        })
    }

    /// Whether a subsystem owns a definition the component does not, so the
    /// call scope varies across the component's positions.
    fn has_local_definitions(&self) -> bool {
        self.owners
            .values()
            .any(|os| os.iter().all(|o| !o.is_empty()))
    }

    /// The call scope of the body of the registry entry `name`: its owners.
    pub(super) fn owner_scope(&self, name: &str) -> Vec<String> {
        self.owners
            .get(name)
            .cloned()
            .unwrap_or_else(|| vec![String::new()])
    }

    /// The entry `variant` (a rewritten instance of `of`) has `of`'s owners.
    pub(super) fn inherit_owners(&mut self, variant: &str, of: &str) {
        if let Some(os) = self.owners.get(of).cloned() {
            self.owners.insert(variant.to_string(), os);
        }
    }

    /// `f` run with the call scope `scope`, the previous one restored after.
    pub(super) fn with_call_scope<T>(&self, scope: Vec<String>, f: impl FnOnce() -> T) -> T {
        let prev = self.call_scope.replace(scope);
        let out = f();
        self.call_scope.replace(prev);
        out
    }
}

/// The `priority` of a `match` rule (esm-spec §9.6.3): higher fires first, ties
/// break by declaration order. Absent ⇒ `0`. The schema constrains `priority`
/// to an integer; any numeric encoding is coerced defensively (a boolean, like
/// any non-number, yields `0`).
fn rule_priority(decl: &Map<String, Value>) -> i64 {
    match decl.get("priority") {
        Some(Value::Number(n)) => n
            .as_i64()
            .or_else(|| n.as_f64().map(|f| f.round() as i64))
            .unwrap_or(0),
        _ => 0,
    }
}

/// The static shape environment of one component: every declared variable name
/// mapped to its declared `shape` (ordered index-set names). This is the ONLY
/// information a `where` constraint may consult (esm-spec §9.6.1) — declared
/// shapes at lowering time, never runtime values — so constraint evaluation is
/// fully static and the §9.6.3 determinism contract is untouched. Variables
/// with no `shape` (scalars) are absent, as are species / parameters of
/// reaction systems (which carry no `shape` field): a shape-constrained rule
/// can only fire on a declared, shaped model variable. Mirrors the Julia
/// reference `_component_shape_env`.
fn component_shape_env(
    comp: &Map<String, Value>,
) -> std::collections::BTreeMap<String, Vec<String>> {
    let mut env = std::collections::BTreeMap::new();
    let Some(vars) = comp.get("variables").and_then(|v| v.as_object()) else {
        return env;
    };
    for (vn, vd) in vars {
        let Some(shp) = vd.get("shape").and_then(|s| s.as_array()) else {
            continue;
        };
        if !shp.iter().all(|s| s.is_string()) {
            continue;
        }
        let shape: Vec<String> = shp
            .iter()
            .map(|s| s.as_str().unwrap_or_default().to_string())
            .collect();
        env.insert(vn.clone(), shape);
    }
    env
}

/// Evaluate a registered `where` constraint map (param → required shape)
/// against the bindings produced by a successful structural match (esm-spec
/// §9.6.1). A constraint on param `p` holds iff `bindings[p]` is a BARE
/// variable-reference string naming an entry of `shape_env` whose declared
/// shape equals the required list exactly (same names, same order). Everything
/// else — a compound sub-AST, a numeric literal, a scalar-field-bound literal,
/// a scoped (`System.var`) reference, an undeclared name, a scalar variable, or
/// a param that never bound — fails the constraint. Deliberately syntactic and
/// conservative. Mirrors the Julia reference `_where_satisfied`.
fn where_satisfied(
    where_c: &Option<std::collections::BTreeMap<String, Vec<String>>>,
    bindings: &Binds,
    shape_env: &std::collections::BTreeMap<String, Vec<String>>,
    bv: Option<&BodyView>,
) -> bool {
    let Some(where_c) = where_c else {
        return true;
    };
    for (p, req) in where_c {
        let Some(bound) = binds_get(bindings, p) else {
            return false;
        };
        let SNode::Str(b) = &**bound else {
            return false;
        };
        // A template-body parameter satisfies it iff its instance binds a bare
        // variable of exactly that declared shape (esm-spec §9.6.4 rule 3).
        if let Some(view) = bv
            && view.params.contains(b)
        {
            if view.entries.get(b) != Some(&shape_entry(req)) {
                return false;
            }
            continue;
        }
        let Some(shp) = shape_env.get(b) else {
            return false;
        };
        if shp != req {
            return false;
        }
    }
    true
}

/// Normalize a template's `where` block into the registered constraint map
/// (param → required shape), checking every referenced index-set name against
/// the CONSUMING document's merged `index_sets` registry (`iset_names`). An
/// unknown name is `operator_constraint_unknown_index_set` (esm-spec
/// §9.6.1/§9.6.6) — raised here, at rule registration in the consuming
/// component, not when a library file is loaded standalone. Returns `None` when
/// the decl carries no `where` block. The `where` block is already
/// structurally validated by [`validate_templates`]. Mirrors the Julia
/// reference `_registered_where`.
fn registered_where(
    decl: &Map<String, Value>,
    iset_names: &std::collections::HashSet<String>,
    scope: &str,
    tname: &str,
) -> Result<Option<std::collections::BTreeMap<String, Vec<String>>>, ExpressionTemplateError> {
    let Some(whr) = decl.get("where").and_then(|v| v.as_object()) else {
        return Ok(None);
    };
    let mut out = std::collections::BTreeMap::new();
    for (p, cobj) in whr {
        let shp = cobj.get("shape").and_then(|v| v.as_array());
        let req: Vec<String> = shp
            .map(|a| {
                a.iter()
                    .map(|s| s.as_str().unwrap_or_default().to_string())
                    .collect()
            })
            .unwrap_or_default();
        for s in &req {
            if !iset_names.contains(s) {
                return Err(err(
                    codes::OPERATOR_CONSTRAINT_UNKNOWN_INDEX_SET,
                    format!(
                        "{scope}.operators.{tname}: where.{p}.shape names index set \
                         '{s}', which the consuming document's index_sets registry does not \
                         declare (esm-spec §9.6.1/§9.6.6)"
                    ),
                ));
            }
        }
        out.insert(p.clone(), req);
    }
    Ok(Some(out))
}

/// The rules of one component (esm-spec §9.6.3, §9.6.12).
struct Rules {
    /// The `match` rules, in §9.6.3 selection order.
    rules: Vec<MatchRule>,
    /// The match-less definitions callable by their operator's name, grouped
    /// by it, each group in selection order.
    call_rules: std::collections::HashMap<String, Vec<MatchRule>>,
    /// The operand count each defined operator's definitions take.
    arities: Arities,
}

/// Register a component's definitions in declaration order (serde_json's
/// `preserve_order` feature keeps source order). Each entry with a `match` is
/// an auto-applied rule; each match-less entry whose `defines` is not a core
/// operator is callable at a call of that operator — its pattern is
/// `{op: defines, args: params}`, and the call may carry no other field
/// (esm-spec §9.6.3 constraint 2, §9.6.12). Both kinds are sorted by
/// [`MatchRule::selection_key`]. Each rule's `where` block is normalized and
/// its referenced index sets resolved against the consuming document's
/// registry (`iset_names`) at registration — an unknown name is
/// `operator_constraint_unknown_index_set` (esm-spec §9.6.1). The arity table
/// records the operand count of every match-less definition under the operator
/// it defines and of every `match` rule rooted at a defined operator. The
/// bounded fixpoint (`MAX_REWRITE_PASSES`) is the sole termination guard
/// (esm-spec §9.6.3). Mirrors the registration loop of the Julia reference
/// `lower_expression_templates`.
fn collect_rules(
    templates: &Map<String, Value>,
    named: &Named,
    iset_names: &std::collections::HashSet<String>,
    scope: &str,
) -> Result<Rules, ExpressionTemplateError> {
    let mut rules = Vec::new();
    let mut call_rules: std::collections::HashMap<String, Vec<MatchRule>> =
        std::collections::HashMap::new();
    let mut arities = Arities::new();
    for (decl_index, (name, decl)) in templates.iter().enumerate() {
        let decl_index = decl_index + 1;
        let Some(obj) = decl.as_object() else {
            continue;
        };
        let param_list: Vec<String> = obj
            .get("params")
            .and_then(|p| p.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| v.as_str().map(String::from))
                    .collect()
            })
            .unwrap_or_default();
        let param_set: std::collections::HashSet<String> = param_list.iter().cloned().collect();
        // The RAW (uninlined, Option B) body as a shared DAG. A firing writes
        // a reference to the rule (esm-spec §9.6.3 constraint 7).
        let body = named
            .get(name)
            .map(decl_body)
            .unwrap_or_else(|| Rc::new(SNode::Null));
        let defines = definition_defines(name, decl);
        match obj.get("match") {
            // Reached only through an explicit reference (§9.6.1): no call
            // rule, no arity.
            None if is_reference_only(decl) => {}
            None => {
                arities
                    .entry(defines.clone())
                    .or_default()
                    .push((param_list.len(), name.clone()));
                if !is_core_operator(&defines) && defines != APPLY_OP {
                    let pattern = serde_json::json!({
                        "op": defines,
                        "args": param_list.clone(),
                    });
                    let where_c = registered_where(obj, iset_names, scope, name)?;
                    call_rules.entry(defines).or_default().push(MatchRule {
                        name: name.clone(),
                        param_set,
                        param_list,
                        pattern,
                        body,
                        priority: rule_priority(obj),
                        where_c,
                        decl_index,
                    });
                }
            }
            Some(pattern) => {
                if let Some(rop) = match_root_op(obj)
                    && !is_core_operator(rop)
                {
                    let n = pattern
                        .get("args")
                        .and_then(Value::as_array)
                        .map_or(0, Vec::len);
                    arities
                        .entry(rop.to_string())
                        .or_default()
                        .push((n, name.clone()));
                }
                let where_c = registered_where(obj, iset_names, scope, name)?;
                rules.push(MatchRule {
                    name: name.clone(),
                    param_set,
                    param_list,
                    pattern: pattern.clone(),
                    body,
                    priority: rule_priority(obj),
                    where_c,
                    decl_index,
                });
            }
        }
    }
    // Deterministic selection order (esm-spec §9.6.3): highest `priority`
    // first, then a definition with a `where` before one without (esm 2.4.0),
    // then declaration order (earliest wins).
    rules.sort_by_key(MatchRule::selection_key);
    for v in call_rules.values_mut() {
        v.sort_by_key(MatchRule::selection_key);
    }
    Ok(Rules {
        rules,
        call_rules,
        arities,
    })
}

/// The definition that resolves the object node `node` (esm-spec §9.6.3
/// constraint 2, §9.6.12): among the `match` rules whose pattern matches and
/// the match-less definitions of the defined operator `node` calls that take
/// its operands, those whose `where` holds, the first in
/// [`MatchRule::selection_key`] order, with what it bound. Mirrors the Julia
/// reference `_select_definition`.
fn select_definition<'l>(
    l: &'l Lowering,
    node: &Sv,
    fields: &[(String, Sv)],
    bv: Option<&BodyView>,
) -> Option<(&'l MatchRule, Binds)> {
    let mut best: Option<(&MatchRule, Binds)> = None;
    for rule in &l.rules {
        let mut binds = Binds::new();
        if try_match(&rule.pattern, node, &rule.param_set, &mut binds, bv)
            && where_satisfied(&rule.where_c, &binds, &l.shape_env, bv)
        {
            best = Some((rule, binds));
            break;
        }
    }
    if let Some(op) = obj_op(fields)
        && let Some(calls) = l.call_rules.get(op)
        && only_op_args(fields)
    {
        for rule in calls {
            if let Some((b, _)) = &best
                && b.selection_key() < rule.selection_key()
            {
                break;
            }
            if !l.callable_here(&rule.name) {
                continue;
            }
            let mut binds = Binds::new();
            if try_match(&rule.pattern, node, &rule.param_set, &mut binds, bv)
                && where_satisfied(&rule.where_c, &binds, &l.shape_env, bv)
            {
                best = Some((rule, binds));
                break;
            }
        }
    }
    best
}

/// The `unlowered_operator` explanation of esm-spec §9.6.6 for an unresolved
/// call `call` (raw JSON) of a defined operator: every definition of it in
/// `registry` (name → raw entry), sorted by name, with the reason it was not
/// eligible there — its `match` did not match, its `where` failed (naming the
/// constraint), or its arity or call shape differed. No definition of the
/// operator in the registry: a placeholder. Mirrors the Julia reference
/// `_explain_unresolved_call`.
pub(crate) fn explain_unresolved_call(
    call: &Value,
    registry: &indexmap::IndexMap<String, Value>,
    shape_env: &std::collections::BTreeMap<String, Vec<String>>,
) -> String {
    let Some(op) = call.get("op").and_then(Value::as_str) else {
        return String::new();
    };
    let args: &[Value] = call
        .get("args")
        .and_then(Value::as_array)
        .map_or(&[], Vec::as_slice);
    let k = args.len();
    let target = to_shared(call);
    let mut names: Vec<&String> = registry.keys().collect();
    names.sort_unstable();
    let mut lines = Vec::new();
    for name in names {
        let decl = &registry[name.as_str()];
        let Some(obj) = decl.as_object() else {
            continue;
        };
        let params: Vec<String> = obj
            .get("params")
            .and_then(Value::as_array)
            .map(|a| {
                a.iter()
                    .filter_map(|p| p.as_str().map(str::to_string))
                    .collect()
            })
            .unwrap_or_default();
        let param_set: std::collections::HashSet<String> = params.iter().cloned().collect();
        let whr = obj.get("where");
        if let Some(m) = obj.get("match") {
            if match_root_op(obj) != Some(op) {
                continue;
            }
            let mut b = Binds::new();
            if !try_match(m, &target, &param_set, &mut b, None) {
                lines.push(format!("'{name}': its match does not match the call"));
                continue;
            }
            lines.push(format!(
                "'{name}': its where constraint {}",
                where_reason(whr, &b, shape_env)
            ));
        } else {
            if definition_defines(name, decl) != op {
                continue;
            }
            if is_reference_only(decl) {
                lines.push(format!(
                    "'{name}': reference-only, reached by explicit references, never by a call"
                ));
                continue;
            }
            let call_obj = call.as_object();
            let extra: Vec<&str> = call_obj
                .map(|o| {
                    let mut v: Vec<&str> = o
                        .keys()
                        .map(String::as_str)
                        .filter(|x| *x != "op" && *x != "args")
                        .collect();
                    v.sort_unstable();
                    v
                })
                .unwrap_or_default();
            if params.len() != k {
                lines.push(format!(
                    "'{name}': takes {} operand(s), the call carries {k}",
                    params.len()
                ));
            } else if !extra.is_empty() {
                lines.push(format!(
                    "'{name}': has no match, so it binds operands only, and the call carries {}",
                    extra.join(", ")
                ));
            } else {
                let b: Binds = params
                    .iter()
                    .zip(args)
                    .map(|(p, a)| (p.clone(), to_shared(a)))
                    .collect();
                lines.push(format!(
                    "'{name}': its where constraint {}",
                    where_reason(whr, &b, shape_env)
                ));
            }
        }
    }
    // esm-spec §9.6.12: emit and flatten keep only the definitions a reference
    // reaches, so an unreferenced definition is no longer here to list.
    let note = "; definitions no reference reached were removed by emit and flatten and are not \
                listed";
    if lines.is_empty() {
        return format!("no definition of '{op}' is in scope (a placeholder){note}");
    }
    format!("definitions of '{op}' in scope: {}{note}", lines.join("; "))
}

/// Why a definition's `where` did not hold at a call (its first constraint).
fn where_reason(
    whr: Option<&Value>,
    b: &Binds,
    shape_env: &std::collections::BTreeMap<String, Vec<String>>,
) -> String {
    let Some(whr) = whr.and_then(Value::as_object) else {
        return "holds (the definition was not selected)".to_string();
    };
    let Some((p, c)) = whr.iter().next() else {
        return "fails".to_string();
    };
    let want = c
        .get("shape")
        .map_or_else(|| "null".to_string(), Value::to_string);
    match binds_get(b, p).map(|v| &**v) {
        Some(SNode::Str(got)) => {
            let shp = shape_env
                .get(got)
                .map_or_else(|| "none".to_string(), |s| format!("{s:?}"));
            format!(
                "{p}.shape = {want} fails: the operand bound to {p} ('{got}') has declared shape {shp}"
            )
        }
        _ => format!("{p}.shape = {want} fails: the operand bound to {p} is not a bare variable"),
    }
}

/// Structurally match `pattern` against `target`, binding metavariables (names
/// in `params`) into `binds`. A metavariable in an operand/`args` position
/// binds the matched sub-AST; in a scalar field it binds the matched literal.
/// A metavariable appearing twice must bind consistently. Pattern object keys
/// are matched as a subset: `target` MAY carry extra keys.
///
/// Inside a template body (`bv`, esm-spec §9.6.4 rules 3 and 4) a parameter is
/// a leaf: a metavariable captures it whole, and any other pattern node sees it
/// only as the literal its instance binds in a structural position (and never
/// matches an operand-position parameter). Mirrors the Julia reference
/// `_match_pattern`.
fn try_match(
    pattern: &Value,
    target: &Sv,
    params: &std::collections::HashSet<String>,
    binds: &mut Binds,
    bv: Option<&BodyView>,
) -> bool {
    if let Some(view) = bv
        && let SNode::Str(s) = &**target
        && view.params.contains(s)
        && !matches!(pattern, Value::String(p) if params.contains(p.as_str()))
    {
        return match view.lit.get(s) {
            Some(lit) => try_match(pattern, lit, params, binds, None),
            None => false,
        };
    }
    match pattern {
        Value::String(s) => {
            if params.contains(s.as_str()) {
                // A repeated metavariable must bind consistently; the
                // pointer fast path in `sv_eq` makes re-binding a shared
                // subtree O(1) instead of a deep compare.
                match binds.iter().position(|(k, _)| k == s) {
                    Some(i) => {
                        let prev = binds[i].1.clone();
                        sv_eq(&prev, target)
                    }
                    None => {
                        binds.push((s.clone(), target.clone()));
                        true
                    }
                }
            } else {
                value_eq_sv(pattern, target)
            }
        }
        Value::Array(parr) => match &**target {
            SNode::Arr(tarr) if parr.len() == tarr.len() => parr
                .iter()
                .zip(tarr.iter())
                .all(|(p, t)| try_match(p, t, params, binds, bv)),
            // A pattern array may name parameters at its elements: match it
            // against the data's own node form.
            SNode::Data(v) => match &**v {
                Value::Array(items) if parr.len() == items.len() => {
                    let t = Rc::new(SNode::Arr(items.iter().map(to_shared).collect()));
                    try_match(pattern, &t, params, binds, bv)
                }
                _ => false,
            },
            _ => false,
        },
        Value::Object(pobj) => match &**target {
            SNode::Obj(tfields) => pobj.iter().all(|(k, pv)| match obj_get(tfields, k) {
                Some(tv) => try_match(pv, tv, params, binds, bv),
                None => false,
            }),
            _ => false,
        },
        // numbers / bools / null: exact equality.
        _ => value_eq_sv(pattern, target),
    }
}

/// Instantiate an `apply_expression_template` node (given its object `fields`)
/// by pure structural substitution of its `bindings` into the referenced
/// template's `body` (esm-spec §9.6.3). The body is NOT re-scanned here — the
/// caller ([`expand_all`]) recursively expands the result. Mirrors the Julia
/// reference `_expand_apply`.
fn expand_apply(
    node: &[(String, Sv)],
    named: &Named,
    scope: &str,
) -> Result<Sv, ExpressionTemplateError> {
    let name = match obj_get(node, "name").map(|v| &**v) {
        Some(SNode::Str(s)) => Some(s.as_str()),
        _ => None,
    }
    .ok_or_else(|| {
        err(
            codes::OPERATOR_INVALID_DEFINITION,
            format!("{scope}: apply_operator node missing or empty 'name'"),
        )
    })?;
    if name.is_empty() {
        return Err(err(
            codes::OPERATOR_INVALID_DEFINITION,
            format!("{scope}: apply_operator 'name' must be non-empty"),
        ));
    }
    let decl = named.get(name).ok_or_else(|| {
        err(
            codes::OPERATOR_UNKNOWN_DEFINITION,
            format!("{scope}: apply_operator references undeclared template '{name}'"),
        )
    })?;
    let SNode::Obj(decl_fields) = &**decl else {
        return Err(err(
            codes::OPERATOR_INVALID_DEFINITION,
            format!("{scope}: template '{name}' declaration is not an object"),
        ));
    };
    let bindings: &[(String, Sv)] = match obj_get(node, "bindings").map(|v| &**v) {
        Some(SNode::Obj(fields)) => fields,
        _ => {
            return Err(err(
                codes::OPERATOR_BINDINGS_MISMATCH,
                format!("{scope}: apply_operator '{name}' missing 'bindings' object"),
            ));
        }
    };

    let params: Vec<&str> = match obj_get(decl_fields, "params").map(|v| &**v) {
        Some(SNode::Arr(items)) => items
            .iter()
            .filter_map(|v| match &**v {
                SNode::Str(s) => Some(s.as_str()),
                _ => None,
            })
            .collect(),
        _ => Vec::new(),
    };
    let declared: std::collections::HashSet<&str> = params.iter().copied().collect();
    let provided: std::collections::HashSet<&str> =
        bindings.iter().map(|(k, _)| k.as_str()).collect();
    for p in &params {
        if !provided.contains(p) {
            return Err(err(
                codes::OPERATOR_BINDINGS_MISMATCH,
                format!("{scope}: apply_operator '{name}' missing binding for param '{p}'"),
            ));
        }
    }
    for (p, _) in bindings {
        if !declared.contains(p.as_str()) {
            return Err(err(
                codes::OPERATOR_BINDINGS_MISMATCH,
                format!("{scope}: apply_operator '{name}' supplies unknown param '{p}'"),
            ));
        }
    }

    // The bindings have already been expanded innermost-first by the caller,
    // so they are consumed as-is. The body is instantiated by pure structural
    // substitution and is NOT re-scanned here (esm-spec §9.6.3 rule 2).
    let resolved: Binds = bindings.to_vec();
    let body = decl_body(decl);
    Ok(substitute(&body, &resolved))
}
/// Fully expand EVERY `apply_expression_template` node in `node` by pure
/// substitution to a fixpoint (innermost-first). The per-registry kernel of
/// the public [`expand`] function (esm-spec §9.6.4 rule 2). Mirrors the Julia
/// reference `_expand_all`.
pub(super) fn expand_all(
    node: &Sv,
    named: &Named,
    scope: &str,
    memo: &mut PtrMemo<Sv>,
) -> Result<Sv, ExpressionTemplateError> {
    match &**node {
        SNode::Obj(fields) => {
            if let Some(hit) = memo.get(node) {
                return Ok(hit.clone());
            }
            let res = if obj_op(fields) == Some(APPLY_OP) {
                let mut newfields = fields.clone();
                if let Some(b_idx) = newfields.iter().position(|(k, _)| k == "bindings")
                    && let SNode::Obj(b) = &*newfields[b_idx].1.clone()
                {
                    let mut nb = Vec::with_capacity(b.len());
                    let mut b_changed = false;
                    for (k, v) in b {
                        let rv = expand_all(v, named, scope, memo)?;
                        b_changed |= !Rc::ptr_eq(&rv, v);
                        nb.push((k.clone(), rv));
                    }
                    if b_changed {
                        newfields[b_idx].1 = Rc::new(SNode::Obj(nb));
                    }
                }
                let body = expand_apply(&newfields, named, scope)?;
                let expanded = expand_all(&body, named, scope, memo)?;
                match obj_get(&newfields, "name").map(|v| &**v) {
                    Some(SNode::Str(name)) => mark_template_origin(expanded, name),
                    _ => expanded,
                }
            } else {
                let mut changed = false;
                let mut out = Vec::with_capacity(fields.len());
                for (k, v) in fields {
                    let rv = expand_all(v, named, scope, memo)?;
                    changed |= !Rc::ptr_eq(&rv, v);
                    out.push((k.clone(), rv));
                }
                if changed {
                    Rc::new(SNode::Obj(out))
                } else {
                    node.clone()
                }
            };
            memo.insert(node, res.clone());
            Ok(res)
        }
        SNode::Arr(items) => {
            if let Some(hit) = memo.get(node) {
                return Ok(hit.clone());
            }
            let mut changed = false;
            let mut out = Vec::with_capacity(items.len());
            for v in items {
                let rv = expand_all(v, named, scope, memo)?;
                changed |= !Rc::ptr_eq(&rv, v);
                out.push(rv);
            }
            let res = if changed {
                Rc::new(SNode::Arr(out))
            } else {
                node.clone()
            };
            memo.insert(node, res.clone());
            Ok(res)
        }
        _ => Ok(node.clone()),
    }
}

/// The declared `params` of a template decl, in declared order.
pub(super) fn decl_params(decl: &Sv) -> Vec<String> {
    let SNode::Obj(fields) = &**decl else {
        return Vec::new();
    };
    match obj_get(fields, "params").map(|v| &**v) {
        Some(SNode::Arr(items)) => items
            .iter()
            .filter_map(|v| match &**v {
                SNode::Str(s) => Some(s.clone()),
                _ => None,
            })
            .collect(),
        _ => Vec::new(),
    }
}

/// The ONE call-site resolution of an `apply_expression_template` node (given
/// its object `fields`): `name` present, declared in `named`, `bindings` an
/// object covering the declaration's `params` exactly. `reject_match_rule`
/// additionally rejects a reference to a `match` rewrite rule (only match-less
/// templates are invocable by name, esm-spec §9.6.2) — a reference a firing
/// wrote names its rule and is resolved without it. Returns the name, the decl
/// and the bindings. Mirrors the Julia reference `_resolve_apply_site`.
pub(super) fn resolve_apply_site(
    fields: &[(String, Sv)],
    named: &Named,
    scope: &str,
    reject_match_rule: bool,
) -> Result<(String, Sv, Binds), ExpressionTemplateError> {
    let name = match obj_get(fields, "name").map(|v| &**v) {
        Some(SNode::Str(s)) => s.clone(),
        _ => {
            return Err(err(
                codes::OPERATOR_INVALID_DEFINITION,
                format!("{scope}: apply_operator node missing 'name'"),
            ));
        }
    };
    let decl = named.get(&name).ok_or_else(|| {
        err(
            codes::OPERATOR_UNKNOWN_DEFINITION,
            format!("{scope}: apply_operator references undeclared template '{name}'"),
        )
    })?;
    if reject_match_rule && decl_has_match(decl) {
        return Err(err(
            codes::OPERATOR_UNKNOWN_DEFINITION,
            format!(
                "{scope}: apply_operator references '{name}', a `match` rewrite rule — \
                 only match-less templates are invocable by name (esm-spec §9.6.2)"
            ),
        ));
    }
    let bindings: Binds = match obj_get(fields, "bindings").map(|v| &**v) {
        Some(SNode::Obj(b)) => b.clone(),
        _ => {
            return Err(err(
                codes::OPERATOR_BINDINGS_MISMATCH,
                format!("{scope}: apply_operator '{name}' missing 'bindings' object"),
            ));
        }
    };
    let params = decl_params(decl);
    let declared: std::collections::HashSet<&str> = params.iter().map(String::as_str).collect();
    let provided: std::collections::HashSet<&str> =
        bindings.iter().map(|(k, _)| k.as_str()).collect();
    for p in &params {
        if !provided.contains(p.as_str()) {
            return Err(err(
                codes::OPERATOR_BINDINGS_MISMATCH,
                format!("{scope}: apply_operator '{name}' missing binding for param '{p}'"),
            ));
        }
    }
    for (p, _) in &bindings {
        if !declared.contains(p.as_str()) {
            return Err(err(
                codes::OPERATOR_BINDINGS_MISMATCH,
                format!("{scope}: apply_operator '{name}' supplies unknown param '{p}'"),
            ));
        }
    }
    Ok((name, decl.clone(), bindings))
}

/// Call-site check for a SURVIVING `apply_expression_template` reference
/// (esm-spec §9.6.9): the referenced `name` must resolve to an in-scope
/// MATCH-LESS template and `bindings` must cover its `params` exactly. Runs
/// after rule 3, which materialized every referenced rule without its `match`.
/// Mirrors `_validate_apply_ref`.
fn validate_apply_ref(
    fields: &[(String, Sv)],
    named: &Named,
    scope: &str,
) -> Result<(), ExpressionTemplateError> {
    resolve_apply_site(fields, named, scope, true).map(|_| ())
}

/// Walk `node` and run [`validate_apply_ref`] on every surviving
/// `apply_expression_template` reference it carries (esm-spec §9.6.9). Descends
/// into references' `bindings` too. Mirrors `_check_surviving_refs`.
fn check_surviving_refs(
    node: &Sv,
    named: &Named,
    scope: &str,
    seen: &mut PtrSet,
) -> Result<(), ExpressionTemplateError> {
    match &**node {
        SNode::Arr(items) => {
            if !seen.insert(node) {
                return Ok(());
            }
            for c in items {
                check_surviving_refs(c, named, scope, seen)?;
            }
        }
        SNode::Obj(fields) => {
            if !seen.insert(node) {
                return Ok(());
            }
            if obj_op(fields) == Some(APPLY_OP) {
                validate_apply_ref(fields, named, scope)?;
            }
            for (_, v) in fields {
                check_surviving_refs(v, named, scope, seen)?;
            }
        }
        _ => {}
    }
    Ok(())
}

/// What a firing of `rule` writes in place of the matched node (esm-spec §9.6.3
/// constraint 7): a reference to the rule bound to what the match captured, a
/// parameter the match never bound being bound to its own name. A rule whose
/// body is a single leaf writes the leaf (for one of its parameters, what that
/// parameter bound): there is no body to share. Mirrors the Julia reference
/// `_rule_reference`.
fn rule_reference(rule: &MatchRule, captured: &Binds) -> Sv {
    match &*rule.body {
        SNode::Obj(_) | SNode::Arr(_) | SNode::Data(_) => {
            let bindings: Vec<(String, Sv)> = rule
                .param_list
                .iter()
                .map(|p| {
                    let v = binds_get(captured, p)
                        .cloned()
                        .unwrap_or_else(|| Rc::new(SNode::Str(p.clone())));
                    (p.clone(), v)
                })
                .collect();
            Rc::new(SNode::Obj(vec![
                ("op".to_string(), Rc::new(SNode::Str(APPLY_OP.to_string()))),
                ("args".to_string(), Rc::new(SNode::Arr(Vec::new()))),
                ("name".to_string(), Rc::new(SNode::Str(rule.name.clone()))),
                ("bindings".to_string(), Rc::new(SNode::Obj(bindings))),
            ]))
        }
        SNode::Str(s) if rule.param_set.contains(s) => binds_get(captured, s)
            .cloned()
            .unwrap_or_else(|| rule.body.clone()),
        _ => rule.body.clone(),
    }
}

/// One pre-order (outermost-first) rewrite pass over `node` (esm-spec §9.6.3).
/// At each object node the first rule in `l.rules` (highest `priority` first,
/// ties by declaration order) whose `match` pattern matches the node AND whose
/// `where` constraints hold fires; constraint filtering is part of match
/// eligibility (§9.6.3 constraint 2). A firing writes a reference to the rule
/// ([`rule_reference`], constraint 7), recorded in `l`'s depth map at depth
/// `pass`, and the walk does not descend into it during this pass. At a
/// reference — authored or written — no pattern matches (§9.6.4 rule 4), but
/// the walk descends into the values of its `bindings`, which are expressions
/// of the call site; a reference rebuilt because a binding changed keeps its
/// depth. `bv` is the template-body view when `node` is a template body being
/// rewritten for one instance (§9.6.4 rule 3), `None` at a component's
/// expression positions. Returns the rewritten node and whether any rule fired;
/// `last` records the name of the last rule that fired, for the
/// non-convergence diagnostic.
///
/// The walk is identity-memoized and sharing-preserving (mirroring the Julia
/// reference): the rewrite of a node is a function of the node alone, so a
/// subtree shared under many parents is rewritten ONCE and the shared result
/// respliced. Unchanged subtrees are returned by identity. Each memo entry
/// also records the subtree's final `last` value (when it rewrote anything),
/// replayed on memo hits. Mirrors the Julia reference `_rewrite_pass`.
fn rewrite_pass(
    node: &Sv,
    l: &Lowering,
    pass: usize,
    last: &mut String,
    memo: &mut PtrMemo<(Sv, bool, Option<String>)>,
    bv: Option<&BodyView>,
) -> (Sv, bool) {
    match &**node {
        SNode::Arr(items) => {
            if let Some((res, ch, lst)) = memo.get(node) {
                if let Some(lst) = lst {
                    *last = lst.clone();
                }
                return (res.clone(), *ch);
            }
            let mut changed = false;
            let mut out = Vec::with_capacity(items.len());
            for c in items {
                let (nc, ch) = rewrite_pass(c, l, pass, last, memo, bv);
                out.push(nc);
                changed |= ch;
            }
            let res = if changed {
                Rc::new(SNode::Arr(out))
            } else {
                node.clone()
            };
            memo.insert(node, (res.clone(), changed, changed.then(|| last.clone())));
            (res, changed)
        }
        SNode::Obj(fields) => {
            if let Some((res, ch, lst)) = memo.get(node) {
                if let Some(lst) = lst {
                    *last = lst.clone();
                }
                return (res.clone(), *ch);
            }
            if obj_op(fields) == Some(APPLY_OP) {
                // A reference is a leaf for matching; its bindings are
                // expressions of the call site and are rewritten.
                let (res, changed) = match obj_get(fields, "bindings").map(|v| &**v) {
                    Some(SNode::Obj(b)) => {
                        let mut changed = false;
                        let mut nb = Vec::with_capacity(b.len());
                        for (k, v) in b {
                            let (nv, ch) = rewrite_pass(v, l, pass, last, memo, bv);
                            changed |= ch;
                            nb.push((k.clone(), nv));
                        }
                        if changed {
                            let nb = Rc::new(SNode::Obj(nb));
                            let nf: Vec<(String, Sv)> = fields
                                .iter()
                                .map(|(k, v)| {
                                    let v = if k == "bindings" {
                                        nb.clone()
                                    } else {
                                        v.clone()
                                    };
                                    (k.clone(), v)
                                })
                                .collect();
                            let nn = Rc::new(SNode::Obj(nf));
                            if let Some(d) = l.depth_of(node) {
                                l.set_depth(&nn, d);
                            }
                            (nn, true)
                        } else {
                            (node.clone(), false)
                        }
                    }
                    _ => (node.clone(), false),
                };
                memo.insert(node, (res.clone(), changed, changed.then(|| last.clone())));
                return (res, changed);
            }
            if let Some((rule, binds)) = select_definition(l, node, fields, bv) {
                *last = rule.name.clone();
                let res = rule_reference(rule, &binds);
                if matches!(&*res, SNode::Obj(f) if obj_op(f) == Some(APPLY_OP)) {
                    l.set_depth(&res, pass);
                }
                memo.insert(node, (res.clone(), true, Some(last.clone())));
                return (res, true);
            }
            // No rule fired here — descend into children.
            let mut changed = false;
            let mut out = Vec::with_capacity(fields.len());
            for (k, v) in fields {
                let (nv, ch) = rewrite_pass(v, l, pass, last, memo, bv);
                out.push((k.clone(), nv));
                changed |= ch;
            }
            let res = if changed {
                Rc::new(SNode::Obj(out))
            } else {
                node.clone()
            };
            memo.insert(node, (res.clone(), changed, changed.then(|| last.clone())));
            (res, changed)
        }
        _ => (node.clone(), false),
    }
}

/// Drive [`rewrite_pass`] to a fixpoint (esm-spec §9.6.3): repeat pre-order
/// passes until a pass performs zero rewrites, and return the rewritten node
/// with the number of productive passes. A rewrite made in pass `p` has depth
/// `p`; one whose depth would exceed `MAX_REWRITE_PASSES` (a productive pass
/// `MAX_REWRITE_PASSES + 1`) rejects the file with `rewrite_rule_nonterminating`
/// (§9.6.4 rule 3, "Rewrite depth"). This bound — not a static check — is the
/// authoritative termination guard. Nothing here expands a reference. Mirrors
/// the Julia reference `_rewrite_to_fixpoint`.
pub(super) fn rewrite_to_fixpoint(
    node: &Sv,
    l: &Lowering,
    scope: &str,
    bv: Option<&BodyView>,
) -> Result<(Sv, usize), ExpressionTemplateError> {
    if !l.has_rules() {
        return Ok((node.clone(), 0));
    }
    let mut current = node.clone();
    let mut last = String::new();
    for pass in 1..=(MAX_REWRITE_PASSES + 1) {
        // Fresh memo each pass: a pass's rewrite of a node is pass-local
        // (written references are deliberately not revisited until the next
        // pass).
        let mut memo = PtrMemo::default();
        let (next, changed) = rewrite_pass(&current, l, pass, &mut last, &mut memo, bv);
        current = next;
        if !changed {
            return Ok((current, pass - 1));
        }
    }
    Err(err(
        codes::REWRITE_RULE_NONTERMINATING,
        format!(
            "{scope}: expression-template rewriting did not converge within \
             MAX_REWRITE_PASSES={MAX_REWRITE_PASSES} passes (last rule fired '{last}'). \
             A `match` rule likely re-introduces its own pattern (esm-spec §9.6.3)."
        ),
    ))
}

fn find_apply_paths(view: &Value, hits: &mut Vec<String>) {
    crate::json_visit::visit_values(view, &mut |path, v| {
        if let Some(obj) = v.as_object()
            && obj.get("op").and_then(|w| w.as_str()) == Some(APPLY_OP)
        {
            hits.push(path.to_string());
        }
    });
}

/// Reject `expression_templates` and `apply_expression_template` constructs
/// in files declaring `esm` < 0.4.0. Mirrors the equivalent TS / Python /
/// Julia / Go checks for cross-binding-uniform diagnostics.
pub fn reject_expression_templates_pre_v04(view: &Value) -> Result<(), ExpressionTemplateError> {
    crate::version_gates::VERSIONED[crate::version_gates::EXPRESSION_TEMPLATES].check_document(view)
}

/// Every `expression_templates` block on a component and every
/// `apply_expression_template` node in `view`, joined for the gate's message,
/// or `None` when it spells neither.
pub(crate) fn expression_template_offences(view: &Value) -> Option<String> {
    let obj = view.as_object()?;
    let mut offences: Vec<String> = Vec::new();
    for compkind in ["models", "reaction_systems"] {
        if let Some(comps) = obj.get(compkind).and_then(|v| v.as_object()) {
            for (cname, comp) in comps {
                if let Some(comp_obj) = comp.as_object()
                    && comp_obj.contains_key("operators")
                {
                    offences.push(format!("/{compkind}/{cname}/operators"));
                }
            }
        }
    }
    find_apply_paths(view, &mut offences);
    (!offences.is_empty()).then(|| offences.join(", "))
}

/// Build the `named` registry (template name → decl object as a shared DAG)
/// from a component's `expression_templates` block.
pub(super) fn build_named(templates: &Map<String, Value>) -> Named {
    templates
        .iter()
        .map(|(n, d)| (n.clone(), to_shared(d)))
        .collect()
}

/// True if `value` declares any non-empty `expression_templates` block
/// (top-level, a component's, or a subsystem's at any depth). With
/// [`scan_without_templates`] finding no `apply_expression_template` op
/// anywhere, this is the Julia reference's `_has_template_machinery`.
fn declares_templates(value: &Value) -> bool {
    let Some(obj) = value.as_object() else {
        return false;
    };
    if obj
        .get("operators")
        .and_then(|v| v.as_object())
        .is_some_and(|t| !t.is_empty())
    {
        return true;
    }
    for compkind in ["models", "reaction_systems"] {
        if let Some(comps) = obj.get(compkind).and_then(|v| v.as_object())
            && comps.values().any(component_declares_templates)
        {
            return true;
        }
    }
    false
}

/// Whether the component `comp`, or a subsystem of it at any depth, declares
/// a non-empty `operators` block.
fn component_declares_templates(comp: &Value) -> bool {
    comp.get("operators")
        .and_then(|v| v.as_object())
        .is_some_and(|t| !t.is_empty())
        || comp
            .get("subsystems")
            .and_then(|v| v.as_object())
            .is_some_and(|subs| subs.values().any(component_declares_templates))
}

/// The fast path's one walk over a document that declares no templates: does
/// it use an `apply_expression_template` op anywhere (then it has template
/// machinery after all), and if not, the first error each §9.6.4
/// expanded-form validator reports on it, in that validator's pre-order.
/// Equivalent to looking for the op and then running
/// [`validate_makearray_regions`] over the whole document; the op is looked for inside `expression_templates`
/// subtrees too, which the validators skip.
#[derive(Default)]
struct UntemplatedScan {
    uses_apply: bool,
    makearray: Option<ExpressionTemplateError>,
}

fn scan_without_templates(
    tree: &Value,
    at: &JsonPath<'_>,
    in_templates: bool,
    out: &mut UntemplatedScan,
    visit: &mut dyn FnMut(&JsonPath<'_>, &Value),
) {
    visit(at, tree);
    match tree {
        Value::Array(arr) => {
            for (i, child) in arr.iter().enumerate() {
                scan_without_templates(child, &JsonPath::Index(at, i), in_templates, out, visit);
                if out.uses_apply {
                    return;
                }
            }
        }
        Value::Object(obj) => {
            let op = crate::json_visit::small_get(obj, "op").and_then(|v| v.as_str());
            if op == Some(APPLY_OP) {
                out.uses_apply = true;
                return;
            }
            if !in_templates && op == Some("makearray") && out.makearray.is_none() {
                out.makearray = check_makearray_regions(obj, at).err();
            }
            for (k, v) in obj {
                let skip = in_templates || k == "operators";
                scan_without_templates(v, &JsonPath::Key(at, k), skip, out, visit);
                if out.uses_apply {
                    return;
                }
            }
        }
        _ => {}
    }
}

/// Run the load-time rewrite pass (esm-spec §9.6, Option B / esm 0.9.0):
/// auto-apply each component's `match` rules to a fixpoint, each firing
/// writing a reference to its rule (esm-spec §9.6.3 constraint 7), rewrite the
/// bodies of the templates the references reach once per template instance
/// (§9.6.4 rule 3), PRESERVE every reference and each component's
/// `expression_templates` block, and discharge the §9.6.9 reference-aware
/// validators. Nothing here expands a reference. Mutates `value` in
/// place. Surviving references denote their expansion ([`expand`]); the
/// reference-preserving form travels into emit (§9.6.4 rule 5).
///
/// Pre-condition: the input has been schema-validated.
pub fn lower_expression_templates(value: &mut Value) -> Result<(), ExpressionTemplateError> {
    lower_expression_templates_found(value)?;
    strip_fixed_units(value);
    Ok(())
}

/// [`lower_expression_templates`] for a mounted leaf: its registries keep the
/// fixed unit expressions of its materialized `partial` / `integral` rules
/// ([`FIXED_UNITS_KEY`]) for the mounting document's expansion.
pub(crate) fn lower_mounted_leaf(value: &mut Value) -> Result<(), ExpressionTemplateError> {
    lower_expression_templates_found(value).map(|_| ())
}

/// [`lower_expression_templates`], answering whether the document has any
/// template machinery — a non-empty `expression_templates` block or an
/// `apply_expression_template` op. When it has none, the document is left
/// unchanged, and [`expand`] would only strip its components' (empty)
/// `expression_templates` blocks ([`strip_component_template_blocks`]).
pub(crate) fn lower_expression_templates_found(
    value: &mut Value,
) -> Result<bool, ExpressionTemplateError> {
    // Old spellings (esm-spec §9.6.12) when the caller skipped the wire
    // boundary (the load's own pass runs after it, through
    // `lower_expression_templates_visiting`).
    crate::old_spellings::wire_old_spellings(value)?;
    lower_expression_templates_visiting(value, &mut |_, _| {}).map(|(found, _)| found)
}

/// [`lower_expression_templates_found`], also handing `visit` every value of
/// the document, in pre-order, when the document has no template machinery:
/// the second answer says whether it did (the whole document, unchanged by
/// this pass, was visited), so a caller can fold its own read-only walk into
/// this one. When it is `false`, what `visit` saw is incomplete.
pub(crate) fn lower_expression_templates_visiting(
    value: &mut Value,
    visit: &mut dyn FnMut(&JsonPath<'_>, &Value),
) -> Result<(bool, bool), ExpressionTemplateError> {
    reject_expression_templates_pre_v04(value)?;

    if value.as_object().is_none() {
        return Ok((false, false));
    }

    // Fast path: files that neither declare `expression_templates` blocks nor
    // use any `apply_expression_template` op need no expansion at all. The
    // §9.6.4 expanded-form validators still apply — the raw tree IS the
    // expanded form — and share the walk that looks for the op.
    if !declares_templates(value) {
        let mut scan = UntemplatedScan::default();
        scan_without_templates(value, &JsonPath::Root(""), false, &mut scan, visit);
        if !scan.uses_apply {
            if let Some(e) = scan.makearray {
                return Err(e);
            }
            return Ok((false, true));
        }
    }

    let root = value.as_object_mut().expect("checked object above");
    let mut sites: Vec<Site> = Vec::new();
    let mut lowerings: Vec<(&'static str, String, Lowering)> = Vec::new();
    let res = lower_components(root, &mut lowerings, &mut sites);
    // Write every rewritten position back into the document (on an error, only
    // what was parked out of it).
    for site in sites {
        let Some(slot) = site_slot(root, &site.field) else {
            continue;
        };
        if res.is_ok() && !Rc::ptr_eq(&site.tree, &site.orig) {
            *slot = to_value(&site.tree);
        }
        unpark_plain(slot, site.parked);
    }
    res?;

    // esm-spec §9.6.4 rule 1 (Option B): surviving `apply_expression_template`
    // references are the NEW NORMAL. Only UNKNOWN-name / bindings-mismatch
    // references are errors — already checked per component / per transform by
    // `check_surviving_refs`. No global "no apply ops remain" gate.

    // Validation discharge (esm-spec §9.6.9): the makearray-region check on
    // the reference-preserving form. Region bounds cannot carry template
    // params, so it runs on the reference-preserving tree AND the retained
    // folded template bodies.
    validate_makearray_regions(value, "")?;
    validate_makearray_regions_in_registries(lowerings.iter().map(|(_, _, l)| &l.named))?;

    Ok((true, false))
}

/// Where a rewritten expression position lives in the document.
enum SiteField {
    /// A non-template field `key` of the component `compkind.cname`.
    Comp {
        compkind: &'static str,
        cname: String,
        key: String,
    },
    /// A field `key` of the subsystem at the key path `path` below the
    /// component `compkind.cname`.
    Sub {
        compkind: &'static str,
        cname: String,
        path: Vec<String>,
        key: String,
    },
    /// The `transform` of the `coupling` entry at this index.
    Transform(usize),
}

/// One rewritten expression position: the index of the component whose rules
/// rewrite it, where it lives, its tree as loaded (`orig`) and as rewritten
/// (`tree`), the plain elements parked out of it ([`park_plain`]), and the
/// scope its fixpoint diagnostics name.
struct Site {
    comp: usize,
    field: SiteField,
    orig: Sv,
    tree: Sv,
    parked: Vec<(usize, Value)>,
    scope: String,
    /// The subsystem path below the component the position is in (`""`: the
    /// component's own field, or a coupling transform).
    call_scope: String,
}

fn site_slot<'a>(root: &'a mut Map<String, Value>, field: &SiteField) -> Option<&'a mut Value> {
    match field {
        SiteField::Comp {
            compkind, cname, ..
        }
        | SiteField::Sub {
            compkind, cname, ..
        } => comp_slot(
            root.get_mut(*compkind)?
                .as_object_mut()?
                .get_mut(cname)?
                .as_object_mut()?,
            field,
        ),
        SiteField::Transform(i) => root
            .get_mut("coupling")?
            .as_array_mut()?
            .get_mut(*i)?
            .as_object_mut()?
            .get_mut("transform"),
    }
}

/// The slot of the component field or subsystem field `field` in its
/// component `comp`.
fn comp_slot<'a>(comp: &'a mut Map<String, Value>, field: &SiteField) -> Option<&'a mut Value> {
    match field {
        SiteField::Comp { key, .. } => comp.get_mut(key),
        SiteField::Sub { path, key, .. } => {
            let mut node = comp;
            for k in path {
                node = node
                    .get_mut("subsystems")?
                    .as_object_mut()?
                    .get_mut(k)?
                    .as_object_mut()?;
            }
            node.get_mut(key)
        }
        SiteField::Transform(_) => None,
    }
}

/// Every field below `node`'s subsystems, at any depth, other than a
/// `subsystems` map itself, as `(subsystem key path, field key)` in document
/// order.
fn subsystem_fields(
    node: &Map<String, Value>,
    prefix: &[String],
    out: &mut Vec<(Vec<String>, String)>,
) {
    let Some(Value::Object(subs)) = node.get("subsystems") else {
        return;
    };
    for (k, sub) in subs {
        let Value::Object(sub) = sub else {
            continue;
        };
        let mut path = prefix.to_vec();
        path.push(k.clone());
        for f in sub.keys() {
            if f != "subsystems" {
                out.push((path.clone(), f.clone()));
            }
        }
        subsystem_fields(sub, &path, out);
    }
}

/// The lowering proper (esm-spec §9.6.3, §9.6.4 rules 1, 3 and 4): per
/// component, the fixpoint of its `match` rules over each non-template field
/// (each firing writes a reference, constraint 7); then each coupling
/// `variable_map` transform against the rules of the component that receives
/// it; then, per component, rule 3 inside the bodies of the templates its
/// references reach (updating its `expression_templates` block) and the
/// call-site checks on its surviving references. The rewritten trees are left
/// in `sites` for the caller to write back. Mirrors the Julia reference
/// `lower_expression_templates`.
fn lower_components(
    root: &mut Map<String, Value>,
    lowerings: &mut Vec<(&'static str, String, Lowering)>,
    sites: &mut Vec<Site>,
) -> Result<(), ExpressionTemplateError> {
    // The consuming document's merged index_sets registry (post-§9.7.5): the
    // namespace `where` shape constraints resolve against at registration
    // (esm-spec §9.6.1 — `operator_constraint_unknown_index_set` for a name not
    // declared here).
    let iset_names: std::collections::HashSet<String> = root
        .get("index_sets")
        .and_then(|v| v.as_object())
        .map(|o| o.keys().cloned().collect())
        .unwrap_or_default();
    let enums = root.get("enums").cloned();

    // Models are registered first; a reaction system never overwrites a
    // same-named model as the receiver of a coupling transform.
    let mut by_name: std::collections::HashMap<String, usize> = std::collections::HashMap::new();

    for compkind in ["models", "reaction_systems"] {
        let Some(Value::Object(comps)) = root.get_mut(compkind) else {
            continue;
        };
        for (cname, comp_value) in comps.iter_mut() {
            let Value::Object(comp) = comp_value else {
                continue;
            };
            let scope_base = format!("{compkind}.{cname}");
            // A model mounted as a subsystem keeps its references and brings
            // its template definitions; they join this component's registry
            // here (esm-spec §9.6.4 rule 1).
            let owners = hoist_mounted_templates(comp, cname);
            // Static shape environment for `where` constraint evaluation
            // (esm-spec §9.6.1): declared variable shapes only.
            let shape_env = component_shape_env(comp);
            // esm-spec §9.6.4 rule 1 (Option B): DO NOT remove the block — it is
            // the retained registered registry that emit materializes (rule 5)
            // and Expand consumes (rule 2). CLONE it to build the registries.
            let mut templates: Map<String, Value> = comp
                .get("operators")
                .and_then(|v| v.as_object())
                .cloned()
                .unwrap_or_default();
            validate_templates(&templates, &scope_base)?;
            // Registration-time body CHECKING (esm-spec §9.7.3, Option B):
            // validate the body-reference DAG (acyclic, depth-bounded,
            // references resolve to match-less templates). Bodies are NOT
            // inlined — references are preserved (§9.6.4).
            validate_template_body_references(&templates, &scope_base)?;
            // esm 2.4.0 (esm-spec §9.6.12): every definition records the
            // defined operator it defines, written onto its registry entry;
            // a core operator's name is reserved.
            let mut inferred = false;
            for (tname, decl) in templates.iter_mut() {
                check_defines_not_core(tname, decl, &scope_base)?;
                if let Value::Object(obj) = decl
                    && !obj.contains_key("defines")
                {
                    let d = definition_defines(tname, &Value::Object(obj.clone()));
                    obj.insert("defines".to_string(), Value::String(d));
                    inferred = true;
                }
            }
            if inferred {
                comp.insert("operators".to_string(), Value::Object(templates.clone()));
            }
            let named = build_named(&templates);
            let Rules {
                rules,
                call_rules,
                arities,
            } = collect_rules(&templates, &named, &iset_names, &scope_base)?;
            let l = Lowering {
                named,
                rules,
                call_rules,
                arities,
                owners,
                call_scope: std::cell::RefCell::new(vec![String::new()]),
                shape_env,
                enums: enums.clone(),
                scope: scope_base.clone(),
                depth: std::cell::RefCell::new(PtrMemo::default()),
            };
            let idx = lowerings.len();
            // Outermost-first, priority-ordered, bounded-fixpoint rewrite per
            // non-template field (esm-spec §9.6.3): each firing writes a
            // reference to its rule; references are leaves for matching and
            // the walk descends into their bindings (§9.6.4 rule 4).
            // When a subsystem owns a definition the component does not, each
            // subsystem's fields are positions of their own, rewritten in that
            // subsystem's call scope (esm-spec §4.7, §9.6.12).
            let mut fields: Vec<(Vec<String>, String)> = Vec::new();
            for k in comp.keys() {
                if k == "operators" {
                    continue;
                }
                if k == "subsystems" && l.has_local_definitions() {
                    subsystem_fields(comp, &[], &mut fields);
                } else {
                    fields.push((Vec::new(), k.clone()));
                }
            }
            for (path, k) in fields {
                let field = if path.is_empty() {
                    SiteField::Comp {
                        compkind,
                        cname: cname.clone(),
                        key: k,
                    }
                } else {
                    SiteField::Sub {
                        compkind,
                        cname: cname.clone(),
                        path,
                        key: k,
                    }
                };
                let Some(child) = comp_slot(comp, &field) else {
                    continue;
                };
                let parked = park_plain(child, l.has_rules());
                let orig = to_shared(child);
                let (scope, call_scope) = match &field {
                    SiteField::Sub { path, key, .. } => (
                        format!(
                            "{scope_base}.subsystems.{}.{key}",
                            path.join(".subsystems.")
                        ),
                        path.join("."),
                    ),
                    SiteField::Comp { key, .. } => (format!("{scope_base}.{key}"), String::new()),
                    SiteField::Transform(_) => unreachable!("a component field"),
                };
                sites.push(Site {
                    comp: idx,
                    field,
                    orig: orig.clone(),
                    tree: orig.clone(),
                    parked,
                    scope: scope.clone(),
                    call_scope: call_scope.clone(),
                });
                let (tree, _) = l.with_call_scope(vec![call_scope], || {
                    rewrite_to_fixpoint(&orig, &l, &scope, None)
                })?;
                sites.last_mut().expect("just pushed").tree = tree;
            }
            by_name.entry(cname.clone()).or_insert(idx);
            lowerings.push((compkind, cname.clone(), l));
        }
    }

    // Coupling `variable_map` expression transforms (esm-spec §10.4/§10.5) are
    // rewritten against the rules of the component that owns the entry's `to`
    // target — the RECEIVING component, where a regridding library import
    // (§9.7) lives — exactly as a field of that component would be.
    if let Some(Value::Array(entries)) = root.get("coupling") {
        for (idx, entry) in entries.iter().enumerate() {
            let Some(obj) = entry.as_object() else {
                continue;
            };
            if obj.get("type").and_then(|v| v.as_str()) != Some("variable_map") {
                continue;
            }
            let Some(transform) = obj.get("transform").filter(|t| t.is_object()) else {
                continue;
            };
            let Some(comp_name) = obj
                .get("to")
                .and_then(|v| v.as_str())
                .map(|t| t.split('.').next().unwrap_or(""))
            else {
                continue;
            };
            let Some(&li) = by_name.get(comp_name) else {
                continue;
            };
            let l = &lowerings[li].2;
            let scope = format!("coupling[{idx}].transform");
            let orig = to_shared(transform);
            let (tree, _) = rewrite_to_fixpoint(&orig, l, &scope, None)?;
            sites.push(Site {
                comp: li,
                field: SiteField::Transform(idx),
                orig,
                tree,
                parked: Vec::new(),
                scope,
                call_scope: String::new(),
            });
        }
    }

    // esm-spec §9.6.4 rule 3: the rules apply inside the bodies of the
    // templates the references reach, once per template instance, without
    // expanding any reference. esm-spec §9.6.4 rule 1 (Option B): the
    // component's `expression_templates` block is RETAINED — the registry
    // emit materializes (§9.6.4 rule 5) and Expand consumes (§9.6.4 rule 2).
    for (li, (compkind, cname, l)) in lowerings.iter_mut().enumerate() {
        let mut comp_sites: Vec<(String, Sv)> = sites
            .iter()
            .filter(|s| s.comp == li)
            .map(|s| {
                let scope = match &s.field {
                    SiteField::Comp { .. } | SiteField::Sub { .. } => s.scope.clone(),
                    SiteField::Transform(_) => format!("{} coupling transform", l.scope),
                };
                (scope, s.tree.clone())
            })
            .collect();
        let updates = apply_rule3(l, &mut comp_sites)?;
        for (s, (_, tree)) in sites.iter_mut().filter(|s| s.comp == li).zip(comp_sites) {
            s.tree = tree;
        }
        if !updates.is_empty()
            && let Some(Value::Object(comp)) = root
                .get_mut(*compkind)
                .and_then(|c| c.as_object_mut())
                .and_then(|c| c.get_mut(cname.as_str()))
        {
            let block = comp
                .entry("operators")
                .or_insert_with(|| Value::Object(Map::new()));
            if let Value::Object(block) = block {
                for (n, decl) in updates {
                    block.insert(n, to_value(&decl));
                }
            }
        }
        // Call-site checks on surviving references (§9.6.9): unknown name /
        // bindings mismatch, against the registry as rule 3 left it.
        for s in sites.iter().filter(|s| s.comp == li) {
            let scope = match &s.field {
                SiteField::Comp { .. } | SiteField::Sub { .. } => s.scope.clone(),
                SiteField::Transform(_) => format!("{} coupling transform", l.scope),
            };
            check_surviving_refs(&s.tree, &l.named, &scope, &mut PtrSet::default())?;
        }
        // esm-spec §9.6.12 "Arity": surviving calls in the component, in the
        // transforms it receives, and in the bodies its references reach.
        if !l.arities.is_empty() {
            let mut reached = std::collections::BTreeSet::new();
            for s in sites.iter().filter(|s| s.comp == li) {
                let scope = match &s.field {
                    SiteField::Comp { .. } | SiteField::Sub { .. } => s.scope.clone(),
                    SiteField::Transform(_) => format!("{} coupling transform", l.scope),
                };
                l.with_call_scope(vec![s.call_scope.clone()], || {
                    check_call_arity(&s.tree, l, &scope, &mut PtrSet::default())
                })?;
                reached_definitions(&mut reached, &s.tree, &l.named);
            }
            for r in &reached {
                let body = decl_body(&l.named[r]);
                let scope = format!("{}.operators.{r}", l.scope);
                l.with_call_scope(l.owner_scope(r), || {
                    check_call_arity(&body, l, &scope, &mut PtrSet::default())
                })?;
            }
        }
        // An entry only subsystems own is no callable definition of the
        // component (esm-spec §9.6.3 constraint 4): it is written
        // `reference_only` (§9.6.1), so the loaded, emitted and flattened
        // registries say so and emit → load is a fixed point. Mirrors the
        // Julia reference `_mark_subsystem_owned!`.
        let sub_owned: Vec<&String> = l
            .owners
            .iter()
            .filter(|(_, os)| !os.iter().any(String::is_empty))
            .map(|(n, _)| n)
            .collect();
        if !sub_owned.is_empty()
            && let Some(Value::Object(block)) = root
                .get_mut(*compkind)
                .and_then(|c| c.as_object_mut())
                .and_then(|c| c.get_mut(cname.as_str()))
                .and_then(|c| c.get_mut("operators"))
        {
            for n in sub_owned {
                if let Some(Value::Object(d)) = block.get_mut(n.as_str())
                    && d.get("reference_only") != Some(&Value::Bool(true))
                {
                    d.insert("reference_only".to_string(), Value::Bool(true));
                }
            }
        }
    }
    Ok(())
}

/// esm-spec §9.6.12 "Arity": a call of a defined operator `N` that survives
/// the fixpoint, when definitions of `N` are in scope and none takes the call's
/// operand count, is `operator_arity_mismatch` at load. A name with no
/// definition in scope is a placeholder, whatever its arity. Mirrors the Julia
/// reference `_check_call_arity`.
fn check_call_arity(
    node: &Sv,
    l: &Lowering,
    scope: &str,
    seen: &mut PtrSet,
) -> Result<(), ExpressionTemplateError> {
    match &**node {
        SNode::Arr(items) => {
            if !seen.insert(node) {
                return Ok(());
            }
            for c in items {
                check_call_arity(c, l, scope, seen)?;
            }
        }
        SNode::Obj(fields) => {
            if !seen.insert(node) {
                return Ok(());
            }
            let counts: Option<std::collections::BTreeSet<usize>> = obj_op(fields)
                .filter(|op| !is_core_operator(op))
                .and_then(|op| l.arities.get(op))
                .map(|defs| {
                    defs.iter()
                        .filter(|(_, n)| l.callable_here(n))
                        .map(|(k, _)| *k)
                        .collect()
                })
                .filter(|c: &std::collections::BTreeSet<usize>| !c.is_empty());
            if let Some(op) = obj_op(fields)
                && let Some(counts) = counts
            {
                let k = match obj_get(fields, "args").map(|a| &**a) {
                    Some(SNode::Arr(a)) => a.len(),
                    Some(SNode::Data(v)) => v.as_array().map_or(0, Vec::len),
                    _ => 0,
                };
                if !counts.contains(&k) {
                    let takes: Vec<String> = counts.iter().map(usize::to_string).collect();
                    return Err(err(
                        codes::OPERATOR_ARITY_MISMATCH,
                        format!(
                            "{scope}: a call of the defined operator '{op}' carries {k} \
                             operand(s), but its definitions in scope take {} (esm-spec \
                             §9.6.12)",
                            takes.join(", ")
                        ),
                    ));
                }
            }
            for (_, v) in fields {
                check_call_arity(v, l, scope, seen)?;
            }
        }
        _ => {}
    }
    Ok(())
}

/// The registry entries a node's references reach, transitively through
/// bodies. Mirrors the Julia reference `_reached_definitions!`.
fn reached_definitions(out: &mut std::collections::BTreeSet<String>, node: &Sv, named: &Named) {
    let mut names = Vec::new();
    collect_apply_names_sv(node, &mut names, &mut PtrSet::default());
    for r in names {
        if out.contains(&r) {
            continue;
        }
        let Some(d) = named.get(&r) else {
            continue;
        };
        out.insert(r);
        reached_definitions(out, &decl_body(d), named);
    }
}

/// Post-expansion validator (esm-spec §4.3.2 / §9.6.4): every `makearray`
/// region bound pair `[start, stop]` on the expanded, metaparameter-folded
/// tree must satisfy `stop >= start - 1`. `stop == start - 1` is the canonical
/// EMPTY bound — the region covers no elements and contributes nothing (the
/// spelling an interior region like `[2, N-1]` folds to at the minimum
/// admissible extent `N = 2`). `stop < start - 1` is INVERTED and rejected with
/// `makearray_region_inverted`: it is almost always an authoring bug (an
/// interior stencil instantiated below its minimum extent, e.g. `[2, N-1]` at
/// `N = 1` folding to `[2, 0]`), and silently treating it as empty would hide
/// the defect. Template bodies are skipped — pre-substitution bounds may
/// legally carry metaparameter names there; only concrete integer pairs are
/// checked (a fully-folded document tree carries nothing else in bound
/// position). Mirrors the Julia reference `_validate_makearray_regions`.
///
/// Hand-rolled rather than `crate::json_visit`: descent is key-dependent
/// (`expression_templates` subtrees are skipped) and the diagnostic needs the
/// offender's path with an early error return.
pub fn validate_makearray_regions(tree: &Value, path: &str) -> Result<(), ExpressionTemplateError> {
    validate_makearray_regions_at(tree, &JsonPath::Root(path))
}

fn validate_makearray_regions_at(
    tree: &Value,
    at: &JsonPath<'_>,
) -> Result<(), ExpressionTemplateError> {
    match tree {
        Value::Array(arr) if crate::json_visit::is_number_data(arr) => Ok(()),
        Value::Array(arr) => {
            for (i, child) in arr.iter().enumerate() {
                validate_makearray_regions_at(child, &JsonPath::Index(at, i))?;
            }
            Ok(())
        }
        Value::Object(obj) => {
            check_makearray_regions(obj, at)?;
            for (k, v) in obj {
                // Template bodies/matches are pre-substitution trees; bounds may
                // legally carry metaparameter names or fold later (§9.7.6).
                if k == "operators" {
                    continue;
                }
                validate_makearray_regions_at(v, &JsonPath::Key(at, k))?;
            }
            Ok(())
        }
        _ => Ok(()),
    }
}

/// [`validate_makearray_regions`]' check on one object node at `at`.
fn check_makearray_regions(
    obj: &Map<String, Value>,
    at: &JsonPath<'_>,
) -> Result<(), ExpressionTemplateError> {
    if obj.get("op").and_then(|v| v.as_str()) == Some("makearray")
        && let Some(regions) = obj.get("regions").and_then(|v| v.as_array())
    {
        for (ri, region) in regions.iter().enumerate() {
            let Some(region_arr) = region.as_array() else {
                continue;
            };
            for (di, bounds) in region_arr.iter().enumerate() {
                let Some(bounds_arr) = bounds.as_array() else {
                    continue;
                };
                if bounds_arr.len() != 2 {
                    continue;
                }
                // Only concrete integer pairs are checked; a fully folded
                // document carries nothing else here. `as_i64` rejects
                // booleans and floats, matching the Julia `Integer && !Bool`
                // gate.
                let (Some(lo), Some(hi)) = (bounds_arr[0].as_i64(), bounds_arr[1].as_i64()) else {
                    continue;
                };
                if hi < lo - 1 {
                    return Err(err(
                        codes::MAKEARRAY_REGION_INVERTED,
                        format!(
                            "{at}: makearray regions[{ri}] dimension {di} bound pair \
                             [{lo}, {hi}] is inverted (stop < start - 1). An empty bound \
                             is spelled [start, start-1] and contributes no elements \
                             (esm-spec §4.3.2); a further-inverted pair is an authoring \
                             error — e.g. an interior stencil region [2, N-1] instantiated \
                             at N below the scheme's minimum extent (§9.6.8)."
                        ),
                    ));
                }
            }
        }
    }
    Ok(())
}
