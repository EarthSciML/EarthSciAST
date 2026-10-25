//! Computed-subscript gathers ([`Instr::DataGather`]): an `index` whose
//! subscripts are values computed per element — a reversed or
//! parameter-offset axis, a data-dependent `c[j[i]]`, a clamp, a `mod`/`floor`
//! unflattening, a scalar subscript computed at run time.
//!
//! Every case builds with NO fallback rule and is compared bit for bit, with
//! the fault it latches, against the per-cell oracle and the whole-array
//! overlay, on both executors, fused and unfused ([`ab`]).

use super::array_tests::{
    ab, agrees_or_refuses, compile, d_eq, doc, idx, lit, no_params, opcount, plus,
};
use super::taped;
use crate::simulate_array::ConstArrayScope;
use crate::value_invention::BoundaryKind;
use serde_json::json;
use std::collections::{HashMap, HashSet};

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
        compiled.const_scope =
            std::sync::Arc::new(ConstArrayScope::default().with_boundary("C", vec![kind]));
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

/// The data-subscript bounds test is `subscript_of` then `1..=n`, for every
/// value class, including the values a half away from a whole number.
#[test]
fn data_subscript_matches_round_then_range() {
    use super::ir::{data_subscript, subscript_of};
    let reference = |v: f64, n: usize| {
        let r = subscript_of(v);
        (r >= 1 && r <= n as i64).then(|| (r - 1) as usize)
    };
    let mut vals: Vec<f64> = vec![f64::NAN, f64::INFINITY, f64::NEG_INFINITY, -0.0, 0.0];
    for k in -3i64..70 {
        for d in [-0.5f64, 0.0, 0.5] {
            let x = k as f64 + d;
            vals.push(x);
            vals.push(f64::from_bits(x.to_bits().wrapping_add(1)));
            vals.push(f64::from_bits(x.to_bits().wrapping_sub(1)));
        }
    }
    let mut x: u64 = 0x2545F4914F6CDD1D;
    for _ in 0..200_000 {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        vals.push(f64::from_bits(x));
        vals.push((x % 1_000_003) as f64 / 7.0 - 30.0);
    }
    for n in [0usize, 1, 2, 5, 20, 64, 1000] {
        for &v in &vals {
            assert_eq!(data_subscript(v, n), reference(v, n), "{v:?} n={n}");
        }
    }
}

/// One subscript expression shared by a gather that reads only the column
/// axis (lowered over that sub-box) and by one that reads both axes: each
/// is lowered over its own box, and the program agrees with the oracle.
#[test]
fn a_shared_subscript_serves_a_sub_box_gather_and_a_full_box_gather() {
    let (nc, nl) = (4i64, 6i64);
    let cnt = json!({"op": "faq", "args": [], "output_idx": ["c"],
        "ranges": {"c": [1, nc], "l": [1, nl]}, "reduce": "+",
        "expr": {"op": "ifelse", "args": [
            {"op": ">", "args": [idx(json!("u"), &[json!("c"), json!("l")]), 0.0]}, 1.0, 0.0]}});
    let sub = json!({"op": "max", "args": [1, idx(json!("cnt"), &[json!("c")])]});
    let rhs = plus(
        idx(json!("u"), &[json!("c"), sub.clone()]),
        json!({"op": "*", "args": [
            idx(json!("u"), &[json!("c"), json!({"op": "min", "args": [json!(nl), plus(sub.clone(), json!("l"))]})]),
            sub]}),
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
    ab(&compiled, &no_params());
}

/// A data subscript that names the column axis and a bare array aligned with
/// the whole `(c, l)` box (`u[c, max(1, min(nl, w))]`): the scan for a
/// sub-box sees only `c`, and lowering over the `(c)` sub-box cannot read
/// `w`. That route then does not apply: what it emitted is undone and the
/// gather is lowered over the full box, so the rule builds, and its fused
/// and unfused programs agree bit for bit.
#[test]
fn a_failed_sub_box_lowering_falls_back_to_the_full_box() {
    let (nc, nl) = (4i64, 6i64);
    let w = json!({"op": "faq", "args": [], "output_idx": ["c", "l"],
        "ranges": {"c": [1, nc], "l": [1, nl]},
        "expr": plus(floor(idx(json!("u"), &[json!("c"), json!("l")])), json!(3))});
    let sub = json!({"op": "max", "args": [1, {"op": "min", "args": [nl, "w"]}]});
    let rhs = plus(
        json!({"op": "*", "args": [-0.1, idx(json!("u"), &[json!("c"), json!("l")])]}),
        idx(json!("u"), &[json!("c"), sub]),
    );
    let compiled = compile(doc(
        json!({
            "u": {"type": "unknown", "shape": ["c", "l"]},
            "w": {"type": "unknown", "shape": ["c", "l"]}
        }),
        vec![
            json!({"lhs": "w", "rhs": w}),
            json!({"lhs": {"op": "faq", "args": [], "output_idx": ["c", "l"],
                    "expr": {"op": "D", "args": [idx(json!("u"), &[json!("c"), json!("l")])], "wrt": "t"},
                    "ranges": {"c": [1, nc], "l": [1, nl]}},
                   "rhs": {"op": "faq", "args": [], "output_idx": ["c", "l"],
                    "ranges": {"c": [1, nc], "l": [1, nl]}, "expr": rhs}}),
        ],
    ));
    let n = compiled.state_variable_names().len();
    let pv = compiled.debug_resolve_params(&HashMap::new());
    let fused = taped(compiled.build_tape_opts(
        &HashSet::new(),
        Some(super::fuse::SuperopCfg {
            bin3: false,
            ext_pairs: true,
        }),
    ))
    .0;
    let unfused = taped(compiled.build_tape_opts(&HashSet::new(), None)).0;
    for seed in 0..3u64 {
        let state = super::tests::seeded_state(n, seed, -2.0, 2.0);
        let mut dy_f = vec![0.0f64; n];
        let mut dy_u = vec![0.0f64; n];
        super::refexec::run_reference(&fused, &compiled, &state, &pv, 0.0, &mut dy_f);
        super::refexec::run_reference(&unfused, &compiled, &state, &pv, 0.0, &mut dy_u);
        let bits = |v: &[f64]| v.iter().map(|x| x.to_bits()).collect::<Vec<_>>();
        assert_eq!(bits(&dy_f), bits(&dy_u), "seed {seed}: fused vs unfused");
    }
}

/// A filtered array `faq` whose kept cells gather a const array through a
/// per-column count, `k[c, cnt[c]]` under `filter = cnt[c] > 0`, directly
/// and inside a nested reduction: a column whose count is 0 is filtered
/// out, so its out-of-range read is never evaluated and nothing faults
/// (esm-spec §5.5.8: a filtered-out term never faults). No part of the body
/// may be evaluated ahead of the filter at the cells it excludes: native
/// agrees with the oracle, or refuses the rule when it cannot place the
/// fault behind the filter, and never raises it.
#[test]
fn a_filtered_out_const_gather_never_faults() {
    let (nc, nl, nm) = (4i64, 3i64, 3i64);
    let cnt_c = idx(json!("cnt"), &[json!("c")]);
    let gather = idx(json!("k"), &[json!("c"), cnt_c.clone()]);
    let nested = json!({"op": "faq", "args": [], "output_idx": [],
        "ranges": {"m": [1, 2]},
        "expr": {"op": "*", "args": ["m", gather.clone()]}});
    for term in [gather, nested] {
        let body = json!({"op": "faq", "args": [], "output_idx": ["c", "l"],
            "ranges": {"c": [1, nc], "l": [1, nl]},
            "filter": {"op": ">", "args": [cnt_c.clone(), 0]},
            "expr": plus(
                json!({"op": "*", "args": [-0.1, idx(json!("u"), &[json!("c"), json!("l")])]}),
                term)});
        let k: Vec<Vec<f64>> = (0..nc)
            .map(|c| (0..nm).map(|m| (c * 10 + m) as f64 + 0.5).collect())
            .collect();
        let compiled = compile(doc(
            json!({
                "u": {"type": "unknown", "shape": ["c", "l"]},
                "cnt": {"type": "unknown", "shape": ["c"]},
                "k": {"type": "unknown", "shape": ["c", "m"]}
            }),
            vec![
                json!({"lhs": "k", "rhs": {"op": "const", "args": [], "value": k}}),
                json!({"lhs": {"op": "faq", "args": [], "output_idx": ["c"],
                        "expr": {"op": "D", "args": [cnt_c.clone()], "wrt": "t"},
                        "ranges": {"c": [1, nc]}},
                       "rhs": {"op": "faq", "args": [], "output_idx": ["c"],
                        "ranges": {"c": [1, nc]}, "expr": 0.0}}),
                json!({"lhs": {"op": "faq", "args": [], "output_idx": ["c", "l"],
                        "expr": {"op": "D", "args": [idx(json!("u"), &[json!("c"), json!("l")])], "wrt": "t"},
                        "ranges": {"c": [1, nc], "l": [1, nl]}},
                       "rhs": body}),
            ],
        ));
        let counts = [1.0, 0.0, 3.0, 2.0];
        let state: Vec<f64> = compiled
            .state_variable_names()
            .iter()
            .enumerate()
            .map(|(s, name)| match name.strip_prefix("cnt[") {
                Some(rest) => counts[rest.trim_end_matches(']').parse::<usize>().unwrap() - 1],
                None => 0.25 * s as f64 - 1.0,
            })
            .collect();
        // Native either agrees with the oracle (no fault) or refuses the rule
        // at build time for the fault it cannot place; it never faults.
        let refused = agrees_or_refuses(&compiled, &no_params(), &[state]);
        assert!(
            refused.iter().all(|(rule, why)| rule == "D(u)"
                && why.contains("E_TREEWALK_CONSTARRAY_OOB")
                && why.contains("fault scan")),
            "{refused:?}"
        );
    }
}
