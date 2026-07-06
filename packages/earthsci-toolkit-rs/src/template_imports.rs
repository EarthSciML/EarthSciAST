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
use indexmap::IndexMap;
use serde_json::{Map, Value};
use std::collections::BTreeMap;
use std::path::{Component, Path, PathBuf};

const COMPONENT_KINDS: [&str; 2] = ["models", "reaction_systems"];

/// The `apply_expression_template` op string — the named-template invocation
/// node whose `name` field the §9.7.7 rename walk rewrites.
const APPLY_OP: &str = "apply_expression_template";

/// A template-library file MUST NOT declare any of these (esm-spec §9.7.1).
const LIBRARY_FORBIDDEN_KEYS: [&str; 5] = [
    "models",
    "reaction_systems",
    "data_loaders",
    "coupling",
    "domain",
];

/// Keys whose VALUES are never expression positions: metaparameter names are
/// substituted as bare variable-reference strings, so structural string
/// fields must not be rewritten. Template `params` shadowing is handled
/// separately in [`substitute_metaparams_decl`].
const META_SUBST_SKIP_KEYS: [&str; 12] = [
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
    // `where` match-scoping constraints (esm-spec §9.6.1) carry index-set NAMES,
    // a structural namespace — never expression positions.
    "where",
];

/// Scalar Expression-node fields whose string value names an AXIS / index set
/// (rewritten by the index-set rename map, param-shadowed like §9.6.1).
const RENAME_AXIS_KEYS: [&str; 2] = ["wrt", "dim"];

/// The remaining scalar structural ExpressionNode fields (beyond
/// [`META_SUBST_SKIP_KEYS`]) whose values are never variable-reference
/// positions for the §9.7.7 rename walk: `op`, closed-registry ids, literal
/// enums. `from`, `wrt`/`dim`, apply-`name`, and `of` are handled positionally.
const RENAME_EXTRA_PROTECTED_KEYS: [&str; 12] = [
    "op",
    "id",
    "expect_cadence",
    "reduce",
    "semiring",
    "manifold",
    "fn",
    "table",
    "side",
    "attrs",
    "members",
    "from_faq",
];

/// True when object key `k` is a structural scalar field the §9.7.7 rename walk
/// must never rewrite (`_RENAME_PROTECTED_KEYS` in the Julia reference:
/// [`META_SUBST_SKIP_KEYS`] ∪ [`RENAME_EXTRA_PROTECTED_KEYS`]).
fn is_rename_protected(k: &str) -> bool {
    META_SUBST_SKIP_KEYS.contains(&k) || RENAME_EXTRA_PROTECTED_KEYS.contains(&k)
}

use crate::diagnostic::err;

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
    let Some((major, minor, _)) = crate::diagnostic::parse_semver(esm) else {
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
                format!(
                    "{origin}: metaparameters.{name} must be an object with `type: \"integer\"`"
                ),
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
        Value::Array(arr) => Value::Array(
            arr.iter()
                .map(|v| substitute_metaparams(v, values))
                .collect(),
        ),
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
            format!(
                "{ctx}: non-integer literal {x} in a structural integer site (esm-spec §9.7.6)"
            ),
        ));
    }
    let Some(obj) = x.as_object() else {
        return Err(err(
            "metaparameter_type_error",
            format!(
                "{ctx}: invalid metaparameter expression (expected integer, name, or {{op, args}})"
            ),
        ));
    };
    let (Some(op_raw), Some(args)) = (obj.get("op"), obj.get("args").and_then(|a| a.as_array()))
    else {
        return Err(err(
            "metaparameter_type_error",
            format!(
                "{ctx}: invalid metaparameter expression (expected {{op: +|-|*|/, args: [...]}})"
            ),
        ));
    };
    if args.is_empty() {
        return Err(err(
            "metaparameter_type_error",
            format!(
                "{ctx}: invalid metaparameter expression (expected {{op: +|-|*|/, args: [...]}})"
            ),
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
                            if let Some(f) =
                                try_fold(entry, &format!("{ctx}: makearray regions bound"))?
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
// Import-edge renaming / namespacing + free-name rebinding (esm-spec §9.7.7)
// ---------------------------------------------------------------------------

/// True when `s` is one or more `[A-Za-z_][A-Za-z0-9_]*` segments joined by
/// single dots — the §4.6 scoped-reference shape, the grammar for a `prefix`
/// and for `rename`/`rebind` TARGETS (esm-spec §9.7.7). Keys are never
/// grammar-checked. Mirrors the Julia `_is_valid_dotted_name`.
fn is_valid_dotted_name(s: &str) -> bool {
    !s.is_empty() && s.split('.').all(is_name_segment)
}

fn is_name_segment(seg: &str) -> bool {
    let mut chars = seg.chars();
    match chars.next() {
        Some(c) if c.is_ascii_alphabetic() || c == '_' => {}
        _ => return false,
    }
    chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// Read a `rename` / `rebind` map (name → dotted-identifier target). An empty
/// or absent map (or JSON `null`) is empty; a non-object, an empty key, or a
/// non-dotted-identifier target is `template_import_rename_invalid`. Order is
/// preserved (serde_json `preserve_order` source → `IndexMap`). Mirrors the
/// Julia `_name_map`.
fn name_map(
    raw: Option<&Value>,
    field: &str,
    where_: &str,
) -> Result<IndexMap<String, String>, ExpressionTemplateError> {
    let mut out = IndexMap::new();
    let Some(raw) = raw.filter(|v| !v.is_null()) else {
        return Ok(out);
    };
    let Some(obj) = raw.as_object() else {
        return Err(err(
            "template_import_rename_invalid",
            format!(
                "{where_}: `{field}` must be an object mapping names to names (esm-spec §9.7.7)"
            ),
        ));
    };
    for (k, v) in obj {
        if k.is_empty() {
            return Err(err(
                "template_import_rename_invalid",
                format!("{where_}: `{field}` has an empty key (esm-spec §9.7.7)"),
            ));
        }
        let valid_target = v.as_str().is_some_and(is_valid_dotted_name);
        if !valid_target {
            return Err(err(
                "template_import_rename_invalid",
                format!(
                    "{where_}: `{field}`.{k} target {v} is not a valid dotted identifier \
                     (segments [A-Za-z_][A-Za-z0-9_]* joined by single dots; esm-spec §9.7.7)"
                ),
            ));
        }
        out.insert(k.clone(), v.as_str().unwrap().to_string());
    }
    Ok(out)
}

/// One transitive-substitution pass over an imported declaration (esm-spec
/// §9.7.7): `varmap` (renamed open metaparameters + rebound free names)
/// rewrites bare strings in variable-reference positions; `isetmap` rewrites
/// index-set reference positions (`{"from": …}` values, the `wrt`/`dim` axis
/// fields, and the `where.*.shape` match-scoping index-set names, in `body` and
/// `match` alike); `tplmap` rewrites `apply_expression_template.name`. Structural
/// scalar fields ([`is_rename_protected`]) and bound-index lists (range `of`) are
/// never rewritten. Pure syntactic substitution. Mirrors the Julia `_rename_walk`.
///
/// `where` is handled positionally (never by the protected-key copy that
/// metaparameter substitution uses, esm-spec §9.7.7): a `where` block is a map
/// `{paramName: {shape: [indexSetName, …]}}`. Rename renames templates, index
/// sets, and metaparameters — NOT template-internal param names — so the
/// constraint KEYS (param names) are copied verbatim while each constraint's
/// `shape` entries are mapped through `isetmap` (an unmapped name stays as
/// spelled). Without this the rule body/registry would use the renamed set while
/// `where` still named the original, and registration would fail with
/// `template_constraint_unknown_index_set`.
fn rename_walk(
    x: &Value,
    varmap: &IndexMap<String, String>,
    isetmap: &IndexMap<String, String>,
    tplmap: &IndexMap<String, String>,
) -> Value {
    match x {
        Value::String(s) => match varmap.get(s) {
            Some(n) => Value::String(n.clone()),
            None => x.clone(),
        },
        Value::Array(arr) => Value::Array(
            arr.iter()
                .map(|v| rename_walk(v, varmap, isetmap, tplmap))
                .collect(),
        ),
        Value::Object(obj) => {
            let is_apply = obj.get("op").and_then(|v| v.as_str()) == Some(APPLY_OP);
            let mut out = Map::new();
            for (k, v) in obj {
                if k == "from" && v.is_string() {
                    let s = v.as_str().unwrap();
                    out.insert(
                        k.clone(),
                        Value::String(isetmap.get(s).cloned().unwrap_or_else(|| s.to_string())),
                    );
                } else if RENAME_AXIS_KEYS.contains(&k.as_str()) && v.is_string() {
                    let s = v.as_str().unwrap();
                    out.insert(
                        k.clone(),
                        Value::String(isetmap.get(s).cloned().unwrap_or_else(|| s.to_string())),
                    );
                } else if k == "name" && is_apply && v.is_string() {
                    let s = v.as_str().unwrap();
                    out.insert(
                        k.clone(),
                        Value::String(tplmap.get(s).cloned().unwrap_or_else(|| s.to_string())),
                    );
                } else if k == "where" && v.is_object() {
                    out.insert(k.clone(), rename_where(v, isetmap));
                } else if k == "of" || is_rename_protected(k) {
                    out.insert(k.clone(), v.clone());
                } else {
                    out.insert(k.clone(), rename_walk(v, varmap, isetmap, tplmap));
                }
            }
            Value::Object(out)
        }
        _ => x.clone(),
    }
}

/// Rewrite a `where` match-scoping block (esm-spec §9.6.1) under an import-edge
/// index-set rename (esm-spec §9.7.7). Constraint KEYS (param names) are copied
/// verbatim — rename never touches template-internal param names — and each
/// constraint's `shape` entries (index-set names) are mapped through `isetmap`,
/// with any unmapped name left as spelled (the body-reference rule). Mirrors the
/// Julia `_rename_where`.
fn rename_where(whr: &Value, isetmap: &IndexMap<String, String>) -> Value {
    let obj = match whr.as_object() {
        Some(o) => o,
        None => return whr.clone(),
    };
    let mut out = Map::new();
    for (p, cobj) in obj {
        match cobj.as_object() {
            Some(cmap) => {
                let mut cout = Map::new();
                for (ck, cv) in cmap {
                    if ck == "shape" && cv.is_array() {
                        let shape = cv
                            .as_array()
                            .unwrap()
                            .iter()
                            .map(|e| match e.as_str() {
                                Some(s) => Value::String(
                                    isetmap.get(s).cloned().unwrap_or_else(|| s.to_string()),
                                ),
                                None => e.clone(),
                            })
                            .collect();
                        cout.insert(ck.clone(), Value::Array(shape));
                    } else {
                        cout.insert(ck.clone(), cv.clone());
                    }
                }
                out.insert(p.clone(), Value::Object(cout));
            }
            None => {
                out.insert(p.clone(), cobj.clone());
            }
        }
    }
    Value::Object(out)
}

/// A copy of `map` with any key in `pset` dropped — the §9.6.1 shadowing rule:
/// a template's own `params` shadow like-named `varmap` / `isetmap` entries
/// inside its `body`/`match` (a param is the inner binder; renaming must not
/// capture it).
fn without_keys(
    map: &IndexMap<String, String>,
    pset: &std::collections::HashSet<String>,
) -> IndexMap<String, String> {
    map.iter()
        .filter(|(k, _)| !pset.contains(*k))
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect()
}

/// [`rename_walk`] over one template declaration with the §9.6.1 shadowing
/// rule. `tplmap` is never shadowed — params do not bind template names.
/// Mirrors the Julia `_rename_decl`.
fn rename_decl(
    decl: &Value,
    varmap: &IndexMap<String, String>,
    isetmap: &IndexMap<String, String>,
    tplmap: &IndexMap<String, String>,
) -> Value {
    let pset: std::collections::HashSet<String> = decl
        .get("params")
        .and_then(|p| p.as_array())
        .map(|a| {
            a.iter()
                .filter_map(|v| v.as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default();
    if pset.is_empty() {
        return rename_walk(decl, varmap, isetmap, tplmap);
    }
    let v2 = without_keys(varmap, &pset);
    let i2 = without_keys(isetmap, &pset);
    rename_walk(decl, &v2, &i2, tplmap)
}

/// Bound index symbols of a declaration: aggregate `output_idx` entries and
/// `ranges` keys (at any nesting depth). Rebinding one would desynchronize the
/// ranges KEYS from their `expr` occurrences, so it is rejected. Mirrors the
/// Julia `_collect_bound_syms!`.
fn collect_bound_syms(x: &Value, out: &mut std::collections::HashSet<String>) {
    match x {
        Value::Array(arr) => {
            for v in arr {
                collect_bound_syms(v, out);
            }
        }
        Value::Object(obj) => {
            if obj.get("op").and_then(|v| v.as_str()) == Some("aggregate") {
                if let Some(oi) = obj.get("output_idx").and_then(|v| v.as_array()) {
                    for e in oi {
                        if let Some(s) = e.as_str() {
                            out.insert(s.to_string());
                        }
                    }
                }
                if let Some(rg) = obj.get("ranges").and_then(|v| v.as_object()) {
                    for k in rg.keys() {
                        out.insert(k.clone());
                    }
                }
            }
            for v in obj.values() {
                collect_bound_syms(v, out);
            }
        }
        _ => {}
    }
}

/// Every bare string in a variable-reference position of a declaration (the
/// positions `varmap` would rewrite), minus the per-template `params` shadow
/// set. Used for the rebind occurs-check and the freshness (collision) guard.
/// Mirrors the Julia `_collect_ref_names!`.
fn collect_ref_names(
    x: &Value,
    shadowed: &std::collections::HashSet<String>,
    out: &mut std::collections::HashSet<String>,
) {
    match x {
        Value::String(s) => {
            if !shadowed.contains(s) {
                out.insert(s.clone());
            }
        }
        Value::Array(arr) => {
            for v in arr {
                collect_ref_names(v, shadowed, out);
            }
        }
        Value::Object(obj) => {
            for (k, v) in obj {
                if k == "from"
                    || RENAME_AXIS_KEYS.contains(&k.as_str())
                    || k == "of"
                    || is_rename_protected(k)
                {
                    continue;
                }
                collect_ref_names(v, shadowed, out);
            }
        }
        _ => {}
    }
}

/// Apply one import edge's `prefix` / `rename` / `rebind` (esm-spec §9.7.7) to
/// the target's SURVIVING export scope — templates after `only`, all index
/// sets, and metaparameters still open after this edge's `bindings` —
/// transitively through every occurrence inside the surviving declarations.
/// Runs after `bindings` instantiation and `only` filtering, before the
/// §9.7.4/§9.7.5 merge, so dedup and conflict detection operate on post-rename
/// names. Pure load-time substitution. Mirrors the Julia `_apply_edge_renames!`.
///
/// The edge is processed as a sequence of named phases (each a helper below,
/// in this exact order): rename-key typo protection, final-name map
/// construction, per-namespace uniqueness, free/bound name inventory,
/// rebind-key occurs-check, freshness (capture) guard, then the one
/// simultaneous substitution.
fn apply_edge_renames(
    scope: &mut TemplateScope,
    entry: &Map<String, Value>,
    origin: &str,
    ref_str: &str,
) -> Result<(), ExpressionTemplateError> {
    let where_ = format!("{origin}: import of '{ref_str}'");
    let prefix_raw = entry.get("prefix").filter(|v| !v.is_null());
    let rename = name_map(entry.get("rename"), "rename", &where_)?;
    let rebind = name_map(entry.get("rebind"), "rebind", &where_)?;
    let prefix: Option<String> = match prefix_raw {
        None => None,
        Some(v) => {
            if !v.as_str().is_some_and(is_valid_dotted_name) {
                return Err(err(
                    "template_import_rename_invalid",
                    format!(
                        "{where_}: `prefix` {v} is not a valid dotted identifier (segments \
                         [A-Za-z_][A-Za-z0-9_]* joined by single dots; esm-spec §9.7.7)"
                    ),
                ));
            }
            Some(v.as_str().unwrap().to_string())
        }
    };
    if prefix.is_none() && rename.is_empty() && rebind.is_empty() {
        return Ok(());
    }

    let exported = exported_names(scope);
    check_rename_keys_exported(&rename, &exported, &where_)?;

    let maps = build_final_name_maps(scope, &rename, prefix.as_deref());
    check_final_name_uniqueness(&maps, &where_)?;

    let inventory = collect_name_inventory(scope);
    check_rebind_keys(&rebind, &exported, &inventory, &where_)?;
    check_new_name_freshness(&rebind, &maps.metamap, &inventory, &where_)?;

    apply_scope_substitution(scope, &maps, &rebind);
    Ok(())
}

/// The per-namespace original → final name maps for one import edge
/// (esm-spec §9.7.7): every surviving template / index-set / metaparameter
/// name mapped through `rename` (highest precedence) or `prefix`, identity
/// otherwise. Built by [`build_final_name_maps`].
struct EdgeNameMaps {
    tplmap: IndexMap<String, String>,
    isetmap: IndexMap<String, String>,
    metamap: IndexMap<String, String>,
}

/// Every name the target exports at this edge — templates after `only`, all
/// index sets, and metaparameters left open by this edge's `bindings`. This
/// is the domain `rename` keys must address (and `rebind` keys must NOT).
fn exported_names(scope: &TemplateScope) -> std::collections::HashSet<String> {
    let mut exported: std::collections::HashSet<String> = std::collections::HashSet::new();
    exported.extend(scope.templates.keys().cloned());
    exported.extend(scope.index_sets.keys().cloned());
    exported.extend(scope.metaparams.keys().cloned());
    exported
}

/// `rename` keys must name a surviving exported name (typo protection,
/// esm-spec §9.7.7) — `template_import_rename_unknown_name` otherwise.
fn check_rename_keys_exported(
    rename: &IndexMap<String, String>,
    exported: &std::collections::HashSet<String>,
    where_: &str,
) -> Result<(), ExpressionTemplateError> {
    for k in rename.keys() {
        if !exported.contains(k) {
            return Err(err(
                "template_import_rename_unknown_name",
                format!(
                    "{where_}: `rename` names '{k}', which the target does not export at this \
                     edge (the surviving exports are templates after `only`, index sets, and \
                     metaparameters left open by this edge's `bindings`; esm-spec §9.7.7)"
                ),
            ));
        }
    }
    Ok(())
}

/// Map every surviving exported name to its final name: an explicit `rename`
/// entry wins, else `prefix.name`, else identity (esm-spec §9.7.7).
fn build_final_name_maps(
    scope: &TemplateScope,
    rename: &IndexMap<String, String>,
    prefix: Option<&str>,
) -> EdgeNameMaps {
    let final_name = |n: &str| -> String {
        if let Some(t) = rename.get(n) {
            t.clone()
        } else if let Some(p) = prefix {
            format!("{p}.{n}")
        } else {
            n.to_string()
        }
    };
    EdgeNameMaps {
        tplmap: scope
            .templates
            .keys()
            .map(|n| (n.clone(), final_name(n)))
            .collect(),
        isetmap: scope
            .index_sets
            .keys()
            .map(|n| (n.clone(), final_name(n)))
            .collect(),
        metamap: scope
            .metaparams
            .keys()
            .map(|n| (n.clone(), final_name(n)))
            .collect(),
    }
}

/// Per-namespace final-name uniqueness: two distinct original names mapping
/// to the same final name is `template_import_rename_collision` (esm-spec
/// §9.7.7).
fn check_final_name_uniqueness(
    maps: &EdgeNameMaps,
    where_: &str,
) -> Result<(), ExpressionTemplateError> {
    for (what, m) in [
        ("template", &maps.tplmap),
        ("index set", &maps.isetmap),
        ("metaparameter", &maps.metamap),
    ] {
        let mut seen: std::collections::HashMap<String, String> = std::collections::HashMap::new();
        for (o, n) in m {
            if let Some(prev) = seen.get(n) {
                return Err(err(
                    "template_import_rename_collision",
                    format!(
                        "{where_}: {what} names '{prev}' and '{o}' both map to '{n}' after \
                         renaming (esm-spec §9.7.7)"
                    ),
                ));
            }
            seen.insert(n.clone(), o.clone());
        }
    }
    Ok(())
}

/// Free / bound / param name inventory over a scope's surviving declarations
/// (esm-spec §9.7.7), consulted by the `rebind` occurs-check and the
/// freshness (collision) guard.
struct NameInventory {
    /// Bare strings in variable-reference positions, minus each template's
    /// own `params` shadow set and the declared metaparameter names.
    free: std::collections::HashSet<String>,
    /// Bound index symbols (aggregate `output_idx` entries / `ranges` keys).
    bound: std::collections::HashSet<String>,
    /// The union of every template's declared `params`.
    params_all: std::collections::HashSet<String>,
}

/// Build the [`NameInventory`]: free names come from the variable-reference
/// positions of every surviving template (shadowed by that template's own
/// `params`) plus index-set `offsets` / `values` producer refs; declared
/// metaparameter names are never free.
fn collect_name_inventory(scope: &TemplateScope) -> NameInventory {
    let mut free: std::collections::HashSet<String> = std::collections::HashSet::new();
    let mut bound: std::collections::HashSet<String> = std::collections::HashSet::new();
    let mut params_all: std::collections::HashSet<String> = std::collections::HashSet::new();
    for d in scope.templates.values() {
        collect_bound_syms(d, &mut bound);
        let mut shadowed: std::collections::HashSet<String> = std::collections::HashSet::new();
        if let Some(params) = d.get("params").and_then(|p| p.as_array()) {
            for p in params {
                if let Some(s) = p.as_str() {
                    shadowed.insert(s.to_string());
                }
            }
        }
        params_all.extend(shadowed.iter().cloned());
        collect_ref_names(d, &shadowed, &mut free);
    }
    for d in scope.index_sets.values() {
        for f in ["offsets", "values"] {
            if let Some(s) = d.get(f).and_then(|v| v.as_str()) {
                free.insert(s.to_string());
            }
        }
    }
    for k in scope.metaparams.keys() {
        free.remove(k); // declared names are not free
    }
    NameInventory {
        free,
        bound,
        params_all,
    }
}

/// `rebind` keys must denote free names (typo protection, esm-spec §9.7.7):
/// a declared name is `template_import_rebind_unknown_name` (use `rename`
/// for those), a bound index symbol is `template_import_rename_invalid`, and
/// a name not occurring free is `template_import_rebind_unknown_name`.
fn check_rebind_keys(
    rebind: &IndexMap<String, String>,
    exported: &std::collections::HashSet<String>,
    inventory: &NameInventory,
    where_: &str,
) -> Result<(), ExpressionTemplateError> {
    for k in rebind.keys() {
        if exported.contains(k) {
            return Err(err(
                "template_import_rebind_unknown_name",
                format!(
                    "{where_}: `rebind` names '{k}', a declared name of the target (template / \
                     index set / metaparameter) — `rebind` addresses only free names; use \
                     `rename` for declared names (esm-spec §9.7.7)"
                ),
            ));
        }
        if inventory.bound.contains(k) {
            return Err(err(
                "template_import_rename_invalid",
                format!(
                    "{where_}: `rebind` key '{k}' is a bound index symbol (`output_idx` / \
                     `ranges`) of an imported template, not a free name (esm-spec §9.7.7)"
                ),
            ));
        }
        if !inventory.free.contains(k) {
            return Err(err(
                "template_import_rebind_unknown_name",
                format!(
                    "{where_}: `rebind` names '{k}', which does not occur free in the imported \
                     declarations (esm-spec §9.7.7)"
                ),
            ));
        }
    }
    Ok(())
}

/// Freshness guard: every renamed metaparameter and rebound free name must
/// be fresh — colliding with a remaining free name, a bound index symbol, a
/// template param, or another rename/rebind target would capture or merge
/// distinct names (`template_import_rename_collision`, esm-spec §9.7.7).
fn check_new_name_freshness(
    rebind: &IndexMap<String, String>,
    metamap: &IndexMap<String, String>,
    inventory: &NameInventory,
    where_: &str,
) -> Result<(), ExpressionTemplateError> {
    let rebind_keys: std::collections::HashSet<&str> = rebind.keys().map(String::as_str).collect();
    let mut taken: std::collections::HashSet<String> = std::collections::HashSet::new();
    for f in &inventory.free {
        if !rebind_keys.contains(f.as_str()) {
            taken.insert(f.clone());
        }
    }
    taken.extend(inventory.bound.iter().cloned());
    taken.extend(inventory.params_all.iter().cloned());
    let mut newnames: Vec<String> = Vec::new();
    for (o, n) in metamap {
        if o != n {
            newnames.push(n.clone());
        }
    }
    for (o, n) in rebind {
        if o != n {
            newnames.push(n.clone());
        }
    }
    for t in &newnames {
        if taken.contains(t) {
            return Err(err(
                "template_import_rename_collision",
                format!(
                    "{where_}: renamed/rebound name '{t}' collides with a name still in use \
                     inside the imported declarations (a remaining free name, a bound index \
                     symbol, a template param, or another rename/rebind target; esm-spec §9.7.7)"
                ),
            ));
        }
        taken.insert(t.clone());
    }
    Ok(())
}

/// Apply the edge's renames as ONE simultaneous substitution (identity
/// entries dropped): rekey the scope's templates / index sets /
/// metaparameters to their final names and rewrite every occurrence inside
/// the surviving declarations ([`rename_decl`] / [`rename_walk`]), including
/// derived index-set `of` member lists.
fn apply_scope_substitution(
    scope: &mut TemplateScope,
    maps: &EdgeNameMaps,
    rebind: &IndexMap<String, String>,
) {
    let mut varmap: IndexMap<String, String> = IndexMap::new();
    for (o, n) in &maps.metamap {
        if o != n {
            varmap.insert(o.clone(), n.clone());
        }
    }
    for (o, n) in rebind {
        if o != n {
            varmap.insert(o.clone(), n.clone());
        }
    }
    let iset_changed: IndexMap<String, String> = maps
        .isetmap
        .iter()
        .filter(|(o, n)| o != n)
        .map(|(o, n)| (o.clone(), n.clone()))
        .collect();
    let tpl_changed: IndexMap<String, String> = maps
        .tplmap
        .iter()
        .filter(|(o, n)| o != n)
        .map(|(o, n)| (o.clone(), n.clone()))
        .collect();

    let mut newt = Map::new();
    for (n, d) in &scope.templates {
        let nd = rename_decl(d, &varmap, &iset_changed, &tpl_changed);
        newt.insert(
            maps.tplmap
                .get(n)
                .expect("tplmap covers every template")
                .clone(),
            nd,
        );
    }
    scope.templates = newt;

    let mut newi = Map::new();
    for (n, d) in &scope.index_sets {
        let mut nd = rename_walk(d, &varmap, &iset_changed, &tpl_changed);
        if let Some(of) = nd.get("of").and_then(|v| v.as_array()).cloned() {
            let new_of: Vec<Value> = of
                .iter()
                .map(|e| match e.as_str() {
                    Some(s) => Value::String(
                        iset_changed
                            .get(s)
                            .cloned()
                            .unwrap_or_else(|| s.to_string()),
                    ),
                    None => e.clone(),
                })
                .collect();
            if let Some(o) = nd.as_object_mut() {
                o.insert("of".to_string(), Value::Array(new_of));
            }
        }
        newi.insert(
            maps.isetmap
                .get(n)
                .expect("isetmap covers every index set")
                .clone(),
            nd,
        );
    }
    scope.index_sets = newi;

    let mut newm = Map::new();
    for (n, d) in &scope.metaparams {
        newm.insert(
            maps.metamap
                .get(n)
                .expect("metamap covers every metaparameter")
                .clone(),
            d.clone(),
        );
    }
    scope.metaparams = newm;
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
            format!(
                "{origin}: expression_template_imports entries must be objects with a `ref` field"
            ),
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
                require_int(
                    v,
                    &format!("{origin}: import of '{ref_str}', binding '{name}'"),
                )?,
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

    // Import-edge renaming / namespacing + free-name rebinding (esm-spec
    // §9.7.7) — after `bindings` instantiation and `only` filtering, before the
    // §9.7.4/§9.7.5 merge, so dedup/conflict checks see post-rename names.
    apply_edge_renames(&mut scope, entry_obj, origin, ref_str)?;
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
    if let Some(imports) = raw
        .get("expression_template_imports")
        .and_then(|v| v.as_array())
    {
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
///
/// The document is processed as six named phases (each a helper below, in
/// this exact order): top-level scope resolution, per-component imports,
/// metaparameter close, name-collision check, expression-position
/// substitution, and structural-site folding.
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
    let mut top_templates =
        resolve_top_level_scope(&root, base_path, &mut stack, &mut doc_meta, &mut doc_isets)?;

    // --- per-component imports (models / reaction systems, esm-spec §9.7.2) ---
    resolve_component_imports(
        &mut root,
        base_path,
        &mut stack,
        &mut doc_meta,
        &mut doc_isets,
    )?;

    // --- close this document's metaparameters (§9.7.6 sites 4-5) ---
    let values = close_document_metaparams(&doc_meta, metaparameters)?;

    // --- §9.7.6 name-collision check: no shadowing of visible names ---
    check_metaparam_collisions(&root, &doc_meta, &doc_isets)?;

    // --- expression-position substitution of the closed values ---
    substitute_closed_metaparams(&mut root, &mut top_templates, &mut doc_isets, &values);

    // --- fold structural sites on the closed document ---
    fold_closed_document(&mut root, &mut top_templates, &mut doc_isets)?;

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

/// Phase 1 of [`resolve_template_machinery`]: resolve the ROOT document's own
/// top-level `expression_templates` + `expression_template_imports` (a root
/// template-library file, esm-spec §9.7.4) into its effective template
/// sequence, merging the imported index sets and still-open metaparameters
/// into the document registries. Returns the effective top-level templates
/// (empty for a non-library root).
fn resolve_top_level_scope(
    root: &Map<String, Value>,
    base_path: &Path,
    stack: &mut Vec<String>,
    doc_meta: &mut Map<String, Value>,
    doc_isets: &mut Map<String, Value>,
) -> Result<Map<String, Value>, ExpressionTemplateError> {
    if !root.contains_key("expression_templates") {
        return Ok(Map::new());
    }
    let mut top_scope = TemplateScope::default();
    if let Some(imports) = root
        .get("expression_template_imports")
        .and_then(|v| v.as_array())
        .cloned()
    {
        for entry in &imports {
            let sub = resolve_import_entry(entry, base_path, stack, "document")?;
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
            doc_isets,
            &n,
            d,
            "template_import_index_set_conflict",
            "index set",
            "document",
        )?;
    }
    for (n, d) in top_scope.metaparams {
        merge_named(
            doc_meta,
            &n,
            d,
            "template_import_name_conflict",
            "metaparameter",
            "document",
        )?;
    }
    Ok(top_scope.templates)
}

/// Phase 2 of [`resolve_template_machinery`]: per-component imports (models /
/// reaction systems, esm-spec §9.7.2). Each component's effective sequence
/// (imports depth-first post-order, then local declarations) replaces its
/// `expression_templates` block — the preserve_order Map key order IS the
/// §9.6.3 declaration order — and its `expression_template_imports` is
/// consumed. Imported index sets and still-open metaparameters merge into
/// the document registries.
fn resolve_component_imports(
    root: &mut Map<String, Value>,
    base_path: &Path,
    stack: &mut Vec<String>,
    doc_meta: &mut Map<String, Value>,
    doc_isets: &mut Map<String, Value>,
) -> Result<(), ExpressionTemplateError> {
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
                    let sub = resolve_import_entry(entry, base_path, stack, &corigin)?;
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
                    doc_isets,
                    &n,
                    d,
                    "template_import_index_set_conflict",
                    "index set",
                    &corigin,
                )?;
            }
            for (n, d) in cscope.metaparams {
                merge_named(
                    doc_meta,
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
    Ok(())
}

/// Phase 3 of [`resolve_template_machinery`]: close the document's
/// metaparameters (§9.7.6 sites 4-5). Loader-API bindings win, then
/// declaration defaults; a loader-API binding for an undeclared name is
/// `template_import_unknown_name`, and any name still open afterwards is
/// `metaparameter_unbound`. Returns the closed name → value map.
fn close_document_metaparams(
    doc_meta: &Map<String, Value>,
    metaparameters: &BTreeMap<String, i64>,
) -> Result<BTreeMap<String, i64>, ExpressionTemplateError> {
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
    for (name, decl) in doc_meta {
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
    Ok(values)
}

/// Phase 4 of [`resolve_template_machinery`]: the §9.7.6 name-collision
/// check — a declared metaparameter must not shadow any visible variable /
/// parameter / species / index-set name (`metaparameter_name_conflict`).
fn check_metaparam_collisions(
    root: &Map<String, Value>,
    doc_meta: &Map<String, Value>,
    doc_isets: &Map<String, Value>,
) -> Result<(), ExpressionTemplateError> {
    if doc_meta.is_empty() {
        return Ok(());
    }
    let mut visible: std::collections::HashSet<String> = doc_isets.keys().cloned().collect();
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
    Ok(())
}

/// Phase 5 of [`resolve_template_machinery`]: expression-position
/// substitution of the closed metaparameter values (esm-spec §9.7.6)
/// throughout every component (template declarations get the param-shadowing
/// walk, [`substitute_metaparams_decl`]), the top-level templates, and the
/// index-set registry. No-op when no values closed.
fn substitute_closed_metaparams(
    root: &mut Map<String, Value>,
    top_templates: &mut Map<String, Value>,
    doc_isets: &mut Map<String, Value>,
    values: &BTreeMap<String, i64>,
) {
    if values.is_empty() {
        return;
    }
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
                            let nd = substitute_metaparams_decl(&tpl[&tn], values);
                            tpl.insert(tn, nd);
                        }
                    }
                } else if let Some(v) = comp.get(&k) {
                    let nv = substitute_metaparams(v, values);
                    comp.insert(k, nv);
                }
            }
        }
    }
    let tnames: Vec<String> = top_templates.keys().cloned().collect();
    for tn in tnames {
        let nd = substitute_metaparams_decl(&top_templates[&tn], values);
        top_templates.insert(tn, nd);
    }
    let mut new_isets = Map::new();
    for (n, d) in doc_isets.iter() {
        new_isets.insert(n.clone(), substitute_metaparams(d, values));
    }
    *doc_isets = new_isets;
}

/// Phase 6 of [`resolve_template_machinery`]: fold the structural integer
/// sites of the now-closed document — aggregate `ranges` / makearray
/// `regions` bounds in every component and top-level template
/// ([`fold_structural_sites`]), then index-set `size` expressions in strict
/// mode (a remaining open name is `metaparameter_unbound`).
fn fold_closed_document(
    root: &mut Map<String, Value>,
    top_templates: &mut Map<String, Value>,
    doc_isets: &mut Map<String, Value>,
) -> Result<(), ExpressionTemplateError> {
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
    fold_index_set_sizes(doc_isets, "document", true)
}

// ===================================================================
// Scope-directed template injection (esm-spec §9.7.10)
//
// The consuming surface — a §4.7 subsystem-ref edge (form A), a §10 coupling
// entry (form B), or a §6.6/§6.7 test/example (form C) — may register imports
// into a TARGET component's own scope without editing the leaf. Forms A/B are
// applied here, at the raw-Value level, BEFORE `resolve_template_machinery`:
// each widens the target component's `expression_template_imports` in the
// §9.7.10 merge order, so the ordinary import resolver + §9.6.3 fixpoint lower
// the target's rewrite-targets with no engine change. Form C is applied by the
// PDE test runner (`pde_inline_tests.rs`) in a per-test ephemeral build.
// Mirrors the Julia reference (`template_imports.jl` `apply_scope_injections`).
// ===================================================================

/// Append raw §9.7.2 import entries to a component's own
/// `expression_template_imports` (esm-spec §9.7.10 merge order: the target's
/// own imports first, then the injected list).
fn append_component_imports(comp: &mut Map<String, Value>, imports: &[Value]) {
    let mut base: Vec<Value> = comp
        .get("expression_template_imports")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    base.extend(imports.iter().cloned());
    comp.insert(
        "expression_template_imports".to_string(),
        Value::Array(base),
    );
}

/// esm-spec §9.7.10 form A: append the subsystem-ref edge's injected §9.7.2
/// import entries to the single top-level component's own
/// `expression_template_imports`, so the referenced document is lowered under
/// the assembler-chosen discretization. A referenced subsystem file holds
/// exactly one top-level model or reaction system (§4.7), the implicit target.
/// A data-loader-only referenced file has no expression positions, so the
/// injection finds no home and the mount fails cleanly downstream.
fn apply_subsystem_ref_injection(root: &mut Value, injected: &[Value]) -> bool {
    if injected.is_empty() {
        return false;
    }
    let Some(root_obj) = root.as_object_mut() else {
        return false;
    };
    for compkind in COMPONENT_KINDS {
        let Some(Value::Object(comps)) = root_obj.get_mut(compkind) else {
            continue;
        };
        let Some(cname) = comps.keys().next().cloned() else {
            continue;
        };
        if let Some(Value::Object(comp)) = comps.get_mut(&cname) {
            append_component_imports(comp, injected);
            return true;
        }
    }
    false
}

/// The set of system names one coupling entry references (esm-spec §10.8):
/// `operator_compose`/`couple` → members of `systems`; `variable_map` → owning
/// systems of `from`/`to`; `event` → owning systems of any scoped reference in
/// the entry. A `callback` references none.
fn coupling_referenced_systems(entry: &Map<String, Value>) -> std::collections::HashSet<String> {
    let mut out = std::collections::HashSet::new();
    let ctype = entry.get("type").and_then(Value::as_str).unwrap_or("");
    match ctype {
        "operator_compose" | "couple" => {
            if let Some(sys) = entry.get("systems").and_then(Value::as_array) {
                for s in sys {
                    if let Some(s) = s.as_str() {
                        out.insert(s.to_string());
                        out.insert(s.split('.').next().unwrap_or(s).to_string());
                    }
                }
            }
        }
        "variable_map" => {
            for k in ["from", "to"] {
                if let Some(v) = entry.get(k).and_then(Value::as_str) {
                    out.insert(v.split('.').next().unwrap_or(v).to_string());
                }
            }
        }
        "event" => {
            for v in entry.values() {
                collect_scoped_owners(v, &mut out);
            }
        }
        _ => {}
    }
    out
}

/// Walk `x` and add the owning-system segment of every scoped reference (a
/// string of the form `"System.var"`) to `out`. Used for `event` entries whose
/// system references are spread across conditions/affects.
fn collect_scoped_owners(x: &Value, out: &mut std::collections::HashSet<String>) {
    match x {
        Value::String(s) => {
            if let Some((head, _)) = s.split_once('.') {
                out.insert(head.to_string());
            }
        }
        Value::Array(a) => {
            for v in a {
                collect_scoped_owners(v, out);
            }
        }
        Value::Object(m) => {
            for v in m.values() {
                collect_scoped_owners(v, out);
            }
        }
        _ => {}
    }
}

/// esm-spec §9.7.10 form B / §10.8: for each `coupling` entry carrying an
/// `expression_template_imports` map `{ <target>: [imports...] }`, resolve each
/// target key to a top-level system and append its imports to that system's own
/// `expression_template_imports` (merge order §9.7.10). The map is consumed here
/// (removed from the entry) so form B does not survive `parse → emit`.
///
/// Diagnostics (esm-spec §9.6.6): a key naming no system the entry references is
/// `template_inject_target_unknown`; a key resolving to a data loader is
/// `template_inject_target_is_loader`; a key resolving to neither model,
/// reaction system, nor loader is `template_inject_target_not_component`. Only
/// TOP-LEVEL system targets are resolved by this binding — a nested
/// `Parent.Child` key is out of scope (RFC §8.3) → `template_inject_target_not_component`.
fn apply_coupling_injections(root: &mut Value) -> Result<bool, ExpressionTemplateError> {
    let Some(root_obj) = root.as_object_mut() else {
        return Ok(false);
    };
    let has_injection = root_obj
        .get("coupling")
        .and_then(Value::as_array)
        .is_some_and(|arr| {
            arr.iter().any(|e| {
                e.as_object()
                    .is_some_and(|o| o.contains_key("expression_template_imports"))
            })
        });
    if !has_injection {
        return Ok(false);
    }

    // Snapshot the top-level system key sets for target resolution (each `.get`
    // is a scoped borrow that ends before `coupling` is taken mutably below).
    let model_keys: std::collections::HashSet<String> = root_obj
        .get("models")
        .and_then(Value::as_object)
        .map(|m| m.keys().cloned().collect())
        .unwrap_or_default();
    let rsys_keys: std::collections::HashSet<String> = root_obj
        .get("reaction_systems")
        .and_then(Value::as_object)
        .map(|m| m.keys().cloned().collect())
        .unwrap_or_default();
    let loader_keys: std::collections::HashSet<String> = root_obj
        .get("data_loaders")
        .and_then(Value::as_object)
        .map(|m| m.keys().cloned().collect())
        .unwrap_or_default();

    // Resolve every injection to (compkind, target, imports), consuming the maps
    // off the coupling entries; then apply, so target diagnostics fire before any
    // mutation (esm-spec §9.7.10 merge order 3, coupling-array order).
    let mut plan: Vec<(&'static str, String, Vec<Value>)> = Vec::new();
    {
        let Some(Value::Array(coupling)) = root_obj.get_mut("coupling") else {
            return Ok(false);
        };
        for entry in coupling.iter_mut() {
            let Some(entry_obj) = entry.as_object_mut() else {
                continue;
            };
            let Some(inj_val) = entry_obj.get("expression_template_imports").cloned() else {
                continue;
            };
            let Some(inj_map) = inj_val.as_object() else {
                return Err(err(
                    "template_inject_target_not_component",
                    "coupling entry `expression_template_imports` must be a map from a target \
                     system name to a list of imports (esm-spec §9.7.10 / §10.8)",
                ));
            };
            let referenced = coupling_referenced_systems(entry_obj);
            for (target, imports_val) in inj_map {
                if !referenced.contains(target) {
                    let mut refs: Vec<String> = referenced.iter().cloned().collect();
                    refs.sort();
                    let refs_str = if refs.is_empty() {
                        "(none)".to_string()
                    } else {
                        refs.join(", ")
                    };
                    return Err(err(
                        "template_inject_target_unknown",
                        format!(
                            "coupling entry `expression_template_imports` key '{target}' names no \
                             system referenced by that entry (esm-spec §9.7.10 / §10.8). The entry \
                             references: {refs_str}."
                        ),
                    ));
                }
                let compkind = if model_keys.contains(target) {
                    "models"
                } else if rsys_keys.contains(target) {
                    "reaction_systems"
                } else if loader_keys.contains(target) {
                    return Err(err(
                        "template_inject_target_is_loader",
                        format!(
                            "coupling entry `expression_template_imports` key '{target}' resolves \
                             to a data loader, which is pure I/O with no expression positions to \
                             rewrite (esm-spec §9.7.10 / §14)."
                        ),
                    ));
                } else {
                    return Err(err(
                        "template_inject_target_not_component",
                        format!(
                            "coupling entry `expression_template_imports` key '{target}' resolves \
                             to neither a top-level model, reaction system, nor data loader \
                             (esm-spec §9.7.10). Nested `Parent.Child` targets are out of scope."
                        ),
                    ));
                };
                let Some(imports_arr) = imports_val.as_array() else {
                    return Err(err(
                        "template_import_not_library",
                        format!(
                            "coupling entry `expression_template_imports` value for '{target}' \
                             must be a list of §9.7.2 import entries (esm-spec §9.7.10 / §10.8)."
                        ),
                    ));
                };
                plan.push((compkind, target.clone(), imports_arr.clone()));
            }
            entry_obj.remove("expression_template_imports");
        }
    }

    for (compkind, target, imports) in plan {
        if let Some(Value::Object(comps)) = root_obj.get_mut(compkind)
            && let Some(Value::Object(comp)) = comps.get_mut(&target)
        {
            append_component_imports(comp, &imports);
        }
    }
    Ok(true)
}

/// esm-spec §9.7.10 forms A + B: fold any scope-directed injection — a
/// subsystem-ref edge's `injected` import list (form A) or a coupling entry's
/// injection map (form B) — into the target components' own
/// `expression_template_imports`, in place, so the ordinary import resolver +
/// §9.6.3 fixpoint lower the target under the consumer-chosen discretization.
/// Runs BEFORE `resolve_template_machinery`; form B target diagnostics
/// (`template_inject_target_*`) surface here.
pub fn apply_scope_injections(
    root: &mut Value,
    injected: &[Value],
) -> Result<(), ExpressionTemplateError> {
    apply_subsystem_ref_injection(root, injected);
    apply_coupling_injections(root)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn dotted_name_grammar_accepts_scoped_refs_and_rejects_malformed() {
        // §4.6 scoped-reference shape: [A-Za-z_][A-Za-z0-9_]* segments joined
        // by single dots (esm-spec §9.7.7).
        assert!(is_valid_dotted_name("a"));
        assert!(is_valid_dotted_name("lib.stencil_1"));
        assert!(is_valid_dotted_name("_x.y_2.z"));
        assert!(!is_valid_dotted_name(""));
        assert!(!is_valid_dotted_name("1abc"));
        assert!(!is_valid_dotted_name("a..b"));
        assert!(!is_valid_dotted_name("a."));
        assert!(!is_valid_dotted_name("a-b"));
    }

    #[test]
    fn lexical_normalize_collapses_dot_components_without_io() {
        // The cycle-detection key must be stable for not-yet-read paths, so
        // normalization is purely lexical (esm-spec §9.7.2, as §4.7).
        assert_eq!(
            lexical_normalize(Path::new("a/./b/../c")),
            PathBuf::from("a/c")
        );
        assert_eq!(
            lexical_normalize(Path::new("./lib/tpl.json")),
            PathBuf::from("lib/tpl.json")
        );
        // A leading `..` that cannot be popped is preserved.
        assert_eq!(lexical_normalize(Path::new("../x")), PathBuf::from("../x"));
    }

    #[test]
    fn try_fold_folds_closed_arithmetic_and_leaves_open_names_symbolic() {
        // Closed integer expressions fold exactly (esm-spec §9.7.6).
        assert_eq!(try_fold(&json!(3), "t").unwrap(), Some(3));
        assert_eq!(
            try_fold(&json!({"op": "+", "args": [1, 2, 3]}), "t").unwrap(),
            Some(6)
        );
        assert_eq!(
            try_fold(&json!({"op": "-", "args": [5]}), "t").unwrap(),
            Some(-5)
        );
        assert_eq!(
            try_fold(&json!({"op": "/", "args": [8, 2]}), "t").unwrap(),
            Some(4)
        );
        // A bare name anywhere leaves the site symbolic for a later binding.
        assert_eq!(try_fold(&json!("N"), "t").unwrap(), None);
        assert_eq!(
            try_fold(&json!({"op": "*", "args": ["N", 2]}), "t").unwrap(),
            None
        );
        // Inexact division and non-integer literals are type errors.
        let e = try_fold(&json!({"op": "/", "args": [7, 2]}), "t").unwrap_err();
        assert_eq!(e.code, "metaparameter_type_error");
        let e = try_fold(&json!(2.5), "t").unwrap_err();
        assert_eq!(e.code, "metaparameter_type_error");
    }
}
