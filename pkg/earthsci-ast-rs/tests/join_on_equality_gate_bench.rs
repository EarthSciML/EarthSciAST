//! Wall-clock before/after for the `join.on` equality gate (CONFORMANCE_SPEC.md
//! §5.5.8). `#[ignore]`d — these are measurements, not assertions, and the large
//! arm deliberately runs the full `O(N·M)` product once.
//!
//! ```text
//! cargo test --test join_on_equality_gate_bench -- --ignored --nocapture
//! ```
//!
//! Three arms over the identical two-table equi-join, so the only thing that
//! varies is HOW the equality is spelled:
//!
//! * **filter (raw)** — the equality written by hand as
//!   `index(lkey,l) == index(rkey,r)`. This is the shape `join.on` lowers to,
//!   and the fastest pre-gate spelling.
//!   It is if anything a CONSERVATIVE baseline: for a key resolving to a loop
//!   symbol the pre-gate lowering routed the same equality through two constant
//!   code tables (`index(makearray(…), sym)` per side), which is strictly more
//!   work per leaf — the reason `join.on` used to be *slower* than the filter it
//!   lowered to.
//! * **join.on, gate ON** — driving enumeration from the match set.
//!
//! Both must agree BIT-for-bit; the test asserts that before reporting a time.
//!
//! Set `ESS_VEC_DISABLE=1` to measure the per-cell oracle regime instead of the
//! whole-array overlay — the aggregate here is simple enough that the overlay
//! claims the un-driven arm and folds the product as shifted whole-array
//! slices, which is far faster than the per-cell walk while still being
//! `O(N·M)`. Both regimes are reported in the branch notes.

#![cfg(not(target_arch = "wasm32"))]

use std::collections::HashMap;
use std::time::Instant;

use earthsci_ast::extension::broad_phase::set_join_gate_enabled;
use earthsci_ast::{ProblemOptions, esm_problem, observed_field};
use ndarray::{ArrayD, IxDyn};
use serde_json::{Value, json};

fn arr1(v: &[f64]) -> ArrayD<f64> {
    ArrayD::from_shape_vec(IxDyn(&[v.len()]), v.to_vec()).unwrap()
}

fn ix(f: &str, i: &str) -> Value {
    json!({"op": "index", "args": [f, i]})
}

#[derive(Clone, Copy)]
enum Arm {
    GateOff,
    GateOn,
}

impl Arm {
    fn label(self) -> &'static str {
        match self {
            Arm::GateOff => "join.on, gate OFF (full product)",
            Arm::GateOn => "join.on, gate ON  (driven)      ",
        }
    }
}

/// `nl` source rows and `nr` factor rows over `nkeys` distinct integer IDs.
fn doc(nl: usize, nr: usize, nkeys: usize) -> (Value, HashMap<String, ArrayD<f64>>) {
    let lkey: Vec<f64> = (0..nl).map(|i| (i % nkeys) as f64 + 1.0).collect();
    let rkey: Vec<f64> = (0..nr).map(|j| (j % nkeys) as f64 + 1.0).collect();
    let activity: Vec<f64> = (0..nl).map(|i| 1.0 + (i % 7) as f64).collect();
    let rate: Vec<f64> = (0..nr).map(|j| 0.5 + (j % 11) as f64).collect();

    let mut node = json!({
        "op": "aggregate",
        "reduce": "+",
        "output_idx": ["l"],
        "ranges": {"l": {"from": "lrows"}, "r": {"from": "rrows"}},
        "args": ["lkey", "rkey", "activity", "rate"],
        "expr": {"op": "*", "args": [ix("activity", "l"), ix("rate", "r")]}
    });
    node.as_object_mut()
        .unwrap()
        .insert("join".into(), json!([{"on": [["lkey", "rkey"]]}]));

    let doc = json!({
        "esm": "1.0.0",
        "metadata": {"name": "join_on_bench"},
        "index_sets": {
            "lrows": {"kind": "interval", "size": nl},
            "rrows": {"kind": "interval", "size": nr}
        },
        "models": {"J": {
            "variables": {
                "lkey": {"type": "parameter", "shape": ["lrows"]},
                "activity": {"type": "parameter", "shape": ["lrows"]},
                "rkey": {"type": "parameter", "shape": ["rrows"]},
                "rate": {"type": "parameter", "shape": ["rrows"]},
                "E": {"type": "unknown", "shape": ["lrows"]}
            },
            "equations": [{"lhs": "E", "rhs": node}]
        }}
    });
    let arrays = [
        ("lkey".to_string(), arr1(&lkey)),
        ("rkey".to_string(), arr1(&rkey)),
        ("activity".to_string(), arr1(&activity)),
        ("rate".to_string(), arr1(&rate)),
    ]
    .into_iter()
    .collect();
    (doc, arrays)
}

fn time_arm(nl: usize, nr: usize, nkeys: usize, arm: Arm) -> (f64, Vec<f64>) {
    let (d, arrays) = doc(nl, nr, nkeys);
    let prev = set_join_gate_enabled(matches!(arm, Arm::GateOn));
    let t = Instant::now();
    let prep = esm_problem(
        &d,
        (0.0, 0.0),
        ProblemOptions {
            model_name: Some("J".into()),
            const_arrays: arrays,
            build_providers: Vec::new(),
            ..Default::default()
        },
    )
    .expect("prepare");
    let secs = t.elapsed().as_secs_f64();
    set_join_gate_enabled(prev);
    let e = observed_field(&prep, "E").expect("E materialized");
    (secs, e.iter().copied().collect())
}

fn report(nl: usize, nr: usize, nkeys: usize, arms: &[Arm]) {
    let matches = nl * (nr / nkeys.max(1));
    println!(
        "\n=== {nl} x {nr} = {} combinations, {nkeys} keys, {matches} matches ===",
        nl * nr
    );
    let mut reference: Option<Vec<f64>> = None;
    for &arm in arms {
        let (secs, vals) = time_arm(nl, nr, nkeys, arm);
        match &reference {
            None => reference = Some(vals),
            Some(r) => assert_eq!(
                r.iter().map(|v| v.to_bits()).collect::<Vec<_>>(),
                vals.iter().map(|v| v.to_bits()).collect::<Vec<_>>(),
                "{} disagrees with the first arm",
                arm.label()
            ),
        }
        println!("  {}  {secs:>9.3} s", arm.label());
    }
}

#[test]
#[ignore = "measurement, not an assertion; run with --ignored --nocapture"]
fn bench_500k_combinations() {
    report(500, 1000, 1000, &[Arm::GateOff, Arm::GateOn]);
}

#[test]
#[ignore = "measurement, not an assertion; run with --ignored --nocapture"]
fn bench_10m_combinations() {
    report(1000, 10_000, 10_000, &[Arm::GateOff, Arm::GateOn]);
}

/// The size the pre-gate path could not reach at all: the full product here is
/// 10^8 leaves. Driven only.
#[test]
#[ignore = "measurement, not an assertion; run with --ignored --nocapture"]
fn bench_100m_combinations_gated_only() {
    report(10_000, 10_000, 10_000, &[Arm::GateOn]);
}
