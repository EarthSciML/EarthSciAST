//! esm-spec §4.7 "Two mount forms, one mechanism": a top-level
//! `reaction_systems.<k>` `{ref}` mounts the referenced leaf's reaction system
//! under the key `<k>`, through the same edge pipeline as a top-level
//! `models.<k>` `{ref}`.
//!
//! The fixtures are shared with the other bindings
//! (`tests/conformance/toplevel_reaction_system_ref/`). Julia and Rust mount the
//! form; Python, TypeScript and Go refuse it with `mount_form_unsupported`.

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
