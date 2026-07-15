//! Load-time rewrite engine for `expression_templates` (esm-spec §9.6 /
//! §9.6.3, docs/content/rfcs/open-op-namespace-fixpoint-rewrite.md).
//!
//! Each `expression_templates` entry is a rewrite rule with `params`
//! (metavariables) and a `body` (the replacement Expression), applied in one of
//! two ways: WITHOUT a `match` field it is invoked explicitly by an
//! `apply_expression_template` node; WITH a `match` field it is an auto-applied
//! rewrite rule fired wherever the pattern structurally matches a node.
//!
//! Rewriting is an OUTERMOST-FIRST, PRIORITY-ORDERED, BOUNDED-FIXPOINT process
//! (esm-spec §9.6.3). One pass (`rewrite_pass`) is a single pre-order
//! (outermost-first) walk: at each node the engine first tries to fire a rule
//! AT that node before descending — an `apply_expression_template` op is
//! expanded, otherwise the `match` rules are consulted and the winner is
//! selected deterministically (highest `priority`, ties broken by declaration
//! order). The winner's body replaces the node and the walk does NOT descend
//! into that freshly-produced body during the current pass. Passes repeat until
//! a pass performs zero rewrites (the fixpoint) or until `MAX_REWRITE_PASSES`
//! productive passes have run without converging, in which case the file is
//! rejected with `rewrite_rule_nonterminating` (the pass bound — not a static
//! check — is the authoritative termination guard). Because selection and
//! traversal are fully deterministic, all bindings produce byte-identical
//! fixpoints. After convergence the tree contains no `apply_expression_template`
//! ops and no `expression_templates` blocks — downstream consumers see only
//! normal Expression ASTs (Option A round-trip). Any rewrite-target op (e.g. a
//! spatial `D`) that survives the fixpoint into an evaluation position is caught
//! later by the `unlowered_operator` gate, not here.
//!
//! Operates on the pre-deserialization `serde_json::Value` view, so it must
//! run after schema validation but before deserializing into typed structs.

use serde_json::{Map, Value};
use std::rc::Rc;

const APPLY_OP: &str = "apply_expression_template";

/// Stable diagnostic codes raised by the expression-template expansion
/// pass. Mirrors the codes emitted by the TS / Python / Julia / Go bindings.
pub type ExpressionTemplateError = crate::diagnostic::DiagnosticError;

use crate::diagnostic::err;

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
enum SNode {
    Null,
    Bool(bool),
    Num(serde_json::Number),
    Str(String),
    Arr(Vec<Sv>),
    Obj(Vec<(String, Sv)>),
}

/// A shared (reference-counted) expression node.
type Sv = Rc<SNode>;

/// Convert an owned JSON tree into the shared mirror. The input is a tree
/// (parsed JSON has no aliasing), so no memoization is needed: O(input).
fn to_shared(v: &Value) -> Sv {
    Rc::new(match v {
        Value::Null => SNode::Null,
        Value::Bool(b) => SNode::Bool(*b),
        Value::Number(n) => SNode::Num(n.clone()),
        Value::String(s) => SNode::Str(s.clone()),
        Value::Array(arr) => SNode::Arr(arr.iter().map(to_shared).collect()),
        Value::Object(obj) => SNode::Obj(
            obj.iter()
                .map(|(k, v)| (k.clone(), to_shared(v)))
                .collect(),
        ),
    })
}

/// Materialize a shared DAG back into an owned `serde_json::Value` tree.
/// This is the ONE inherently size-proportional step: an owned `Value`
/// cannot alias subtrees, so a DAG whose logical expansion has 2^n leaves
/// materializes 2^n owned copies. It runs once per rewritten field, at the
/// boundary where the expanded form is spliced back into the owned document.
fn to_value(s: &SNode) -> Value {
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
fn obj_get<'a>(fields: &'a [(String, Sv)], key: &str) -> Option<&'a Sv> {
    fields.iter().find(|(k, _)| k == key).map(|(_, v)| v)
}

/// The `op` string of a shared object node, if any.
fn obj_op(fields: &[(String, Sv)]) -> Option<&str> {
    match obj_get(fields, "op").map(|v| &**v) {
        Some(SNode::Str(s)) => Some(s.as_str()),
        _ => None,
    }
}

/// Structural equality between shared nodes, with a pointer fast path so
/// comparing two handles onto the same shared subtree is O(1). Object
/// equality is key-set based (order-insensitive), mirroring
/// `serde_json::Value`'s `PartialEq`.
fn sv_eq(a: &Sv, b: &Sv) -> bool {
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
fn value_eq_sv(p: &Value, t: &SNode) -> bool {
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
type Binds = Vec<(String, Sv)>;

fn binds_get<'a>(binds: &'a Binds, key: &str) -> Option<&'a Sv> {
    binds.iter().find(|(k, _)| k == key).map(|(_, v)| v)
}

/// Pointer-keyed memo table for identity-memoized walks over shared DAGs.
/// Keys are `Rc::as_ptr` addresses of nodes reachable from a root that is
/// borrowed alive for the duration of the walk, so no keyed allocation can
/// be freed (and its address reused) mid-walk.
type PtrMemo<T> = std::collections::HashMap<*const SNode, T>;

/// Reject `apply_expression_template` nodes inside a `match` pattern
/// (esm-spec §9.7.3: match patterns MUST NOT reference templates).
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
                    "apply_expression_template_invalid_declaration",
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
                "apply_expression_template_invalid_declaration",
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
                    "apply_expression_template_invalid_declaration",
                    format!("{scope}.expression_templates.{name}: 'params' must be an array"),
                )
            })?;
        let mut seen: std::collections::HashSet<&str> = std::collections::HashSet::new();
        for p in params {
            let p_str = p.as_str().ok_or_else(|| {
                err(
                    "apply_expression_template_invalid_declaration",
                    format!("{scope}.expression_templates.{name}: param names must be strings"),
                )
            })?;
            if p_str.is_empty() {
                return Err(err(
                    "apply_expression_template_invalid_declaration",
                    format!("{scope}.expression_templates.{name}: param names must be non-empty"),
                ));
            }
            if !seen.insert(p_str) {
                return Err(err(
                    "apply_expression_template_invalid_declaration",
                    format!("{scope}.expression_templates.{name}: param '{p_str}' declared twice"),
                ));
            }
        }
        let _body = decl_obj.get("body").ok_or_else(|| {
            err(
                "apply_expression_template_invalid_declaration",
                format!("{scope}.expression_templates.{name}: 'body' is required"),
            )
        })?;
        // A body MAY reference other match-less in-scope templates via
        // apply_expression_template nodes (esm-spec §9.7.3); those are
        // checked (acyclic, depth <= MAX_TEMPLATE_EXPANSION_DEPTH) and
        // inlined at registration by `compose_template_bodies` — the old
        // any-nesting rejection is now cycle-only
        // (`apply_expression_template_recursive_body`).

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
                    "apply_expression_template_invalid_declaration",
                    format!(
                        "{scope}.expression_templates.{name}: 'where' is only admissible \
                         alongside 'match' — constraints scope an auto-applied rewrite rule, not \
                         a named fragment (esm-spec §9.6.1)"
                    ),
                ));
            }
            let whr_obj = whr.as_object().filter(|o| !o.is_empty()).ok_or_else(|| {
                err(
                    "apply_expression_template_invalid_declaration",
                    format!(
                        "{scope}.expression_templates.{name}: 'where' must be a non-empty object \
                         mapping declared params to constraint objects"
                    ),
                )
            })?;
            for (p, cobj) in whr_obj {
                if !seen.contains(p.as_str()) {
                    return Err(err(
                        "apply_expression_template_invalid_declaration",
                        format!(
                            "{scope}.expression_templates.{name}: 'where' constrains '{p}', which \
                             is not a declared param (esm-spec §9.6.1)"
                        ),
                    ));
                }
                let cobj_obj = cobj.as_object().ok_or_else(|| {
                    err(
                        "apply_expression_template_invalid_declaration",
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
                        "apply_expression_template_invalid_declaration",
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
                            "apply_expression_template_invalid_declaration",
                            format!(
                                "{scope}.expression_templates.{name}: where.{p}.shape must be a \
                                 non-empty array of index-set names"
                            ),
                        )
                    })?;
                for s in shp {
                    if s.as_str().is_none_or(|s| s.is_empty()) {
                        return Err(err(
                            "apply_expression_template_invalid_declaration",
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
fn collect_apply_names(x: &Value, out: &mut Vec<String>) {
    match x {
        Value::Array(arr) => {
            for c in arr {
                collect_apply_names(c, out);
            }
        }
        Value::Object(obj) => {
            if obj.get("op").and_then(|v| v.as_str()) == Some(APPLY_OP)
                && let Some(name) = obj.get("name").and_then(|v| v.as_str())
            {
                out.push(name.to_string());
            }
            for (_, v) in obj {
                collect_apply_names(v, out);
            }
        }
        _ => {}
    }
}

/// Inline every `apply_expression_template` node in `node` against the
/// composed `bodies`, post-order (so the bindings' own sub-ASTs are inlined
/// first). Referenced bodies are already closed when this runs in
/// topological order, so a single `expand_apply` produces an apply-free
/// subtree. Identity-memoized and sharing-preserving: a subtree shared
/// under many parents is inlined once and the shared result respliced, so
/// composed bodies stay DAGs instead of exploding into trees.
fn inline_applies(
    node: &Sv,
    decls: &Map<String, Value>,
    bodies: &std::collections::HashMap<String, Sv>,
    scope: &str,
    memo: &mut PtrMemo<Sv>,
) -> Result<Sv, ExpressionTemplateError> {
    match &**node {
        SNode::Arr(items) => {
            let key = Rc::as_ptr(node);
            if let Some(hit) = memo.get(&key) {
                return Ok(hit.clone());
            }
            let mut changed = false;
            let mut out = Vec::with_capacity(items.len());
            for c in items {
                let nc = inline_applies(c, decls, bodies, scope, memo)?;
                changed |= !Rc::ptr_eq(&nc, c);
                out.push(nc);
            }
            let res = if changed {
                Rc::new(SNode::Arr(out))
            } else {
                node.clone()
            };
            memo.insert(key, res.clone());
            Ok(res)
        }
        SNode::Obj(fields) => {
            let key = Rc::as_ptr(node);
            if let Some(hit) = memo.get(&key) {
                return Ok(hit.clone());
            }
            let mut changed = false;
            let mut out: Vec<(String, Sv)> = Vec::with_capacity(fields.len());
            for (k, v) in fields {
                let nv = inline_applies(v, decls, bodies, scope, memo)?;
                changed |= !Rc::ptr_eq(&nv, v);
                out.push((k.clone(), nv));
            }
            let res = if obj_op(&out) == Some(APPLY_OP) {
                expand_apply(&out, decls, bodies, scope)?
            } else if changed {
                Rc::new(SNode::Obj(out))
            } else {
                node.clone()
            };
            memo.insert(key, res.clone());
            Ok(res)
        }
        _ => Ok(node.clone()),
    }
}

/// The result of §9.7.3 registration-time body composition in the shared
/// representation: every template's closed (apply-free) body as a shared
/// DAG, plus the body-reference graph (used by the owned wrapper to decide
/// which decls to materialize back).
struct ComposedBodies {
    /// name -> closed body as a shared DAG (ALL templates, including those
    /// that referenced nothing).
    bodies: std::collections::HashMap<String, Sv>,
    /// name -> referenced template names (empty = body was already closed).
    refs: std::collections::BTreeMap<String, Vec<String>>,
}

/// Registration-time body composition (esm-spec §9.7.3): template bodies MAY
/// reference other in-scope MATCH-LESS templates via
/// `apply_expression_template` nodes. Builds the body-reference graph,
/// rejects cycles (`apply_expression_template_recursive_body`) and chains
/// deeper than `MAX_TEMPLATE_EXPANSION_DEPTH` templates
/// (`template_body_expansion_too_deep`), then inlines dependencies-first by
/// pure substitution — confluent, so topological order cannot affect the
/// result. Afterwards every returned `body` is a closed Expression AST with
/// zero `apply_expression_template` nodes; runs BEFORE the §9.6.3 fixpoint
/// ever consults a `match` rule.
///
/// Bodies are composed as shared DAGs (`Sv`): a referenced body is spliced
/// in BY REFERENCE, so a chain of templates that each reference their
/// predecessor k times costs O(chain) memory here instead of O(k^chain).
/// `templates` itself is not mutated.
fn compose_template_bodies_shared(
    templates: &Map<String, Value>,
    scope: &str,
) -> Result<ComposedBodies, ExpressionTemplateError> {
    let mut bodies: std::collections::HashMap<String, Sv> = std::collections::HashMap::new();
    let mut refs: std::collections::BTreeMap<String, Vec<String>> =
        std::collections::BTreeMap::new();
    if templates.is_empty() {
        return Ok(ComposedBodies { bodies, refs });
    }
    let mut any_refs = false;
    for (name, decl) in templates.iter() {
        let mut names = Vec::new();
        match decl.get("body") {
            Some(body) => {
                collect_apply_names(body, &mut names);
                bodies.insert(name.clone(), to_shared(body));
            }
            None => {
                bodies.insert(name.clone(), Rc::new(SNode::Null));
            }
        }
        any_refs = any_refs || !names.is_empty();
        refs.insert(name.clone(), names);
    }
    if !any_refs {
        return Ok(ComposedBodies { bodies, refs });
    }

    for (name, rs) in &refs {
        for r in rs {
            let Some(tdecl) = templates.get(r) else {
                return Err(err(
                    "apply_expression_template_unknown_template",
                    format!(
                        "{scope}.expression_templates.{name}: body references undeclared \
                         template '{r}' (esm-spec §9.7.3)"
                    ),
                ));
            };
            if tdecl.get("match").is_some() {
                return Err(err(
                    "apply_expression_template_unknown_template",
                    format!(
                        "{scope}.expression_templates.{name}: body references '{r}', a `match` \
                         rewrite rule — only match-less templates are invocable by name \
                         (esm-spec §9.7.3)"
                    ),
                ));
            }
        }
    }

    // DFS over the reference graph: cycle detection, chain-depth bound, and
    // a dependencies-first (post-) order for inlining.
    #[allow(clippy::too_many_arguments)]
    fn visit(
        name: &str,
        refs: &std::collections::BTreeMap<String, Vec<String>>,
        state: &mut std::collections::HashMap<String, u8>, // 1 = on stack, 2 = done
        depth: &mut std::collections::HashMap<String, usize>,
        order: &mut Vec<String>,
        chain: &mut Vec<String>,
        scope: &str,
    ) -> Result<usize, ExpressionTemplateError> {
        match state.get(name).copied().unwrap_or(0) {
            1 => {
                let start = chain.iter().position(|c| c == name).unwrap_or(0);
                let mut cyc: Vec<String> = chain[start..].to_vec();
                cyc.push(name.to_string());
                Err(err(
                    "apply_expression_template_recursive_body",
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
                        d = d.max(1 + visit(&r, refs, state, depth, order, chain, scope)?);
                    }
                }
                chain.pop();
                state.insert(name.to_string(), 2);
                depth.insert(name.to_string(), d);
                if d > MAX_TEMPLATE_EXPANSION_DEPTH {
                    return Err(err(
                        "template_body_expansion_too_deep",
                        format!(
                            "{scope}.expression_templates.{name}: body-reference chain of {d} \
                             templates exceeds \
                             MAX_TEMPLATE_EXPANSION_DEPTH={MAX_TEMPLATE_EXPANSION_DEPTH} \
                             (esm-spec §9.7.3)"
                        ),
                    ));
                }
                order.push(name.to_string());
                Ok(d)
            }
        }
    }

    let mut state = std::collections::HashMap::new();
    let mut depth = std::collections::HashMap::new();
    let mut order: Vec<String> = Vec::new();
    let mut chain: Vec<String> = Vec::new();
    for name in refs.keys() {
        visit(
            name, &refs, &mut state, &mut depth, &mut order, &mut chain, scope,
        )?;
    }

    for name in order {
        let Some(rs) = refs.get(&name) else { continue };
        if rs.is_empty() {
            continue;
        }
        let body = bodies
            .get(&name)
            .cloned()
            .unwrap_or_else(|| Rc::new(SNode::Null));
        let mut memo = PtrMemo::default();
        let inlined = inline_applies(
            &body,
            templates,
            &bodies,
            &format!("{scope}.expression_templates.{name}"),
            &mut memo,
        )?;
        bodies.insert(name.clone(), inlined);
    }
    Ok(ComposedBodies { bodies, refs })
}

/// Owned-view wrapper over [`compose_template_bodies_shared`] for callers
/// that keep templates as `serde_json::Value` decls (the §9.7 import
/// machinery): composes with structural sharing, then materializes the
/// closed bodies back into the decl objects in place — only for templates
/// that actually referenced others, exactly as before. NOTE: this owned
/// materialization is inherently proportional to the COMPOSED size (an
/// owned `Value` cannot alias subtrees), so a deep multi-reference chain in
/// an imported library still materializes exponentially here; the load-time
/// component fixpoint itself uses the shared form and does not pay this.
pub(crate) fn compose_template_bodies(
    templates: &mut Map<String, Value>,
    scope: &str,
) -> Result<(), ExpressionTemplateError> {
    if templates.is_empty() {
        return Ok(());
    }
    let composed = compose_template_bodies_shared(templates, scope)?;
    for (name, rs) in &composed.refs {
        if rs.is_empty() {
            continue;
        }
        let inlined = composed
            .bodies
            .get(name)
            .map(|b| to_value(b))
            .unwrap_or(Value::Null);
        if let Some(Value::Object(decl)) = templates.get_mut(name) {
            decl.insert("body".to_string(), inlined);
        }
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
fn substitute(body: &Sv, bindings: &Binds) -> Sv {
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
            let key = Rc::as_ptr(node);
            if let Some(hit) = memo.get(&key) {
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
            memo.insert(key, res.clone());
            res
        }
        SNode::Obj(fields) => {
            let key = Rc::as_ptr(node);
            if let Some(hit) = memo.get(&key) {
                return hit.clone();
            }
            let mut changed = false;
            let mut out = Vec::with_capacity(fields.len());
            for (k, v) in fields {
                let nv = subst_shared(v, bindings, memo);
                changed |= !Rc::ptr_eq(&nv, v);
                out.push((k.clone(), nv));
            }
            let res = if changed {
                Rc::new(SNode::Obj(out))
            } else {
                node.clone()
            };
            memo.insert(key, res.clone());
            res
        }
        _ => node.clone(),
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
    /// — the §9.7.3-composed body as a shared DAG.
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
    /// All template declarations in the component (params / bindings
    /// validation for named expansion; bodies live in `bodies`).
    decls: &'a Map<String, Value>,
    /// The §9.7.3-composed closed bodies as shared DAGs, keyed by template
    /// name (named-expansion lookup table).
    bodies: &'a std::collections::HashMap<String, Sv>,
    /// Auto-applied `match` rules, **pre-sorted** highest-`priority`-first with
    /// ties broken by declaration order (esm-spec §9.6.3). `rewrite_pass` fires
    /// the first rule in this order whose pattern matches a node.
    rules: &'a [MatchRule],
    /// The enclosing component's static shape environment (declared variable
    /// name → declared shape), consulted by a rule's `where` constraints
    /// (esm-spec §9.6.1). Empty when no component context (coupling transforms
    /// use the receiving component's environment).
    shape_env: &'a std::collections::BTreeMap<String, Vec<String>>,
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
                    "template_constraint_unknown_index_set",
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
    bodies: &std::collections::HashMap<String, Sv>,
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
        // The §9.7.3-composed closed body (shared DAG); `bodies` covers every
        // declared template, so a miss only happens for a body-less decl.
        let body = bodies
            .get(name)
            .cloned()
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

fn expand_apply(
    node: &[(String, Sv)],
    decls: &Map<String, Value>,
    bodies: &std::collections::HashMap<String, Sv>,
    scope: &str,
) -> Result<Sv, ExpressionTemplateError> {
    let name = match obj_get(node, "name").map(|v| &**v) {
        Some(SNode::Str(s)) => Some(s.as_str()),
        _ => None,
    }
    .ok_or_else(|| {
        err(
            "apply_expression_template_invalid_declaration",
            format!("{scope}: apply_expression_template node missing or empty 'name'"),
        )
    })?;
    if name.is_empty() {
        return Err(err(
            "apply_expression_template_invalid_declaration",
            format!("{scope}: apply_expression_template 'name' must be non-empty"),
        ));
    }
    let decl = decls.get(name).ok_or_else(|| {
        err(
            "apply_expression_template_unknown_template",
            format!("{scope}: apply_expression_template references undeclared template '{name}'"),
        )
    })?;
    let decl_obj = decl.as_object().ok_or_else(|| {
        err(
            "apply_expression_template_invalid_declaration",
            format!("{scope}: template '{name}' declaration is not an object"),
        )
    })?;
    let bindings: &[(String, Sv)] = match obj_get(node, "bindings").map(|v| &**v) {
        Some(SNode::Obj(fields)) => fields,
        _ => {
            return Err(err(
                "apply_expression_template_bindings_mismatch",
                format!("{scope}: apply_expression_template '{name}' missing 'bindings' object"),
            ));
        }
    };

    let params: Vec<&str> = decl_obj
        .get("params")
        .and_then(|p| p.as_array())
        .map(|arr| arr.iter().filter_map(|v| v.as_str()).collect())
        .unwrap_or_default();
    let declared: std::collections::HashSet<&str> = params.iter().copied().collect();
    let provided: std::collections::HashSet<&str> =
        bindings.iter().map(|(k, _)| k.as_str()).collect();
    for p in &params {
        if !provided.contains(p) {
            return Err(err(
                "apply_expression_template_bindings_mismatch",
                format!(
                    "{scope}: apply_expression_template '{name}' missing binding for param '{p}'"
                ),
            ));
        }
    }
    for (p, _) in bindings {
        if !declared.contains(p.as_str()) {
            return Err(err(
                "apply_expression_template_bindings_mismatch",
                format!("{scope}: apply_expression_template '{name}' supplies unknown param '{p}'"),
            ));
        }
    }

    // Splice the bindings' sub-ASTs into the body AS-IS (esm-spec §9.6.3): the
    // substituted body is re-scanned in a SUBSEQUENT pass, so any
    // `apply_expression_template` op or `match`-eligible sub-AST inside a
    // binding is rewritten then — not here. Bindings are spliced BY
    // REFERENCE: a binding used at several substitution sites is shared, not
    // copied. A body itself may not contain `apply_expression_template`
    // call sites by this point (composed at registration, §9.7.3).
    let resolved: Binds = bindings.to_vec();
    let body = bodies
        .get(name)
        .cloned()
        .unwrap_or_else(|| Rc::new(SNode::Null));
    Ok(substitute(&body, &resolved))
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
            let key = Rc::as_ptr(node);
            if let Some((res, ch, l)) = memo.get(&key) {
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
            memo.insert(key, (res.clone(), changed, changed.then(|| last.clone())));
            Ok((res, changed))
        }
        SNode::Obj(fields) => {
            let key = Rc::as_ptr(node);
            if let Some((res, ch, l)) = memo.get(&key) {
                if let Some(l) = l {
                    *last = l.clone();
                }
                return Ok((res.clone(), *ch));
            }
            let op = obj_op(fields);
            // (1) Outermost-first: fire a rule AT this node before descending.
            if op == Some(APPLY_OP) {
                *last = APPLY_OP.to_string();
                let res = expand_apply(fields, ctx.decls, ctx.bodies, scope)?;
                memo.insert(key, (res.clone(), true, Some(last.clone())));
                return Ok((res, true));
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
                    let res = substitute(&rule.body, &binds);
                    memo.insert(key, (res.clone(), true, Some(last.clone())));
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
            memo.insert(key, (res.clone(), changed, changed.then(|| last.clone())));
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
    let mut current = node.clone();
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
        "rewrite_rule_nonterminating",
        format!(
            "{scope}: expression-template rewriting did not converge within \
             MAX_REWRITE_PASSES={MAX_REWRITE_PASSES} passes (last rewritten op '{last}'). \
             A `match` rule likely re-introduces its own pattern (esm-spec §9.6.3)."
        ),
    ))
}

fn find_apply_paths(view: &Value, path: &str, hits: &mut Vec<String>) {
    match view {
        Value::Array(arr) => {
            for (i, child) in arr.iter().enumerate() {
                find_apply_paths(child, &format!("{path}/{i}"), hits);
            }
        }
        Value::Object(obj) => {
            if obj.get("op").and_then(|v| v.as_str()) == Some(APPLY_OP) {
                hits.push(path.to_string());
            }
            for (k, v) in obj {
                find_apply_paths(v, &format!("{path}/{k}"), hits);
            }
        }
        _ => {}
    }
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
    find_apply_paths(view, "", &mut offences);

    if !offences.is_empty() {
        return Err(err(
            "apply_expression_template_version_too_old",
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
/// lowering and reused by coupling `variable_map` transforms (esm-spec §10.4):
/// the named-template lookup table, the pre-sorted auto `match` rules (with
/// their registered `where` constraints), and the static shape environment the
/// constraints consult.
struct CompRegistry {
    /// Template declarations (params / bindings validation).
    decls: Map<String, Value>,
    /// §9.7.3-composed closed bodies as shared DAGs (`Rc` clones — cheap).
    bodies: std::collections::HashMap<String, Sv>,
    rules: Vec<MatchRule>,
    shape_env: std::collections::BTreeMap<String, Vec<String>>,
}

/// Run the single load-time rewrite pass (esm-spec §9.6): expand every
/// `apply_expression_template` op, auto-apply each component's `match` rules in
/// declaration order, and strip the `expression_templates` blocks. Mutates
/// `value` in place. This is the format's one structural-substitution engine —
/// variable substitution, named-template expansion, and PDE-operator / `bc`
/// lowering all flow through [`rewrite`].
///
/// Pre-condition: the input has been schema-validated.
pub fn lower_expression_templates(value: &mut Value) -> Result<(), ExpressionTemplateError> {
    reject_expression_templates_pre_v04(value)?;

    let Some(root) = value.as_object_mut() else {
        return Ok(());
    };

    // The consuming document's merged index_sets registry (post-§9.7.5): the
    // namespace `where` shape constraints resolve against at registration
    // (esm-spec §9.6.1 — `template_constraint_unknown_index_set` for a name not
    // declared here). Captured before the per-component mutable borrows.
    let iset_names: std::collections::HashSet<String> = root
        .get("index_sets")
        .and_then(|v| v.as_object())
        .map(|o| o.keys().cloned().collect())
        .unwrap_or_default();

    // Per-component rewrite registries (templates + ordered match rules + static
    // shape environment), captured so coupling `variable_map` expression
    // transforms (esm-spec §10.4) can be rewritten against the RECEIVING
    // component's registry below. Models are registered first; a reaction
    // system never overwrites a same-named model.
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
            // (esm-spec §9.6.1): declared variable shapes only. Computed before
            // the templates block is removed (it reads only `variables`).
            let shape_env = component_shape_env(comp);
            // Take the templates block (if any) so we can borrow comp mutably.
            let templates: Map<String, Value> = match comp.remove("expression_templates") {
                Some(Value::Object(t)) => t,
                _ => Map::new(),
            };
            // A template-less component has nothing to expand or auto-apply.
            // Stray `apply_expression_template` nodes (if any) are caught by
            // the post-pass leftover scan below as `unknown_template`.
            if templates.is_empty() {
                continue;
            }
            validate_templates(&templates, &scope_base)?;
            // Registration-time body composition (esm-spec §9.7.3): inline
            // body references to match-less in-scope templates as a
            // statically-checked acyclic DAG, so every rule body the
            // fixpoint sees is a closed AST. Composed bodies are shared
            // DAGs — a referenced body is spliced by reference, never
            // copied — so a deep multi-reference chain stays linear here.
            let composed = compose_template_bodies_shared(&templates, &scope_base)?;
            let rules = collect_match_rules(&templates, &composed.bodies, &iset_names, &scope_base)?;
            let ctx = RewriteCtx {
                decls: &templates,
                bodies: &composed.bodies,
                rules: &rules,
                shape_env: &shape_env,
            };
            // Outermost-first, priority-ordered, bounded-fixpoint rewrite per
            // non-template field (esm-spec §9.6.3): expands
            // `apply_expression_template` ops AND fires auto `match` rules until
            // a pass performs zero rewrites (or the pass bound rejects). Each
            // field is rewritten in the shared representation and materialized
            // back into the owned document ONCE, only if it changed.
            let keys: Vec<String> = comp.keys().cloned().collect();
            for k in keys {
                let scope = format!("{scope_base}.{k}");
                let Some(child) = comp.get(&k) else { continue };
                let shared = to_shared(child);
                let rewritten = rewrite_to_fixpoint(&shared, &ctx, &scope)?;
                if !Rc::ptr_eq(&rewritten, &shared) {
                    comp.insert(k, to_value(&rewritten));
                }
            }
            registries
                .entry(cname.clone())
                .or_insert_with(|| CompRegistry {
                    decls: templates.clone(),
                    bodies: composed.bodies.clone(),
                    rules: rules.clone(),
                    shape_env: shape_env.clone(),
                });
        }
    }

    // Coupling `variable_map` expression transforms (esm-spec §10.4/§10.5):
    // template invocations in a transform expand at load against the template
    // registry of the component that owns the entry's `to` target — the
    // RECEIVING component, where a regridding library import (§9.7) lives. The
    // transform is rewritten to fixpoint exactly as a field of that component
    // would be (named templates + auto `match` rules, §9.6.3). A transform
    // whose receiving component is absent or template-less is left
    // unrewritten; any `apply_expression_template` nodes remaining in it are
    // caught by the leftover scan below.
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
                decls: &reg.decls,
                bodies: &reg.bodies,
                rules: &reg.rules,
                shape_env: &reg.shape_env,
            };
            let scope = format!("coupling[{idx}].transform");
            let shared = to_shared(&transform);
            let rewritten = rewrite_to_fixpoint(&shared, &ctx, &scope)?;
            if !Rc::ptr_eq(&rewritten, &shared) {
                obj.insert("transform".to_string(), to_value(&rewritten));
            }
        }
    }

    // Residual call sites. The top-level `expression_templates` registry is
    // EXCLUDED: it is a DECLARATION that survives verbatim (esm-spec §9.6.4 rule
    // 5), and a template BODY may legitimately carry `apply_expression_template`
    // nodes referencing other match-less templates — resolved at registration
    // time as an acyclic DAG (§9.6.3 / §9.7.3), not leftover call sites. Scanning
    // it would report a template library's own declarations as unexpanded, which
    // is exactly what happened the moment the registry stopped being deleted.
    let mut leftover: Vec<String> = Vec::new();
    match value.as_object() {
        Some(root) => {
            for (key, child) in root {
                if key == "expression_templates" {
                    continue;
                }
                find_apply_paths(child, &format!("/{key}"), &mut leftover);
            }
        }
        None => find_apply_paths(value, "", &mut leftover),
    }
    if !leftover.is_empty() {
        return Err(err(
            "apply_expression_template_unknown_template",
            format!(
                "apply_expression_template ops remain after expansion at: {} \
                 — likely referenced from a component lacking an expression_templates block",
                leftover.join(", ")
            ),
        ));
    }

    // Validators run on the expanded form (esm-spec §9.6.4): reject any
    // geometry-kernel node whose (possibly just-substituted) `manifold` is
    // outside the closed set, and any makearray region whose folded bound pair
    // is inverted (stop < start - 1; esm-spec §4.3.2).
    validate_geometry_manifolds(value, "")?;
    validate_makearray_regions(value, "")?;

    Ok(())
}

/// Geometry-kernel ops whose `manifold` scalar field is restricted to the
/// closed manifold registry (CONFORMANCE_SPEC §5.8.4).
const GEOMETRY_MANIFOLD_OPS: [&str; 2] = ["intersect_polygon", "polygon_intersection_area"];

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
                        "geometry_manifold_invalid",
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
                                "makearray_region_inverted",
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn arrhenius_fixture() -> Value {
        json!({
          "esm": "0.4.0",
          "metadata": {"name": "expr_template_smoke", "authors": ["esm-giy"]},
          "reaction_systems": {
            "chem": {
              "species": {"A": {"default": 1.0}, "B": {"default": 0.5}},
              "parameters": {"T": {"default": 298.15}, "num_density": {"default": 2.5e19}},
              "expression_templates": {
                "arrhenius": {
                  "params": ["A_pre", "Ea"],
                  "body": {
                    "op": "*",
                    "args": [
                      "A_pre",
                      {"op": "exp", "args": [
                        {"op": "/", "args": [{"op": "-", "args": ["Ea"]}, "T"]}
                      ]},
                      "num_density"
                    ]
                  }
                }
              },
              "reactions": [
                {"id": "R1",
                 "substrates": [{"species": "A", "stoichiometry": 1}],
                 "products": [{"species": "B", "stoichiometry": 1}],
                 "rate": {"op": "apply_expression_template", "args": [],
                          "name": "arrhenius",
                          "bindings": {"A_pre": 1.8e-12, "Ea": 1500}}}
              ]
            }
          }
        })
    }

    #[test]
    fn expansion_strips_templates_block_and_replaces_apply_node() {
        let mut v = arrhenius_fixture();
        lower_expression_templates(&mut v).expect("expansion");
        let chem = &v["reaction_systems"]["chem"];
        assert!(chem.get("expression_templates").is_none());
        let rate = &chem["reactions"][0]["rate"];
        assert_eq!(rate["op"], json!("*"));
        // First arg: the scalar 1.8e-12.
        assert_eq!(rate["args"][0], json!(1.8e-12));
    }

    #[test]
    fn rejects_unknown_template_name() {
        let mut v = arrhenius_fixture();
        v["reaction_systems"]["chem"]["reactions"][0]["rate"]["name"] = json!("missing");
        let e = lower_expression_templates(&mut v).expect_err("should fail");
        assert_eq!(e.code, "apply_expression_template_unknown_template");
    }

    #[test]
    fn rejects_missing_binding() {
        let mut v = arrhenius_fixture();
        v["reaction_systems"]["chem"]["reactions"][0]["rate"]["bindings"]
            .as_object_mut()
            .unwrap()
            .remove("Ea");
        let e = lower_expression_templates(&mut v).expect_err("should fail");
        assert_eq!(e.code, "apply_expression_template_bindings_mismatch");
    }

    #[test]
    fn rejects_extra_binding() {
        let mut v = arrhenius_fixture();
        v["reaction_systems"]["chem"]["reactions"][0]["rate"]["bindings"]["bogus"] = json!(99);
        let e = lower_expression_templates(&mut v).expect_err("should fail");
        assert_eq!(e.code, "apply_expression_template_bindings_mismatch");
    }

    #[test]
    fn rejects_recursive_body() {
        let mut v = arrhenius_fixture();
        v["reaction_systems"]["chem"]["expression_templates"]["arrhenius"]["body"] = json!({
            "op": "apply_expression_template",
            "args": [],
            "name": "arrhenius",
            "bindings": {"A_pre": 1, "Ea": 1}
        });
        let e = lower_expression_templates(&mut v).expect_err("should fail");
        assert_eq!(e.code, "apply_expression_template_recursive_body");
    }

    /// A chain of match-less templates T0..T12 where each T_i's body
    /// references T_{i-1} TWICE (esm-spec §9.7.3) logically expands to 2^12
    /// copies of the T0 leaf. Composition and call-site expansion must build
    /// this with structural sharing (shared DAGs, materialized into the owned
    /// document once): the old deep-copy substitution was exponential in time
    /// and memory across every intermediate — composed bodies, per-pass tree
    /// rebuilds, registry clones — and OOMed real ~4KB documents at depth 19
    /// while respecting every documented limit (chain depth <= 32). The
    /// expanded document itself is byte-identical either way; this pins the
    /// expansion's correctness at a depth where the pre-fix pipeline was
    /// already pathological.
    #[test]
    fn deep_double_reference_chain_expands_correctly() {
        const DEPTH: usize = 12;
        let apply = |name: &str| -> Value {
            json!({"op": APPLY_OP, "args": [], "name": name, "bindings": {}})
        };
        let mut templates = Map::new();
        templates.insert(
            "T0".to_string(),
            json!({"params": [], "body": {"op": "*", "args": [
                1.8e-12,
                {"op": "exp", "args": [
                    {"op": "/", "args": [{"op": "-", "args": [1500.0]}, "T"]}
                ]}
            ]}}),
        );
        for i in 1..=DEPTH {
            let prev = format!("T{}", i - 1);
            templates.insert(
                format!("T{i}"),
                json!({"params": [], "body": {"op": "+", "args": [apply(&prev), apply(&prev)]}}),
            );
        }
        let mut v = json!({
            "esm": "0.4.0",
            "metadata": {"name": "deep_chain", "authors": ["t"]},
            "reaction_systems": {"chem": {
                "species": {"A": {"default": 1.0}, "B": {"default": 0.5}},
                "parameters": {"T": {"default": 298.15}},
                "expression_templates": Value::Object(templates),
                "reactions": [{
                    "id": "R1",
                    "substrates": [{"species": "A", "stoichiometry": 1}],
                    "products": [{"species": "B", "stoichiometry": 1}],
                    "rate": apply(&format!("T{DEPTH}"))
                }]
            }}
        });
        lower_expression_templates(&mut v).expect("expansion");
        let chem = &v["reaction_systems"]["chem"];
        assert!(chem.get("expression_templates").is_none());
        let rate = &chem["reactions"][0]["rate"];
        assert_eq!(rate["op"], json!("+"));
        // Leftmost leaf: the T0 Arrhenius-style body, fully closed.
        let mut leaf = rate;
        while leaf["op"] == json!("+") {
            leaf = &leaf["args"][0];
        }
        assert_eq!(leaf["op"], json!("*"));
        assert_eq!(leaf["args"][0], json!(1.8e-12));
        // Node count of the materialized tree: the T0 body has 15 JSON values
        // and each `+` level contributes 3 (object + "op" string + args
        // array) plus its two children -> nodes(d) = 2^d * 18 - 3.
        fn count(v: &Value) -> usize {
            match v {
                Value::Array(a) => 1 + a.iter().map(count).sum::<usize>(),
                Value::Object(o) => 1 + o.values().map(count).sum::<usize>(),
                _ => 1,
            }
        }
        assert_eq!(count(rate), (1usize << DEPTH) * 18 - 3);
    }

    #[test]
    fn rejects_pre_v04_files_using_templates() {
        let mut v = arrhenius_fixture();
        v["esm"] = json!("0.3.5");
        let e = lower_expression_templates(&mut v).expect_err("should fail");
        assert_eq!(e.code, "apply_expression_template_version_too_old");
    }

    #[test]
    fn ast_valued_bindings_substitute_into_body() {
        let mut v = arrhenius_fixture();
        v["reaction_systems"]["chem"]["reactions"][0]["rate"]["bindings"]["Ea"] = json!({
            "op": "*", "args": [3, "T"]
        });
        lower_expression_templates(&mut v).expect("expansion");
        let rate = &v["reaction_systems"]["chem"]["reactions"][0]["rate"];
        let exp_node = &rate["args"][1];
        assert_eq!(exp_node["op"], json!("exp"));
        let div_node = &exp_node["args"][0];
        assert_eq!(div_node["op"], json!("/"));
        let neg_node = &div_node["args"][0];
        assert_eq!(neg_node["op"], json!("-"));
        let inner = &neg_node["args"][0];
        assert_eq!(inner["op"], json!("*"));
    }

    #[test]
    fn conformance_fixture_matches_expanded_form() {
        let manifest_dir = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let repo_root = manifest_dir
            .parent()
            .and_then(|p| p.parent())
            .expect("repo_root from CARGO_MANIFEST_DIR")
            .to_path_buf();
        let fixture_path =
            repo_root.join("tests/conformance/expression_templates/arrhenius_smoke/fixture.esm");
        let expanded_path =
            repo_root.join("tests/conformance/expression_templates/arrhenius_smoke/expanded.esm");
        let src = std::fs::read_to_string(&fixture_path).expect("read fixture.esm");
        let mut got: Value = serde_json::from_str(&src).expect("parse fixture");
        lower_expression_templates(&mut got).expect("expansion");
        let expanded_src = std::fs::read_to_string(&expanded_path).expect("read expanded.esm");
        let want: Value = serde_json::from_str(&expanded_src).expect("parse expanded");
        let got_reactions = &got["reaction_systems"]["chem"]["reactions"];
        let want_reactions = &want["reaction_systems"]["chem"]["reactions"];
        assert_eq!(got_reactions, want_reactions);
    }

    /// The v0.8.0 variable_map expression-transform widening (esm-spec
    /// §10.4/§10.5): a coupling `transform` invoking a template declared by the
    /// RECEIVING component expands at load against that component's registry
    /// (§9.6.4). Cross-binding golden: expanded.esm.
    #[test]
    fn coupling_transform_expression_conformance_fixture_matches_expanded_form() {
        let manifest_dir = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let repo_root = manifest_dir
            .parent()
            .and_then(|p| p.parent())
            .expect("repo_root from CARGO_MANIFEST_DIR")
            .to_path_buf();
        let case =
            repo_root.join("tests/conformance/expression_templates/coupling_transform_expression");
        let src = std::fs::read_to_string(case.join("fixture.esm")).expect("read fixture.esm");
        let mut got: Value = serde_json::from_str(&src).expect("parse fixture");
        lower_expression_templates(&mut got).expect("expansion");
        let expanded_src =
            std::fs::read_to_string(case.join("expanded.esm")).expect("read expanded.esm");
        let want: Value = serde_json::from_str(&expanded_src).expect("parse expanded");
        assert_eq!(&got["coupling"], &want["coupling"]);
        assert_eq!(&got["models"], &want["models"]);
    }

    #[test]
    fn no_templates_block_is_a_noop() {
        let mut v = json!({
            "esm": "0.4.0",
            "metadata": {"name": "no_templates", "authors": ["t"]},
            "reaction_systems": {
                "chem": {
                    "species": {"A": {}},
                    "parameters": {"k": {"default": 1.0}},
                    "reactions": [{
                        "id": "R1",
                        "substrates": [{"species": "A", "stoichiometry": 1}],
                        "products": null,
                        "rate": "k"
                    }]
                }
            }
        });
        lower_expression_templates(&mut v).expect("expansion");
        assert_eq!(
            v["reaction_systems"]["chem"]["reactions"][0]["rate"],
            json!("k")
        );
    }

    /// A `match` rule (esm-spec §9.6) auto-applies wherever its operator pattern
    /// matches — no `apply_expression_template` node required — binding an
    /// operand metavariable to the matched sub-AST. Non-matching siblings (the
    /// equation LHS) are left untouched.
    #[test]
    fn match_rule_lowers_grad_operator() {
        let mut v = json!({
          "esm": "0.4.0",
          "metadata": {"name": "grad_lowering", "authors": ["t"]},
          "models": {
            "Diff": {
              "variables": {"u": {"type": "state"}},
              "expression_templates": {
                "central_grad_x": {
                  "params": ["f"],
                  "match": {"op": "grad", "args": ["f"], "dim": "x"},
                  "body": {
                    "op": "-",
                    "args": [
                      {"op": "index", "args": ["f", {"op": "+", "args": ["i", 1]}]},
                      {"op": "index", "args": ["f", {"op": "-", "args": ["i", 1]}]}
                    ]
                  }
                }
              },
              "equations": [
                {"lhs": {"op": "D", "args": ["u"], "wrt": "t"},
                 "rhs": {"op": "grad", "args": ["u"], "dim": "x"}}
              ]
            }
          }
        });
        lower_expression_templates(&mut v).expect("rewrite");
        let model = &v["models"]["Diff"];
        assert!(model.get("expression_templates").is_none());
        let rhs = &model["equations"][0]["rhs"];
        // grad(u, dim=x) lowered to the finite-difference body, f -> "u".
        assert_eq!(rhs["op"], json!("-"));
        assert_eq!(rhs["args"][0]["op"], json!("index"));
        assert_eq!(rhs["args"][0]["args"][0], json!("u"));
        assert_eq!(rhs["args"][1]["args"][0], json!("u"));
        // The non-matching LHS is left untouched.
        assert_eq!(model["equations"][0]["lhs"]["op"], json!("D"));
    }

    /// A metavariable appearing in a scalar field (`dim`) binds the matched
    /// literal, while one in `args` binds the matched sub-AST.
    #[test]
    fn match_rule_binds_scalar_field_metavariable() {
        let mut v = json!({
          "esm": "0.4.0",
          "metadata": {"name": "scalar_meta", "authors": ["t"]},
          "models": {
            "M": {
              "variables": {"u": {"type": "state"}},
              "expression_templates": {
                "grad_to_deriv": {
                  "params": ["f", "d"],
                  "match": {"op": "grad", "args": ["f"], "dim": "d"},
                  "body": {"op": "deriv", "args": ["f"], "wrt": "d"}
                }
              },
              "equations": [
                {"lhs": "u", "rhs": {"op": "grad", "args": ["u"], "dim": "y"}}
              ]
            }
          }
        });
        lower_expression_templates(&mut v).expect("rewrite");
        let rhs = &v["models"]["M"]["equations"][0]["rhs"];
        assert_eq!(rhs["op"], json!("deriv"));
        assert_eq!(rhs["args"][0], json!("u")); // operand metavar f -> "u"
        assert_eq!(rhs["wrt"], json!("y")); // scalar metavar d -> literal "y"
    }

    /// A `match` rule whose `body` re-introduces its own pattern never reaches a
    /// fixpoint. There is no static pre-check any more (esm-spec §9.6.3): the
    /// bounded fixpoint runs `MAX_REWRITE_PASSES` productive passes without
    /// converging and then rejects the file with `rewrite_rule_nonterminating`.
    #[test]
    fn rejects_nonterminating_match_rule() {
        let mut v = json!({
          "esm": "0.4.0",
          "metadata": {"name": "nonterm", "authors": ["t"]},
          "models": {
            "M": {
              "variables": {"u": {"type": "state"}},
              "expression_templates": {
                "loop_rule": {
                  "params": ["f"],
                  "match": {"op": "grad", "args": ["f"], "dim": "x"},
                  "body": {"op": "+", "args": [
                    {"op": "grad", "args": ["f"], "dim": "x"}, 1]}
                }
              },
              "equations": [
                {"lhs": "u", "rhs": {"op": "grad", "args": ["u"], "dim": "x"}}
              ]
            }
          }
        });
        let e = lower_expression_templates(&mut v).expect_err("should fail");
        assert_eq!(e.code, "rewrite_rule_nonterminating");
    }

    /// Rules are applied in template *declaration order* (not the alphabetical
    /// key order of an unordered map): the first declared rule whose pattern
    /// matches wins. `z_rule` is declared before `a_rule`, so it must fire.
    #[test]
    fn match_rules_apply_in_declaration_order() {
        let mut v = json!({
          "esm": "0.4.0",
          "metadata": {"name": "order", "authors": ["t"]},
          "models": {
            "M": {
              "variables": {"u": {"type": "state"}},
              "expression_templates": {
                "z_rule": {
                  "params": ["f"],
                  "match": {"op": "grad", "args": ["f"], "dim": "x"},
                  "body": {"op": "winner", "args": ["f"]}
                },
                "a_rule": {
                  "params": ["f"],
                  "match": {"op": "grad", "args": ["f"], "dim": "x"},
                  "body": {"op": "loser", "args": ["f"]}
                }
              },
              "equations": [
                {"lhs": "u", "rhs": {"op": "grad", "args": ["u"], "dim": "x"}}
              ]
            }
          }
        });
        lower_expression_templates(&mut v).expect("rewrite");
        let rhs = &v["models"]["M"]["equations"][0]["rhs"];
        assert_eq!(rhs["op"], json!("winner"));
    }

    /// `priority` out-ranks declaration order (esm-spec §9.6.3): a
    /// later-declared rule with higher `priority` fires over an earlier-declared
    /// default-priority rule matching the same node.
    #[test]
    fn higher_priority_rule_wins_over_earlier_declared() {
        let mut v = json!({
          "esm": "0.8.0",
          "metadata": {"name": "prio", "authors": ["t"]},
          "models": {
            "M": {
              "variables": {"u": {"type": "state"}},
              "expression_templates": {
                "low": {
                  "params": ["f"],
                  "match": {"op": "grad", "args": ["f"], "dim": "x"},
                  "body": {"op": "loser", "args": ["f"]}
                },
                "high": {
                  "params": ["f"],
                  "priority": 100,
                  "match": {"op": "grad", "args": ["f"], "dim": "x"},
                  "body": {"op": "winner", "args": ["f"]}
                }
              },
              "equations": [
                {"lhs": "u", "rhs": {"op": "grad", "args": ["u"], "dim": "x"}}
              ]
            }
          }
        });
        lower_expression_templates(&mut v).expect("rewrite");
        assert_eq!(
            v["models"]["M"]["equations"][0]["rhs"]["op"],
            json!("winner")
        );
    }

    /// The bounded fixpoint re-scans a freshly-produced body only in a SUBSEQUENT
    /// pass (esm-spec §9.6.3): a sugar rule emits a nested op that a second rule
    /// lowers on the next pass, converging to a fully-lowered tree.
    #[test]
    fn produced_body_is_rescanned_in_a_later_pass() {
        let mut v = json!({
          "esm": "0.8.0",
          "metadata": {"name": "fixpoint", "authors": ["t"]},
          "models": {
            "M": {
              "variables": {"u": {"type": "state"}},
              "expression_templates": {
                "sugar": {
                  "params": ["f"],
                  "match": {"op": "sugar", "args": ["f"]},
                  "body": {"op": "inner", "args": ["f"]}
                },
                "inner_to_leaf": {
                  "params": ["f"],
                  "match": {"op": "inner", "args": ["f"]},
                  "body": {"op": "*", "args": ["k", "f"]}
                }
              },
              "equations": [
                {"lhs": "u", "rhs": {"op": "sugar", "args": ["u"]}}
              ]
            }
          }
        });
        lower_expression_templates(&mut v).expect("rewrite");
        let rhs = &v["models"]["M"]["equations"][0]["rhs"];
        // sugar(u) -> inner(u) (pass 1) -> k * u (pass 2).
        assert_eq!(*rhs, json!({"op": "*", "args": ["k", "u"]}));
    }
    // -----------------------------------------------------------------------
    // Scalar-field template-parameter substitution
    // (esm-spec §9.6.1 / §9.6.3 constraint 5; mirrors the other bindings 1:1)
    // -----------------------------------------------------------------------

    fn scalar_field_doc(templates: Value, bindings: Value, name: &str) -> Value {
        json!({
          "esm": "0.8.0",
          "metadata": {"name": "scalar_field_param_unit", "authors": ["t"]},
          "models": {"M": {
            "variables": {
              "pa": {"type": "parameter"},
              "pb": {"type": "parameter"},
              "area": {"type": "observed",
                "expression": {"op": "apply_expression_template", "args": [],
                  "name": name, "bindings": bindings}}
            },
            "equations": [],
            "expression_templates": templates
          }}
        })
    }

    /// A parameter name appearing as the string value of a scalar
    /// Expression-node field in `body` is a substitution site (the mirror of
    /// the match-side scalar-field binding rule, esm-spec §9.6.1).
    #[test]
    fn scalar_field_substitution_happy_path() {
        let mut v = scalar_field_doc(
            json!({"overlap_area": {
              "params": ["K_manifold", "a", "b"],
              "body": {"op": "polygon_intersection_area",
                       "manifold": "K_manifold", "args": ["a", "b"]}}}),
            json!({"K_manifold": "planar", "a": "pa", "b": "pb"}),
            "overlap_area",
        );
        lower_expression_templates(&mut v).expect("rewrite");
        assert_eq!(
            v["models"]["M"]["variables"]["area"]["expression"],
            json!({"op": "polygon_intersection_area", "manifold": "planar",
                   "args": ["pa", "pb"]})
        );
    }

    /// A scalar-field param passed through a §9.7.3 registration-time body
    /// composition (outer body applies inner, forwarding its own param into
    /// the inner manifold slot) substitutes end-to-end.
    #[test]
    fn scalar_field_param_threads_through_body_composition() {
        let mut v = scalar_field_doc(
            json!({
              "inner": {
                "params": ["m", "x", "y"],
                "body": {"op": "polygon_intersection_area", "manifold": "m",
                         "args": ["x", "y"]}},
              "outer": {
                "params": ["K", "p", "q"],
                "body": {"op": "*", "args": [
                  {"op": "apply_expression_template", "args": [], "name": "inner",
                   "bindings": {"m": "K", "x": "p", "y": "q"}},
                  2.0]}}
            }),
            json!({"K": "spherical", "p": "pa", "q": "pb"}),
            "outer",
        );
        lower_expression_templates(&mut v).expect("rewrite");
        assert_eq!(
            v["models"]["M"]["variables"]["area"]["expression"],
            json!({"op": "*", "args": [
              {"op": "polygon_intersection_area", "manifold": "spherical",
               "args": ["pa", "pb"]},
              2.0]})
        );
    }

    /// Validators run on the expanded form (esm-spec §9.6.4): a template
    /// invocation binding the manifold parameter to a non-member literal is
    /// rejected with `geometry_manifold_invalid`.
    #[test]
    fn scalar_field_invalid_substituted_manifold_rejected() {
        let mut v = scalar_field_doc(
            json!({"overlap_area": {
              "params": ["K_manifold", "a", "b"],
              "body": {"op": "polygon_intersection_area",
                       "manifold": "K_manifold", "args": ["a", "b"]}}}),
            json!({"K_manifold": "bogus", "a": "pa", "b": "pb"}),
            "overlap_area",
        );
        let err = lower_expression_templates(&mut v).expect_err("must reject");
        assert_eq!(err.code, "geometry_manifold_invalid");
    }

    /// Pinned shadowing resolution (esm-spec §9.6.1): a declared param name
    /// shadows a coincident field literal inside `body` — the param wins.
    /// Authors must not name params after field literals; the engine
    /// substitutes anyway.
    #[test]
    fn scalar_field_params_shadow_literals() {
        let mut v = scalar_field_doc(
            json!({"shadowed": {
              "params": ["planar", "x", "y"],
              "body": {"op": "polygon_intersection_area",
                       "manifold": "planar", "args": ["x", "y"]}}}),
            json!({"planar": "spherical", "x": "pa", "y": "pb"}),
            "shadowed",
        );
        lower_expression_templates(&mut v).expect("rewrite");
        assert_eq!(
            v["models"]["M"]["variables"]["area"]["expression"]["manifold"],
            json!("spherical")
        );
    }
}
