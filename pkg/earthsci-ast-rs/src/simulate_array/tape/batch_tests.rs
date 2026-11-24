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
