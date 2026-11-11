//! esm-spec §4.7 "Two mount forms, one mechanism": a top-level
//! `reaction_systems.<k>` `{ref}` mounts the referenced leaf's reaction system
//! under the key `<k>`, through the same edge pipeline as a top-level
//! `models.<k>` `{ref}`.
//!
//! The fixtures are shared with the other bindings
//! (`tests/conformance/toplevel_reaction_system_ref/`); all five bindings mount
//! the form.

#![cfg(not(target_arch = "wasm32"))]

use std::path::PathBuf;

use earthsci_ast::{load_path, to_json};
use serde_json::Value;

use crate::common;
use crate::mount_element_type::expected_load_error;

fn dir() -> PathBuf {
    common::repo_fixture("conformance/toplevel_reaction_system_ref")
}

fn expected() -> Value {
    let text = std::fs::read_to_string(dir().join("expected.json")).expect("expected.json");
    serde_json::from_str(&text).expect("expected.json parses")
}

/// The `models` and `reaction_systems` blocks of `fixture` after load and emit.
fn components(fixture: &str) -> (Value, Value) {
    let file = load_path(dir().join(fixture)).unwrap_or_else(|e| panic!("{fixture}: {e}"));
    let doc: Value =
        serde_json::from_str(&to_json(&file).expect("serializes")).expect("emits JSON");
    (
        doc.get("models").cloned().unwrap_or(Value::Null),
        doc.get("reaction_systems").cloned().unwrap_or(Value::Null),
    )
}

#[test]
fn a_mounted_reaction_system_loads_as_if_written_inline() {
    let exp = expected();
    assert!(
        exp["implemented_by"]
            .as_array()
            .expect("implemented_by")
            .iter()
            .any(|b| b == "rust"),
        "expected.json must list rust as implementing the form"
    );
    for (fixture, inline) in exp["loads"].as_object().expect("loads") {
        let inline = inline.as_str().expect("inline fixture name");
        let (got_models, got_rs) = components(fixture);
        let (want_models, want_rs) = components(inline);
        assert_eq!(got_rs, want_rs, "{fixture}: reaction_systems vs {inline}");
        assert_eq!(got_models, want_models, "{fixture}: models vs {inline}");
    }
}

#[test]
fn a_bad_reaction_system_mount_is_refused() {
    let exp = expected();
    for (fixture, want) in exp["load_errors"].as_object().expect("load_errors") {
        let code = expected_load_error(want, "rust");
        match load_path(dir().join(fixture)) {
            Ok(_) => panic!("{fixture} loaded; expected a refusal ({code:?})"),
            Err(e) => {
                if let Some(code) = code {
                    assert!(
                        e.to_string().contains(&code),
                        "{fixture}: expected `{code}`, got {e}"
                    );
                }
            }
        }
    }
}

/// Only a STRING `ref` makes a top-level entry a mount edge, at both forms, as
/// in the other bindings. `{ref: 5}` is not an edge: it is left to the schema,
/// which refuses it at the entry, rather than to the mount pipeline.
#[test]
fn a_non_string_ref_is_not_a_mount_edge() {
    for block in ["reaction_systems", "models"] {
        let doc = serde_json::json!({
            "esm": "2.0.0",
            "metadata": {"name": "non_string_ref"},
            block: {"Chem": {"ref": 5}},
        });
        let err = earthsci_ast::load_string(&doc.to_string())
            .expect_err("a non-string ref must be refused");
        let msg = err.to_string();
        assert!(
            !msg.contains("ref must be a string") && !msg.contains("unresolved_subsystem_ref"),
            "{block}: a non-string ref reached the mount pipeline: {msg}"
        );
        assert!(
            matches!(err, earthsci_ast::EsmError::SchemaValidation(_)),
            "{block}: expected a schema refusal, got {msg}"
        );
    }
}

/// The two top-level mount forms raise the same code for the same failure
/// (esm-spec §4.7 "Two mount forms, one mechanism"): at `models.<k>`, a leaf
/// with no model, several and no `model` selector, a selector naming a model
/// the leaf does not declare, and a missing file are each
/// `unresolved_subsystem_ref`, as at `reaction_systems.<k>`.
#[test]
fn a_bad_model_mount_raises_the_reaction_system_forms_code() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let write = |name: &str, doc: Value| {
        std::fs::write(tmp.path().join(name), doc.to_string()).expect("write");
    };
    write(
        "two_models.esm",
        serde_json::json!({
            "esm": "2.0.0",
            "metadata": {"name": "two_models"},
            "models": {
                "A": {"variables": {}, "equations": []},
                "B": {"variables": {}, "equations": []},
            },
        }),
    );
    std::fs::copy(dir().join("leaf.esm"), tmp.path().join("rs_leaf.esm")).expect("copy leaf");
    let cases = [
        ("no model", serde_json::json!({"ref": "./rs_leaf.esm"})),
        ("ambiguous", serde_json::json!({"ref": "./two_models.esm"})),
        (
            "unknown selector",
            serde_json::json!({"ref": "./two_models.esm", "model": "C"}),
        ),
        (
            "missing file",
            serde_json::json!({"ref": "./no_such_leaf.esm"}),
        ),
    ];
    for (case, entry) in cases {
        write(
            "mounter.esm",
            serde_json::json!({
                "esm": "2.0.0",
                "metadata": {"name": "mounter"},
                "models": {"M": entry},
            }),
        );
        let err = load_path(tmp.path().join("mounter.esm"))
            .expect_err("a bad models.<k> mount must be refused");
        assert!(
            err.to_string().contains("[unresolved_subsystem_ref]"),
            "{case}: expected unresolved_subsystem_ref, got {err}"
        );
    }
}
