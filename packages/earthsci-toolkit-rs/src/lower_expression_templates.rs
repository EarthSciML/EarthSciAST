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

const APPLY_OP: &str = "apply_expression_template";

/// Stable diagnostic codes raised by the expression-template expansion
/// pass. Mirrors the codes emitted by the TS / Python / Julia / Go bindings.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExpressionTemplateError {
    pub code: &'static str,
    pub message: String,
}

impl std::fmt::Display for ExpressionTemplateError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "[{}] {}", self.code, self.message)
    }
}

impl std::error::Error for ExpressionTemplateError {}

fn err(code: &'static str, message: impl Into<String>) -> ExpressionTemplateError {
    ExpressionTemplateError {
        code,
        message: message.into(),
    }
}

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

/// Inline every `apply_expression_template` node in `node` against
/// `templates`, post-order (so the bindings' own sub-ASTs are inlined
/// first). Referenced bodies are already closed when this runs in
/// topological order, so a single `expand_apply` produces an apply-free
/// subtree.
fn inline_applies(
    node: &Value,
    templates: &Map<String, Value>,
    scope: &str,
) -> Result<Value, ExpressionTemplateError> {
    match node {
        Value::Array(arr) => {
            let mut out = Vec::with_capacity(arr.len());
            for c in arr {
                out.push(inline_applies(c, templates, scope)?);
            }
            Ok(Value::Array(out))
        }
        Value::Object(obj) => {
            let mut out = Map::new();
            for (k, v) in obj {
                out.insert(k.clone(), inline_applies(v, templates, scope)?);
            }
            if out.get("op").and_then(|v| v.as_str()) == Some(APPLY_OP) {
                return expand_apply(&out, templates, scope);
            }
            Ok(Value::Object(out))
        }
        _ => Ok(node.clone()),
    }
}

/// Registration-time body composition (esm-spec §9.7.3): template bodies MAY
/// reference other in-scope MATCH-LESS templates via
/// `apply_expression_template` nodes. Builds the body-reference graph,
/// rejects cycles (`apply_expression_template_recursive_body`) and chains
/// deeper than `MAX_TEMPLATE_EXPANSION_DEPTH` templates
/// (`template_body_expansion_too_deep`), then inlines dependencies-first by
/// pure substitution — confluent, so topological order cannot affect the
/// result. Afterwards every `body` is a closed Expression AST with zero
/// `apply_expression_template` nodes; runs BEFORE the §9.6.3 fixpoint ever
/// consults a `match` rule. Mutates the decl objects in `templates` in
/// place.
pub(crate) fn compose_template_bodies(
    templates: &mut Map<String, Value>,
    scope: &str,
) -> Result<(), ExpressionTemplateError> {
    if templates.is_empty() {
        return Ok(());
    }
    let mut refs: std::collections::BTreeMap<String, Vec<String>> = std::collections::BTreeMap::new();
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
        visit(name, &refs, &mut state, &mut depth, &mut order, &mut chain, scope)?;
    }

    for name in order {
        let Some(rs) = refs.get(&name) else { continue };
        if rs.is_empty() {
            continue;
        }
        let body = templates
            .get(&name)
            .and_then(|d| d.get("body"))
            .cloned()
            .unwrap_or(Value::Null);
        let inlined = inline_applies(
            &body,
            templates,
            &format!("{scope}.expression_templates.{name}"),
        )?;
        if let Some(Value::Object(decl)) = templates.get_mut(&name) {
            decl.insert("body".to_string(), inlined);
        }
    }
    Ok(())
}

fn substitute(body: &Value, bindings: &Map<String, Value>) -> Value {
    match body {
        Value::String(s) => {
            if let Some(v) = bindings.get(s) {
                v.clone()
            } else {
                body.clone()
            }
        }
        Value::Array(arr) => Value::Array(arr.iter().map(|c| substitute(c, bindings)).collect()),
        Value::Object(obj) => {
            let mut out = Map::new();
            for (k, v) in obj {
                out.insert(k.clone(), substitute(v, bindings));
            }
            Value::Object(out)
        }
        _ => body.clone(),
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
struct MatchRule {
    /// Template id (for diagnostics).
    name: String,
    /// Metavariable names (wildcards in `pattern`, slots in `body`).
    params: Vec<String>,
    /// The pattern Expression a node is matched against.
    pattern: Value,
    /// The replacement Expression instantiated with the bound metavariables.
    body: Value,
    /// Selection precedence (esm-spec §9.6.3): higher fires first; ties break by
    /// declaration order. Absent ⇒ `0`.
    priority: i64,
}

/// Bundles the per-component rewrite inputs threaded through each pass.
struct RewriteCtx<'a> {
    /// All templates declared in the component (named-expansion lookup table).
    templates: &'a Map<String, Value>,
    /// Auto-applied `match` rules, **pre-sorted** highest-`priority`-first with
    /// ties broken by declaration order (esm-spec §9.6.3). `rewrite_pass` fires
    /// the first rule in this order whose pattern matches a node.
    rules: &'a [MatchRule],
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

/// Collect the auto-applied `match` rules from a component's templates in
/// declaration order (serde_json's `preserve_order` feature keeps source
/// order), then pre-sort them by descending `priority` with ties broken by
/// declaration order (a stable sort preserves push order for equal
/// priorities). The old static self-reintroduction / nontermination pre-check
/// is GONE — the bounded fixpoint (`MAX_REWRITE_PASSES`) is now the sole
/// termination guard (esm-spec §9.6.3), so a self-reintroducing rule simply
/// fails to converge rather than being detected up front.
fn collect_match_rules(templates: &Map<String, Value>) -> Vec<MatchRule> {
    let mut rules = Vec::new();
    for (name, decl) in templates {
        let Some(obj) = decl.as_object() else { continue };
        let Some(pattern) = obj.get("match") else {
            continue;
        };
        let params: Vec<String> = obj
            .get("params")
            .and_then(|p| p.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| v.as_str().map(String::from))
                    .collect()
            })
            .unwrap_or_default();
        let body = obj.get("body").cloned().unwrap_or(Value::Null);
        rules.push(MatchRule {
            name: name.clone(),
            params,
            pattern: pattern.clone(),
            body,
            priority: rule_priority(obj),
        });
    }
    // Deterministic selection order (esm-spec §9.6.3): highest `priority` first,
    // ties broken by declaration order. `sort_by_key` is stable, so equal
    // priorities retain their push (declaration) order.
    rules.sort_by_key(|r| std::cmp::Reverse(r.priority));
    rules
}

/// Structurally match `pattern` against `target`, binding metavariables (names
/// in `params`) into `binds`. A metavariable in an operand/`args` position
/// binds the matched sub-AST; in a scalar field it binds the matched literal.
/// A metavariable appearing twice must bind consistently. Pattern object keys
/// are matched as a subset: `target` MAY carry extra keys.
fn try_match(
    pattern: &Value,
    target: &Value,
    params: &std::collections::HashSet<&str>,
    binds: &mut Map<String, Value>,
) -> bool {
    match pattern {
        Value::String(s) => {
            if params.contains(s.as_str()) {
                match binds.get(s) {
                    Some(prev) => prev == target,
                    None => {
                        binds.insert(s.clone(), target.clone());
                        true
                    }
                }
            } else {
                pattern == target
            }
        }
        Value::Array(parr) => match target {
            Value::Array(tarr) if parr.len() == tarr.len() => parr
                .iter()
                .zip(tarr.iter())
                .all(|(p, t)| try_match(p, t, params, binds)),
            _ => false,
        },
        Value::Object(pobj) => match target {
            Value::Object(tobj) => pobj.iter().all(|(k, pv)| match tobj.get(k) {
                Some(tv) => try_match(pv, tv, params, binds),
                None => false,
            }),
            _ => false,
        },
        // numbers / bools / null: exact equality.
        _ => pattern == target,
    }
}

fn expand_apply(
    node: &Map<String, Value>,
    templates: &Map<String, Value>,
    scope: &str,
) -> Result<Value, ExpressionTemplateError> {
    let name = node.get("name").and_then(|v| v.as_str()).ok_or_else(|| {
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
    let decl = templates.get(name).ok_or_else(|| {
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
    let bindings = node
        .get("bindings")
        .and_then(|v| v.as_object())
        .ok_or_else(|| {
            err(
                "apply_expression_template_bindings_mismatch",
                format!("{scope}: apply_expression_template '{name}' missing 'bindings' object"),
            )
        })?;

    let params: Vec<&str> = decl_obj
        .get("params")
        .and_then(|p| p.as_array())
        .map(|arr| arr.iter().filter_map(|v| v.as_str()).collect())
        .unwrap_or_default();
    let declared: std::collections::HashSet<&str> = params.iter().copied().collect();
    let provided: std::collections::HashSet<&str> = bindings.keys().map(String::as_str).collect();
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
    for p in &provided {
        if !declared.contains(p) {
            return Err(err(
                "apply_expression_template_bindings_mismatch",
                format!("{scope}: apply_expression_template '{name}' supplies unknown param '{p}'"),
            ));
        }
    }

    // Splice the bindings' sub-ASTs into the body AS-IS (esm-spec §9.6.3): the
    // substituted body is re-scanned in a SUBSEQUENT pass, so any
    // `apply_expression_template` op or `match`-eligible sub-AST inside a
    // binding is rewritten then — not here. A body itself may not contain
    // `apply_expression_template` (rejected by `validate_templates`).
    let mut resolved = Map::new();
    for (k, v) in bindings {
        resolved.insert(k.clone(), v.clone());
    }
    let body = decl_obj.get("body").cloned().unwrap_or(Value::Null);
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
/// records the op of the most recent rewrite, for the non-convergence
/// diagnostic.
fn rewrite_pass(
    node: &Value,
    ctx: &RewriteCtx,
    scope: &str,
    last: &mut String,
) -> Result<(Value, bool), ExpressionTemplateError> {
    match node {
        Value::Array(arr) => {
            let mut changed = false;
            let mut out = Vec::with_capacity(arr.len());
            for c in arr {
                let (nc, ch) = rewrite_pass(c, ctx, scope, last)?;
                out.push(nc);
                changed |= ch;
            }
            Ok((Value::Array(out), changed))
        }
        Value::Object(obj) => {
            let op = obj.get("op").and_then(|v| v.as_str());
            // (1) Outermost-first: fire a rule AT this node before descending.
            if op == Some(APPLY_OP) {
                *last = APPLY_OP.to_string();
                return Ok((expand_apply(obj, ctx.templates, scope)?, true));
            }
            for rule in ctx.rules {
                let param_set: std::collections::HashSet<&str> =
                    rule.params.iter().map(String::as_str).collect();
                let mut binds = Map::new();
                if try_match(&rule.pattern, node, &param_set, &mut binds) {
                    let _ = &rule.name; // retained for diagnostics / future tracing
                    *last = op.unwrap_or("").to_string();
                    return Ok((substitute(&rule.body, &binds), true));
                }
            }
            // (2) No rule fired here — descend into children.
            let mut changed = false;
            let mut out = Map::new();
            for (k, v) in obj {
                let (nv, ch) = rewrite_pass(v, ctx, scope, last)?;
                out.insert(k.clone(), nv);
                changed |= ch;
            }
            Ok((Value::Object(out), changed))
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
    node: &Value,
    ctx: &RewriteCtx,
    scope: &str,
) -> Result<Value, ExpressionTemplateError> {
    let mut current = node.clone();
    let mut last = String::new();
    for _ in 0..MAX_REWRITE_PASSES {
        let (next, changed) = rewrite_pass(&current, ctx, scope, &mut last)?;
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
    let parts: Vec<&str> = esm.split('.').collect();
    if parts.len() != 3 {
        return Ok(());
    }
    let major: u32 = match parts[0].parse() {
        Ok(v) => v,
        Err(_) => return Ok(()),
    };
    let minor: u32 = match parts[1].parse() {
        Ok(v) => v,
        Err(_) => return Ok(()),
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

    for compkind in ["models", "reaction_systems"] {
        let Some(Value::Object(comps)) = root.get_mut(compkind) else {
            continue;
        };
        for (cname, comp_value) in comps.iter_mut() {
            let Value::Object(comp) = comp_value else {
                continue;
            };
            let scope_base = format!("{compkind}.{cname}");
            // Take the templates block (if any) so we can borrow comp mutably.
            let mut templates: Map<String, Value> = match comp.remove("expression_templates") {
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
            // fixpoint sees is a closed AST.
            compose_template_bodies(&mut templates, &scope_base)?;
            let rules = collect_match_rules(&templates);
            let ctx = RewriteCtx {
                templates: &templates,
                rules: &rules,
            };
            // Outermost-first, priority-ordered, bounded-fixpoint rewrite per
            // non-template field (esm-spec §9.6.3): expands
            // `apply_expression_template` ops AND fires auto `match` rules until
            // a pass performs zero rewrites (or the pass bound rejects).
            let keys: Vec<String> = comp.keys().cloned().collect();
            for k in keys {
                let scope = format!("{scope_base}.{k}");
                if let Some(child) = comp.get(&k).cloned() {
                    let rewritten = rewrite_to_fixpoint(&child, &ctx, &scope)?;
                    comp.insert(k, rewritten);
                }
            }
        }
    }

    let mut leftover: Vec<String> = Vec::new();
    find_apply_paths(value, "", &mut leftover);
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
    Ok(())
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
}
