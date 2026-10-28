//! esm-spec §9.2 / §9.5.5, ruling Q-106: the closed-function argument checks
//! and the function-table checks run at LOAD and in `validate()`, on every
//! `interp.*` `fn` node wherever it appears and on every `function_tables`
//! entry whether or not a lookup references it.
//!
//! The fixtures are the schema-valid documents `tests/invalid/closed_fn_*.esm`
//! and `tests/invalid/function_table_*.esm`, pinned `resolver_only` with a
//! `resolver_error_code` in `tests/invalid/expected_errors.json` — the
//! `enum_duplicate_value.esm` convention (see `lower_enums_integration.rs`).

use earthsci_ast::{EsmFile, load_path, validate, validate_text};
use serde_json::Value;

mod common;

/// Every `closed_fn_*` / `function_table_*` fixture is refused at load with
/// exactly its pinned code, `validate_text` reports it invalid, and the typed
/// `validate()` — run on the document deserialized WITHOUT load, as one built
/// in memory would be — reports the same code.
#[test]
fn closed_function_and_table_fixtures_are_refused_at_load_with_the_pinned_code() {
    let dir = common::repo_fixture("invalid");
    let pins: Value = serde_json::from_str(
        &std::fs::read_to_string(dir.join("expected_errors.json")).expect("read pins"),
    )
    .expect("parse expected_errors.json");

    let mut names: Vec<String> = std::fs::read_dir(&dir)
        .expect("read tests/invalid")
        .filter_map(|e| e.ok()?.file_name().into_string().ok())
        .filter(|n| {
            n.ends_with(".esm") && (n.starts_with("closed_fn_") || n.starts_with("function_table_"))
        })
        .collect();
    names.sort();
    assert!(
        names.len() >= 30,
        "expected the 30 fixtures, found {names:?}"
    );

    for name in &names {
        let pin = &pins[name.as_str()];
        assert_eq!(pin["resolver_only"], true, "{name}: pin");
        assert_eq!(pin["is_valid"], false, "{name}: pin");
        let code = pin["resolver_error_code"]
            .as_str()
            .unwrap_or_else(|| panic!("{name}: no resolver_error_code"));
        let path = dir.join(name);

        let msg = load_path(&path)
            .expect_err(&format!("{name}: must be refused at load"))
            .to_string();
        assert!(msg.contains(&format!("[{code}]")), "{name}: got: {msg}");

        let text = std::fs::read_to_string(&path).expect("read fixture");
        let result = validate_text(&text, Some(&dir));
        assert!(
            !result.is_valid,
            "{name}: validate_text must report invalid"
        );

        let typed: EsmFile = serde_json::from_str(&text).expect("deserializes without load");
        // The first of its load-check findings: every table is checked before
        // any expression node (ruling Q-113).
        let codes: Vec<String> = validate(&typed)
            .structural_errors
            .iter()
            .map(|e| e.code.to_string())
            .filter(|c| {
                ["interp_", "searchsorted_", "table_", "closed_function_"]
                    .iter()
                    .any(|p| c.starts_with(p))
            })
            .collect();
        assert_eq!(
            codes.first().map(String::as_str),
            Some(code),
            "{name}: validate() must report {code} first; got {codes:?}"
        );
    }
}

/// A `fn` node inside an expression-template BODY is checked where the
/// template is applied, on the arguments the application gives it — not in
/// the body, where the table is a template parameter (esm-spec §9.2).
#[test]
fn a_template_body_is_checked_at_its_application() {
    let doc = |axis: &str| {
        format!(
            r#"{{
          "esm": "1.0.0",
          "metadata": {{ "name": "tpl", "authors": ["test"] }},
          "models": {{ "M": {{
            "expression_templates": {{
              "lookup": {{
                "params": ["ax", "q"],
                "body": {{ "op": "fn", "name": "interp.linear",
                           "args": [{{"op": "const", "args": [], "value": [1.0, 2.0]}}, "ax", "q"] }}
              }}
            }},
            "variables": {{
              "y": {{"type": "unknown", "default": 0.0}},
              "p": {{"type": "parameter", "default": 0.5}}
            }},
            "equations": [{{
              "lhs": {{"op": "D", "args": ["y"], "wrt": "t"}},
              "rhs": {{ "op": "apply_expression_template", "args": [], "name": "lookup",
                        "bindings": {{ "ax": {{"op": "const", "args": [], "value": {axis}}}, "q": "p" }} }}
            }}]
          }} }}
        }}"#
        )
    };
    earthsci_ast::load_string(&doc("[0.0, 1.0]"))
        .unwrap_or_else(|e| panic!("a well-formed application must load: {e}"));
    let msg = earthsci_ast::load_string(&doc("[1.0, 0.0]"))
        .expect_err("a decreasing axis given by the application must be refused")
        .to_string();
    assert!(msg.contains("[interp_non_monotonic_axis]"), "got: {msg}");
}
