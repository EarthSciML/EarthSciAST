use super::*;

// ---------------------------------------------------------------------------
// Eager-expansion carve-out: the rewrite-target op tier T (esm-spec §9.6.4
// rule 3 / RFC out-of-line-expression-templates §7.2)
// ---------------------------------------------------------------------------

/// The tier-**T** ops that ARE evaluable-core registry entries and so cannot be
/// derived from "not in the core": the structural derivative `D` (a SPATIAL `D`
/// is a rewrite target) and the two load-eliminated forms `table_lookup` /
/// `enum` (esm-spec §4.5 / §9.5).
///
/// The open rewrite-target sugar ops (`grad`/`div`/`laplacian`/`curl`/`∇`/
/// `integral`) and any unregistered custom op are DELIBERATELY not hand-listed
/// here — [`op_in_t`] derives them from "not in the evaluable core"
/// (`!is_core_op`), so the sugar vocabulary lives in exactly one place
/// (`op_registry`) and this list never drifts from it (that is precisely why a
/// hand-list previously carried `grad`/`div`/`laplacian`/`integral` but silently
/// omitted `curl`/`∇`). `apply_expression_template` itself is excluded.
const REWRITE_TARGET_OPS: [&str; 3] = ["D", "table_lookup", "enum"];

/// True iff op string `op` is a member of the rewrite-target tier **T**
/// (esm-spec §9.6.4 rule 3): one of the named rewrite-target ops, or an op with
/// no evaluable-core registry entry (an open-namespace custom op). The template
/// reference op itself is never in T. Mirrors the Julia reference `_op_in_T`.
fn op_in_t(op: &str) -> bool {
    if op == APPLY_OP {
        return false;
    }
    if REWRITE_TARGET_OPS.contains(&op) {
        return true;
    }
    !crate::op_registry::is_core_op(op)
}

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

/// True iff `node` contains, ANYWHERE within it (descending through every
/// field, including the `bindings` of nested `apply_expression_template`
/// nodes), an object whose `op` is in **T** (`op_in_t`). Does NOT follow
/// references to other templates — that transitive step is
/// `template_target_bearing`. Mirrors the Julia reference `_direct_T_op`.
fn direct_t_op(node: &Sv, seen: &mut PtrSet) -> bool {
    match &**node {
        SNode::Arr(items) => {
            if !seen.insert(node) {
                return false;
            }
            items.iter().any(|c| direct_t_op(c, seen))
        }
        SNode::Obj(fields) => {
            if !seen.insert(node) {
                return false;
            }
            if let Some(op) = obj_op(fields)
                && op_in_t(op)
            {
                return true;
            }
            fields.iter().any(|(_, v)| direct_t_op(v, seen))
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
/// body-reference DAG, shared by [`template_target_bearing`] and
/// [`template_manifold_bearing`]. For every template in `named` the flag is
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

/// Compute, for every template in `named`, its **target-bearing** flag
/// (esm-spec §9.6.4 rule 3): a template is target-bearing iff its body contains
/// an op in **T** anywhere (including inside nested references' `bindings`), OR
/// it references — transitively through the §9.7.3-checked acyclic DAG — a
/// target-bearing template. The DAG is acyclic (checked by
/// `validate_template_body_references`), so a memoized DFS terminates. Mirrors the Julia
/// reference `_template_target_bearing`.
fn template_target_bearing(named: &Named) -> std::collections::HashMap<String, bool> {
    transitive_reachable(named, |body| direct_t_op(body, &mut PtrSet::default()))
}

/// Whether an `apply_expression_template` node (given its object `fields`) is
/// **eager** (esm-spec §9.6.4 rule 3): its referenced template is
/// target-bearing, OR any of its `bindings` values contains an op in **T**.
/// Mirrors the Julia reference `_ref_is_eager`.
fn ref_is_eager(
    fields: &[(String, Sv)],
    target_bearing: &std::collections::HashMap<String, bool>,
) -> bool {
    let Some(SNode::Str(name)) = obj_get(fields, "name").map(|v| &**v) else {
        return false;
    };
    if target_bearing.get(name).copied().unwrap_or(false) {
        return true;
    }
    match obj_get(fields, "bindings") {
        Some(b) => direct_t_op(b, &mut PtrSet::default()),
        None => false,
    }
}

/// Maximum number of productive rewrite passes before a file is rejected as
/// non-converging (esm-spec §9.6.3, diagnostic `rewrite_rule_nonterminating`).
/// Pinned identically across all bindings so the accept/reject decision — and
/// the resulting fixpoint — is byte-identical everywhere.
const MAX_REWRITE_PASSES: usize = 64;

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
    /// The pattern Expression a node is matched against. Patterns are small
    /// and never composed, so the owned view is kept.
    pattern: Value,
    /// The replacement Expression instantiated with the bound metavariables
    /// — the RAW (uninlined, Option B) body as a shared DAG.
    body: Sv,
    /// Selection precedence (esm-spec §9.6.3): higher fires first; ties break by
    /// declaration order. Absent ⇒ `0`.
    priority: i64,
    /// Registered static match-scoping constraints (esm-spec §9.6.1): param →
    /// required shape (ordered index-set names). `None` when the rule carries
    /// no `where` block. Checked as part of match eligibility.
    where_c: Option<std::collections::BTreeMap<String, Vec<String>>>,
}

/// Bundles the per-component rewrite inputs threaded through each pass.
struct RewriteCtx<'a> {
    /// Template name → decl object (shared node): the named-expansion lookup
    /// table for eager references and surviving-reference leaf semantics.
    named: &'a Named,
    /// Auto-applied `match` rules, **pre-sorted** highest-`priority`-first with
    /// ties broken by declaration order (esm-spec §9.6.3). `rewrite_pass` fires
    /// the first rule in this order whose pattern matches a node.
    rules: &'a [MatchRule],
    /// The enclosing component's static shape environment (declared variable
    /// name → declared shape), consulted by a rule's `where` constraints
    /// (esm-spec §9.6.1). Empty when no component context (coupling transforms
    /// use the receiving component's environment).
    shape_env: &'a std::collections::BTreeMap<String, Vec<String>>,
    /// Per-template target-bearing flags (esm-spec §9.6.4 rule 3): drive the
    /// eager pre-pass and the surviving-reference leaf semantics.
    target_bearing: &'a std::collections::HashMap<String, bool>,
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
/// unknown name is `template_constraint_unknown_index_set` (esm-spec
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
                    codes::TEMPLATE_CONSTRAINT_UNKNOWN_INDEX_SET,
                    format!(
                        "{scope}.expression_templates.{tname}: where.{p}.shape names index set \
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

/// Collect the auto-applied `match` rules from a component's templates in
/// declaration order (serde_json's `preserve_order` feature keeps source
/// order), then pre-sort them by descending `priority` with ties broken by
/// declaration order (a stable sort preserves push order for equal
/// priorities). Each rule's `where` block is normalized and its referenced
/// index sets resolved against the consuming document's registry (`iset_names`)
/// at registration — an unknown name is `template_constraint_unknown_index_set`
/// (esm-spec §9.6.1). The old static self-reintroduction / nontermination
/// pre-check is GONE — the bounded fixpoint (`MAX_REWRITE_PASSES`) is now the
/// sole termination guard (esm-spec §9.6.3).
fn collect_match_rules(
    templates: &Map<String, Value>,
    named: &Named,
    iset_names: &std::collections::HashSet<String>,
    scope: &str,
) -> Result<Vec<MatchRule>, ExpressionTemplateError> {
    let mut rules = Vec::new();
    for (name, decl) in templates {
        let Some(obj) = decl.as_object() else {
            continue;
        };
        let Some(pattern) = obj.get("match") else {
            continue;
        };
        let param_set: std::collections::HashSet<String> = obj
            .get("params")
            .and_then(|p| p.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| v.as_str().map(String::from))
                    .collect()
            })
            .unwrap_or_default();
        // The RAW (uninlined, Option B) body as a shared DAG. On a fired rule
        // it is instantiated by pure substitution, then the eager pre-pass
        // expands any target-bearing reference it introduces (§9.6.4 rule 4).
        let body = named
            .get(name)
            .map(decl_body)
            .unwrap_or_else(|| Rc::new(SNode::Null));
        let where_c = registered_where(obj, iset_names, scope, name)?;
        rules.push(MatchRule {
            name: name.clone(),
            param_set,
            pattern: pattern.clone(),
            body,
            priority: rule_priority(obj),
            where_c,
        });
    }
    // Deterministic selection order (esm-spec §9.6.3): highest `priority` first,
    // ties broken by declaration order. `sort_by_key` is stable, so equal
    // priorities retain their push (declaration) order.
    rules.sort_by_key(|r| std::cmp::Reverse(r.priority));
    Ok(rules)
}

/// Structurally match `pattern` against `target`, binding metavariables (names
/// in `params`) into `binds`. A metavariable in an operand/`args` position
/// binds the matched sub-AST; in a scalar field it binds the matched literal.
/// A metavariable appearing twice must bind consistently. Pattern object keys
/// are matched as a subset: `target` MAY carry extra keys.
fn try_match(
    pattern: &Value,
    target: &Sv,
    params: &std::collections::HashSet<String>,
    binds: &mut Binds,
) -> bool {
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
                .all(|(p, t)| try_match(p, t, params, binds)),
            _ => false,
        },
        Value::Object(pobj) => match &**target {
            SNode::Obj(tfields) => pobj.iter().all(|(k, pv)| match obj_get(tfields, k) {
                Some(tv) => try_match(pv, tv, params, binds),
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
/// caller (`expand_eager` / `expand_all`) recursively expands the result.
/// Mirrors the Julia reference `_expand_apply`.
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
            codes::APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
            format!("{scope}: apply_expression_template node missing or empty 'name'"),
        )
    })?;
    if name.is_empty() {
        return Err(err(
            codes::APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
            format!("{scope}: apply_expression_template 'name' must be non-empty"),
        ));
    }
    let decl = named.get(name).ok_or_else(|| {
        err(
            codes::APPLY_EXPRESSION_TEMPLATE_UNKNOWN_TEMPLATE,
            format!("{scope}: apply_expression_template references undeclared template '{name}'"),
        )
    })?;
    let SNode::Obj(decl_fields) = &**decl else {
        return Err(err(
            codes::APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
            format!("{scope}: template '{name}' declaration is not an object"),
        ));
    };
    let bindings: &[(String, Sv)] = match obj_get(node, "bindings").map(|v| &**v) {
        Some(SNode::Obj(fields)) => fields,
        _ => {
            return Err(err(
                codes::APPLY_EXPRESSION_TEMPLATE_BINDINGS_MISMATCH,
                format!("{scope}: apply_expression_template '{name}' missing 'bindings' object"),
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
                codes::APPLY_EXPRESSION_TEMPLATE_BINDINGS_MISMATCH,
                format!(
                    "{scope}: apply_expression_template '{name}' missing binding for param '{p}'"
                ),
            ));
        }
    }
    for (p, _) in bindings {
        if !declared.contains(p.as_str()) {
            return Err(err(
                codes::APPLY_EXPRESSION_TEMPLATE_BINDINGS_MISMATCH,
                format!("{scope}: apply_expression_template '{name}' supplies unknown param '{p}'"),
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

/// The eager-expansion pre-pass (esm-spec §9.6.4 rule 3): expand — by pure
/// substitution, innermost-first — every EAGER `apply_expression_template`
/// node, and only eager nodes. Non-eager (surviving) references are returned
/// intact. Consumes no `MAX_REWRITE_PASSES` budget. Mirrors the Julia
/// reference `_expand_eager`.
fn expand_eager(
    node: &Sv,
    named: &Named,
    target_bearing: &std::collections::HashMap<String, bool>,
    scope: &str,
    memo: &mut PtrMemo<Sv>,
) -> Result<Sv, ExpressionTemplateError> {
    match &**node {
        SNode::Obj(fields) => {
            if let Some(hit) = memo.get(node) {
                return Ok(hit.clone());
            }
            let res = if obj_op(fields) == Some(APPLY_OP) {
                // Innermost-first: expand eager references inside the bindings.
                let mut newfields = fields.clone();
                let mut b_changed = false;
                if let Some(b_idx) = newfields.iter().position(|(k, _)| k == "bindings")
                    && let SNode::Obj(b) = &*newfields[b_idx].1.clone()
                {
                    let mut nb = Vec::with_capacity(b.len());
                    for (k, v) in b {
                        let rv = expand_eager(v, named, target_bearing, scope, memo)?;
                        b_changed |= !Rc::ptr_eq(&rv, v);
                        nb.push((k.clone(), rv));
                    }
                    if b_changed {
                        newfields[b_idx].1 = Rc::new(SNode::Obj(nb));
                    }
                }
                if ref_is_eager(&newfields, target_bearing) {
                    let body = expand_apply(&newfields, named, scope)?;
                    expand_eager(&body, named, target_bearing, scope, memo)?
                } else if b_changed {
                    Rc::new(SNode::Obj(newfields))
                } else {
                    node.clone()
                }
            } else {
                let mut changed = false;
                let mut out = Vec::with_capacity(fields.len());
                for (k, v) in fields {
                    let rv = expand_eager(v, named, target_bearing, scope, memo)?;
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
                let rv = expand_eager(v, named, target_bearing, scope, memo)?;
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

/// Convenience wrapper: run [`expand_eager`] with a fresh memo.
fn expand_eager_root(
    node: &Sv,
    named: &Named,
    target_bearing: &std::collections::HashMap<String, bool>,
    scope: &str,
) -> Result<Sv, ExpressionTemplateError> {
    let mut memo = PtrMemo::default();
    expand_eager(node, named, target_bearing, scope, &mut memo)
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
                expand_all(&body, named, scope, memo)?
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

/// Call-site check for a SURVIVING (non-expanded) `apply_expression_template`
/// reference (esm-spec §9.6.9): the referenced `name` must resolve to an
/// in-scope MATCH-LESS template and `bindings` must cover its `params`
/// exactly. Same diagnostics as [`expand_apply`], but WITHOUT expanding — the
/// reference is preserved (§9.6.4 rule 1). Mirrors `_validate_apply_ref`.
fn validate_apply_ref(
    fields: &[(String, Sv)],
    named: &Named,
    scope: &str,
) -> Result<(), ExpressionTemplateError> {
    let name = match obj_get(fields, "name").map(|v| &**v) {
        Some(SNode::Str(s)) => s.as_str(),
        _ => {
            return Err(err(
                codes::APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
                format!("{scope}: apply_expression_template node missing 'name'"),
            ));
        }
    };
    let decl = named.get(name).ok_or_else(|| {
        err(
            codes::APPLY_EXPRESSION_TEMPLATE_UNKNOWN_TEMPLATE,
            format!("{scope}: apply_expression_template references undeclared template '{name}'"),
        )
    })?;
    if decl_has_match(decl) {
        return Err(err(
            codes::APPLY_EXPRESSION_TEMPLATE_UNKNOWN_TEMPLATE,
            format!(
                "{scope}: apply_expression_template references '{name}', a `match` rewrite rule — \
                 only match-less templates are invocable by name (esm-spec §9.6.2)"
            ),
        ));
    }
    let bindings: &[(String, Sv)] = match obj_get(fields, "bindings").map(|v| &**v) {
        Some(SNode::Obj(b)) => b,
        _ => {
            return Err(err(
                codes::APPLY_EXPRESSION_TEMPLATE_BINDINGS_MISMATCH,
                format!("{scope}: apply_expression_template '{name}' missing 'bindings' object"),
            ));
        }
    };
    let SNode::Obj(decl_fields) = &**decl else {
        return Ok(());
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
                codes::APPLY_EXPRESSION_TEMPLATE_BINDINGS_MISMATCH,
                format!(
                    "{scope}: apply_expression_template '{name}' missing binding for param '{p}'"
                ),
            ));
        }
    }
    for (p, _) in bindings {
        if !declared.contains(p.as_str()) {
            return Err(err(
                codes::APPLY_EXPRESSION_TEMPLATE_BINDINGS_MISMATCH,
                format!("{scope}: apply_expression_template '{name}' supplies unknown param '{p}'"),
            ));
        }
    }
    Ok(())
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

/// One pre-order (outermost-first) rewrite pass over `node` (esm-spec §9.6.3).
/// At each object node the engine tries to fire a rule AT the node BEFORE
/// descending:
///
/// 1. an `apply_expression_template` op is expanded (`expand_apply`), OR
/// 2. the first rule in `ctx.rules` (pre-sorted highest-`priority`-first, ties
///    by declaration order) whose `match` pattern structurally matches the node
///    fires.
///
/// A fired rule's body replaces the node and the walk does NOT descend into
/// that freshly-produced body during this pass (it is revisited next pass). If
/// nothing fires, the walk descends into the node's children. Returns the
/// rewritten node and whether any rewrite occurred in this subtree; `last`
/// records the op (and the firing rule's name) of the most recent rewrite,
/// for the non-convergence diagnostic.
///
/// The walk is identity-memoized and sharing-preserving (mirroring the Julia
/// reference): the rewrite of a node is a pure function of the node itself
/// (pattern matching is structural; the registries and `shape_env` are
/// pass-constant), so a subtree shared under many parents is rewritten ONCE
/// and the shared result respliced — preserving the DAG `substitute` builds
/// instead of exploding it back into a tree, and keeping pass cost linear in
/// UNIQUE nodes. Unchanged subtrees are returned by identity. Each memo
/// entry also records the subtree's final `last` value (when it rewrote
/// anything), replayed on memo hits so the non-convergence diagnostic sees
/// exactly what an unmemoized sequential walk would have seen.
fn rewrite_pass(
    node: &Sv,
    ctx: &RewriteCtx,
    scope: &str,
    last: &mut String,
    memo: &mut PtrMemo<(Sv, bool, Option<String>)>,
) -> Result<(Sv, bool), ExpressionTemplateError> {
    match &**node {
        SNode::Arr(items) => {
            if let Some((res, ch, l)) = memo.get(node) {
                if let Some(l) = l {
                    *last = l.clone();
                }
                return Ok((res.clone(), *ch));
            }
            let mut changed = false;
            let mut out = Vec::with_capacity(items.len());
            for c in items {
                let (nc, ch) = rewrite_pass(c, ctx, scope, last, memo)?;
                out.push(nc);
                changed |= ch;
            }
            let res = if changed {
                Rc::new(SNode::Arr(out))
            } else {
                node.clone()
            };
            memo.insert(node, (res.clone(), changed, changed.then(|| last.clone())));
            Ok((res, changed))
        }
        SNode::Obj(fields) => {
            if let Some((res, ch, l)) = memo.get(node) {
                if let Some(l) = l {
                    *last = l.clone();
                }
                return Ok((res.clone(), *ch));
            }
            let op = obj_op(fields);
            // (1) Outermost-first: fire a rule AT this node before descending.
            if op == Some(APPLY_OP) {
                // esm-spec §9.6.4 rule 4 (Option B): the engine treats a
                // surviving (non-eager) reference as a LEAF — it does not
                // descend into its `bindings`, no rule fires inside it, and it
                // survives the fixpoint. Eager references were removed by the
                // pre-pass; a defensive check keeps any eager node a caller
                // passed in unexpanded correct.
                if ref_is_eager(fields, ctx.target_bearing) {
                    *last = APPLY_OP.to_string();
                    let res = expand_eager_root(node, ctx.named, ctx.target_bearing, scope)?;
                    memo.insert(node, (res.clone(), true, Some(last.clone())));
                    return Ok((res, true));
                }
                memo.insert(node, (node.clone(), false, None));
                return Ok((node.clone(), false));
            }
            for rule in ctx.rules {
                let mut binds = Binds::new();
                // Constraint filtering is part of match ELIGIBILITY (esm-spec
                // §9.6.3 constraint 2): a `where`-excluded rule is treated
                // exactly like a non-matching rule at this node, so the scan
                // proceeds to the next candidate in priority / declaration order.
                if try_match(&rule.pattern, node, &rule.param_set, &mut binds)
                    && where_satisfied(&rule.where_c, &binds, ctx.shape_env)
                {
                    *last = format!("{} (rule '{}')", op.unwrap_or(""), rule.name);
                    // Instantiate by pure substitution (through nested
                    // references' `bindings`; `name` is never a site). An eager
                    // reference introduced by the instantiation expands as part
                    // of the same rewrite (§9.6.4 rule 4).
                    let body = substitute(&rule.body, &binds);
                    let res = expand_eager_root(&body, ctx.named, ctx.target_bearing, scope)?;
                    memo.insert(node, (res.clone(), true, Some(last.clone())));
                    return Ok((res, true));
                }
            }
            // (2) No rule fired here — descend into children.
            let mut changed = false;
            let mut out = Vec::with_capacity(fields.len());
            for (k, v) in fields {
                let (nv, ch) = rewrite_pass(v, ctx, scope, last, memo)?;
                out.push((k.clone(), nv));
                changed |= ch;
            }
            let res = if changed {
                Rc::new(SNode::Obj(out))
            } else {
                node.clone()
            };
            memo.insert(node, (res.clone(), changed, changed.then(|| last.clone())));
            Ok((res, changed))
        }
        _ => Ok((node.clone(), false)),
    }
}

/// Drive `rewrite_pass` to a fixpoint (esm-spec §9.6.3): repeat pre-order passes
/// until a pass performs zero rewrites, or reject the file with
/// `rewrite_rule_nonterminating` once `MAX_REWRITE_PASSES` productive passes
/// have run without converging. This bound — not a static check — is the
/// authoritative termination guard, so a self-reintroducing rule fails to
/// converge rather than being flagged up front. Selection and traversal are
/// fully deterministic, so all bindings produce byte-identical fixpoints.
fn rewrite_to_fixpoint(
    node: &Sv,
    ctx: &RewriteCtx,
    scope: &str,
) -> Result<Sv, ExpressionTemplateError> {
    // esm-spec §9.6.4 rule 3 / §7.1 step 5: the eager-expansion pre-pass runs
    // BEFORE the fixpoint and consumes no `MAX_REWRITE_PASSES` budget. It
    // removes every eager reference (target-bearing, or T-op in bindings) so
    // the fixpoint and the later `unlowered_operator` gate walk a tree in which
    // no rewrite-target op hides inside a surviving reference.
    let mut current = expand_eager_root(node, ctx.named, ctx.target_bearing, scope)?;
    let mut last = String::new();
    for _ in 0..MAX_REWRITE_PASSES {
        // Fresh memo each pass: a pass's rewrite of a node is pass-local
        // (freshly-produced bodies are deliberately not revisited until the
        // next pass). The memo (and thus every raw-pointer key's referent)
        // is kept alive by `current` plus the memo's own `Rc` handles for
        // the duration of the pass.
        let mut memo = PtrMemo::default();
        let (next, changed) = rewrite_pass(&current, ctx, scope, &mut last, &mut memo)?;
        current = next;
        if !changed {
            return Ok(current); // fixpoint reached
        }
    }
    Err(err(
        codes::REWRITE_RULE_NONTERMINATING,
        format!(
            "{scope}: expression-template rewriting did not converge within \
             MAX_REWRITE_PASSES={MAX_REWRITE_PASSES} passes (last rewritten op '{last}'). \
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
    let Some(obj) = view.as_object() else {
        return Ok(());
    };
    let Some(esm) = obj.get("esm").and_then(|v| v.as_str()) else {
        return Ok(());
    };
    let Some((major, minor, _)) = crate::diagnostic::parse_semver(esm) else {
        return Ok(());
    };
    if !(major == 0 && minor < 4) {
        return Ok(());
    }

    let mut offences: Vec<String> = Vec::new();
    for compkind in ["models", "reaction_systems"] {
        if let Some(comps) = obj.get(compkind).and_then(|v| v.as_object()) {
            for (cname, comp) in comps {
                if let Some(comp_obj) = comp.as_object()
                    && comp_obj.contains_key("expression_templates")
                {
                    offences.push(format!("/{compkind}/{cname}/expression_templates"));
                }
            }
        }
    }
    find_apply_paths(view, &mut offences);

    if !offences.is_empty() {
        return Err(err(
            codes::APPLY_EXPRESSION_TEMPLATE_VERSION_TOO_OLD,
            format!(
                "expression_templates / apply_expression_template require esm >= 0.4.0; \
                 file declares {esm}. Offending paths: {}",
                offences.join(", ")
            ),
        ));
    }
    Ok(())
}

/// A per-component rewrite registry captured during model / reaction-system
/// lowering and reused by coupling `variable_map` transforms (esm-spec §10.4)
/// and by the reference-aware validators (§9.6.9): the named-template lookup
/// table (decl nodes as shared DAGs), the pre-sorted auto `match` rules (with
/// their registered `where` constraints), the static shape environment the
/// constraints consult, and the per-template target-bearing flags.
pub(super) struct CompRegistry {
    pub(super) named: Named,
    rules: Vec<MatchRule>,
    shape_env: std::collections::BTreeMap<String, Vec<String>>,
    target_bearing: std::collections::HashMap<String, bool>,
}

/// Build the `named` registry (template name → decl object as a shared DAG)
/// from a component's `expression_templates` block.
pub(super) fn build_named(templates: &Map<String, Value>) -> Named {
    templates
        .iter()
        .map(|(n, d)| (n.clone(), to_shared(d)))
        .collect()
}

/// `Expand(node)` (esm-spec §9.6.4 rule 2) against ONE component
/// `expression_templates` registry: fully expand every surviving
/// `apply_expression_template` reference in `node` by pure substitution to a
/// fixpoint, and return the expanded tree.
///
/// This is the entry point for a NON-ENGINE consumer that must reach its
/// decisions on the expanded form — rule 4's pattern opacity scopes to the
/// §9.6.3 rewrite-rule engine, while every other consumer is governed by rule 2
/// (a reference denotes its expansion; every consumer MAY expand). The
/// projection-pushdown desugar (`pushdown_rewrite.rs`) is the caller: it matches
/// on the expanded view and then edits the reference-preserving call site, so
/// the shared template body stays singly-lowered.
///
/// `templates` is the component's `expression_templates` object. Deterministic
/// and sharing-preserving; the returned tree is a fresh owned `Value`.
pub fn expand_against_registry(
    node: &Value,
    templates: &Map<String, Value>,
    scope: &str,
) -> Result<Value, ExpressionTemplateError> {
    let named = build_named(templates);
    let mut memo = PtrMemo::default();
    let out = expand_all(&to_shared(node), &named, scope, &mut memo)?;
    Ok(to_value(&out))
}

/// True if `value` either declares any non-empty `expression_templates` block
/// (component-level or top-level) or contains any `apply_expression_template`
/// op anywhere. Mirrors the Julia reference `_has_template_machinery`.
fn has_template_machinery(value: &Value) -> bool {
    let Some(obj) = value.as_object() else {
        return false;
    };
    if obj
        .get("expression_templates")
        .and_then(|v| v.as_object())
        .is_some_and(|t| !t.is_empty())
    {
        return true;
    }
    for compkind in ["models", "reaction_systems"] {
        if let Some(comps) = obj.get(compkind).and_then(|v| v.as_object()) {
            for (_, comp) in comps {
                if comp
                    .get("expression_templates")
                    .and_then(|v| v.as_object())
                    .is_some_and(|t| !t.is_empty())
                {
                    return true;
                }
            }
        }
    }
    let mut hits = Vec::new();
    find_apply_paths(value, &mut hits);
    !hits.is_empty()
}

/// Run the load-time rewrite pass (esm-spec §9.6, Option B / esm 0.9.0):
/// eagerly expand target-bearing `apply_expression_template` references,
/// auto-apply each component's `match` rules to a fixpoint, PRESERVE surviving
/// (non-eager) references and each component's `expression_templates` block,
/// and discharge the §9.6.9 reference-aware validators. Mutates `value` in
/// place. Surviving references denote their expansion ([`expand`]); the
/// reference-preserving form travels into emit (§9.6.4 rule 5).
///
/// Pre-condition: the input has been schema-validated.
pub fn lower_expression_templates(value: &mut Value) -> Result<(), ExpressionTemplateError> {
    reject_expression_templates_pre_v04(value)?;

    if value.as_object().is_none() {
        return Ok(());
    }

    // Fast path: files that neither declare `expression_templates` blocks nor
    // use any `apply_expression_template` op need no expansion at all. The
    // §9.6.4 expanded-form validators still apply — the raw tree IS the
    // expanded form.
    if !has_template_machinery(value) {
        validate_geometry_manifolds(value, "")?;
        validate_makearray_regions(value, "")?;
        return Ok(());
    }

    let root = value.as_object_mut().expect("checked object above");

    // The consuming document's merged index_sets registry (post-§9.7.5): the
    // namespace `where` shape constraints resolve against at registration
    // (esm-spec §9.6.1 — `template_constraint_unknown_index_set` for a name not
    // declared here). Captured before the per-component mutable borrows.
    let iset_names: std::collections::HashSet<String> = root
        .get("index_sets")
        .and_then(|v| v.as_object())
        .map(|o| o.keys().cloned().collect())
        .unwrap_or_default();

    // Per-component rewrite registries, captured so coupling `variable_map`
    // expression transforms (esm-spec §10.4) can be rewritten against the
    // RECEIVING component's registry below and the §9.6.9 validators can expand
    // surviving references per-instantiation. Models are registered first; a
    // reaction system never overwrites a same-named model.
    let mut registries: std::collections::HashMap<String, CompRegistry> =
        std::collections::HashMap::new();

    for compkind in ["models", "reaction_systems"] {
        let Some(Value::Object(comps)) = root.get_mut(compkind) else {
            continue;
        };
        for (cname, comp_value) in comps.iter_mut() {
            let Value::Object(comp) = comp_value else {
                continue;
            };
            let scope_base = format!("{compkind}.{cname}");
            // Static shape environment for `where` constraint evaluation
            // (esm-spec §9.6.1): declared variable shapes only.
            let shape_env = component_shape_env(comp);
            // esm-spec §9.6.4 rule 1 (Option B): DO NOT remove the block — it is
            // the retained registered registry that emit materializes (rule 5)
            // and Expand consumes (rule 2). CLONE it to build the registries.
            let templates: Map<String, Value> = comp
                .get("expression_templates")
                .and_then(|v| v.as_object())
                .cloned()
                .unwrap_or_default();
            validate_templates(&templates, &scope_base)?;
            // Registration-time body CHECKING (esm-spec §9.7.3, Option B):
            // validate the body-reference DAG (acyclic, depth-bounded,
            // references resolve to match-less templates). Bodies are NOT
            // inlined — references are preserved (§9.6.4).
            validate_template_body_references(&templates, &scope_base)?;
            let named = build_named(&templates);
            let rules = collect_match_rules(&templates, &named, &iset_names, &scope_base)?;
            let target_bearing = template_target_bearing(&named);
            let ctx = RewriteCtx {
                named: &named,
                rules: &rules,
                shape_env: &shape_env,
                target_bearing: &target_bearing,
            };
            // Outermost-first, priority-ordered, bounded-fixpoint rewrite per
            // non-template field (esm-spec §9.6.3): fires auto `match` rules and
            // eagerly expands target-bearing references; NON-eager references
            // survive (§9.6.4 rule 4). Then call-site checks on surviving
            // references (§9.6.9): unknown name / bindings mismatch.
            let keys: Vec<String> = comp.keys().cloned().collect();
            for k in keys {
                if k == "expression_templates" {
                    continue;
                }
                let scope = format!("{scope_base}.{k}");
                let Some(child) = comp.get(&k) else { continue };
                let shared = to_shared(child);
                let rewritten = rewrite_to_fixpoint(&shared, &ctx, &scope)?;
                check_surviving_refs(&rewritten, &named, &scope, &mut PtrSet::default())?;
                if !Rc::ptr_eq(&rewritten, &shared) {
                    comp.insert(k, to_value(&rewritten));
                }
            }
            registries.entry(cname.clone()).or_insert(CompRegistry {
                named,
                rules,
                shape_env,
                target_bearing,
            });
        }
    }

    // Coupling `variable_map` expression transforms (esm-spec §10.4/§10.5):
    // template invocations in a transform expand at load against the template
    // registry of the component that owns the entry's `to` target — the
    // RECEIVING component, where a regridding library import (§9.7) lives.
    if let Some(Value::Array(entries)) = root.get_mut("coupling") {
        for (idx, entry) in entries.iter_mut().enumerate() {
            let Some(obj) = entry.as_object_mut() else {
                continue;
            };
            if obj.get("type").and_then(|v| v.as_str()) != Some("variable_map") {
                continue;
            }
            let Some(transform) = obj.get("transform").filter(|t| t.is_object()).cloned() else {
                continue;
            };
            let Some(comp_name) = obj
                .get("to")
                .and_then(|v| v.as_str())
                .map(|t| t.split('.').next().unwrap_or(""))
            else {
                continue;
            };
            let Some(reg) = registries.get(comp_name) else {
                continue;
            };
            let ctx = RewriteCtx {
                named: &reg.named,
                rules: &reg.rules,
                shape_env: &reg.shape_env,
                target_bearing: &reg.target_bearing,
            };
            let scope = format!("coupling[{idx}].transform");
            let shared = to_shared(&transform);
            let rewritten = rewrite_to_fixpoint(&shared, &ctx, &scope)?;
            check_surviving_refs(&rewritten, &reg.named, &scope, &mut PtrSet::default())?;
            if !Rc::ptr_eq(&rewritten, &shared) {
                obj.insert("transform".to_string(), to_value(&rewritten));
            }
        }
    }

    // esm-spec §9.6.4 rule 1 (Option B): surviving `apply_expression_template`
    // references are the NEW NORMAL. Only UNKNOWN-name / bindings-mismatch
    // references are errors — already checked per component / per transform by
    // `check_surviving_refs`. No global "no apply ops remain" gate.

    // Validation discharge (esm-spec §9.6.9): geometry-manifold and
    // makearray-region checks on the reference-preserving form. The manifold
    // check is per-instantiation (a `manifold` may be a template param), so it
    // descends through surviving references' single-instantiation expansions.
    // Region bounds cannot carry template params, so the makearray check runs
    // on the reference-preserving tree AND the retained folded template bodies.
    validate_geometry_manifolds_refaware(value, &registries)?;
    validate_makearray_regions(value, "")?;
    validate_makearray_regions_in_registries(&registries)?;

    Ok(())
}

/// Geometry-kernel ops whose `manifold` scalar field is restricted to the
/// closed manifold registry (CONFORMANCE_SPEC §5.8.4).
pub(super) const GEOMETRY_MANIFOLD_OPS: [&str; 2] =
    ["intersect_polygon", "polygon_intersection_area"];

/// The closed manifold registry. The document schema admits any string in the
/// `manifold` position so a template `body` can carry a parameter name there
/// (esm-spec §9.6.1 scalar-field substitution site); the closed set is
/// enforced by [`validate_geometry_manifolds`] on the EXPANDED form per
/// esm-spec §9.6.4.
const GEOMETRY_MANIFOLD_VALUES: [&str; 3] = ["planar", "spherical", "geodesic"];

/// Post-expansion validator (esm-spec §9.6.4): every `intersect_polygon` /
/// `polygon_intersection_area` node OUTSIDE an `expression_templates` block
/// must carry a `manifold` drawn from the closed set {planar, spherical,
/// geodesic}. Template bodies are skipped — a parameter name in the `manifold`
/// position of a `body` is a legal scalar-field substitution site (esm-spec
/// §9.6.1); by the time this validator runs on a loaded document every such
/// site has been substituted, so an out-of-set value here is a real defect
/// (e.g. a template invocation binding the manifold parameter to a non-member
/// literal). Errors with code `geometry_manifold_invalid`.
///
/// Hand-rolled rather than `crate::json_visit`: descent is key-dependent
/// (`expression_templates` subtrees are skipped) and the diagnostic needs the
/// offender's path with an early error return.
pub fn validate_geometry_manifolds(
    tree: &Value,
    path: &str,
) -> Result<(), ExpressionTemplateError> {
    match tree {
        Value::Array(arr) => {
            for (i, child) in arr.iter().enumerate() {
                validate_geometry_manifolds(child, &format!("{path}/{i}"))?;
            }
            Ok(())
        }
        Value::Object(obj) => {
            if let Some(op) = obj.get("op").and_then(|v| v.as_str())
                && GEOMETRY_MANIFOLD_OPS.contains(&op)
                && let Some(m) = obj.get("manifold")
            {
                let ok = m
                    .as_str()
                    .is_some_and(|s| GEOMETRY_MANIFOLD_VALUES.contains(&s));
                if !ok {
                    return Err(err(
                        codes::GEOMETRY_MANIFOLD_INVALID,
                        format!(
                            "{path}: `{op}` carries manifold {m}, not a member of the \
                             closed set {{planar, spherical, geodesic}}. The manifold \
                             enum is enforced on the expanded form (esm-spec §9.6.4; \
                             CONFORMANCE_SPEC §5.8.4) — a template parameter substituted \
                             into this scalar field must be bound to one of the \
                             closed-set literals."
                        ),
                    ));
                }
            }
            for (k, v) in obj {
                // Pre-substitution template trees; params may legally occupy
                // the manifold position there (esm-spec §9.6.1).
                if k == "expression_templates" {
                    continue;
                }
                validate_geometry_manifolds(v, &format!("{path}/{k}"))?;
            }
            Ok(())
        }
        _ => Ok(()),
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
    match tree {
        Value::Array(arr) => {
            for (i, child) in arr.iter().enumerate() {
                validate_makearray_regions(child, &format!("{path}/{i}"))?;
            }
            Ok(())
        }
        Value::Object(obj) => {
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
                        // Only concrete integer pairs are checked; a fully
                        // folded document carries nothing else here. `as_i64`
                        // rejects booleans and floats, matching the Julia
                        // `Integer && !Bool` gate.
                        let (Some(lo), Some(hi)) = (bounds_arr[0].as_i64(), bounds_arr[1].as_i64())
                        else {
                            continue;
                        };
                        if hi < lo - 1 {
                            return Err(err(
                                codes::MAKEARRAY_REGION_INVERTED,
                                format!(
                                    "{path}: makearray regions[{ri}] dimension {di} bound pair \
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
            for (k, v) in obj {
                // Template bodies/matches are pre-substitution trees; bounds may
                // legally carry metaparameter names or fold later (§9.7.6).
                if k == "expression_templates" {
                    continue;
                }
                validate_makearray_regions(v, &format!("{path}/{k}"))?;
            }
            Ok(())
        }
        _ => Ok(()),
    }
}
