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

/// `pick(a, x) = a[floor(x) + 4]`: past the end of `a` once `x >= 1`, so a
/// call faults where its state does.
fn faulting_batch(n_fields: usize) -> Value {
    use super::test_support::{d_eq, doc, idx, lit, plus};
    let mut vars = serde_json::Map::new();
    vars.insert("C".into(), json!({"type": "unknown", "shape": ["c"]}));
    let mut eqs = vec![json!({"lhs": "C", "rhs": lit(&[1.0, 2.0, 3.0, 4.0])})];
    for k in 1..=n_fields {
        let u = format!("u{k}");
        vars.insert(u.clone(), json!({"type": "unknown", "shape": ["i"]}));
        let x = idx(json!(u.clone()), &[json!("i")]);
        let call = apply("pick", json!({"a": "C", "x": x}));
        eqs.push(d_eq(&u, 5, plus(call, json!(k as f64))));
    }
    let mut d = doc(Value::Object(vars), eqs);
    d["models"]["M"]["operators"] = json!({
        "pick": {
            "params": ["a", "x"],
            "body": idx(json!("a"), &[plus(json!({"op": "floor", "args": ["x"]}), json!(4))])
        }
    });
    d
}

/// A fault inside a batched call is reported as without batching: the
/// latched fault (and `dy`) match the per-cell oracle's, on fresh scratches,
/// whichever calls of the batch fault.
#[test]
fn a_fault_inside_a_batch_is_reported_as_without_batching() {
    let compiled = super::test_support::compile(faulting_batch(3));
    let prog = super::test_support::ab(&compiled, &super::test_support::no_params());
    let (n_batches, n_calls) = batches(&prog);
    assert!(
        n_batches >= 1 && n_calls >= 3,
        "{n_batches} batches of {n_calls} calls"
    );
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
