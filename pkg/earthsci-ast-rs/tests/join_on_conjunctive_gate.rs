//! CONJUNCTIVE, selectivity-ordered `join.on` gating — CONFORMANCE_SPEC.md
//! §5.24, the successor to §5.5.8's "only ONE need DRIVE ... the reference
//! drives the first in document order".
//!
//! Three things are asserted here, and the driver is only legitimate if all
//! three hold:
//!
//! 1. **Many-to-many survives the intersection.** RFC `semiring-faq-unified-ir`
//!    §5.3 defines a key occurring `m` times left and `n` times right as
//!    yielding all `m·n` combined terms, and an unmatched row as contributing
//!    the additive identity `0̄`. An intersection is exactly where that is easy
//!    to get wrong — drop one partner and the answer is quietly smaller, keep a
//!    duplicate and it is quietly larger — so every arm here is compared
//!    bit-for-bit against a plain-Rust oracle that folds the admitted terms in
//!    the same ascending order the odometer does.
//! 2. **The result does NOT depend on the clause order.** §5.24 leaves the
//!    driver's selectivity estimate free but requires the RESULT to be
//!    invariant. Each fixture is therefore evaluated under EVERY permutation of
//!    its `join` clauses and every permutation must agree bit-for-bit, with the
//!    hand-written `filter` the clauses lower to, and with the same document
//!    under the driver kill-switch (`set_join_gate_enabled(false)`).
//! 3. **The conjunction actually DRIVES.** The leaf-visit counter
//!    (`overlap_enum_visits`, bumped only on the gate-driven unroll) must equal
//!    the number of tuples the clauses TOGETHER admit — not what the best
//!    single clause admits, which is what the pre-§5.24 driver cost. This is
//!    the assertion that goes red if the intersection silently degrades back
//!    into "drive on one, filter with the rest": the answers stay right and
//!    only the cost regresses.

#![cfg(not(target_arch = "wasm32"))]

use std::collections::HashMap;

use earthsci_ast::extension::broad_phase::{
    overlap_enum_visits, reset_overlap_enum_visits, set_join_gate_enabled,
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

fn eq(lcol: &str, lsym: &str, rcol: &str, rsym: &str) -> Value {
    json!({"op": "==", "args": [ix(lcol, lsym), ix(rcol, rsym)]})
}

/// Every permutation of `0..n` (n ≤ 4 here), so a fixture can be run under each
/// ordering of its `join` clauses.
fn permutations(n: usize) -> Vec<Vec<usize>> {
    let mut out = vec![vec![]];
    for _ in 0..n {
        let mut next = Vec::new();
        for p in &out {
            for v in 0..n {
                if !p.contains(&v) {
                    let mut q = p.clone();
                    q.push(v);
                    next.push(q);
                }
            }
        }
        out = next;
    }
    out
}

// =========================================================================== //
// Fixture A — TWO clauses restricting ONE contracted axis (the J11 shape)
// =========================================================================== //

/// `E[l] = Σ_{r : a-keys equal AND b-keys equal} activity[l] · rate[r]`.
///
/// The shape moves.esm's `tech_fraction` has: one output axis, one contracted
/// row axis, and several clauses each pairing the output axis with the row
/// axis. Pre-§5.24 exactly one of them drove and the other was a per-leaf test;
/// now the contracted axis walks the INTERSECTION of the two partner lists.
///
/// Both key columns carry deliberate duplicates so the many-to-many
/// cardinality is non-trivial and the two clauses disagree about which rows to
/// admit: `akey` alone admits far more than the pair does.
struct TwoClause {
    lkey_a: Vec<f64>,
    lkey_b: Vec<f64>,
    rkey_a: Vec<f64>,
    rkey_b: Vec<f64>,
    activity: Vec<f64>,
    rate: Vec<f64>,
}

impl TwoClause {
    fn nl(&self) -> usize {
        self.lkey_a.len()
    }
    fn nr(&self) -> usize {
        self.rkey_a.len()
    }

    fn matches(&self, l: usize, r: usize) -> bool {
        self.lkey_a[l] == self.rkey_a[r] && self.lkey_b[l] == self.rkey_b[r]
    }

    /// The admitted (l, r) pairs — what a conjunctively-driven walk must visit.
    fn conjunction_size(&self) -> u64 {
        let mut n = 0;
        for l in 0..self.nl() {
            for r in 0..self.nr() {
                if self.matches(l, r) {
                    n += 1;
                }
            }
        }
        n
    }

    /// What the BEST single clause admits — the pre-§5.24 cost, and the number
    /// the visit assertion must NOT see.
    fn best_single_clause_size(&self) -> u64 {
        let count = |lk: &[f64], rk: &[f64]| -> u64 {
            let mut n = 0;
            for &a in lk {
                for &b in rk {
                    if a == b {
                        n += 1;
                    }
                }
            }
            n
        };
        count(&self.lkey_a, &self.rkey_a).min(count(&self.lkey_b, &self.rkey_b))
    }

    /// `Σ_r` folded ascending, the odometer's association, so the comparison is
    /// bit-exact rather than merely close.
    fn oracle(&self) -> Vec<f64> {
        (0..self.nl())
            .map(|l| {
                let mut acc = 0.0f64;
                for r in 0..self.nr() {
                    if self.matches(l, r) {
                        acc += self.activity[l] * self.rate[r];
                    }
                }
                acc
            })
            .collect()
    }

    fn const_arrays(&self) -> HashMap<String, ArrayD<f64>> {
        [
            ("lkey_a", &self.lkey_a),
            ("lkey_b", &self.lkey_b),
            ("rkey_a", &self.rkey_a),
            ("rkey_b", &self.rkey_b),
            ("activity", &self.activity),
            ("rate", &self.rate),
        ]
        .into_iter()
        .map(|(n, v)| (n.to_string(), arr1(v)))
        .collect()
    }

    /// `perm` orders the two `join` clauses; `gate` false spells them as the
    /// hand-written `filter` they lower to instead.
    fn doc(&self, perm: &[usize], gate: bool) -> Value {
        let clauses = [
            json!({"on": [["lkey_a", "rkey_a"]]}),
            json!({"on": [["lkey_b", "rkey_b"]]}),
        ];
        let mut node = json!({
            "op": "aggregate",
            "reduce": "+",
            "output_idx": ["l"],
            "ranges": {"l": {"from": "lrows"}, "r": {"from": "rrows"}},
            "args": ["lkey_a", "lkey_b", "rkey_a", "rkey_b", "activity", "rate"],
            "expr": {"op": "*", "args": [ix("activity", "l"), ix("rate", "r")]}
        });
        let obj = node.as_object_mut().unwrap();
        if gate {
            obj.insert(
                "join".into(),
                Value::Array(perm.iter().map(|&i| clauses[i].clone()).collect()),
            );
        } else {
            obj.insert(
                "filter".into(),
                json!({"op": "and", "args": [
                    eq("lkey_a", "l", "rkey_a", "r"),
                    eq("lkey_b", "l", "rkey_b", "r"),
                ]}),
            );
        }
        json!({
            "esm": "1.0.0",
            "metadata": {"name": "join_on_conjunctive_gate"},
            "index_sets": {
                "lrows": {"kind": "interval", "size": self.nl()},
                "rrows": {"kind": "interval", "size": self.nr()}
            },
            "models": {"J": {
                "variables": {
                    "lkey_a": {"type": "parameter", "shape": ["lrows"]},
                    "lkey_b": {"type": "parameter", "shape": ["lrows"]},
                    "activity": {"type": "parameter", "shape": ["lrows"]},
                    "rkey_a": {"type": "parameter", "shape": ["rrows"]},
                    "rkey_b": {"type": "parameter", "shape": ["rrows"]},
                    "rate": {"type": "parameter", "shape": ["rrows"]},
                    "E": {"type": "unknown", "shape": ["lrows"]}
                },
                "equations": [{"lhs": "E", "rhs": node}]
            }}
        })
    }
}

/// Materialize `E`, returning `(values, gate-driven leaf visits)`.
fn run(doc: &Value, consts: HashMap<String, ArrayD<f64>>, driver: bool) -> (Vec<f64>, u64) {
    let prev = set_join_gate_enabled(driver);
    reset_overlap_enum_visits();
    let prep = esm_problem(
        doc,
        (0.0, 0.0),
        ProblemOptions {
            model_name: Some("J".into()),
            const_arrays: consts,
            build_providers: Vec::new(),
            ..Default::default()
        },
    )
    .expect("prepare");
    let visits = overlap_enum_visits();
    let field = observed_field(&prep, "E").expect("E materialized");
    set_join_gate_enabled(prev);
    (field.iter().copied().collect(), visits)
}

fn assert_bits(what: &str, got: &[f64], want: &[f64]) {
    assert_eq!(got.len(), want.len(), "{what}: wrong output length");
    for (i, (g, w)) in got.iter().zip(want).enumerate() {
        assert_eq!(
            g.to_bits(),
            w.to_bits(),
            "{what}: E[{i}] = {g} but the reference says {w}"
        );
    }
}

/// The many-to-many fixture, laid out so that every quantity the assertions
/// name is checkable by hand:
///
/// * `akey` 7 appears 3x left and 3x right, so clause A alone admits 9 pairs
///   there; `bkey` cuts them to the 2x2 that also agree on `b`.
/// * left row 3 agrees with nothing on `b` at all — its output must be the
///   additive identity, not a hole and not clause A's answer.
/// * left row 4 agrees with nothing on either key.
fn m2m() -> TwoClause {
    TwoClause {
        lkey_a: vec![7.0, 7.0, 7.0, 9.0, 5.0],
        lkey_b: vec![1.0, 1.0, 2.0, 4.0, 4.0],
        rkey_a: vec![7.0, 7.0, 7.0, 9.0, 9.0, 8.0],
        rkey_b: vec![1.0, 1.0, 3.0, 2.0, 2.0, 1.0],
        activity: vec![1.0, 2.0, 3.0, 4.0, 5.0],
        rate: vec![10.0, 20.0, 30.0, 40.0, 50.0, 60.0],
    }
}

#[test]
fn many_to_many_survives_the_conjunctive_intersection() {
    let t = m2m();
    // Hand-counted: (l0,l1) x (r0,r1) on (a=7,b=1) — 2x2 = 4 — and nothing
    // else. Every other agreement on `a` disagrees on `b`.
    assert_eq!(t.conjunction_size(), 4, "the fixture is a 2x2 many-to-many");
    // Clause A alone admits 3x3 (key 7) + 1x2 (key 9) = 11; clause B alone
    // 2x2 (key 1) + 1x2 (key 4->2? no) ... the MIN of the two is what the
    // pre-§5.24 driver would have walked, and it is strictly more than 4.
    assert!(
        t.best_single_clause_size() > t.conjunction_size(),
        "the fixture must distinguish the conjunction from the best single clause"
    );

    let oracle = t.oracle();
    // Left row 3 matches on `a` (9 == 9, twice) but never on `b`: the identity.
    assert_eq!(oracle[3], 0.0, "an unmatched row contributes 0̄");
    assert_eq!(oracle[4], 0.0, "a row matching neither key contributes 0̄");
    // The two matched rows are m·n sums, not single terms.
    assert_eq!(oracle[0], 1.0 * 10.0 + 1.0 * 20.0);
    assert_eq!(oracle[1], 2.0 * 10.0 + 2.0 * 20.0);

    // The hand-written filter the clauses lower to — the differential baseline.
    let (filtered, filter_visits) = run(&t.doc(&[0, 1], false), t.const_arrays(), true);
    assert_eq!(
        filter_visits, 0,
        "the un-gated arm must not run the gate-driven unroll"
    );
    assert_bits("hand-written filter", &filtered, &oracle);

    for perm in permutations(2) {
        let what = format!("clause order {perm:?}");
        let (got, visits) = run(&t.doc(&perm, true), t.const_arrays(), true);
        assert_bits(&what, &got, &oracle);
        assert_eq!(
            visits,
            t.conjunction_size(),
            "{what}: the driven walk must visit the tuples the clauses TOGETHER \
             admit ({}), not what the best single clause admits ({})",
            t.conjunction_size(),
            t.best_single_clause_size()
        );

        // …and the same document with the driver killed, which walks the full
        // product and lets the lowered `filter` decide.
        let (undriven, undriven_visits) = run(&t.doc(&perm, true), t.const_arrays(), false);
        assert_eq!(undriven_visits, 0, "{what}: the kill-switch must not drive");
        assert_bits(&format!("{what}, driver off"), &undriven, &oracle);
    }
}

#[test]
fn an_empty_intersection_is_the_semiring_identity_not_a_hole() {
    // Clause A admits the DIAGONAL pairs and clause B admits the
    // ANTI-diagonal ones, so each clause on its own admits two leaves and
    // their intersection admits none. Every output must then be exactly `+0.0`
    // under (+, 0) — §5.5.6 identity fill, not a hole and not a NaN.
    let t = TwoClause {
        lkey_a: vec![1.0, 2.0],
        lkey_b: vec![9.0, 8.0],
        rkey_a: vec![1.0, 2.0],
        rkey_b: vec![8.0, 9.0],
        activity: vec![3.0, 4.0],
        rate: vec![5.0, 6.0],
    };
    assert_eq!(t.conjunction_size(), 0);
    assert!(t.best_single_clause_size() > 0, "each clause alone matches");
    for perm in permutations(2) {
        let (got, visits) = run(&t.doc(&perm, true), t.const_arrays(), true);
        assert_eq!(visits, 0, "an empty intersection visits no leaf at all");
        for (i, v) in got.iter().enumerate() {
            assert_eq!(
                v.to_bits(),
                0.0f64.to_bits(),
                "E[{i}] must be +0.0, got {v}"
            );
        }
    }
}

// =========================================================================== //
// Fixture B — the intersection UNDER a both-contracted gate
// =========================================================================== //

/// `E[l] = Σ_{r,s} activity[l] · rate[r] · weight[s]` gated by
///
/// * `lkey_a ↔ rkey_a` and `lkey_b ↔ rkey_b` — two clauses pairing the OUTPUT
///   axis with the contracted row axis, so `r` walks their intersection;
/// * `rkey_c ↔ skey_c` — a clause pairing TWO CONTRACTED axes, §5.5.8's fourth
///   shape, so `s` walks `r`'s partners.
///
/// This is the arm where the two mechanisms meet: the partner-restricted walk
/// has to intersect its own partner list against the list Phase 1 already
/// admitted for `s`… and, more subtly, has to iterate `r` over the RESTRICTED
/// list rather than over its range. It is J11 exactly (four clauses, three of
/// them output↔row and one row↔process-group).
struct ThreeClause {
    lkey_a: Vec<f64>,
    lkey_b: Vec<f64>,
    rkey_a: Vec<f64>,
    rkey_b: Vec<f64>,
    rkey_c: Vec<f64>,
    skey_c: Vec<f64>,
    activity: Vec<f64>,
    rate: Vec<f64>,
    weight: Vec<f64>,
}

impl ThreeClause {
    fn matches(&self, l: usize, r: usize, s: usize) -> bool {
        self.lkey_a[l] == self.rkey_a[r]
            && self.lkey_b[l] == self.rkey_b[r]
            && self.rkey_c[r] == self.skey_c[s]
    }

    fn admitted(&self) -> u64 {
        let mut n = 0;
        for l in 0..self.lkey_a.len() {
            for r in 0..self.rkey_a.len() {
                for s in 0..self.skey_c.len() {
                    if self.matches(l, r, s) {
                        n += 1;
                    }
                }
            }
        }
        n
    }

    /// Folded in the odometer's order: `r` slow, `s` fast (the contracted
    /// symbols run in ascending name order, `r` before `s`).
    fn oracle(&self) -> Vec<f64> {
        (0..self.lkey_a.len())
            .map(|l| {
                let mut acc = 0.0f64;
                for r in 0..self.rkey_a.len() {
                    for s in 0..self.skey_c.len() {
                        if self.matches(l, r, s) {
                            acc += self.activity[l] * self.rate[r] * self.weight[s];
                        }
                    }
                }
                acc
            })
            .collect()
    }

    fn const_arrays(&self) -> HashMap<String, ArrayD<f64>> {
        [
            ("lkey_a", &self.lkey_a),
            ("lkey_b", &self.lkey_b),
            ("activity", &self.activity),
            ("rkey_a", &self.rkey_a),
            ("rkey_b", &self.rkey_b),
            ("rkey_c", &self.rkey_c),
            ("rate", &self.rate),
            ("skey_c", &self.skey_c),
            ("weight", &self.weight),
        ]
        .into_iter()
        .map(|(n, v)| (n.to_string(), arr1(v)))
        .collect()
    }

    fn doc(&self, perm: &[usize], gate: bool) -> Value {
        let clauses = [
            json!({"on": [["lkey_a", "rkey_a"]]}),
            json!({"on": [["lkey_b", "rkey_b"]]}),
            json!({"on": [["rkey_c", "skey_c"]]}),
        ];
        let mut node = json!({
            "op": "aggregate",
            "reduce": "+",
            "output_idx": ["l"],
            "ranges": {
                "l": {"from": "lrows"}, "r": {"from": "rrows"}, "s": {"from": "srows"}
            },
            "args": ["lkey_a", "lkey_b", "rkey_a", "rkey_b", "rkey_c", "skey_c",
                     "activity", "rate", "weight"],
            "expr": {"op": "*", "args": [
                {"op": "*", "args": [ix("activity", "l"), ix("rate", "r")]},
                ix("weight", "s")
            ]}
        });
        let obj = node.as_object_mut().unwrap();
        if gate {
            obj.insert(
                "join".into(),
                Value::Array(perm.iter().map(|&i| clauses[i].clone()).collect()),
            );
        } else {
            obj.insert(
                "filter".into(),
                json!({"op": "and", "args": [
                    eq("lkey_a", "l", "rkey_a", "r"),
                    eq("lkey_b", "l", "rkey_b", "r"),
                    eq("rkey_c", "r", "skey_c", "s"),
                ]}),
            );
        }
        json!({
            "esm": "1.0.0",
            "metadata": {"name": "join_on_conjunctive_gate_3"},
            "index_sets": {
                "lrows": {"kind": "interval", "size": self.lkey_a.len()},
                "rrows": {"kind": "interval", "size": self.rkey_a.len()},
                "srows": {"kind": "interval", "size": self.skey_c.len()}
            },
            "models": {"J": {
                "variables": {
                    "lkey_a": {"type": "parameter", "shape": ["lrows"]},
                    "lkey_b": {"type": "parameter", "shape": ["lrows"]},
                    "activity": {"type": "parameter", "shape": ["lrows"]},
                    "rkey_a": {"type": "parameter", "shape": ["rrows"]},
                    "rkey_b": {"type": "parameter", "shape": ["rrows"]},
                    "rkey_c": {"type": "parameter", "shape": ["rrows"]},
                    "rate": {"type": "parameter", "shape": ["rrows"]},
                    "skey_c": {"type": "parameter", "shape": ["srows"]},
                    "weight": {"type": "parameter", "shape": ["srows"]},
                    "E": {"type": "unknown", "shape": ["lrows"]}
                },
                "equations": [{"lhs": "E", "rhs": node}]
            }}
        })
    }
}

#[test]
fn a_both_contracted_gate_composes_with_the_intersection() {
    // `r` rows 0..3 all carry a = 7; only rows 0 and 2 also carry b = 1, so the
    // intersection for l = 0 is {r0, r2}. Each of those points at a `c` value
    // that TWO `s` rows carry, so the answer is a 2x2 many-to-many across the
    // second contracted axis as well.
    let t = ThreeClause {
        lkey_a: vec![7.0, 9.0],
        lkey_b: vec![1.0, 1.0],
        rkey_a: vec![7.0, 7.0, 7.0, 7.0],
        rkey_b: vec![1.0, 2.0, 1.0, 2.0],
        rkey_c: vec![100.0, 100.0, 200.0, 200.0],
        skey_c: vec![100.0, 200.0, 200.0],
        activity: vec![1.0, 2.0],
        rate: vec![10.0, 20.0, 30.0, 40.0],
        weight: vec![0.5, 0.25, 0.125],
    };
    // l0: r0 (c=100 -> s0) and r2 (c=200 -> s1, s2) = 3 leaves. l1 matches no r.
    assert_eq!(t.admitted(), 3);
    let oracle = t.oracle();
    assert_eq!(oracle[1], 0.0, "l1 matches nothing: the identity");

    let (filtered, filter_visits) = run(&t.doc(&[0, 1, 2], false), t.const_arrays(), true);
    assert_eq!(filter_visits, 0);
    assert_bits("hand-written filter", &filtered, &oracle);

    for perm in permutations(3) {
        let what = format!("clause order {perm:?}");
        let (got, visits) = run(&t.doc(&perm, true), t.const_arrays(), true);
        assert_bits(&what, &got, &oracle);
        assert_eq!(
            visits,
            t.admitted(),
            "{what}: the conjunction of all three clauses admits {} leaves",
            t.admitted()
        );
        let (undriven, undriven_visits) = run(&t.doc(&perm, true), t.const_arrays(), false);
        assert_eq!(undriven_visits, 0, "{what}: the kill-switch must not drive");
        assert_bits(&format!("{what}, driver off"), &undriven, &oracle);
    }
}
