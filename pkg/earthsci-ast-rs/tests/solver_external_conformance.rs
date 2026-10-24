//! esm-spec §2.2.6 `solver.external` resolution, against the SHARED pin.
//!
//! Reads `tests/conformance/solver_external/manifest.json` and asserts this
//! binding against it (CONFORMANCE_SPEC §5.47). Each fixture pins two things:
//! the authored string the typed document holds (and `emit` writes), and the
//! location [`earthsci_ast::solver_external_location`] returns. Expectations
//! are repo- or cwd-relative, never literal absolute paths, because a resolved
//! location is machine-specific.
//!
//! Nothing a fixture names exists on disk, and nothing here creates it: a
//! binding that reached for the target would fail rather than pass by luck.

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
    repo_root().join("tests/conformance/solver_external")
}

fn manifest() -> Value {
    let p = suite_dir().join("manifest.json");
    serde_json::from_str(
        &std::fs::read_to_string(&p)
            .unwrap_or_else(|e| panic!("the shared pin {} must be readable: {e}", p.display())),
    )
    .expect("manifest.json is JSON")
}

fn fixtures(m: &Value, expect: &str) -> Vec<Value> {
    m["fixtures"]
        .as_array()
        .expect("fixtures array")
        .iter()
        .filter(|f| f["expect"] == expect)
        .cloned()
        .collect()
}

/// RFC 3986 §5.2.4 on an absolute path, for the expected side: the pins state
/// their paths with dot segments already removed, but the repo root and the
/// working directory may carry them (`<crate>/../..`).
fn lexical(path: &Path) -> String {
    let mut parts: Vec<String> = Vec::new();
    for c in path.components() {
        match c {
            std::path::Component::Normal(s) => parts.push(s.to_string_lossy().into_owned()),
            std::path::Component::ParentDir => {
                parts.pop();
            }
            _ => {}
        }
    }
    format!("/{}", parts.join("/"))
}

/// The location a pin denotes, or `None` for a `null` pin.
fn expected_location(pin: &Value) -> Option<String> {
    if pin.is_null() {
        return None;
    }
    if let Some(v) = pin.get("verbatim").and_then(Value::as_str) {
        return Some(v.to_string());
    }
    if let Some(rel) = pin.get("repo_path").and_then(Value::as_str) {
        return Some(format!("file://{}", lexical(&repo_root().join(rel))));
    }
    let rel = pin["cwd_path"]
        .as_str()
        .expect("repo_path, cwd_path or verbatim");
    let cwd = std::env::current_dir().expect("working directory");
    Some(format!("file://{}", lexical(&cwd.join(rel))))
}

fn load(f: &Value) -> Result<earthsci_ast::EsmFile, earthsci_ast::EsmError> {
    let path = suite_dir().join(f["path"].as_str().expect("path"));
    match f["load"].as_str().expect("load") {
        "path" => earthsci_ast::load_path(&path),
        "string" => {
            let text = std::fs::read_to_string(&path).expect("fixture text");
            earthsci_ast::load_string(&text)
        }
        other => panic!("unknown load mode {other:?}"),
    }
}

#[test]
fn every_accepted_fixture_holds_resolves_and_emits_as_the_shared_manifest_says() {
    let m = manifest();
    let accepted = fixtures(&m, "accepted");
    assert!(!accepted.is_empty(), "the manifest pins accepted fixtures");
    for f in accepted {
        let id = f["id"].as_str().expect("id");
        let doc = load(&f).unwrap_or_else(|e| panic!("{id} must load: {e}"));

        let held = doc.solver.as_ref().and_then(|s| s.external.clone());
        assert_eq!(
            held.as_deref(),
            f["external"].as_str(),
            "{id}: the typed document's solver.external"
        );

        let base = f["base"].get("repo_path").and_then(Value::as_str);
        let base = base.map(|rel| repo_root().join(rel));
        let location = earthsci_ast::solver_external_location(&doc, base.as_deref())
            .unwrap_or_else(|e| panic!("{id}: the accessor must resolve: {e}"));
        assert_eq!(
            location,
            expected_location(&f["location"]),
            "{id}: solver_external_location"
        );

        let emitted: Value =
            serde_json::from_str(&earthsci_ast::to_json(&doc).expect("emits")).expect("JSON");
        let solver = emitted.get("solver").cloned().unwrap_or(Value::Null);
        assert_eq!(solver, f["solver"], "{id}: the emitted solver block");
    }
}

#[test]
fn a_dollar_brace_reference_is_refused_with_the_registered_code_naming_it() {
    let m = manifest();
    let refused = fixtures(&m, "refused");
    assert!(!refused.is_empty(), "the manifest pins refused fixtures");
    for f in refused {
        let id = f["id"].as_str().expect("id");
        let e = load(&f)
            .err()
            .unwrap_or_else(|| panic!("{id} must be REFUSED at load, not accepted"));
        let msg = e.to_string();

        let code = f["error_code"].as_str().expect("error_code");
        let registered = earthsci_ast::ERROR_CODES
            .iter()
            .find(|(name, _)| *name == "SOLVER_EXTERNAL_UNRESOLVED")
            .map(|(_, value)| *value);
        assert_eq!(
            Some(code),
            registered,
            "{id}: the manifest's code must be the one this binding registers"
        );
        assert!(
            msg.contains(&format!("[{code}]")),
            "{id}: the diagnostic must carry [{code}]; got: {msg}"
        );
        for needle in f["message_contains"].as_array().expect("message_contains") {
            let needle = needle.as_str().expect("string");
            assert!(
                msg.contains(needle),
                "{id}: the diagnostic must name {needle:?}; got: {msg}"
            );
        }
    }
}

#[test]
fn emitting_to_another_directory_keeps_the_authored_string_and_moves_the_location() {
    let m = manifest();
    let f = fixtures(&m, "accepted")
        .into_iter()
        .find(|f| f["id"] == "bare_relative")
        .expect("bare_relative is pinned");
    let first = load(&f).expect("loads");
    let emitted = earthsci_ast::to_json(&first).expect("emits");

    let tmp = tempfile::tempdir().expect("tempdir");
    let out = tmp.path().join("emitted.esm");
    std::fs::write(&out, &emitted).expect("write");
    let second = earthsci_ast::load_path(&out).expect("the emitted document must load");

    let authored = f["external"].as_str();
    assert_eq!(
        second.solver.as_ref().and_then(|s| s.external.as_deref()),
        authored,
        "the resolved location is never written back"
    );
    let moved = earthsci_ast::solver_external_location(&second, None)
        .expect("resolves")
        .expect("has a location");
    assert_eq!(
        moved,
        format!(
            "file://{}",
            lexical(&tmp.path().join(authored.expect("authored")))
        ),
        "the new directory changes the accessor's answer, not the document"
    );
}

#[test]
fn flatten_is_identical_with_and_without_external() {
    let m = manifest();
    let load_inv = |key: &str| {
        let rel = m["invariance"][key].as_str().expect("invariance path");
        earthsci_ast::load_path(suite_dir().join(rel))
            .unwrap_or_else(|e| panic!("invariance.{key} must load: {e}"))
    };
    let with = load_inv("with");
    let without = load_inv("without");
    assert!(
        with.solver
            .as_ref()
            .and_then(|s| s.external.as_ref())
            .is_some(),
        "the `with` fixture carries external"
    );
    assert!(
        without
            .solver
            .as_ref()
            .and_then(|s| s.external.as_ref())
            .is_none(),
        "the `without` fixture does not"
    );

    let flat = |doc: &earthsci_ast::EsmFile| {
        serde_json::to_value(earthsci_ast::flatten(doc).expect("flattens")).expect("serializes")
    };
    assert_eq!(
        flat(&with),
        flat(&without),
        "presence of solver.external must not change the flattened system"
    );
}

#[test]
fn the_version_gate_refuses_external_below_1_3_0_and_the_block_gate_runs_first() {
    let doc = |esm: &str, solver: Value| serde_json::json!({ "esm": esm, "solver": solver });
    let external = serde_json::json!({ "external": "x.run.json" });

    for esm in ["1.1.0", "1.2.0"] {
        let e = earthsci_ast::reject_solver_external_pre_v13(&doc(esm, external.clone()))
            .expect_err("external below 1.3.0 is refused");
        assert_eq!(e.code, "solver_external_version_too_old");
        assert!(e.message.contains("/solver/external"), "{}", e.message);
        earthsci_ast::reject_solver_external_pre_v13(&doc(
            esm,
            serde_json::json!({"reltol": 1e-6}),
        ))
        .unwrap_or_else(|e| panic!("a block without external stays valid at {esm}: {e}"));
    }
    earthsci_ast::reject_solver_external_pre_v13(&doc("1.3.0", external.clone()))
        .expect("1.3.0 admits external");

    // Below 1.1.0 the whole block is refused, under the older code.
    let text = serde_json::json!({
        "esm": "1.0.0",
        "metadata": {"name": "t"},
        "solver": external,
        "models": {"M": {"variables": {}, "equations": []}}
    })
    .to_string();
    let msg = earthsci_ast::load_string(&text)
        .expect_err("refused")
        .to_string();
    assert!(msg.contains("[solver_version_too_old]"), "{msg}");
}
