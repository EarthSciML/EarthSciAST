//! Rust adapter for the `compiled_rhs` conformance tier — in-process gate.
//!
//! The shipped manifest (`tests/conformance/compiled_rhs/manifest.json`) is
//! owned by the tier and driven by the Python runner. This test drives the
//! adapter's exact code path — [`earthsci_ast::compiled_rhs_adapter`], the
//! same entry points `src/bin/earthsci-compiled-rhs-adapter-rust.rs` calls —
//! against a crate-local manifest of the same schema, so a regression in the
//! adapter fails `cargo test` rather than waiting for the cross-language run.
//!
//! Every probe in that manifest carries an `analytic_rhs` anchor computed
//! WITHOUT any binding, and the assertions below compare against the anchor,
//! never against a recorded Rust output. That is what makes this a
//! correctness test and not a snapshot.

use std::path::PathBuf;

use earthsci_ast::compiled_rhs_adapter::{
    COMPILED_UNAVAILABLE_REASON, Engine, parse_args, run_manifest,
};
use serde_json::Value;

/// rtol for the anchor comparison. The tier's own `algebraic` class is 1e-13
/// and `transcendental` 1e-12; 1e-12 covers both.
const RTOL: f64 = 1e-12;

fn manifest_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/compiled_rhs/manifest.json")
}

fn manifest_json() -> Value {
    serde_json::from_str(&std::fs::read_to_string(manifest_path()).expect("read test manifest"))
        .expect("parse test manifest")
}

/// The interpreter engine reproduces every analytic anchor in the manifest.
///
/// This walks the manifest rather than hard-coding fixture ids, so adding a
/// fixture with an anchor extends the gate for free.
#[test]
fn interpreter_engine_matches_analytic_anchors() {
    let run = run_manifest(&manifest_path(), Engine::Interpreter).expect("adapter run");
    assert!(
        run.failed.is_empty(),
        "fixtures produced no numbers: {:?}",
        run.failed
    );
    let report = run.payload;
    assert_eq!(report["binding"], "rust");
    assert_eq!(report["engine"], "interpreter");

    let manifest = manifest_json();
    let fixtures = manifest["fixtures"].as_array().expect("fixtures");
    assert!(!fixtures.is_empty(), "test manifest has no fixtures");
    let mut checked = 0usize;

    for fx in fixtures {
        let id = fx["id"].as_str().expect("fixture id");
        let got_fx = &report["fixtures"][id];
        assert!(
            got_fx["error"].is_null(),
            "fixture {id} failed: {}",
            got_fx["error"]
        );
        // Every element of `state_order` must appear in every probe's output,
        // spelled exactly as the manifest spells it (bare column-major names).
        let order: Vec<&str> = fx["state_order"]
            .as_array()
            .expect("state_order")
            .iter()
            .map(|v| v.as_str().expect("state_order entry"))
            .collect();

        for probe in fx["rhs_probes"].as_array().expect("rhs_probes") {
            let pid = probe["id"].as_str().expect("probe id");
            let got = got_fx["rhs"][pid]
                .as_object()
                .unwrap_or_else(|| panic!("fixture {id} probe {pid}: no rhs in report"));
            assert_eq!(
                got.len(),
                order.len(),
                "fixture {id} probe {pid}: reported {} elements, state_order has {}",
                got.len(),
                order.len()
            );
            for name in &order {
                assert!(
                    got.contains_key(*name),
                    "fixture {id} probe {pid}: element {name:?} missing from the report; \
                     got {:?}",
                    got.keys().collect::<Vec<_>>()
                );
            }
            let want = probe["analytic_rhs"]
                .as_object()
                .unwrap_or_else(|| panic!("fixture {id} probe {pid}: no analytic_rhs anchor"));
            for (name, wv) in want {
                let want = wv.as_f64().expect("anchor value");
                let have = got[name].as_f64().unwrap_or_else(|| {
                    panic!("fixture {id} probe {pid}: element {name:?} is not a number")
                });
                let tol = RTOL * want.abs() + 1e-300;
                assert!(
                    (have - want).abs() <= tol,
                    "fixture {id} probe {pid} element {name}: got {have:e}, \
                     want {want:e} (|diff| {:e} > tol {tol:e})",
                    (have - want).abs()
                );
                checked += 1;
            }
        }
    }
    assert!(checked >= 20, "only {checked} elements compared");
}

/// `--engine compiled` answers with the contract's whole-output `unavailable`
/// form: no `fixtures` key, a `status` and a `reason` naming phase 2.
#[test]
fn compiled_engine_is_unavailable_in_phase_1() {
    let report = run_manifest(&manifest_path(), Engine::Compiled)
        .expect("adapter run")
        .payload;
    assert_eq!(report["binding"], "rust");
    assert_eq!(report["engine"], "compiled");
    assert_eq!(report["status"], "unavailable");
    assert_eq!(report["reason"], COMPILED_UNAVAILABLE_REASON);
    assert!(
        report.get("fixtures").is_none(),
        "the unavailable form is WHOLE-OUTPUT; it must not carry per-fixture results"
    );
    // The compiled engine must not even touch the manifest, so a missing one
    // is still an `unavailable` answer rather than an error.
    let absent = PathBuf::from("/nonexistent/compiled_rhs/manifest.json");
    assert_eq!(
        run_manifest(&absent, Engine::Compiled)
            .expect("unavailable without reading the manifest")
            .payload["status"],
        "unavailable"
    );
}

/// The CLI contract: both paths required, `--engine` optional and defaulting to
/// `interpreter`, anything else rejected.
#[test]
fn cli_argument_contract() {
    let argv = |s: &str| s.split_whitespace().map(String::from).collect::<Vec<_>>();

    let a = parse_args(argv("--manifest m.json --output o.json")).expect("defaults");
    assert_eq!(a.manifest, PathBuf::from("m.json"));
    assert_eq!(a.output, PathBuf::from("o.json"));
    assert_eq!(a.engine, Engine::Interpreter);

    let a = parse_args(argv("--manifest m.json --output o.json --engine compiled")).expect("ok");
    assert_eq!(a.engine, Engine::Compiled);
    assert_eq!(a.engine.as_str(), "compiled");

    assert!(parse_args(argv("--manifest m.json")).is_err());
    assert!(parse_args(argv("--output o.json")).is_err());
    assert!(parse_args(argv("--manifest m.json --output o.json --engine xla")).is_err());
    assert!(parse_args(argv("--manifest m.json --output o.json --bogus 1")).is_err());
}

/// Unknown manifest fields are ignored, not fatal: the runner is free to add
/// tier bookkeeping (tolerance classes, exclusions, golden pointers) without
/// every binding's adapter needing a release.
#[test]
fn unknown_manifest_fields_are_ignored() {
    let mut manifest = manifest_json();
    manifest["some_future_field"] = serde_json::json!({ "anything": [1, 2, 3] });
    for fx in manifest["fixtures"].as_array_mut().expect("fixtures") {
        fx["golden"] = serde_json::json!("golden/whatever.json");
        fx["future_per_fixture_field"] = serde_json::json!(true);
        for probe in fx["rhs_probes"].as_array_mut().expect("probes") {
            probe["future_probe_field"] = serde_json::json!("ignored");
        }
    }
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("manifest.json");
    // The manifest's fixture paths are relative to the repository's `tests/`
    // directory, and the temp dir has no such ancestor to walk up to — so
    // rewrite them absolute, which the resolver also accepts.
    let mut manifest = manifest;
    let repo_tests = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tests");
    for fx in manifest["fixtures"].as_array_mut().expect("fixtures") {
        let rel = fx["path"].as_str().expect("path").to_string();
        fx["path"] = serde_json::json!(repo_tests.join(&rel).to_string_lossy());
    }
    std::fs::write(&path, serde_json::to_string_pretty(&manifest).unwrap()).expect("write");

    let run = run_manifest(&path, Engine::Interpreter).expect("adapter run");
    assert!(run.failed.is_empty(), "fixtures failed: {:?}", run.failed);
    for fx in manifest["fixtures"].as_array().expect("fixtures") {
        let id = fx["id"].as_str().unwrap();
        assert!(
            run.payload["fixtures"][id]["error"].is_null(),
            "fixture {id}: {}",
            run.payload["fixtures"][id]["error"]
        );
    }
}

/// A RELATIVE `--manifest` resolves its fixtures just as an absolute one does.
///
/// This is a regression test, not a hypothetical: the fixture-path resolver
/// finds the repository's `tests/` directory by walking the manifest's
/// ancestors, and a relative path runs out of ancestors at its own first
/// segment. Every test above passes an absolute path (from `CARGO_MANIFEST_DIR`),
/// so they all passed while the binary — invoked as
/// `cargo run ... -- --manifest tests/fixtures/compiled_rhs/manifest.json`
/// from the crate directory, which is how a runner spells it — failed every
/// single fixture.
///
/// `cargo test` runs the test binary with the crate root as its working
/// directory, so this relative path is the same one that failed.
#[test]
fn relative_manifest_path_resolves_fixtures() {
    let rel = std::path::Path::new("tests/fixtures/compiled_rhs/manifest.json");
    assert!(
        rel.is_relative(),
        "this test is meaningless with an absolute path"
    );
    let run = run_manifest(rel, Engine::Interpreter).expect("adapter run");
    assert!(
        run.failed.is_empty(),
        "a relative --manifest must resolve its fixtures; failed: {:?}",
        run.failed
    );
    assert!(
        run.payload["fixtures"]["elementwise_gather"]["rhs"]["zeros"]["s"]
            .as_f64()
            .is_some(),
        "expected numbers, got {}",
        run.payload["fixtures"]["elementwise_gather"]
    );
}
