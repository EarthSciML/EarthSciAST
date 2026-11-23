//! esm-spec §9.3: an `enum` op in a mounted file resolves against THAT file's
//! `enums` block, at either §4.7 mount form, and `enums` do not merge across
//! the mount.
//!
//! Issue #260: two leaves declaring the same enum symbol with different values
//! were merged into one registry, first declaration winning, so the second
//! leaf silently computed with the first leaf's constant. The fixtures are
//! shared with the other four bindings (`tests/conformance/mount_enums/`).

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::{load_path, to_json};
use serde_json::Value;

use crate::common;

fn expected() -> Value {
    let text = std::fs::read_to_string(common::category_dir("mount_enums").join("expected.json"))
        .expect("expected.json");
    serde_json::from_str(&text).expect("expected.json parses")
}

/// The integer constant the single equation defining `path`'s variable lowers
/// to, where `path` is model, then subsystem keys, then the variable.
fn lowered_value(doc: &Value, path: &str) -> Value {
    let parts: Vec<&str> = path.split('.').collect();
    let (var, comps) = parts.split_last().expect("non-empty path");
    let mut node = &doc["models"][comps[0]];
    for sub in &comps[1..] {
        node = &node["subsystems"][*sub];
    }
    let eqs = node["equations"]
        .as_array()
        .unwrap_or_else(|| panic!("{path}: no equations in {node}"));
    let eq = eqs
        .iter()
        .find(|e| e["lhs"] == Value::String((*var).to_string()))
        .unwrap_or_else(|| panic!("{path}: no equation defines {var}"));
    eq["rhs"].clone()
}

#[test]
fn a_mounted_files_enum_ops_resolve_against_its_own_block() {
    let exp = expected();
    for (fixture, values) in exp["loads"].as_object().expect("loads") {
        let path = common::category_dir("mount_enums").join(fixture);
        let file = load_path(&path).unwrap_or_else(|e| panic!("{fixture} does not load: {e}"));
        // A mounted leaf's references survive (esm-spec §9.6.4 rule 1); the
        // constant each one denotes is read off the saved document through
        // the explicit expansion utility (rule 2).
        let mut doc: Value = serde_json::from_str(&to_json(&file).expect("serializes")).unwrap();
        earthsci_ast::extension::lower_expression_templates::expand(&mut doc)
            .unwrap_or_else(|e| panic!("{fixture}: expand: {e}"));
        for (var, want) in values.as_object().expect("values") {
            let rhs = lowered_value(&doc, var);
            let got = if rhs["op"] == "const" {
                rhs["value"].clone()
            } else {
                rhs.clone()
            };
            assert_eq!(
                got.as_i64(),
                want.as_i64(),
                "{fixture}: {var} lowers to {rhs}, expected the constant {want}"
            );
        }
    }
}

#[test]
fn an_assemblys_own_enum_op_does_not_see_a_leafs_block() {
    let exp = expected();
    for (fixture, code) in exp["errors"].as_object().expect("errors") {
        let code = code.as_str().expect("code");
        match load_path(common::category_dir("mount_enums").join(fixture)) {
            Ok(_) => panic!("{fixture} loaded; expected `{code}`"),
            Err(e) => {
                let msg = e.to_string();
                assert!(
                    msg.contains(code) && !msg.contains(&format!("{code}_symbol")),
                    "{fixture}: expected `{code}`, got: {msg}"
                );
            }
        }
    }
}
