//! The array forms the tape lowers without per-cell work: const-array gathers
//! that leave the array (a boundary policy or the fail-closed fault), a
//! `makearray` region whose value covers only the region's non-singleton axes,
//! empty boxes and regions, the whole-array shape ops (`reshape`,
//! `transpose`, `concat`, positional broadcast), a filtered rank-0
//! reduction, and a shaped observed defined by a scalar-condition `ifelse`.
//!
//! Every case builds with NO fallback rule and is compared bit for bit
//! against the per-cell oracle (the `interpreter` compiler) and the
//! whole-array overlay, on the reference executor and on the fast executor,
//! fused and unfused — together with the fault the evaluation latches, which
//! is part of what the interpreter answers.

use super::super::{ArrayCompiled, ConstArrayScope, RhsScratch, RhsStats};
use super::ir::*;
use super::refexec::run_reference;
use super::taped;
use crate::simulate_array::take_const_array_oob;
use crate::value_invention::BoundaryKind;
use serde_json::json;
use std::collections::{HashMap, HashSet};

pub(super) fn compile(doc: serde_json::Value) -> ArrayCompiled {
    let file = crate::parse::load_string(&doc.to_string()).expect("fixture document loads");
    ArrayCompiled::from_file(&file).expect("fixture compiles")
}

fn seeded_state(n: usize, seed: u64, lo: f64, hi: f64) -> Vec<f64> {
    let mut x = seed.wrapping_mul(0x9E3779B97F4A7C15).wrapping_add(1);
    (0..n)
        .map(|_| {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            let u = (x >> 11) as f64 / (1u64 << 53) as f64;
            lo + u * (hi - lo)
        })
        .collect()
}

fn assert_bits_eq(a: &[f64], b: &[f64], what: &str) {
    assert_eq!(a.len(), b.len(), "{what}: length");
    for (k, (x, y)) in a.iter().zip(b.iter()).enumerate() {
        assert_eq!(
            x.to_bits(),
            y.to_bits(),
            "{what}: dy[{k}] diverged: {x:?} ({:016x}) vs {y:?} ({:016x})",
            x.to_bits(),
            y.to_bits()
        );
    }
}

fn cfg() -> super::fuse::SuperopCfg {
    super::fuse::SuperopCfg {
        bin3: false,
        ext_pairs: true,
    }
}

/// A fresh scratch carrying `prog`.
fn scratch_with(compiled: &ArrayCompiled, prog: TapeProgram) -> RhsScratch {
    let mut s = RhsScratch::new(&compiled.var_shapes);
    s.set_const_arrays(std::sync::Arc::clone(&compiled.const_scope));
    s.install_tape(std::sync::Arc::new(prog));
    s
}

/// Build the fused and unfused tapes — neither may carry a fallback — and
/// compare `dy` and the latched fault against the oracle and the overlay at
/// several states, times and parameter maps. The fast executor is compared
/// on a FRESH scratch per evaluation: a CONST-section fault latches when the
/// section primes, which a warm scratch has already done. Returns the fused
/// program.
pub(super) fn ab(compiled: &ArrayCompiled, param_maps: &[HashMap<String, f64>]) -> TapeProgram {
    let (prog, report) = taped(compiled.build_tape_opts(&HashSet::new(), Some(cfg())));
    assert!(
        report.fallbacks.is_empty(),
        "fallbacks: {:?}",
        report.fallbacks
    );
    let n = compiled.state_variable_names().len();
    for params in param_maps {
        for seed in 0..3u64 {
            let state = seeded_state(n, seed, -2.0, 2.0);
            for &t in &[0.0, 0.7] {
                compare_at(compiled, params, &state, t);
            }
        }
    }
    prog
}

/// Compare the fused and unfused tapes, in both executors, against the
/// oracle and the overlay at one state, time and parameter map: `dy` bit for
/// bit and the latched fault.
fn compare_at(compiled: &ArrayCompiled, params: &HashMap<String, f64>, state: &[f64], t: f64) {
    let n = state.len();
    let pv = compiled.debug_resolve_params(params);
    take_const_array_oob();
    let (dy_oracle, _) = compiled.debug_eval_rhs(state, t, params, true);
    let f_oracle = take_const_array_oob();
    let (dy_overlay, _) = compiled.debug_eval_rhs(state, t, params, false);
    let f_overlay = take_const_array_oob();
    assert_bits_eq(&dy_overlay, &dy_oracle, "overlay vs oracle");
    assert_eq!(f_overlay, f_oracle, "overlay fault");
    for fused in [true, false] {
        let label = if fused { "fused" } else { "unfused" };
        let p = taped(compiled.build_tape_opts(&HashSet::new(), fused.then(cfg))).0;
        let mut dy = vec![0.0f64; n];
        run_reference(&p, compiled, state, &pv, t, &mut dy);
        let f_ref = take_const_array_oob();
        assert_bits_eq(&dy, &dy_oracle, &format!("{label} reference executor"));
        assert_eq!(f_ref, f_oracle, "{label} reference executor fault");
        let mut scratch = scratch_with(compiled, p);
        let mut dy = vec![0.0f64; n];
        compiled.debug_eval_rhs_into(
            state,
            t,
            &pv,
            &mut dy,
            &mut scratch,
            &mut RhsStats::default(),
        );
        let f_fast = take_const_array_oob();
        assert_bits_eq(&dy, &dy_oracle, &format!("{label} fast executor"));
        assert_eq!(f_fast, f_oracle, "{label} fast executor fault");
    }
}

/// The tape's refusals when it refuses any rule; otherwise [`compare_at`] at
/// each of `states` under each parameter map, and no refusals.
pub(super) fn agrees_or_refuses(
    compiled: &ArrayCompiled,
    param_maps: &[HashMap<String, f64>],
    states: &[Vec<f64>],
) -> Vec<(String, String)> {
    let (_, report) = compiled.build_tape_opts(&HashSet::new(), Some(cfg()));
    if !report.fallbacks.is_empty() {
        return report.fallbacks;
    }
    for params in param_maps {
        for state in states {
            compare_at(compiled, params, state, 0.0);
        }
    }
    Vec::new()
}

pub(super) fn no_params() -> Vec<HashMap<String, f64>> {
    vec![HashMap::new()]
}

pub(super) fn opcount(prog: &TapeProgram, opcode: &str) -> usize {
    prog.instrs.iter().filter(|i| i.opcode() == opcode).count()
}

/// `D(u[i]) = rhs` over `i ∈ [1, n]`.
pub(super) fn d_eq(var: &str, n: i64, rhs: serde_json::Value) -> serde_json::Value {
    json!({
        "lhs": {"op": "faq", "args": [], "output_idx": ["i"],
                "expr": {"op": "D", "args": [{"op": "index", "args": [var, "i"]}], "wrt": "t"},
                "ranges": {"i": [1, n]}},
        "rhs": {"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": [1, n]}, "expr": rhs}
    })
}

pub(super) fn idx(base: serde_json::Value, subs: &[serde_json::Value]) -> serde_json::Value {
    let mut args = vec![base];
    args.extend(subs.iter().cloned());
    json!({"op": "index", "args": args})
}

pub(super) fn plus(a: serde_json::Value, b: serde_json::Value) -> serde_json::Value {
    json!({"op": "+", "args": [a, b]})
}

pub(super) fn lit(v: &[f64]) -> serde_json::Value {
    json!({"op": "const", "args": [], "value": v})
}

pub(super) fn doc(vars: serde_json::Value, eqs: Vec<serde_json::Value>) -> serde_json::Value {
    json!({
        "esm": "1.1.0",
        "metadata": {"name": "tape_array_forms"},
        "models": {"M": {"variables": vars, "equations": eqs}}
    })
}

// ---------------------------------------------------------------------------
// Const-array gathers out of range.
// ---------------------------------------------------------------------------

/// An inline const read one past its end on the last cell, and one before
/// its start on the first: the oracle's `NaN` at exactly those cells, and its
/// fault — for the FIRST cell in its visiting order, which is the `i - 1`
/// read at cell 1 even though the `i + 1` read comes first in the body.
#[test]
fn const_gather_out_of_range_faults_at_the_oracles_first_cell() {
    let n = 4;
    let c = lit(&[10.0, 20.0, 30.0, 40.0]);
    let body = plus(
        idx(c.clone(), &[plus(json!("i"), json!(1))]),
        idx(c, &[json!({"op": "-", "args": ["i", 1]})]),
    );
    let compiled = compile(doc(
        json!({"u": {"type": "unknown", "shape": ["i"]}}),
        vec![d_eq("u", n, body)],
    ));
    let prog = ab(&compiled, &no_params());
    assert_eq!(opcount(&prog, "Fault"), 1, "one fault per rule");
    assert_eq!(prog.faults.len(), 1);
    assert!(
        prog.faults[0].contains("index 0 out of range 1..4 in dim 0"),
        "{}",
        prog.faults[0]
    );
}

/// A named const array (an observed defined by a literal) read past the end
/// of its FIRST axis only, inside a box, and a fixed subscript past the end
/// of its second: each is `NaN` where the oracle's is, with the oracle's
/// fault (the first cell, and the first out-of-range dim at it).
#[test]
fn named_const_gather_out_of_range_in_a_box() {
    let n = 3;
    let tbl = json!({"op": "const", "args": [], "value": [[1.0, 2.0], [3.0, 4.0], [5.0, 6.0]]});
    for body in [
        idx(json!("tbl"), &[plus(json!("i"), json!(1)), json!(2)]),
        idx(json!("tbl"), &[json!("i"), json!(3)]),
        idx(json!("tbl"), &[json!(4), json!(3)]),
    ] {
        let compiled = compile(doc(
            json!({
                "u": {"type": "unknown", "shape": ["i"]},
                "tbl": {"type": "unknown", "shape": ["a0", "a1"]}
            }),
            vec![
                json!({"lhs": "tbl", "rhs": tbl.clone()}),
                d_eq("u", n, body),
            ],
        ));
        let prog = ab(&compiled, &no_params());
        assert_eq!(opcount(&prog, "Fault"), 1);
    }
}

/// A const read inside a contraction: the oracle walks each output cell's
/// tuples in turn, so its first fault is the first output cell's first
/// out-of-range tuple — in the unrolled form (the window shifts with the
/// output index) and in the promoted box, whose contracted axes lead.
#[test]
fn const_gather_out_of_range_in_a_contraction() {
    let n = 4;
    let c = lit(&[1.0, 2.0, 3.0]);
    let window = json!({"op": "faq", "args": [], "output_idx": ["i"],
        "ranges": {"i": [1, n], "k": [0, 1]},
        "expr": {"op": "*", "args": [
            idx(c.clone(), &[plus(json!("i"), json!("k"))]),
            idx(json!("u"), &[json!("i")])]}});
    let promoted = json!({"op": "faq", "args": [], "output_idx": ["i"],
        "ranges": {"i": [1, n], "k": [1, 4]},
        "expr": {"op": "*", "args": [idx(c, &[json!("k")]), idx(json!("u"), &[json!("i")])]}});
    for rhs in [window, promoted] {
        let compiled = compile(doc(
            json!({"u": {"type": "unknown", "shape": ["i"]}}),
            vec![json!({
                "lhs": {"op": "faq", "args": [], "output_idx": ["i"],
                        "expr": {"op": "D", "args": [idx(json!("u"), &[json!("i")])], "wrt": "t"},
                        "ranges": {"i": [1, n]}},
                "rhs": rhs
            })],
        ));
        ab(&compiled, &no_params());
    }
}

/// A read past a const array's end under a declared `clamp` or `periodic`
/// policy is resolved at build time — edge runs, wrapped copy segments — and
/// the tape stays independent of the box: the same instruction count at 16
/// and at 64 cells.
#[test]
fn const_gather_boundary_policies_resolve_at_build() {
    let build = |n: i64, kind: BoundaryKind| {
        let body = plus(
            idx(json!("C"), &[plus(json!("i"), json!(2))]),
            idx(json!("C"), &[json!({"op": "-", "args": ["i", 3]})]),
        );
        let mut compiled = compile(doc(
            json!({
                "u": {"type": "unknown", "shape": ["i"]},
                "C": {"type": "unknown", "shape": ["c"]}
            }),
            vec![
                json!({"lhs": "C", "rhs": lit(&[1.0, 2.0, 4.0, 8.0, 16.0])}),
                d_eq("u", n, body),
            ],
        ));
        compiled.const_scope =
            std::sync::Arc::new(ConstArrayScope::default().with_boundary("C", vec![kind]));
        compiled
    };
    // Unfused: whether fusion folds a many-segment gather depends on the run
    // count, which is not the question here.
    let unfused_len = |c: &ArrayCompiled| {
        taped(c.build_tape_opts(&HashSet::new(), None))
            .0
            .instrs
            .len()
    };
    for kind in [BoundaryKind::Clamp, BoundaryKind::Periodic] {
        let (small, large) = (build(16, kind), build(64, kind));
        assert_eq!(opcount(&ab(&small, &no_params()), "Fault"), 0);
        ab(&large, &no_params());
        assert_eq!(
            unfused_len(&small),
            unfused_len(&large),
            "{kind:?}: the tape grows with the box"
        );
    }
}

/// The wholesale gather with literal subscripts: past the end is the fault
/// and `NaN`, and under a policy it resolves to one element.
#[test]
fn wholesale_const_gather_out_of_range() {
    let compiled = compile(doc(
        json!({
            "s": {"type": "unknown", "default": 1.0},
            "g": {"type": "unknown"}
        }),
        vec![
            json!({"lhs": "g", "rhs": idx(lit(&[1.0, 2.0, 3.0]), &[json!(4)])}),
            json!({"lhs": {"op": "D", "args": ["s"], "wrt": "t"},
                   "rhs": {"op": "*", "args": ["g", "s"]}}),
        ],
    ));
    let prog = ab(&compiled, &no_params());
    assert_eq!(opcount(&prog, "Fault"), 1);
}

/// `index(p, i)` on a 0-D parameter is the oracle's `E_TREEWALK_INDEX_ON_SCALAR`
/// with `NaN`; in a filtered rank-0 reduction (the `join_filter.esm` shape)
/// the filter's fault at the first tuple settles which one latches, so the
/// body's — which the oracle evaluates only at kept tuples — is irrelevant.
#[test]
fn index_on_a_scalar_parameter_faults() {
    let compiled = compile(doc(
        json!({
            "e": {"type": "unknown", "default": 0.0},
            "rate": {"type": "parameter", "default": 2.0}
        }),
        vec![json!({
            "lhs": {"op": "D", "args": ["e"], "wrt": "t"},
            "rhs": {"op": "faq", "args": [], "output_idx": [],
                "ranges": {"k": [1, 3]},
                "filter": {"op": ">", "args": [idx(json!("rate"), &[json!("k")]), 0]},
                "expr": {"op": "*", "args": [idx(json!("rate"), &[json!("k")]), "e"]}}
        })],
    ));
    let prog = ab(&compiled, &no_params());
    assert_eq!(opcount(&prog, "Fault"), 1);
    assert!(prog.faults[0].starts_with("E_TREEWALK_INDEX_ON_SCALAR: 'rate'"));
}

// ---------------------------------------------------------------------------
// makearray.
// ---------------------------------------------------------------------------

/// The §9.6.8 discretization shape, along each axis: an interior stencil
/// `faq` and two boundary faces whose values are aggregates over the face's
/// one free axis — the leading-singleton face `[[1,1],[1,m]]` holding an
/// `[m]` value, and the trailing-singleton face `[[1,n],[1,1]]` an `[n]`
/// one. The oracle used to poison such a makearray with `NaN`; esm-spec
/// §4.3.2 places the value over the non-singleton axes.
#[test]
fn makearray_lower_rank_region_values() {
    let (n, m) = (5i64, 4i64);
    let c = |i: serde_json::Value, j: serde_json::Value| idx(json!("c"), &[i, j]);
    let face_j = |col: i64, other: i64| {
        json!({"op": "faq", "output_idx": ["j"], "args": [],
            "ranges": {"j": [1, m]},
            "expr": {"op": "-", "args": [c(json!(col), json!("j")), c(json!(other), json!("j"))]}})
    };
    let face_i = |row: i64, other: i64| {
        json!({"op": "faq", "output_idx": ["i"], "args": [],
            "ranges": {"i": [1, n]},
            "expr": {"op": "-", "args": [c(json!("i"), json!(row)), c(json!("i"), json!(other))]}})
    };
    let along_i = json!({"op": "makearray", "args": [],
    "regions": [[[2, n - 1], [1, m]], [[1, 1], [1, m]], [[n, n], [1, m]]],
    "values": [
        {"op": "faq", "output_idx": ["i", "j"], "args": [],
         "ranges": {"i": [2, n - 1], "j": [1, m]},
         "expr": {"op": "-", "args": [
            c(plus(json!("i"), json!(1)), json!("j")),
            c(json!({"op": "-", "args": ["i", 1]}), json!("j"))]}},
        face_j(2, 1),
        face_j(n, n - 1)
    ]});
    let along_j = json!({"op": "makearray", "args": [],
    "regions": [[[1, n], [2, m - 1]], [[1, n], [1, 1]], [[1, n], [m, m]]],
    "values": [
        {"op": "faq", "output_idx": ["i", "j"], "args": [],
         "ranges": {"i": [1, n], "j": [2, m - 1]},
         "expr": {"op": "-", "args": [
            c(json!("i"), plus(json!("j"), json!(1))),
            c(json!("i"), json!({"op": "-", "args": ["j", 1]}))]}},
        face_i(2, 1),
        face_i(m, m - 1)
    ]});
    for rhs in [along_i, along_j] {
        let compiled = compile(json!({
            "esm": "1.1.0",
            "metadata": {"name": "tape_makearray_faces"},
            "index_sets": {"x": {"kind": "interval", "size": n}, "y": {"kind": "interval", "size": m}},
            "models": {"M": {
                "variables": {"c": {"type": "unknown", "shape": ["x", "y"]}},
                "equations": [{"lhs": {"op": "D", "args": ["c"], "wrt": "t"}, "rhs": rhs}]
            }}
        }));
        let prog = ab(&compiled, &no_params());
        assert!(opcount(&prog, "Gather") + opcount(&prog, "Fused") > 0);
    }
}

/// An EMPTY region (`[2, 1]`, the interior of a stencil at its minimum
/// extent) covers no cell; its value is never consulted.
#[test]
fn makearray_empty_region_is_skipped() {
    let compiled = compile(json!({
        "esm": "1.1.0",
        "metadata": {"name": "tape_makearray_empty"},
        "index_sets": {"x": {"kind": "interval", "size": 2}},
        "models": {"M": {
            "variables": {"c": {"type": "unknown", "shape": ["x"]}},
            "equations": [{"lhs": {"op": "D", "args": ["c"], "wrt": "t"}, "rhs":
                {"op": "makearray", "args": [],
                 "regions": [[[2, 1]], [[1, 1]], [[2, 2]]],
                 "values": [
                    {"op": "faq", "output_idx": ["i"], "args": [], "ranges": {"i": [2, 1]},
                     "expr": idx(json!("c"), &[plus(json!("i"), json!(1))])},
                    {"op": "-", "args": [idx(json!("c"), &[json!(2)]), idx(json!("c"), &[json!(1)])]},
                    {"op": "-", "args": [idx(json!("c"), &[json!(2)]), idx(json!("c"), &[json!(1)])]}
                 ]}}]
        }}
    }));
    ab(&compiled, &no_params());
}

/// An empty region's value is still evaluated by the oracle, and an ARRAY
/// value that does not fit the (empty) region poisons the whole makearray
/// with `NaN`, as a mismatched value in any region does. The overlay agrees,
/// and the tape, which cannot place that `NaN`, refuses the rule.
#[test]
fn makearray_empty_region_with_a_mismatched_value_is_the_oracles_nan() {
    let n = 3;
    let compiled = compile(json!({
        "esm": "1.1.0",
        "metadata": {"name": "tape_makearray_empty_mismatch"},
        "index_sets": {"x": {"kind": "interval", "size": n}},
        "models": {"M": {
            "variables": {"c": {"type": "unknown", "shape": ["x"]}},
            "equations": [{"lhs": {"op": "D", "args": ["c"], "wrt": "t"}, "rhs":
                {"op": "makearray", "args": [],
                 "regions": [[[3, 2]], [[1, 3]]],
                 "values": [
                    lit(&[1.0, 2.0, 3.0, 4.0, 5.0]),
                    {"op": "faq", "output_idx": ["i"], "args": [], "ranges": {"i": [1, 3]},
                     "expr": {"op": "-", "args": [idx(json!("c"), &[json!("i")])]}}
                 ]}}]
        }}
    }));
    let state = vec![0.5, -1.25, 2.0];
    let params = HashMap::new();
    let (dy_oracle, _) = compiled.debug_eval_rhs(&state, 0.0, &params, true);
    let (dy_overlay, _) = compiled.debug_eval_rhs(&state, 0.0, &params, false);
    assert!(dy_oracle.iter().all(|x| x.is_nan()), "{dy_oracle:?}");
    assert_bits_eq(&dy_overlay, &dy_oracle, "overlay vs oracle");
    let refused = agrees_or_refuses(&compiled, &no_params(), &[state]);
    assert!(
        !refused.is_empty(),
        "the tape assembled a mismatched makearray"
    );
}

// ---------------------------------------------------------------------------
// Empty output boxes.
// ---------------------------------------------------------------------------

/// A `faq` over a size-0 index set is the empty array, and a contraction over
/// it is the reduction identity — neither evaluates its body.
#[test]
fn empty_output_box_is_an_empty_array() {
    let compiled = compile(json!({
        "esm": "1.1.0",
        "metadata": {"name": "tape_empty_box"},
        "index_sets": {"r": {"kind": "interval", "size": 0}, "c": {"kind": "interval", "size": 3}},
        "models": {"M": {
            "variables": {
                "v": {"type": "parameter", "shape": ["r"]},
                "x": {"type": "unknown", "shape": ["r"]},
                "e": {"type": "unknown", "shape": ["c"]},
                "u": {"type": "unknown", "shape": ["c"]}
            },
            "equations": [
                {"lhs": "x", "rhs": {"op": "faq", "output_idx": ["q"], "args": [],
                    "ranges": {"q": {"from": "r"}},
                    "expr": {"op": "*", "args": [2, idx(json!("v"), &[json!("q")])]}}},
                {"lhs": "e", "rhs": {"op": "faq", "output_idx": ["i"], "args": [],
                    "ranges": {"i": {"from": "c"}, "q": {"from": "r"}},
                    "expr": idx(json!("x"), &[json!("q")])}},
                {"lhs": {"op": "D", "args": ["u"], "wrt": "t"},
                 "rhs": {"op": "+", "args": ["e", "u"]}}
            ]
        }}
    }));
    ab(&compiled, &no_params());
}

// ---------------------------------------------------------------------------
// Whole-array shape ops.
// ---------------------------------------------------------------------------

/// `reshape` (column-major), `transpose` (default and explicit `perm`),
/// `concat` along either axis, and the positional broadcast of anonymous
/// operands (trailing-singleton padding), each read back element by element
/// into a 0-D tendency — plus the incompatible broadcast, which is the
/// oracle's `NaN`.
#[test]
fn whole_array_shape_ops() {
    let reads: Vec<serde_json::Value> = vec![
        idx(
            json!({"op": "reshape", "args": ["u"], "shape": [2, 3]}),
            &[json!(2), json!(1)],
        ),
        idx(
            json!({"op": "reshape", "args": [{"op": "reshape", "args": ["w"], "shape": [3, 2]}], "shape": [6]}),
            &[json!(5)],
        ),
        idx(
            json!({"op": "reshape", "args": ["w"], "shape": [3, 2]}),
            &[json!(3), json!(2)],
        ),
        idx(
            json!({"op": "transpose", "args": ["w"]}),
            &[json!(3), json!(1)],
        ),
        idx(
            json!({"op": "transpose", "args": ["w"], "perm": [1, 0]}),
            &[json!(2), json!(2)],
        ),
        idx(
            json!({"op": "concat", "args": ["u", "u"], "axis": 0}),
            &[json!(9)],
        ),
        idx(
            json!({"op": "concat", "args": ["w", "w"], "axis": 1}),
            &[json!(2), json!(5)],
        ),
        idx(
            json!({"op": "concat", "args": ["w", "w2"], "axis": 0}),
            &[json!(3), json!(1)],
        ),
        idx(
            json!({"op": "broadcast", "fn": "+", "args": ["v", {"op": "reshape", "args": ["v"], "shape": [1, 3]}]}),
            &[json!(3), json!(2)],
        ),
        idx(
            json!({"op": "*", "args": [{"op": "reshape", "args": ["v"], "shape": [3, 1]}, {"op": "reshape", "args": ["v"], "shape": [1, 3]}]}),
            &[json!(2), json!(3)],
        ),
        // `(6,)` against `(2, 3)`: extents 6 and 2 clash on the first axis.
        idx(
            json!({"op": "+", "args": ["u", "w"]}),
            &[json!(1), json!(1)],
        ),
    ];
    let mut vars = serde_json::Map::new();
    vars.insert("u".into(), json!({"type": "unknown", "shape": ["six"]}));
    vars.insert(
        "w".into(),
        json!({"type": "unknown", "shape": ["two", "three"]}),
    );
    vars.insert(
        "w2".into(),
        json!({"type": "unknown", "shape": ["one", "three"]}),
    );
    vars.insert("v".into(), json!({"type": "unknown", "shape": ["three"]}));
    let mut eqs = Vec::new();
    for (k, r) in reads.into_iter().enumerate() {
        let name = format!("s{k}");
        vars.insert(name.clone(), json!({"type": "unknown", "default": 0.0}));
        eqs.push(json!({"lhs": {"op": "D", "args": [name], "wrt": "t"}, "rhs": r}));
    }
    for var in ["u", "v", "w", "w2"] {
        eqs.push(json!({"lhs": {"op": "D", "args": [var], "wrt": "t"}, "rhs": 0.0}));
    }
    let compiled = compile(json!({
        "esm": "1.1.0",
        "metadata": {"name": "tape_shape_ops"},
        "index_sets": {
            "six": {"kind": "interval", "size": 6},
            "three": {"kind": "interval", "size": 3},
            "two": {"kind": "interval", "size": 2},
            "one": {"kind": "interval", "size": 1}
        },
        "models": {"M": {"variables": vars, "equations": eqs}}
    }));
    let prog = ab(&compiled, &no_params());
    assert!(opcount(&prog, "Reshape") > 0);
}

// ---------------------------------------------------------------------------
// Reductions and ifelse.
// ---------------------------------------------------------------------------

/// A filtered rank-0 reduction, under every semiring the tape folds, with a
/// filter that keeps some tuples and one that keeps none.
#[test]
fn filtered_rank0_reduction() {
    let n = 6;
    for reduce in ["+", "*", "max", "min"] {
        for bound in [0.0, 5.0] {
            let compiled = compile(doc(
                json!({
                    "u": {"type": "unknown", "shape": ["i"]},
                    "s": {"type": "unknown", "default": 0.0},
                    "tot": {"type": "unknown"}
                }),
                vec![
                    json!({"lhs": "tot", "rhs": {"op": "faq", "args": [], "output_idx": [],
                        "ranges": {"j": [1, n]}, "reduce": reduce,
                        "filter": {"op": "<", "args": [idx(json!("u"), &[json!("j")]), bound]},
                        "expr": {"op": "*", "args": [idx(json!("u"), &[json!("j")]), 0.5]}}}),
                    json!({"lhs": {"op": "D", "args": ["s"], "wrt": "t"}, "rhs": "tot"}),
                    d_eq("u", n, idx(json!("u"), &[json!("i")])),
                ],
            ));
            ab(&compiled, &no_params());
        }
    }
}

/// A shaped observed defined by an `ifelse` under a runtime scalar condition,
/// one arm an array and the other a scalar: the oracle returns the taken arm
/// and fills a scalar over the declared shape, so the fill happens inside
/// each arm (`scalar_rhs_broadcast.esm`).
#[test]
fn shaped_ifelse_with_a_scalar_arm() {
    let compiled = compile(json!({
        "esm": "1.1.0",
        "metadata": {"name": "tape_shaped_ifelse"},
        "index_sets": {"r": {"kind": "interval", "size": 3}},
        "models": {"M": {
            "variables": {
                "guard": {"type": "parameter", "default": 1.0},
                "col": {"type": "unknown", "shape": ["r"]},
                "folded": {"type": "unknown", "shape": ["r"]},
                "nested": {"type": "unknown", "shape": ["r"]},
                "s": {"type": "unknown", "default": 0.5},
                "u": {"type": "unknown", "shape": ["r"]}
            },
            "equations": [
                {"lhs": "col", "rhs": lit(&[10.0, 20.0, 30.0])},
                {"lhs": "folded", "rhs": {"op": "ifelse", "args": [
                    {"op": ">", "args": ["guard", 0.0]}, "col", -4.0]}},
                {"lhs": "nested", "rhs": {"op": "ifelse", "args": [
                    {"op": "<", "args": ["guard", 0.5]}, "s",
                    {"op": "ifelse", "args": [{"op": ">", "args": ["guard", 2.0]}, 7.0, "col"]}]}},
                {"lhs": {"op": "D", "args": ["s"], "wrt": "t"}, "rhs": 0.0},
                {"lhs": {"op": "D", "args": ["u"], "wrt": "t"},
                 "rhs": {"op": "+", "args": ["folded", "nested", "u"]}}
            ]
        }}
    }));
    let maps: Vec<HashMap<String, f64>> = [-1.0, 1.0, 3.0]
        .iter()
        .map(|&g| HashMap::from([("guard".to_string(), g)]))
        .collect();
    ab(&compiled, &maps);
}

/// An observed with NO declared shape defined by an `ifelse` under a runtime
/// scalar condition, one arm an array (`F * 2`, `F: [cell]`) and the other a
/// scalar (issue #664, the NEI2016 emission observeds). The compiler gives the
/// observed its array arm's box, so the oracle fills the scalar arm over it
/// and the tape joins the arms in that box. `extra_vars` and `readers` add
/// the right-hand sides that read it; `lev` picks the arm.
fn undeclared_mixed_doc(
    body: serde_json::Value,
    extra_vars: serde_json::Value,
    readers: Vec<serde_json::Value>,
) -> serde_json::Value {
    let mut vars = json!({
        "lev": {"type": "parameter", "default": 1.0},
        "F": {"type": "parameter", "shape": ["cell"], "default": 1.5},
        "X": {"type": "unknown"}
    });
    for (k, v) in extra_vars.as_object().expect("an object") {
        vars[k] = v.clone();
    }
    let mut eqs = vec![json!({"lhs": "X", "rhs": body})];
    eqs.extend(readers);
    json!({
        "esm": "1.1.0",
        "metadata": {"name": "tape_undeclared_mixed_ifelse"},
        "index_sets": {
            "cell": {"kind": "interval", "size": 3},
            "other": {"kind": "interval", "size": 2}
        },
        "models": {"M": {"variables": vars, "equations": eqs}}
    })
}

fn mixed_ifelse(array_arm: serde_json::Value, scalar_arm: serde_json::Value) -> serde_json::Value {
    json!({"op": "ifelse", "args": [{"op": "<", "args": ["lev", 2.0]}, array_arm, scalar_arm]})
}

/// Both arms, at both values of the runtime condition.
fn both_arms() -> Vec<HashMap<String, f64>> {
    [1.0, 3.0]
        .iter()
        .map(|&lev| HashMap::from([("lev".to_string(), lev)]))
        .collect()
}

/// The observed is gathered per cell, read bare by a shaped state, summed
/// into a scalar state and read at a fixed element: each reader sees the
/// array arm's elements, or the scalar in every element, under both
/// compilers.
#[test]
fn undeclared_ifelse_with_a_scalar_arm() {
    let x = mixed_ifelse(json!({"op": "*", "args": ["F", 2.0]}), json!(0.25));
    let readers = vec![
        d_eq("q", 3, idx(json!("X"), &[json!("i")])),
        json!({"lhs": {"op": "D", "args": ["r"], "wrt": "t"}, "rhs": "X"}),
        json!({"lhs": {"op": "D", "args": ["s"], "wrt": "t"}, "rhs": {"op": "+", "args": [
            {"op": "faq", "args": [], "output_idx": [], "ranges": {"j": [1, 3]},
             "expr": idx(json!("X"), &[json!("j")])},
            idx(json!("X"), &[json!(2)])]}}),
    ];
    let vars = json!({
        "q": {"type": "unknown", "shape": ["cell"], "default": 0.0},
        "r": {"type": "unknown", "shape": ["cell"], "default": 0.0},
        "s": {"type": "unknown", "default": 0.0}
    });
    let compiled = compile(undeclared_mixed_doc(x, vars, readers));
    ab(&compiled, &both_arms());
}

/// The scalar arm first, the `ifelse` nested inside elementwise arithmetic,
/// and an observed nobody reads (the NEI2016 shape in reseact).
#[test]
fn undeclared_ifelse_scalar_arm_first_nested_and_unread() {
    let wrapped = json!({"op": "+", "args": [1.0, {"op": "*", "args": [3.0,
        {"op": "ifelse", "args": [{"op": ">=", "args": ["lev", 2.0]}, -0.5, "F"]}]}]});
    let vars = json!({"q": {"type": "unknown", "shape": ["cell"], "default": 0.0}});
    let compiled = compile(undeclared_mixed_doc(
        wrapped,
        vars.clone(),
        vec![d_eq("q", 3, idx(json!("X"), &[json!("i")]))],
    ));
    ab(&compiled, &both_arms());
    let x = mixed_ifelse(json!({"op": "*", "args": ["F", 2.0]}), json!(0.0));
    let compiled = compile(undeclared_mixed_doc(
        x,
        vars,
        vec![d_eq(
            "q",
            3,
            json!({"op": "*", "args": [-1.0, idx(json!("q"), &[json!("i")])]}),
        )],
    ));
    ab(&compiled, &both_arms());
}

/// The observed's box is its array arm's: both evaluators hold it as that
/// array whichever arm the condition takes.
#[test]
fn undeclared_ifelse_observed_takes_its_array_arms_box() {
    use super::super::AlgebraicRule;
    let x = mixed_ifelse(json!({"op": "*", "args": ["F", 2.0]}), json!(0.0));
    let compiled = compile(undeclared_mixed_doc(x, json!({}), vec![]));
    let declared = compiled.observed_rules.iter().find_map(|r| match r {
        AlgebraicRule::Scalar {
            var,
            declared_shape,
            ..
        } if var == "X" => Some(declared_shape.clone()),
        _ => None,
    });
    assert_eq!(declared, Some(Some(vec![3])));
}

/// Where the arm's value is consumed whole — a gather of the `ifelse` itself,
/// operands over different index sets — the oracle's answer follows the taken
/// arm's shape, so no box is inferred and native still refuses.
#[test]
fn undeclared_ifelse_consumed_whole_is_still_refused() {
    let gathered = idx(
        mixed_ifelse(json!({"op": "*", "args": ["F", 2.0]}), json!(0.0)),
        &[json!(2)],
    );
    let two_sets = mixed_ifelse(json!({"op": "+", "args": ["F", "G"]}), json!(0.0));
    for body in [gathered, two_sets] {
        let compiled = compile(undeclared_mixed_doc(
            body,
            json!({"G": {"type": "parameter", "shape": ["other"], "default": 1.0}}),
            vec![],
        ));
        let (_, report) = compiled.build_tape_opts(&HashSet::new(), Some(cfg()));
        assert!(
            report
                .fallbacks
                .iter()
                .any(|(_, why)| why.contains("branch value boxes differ")),
            "{:?}",
            report.fallbacks
        );
    }
}

/// The box each compiled observed rule carries, by name.
fn declared_box(compiled: &ArrayCompiled, name: &str) -> Option<Option<Vec<usize>>> {
    use super::super::AlgebraicRule;
    compiled.observed_rules.iter().find_map(|r| match r {
        AlgebraicRule::Scalar {
            var,
            declared_shape,
            ..
        } if var == name => Some(declared_shape.clone()),
        _ => None,
    })
}

/// Whether native refused some rule because its `ifelse` arms differ in box.
fn refuses_mixed_arms(compiled: &ArrayCompiled) -> bool {
    let (_, report) = compiled.build_tape_opts(&HashSet::new(), Some(cfg()));
    report
        .fallbacks
        .iter()
        .any(|(_, why)| why.contains("branch value boxes differ"))
}

/// `shape: []` declares a scalar (the PR #634 ruling: an explicit `[]` is a
/// real shape, only an absent one is inferred). No box is inferred for it, and
/// a scalar cannot hold the array arm, so native refuses the mixed `ifelse`.
#[test]
fn declared_scalar_ifelse_with_an_array_arm_is_not_promoted() {
    let x = mixed_ifelse(json!({"op": "*", "args": ["F", 2.0]}), json!(0.0));
    let compiled = compile(undeclared_mixed_doc(
        x,
        json!({"X": {"type": "unknown", "shape": []}}),
        vec![],
    ));
    assert_eq!(declared_box(&compiled, "X"), Some(None));
    assert!(refuses_mixed_arms(&compiled));
}

/// A chain: `Y = ifelse(c2, X, 0.0)` reads `X`, itself inferred from its own
/// mixed `ifelse`. `Y` takes `X`'s inferred box, and both arms of both
/// conditions agree with the interpreter.
#[test]
fn chained_ifelse_with_a_scalar_arm_takes_the_inferred_box() {
    let x = mixed_ifelse(json!({"op": "*", "args": ["F", 2.0]}), json!(0.0));
    let y = json!({"op": "ifelse", "args": [{"op": ">", "args": ["lev", 2.0]}, -1.0, "X"]});
    let compiled = compile(undeclared_mixed_doc(
        x,
        json!({
            "Y": {"type": "unknown"},
            "q": {"type": "unknown", "shape": ["cell"], "default": 0.0}
        }),
        vec![
            json!({"lhs": "Y", "rhs": y}),
            d_eq("q", 3, idx(json!("Y"), &[json!("i")])),
        ],
    ));
    assert_eq!(declared_box(&compiled, "X"), Some(Some(vec![3])));
    assert_eq!(declared_box(&compiled, "Y"), Some(Some(vec![3])));
    let maps: Vec<HashMap<String, f64>> = [1.0, 2.5, 3.0]
        .iter()
        .map(|&lev| HashMap::from([("lev".to_string(), lev)]))
        .collect();
    ab(&compiled, &maps);
}

/// [`undeclared_mixed_doc`] with `F` declared WITHOUT a shape and fed from a
/// data source, its three-cell array written into the forcing buffer. No
/// declaration fixes `F`'s rank, so no box is inferred before the build;
/// both evaluators read it off the data when they evaluate `X`.
fn data_fed_mixed(
    body: serde_json::Value,
    extra_vars: serde_json::Value,
    readers: Vec<serde_json::Value>,
) -> ArrayCompiled {
    let mut vars = json!({"F": {"type": "parameter", "default": 1.5,
        "update": {"kind": "data", "source": "src", "from": {"file_variable": "F"}}}});
    for (k, v) in extra_vars.as_object().expect("an object") {
        vars[k] = v.clone();
    }
    let mut doc = undeclared_mixed_doc(body, vars, readers);
    doc["data_sources"] = json!({"src": {"kind": "static",
        "source": {"url_template": "file:///nonexistent/f.nc"}}});
    let compiled = compile(doc);
    compiled.forcing_handle().borrow_mut().insert(
        "F".to_string(),
        ndarray::ArrayD::from_shape_vec(ndarray::IxDyn(&[3]), vec![1.5, -2.0, 0.75])
            .expect("shape"),
    );
    compiled
}

/// Readers of `X`: a per-cell gather, a sum over the cells and a fixed
/// element. Each faults or reads a different number if `X` is a scalar on one
/// arm. (A bare read by a shaped state, `D(r) = X`, is left out: the oracle
/// reads an array observed that declares no shape as `NaN` there whether or
/// not an `ifelse` defines it, which is a separate gap.)
fn mixed_readers() -> (serde_json::Value, Vec<serde_json::Value>) {
    let readers = vec![
        d_eq("q", 3, idx(json!("X"), &[json!("i")])),
        json!({"lhs": {"op": "D", "args": ["s"], "wrt": "t"}, "rhs": {"op": "+", "args": [
            {"op": "faq", "args": [], "output_idx": [], "ranges": {"j": [1, 3]},
             "expr": idx(json!("X"), &[json!("j")])},
            idx(json!("X"), &[json!(2)])]}}),
    ];
    let vars = json!({
        "q": {"type": "unknown", "shape": ["cell"], "default": 0.0},
        "s": {"type": "unknown", "default": 0.0}
    });
    (vars, readers)
}

/// A constant arm and a data arm under a runtime scalar condition, on an
/// observed with no declared shape: native builds it (it refused it as
/// "branch value boxes differ") and agrees with the interpreter on both arms
/// — the array arm first or second, nested in arithmetic or in another
/// `ifelse`, read or unread.
#[test]
fn data_fed_ifelse_with_a_constant_arm() {
    let f2 = || json!({"op": "*", "args": ["F", 2.0]});
    let bodies = [
        // The NEI2016 form: the data arm first.
        mixed_ifelse(f2(), json!(0.25)),
        // Reversed: the constant arm first.
        json!({"op": "ifelse", "args": [{"op": ">=", "args": ["lev", 2.0]}, 0.25, f2()]}),
        // Inside elementwise arithmetic.
        json!({"op": "+", "args": [1.0, {"op": "*", "args": [3.0,
            {"op": "ifelse", "args": [{"op": ">=", "args": ["lev", 2.0]}, -0.5, "F"]}]}]}),
        // Nested: the data arm inside the inner `ifelse`, constants elsewhere.
        json!({"op": "ifelse", "args": [{"op": ">", "args": ["lev", 2.75]}, 7.0,
            mixed_ifelse(f2(), json!(-1.0))]}),
        // Nested the other way: the inner `ifelse` is all constants.
        json!({"op": "ifelse", "args": [{"op": "<", "args": ["lev", 2.0]}, f2(),
            {"op": "ifelse", "args": [{"op": ">", "args": ["lev", 2.75]}, 4.0, -4.0]}]}),
    ];
    let maps: Vec<HashMap<String, f64>> = [1.0, 2.5, 3.0]
        .iter()
        .map(|&lev| HashMap::from([("lev".to_string(), lev)]))
        .collect();
    for body in bodies {
        let (vars, readers) = mixed_readers();
        ab(&data_fed_mixed(body.clone(), vars, readers), &maps);
        // Unread, as `NEI2016Emis.CO` is in reseact.
        let unread = data_fed_mixed(
            body,
            json!({"q": {"type": "unknown", "shape": ["cell"], "default": 0.0}}),
            vec![d_eq(
                "q",
                3,
                json!({"op": "*", "args": [-1.0, idx(json!("q"), &[json!("i")])]}),
            )],
        );
        ab(&unread, &maps);
    }
}

/// The observed both evaluators materialize has the data's shape whichever
/// arm the condition takes: the constant arm fills every cell.
#[test]
fn data_fed_ifelse_observed_takes_the_datas_shape() {
    let compiled = data_fed_mixed(
        mixed_ifelse(json!({"op": "*", "args": ["F", 2.0]}), json!(0.25)),
        json!({}),
        vec![],
    );
    assert!(!refuses_mixed_arms(&compiled));
    for (lev, want) in [(1.0, vec![3.0, -4.0, 1.5]), (3.0, vec![0.25; 3])] {
        let params = HashMap::from([("lev".to_string(), lev)]);
        let pv = compiled.debug_resolve_params(&params);
        let mut oracle = compiled.debug_new_scratch();
        let prog = taped(compiled.build_tape_opts(&HashSet::new(), Some(cfg()))).0;
        let mut tape = scratch_with(&compiled, prog);
        tape.set_exports_active(true);
        for scratch in [&mut oracle, &mut tape] {
            compiled.debug_eval_rhs_into(&[], 0.0, &pv, &mut [], scratch, &mut RhsStats::default());
        }
        let tape_x = tape.taped_observeds().expect("a tape")["X"].clone();
        for (who, x) in [
            ("oracle", &oracle.observed_arrays()["X"]),
            ("tape", &tape_x),
        ] {
            assert_eq!(x.shape(), &[3], "{who}, lev = {lev}");
            assert_eq!(
                x.iter().copied().collect::<Vec<_>>(),
                want,
                "{who}, lev = {lev}"
            );
        }
    }
}

/// A declared array arm that also reads a scalar observed defined by a
/// gather: the NEI2016 emission observeds as reseact builds them,
/// `CO = ifelse(lev < 2, flux_CO / days_in_month …, 0.0)` with `flux_CO`
/// shaped and `days_in_month` a table lookup. A gather with scalar
/// subscripts is a scalar, so the build gives `X` the array arm's box before
/// anything is evaluated (esm-spec §4.3.4), with the gather written directly
/// and at `interp.linear`'s cell index (a rank-0 `faq` count).
#[test]
fn ifelse_reading_a_gathered_scalar_takes_the_array_arms_box() {
    let table = json!({"op": "const", "args": [], "value": [31.0, 28.0, 31.0]});
    let count = json!({"op": "faq", "args": [], "output_idx": [], "reduce": "+",
        "ranges": {"j": [1, 3]}, "expr": {"op": "ifelse", "args": [{"op": "<=", "args": [
            idx(json!({"op": "const", "args": [], "value": [0.0, 10.0, 20.0]}), &[json!("j")]),
            15.0]}, 1, 0]}});
    let gathers = [idx(table.clone(), &[json!(2)]), idx(table, &[count])];
    let fd = || json!({"op": "/", "args": ["F", "D"]});
    let bodies = [
        mixed_ifelse(fd(), json!(0.0)),
        json!({"op": "ifelse", "args": [{"op": ">=", "args": ["lev", 2.0]}, 0.0, fd()]}),
    ];
    for (x, gather) in bodies
        .into_iter()
        .flat_map(|x| gathers.clone().map(|g| (x.clone(), g)))
    {
        let d = json!({"lhs": "D", "rhs": gather});
        let (mut vars, mut readers) = mixed_readers();
        vars["D"] = json!({"type": "unknown"});
        readers.push(d.clone());
        let compiled = compile(undeclared_mixed_doc(x.clone(), vars, readers));
        assert_eq!(compiled.conditional_shapes["X"], ["cell"]);
        assert_eq!(declared_box(&compiled, "X"), Some(Some(vec![3])));
        ab(&compiled, &both_arms());
        // Unread, as `NEI2016Emis.CO` is in reseact.
        let unread = compile(undeclared_mixed_doc(
            x,
            json!({"D": {"type": "unknown"}}),
            vec![d.clone()],
        ));
        assert!(!refuses_mixed_arms(&unread));
    }
}

/// Where the data arm is consumed whole, or meets an array of another shape,
/// the oracle's answer still follows the taken arm, so native still refuses;
/// and `shape: []` still declares a scalar.
#[test]
fn data_fed_ifelse_consumed_whole_or_declared_scalar_is_still_refused() {
    let gathered = idx(
        mixed_ifelse(json!({"op": "*", "args": ["F", 2.0]}), json!(0.0)),
        &[json!(2)],
    );
    let two_sets = mixed_ifelse(json!({"op": "+", "args": ["F", "G"]}), json!(0.0));
    let g = json!({"G": {"type": "parameter", "shape": ["other"], "default": 1.0}});
    for body in [gathered, two_sets] {
        assert!(refuses_mixed_arms(&data_fed_mixed(body, g.clone(), vec![])));
    }
    let scalar = data_fed_mixed(
        mixed_ifelse(json!({"op": "*", "args": ["F", 2.0]}), json!(0.0)),
        json!({"X": {"type": "unknown", "shape": []}}),
        vec![],
    );
    assert!(refuses_mixed_arms(&scalar));
}

/// An operand with no declared shape whose value is an array (a `faq` over
/// `[cell, other]`) is not counted as a scalar: its rank is not read off a
/// declaration, so no box is inferred for the `ifelse` that reads it.
#[test]
fn unshaped_array_operand_blocks_the_inference() {
    let x = mixed_ifelse(json!({"op": "+", "args": ["F", "W"]}), json!(0.0));
    let w = json!({"op": "faq", "args": [], "output_idx": ["i", "j"],
        "ranges": {"i": [1, 3], "j": [1, 2]}, "expr": 1.0});
    let compiled = compile(undeclared_mixed_doc(
        x,
        json!({"W": {"type": "unknown"}}),
        vec![json!({"lhs": "W", "rhs": w})],
    ));
    assert_eq!(declared_box(&compiled, "X"), Some(None));
}
