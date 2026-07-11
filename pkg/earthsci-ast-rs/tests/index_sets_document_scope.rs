//! v0.8.0 scope regression (bead: index_sets → document scope).
//!
//! `index_sets` moved from a per-`Model` field to a single TOP-LEVEL,
//! document-scoped registry (one registry shared by all models). These tests
//! pin that contract for the Rust binding: the registry deserializes onto
//! `EsmFile` (not `Model`), survives a serialize → reparse round-trip at the
//! document top level, and the aggregate `{ "from": <set> }` range resolver
//! reads it from the document registry passed in explicitly.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::aggregate::resolve_aggregate_ranges;
use earthsci_ast::{EsmFile, load};
use std::collections::HashMap;

mod common;

fn fixture(rel: &str) -> String {
    let path = common::repo_fixture(rel);
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()))
}

/// The aggregate fixture declares a top-level `index_sets` registry; it lands on
/// `EsmFile.index_sets`, survives round-trip, and its `{from}` ranges resolve.
#[test]
fn aggregate_fixture_index_sets_is_document_scoped_and_round_trips() {
    let json = fixture("valid/aggregate/aggregate_semiring_indexset.esm");
    let file = load(&json).unwrap_or_else(|e| panic!("load: {e}"));

    // (1) Document-scoped: the registry is on the file, not on any model.
    let sets = file
        .index_sets
        .as_ref()
        .expect("top-level index_sets present on EsmFile");
    assert_eq!(sets["cells"].kind, "interval");
    assert_eq!(sets["cells"].size, Some(5));
    assert_eq!(sets["county"].kind, "categorical");

    // (2) Round-trip: serialize the typed doc, reparse, registry is unchanged.
    let serialized = serde_json::to_string(&file).expect("serialize EsmFile");
    assert!(
        serialized.contains("\"index_sets\""),
        "serialized document keeps a top-level index_sets"
    );
    let round: EsmFile = serde_json::from_str(&serialized).expect("reparse");
    assert_eq!(
        round.index_sets, file.index_sets,
        "index_sets survives round-trip byte-for-byte (typed)"
    );

    // (3) Aggregate ranges resolve against the DOCUMENT registry, threaded in.
    let index_sets = file.index_sets.clone().unwrap_or_default();
    let mut model = file
        .models
        .as_ref()
        .and_then(|m| m.values().next())
        .expect("model present")
        .clone();
    resolve_aggregate_ranges(&mut model, &index_sets)
        .expect("`{from}` ranges resolve against the document registry");
}

/// The conservative-regrid fixture declares a richer document-scoped registry
/// (interval + derived kinds). It lands on `EsmFile.index_sets`, survives
/// round-trip, and its `{from}` ranges resolve against the document registry
/// (an empty registry makes them undeclared — proving the resolver reads the
/// document-scoped registry, not any per-model one).
#[test]
fn regrid_fixture_index_sets_is_document_scoped_and_round_trips() {
    let json = fixture("valid/geometry/conservative_regrid_overlap_join.esm");
    let file = load(&json).unwrap_or_else(|e| panic!("load: {e}"));

    let sets = file
        .index_sets
        .as_ref()
        .expect("top-level index_sets present on EsmFile");
    // Interval + derived kinds all deserialize into the one document registry.
    assert_eq!(sets["src_cells"].kind, "interval");
    assert_eq!(sets["tgt_cells"].kind, "interval");
    assert_eq!(sets["candidate_pairs"].kind, "derived");
    assert_eq!(
        sets["candidate_pairs"].from_faq.as_deref(),
        Some("candidate_set")
    );

    // Round-trip preserves the whole registry.
    let serialized = serde_json::to_string(&file).expect("serialize EsmFile");
    let round: EsmFile = serde_json::from_str(&serialized).expect("reparse");
    assert_eq!(
        round.index_sets, file.index_sets,
        "index_sets survives round-trip byte-for-byte (typed)"
    );

    // The `{from}` range references resolve against the DOCUMENT registry
    // (interval sets → dense intervals; derived sets → dynamic bounds). NOTE:
    // this structural fixture's bin-Skolem `join.on` is a value-equality join
    // over a data-derived column, which the dense evaluator deliberately does
    // not drive (an UnsupportedFeatureError, RFC §5.3) — orthogonal to the
    // index-set scope, so only the range resolution is exercised here.
    let index_sets = file.index_sets.clone().unwrap_or_default();
    let mut model = file
        .models
        .as_ref()
        .and_then(|m| m.values().next())
        .expect("model present")
        .clone();
    resolve_aggregate_ranges(&mut model, &index_sets)
        .expect("`{from}` ranges resolve against the document registry");

    // Same references, empty registry ⇒ undeclared: the resolver truly consults
    // the document-scoped registry that was threaded in, not a model field.
    let mut bare = file
        .models
        .as_ref()
        .and_then(|m| m.values().next())
        .unwrap()
        .clone();
    let err = resolve_aggregate_ranges(&mut bare, &HashMap::new())
        .expect_err("empty document registry makes `{from}` refs undeclared");
    assert!(
        err.to_string().contains("document `index_sets` registry"),
        "resolver names the document registry: {err}"
    );
}
