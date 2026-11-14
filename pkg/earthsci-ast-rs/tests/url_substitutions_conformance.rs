//! esm-spec §4.7 "Binding a data source's location at the mount"
//! (`url_substitutions`), through a real load, against the SHARED pin
//! `tests/conformance/url_substitutions/manifest.json` (`fixtures`). The edge
//! rule itself (`cases`) is pinned by the unit test in `src/data_source_urls.rs`.
//!
//! The ingestion tests, the reason the field exists (ONE shared catalogue,
//! mounted by two documents that bind it to two data directories, must read two
//! different tables through the `esm` binary's own ingest path, not just a
//! rewritten string), live with the binary, in
//! `cli/tests/cli/url_substitutions_conformance.rs`.

use serde_json::Value;
use std::path::{Path, PathBuf};

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .expect("the crate sits two levels under the repository root")
        .to_path_buf()
}

fn suite_dir() -> PathBuf {
    repo_root().join("tests/conformance/url_substitutions")
}

fn manifest() -> Value {
    let p = suite_dir().join("manifest.json");
    serde_json::from_str(&std::fs::read_to_string(&p).expect("read the shared manifest"))
        .expect("manifest.json is JSON")
}

/// Lexical dot-segment removal, so a `repo_path` pin compares with the
/// resolved (lexically normalized) URL.
fn normalize(p: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for c in p.components() {
        match c {
            std::path::Component::ParentDir => {
                out.pop();
            }
            std::path::Component::CurDir => {}
            other => out.push(other.as_os_str()),
        }
    }
    out
}

fn expected(pin: &Value) -> String {
    if let Some(v) = pin.get("verbatim").and_then(Value::as_str) {
        return v.to_string();
    }
    let rel = pin["repo_path"].as_str().expect("repo_path or verbatim");
    format!("file://{}", normalize(&repo_root().join(rel)).display())
}

#[test]
fn every_fixture_loads_or_is_refused_as_the_shared_manifest_says() {
    let m = manifest();
    let fixtures = m["fixtures"].as_array().expect("fixtures");
    assert!(!fixtures.is_empty());
    for f in fixtures {
        let id = f["id"].as_str().expect("id");
        let path = suite_dir().join(f["path"].as_str().expect("path"));
        let loaded = earthsci_ast::load_path(&path);
        match f["expect"].as_str().expect("expect") {
            "accepted" => {
                let doc = loaded.unwrap_or_else(|e| panic!("{id} must load: {e}"));
                let doc = serde_json::to_value(&doc).expect("serializable");
                for (axis, size) in f
                    .get("index_set_sizes")
                    .and_then(Value::as_object)
                    .into_iter()
                    .flatten()
                {
                    assert_eq!(
                        doc["index_sets"][axis]["size"], *size,
                        "{id}: index_sets.{axis}.size"
                    );
                }
                // A mounted document's `data_sources` merge into the mounting
                // document at either form, so the substituted locations are
                // observable here.
                let Some(pins) = f.get("hoisted_sources").and_then(Value::as_object) else {
                    continue;
                };
                for (name, pin) in pins {
                    let src = &doc["data_sources"][name]["source"];
                    assert_eq!(
                        src["url_template"],
                        Value::String(expected(&pin["url_template"])),
                        "{id}: data_sources.{name}.source.url_template"
                    );
                    if let Some(ms) = pin.get("mirrors").and_then(Value::as_array) {
                        let want: Vec<Value> =
                            ms.iter().map(|p| Value::String(expected(p))).collect();
                        assert_eq!(src["mirrors"], Value::Array(want), "{id}: mirrors");
                    }
                }
            }
            "refused" => {
                let e = loaded
                    .err()
                    .unwrap_or_else(|| panic!("{id} must be REFUSED at load"))
                    .to_string();
                let code = f["error_code"].as_str().expect("error_code");
                assert!(
                    earthsci_ast::ERROR_CODES.iter().any(|(_, v)| *v == code),
                    "{code} must be a registered code"
                );
                assert!(e.contains(code), "{id}: must carry [{code}]: {e}");
                for n in f["message_contains"].as_array().into_iter().flatten() {
                    let n = n.as_str().expect("str");
                    assert!(e.contains(n), "{id}: must name {n:?}: {e}");
                }
            }
            other => panic!("{id}: unknown expectation {other:?}"),
        }
    }
}

#[test]
fn the_edge_does_not_survive_parse_emit_and_the_emitted_form_is_a_fixed_point() {
    let path = suite_dir().join("mount_toplevel.esm");
    let first = earthsci_ast::load_path(&path).expect("loads");
    let emitted = earthsci_ast::to_json(&first).expect("emits");
    assert!(
        !emitted.contains("\"url_substitutions\":"),
        "the edge is consumed at load"
    );
    let tmp = tempfile::tempdir().expect("tempdir");
    let out = tmp.path().join("emitted.esm");
    std::fs::write(&out, &emitted).expect("write");
    let second = earthsci_ast::load_path(&out).expect("the emitted document loads");
    assert_eq!(
        serde_json::to_value(&first).expect("v")["data_sources"],
        serde_json::to_value(&second).expect("v")["data_sources"],
    );
}
