//! esm 2.4.0 "one operator type": the spellings an earlier document wrote,
//! read at the wire boundary (esm-spec §9.6.12 "Old names (no refusal)", §4.2
//! "Reading earlier documents"). Nothing is refused:
//!
//! - the field `expression_templates` is read as `operators` and
//!   `expression_template_imports` as `operator_imports` (warning
//!   `deprecated_field`), wherever a field of that name appears — never among
//!   the keys of a name-keyed map, whose keys are author-chosen names;
//! - the op `apply_expression_template` is read as `apply_operator`, and the
//!   spatial derivative — a `D` whose `wrt` is present and is not the literal
//!   `"t"`, and the spellings `δ` and `∂` — as `partial`, every other field
//!   kept (warning `deprecated_op`). A `D` whose `wrt` names one of the
//!   enclosing definition's `params` is left as written: it is decided per
//!   definition instance (esm-spec §9.6.4 rule 3).
//!
//! One warning per code per document, naming each site as
//! `<pointer> (<old spelling>)`. Idempotent: a second pass finds nothing.
//! Mirrors the Julia reference `_rewrite_old_spellings!`.

use serde_json::{Map, Value};

use crate::diagnostic::{DiagnosticError, codes, err};
use crate::json_visit::JsonPath;

/// Old field spelling → new.
const DEPRECATED_FIELDS: [(&str, &str); 2] = [
    ("expression_templates", "operators"),
    ("expression_template_imports", "operator_imports"),
];

/// The old op spelling of the reference node.
const OLD_APPLY_OP: &str = "apply_expression_template";

/// The other spellings of the spatial derivative.
const PARTIAL_SPELLINGS: [&str; 2] = ["δ", "∂"];

/// Objects whose keys are author-chosen names, not fields: a field spelling is
/// never renamed among them (a variable may be called `expression_templates`).
/// The metaparameter walk's name-keyed maps, plus the document's other
/// name-keyed registries.
const NAME_MAPS: [&str; 27] = [
    "variables",
    "species",
    "parameters",
    "guesses",
    "subsystems",
    "operators",
    "ranges",
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
    "url_substitutions",
    "where",
    "models",
    "reaction_systems",
    "data_sources",
    "index_sets",
    "enums",
    "metaparameters",
    "domains",
    "coupling_roles",
];

/// What one pass read: the sites of each kind, as `<pointer> (<old>)`.
#[derive(Default, Debug, PartialEq, Eq)]
pub(crate) struct OldSpellings {
    /// Field renames, in walk order.
    pub(crate) fields: Vec<String>,
    /// Op renames, in walk order.
    pub(crate) ops: Vec<String>,
    /// Models whose deprecated `initialization_equations` were rewritten
    /// (esm 2.5.0, [`crate::ic_migration`]).
    pub(crate) initialization: Vec<String>,
}

impl OldSpellings {
    /// The load warnings for these sites: `deprecated_field` then
    /// `deprecated_op`, each only when it has a site.
    pub(crate) fn warnings(&self) -> Vec<String> {
        let mut out = Vec::new();
        let mut parts = Vec::new();
        if !self.fields.is_empty() {
            parts.push(format!(
                "the fields `expression_templates` and `expression_template_imports` are read \
                 as `operators` and `operator_imports` (esm 2.4.0, esm-spec §9.6.12). Read at: \
                 {}.",
                self.fields.join(", ")
            ));
        }
        if !self.initialization.is_empty() {
            parts.push(format!(
                "`initialization_equations` is rewritten into `ic` equations in `equations`, \
                 or into `guesses` for a model with no time derivative (esm 2.5.0, esm-spec \
                 §11.4.4). Read at: {}.",
                self.initialization.join(", ")
            ));
        }
        if !parts.is_empty() {
            out.push(format!("deprecated_field: {}", parts.join(" ")));
        }
        if !self.ops.is_empty() {
            out.push(format!(
                "deprecated_op: `apply_expression_template` is read as `apply_operator`, and a \
                 spatial `D` (and `δ`, `∂`) as `partial` (esm 2.4.0, esm-spec §4.2, §9.6.12). \
                 Rewritten at: {}.",
                self.ops.join(", ")
            ));
        }
        out
    }
}

fn pointer_token(k: &str) -> String {
    k.replace('~', "~0").replace('/', "~1")
}

/// Rename the key `old` of `node` to `new`, keeping its position. Both
/// spellings in one object is `operator_invalid_definition`: there is nothing
/// to choose between silently.
fn rename_field(
    node: &mut Map<String, Value>,
    old: &str,
    new: &str,
    at: &str,
) -> Result<(), DiagnosticError> {
    if node.contains_key(new) {
        return Err(err(
            codes::OPERATOR_INVALID_DEFINITION,
            format!(
                "{at}: an object carries both `{old}` and its esm-2.4.0 spelling `{new}`; \
                 write only `{new}` (esm-spec §9.6.12)"
            ),
        ));
    }
    let entries = std::mem::take(node);
    for (k, v) in entries {
        if k == old {
            node.insert(new.to_string(), v);
        } else {
            node.insert(k, v);
        }
    }
    Ok(())
}

/// The string params of a definition entry, or `None`.
fn decl_params(decl: &Value) -> Option<std::collections::HashSet<String>> {
    let p = decl.get("params")?.as_array()?;
    Some(
        p.iter()
            .filter_map(|x| x.as_str().map(str::to_string))
            .collect(),
    )
}

fn walk(
    node: &mut Value,
    at: &JsonPath<'_>,
    namemap: bool,
    params: Option<&std::collections::HashSet<String>>,
    iv: Option<&str>,
    out: &mut OldSpellings,
) -> Result<(), DiagnosticError> {
    match node {
        Value::Object(map) => {
            if !namemap {
                for (old, new) in DEPRECATED_FIELDS {
                    if map.contains_key(old) {
                        let here = at.pointer();
                        let shown = if here.is_empty() { "/" } else { here.as_str() };
                        rename_field(map, old, new, shown)?;
                        out.fields
                            .push(format!("{here}/{} ({old})", pointer_token(new)));
                    }
                }
                if map.get("op").and_then(Value::as_str) == Some("ic") && params.is_none() {
                    crate::ic_migration::check_ic_node(map, &at.pointer())?;
                }
                let renamed = match map.get("op").and_then(Value::as_str) {
                    Some(OLD_APPLY_OP) => Some((
                        crate::lower_expression_templates::APPLY_OP_NAME,
                        OLD_APPLY_OP,
                    )),
                    Some(op) if PARTIAL_SPELLINGS.contains(&op) => Some((
                        "partial",
                        if op == PARTIAL_SPELLINGS[0] {
                            PARTIAL_SPELLINGS[0]
                        } else {
                            PARTIAL_SPELLINGS[1]
                        },
                    )),
                    Some("D")
                        if iv.is_some_and(|iv| {
                            map.get("wrt").and_then(Value::as_str) == Some(iv)
                                && !params.is_some_and(|p| p.contains(iv))
                        }) =>
                    {
                        // esm-spec §4.2 "The derivative axis": a `wrt` naming
                        // the document's renamed independent variable is the
                        // time derivative, read with the literal axis (no
                        // warning, not an old spelling).
                        map.insert("wrt".to_string(), Value::from("t"));
                        None
                    }
                    Some("D") => {
                        let spatial = match map.get("wrt") {
                            None | Some(Value::Null) => false,
                            Some(Value::String(w)) => {
                                w != "t" && !params.is_some_and(|p| p.contains(w))
                            }
                            Some(_) => true,
                        };
                        spatial.then_some(("partial", "D"))
                    }
                    _ => None,
                };
                if let Some((new_op, old_op)) = renamed {
                    map.insert("op".to_string(), Value::from(new_op));
                    out.ops.push(format!("{} ({old_op})", at.pointer()));
                }
            }
            for (k, v) in map.iter_mut() {
                if !matches!(v, Value::Object(_) | Value::Array(_)) {
                    continue;
                }
                let child = JsonPath::Key(at, k);
                if !namemap
                    && k == "operators"
                    && let Value::Object(defs) = v
                {
                    // A definition block: each entry's own params decide a
                    // `D` whose `wrt` names one of them.
                    for (dn, dv) in defs.iter_mut() {
                        if !matches!(dv, Value::Object(_) | Value::Array(_)) {
                            continue;
                        }
                        let p = decl_params(dv);
                        walk(dv, &JsonPath::Key(&child, dn), false, p.as_ref(), iv, out)?;
                    }
                    continue;
                }
                let nm = !namemap && NAME_MAPS.contains(&k.as_str());
                walk(v, &child, nm, params, iv, out)?;
            }
        }
        Value::Array(items) => {
            if crate::json_visit::is_number_data(items) {
                return Ok(());
            }
            for (i, v) in items.iter_mut().enumerate() {
                if matches!(v, Value::Object(_) | Value::Array(_)) {
                    walk(v, &JsonPath::Index(at, i), false, params, iv, out)?;
                }
            }
        }
        _ => {}
    }
    Ok(())
}

/// Read every old spelling of `doc` as its esm-2.4.0 name, in place, and
/// return the sites read (fields, then ops). See the module documentation.
pub(crate) fn rewrite_old_spellings(doc: &mut Value) -> Result<OldSpellings, DiagnosticError> {
    let mut out = OldSpellings::default();
    // The document's own renamed independent variable (`domain.
    // independent_variable` when declared and not "t"), esm-spec §4.2.
    let iv = doc
        .get("domain")
        .and_then(|d| d.get("independent_variable"))
        .and_then(Value::as_str)
        .filter(|iv| *iv != "t")
        .map(str::to_string);
    walk(
        doc,
        &JsonPath::Root(""),
        false,
        None,
        iv.as_deref(),
        &mut out,
    )?;
    out.initialization = crate::ic_migration::migrate_initialization_equations(doc)?;
    Ok(out)
}

/// [`rewrite_old_spellings`], printing its warnings: for entry points a caller
/// may reach without the load's wire boundary (template lowering, template
/// machinery). A document already read is left as it is, silently.
pub(crate) fn wire_old_spellings(doc: &mut Value) -> Result<(), DiagnosticError> {
    if !has_old_spellings(doc) {
        return Ok(());
    }
    for w in rewrite_old_spellings(doc)?.warnings() {
        eprintln!("warning: {w}");
    }
    Ok(())
}

/// `doc` read through its old spellings, without warnings, when it has any
/// (and they read without conflict): the document a schema check judges, as
/// the loader reads it before its schema check (`δ`, `∂` and the old field
/// names are not schema names).
pub(crate) fn read_silently(doc: &Value) -> Option<Value> {
    if !has_old_spellings(doc) {
        return None;
    }
    let mut read = doc.clone();
    rewrite_old_spellings(&mut read).ok()?;
    Some(read)
}

/// Whether `doc` spells anything an earlier document wrote (a cheap read-only
/// check; a `D` whose `wrt` names a definition param counts, so the rewrite
/// may then find nothing).
pub(crate) fn has_old_spellings(doc: &Value) -> bool {
    match doc {
        Value::Object(map) => {
            if map.keys().any(|k| {
                k == "expression_templates"
                    || k == "expression_template_imports"
                    || k == "initialization_equations"
            }) {
                return true;
            }
            if let Some(op) = map.get("op").and_then(Value::as_str) {
                if op == OLD_APPLY_OP || PARTIAL_SPELLINGS.contains(&op) {
                    return true;
                }
                if op == "D"
                    && !matches!(map.get("wrt"), None | Some(Value::Null))
                    && map.get("wrt").and_then(Value::as_str) != Some("t")
                {
                    return true;
                }
            }
            map.values().any(has_old_spellings)
        }
        Value::Array(items) => {
            !crate::json_visit::is_number_data(items) && items.iter().any(has_old_spellings)
        }
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn old_fields_and_ops_are_read_as_the_new_names() {
        let mut doc = json!({
            "esm": "2.3.0",
            "models": {"M": {
                "variables": {"expression_templates": {"type": "parameter"}},
                "expression_templates": {
                    "lap": {"params": ["f", "x"], "body": {"op": "D", "args": ["f"], "wrt": "x"}},
                    "grad_y": {"params": ["f"], "body": {"op": "D", "args": ["f"], "wrt": "y"}}
                },
                "expression_template_imports": [],
                "equations": [
                    {"lhs": {"op": "D", "args": ["u"], "wrt": "t"},
                     "rhs": {"op": "+", "args": [
                        {"op": "apply_expression_template", "args": [], "name": "lap",
                         "bindings": {"f": "u", "x": "x"}},
                        {"op": "δ", "args": ["u"], "wrt": "x"},
                        {"op": "D", "args": ["u"], "wrt": "x"}]}}
                ]
            }}
        });
        let got = rewrite_old_spellings(&mut doc).expect("no conflict");
        let m = &doc["models"]["M"];
        assert!(m["variables"].get("expression_templates").is_some());
        let keys: Vec<&String> = m.as_object().unwrap().keys().collect();
        assert_eq!(
            keys,
            ["variables", "operators", "operator_imports", "equations"]
        );
        assert_eq!(m["operators"]["lap"]["body"]["op"], "D");
        assert_eq!(m["operators"]["grad_y"]["body"]["op"], "partial");
        let rhs = &m["equations"][0]["rhs"]["args"];
        assert_eq!(rhs[0]["op"], "apply_operator");
        assert_eq!(rhs[1]["op"], "partial");
        assert_eq!(rhs[2]["op"], "partial");
        assert_eq!(m["equations"][0]["lhs"]["op"], "D");
        assert_eq!(
            got.fields,
            [
                "/models/M/operators (expression_templates)",
                "/models/M/operator_imports (expression_template_imports)"
            ]
        );
        assert_eq!(got.ops.len(), 4, "{:?}", got.ops);
        let w = got.warnings();
        assert!(w[0].starts_with("deprecated_field: "));
        assert!(w[1].starts_with("deprecated_op: "));
        // Idempotent.
        assert_eq!(
            rewrite_old_spellings(&mut doc).unwrap(),
            OldSpellings::default()
        );
    }

    /// The shared `old_names` fixtures (esm-spec §9.6.12): the document warns
    /// `deprecated_field` and `deprecated_op`, its old-spelled library
    /// `deprecated_field`, and the same document in the new spellings neither.
    #[test]
    fn the_old_names_fixtures_warn_as_their_golden_says() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/conformance/expression_templates/old_names");
        let codes = |f: &str| -> Vec<String> {
            let mut v: Value =
                serde_json::from_str(&std::fs::read_to_string(dir.join(f)).unwrap()).unwrap();
            rewrite_old_spellings(&mut v)
                .unwrap()
                .warnings()
                .iter()
                .map(|w| w.split(':').next().unwrap().to_string())
                .collect()
        };
        let want: Value =
            serde_json::from_str(&std::fs::read_to_string(dir.join("warnings.json")).unwrap())
                .unwrap();
        let want: Vec<String> = want["warnings"]
            .as_array()
            .unwrap()
            .iter()
            .map(|w| w.as_str().unwrap().to_string())
            .collect();
        assert_eq!(codes("fixture.esm"), want);
        assert_eq!(codes("lib_old.esm"), ["deprecated_field"]);
        assert!(codes("new_names.esm").is_empty());
        assert!(codes("lib_new.esm").is_empty());
    }

    /// esm-spec §4.2 "The derivative axis": a `D` along the document's renamed
    /// independent variable is the time derivative, read with `wrt: "t"` and
    /// no warning; along any other axis it is `partial`.
    #[test]
    fn a_wrt_naming_the_independent_variable_is_time() {
        let mut doc = json!({
            "domain": {"independent_variable": "tau"},
            "models": {"M": {"equations": [
                {"lhs": {"op": "D", "args": ["u"], "wrt": "tau"}, "rhs": 0},
                {"lhs": "v", "rhs": {"op": "D", "args": ["u"], "wrt": "x"}}
            ]}}
        });
        let got = rewrite_old_spellings(&mut doc).unwrap();
        let eqs = &doc["models"]["M"]["equations"];
        assert_eq!(eqs[0]["lhs"], json!({"op": "D", "args": ["u"], "wrt": "t"}));
        assert_eq!(eqs[1]["rhs"]["op"], "partial");
        assert_eq!(got.ops, ["/models/M/equations/1/rhs (D)"]);
    }

    #[test]
    fn both_spellings_in_one_object_is_an_error() {
        let mut doc = json!({"models": {"M": {"operators": {}, "expression_templates": {}}}});
        let e = rewrite_old_spellings(&mut doc).unwrap_err();
        assert_eq!(e.code, "operator_invalid_definition");
    }
}
