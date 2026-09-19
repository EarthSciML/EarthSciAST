//! The join-gate index caches have a RESIDENT-PAIR BUDGET (issue #418), so an
//! index can now be evicted and rebuilt within one run. This pins the two
//! properties that makes acceptable.
//!
//! 1. **It cannot change an answer.** A gate is a pure optimisation: the driver
//!    may decline one outright (the lowered `filter` then computes the same
//!    terms over the full product), and a rebuilt index is the same pure
//!    function of the same key columns. So a run with the budget set to zero —
//!    nothing retained past the gate that is holding it, every evaluation
//!    rebuilding from scratch — must be BIT-identical to a run with the default
//!    budget, and to the hand-written equality `filter` the gate lowers to.
//! 2. **It cannot change what the gate DRIVES.** The leaf-visit counter
//!    (`overlap_enum_visits`, bumped only on the gate-driven unroll) must read
//!    the same on both arms: an evicted index is rebuilt, not silently
//!    declined, and a declined gate would fall back to the full product and
//!    show up here as a different count.
//!
//! Why a whole file for a cache policy: the memoization is load-bearing (a gate
//! is resolved once per node and consulted once per output cell), so a change
//! to it is exactly the kind that looks harmless and is not.

#![cfg(not(target_arch = "wasm32"))]

use std::collections::HashMap;

use earthsci_ast::extension::broad_phase::{
    DEFAULT_GATE_CACHE_PAIRS, overlap_enum_visits, reset_overlap_enum_visits,
    set_gate_cache_pair_budget,
};
use earthsci_ast::{ProblemOptions, esm_problem, observed_field};
use ndarray::{ArrayD, IxDyn};
use serde_json::{Value, json};

fn arr1(v: &[f64]) -> ArrayD<f64> {
    ArrayD::from_shape_vec(IxDyn(&[v.len()]), v.to_vec()).unwrap()
}

fn ix(f: &str, i: &str) -> Value {
    json!({"op": "index", "args": [f, i]})
}

/// `L` rows carry a join key and an activity, `R` rows a key and a rate; the
/// single observed is `E[l] = Σ_{r : lkey[l] == rkey[r]} activity[l]·rate[r]`,
/// the shape a relational emissions roll-up has.
struct Tables {
    lkey: Vec<f64>,
    rkey: Vec<f64>,
    activity: Vec<f64>,
    rate: Vec<f64>,
}

impl Tables {
    /// A many-to-many fixture: 40 left rows over 8 keys against 24 right rows
    /// over the same 8, so every key matches 5×3 and the match set is 120 pairs.
    fn fixture() -> Tables {
        let lkey: Vec<f64> = (0..40).map(|i| (i % 8) as f64).collect();
        let rkey: Vec<f64> = (0..24).map(|j| (j % 8) as f64).collect();
        let activity = (1..=40).map(|i| i as f64).collect();
        let rate = (1..=24).map(|j| 10.0 * j as f64).collect();
        Tables {
            lkey,
            rkey,
            activity,
            rate,
        }
    }

    /// Folded in ascending `r`, the association the contraction odometer uses,
    /// so the oracle is bit-comparable and not merely close.
    fn oracle(&self) -> Vec<f64> {
        (0..self.lkey.len())
            .map(|l| {
                let mut acc = 0.0f64;
                for r in 0..self.rkey.len() {
                    if self.lkey[l] == self.rkey[r] {
                        acc += self.activity[l] * self.rate[r];
                    }
                }
                acc
            })
            .collect()
    }

    fn const_arrays(&self) -> HashMap<String, ArrayD<f64>> {
        [
            ("lkey".to_string(), arr1(&self.lkey)),
            ("rkey".to_string(), arr1(&self.rkey)),
            ("activity".to_string(), arr1(&self.activity)),
            ("rate".to_string(), arr1(&self.rate)),
        ]
        .into_iter()
        .collect()
    }

    /// `gated` selects the arm: the `join.on` gate under test, or the
    /// hand-written equality `filter` it lowers to (the differential baseline,
    /// which touches no cache at all).
    fn doc(&self, gated: bool) -> Value {
        let mut vars = serde_json::Map::new();
        for (name, set) in [
            ("lkey", "lrows"),
            ("activity", "lrows"),
            ("rkey", "rrows"),
            ("rate", "rrows"),
        ] {
            vars.insert(name.into(), json!({"type": "parameter", "shape": [set]}));
        }
        vars.insert("E".into(), json!({"type": "unknown", "shape": ["lrows"]}));

        let mut node = json!({
            "op": "faq",
            "reduce": "+",
            "output_idx": ["l"],
            "ranges": {"l": {"from": "lrows"}, "r": {"from": "rrows"}},
            "args": ["lkey", "rkey", "activity", "rate"],
            "expr": {"op": "*", "args": [ix("activity", "l"), ix("rate", "r")]}
        });
        let obj = node.as_object_mut().unwrap();
        if gated {
            obj.insert("join".into(), json!([{"on": [["lkey", "rkey"]]}]));
        } else {
            obj.insert(
                "filter".into(),
                json!({"op": "==", "args": [ix("lkey", "l"), ix("rkey", "r")]}),
            );
        }

        json!({
            "esm": "1.1.0",
            "metadata": {"name": "join_gate_cache_budget"},
            "index_sets": {
                "lrows": {"kind": "interval", "size": self.lkey.len()},
                "rrows": {"kind": "interval", "size": self.rkey.len()}
            },
            "models": {"J": {
                "variables": Value::Object(vars),
                "equations": [{"lhs": "E", "rhs": node}]
            }}
        })
    }
}

/// Materialize `E`, returning `(values, gate-driven leaf visits)`.
fn run(t: &Tables, gated: bool) -> (Vec<f64>, u64) {
    let doc = t.doc(gated);
    reset_overlap_enum_visits();
    let prep = esm_problem(
        &doc,
        (0.0, 0.0),
        ProblemOptions {
            model_name: Some("J".into()),
            const_arrays: t.const_arrays(),
            build_providers: Vec::new(),
            ..Default::default()
        },
    )
    .expect("prepare");
    let visits = overlap_enum_visits();
    let field = observed_field(&prep, "E").expect("E materialized");
    (field.iter().copied().collect(), visits)
}

/// Evaluate the gated document REPEATEDLY under one budget. Repetition is the
/// point: the first evaluation always builds the index, so only a second one
/// can tell a retained index from a rebuilt one.
fn run_repeatedly(t: &Tables, budget: usize, times: usize) -> (Vec<f64>, u64) {
    let prev = set_gate_cache_pair_budget(budget);
    let mut last = (Vec::new(), 0);
    for _ in 0..times {
        last = run(t, true);
    }
    set_gate_cache_pair_budget(prev);
    last
}

#[test]
fn a_zero_budget_rebuilds_the_index_and_answers_identically() {
    let t = Tables::fixture();
    let oracle = t.oracle();
    let (filtered, filter_visits) = run(&t, false);
    assert_eq!(
        filter_visits, 0,
        "the un-gated arm must not run the gate-driven unroll"
    );

    let (retained, retained_visits) = run_repeatedly(&t, DEFAULT_GATE_CACHE_PAIRS, 3);
    let (evicted, evicted_visits) = run_repeatedly(&t, 0, 3);

    assert_eq!(
        retained_visits, evicted_visits,
        "an evicted index must be REBUILT, not declined: a declined gate walks \
         the full product and would not bump the driven-unroll counter the same way"
    );
    assert!(
        evicted_visits > 0,
        "the gate stopped driving altogether under a zero budget"
    );

    assert_eq!(evicted.len(), t.lkey.len());
    for l in 0..t.lkey.len() {
        assert_eq!(
            evicted[l].to_bits(),
            retained[l].to_bits(),
            "E[{l}] differs between a retained index ({}) and a rebuilt one ({})",
            retained[l],
            evicted[l]
        );
        assert_eq!(
            evicted[l].to_bits(),
            filtered[l].to_bits(),
            "E[{l}] differs from the hand-written filter the gate lowers to"
        );
        assert_eq!(
            evicted[l].to_bits(),
            oracle[l].to_bits(),
            "E[{l}] = {} but the oracle says {}",
            evicted[l],
            oracle[l]
        );
    }
}

#[test]
fn the_budget_setter_reports_the_previous_setting() {
    let first = set_gate_cache_pair_budget(1234);
    assert_eq!(
        first, DEFAULT_GATE_CACHE_PAIRS,
        "an untouched thread starts at the default budget"
    );
    let second = set_gate_cache_pair_budget(first);
    assert_eq!(second, 1234, "the setter did not report what it replaced");
}
