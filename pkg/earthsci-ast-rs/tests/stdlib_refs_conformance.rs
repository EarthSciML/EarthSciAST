//! Conformance tests for esm-spec §4.7 standard-library refs:
//! `esm:std/<file>.esm` resolves to the crate's bundled copy of lib/
//! (`src/stdlib/`, compiled in with `include_str!`). Drives every case of
//! `tests/conformance/stdlib_refs/manifest.json`; the bundle-internal rules
//! (sibling imports, cycle identity) are unit tests in `src/stdlib.rs`.

use earthsci_ast::extension::lower_expression_templates::expand;
use earthsci_ast::{flatten, load_path, load_string, to_json};
use serde_json::Value;
use std::path::PathBuf;

fn stdlib_refs_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tests/conformance/stdlib_refs")
}

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

/// Run `f` with `env` set, restoring the previous values after. The variable
/// names are private to this tier, so no other test reads them concurrently.
fn with_env<T>(env: &[(String, String)], f: impl FnOnce() -> T) -> T {
    let old: Vec<(String, Option<String>)> = env
        .iter()
        .map(|(k, _)| (k.clone(), std::env::var(k).ok()))
        .collect();
    for (k, v) in env {
        // SAFETY: see the doc comment; these names are read only here.
        unsafe { std::env::set_var(k, v) };
    }
    let out = f();
    for (k, v) in old {
        match v {
            Some(v) => unsafe { std::env::set_var(&k, v) },
            None => unsafe { std::env::remove_var(&k) },
        }
    }
    out
}

#[test]
fn stdlib_refs_manifest_cases() {
    let root = stdlib_refs_dir();
    let manifest: Value =
        serde_json::from_str(&std::fs::read_to_string(root.join("manifest.json")).unwrap())
            .unwrap();
    let cases = manifest["cases"].as_array().expect("cases");
    assert!(!cases.is_empty());
    for case in cases {
        let id = case["id"].as_str().unwrap();
        let env: Vec<(String, String)> = case
            .get("env")
            .and_then(Value::as_object)
            .map(|m| {
                m.iter()
                    .map(|(k, v)| (k.clone(), v.as_str().unwrap().to_string()))
                    .collect()
            })
            .unwrap_or_default();
        let fixture = root.join(case["fixture"].as_str().unwrap());
        with_env(&env, || match case["expect"].as_str().unwrap() {
            "same_as_twin" => {
                let twin = root.join(case["twin"].as_str().unwrap());
                assert_eq!(loaded_doc(&fixture), loaded_doc(&twin), "{id}");
            }
            "error" => {
                let code = case["code"].as_str().unwrap();
                let message = match load_path(&fixture) {
                    Err(e) => e.to_string(),
                    Ok(file) => {
                        assert_eq!(case["driver"], "flatten", "{id}: load must fail");
                        match flatten(&file) {
                            Err(e) => e.to_string(),
                            Ok(_) => panic!("{id}: flatten must fail with {code}"),
                        }
                    }
                };
                assert!(message.contains(code), "{id}: want {code}, got: {message}");
            }
            other => panic!("{id}: unknown expect {other}"),
        });
    }
}

/// A document with no location of its own still reaches the bundle.
#[test]
fn a_document_loaded_from_a_string_imports_the_bundle() {
    let text = std::fs::read_to_string(stdlib_refs_dir().join("import_interp.esm")).unwrap();
    let file = load_string(&text).expect("loads with no base path");
    // The loaded form keeps template references (esm-spec §9.6.4 Option B);
    // expanding them shows the imported template resolved.
    let mut doc: Value = serde_json::from_str(&to_json(&file).unwrap()).unwrap();
    expand(&mut doc).expect("expand");
    let eqs = doc["models"]["M"]["equations"].to_string();
    assert!(
        !eqs.contains("apply_expression_template") && eqs.contains("faq"),
        "{eqs}"
    );
}

#[test]
fn bundle_names_the_repo_lib_files() {
    let mut names: Vec<String> = std::fs::read_dir(stdlib_refs_dir().join("../../../lib"))
        .unwrap()
        .filter_map(|e| e.ok())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| n.ends_with(".esm"))
        .collect();
    names.sort();
    assert_eq!(earthsci_ast::stdlib::bundled_names(), names);
}
