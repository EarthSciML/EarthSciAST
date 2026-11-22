//! Conformance tests for esm-spec §1.2.1: a document read from a path or URL
//! is read in the format its file extension names (`.md` Markdown, `.typ`
//! Typst, anything else JSON), at the root and at every ref site. Drives every
//! case of `tests/conformance/source_documents/manifest.json`.

use earthsci_ast::{flatten, load_path, to_json};
use serde_json::Value;

use crate::common;

/// Every string value of a `ref` key replaced by one placeholder: the authored
/// ref round-trips verbatim, so its spelling is the one expected difference.
fn mask_refs(v: &mut Value) {
    match v {
        Value::Object(map) => {
            for (k, child) in map.iter_mut() {
                if k == "ref" && child.is_string() {
                    *child = Value::String("<ref>".into());
                } else {
                    mask_refs(child);
                }
            }
        }
        Value::Array(items) => items.iter_mut().for_each(mask_refs),
        _ => {}
    }
}

fn loaded_doc(path: &std::path::Path) -> Value {
    let file = load_path(path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    let mut doc: Value = serde_json::from_str(&to_json(&file).expect("serialize")).unwrap();
    mask_refs(&mut doc);
    doc
}

#[test]
fn source_documents_manifest_cases() {
    let root = common::category_dir("source_documents");
    let manifest: Value =
        serde_json::from_str(&std::fs::read_to_string(root.join("manifest.json")).unwrap())
            .unwrap();
    let cases = manifest["cases"].as_array().expect("cases");
    assert!(!cases.is_empty());
    for case in cases {
        let id = case["id"].as_str().unwrap();
        let fixture = root.join(case["fixture"].as_str().unwrap());
        let driver = case["driver"].as_str().unwrap();
        match case["expect"].as_str().unwrap() {
            "same_as_twin" => {
                let twin = root.join(case["twin"].as_str().unwrap());
                assert_eq!(loaded_doc(&fixture), loaded_doc(&twin), "{id}");
            }
            "ok" => {
                let file = load_path(&fixture).unwrap_or_else(|e| panic!("{id}: load: {e}"));
                if driver == "flatten" {
                    flatten(&file).unwrap_or_else(|e| panic!("{id}: flatten: {e}"));
                }
            }
            "error" => {
                let code = case["code"].as_str().unwrap();
                let message = match load_path(&fixture) {
                    Err(e) => {
                        // A coded refusal carries the case's code itself, and
                        // a malformed source root is a source parse error,
                        // not a schema-stage one.
                        if let Some(got) = e.code() {
                            assert_eq!(got, code, "{id}: {e}");
                        }
                        if code == "parse_error" {
                            assert!(
                                matches!(e, earthsci_ast::EsmError::SourceParse { .. }),
                                "{id}: want EsmError::SourceParse, got {e:?}"
                            );
                        }
                        e.to_string()
                    }
                    Ok(file) => {
                        assert_eq!(driver, "flatten", "{id}: load must fail");
                        match flatten(&file) {
                            Err(e) => e.to_string(),
                            Ok(_) => panic!("{id}: flatten must fail with {code}"),
                        }
                    }
                };
                assert!(message.contains(code), "{id}: want {code}, got: {message}");
            }
            other => panic!("{id}: unknown expect {other}"),
        }
    }
}
