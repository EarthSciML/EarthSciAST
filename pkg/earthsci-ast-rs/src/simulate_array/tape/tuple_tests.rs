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
        let prog = ab_check(corpus(rel), -2.0, 2.0);
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
        let prog = ab_check(self_join_doc(n), -2.0, 2.0);
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
    let prog = ab_check(doc, -3.0, 3.0);
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
    let prog = ab_check(doc, -2.0, 2.0);
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
    let prog = ab_check(doc, -2.0, 2.0);
    assert_eq!(count(&prog, "SegReduce"), 1);
    assert_eq!(prog.seg_tables[0].rows, vec![0, 2, 5, 6]);
    // The gather of `u` sees one ghost: row 2's member 5 lies past node 4.
    // A column-major program stores `u`'s box axis-reversed (`layout`).
    let u_box: [usize; 2] = if prog.col_major { [2, 4] } else { [4, 2] };
    let ghosts: usize = prog
        .gather_tables
        .iter()
        .filter(|t| t.src_shape[..] == u_box)
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

/// A fault site in a filtered body is reached only at the tuples the filter
/// keeps: with no earlier fault to settle it the tape refuses, rather than
/// raising the fault where the oracle (every tuple excluded) raises none. The
/// fault is `index(p, 1)` on the scalar parameter, inside the base of a
/// gather.
#[test]
fn a_fault_in_a_filtered_tuple_body_is_not_certain() {
    let base =
        json!({"op": "+", "args": [cnst(json!([1.0, 2.0, 3.0])), idx(json!("p"), &[json!(1)])]});
    let body =
        json!({"op": "*", "args": [idx(base, &[json!("k")]), idx(json!("v"), &[json!("k")])]});
    let filter = json!({"op": ">", "args": [idx(json!("v"), &[json!("k")]), 0]});
    let compiled =
        super::array_tests::compile(ragged_doc(cnst(json!([2, 3, 1])), body, Some(filter)));
    let refused = agrees_or_refuses(&compiled, &both_branches(), &states());
    assert!(
        refused
            .iter()
            .any(|(_, r)| r.starts_with("fault: `E_TREEWALK_INDEX_ON_SCALAR`")),
        "{refused:?}"
    );
}

/// A gather from a const array with an EMPTY axis under a boundary policy:
/// no index can be wrapped or clamped into it, so, as `index_into` does, the
/// build treats it as out of range whatever the policy (and refuses) rather
/// than dividing by the empty extent.
#[test]
fn a_tuple_gather_from_an_empty_const_axis_is_refused_under_any_policy() {
    use crate::simulate_array::ConstArrayScope;
    use crate::value_invention::BoundaryKind;
    for kind in [BoundaryKind::Periodic, BoundaryKind::Clamp] {
        let body = json!({"op": "*", "args": [idx(json!("C"), &[json!("k")]), idx(json!("v"), &[json!("i")])]});
        let mut doc = ragged_doc(cnst(json!([2, 3, 1])), body, None);
        doc["index_sets"]["none"] = json!({"kind": "interval", "size": 0});
        doc["models"]["M"]["variables"]["C"] =
            json!({"type": "unknown", "units": "1", "shape": ["none"]});
        doc["models"]["M"]["equations"]
            .as_array_mut()
            .unwrap()
            .push(json!({"lhs": "C", "rhs": cnst(json!([]))}));
        let mut compiled = super::array_tests::compile(doc);
        let scope: ConstArrayScope = (*compiled.const_scope).clone();
        compiled.const_scope = std::sync::Arc::new(scope.with_boundary("C", vec![kind]));
        let refused = agrees_or_refuses(&compiled, &both_branches(), &states());
        assert!(!refused.is_empty(), "{kind:?}");
    }
}

// ---------------------------------------------------------------------------
// The tuple-list budget: a CONST contraction is folded a sub-box at a time.
// ---------------------------------------------------------------------------

/// F58's star join (EarthSciML/EarthSciAST#418), scaled down: `total[o, f]`
/// sums `val[a] * w[f]` over the `n_big / n_key` fact rows sharing output row
/// `o`'s key, for every value of a free axis `f` the join does not gate. The
/// tuple list is `n_out * n_free * n_big / n_key` long. The values span
/// magnitudes, so a fold in another order would show in the low bits, and a
/// state reads the result so that the interpreter is the reference.
fn star_join_doc(
    n_big: usize,
    n_key: usize,
    n_out: usize,
    n_free: usize,
    reads_state: bool,
) -> Value {
    let key: Vec<f64> = (0..n_big).map(|a| (a % n_key + 1) as f64).collect();
    let val: Vec<f64> = (0..n_big)
        .map(|a| (1.0 + 0.37 * a as f64) * 10f64.powi((a % 7) as i32 - 3))
        .collect();
    let okey: Vec<f64> = (0..n_out).map(|o| (o % n_key + 1) as f64).collect();
    let w: Vec<f64> = (0..n_free).map(|f| 0.5 + f as f64 / 3.0).collect();
    let of = json!({"o": {"from": "outs"}, "f": {"from": "frees"}});
    let factor = if reads_state {
        idx(json!("y"), &[json!("o"), json!("f")])
    } else {
        idx(json!("w"), &[json!("f")])
    };
    json!({
        "esm": "1.1.0",
        "metadata": {"name": "star_join_budget", "authors": ["tape tests"]},
        "index_sets": {
            "bigs": {"kind": "interval", "size": n_big},
            "outs": {"kind": "interval", "size": n_out},
            "frees": {"kind": "interval", "size": n_free}
        },
        "models": {"M": {
            "variables": {
                "key": {"type": "unknown", "units": "1", "shape": ["bigs"]},
                "val": {"type": "unknown", "units": "1", "shape": ["bigs"]},
                "okey": {"type": "unknown", "units": "1", "shape": ["outs"]},
                "w": {"type": "unknown", "units": "1", "shape": ["frees"]},
                "total": {"type": "unknown", "units": "1", "shape": ["outs", "frees"]},
                "y": {"type": "unknown", "units": "1", "shape": ["outs", "frees"], "default": 1.0}
            },
            "equations": [
                {"lhs": "key", "rhs": cnst(json!(key))},
                {"lhs": "val", "rhs": cnst(json!(val))},
                {"lhs": "okey", "rhs": cnst(json!(okey))},
                {"lhs": "w", "rhs": cnst(json!(w))},
                {"lhs": "total", "rhs": {"op": "faq", "args": [], "semiring": "sum_product",
                    "output_idx": ["o", "f"],
                    "ranges": {"o": {"from": "outs"}, "f": {"from": "frees"}, "a": {"from": "bigs"}},
                    "join": [{"on": [["okey", "key"]]}],
                    "expr": {"op": "*", "args": [idx(json!("val"), &[json!("a")]), factor]}}},
                {"lhs": {"op": "faq", "args": [], "output_idx": ["o", "f"], "ranges": of,
                         "expr": {"op": "D", "args": [idx(json!("y"), &[json!("o"), json!("f")])], "wrt": "t"}},
                 "rhs": {"op": "faq", "args": [], "output_idx": ["o", "f"], "ranges": of,
                         "expr": {"op": "-", "args": [
                             idx(json!("total"), &[json!("o"), json!("f")]),
                             idx(json!("y"), &[json!("o"), json!("f")])]}}}
            ]
        }}
    })
}

/// Every element the program holds that grows with a tuple list: its
/// constant payloads, its gather position tables, its segment tables and its
/// slab.
fn materialized_elems(prog: &TapeProgram) -> usize {
    prog.const_data
        .iter()
        .map(|c| c.values.len())
        .sum::<usize>()
        + prog
            .gather_tables
            .iter()
            .map(|g| g.pos.len())
            .sum::<usize>()
        + prog.seg_tables.iter().map(|s| s.rows.len()).sum::<usize>()
        + prog.slab.total_elems
}

/// Over the tuple-list budget, a CONST join contraction is folded at build
/// time a sub-box at a time and the program holds only its answer: what the
/// program materializes no longer grows with the candidate pairs the join
/// matches (it did, by ~115 bytes a tuple, which took F58's control from 34
/// to 445 bytes a pair), and the answer is bit-identical to the
/// interpreter's under both arms (`ab_check`).
#[test]
fn a_join_over_the_tuple_list_budget_folds_and_stops_growing_with_its_pairs() {
    use super::lower::set_tuple_list_budget;
    let (n_big, n_out, n_free) = (2400usize, 24usize, 3usize);
    let mut folded = Vec::new();
    let mut whole = Vec::new();
    // Ten times the pairs between the two sizes, the same declared arrays.
    for n_key in [24usize, 3] {
        let tuples = n_out * n_free * (n_big / n_key);
        let prev = set_tuple_list_budget(usize::MAX);
        let prog = ab_check(star_join_doc(n_big, n_key, n_out, n_free, false), -2.0, 2.0);
        set_tuple_list_budget(prev);
        assert_eq!(
            count(&prog, "SegReduce"),
            1,
            "n_key = {n_key}: under budget"
        );
        assert_eq!(prog.seg_tables[0].rows.last().copied(), Some(tuples as u32));
        whole.push(materialized_elems(&prog));

        // A budget of two cells' runs (chunks that split the free axis
        // inside one output row), and one of a third of a cell's run (each
        // cell folded in windows, carrying its accumulator).
        let mut sizes = Vec::new();
        for b in [2 * n_big / n_key, n_big / n_key / 3] {
            let prev = set_tuple_list_budget(b);
            let prog = ab_check(star_join_doc(n_big, n_key, n_out, n_free, false), -2.0, 2.0);
            set_tuple_list_budget(prev);
            assert_eq!(count(&prog, "SegReduce"), 0, "n_key = {n_key}, budget {b}");
            assert!(prog.gather_tables.is_empty() && prog.seg_tables.is_empty());
            sizes.push(materialized_elems(&prog));
        }
        assert_eq!(sizes[0], sizes[1]);
        folded.push(sizes[0]);
    }
    assert!(
        whole[1] > 5 * whole[0],
        "the control: a whole list grows with its pairs {whole:?}"
    );
    assert_eq!(folded[0], folded[1], "a folded join grew with its pairs");
    assert!(folded[1] * 10 < whole[1], "{folded:?} vs {whole:?}");
}

/// A contraction that reads a STATE is not build-time data: over the budget it
/// keeps the whole tuple list rather than being folded, and still agrees.
#[test]
fn a_join_reading_a_state_is_not_folded_over_the_budget() {
    use super::lower::set_tuple_list_budget;
    let prev = set_tuple_list_budget(8);
    let prog = ab_check(star_join_doc(240, 3, 6, 2, true), -2.0, 2.0);
    set_tuple_list_budget(prev);
    assert_eq!(count(&prog, "SegReduce"), 1);
}

/// The budget is the PROGRAM's, not a list's: two joins that each fit it
/// alone but not together keep the first list and fold the second. A list's
/// arrays live as long as the program, so a per-list cap would let a hundred
/// lists cost a hundred times it.
#[test]
fn the_tuple_list_budget_is_shared_by_every_list_in_a_program() {
    use super::lower::set_tuple_list_budget;
    let (n_big, n_key, n_out, n_free) = (600usize, 6usize, 12usize, 2usize);
    let tuples = n_out * n_free * (n_big / n_key);
    let mut doc = star_join_doc(n_big, n_key, n_out, n_free, false);
    let model = &mut doc["models"]["M"];
    model["variables"]["total2"] = model["variables"]["total"].clone();
    model["variables"]["z"] = model["variables"]["y"].clone();
    let eqs = model["equations"].as_array_mut().unwrap();
    let mut second = eqs[4].clone();
    second["lhs"] = json!("total2");
    second["rhs"]["expr"]["args"][0] = idx(json!("key"), &[json!("a")]);
    let mut ode = eqs[5].clone();
    ode["lhs"]["expr"]["args"][0]["args"][0] = json!("z");
    ode["rhs"]["expr"]["args"][0]["args"][0] = json!("total2");
    ode["rhs"]["expr"]["args"][1]["args"][0] = json!("z");
    eqs.push(second);
    eqs.push(ode);
    for (budget, lists) in [(2 * tuples, 2), (tuples, 1)] {
        let prev = set_tuple_list_budget(budget);
        let prog = ab_check(doc.clone(), -2.0, 2.0);
        set_tuple_list_budget(prev);
        assert_eq!(count(&prog, "SegReduce"), lists, "budget {budget}");
    }
}

/// Add to a [`star_join_doc`] a rank-0 contraction `name` over the same
/// join, `Σ_{o, a : okey[o] = key[a]} val[a]`, and a scalar state `z`
/// relaxing to it. Its list holds `n_out · n_big / n_key` tuples.
fn with_grand_total(mut doc: Value, name: &str) -> Value {
    let model = &mut doc["models"]["M"];
    model["variables"][name] = json!({"type": "unknown", "units": "1"});
    model["variables"]["z"] = json!({"type": "unknown", "units": "1", "default": 1.0});
    let eqs = model["equations"].as_array_mut().unwrap();
    eqs.push(
        json!({"lhs": name, "rhs": {"op": "faq", "args": [], "semiring": "sum_product",
        "output_idx": [],
        "ranges": {"o": {"from": "outs"}, "a": {"from": "bigs"}},
        "join": [{"on": [["okey", "key"]]}],
        "expr": idx(json!("val"), &[json!("a")])}}),
    );
    eqs.push(json!({"lhs": {"op": "D", "args": ["z"], "wrt": "t"},
        "rhs": {"op": "-", "args": [name, "z"]}}));
    doc
}

/// A rank-0 contraction is one cell, so over the budget its run is folded a
/// window at a time into a literal, bit-identical to the interpreter's,
/// rather than materialized whole.
#[test]
fn a_rank_zero_join_over_the_tuple_list_budget_folds_in_windows() {
    use super::lower::set_tuple_list_budget;
    let (n_big, n_key, n_out, n_free) = (600usize, 6usize, 12usize, 2usize);
    let grand = n_out * (n_big / n_key);
    let doc = with_grand_total(star_join_doc(n_big, n_key, n_out, n_free, false), "grand");
    let prev = set_tuple_list_budget(usize::MAX);
    let prog = ab_check(doc.clone(), -2.0, 2.0);
    set_tuple_list_budget(prev);
    assert_eq!(count(&prog, "SegReduce"), 2, "under budget");
    // Two windows, several, and one tuple a window. Under any budget that
    // holds `grand`'s list, `grand` (lowered first, by name) would keep it.
    for budget in [grand - 1, grand / 7, 1] {
        let prev = set_tuple_list_budget(budget);
        let prog = ab_check(doc.clone(), -2.0, 2.0);
        set_tuple_list_budget(prev);
        assert_eq!(count(&prog, "SegReduce"), 0, "budget {budget}");
        assert!(prog.seg_tables.is_empty(), "budget {budget}");
    }
}

/// The tape PRICES an `on` gate before building it, as the interpreter's
/// planner does (PR #423): a clause whose key barely discriminates — here a
/// constant, so it matches the whole product — is declined once a selective
/// sibling already drives, and its equality is left to the filter. Building it
/// anyway is how a six-valued key against a 1.4-million-row table came to
/// hold a 1.2-billion-pair index under `native`. Same answer either way
/// (`ab_check`), and the same tuple list, since the declined clause admits
/// every pair.
#[test]
fn an_uneconomic_on_gate_is_declined_when_a_sibling_drives() {
    let n = 200usize;
    // `k` matches 20 of the 40 000 pairs; `c` matches all of them.
    let kl: Vec<f64> = (1..=n).map(|i| i as f64).collect();
    let kr: Vec<f64> = (1..=n)
        .map(|i| if i <= 20 { i as f64 } else { (1000 + i) as f64 })
        .collect();
    let ones = vec![1.0f64; n];
    let doc = json!({
        "esm": "1.1.0",
        "metadata": {"name": "gate_planner", "authors": ["tape tests"]},
        "index_sets": {"ls": {"kind": "interval", "size": n}, "rs": {"kind": "interval", "size": n}},
        "models": {"M": {
            "variables": {
                "kl": {"type": "unknown", "units": "1", "shape": ["ls"]},
                "kr": {"type": "unknown", "units": "1", "shape": ["rs"]},
                "cl": {"type": "unknown", "units": "1", "shape": ["ls"]},
                "cr": {"type": "unknown", "units": "1", "shape": ["rs"]},
                "v": {"type": "unknown", "units": "1", "shape": ["rs"], "default": 1.0},
                "total": {"type": "unknown", "units": "1", "default": 0.0}
            },
            "equations": [
                {"lhs": "kl", "rhs": cnst(json!(kl))},
                {"lhs": "kr", "rhs": cnst(json!(kr))},
                {"lhs": "cl", "rhs": cnst(json!(ones))},
                {"lhs": "cr", "rhs": cnst(json!(ones))},
                {"lhs": {"op": "faq", "args": [], "output_idx": ["j"],
                         "expr": {"op": "D", "args": [idx(json!("v"), &[json!("j")])], "wrt": "t"},
                         "ranges": {"j": {"from": "rs"}}},
                 "rhs": {"op": "faq", "args": [], "output_idx": ["j"], "ranges": {"j": {"from": "rs"}},
                         "expr": {"op": "*", "args": [-0.5, idx(json!("v"), &[json!("j")])]}}},
                {"lhs": {"op": "D", "args": ["total"], "wrt": "t"},
                 "rhs": {"op": "faq", "args": [], "output_idx": [], "semiring": "sum_product",
                         "ranges": {"l": {"from": "ls"}, "r": {"from": "rs"}},
                         "join": [{"on": [["cl", "cr"]]}, {"on": [["kl", "kr"]]}],
                         "expr": {"op": "*", "args": [
                             idx(json!("kl"), &[json!("l")]),
                             idx(json!("v"), &[json!("r")])]}}}
            ]
        }}
    });
    let declines = crate::broad_phase::gate_plan_declines;
    // The default floor keeps a gate this small; with no floor it is declined.
    let before = declines();
    let prog = ab_check(doc.clone(), -2.0, 2.0);
    assert_eq!(declines(), before, "under the floor nothing is declined");
    assert_eq!(prog.seg_tables[0].rows, vec![0, 20]);
    let prev = crate::broad_phase::set_gate_plan(4, 0);
    let prog = ab_check(doc.clone(), -2.0, 2.0);
    // One tape build on its own, so no interpreter evaluation is counted.
    let compiled = super::tests::compile(doc);
    let before = declines();
    let built = compiled.build_tape_opts(&std::collections::HashSet::new(), None);
    let declined = declines() - before;
    crate::broad_phase::set_gate_plan(prev.0, prev.1);
    assert!(built.0.is_ok());
    assert_eq!(declined, 1, "the constant-key gate was built");
    assert_eq!(
        prog.seg_tables[0].rows,
        vec![0, 20],
        "the selective gate still drives"
    );
}

/// A ragged `+` contraction is seeded from `0` like every other (esm-spec
/// §4.3.1): a row whose terms are all `-0.0` sums to `+0.0`, one term or
/// several, on the tape and in the interpreter.
#[test]
fn an_all_negative_zero_ragged_row_sums_to_positive_zero() {
    let body = json!({"op": "-", "args": [{"op": "*", "args": [0.0, {"op": "exp", "args": [
        idx(json!("v"), &[idx(json!("cols"), &[json!("i"), json!("k")])])]}]}]});
    for cnt in [json!([2, 3, 1]), json!([1, 1, 1])] {
        let doc = ragged_doc(cnst(cnt), body.clone(), None);
        let prog = ab_check(doc.clone(), -2.0, 2.0);
        assert_eq!(count(&prog, "SegReduce"), 1);
        let compiled = super::array_tests::compile(doc);
        for state in states() {
            let (dy, _) = compiled.debug_eval_rhs(&state, 0.0, &HashMap::new(), false);
            assert!(dy.iter().all(|v| v.to_bits() == 0), "{dy:?}");
        }
    }
}
