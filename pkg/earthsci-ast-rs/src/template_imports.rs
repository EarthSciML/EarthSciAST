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
//! 4. §9.7.3 registration-time body-reference validation
//!    (`validate_template_body_references`, invoked per component from
//!    `lower_expression_templates`);
//! 5. the §9.6.3 fixpoint on fully-concrete trees.
//!
//! Round-trip is Option A, which expands CALL SITES and does NOT delete
//! DECLARATIONS (esm-spec §9.6.4 rule 5). `expression_template_imports` is an
//! import directive consumed by the fixpoint and does not survive `parse →
//! emit`; the `apply_expression_template` call sites it lowers do not survive
//! either. But a top-level `expression_templates` registry and a top-level
//! `metaparameters` block are DECLARATIONS — peers of `index_sets` — and they
//! survive VERBATIM: a template-library file MUST round-trip to itself.
//!
//! This module used to delete all three, so a pure library file emitted as
//! `{esm, metadata, index_sets}` — none of the five top-level payload keys —
//! which the schema's top-level `anyOf` rejects. A conforming library was legal
//! on disk and illegal the instant it was loaded and re-emitted.
//!
//! All diagnostics are raised as [`ExpressionTemplateError`] with the stable
//! §9.6.6 codes so they are machine-checkable across bindings. Mirrors the
//! Julia reference implementation
//! (`EarthSciAST.jl/src/template_imports.jl`).
//!
//! Remote (`http(s)://`) template-library refs are not fetched (this crate
//! carries no HTTP client, matching the subsystem-ref loader): they are
//! rejected as `template_import_unresolved`.

use crate::lower_expression_templates::{
    ExpressionTemplateError, collect_apply_names as compose_collect_apply_names,
    reject_expression_templates_pre_v04, validate_template_body_references, validate_templates,
};
use indexmap::IndexMap;
use serde_json::{Map, Value};
use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::path::{Component, Path, PathBuf};

const COMPONENT_KINDS: [&str; 2] = ["models", "reaction_systems"];

/// The `apply_expression_template` op string — the named-template invocation
/// node whose `name` field the §9.7.7 rename walk rewrites.
const APPLY_OP: &str = "apply_expression_template";

/// A template-library file MUST NOT declare any of these (esm-spec §9.7.1).
const LIBRARY_FORBIDDEN_KEYS: [&str; 5] = [
    "models",
    "reaction_systems",
    "data_sources",
    "coupling",
    "domain",
];

// ---------------------------------------------------------------------------
// Canonical structural-field table
// ---------------------------------------------------------------------------
// The ONE registry of raw-JSON object keys whose VALUES are structural — never
// ordinary expression positions — for the two load-time rewrite passes in this
// module (metaparameter substitution, esm-spec §9.7.6, and the import-edge
// rename walk, esm-spec §9.7.7). The two predicates below are DERIVED from it;
// nothing else hand-maintains key membership. Mirrors `_STRUCTURAL_FIELDS` in
// the Julia reference (`EarthSciAST.jl/src/template_imports.jl`) kind for kind.
//
// NEW Expression structural fields MUST be registered here with the right kind,
// or metaparameter substitution / import-edge renaming will rewrite their string
// values as if they were variable references.

/// Opaque to metaparameter substitution AND copied verbatim by the rename walk.
/// `name` and `where` additionally get a positional rename-walk branch.
const PROTECTED_KEYS: [&str; 11] = [
    "metadata",
    "params",
    "type",
    "units",
    "kind",
    "description",
    "name",
    "expression_template_imports",
    "metaparameters",
    "only",
    // `where` match-scoping constraints (esm-spec §9.6.1) carry index-set NAMES,
    // a structural namespace — never expression positions.
    "where",
];

/// Scalar Expression-node fields whose string value names an AXIS / index set
/// (rewritten by the index-set rename map, param-shadowed like §9.6.1), and
/// opaque to metaparameter substitution — an axis name is never an
/// integer-valued metaparameter reference. `var` is `integral`'s integration
/// variable (esm-spec §4.2) — the same kind of axis-naming scalar as
/// `wrt`/`dim` (§4.9.1), so an imported `integral` rewrite rule follows its axis
/// under rename exactly as a `D` rule does.
const RENAME_AXIS_KEYS: [&str; 3] = ["wrt", "dim", "var"];

/// NODE-HEADER fields: they describe the Expression node itself rather than
/// parameterizing whatever op it carries — `op` (which operator this node IS),
/// `id` (this node's identity) and `expect_cadence` (an assertion about this
/// node). None is an expression position (esm-spec §9.7.6), so a metaparameter
/// that happens to share a name with an operator — `max`, say — must not rewrite
/// `{"op": "max", …}` into `{"op": 3, …}`, which then dies in the typed load
/// with a raw "cannot unmarshal number into `op`" rather than a diagnostic.
/// Opaque to substitution AND copied verbatim by the rename walk.
const NODE_HEADER_KEYS: [&str; 3] = ["op", "id", "expect_cadence"];

/// Closed-registry ids / literal enums PARAMETERIZING the node's op. Like
/// [`NODE_HEADER_KEYS`] these are names rather than values, so they are opaque
/// to metaparameter substitution AND copied verbatim by the §9.7.7 rename walk;
/// the kind is kept distinct because the two answer different questions about a
/// node (what it IS vs how its op is parameterized). `from`, `wrt`/`dim`,
/// apply-`name`, and `of` are handled positionally.
const REGISTRY_KEYS: [&str; 9] = [
    "reduce", "semiring", "manifold", "fn", "table", "side", "attrs", "members", "from_faq",
];

/// Loop symbols, references, ids, enums, units and free text: not expression
/// positions, but not protected by the rename walk either, so opaque to
/// metaparameter substitution ONLY. `of` and `on` keep their dedicated
/// rename-walk branches. Mirrors the `:opaque` kind of `_STRUCTURAL_FIELDS` in
/// the Julia reference.
const OPAQUE_KEYS: [&str; 33] = [
    // Loop symbols and bound index names of a `faq` node. `metaparameter_name_conflict`
    // refuses a metaparameter spelled like a loop symbol, so a metaparameter reaches
    // these fields only as an `on` data-column name; they are names wherever they
    // appear, so they are skipped rather than left to that check.
    "on",
    "syms",
    "arg",
    "output_idx",
    "of",
    // A `table_lookup` output name.
    "output",
    "handler_id",
    // References to files, components, data sources, data columns and the
    // import-edge rename vocabulary.
    "ref",
    "model",
    "reaction_system",
    "prefix",
    "rename",
    "rebind",
    "index_set_rename",
    "source",
    "file_variable",
    "path",
    // Closed enums.
    "direction",
    "hook",
    "root_find",
    "system_kind",
    "element_type",
    "scale",
    "format",
    "unmapped",
    // Units (unit symbols such as `m`, `s`, `K` are valid identifiers) and free
    // text.
    "default_units",
    "label",
    "location",
    "notes",
    "citation",
    "doi",
    "url",
    "_comment",
];

/// Keys whose value is a map keyed by AUTHOR-CHOSEN names (variables, species,
/// loop symbols, template params, …). A map key is a declared name, not a field,
/// so it is never tested with [`is_meta_subst_skipped`]: a variable named
/// `source` or a template param named `label` still has its value substituted.
/// A key that is also skipped (`where`, `rename`, …) is skipped whole.
const NAME_KEYED_MAP_KEYS: [&str; 19] = [
    "variables",
    "species",
    "parameters",
    "guesses",
    "subsystems",
    "expression_templates",
    "ranges",
    "axes",
    "bindings",
    "config",
    "coords",
    "initial_conditions",
    "parameter_overrides",
    "pinned_coords",
    "map",
    "rename",
    "rebind",
    "index_set_rename",
    "where",
];

/// `integral` bound fields (esm-spec §4.2). Unlike `var` these are full
/// Expression positions — a numeric literal, a parameter reference, an AST
/// subtree — so they stay variable-reference positions for `varmap`; only a
/// bare string naming a RENAMED index set (the cumulative form
/// `"upper": "x"`) is an axis occurrence and follows the rename (§9.7.7).
const RENAME_BOUND_KEYS: [&str; 2] = ["lower", "upper"];

/// True when object key `k`'s VALUE is never an expression position:
/// metaparameter names are substituted as bare variable-reference strings, so
/// structural string fields must not be rewritten. Template `params` shadowing
/// is handled separately in [`substitute_metaparams_decl`].
///
/// All five bindings MUST agree on this predicate — a divergence is silent until
/// a document happens to name a metaparameter after a structural field's value
/// (`tests/conformance/expression_templates/metaparam_axis_name_collision`).
///
/// Every structural kind but `bound` and `positional` is in: an expression
/// position is the ONLY thing substitution may rewrite, and `bound` is the one
/// structural-table entry that IS one. [`OPAQUE_KEYS`] is in this predicate but
/// not in [`is_rename_protected`], so the two are derived separately.
///
/// The classification this set is derived from lives in
/// `tests/metaparameter_substitution/field_classification.json`; a unit test
/// fails when this predicate or [`NAME_KEYED_MAP_KEYS`] disagrees with it.
fn is_meta_subst_skipped(k: &str) -> bool {
    PROTECTED_KEYS.contains(&k)
        || RENAME_AXIS_KEYS.contains(&k)
        || NODE_HEADER_KEYS.contains(&k)
        || REGISTRY_KEYS.contains(&k)
        || OPAQUE_KEYS.contains(&k)
}

/// True when object key `k` is a structural scalar field the §9.7.7 rename walk
/// must never rewrite (`_RENAME_PROTECTED_KEYS` in the Julia reference: the
/// protected, axis, node-header and registry kinds).
fn is_rename_protected(k: &str) -> bool {
    PROTECTED_KEYS.contains(&k)
        || RENAME_AXIS_KEYS.contains(&k)
        || NODE_HEADER_KEYS.contains(&k)
        || REGISTRY_KEYS.contains(&k)
}

use crate::diagnostic::{codes, err};

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
        codes::TEMPLATE_IMPORT_VERSION_TOO_OLD,
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

/// A document carrying top-level `expression_templates` is a template-library
/// file (esm-spec §9.7.1), which MUST NOT declare `models`, `reaction_systems`,
/// `data_sources`, `coupling`, or `domain`. Rewrite rules are component-local
/// (§9.6.3 constraint 4), so beside a component the block is visible to
/// nothing: the document is rejected with `template_library_illegal_payload`
/// rather than loaded with the templates silently inert. An import target is
/// held to the same rule at the edge, as `template_import_not_library`.
pub(crate) fn reject_impure_template_library(view: &Value) -> Result<(), ExpressionTemplateError> {
    if !is_template_library_doc(view) {
        return Ok(());
    }
    let present: Vec<String> = LIBRARY_FORBIDDEN_KEYS
        .iter()
        .filter(|k| view.get(**k).is_some())
        .map(|k| format!("`{k}`"))
        .collect();
    if present.is_empty() {
        return Ok(());
    }
    Err(err(
        codes::TEMPLATE_LIBRARY_ILLEGAL_PAYLOAD,
        format!(
            "top-level `expression_templates` makes this document a template-library file, which MUST NOT declare {} (esm-spec §9.7.1); templates declared there are visible to no component. Declare them in the component's own `expression_templates` block (§9.6.1), or move them to a template-library file and import it with `expression_template_imports` (§9.7.2)",
            present.join(", ")
        ),
    ))
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
            codes::METAPARAMETER_TYPE_ERROR,
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
            codes::METAPARAMETER_TYPE_ERROR,
            format!("{origin}: `metaparameters` must be an object"),
        ));
    };
    for (name, v) in mp_obj {
        let Some(decl) = v.as_object() else {
            return Err(err(
                codes::METAPARAMETER_TYPE_ERROR,
                format!(
                    "{origin}: metaparameters.{name} must be an object with `type: \"integer\"`"
                ),
            ));
        };
        if decl.get("type").and_then(|t| t.as_str()) != Some("integer") {
            return Err(err(
                codes::METAPARAMETER_TYPE_ERROR,
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
/// variable-reference surface syntax — with their bound VALUES, everywhere
/// except the [`is_meta_subst_skipped`] structural fields (esm-spec §9.7.6:
/// expression-position substitution; no folding here). A bound value is
/// usually an integer literal (`Value::from(i64)`), but at an import edge it
/// may be a symbolic metaparameter expression (`{op, args}` over the
/// importer's still-open names) spliced in for a deferred fold at the
/// importer's close (esm-spec §9.7.6 binding value flow, site 1).
/// Hand-rolled rather than `crate::json_visit`: descent is key-dependent
/// (the [`is_meta_subst_skipped`] entries are copied verbatim, not walked, and
/// the entries of a [`NAME_KEYED_MAP_KEYS`] map are walked without a skip test
/// on their names).
fn substitute_metaparams(x: &Value, values: &BTreeMap<String, Value>) -> Value {
    match x {
        Value::String(s) => match values.get(s) {
            Some(v) => v.clone(),
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
                out.insert(k.clone(), substitute_metaparams_field(k, v, values));
            }
            Value::Object(out)
        }
        _ => x.clone(),
    }
}

/// [`substitute_metaparams`] applied to the value `v` of the object field `k`,
/// for a caller that iterates an object's fields itself: the field is skipped,
/// walked as a name-keyed map, or walked, exactly as inside the recursive walk.
fn substitute_metaparams_field(k: &str, v: &Value, values: &BTreeMap<String, Value>) -> Value {
    if is_meta_subst_skipped(k) {
        return v.clone();
    }
    match v {
        Value::Object(entries) if NAME_KEYED_MAP_KEYS.contains(&k) => Value::Object(
            entries
                .iter()
                .map(|(name, entry)| (name.clone(), substitute_metaparams(entry, values)))
                .collect(),
        ),
        _ => substitute_metaparams(v, values),
    }
}

/// Metaparameter substitution over one `expression_templates` entry: the
/// template's own `params` shadow like-named metaparameters inside its
/// `body` and `match` (a param is the inner binder; substitution must not
/// capture it).
fn substitute_metaparams_decl(decl: &Value, values: &BTreeMap<String, Value>) -> Value {
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
            codes::METAPARAMETER_TYPE_ERROR,
            format!(
                "{ctx}: non-integer literal {x} in a structural integer site (esm-spec §9.7.6)"
            ),
        ));
    }
    let Some(obj) = x.as_object() else {
        return Err(err(
            codes::METAPARAMETER_TYPE_ERROR,
            format!(
                "{ctx}: invalid metaparameter expression (expected integer, name, or {{op, args}})"
            ),
        ));
    };
    let (Some(op_raw), Some(args)) = (obj.get("op"), obj.get("args").and_then(|a| a.as_array()))
    else {
        return Err(err(
            codes::METAPARAMETER_TYPE_ERROR,
            format!(
                "{ctx}: invalid metaparameter expression (expected {{op: +|-|*|/, args: [...]}})"
            ),
        ));
    };
    if args.is_empty() {
        return Err(err(
            codes::METAPARAMETER_TYPE_ERROR,
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
            codes::METAPARAMETER_TYPE_ERROR,
            format!("{ctx}: op '{op}' is not allowed in a metaparameter expression (only + - * /)"),
        ));
    }
    let overflow = || {
        err(
            codes::METAPARAMETER_TYPE_ERROR,
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
                        codes::METAPARAMETER_TYPE_ERROR,
                        format!("{ctx}: division by zero"),
                    ));
                }
                if acc % *v != 0 {
                    return Err(err(
                        codes::METAPARAMETER_TYPE_ERROR,
                        format!("{ctx}: {acc} / {v} does not divide exactly (esm-spec §9.7.6)"),
                    ));
                }
                acc.checked_div(*v).ok_or_else(overflow)?
            }
        };
    }
    Ok(Some(acc))
}

/// Hand-rolled rather than `crate::json_visit`: descent is key-dependent
/// (`op` entries are operator names, not metaparameter names, and are
/// skipped).
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

/// Structural grammar check for a metaparameter expression (esm-spec §9.7.6),
/// independent of whether its names are yet concrete: an integer literal, a
/// name string, or `{op: +|-|*|/, args: [...non-empty...]}` recursively.
/// Unlike [`try_fold`] (which defers op-validation until every arg is
/// concrete), this catches an inadmissible op (`%`), missing/empty `args`, or a
/// float/bool literal at the binding EDGE even when an arg is still a symbolic
/// importer name. Mirrors the Python `_validate_meta_expr`.
fn validate_meta_expr(x: &Value, ctx: &str) -> Result<(), ExpressionTemplateError> {
    if as_int(x).is_some() || x.is_string() {
        return Ok(());
    }
    if x.is_boolean() || x.is_number() {
        return Err(err(
            codes::METAPARAMETER_TYPE_ERROR,
            format!(
                "{ctx}: non-integer literal {x} in a metaparameter expression (esm-spec §9.7.6)"
            ),
        ));
    }
    let Some(obj) = x.as_object() else {
        return Err(err(
            codes::METAPARAMETER_TYPE_ERROR,
            format!(
                "{ctx}: invalid metaparameter expression (expected integer, name, or {{op, args}})"
            ),
        ));
    };
    let op = obj.get("op").and_then(|v| v.as_str());
    let args = obj.get("args").and_then(|a| a.as_array());
    let op_ok = matches!(op, Some("+" | "-" | "*" | "/"));
    match args {
        Some(a) if op_ok && !a.is_empty() => {
            for elem in a {
                validate_meta_expr(elem, ctx)?;
            }
            Ok(())
        }
        _ => Err(err(
            codes::METAPARAMETER_TYPE_ERROR,
            format!(
                "{ctx}: invalid metaparameter expression (expected {{op: +|-|*|/, args: [...]}})"
            ),
        )),
    }
}

/// Validate that `v` is a *metaparameter expression* (esm-spec §9.7.6) — an
/// integer literal, a metaparameter-name string, or a `{op: +|-|*|/, args}`
/// tree over the same — and return it UNCHANGED (UNFOLDED); its free names
/// close at a later binding site. Raises `metaparameter_type_error` on an
/// inadmissible node. This is the relaxed replacement for [`require_int`] at
/// the metaparameter *binding* sites (import edge / subsystem edge): a binding
/// may now derive a child metaparameter from an arithmetic combination of the
/// importer's metaparameters (e.g. `NTGT = NX*NY`), which import renaming
/// (name→name) could not express. Mirrors the Python `require_meta_expr`.
pub(crate) fn require_meta_expr(v: &Value, ctx: &str) -> Result<Value, ExpressionTemplateError> {
    validate_meta_expr(v, ctx)?;
    Ok(v.clone())
}

/// Fold a metaparameter expression to a concrete `i64` against a CLOSED
/// environment `env` (name → int) — the importing document's metaparameter
/// scope (esm-spec §9.7.6 binding value flow). Substitutes the env names, then
/// folds with the exact-integer [`try_fold`] arithmetic (`/` must divide
/// exactly; 64-bit overflow is an error). Raises `template_import_unknown_name`
/// if the expression references a name absent from `env` — the mount-edge typo
/// failure, keeping error locality at the edge that authored the expression.
/// Mirrors the Python `eval_meta_expr`.
pub(crate) fn eval_meta_expr(
    expr: &Value,
    env: &BTreeMap<String, i64>,
    ctx: &str,
) -> Result<i64, ExpressionTemplateError> {
    let env_values: BTreeMap<String, Value> = env
        .iter()
        .map(|(k, v)| (k.clone(), Value::from(*v)))
        .collect();
    let substituted = substitute_metaparams(expr, &env_values);
    match try_fold(&substituted, ctx)? {
        Some(v) => Ok(v),
        None => {
            let mut names = Vec::new();
            collect_names(expr, &mut names);
            let free: std::collections::BTreeSet<String> =
                names.into_iter().filter(|n| !env.contains_key(n)).collect();
            let free_list = if free.is_empty() {
                "a name".to_string()
            } else {
                free.into_iter().collect::<Vec<_>>().join(", ")
            };
            Err(err(
                codes::TEMPLATE_IMPORT_UNKNOWN_NAME,
                format!(
                    "{ctx}: metaparameter expression references {free_list} not in the importing \
                     document's metaparameter scope (esm-spec §9.7.6)"
                ),
            ))
        }
    }
}

/// Fold metaparameter expressions in the structural integer sites —
/// `faq` dense `ranges` tuple entries and `makearray` `regions` bound
/// pairs — to concrete integers, in place, wherever they are already closed.
/// Entries still carrying a bare name (a template-param slot, or an open
/// metaparameter in a not-yet-fully-bound library) are left symbolic for a
/// later binding site. Index-set sizes are folded separately by
/// [`fold_index_set_sizes`].
fn fold_structural_sites(x: &mut Value, ctx: &str) -> Result<(), ExpressionTemplateError> {
    crate::json_visit::try_visit_values_mut(x, &mut |v| {
        let Some(obj) = v.as_object_mut() else {
            return Ok(());
        };
        let op = obj
            .get("op")
            .and_then(|w| w.as_str())
            .unwrap_or_default()
            .to_string();
        if op == "faq" {
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
        Ok(())
    })
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
                        codes::METAPARAMETER_UNBOUND,
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
            codes::TEMPLATE_IMPORT_RENAME_INVALID,
            format!(
                "{where_}: `{field}` must be an object mapping names to names (esm-spec §9.7.7)"
            ),
        ));
    };
    for (k, v) in obj {
        if k.is_empty() {
            return Err(err(
                codes::TEMPLATE_IMPORT_RENAME_INVALID,
                format!("{where_}: `{field}` has an empty key (esm-spec §9.7.7)"),
            ));
        }
        let valid_target = v.as_str().is_some_and(is_valid_dotted_name);
        if !valid_target {
            return Err(err(
                codes::TEMPLATE_IMPORT_RENAME_INVALID,
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
/// index-set reference positions (`{"from": …}` values, the `wrt`/`dim`/`var`
/// axis fields, a bare-axis-name `integral` `lower`/`upper` bound, and the
/// `where.*.shape` match-scoping index-set names, in `body` and
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
///
/// Hand-rolled rather than `crate::json_visit`: nearly every object entry has
/// a key-dependent substitution or skip rule.
/// Is `v` a join clause's `on` — a list of `[left, right]` key-column pairs
/// (esm-spec §4.9.5)? `on` occurs in exactly one place in the schema, a `join`
/// clause, and its shape is unambiguous, so the key plus this test is a sound
/// positional guard.
fn is_join_on_pairs(v: &Value) -> bool {
    v.as_array().is_some_and(|arr| {
        arr.iter()
            .all(|p| p.as_array().is_some_and(|p| p.len() == 2))
    })
}

/// Rewrite a join clause's `on` key columns under an index-set rename (esm-spec
/// §9.7.7 / §4.7 transitivity list).
///
/// An `on` name resolves as a LOOP SYMBOL, then the INDEX SET one of the node's
/// ranges draws `{from}`, then a DATA COLUMN (CONFORMANCE_SPEC §5.5.8). Only the
/// middle class is an axis occurrence, and a rename map is keyed by axis name,
/// so an entry follows the rename **iff** it is a key of `isetmap`. Anything else
/// — a loop symbol, a data-column name — is handed to `fallback` (the caller's
/// ordinary treatment for a bare string here: the §9.7.7 `varmap` fold, or
/// identity at a mount edge), so this rule only ever ADDS the axis case. The
/// `isetmap` test runs on the name AS SPELLED, before any fallback, so the two
/// maps cannot chain.
fn rename_join_on(
    v: &Value,
    isetmap: &IndexMap<String, String>,
    fallback: &dyn Fn(&str) -> String,
) -> Value {
    Value::Array(
        v.as_array()
            .map(|arr| {
                arr.iter()
                    .map(|pair| match pair.as_array() {
                        Some(p) => Value::Array(
                            p.iter()
                                .map(|e| match e.as_str() {
                                    Some(s) => Value::String(match isetmap.get(s) {
                                        Some(n) => n.clone(),
                                        None => fallback(s),
                                    }),
                                    None => e.clone(),
                                })
                                .collect(),
                        ),
                        None => pair.clone(),
                    })
                    .collect()
            })
            .unwrap_or_default(),
    )
}

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
                } else if RENAME_BOUND_KEYS.contains(&k.as_str())
                    && v.as_str().is_some_and(|s| isetmap.contains_key(s))
                {
                    let s = v.as_str().unwrap();
                    out.insert(k.clone(), Value::String(isetmap[s].clone()));
                } else if k == "name" && is_apply && v.is_string() {
                    let s = v.as_str().unwrap();
                    out.insert(
                        k.clone(),
                        Value::String(tplmap.get(s).cloned().unwrap_or_else(|| s.to_string())),
                    );
                } else if k == "where" && v.is_object() {
                    out.insert(k.clone(), rename_where(v, isetmap));
                } else if k == "on" && is_join_on_pairs(v) {
                    // A join clause's key columns (esm-spec §4.9.5). Only an
                    // entry that is a KEY of `isetmap` is an axis occurrence; a
                    // loop symbol or a data-column name keeps the varmap fold it
                    // had before this rule existed.
                    out.insert(
                        k.clone(),
                        rename_join_on(v, isetmap, &|s| {
                            varmap.get(s).cloned().unwrap_or_else(|| s.to_string())
                        }),
                    );
                } else if let Some(entries) = v
                    .as_object()
                    .filter(|_| NAME_KEYED_MAP_KEYS.contains(&k.as_str()))
                {
                    // A map keyed by author-chosen names (a `ranges` loop
                    // symbol, an apply-node `bindings` param): an entry name is
                    // a declared name, not a field, so it is never dispatched on
                    // (esm-spec §9.7.6 map-key rule). A `ranges` entry named
                    // `dim` still has its `from` renamed.
                    let walked = entries
                        .iter()
                        .map(|(name, entry)| {
                            (name.clone(), rename_walk(entry, varmap, isetmap, tplmap))
                        })
                        .collect();
                    out.insert(k.clone(), Value::Object(walked));
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

// ---------------------------------------------------------------------------
// Mount-edge index-set renaming (esm-spec §4.7 "Mount-edge index-set renaming")
// ---------------------------------------------------------------------------

/// One index-set substitution pass over a FULLY RESOLVED mounted document
/// (esm-spec §4.7 "Mount-edge index-set renaming", transitivity list).
///
/// Deliberately NOT [`rename_walk`]: that walk is written for template and
/// index-set DECLARATIONS, where `from` only ever occurs as a range reference
/// and every bare string is a variable-reference position. A mount carries a
/// whole component, where `from` also names a data source
/// (`Parameter.update.from`), a coupling endpoint (`variable_map.from`) and a
/// connector endpoint, and where `shape` lists, `Assertion.coords` keys and
/// `DataSourceSelectAxis.gated_by` name axes that no declaration walk ever sees.
/// So this walk touches ONLY positions that are index-set names by position,
/// and never rewrites a bare string on its own account — a name it does not
/// recognise is left exactly as spelled.
///
/// `index_sets` declarations are re-keyed by the caller
/// ([`apply_mount_index_set_rename`]); walking them here is harmless because no
/// `IndexSet` field is a position this walk rewrites.
fn mount_rename_walk(x: &mut Value, m: &IndexMap<String, String>) {
    match x {
        Value::Array(arr) => {
            for v in arr.iter_mut() {
                mount_rename_walk(v, m);
            }
        }
        Value::Object(obj) => {
            // An ExpressionNode is identified by its `op`; only there are
            // `wrt`/`dim`/`var`, the `integral` bounds and `ranges` axis
            // positions (esm-spec §4.2 / §4.3.1).
            let is_node = obj.get("op").is_some_and(Value::is_string);
            if is_node {
                for k in RENAME_AXIS_KEYS.iter().chain(RENAME_BOUND_KEYS.iter()) {
                    if let Some(Value::String(s)) = obj.get_mut(*k)
                        && let Some(n) = m.get(s.as_str())
                    {
                        *s = n.clone();
                    }
                }
                if let Some(Value::Object(ranges)) = obj.get_mut("ranges") {
                    for rv in ranges.values_mut() {
                        // `{ "from": <index set> }`; a range's own `of` is a
                        // list of BOUND SYMBOLS, never index-set names.
                        if let Some(Value::String(s)) = rv.get_mut("from")
                            && let Some(n) = m.get(s.as_str())
                        {
                            *s = n.clone();
                        }
                    }
                }
                // `join.<i>.on` key columns (§4.9.5): an entry follows the
                // rename iff it names a renamed index set; a loop symbol or a
                // data-column name is left as spelled. A clause's `syms` are
                // bound symbols, never axes.
                if let Some(Value::Array(join)) = obj.get_mut("join") {
                    for clause in join.iter_mut() {
                        let Some(on) = clause.get("on") else { continue };
                        if !is_join_on_pairs(on) {
                            continue;
                        }
                        let renamed = rename_join_on(on, m, &|s| s.to_string());
                        if let Some(c) = clause.as_object_mut() {
                            c.insert("on".to_string(), renamed);
                        }
                    }
                }
            } else if let Some(Value::Array(shape)) = obj.get_mut("shape") {
                // `ModelVariable`/`Parameter` `shape` and a `where` constraint's
                // `shape` are ordered index-set names; an ExpressionNode `shape`
                // (`reshape`'s target extents) and a `FunctionTable` `shape` are
                // integers, so the `is_node` guard plus the string test cover both.
                for e in shape.iter_mut() {
                    if let Value::String(s) = e
                        && let Some(n) = m.get(s.as_str())
                    {
                        *s = n.clone();
                    }
                }
            }
            // `DataSourceSelectAxis.gated_by` names a `kind: "derived"` set.
            if let Some(Value::String(s)) = obj.get_mut("gated_by")
                && let Some(n) = m.get(s.as_str())
            {
                *s = n.clone();
            }
            // `Assertion.coords` KEYS are spatial index-set names (§6.6.5).
            if let Some(Value::Object(coords)) = obj.get_mut("coords")
                && coords.keys().any(|k| m.contains_key(k))
            {
                let renamed: Map<String, Value> = coords
                    .iter()
                    .map(|(k, v)| (m.get(k).cloned().unwrap_or_else(|| k.clone()), v.clone()))
                    .collect();
                *coords = renamed;
            }
            for v in obj.values_mut() {
                mount_rename_walk(v, m);
            }
        }
        _ => {}
    }
}

/// Apply a mount edge's `index_set_rename` to a FULLY RESOLVED mounted
/// document, in place (esm-spec §4.7 "Mount-edge index-set renaming").
///
/// Runs at pipeline step 2: after the referenced document has resolved as a
/// complete document (its own imports, this edge's `bindings` and §9.7.10
/// injection, its metaparameter close and the §9.6.3 fixpoint) and BEFORE its
/// `index_sets` merge into the mounting registry — so the map's KEYS speak the
/// mounted document's own post-resolution vocabulary, exactly as §9.7.7's
/// `rename` speaks the import target's export vocabulary.
///
/// An absent, `null` or empty map is the identity and leaves `doc` untouched,
/// which is what makes the field purely additive.
///
/// `nested_contributed` names the index sets that reached `doc["index_sets"]`
/// through a mount NESTED INSIDE the referenced document, not through its own
/// declarations or its own `expression_template_imports`. They are excluded
/// from this edge's vocabulary: §4.7 says "step 2 covers what THIS referenced
/// document declares and imports, and an axis reaching the registry through a
/// mount *nested inside* the referenced document is renamed (or not) at that
/// nested edge, by its own `index_set_rename`". Naming one here is
/// `subsystem_index_set_rename_unknown_name`, exactly as it is in the four
/// other bindings — which never see the nested contribution at this point
/// because they resolve the leaf's nested `{ref}`s after the rename. This
/// binding resolves them before it (issue #311, so the §9.6.3 fixpoint can
/// reach them), so the exclusion has to be explicit.
pub(crate) fn apply_mount_index_set_rename(
    doc: &mut Value,
    edge: &Map<String, Value>,
    where_: &str,
    nested_contributed: &std::collections::BTreeSet<String>,
) -> Result<(), ExpressionTemplateError> {
    let raw = edge.get("index_set_rename");
    if raw.is_none_or(Value::is_null) {
        return Ok(());
    }
    let requested = name_map(raw, "index_set_rename", where_)?;

    let declared: Vec<String> = doc
        .get("index_sets")
        .and_then(|v| v.as_object())
        .map(|o| {
            o.keys()
                .filter(|k| !nested_contributed.contains(*k))
                .cloned()
                .collect()
        })
        .unwrap_or_default();

    // Renames never invent names (esm-spec §4.7, mirroring §9.7.7).
    for key in requested.keys() {
        if !declared.iter().any(|d| d == key) {
            return Err(err(
                codes::SUBSYSTEM_INDEX_SET_RENAME_UNKNOWN_NAME,
                format!(
                    "{where_}: `index_set_rename` names index set '{key}', which the resolved \
                     mounted document does not declare (it declares: {}). Keys speak the \
                     MOUNTED document's own post-resolution vocabulary (esm-spec §4.7 \
                     \"Mount-edge index-set renaming\")",
                    if declared.is_empty() {
                        "none".to_string()
                    } else {
                        declared.join(", ")
                    }
                ),
            ));
        }
    }

    // Identity entries are no-ops; everything else must land on a distinct name.
    let changed: IndexMap<String, String> = requested.into_iter().filter(|(o, n)| o != n).collect();
    if changed.is_empty() {
        return Ok(());
    }
    let mut finals: Vec<String> = Vec::with_capacity(declared.len());
    for name in &declared {
        let final_name = changed.get(name).cloned().unwrap_or_else(|| name.clone());
        if finals.contains(&final_name) {
            return Err(err(
                codes::TEMPLATE_IMPORT_RENAME_COLLISION,
                format!(
                    "{where_}: `index_set_rename` maps two index sets onto '{final_name}'; \
                     post-rename names must be distinct within one mount edge \
                     (esm-spec §4.7 / §9.7.7)"
                ),
            ));
        }
        finals.push(final_name);
    }

    mount_rename_walk(doc, &changed);

    // Re-key the registry last, preserving declaration order, and rewrite each
    // ragged/derived `of` parent list (an index-set-name list — unlike a
    // range's `of`, which the walk deliberately leaves alone).
    if let Some(Value::Object(sets)) = doc.get_mut("index_sets") {
        let mut renamed = Map::new();
        for (name, decl) in sets.iter() {
            let mut decl = decl.clone();
            if let Some(Value::Array(of)) = decl.get_mut("of") {
                for e in of.iter_mut() {
                    if let Value::String(s) = e
                        && let Some(n) = changed.get(s.as_str())
                    {
                        *s = n.clone();
                    }
                }
            }
            let final_name = changed.get(name).cloned().unwrap_or_else(|| name.clone());
            // A renamed axis may land on the name of an axis this edge does NOT
            // rename — one a mount nested inside the referenced document
            // contributed, which is in the registry here only because this
            // binding resolves nested refs before the rename (issue #311). Deep
            // equality is idempotent, a disagreement is the §4.7 merge rule's
            // own `subsystem_index_set_conflict`; the other bindings reach the
            // same two verdicts because the nested contribution arrives after
            // their rename and meets it in `merge_subsystem_index_sets`.
            if let Some(existing) = renamed.get(&final_name)
                && existing != &decl
            {
                return Err(err(
                    codes::SUBSYSTEM_INDEX_SET_CONFLICT,
                    format!(
                        "{where_}: `index_set_rename` maps index set '{name}' onto '{final_name}', \
                         which a mount nested inside the referenced document already contributes \
                         with a non-deep-equal declaration (esm-spec §4.7)"
                    ),
                ));
            }
            renamed.insert(final_name, decl);
        }
        *sets = renamed;
    }
    Ok(())
}

/// Bound index symbols (loop symbols) of a subtree: the `output_idx` entries and
/// `ranges` keys of every Expression node, at any nesting depth — the binder
/// definition of the `reserved_index_symbol` rule (esm-spec §4.9.1.1), which is
/// not limited to `faq` (`argmin` / `argmax` bind the same way). Rebinding one
/// would desynchronize the ranges KEYS from their `expr` occurrences, so it is
/// rejected; a metaparameter spelled like one is `metaparameter_name_conflict`.
/// Mirrors the Julia `_collect_bound_syms!`.
fn collect_bound_syms(x: &Value, out: &mut std::collections::HashSet<String>) {
    crate::json_visit::visit_values(x, &mut |_path, v| {
        let Some(obj) = v.as_object() else { return };
        if !obj.contains_key("op") {
            return;
        }
        if let Some(oi) = obj.get("output_idx").and_then(|w| w.as_array()) {
            for e in oi {
                if let Some(s) = e.as_str() {
                    out.insert(s.to_string());
                }
            }
        }
        if let Some(rg) = obj.get("ranges").and_then(|w| w.as_object()) {
            for k in rg.keys() {
                out.insert(k.clone());
            }
        }
    });
}

/// Every bare string in a variable-reference position of a declaration (the
/// positions `varmap` would rewrite), minus the per-template `params` shadow
/// set. Used for the rebind occurs-check and the freshness (collision) guard.
/// Mirrors the Julia `_collect_ref_names!`.
///
/// Hand-rolled rather than `crate::json_visit`: descent is key-dependent —
/// index-set/axis/`of`/protected object entries are skipped entirely, in
/// lockstep with [`rename_walk`]'s substitution positions.
fn collect_ref_names(
    x: &Value,
    shadowed: &std::collections::HashSet<String>,
    out: &mut std::collections::HashSet<String>,
) {
    match x {
        Value::String(s) if !shadowed.contains(s) => {
            out.insert(s.clone());
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
                // `rename_walk`'s name-keyed map rule: an entry name is never
                // pruned.
                match v.as_object() {
                    Some(entries) if NAME_KEYED_MAP_KEYS.contains(&k.as_str()) => {
                        for entry in entries.values() {
                            collect_ref_names(entry, shadowed, out);
                        }
                    }
                    _ => collect_ref_names(v, shadowed, out),
                }
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
                    codes::TEMPLATE_IMPORT_RENAME_INVALID,
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
                codes::TEMPLATE_IMPORT_RENAME_UNKNOWN_NAME,
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
                    codes::TEMPLATE_IMPORT_RENAME_COLLISION,
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
                codes::TEMPLATE_IMPORT_REBIND_UNKNOWN_NAME,
                format!(
                    "{where_}: `rebind` names '{k}', a declared name of the target (template / \
                     index set / metaparameter) — `rebind` addresses only free names; use \
                     `rename` for declared names (esm-spec §9.7.7)"
                ),
            ));
        }
        if inventory.bound.contains(k) {
            return Err(err(
                codes::TEMPLATE_IMPORT_RENAME_INVALID,
                format!(
                    "{where_}: `rebind` key '{k}' is a bound index symbol (`output_idx` / \
                     `ranges`) of an imported template, not a free name (esm-spec §9.7.7)"
                ),
            ));
        }
        if !inventory.free.contains(k) {
            return Err(err(
                codes::TEMPLATE_IMPORT_REBIND_UNKNOWN_NAME,
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
                codes::TEMPLATE_IMPORT_RENAME_COLLISION,
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
            codes::TEMPLATE_IMPORT_NAME_CONFLICT,
            "template",
            origin,
        )?;
    }
    for (n, d) in src.index_sets {
        merge_named(
            &mut dst.index_sets,
            &n,
            d,
            codes::TEMPLATE_IMPORT_INDEX_SET_CONFLICT,
            "index set",
            origin,
        )?;
    }
    for (n, d) in src.metaparams {
        merge_named(
            &mut dst.metaparams,
            &n,
            d,
            codes::TEMPLATE_IMPORT_NAME_CONFLICT,
            "metaparameter",
            origin,
        )?;
    }
    Ok(())
}

/// Per-edge metaparameter instantiation (esm-spec §9.7.6 binding site 1):
/// substitute the bound names throughout the exported templates and index
/// sets, then fold the structural sites that are now closed. A bound VALUE is
/// a metaparameter expression (usually an integer literal, but possibly a
/// symbolic `NX*NY` over the importer's still-open metaparameters); the folds
/// leave any site still carrying a free name symbolic for the importer's close
/// (esm-spec §9.7.6 binding value flow, site 1).
fn instantiate_scope(
    scope: &mut TemplateScope,
    values: &BTreeMap<String, Value>,
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
                // `PathBuf::pop` succeeds on a trailing `..`, so a naive
                // `if !out.pop()` wrongly collapses consecutive parent
                // segments (e.g. `../../x` → `x`). Only pop a real (normal)
                // tail; if `out` is empty or already ends in `..`, the `..`
                // escapes the base and must survive — this value is BOTH the
                // import-cycle key and the path read by `load_import_raw`.
                if matches!(out.components().next_back(), Some(Component::Normal(_))) {
                    out.pop();
                } else {
                    out.push("..");
                }
            }
            other => out.push(other.as_os_str()),
        }
    }
    out
}

fn canonical_ref(ref_str: &str, base_dir: &Path) -> String {
    // esm-spec §4.7: the cycle/cache key is built from the EXPANDED ref, so it
    // names the same file `load_import_raw` actually reads.
    let expanded = crate::ref_loading::expand_env_refs(ref_str);
    lexical_normalize(&base_dir.join(expanded.as_ref()))
        .to_string_lossy()
        .into_owned()
}

fn load_import_raw(
    ref_str: &str,
    base_dir: &Path,
    origin: &str,
) -> Result<(Value, PathBuf), ExpressionTemplateError> {
    // esm-spec §4.7: expand before classifying, so a variable holding a URL is
    // rejected as the remote ref it expands to rather than joined onto
    // `base_dir` as a path segment.
    let expanded = crate::ref_loading::expand_env_refs(ref_str);
    let ref_str: &str = &expanded;
    if ref_str.starts_with("http://") || ref_str.starts_with("https://") {
        return Err(err(
            codes::TEMPLATE_IMPORT_UNRESOLVED,
            format!(
                "{origin}: failed to load template-library ref '{ref_str}': remote refs are not \
                 fetched by the Rust loader; download the file and import it by local path"
            ),
        ));
    }
    let path = lexical_normalize(&base_dir.join(ref_str));
    let content = std::fs::read_to_string(&path).map_err(|e| {
        err(
            codes::TEMPLATE_IMPORT_UNRESOLVED,
            format!(
                "{origin}: template-library file not found or unreadable: {} (from ref \
                 '{ref_str}'): {e}",
                path.display()
            ),
        )
    })?;
    let mut raw: Value = serde_json::from_str(&content).map_err(|e| {
        err(
            codes::TEMPLATE_IMPORT_UNRESOLVED,
            format!(
                "{origin}: template-library ref '{}' is not valid JSON: {e}",
                path.display()
            ),
        )
    })?;
    // A template library is a document too, and its template BODIES carry
    // expression nodes — so it needs the same wire-boundary treatment as the
    // root (docs/content/rfcs/faq-node-rename.md §5.2).
    crate::parse::prepare_document_ops(&mut raw).map_err(|e| {
        err(
            codes::TEMPLATE_IMPORT_UNRESOLVED,
            format!("{origin}: {}: {e}", path.display()),
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
            codes::TEMPLATE_IMPORT_UNRESOLVED,
            format!(
                "{origin}: expression_template_imports entries must be objects with a `ref` field"
            ),
        ));
    };
    let ref_str = match entry_obj.get("ref").and_then(|v| v.as_str()) {
        Some(s) if !s.is_empty() => s,
        _ => {
            return Err(err(
                codes::TEMPLATE_IMPORT_UNRESOLVED,
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
            codes::TEMPLATE_IMPORT_CYCLE,
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

    // Library purity (esm-spec §9.7.1): the reference mechanisms are disjoint —
    // a coupling-library file (top-level `coupling_roles`) is imported via a
    // `coupling_import` coupling entry, not as a template library (esm-spec §10.9).
    if crate::coupling_imports::is_coupling_library_doc(&raw) {
        return Err(err(
            codes::TEMPLATE_IMPORT_IS_COUPLING_LIBRARY,
            format!(
                "{origin}: import target '{ref_str}' is a coupling-library file (has \
                 `coupling_roles`), not a template library (esm-spec §10.9)"
            ),
        ));
    }
    // Library purity (esm-spec §9.7.1): the two reference mechanisms are
    // disjoint — a component/subsystem file is not importable as a library.
    if !is_template_library_doc(&raw) {
        return Err(err(
            codes::TEMPLATE_IMPORT_NOT_LIBRARY,
            format!(
                "{origin}: import target '{ref_str}' lacks top-level `expression_templates` — \
                 not a template-library file (esm-spec §9.7.1)"
            ),
        ));
    }
    for k in LIBRARY_FORBIDDEN_KEYS {
        if raw.get(k).is_some() {
            return Err(err(
                codes::TEMPLATE_IMPORT_NOT_LIBRARY,
                format!(
                    "{origin}: import target '{ref_str}' declares `{k}` — not a pure \
                     template-library file (esm-spec §9.7.1)"
                ),
            ));
        }
    }
    if let Err(e) = crate::parse::validate_schema(&raw) {
        return Err(err(
            codes::TEMPLATE_IMPORT_UNRESOLVED,
            format!("{origin}: import target '{ref_str}' failed schema validation: {e}"),
        ));
    }

    stack.push(canonical);
    let result = process_library(&raw, &target_dir, stack, &format!("{origin} -> {ref_str}"));
    stack.pop();
    let mut scope = result?;

    // Edge metaparameter bindings (esm-spec §9.7.6 binding site 1). A binding
    // VALUE may be a metaparameter expression over the importer's metaparameters
    // (e.g. `NX*NY`); at an import edge the importer's names are not yet closed
    // (innermost-first), so the value is carried SYMBOLICALLY into the child and
    // folds when the importing document closes (§9.7.6 "Binding value flow").
    let mut values: BTreeMap<String, Value> = BTreeMap::new();
    if let Some(bindings) = entry_obj.get("bindings").and_then(|v| v.as_object()) {
        for (name, v) in bindings {
            if !scope.metaparams.contains_key(name) {
                return Err(err(
                    codes::TEMPLATE_IMPORT_UNKNOWN_NAME,
                    format!(
                        "{origin}: import of '{ref_str}' binds metaparameter '{name}', which \
                         the target neither declares nor re-exports (esm-spec §9.7.6)"
                    ),
                ));
            }
            values.insert(
                name.clone(),
                require_meta_expr(
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
                    codes::TEMPLATE_IMPORT_UNKNOWN_NAME,
                    format!(
                        "{origin}: `only` names template '{n}', which '{ref_str}' does not \
                         declare (esm-spec §9.7.2)"
                    ),
                ));
            }
        }
        let keep_set: std::collections::HashSet<&str> = keep.iter().map(String::as_str).collect();
        // esm-spec §9.7.2 / §9.6.4 rule 5 (Option B): `only` filters the
        // importer's EXPLICIT visibility, but the kept templates' bodies may
        // reference other "internal-wiring" templates that resolved in the
        // target's own scope (a BC rule referencing an interior stencil). With
        // bodies no longer inlined (§9.7.3), those referenced templates must be
        // carried along as the transitive reference closure, or the surviving
        // references would dangle. `only` is respected automatically —
        // materialization is by reference closure.
        let mut closure: std::collections::HashSet<String> = std::collections::HashSet::new();
        let mut wstack: Vec<String> = Vec::new();
        for n in &keep {
            if let Some(d) = scope.templates.get(n)
                && let Some(body) = d.get("body")
            {
                compose_collect_apply_names(body, &mut wstack);
            }
        }
        while let Some(r) = wstack.pop() {
            if keep_set.contains(r.as_str())
                || closure.contains(&r)
                || !scope.templates.contains_key(&r)
            {
                continue;
            }
            closure.insert(r.clone());
            if let Some(d) = scope.templates.get(&r)
                && let Some(body) = d.get("body")
            {
                compose_collect_apply_names(body, &mut wstack);
            }
        }
        let mut filtered = Map::new();
        for (n, d) in &scope.templates {
            if keep_set.contains(n.as_str()) || closure.contains(n) {
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
/// §9.7.3 body-reference validation — so a BC-layer body reference to an
/// imported interior stencil is checked here, while the referenced template is
/// still in scope, before any `only` filtering by a downstream importer.
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
    for (n, d) in own.iter_mut() {
        lower_library_template_enums(raw, n, d, origin)?;
    }
    for (n, d) in own {
        merge_named(
            &mut scope.templates,
            &n,
            d,
            codes::TEMPLATE_IMPORT_NAME_CONFLICT,
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
                codes::TEMPLATE_IMPORT_INDEX_SET_CONFLICT,
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
            codes::TEMPLATE_IMPORT_NAME_CONFLICT,
            "metaparameter",
            origin,
        )?;
    }

    // §9.7.3 body-reference validation in the library's own scope, before any
    // downstream `only` filtering can hide a referenced template.
    validate_template_body_references(&scope.templates, origin)?;
    let own_names: Vec<String> = raw
        .get("expression_templates")
        .and_then(|v| v.as_object())
        .map(|t| t.keys().cloned().collect())
        .unwrap_or_default();
    expand_library_enum_calls(raw, &mut scope.templates, &own_names, origin)?;
    // In the library's own scope, before an importing edge's `bindings`
    // instantiate the templates and consume the names it closes.
    check_metaparam_loop_symbols(scope.metaparams.keys(), origin, &[&scope.templates])?;
    Ok(scope)
}

/// Resolve the `enum` symbols a template library binds in its OWN calls
/// (esm-spec §9.3). After [`lower_library_template_enums`], the only `enum` ops
/// left in the library's scope are spelled with a template parameter. A call to
/// a template that can still produce one binds that parameter here, in the
/// library, so each of the library's own template bodies has those calls
/// expanded (the eager expansion esm-spec §9.6.4 rule 3 requires at load anyway)
/// and the result lowered against the library's block. An op the expansion
/// leaves spelled with the calling template's own parameter stays open for the
/// importer's binding. Runs after the body-reference DAG check, so expansion
/// terminates; every new body is computed before any is replaced.
fn expand_library_enum_calls(
    library: &Value,
    templates: &mut Map<String, Value>,
    own_names: &[String],
    origin: &str,
) -> Result<(), ExpressionTemplateError> {
    let expanded =
        crate::lower_expression_templates::expand_enum_bearing_calls(templates, own_names, origin)?;
    let mut decls = Vec::with_capacity(expanded.len());
    for (name, body) in expanded {
        let Some(decl) = templates.get(&name) else {
            continue;
        };
        let mut decl = decl.clone();
        decl["body"] = body;
        lower_library_template_enums(library, &name, &mut decl, origin)?;
        decls.push((name, decl));
    }
    for (name, decl) in decls {
        templates.insert(name, decl);
    }
    Ok(())
}

/// Lower the `enum` ops in one of a template library's OWN template bodies
/// against the library's `enums` block (esm-spec §9.3), before the template
/// reaches an importer whose block is a different one. An op spelled with one
/// of the template's `params` stays open and resolves at the call site.
fn lower_library_template_enums(
    library: &Value,
    name: &str,
    decl: &mut Value,
    origin: &str,
) -> Result<(), ExpressionTemplateError> {
    let params: HashSet<String> = decl
        .get("params")
        .and_then(|p| p.as_array())
        .map(|ps| {
            ps.iter()
                .filter_map(|p| p.as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default();
    let Some(body) = decl.get_mut("body") else {
        return Ok(());
    };
    crate::lower_enums::lower_enum_ops_for_file(library, body, &params).map_err(|e| {
        err(
            e.code,
            format!(
                "{origin}: template '{name}': {} — an `enum` op in a template library \
                 resolves against that library's own `enums` block (esm-spec §9.3)",
                e.message
            ),
        )
    })
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

/// The metaparameter names declared by every document `raw` MOUNTS, at either
/// §4.7 mount form, transitively through the mount DAG.
///
/// A §4.7 mount edge CONSUMES the referenced document's `metaparameters` AT the
/// edge (§9.7.6 binding site 3), so those names never join the mounting
/// document's own declared set — which is why a loader-API binding for one of
/// them used to be refused at a root that had no reason to redeclare it. This
/// walk is what lets the site-4 check (and the §8.9.4 `extent` check) ask "does
/// ANYONE in this assembly declare that name?" instead of "does the root".
///
/// Reads only each referenced file's top-level `metaparameters` KEYS. A ref that
/// cannot be read is IGNORED: this walk exists only to WIDEN acceptance, and the
/// resolution error belongs to the ref resolver, which reports it with the
/// proper mount pointer. Cycles terminate on the visited set of normalized
/// paths, so a mount DAG that revisits a file — or points back at itself — still
/// terminates.
///
/// Call it behind [`document_declares_an_extent`] / a non-empty loader-API map:
/// nothing else can be affected by the widening, and the guard keeps the
/// ordinary load from reading every mounted file a second time.
///
/// Mirrors the Python `collect_mount_declared_metaparameters`.
pub(crate) fn collect_mount_declared_metaparameters(
    raw: &Value,
    base_path: &Path,
) -> BTreeSet<String> {
    collect_declared_through_refs(raw, base_path, false)
}

/// [`collect_mount_declared_metaparameters`] plus the §9.7.2
/// `expression_template_imports` edges, at the document and the component
/// level, transitively.
///
/// A DIFFERENT question from the mount one, and only
/// [`check_data_source_extents`] asks it: a metaparameter an imported library
/// declares and the edge leaves unbound is RE-EXPORTED into this document's own
/// scope (§9.7.6 site 2), so the loader API may bind it here — which the site-4
/// check already allows, because by the time it runs the re-export has joined
/// the document's declared set. The static `extent` check runs on the AUTHORED
/// tree, before any of that, so it has to reach the same names by walking. It
/// must NOT widen the site-4 check itself: a name an import edge BINDS is
/// consumed rather than re-exported, and site 4 is right to refuse it.
pub(crate) fn collect_import_reachable_metaparameters(
    raw: &Value,
    base_path: &Path,
) -> BTreeSet<String> {
    collect_declared_through_refs(raw, base_path, true)
}

fn collect_declared_through_refs(
    raw: &Value,
    base_path: &Path,
    follow_imports: bool,
) -> BTreeSet<String> {
    let mut seen: HashSet<String> = HashSet::new();
    let mut out: BTreeSet<String> = BTreeSet::new();
    collect_mount_declared_into(raw, base_path, follow_imports, &mut seen, &mut out);
    out
}

fn collect_mount_declared_into(
    raw: &Value,
    base_path: &Path,
    follow_imports: bool,
    seen: &mut HashSet<String>,
    out: &mut BTreeSet<String>,
) {
    let Some(obj) = raw.as_object() else {
        return;
    };
    // A DOCUMENT-level `expression_template_imports`.
    visit_import_edges(obj, base_path, follow_imports, seen, out);
    for compkind in COMPONENT_KINDS {
        let Some(comps) = obj.get(compkind).and_then(|v| v.as_object()) else {
            continue;
        };
        for comp in comps.values() {
            let Some(cobj) = comp.as_object() else {
                continue;
            };
            // A top-level `models.<k>` / `reaction_systems.<k>` `{ref}` mount.
            visit_mount_ref(cobj, base_path, follow_imports, seen, out);
            visit_import_edges(cobj, base_path, follow_imports, seen, out);
            visit_subsystem_tree(cobj, base_path, follow_imports, seen, out);
        }
    }
}

/// A `subsystems` map to any depth: an INLINE entry may itself hold the
/// `{ref}` mount whose leaf declares the name.
fn visit_subsystem_tree(
    holder: &Map<String, Value>,
    base_path: &Path,
    follow_imports: bool,
    seen: &mut HashSet<String>,
    out: &mut BTreeSet<String>,
) {
    let Some(subs) = holder.get("subsystems").and_then(|v| v.as_object()) else {
        return;
    };
    for sub in subs.values() {
        let Some(sobj) = sub.as_object() else {
            continue;
        };
        visit_mount_ref(sobj, base_path, follow_imports, seen, out);
        visit_import_edges(sobj, base_path, follow_imports, seen, out);
        visit_subsystem_tree(sobj, base_path, follow_imports, seen, out);
    }
}

/// The §9.7.2 import edges one scope carries, when asked for.
fn visit_import_edges(
    holder: &Map<String, Value>,
    base_path: &Path,
    follow_imports: bool,
    seen: &mut HashSet<String>,
    out: &mut BTreeSet<String>,
) {
    if !follow_imports {
        return;
    }
    let Some(entries) = holder
        .get("expression_template_imports")
        .and_then(|v| v.as_array())
    else {
        return;
    };
    for entry in entries {
        if let Some(eobj) = entry.as_object() {
            visit_mount_ref(eobj, base_path, follow_imports, seen, out);
        }
    }
}

/// One mount edge of [`collect_mount_declared_into`]: read the referenced
/// document's declared metaparameter names, then recurse into ITS mounts.
fn visit_mount_ref(
    entry: &Map<String, Value>,
    base_path: &Path,
    follow_imports: bool,
    seen: &mut HashSet<String>,
    out: &mut BTreeSet<String>,
) {
    let Some(ref_str) = entry.get("ref").and_then(|v| v.as_str()) else {
        return;
    };
    // esm-spec §4.7 `${VAR}` expansion, before the remote classification below.
    let expanded = crate::ref_loading::expand_env_refs(ref_str);
    let ref_str: &str = &expanded;
    // Remote refs are not fetched by this crate (the subsystem-ref loader
    // rejects them outright); contributing nothing is the right widening.
    if ref_str.starts_with("http://") || ref_str.starts_with("https://") {
        return;
    }
    let path = lexical_normalize(&base_path.join(ref_str));
    if !seen.insert(path.to_string_lossy().into_owned()) {
        return;
    }
    let Ok(content) = std::fs::read_to_string(&path) else {
        return;
    };
    let Ok(child) = serde_json::from_str::<Value>(&content) else {
        return;
    };
    if let Some(decls) = child.get("metaparameters").and_then(|v| v.as_object()) {
        out.extend(decls.keys().cloned());
    }
    let child_dir = path
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_else(|| base_path.to_path_buf());
    collect_mount_declared_into(&child, &child_dir, follow_imports, seen, out);
}

/// Fold ONE §4.7 mount contribution's interval `size` against the MOUNTING
/// document's already-closed metaparameter environment, before the deep-equal
/// comparison that merges it (esm-spec §4.7 "Index-set merge").
///
/// This is the step that makes the merge order answerable. A §4.7 mount resolves
/// POST-CLOSE (§9.7.6 site 3: "the mounting document closes its own
/// metaparameters before its refs resolve"), so by the time a contribution
/// arrives the registry side has already folded to integers. Comparing an
/// unfolded contribution against a folded registry entry makes two IDENTICAL
/// declarations collide, which is issue #198; and leaving the contribution
/// unfolded publishes a resolved document whose axis still carries a
/// metaparameter name, which contradicts "the mounted form is fully concrete
/// when it splices in" and §9.7.6 site 5's "closed at some enclosing document's
/// close".
///
/// A `size` already an integer is returned unchanged. A `size` whose free names
/// are NOT all in `env` stays symbolic rather than erroring: the enclosing
/// document is not obliged to be able to close a name the assembly never
/// declared, and leaving it open preserves what loads today.
pub(crate) fn fold_mount_contribution(decl: &Value, env: &BTreeMap<String, i64>) -> Value {
    let Some(obj) = decl.as_object() else {
        return decl.clone();
    };
    let Some(size) = obj.get("size") else {
        return decl.clone();
    };
    if size.is_i64() || size.is_u64() || size.is_null() {
        return decl.clone();
    }
    let Ok(folded) = eval_meta_expr(size, env, "index set size") else {
        return decl.clone();
    };
    let mut out = obj.clone();
    out.insert("size".to_string(), Value::from(folded));
    Value::Object(out)
}

/// Whether any `data_sources` entry carries an `extent` (§8.9.4).
///
/// The cheap guard on [`collect_mount_declared_metaparameters`]: the widened
/// site-4 check and [`check_data_source_extents`] are that walk's only callers,
/// and neither can matter unless the load either carries loader-API bindings or
/// the document declares an `extent`. A document with neither pays no ref reads
/// for this at all, so the ordinary path is unchanged in behaviour AND in I/O.
pub(crate) fn document_declares_an_extent(raw: &Value) -> bool {
    raw.get("data_sources")
        .and_then(|v| v.as_object())
        .is_some_and(|sources| {
            sources
                .values()
                .any(|src| src.get("extent").is_some_and(Value::is_object))
        })
}

/// esm-spec §8.9.4: every `data_sources.<k>.extent.metaparameter` MUST name a
/// metaparameter THIS document declares, or one a document it mounts declares.
///
/// A discovered extent is a §9.7.6 site-4 loader-API binding, and "binding an
/// unknown name is an error" — but that error could only be raised once the
/// source had been SAMPLED, which happens at build. So an `extent` naming a
/// metaparameter nobody declares used to validate clean and fail only when the
/// file was finally read, with a diagnostic about the loader API rather than
/// about the typo. The condition is decidable from the document alone, so it is
/// decided at load: `template_import_unknown_name`, the code §9.7.6 already
/// gives an unknown name at a binding site. No new code — this IS that
/// condition, checked earlier.
pub(crate) fn check_data_source_extents(
    raw: &Value,
    base_path: &Path,
    mount_declared: &BTreeSet<String>,
) -> Result<(), ExpressionTemplateError> {
    let Some(sources) = raw.get("data_sources").and_then(|v| v.as_object()) else {
        return Ok(());
    };
    if document_is_in_resolved_shape(raw) {
        return Ok(());
    }
    let declared = collect_metaparam_decls(raw, "document")?;
    // Widened LAZILY, only for a name about to be refused: a metaparameter an
    // imported library declares and the edge leaves unbound is RE-EXPORTED into
    // this document's scope (§9.7.6 site 2) and is a perfectly good loader-API
    // binding target — but this check runs on the AUTHORED tree, before the
    // imports resolve, so it has to walk for it. A conforming document pays
    // nothing: the walk runs only on the path that would otherwise raise.
    let mut reachable: Option<BTreeSet<String>> = None;
    for (key, src) in sources {
        let Some(name) = src
            .get("extent")
            .and_then(|e| e.get("metaparameter"))
            .and_then(|v| v.as_str())
        else {
            continue;
        };
        if declared.contains_key(name) || mount_declared.contains(name) {
            continue;
        }
        let reachable = reachable
            .get_or_insert_with(|| collect_import_reachable_metaparameters(raw, base_path));
        if reachable.contains(name) {
            continue;
        }
        return Err(err(
            codes::TEMPLATE_IMPORT_UNKNOWN_NAME,
            format!(
                "data_sources.{key}.extent binds metaparameter '{name}', which neither this \
                 document nor any document it mounts declares (esm-spec §8.9.4, §9.7.6)"
            ),
        ));
    }
    Ok(())
}

/// Resolve every esm-spec §9.7 construct of the ROOT document `raw_data`
/// (relative import refs resolve against `base_path`): imports recursively
/// with per-edge instantiation, `index_sets` merge, metaparameter close
/// (`metaparameters` is the loader-API binding site 4; already-closed edge
/// bindings win, then API bindings, then defaults) and fold,
/// expression-position substitution, and — for a root library file — §9.7.3
/// body-reference validation.
///
/// Returns an order-preserving JSON tree ready for
/// [`crate::lower_expression_templates::lower_expression_templates`] with
/// `expression_template_imports` consumed, and the top-level
/// `expression_templates` / `metaparameters` DECLARATIONS restored verbatim from
/// a pre-folding snapshot (esm-spec §9.6.4 rule 5 — Option A expands call sites,
/// it does not delete declarations). `Ok(None)` when the document carries no
/// §9.7 machinery (the legacy fast path).
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
    resolve_template_machinery_scoped(raw_data, base_path, metaparameters, &BTreeSet::new(), false)
}

/// [`resolve_template_machinery`] plus the two §4.7 mount-scope facts the
/// 3-argument entry point cannot know.
///
/// `mount_declared` widens the §9.7.6 site-4 check to the names declared by the
/// documents this one MOUNTS — see [`collect_mount_declared_metaparameters`].
/// `mounted_leaf` says this call IS a §4.7 mount edge, so an index-set `size`
/// this scope cannot close stays symbolic for the MOUNTING registry to close
/// (§9.7.6 site 5) instead of being `metaparameter_unbound` here.
///
/// A sibling rather than a widened signature: API_SPEC.md §8 pins
/// `resolve_template_machinery` at `(&Value, &Path, &BTreeMap)` across the
/// bindings, and Rust has no keyword arguments to hang the Python form's
/// `mount_declared=` / `mounted_leaf=` on.
pub(crate) fn resolve_template_machinery_scoped(
    raw_data: &Value,
    base_path: &Path,
    metaparameters: &BTreeMap<String, i64>,
    mount_declared: &BTreeSet<String>,
    mounted_leaf: bool,
) -> Result<Option<Value>, ExpressionTemplateError> {
    if !has_import_machinery(raw_data) {
        // A binding naming something a MOUNTED document declares is meaningful
        // even here: this document has no §9.7 machinery of its OWN, and the
        // mount edge forwards the name into the leaf's close. Only a name no
        // document in the assembly declares is the typo this refuses.
        let unknown: Vec<&str> = metaparameters
            .keys()
            .filter(|k| !mount_declared.contains(*k))
            .map(String::as_str)
            .collect();
        if !unknown.is_empty() {
            return Err(err(
                codes::TEMPLATE_IMPORT_UNKNOWN_NAME,
                format!(
                    "loader API binds metaparameter(s) {} which neither this document nor any \
                     document it mounts declares (esm-spec §9.7.6)",
                    unknown.join(", ")
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

    // Snapshot the §9.7.1 DECLARATIONS exactly as authored, before any phase
    // below composes a body or folds a metaparameter into the working copies.
    // These are restored verbatim at the end — see esm-spec §9.6.4 rule 5 there.
    let original_templates = root.get("expression_templates").cloned();
    let original_metaparameters = root.get("metaparameters").cloned();

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
    let values = close_document_metaparams(&doc_meta, metaparameters, mount_declared)?;

    // --- §9.7.6 name-collision check: no shadowing of visible names ---
    check_metaparam_collisions(&root, &top_templates, &doc_meta, &doc_isets)?;

    // --- expression-position substitution of the closed values ---
    //
    // THIS document's own closed metaparameters and nothing else. An
    // `expression_template_imports[k].bindings` entry closes the metaparameters of
    // the IMPORTED document (§9.7.6 binding site 1) — the imported subtree is
    // instantiated with those values and the name is consumed there. It does NOT
    // enter the importing document's own scope: site 2 re-exports only the names
    // an edge leaves OPEN. So a bare name in the consumer's own expressions that
    // merely coincides with an edge binding is a free variable reference and MUST
    // stay symbolic (Julia, the reference binding, plus Go and TypeScript all
    // leave it symbolic). Folding it here would also bypass the §9.7.6
    // `metaparameter_name_conflict` no-shadowing check — a leaked binding could
    // silently replace a *declared* variable of the same name with an integer
    // literal. A consumer that genuinely wants to share a size with the library
    // declares its own `metaparameters` entry and passes it down as the edge
    // binding VALUE (`{"N": "NY"}`), which §9.7.6 resolves in the importing scope.
    substitute_closed_metaparams(&mut root, &mut top_templates, &mut doc_isets, &values);

    // --- fold structural sites on the closed document ---
    // `mounted_leaf` says a MOUNTING document's registry will receive these
    // index sets and close them (§4.7 "Index-set merge"), so an axis this scope
    // cannot size stays symbolic instead of being `metaparameter_unbound` here.
    // Without it, whether a mounted leaf accepted an assembler-scoped axis
    // turned on `has_import_machinery` — a WHOLE-DOCUMENT boolean — so adding an
    // `expression_template_imports` entry for a library the leaf never calls
    // changed whether the leaf's shape resolved.
    fold_closed_document(&mut root, &mut top_templates, &mut doc_isets, !mounted_leaf)?;

    // --- root library file: validate template-body references ---
    if is_library {
        validate_template_body_references(&top_templates, "document")?;
    }

    // esm-spec §9.6.4 rule 5: OPTION A EXPANDS CALL SITES; IT DOES NOT DELETE
    // DECLARATIONS.
    //
    // A top-level `expression_templates` registry and a top-level
    // `metaparameters` block (§9.7.1) are DECLARATIONS — peers of `index_sets` —
    // not `apply_expression_template` call sites. Both survive `parse → emit`
    // VERBATIM, and a template-library file MUST round-trip to itself.
    //
    // This code deleted them, reading "no §9.7 construct survives parse → emit"
    // as covering the declarations too. The consequence: a pure library file
    // emitted as `{esm, metadata, index_sets}` — carrying NONE of the five
    // top-level payload keys — which the schema's top-level `anyOf` rejects.
    // Combined with rule 4 (validation runs post-expansion), a conforming
    // template library was UNREPRESENTABLE: legal on disk, illegal the moment it
    // was loaded and re-emitted.
    //
    // The ORIGINALS are restored, not the working copies: `top_templates` has had
    // its bodies composed and its metaparameters substituted in place, and
    // emitting that would round-trip a library to a DIFFERENT (expanded) library.
    // Verbatim means verbatim.
    if let Some(templates) = original_templates {
        root.insert("expression_templates".to_string(), templates);
    }
    if let Some(metaparams) = original_metaparameters {
        root.insert("metaparameters".to_string(), metaparams);
    }

    // `expression_template_imports`, by contrast, IS a load-time construct
    // consumed by the fixpoint — an import directive, not a declaration — and
    // correctly does not survive (§9.7.6 round-trip).
    root.remove("expression_template_imports");
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
            codes::TEMPLATE_IMPORT_NAME_CONFLICT,
            "template",
            "document",
        )?;
    }
    for (n, d) in top_scope.index_sets {
        merge_named(
            doc_isets,
            &n,
            d,
            codes::TEMPLATE_IMPORT_INDEX_SET_CONFLICT,
            "index set",
            "document",
        )?;
    }
    for (n, d) in top_scope.metaparams {
        merge_named(
            doc_meta,
            &n,
            d,
            codes::TEMPLATE_IMPORT_NAME_CONFLICT,
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
                        codes::TEMPLATE_IMPORT_NAME_CONFLICT,
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
                    codes::TEMPLATE_IMPORT_INDEX_SET_CONFLICT,
                    "index set",
                    &corigin,
                )?;
            }
            for (n, d) in cscope.metaparams {
                merge_named(
                    doc_meta,
                    &n,
                    d,
                    codes::TEMPLATE_IMPORT_NAME_CONFLICT,
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
/// declaration defaults; a loader-API binding for a name NO document in the
/// assembly declares is `template_import_unknown_name`, and any name still open
/// afterwards is `metaparameter_unbound`. Returns the closed name → value map.
///
/// `mount_declared` is the set of metaparameter names declared by the documents
/// this one MOUNTS (§4.7, either mount form, transitively —
/// [`collect_mount_declared_metaparameters`]). A loader-API binding may name one
/// of those: it is meaningful even though THIS document does not declare it,
/// because the mount edge forwards it into the leaf's own close for the names
/// the leaf declares. Such a name is accepted and CONSUMED here — it closes
/// nothing in this scope, so it is absent from the returned map (which is built
/// from `doc_meta` alone). A name in NEITHER set is still a typo and still
/// raises `template_import_unknown_name`: bindings never invent metaparameters.
fn close_document_metaparams(
    doc_meta: &Map<String, Value>,
    metaparameters: &BTreeMap<String, i64>,
    mount_declared: &BTreeSet<String>,
) -> Result<BTreeMap<String, i64>, ExpressionTemplateError> {
    for k in metaparameters.keys() {
        if !doc_meta.contains_key(k) && !mount_declared.contains(k) {
            return Err(err(
                codes::TEMPLATE_IMPORT_UNKNOWN_NAME,
                format!(
                    "loader API binds metaparameter '{k}', which neither this document nor any \
                     document it mounts declares (esm-spec §9.7.6)"
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
            codes::METAPARAMETER_UNBOUND,
            format!(
                "metaparameter(s) {} still open after edge bindings, loader-API bindings, and \
                 defaults (esm-spec §9.7.6)",
                open_names.join(", ")
            ),
        ));
    }
    Ok(values)
}

/// The §9.7.6 name-collision check for loop symbols: a metaparameter name must
/// not spell a `ranges` key or `output_idx` entry of an Expression node anywhere
/// in `trees` (`metaparameter_name_conflict`). Substitution rewrites every bare
/// string that spells a bound metaparameter, and inside the node that binds it a
/// loop symbol is exactly such a string, so no field rule can tell the two apart.
fn check_metaparam_loop_symbols<'a>(
    names: impl IntoIterator<Item = &'a String>,
    origin: &str,
    trees: &[&Map<String, Value>],
) -> Result<(), ExpressionTemplateError> {
    let mut names = names.into_iter().peekable();
    if names.peek().is_none() {
        return Ok(());
    }
    let mut bound = std::collections::HashSet::new();
    for tree in trees {
        for v in tree.values() {
            collect_bound_syms(v, &mut bound);
        }
    }
    for name in names {
        if bound.contains(name) {
            return Err(err(
                codes::METAPARAMETER_NAME_CONFLICT,
                format!(
                    "{origin}: metaparameter '{name}' collides with a loop symbol \
                     (a `ranges` key or `output_idx` entry) (esm-spec §9.7.6)"
                ),
            ));
        }
    }
    Ok(())
}

/// Phase 4 of [`resolve_template_machinery`]: the §9.7.6 name-collision
/// check — a declared metaparameter must not shadow any visible variable /
/// parameter / species / index-set name, nor any loop symbol
/// (`metaparameter_name_conflict`).
fn check_metaparam_collisions(
    root: &Map<String, Value>,
    top_templates: &Map<String, Value>,
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
                codes::METAPARAMETER_NAME_CONFLICT,
                format!(
                    "metaparameter '{name}' collides with a visible \
                     variable/parameter/species/index-set name (esm-spec §9.7.6)"
                ),
            ));
        }
    }
    // Components carry their imported templates by now; `top_templates` is a
    // root library's effective top-level sequence, imports included.
    check_metaparam_loop_symbols(doc_meta.keys(), "document", &[root, top_templates])
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
    int_values: &BTreeMap<String, i64>,
) {
    if int_values.is_empty() {
        return;
    }
    // The closed metaparameters substitute as integer-literal VALUES (the
    // substitute helpers take a name → `Value` map so an import edge can splice
    // a symbolic expression; here every value is a concrete integer).
    let values: BTreeMap<String, Value> = int_values
        .iter()
        .map(|(k, v)| (k.clone(), Value::from(*v)))
        .collect();
    let values = &values;
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
                    let nv = substitute_metaparams_field(&k, v, values);
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
/// sites of the now-closed document — `faq` `ranges` / makearray `regions`
/// bounds in every component and top-level template
/// ([`fold_structural_sites`]), then the index-set `size` expressions.
///
/// `strict` says whether this document is the LAST scope that could close a
/// name. At a ROOT document it is, so a still-open `size` is
/// `metaparameter_unbound`. At a §4.7 mount edge it is NOT: the leaf resolves
/// in its own scope, but its `index_sets` then merge into the MOUNTING
/// document's registry (§4.7 "Index-set merge") and close there, so a name the
/// leaf cannot bind stays symbolic and travels up rather than failing here.
/// That is §9.7.6 site 5's "a metaparameter an edge leaves unbound … is closed
/// at some enclosing document's close", applied to the axis the name sizes.
fn fold_closed_document(
    root: &mut Map<String, Value>,
    top_templates: &mut Map<String, Value>,
    doc_isets: &mut Map<String, Value>,
    strict: bool,
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
    fold_index_set_sizes(doc_isets, "document", strict)
}

// ===================================================================
// Scope-directed template injection (esm-spec §9.7.10)
//
// The consuming surface — a §4.7 subsystem-ref edge (form A), a §10 coupling
// entry (form B), or a §6.6/§6.7 test/analysis (form C) — may register imports
// into a TARGET component's own scope without editing the leaf. Forms A/B are
// applied here, at the raw-Value level, BEFORE `resolve_template_machinery`:
// each widens the target component's `expression_template_imports` in the
// §9.7.10 merge order, so the ordinary import resolver + §9.6.3 fixpoint lower
// the target's rewrite-targets with no engine change. Form C is applied by the
// PDE test runner (`inline_tests.rs`) in a per-test ephemeral build.
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
    crate::json_visit::visit_values(x, &mut |_path, v| {
        if let Value::String(s) = v
            && let Some((head, _)) = s.split_once('.')
        {
            out.insert(head.to_string());
        }
    });
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
        .get("data_sources")
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
                    codes::TEMPLATE_INJECT_TARGET_NOT_COMPONENT,
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
                        codes::TEMPLATE_INJECT_TARGET_UNKNOWN,
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
                        codes::TEMPLATE_INJECT_TARGET_IS_LOADER,
                        format!(
                            "coupling entry `expression_template_imports` key '{target}' resolves \
                             to a data loader, which is pure I/O with no expression positions to \
                             rewrite (esm-spec §9.7.10 / §14)."
                        ),
                    ));
                } else {
                    return Err(err(
                        codes::TEMPLATE_INJECT_TARGET_NOT_COMPONENT,
                        format!(
                            "coupling entry `expression_template_imports` key '{target}' resolves \
                             to neither a top-level model, reaction system, nor data loader \
                             (esm-spec §9.7.10). Nested `Parent.Child` targets are out of scope."
                        ),
                    ));
                };
                let Some(imports_arr) = imports_val.as_array() else {
                    return Err(err(
                        codes::TEMPLATE_IMPORT_NOT_LIBRARY,
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

/// Whether `doc` is in the shape only a RESOLVED document has — no unresolved
/// §4.7 mount left, and at least one index set with every interval `size`
/// already a concrete integer.
///
/// [`check_data_source_extents`] is an AUTHORING check and must stay
/// idempotent. A §4.7 mount CONSUMES the leaf's `metaparameters` (§9.7.6 site
/// 3), so once a document has been resolved, a name only the leaf declared is
/// declared nowhere and the `{ref}` stub the mount walk reads is gone — while
/// the `extent` that named it is still there, having already done its job. A
/// binding that re-loads its own resolved document (this one does, at build,
/// and again at the typed parse that follows it) must not be told that document
/// is invalid. esm-spec §8.9.4 states the exemption normatively; the Python,
/// TypeScript, Julia and Go twins spell it the same way.
fn document_is_in_resolved_shape(doc: &Value) -> bool {
    !document_has_unresolved_mount(doc) && index_sets_are_fully_folded(doc)
}

/// Whether `doc` still carries an unresolved §4.7 mount — a `models.<k>` /
/// `reaction_systems.<k>` `{ref}`, or a `subsystems.<k>` `{ref}`.
fn document_has_unresolved_mount(doc: &Value) -> bool {
    let Some(obj) = doc.as_object() else {
        return false;
    };
    for kind in COMPONENT_KINDS {
        let Some(comps) = obj.get(kind).and_then(|v| v.as_object()) else {
            continue;
        };
        for comp in comps.values() {
            if comp.get("ref").is_some() {
                return true;
            }
            if let Some(subs) = comp.get("subsystems").and_then(|v| v.as_object())
                && subs.values().any(|s| s.get("ref").is_some())
            {
                return true;
            }
        }
    }
    false
}

/// Whether `doc` declares at least one index set and every interval `size` in
/// the registry is already a concrete integer — the state a document reaches
/// only after its metaparameters have closed and folded. Requiring at least one
/// entry keeps the vacuous case (a document with no `index_sets` at all, where
/// nothing has been folded) on the checked path.
fn index_sets_are_fully_folded(doc: &Value) -> bool {
    let Some(isets) = doc.get("index_sets").and_then(|v| v.as_object()) else {
        return false;
    };
    if isets.is_empty() {
        return false;
    }
    isets.values().all(|d| match d.get("size") {
        None => true,
        Some(v) => v.is_i64() || v.is_u64(),
    })
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
    fn lexical_normalize_preserves_consecutive_parent_components() {
        // `PathBuf::pop` succeeds on a trailing `..`, so a naive `if !out.pop()`
        // wrongly collapses consecutive parent segments. Because this value is
        // BOTH the import-cycle key and the path `load_import_raw` reads, every
        // `..` that cannot be cancelled must survive (esm-spec §9.7.2).
        assert_eq!(
            lexical_normalize(Path::new("../../x")),
            PathBuf::from("../../x")
        );
        // `a` cancels the first `..`; the second `..` then escapes the base.
        assert_eq!(
            lexical_normalize(Path::new("a/../../x")),
            PathBuf::from("../x")
        );
        assert_eq!(
            lexical_normalize(Path::new("./../x")),
            PathBuf::from("../x")
        );
        // The single-`..` case is unchanged.
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

    // -- metaparameter-EXPRESSION binding-value helpers (esm-spec §9.7.6) --
    // Mirrors pkg/earthsci-ast-py/tests/test_metaparam_expr_bindings.py §1.

    fn env(pairs: &[(&str, i64)]) -> BTreeMap<String, i64> {
        pairs.iter().map(|(k, v)| (k.to_string(), *v)).collect()
    }

    #[test]
    fn eval_meta_expr_folds_product() {
        // A `{op:*, args:[name, name]}` value folds against the closed env.
        assert_eq!(
            eval_meta_expr(
                &json!({"op": "*", "args": ["NX", "NY"]}),
                &env(&[("NX", 18), ("NY", 20)]),
                "t"
            )
            .unwrap(),
            360
        );
    }

    #[test]
    fn eval_meta_expr_name_and_literal() {
        assert_eq!(
            eval_meta_expr(&json!("NX"), &env(&[("NX", 7)]), "t").unwrap(),
            7
        );
        assert_eq!(eval_meta_expr(&json!(5), &env(&[]), "t").unwrap(), 5);
    }

    #[test]
    fn eval_meta_expr_nested_arithmetic() {
        // (NX + 2) * NY  with NX=4, NY=3  ->  18
        let expr = json!({"op": "*", "args": [{"op": "+", "args": ["NX", 2]}, "NY"]});
        assert_eq!(
            eval_meta_expr(&expr, &env(&[("NX", 4), ("NY", 3)]), "t").unwrap(),
            18
        );
    }

    #[test]
    fn require_meta_expr_returns_unfolded() {
        let expr = json!({"op": "*", "args": ["NX", "NY"]});
        assert_eq!(require_meta_expr(&expr, "t").unwrap(), expr); // unchanged, unfolded
    }

    #[test]
    fn meta_expr_helper_diagnostics() {
        // (expr, env, expected code) — require_meta_expr then eval_meta_expr,
        // first error wins, mirroring the Python parametrized helper test.
        let cases: Vec<(Value, BTreeMap<String, i64>, &str)> = vec![
            // Bad op is caught structurally at the edge, even with a symbolic arg.
            (
                json!({"op": "%", "args": ["NX", 2]}),
                env(&[]),
                "metaparameter_type_error",
            ),
            (
                json!({"op": "*", "args": []}),
                env(&[]),
                "metaparameter_type_error",
            ),
            (json!(1.5), env(&[]), "metaparameter_type_error"),
            // Unknown free name is caught at fold time.
            (
                json!({"op": "*", "args": ["NZ", "NY"]}),
                env(&[("NX", 18), ("NY", 20)]),
                "template_import_unknown_name",
            ),
            // Inexact division is rejected.
            (
                json!({"op": "/", "args": ["NX", 7]}),
                env(&[("NX", 18)]),
                "metaparameter_type_error",
            ),
        ];
        for (expr, e, code) in cases {
            let got = require_meta_expr(&expr, "t")
                .and_then(|_| eval_meta_expr(&expr, &e, "t").map(|_| ()))
                .unwrap_err();
            assert_eq!(got.code, code, "expr {expr}");
        }
    }

    /// The skip set and the name-keyed map set are derived from a classification
    /// of every string-capable schema property
    /// (`scripts/check-metaparameter-substitution-fields.py`); all five bindings
    /// compare against the same file.
    #[test]
    fn metaparameter_substitution_tables_match_shared_classification() {
        use std::collections::BTreeSet;
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/metaparameter_substitution/field_classification.json");
        let cls: Value = serde_json::from_str(
            &std::fs::read_to_string(&path).expect("read the classification file"),
        )
        .expect("parse the classification file");
        let listed = |key: &str| -> BTreeSet<String> {
            cls[key]
                .as_array()
                .unwrap_or_else(|| panic!("{key} is not an array"))
                .iter()
                .map(|v| v.as_str().expect("key names are strings").to_string())
                .collect()
        };
        let skipped: BTreeSet<String> = PROTECTED_KEYS
            .iter()
            .chain(RENAME_AXIS_KEYS.iter())
            .chain(NODE_HEADER_KEYS.iter())
            .chain(REGISTRY_KEYS.iter())
            .chain(OPAQUE_KEYS.iter())
            .map(|k| k.to_string())
            .collect();
        assert_eq!(skipped, listed("skip_keys"));
        for k in &skipped {
            assert!(is_meta_subst_skipped(k), "{k:?} is not skipped");
        }
        let maps: BTreeSet<String> = NAME_KEYED_MAP_KEYS.iter().map(|k| k.to_string()).collect();
        assert_eq!(maps, listed("name_keyed_map_keys"));
        // The substitution-only kind must not leak into the rename walk's
        // protected set: that set is derived from the kinds, not from the skip
        // predicate.
        for k in OPAQUE_KEYS {
            assert!(
                !is_rename_protected(k),
                "{k:?} leaked into is_rename_protected"
            );
        }
    }
}
