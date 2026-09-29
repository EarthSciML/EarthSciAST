//! Tuple-list contractions (`lower/tuples.rs`): a join-gated or ragged
//! contraction lowers to one [`Instr::SegReduce`] over the tuples it admits,
//! bit-identical to the interpreter in both executors, with a tape that does
//! not grow with the data and a tuple list that grows with the matches rather
//! than with the product.

use super::ir::*;
use super::tests::ab_check;
use serde_json::{Value, json};

fn corpus(rel: &str) -> Value {
    let p = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .join(rel);
    let text = std::fs::read_to_string(&p).unwrap_or_else(|e| panic!("{}: {e}", p.display()));
    serde_json::from_str(&text).expect("corpus document is JSON")
}

fn count(prog: &TapeProgram, opcode: &str) -> usize {
    prog.instrs.iter().filter(|i| i.opcode() == opcode).count()
}

/// The five join documents and the two ragged ones the native compiler used
/// to refuse, each now on the tape in one segmented reduction per gated or
/// ragged contraction.
#[test]
fn the_corpus_join_and_ragged_documents_lower_to_segmented_reductions() {
    for (rel, reductions) in [
        ("tests/valid/faq/join_disaggregation_m2m.esm", 1),
        ("tests/valid/faq/join_disaggregation_m2m_permuted.esm", 1),
        ("tests/valid/faq/join_on_data_columns.esm", 1),
        ("tests/valid/faq/join_on_self_join.esm", 2),
        ("tests/valid/faq/join_on_self_join_syms.esm", 2),
        ("tests/valid/faq/ragged_member_gather.esm", 1),
        (
            "tests/conformance/expression_templates/import_rebind_keyed_factors/expanded.esm",
            1,
        ),
    ] {
        let prog = ab_check(corpus(rel), 0, -2.0, 2.0);
        assert_eq!(count(&prog, "SegReduce"), reductions, "{rel}");
    }
}

/// A self-join over `n` rows: row `a`'s key is `a - 1` and row `b`'s is `b`,
/// so exactly `n - 1` of the `n²` pairs match, and the summed payload is
/// state-dependent and spans magnitudes, so a fold in another order would
/// show in the low bits.
fn self_join_doc(n: usize) -> Value {
    let ids: Vec<f64> = (1..=n).map(|k| k as f64).collect();
    let prior: Vec<f64> = (0..n).map(|k| k as f64).collect();
    let payload: Vec<f64> = (0..n)
        .map(|k| (1.0 + 0.3 * k as f64) * 10f64.powi((k % 9) as i32 - 4))
        .collect();
    let ranges = json!({"a": {"from": "rows"}, "b": {"from": "rows"}});
    let join = json!([{"on": [["row_prior", "row_id"]]}]);
    json!({
        "esm": "1.1.0",
        "metadata": {"name": "self_join_scaling", "authors": ["tape tests"]},
        "index_sets": {"rows": {"kind": "interval", "size": n}},
        "models": {"M": {
            "variables": {
                "row_id": {"type": "unknown", "units": "1", "shape": ["rows"]},
                "row_prior": {"type": "unknown", "units": "1", "shape": ["rows"]},
                "payload": {"type": "unknown", "units": "1", "shape": ["rows"]},
                "u": {"type": "unknown", "units": "1", "shape": ["rows"], "default": 1.0},
                "s": {"type": "unknown", "units": "1", "default": 0.0},
                "c": {"type": "unknown", "units": "1", "default": 0.0}
            },
            "equations": [
                {"lhs": "row_id", "rhs": {"op": "const", "args": [], "value": ids}},
                {"lhs": "row_prior", "rhs": {"op": "const", "args": [], "value": prior}},
                {"lhs": "payload", "rhs": {"op": "const", "args": [], "value": payload}},
                {"lhs": {"op": "faq", "args": [], "output_idx": ["i"],
                         "expr": {"op": "D", "args": [{"op": "index", "args": ["u", "i"]}], "wrt": "t"},
                         "ranges": {"i": {"from": "rows"}}},
                 "rhs": {"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": {"from": "rows"}},
                         "expr": {"op": "-", "args": [{"op": "index", "args": ["u", "i"]}]}}},
                {"lhs": {"op": "D", "args": ["s"], "wrt": "t"},
                 "rhs": {"op": "faq", "args": [], "output_idx": [], "semiring": "sum_product",
                         "ranges": ranges, "join": join,
                         "expr": {"op": "*", "args": [
                             {"op": "index", "args": ["payload", "b"]},
                             {"op": "index", "args": ["u", "a"]}]}}},
                {"lhs": {"op": "D", "args": ["c"], "wrt": "t"},
                 "rhs": {"op": "faq", "args": [], "output_idx": [], "semiring": "sum_product",
                         "ranges": ranges, "join": join, "expr": 1.0}}
            ]
        }}
    })
}

/// The tuple list holds the matches, not the product, and the tape is the
/// same length at every size.
#[test]
fn a_self_join_materializes_its_matches_and_its_tape_is_flat_in_n() {
    let mut sizes = Vec::new();
    for n in [16usize, 300] {
        let prog = ab_check(self_join_doc(n), 0, -2.0, 2.0);
        assert_eq!(count(&prog, "SegReduce"), 2);
        for t in &prog.seg_tables {
            assert_eq!(
                t.rows,
                vec![0, (n - 1) as u32],
                "n = {n}: one cell, n - 1 matches"
            );
        }
        sizes.push((prog.instrs.len(), prog.fuse_stats.instrs_before));
    }
    assert_eq!(sizes[0], sizes[1], "the tape grew with the data");
}

/// A many-to-many join between two data columns, where every key occurs
/// several times on both sides: each match is one term, folded in the
/// interpreter's `(l, r)` order.
#[test]
fn a_many_to_many_data_column_join_folds_in_the_interpreters_order() {
    let (nl, nr) = (11usize, 7usize);
    let kl: Vec<f64> = (0..nl).map(|k| (k % 3) as f64).collect();
    let kr: Vec<f64> = (0..nr).map(|k| ((k * 2) % 3) as f64).collect();
    let w: Vec<f64> = (0..nl)
        .map(|k| (0.7 + k as f64) * 10f64.powi((k % 5) as i32 - 2))
        .collect();
    let doc = json!({
        "esm": "1.1.0",
        "metadata": {"name": "m2m_data_columns", "authors": ["tape tests"]},
        "index_sets": {"ls": {"kind": "interval", "size": nl}, "rs": {"kind": "interval", "size": nr}},
        "models": {"M": {
            "variables": {
                "kl": {"type": "unknown", "units": "1", "shape": ["ls"]},
                "kr": {"type": "unknown", "units": "1", "shape": ["rs"]},
                "w": {"type": "unknown", "units": "1", "shape": ["ls"]},
                "v": {"type": "unknown", "units": "1", "shape": ["rs"], "default": 1.0},
                "total": {"type": "unknown", "units": "1", "default": 0.0}
            },
            "equations": [
                {"lhs": "kl", "rhs": {"op": "const", "args": [], "value": kl}},
                {"lhs": "kr", "rhs": {"op": "const", "args": [], "value": kr}},
                {"lhs": "w", "rhs": {"op": "const", "args": [], "value": w}},
                {"lhs": {"op": "faq", "args": [], "output_idx": ["j"],
                         "expr": {"op": "D", "args": [{"op": "index", "args": ["v", "j"]}], "wrt": "t"},
                         "ranges": {"j": {"from": "rs"}}},
                 "rhs": {"op": "faq", "args": [], "output_idx": ["j"], "ranges": {"j": {"from": "rs"}},
                         "expr": {"op": "*", "args": [0.5, {"op": "index", "args": ["v", "j"]}]}}},
                {"lhs": {"op": "D", "args": ["total"], "wrt": "t"},
                 "rhs": {"op": "faq", "args": [], "output_idx": [], "semiring": "sum_product",
                         "ranges": {"l": {"from": "ls"}, "r": {"from": "rs"}},
                         "join": [{"on": [["kl", "kr"]]}],
                         "expr": {"op": "*", "args": [
                             {"op": "index", "args": ["w", "l"]},
                             {"op": "index", "args": ["v", "r"]}]}}}
            ]
        }}
    });
    let prog = ab_check(doc, 0, -3.0, 3.0);
    let matches = (0..nl)
        .map(|a| (0..nr).filter(|&b| kl[a] == kr[b]).count())
        .sum::<usize>();
    assert_eq!(prog.seg_tables.len(), 1);
    assert_eq!(prog.seg_tables[0].rows, vec![0, matches as u32]);
}

/// A gate with one side an OUTPUT index: each output cell's run lists the
/// records its key column assigns to it (the interpreter's RESTRICT walk),
/// an empty run is the identity, and a record's state-dependent term is
/// gathered from the state in place.
#[test]
fn a_gate_on_an_output_index_restricts_each_cells_run() {
    let (ncell, nrec) = (5usize, 13usize);
    // Records land on cells 1, 2 and 4 only; cells 3 and 5 stay empty.
    let rec_cell: Vec<f64> = (0..nrec).map(|k| [1.0, 2.0, 4.0][k % 3]).collect();
    let doc = json!({
        "esm": "1.1.0",
        "metadata": {"name": "gate_restrict", "authors": ["tape tests"]},
        "index_sets": {"cells": {"kind": "interval", "size": ncell}, "recs": {"kind": "interval", "size": nrec}},
        "models": {"M": {
            "variables": {
                "rec_cell": {"type": "unknown", "units": "1", "shape": ["recs"]},
                "q": {"type": "unknown", "units": "1", "shape": ["recs"], "default": 1.0},
                "binned": {"type": "unknown", "units": "1", "shape": ["cells"]},
                "m": {"type": "unknown", "units": "1", "shape": ["cells"], "default": 0.0}
            },
            "equations": [
                {"lhs": "rec_cell", "rhs": {"op": "const", "args": [], "value": rec_cell}},
                {"lhs": "binned", "rhs": {"op": "faq", "args": [], "output_idx": ["c"],
                    "semiring": "sum_product",
                    "ranges": {"c": {"from": "cells"}, "r": {"from": "recs"}},
                    "join": [{"on": [["rec_cell", "c"]]}],
                    "expr": {"op": "*", "args": [
                        {"op": "index", "args": ["q", "r"]},
                        {"op": "index", "args": ["q", "r"]}]}}},
                {"lhs": {"op": "faq", "args": [], "output_idx": ["r"],
                         "expr": {"op": "D", "args": [{"op": "index", "args": ["q", "r"]}], "wrt": "t"},
                         "ranges": {"r": {"from": "recs"}}},
                 "rhs": {"op": "faq", "args": [], "output_idx": ["r"], "ranges": {"r": {"from": "recs"}},
                         "expr": {"op": "-", "args": [{"op": "index", "args": ["q", "r"]}]}}},
                {"lhs": {"op": "faq", "args": [], "output_idx": ["c"],
                         "expr": {"op": "D", "args": [{"op": "index", "args": ["m", "c"]}], "wrt": "t"},
                         "ranges": {"c": {"from": "cells"}}},
                 "rhs": {"op": "faq", "args": [], "output_idx": ["c"], "ranges": {"c": {"from": "cells"}},
                         "expr": {"op": "index", "args": ["binned", "c"]}}}
            ]
        }}
    });
    let prog = ab_check(doc, 0, -2.0, 2.0);
    assert_eq!(count(&prog, "SegReduce"), 1);
    let per_cell = |c: f64| rec_cell.iter().filter(|&&x| x == c).count() as u32;
    let mut rows = vec![0u32];
    for c in 1..=ncell {
        rows.push(rows.last().unwrap() + per_cell(c as f64));
    }
    assert_eq!(prog.seg_tables[0].rows, rows);
}

/// A ragged contraction whose body gathers a 2-D STATE through a column of
/// member indices (`u[cols[i, k], 2]`): the state is read in place through
/// its own strides, and a member index past the state's extent reads the
/// zero ghost, as `index_into` does.
#[test]
fn a_ragged_gather_of_a_two_dimensional_state_reads_it_in_place() {
    let doc = json!({
        "esm": "1.1.0",
        "metadata": {"name": "ragged_state_gather", "authors": ["tape tests"]},
        "index_sets": {
            "rows": {"kind": "interval", "size": 3},
            "maxnz": {"kind": "interval", "size": 3},
            "nodes": {"kind": "interval", "size": 4},
            "comps": {"kind": "interval", "size": 2},
            "nz": {"kind": "ragged", "of": ["rows"], "offsets": "cnt", "values": "cols"}
        },
        "models": {"M": {
            "variables": {
                "cnt": {"type": "unknown", "units": "1", "shape": ["rows"]},
                "cols": {"type": "unknown", "units": "1", "shape": ["rows", "maxnz"]},
                "w": {"type": "unknown", "units": "1", "shape": ["rows", "maxnz"]},
                "u": {"type": "unknown", "units": "1", "shape": ["nodes", "comps"], "default": 1.0},
                "v": {"type": "unknown", "units": "1", "shape": ["rows"], "default": 0.0}
            },
            "equations": [
                {"lhs": "cnt", "rhs": {"op": "const", "args": [], "value": [2, 3, 1]}},
                {"lhs": "cols", "rhs": {"op": "const", "args": [], "value": [[4, 1, 0], [2, 5, 3], [3, 0, 0]]}},
                {"lhs": "w", "rhs": {"op": "const", "args": [], "value": [[1.5, -2.5, 0.0], [0.125, 7.0, -3.25], [1e-3, 0.0, 0.0]]}},
                {"lhs": {"op": "faq", "args": [], "output_idx": ["n", "p"],
                         "expr": {"op": "D", "args": [{"op": "index", "args": ["u", "n", "p"]}], "wrt": "t"},
                         "ranges": {"n": {"from": "nodes"}, "p": {"from": "comps"}}},
                 "rhs": {"op": "faq", "args": [], "output_idx": ["n", "p"],
                         "ranges": {"n": {"from": "nodes"}, "p": {"from": "comps"}},
                         "expr": {"op": "*", "args": [-0.25, {"op": "index", "args": ["u", "n", "p"]}]}}},
                {"lhs": {"op": "faq", "args": [], "output_idx": ["i"],
                         "expr": {"op": "D", "args": [{"op": "index", "args": ["v", "i"]}], "wrt": "t"},
                         "ranges": {"i": {"from": "rows"}}},
                 "rhs": {"op": "faq", "args": [], "semiring": "sum_product", "output_idx": ["i"],
                         "ranges": {"i": {"from": "rows"}, "k": {"from": "nz", "of": ["i"]}},
                         "expr": {"op": "*", "args": [
                             {"op": "index", "args": ["w", "i", "k"]},
                             {"op": "index", "args": ["u", {"op": "index", "args": ["cols", "i", "k"]}, 2]}]}}}
            ]
        }}
    });
    let prog = ab_check(doc, 0, -2.0, 2.0);
    assert_eq!(count(&prog, "SegReduce"), 1);
    assert_eq!(prog.seg_tables[0].rows, vec![0, 2, 5, 6]);
    // The gather of `u` sees one ghost: row 2's member 5 lies past node 4.
    let ghosts: usize = prog
        .gather_tables
        .iter()
        .filter(|t| t.src_shape[..] == [4, 2])
        .map(|t| t.pos.iter().filter(|&&p| p == GATHER_GHOST).count())
        .sum();
    assert_eq!(ghosts, 1);
}

// ---------------------------------------------------------------------------
// Build-time data and laziness inside a tuple-list body.
// ---------------------------------------------------------------------------

use super::array_tests::{agrees_or_refuses, idx};
use std::collections::HashMap;

/// A ragged contraction `v' = Σ_{k ∈ nz(i)} body` over three rows whose
/// member counts are the observed `cnt`, with a parameter `p` (default 1)
/// and an optional filter.
fn ragged_doc(cnt: Value, body: Value, filter: Option<Value>) -> Value {
    let mut rhs = json!({"op": "faq", "args": [], "semiring": "sum_product", "output_idx": ["i"],
        "ranges": {"i": {"from": "rows"}, "k": {"from": "nz", "of": ["i"]}},
        "expr": body});
    if let Some(f) = filter {
        rhs["filter"] = f;
    }
    json!({
        "esm": "1.1.0",
        "metadata": {"name": "ragged_review", "authors": ["tape tests"]},
        "index_sets": {
            "rows": {"kind": "interval", "size": 3},
            "maxnz": {"kind": "interval", "size": 3},
            "nz": {"kind": "ragged", "of": ["rows"], "offsets": "cnt", "values": "cols"}
        },
        "models": {"M": {
            "variables": {
                "p": {"type": "parameter", "units": "1", "default": 1.0},
                "cnt": {"type": "unknown", "units": "1", "shape": ["rows"]},
                "cols": {"type": "unknown", "units": "1", "shape": ["rows", "maxnz"]},
                "w": {"type": "unknown", "units": "1", "shape": ["rows", "maxnz"]},
                "v": {"type": "unknown", "units": "1", "shape": ["rows"], "default": 1.0}
            },
            "equations": [
                {"lhs": "cnt", "rhs": cnt},
                {"lhs": "cols", "rhs": {"op": "const", "args": [], "value": [[1, 2, 0], [3, 1, 2], [2, 0, 0]]}},
                {"lhs": "w", "rhs": {"op": "const", "args": [], "value": [[1.5, -2.5, 0.0], [0.125, 7.0, -3.25], [1e-3, 0.0, 0.0]]}},
                {"lhs": {"op": "faq", "args": [], "output_idx": ["i"],
                         "expr": {"op": "D", "args": [{"op": "index", "args": ["v", "i"]}], "wrt": "t"},
                         "ranges": {"i": {"from": "rows"}}},
                 "rhs": rhs}
            ]
        }}
    })
}

fn cnst(v: Value) -> Value {
    json!({"op": "const", "args": [], "value": v})
}

fn p_positive() -> Value {
    json!({"op": ">", "args": ["p", 0]})
}

/// `p = 1` (the default, the true branch) and `p = -1` (the false branch).
fn both_branches() -> Vec<HashMap<String, f64>> {
    vec![HashMap::new(), HashMap::from([("p".to_string(), -1.0)])]
}

fn wv() -> Value {
    json!({"op": "*", "args": [idx(json!("w"), &[json!("i"), json!("k")]), idx(json!("v"), &[json!("i")])]})
}

fn states() -> Vec<Vec<f64>> {
    vec![vec![0.5, -1.25, 2.0], vec![-0.5, -1.0, -2.0]]
}

/// A runtime-conditioned `ifelse` joins two values in one slot; the build
/// knows neither which branch runs nor, so, the join's value. Ragged
/// offsets chosen by a parameter are therefore not build-time data (the
/// tape refuses rather than reading one branch's), while two branches that
/// agree exactly still are.
#[test]
fn a_branch_join_is_build_time_data_only_when_its_branches_agree() {
    let cnt = json!({"op": "ifelse", "args": [p_positive(), cnst(json!([2, 3, 1])), cnst(json!([1, 1, 1]))]});
    let compiled = super::array_tests::compile(ragged_doc(cnt, wv(), None));
    let refused = agrees_or_refuses(&compiled, &both_branches(), &states());
    assert!(
        refused
            .iter()
            .any(|(_, r)| r.contains("ragged offsets factor `cnt`")),
        "{refused:?}"
    );

    let cnt = json!({"op": "ifelse", "args": [p_positive(), cnst(json!([2, 3, 1])), cnst(json!([2, 3, 1]))]});
    let compiled = super::array_tests::compile(ragged_doc(cnt, wv(), None));
    super::array_tests::ab(&compiled, &both_branches());
}

/// The same for a gather subscript inside the body: `v[ifelse(p > 0, i, k)]`
/// is not build-time data over the list.
#[test]
fn a_branch_join_subscript_is_not_build_time_data() {
    let body = json!({"op": "*", "args": [
        idx(json!("w"), &[json!("i"), json!("k")]),
        idx(json!("v"), &[json!({"op": "ifelse", "args": [p_positive(), "i", "k"]})])]});
    let compiled = super::array_tests::compile(ragged_doc(cnst(json!([2, 3, 1])), body, None));
    let refused = agrees_or_refuses(&compiled, &both_branches(), &states());
    assert!(
        refused
            .iter()
            .any(|(_, r)| r.contains("not build-time data over the list")),
        "{refused:?}"
    );
}

/// A loop symbol first read inside one branch of a runtime `ifelse` and then
/// in the other: its column is defined whichever branch runs.
#[test]
fn a_loop_symbol_first_read_in_a_branch_is_defined_on_both_paths() {
    let body = json!({"op": "*", "args": [
        {"op": "ifelse", "args": [p_positive(), "k", {"op": "*", "args": [2, "k"]}]},
        wv()]});
    let compiled = super::array_tests::compile(ragged_doc(cnst(json!([2, 3, 1])), body, None));
    super::array_tests::ab(&compiled, &both_branches());
}
