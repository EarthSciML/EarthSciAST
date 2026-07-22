//! CROSS-LANGUAGE conformance for the projection-pushdown spatial OVERLAP
//! join-gate (Phase 2a / Phase 6 cross-language: Rust). Proves the Rust engine
//! derives the SAME support-set members as the Julia reference from the SAME
//! shared fixture geometry.
//!
//! The gate replaces uniform-grid bin-EQUALITY (`join.on [[l,r]]`) with envelope
//! CANDIDACY built on the Phase-3a rstar broad phase: the producer admits a
//! contracted `(point, cell)` tuple iff its two range positions are in the
//! candidate set computed ONCE from the two envelope factor arrays. A rectangle
//! strict-containment `filter` is the narrow phase. Materialising the producer's
//! `distinct` set is then the EXACT set of cells containing >=1 point.
//!
//! Two cases, both asserting the Julia goldens verbatim:
//!
//!   (a) ISRM L1 (3x3 grid, points in cells {1,2,4,9}) — the headline support set
//!       `[1,2,4,9]`, the Julia golden from EarthSciAST.jl
//!       `test/pushdown_edge_test.jl` / `test/auto_pushdown_rewrite_test.jl`,
//!       loaded from the SHARED fixture `fixtures/pushdown/overlap_gate_point_in_rect.esm`.
//!
//!   (b) point-in-rectangle micro fixture (5 points x 4 cells) — the Julia golden
//!       `[1,2]` from `test/overlap_gate_conformance_test.jl`, incl. the
//!       broad-phase candidate set being a CONSERVATIVE SUPERSET of the true
//!       strict containments and the narrow filter dropping the boundary pairs.
//!
//! Determinism: integer keys, §5.5 sorted total order — the canonical index-set
//! JSON is byte-identical across languages.

#![cfg(not(target_arch = "wasm32"))]

use std::collections::HashMap;

use earthsci_ast::broad_phase;
use earthsci_ast::value_invention::materialize_value_invention;
use earthsci_ast::{BoundaryKind, Key, canonical_index_set_json};
use ndarray::{ArrayD, IxDyn};
use serde_json::Value;

fn arr(shape: &[usize], data: Vec<f64>) -> ArrayD<f64> {
    ArrayD::from_shape_vec(IxDyn(shape), data).expect("shape matches data")
}

fn ca(pairs: Vec<(&str, ArrayD<f64>)>) -> HashMap<String, ArrayD<f64>> {
    pairs.into_iter().map(|(k, v)| (k.to_string(), v)).collect()
}

fn names(ns: &[&str]) -> Vec<String> {
    ns.iter().map(|s| s.to_string()).collect()
}

/// Extract a model view carrying the document-scoped `index_sets` (mirrors the
/// value-invention front-door's `model_with_loaders` merge), the same shape the
/// existing in-crate value-invention tests use.
fn model_with_index_sets(doc: &Value, model_name: &str) -> Value {
    let mut model = doc["models"][model_name].clone();
    if let (Value::Object(m), Some(is)) = (&mut model, doc.get("index_sets")) {
        m.entry("index_sets".to_string())
            .or_insert_with(|| is.clone());
    }
    model
}

/// The ISRM L1 geometry: a 3x3 grid of 2x2 cells (cell k = (row-1)*3 + col) and
/// 5 emission points placed by hand in cells {1, 2, 4, 9}.
fn l1_const_arrays() -> HashMap<String, ArrayD<f64>> {
    // Cell rectangles [W,S,E,N], row-major k = 1..9.
    let w = arr(&[9], vec![0.0, 2.0, 4.0, 0.0, 2.0, 4.0, 0.0, 2.0, 4.0]);
    let e = arr(&[9], vec![2.0, 4.0, 6.0, 2.0, 4.0, 6.0, 2.0, 4.0, 6.0]);
    let s = arr(&[9], vec![0.0, 0.0, 0.0, 2.0, 2.0, 2.0, 4.0, 4.0, 4.0]);
    let n = arr(&[9], vec![2.0, 2.0, 2.0, 4.0, 4.0, 4.0, 6.0, 6.0, 6.0]);
    // Points: e1(1,1)->c1, e2(3,1)->c2, e3(1,3)->c4, e4(5,5)->c9, e5(1.5,1.5)->c1.
    let x = arr(&[5], vec![1.0, 3.0, 1.0, 5.0, 1.5]);
    let y = arr(&[5], vec![1.0, 1.0, 3.0, 5.0, 1.5]);
    ca(vec![
        ("X", x),
        ("Y", y),
        ("W", w),
        ("S", s),
        ("E", e),
        ("N", n),
    ])
}

/// (a) HEADLINE — the ISRM L1 point-in-rectangle producer materialises to EXACTLY
/// the Julia support set `[1,2,4,9]`, from the shared `.esm` fixture.
#[test]
fn l1_overlap_producer_members_match_julia_golden() {
    const FIXTURE: &str = include_str!("fixtures/pushdown/overlap_gate_point_in_rect.esm");
    let doc: Value = serde_json::from_str(FIXTURE).expect("fixture parses");
    let model = model_with_index_sets(&doc, "ISRM");

    let const_arrays = l1_const_arrays();
    let vi = materialize_value_invention(
        &model,
        &const_arrays,
        &HashMap::new(),
        &HashMap::<String, Vec<BoundaryKind>>::new(),
    )
    .expect("overlap-gate producer materialises");

    // skolem("cell", [c]) is a single-component key => the scalar cell index; the
    // distinct set is the exact hand-computed containing cells.
    let members = &vi.members["emis_src_cells_faq"];
    assert_eq!(
        *members,
        vec![Key::Int(1), Key::Int(2), Key::Int(4), Key::Int(9)],
        "Rust overlap-gate support set must equal the Julia L1 golden [1,2,4,9]"
    );
    assert_eq!(vi.extents["emis_src_cells_faq"], 4);
    // Byte-identical canonical index-set JSON — the cross-language determinism golden.
    assert_eq!(canonical_index_set_json(members), "[1,2,4,9]");
}

/// (a') The rstar broad-phase candidate set for the L1 geometry is a CONSERVATIVE
/// SUPERSET of the true strict containments, and equals the brute-force oracle.
/// (All 5 L1 points land strictly interior to a single cell, so here the broad
/// phase already equals the containments — 0-based (point, cell) pairs.)
#[test]
fn l1_broad_phase_is_conservative_and_rstar_equals_bruteforce() {
    let g = l1_const_arrays();
    let src = broad_phase::envelope_vectors(&names(&["X", "Y"]), &g).unwrap();
    let tgt = broad_phase::envelope_vectors(&names(&["W", "S", "E", "N"]), &g).unwrap();

    let cs = broad_phase::broad_phase_candidates(&src, &tgt, 0.0);
    assert_eq!(
        cs,
        broad_phase::broad_phase_candidates_bruteforce(&src, &tgt, 0.0),
        "rstar != brute-force on the L1 geometry"
    );
    // True containments (0-based point, 0-based cell): e1->c1, e2->c2, e3->c4,
    // e4->c9, e5->c1.
    let containments = [(0usize, 0usize), (1, 1), (2, 3), (3, 8), (4, 0)];
    for pair in containments {
        assert!(
            cs.contains(&pair),
            "broad phase missed a true containment {pair:?}"
        );
    }
}

/// (b) The point-in-rectangle MICRO fixture from the Julia
/// `overlap_gate_conformance_test.jl`: 5 points x 4 cells whose materialised
/// distinct set is the Julia golden `[1,2]` — the boundary points p3/p5 are broad
/// candidates for two cells each but the strict-containment filter drops them.
#[test]
fn point_in_rect_micro_fixture_members_match_julia_golden() {
    // cells (rects [W,S,E,N]): c1=[0,0,2,2] c2=[2,2,4,4] c3=[4,4,6,6] c4=[6,6,8,8]
    // points [X,Y]: p1(1,1) p2(3,3) p3(2,2) p4(10,10) p5(6,6)
    let const_arrays = ca(vec![
        ("X", arr(&[5], vec![1.0, 3.0, 2.0, 10.0, 6.0])),
        ("Y", arr(&[5], vec![1.0, 3.0, 2.0, 10.0, 6.0])),
        ("W", arr(&[4], vec![0.0, 2.0, 4.0, 6.0])),
        ("S", arr(&[4], vec![0.0, 2.0, 4.0, 6.0])),
        ("E", arr(&[4], vec![2.0, 4.0, 6.0, 8.0])),
        ("N", arr(&[4], vec![2.0, 4.0, 6.0, 8.0])),
    ]);

    // Broad-phase candidate set (0-based) == the Julia golden
    // {(1,1),(2,2),(3,1),(3,2),(5,3),(5,4)} shifted to 0-based, and a conservative
    // superset of the true strict containments {(p1,c1),(p2,c2)}.
    let src = broad_phase::envelope_vectors(&names(&["X", "Y"]), &const_arrays).unwrap();
    let tgt = broad_phase::envelope_vectors(&names(&["W", "S", "E", "N"]), &const_arrays).unwrap();
    let cs = broad_phase::broad_phase_candidates(&src, &tgt, 0.0);
    assert_eq!(cs, vec![(0, 0), (1, 1), (2, 0), (2, 1), (4, 2), (4, 3)]);
    for c in [(0usize, 0usize), (1, 1)] {
        assert!(cs.contains(&c), "true containment {c:?} not a candidate");
    }

    // The producer: point-in-rect over points x cells, overlap gate + strict
    // rectangle-interior narrow filter (X-W)(E-X)(Y-S)(N-Y) > 0.
    let doc: Value = serde_json::json!({
        "esm": "0.9.0",
        "metadata": { "name": "overlap_gate_point_in_rect_micro" },
        "index_sets": {
            "points": { "kind": "interval", "size": 5 },
            "cells":  { "kind": "interval", "size": 4 },
            "present_cells": { "kind": "derived", "from_faq": "cells_with_points" }
        },
        "models": { "PointInRect": {
            "variables": {
                "X": { "type": "parameter", "shape": ["points"] },
                "Y": { "type": "parameter", "shape": ["points"] },
                "W": { "type": "parameter", "shape": ["cells"] },
                "S": { "type": "parameter", "shape": ["cells"] },
                "E": { "type": "parameter", "shape": ["cells"] },
                "N": { "type": "parameter", "shape": ["cells"] },
                "cell_present": { "type": "state", "shape": ["present_cells"] }
            },
            "equations": [ {
                "lhs": { "op": "index", "args": ["cell_present", "m"] },
                "rhs": {
                    "op": "aggregate",
                    "id": "cells_with_points",
                    "semiring": "bool_and_or",
                    "distinct": true,
                    "output_idx": ["m"],
                    "ranges": { "i": { "from": "points" }, "j": { "from": "cells" } },
                    "join": [ { "overlap": { "src_env": ["X", "Y"], "tgt_env": ["W", "S", "E", "N"], "eps": 0.0 } } ],
                    "filter": { "op": ">", "args": [
                        { "op": "*", "args": [
                            { "op": "*", "args": [
                                { "op": "-", "args": [ {"op":"index","args":["X","i"]}, {"op":"index","args":["W","j"]} ] },
                                { "op": "-", "args": [ {"op":"index","args":["E","j"]}, {"op":"index","args":["X","i"]} ] } ] },
                            { "op": "*", "args": [
                                { "op": "-", "args": [ {"op":"index","args":["Y","i"]}, {"op":"index","args":["S","j"]} ] },
                                { "op": "-", "args": [ {"op":"index","args":["N","j"]}, {"op":"index","args":["Y","i"]} ] } ] } ] },
                        0.0 ] },
                    "args": ["X", "Y", "W", "S", "E", "N"],
                    "key": { "op": "skolem", "label": "cell", "args": ["j"] },
                    "expr": { "op": "true", "args": [] }
                }
            } ]
        } }
    });
    let model = model_with_index_sets(&doc, "PointInRect");
    let vi = materialize_value_invention(
        &model,
        &const_arrays,
        &HashMap::new(),
        &HashMap::<String, Vec<BoundaryKind>>::new(),
    )
    .expect("micro overlap-gate producer materialises");

    let members = &vi.members["cells_with_points"];
    assert_eq!(
        *members,
        vec![Key::Int(1), Key::Int(2)],
        "point-in-rect micro support set must equal the Julia golden [1,2]"
    );
    assert_eq!(vi.extents["cells_with_points"], 2);
    assert_eq!(canonical_index_set_json(members), "[1,2]");
}
