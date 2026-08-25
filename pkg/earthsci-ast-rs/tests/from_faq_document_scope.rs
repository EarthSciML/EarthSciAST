//! `from_faq` resolves at DOCUMENT scope (esm-spec.md §9.7.5).
//!
//! `index_sets` is a document-scoped registry, so a `kind:"derived"` entry is
//! visible to every model and its producing node may live in ANY of them. Every
//! binding used to resolve `from_faq` against one model's expression nodes,
//! which made the cross-model shape unresolvable even though the node plainly
//! existed. The consequence of the ruling: an expression-node `id` is unique per
//! DOCUMENT, not per model.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::{EdgeKind, ReferenceResolutionError, resolve_references};
use serde_json::{Value, json};

mod common;

fn fixture_json(rel: &str) -> Value {
    let path = common::repo_fixture(rel);
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {path:?}: {e}"));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("parse {path:?}: {e}"))
}

/// The producing node lives in a different model from the derived set's user.
#[test]
fn from_faq_resolves_a_producer_in_another_model() {
    let doc = json!({
        "index_sets": {
            "faces": {"kind": "interval", "size": 8},
            "edges": {"kind": "derived", "from_faq": "edge_faq"}
        },
        "models": {
            "Consumer": {"equations": [{"lhs": {
                "op": "aggregate", "args": [], "output_idx": [],
                "ranges": {"e": {"from": "edges"}}
            }, "rhs": 0}]},
            "Producer": {"equations": [{"lhs": {
                "op": "aggregate", "args": [], "id": "edge_faq", "output_idx": ["edge"],
                "ranges": {"f": {"from": "faces"}}
            }, "rhs": 0}]}
        }
    });
    let graphs = resolve_references(&doc).expect("resolves at document scope");

    // BOTH graphs carry the edge: the registry entry is document-scoped, so
    // every model sees the same derived set and the same producer.
    for name in ["Consumer", "Producer"] {
        let faq = graphs[name].edges_of_kind(EdgeKind::FromFaq);
        assert_eq!(faq.len(), 1, "{name}");
        assert_eq!(faq[0].source, "index_set:edges");
        assert_eq!(faq[0].target, "node:edge_faq");
    }
    // The consumer's graph gained a real vertex for the foreign producer, so the
    // partition pass can walk index_set -> node across the model boundary.
    let v = &graphs["Consumer"].vertices["node:edge_faq"];
    assert_eq!(v.node_id.as_deref(), Some("edge_faq"));
    assert_eq!(v.path.as_deref(), Some("models/Producer/equations/0/lhs"));
}

/// A `from_faq` naming no node in the whole document is still `unknown_faq_node`.
#[test]
fn from_faq_naming_no_node_in_the_document_still_errors() {
    let doc = json!({
        "index_sets": {"edges": {"kind": "derived", "from_faq": "nowhere"}},
        "models": {
            "A": {"equations": [{"lhs": {"op": "aggregate", "args": [], "id": "here"}, "rhs": 0}]},
            "B": {"equations": [{"lhs": {"op": "aggregate", "args": [], "id": "there"}, "rhs": 0}]}
        }
    });
    let e = resolve_references(&doc).unwrap_err();
    assert!(
        matches!(e, ReferenceResolutionError::UnknownFaqNode { .. }),
        "got {e:?}"
    );
}

/// Node ids are unique per DOCUMENT: the same id in two models is a load error.
#[test]
fn duplicate_node_id_across_two_models_errors() {
    let doc = json!({
        "models": {
            "A": {"equations": [{"lhs": {"op": "aggregate", "args": [], "id": "dup"}, "rhs": 0}]},
            "B": {"equations": [{"lhs": {"op": "aggregate", "args": [], "id": "dup"}, "rhs": 0}]}
        }
    });
    let e = resolve_references(&doc).unwrap_err();
    match &e {
        ReferenceResolutionError::DuplicateNodeId {
            id, path, first, ..
        } => {
            assert_eq!(id, "dup");
            // Model-qualified on both sides, so the cross-model clash is visible.
            assert!(path.starts_with("models/"), "{path}");
            assert!(first.starts_with("models/"), "{first}");
        }
        other => panic!("want DuplicateNodeId, got {other:?}"),
    }
}

/// The shared cross-binding fixture for the ruling.
#[test]
fn cross_model_from_faq_corpus_fixture_resolves() {
    let doc = fixture_json("valid/aggregate/cross_model_from_faq.esm");
    let graphs = resolve_references(&doc).expect("resolves");
    let mut names: Vec<&str> = graphs.keys().map(String::as_str).collect();
    names.sort_unstable();
    assert_eq!(names, ["EdgeProducer", "FluxConsumer"]);
    let faq = graphs["FluxConsumer"].edges_of_kind(EdgeKind::FromFaq);
    assert_eq!(faq.len(), 1);
    assert_eq!(faq[0].source, "index_set:edges");
    assert_eq!(faq[0].target, "node:edge_enum");
}

/// CORPUS_DEFECTS #2 AND #3 are both fixed on this fixture, and it was the
/// SECOND instance of #3 — masked until #2 landed.
///
///   - #2: `rg_candidate_pairs.from_faq` names `rg_candidate_set`, which lives
///     in `OceanDynamics` while the registry entry is document-scoped.
///   - #3: that producing node carries `join.on == [["rg_src_bin",
///     "rg_tgt_bin"]]`, naming declared model VARIABLES — per-cell
///     value-invention bin buffers written by equations 0 and 1 — rather than
///     node-local binders. Both columns now resolve through the variable class
///     of `join_binder_class`.
#[test]
fn wildfire_fixture_resolves_fully() {
    let doc = fixture_json("valid/wildfire_atmosphere_ocean.esm");
    let graphs = resolve_references(&doc).expect("wildfire_atmosphere_ocean.esm should resolve");
    let ocean = graphs.get("OceanDynamics").expect("an OceanDynamics graph");
    assert!(
        ocean
            .edges_of_kind(EdgeKind::JoinFactor)
            .iter()
            .any(|e| e.target == "factor:rg_src_bin"),
        "no join_factor edge to factor:rg_src_bin"
    );
}

/// The other instance of CORPUS_DEFECTS #3: six aggregates in
/// `ConservativeRegridAssembly` join on `[["src_bin", "tgt_bin"]]`, both
/// declared model variables shaped over the join's range index sets.
#[test]
fn conservative_regrid_assembly_resolves() {
    let doc = fixture_json("valid/geometry/conservative_regrid_assembly.esm");
    resolve_references(&doc).expect("conservative_regrid_assembly.esm should resolve");
}

/// The corpus-wide sweep: EVERY schema-valid fixture resolves. This is the
/// acceptance test for `tests/CORPUS_DEFECTS.md` and the Rust counterpart of the
/// Python / TypeScript / Go / Julia corpus sweeps — the five agree on the
/// partition, which is EMPTY of rejections.
#[test]
fn every_shared_valid_fixture_resolves() {
    fn collect(dir: &std::path::Path, out: &mut Vec<std::path::PathBuf>) {
        for entry in std::fs::read_dir(dir).expect("read tests/valid") {
            let path = entry.expect("dir entry").path();
            if path.is_dir() {
                collect(&path, out);
            } else if path.extension().is_some_and(|e| e == "esm") {
                out.push(path);
            }
        }
    }
    let valid = common::repo_fixture("valid");
    let mut files = Vec::new();
    collect(&valid, &mut files);
    files.sort();
    assert!(files.len() > 50, "corpus too small: {}", files.len());

    let mut failures = Vec::new();
    for path in &files {
        let text = std::fs::read_to_string(path).expect("read fixture");
        let doc: Value = serde_json::from_str(&text).expect("parse fixture");
        if let Err(e) = resolve_references(&doc) {
            failures.push(format!("{}: {e}", path.display()));
        }
    }
    assert!(failures.is_empty(), "unresolved fixtures: {failures:#?}");
}
