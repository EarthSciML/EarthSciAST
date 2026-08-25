//! `from_faq` resolves at DOCUMENT scope (esm-spec.md §9.7.5).
//!
//! `index_sets` is a document-scoped registry, so a `kind:"derived"` entry is
//! visible to every model and its producing node may live in ANY of them. Every
//! binding used to resolve `from_faq` against one model's expression nodes,
//! which made the cross-model shape unresolvable even though the node plainly
//! existed. The consequence of the ruling: an expression-node `id` is unique per
//! DOCUMENT, not per model.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::reference_resolution::{EdgeKind, ReferenceResolutionError, resolve_references};
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

/// CORPUS_DEFECTS #2 is fixed; what remains on this fixture is #3.
///
/// `rg_candidate_pairs.from_faq` names `rg_candidate_set`, which lives in
/// `OceanDynamics` while the registry entry is document-scoped. That resolves
/// now. The fixture still does not resolve as a whole: the producing node
/// carries `join.on == [["rg_src_bin", "rg_tgt_bin"]]`, naming model variables
/// rather than node-local binders — the SAME undiagnosed shape as corpus defect
/// #3 (`geometry/conservative_regrid_assembly.esm`), which defect #2 used to
/// mask by erroring first.
#[test]
fn wildfire_fixture_no_longer_raises_unknown_faq_node() {
    let doc = fixture_json("valid/wildfire_atmosphere_ocean.esm");
    let e = resolve_references(&doc).unwrap_err();
    match &e {
        ReferenceResolutionError::UnresolvedJoinFactor { factor, .. } => {
            assert_eq!(factor, "rg_src_bin");
        }
        other => panic!("want the defect-#3 join error, got {other:?}"),
    }
}
