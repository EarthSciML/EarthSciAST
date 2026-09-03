//! esm-spec §8.2.1 data-source location resolution, against the SHARED pin.
//!
//! Reads `tests/conformance/data_source_url/manifest.json` — the one place the
//! expected resolution is written down — and asserts this binding against it.
//! Every binding's own suite reads the same file, so a path rule that differed
//! between bindings (which would silently make documents non-portable, the
//! defect §8.2.1 closes) fails here rather than downstream.
//!
//! Expectations are repo-relative paths, not literal URLs: the resolved form is
//! a machine-specific absolute `file://` URL and a golden holding one would
//! only pass on the machine that wrote it.

use serde_json::Value;
use std::path::{Path, PathBuf};

fn repo_root() -> PathBuf {
    // <repo>/pkg/earthsci-ast-rs/tests/this_file.rs
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .expect("the crate sits two levels under the repository root")
        .to_path_buf()
}

fn suite_dir() -> PathBuf {
    repo_root().join("tests/conformance/data_source_url")
}

fn manifest() -> Value {
    let p = suite_dir().join("manifest.json");
    serde_json::from_str(&std::fs::read_to_string(&p).unwrap_or_else(|e| {
        panic!("the shared pin {} must be readable: {e}", p.display())
    }))
    .expect("manifest.json is JSON")
}

fn fixture(m: &Value, id: &str) -> Value {
    m["fixtures"]
        .as_array()
        .expect("fixtures array")
        .iter()
        .find(|f| f["id"] == id)
        .unwrap_or_else(|| panic!("no fixture {id:?} in the shared manifest"))
        .clone()
}

/// One pinned expectation: a literal URL, or a path relative to the repo root.
fn expected(pin: &Value) -> String {
    if let Some(v) = pin.get("verbatim").and_then(Value::as_str) {
        return v.to_string();
    }
    let rel = pin["repo_path"].as_str().expect("repo_path or verbatim");
    format!("file://{}", repo_root().join(rel).display())
}

#[test]
fn every_pinned_form_resolves_as_the_shared_manifest_says() {
    let m = manifest();
    let f = fixture(&m, "relative_catalog");
    let path = suite_dir().join(f["path"].as_str().expect("path"));
    let doc = earthsci_ast::load_path(&path).expect("the catalog must load");
    let doc = serde_json::to_value(&doc).expect("serializable");

    for (name, pin) in f["sources"].as_object().expect("sources") {
        let src = &doc["data_sources"][name]["source"];
        assert_eq!(
            src["url_template"],
            Value::String(expected(&pin["url_template"])),
            "data_sources.{name}.source.url_template"
        );
        if let Some(mirrors) = pin.get("mirrors").and_then(Value::as_array) {
            let want: Vec<Value> = mirrors.iter().map(|p| Value::String(expected(p))).collect();
            assert_eq!(
                src["mirrors"],
                Value::Array(want),
                "data_sources.{name}.source.mirrors"
            );
        }
    }
}

#[test]
fn resolution_is_idempotent_so_parse_emit_parse_is_stable() {
    // Re-loaded from a DIFFERENT directory, so a template that had somehow
    // stayed relative would resolve somewhere else and be caught, rather than
    // resolving to the same place by accident.
    let m = manifest();
    let f = fixture(&m, "relative_catalog");
    let first = earthsci_ast::load_path(&suite_dir().join(f["path"].as_str().expect("path")))
        .expect("the catalog must load");
    let emitted = earthsci_ast::to_json(&first).expect("emits");

    let tmp = tempfile::tempdir().expect("tempdir");
    let out = tmp.path().join("emitted.esm");
    std::fs::write(&out, &emitted).expect("write");
    let second = earthsci_ast::load_path(&out).expect("the emitted catalog must load");

    assert_eq!(
        serde_json::to_value(&first).expect("v")["data_sources"],
        serde_json::to_value(&second).expect("v")["data_sources"],
        "a second resolution pass, from a different directory, must change nothing"
    );
}

#[test]
fn an_unresolvable_template_is_refused_by_a_diagnostic_that_names_it() {
    // Not merely "it does not resolve": the diagnostic has to NAME the entry
    // and the template. Treating `${MOVES_SNAPSHOTS}` as a directory name
    // yields an I/O error about a path nobody wrote, one step away from a
    // source that delivers a consuming parameter's default and compares
    // nothing.
    let m = manifest();
    for id in ["env_var_catalog", "env_var_mirror_catalog"] {
        let f = fixture(&m, id);
        let path = suite_dir().join(f["path"].as_str().expect("path"));
        let e = earthsci_ast::load_path(&path)
            .err()
            .unwrap_or_else(|| panic!("{id} must be REFUSED at load, not accepted"));
        let msg = e.to_string();

        let code = f["error_code"].as_str().expect("error_code");
        // `diagnostic` is pub(crate), so the code is read out of the PUBLIC
        // enumerable registry — which is also the thing the peer bindings'
        // registries are diffed against.
        let registered = earthsci_ast::ERROR_CODES
            .iter()
            .find(|(name, _)| *name == "DATA_SOURCE_URL_UNRESOLVED")
            .map(|(_, value)| *value);
        assert_eq!(
            Some(code),
            registered,
            "the manifest's code must be the one this binding registers"
        );
        assert!(
            msg.contains(code),
            "the diagnostic must carry [{code}]; got: {msg}"
        );
        for needle in f["message_contains"].as_array().expect("message_contains") {
            let needle = needle.as_str().expect("string");
            assert!(
                msg.contains(needle),
                "the diagnostic must name {needle:?}; got: {msg}"
            );
        }
    }
}
