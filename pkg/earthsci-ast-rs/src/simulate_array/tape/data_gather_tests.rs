//! Computed-subscript gathers ([`Instr::DataGather`]): an `index` whose
//! subscripts are values computed per element — a reversed or
//! parameter-offset axis, a data-dependent `c[j[i]]`, a clamp, a `mod`/`floor`
//! unflattening, a scalar subscript computed at run time.
//!
//! Every case builds with NO fallback rule and is compared bit for bit, with
//! the fault it latches, against the per-cell oracle and the whole-array
//! overlay, on both executors, fused and unfused ([`ab`]).

use super::array_tests::{ab, compile, d_eq, doc, idx, lit, no_params, opcount, plus};
use super::taped;
use crate::simulate_array::ConstArrayScope;
use crate::value_invention::BoundaryKind;
use serde_json::json;
use std::collections::{HashMap, HashSet};
use std::rc::Rc;

fn minus(a: serde_json::Value, b: serde_json::Value) -> serde_json::Value {
    json!({"op": "-", "args": [a, b]})
}

fn floor(a: serde_json::Value) -> serde_json::Value {
    json!({"op": "floor", "args": [a]})
}

/// `floor(u[i]) + k`: a subscript the state decides, so it is known only at
/// run time (the seeded states lie in [-2, 2)).
fn state_sub(k: i64) -> serde_json::Value {
    plus(floor(idx(json!("u"), &[json!("i")])), json!(k))
}

fn params(entries: &[(&str, f64)]) -> Vec<HashMap<String, f64>> {
    vec![entries.iter().map(|(k, v)| (k.to_string(), *v)).collect()]
}

/// A reversed axis into an inline const, `c[5 - i]`, and the same through
/// a named const factor: in range at every cell, no fault.
#[test]
fn reversed_const_subscript() {
    let n = 4;
    for base in [lit(&[10.0, 20.0, 30.0, 40.0]), json!("C")] {
        let body = json!({"op": "*", "args": [
            idx(base, &[minus(json!(5), json!("i"))]),
            idx(json!("u"), &[json!("i")])]});
        let compiled = compile(doc(
            json!({
                "u": {"type": "unknown", "shape": ["i"]},
                "C": {"type": "unknown", "shape": ["c"]}
            }),
            vec![
                json!({"lhs": "C", "rhs": lit(&[1.0, 2.0, 3.0, 4.0])}),
                d_eq("u", n, body),
            ],
        ));
        let prog = ab(&compiled, &no_params());
        assert_eq!(opcount(&prog, "Fault"), 0);
    }
}

/// `C[o + i]` with `o` a tunable parameter: in range at `o = 0`, and at
/// `o = 1` the last cell reads past the end — `NaN` there and the oracle's
/// fault — with no recompilation between the two.
#[test]
fn parameter_offset_into_a_const_faults_where_the_oracle_does() {
    let n = 4;
    let body = idx(json!("C"), &[plus(json!("o"), json!("i"))]);
    let compiled = compile(doc(
        json!({
            "u": {"type": "unknown", "shape": ["i"]},
            "o": {"type": "parameter", "default": 0.0},
            "C": {"type": "unknown", "shape": ["c"]}
        }),
        vec![
            json!({"lhs": "C", "rhs": lit(&[1.0, 2.0, 3.0, 4.0])}),
            d_eq("u", n, body),
        ],
    ));
    let mut maps = params(&[("o", 0.0)]);
    maps.extend(params(&[("o", 1.0)]));
    maps.extend(params(&[("o", -1.0)]));
    maps.extend(params(&[("o", 0.6)]));
    let prog = ab(&compiled, &maps);
    assert_eq!(opcount(&prog, "DataGather"), 1);
}

/// A data-dependent gather from the state, `C[floor(u[i]) + 3]` (in range)
/// and `C[floor(u[i]) + 4]` (past the end where `u >= 1`): two sites in one
/// rule, so the fault latched is the one at the oracle's first faulting
/// cell, whichever site the tape evaluates first.
#[test]
fn state_dependent_const_gathers_latch_the_oracles_first_fault() {
    let n = 6;
    for body in [
        idx(json!("C"), &[state_sub(3)]),
        plus(
            idx(json!("C"), &[state_sub(4)]),
            idx(json!("C"), &[state_sub(1)]),
        ),
        plus(
            idx(json!("C"), &[state_sub(1)]),
            idx(json!("C"), &[state_sub(4)]),
        ),
    ] {
        let compiled = compile(doc(
            json!({
                "u": {"type": "unknown", "shape": ["i"]},
                "C": {"type": "unknown", "shape": ["c"]}
            }),
            vec![
                json!({"lhs": "C", "rhs": lit(&[1.0, 2.0, 3.0, 4.0])}),
                d_eq("u", n, body),
            ],
        ));
        ab(&compiled, &no_params());
    }
}

/// A build-time-certain fault (`C[i - 1]` at the first cell) and a
/// run-time one in the same rule: whichever the oracle reaches first is the
/// one latched.
#[test]
fn a_certain_fault_and_a_run_time_fault_in_one_rule() {
    let n = 5;
    for body in [
        plus(
            idx(json!("C"), &[state_sub(4)]),
            idx(json!("C"), &[minus(json!("i"), json!(1))]),
        ),
        plus(
            idx(json!("C"), &[plus(json!("i"), json!(1))]),
            idx(json!("C"), &[state_sub(4)]),
        ),
    ] {
        let compiled = compile(doc(
            json!({
                "u": {"type": "unknown", "shape": ["i"]},
                "C": {"type": "unknown", "shape": ["c"]}
            }),
            vec![
                json!({"lhs": "C", "rhs": lit(&[1.0, 2.0, 3.0, 4.0, 5.0])}),
                d_eq("u", n, body),
            ],
        ));
        ab(&compiled, &no_params());
    }
}

/// Under a declared `clamp` or `periodic` policy a run-time subscript past
/// the end resolves, and nothing faults.
#[test]
fn run_time_subscript_under_a_boundary_policy() {
    let n = 6;
    for kind in [BoundaryKind::Clamp, BoundaryKind::Periodic] {
        let body = plus(
            idx(json!("C"), &[state_sub(4)]),
            idx(json!("C"), &[state_sub(-1)]),
        );
        let mut compiled = compile(doc(
            json!({
                "u": {"type": "unknown", "shape": ["i"]},
                "C": {"type": "unknown", "shape": ["c"]}
            }),
            vec![
                json!({"lhs": "C", "rhs": lit(&[1.0, 2.0, 3.0, 4.0])}),
                d_eq("u", n, body),
            ],
        ));
        compiled.const_scope = Rc::new(ConstArrayScope::default().with_boundary("C", vec![kind]));
        let prog = ab(&compiled, &no_params());
        assert!(
            prog.data_gathers.iter().all(|g| g.order.is_none()),
            "{kind:?}: a resolving policy cannot fault"
        );
    }
}

/// A clamp written into the subscript, `C[min(4, max(1, i + 1))]`, and the
/// state's own zero ghost read through a data subscript past either end.
#[test]
fn clamped_and_zero_ghost_subscripts() {
    let n = 5;
    let clamp =
        json!({"op": "min", "args": [4, {"op": "max", "args": [1, plus(json!("i"), json!(1))]}]});
    for body in [
        idx(json!("C"), &[clamp]),
        idx(json!("u"), &[state_sub(2)]),
        idx(json!("u"), &[minus(json!(6), json!("i"))]),
    ] {
        let compiled = compile(doc(
            json!({
                "u": {"type": "unknown", "shape": ["i"]},
                "C": {"type": "unknown", "shape": ["c"]}
            }),
            vec![
                json!({"lhs": "C", "rhs": lit(&[1.0, 2.0, 3.0, 4.0])}),
                d_eq("u", n, body),
            ],
        ));
        ab(&compiled, &no_params());
    }
}

/// A rank-2 source unflattened by `mod`/`floor` subscripts, from a const and
/// from an observed (zero ghost), the rrtm `pfrac_flat` shape.
#[test]
fn mod_floor_unflattening() {
    let n = 6;
    let row = plus(
        json!(1),
        minus(
            minus(json!("i"), json!(1)),
            json!({"op": "*", "args": [2, floor(json!({"op": "/", "args": [minus(json!("i"), json!(1)), 2]}))]}),
        ),
    );
    let col = plus(
        json!(1),
        floor(json!({"op": "/", "args": [minus(json!("i"), json!(1)), 2]})),
    );
    for base in ["Q", "X"] {
        let body = json!({"op": "*", "args": [
            idx(json!(base), &[row.clone(), col.clone()]),
            idx(json!("u"), &[json!("i")])]});
        let compiled = compile(doc(
            json!({
                "u": {"type": "unknown", "shape": ["i"]},
                "Q": {"type": "unknown", "shape": ["g", "l"]},
                "X": {"type": "unknown", "shape": ["g", "l"]}
            }),
            vec![
                json!({"lhs": "Q", "rhs": json!({"op": "const", "args": [],
                    "value": [[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]]})}),
                json!({"lhs": "X", "rhs": {"op": "faq", "args": [], "output_idx": ["a", "b"],
                    "ranges": {"a": [1, 2], "b": [1, 3]},
                    "expr": {"op": "*", "args": [2.0, idx(json!("Q"), &[json!("a"), json!("b")])]}}}),
                d_eq("u", n, body),
            ],
        ));
        ab(&compiled, &no_params());
    }
}

/// A data subscript over a rank-2 box (the gather's subscripts are arrays
/// over both axes), and a repeated output symbol (a diagonal).
#[test]
fn rank_2_box_and_diagonal() {
    let n = 3;
    let lhs = json!({"op": "faq", "args": [], "output_idx": ["i", "j"],
        "expr": {"op": "D", "args": [idx(json!("u"), &[json!("i"), json!("j")])], "wrt": "t"},
        "ranges": {"i": [1, n], "j": [1, n]}});
    let sub = plus(floor(idx(json!("u"), &[json!("i"), json!("j")])), json!(3));
    for expr in [
        idx(json!("C"), &[sub.clone(), json!("j")]),
        idx(json!("u"), &[json!("j"), json!("j")]),
        idx(json!("C"), &[json!("i"), json!("i")]),
    ] {
        let rhs = json!({"op": "faq", "args": [], "output_idx": ["i", "j"],
            "ranges": {"i": [1, n], "j": [1, n]}, "expr": expr});
        let compiled = compile(doc(
            json!({
                "u": {"type": "unknown", "shape": ["i", "j"]},
                "C": {"type": "unknown", "shape": ["a", "b"]}
            }),
            vec![
                json!({"lhs": "C", "rhs": json!({"op": "const", "args": [],
                    "value": [[1.0, 2.0, 3.0], [4.0, 5.0, 6.0], [7.0, 8.0, 9.0], [10.0, 11.0, 12.0]]})}),
                json!({"lhs": lhs.clone(), "rhs": rhs}),
            ],
        ));
        ab(&compiled, &no_params());
    }
}

/// A scalar rule read at a subscript computed at run time (the YSU
/// `Ri1[kpbl1 - 1]` shape), from an observed and from a const, with the
/// subscript inside and outside the source.
#[test]
fn scalar_subscript_computed_at_run_time() {
    let n = 4;
    for (base, k) in [("X", 0.0), ("X", 2.0), ("X", 9.0), ("C", 2.0), ("C", 5.0)] {
        let compiled = compile(doc(
            json!({
                "u": {"type": "unknown", "shape": ["i"]},
                "kp": {"type": "parameter", "default": 1.0},
                "C": {"type": "unknown", "shape": ["c"]},
                "X": {"type": "unknown", "shape": ["c"]},
                "s": {"type": "unknown"}
            }),
            vec![
                json!({"lhs": "C", "rhs": lit(&[1.0, 2.0, 3.0, 4.0])}),
                json!({"lhs": "X", "rhs": {"op": "faq", "args": [], "output_idx": ["a"],
                    "ranges": {"a": [1, 4]},
                    "expr": {"op": "*", "args": [3.0, idx(json!("C"), &[json!("a")])]}}}),
                json!({"lhs": "s", "rhs": idx(json!(base), &[minus(floor(json!("kp")), json!(1))])}),
                d_eq(
                    "u",
                    n,
                    json!({"op": "*", "args": ["s", idx(json!("u"), &[json!("i")])]}),
                ),
            ],
        ));
        let prog = ab(&compiled, &params(&[("kp", k)]));
        assert_eq!(opcount(&prog, "DataGather"), 1, "{base} {k}");
    }
}

/// The tape is independent of the box: the same instruction count at 16
/// and at 256 cells.
#[test]
fn computed_subscript_gathers_do_not_grow_with_the_box() {
    let build = |n: i64| {
        compile(doc(
            json!({
                "u": {"type": "unknown", "shape": ["i"]},
                "o": {"type": "parameter", "default": 0.0},
                "C": {"type": "unknown", "shape": ["c"]}
            }),
            vec![
                json!({"lhs": "C", "rhs": {"op": "faq", "args": [], "output_idx": ["a"],
                    "ranges": {"a": [1, n]}, "expr": json!("a")}}),
                d_eq(
                    "u",
                    n,
                    plus(
                        idx(json!("C"), &[minus(json!(n + 1), json!("i"))]),
                        idx(json!("u"), &[plus(json!("o"), json!("i"))]),
                    ),
                ),
            ],
        ))
    };
    let len = |n: i64| {
        taped(build(n).build_tape_opts(&HashSet::new(), None))
            .0
            .instrs
            .len()
    };
    assert_eq!(len(16), len(256));
    ab(&build(16), &params(&[("o", 1.0)]));
}

/// A run-time-subscript const gather in an elementwise `ifelse` arm faults
/// only at the cells whose condition takes that arm: the rule's fault scan
/// checks those, in the oracle's order, against the rule's other faults.
#[test]
fn guarded_run_time_subscript_faults_only_where_taken() {
    let n = 6;
    let pos = json!({"op": ">", "args": [idx(json!("u"), &[json!("i")]), 0.0]});
    for body in [
        json!({"op": "ifelse", "args": [pos.clone(), idx(json!("C"), &[state_sub(3)]), 0.0]}),
        json!({"op": "ifelse", "args": [pos.clone(), 0.0, idx(json!("C"), &[state_sub(4)])]}),
        json!({"op": "ifelse", "args": [pos.clone(), idx(json!("C"), &[plus(json!("o"), json!("i"))]), 1.0]}),
        plus(
            json!({"op": "ifelse", "args": [pos, idx(json!("C"), &[state_sub(4)]), 0.0]}),
            idx(json!("C"), &[plus(json!("o"), json!("i"))]),
        ),
    ] {
        let compiled = compile(doc(
            json!({
                "u": {"type": "unknown", "shape": ["i"]},
                "o": {"type": "parameter", "default": 0.0},
                "C": {"type": "unknown", "shape": ["c"]}
            }),
            vec![
                json!({"lhs": "C", "rhs": lit(&[1.0, 2.0, 3.0, 4.0, 5.0, 6.0])}),
                d_eq("u", n, body),
            ],
        ));
        let mut maps = params(&[("o", 0.0)]);
        maps.extend(params(&[("o", 2.0)]));
        ab(&compiled, &maps);
    }
}

/// The subscript rounding is `f64::round` then the saturating conversion,
/// the interpreter's `eval_index_args`, for every value class.
#[test]
fn subscript_rounding_matches_round() {
    let mut vals = vec![
        0.0,
        -0.0,
        0.5,
        -0.5,
        1.5,
        -1.5,
        2.5,
        0.49999999999999994,
        -0.49999999999999994,
        1e15 + 0.5,
        -1e15 - 0.5,
        3.9e15 + 0.5,
        4.0e15,
        4.5e15,
        1e300,
        -1e300,
        f64::NAN,
        f64::INFINITY,
        f64::NEG_INFINITY,
        f64::MIN_POSITIVE,
        9.2e18,
        -9.3e18,
    ];
    let mut x: u64 = 0x9E3779B97F4A7C15;
    for _ in 0..200_000 {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        let v = f64::from_bits(x);
        vals.push(v);
        vals.push((x % 4001) as f64 / 8.0 - 250.0);
    }
    for v in vals {
        assert_eq!(super::ir::subscript_of(v), v.round() as i64, "{v:?}");
    }
}

/// A per-column count used as a subscript (`u[c, max(1, cnt[c])]`, the
/// kpbl shape) over a column-major state: the contraction's box is laid out
/// with the state, and the gather folds into the group that computes its
/// subscript — and the program still agrees with the oracle.
#[test]
fn a_column_count_subscript_folds_into_its_group() {
    let (nc, nl) = (5i64, 7i64);
    let cnt = json!({"op": "faq", "args": [], "output_idx": ["c"],
        "ranges": {"c": [1, nc], "l": [1, nl]}, "reduce": "+",
        "expr": {"op": "ifelse", "args": [
            {"op": ">", "args": [idx(json!("u"), &[json!("c"), json!("l")]), 0.0]}, 1.0, 0.0]}});
    let rhs = plus(
        json!({"op": "*", "args": [-0.1, idx(json!("u"), &[json!("c"), json!("l")])]}),
        idx(
            json!("u"),
            &[
                json!("c"),
                json!({"op": "max", "args": [1, idx(json!("cnt"), &[json!("c")])]}),
            ],
        ),
    );
    let compiled = compile(doc(
        json!({
            "u": {"type": "unknown", "shape": ["c", "l"]},
            "cnt": {"type": "unknown", "shape": ["c"]}
        }),
        vec![
            json!({"lhs": "cnt", "rhs": cnt}),
            json!({"lhs": {"op": "faq", "args": [], "output_idx": ["c", "l"],
                    "expr": {"op": "D", "args": [idx(json!("u"), &[json!("c"), json!("l")])], "wrt": "t"},
                    "ranges": {"c": [1, nc], "l": [1, nl]}},
                   "rhs": {"op": "faq", "args": [], "output_idx": ["c", "l"],
                    "ranges": {"c": [1, nc], "l": [1, nl]}, "expr": rhs}}),
        ],
    ));
    let prog = ab(&compiled, &no_params());
    assert!(prog.col_major);
    assert_eq!(opcount(&prog, "IndexGather"), 0, "the gather is folded");
    assert_eq!(
        opcount(&prog, "Gather"),
        0,
        "no transposed copy of the state"
    );
}
