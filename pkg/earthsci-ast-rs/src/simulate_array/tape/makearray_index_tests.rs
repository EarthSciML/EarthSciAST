//! `index(makearray(...), s…)` read inside a box: the makearray is a per-cell
//! array (its region values may read the box's symbols), and the oracle
//! evaluates EVERY region's value at EVERY cell of the box, cells outermost
//! in row-major order, then reads the subscripted element of the array it
//! assembled, 1-based over the makearray's bounding box. Each case is
//! compared bit for bit, with the fault the evaluation latches, against the
//! per-cell oracle and the overlay ([`ab`]); a case the tape cannot match it
//! must refuse rather than answer differently.

use super::super::ArrayCompiled;
use super::array_tests::{ab, compare_tape_at, compile, idx, lit, no_params, opcount, plus};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};

/// `D(u[k, i]) = body` over `k ∈ [1, n_lev]`, `i ∈ [1, n_ion]`, with
/// `extra` variables beside the state `u`.
fn ki_doc(n_lev: i64, n_ion: i64, body: Value, extra: Value) -> Value {
    let mut vars = json!({"u": {"type": "unknown", "shape": ["lev", "ion"]}});
    for (k, v) in extra.as_object().expect("extra variables").iter() {
        vars[k] = v.clone();
    }
    let ranges = json!({"k": [1, n_lev], "i": [1, n_ion]});
    json!({
        "esm": "2.0.0",
        "metadata": {"name": "tape_index_of_makearray"},
        "index_sets": {
            "lev": {"kind": "interval", "size": n_lev},
            "ion": {"kind": "interval", "size": n_ion}
        },
        "models": {"M": {
            "variables": vars,
            "equations": [{
                "lhs": {"op": "faq", "args": [], "output_idx": ["k", "i"], "ranges": ranges,
                        "expr": {"op": "D", "args": [idx(json!("u"), &[json!("k"), json!("i")])],
                                 "wrt": "t"}},
                "rhs": {"op": "faq", "args": [], "output_idx": ["k", "i"], "ranges": ranges,
                        "expr": body}
            }]
        }}
    })
}

fn ma(regions: Value, values: Vec<Value>) -> Value {
    json!({"op": "makearray", "args": [], "regions": regions, "values": values})
}

fn u(k: Value, i: Value) -> Value {
    idx(json!("u"), &[k, i])
}

fn minus(a: Value, b: Value) -> Value {
    json!({"op": "-", "args": [a, b]})
}

fn times(a: Value, b: Value) -> Value {
    json!({"op": "*", "args": [a, b]})
}

fn states(n: usize) -> Vec<Vec<f64>> {
    vec![
        (0..n).map(|x| 0.25 * x as f64 - 1.0).collect(),
        (0..n).map(|x| 1.5 - 0.375 * x as f64).collect(),
    ]
}

/// The tape's refusals, or none after comparing it against the oracle (and,
/// with `overlay`, the overlay against the oracle) at a few states.
fn refusals(compiled: &ArrayCompiled, overlay: bool) -> Vec<(String, String)> {
    let (prog, report) = compiled.build_tape_opts(&HashSet::new(), None);
    if prog.is_err() || !report.fallbacks.is_empty() {
        assert!(!report.fallbacks.is_empty(), "{report}");
        return report.fallbacks;
    }
    for state in states(compiled.state_variable_names().len()) {
        for t in [0.0, 0.7] {
            compare_tape_at(compiled, &HashMap::new(), &state, t, overlay);
        }
    }
    Vec::new()
}

/// Lowers, and agrees with the oracle and the overlay.
fn agrees(doc: Value) {
    let compiled = compile(doc);
    let refused = refusals(&compiled, true);
    assert!(refused.is_empty(), "refused: {refused:?}");
}

/// A region no cell reads — a constant subscript outside it, a region past
/// the box's reach, the legal empty spelling — still has its value
/// evaluated at every cell: an out-of-range const read there is the
/// oracle's fault (and `NaN` nowhere it is read).
#[test]
fn regions_no_cell_reads_still_fault() {
    let c = lit(&[10.0, 20.0, 30.0]);
    let off = idx(c.clone(), &[plus(json!("k"), json!(10))]);
    for (regions, sub) in [
        // A constant subscript outside the region.
        (json!([[[1, 1]], [[3, 3]]]), json!(1)),
        // A region past every subscript the box reaches.
        (json!([[[1, 3]], [[4, 4]]]), json!("i")),
        // The empty spelling `stop == start - 1`.
        (json!([[[1, 3]], [[3, 2]]]), json!("i")),
    ] {
        let body = idx(
            ma(regions, vec![u(json!("k"), json!(1)), off.clone()]),
            &[sub],
        );
        agrees(ki_doc(3, 3, body, json!({})));
    }
    // ...and one that cannot fault is dropped.
    let body = idx(
        ma(
            json!([[[1, 3]], [[3, 2]]]),
            vec![u(json!("k"), json!(1)), u(json!("k"), json!(2))],
        ),
        &[json!("i")],
    );
    agrees(ki_doc(3, 3, body, json!({})));
}

/// A region value that faults only at cells its region does not cover: the
/// oracle meets the fault there anyway, and at each cell in region order, so
/// a later region's fault at an earlier cell latches first.
#[test]
fn region_value_faulting_outside_its_pullback() {
    let c = lit(&[10.0, 20.0, 30.0]);
    let body = idx(
        ma(
            json!([[[1, 1]], [[2, 3]]]),
            vec![
                idx(c.clone(), &[plus(json!("i"), json!(1))]),
                idx(c, &[minus(json!("k"), json!(1))]),
            ],
        ),
        &[json!("i")],
    );
    agrees(ki_doc(3, 3, body, json!({})));
    // The only fault is the first region's, at `i = 3`, which it does not
    // cover.
    let body = idx(
        ma(
            json!([[[1, 1]], [[2, 3]]]),
            vec![
                idx(lit(&[10.0, 20.0, 30.0]), &[plus(json!("i"), json!(1))]),
                u(json!("k"), json!("i")),
            ],
        ),
        &[json!("i")],
    );
    agrees(ki_doc(3, 3, body, json!({})));
}

/// A same-rank makearray read at permuted and shifted subscripts: the region
/// values read the box's symbols at the CELL, not at the makearray's
/// coordinate. The overlay reads them at the coordinate, so only the tapes
/// are compared, against the oracle.
#[test]
fn same_rank_permuted_and_shifted_subscripts() {
    let m = ma(
        json!([[[1, 3], [1, 1]], [[1, 3], [2, 3]]]),
        vec![
            u(json!("k"), json!(1)),
            times(json!(2), u(json!("k"), json!(2))),
        ],
    );
    for (n_ion, subs) in [
        (3, vec![json!("i"), json!("k")]),
        (2, vec![json!("k"), plus(json!("i"), json!(1))]),
        (3, vec![json!("k"), json!("i")]),
    ] {
        let compiled = compile(ki_doc(3, n_ion, idx(m.clone(), &subs), json!({})));
        let refused = refusals(&compiled, false);
        assert!(refused.is_empty(), "refused: {refused:?}");
    }
    // A reversed subscript is no unit shift: refused, not answered.
    let compiled = compile(ki_doc(
        3,
        3,
        idx(m, &[minus(json!(4), json!("k")), json!("i")]),
        json!({}),
    ));
    assert!(!refusals(&compiled, false).is_empty());
}

/// A rank-2 makearray read inside a rank-1 box, at a box axis and a
/// constant.
#[test]
fn rank2_makearray_in_a_rank1_box() {
    let m = ma(
        json!([[[1, 3], [1, 1]], [[1, 3], [2, 2]]]),
        vec![
            u(json!("k"), json!(1)),
            times(json!(2), u(json!("k"), json!(3))),
        ],
    );
    let compiled = compile(json!({
        "esm": "2.0.0",
        "metadata": {"name": "tape_index_of_makearray_rank2"},
        "index_sets": {"lev": {"kind": "interval", "size": 3},
                       "ion": {"kind": "interval", "size": 3}},
        "models": {"M": {
            "variables": {
                "u": {"type": "unknown", "shape": ["lev", "ion"]},
                "v": {"type": "unknown", "shape": ["lev"]}
            },
            "equations": [
                {"lhs": {"op": "faq", "args": [], "output_idx": ["k", "i"],
                         "ranges": {"k": [1, 3], "i": [1, 3]},
                         "expr": {"op": "D", "args": [u(json!("k"), json!("i"))], "wrt": "t"}},
                 "rhs": {"op": "faq", "args": [], "output_idx": ["k", "i"],
                         "ranges": {"k": [1, 3], "i": [1, 3]},
                         "expr": idx(json!("v"), &[json!("k")])}},
                {"lhs": {"op": "faq", "args": [], "output_idx": ["k"], "ranges": {"k": [1, 3]},
                         "expr": {"op": "D", "args": [idx(json!("v"), &[json!("k")])], "wrt": "t"}},
                 "rhs": {"op": "faq", "args": [], "output_idx": ["k"], "ranges": {"k": [1, 3]},
                         "expr": plus(idx(m.clone(), &[json!("k"), json!(2)]),
                                      idx(m, &[json!("k"), json!(1)]))}}
            ]
        }}
    }));
    let refused = refusals(&compiled, true);
    assert!(refused.is_empty(), "refused: {refused:?}");
}

/// A whole-array region value of the box's rank in a rank-1 makearray: the
/// oracle's value does not fit the region and poisons the makearray with
/// `NaN`. The tape refuses it rather than placing the array over the box.
#[test]
fn whole_array_region_value_is_not_one_number_per_cell() {
    let body = idx(
        ma(
            json!([[[1, 3]], [[1, 1]]]),
            vec![json!("u"), u(json!("k"), json!(1))],
        ),
        &[json!("i")],
    );
    let compiled = compile(ki_doc(3, 3, body, json!({})));
    assert!(!refusals(&compiled, true).is_empty());
}

/// A bounding box that starts past 1: the oracle's makearray is 1-based over
/// its bounding box, so `m[i + 1]` at `i = 1` reads the region at absolute
/// coordinate 3, and at `i = 2` is past the box (the zero ghost).
#[test]
fn bounding_box_starting_past_one() {
    let m = ma(
        json!([[[2, 2]], [[3, 3]]]),
        vec![u(json!("k"), json!(1)), u(json!("k"), json!(2))],
    );
    agrees(ki_doc(
        3,
        2,
        idx(m.clone(), &[plus(json!("i"), json!(1))]),
        json!({}),
    ));
    agrees(ki_doc(3, 2, idx(m, &[json!("i")]), json!({})));
}

/// Makearrays under elementwise operations: an arithmetic wrapper, and an
/// `ifelse` choosing between two by a per-cell condition, whose untaken arm
/// the oracle never evaluates (its const read out of range must not fault).
#[test]
fn makearray_under_elementwise_operations() {
    let c = lit(&[10.0, 20.0, 30.0]);
    let a = ma(
        json!([[[1, 1]], [[2, 3]]]),
        vec![
            u(json!("k"), json!(1)),
            times(json!(2), u(json!("k"), json!(2))),
        ],
    );
    let b = ma(
        json!([[[1, 2]], [[3, 3]]]),
        vec![
            u(json!("k"), json!(3)),
            idx(c, &[plus(json!("k"), json!(1))]),
        ],
    );
    agrees(ki_doc(
        3,
        3,
        idx(plus(times(json!(2), a.clone()), json!(1)), &[json!("i")]),
        json!({}),
    ));
    let cond = json!({"op": ">", "args": [u(json!("k"), json!(1)), 0.0]});
    agrees(ki_doc(
        3,
        3,
        idx(json!({"op": "ifelse", "args": [cond, a, b]}), &[json!("i")]),
        json!({}),
    ));
}

/// Values that read none of the box's symbols make one array for every cell:
/// built once at the makearray's own rank (all literals: a constant) and
/// gathered at the subscripts, with no per-cell assembly.
#[test]
fn box_independent_values_are_built_once() {
    let body = idx(
        ma(json!([[[1, 1]], [[2, 3]]]), vec![json!(1.5), json!(2.5)]),
        &[json!("i")],
    );
    let compiled = compile(ki_doc(3, 3, body, json!({})));
    let prog = ab(&compiled, &no_params());
    assert_eq!(opcount(&prog, "Assemble"), 0);
    // Reading a state, and starting past 1.
    let body = idx(
        ma(
            json!([[[2, 2]], [[3, 4]]]),
            vec![u(json!(1), json!(1)), json!(2.5)],
        ),
        &[json!("i")],
    );
    agrees(ki_doc(3, 3, body, json!({})));
}
