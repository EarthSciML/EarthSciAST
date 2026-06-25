//! Cross-binding cadence-partition conformance (bead ess-my4.3.8).
//!
//! Drives the Rust partition pass ([`earthsci_toolkit::cadence`]) over the three
//! §6.1 fixtures and asserts it reproduces the golden in
//! `tests/conformance/cadence/manifest.json` — the same golden the Julia and
//! Python siblings assert against, so golden agreement *is* cross-binding
//! agreement (`CONFORMANCE_SPEC.md` §5.7.7). Mirrors the Python runner's
//! `compare_to_golden`: class summary, materialization-threshold multiset, and
//! byte-identical CONST-folded buffers.

use earthsci_toolkit::cadence::{compute_fold, model_with_loaders, partition_model};
use serde_json::{Value, json};
use std::path::PathBuf;

/// Repo root = the crate dir's grandparent (`packages/earthsci-toolkit-rs/../..`).
fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .expect("repo root resolves")
}

fn load_json(rel: &str) -> Value {
    let path = repo_root().join(rel);
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {path:?}: {e}"));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("parse {path:?}: {e}"))
}

fn sorted_thresholds(points: &Value) -> Vec<String> {
    let mut t: Vec<String> = points
        .as_array()
        .expect("materialization_points array")
        .iter()
        .map(|m| m["threshold"].as_str().expect("threshold").to_string())
        .collect();
    t.sort();
    t
}

#[test]
fn rust_partition_matches_golden() {
    let manifest = load_json("tests/conformance/cadence/manifest.json");
    let fixtures = manifest["fixtures"].as_array().expect("fixtures array");
    assert!(!fixtures.is_empty(), "manifest has fixtures");

    for fx in fixtures {
        let id = fx["id"].as_str().expect("fixture id");
        let rel = fx["fixture"].as_str().expect("fixture path");
        let model_name = fx["model"].as_str().expect("model name");

        let doc = load_json(rel);
        // Attach the document's `data_loaders` so loader-seeded discrete
        // variables resolve to DISCRETE (temporal) / CONST (no temporal), §5.7.2.
        let model = model_with_loaders(&doc["models"][model_name], &doc);
        let partition =
            partition_model(&model).unwrap_or_else(|e| panic!("[{id}] partition pass failed: {e}"));

        // (a) class summary — every annotated node's derived class.
        assert_eq!(
            partition.class_summary.to_json(),
            fx["class_summary"],
            "[{id}] class_summary"
        );

        // (b) materialization-point threshold multiset (the frontier cut).
        let got = {
            let pts: Vec<Value> = partition
                .materialization_points
                .iter()
                .map(|m| json!({ "threshold": m.threshold }))
                .collect();
            sorted_thresholds(&Value::Array(pts))
        };
        let want = sorted_thresholds(&fx["materialization_points"]);
        assert_eq!(got, want, "[{id}] materialization thresholds");

        // Three execution outputs: hot-tree / per-event-handler emptiness.
        if let Some(h) = fx.get("hot_tree_empty") {
            assert_eq!(
                Value::Bool(partition.hot_tree_empty),
                *h,
                "[{id}] hot_tree_empty"
            );
        }
        if let Some(h) = fx.get("event_handler_empty") {
            assert_eq!(
                Value::Bool(partition.event_handler_empty),
                *h,
                "[{id}] event_handler_empty"
            );
        }

        // (c) CONST-folded buffers serialise byte-for-byte to the golden.
        if let Some(cf) = fx.get("const_fold") {
            let inputs = cf.get("inputs").cloned().unwrap_or_else(|| json!({}));
            if let Some(expected) = cf.get("expected").and_then(|v| v.as_object()) {
                for (label, spec) in expected {
                    let got = compute_fold(label, spec, &inputs)
                        .unwrap_or_else(|e| panic!("[{id}] fold {label}: {e}"));
                    assert_eq!(
                        got,
                        spec["serialized"].as_str().expect("golden serialized"),
                        "[{id}] CONST-fold buffer {label:?}"
                    );
                }
            }
        }
    }
}

/// The shared invalid fixture: a relational/value-invention node whose Skolem key
/// reads a `state` variable classifies CONTINUOUS, so the partition pass MUST
/// reject it (§5.7.6 guard 2 — no relational engine on the hot path). The same
/// schema-valid fixture is accepted by the schema-only bindings (Go / TS) and
/// rejected here, in Julia, and in Python (tests/invalid/expected_errors.json
/// marks it `resolver_only`). Bead ess-my4.3.11.
#[test]
fn rust_rejects_continuous_relational_fixture() {
    let doc = load_json("tests/invalid/aggregate/continuous_relational_node.esm");
    let model = &doc["models"]["ContinuousRelationalNode"];
    let err = partition_model(model)
        .expect_err("a CONTINUOUS-classified relational node must be rejected (guard 2)");
    let msg = err.to_string();
    assert!(
        msg.contains("CONTINUOUS"),
        "rejection should name the CONTINUOUS class, got: {msg}"
    );
}
