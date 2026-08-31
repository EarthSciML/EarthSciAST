//! The value-equality (`join.on`) gate on the DENSE aggregate — CONFORMANCE_SPEC.md
//! §5.5.8, the equality mirror of the §5.5.6 overlap gate.
//!
//! `join.on` used to be lowered to a member-value-equality `filter` and nothing
//! else, so an `aggregate` contracting two row axes under an equality gate was a
//! genuine `O(N·M)` nested loop that merely TESTED equality — and a key naming a
//! genuine data column (one table's `sourceTypeID` against another's, which is
//! how a relational port such as EPA MOVES/NONROAD spells every join) was
//! rejected outright. The gate now resolves its whole match set once per node
//! and DRIVES enumeration from it.
//!
//! Two independent things are asserted throughout, because the driver is only
//! legitimate if BOTH hold:
//!
//! 1. **Differential correctness**, two ways. Every gated document is compared
//!    against the same document with the `join` clause replaced by the
//!    hand-written equality `filter` it lowers to — the pre-gate path — and, in
//!    `driving_is_bit_identical_to_the_undriven_full_product`, against the very
//!    same document with the driver killed (`set_join_gate_enabled(false)`).
//!    Both must agree BIT-for-bit, not merely to a tolerance: the driven walk
//!    emits an order-preserving subsequence of the filtered full product, so
//!    anything less than bit-identity is a bug. Each is independently checked
//!    against a plain-Rust oracle, so a shared mistake cannot pass.
//! 2. **Cost.** The gated arm's leaf-visit count (`overlap_enum_visits`, bumped
//!    only on the gate-DRIVEN unroll) tracks the MATCH count, not the index-set
//!    product. A visit count of zero means the gate silently declined and the
//!    filter path ran; a visit count near `N·M` means it stopped driving. Both
//!    fail here.

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

/// The hand-written predicate the pre-gate lowering produced for a data-column
/// key pair: raw value equality of the two gathered columns.
fn eq_filter(lcol: &str, lsym: &str, rcol: &str, rsym: &str) -> Value {
    json!({"op": "==", "args": [ix(lcol, lsym), ix(rcol, rsym)]})
}

/// A two-table equi-join document.
///
/// `L` rows carry `lkey` (and `lkey2` for the composite-key arm) plus a numeric
/// `activity`; `R` rows carry `rkey` / `rkey2` plus a numeric `rate`. The single
/// observed is
///
/// ```text
/// E[l] = Σ_{r : keys equal} activity[l] · rate[r]
/// ```
///
/// which is the shape a MOVES emissions rollup has: one gated symbol is an
/// OUTPUT index and the other is contracted — §5.5.6's RESTRICT binding case.
///
/// `gate` selects the arm: `Gate::On` spells the join as `join.on` (the form
/// under test), `Gate::Filter` spells the identical semantics as the explicit
/// `filter` predicate the old lowering emitted (the differential baseline).
#[derive(Clone, Copy, PartialEq)]
enum Gate {
    On,
    Filter,
}

struct Tables {
    lkey: Vec<f64>,
    rkey: Vec<f64>,
    lkey2: Option<Vec<f64>>,
    rkey2: Option<Vec<f64>>,
    activity: Vec<f64>,
    rate: Vec<f64>,
}

impl Tables {
    fn simple(lkey: Vec<f64>, rkey: Vec<f64>) -> Tables {
        let activity = (1..=lkey.len()).map(|i| i as f64).collect();
        let rate = (1..=rkey.len()).map(|j| 10.0 * j as f64).collect();
        Tables {
            lkey,
            rkey,
            lkey2: None,
            rkey2: None,
            activity,
            rate,
        }
    }

    fn nl(&self) -> usize {
        self.lkey.len()
    }
    fn nr(&self) -> usize {
        self.rkey.len()
    }

    /// `E[l] = Σ_{r matching} activity[l]·rate[r]`, folded in ascending `r` — the
    /// same association the contraction odometer uses, so the oracle is
    /// bit-comparable and not merely close.
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

    fn matches(&self, l: usize, r: usize) -> bool {
        if self.lkey[l] != self.rkey[r] {
            return false;
        }
        match (&self.lkey2, &self.rkey2) {
            (Some(a), Some(b)) => a[l] == b[r],
            _ => true,
        }
    }

    fn match_count(&self) -> u64 {
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

    fn const_arrays(&self) -> HashMap<String, ArrayD<f64>> {
        let mut m: HashMap<String, ArrayD<f64>> = [
            ("lkey".to_string(), arr1(&self.lkey)),
            ("rkey".to_string(), arr1(&self.rkey)),
            ("activity".to_string(), arr1(&self.activity)),
            ("rate".to_string(), arr1(&self.rate)),
        ]
        .into_iter()
        .collect();
        if let (Some(a), Some(b)) = (&self.lkey2, &self.rkey2) {
            m.insert("lkey2".to_string(), arr1(a));
            m.insert("rkey2".to_string(), arr1(b));
        }
        m
    }

    fn doc(&self, gate: Gate) -> Value {
        let composite = self.lkey2.is_some();
        let mut vars = serde_json::Map::new();
        for (name, set) in [
            ("lkey", "lrows"),
            ("activity", "lrows"),
            ("rkey", "rrows"),
            ("rate", "rrows"),
        ] {
            vars.insert(name.into(), json!({"type": "parameter", "shape": [set]}));
        }
        if composite {
            vars.insert(
                "lkey2".into(),
                json!({"type": "parameter", "shape": ["lrows"]}),
            );
            vars.insert(
                "rkey2".into(),
                json!({"type": "parameter", "shape": ["rrows"]}),
            );
        }
        vars.insert("E".into(), json!({"type": "unknown", "shape": ["lrows"]}));

        let mut node = json!({
            "op": "aggregate",
            "reduce": "+",
            "output_idx": ["l"],
            "ranges": {"l": {"from": "lrows"}, "r": {"from": "rrows"}},
            "args": ["lkey", "rkey", "activity", "rate"],
            "expr": {"op": "*", "args": [ix("activity", "l"), ix("rate", "r")]}
        });
        let obj = node.as_object_mut().unwrap();
        match gate {
            Gate::On => {
                let mut on = vec![json!(["lkey", "rkey"])];
                if composite {
                    on.push(json!(["lkey2", "rkey2"]));
                }
                obj.insert("join".into(), json!([{"on": on}]));
            }
            Gate::Filter => {
                let pred = if composite {
                    json!({"op": "and", "args": [
                        eq_filter("lkey", "l", "rkey", "r"),
                        eq_filter("lkey2", "l", "rkey2", "r"),
                    ]})
                } else {
                    eq_filter("lkey", "l", "rkey", "r")
                };
                obj.insert("filter".into(), pred);
            }
        }

        json!({
            "esm": "1.0.0",
            "metadata": {"name": "join_on_equality_gate"},
            "index_sets": {
                "lrows": {"kind": "interval", "size": self.nl()},
                "rrows": {"kind": "interval", "size": self.nr()}
            },
            "models": {"J": {
                "variables": Value::Object(vars),
                "equations": [{"lhs": "E", "rhs": node}]
            }}
        })
    }
}

/// Materialize `E` for one arm, returning `(values, gate-driven leaf visits)`.
fn run(t: &Tables, gate: Gate) -> (Vec<f64>, u64) {
    let doc = t.doc(gate);
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

/// Both arms + the oracle, asserted bit-identical. Returns the gated arm's
/// visit count so a caller can additionally pin the COST.
fn assert_gate_matches_filter(t: &Tables, what: &str) -> u64 {
    let (gated, visits) = run(t, Gate::On);
    let (filtered, filter_visits) = run(t, Gate::Filter);
    let oracle = t.oracle();

    assert_eq!(
        filter_visits, 0,
        "{what}: the un-gated arm must not run the gate-driven unroll \
         (it is the differential baseline)"
    );
    assert_eq!(gated.len(), t.nl(), "{what}: wrong output length");
    for l in 0..t.nl() {
        assert_eq!(
            gated[l].to_bits(),
            filtered[l].to_bits(),
            "{what}: E[{l}] differs between the gate ({}) and the hand-written \
             filter ({}) it lowers to",
            gated[l],
            filtered[l]
        );
        assert_eq!(
            gated[l].to_bits(),
            oracle[l].to_bits(),
            "{what}: E[{l}] = {} but the oracle says {}",
            gated[l],
            oracle[l]
        );
    }
    visits
}

// ---------------------------------------------------------------------------
// Differential correctness
// ---------------------------------------------------------------------------

#[test]
fn many_to_many_data_column_join_matches_the_hand_written_filter() {
    // Key 7 appears 3x left and 2x right => all 3·2 = 6 combined terms exist
    // (the DEFINED many-to-many cardinality of §5.3, not an error to guard
    // against); key 9 is 2x1; key 4 is 1x1.
    let t = Tables::simple(vec![7.0, 9.0, 4.0, 7.0, 9.0, 7.0], vec![7.0, 4.0, 9.0, 7.0]);
    assert_eq!(
        t.match_count(),
        3 * 2 + 2 + 1,
        "the m2m fixture is 3·2 (key 7) + 2·1 (key 9) + 1·1 (key 4)"
    );
    let visits = assert_gate_matches_filter(&t, "many-to-many");
    assert_eq!(
        visits,
        t.match_count(),
        "the driven walk visits exactly the matched pairs"
    );
}

#[test]
fn composite_key_join_requires_every_listed_pair_to_agree() {
    // Two key columns. `(7,1)` matches only `(7,1)`: the rows that agree on the
    // FIRST column but not the second must contribute nothing, which is what
    // separates a composite key from two independent gates.
    let t = Tables {
        lkey: vec![7.0, 7.0, 9.0, 9.0],
        lkey2: Some(vec![1.0, 2.0, 1.0, 3.0]),
        rkey: vec![7.0, 7.0, 9.0],
        rkey2: Some(vec![1.0, 5.0, 1.0]),
        activity: vec![1.0, 2.0, 3.0, 4.0],
        rate: vec![10.0, 20.0, 30.0],
    };
    // (l0,r0) on (7,1) and (l2,r2) on (9,1) — 2 of the 12 tuples.
    assert_eq!(t.match_count(), 2);
    let visits = assert_gate_matches_filter(&t, "composite key");
    assert_eq!(
        visits, 2,
        "a composite key matches on the TUPLE, not per column"
    );
}

#[test]
fn unmatched_rows_contribute_the_additive_identity() {
    // Left rows 1 and 3 carry keys no right row has: their output must be
    // exactly 0̄ — the empty-⊕-reduction identity — not NaN and not a hole.
    let t = Tables::simple(vec![7.0, 100.0, 9.0, 101.0], vec![7.0, 9.0, 9.0]);
    let visits = assert_gate_matches_filter(&t, "unmatched rows");
    let (gated, _) = run(&t, Gate::On);
    assert_eq!(gated[1].to_bits(), 0.0f64.to_bits(), "unmatched row is +0");
    assert_eq!(gated[3].to_bits(), 0.0f64.to_bits(), "unmatched row is +0");
    assert_eq!(visits, t.match_count());
}

#[test]
fn empty_match_set_yields_the_identity_everywhere_and_visits_nothing() {
    // Disjoint key domains: the match set is empty, so the driver visits no
    // leaf at all and every output position takes the semiring identity.
    let t = Tables::simple(vec![1.0, 2.0, 3.0], vec![50.0, 51.0]);
    assert_eq!(t.match_count(), 0);
    let (gated, visits) = run(&t, Gate::On);
    let (filtered, _) = run(&t, Gate::Filter);
    for l in 0..t.nl() {
        assert_eq!(gated[l].to_bits(), 0.0f64.to_bits(), "E[{l}] is not 0̄");
        assert_eq!(gated[l].to_bits(), filtered[l].to_bits());
    }
    assert_eq!(
        visits, 0,
        "an empty match set drives no leaf (identity fill, §5.5.6)"
    );
}

#[test]
fn key_order_within_a_column_does_not_change_the_result() {
    // Determinism (§5.5 rule 5): the match set is a pure function of the input
    // MULTISET, so permuting the right table permutes nothing observable in a
    // ⊕-reduction over it.
    let a = Tables::simple(vec![7.0, 9.0, 7.0], vec![7.0, 9.0, 7.0, 9.0]);
    let b = Tables {
        rkey: vec![9.0, 7.0, 9.0, 7.0],
        rate: vec![20.0, 10.0, 40.0, 30.0],
        ..Tables::simple(vec![7.0, 9.0, 7.0], vec![7.0, 9.0, 7.0, 9.0])
    };
    let (ga, _) = run(&a, Gate::On);
    let (gb, _) = run(&b, Gate::On);
    for l in 0..3 {
        assert!(
            (ga[l] - gb[l]).abs() < 1e-12,
            "permuting the right table moved E[{l}]: {} vs {}",
            ga[l],
            gb[l]
        );
    }
}

// ---------------------------------------------------------------------------
// Cost — the property the gate exists for
// ---------------------------------------------------------------------------

/// A synthetic MOVES-shaped pair of tables: `nl` source rows and `nr` factor
/// rows over `nkeys` distinct IDs, so the full product is `nl·nr` while the
/// match set is only `(nl/nkeys)·(nr/nkeys)·nkeys = nl·nr/nkeys`.
fn keyed_tables(nl: usize, nr: usize, nkeys: usize) -> Tables {
    let lkey = (0..nl).map(|i| (i % nkeys) as f64 + 1.0).collect();
    let rkey = (0..nr).map(|j| (j % nkeys) as f64 + 1.0).collect();
    Tables::simple(lkey, rkey)
}

#[test]
fn work_tracks_the_match_count_not_the_index_set_product() {
    // The load-bearing scaling property, stated so that only the driver can
    // satisfy it: the MATCH COUNT is held FIXED at 200 while the index-set
    // product grows 10x (200x200 -> 200x2000). Driven work must not move.
    //
    // If the gate ever stops driving — a regression, or a silent fallback to
    // the `filter` path — the visits either follow the product (10x here) or
    // drop to 0 (the ungated `reduce_contraction`, which never bumps the
    // counter). Both fail.
    let small = keyed_tables(200, 200, 200); // product 40 000
    let large = keyed_tables(200, 2000, 2000); // product 400 000
    assert_eq!(small.match_count(), 200, "one match per left row");
    assert_eq!(
        large.match_count(),
        200,
        "same match count, 10x the product"
    );

    let (_, v_small) = run(&small, Gate::On);
    let (_, v_large) = run(&large, Gate::On);

    assert!(
        v_small > 0,
        "visits of 0 means the gate declined and never drove"
    );
    assert_eq!(v_small, small.match_count(), "small arm is match-driven");
    assert_eq!(
        v_large,
        large.match_count(),
        "10x the product must not cost 10x the work"
    );
    assert_eq!(v_small, v_large, "work tracks matches, not the product");

    let product_large = (large.nl() * large.nr()) as u64;
    assert!(
        v_large * 100 < product_large,
        "{v_large} visits is not a cut against the {product_large} product"
    );
}

/// The complementary direction: hold the PRODUCT fixed and grow the matches.
/// Work must then grow — a driver that had merely gone constant (say by
/// dropping terms) would be caught here and not by the test above.
#[test]
fn work_grows_with_the_matches_when_the_product_is_held_fixed() {
    let sparse = keyed_tables(200, 400, 400); // 200 matches
    let dense = keyed_tables(200, 400, 40); // 40 keys: 5 left x 10 right x 40
    assert_eq!(sparse.match_count(), 200);
    assert_eq!(dense.match_count(), 2000);
    assert_eq!(sparse.nl() * sparse.nr(), dense.nl() * dense.nr());

    let (_, v_sparse) = run(&sparse, Gate::On);
    let (_, v_dense) = run(&dense, Gate::On);
    assert_eq!(v_sparse, 200);
    assert_eq!(v_dense, 2000);
}

#[test]
fn a_single_shared_key_is_the_dense_worst_case_and_still_matches() {
    // Every row shares one key ⇒ the match set IS the full product. The driver
    // must not be faster here — it must simply be CORRECT, and must not
    // double-count: exactly nl·nr terms, each once.
    let t = keyed_tables(30, 20, 1);
    assert_eq!(t.match_count(), 600);
    let visits = assert_gate_matches_filter(&t, "single shared key");
    assert_eq!(visits, 600, "the dense case visits the whole product, once");
}

// ---------------------------------------------------------------------------
// The other two spellings a key column may take
// ---------------------------------------------------------------------------

/// An `on` key naming a LOOP SYMBOL (or the index set it draws from) rather than
/// a data column: the key values are the set's declared members, known at build
/// time. Categorical STRING members are the case that cannot be compared by a
/// numeric evaluator at all, so they exercise the dense value-coding path — and
/// the gate must reach the same many-to-many answer over them.
#[test]
fn categorical_member_key_columns_join_many_to_many() {
    // "coal" is 2x left and 2x right => 4 terms; "oil"/"gas" match nothing.
    let lmem = ["coal", "coal", "oil"];
    let rmem = ["coal", "coal", "gas"];
    let activity = [1.0, 2.0, 3.0];
    let rate = [10.0, 20.0, 30.0];

    let doc = json!({
        "esm": "1.0.0",
        "metadata": {"name": "join_on_categorical_members"},
        "index_sets": {
            "lrows": {"kind": "categorical", "members": lmem},
            "rrows": {"kind": "categorical", "members": rmem}
        },
        "models": {"J": {
            "variables": {
                "activity": {"type": "parameter", "shape": ["lrows"]},
                "rate": {"type": "parameter", "shape": ["rrows"]},
                "E": {"type": "unknown", "shape": ["lrows"]}
            },
            "equations": [{"lhs": "E", "rhs": {
                "op": "aggregate",
                "reduce": "+",
                "output_idx": ["l"],
                "ranges": {"l": {"from": "lrows"}, "r": {"from": "rrows"}},
                "join": [{"on": [["l", "r"]]}],
                "args": ["activity", "rate"],
                "expr": {"op": "*", "args": [ix("activity", "l"), ix("rate", "r")]}
            }}]
        }}
    });

    reset_overlap_enum_visits();
    let prep = esm_problem(
        &doc,
        (0.0, 0.0),
        ProblemOptions {
            model_name: Some("J".into()),
            const_arrays: [
                ("activity".to_string(), arr1(&activity)),
                ("rate".to_string(), arr1(&rate)),
            ]
            .into_iter()
            .collect(),
            build_providers: Vec::new(),
            ..Default::default()
        },
    )
    .expect("prepare");
    let visits = overlap_enum_visits();
    let got = observed_field(&prep, "E").expect("E materialized");

    for l in 0..3 {
        let want: f64 = (0..3)
            .filter(|&r| lmem[l] == rmem[r])
            .map(|r| activity[l] * rate[r])
            .sum();
        // Value equality, not bit equality: Rust's `Iterator::sum` folds an
        // empty sequence to `-0.0` while the engine's empty ⊕-reduction is the
        // semiring identity `+0.0` (§5.6). The two ARE equal as numbers; only
        // the oracle's spelling of zero differs.
        assert_eq!(
            got[l], want,
            "E[{l}] = {} but the oracle says {want}",
            got[l]
        );
    }
    assert_eq!(visits, 4, "coal 2x2; oil and gas match nothing");
}

/// Both gated symbols CONTRACTED — §5.5.6's PAIRS binding case, reached by an
/// aggregate whose output index is some third (ungated) axis. The gate binds
/// both symbols at once from the sorted candidate pairs.
#[test]
fn scalar_reduction_drives_both_contracted_symbols_from_the_pairs() {
    let t = Tables::simple(vec![7.0, 9.0, 7.0, 4.0], vec![7.0, 4.0, 9.0, 7.0]);
    // T[q] = Σ_{l,r : keys equal} activity[l]·rate[r], q over a singleton axis.
    let mut vars = serde_json::Map::new();
    for (name, set) in [
        ("lkey", "lrows"),
        ("activity", "lrows"),
        ("rkey", "rrows"),
        ("rate", "rrows"),
    ] {
        vars.insert(name.into(), json!({"type": "parameter", "shape": [set]}));
    }
    vars.insert("T".into(), json!({"type": "unknown", "shape": ["one"]}));
    let make = |gated: bool| {
        let mut node = json!({
            "op": "aggregate",
            "reduce": "+",
            "output_idx": ["q"],
            "ranges": {"q": {"from": "one"}, "l": {"from": "lrows"}, "r": {"from": "rrows"}},
            "args": ["lkey", "rkey", "activity", "rate"],
            "expr": {"op": "*", "args": [ix("activity", "l"), ix("rate", "r")]}
        });
        let obj = node.as_object_mut().unwrap();
        if gated {
            obj.insert("join".into(), json!([{"on": [["lkey", "rkey"]]}]));
        } else {
            obj.insert("filter".into(), eq_filter("lkey", "l", "rkey", "r"));
        }
        json!({
            "esm": "1.0.0",
            "metadata": {"name": "join_on_pairs_drive"},
            "index_sets": {
                "one": {"kind": "interval", "size": 1},
                "lrows": {"kind": "interval", "size": t.nl()},
                "rrows": {"kind": "interval", "size": t.nr()}
            },
            "models": {"J": {
                "variables": Value::Object(vars.clone()),
                "equations": [{"lhs": "T", "rhs": node}]
            }}
        })
    };
    let go = |gated: bool| -> (f64, u64) {
        reset_overlap_enum_visits();
        let prep = esm_problem(
            &make(gated),
            (0.0, 0.0),
            ProblemOptions {
                model_name: Some("J".into()),
                const_arrays: t.const_arrays(),
                build_providers: Vec::new(),
                ..Default::default()
            },
        )
        .expect("prepare");
        let v = overlap_enum_visits();
        (observed_field(&prep, "T").expect("T materialized")[0], v)
    };

    let (gated, visits) = go(true);
    let (filtered, base_visits) = go(false);
    let oracle: f64 = t.oracle().iter().sum();

    assert_eq!(base_visits, 0, "the baseline arm must not drive");
    assert_eq!(
        gated.to_bits(),
        filtered.to_bits(),
        "PAIRS drive moved the total: {gated} vs {filtered}"
    );
    assert!(
        (gated - oracle).abs() < 1e-9,
        "total {gated} != oracle {oracle}"
    );
    assert_eq!(
        visits,
        t.match_count(),
        "both symbols bound from the candidate pairs"
    );
}

// ---------------------------------------------------------------------------
// The driver is a pure optimisation — proved on the SAME document
// ---------------------------------------------------------------------------

/// The sharpest form of the differential: one document, one build, evaluated
/// with the driver ON and with it OFF (`ESS_JOIN_GATE_DISABLE` /
/// `set_join_gate_enabled`). With the gate off, the aggregate walks the
/// untouched full product and the lowered equality `filter` decides — the
/// pre-driver path exactly. The two must give BIT-identical numbers, because
/// the driven walk emits the order-preserving subsequence of the terms the
/// filtered product emitted, not a re-associated sum of them.
#[test]
fn driving_is_bit_identical_to_the_undriven_full_product() {
    let cases = [
        Tables::simple(vec![7.0, 9.0, 4.0, 7.0, 9.0, 7.0], vec![7.0, 4.0, 9.0, 7.0]),
        Tables::simple(vec![1.0, 2.0, 3.0], vec![50.0, 51.0]), // no matches
        keyed_tables(40, 60, 7),                               // dense m2m
        keyed_tables(40, 60, 60),                              // sparse
        Tables {
            lkey: vec![7.0, 7.0, 9.0, 9.0],
            lkey2: Some(vec![1.0, 2.0, 1.0, 3.0]),
            rkey: vec![7.0, 7.0, 9.0],
            rkey2: Some(vec![1.0, 5.0, 1.0]),
            activity: vec![1.5, 2.25, 3.125, 4.0625],
            rate: vec![10.5, 20.25, 30.125],
        }, // composite key, non-dyadic values so re-association would show
    ];
    for (i, t) in cases.iter().enumerate() {
        let prev = set_join_gate_enabled(false);
        let (undriven, undriven_visits) = run(t, Gate::On);
        set_join_gate_enabled(true);
        let (driven, driven_visits) = run(t, Gate::On);
        set_join_gate_enabled(prev);

        assert_eq!(
            undriven_visits, 0,
            "case {i}: the kill-switch arm must not drive"
        );
        assert_eq!(
            driven_visits,
            t.match_count(),
            "case {i}: the driven arm must visit exactly the matches"
        );
        for l in 0..t.nl() {
            assert_eq!(
                driven[l].to_bits(),
                undriven[l].to_bits(),
                "case {i}: E[{l}] moved when the gate drove: {} vs {}",
                driven[l],
                undriven[l]
            );
        }
    }
}

/// Both gated symbols contracted ALONGSIDE a third contracted axis — the shape
/// the pair list cannot bind on its own, and the one a MOVES rollup reaches as
/// soon as it also sums over, say, months. The later gated axis iterates only
/// its partner list, so the walk still drops the whole `N_r` factor; and it must
/// stay bit-identical to the same document with the driver off.
#[test]
fn extra_contracted_axis_still_drives_the_later_gated_symbol() {
    let t = keyed_tables(20, 40, 10); // 20·(40/10) = 80 matches of 800 tuples
    const NM: usize = 3; // the extra ungated contracted axis
    assert_eq!(t.match_count(), 80);

    let mut vars = serde_json::Map::new();
    for (name, set) in [
        ("lkey", "lrows"),
        ("activity", "lrows"),
        ("rkey", "rrows"),
        ("rate", "rrows"),
    ] {
        vars.insert(name.into(), json!({"type": "parameter", "shape": [set]}));
    }
    vars.insert("T".into(), json!({"type": "unknown", "shape": ["one"]}));
    // T[q] = Σ_{l, m, r : keys equal} activity[l]·rate[r]·m  — `m` is ungated,
    // and the contracted names sort to [l, m, r], so the two gated dims are NOT
    // adjacent and the later one (r) is the restricted axis.
    let node = json!({
        "op": "aggregate",
        "reduce": "+",
        "output_idx": ["q"],
        "ranges": {
            "q": {"from": "one"}, "l": {"from": "lrows"},
            "m": {"from": "months"}, "r": {"from": "rrows"}
        },
        "join": [{"on": [["lkey", "rkey"]]}],
        "args": ["lkey", "rkey", "activity", "rate"],
        "expr": {"op": "*", "args": [ix("activity", "l"), ix("rate", "r"), "m"]}
    });
    let doc = json!({
        "esm": "1.0.0",
        "metadata": {"name": "join_on_extra_axis"},
        "index_sets": {
            "one": {"kind": "interval", "size": 1},
            "months": {"kind": "interval", "size": NM},
            "lrows": {"kind": "interval", "size": t.nl()},
            "rrows": {"kind": "interval", "size": t.nr()}
        },
        "models": {"J": {
            "variables": Value::Object(vars),
            "equations": [{"lhs": "T", "rhs": node}]
        }}
    });
    let go = |gate_on: bool| -> (f64, u64) {
        let prev = set_join_gate_enabled(gate_on);
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
        let v = overlap_enum_visits();
        set_join_gate_enabled(prev);
        (observed_field(&prep, "T").expect("T materialized")[0], v)
    };
    let (driven, visits) = go(true);
    let (undriven, undriven_visits) = go(false);

    assert_eq!(undriven_visits, 0, "the kill-switch arm must not drive");
    assert_eq!(
        driven.to_bits(),
        undriven.to_bits(),
        "an extra contracted axis moved the total: {driven} vs {undriven}"
    );
    let oracle: f64 = t.oracle().iter().sum::<f64>() * (1..=NM as i64).sum::<i64>() as f64;
    assert!(
        (driven - oracle).abs() < 1e-9,
        "total {driven} != oracle {oracle}"
    );
    // Leaves visited = matches x |months|; the interior sweep costs N_l x |months|
    // on top, but the whole N_r factor is gone.
    assert_eq!(
        visits,
        t.match_count() * NM as u64,
        "the later gated axis must walk only its partner list"
    );
}
