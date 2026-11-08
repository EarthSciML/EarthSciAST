//! The closed-AST standard-library shapes through the XLA emitter
//! ([`super::xla_emit`]), against the per-cell oracle:
//!
//!   * the comparison count ([`Instr::Count`](super::ir::Instr::Count)) over
//!     compile-time keys, both lowerings — one comparison per key below
//!     `COUNT_SEARCH_MIN` (64) keys, the bisection from it — on every relation and
//!     both branch orders, with NaN, signed-zero and duplicate keys, unsorted
//!     keys, and NaN, infinite and on-a-key queries. The count is an integer,
//!     so the compiled value is held to the oracle's bits;
//!   * the computed-subscript gather
//!     ([`Instr::DataGather`](super::ir::Instr::DataGather)) under the zero
//!     ghost and the `clamp` and `periodic` policies, at subscripts that are
//!     NaN, infinite, huge and negative — integer selection, so bit for bit;
//!     a gather that can fault stays refused by name;
//!   * every lib template family on the tape (calendar, planar and spherical
//!     overlap, argmin, the keyed and gated relational templates, interp),
//!     within the compiled tier's tolerance classes.

use super::super::ArrayCompiled;
use super::array_tests::{compile, d_eq, doc, idx, lit, plus};
use crate::simulate_array::ConstArrayScope;
use crate::value_invention::BoundaryKind;
use crate::xla_runtime::{CompileRhsError, CompiledRhs};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::rc::Rc;

fn runtime_available() -> bool {
    if std::env::var_os("XLA_EXTENSION_DIR").is_none() {
        eprintln!("SKIP: XLA_EXTENSION_DIR is unset, so there is no XLA runtime to test against");
        return false;
    }
    true
}

fn program(compiled: &ArrayCompiled) -> CompiledRhs {
    match CompiledRhs::compile(compiled) {
        Ok(p) => p,
        Err(CompileRhsError::Refused(e)) => panic!("refused rule {}: {}", e.rule, e.reason),
        Err(CompileRhsError::Runtime(m)) => panic!("xla runtime: {m}"),
    }
}

/// The compiled `dy` and the per-cell oracle's at `state`.
fn both(
    compiled: &ArrayCompiled,
    prog: &CompiledRhs,
    state: &[f64],
    t: f64,
) -> (Vec<f64>, Vec<f64>) {
    let params: HashMap<String, f64> = HashMap::new();
    let pv = compiled.debug_resolve_params(&params);
    let got = prog.eval(state, &pv, t).expect("compiled eval");
    let (want, _) = compiled.debug_eval_rhs(state, t, &params, true);
    (got, want)
}

fn assert_bits(compiled: &ArrayCompiled, prog: &CompiledRhs, state: &[f64], what: &str) {
    let (got, want) = both(compiled, prog, state, 0.0);
    assert_eq!(got.len(), want.len(), "{what}: length");
    for (i, (g, w)) in got.iter().zip(&want).enumerate() {
        assert!(
            g.to_bits() == w.to_bits() || (g.is_nan() && w.is_nan()),
            "{what}: element {i} (state {}): compiled {g:?} vs oracle {w:?}",
            state[i]
        );
    }
}

/// Queries that probe every edge of a count: NaN, both infinities, both
/// zeros, values equal to keys, between keys, and outside the key range.
///
/// No subnormal query: XLA:CPU flushes subnormals to zero, so one compares
/// as a zero in the compiled program, in an ordinary fold as much as in the
/// count.
fn queries(keys: &[f64]) -> Vec<f64> {
    let mut q = vec![
        f64::NAN,
        f64::INFINITY,
        f64::NEG_INFINITY,
        0.0,
        -0.0,
        -5.0,
        50.0,
    ];
    for &k in keys.iter().filter(|k| k.is_finite()) {
        q.extend([k, k + 1e-9, k - 1e-9]);
    }
    q
}

/// `D(u[i]) = Σ_k ifelse(K[k] REL u[i], yes, no)`, the keys `K` a shaped
/// parameter fed through `const_arrays` (so a key can be NaN), compiled on
/// the problem route as a caller builds it.
fn count_model(
    keys: &[f64],
    rel: &str,
    yes: f64,
    no: f64,
    n_cells: usize,
    key_left: bool,
) -> Rc<ArrayCompiled> {
    let k = idx(json!("K"), &[json!("k")]);
    let u = idx(json!("u"), &[json!("i")]);
    let cmp = if key_left {
        json!({"op": rel, "args": [k, u]})
    } else {
        json!({"op": rel, "args": [u, k]})
    };
    let body = json!({"op": "faq", "args": [], "output_idx": [], "reduce": "+",
        "ranges": {"k": [1, keys.len()]},
        "expr": {"op": "ifelse", "args": [cmp, yes, no]}});
    let mut d = doc(
        json!({
            "u": {"type": "unknown", "shape": ["cells"], "default": 0.0},
            "K": {"type": "parameter", "shape": ["keys"]}
        }),
        vec![d_eq("u", n_cells as i64, body)],
    );
    d["index_sets"] = json!({
        "cells": {"kind": "interval", "size": n_cells},
        "keys": {"kind": "interval", "size": keys.len()}
    });
    let opts = crate::ProblemOptions {
        compiler: Some(crate::Compiler::Interpreter),
        const_arrays: [(
            "K".to_string(),
            ndarray::ArrayD::from_shape_vec(ndarray::IxDyn(&[keys.len()]), keys.to_vec()).unwrap(),
        )]
        .into_iter()
        .collect(),
        ..Default::default()
    };
    let prob = crate::esm_problem(&d, (0.0, 1.0), opts).expect("count document builds");
    prob.debug_array_compiled().expect("a right-hand side")
}

fn key_sets() -> Vec<(&'static str, Vec<f64>)> {
    let short_sorted = vec![-1.0, -0.0, 0.0, 0.5, 0.5, 1.0, 2.0, 3.0];
    let short_unsorted = vec![2.0, -1.0, 0.5, 3.0, 0.0, 0.5, -0.0, 1.0];
    let mut long_sorted: Vec<f64> = (0..80).map(|j| (j / 2) as f64 * 0.125 - 1.0).collect();
    long_sorted[16] = -0.0;
    long_sorted[17] = 0.0;
    let mut long_mixed = long_sorted.clone();
    long_mixed.reverse();
    long_mixed.swap(3, 60);
    long_mixed[7] = f64::NAN;
    long_mixed[41] = f64::NAN;
    vec![
        ("short sorted", short_sorted),
        ("short unsorted", short_unsorted),
        ("long sorted", long_sorted),
        ("long unsorted with NaN keys", long_mixed),
    ]
}

#[test]
fn counts_over_compile_time_keys_are_the_folds_integer() {
    if !runtime_available() {
        return;
    }
    for (label, keys) in key_sets() {
        let q = queries(&keys);
        for rel in ["<=", "<", ">=", ">"] {
            for (yes, no) in [(1.0, 0.0), (0.0, 1.0)] {
                for key_left in [true, false] {
                    let compiled = count_model(&keys, rel, yes, no, q.len(), key_left);
                    let prog = program(&compiled);
                    assert_eq!(
                        prog.opcode_count("Count"),
                        1,
                        "{label} {rel} ({yes}, {no}): the fold is one count"
                    );
                    // The bisection reads its keys by gather; the per-key
                    // comparison has none.
                    let hlo = super::xla_emit::emit_rhs(&compiled)
                        .and_then(|e| e.hlo_text())
                        .expect("emits");
                    assert_eq!(
                        hlo.contains("gather("),
                        keys.len() >= 64,
                        "{label} {rel}: bisection iff at least 64 keys"
                    );
                    let what = format!(
                        "{label}, key {} {rel} query, branches ({yes}, {no})",
                        if key_left {
                            "on the left"
                        } else {
                            "on the right"
                        }
                    );
                    assert_bits(&compiled, &prog, &q, &what);
                }
            }
        }
    }
}

/// Near misses of the count shape lower as an ordinary reduction and still
/// agree: other branch literals, and a key that reads the cell.
#[test]
fn near_miss_counts_lower_as_reductions() {
    if !runtime_available() {
        return;
    }
    let keys: Vec<f64> = (0..80).map(|j| j as f64 * 0.1).collect();
    let q = queries(&keys);
    let compiled = count_model(&keys, "<=", 2.0, 0.0, q.len(), true);
    let prog = program(&compiled);
    assert_eq!(
        prog.opcode_count("Count"),
        0,
        "branch literal 2 is not a count"
    );
    assert_bits(&compiled, &prog, &q, "ifelse(K[k] <= u[i], 2, 0)");
}

/// `D(u[i]) = C[s1] + C[s2]` with the subscripts read off the state.
fn gather_doc(n: usize) -> Value {
    let s = |k: i64| {
        plus(
            json!({"op": "floor", "args": [idx(json!("u"), &[json!("i")])]}),
            json!(k),
        )
    };
    doc(
        json!({
            "u": {"type": "unknown", "shape": ["i"]},
            "C": {"type": "unknown", "shape": ["c"]}
        }),
        vec![
            json!({"lhs": "C", "rhs": lit(&[1.5, -2.0, 3.25, 4.0, -0.0])}),
            d_eq(
                "u",
                n as i64,
                plus(idx(json!("C"), &[s(4)]), idx(json!("C"), &[s(-1)])),
            ),
        ],
    )
}

/// Subscript states at every rounding and saturation edge but those below the
/// s64 range, where the oracle's own `r - 1` overflows in a debug build.
fn subscript_states() -> Vec<f64> {
    vec![
        f64::NAN,
        f64::INFINITY,
        1e300,
        9.3e18,
        4.6e18,
        -4.6e18,
        0.0,
        -0.0,
        0.5,
        2.5,
        -2.5,
        -7.0,
        13.0,
        1e15 + 0.5,
        -3.9e15,
    ]
}

#[test]
fn computed_subscript_gathers_resolve_as_the_oracle_does() {
    if !runtime_available() {
        return;
    }
    let u = subscript_states();
    for kind in [BoundaryKind::Clamp, BoundaryKind::Periodic] {
        let mut compiled = compile(gather_doc(u.len()));
        compiled.const_scope =
            std::sync::Arc::new(ConstArrayScope::default().with_boundary("C", vec![kind]));
        let prog = program(&compiled);
        assert!(
            prog.opcode_count("DataGather") >= 1,
            "{kind:?}: a computed gather"
        );
        assert_bits(&compiled, &prog, &u, &format!("{kind:?} policy"));
    }
    // The state's zero ghost past either end, through a data subscript.
    let s = plus(
        json!({"op": "floor", "args": [idx(json!("u"), &[json!("i")])]}),
        json!(2),
    );
    let compiled = compile(doc(
        json!({"u": {"type": "unknown", "shape": ["i"]}}),
        vec![d_eq("u", u.len() as i64, idx(json!("u"), &[s]))],
    ));
    let prog = program(&compiled);
    assert_bits(&compiled, &prog, &u, "zero ghost");
}

/// A gather that can fault (the `error` policy at a run-time subscript) is
/// refused, naming the gather.
#[test]
fn a_faulting_computed_gather_is_refused_by_name() {
    if !runtime_available() {
        return;
    }
    let compiled = compile(gather_doc(6));
    match CompiledRhs::compile(&compiled) {
        Err(CompileRhsError::Refused(e)) => assert!(
            e.reason.contains("DataGather") && e.reason.contains("fault"),
            "{}",
            e.reason
        ),
        Err(CompileRhsError::Runtime(m)) => panic!("xla runtime: {m}"),
        Ok(_) => panic!("a gather that can fault must be refused"),
    }
}

/// `|got - want| <= rtol |want| + atol max|want|`, elementwise.
fn assert_close(compiled: &ArrayCompiled, prog: &CompiledRhs, rtol: f64, atol: f64, what: &str) {
    let n = compiled.state_variable_names().len();
    for seed in 0..3u64 {
        let state = super::tests::seeded_state(n, seed, 0.25, 2.5);
        let (got, want) = both(compiled, prog, &state, 0.7);
        let scale = want.iter().fold(0.0f64, |m, v| m.max(v.abs()));
        for (i, (g, w)) in got.iter().zip(&want).enumerate() {
            assert!(
                g == w
                    || (g.is_nan() && w.is_nan())
                    || (g - w).abs() <= rtol * w.abs() + atol * scale,
                "{what}: seed {seed} element {i}: compiled {g:e} vs oracle {w:e}"
            );
        }
    }
}

#[test]
fn every_template_family_lowers_and_matches_the_oracle() {
    if !runtime_available() {
        return;
    }
    use super::closed_template_tests as ct;
    let cases: Vec<(&str, Value, f64)> = vec![
        ("calendar", ct::calendar_doc(1.6e9, true), 1e-13),
        ("planar overlap", ct::overlap_doc(false), 1e-11),
        ("spherical overlap", ct::overlap_doc(true), 1e-11),
        ("argmin", ct::argmin_doc(), 1e-13),
        ("keyed and gated relational", ct::relational_doc(), 1e-13),
    ];
    for (what, d, tol) in cases {
        let compiled = compile(d);
        let prog = program(&compiled);
        assert_close(&compiled, &prog, tol, 1e-14, what);
    }
    for d in super::interp_template_tests::all_template_models() {
        let compiled = compile(d);
        let prog = program(&compiled);
        assert_close(&compiled, &prog, 1e-13, 1e-300, "interp template");
    }
}
