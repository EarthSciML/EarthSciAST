//! Cross-language SIMULATION-OUTPUT DERIVATION conformance
//! (`tests/conformance/output_derivation/`, streaming-output-sinks RFC §7–§9, §16.12).
//!
//! The derivation turns (`.esm` document + flat state element names + a
//! caller-named observed subset) into the dimension-labeled, CF-annotated plan
//! a Zarr writer is handed. It lives in two languages — this crate's
//! `data_output` module and `pkg/EarthSciAST.jl/src/data_output.jl` — and until
//! this corpus there was **no cross-language gate on it at any level**:
//! EarthSciIO's `conformance/write_spec.json` is an *already-derived* schema
//! (`dims` / `time_dim` / `coords` / `vars` / `chunk_shape` / `shard_shape`), so
//! the write corpus starts downstream of derivation and drives the three writers
//! from a hand-authored shape. A derivation corpus's output type is that write
//! corpus's input type, so the two chain end to end:
//!
//! ```text
//! .esm ──[derivation, this corpus]──▶ OutputSchema ──[writers, EarthSciIO]──▶ Zarr
//! ```
//!
//! Both bindings assert against the SAME committed golden, so golden agreement
//! *is* cross-language agreement (`CONFORMANCE_SPEC.md` §5.7.7's rule). The
//! Julia twin is `pkg/EarthSciAST.jl/test/output_derivation_conformance_test.jl`.

use earthsci_ast::data_output::{OutputPlan, derive_output_plan};
use earthsci_ast::{EsmFile, load};
use serde_json::{Value, json};
use std::path::PathBuf;

/// Repo root = the crate dir's grandparent (`pkg/earthsci-ast-rs/../..`).
fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .expect("repo root resolves")
}

fn corpus(rel: &str) -> PathBuf {
    repo_root()
        .join("tests/conformance/output_derivation")
        .join(rel)
}

fn read_text(rel: &str) -> String {
    let path = corpus(rel);
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {path:?}: {e}"))
}

fn load_json(rel: &str) -> Value {
    serde_json::from_str(&read_text(rel)).unwrap_or_else(|e| panic!("parse {rel}: {e}"))
}

fn strings(v: &Value) -> Vec<String> {
    v.as_array()
        .expect("array of strings")
        .iter()
        .map(|s| s.as_str().expect("string").to_string())
        .collect()
}

/// The plan, rendered into the golden's language-neutral JSON shape.
/// Deliberately a projection of the production [`derive_output_plan`] result —
/// nothing here re-derives anything, so a bug in the derivation cannot hide
/// behind the adapter.
fn render(plan: &OutputPlan) -> Value {
    Value::Array(
        plan.grids
            .iter()
            .map(|g| {
                json!({
                    "dims": g.dims.iter()
                        .map(|(n, len)| json!([n, len]))
                        .collect::<Vec<_>>(),
                    "time_dim": g.time_dim,
                    "coords": g.coords.iter()
                        .map(|c| json!({
                            "name": c.name,
                            "values": c.values,
                            "attrs": Value::Object(c.attrs.clone()),
                        }))
                        .collect::<Vec<_>>(),
                    "vars": g.vars.iter()
                        .map(|v| json!({
                            "name": v.name,
                            "dims": v.dims,
                            "dtype": v.dtype,
                            "attrs": Value::Object(v.attrs.clone()),
                            "shape": v.gridding.shape,
                            // Already 0-based and row-major here; the Julia
                            // binding converts from its 1-based `cart` form.
                            "flat_indices": v.gridding.flat_indices,
                        }))
                        .collect::<Vec<_>>(),
                })
            })
            .collect(),
    )
}

#[test]
fn every_corpus_case_derives_the_golden_plan() {
    let manifest = load_json("manifest.json");
    assert_eq!(manifest["category"], "output_derivation_conformance");
    assert!(
        strings(&manifest["bindings_required"]).contains(&"rust".to_string()),
        "rust must be a required binding"
    );

    let cases = manifest["cases"].as_array().expect("cases array");
    assert!(!cases.is_empty(), "corpus must not be empty");

    for case in cases {
        let id = case["id"].as_str().expect("case id");
        let doc: EsmFile = load(&read_text(case["fixture"].as_str().expect("fixture")))
            .unwrap_or_else(|e| panic!("{id}: fixture loads: {e}"));
        let slots = strings(&case["slot_names"]);
        let observed = strings(&case["observed"]);

        let plan = derive_output_plan(&doc, &slots, &observed)
            .unwrap_or_else(|e| panic!("{id}: plan derives: {e}"));

        let golden = load_json(case["golden"].as_str().expect("golden"));
        assert_eq!(
            render(&plan),
            golden["grids"],
            "{id}: derived plan differs from the golden"
        );
    }
}

/// The clause the corpus exists for, asserted directly so a regression names
/// itself rather than showing up as a golden diff (RFC §16.12).
#[test]
fn a_scalar_carries_no_synthetic_axis_and_scalars_share_one_grid() {
    let doc: EsmFile = load(&read_text("fixtures/scalar_0d.esm")).expect("fixture loads");
    let slots: Vec<String> = ["Box.T", "Box.C", "Box.E"]
        .iter()
        .map(|s| (*s).to_string())
        .collect();

    let plan = derive_output_plan(&doc, &slots, &[]).expect("plan derives");
    assert_eq!(plan.grids.len(), 1, "NOT one grid per scalar");
    assert!(plan.grids[0].dims.is_empty(), "no <base>_d0 axes");
    for v in &plan.grids[0].vars {
        assert_eq!(v.dims, vec!["time".to_string()]);
        assert!(v.gridding.shape.is_empty());
    }
}

/// The record axis is the document's `domain.independent_variable`, not the
/// literal `"time"` — the `mixed` fixture names it `t`.
#[test]
fn the_record_axis_comes_from_the_document() {
    let doc: EsmFile = load(&read_text("fixtures/mixed.esm")).expect("fixture loads");
    let plan = derive_output_plan(&doc, &["Mix.mass".to_string()], &[]).expect("plan derives");
    assert_eq!(plan.grids[0].time_dim, "t");
    assert_eq!(plan.grids[0].vars[0].dims, vec!["t".to_string()]);
}
