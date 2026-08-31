use super::*;

// ---------------------------------------------------------------------------
// Shared-value mirror (structural sharing for the expansion pipeline)
// ---------------------------------------------------------------------------
//
// `serde_json::Value` is an OWNED tree: a substitution that copies a template
// body multiplies memory by the number of call sites. A chain of templates
// T0..Tn whose bodies each reference T_{i-1} TWICE therefore expands to 2^n
// copies of the leaf — a ~4KB file with a depth-19 chain produced a
// multi-million-node AST and an OOM, while respecting every documented limit
// (chain depth <= MAX_TEMPLATE_EXPANSION_DEPTH = 32).
//
// The fix mirrors the Julia reference implementation (its "shared DAGs, not
// exponential trees" change): the expansion pipeline works on an `Rc`-shared
// mirror of `Value` (`SNode`), so substitution splices template bodies and
// bindings BY REFERENCE (an `Rc` bump) instead of copying, and the
// composition / rewrite walks are identity-preserving and pointer-memoized —
// a subtree shared under many parents is processed once and the shared
// result respliced. This is a REPRESENTATION-ONLY change: identical subtrees
// are observationally indistinguishable, selection and traversal stay fully
// deterministic, and expansion semantics, diagnostics, and serialized bytes
// are unchanged.
//
// The document itself remains an owned `serde_json::Value`: each rewritten
// field's expanded DAG is materialized back into it ONCE, at the end of the
// fixpoint (`to_value`). That single materialization is inherently
// proportional to the EXPANDED size — an owned `Value` cannot alias
// subtrees — but it is no longer preceded by exponentially many intermediate
// copies (composed bodies, per-pass tree rebuilds, registry clones), which
// is where the blow-up lived.

/// Shared mirror of `serde_json::Value`. Object fields preserve insertion
/// order (matching serde_json's `preserve_order` feature); expression-node
/// objects are small, so field lookups are linear scans.
#[derive(Debug)]
pub(super) enum SNode {
    Null,
    Bool(bool),
    Num(serde_json::Number),
    Str(String),
    Arr(Vec<Sv>),
    Obj(Vec<(String, Sv)>),
}

/// A shared (reference-counted) expression node.
pub(super) type Sv = Rc<SNode>;

/// Convert an owned JSON tree into the shared mirror. The input is a tree
/// (parsed JSON has no aliasing), so no memoization is needed: O(input).
pub(super) fn to_shared(v: &Value) -> Sv {
    Rc::new(match v {
        Value::Null => SNode::Null,
        Value::Bool(b) => SNode::Bool(*b),
        Value::Number(n) => SNode::Num(n.clone()),
        Value::String(s) => SNode::Str(s.clone()),
        Value::Array(arr) => SNode::Arr(arr.iter().map(to_shared).collect()),
        Value::Object(obj) => {
            SNode::Obj(obj.iter().map(|(k, v)| (k.clone(), to_shared(v))).collect())
        }
    })
}

/// Materialize a shared DAG back into an owned `serde_json::Value` tree.
/// This is the ONE inherently size-proportional step: an owned `Value`
/// cannot alias subtrees, so a DAG whose logical expansion has 2^n leaves
/// materializes 2^n owned copies. It runs once per rewritten field, at the
/// boundary where the expanded form is spliced back into the owned document.
pub(super) fn to_value(s: &SNode) -> Value {
    match s {
        SNode::Null => Value::Null,
        SNode::Bool(b) => Value::Bool(*b),
        SNode::Num(n) => Value::Number(n.clone()),
        SNode::Str(st) => Value::String(st.clone()),
        SNode::Arr(items) => Value::Array(items.iter().map(|c| to_value(c)).collect()),
        SNode::Obj(fields) => {
            let mut out = Map::new();
            for (k, v) in fields {
                out.insert(k.clone(), to_value(v));
            }
            Value::Object(out)
        }
    }
}

/// Field lookup on a shared object node (insertion-ordered small vec).
pub(super) fn obj_get<'a>(fields: &'a [(String, Sv)], key: &str) -> Option<&'a Sv> {
    fields.iter().find(|(k, _)| k == key).map(|(_, v)| v)
}

/// The `op` string of a shared object node, if any.
pub(super) fn obj_op(fields: &[(String, Sv)]) -> Option<&str> {
    match obj_get(fields, "op").map(|v| &**v) {
        Some(SNode::Str(s)) => Some(s.as_str()),
        _ => None,
    }
}

/// Structural equality between shared nodes, with a pointer fast path so
/// comparing two handles onto the same shared subtree is O(1). Object
/// equality is key-set based (order-insensitive), mirroring
/// `serde_json::Value`'s `PartialEq`.
pub(super) fn sv_eq(a: &Sv, b: &Sv) -> bool {
    if Rc::ptr_eq(a, b) {
        return true;
    }
    match (&**a, &**b) {
        (SNode::Null, SNode::Null) => true,
        (SNode::Bool(x), SNode::Bool(y)) => x == y,
        (SNode::Num(x), SNode::Num(y)) => x == y,
        (SNode::Str(x), SNode::Str(y)) => x == y,
        (SNode::Arr(x), SNode::Arr(y)) => {
            x.len() == y.len() && x.iter().zip(y.iter()).all(|(cx, cy)| sv_eq(cx, cy))
        }
        (SNode::Obj(x), SNode::Obj(y)) => {
            x.len() == y.len()
                && x.iter()
                    .all(|(k, vx)| obj_get(y, k).is_some_and(|vy| sv_eq(vx, vy)))
        }
        _ => false,
    }
}

/// Structural equality between an owned pattern literal and a shared node,
/// mirroring `serde_json::Value`'s `PartialEq` semantics (numbers compare
/// via `serde_json::Number` equality, objects are order-insensitive).
pub(super) fn value_eq_sv(p: &Value, t: &SNode) -> bool {
    match (p, t) {
        (Value::Null, SNode::Null) => true,
        (Value::Bool(x), SNode::Bool(y)) => x == y,
        (Value::Number(x), SNode::Num(y)) => x == y,
        (Value::String(x), SNode::Str(y)) => x == y,
        (Value::Array(x), SNode::Arr(y)) => {
            x.len() == y.len() && x.iter().zip(y.iter()).all(|(px, ty)| value_eq_sv(px, ty))
        }
        (Value::Object(x), SNode::Obj(y)) => {
            x.len() == y.len()
                && x.iter()
                    .all(|(k, pv)| obj_get(y, k).is_some_and(|tv| value_eq_sv(pv, tv)))
        }
        _ => false,
    }
}

/// Ordered template-invocation / match bindings (param -> shared sub-AST).
/// Binding sets are small (a template's params), so lookups are linear.
pub(super) type Binds = Vec<(String, Sv)>;

pub(super) fn binds_get<'a>(binds: &'a Binds, key: &str) -> Option<&'a Sv> {
    binds.iter().find(|(k, _)| k == key).map(|(_, v)| v)
}

/// Pointer-keyed memo table for identity-memoized walks over shared DAGs.
///
/// Every entry OWNS an `Rc` handle to its key node, stored beside the value.
/// That keep-alive is load-bearing, not belt-and-braces: `Rc::as_ptr` is only a
/// stable identity for as long as the allocation lives, and several walks
/// deliberately recurse **with the same memo** into freshly substituted template
/// bodies ([`expand_all`] / [`expand_eager`] re-enter on the result of
/// [`expand_apply`]) or over successive `to_shared` roots
/// ([`validate_manifolds_in_refs`]). Those trees are dropped as soon as their
/// expansion is spliced in; without the keep-alive their addresses are free for
/// the allocator to hand back to the very next `Rc::new`, and the memo then
/// reports a hit for a structurally unrelated node — silently splicing a foreign
/// subtree into the document. That is exactly the corruption observed on deep
/// PPM / WENO expansions (an `args` array replaced by an unrelated operator
/// object, which then fails `Expr` deserialization).
pub(super) struct PtrMemo<T> {
    map: std::collections::HashMap<*const SNode, (Sv, T)>,
}

impl<T> Default for PtrMemo<T> {
    fn default() -> Self {
        Self {
            map: std::collections::HashMap::new(),
        }
    }
}

impl<T> PtrMemo<T> {
    /// Memoized value for `node`, by pointer identity.
    pub(super) fn get(&self, node: &Sv) -> Option<&T> {
        self.map.get(&Rc::as_ptr(node)).map(|(_, v)| v)
    }

    /// Record `value` for `node`, retaining a handle to `node` so its address
    /// stays uniquely its own for the memo's lifetime.
    pub(super) fn insert(&mut self, node: &Sv, value: T) {
        self.map.insert(Rc::as_ptr(node), (node.clone(), value));
    }
}

/// Reject `apply_expression_template` nodes inside a `match` pattern
/// (esm-spec §9.7.3: match patterns MUST NOT reference templates).
///
/// Hand-rolled rather than `crate::json_visit`: the diagnostic needs the
/// offender's path AND early error return, which the shared visitors don't
/// combine.
fn assert_no_nested_apply(
    body: &Value,
    template_name: &str,
    path: &str,
) -> Result<(), ExpressionTemplateError> {
    match body {
        Value::Array(arr) => {
            for (i, child) in arr.iter().enumerate() {
                assert_no_nested_apply(child, template_name, &format!("{path}/{i}"))?;
            }
        }
        Value::Object(obj) => {
            if obj.get("op").and_then(|v| v.as_str()) == Some(APPLY_OP) {
                return Err(err(
                    codes::APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
                    format!(
                        "expression_templates.{template_name}: `match` contains an \
                         'apply_expression_template' node at {path}; match patterns MUST NOT \
                         reference templates (esm-spec §9.7.3)"
                    ),
                ));
            }
            for (k, v) in obj {
                assert_no_nested_apply(v, template_name, &format!("{path}/{k}"))?;
            }
        }
        _ => {}
    }
    Ok(())
}

pub(crate) fn validate_templates(
    templates: &Map<String, Value>,
    scope: &str,
) -> Result<(), ExpressionTemplateError> {
    for (name, decl) in templates {
        let decl_obj = decl.as_object().ok_or_else(|| {
            err(
                codes::APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
                format!(
                    "{scope}.expression_templates.{name}: entry must be an object \
                     with params + body"
                ),
            )
        })?;
        // `params` MAY be empty (esm-spec §9.6.1, 0.8.0): a zero-parameter
        // template is a named constant fragment (common in library files).
        let params = decl_obj
            .get("params")
            .and_then(|p| p.as_array())
            .ok_or_else(|| {
                err(
                    codes::APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
                    format!("{scope}.expression_templates.{name}: 'params' must be an array"),
                )
            })?;
        let mut seen: std::collections::HashSet<&str> = std::collections::HashSet::new();
        for p in params {
            let p_str = p.as_str().ok_or_else(|| {
                err(
                    codes::APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
                    format!("{scope}.expression_templates.{name}: param names must be strings"),
                )
            })?;
            if p_str.is_empty() {
                return Err(err(
                    codes::APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
                    format!("{scope}.expression_templates.{name}: param names must be non-empty"),
                ));
            }
            if !seen.insert(p_str) {
                return Err(err(
                    codes::APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
                    format!("{scope}.expression_templates.{name}: param '{p_str}' declared twice"),
                ));
            }
        }
        let _body = decl_obj.get("body").ok_or_else(|| {
            err(
                codes::APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
                format!("{scope}.expression_templates.{name}: 'body' is required"),
            )
        })?;
        // A body MAY reference other match-less in-scope templates via
        // apply_expression_template nodes (esm-spec §9.7.3); the reference
        // graph is checked (acyclic — `apply_expression_template_recursive_body`
        // — and depth <= MAX_TEMPLATE_EXPANSION_DEPTH) at registration by
        // `validate_template_body_references`, with the references themselves
        // preserved uninlined (§9.6.4 rule 2).

        // An optional `match` pattern turns the entry into an auto-applied
        // rewrite rule (esm-spec §9.6); it MUST NOT contain nested
        // `apply_expression_template` ops (esm-spec §9.7.3).
        if let Some(pattern) = decl_obj.get("match") {
            assert_no_nested_apply(pattern, name, "/match")?;
        }

        // An optional `where` block adds static match-scoping constraints on
        // the captured params (esm-spec §9.6.1, 0.8.0). Structural validation
        // only, here; the unknown-index-set check runs at rule REGISTRATION in
        // the consuming component (where the merged `index_sets` registry is in
        // scope) — see [`registered_where`]. A JSON `null` `where` is treated as
        // absent (matching the Julia `get(decl, "where", nothing)`).
        if let Some(whr) = decl_obj.get("where").filter(|v| !v.is_null()) {
            if decl_obj.get("match").is_none() {
                return Err(err(
                    codes::APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
                    format!(
                        "{scope}.expression_templates.{name}: 'where' is only admissible \
                         alongside 'match' — constraints scope an auto-applied rewrite rule, not \
                         a named fragment (esm-spec §9.6.1)"
                    ),
                ));
            }
            let whr_obj = whr.as_object().filter(|o| !o.is_empty()).ok_or_else(|| {
                err(
                    codes::APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
                    format!(
                        "{scope}.expression_templates.{name}: 'where' must be a non-empty object \
                         mapping declared params to constraint objects"
                    ),
                )
            })?;
            for (p, cobj) in whr_obj {
                if !seen.contains(p.as_str()) {
                    return Err(err(
                        codes::APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
                        format!(
                            "{scope}.expression_templates.{name}: 'where' constrains '{p}', which \
                             is not a declared param (esm-spec §9.6.1)"
                        ),
                    ));
                }
                let cobj_obj = cobj.as_object().ok_or_else(|| {
                    err(
                        codes::APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
                        format!(
                            "{scope}.expression_templates.{name}: where.{p} must be a constraint \
                             object (v1 admits exactly the 'shape' kind)"
                        ),
                    )
                })?;
                let is_only_shape = cobj_obj.len() == 1 && cobj_obj.contains_key("shape");
                if !is_only_shape {
                    let mut kinds: Vec<&str> = cobj_obj.keys().map(String::as_str).collect();
                    kinds.sort_unstable();
                    return Err(err(
                        codes::APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
                        format!(
                            "{scope}.expression_templates.{name}: where.{p} carries constraint \
                             kind(s) {}; the v1 constraint vocabulary is exactly {{shape}} \
                             (esm-spec §9.6.1)",
                            kinds.join(", ")
                        ),
                    ));
                }
                let shp = cobj_obj
                    .get("shape")
                    .and_then(|v| v.as_array())
                    .filter(|a| !a.is_empty())
                    .ok_or_else(|| {
                        err(
                            codes::APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
                            format!(
                                "{scope}.expression_templates.{name}: where.{p}.shape must be a \
                                 non-empty array of index-set names"
                            ),
                        )
                    })?;
                for s in shp {
                    if s.as_str().is_none_or(|s| s.is_empty()) {
                        return Err(err(
                            codes::APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
                            format!(
                                "{scope}.expression_templates.{name}: where.{p}.shape entries \
                                 must be non-empty strings"
                            ),
                        ));
                    }
                }
            }
        }
    }
    Ok(())
}

/// Maximum template-body reference-chain depth (counted in TEMPLATES along
/// the longest chain, so a 33-template chain is rejected while a 32-template
/// chain is accepted) before a file is rejected with
/// `template_body_expansion_too_deep` (esm-spec §9.7.3). Pinned identically
/// across all bindings.
pub const MAX_TEMPLATE_EXPANSION_DEPTH: usize = 32;

/// Collect the `name`s of every `apply_expression_template` node in a tree.
pub(crate) fn collect_apply_names(x: &Value, out: &mut Vec<String>) {
    crate::json_visit::visit_values(x, &mut |_path, v| {
        if let Some(obj) = v.as_object()
            && obj.get("op").and_then(|w| w.as_str()) == Some(APPLY_OP)
            && let Some(name) = obj.get("name").and_then(|w| w.as_str())
        {
            out.push(name.to_string());
        }
    });
}

/// Registration-time body-reference **validation** (esm-spec §9.7.3, Option B
/// / esm 0.9.0): template bodies MAY reference other in-scope MATCH-LESS
/// templates via `apply_expression_template` nodes. Builds the body-reference
/// graph, rejects cycles (`apply_expression_template_recursive_body`),
/// references to undeclared or `match`-bearing templates
/// (`apply_expression_template_unknown_template`), and chains deeper than
/// `MAX_TEMPLATE_EXPANSION_DEPTH` templates (`template_body_expansion_too_deep`).
///
/// From `esm: 0.9.0` (RFC out-of-line-expression-templates §7.1 step 4) bodies
/// are **NOT inlined** — the references are preserved uninlined and denote
/// their expansion (§9.6.4 rule 2). Target-bearing flags (§9.6.4 rule 3) are
/// computed separately by [`template_target_bearing`]. This runs BEFORE the
/// §9.6.3 fixpoint ever consults a `match` rule, validates the DAG only, and
/// never mutates `templates`. Mirrors the Julia reference
/// `_compose_template_bodies!` (which likewise only validates).
pub(crate) fn validate_template_body_references(
    templates: &Map<String, Value>,
    scope: &str,
) -> Result<(), ExpressionTemplateError> {
    if templates.is_empty() {
        return Ok(());
    }
    let mut refs: std::collections::BTreeMap<String, Vec<String>> =
        std::collections::BTreeMap::new();
    let mut any_refs = false;
    for (name, decl) in templates.iter() {
        let mut names = Vec::new();
        if let Some(body) = decl.get("body") {
            collect_apply_names(body, &mut names);
        }
        any_refs = any_refs || !names.is_empty();
        refs.insert(name.clone(), names);
    }
    if !any_refs {
        return Ok(());
    }

    for (name, rs) in &refs {
        for r in rs {
            let Some(tdecl) = templates.get(r) else {
                return Err(err(
                    codes::APPLY_EXPRESSION_TEMPLATE_UNKNOWN_TEMPLATE,
                    format!(
                        "{scope}.expression_templates.{name}: body references undeclared \
                         template '{r}' (esm-spec §9.7.3)"
                    ),
                ));
            };
            if tdecl.get("match").is_some() {
                return Err(err(
                    codes::APPLY_EXPRESSION_TEMPLATE_UNKNOWN_TEMPLATE,
                    format!(
                        "{scope}.expression_templates.{name}: body references '{r}', a `match` \
                         rewrite rule — only match-less templates are invocable by name \
                         (esm-spec §9.7.3)"
                    ),
                ));
            }
        }
    }

    // DFS over the reference graph: cycle detection and chain-depth bound.
    fn visit(
        name: &str,
        refs: &std::collections::BTreeMap<String, Vec<String>>,
        state: &mut std::collections::HashMap<String, u8>, // 1 = on stack, 2 = done
        depth: &mut std::collections::HashMap<String, usize>,
        chain: &mut Vec<String>,
        scope: &str,
    ) -> Result<usize, ExpressionTemplateError> {
        match state.get(name).copied().unwrap_or(0) {
            1 => {
                let start = chain.iter().position(|c| c == name).unwrap_or(0);
                let mut cyc: Vec<String> = chain[start..].to_vec();
                cyc.push(name.to_string());
                Err(err(
                    codes::APPLY_EXPRESSION_TEMPLATE_RECURSIVE_BODY,
                    format!(
                        "{scope}.expression_templates: template-body reference cycle {} \
                         (esm-spec §9.7.3)",
                        cyc.join(" -> ")
                    ),
                ))
            }
            2 => Ok(depth[name]),
            _ => {
                state.insert(name.to_string(), 1);
                chain.push(name.to_string());
                let mut d = 1usize;
                if let Some(rs) = refs.get(name) {
                    for r in rs.clone() {
                        d = d.max(1 + visit(&r, refs, state, depth, chain, scope)?);
                    }
                }
                chain.pop();
                state.insert(name.to_string(), 2);
                depth.insert(name.to_string(), d);
                if d > MAX_TEMPLATE_EXPANSION_DEPTH {
                    return Err(err(
                        codes::TEMPLATE_BODY_EXPANSION_TOO_DEEP,
                        format!(
                            "{scope}.expression_templates.{name}: body-reference chain of {d} \
                             templates exceeds \
                             MAX_TEMPLATE_EXPANSION_DEPTH={MAX_TEMPLATE_EXPANSION_DEPTH} \
                             (esm-spec §9.7.3)"
                        ),
                    ));
                }
                Ok(d)
            }
        }
    }

    let mut state = std::collections::HashMap::new();
    let mut depth = std::collections::HashMap::new();
    let mut chain: Vec<String> = Vec::new();
    for name in refs.keys() {
        visit(name, &refs, &mut state, &mut depth, &mut chain, scope)?;
    }
    Ok(())
}

/// Splice `bindings` into `body` with structural sharing (esm-spec §9.6.3):
/// a bound metavariable is replaced by a REFERENCE to the binding's sub-AST,
/// an untouched subtree is returned by identity, and the walk is
/// identity-memoized so a subtree shared under many parents is substituted
/// once. With no bindings the body itself is spliced in unchanged (an `Rc`
/// bump). Pure and deterministic, so aliased results are observationally
/// identical to the old deep-copy substitution.
pub(super) fn substitute(body: &Sv, bindings: &Binds) -> Sv {
    if bindings.is_empty() {
        return body.clone();
    }
    let mut memo: PtrMemo<Sv> = PtrMemo::default();
    subst_shared(body, bindings, &mut memo)
}

fn subst_shared(node: &Sv, bindings: &Binds, memo: &mut PtrMemo<Sv>) -> Sv {
    match &**node {
        SNode::Str(s) => match binds_get(bindings, s) {
            Some(v) => v.clone(),
            None => node.clone(),
        },
        SNode::Arr(items) => {
            if let Some(hit) = memo.get(node) {
                return hit.clone();
            }
            let mut changed = false;
            let mut out = Vec::with_capacity(items.len());
            for c in items {
                let nc = subst_shared(c, bindings, memo);
                changed |= !Rc::ptr_eq(&nc, c);
                out.push(nc);
            }
            let res = if changed {
                Rc::new(SNode::Arr(out))
            } else {
                node.clone()
            };
            memo.insert(node, res.clone());
            res
        }
        SNode::Obj(fields) => {
            if let Some(hit) = memo.get(node) {
                return hit.clone();
            }
            // esm-spec §9.6.3 constraint 5 / §9.6.4 rule 4: parameter
            // substitution applies inside a nested `apply_expression_template`
            // reference's `bindings` values exactly as any other Expression
            // position, but the `name` field is NEVER a substitution site.
            let is_apply = obj_op(fields) == Some(APPLY_OP);
            let mut changed = false;
            let mut out = Vec::with_capacity(fields.len());
            for (k, v) in fields {
                if is_apply && k == "name" {
                    out.push((k.clone(), v.clone()));
                    continue;
                }
                let nv = subst_shared(v, bindings, memo);
                changed |= !Rc::ptr_eq(&nv, v);
                out.push((k.clone(), nv));
            }
            let res = if changed {
                Rc::new(SNode::Obj(out))
            } else {
                node.clone()
            };
            memo.insert(node, res.clone());
            res
        }
        _ => node.clone(),
    }
}
