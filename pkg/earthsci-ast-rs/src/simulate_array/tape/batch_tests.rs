//! Calls of one function batched into one execution ([`super::batch`]):
//! several independent references to one definition, with different array
//! or scalar arguments, become one batch, and the batched execution writes
//! the per-cell oracle's `dy` bit for bit through every executor
//! ([`oracle_ab`]). A nested reference (bilinear reads linear) is batched
//! over every frame of its caller.

use super::ir::{Instr, TapeProgram};
use super::template_fixtures::{AXIS, TABLE};
use super::test_support::{apply, d_lhs, faq, ix, konst, library, op, oracle_ab};
use serde_json::{Value, json};

/// Batches of calls in `prog` and in every function it calls, with the
/// number of calls they hold.
fn batches(prog: &TapeProgram) -> (usize, usize) {
    let mut n = (0, 0);
    for p in std::iter::once(prog).chain(prog.funcs.iter().map(|f| &**f)) {
        for (pc, &k) in p.call_batches.iter().enumerate() {
            if k > 1 {
                assert!(
                    p.instrs[pc..pc + k as usize]
                        .iter()
                        .all(|i| matches!(i, Instr::Call { .. })),
                    "a batch holds calls"
                );
                n.0 += 1;
                n.1 += k as usize;
            }
        }
    }
    n
}

/// `n` fields `u1..un` over `l in [1, 6]` (or scalars when `cells` is
/// false), each read through its own reference to `linear` (or `bilinear`
/// at `(u, w)`), and each relaxing toward its lookup.
fn many_lookups(n: usize, cells: bool, bilinear: bool) -> Value {
    let l = json!({"l": [1, 6]});
    let at = |v: &str| {
        if cells {
            ix(v, vec![json!("l")])
        } else {
            json!(v)
        }
    };
    let per_cell = |e: Value| if cells { faq(&["l"], l.clone(), e) } else { e };
    let shaped = |mut v: Value| {
        if cells {
            v["shape"] = json!(["lev"]);
        }
        v
    };
    let mut vars = serde_json::Map::new();
    let mut eqs = Vec::new();
    vars.insert(
        "w".into(),
        shaped(json!({"type": "unknown", "default": 1.0})),
    );
    eqs.push(json!({
        "lhs": if cells { d_lhs("w", &["l"], l.clone()) } else { json!({"op": "D", "args": ["w"], "wrt": "t"}) },
        "rhs": per_cell(op("*", vec![json!(-0.05), at("w")]))
    }));
    for k in 1..=n {
        let u = format!("u{k}");
        let c = format!("c{k}");
        vars.insert(
            u.clone(),
            shaped(json!({"type": "unknown", "default": 1.0})),
        );
        vars.insert(c.clone(), shaped(json!({"type": "unknown"})));
        let call = if bilinear {
            let table: Vec<Vec<f64>> = (0..AXIS.len())
                .map(|i| {
                    (0..AXIS.len())
                        .map(|j| (i * 7 + j * k) as f64 * 0.5)
                        .collect()
                })
                .collect();
            apply(
                "bilinear",
                json!({"table": konst(json!(table)), "axis_x": konst(json!(AXIS)),
                       "axis_y": konst(json!(AXIS)), "x": at(&u), "y": at("w"),
                       "nx": AXIS.len(), "ny": AXIS.len()}),
            )
        } else {
            apply(
                "linear",
                json!({"table": konst(json!(TABLE)), "axis": konst(json!(AXIS)), "x": at(&u),
                       "n": AXIS.len()}),
            )
        };
        eqs.push(json!({"lhs": c.clone(), "rhs": per_cell(call)}));
        eqs.push(json!({
            "lhs": if cells { d_lhs(&u, &["l"], l.clone()) } else { json!({"op": "D", "args": [u.clone()], "wrt": "t"}) },
            "rhs": per_cell(op("+", vec![
                op("*", vec![json!(-0.1), at(&u)]),
                op("*", vec![json!(0.01 * k as f64), at(&c)])]))
        }));
    }
    let mut m = json!({"variables": Value::Object(vars), "equations": eqs});
    m["operators"] = library("interp.esm");
    json!({
        "esm": "2.0.0",
        "metadata": {"name": "batched_calls"},
        "models": {"M": m}
    })
}

#[test]
fn references_to_one_definition_run_as_one_batch_and_match_the_oracle() {
    for cells in [true, false] {
        for bilinear in [false, true] {
            let (prog, _) = oracle_ab(many_lookups(4, cells, bilinear));
            let (n_batches, n_calls) = batches(&prog);
            assert!(
                n_batches >= 1 && n_calls >= 4,
                "cells {cells}, bilinear {bilinear}: {n_batches} batches of {n_calls} calls"
            );
        }
    }
}

#[test]
fn a_lone_reference_is_no_batch() {
    let (prog, _) = oracle_ab(many_lookups(1, true, false));
    assert_eq!(batches(&prog), (0, 0));
}

/// `a[floor(x) + 4]` for the constant `a = [1, 2, 3, 4]`: past the end of
/// `a` once `x >= 1`, before its start once `x < -3`.
fn read_at(at: Value) -> Value {
    use super::test_support::{idx, plus};
    idx(
        json!("a"),
        &[plus(json!({"op": "floor", "args": [at]}), json!(4))],
    )
}

/// Fields `u1..un` over `i in [1, 5]`, each with its own reference to
/// `pick` (or, with `nested`, to `twice`, whose body references `pick`
/// twice) over `C = [1, 2, 3, 4]`:
///
/// * `pick(a, x) = 2 a[floor(x) + 4] + a[floor(x - 2) + 4]`: the first read
///   faults once `x >= 1`, the second once `x < -1`, so a call's state picks
///   which of its two reads faults, and in which cell;
/// * nested: `pick(a, x) = a[floor(x) + 4]` and `twice(a, x, y) = pick(a, x)
///   + pick(a, y)`, called with `y = 0 - x`, so a field's first or second
///   inner call faults.
///
/// With `between`, a rule whose own read faults the same way (`D(w) =
/// C[floor(w) + 4]`) sits between the first field's rule and the others'.
fn faulting_batch(n_fields: usize, between: bool, nested: bool) -> Value {
    use super::test_support::{d_eq, doc, idx, lit, plus};
    let mut vars = serde_json::Map::new();
    vars.insert("C".into(), json!({"type": "unknown", "shape": ["c"]}));
    let mut eqs = vec![json!({"lhs": "C", "rhs": lit(&[1.0, 2.0, 3.0, 4.0])})];
    for k in 1..=n_fields {
        if between && k == 2 {
            vars.insert("w".into(), json!({"type": "unknown", "shape": ["i"]}));
            let w = idx(json!("w"), &[json!("i")]);
            let read = idx(
                json!("C"),
                &[plus(json!({"op": "floor", "args": [w]}), json!(4))],
            );
            eqs.push(d_eq("w", 5, read));
        }
        let u = format!("u{k}");
        vars.insert(u.clone(), json!({"type": "unknown", "shape": ["i"]}));
        let x = idx(json!(u.clone()), &[json!("i")]);
        let call = if nested {
            let y = op("-", vec![json!(0.0), x.clone()]);
            apply("twice", json!({"a": "C", "x": x, "y": y}))
        } else {
            apply("pick", json!({"a": "C", "x": x}))
        };
        eqs.push(d_eq(&u, 5, plus(call, json!(k as f64))));
    }
    let mut d = doc(Value::Object(vars), eqs);
    d["models"]["M"]["operators"] = if nested {
        json!({
            "pick": {"params": ["a", "x"], "body": read_at(json!("x"))},
            "twice": {
                "params": ["a", "x", "y"],
                "body": plus(
                    apply("pick", json!({"a": "a", "x": "x"})),
                    apply("pick", json!({"a": "a", "x": "y"})))
            }
        })
    } else {
        json!({
            "pick": {
                "params": ["a", "x"],
                "body": plus(
                    op("*", vec![json!(2.0), read_at(json!("x"))]),
                    read_at(op("-", vec![json!("x"), json!(2.0)])))
            }
        })
    };
    d
}

/// A state of `compiled` with every cell of every field `0.5` (no read
/// faults) except the cells `faults` names: `(field, 0-based cell, value)`.
fn state_with(compiled: &super::super::ArrayCompiled, faults: &[(&str, usize, f64)]) -> Vec<f64> {
    compiled
        .state_variable_names()
        .iter()
        .map(|name| {
            let base = name.rsplit('.').next().unwrap_or(name);
            let (var, cell) = base.split_once('[').expect("a field's cell");
            let cell: usize = cell.trim_end_matches(']').parse().expect("1-based cell");
            faults
                .iter()
                .find(|(v, c, _)| *v == var && *c + 1 == cell)
                .map_or(0.5, |&(_, _, x)| x)
        })
        .collect()
}

/// Every case of `cases` (see [`state_with`]) on `doc`: the fused and
/// unfused programs in both executors, each on a fresh scratch, write the
/// per-cell oracle's `dy` and latch its fault. Returns the fused program.
fn faults_match_the_oracle(doc: Value, cases: &[Vec<(&str, usize, f64)>]) -> TapeProgram {
    let compiled = super::test_support::compile(doc);
    let params = std::collections::HashMap::new();
    for faults in cases {
        let state = state_with(&compiled, faults);
        eprintln!("faults at {faults:?}");
        super::test_support::compare_tape_at(&compiled, &params, &state, 0.0);
    }
    super::taped(compiled.build_tape_opts(
        &Default::default(),
        Some(super::test_support::superop_cfg()),
    ))
    .0
}

/// A fault inside a batched call is reported as without batching: the
/// latched fault and `dy` match the per-cell oracle's, on fresh scratches,
/// whichever call of the batch faults, at whichever of the body's two reads
/// and in whichever cell.
#[test]
fn a_fault_inside_a_batch_is_reported_as_without_batching() {
    // The first read faults (`x >= 1`, index 5), the second (`x < -1`,
    // index 0), or both.
    let (first, second, both) = (1.5, -2.0, 3.5);
    let cases = vec![
        vec![],
        vec![("u1", 2, first)],
        vec![("u1", 0, second)],
        vec![("u2", 0, second)],
        vec![("u2", 4, first)],
        vec![("u3", 4, both)],
        vec![("u3", 1, second)],
    ];
    let prog = faults_match_the_oracle(faulting_batch(3, false, false), &cases);
    let (n_batches, n_calls) = batches(&prog);
    assert!(
        n_batches >= 1 && n_calls >= 3,
        "{n_batches} batches of {n_calls} calls"
    );
}

/// A call that can fault is not batched across a rule whose own read can:
/// the rule between the first field's and the others' faults first in the
/// oracle's order, before a later call's fault, and the first field's call
/// faults before it.
#[test]
fn a_call_that_can_fault_keeps_its_place_after_a_fault_before_it() {
    // `w = 2.5` reads index 6, the calls' first read at `1.5` index 5 and
    // their second at `-2.0` index 0.
    let cases = vec![
        vec![("w", 3, 2.5)],
        vec![("w", 3, 2.5), ("u2", 0, 1.5)],
        vec![("w", 3, 2.5), ("u3", 0, -2.0)],
        vec![("w", 0, 2.5), ("u1", 4, 1.5)],
        vec![("w", 0, 2.5), ("u1", 2, -2.0)],
        vec![("u2", 0, 1.5)],
    ];
    let prog = faults_match_the_oracle(faulting_batch(3, true, false), &cases);
    let (n_batches, n_calls) = batches(&prog);
    assert!(
        n_batches >= 1 && n_calls >= 2,
        "the calls after the rule between still batch: {n_batches} batches of {n_calls} calls"
    );
}

/// A batched function whose body calls another function at two instructions
/// reports the fault each frame meets in the order the calls run without
/// batching: run one instruction at a time across the frames, a later frame's
/// first inner call faults before an earlier frame's second one, at the same
/// position of the inner body, and the oracle latches the earlier frame's.
#[test]
fn a_fault_in_a_batched_body_is_the_earlier_frames() {
    // `-1.5`: the field's second inner call (at `1.5`) reads index 5; `2.5`:
    // its first reads index 6.
    let cases = vec![
        vec![("u1", 0, -1.5), ("u2", 0, 2.5)],
        vec![("u1", 0, 2.5), ("u2", 0, -1.5)],
        vec![("u2", 3, -1.5), ("u3", 3, 2.5)],
        vec![("u1", 1, -1.5), ("u3", 1, 2.5)],
        vec![("u2", 0, 2.5)],
    ];
    let prog = faults_match_the_oracle(faulting_batch(3, false, true), &cases);
    let (n_batches, n_calls) = batches(&prog);
    assert!(
        n_batches >= 1 && n_calls >= 3,
        "the fields' calls batch: {n_batches} batches of {n_calls} calls"
    );
}

/// Two calls of one definition, each faulting at a different read of its
/// body: the oracle latches the earlier call's fault. Not batching related:
/// a function body's faults are ordered by their position in the body alone,
/// not after the call's position in its caller, so a later call's fault at
/// an earlier body position replaces an earlier call's, unbatched as well.
#[test]
#[ignore = "faults of two calls are ordered by body position, not by call (unbatched too)"]
fn faults_of_two_calls_latch_in_call_order() {
    let (first, second) = (1.5, -2.0);
    let cases = vec![
        vec![("u1", 0, second), ("u2", 0, first)],
        vec![("u1", 4, second), ("u3", 0, first)],
    ];
    faults_match_the_oracle(faulting_batch(3, false, false), &cases);
}

/// One definition referenced the same way from a binary32 rule and a
/// binary64 one (esm-spec §11.3.1): each reference runs at its own rule's
/// precision. The body reads only the box index `l` (`l / 3`, which rounds
/// differently at each precision), so both references lower to the same
/// program with the same, empty, arguments: neither reads the other's
/// result, nor shares its function, whose constant part runs once per
/// function context.
#[test]
fn identical_calls_at_two_precisions_each_run() {
    let l = json!({"l": [1, 6]});
    let at = |v: &str| ix(v, vec![json!("l")]);
    let third = || apply("third", json!({"x": "l"}));
    let mut m = json!({
        "variables": {
            "u": {"type": "unknown", "shape": ["lev"], "default": 1.0, "element_type": "Float32"},
            "w": {"type": "unknown", "shape": ["lev"], "default": 1.0},
            "a": {"type": "unknown", "shape": ["lev"], "element_type": "Float32"},
            "b": {"type": "unknown", "shape": ["lev"]}
        },
        "equations": [
            {"lhs": "a", "rhs": faq(&["l"], l.clone(), third())},
            {"lhs": "b", "rhs": faq(&["l"], l.clone(), third())},
            {"lhs": d_lhs("u", &["l"], l.clone()), "rhs": faq(&["l"], l.clone(), at("a"))},
            {"lhs": d_lhs("w", &["l"], l.clone()), "rhs": faq(&["l"], l.clone(), at("b"))}
        ]
    });
    m["operators"] = json!({
        "third": {"params": ["x"], "body": op("/", vec![json!("x"), json!(3.0)])}
    });
    let doc = json!({"esm": "2.0.0", "metadata": {"name": "identical_calls_two_precisions"}, "models": {"M": m}});
    let (prog, _) = oracle_ab(doc);
    let n_calls = prog
        .instrs
        .iter()
        .filter(|i| matches!(i, Instr::Call { .. }))
        .count();
    assert_eq!(n_calls, 2, "one call at each precision");
}

/// Two references with the same definition and the same arguments: the
/// second reads the first's result (one call), and `dy` matches the oracle.
#[test]
fn identical_calls_run_once() {
    let l = json!({"l": [1, 6]});
    let at = |v: &str| ix(v, vec![json!("l")]);
    let lookup = || {
        apply(
            "linear",
            json!({"table": "T", "axis": "A", "x": at("u"), "n": AXIS.len()}),
        )
    };
    let mut m = json!({
        "variables": {
            "u": {"type": "unknown", "shape": ["lev"], "default": 1.0},
            "w": {"type": "unknown", "shape": ["lev"], "default": 1.0},
            "T": {"type": "unknown", "shape": ["k"]},
            "A": {"type": "unknown", "shape": ["k"]}
        },
        "equations": [
            {"lhs": "T", "rhs": super::test_support::lit(&TABLE)},
            {"lhs": "A", "rhs": super::test_support::lit(&AXIS)},
            {"lhs": d_lhs("u", &["l"], l.clone()),
             "rhs": faq(&["l"], l.clone(), op("*", vec![json!(-0.01), lookup()]))},
            {"lhs": d_lhs("w", &["l"], l.clone()),
             "rhs": faq(&["l"], l.clone(), op("*", vec![json!(0.02), lookup()]))}
        ]
    });
    m["operators"] = library("interp.esm");
    let doc = json!({"esm": "2.0.0", "metadata": {"name": "identical_calls"}, "models": {"M": m}});
    let (prog, _) = oracle_ab(doc);
    let n_calls = prog
        .instrs
        .iter()
        .filter(|i| matches!(i, Instr::Call { .. }))
        .count();
    assert_eq!(
        n_calls, 1,
        "the second reference reads the first call's result"
    );
}
