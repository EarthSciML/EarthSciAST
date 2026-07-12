//! Coupling-library files and `coupling_import` role binding (esm-spec
//! §10.9–§10.11; RFC docs/content/rfcs/coupling-libraries-role-binding.md).
//!
//! A *coupling-library file* is a document whose payload is a top-level
//! `coupling_roles` map plus a role-scoped `coupling` array. An assembly reuses
//! it with a `{ type: "coupling_import", ref, bind }` coupling entry: at flatten
//! the import expands into concrete `variable_map` / `couple` /
//! `operator_compose` / `event` edges by substituting the bound actual component
//! for every role-named top-level segment (the §10.10.2 occurrence surface).
//!
//! Expansion runs *inside* flatten (esm-spec §10.10.3), after subsystem mounting
//! (which happens at load) and before the coupling-rule step, so every `bind`
//! target resolves against fully-mounted components. The `coupling_import` source
//! entry is preserved for round-trip; only the flattened system carries the
//! expanded edges.
//!
//! This is a faithful port of the TypeScript reference `coupling-imports.ts`.
//! Diagnostics are raised as [`crate::diagnostic::DiagnosticError`] with the
//! stable §10.11 codes so they are machine-checkable across bindings.

use crate::diagnostic::{DiagnosticError, err};
use crate::types::{CouplingEntry, EsmFile};
use serde_json::Value;
use std::collections::HashSet;

/// Payload keys a coupling-library file MUST NOT declare (esm-spec §10.9).
const LIBRARY_FORBIDDEN_KEYS: [&str; 7] = [
    "models",
    "reaction_systems",
    "data_loaders",
    "domain",
    "index_sets",
    "metaparameters",
    "expression_templates",
];

/// Coupling-entry types a library edge MAY carry (esm-spec §10.9).
const ROLE_BEARING_TYPES: [&str; 4] = ["variable_map", "couple", "operator_compose", "event"];

/// A synchronous `ref` -> parsed-document resolver (mirrors the §9.7 template
/// resolver). Given `(ref, base_path)` returns the parsed library document or a
/// `coupling_import_unresolved` diagnostic.
pub type LoadRefFn<'a> = dyn Fn(&str, &str) -> Result<Value, DiagnosticError> + 'a;

/// Options controlling how `coupling_import` refs are resolved at flatten.
pub struct CouplingImportOptions<'a> {
    /// Directory the import `ref`s resolve against. Defaults to `"."`.
    pub base_path: String,
    /// Resolve a `ref` string to a parsed coupling-library document. Defaults to
    /// a synchronous filesystem reader. Tests may supply an in-memory resolver.
    pub load_ref: Option<Box<LoadRefFn<'a>>>,
}

impl Default for CouplingImportOptions<'_> {
    fn default() -> Self {
        Self {
            base_path: ".".to_string(),
            load_ref: None,
        }
    }
}

fn is_object(v: &Value) -> bool {
    v.is_object()
}

/// True when `raw` has the coupling-library-file FORM (top-level
/// `coupling_roles`, esm-spec §10.9). Presence of that key is the sole positive
/// identifier of the file kind; purity is checked separately at the import edge.
pub fn is_coupling_library_doc(raw: &Value) -> bool {
    raw.as_object()
        .is_some_and(|o| o.contains_key("coupling_roles"))
}

/// True when `file` carries at least one `coupling_import` entry in its
/// `coupling` array.
pub fn has_coupling_import(file: &EsmFile) -> bool {
    file.coupling
        .as_ref()
        .is_some_and(|c| c.iter().any(|e| matches!(e, CouplingEntry::CouplingImport { .. })))
}

// ---------------------------------------------------------------------------
// Reference rewriting — the §10.10.2 occurrence surface
// ---------------------------------------------------------------------------

fn head_segment(r: &str) -> &str {
    match r.find('.') {
        Some(i) => &r[..i],
        None => r,
    }
}

/// Replace the top-level segment of a scoped reference with its bound actual.
/// `"Fuel.w_0"` under `{ Fuel: "FuelModelLookup" }` -> `"FuelModelLookup.w_0"`;
/// a dotted bind value (`{ Fuel: "Parent.Child" }`) -> `"Parent.Child.w_0"`.
/// A segment not in `bind` is returned unchanged (bare `"t"`, literals).
fn rewrite_scoped_ref(r: &str, bind: &std::collections::HashMap<String, String>) -> String {
    match r.find('.') {
        Some(i) => {
            let head = &r[..i];
            let tail = &r[i..];
            match bind.get(head) {
                Some(actual) => format!("{actual}{tail}"),
                None => r.to_string(),
            }
        }
        None => match bind.get(r) {
            Some(actual) => actual.clone(),
            None => r.to_string(),
        },
    }
}

/// Rewrite/visit every scoped reference inside an Expression tree.
fn rewrite_expr(expr: &mut Value, f: &dyn Fn(&str) -> String) {
    match expr {
        // Numeric literals / bools / null: copied unchanged.
        Value::String(s) => {
            *s = f(s);
        }
        Value::Object(node) => {
            if let Some(Value::Array(args)) = node.get_mut("args") {
                for a in args.iter_mut() {
                    rewrite_expr(a, f);
                }
            }
            // `apply_expression_template` bindings VALUES are free-variable
            // targets (esm-spec §10.10.2) — Expressions in their own right.
            if node.get("op").and_then(|o| o.as_str()) == Some("apply_expression_template")
                && let Some(Value::Object(b)) = node.get_mut("bindings")
            {
                for (_, bv) in b.iter_mut() {
                    rewrite_expr(bv, f);
                }
            }
        }
        _ => {}
    }
}

/// Apply `struct_fn` to every structural system/scoped reference of a coupling
/// entry and `expr_fn` to every scoped reference inside its Expression fields
/// (esm-spec §10.10.2). Mutates `entry` in place (callers pass a clone).
fn rewrite_entry_in_place(
    entry: &mut Value,
    struct_fn: &dyn Fn(&str) -> String,
    expr_fn: &dyn Fn(&str) -> String,
) {
    let ty = entry
        .get("type")
        .and_then(|t| t.as_str())
        .map(str::to_string);
    match ty.as_deref() {
        Some("variable_map") => {
            rewrite_string_field(entry, "from", struct_fn);
            rewrite_string_field(entry, "to", struct_fn);
            if let Some(t) = entry.get_mut("transform")
                && t.is_object()
            {
                rewrite_expr(t, expr_fn);
            }
        }
        Some("couple") => {
            rewrite_string_array(entry, "systems", struct_fn);
            if let Some(conn) = entry.get_mut("connector")
                && let Some(Value::Array(eqs)) = conn.get_mut("equations")
            {
                for eq in eqs.iter_mut() {
                    if !eq.is_object() {
                        continue;
                    }
                    rewrite_string_field(eq, "from", struct_fn);
                    rewrite_string_field(eq, "to", struct_fn);
                    if let Some(e) = eq.get_mut("expression") {
                        rewrite_expr(e, expr_fn);
                    }
                }
            }
        }
        Some("operator_compose") => {
            rewrite_string_array(entry, "systems", struct_fn);
            let translate = entry.get("translate").cloned();
            if let Some(Value::Object(tr)) = translate {
                let mut next = serde_json::Map::new();
                for (k, v) in tr {
                    let nk = struct_fn(&k);
                    let nv = match v {
                        Value::String(s) => Value::String(struct_fn(&s)),
                        Value::Object(mut o) => {
                            if let Some(Value::String(var)) = o.get_mut("var") {
                                *var = struct_fn(var);
                            }
                            Value::Object(o)
                        }
                        other => other,
                    };
                    next.insert(nk, nv);
                }
                if let Some(obj) = entry.as_object_mut() {
                    obj.insert("translate".to_string(), Value::Object(next));
                }
            }
        }
        Some("event") => {
            if let Some(Value::Array(conds)) = entry.get_mut("conditions") {
                for c in conds.iter_mut() {
                    rewrite_expr(c, expr_fn);
                }
            }
            for key in ["affects", "affect_neg"] {
                if let Some(Value::Array(affects)) = entry.get_mut(key) {
                    for a in affects.iter_mut() {
                        if !a.is_object() {
                            continue;
                        }
                        rewrite_string_field(a, "lhs", struct_fn);
                        if let Some(rhs) = a.get_mut("rhs") {
                            rewrite_expr(rhs, expr_fn);
                        }
                    }
                }
            }
            if let Some(trigger) = entry.get_mut("trigger")
                && trigger.get("type").and_then(|t| t.as_str()) == Some("condition")
                && let Some(e) = trigger.get_mut("expression")
            {
                rewrite_expr(e, expr_fn);
            }
            if let Some(fa) = entry.get_mut("functional_affect")
                && fa.is_object()
            {
                for key in ["read_vars", "read_params", "modified_params"] {
                    rewrite_string_array(fa, key, struct_fn);
                }
            }
            rewrite_string_array(entry, "discrete_parameters", struct_fn);
        }
        _ => {}
    }
}

/// Rewrite a single string field of `obj` in place, if present and a string.
fn rewrite_string_field(obj: &mut Value, key: &str, f: &dyn Fn(&str) -> String) {
    if let Some(Value::String(s)) = obj.get_mut(key) {
        *s = f(s);
    }
}

/// Rewrite every string element of `obj[key]` (an array) in place.
fn rewrite_string_array(obj: &mut Value, key: &str, f: &dyn Fn(&str) -> String) {
    if let Some(Value::Array(arr)) = obj.get_mut(key) {
        for el in arr.iter_mut() {
            if let Value::String(s) = el {
                *s = f(s);
            }
        }
    }
}

/// Collect the top-level role segments a library edge references. Structural
/// ref fields (systems[], from/to, translate keys, event var lists) always name
/// a role; Expression strings name a role only when they are scoped references
/// (contain a dot) — bare Expression operands like `"t"` are incidental.
fn collect_role_segments(edge: &Value) -> HashSet<String> {
    use std::cell::RefCell;
    let seen: RefCell<HashSet<String>> = RefCell::new(HashSet::new());
    let mut clone = edge.clone();
    let struct_fn = |r: &str| -> String {
        seen.borrow_mut().insert(head_segment(r).to_string());
        r.to_string()
    };
    let expr_fn = |r: &str| -> String {
        if r.contains('.') {
            seen.borrow_mut().insert(head_segment(r).to_string());
        }
        r.to_string()
    };
    rewrite_entry_in_place(&mut clone, &struct_fn, &expr_fn);
    seen.into_inner()
}

// ---------------------------------------------------------------------------
// Ref loading (synchronous, mirrors the §9.7 template resolver)
// ---------------------------------------------------------------------------

fn default_load_ref(ref_str: &str, base_path: &str) -> Result<Value, DiagnosticError> {
    if ref_str.starts_with("http://") || ref_str.starts_with("https://") {
        return Err(err(
            "coupling_import_unresolved",
            format!(
                "remote coupling_import ref '{ref_str}' cannot be loaded synchronously; \
                 download the file and import it by local path"
            ),
        ));
    }
    let path = std::path::Path::new(base_path).join(ref_str);
    let content = std::fs::read_to_string(&path).map_err(|e| {
        err(
            "coupling_import_unresolved",
            format!(
                "coupling-library file not found or unreadable: {} (from ref '{ref_str}'): {e}",
                path.display()
            ),
        )
    })?;
    serde_json::from_str(&content).map_err(|e| {
        err(
            "coupling_import_unresolved",
            format!(
                "coupling-library ref '{}' is not valid JSON: {e}",
                path.display()
            ),
        )
    })
}

// ---------------------------------------------------------------------------
// Library validation + expansion
// ---------------------------------------------------------------------------

/// Validate a resolved coupling-library document and expand one
/// `coupling_import` entry into its concrete edges, bound to `bind`. Raises the
/// esm-spec §10.11 diagnostics.
fn expand_one(
    lib: &Value,
    ref_str: &str,
    bind: &std::collections::HashMap<String, String>,
    file: &EsmFile,
) -> Result<Vec<CouplingEntry>, DiagnosticError> {
    if !is_coupling_library_doc(lib) {
        return Err(err(
            "coupling_import_not_library",
            format!(
                "coupling_import ref '{ref_str}' lacks top-level `coupling_roles` — not a \
                 coupling-library file (esm-spec §10.9)"
            ),
        ));
    }
    let doc = lib.as_object().unwrap();

    // Purity (esm-spec §10.9).
    for k in LIBRARY_FORBIDDEN_KEYS {
        if doc.contains_key(k) {
            return Err(err(
                "coupling_library_illegal_payload",
                format!(
                    "coupling-library '{ref_str}' declares `{k}` — a coupling library is nothing \
                     but roles + wiring (esm-spec §10.9)"
                ),
            ));
        }
    }

    let roles: Vec<String> = doc
        .get("coupling_roles")
        .and_then(|v| v.as_object())
        .map(|o| o.keys().cloned().collect())
        .unwrap_or_default();
    if roles.is_empty() {
        return Err(err(
            "coupling_library_illegal_payload",
            format!(
                "coupling-library '{ref_str}' declares no roles (esm-spec §10.9: `coupling_roles` \
                 is required, non-empty)"
            ),
        ));
    }
    let edges: Vec<Value> = doc
        .get("coupling")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    if edges.is_empty() {
        return Err(err(
            "coupling_library_illegal_payload",
            format!(
                "coupling-library '{ref_str}' has an empty `coupling` array (esm-spec §10.9: \
                 required, non-empty)"
            ),
        ));
    }

    // Edge-type + role-scope checks over the declared roles.
    let role_set: HashSet<&str> = roles.iter().map(String::as_str).collect();
    let mut used_roles: HashSet<String> = HashSet::new();
    for edge in &edges {
        if !is_object(edge) {
            continue;
        }
        let ty = edge.get("type").and_then(|t| t.as_str());
        if ty == Some("coupling_import") {
            return Err(err(
                "coupling_library_nested_import",
                format!(
                    "coupling-library '{ref_str}' contains a nested coupling_import (v1 forbids \
                     layering, esm-spec §10.9)"
                ),
            ));
        }
        if ty == Some("callback") || edge.get("expression_template_imports").is_some() {
            return Err(err(
                "coupling_library_illegal_payload",
                format!(
                    "coupling-library '{ref_str}' edge of type '{}' is not role-substitutable (no \
                     callback entries or edge-level expression_template_imports, esm-spec §10.9)",
                    ty.unwrap_or("<none>")
                ),
            ));
        }
        if !ty.is_some_and(|t| ROLE_BEARING_TYPES.contains(&t)) {
            return Err(err(
                "coupling_library_illegal_payload",
                format!(
                    "coupling-library '{ref_str}' contains an unsupported edge type '{}' \
                     (esm-spec §10.9)",
                    ty.unwrap_or("<none>")
                ),
            ));
        }
        for seg in collect_role_segments(edge) {
            if !role_set.contains(seg.as_str()) {
                return Err(err(
                    "coupling_edge_unknown_role",
                    format!(
                        "coupling-library '{ref_str}': edge references '{seg}', which is not a \
                         declared role (esm-spec §10.9)"
                    ),
                ));
            }
            used_roles.insert(seg);
        }
    }
    for role in &roles {
        if !used_roles.contains(role) {
            return Err(err(
                "coupling_role_unused",
                format!(
                    "coupling-library '{ref_str}': role '{role}' is declared but referenced by no \
                     edge (esm-spec §10.9)"
                ),
            ));
        }
    }

    // Binding — total and checked (esm-spec §10.10.1).
    for key in bind.keys() {
        if !role_set.contains(key.as_str()) {
            return Err(err(
                "coupling_import_unknown_role",
                format!(
                    "coupling_import ref '{ref_str}': bind key '{key}' is not a declared role \
                     (esm-spec §10.10.1)"
                ),
            ));
        }
    }
    for role in &roles {
        match bind.get(role) {
            None => {
                return Err(err(
                    "coupling_import_role_unbound",
                    format!(
                        "coupling_import ref '{ref_str}': role '{role}' has no bind entry \
                         (binding is total, esm-spec §10.10.1)"
                    ),
                ));
            }
            Some(actual) => {
                if !resolves_to_component(file, actual) {
                    return Err(err(
                        "coupling_import_bind_not_a_component",
                        format!(
                            "coupling_import ref '{ref_str}': bind '{role}' -> '{actual}' does not \
                             resolve to a component (esm-spec §10.10.1)"
                        ),
                    ));
                }
            }
        }
    }

    // Expand: substitute bound actuals for role names, one simultaneous rewrite.
    let rw = |r: &str| -> String { rewrite_scoped_ref(r, bind) };
    let mut expanded: Vec<CouplingEntry> = Vec::with_capacity(edges.len());
    for edge in &edges {
        let mut clone = edge.clone();
        rewrite_entry_in_place(&mut clone, &rw, &rw);
        let entry: CouplingEntry = serde_json::from_value(clone).map_err(|e| {
            err(
                "coupling_import_unresolved",
                format!(
                    "coupling-library '{ref_str}': expanded edge is not a valid coupling entry: {e}"
                ),
            )
        })?;
        expanded.push(entry);
    }
    Ok(expanded)
}

/// Resolve a `bind` value as a component path (esm-spec §10.10.1) — a system or
/// loader node, walking `models`/`reaction_systems`/`data_loaders` then nested
/// `subsystems`, never terminating on a variable.
fn resolves_to_component(file: &EsmFile, value: &str) -> bool {
    let segs: Vec<&str> = value.split('.').collect();
    let top = segs[0];
    let top_node: Option<Value> = file
        .models
        .as_ref()
        .and_then(|m| m.get(top))
        .and_then(|v| serde_json::to_value(v).ok())
        .or_else(|| {
            file.reaction_systems
                .as_ref()
                .and_then(|m| m.get(top))
                .and_then(|v| serde_json::to_value(v).ok())
        })
        .or_else(|| {
            file.data_loaders
                .as_ref()
                .and_then(|m| m.get(top))
                .and_then(|v| serde_json::to_value(v).ok())
        });
    let mut node = match top_node {
        Some(n) if n.is_object() => n,
        _ => return false,
    };
    for seg in &segs[1..] {
        let child = node
            .get("subsystems")
            .filter(|s| s.is_object())
            .and_then(|subs| subs.get(*seg))
            .filter(|c| c.is_object())
            .cloned();
        match child {
            Some(c) => node = c,
            None => return false,
        }
    }
    true
}

/// Expand every `coupling_import` entry in `file.coupling` into concrete edges,
/// splicing them in the position of the import entry (esm-spec §10.10.3).
/// Returns the effective coupling array, or `None` if the file has no `coupling`
/// block. Non-import entries pass through untouched; a file with no
/// `coupling_import` entries returns a clone of `file.coupling` verbatim.
pub fn expand_coupling_imports(
    file: &EsmFile,
    options: &CouplingImportOptions,
) -> Result<Option<Vec<CouplingEntry>>, DiagnosticError> {
    let Some(coupling) = file.coupling.as_ref() else {
        return Ok(None);
    };
    if !has_coupling_import(file) {
        return Ok(Some(coupling.clone()));
    }
    let mut out: Vec<CouplingEntry> = Vec::new();
    for entry in coupling {
        let CouplingEntry::CouplingImport {
            reference, bind, ..
        } = entry
        else {
            out.push(entry.clone());
            continue;
        };
        let bind = bind.clone().unwrap_or_default();
        let lib = match &options.load_ref {
            Some(f) => f(reference, &options.base_path)?,
            None => default_load_ref(reference, &options.base_path)?,
        };
        for expanded_edge in expand_one(&lib, reference, &bind, file)? {
            out.push(expanded_edge);
        }
    }
    Ok(Some(out))
}
