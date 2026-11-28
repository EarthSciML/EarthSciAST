//! The one-pass equality scatter (`lower/scatter.rs`): which lowering each
//! shape takes, bit-identical to the interpreter in both executors.

use super::test_support::{ab_check, opcount};
use serde_json::{Value, json};

fn fixture(rel: &str) -> Value {
    let p = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .join(rel);
    let text = std::fs::read_to_string(&p).unwrap_or_else(|e| panic!("{}: {e}", p.display()));
    serde_json::from_str(&text).expect("fixture is JSON")
}

/// `D(u[j]) = Σ_{i : filter} body` over `j, i ∈ [1, n]`.
fn scatter_doc(n: i64, filter: Value, body: Value) -> Value {
    json!({
        "esm": "2.0.0",
        "metadata": {"name": "scatter_tape", "authors": ["tape tests"]},
        "index_sets": {"x": {"kind": "interval", "size": n}},
        "models": {"M": {
            "variables": {"u": {"type": "unknown", "units": "1", "shape": ["x"], "default": 1.0}},
            "equations": [{
                "lhs": {"op": "faq", "args": [], "output_idx": ["j"], "ranges": {"j": {"from": "x"}},
                        "expr": {"op": "D", "args": [{"op": "index", "args": ["u", "j"]}], "wrt": "t"}},
                "rhs": {"op": "faq", "args": [], "output_idx": ["j"], "reduce": "+",
                        "ranges": {"j": {"from": "x"}, "i": {"from": "x"}},
                        "filter": filter, "expr": body}
            }]
        }}
    })
}

/// The band transpose's unit shifts are stencil reads: no tuple list, no
/// contracted box.
#[test]
fn a_unit_shift_scatter_lowers_without_a_tuple_list_or_a_box() {
    let prog = ab_check(
        fixture("tests/conformance/scaling/fixtures/band_transpose/band_transpose_N1000.esm"),
        -2.0,
        2.0,
    );
    assert_eq!(opcount(&prog, "SegReduce"), 0);
    assert_eq!(opcount(&prog, "Reduce"), 0);
}

/// A pin that is not a unit shift takes the build-time scatter map: one
/// segmented reduction, no dense reduction.
#[test]
fn a_non_shift_pin_lowers_to_one_segmented_reduction() {
    let body = json!({"op": "index", "args": ["u", "i"]});
    for filter in [
        json!({"op": "==", "args": ["j", {"op": "/", "args": ["i", 2]}]}),
        json!({"op": "==", "args": [{"op": "-", "args": [10, "i"]}, "j"]}),
        json!({"op": "and", "args": [
            {"op": "==", "args": ["j", {"op": "+", "args": ["i", 1]}]},
            {"op": ">", "args": [{"op": "index", "args": ["u", "i"]}, 0]}]}),
        // The pin inside a nested `and`.
        json!({"op": "and", "args": [
            {"op": "and", "args": [
                {"op": "==", "args": ["j", {"op": "+", "args": ["i", 1]}]},
                {"op": ">", "args": [{"op": "index", "args": ["u", "i"]}, 0]}]},
            {"op": "<", "args": ["i", 9]}]}),
    ] {
        let prog = ab_check(scatter_doc(12, filter.clone(), body.clone()), -2.0, 2.0);
        assert_eq!(opcount(&prog, "SegReduce"), 1, "{filter}");
        assert_eq!(opcount(&prog, "Reduce"), 0, "{filter}");
    }
}

/// A pin that reads the state has no build-time map: the dense lowering.
#[test]
fn a_run_time_pin_keeps_the_dense_lowering() {
    let prog = ab_check(
        scatter_doc(
            6,
            json!({"op": "==", "args": ["j", {"op": "index", "args": ["u", "i"]}]}),
            json!({"op": "index", "args": ["u", "i"]}),
        ),
        -2.0,
        2.0,
    );
    assert_eq!(opcount(&prog, "SegReduce"), 0);
}

/// A scatter keeps its list over the program's tuple-list budget: the list
/// holds only the admitted terms, and the dense lowering costs at least as
/// much. Its tuples are still charged, for the lists that follow.
#[test]
fn a_scatter_over_the_tuple_list_budget_keeps_its_list() {
    use super::lower::set_tuple_list_budget;
    let body = json!({"op": "index", "args": ["u", "i"]});
    // j == 13 - i: twelve tuples.
    let filter = json!({"op": "==", "args": ["j", {"op": "-", "args": [13, "i"]}]});
    for budget in [12, 11] {
        let prev = set_tuple_list_budget(budget);
        let prog = ab_check(scatter_doc(12, filter.clone(), body.clone()), -2.0, 2.0);
        set_tuple_list_budget(prev);
        assert_eq!(opcount(&prog, "SegReduce"), 1, "budget {budget}");
    }
    // Two scatters in one program, room in the budget for one: both lists.
    let one = json!({"op": "faq", "args": [], "output_idx": ["j"], "reduce": "+",
        "ranges": {"j": {"from": "x"}, "i": {"from": "x"}},
        "filter": filter, "expr": body});
    let mut doc = scatter_doc(12, filter.clone(), body.clone());
    doc["models"]["M"]["equations"][0]["rhs"] = json!({"op": "+", "args": [one.clone(),
        {"op": "*", "args": [2, {"op": "faq", "args": [], "output_idx": ["j"], "reduce": "+",
            "ranges": {"j": {"from": "x"}, "i": {"from": "x"}},
            "filter": {"op": "==", "args": ["j", {"op": "/", "args": ["i", 1]}]},
            "expr": body}]}]});
    let prev = set_tuple_list_budget(20);
    let prog = ab_check(doc, -2.0, 2.0);
    set_tuple_list_budget(prev);
    assert_eq!(opcount(&prog, "SegReduce"), 2);
}

/// Over the budget at a size whose dense box is past the promotion limit,
/// the scatter keeps its list too.
#[test]
fn a_scatter_over_the_budget_without_a_promotable_box_keeps_its_list() {
    use super::lower::set_tuple_list_budget;
    // 12000 × 12000 cells and points: past the 2^27 promotion limit.
    let doc = scatter_doc(
        12_000,
        json!({"op": "==", "args": ["j", {"op": "/", "args": ["i", 2]}]}),
        json!({"op": "index", "args": ["u", "i"]}),
    );
    let compiled = super::test_support::compile(doc);
    let prev = set_tuple_list_budget(16);
    let (prog, _) = super::taped(compiled.build_tape_opts(&std::collections::HashSet::new(), None));
    set_tuple_list_budget(prev);
    assert_eq!(opcount(&prog, "SegReduce"), 1);
    assert_eq!(opcount(&prog, "Reduce"), 0);
}

/// A ragged range under a free output index: each free cell walks its own
/// row, still one segmented reduction.
#[test]
fn a_ragged_range_under_a_free_index_scatters_per_free_cell() {
    let doc = json!({
        "esm": "2.0.0",
        "metadata": {"name": "ragged_free_scatter", "authors": ["tape tests"]},
        "index_sets": {
            "rows": {"kind": "interval", "size": 4},
            "cols": {"kind": "interval", "size": 3},
            "maxLen": {"kind": "interval", "size": 4},
            "row_members": {"kind": "ragged", "of": ["rows"], "offsets": "rowLen",
                            "values": "rowMem"}
        },
        "models": {"M": {
            "variables": {
                "s": {"type": "unknown", "units": "1", "shape": ["cols"], "default": 1.0},
                "pm": {"type": "unknown", "units": "1", "shape": ["rows", "cols"], "default": 0.0},
                "rowLen": {"type": "unknown", "units": "1", "shape": ["rows"]},
                "rowMem": {"type": "unknown", "units": "1", "shape": ["rows", "maxLen"]}
            },
            "equations": [
                {"lhs": {"op": "faq", "args": [], "output_idx": ["q"], "ranges": {"q": {"from": "cols"}},
                         "expr": {"op": "D", "args": [{"op": "index", "args": ["s", "q"]}], "wrt": "t"}},
                 "rhs": {"op": "faq", "args": [], "output_idx": ["q"], "ranges": {"q": {"from": "cols"}},
                         "expr": {"op": "index", "args": ["s", "q"]}}},
                {"lhs": "rowLen", "rhs": {"op": "const", "args": [], "value": [3, 1, 4, 2]}},
                {"lhs": "rowMem", "rhs": {"op": "const", "args": [],
                    "value": [[2, 1, 2, 1], [3, 1, 1, 1], [1, 3, 3, 2], [2, 2, 1, 1]]}},
                {"lhs": {"op": "faq", "args": [], "output_idx": ["a", "b"],
                         "ranges": {"a": {"from": "rows"}, "b": {"from": "cols"}},
                         "expr": {"op": "D", "args": [{"op": "index", "args": ["pm", "a", "b"]}], "wrt": "t"}},
                 "rhs": {"op": "faq", "args": [], "output_idx": ["a", "b"], "reduce": "+",
                         "ranges": {"a": {"from": "rows"}, "b": {"from": "cols"},
                                    "k": {"from": "row_members", "of": ["a"]}},
                         "filter": {"op": "==", "args": ["b", "k"]},
                         "expr": {"op": "index", "args": ["s", {"op": "index", "args": ["rowMem", "a", "k"]}]}}}
            ]
        }}
    });
    let prog = ab_check(doc, -2.0, 2.0);
    assert_eq!(opcount(&prog, "SegReduce"), 1);
    // The admitted points only, Σ_a min(|row a|, 3) = 3 + 1 + 3 + 2, not the
    // 3 · (3 + 1 + 4 + 2) pairs the dense tuple list masks at run time.
    assert_eq!(prog.tables.seg_tables[0].rows.last(), Some(&9));
}

/// The transposed product of an `overlap`-gated binning, `D(g) = faq_j Σ_{c,
/// r : r == j} inside(c, r)·λ[c]·X[r]`, as EarthSciASTDiff's vector-Jacobian
/// product document of a regrid writes it: the gate binds only contracted
/// names and the filter pins the output index, so the gate's candidate pairs
/// are walked once and scattered into their cells. The list holds the
/// candidates, one run per record, not one walk of every candidate per output
/// cell (`|recs| × |candidates|` tuples before). The output index ranges over
/// a literal `[1, n]`, as the product documents write it: an `overlap` side
/// resolves by index-set name, so with `j` drawn from `recs` the gate would
/// bind `j` instead. Record `n` sits on the edge between cells 1 and 2, so
/// the broad phase admits both and the body keeps one.
#[test]
fn a_gated_scatter_walks_the_gates_candidates_once() {
    let n = 40usize;
    let ix = |a: &str, i: &str| json!({"op": "index", "args": [a, i]});
    let cells_w: Vec<f64> = (0..n).map(|k| k as f64).collect();
    let cells_e: Vec<f64> = (0..n).map(|k| k as f64 + 1.0).collect();
    // Records at scrambled cell centres, the last one on an edge.
    let mut xs: Vec<f64> = (0..n).map(|r| ((r * 7) % n) as f64 + 0.5).collect();
    xs[n - 1] = 1.0;
    let inside = json!({"op": "ifelse", "args": [{"op": "and", "args": [
        {"op": "<=", "args": [ix("W", "c"), ix("X", "r")]},
        {"op": "<", "args": [ix("X", "r"), ix("E", "c")]},
        {"op": "<=", "args": [ix("S", "c"), ix("Y", "r")]},
        {"op": "<", "args": [ix("Y", "r"), ix("N", "c")]}]}, 1.0, 0.0]});
    let doc = json!({
        "esm": "2.0.0",
        "metadata": {"name": "gated_scatter", "authors": ["tape tests"]},
        "index_sets": {"cells": {"kind": "interval", "size": n}, "recs": {"kind": "interval", "size": n}},
        "models": {"M": {
            "variables": {
                "W": {"type": "parameter", "units": "1", "shape": ["cells"], "default": cells_w},
                "E": {"type": "parameter", "units": "1", "shape": ["cells"], "default": cells_e},
                "S": {"type": "parameter", "units": "1", "shape": ["cells"], "default": vec![0.0; n]},
                "N": {"type": "parameter", "units": "1", "shape": ["cells"], "default": vec![1.0; n]},
                "X": {"type": "parameter", "units": "1", "shape": ["recs"], "default": xs},
                "Y": {"type": "parameter", "units": "1", "shape": ["recs"], "default": vec![0.5; n]},
                "lam": {"type": "unknown", "units": "1", "shape": ["cells"], "default": 1.0},
                "g": {"type": "unknown", "units": "1", "shape": ["recs"], "default": 0.0}
            },
            "equations": [
                {"lhs": {"op": "faq", "args": [], "output_idx": ["c"], "ranges": {"c": {"from": "cells"}},
                         "expr": {"op": "D", "args": [ix("lam", "c")], "wrt": "t"}},
                 "rhs": {"op": "faq", "args": [], "output_idx": ["c"], "ranges": {"c": {"from": "cells"}},
                         "expr": {"op": "-", "args": [ix("lam", "c")]}}},
                {"lhs": {"op": "D", "args": ["g"], "wrt": "t"},
                 "rhs": {"op": "faq", "args": [], "output_idx": ["j"],
                         "ranges": {"j": [1, n], "c": {"from": "cells"}, "r": {"from": "recs"}},
                         "reduce": "+",
                         "filter": {"op": "==", "args": ["r", "j"]},
                         "join": [{"overlap": {"src_env": ["X", "Y"], "tgt_env": ["W", "S", "E", "N"], "eps": 0.0}}],
                         "expr": {"op": "*", "args": [
                             {"op": "*", "args": [inside, ix("lam", "c")]}, ix("X", "r")]}}}
            ]
        }}
    });
    let prog = ab_check(doc, -2.0, 2.0);
    assert_eq!(opcount(&prog, "SegReduce"), 1);
    // One candidate per record, two for the record on the edge.
    let mut rows: Vec<u32> = (0..n as u32).collect();
    rows.push(n as u32 + 1);
    assert_eq!(prog.tables.seg_tables[0].rows, rows);
}
