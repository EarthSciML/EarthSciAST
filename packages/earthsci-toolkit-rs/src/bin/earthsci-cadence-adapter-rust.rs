//! `earthsci-cadence-adapter-rust` — the Rust producer for the cross-binding
//! cadence-partition conformance harness (`scripts/run-cadence-conformance.py`,
//! bead ess-my4.3.8).
//!
//! Thin by design (the contract lives in [`earthsci_toolkit::cadence`], not
//! here): load the manifest, run the real partition pass over each fixture's
//! ESM model, and write — per fixture — the class summary, the
//! materialization-point threshold set, and the CONST-folded buffers. The
//! runner compares these to the golden and to the other bindings.
//!
//! Invoked as `earthsci-cadence-adapter-rust --manifest <m.json> --output <r.json>`.

use earthsci_toolkit::adapter_support::{parse_manifest_output_args, write_report};
use earthsci_toolkit::cadence::{self, MaterializationPoint};
use serde_json::{Map, Value, json};
use std::path::Path;
use std::process::ExitCode;

fn main() -> ExitCode {
    let args = match parse_manifest_output_args() {
        Ok(a) => a,
        Err(e) => {
            eprintln!("cadence-adapter-rust: {e}");
            return ExitCode::FAILURE;
        }
    };
    match run(&args.manifest, &args.output) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("cadence-adapter-rust: {e}");
            ExitCode::FAILURE
        }
    }
}

fn run(manifest_path: &Path, output_path: &Path) -> Result<(), Box<dyn std::error::Error>> {
    let manifest: Value = serde_json::from_str(&std::fs::read_to_string(manifest_path)?)?;
    // Fixture paths in the manifest are repo-root-relative; the manifest lives at
    // <root>/tests/conformance/cadence/manifest.json, so the root is four levels up.
    let repo_root = manifest_path
        .ancestors()
        .nth(4)
        .ok_or("cannot locate repo root from manifest path")?;

    let fixtures = manifest
        .get("fixtures")
        .and_then(|v| v.as_array())
        .ok_or("manifest.fixtures must be an array")?;

    let mut out_fixtures = Map::new();
    for fx in fixtures {
        let id = fx.get("id").and_then(|v| v.as_str()).ok_or("fixture.id")?;
        let rel = fx
            .get("fixture")
            .and_then(|v| v.as_str())
            .ok_or("fixture.fixture")?;
        let model_name = fx
            .get("model")
            .and_then(|v| v.as_str())
            .ok_or("fixture.model")?;

        let doc: Value = serde_json::from_str(&std::fs::read_to_string(repo_root.join(rel))?)?;
        let model = doc
            .get("models")
            .and_then(|m| m.get(model_name))
            .ok_or_else(|| format!("{rel}: model {model_name:?} not found"))?;
        // Attach the document's `data_loaders` so the loader-seeded cadence
        // refinement (§5.7.2) can resolve a discrete variable's data_ingest source.
        let model = cadence::model_with_loaders(model, &doc);

        let partition = cadence::partition_model(&model)?;

        // CONST-folded buffers — the fixtures are value-free, so the document
        // literals live in the manifest's `const_fold.inputs`; the partition
        // pass folds them (topology via the relational engine).
        let mut buffers = Map::new();
        if let Some(cf) = fx.get("const_fold") {
            let inputs = cf.get("inputs").cloned().unwrap_or_else(|| json!({}));
            if let Some(expected) = cf.get("expected").and_then(|v| v.as_object()) {
                for (label, spec) in expected {
                    let serialized = cadence::compute_fold(label, spec, &inputs)?;
                    buffers.insert(label.clone(), Value::String(serialized));
                }
            }
        }

        out_fixtures.insert(
            id.to_string(),
            json!({
                "class_summary": partition.class_summary.to_json(),
                "materialization_points": partition
                    .materialization_points
                    .iter()
                    .map(mp_json)
                    .collect::<Vec<_>>(),
                "const_fold_buffers": Value::Object(buffers),
                "hot_tree_empty": partition.hot_tree_empty,
                "event_handler_empty": partition.event_handler_empty,
            }),
        );
    }

    let report = json!({ "binding": "rust", "fixtures": Value::Object(out_fixtures) });
    write_report(output_path, &report)
}

fn mp_json(m: &MaterializationPoint) -> Value {
    json!({ "label": m.label, "kind": m.kind, "threshold": m.threshold })
}
