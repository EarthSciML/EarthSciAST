//! Load-time resolution for esm-spec §9.7: template-library files, cross-file
//! `expression_template_imports`, and load-time `metaparameters`
//! (docs/content/rfcs/template-library-imports.md; esm-libraries-spec §2.1c).
//!
//! Everything here resolves BEFORE the §9.6.3 rewrite fixpoint
//! (`lower_expression_templates`) and before any validator sees the tree.
//! Per document the order is innermost-first (esm-spec §9.7.6):
//!
//! 1. resolve imports (recursively, depth-first post-order, instantiating the
//!    imported subtree with the edge's metaparameter `bindings` at each edge);
//! 2. merge imported `index_sets` into the document registry;
//! 3. close and fold this document's metaparameters (loader-API bindings,
//!    then defaults; `metaparameter_unbound` if still open);
//! 4. §9.7.3 registration-time body composition (`compose_template_bodies`,
//!    invoked per component from `lower_expression_templates`);
//! 5. the §9.6.3 fixpoint on fully-concrete trees.
//!
//! Round-trip is Option A: `expression_template_imports`, `metaparameters`,
//! and top-level `expression_templates` do not survive `parse → emit`; the
//! emitted form is the expanded, folded document.
//!
//! All diagnostics are raised as [`ExpressionTemplateError`] with the stable
//! §9.6.6 codes so they are machine-checkable across bindings. Mirrors the
//! Julia reference implementation
//! (`EarthSciSerialization.jl/src/template_imports.jl`).
//!
//! Remote (`http(s)://`) template-library refs are not fetched (this crate
//! carries no HTTP client, matching the subsystem-ref loader): they are
//! rejected as `template_import_unresolved`.

use crate::lower_expression_templates::{
    ExpressionTemplateError, compose_template_bodies, reject_expression_templates_pre_v04,
    validate_templates,
};
use serde_json::{Map, Value};
use std::collections::BTreeMap;
use std::path::{Component, Path, PathBuf};

const COMPONENT_KINDS: [&str; 2] = ["models", "reaction_systems"];

/// A template-library file MUST NOT declare any of these (esm-spec §9.7.1).
const LIBRARY_FORBIDDEN_KEYS: [&str; 5] =
    ["models", "reaction_systems", "data_loaders", "coupling", "domain"];

/// Keys whose VALUES are never expression positions: metaparameter names are
/// substituted as bare variable-reference strings, so structural string
/// fields must not be rewritten. Template `params` shadowing is handled
/// separately in [`substitute_metaparams_decl`].
const META_SUBST_SKIP_KEYS: [&str; 11] = [
    "metadata",
    "params",
    "type",
    "units",
    "kind",
    "description",
    "name",
    "wrt",
    "expression_template_imports",
    "metaparameters",
    "only",
];

fn err(code: &'static str, message: impl Into<String>) -> ExpressionTemplateError {
    ExpressionTemplateError {
        code,
        message: message.into(),
    }
}

// ---------------------------------------------------------------------------
// Spec-version gate (esm-spec §9.6.5)
// ---------------------------------------------------------------------------

/// `expression_template_imports`, top-level `expression_templates`
/// (template-library files), and `metaparameters` arrive at `esm: 0.8.0`;
/// files declaring an earlier version that carry any of them are rejected
/// with `template_import_version_too_old` (esm-spec §9.6.5). Mirrors
/// [`reject_expression_templates_pre_v04`] for the §9.7 constructs.
pub fn reject_template_imports_pre_v08(view: &Value) -> Result<(), ExpressionTemplateError> {
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
    let (Ok(major), Ok(minor)) = (parts[0].parse::<u32>(), parts[1].parse::<u32>()) else {
        return Ok(());
    };
    if !(major == 0 && minor < 8) {
        return Ok(());
    }

    let mut offences: Vec<String> = Vec::new();
    if obj.contains_key("expression_templates") {
        offences.push("/expression_templates".to_string());
    }
    if obj.contains_key("metaparameters") {
        offences.push("/metaparameters".to_string());
    }
    if obj.contains_key("expression_template_imports") {
        offences.push("/expression_template_imports".to_string());
    }
    for compkind in COMPONENT_KINDS {
        if let Some(comps) = obj.get(compkind).and_then(|v| v.as_object()) {
            for (cname, comp) in comps {
                if let Some(comp_obj) = comp.as_object()
                    && comp_obj.contains_key("expression_template_imports")
                {
                    offences.push(format!("/{compkind}/{cname}/expression_template_imports"));
                }
            }
        }
    }
    if offences.is_empty() {
        return Ok(());
    }
    Err(err(
        "template_import_version_too_old",
        format!(
            "expression_template_imports / top-level expression_templates / metaparameters \
             require esm >= 0.8.0; file declares {esm}. Offending paths: {}",
            offences.join(", ")
        ),
    ))
}

/// True when `raw` has the template-library-file FORM (top-level
/// `expression_templates`, esm-spec §9.7.1). Purity (no models / reaction
/// systems / loaders / coupling / domain) is checked separately at import
/// edges.
pub fn is_template_library_doc(raw: &Value) -> bool {
    raw.as_object()
        .is_some_and(|o| o.contains_key("expression_templates"))
}

// ---------------------------------------------------------------------------
// Metaparameters (esm-spec §9.7.6)
// ---------------------------------------------------------------------------

/// Read a JSON INTEGER (serde_json integer-backed number; floats — including
/// integral floats like `2.0` — are not integers, matching the Julia
/// reference).
fn as_int(v: &Value) -> Option<i64> {
    v.as_i64()
}

fn require_int(v: &Value, ctx: &str) -> Result<i64, ExpressionTemplateError> {
    as_int(v).ok_or_else(|| {
        err(
            "metaparameter_type_error",
            format!("{ctx}: value {v} is not an integer (esm-spec §9.7.6)"),
        )
    })
}

fn collect_metaparam_decls(
    raw: &Value,
    origin: &str,
) -> Result<Map<String, Value>, ExpressionTemplateError> {
    let mut out = Map::new();
    let Some(mp) = raw.get("metaparameters") else {
        return Ok(out);
    };
    if mp.is_null() {
        return Ok(out);
    }
    let Some(mp_obj) = mp.as_object() else {
        return Err(err(
            "metaparameter_type_error",
            format!("{origin}: `metaparameters` must be an object"),
        ));
    };
    for (name, v) in mp_obj {
        let Some(decl) = v.as_object() else {
            return Err(err(
                "metaparameter_type_error",
                format!("{origin}: metaparameters.{name} must be an object with `type: \"integer\"`"),
            ));
        };
        if decl.get("type").and_then(|t| t.as_str()) != Some("integer") {
            return Err(err(
                "metaparameter_type_error",
                format!(
                    "{origin}: metaparameters.{name}: `type` must be \"integer\" (the only kind)"
                ),
            ));
        }
        if let Some(d) = decl.get("default")
            && !d.is_null()
        {
            require_int(d, &format!("{origin}: metaparameters.{name} default"))?;
        }
        out.insert(name.clone(), v.clone());
    }
    Ok(out)
}

/// Substitute closed metaparameter names — appearing as bare strings, the
/// variable-reference surface syntax — with their integer values, everywhere
/// except the [`META_SUBST_SKIP_KEYS`] structural fields (esm-spec §9.7.6:
/// expression-position substitution; no folding here).
fn substitute_metaparams(x: &Value, values: &BTreeMap<String, i64>) -> Value {
    match x {
        Value::String(s) => match values.get(s) {
            Some(v) => Value::from(*v),
            None => x.clone(),
        },
        Value::Array(arr) => {
            Value::Array(arr.iter().map(|v| substitute_metaparams(v, values)).collect())
        }
        Value::Object(obj) => {
            let mut out = Map::new();
            for (k, v) in obj {
                if META_SUBST_SKIP_KEYS.contains(&k.as_str()) {
                    out.insert(k.clone(), v.clone());
                } else {
                    out.insert(k.clone(), substitute_metaparams(v, values));
                }
            }
            Value::Object(out)
        }
        _ => x.clone(),
    }
}

/// Metaparameter substitution over one `expression_templates` entry: the
/// template's own `params` shadow like-named metaparameters inside its
/// `body` and `match` (a param is the inner binder; substitution must not
/// capture it).
fn substitute_metaparams_decl(decl: &Value, values: &BTreeMap<String, i64>) -> Value {
    let params: Vec<String> = decl
        .get("params")
        .and_then(|p| p.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|v| v.as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default();
    if params.iter().any(|p| values.contains_key(p)) {
        let mut shadowed = values.clone();
        for p in &params {
            shadowed.remove(p);
        }
        substitute_metaparams(decl, &shadowed)
    } else {
        substitute_metaparams(decl, values)
    }
}

/// Fold a metaparameter expression (integer literal, name, or `{op, args}`
/// over `+ - * /`) to a concrete `i64` with exact checked 64-bit arithmetic
/// (esm-spec §9.7.6). Returns `Ok(None)` when the expression still contains
/// a bare name (an open metaparameter awaiting a later binding site, or a
/// template-param slot inside a rule body) — the site is left symbolic for a
/// later pass. Errors with `metaparameter_type_error` for a non-integer
/// literal, an op outside `+ - * /` over concrete args, inexact division, or
/// 64-bit overflow.
fn try_fold(x: &Value, ctx: &str) -> Result<Option<i64>, ExpressionTemplateError> {
    if let Some(i) = as_int(x) {
        return Ok(Some(i));
    }
    if x.is_string() {
        return Ok(None);
    }
    if x.is_number() {
        return Err(err(
            "metaparameter_type_error",
            format!("{ctx}: non-integer literal {x} in a structural integer site (esm-spec §9.7.6)"),
        ));
    }
    let Some(obj) = x.as_object() else {
        return Err(err(
            "metaparameter_type_error",
            format!("{ctx}: invalid metaparameter expression (expected integer, name, or {{op, args}})"),
        ));
    };
    let (Some(op_raw), Some(args)) = (obj.get("op"), obj.get("args").and_then(|a| a.as_array()))
    else {
        return Err(err(
            "metaparameter_type_error",
            format!("{ctx}: invalid metaparameter expression (expected {{op: +|-|*|/, args: [...]}})"),
        ));
    };
    if args.is_empty() {
        return Err(err(
            "metaparameter_type_error",
            format!("{ctx}: invalid metaparameter expression (expected {{op: +|-|*|/, args: [...]}})"),
        ));
    }
    let mut vals: Vec<i64> = Vec::with_capacity(args.len());
    for a in args {
        match try_fold(a, ctx)? {
            Some(v) => vals.push(v),
            None => return Ok(None),
        }
    }
    let op = op_raw.as_str().unwrap_or_default().to_string();
    if !["+", "-", "*", "/"].contains(&op.as_str()) {
        return Err(err(
            "metaparameter_type_error",
            format!("{ctx}: op '{op}' is not allowed in a metaparameter expression (only + - * /)"),
        ));
    }
    let overflow = || {
        err(
            "metaparameter_type_error",
            format!("{ctx}: 64-bit integer overflow while folding a metaparameter expression"),
        )
    };
    let mut acc = vals[0];
    if op == "-" && vals.len() == 1 {
        return Ok(Some(acc.checked_neg().ok_or_else(overflow)?));
    }
    for v in &vals[1..] {
        acc = match op.as_str() {
            "+" => acc.checked_add(*v).ok_or_else(overflow)?,
            "-" => acc.checked_sub(*v).ok_or_else(overflow)?,
            "*" => acc.checked_mul(*v).ok_or_else(overflow)?,
            _ => {
                if *v == 0 {
                    return Err(err(
                        "metaparameter_type_error",
                        format!("{ctx}: division by zero"),
                    ));
                }
                if acc % *v != 0 {
                    return Err(err(
                        "metaparameter_type_error",
                        format!("{ctx}: {acc} / {v} does not divide exactly (esm-spec §9.7.6)"),
                    ));
                }
                acc.checked_div(*v).ok_or_else(overflow)?
            }
        };
    }
    Ok(Some(acc))
}

fn collect_names(x: &Value, out: &mut Vec<String>) {
    match x {
        Value::String(s) => out.push(s.clone()),
        Value::Array(arr) => {
            for v in arr {
                collect_names(v, out);
            }
        }
        Value::Object(obj) => {
            for (k, v) in obj {
                if k == "op" {
                    continue;
                }
                collect_names(v, out);
            }
        }
        _ => {}
    }
}

/// Fold metaparameter expressions in the structural integer sites —
/// `aggregate` dense `ranges` tuple entries and `makearray` `regions` bound
/// pairs — to concrete integers, in place, wherever they are already closed.
/// Entries still carrying a bare name (a template-param slot, or an open
/// metaparameter in a not-yet-fully-bound library) are left symbolic for a
/// later binding site. Index-set sizes are folded separately by
/// [`fold_index_set_sizes`].
fn fold_structural_sites(x: &mut Value, ctx: &str) -> Result<(), ExpressionTemplateError> {
    match x {
        Value::Array(arr) => {
            for v in arr {
                fold_structural_sites(v, ctx)?;
            }
            Ok(())
        }
        Value::Object(obj) => {
            let op = obj
                .get("op")
                .and_then(|v| v.as_str())
                .unwrap_or_default()
                .to_string();
            if op == "aggregate" {
                if let Some(Value::Object(ranges)) = obj.get_mut("ranges") {
                    let keys: Vec<String> = ranges.keys().cloned().collect();
                    for k in keys {
                        if let Some(Value::Array(rv)) = ranges.get_mut(&k) {
                            // {from: ...} index-set refs are untouched.
                            for entry in rv.iter_mut() {
                                if as_int(entry).is_some() {
                                    continue;
                                }
                                if let Some(f) =
                                    try_fold(entry, &format!("{ctx}: aggregate ranges.{k}"))?
                                {
                                    *entry = Value::from(f);
                                }
                            }
                        }
                    }
                }
            } else if op == "makearray"
                && let Some(Value::Array(regions)) = obj.get_mut("regions")
            {
                for region in regions.iter_mut() {
                    let Value::Array(region_arr) = region else {
                        continue;
                    };
                    for bounds in region_arr.iter_mut() {
                        let Value::Array(bounds_arr) = bounds else {
                            continue;
                        };
                        for entry in bounds_arr.iter_mut() {
                            if as_int(entry).is_some() {
                                continue;
                            }
                            if let Some(f) = try_fold(entry, &format!("{ctx}: makearray regions bound"))?
                            {
                                *entry = Value::from(f);
                            }
                        }
                    }
                }
            }
            for (_, v) in obj.iter_mut() {
                fold_structural_sites(v, ctx)?;
            }
            Ok(())
        }
        _ => Ok(()),
    }
}

/// Fold interval `size` metaparameter expressions in an `index_sets`
/// registry. With `strict = true` (the root document, after its
/// metaparameters closed) any remaining bare name is `metaparameter_unbound`;
/// with `strict = false` (a library instantiated at an edge that left some
/// metaparameters open) open sizes stay symbolic and close at a later
/// binding site.
fn fold_index_set_sizes(
    index_sets: &mut Map<String, Value>,
    ctx: &str,
    strict: bool,
) -> Result<(), ExpressionTemplateError> {
    for (name, decl) in index_sets.iter_mut() {
        let Some(decl_obj) = decl.as_object_mut() else {
            continue;
        };
        let Some(sz) = decl_obj.get("size") else {
            continue;
        };
        if as_int(sz).is_some() {
            continue;
        }
        match try_fold(sz, &format!("{ctx}: index_sets.{name}.size"))? {
            Some(f) => {
                decl_obj.insert("size".to_string(), Value::from(f));
            }
            None => {
                if strict {
                    let mut names = Vec::new();
                    collect_names(sz, &mut names);
                    names.dedup();
                    return Err(err(
                        "metaparameter_unbound",
                        format!(
                            "{ctx}: index_sets.{name}.size references unbound name(s) {} \
                             (esm-spec §9.7.6)",
                            names.join(", ")
                        ),
                    ));
                }
            }
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Import-graph resolution (esm-spec §9.7.2 / §9.7.4 / §9.7.5)
// ---------------------------------------------------------------------------

/// Everything one template-library file exports after resolution in its OWN
/// scope: its effective template sequence (imports depth-first post-order,
/// then own declarations; esm-spec §9.7.4), its instantiated `index_sets`,
/// and its still-open metaparameter declarations (re-exported to the
/// importer, esm-spec §9.7.6 binding site 2). `serde_json`'s
/// `preserve_order` `Map` keeps the effective order.
#[derive(Default)]
struct TemplateScope {
    templates: Map<String, Value>,
    index_sets: Map<String, Value>,
    metaparams: Map<String, Value>,
}

fn merge_named(
    dst: &mut Map<String, Value>,
    name: &str,
    decl: Value,
    code: &'static str,
    what: &str,
    origin: &str,
) -> Result<(), ExpressionTemplateError> {
    if let Some(existing) = dst.get(name) {
        // Deep-equal redeclaration (a diamond import) dedups at first
        // occurrence; a non-equal collision is a conflict (esm-spec
        // §9.7.4/§9.7.5).
        if *existing == decl {
            return Ok(());
        }
        return Err(err(
            code,
            format!(
                "{origin}: {what} '{name}' collides with a non-deep-equal existing definition \
                 (esm-spec §9.7.4/§9.7.5)"
            ),
        ));
    }
    dst.insert(name.to_string(), decl);
    Ok(())
}

fn merge_scope(
    dst: &mut TemplateScope,
    src: TemplateScope,
    origin: &str,
) -> Result<(), ExpressionTemplateError> {
    for (n, d) in src.templates {
        merge_named(
            &mut dst.templates,
            &n,
            d,
            "template_import_name_conflict",
            "template",
            origin,
        )?;
    }
    for (n, d) in src.index_sets {
        merge_named(
            &mut dst.index_sets,
            &n,
            d,
            "template_import_index_set_conflict",
            "index set",
            origin,
        )?;
    }
    for (n, d) in src.metaparams {
        merge_named(
            &mut dst.metaparams,
            &n,
            d,
            "template_import_name_conflict",
            "metaparameter",
            origin,
        )?;
    }
    Ok(())
}

/// Per-edge metaparameter instantiation (esm-spec §9.7.6 binding site 1):
/// substitute the bound names as integer literals throughout the exported
/// templates and index sets, then fold the structural sites that are now
/// closed.
fn instantiate_scope(
    scope: &mut TemplateScope,
    values: &BTreeMap<String, i64>,
    ctx: &str,
) -> Result<(), ExpressionTemplateError> {
    let mut new_templates = Map::new();
    for (n, d) in &scope.templates {
        let mut nd = substitute_metaparams_decl(d, values);
        fold_structural_sites(&mut nd, ctx)?;
        new_templates.insert(n.clone(), nd);
    }
    scope.templates = new_templates;
    let mut new_index_sets = Map::new();
    for (n, d) in &scope.index_sets {
        new_index_sets.insert(n.clone(), substitute_metaparams(d, values));
    }
    fold_index_set_sizes(&mut new_index_sets, ctx, false)?;
    scope.index_sets = new_index_sets;
    Ok(())
}

/// Lexically normalize a path (collapse `.` and `..` components) — the
/// canonical key for import-cycle detection (esm-spec §9.7.2, as §4.7). The
/// normalization is lexical so that a not-yet-read path still has a stable
/// key.
fn lexical_normalize(p: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for comp in p.components() {
        match comp {
            Component::CurDir => {}
            Component::ParentDir => {
                if !out.pop() {
                    out.push("..");
                }
            }
            other => out.push(other.as_os_str()),
        }
    }
    out
}

fn canonical_ref(ref_str: &str, base_dir: &Path) -> String {
    lexical_normalize(&base_dir.join(ref_str))
        .to_string_lossy()
        .into_owned()
}

fn load_import_raw(
    ref_str: &str,
    base_dir: &Path,
    origin: &str,
) -> Result<(Value, PathBuf), ExpressionTemplateError> {
    if ref_str.starts_with("http://") || ref_str.starts_with("https://") {
        return Err(err(
            "template_import_unresolved",
            format!(
                "{origin}: failed to load template-library ref '{ref_str}': remote refs are not \
                 fetched by the Rust loader; download the file and import it by local path"
            ),
        ));
    }
    let path = lexical_normalize(&base_dir.join(ref_str));
    let content = std::fs::read_to_string(&path).map_err(|e| {
        err(
            "template_import_unresolved",
            format!(
                "{origin}: template-library file not found or unreadable: {} (from ref \
                 '{ref_str}'): {e}",
                path.display()
            ),
        )
    })?;
    let raw: Value = serde_json::from_str(&content).map_err(|e| {
        err(
            "template_import_unresolved",
            format!(
                "{origin}: template-library ref '{}' is not valid JSON: {e}",
                path.display()
            ),
        )
    })?;
    let dir = path
        .parent()
        .map(|p| p.to_path_buf())
        .unwrap_or_else(|| base_dir.to_path_buf());
    Ok((raw, dir))
}

/// Resolve ONE `expression_template_imports` entry (esm-spec §9.7.2): load
/// the target (path-scoped cycle detection over canonical refs, as §4.7),
/// verify library purity, resolve the target recursively in its own scope,
/// instantiate at this edge's `bindings`, then apply `only` visibility
/// filtering.
fn resolve_import_entry(
    entry: &Value,
    base_dir: &Path,
    stack: &mut Vec<String>,
    origin: &str,
) -> Result<TemplateScope, ExpressionTemplateError> {
    let Some(entry_obj) = entry.as_object() else {
        return Err(err(
            "template_import_unresolved",
            format!("{origin}: expression_template_imports entries must be objects with a `ref` field"),
        ));
    };
    let ref_str = match entry_obj.get("ref").and_then(|v| v.as_str()) {
        Some(s) if !s.is_empty() => s,
        _ => {
            return Err(err(
                "template_import_unresolved",
                format!(
                    "{origin}: expression_template_imports entry requires a non-empty string `ref`"
                ),
            ));
        }
    };
    let canonical = canonical_ref(ref_str, base_dir);
    if let Some(pos) = stack.iter().position(|s| *s == canonical) {
        let mut cyc: Vec<String> = stack[pos..].to_vec();
        cyc.push(canonical);
        return Err(err(
            "template_import_cycle",
            format!(
                "{origin}: import-graph cycle detected: {} (esm-spec §9.7.2)",
                cyc.join(" -> ")
            ),
        ));
    }

    let (raw, target_dir) = load_import_raw(ref_str, base_dir, origin)?;
    // Version gates on the target (esm-spec §9.6.5).
    reject_expression_templates_pre_v04(&raw)?;
    reject_template_imports_pre_v08(&raw)?;

    // Library purity (esm-spec §9.7.1): the two reference mechanisms are
    // disjoint — a component/subsystem file is not importable as a library.
    if !is_template_library_doc(&raw) {
        return Err(err(
            "template_import_not_library",
            format!(
                "{origin}: import target '{ref_str}' lacks top-level `expression_templates` — \
                 not a template-library file (esm-spec §9.7.1)"
            ),
        ));
    }
    for k in LIBRARY_FORBIDDEN_KEYS {
        if raw.get(k).is_some() {
            return Err(err(
                "template_import_not_library",
                format!(
                    "{origin}: import target '{ref_str}' declares `{k}` — not a pure \
                     template-library file (esm-spec §9.7.1)"
                ),
            ));
        }
    }
    if let Err(e) = crate::parse::validate_schema(&raw) {
        return Err(err(
            "template_import_unresolved",
            format!("{origin}: import target '{ref_str}' failed schema validation: {e}"),
        ));
    }

    stack.push(canonical);
    let result = process_library(&raw, &target_dir, stack, &format!("{origin} -> {ref_str}"));
    stack.pop();
    let mut scope = result?;

    // Edge metaparameter bindings (esm-spec §9.7.6 binding site 1).
    let mut values: BTreeMap<String, i64> = BTreeMap::new();
    if let Some(bindings) = entry_obj.get("bindings").and_then(|v| v.as_object()) {
        for (name, v) in bindings {
            if !scope.metaparams.contains_key(name) {
                return Err(err(
                    "template_import_unknown_name",
                    format!(
                        "{origin}: import of '{ref_str}' binds metaparameter '{name}', which \
                         the target neither declares nor re-exports (esm-spec §9.7.6)"
                    ),
                ));
            }
            values.insert(
                name.clone(),
                require_int(v, &format!("{origin}: import of '{ref_str}', binding '{name}'"))?,
            );
        }
    }
    if !values.is_empty() {
        instantiate_scope(&mut scope, &values, &format!("{origin} -> {ref_str}"))?;
        for name in values.keys() {
            scope.metaparams.remove(name);
        }
    }

    // `only` visibility filtering (esm-spec §9.7.2) — after the target's own
    // internal wiring resolved in its own scope.
    if let Some(only) = entry_obj.get("only").and_then(|v| v.as_array()) {
        let keep: Vec<String> = only
            .iter()
            .map(|n| n.as_str().unwrap_or_default().to_string())
            .collect();
        for n in &keep {
            if !scope.templates.contains_key(n) {
                return Err(err(
                    "template_import_unknown_name",
                    format!(
                        "{origin}: `only` names template '{n}', which '{ref_str}' does not \
                         declare (esm-spec §9.7.2)"
                    ),
                ));
            }
        }
        let keep_set: std::collections::HashSet<&str> = keep.iter().map(String::as_str).collect();
        let mut filtered = Map::new();
        for (n, d) in &scope.templates {
            if keep_set.contains(n.as_str()) {
                filtered.insert(n.clone(), d.clone());
            }
        }
        scope.templates = filtered;
    }
    Ok(scope)
}

/// Resolve a template-library document in its OWN scope: its imports
/// (depth-first post-order), then its own templates / index sets /
/// metaparameters appended in declaration order (esm-spec §9.7.4), then
/// §9.7.3 body composition — so a BC-layer body reference to an imported
/// interior stencil closes here, before any `only` filtering by a downstream
/// importer.
fn process_library(
    raw: &Value,
    dir: &Path,
    stack: &mut Vec<String>,
    origin: &str,
) -> Result<TemplateScope, ExpressionTemplateError> {
    let mut scope = TemplateScope::default();
    if let Some(imports) = raw.get("expression_template_imports").and_then(|v| v.as_array()) {
        for entry in imports {
            let sub = resolve_import_entry(entry, dir, stack, origin)?;
            merge_scope(&mut scope, sub, origin)?;
        }
    }

    let mut own = Map::new();
    if let Some(tpl) = raw.get("expression_templates").and_then(|v| v.as_object()) {
        for (n, d) in tpl {
            own.insert(n.clone(), d.clone());
        }
    }
    validate_templates(&own, origin)?;
    for (n, d) in own {
        merge_named(
            &mut scope.templates,
            &n,
            d,
            "template_import_name_conflict",
            "template",
            origin,
        )?;
    }

    if let Some(isets) = raw.get("index_sets").and_then(|v| v.as_object()) {
        for (n, d) in isets {
            merge_named(
                &mut scope.index_sets,
                n,
                d.clone(),
                "template_import_index_set_conflict",
                "index set",
                origin,
            )?;
        }
    }

    for (n, d) in collect_metaparam_decls(raw, origin)? {
        merge_named(
            &mut scope.metaparams,
            &n,
            d,
            "template_import_name_conflict",
            "metaparameter",
            origin,
        )?;
    }

    // §9.7.3 body composition in the library's own scope, so downstream
    // `only` filtering sees closed bodies.
    compose_template_bodies(&mut scope.templates, origin)?;
    Ok(scope)
}

// ---------------------------------------------------------------------------
// Root-document resolution (the load-time entry point)
// ---------------------------------------------------------------------------

fn has_import_machinery(raw: &Value) -> bool {
    let Some(obj) = raw.as_object() else {
        return false;
    };
    if obj.contains_key("expression_templates")
        || obj.contains_key("metaparameters")
        || obj.contains_key("expression_template_imports")
    {
        return true;
    }
    for compkind in COMPONENT_KINDS {
        if let Some(comps) = obj.get(compkind).and_then(|v| v.as_object()) {
            for (_, comp) in comps {
                if comp
                    .as_object()
                    .is_some_and(|c| c.contains_key("expression_template_imports"))
                {
                    return true;
                }
            }
        }
    }
    false
}

/// Resolve every esm-spec §9.7 construct of the ROOT document `raw_data`
/// (relative import refs resolve against `base_path`): imports recursively
/// with per-edge instantiation, `index_sets` merge, metaparameter close
/// (`metaparameters` is the loader-API binding site 4; already-closed edge
/// bindings win, then API bindings, then defaults) and fold,
/// expression-position substitution, and — for a root library file — §9.7.3
/// body composition.
///
/// Returns an order-preserving JSON tree ready for
/// [`crate::lower_expression_templates::lower_expression_templates`] with
/// `expression_template_imports`, `metaparameters`, and top-level
/// `expression_templates` consumed (Option A round-trip: none survives
/// `parse → emit`), or `Ok(None)` when the document carries no §9.7
/// machinery (the legacy fast path).
pub fn resolve_template_machinery(
    raw_data: &Value,
    base_path: &Path,
    metaparameters: &BTreeMap<String, i64>,
) -> Result<Option<Value>, ExpressionTemplateError> {
    if !has_import_machinery(raw_data) {
        if !metaparameters.is_empty() {
            let names: Vec<&str> = metaparameters.keys().map(String::as_str).collect();
            return Err(err(
                "template_import_unknown_name",
                format!(
                    "loader API binds metaparameter(s) {} but the document declares none \
                     (esm-spec §9.7.6)",
                    names.join(", ")
                ),
            ));
        }
        return Ok(None);
    }
    let mut root: Map<String, Value> = raw_data
        .as_object()
        .cloned()
        .expect("has_import_machinery implies an object");
    let mut stack: Vec<String> = Vec::new();

    let mut doc_meta = collect_metaparam_decls(raw_data, "document")?;
    let mut doc_isets: Map<String, Value> = root
        .get("index_sets")
        .and_then(|v| v.as_object())
        .cloned()
        .unwrap_or_default();

    // --- top-level templates + imports (root template-library file) ---
    let is_library = root.contains_key("expression_templates");
    let mut top_templates: Map<String, Value> = Map::new();
    if is_library {
        let mut top_scope = TemplateScope::default();
        if let Some(imports) = root
            .get("expression_template_imports")
            .and_then(|v| v.as_array())
            .cloned()
        {
            for entry in &imports {
                let sub = resolve_import_entry(entry, base_path, &mut stack, "document")?;
                merge_scope(&mut top_scope, sub, "document")?;
            }
        }
        let mut own = Map::new();
        if let Some(tpl) = root.get("expression_templates").and_then(|v| v.as_object()) {
            for (n, d) in tpl {
                own.insert(n.clone(), d.clone());
            }
        }
        validate_templates(&own, "document")?;
        for (n, d) in own {
            merge_named(
                &mut top_scope.templates,
                &n,
                d,
                "template_import_name_conflict",
                "template",
                "document",
            )?;
        }
        for (n, d) in top_scope.index_sets {
            merge_named(
                &mut doc_isets,
                &n,
                d,
                "template_import_index_set_conflict",
                "index set",
                "document",
            )?;
        }
        for (n, d) in top_scope.metaparams {
            merge_named(
                &mut doc_meta,
                &n,
                d,
                "template_import_name_conflict",
                "metaparameter",
                "document",
            )?;
        }
        top_templates = top_scope.templates;
    }

    // --- per-component imports (models / reaction systems, esm-spec §9.7.2) ---
    for compkind in COMPONENT_KINDS {
        let Some(Value::Object(comps)) = root.get_mut(compkind) else {
            continue;
        };
        let cnames: Vec<String> = comps.keys().cloned().collect();
        for cname in cnames {
            let corigin = format!("{compkind}.{cname}");
            let Some(Value::Object(comp)) = comps.get(&cname) else {
                continue;
            };
            let Some(imports) = comp.get("expression_template_imports").cloned() else {
                continue;
            };
            let mut cscope = TemplateScope::default();
            if let Some(entries) = imports.as_array() {
                for entry in entries {
                    let sub = resolve_import_entry(entry, base_path, &mut stack, &corigin)?;
                    merge_scope(&mut cscope, sub, &corigin)?;
                }
            }
            if let Some(tpl) = comp.get("expression_templates").and_then(|v| v.as_object()) {
                let mut own = Map::new();
                for (n, d) in tpl {
                    own.insert(n.clone(), d.clone());
                }
                validate_templates(&own, &corigin)?;
                for (n, d) in own {
                    merge_named(
                        &mut cscope.templates,
                        &n,
                        d,
                        "template_import_name_conflict",
                        "template",
                        &corigin,
                    )?;
                }
            }
            for (n, d) in cscope.index_sets {
                merge_named(
                    &mut doc_isets,
                    &n,
                    d,
                    "template_import_index_set_conflict",
                    "index set",
                    &corigin,
                )?;
            }
            for (n, d) in cscope.metaparams {
                merge_named(
                    &mut doc_meta,
                    &n,
                    d,
                    "template_import_name_conflict",
                    "metaparameter",
                    &corigin,
                )?;
            }
            // The effective sequence (imports depth-first post-order, then
            // local declarations) becomes the component's template block;
            // the preserve_order Map key order IS the §9.6.3 declaration
            // order.
            if let Some(Value::Object(comp)) = comps.get_mut(&cname) {
                comp.insert(
                    "expression_templates".to_string(),
                    Value::Object(cscope.templates),
                );
                comp.remove("expression_template_imports");
            }
        }
    }

    // --- close this document's metaparameters (§9.7.6 sites 4-5) ---
    for k in metaparameters.keys() {
        if !doc_meta.contains_key(k) {
            return Err(err(
                "template_import_unknown_name",
                format!(
                    "loader API binds metaparameter '{k}', which the document does not declare \
                     (esm-spec §9.7.6)"
                ),
            ));
        }
    }
    let mut values: BTreeMap<String, i64> = BTreeMap::new();
    let mut open_names: Vec<String> = Vec::new();
    for (name, decl) in &doc_meta {
        if let Some(v) = metaparameters.get(name) {
            values.insert(name.clone(), *v);
        } else {
            match decl.get("default").filter(|d| !d.is_null()) {
                Some(d) => {
                    values.insert(name.clone(), as_int(d).expect("validated integer default"));
                }
                None => open_names.push(name.clone()),
            }
        }
    }
    if !open_names.is_empty() {
        return Err(err(
            "metaparameter_unbound",
            format!(
                "metaparameter(s) {} still open after edge bindings, loader-API bindings, and \
                 defaults (esm-spec §9.7.6)",
                open_names.join(", ")
            ),
        ));
    }

    // --- §9.7.6 name-collision check: no shadowing of visible names ---
    if !doc_meta.is_empty() {
        let mut visible: std::collections::HashSet<String> =
            doc_isets.keys().cloned().collect();
        for compkind in COMPONENT_KINDS {
            if let Some(comps) = root.get(compkind).and_then(|v| v.as_object()) {
                for (_, comp) in comps {
                    let Some(comp_obj) = comp.as_object() else {
                        continue;
                    };
                    for blk in ["variables", "species", "parameters"] {
                        if let Some(b) = comp_obj.get(blk).and_then(|v| v.as_object()) {
                            visible.extend(b.keys().cloned());
                        }
                    }
                }
            }
        }
        for name in doc_meta.keys() {
            if visible.contains(name) {
                return Err(err(
                    "metaparameter_name_conflict",
                    format!(
                        "metaparameter '{name}' collides with a visible \
                         variable/parameter/species/index-set name (esm-spec §9.7.6)"
                    ),
                ));
            }
        }
    }

    // --- expression-position substitution of the closed values ---
    if !values.is_empty() {
        for compkind in COMPONENT_KINDS {
            let Some(Value::Object(comps)) = root.get_mut(compkind) else {
                continue;
            };
            for (_, comp_value) in comps.iter_mut() {
                let Value::Object(comp) = comp_value else {
                    continue;
                };
                let keys: Vec<String> = comp.keys().cloned().collect();
                for k in keys {
                    if k == "expression_templates"
                        && comp.get(&k).map(Value::is_object).unwrap_or(false)
                    {
                        if let Some(Value::Object(tpl)) = comp.get_mut(&k) {
                            let tnames: Vec<String> = tpl.keys().cloned().collect();
                            for tn in tnames {
                                let nd = substitute_metaparams_decl(&tpl[&tn], &values);
                                tpl.insert(tn, nd);
                            }
                        }
                    } else if let Some(v) = comp.get(&k) {
                        let nv = substitute_metaparams(v, &values);
                        comp.insert(k, nv);
                    }
                }
            }
        }
        let tnames: Vec<String> = top_templates.keys().cloned().collect();
        for tn in tnames {
            let nd = substitute_metaparams_decl(&top_templates[&tn], &values);
            top_templates.insert(tn, nd);
        }
        let mut new_isets = Map::new();
        for (n, d) in &doc_isets {
            new_isets.insert(n.clone(), substitute_metaparams(d, &values));
        }
        doc_isets = new_isets;
    }

    // --- fold structural sites on the closed document ---
    for compkind in COMPONENT_KINDS {
        let Some(Value::Object(comps)) = root.get_mut(compkind) else {
            continue;
        };
        for (cname, comp) in comps.iter_mut() {
            fold_structural_sites(comp, &format!("{compkind}.{cname}"))?;
        }
    }
    let tnames: Vec<String> = top_templates.keys().cloned().collect();
    for tn in tnames {
        let mut td = top_templates[&tn].clone();
        fold_structural_sites(&mut td, &format!("document.expression_templates.{tn}"))?;
        top_templates.insert(tn, td);
    }
    fold_index_set_sizes(&mut doc_isets, "document", true)?;

    // --- root library file: compose bodies (validation), then strip; no
    //     §9.7 construct survives parse → emit (esm-spec §9.7.6 round-trip) ---
    if is_library {
        compose_template_bodies(&mut top_templates, "document")?;
        root.remove("expression_templates");
    }
    root.remove("expression_template_imports");
    root.remove("metaparameters");
    if !doc_isets.is_empty() {
        root.insert("index_sets".to_string(), Value::Object(doc_isets));
    }
    Ok(Some(Value::Object(root)))
}
