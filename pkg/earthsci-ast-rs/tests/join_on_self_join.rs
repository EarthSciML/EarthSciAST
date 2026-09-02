//! A relation joined to ITSELF: two `aggregate` ranges over ONE index set
//! (CONFORMANCE_SPEC.md §5.5.8 "Two ranges over one index set").
//!
//! Two ranges over one index set is already the documented spelling of a prefix
//! reduction (esm-spec §4.3.1, `filter: j <= i`). What could not be spelled was
//! the same shape with a value-equality GATE instead of an inequality filter:
//! `join.on` resolved a key column to a loop symbol through the column's AXIS,
//! and an axis drawn by two range symbols named neither, so the left key was
//! rejected outright. The resolution now assigns the two sides — by canonical
//! range order for the two-candidate case, and by the clause's own `syms` for
//! everything else.
//!
//! Everything here asserts a SPECIFIC value and a SPECIFIC row count. A
//! self-join is exactly the construct where a wrong side assignment yields a
//! plausible number — the NEXT row's value instead of the PREVIOUS row's — so
//! "it ran" and "the shape is right" prove nothing. Each expectation below is
//! also computed independently in [`prior_oracle`] / [`back_oracle`].
//!
//! The cost claim is asserted the same way `join_on_equality_gate.rs` asserts
//! it: `overlap_enum_visits` is bumped only on the gate-DRIVEN unroll, so a
//! visit count of 0 means the gate declined (and the lowered `filter` walked the
//! full product), and a count near `N²` means it stopped driving.

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

/// One table of `n` rows: `row_id[i] = i`, `row_prior[i] = i − 1`,
/// `row_back[i] = i − `[`BACK`], and a payload `payload[i]`.
///
/// The offsets are ORDINARY KEY COLUMNS, not a format feature: the join learns
/// nothing about "previous" — it equi-joins two columns that happen to be
/// shifted copies of each other, which is what makes the construct general.
const BACK: i64 = 3;

struct Table {
    n: usize,
    payload: Vec<f64>,
}

impl Table {
    fn new(n: usize) -> Table {
        Table {
            n,
            // Distinct powers-ish payload so a wrong pairing cannot coincide
            // with the right one: consecutive values never repeat a sum.
            payload: (0..n).map(|i| (i as f64 + 1.0) * 7.0 - 3.0).collect(),
        }
    }

    fn row_id(&self) -> Vec<f64> {
        (1..=self.n).map(|i| i as f64).collect()
    }
    fn shifted(&self, by: i64) -> Vec<f64> {
        (1..=self.n).map(|i| (i as i64 - by) as f64).collect()
    }

    fn const_arrays(&self) -> HashMap<String, ArrayD<f64>> {
        [
            ("row_id".to_string(), arr1(&self.row_id())),
            ("row_prior".to_string(), arr1(&self.shifted(1))),
            ("row_back".to_string(), arr1(&self.shifted(BACK))),
            ("payload".to_string(), arr1(&self.payload)),
        ]
        .into_iter()
        .collect()
    }

    /// `out[a] = payload[a − 1]`, and `0̄` for the first row, which has no
    /// predecessor — the inner join's unmatched-row rule (§5.3), not a hole.
    fn prior_oracle(&self) -> Vec<f64> {
        (0..self.n)
            .map(|a| if a == 0 { 0.0 } else { self.payload[a - 1] })
            .collect()
    }

    /// `out[a] = payload[a − BACK]`, `0̄` for the first `BACK` rows.
    fn back_oracle(&self) -> Vec<f64> {
        (0..self.n)
            .map(|a| {
                let src = a as i64 - BACK;
                if src < 0 {
                    0.0
                } else {
                    self.payload[src as usize]
                }
            })
            .collect()
    }

    /// `out[a] = payload[a + 1]`, `0̄` for the last row — what the TRANSPOSED
    /// side assignment computes, and the specific wrong answer the default rule
    /// must not produce.
    fn next_oracle(&self) -> Vec<f64> {
        (0..self.n)
            .map(|a| {
                if a + 1 >= self.n {
                    0.0
                } else {
                    self.payload[a + 1]
                }
            })
            .collect()
    }

    /// How many `(a, b)` pairs the gate admits for a `by`-row lookback.
    fn match_count(&self, by: i64) -> u64 {
        (self.n as i64 - by).max(0) as u64
    }
}

/// How the self-join is spelled.
#[derive(Clone, Copy)]
enum Spelling {
    /// `join.on` with NO `syms`: the default side assignment.
    Default,
    /// `join.syms` naming the two range symbols, in the given order.
    Syms(&'static str, &'static str),
    /// The hand-written equality `filter` the clause lowers to, with no `join`
    /// clause at all — the pre-gate path, and the differential oracle.
    Filter(&'static str, &'static str),
}

/// One self-join document: `out[a] = Σ_b payload[b]` over the pairs where
/// `<key_col>[a] == row_id[b]`.
///
/// `a` and `b` BOTH draw the one index set `rows`. That is the whole point: the
/// two sides of the join are two ranges over one relation.
fn doc(t: &Table, key_col: &str, spelling: Spelling) -> Value {
    let mut node = json!({
        "op": "aggregate",
        "semiring": "sum_product",
        "reduce": "+",
        "output_idx": ["a"],
        "ranges": {"a": {"from": "rows"}, "b": {"from": "rows"}},
        "args": ["row_id", "row_prior", "row_back", "payload"],
        "expr": ix("payload", "b")
    });
    let obj = node.as_object_mut().unwrap();
    match spelling {
        Spelling::Default => {
            obj.insert("join".into(), json!([{"on": [[key_col, "row_id"]]}]));
        }
        Spelling::Syms(l, r) => {
            obj.insert(
                "join".into(),
                json!([{"on": [[key_col, "row_id"]], "syms": [l, r]}]),
            );
        }
        Spelling::Filter(lsym, rsym) => {
            obj.insert(
                "filter".into(),
                json!({"op": "==", "args": [ix(key_col, lsym), ix("row_id", rsym)]}),
            );
        }
    }
    json!({
        "esm": "1.1.0",
        "metadata": {"name": "self_join"},
        "index_sets": {"rows": {"kind": "interval", "size": t.n}},
        "models": {"S": {
            "variables": {
                "row_id":    {"type": "parameter", "shape": ["rows"]},
                "row_prior": {"type": "parameter", "shape": ["rows"]},
                "row_back":  {"type": "parameter", "shape": ["rows"]},
                "payload":   {"type": "parameter", "shape": ["rows"]},
                "out":       {"type": "unknown",   "shape": ["rows"]}
            },
            "equations": [{"lhs": "out", "rhs": node}]
        }}
    })
}

/// Build one document and return `(out, driven leaf visits)`.
fn run(t: &Table, key_col: &str, spelling: Spelling, gate: bool) -> (Vec<f64>, u64) {
    let d = doc(t, key_col, spelling);
    let prev = set_join_gate_enabled(gate);
    reset_overlap_enum_visits();
    let prep = esm_problem(
        &d,
        (0.0, 0.0),
        ProblemOptions {
            model_name: Some("S".into()),
            const_arrays: t.const_arrays(),
            build_providers: Vec::new(),
            ..Default::default()
        },
    );
    let visits = overlap_enum_visits();
    set_join_gate_enabled(prev);
    let prep = prep.expect("a self-join must build");
    let out = observed_field(&prep, "out").expect("out is materialized");
    (out.iter().copied().collect(), visits)
}

/// The build error a document is refused with, or a panic naming what it
/// produced instead.
fn build_err(d: &Value, n: usize) -> String {
    let t = Table::new(n);
    match esm_problem(
        d,
        (0.0, 0.0),
        ProblemOptions {
            model_name: Some("S".into()),
            const_arrays: t.const_arrays(),
            build_providers: Vec::new(),
            ..Default::default()
        },
    ) {
        Ok(_) => panic!("expected a build error, but the document built"),
        Err(e) => e.to_string(),
    }
}

fn bits(v: &[f64]) -> Vec<u64> {
    v.iter().map(|x| x.to_bits()).collect()
}

// ---------------------------------------------------------------------------
// The value, and the specific wrong value it must not be
// ---------------------------------------------------------------------------

#[test]
fn the_default_side_assignment_reads_the_previous_row() {
    // The F11 shape at every row: `out[a]` is the payload of row `a−1`, and row
    // 1 reads the additive identity because the inner join drops it.
    let t = Table::new(9);
    let (out, visits) = run(&t, "row_prior", Spelling::Default, true);

    assert_eq!(out.len(), 9, "one output row per table row");
    assert_eq!(
        bits(&out),
        bits(&t.prior_oracle()),
        "expected {:?}, got {out:?}",
        t.prior_oracle()
    );
    // Named explicitly, because these ARE the numbers: payload[i] = 7i+4.
    assert_eq!(out[0], 0.0, "row 1 has no predecessor: 0-bar, not a hole");
    assert_eq!(out[1], 4.0, "row 2 reads payload[1] = 4");
    assert_eq!(out[8], 53.0, "row 9 reads payload[7] = 53");

    // …and NOT the transposed reading, which would have been just as plausible.
    assert_ne!(
        bits(&out),
        bits(&t.next_oracle()),
        "the default assignment must read the PREVIOUS row, not the next"
    );
    assert_eq!(
        visits,
        t.match_count(1),
        "the gate drove exactly the 8 matched pairs"
    );
}

#[test]
fn a_bounded_lookback_is_just_another_key_column() {
    // The three-second-lookback half of the downstream need, spelled with no new
    // feature: a second shifted key column, same clause shape.
    let t = Table::new(9);
    let (out, visits) = run(&t, "row_back", Spelling::Default, true);

    assert_eq!(out.len(), 9);
    assert_eq!(bits(&out), bits(&t.back_oracle()), "got {out:?}");
    assert_eq!(&out[0..3], &[0.0, 0.0, 0.0], "the first 3 rows are unmatched");
    assert_eq!(out[3], 4.0, "row 4 reads payload[1] = 4");
    assert_eq!(out[8], 39.0, "row 9 reads payload[6] = 39");
    assert_eq!(visits, t.match_count(BACK), "6 matched pairs, 6 visits");
}

#[test]
fn explicit_syms_choose_the_orientation() {
    let t = Table::new(9);
    // `syms: [a, b]` restates the default and must not change the answer.
    let (same, _) = run(&t, "row_prior", Spelling::Syms("a", "b"), true);
    assert_eq!(bits(&same), bits(&t.prior_oracle()));

    // `syms: [b, a]` reads the key at the CONTRACTED symbol instead: the row
    // whose predecessor is `a`, i.e. the NEXT row. A different, specific answer
    // — which is the proof `syms` is consulted rather than ignored.
    let (flipped, visits) = run(&t, "row_prior", Spelling::Syms("b", "a"), true);
    assert_eq!(bits(&flipped), bits(&t.next_oracle()), "got {flipped:?}");
    assert_eq!(flipped[0], 11.0, "row 1 reads payload[2] = 11");
    assert_eq!(flipped[8], 0.0, "row 9 has no successor");
    assert_eq!(visits, t.match_count(1));
}

// ---------------------------------------------------------------------------
// Differential correctness: the gate against the filter, and driven against not
// ---------------------------------------------------------------------------

#[test]
fn the_gate_agrees_bit_for_bit_with_the_hand_written_filter() {
    let t = Table::new(40);
    let (gated, gated_visits) = run(&t, "row_prior", Spelling::Default, true);
    // The pre-gate spelling of the identical semantics, with the sides written
    // out by hand: `row_prior[a] == row_id[b]`.
    let (filtered, _) = run(&t, "row_prior", Spelling::Filter("a", "b"), true);

    assert_eq!(gated.len(), 40);
    assert_eq!(
        bits(&gated),
        bits(&filtered),
        "the gate must not merely agree to a tolerance with the filter it lowers to"
    );
    assert_eq!(bits(&gated), bits(&t.prior_oracle()));
    assert_eq!(gated_visits, 39);
}

#[test]
fn driving_is_bit_identical_to_the_undriven_full_product() {
    // The driver changes the enumeration EXTENT, never an answer. Same document,
    // same data, gate killed — which makes the lowered equality `filter` decide
    // the full 40x40 product instead.
    let t = Table::new(40);
    let (driven, driven_visits) = run(&t, "row_prior", Spelling::Default, true);
    let (undriven, _) = run(&t, "row_prior", Spelling::Default, false);

    assert_eq!(bits(&driven), bits(&undriven), "driving changed an answer");
    assert_eq!(bits(&driven), bits(&t.prior_oracle()));
    assert_eq!(driven_visits, 39, "driven work is the match count");
}

// ---------------------------------------------------------------------------
// Cost — the reason the default rule had to keep the gate, not just the filter
// ---------------------------------------------------------------------------

#[test]
fn work_tracks_the_match_count_not_the_squared_row_count() {
    // A self-join's product is N², and its match set is N − 1: the ratio grows
    // without bound, so this is where a fallback shows up first. Hold nothing
    // fixed but the shape and grow N by 10x — driven work must grow 10x (with
    // the matches), not 100x (with the product).
    let small = Table::new(50);
    let large = Table::new(500);

    let (out_small, v_small) = run(&small, "row_prior", Spelling::Default, true);
    let (out_large, v_large) = run(&large, "row_prior", Spelling::Default, true);
    assert_eq!(bits(&out_small), bits(&small.prior_oracle()));
    assert_eq!(bits(&out_large), bits(&large.prior_oracle()));

    assert!(
        v_small > 0,
        "0 visits means the gate declined and the filter walked the product"
    );
    assert_eq!(v_small, 49, "N − 1 matched pairs at N = 50");
    assert_eq!(v_large, 499, "N − 1 matched pairs at N = 500");

    let product = (large.n * large.n) as u64; // 250 000
    assert!(
        v_large * 100 < product,
        "{v_large} visits is not a cut against the {product} product"
    );
}

// ---------------------------------------------------------------------------
// The refusals: what the format cannot determine, it must not guess
// ---------------------------------------------------------------------------

#[test]
fn three_ranges_over_one_index_set_are_refused_by_name() {
    // With three candidates there is no grounded pairing, and taking two of the
    // three would be a guess that reads as a number rather than as a failure.
    let t = Table::new(6);
    let mut d = doc(&t, "row_prior", Spelling::Default);
    d["models"]["S"]["equations"][0]["rhs"]["ranges"]["c"] = json!({"from": "rows"});
    let msg = build_err(&d, 6);
    assert!(
        msg.contains("drawn by 3 range symbols") && msg.contains("join.syms"),
        "the refusal must name the ambiguity and the spelling that fixes it: {msg}"
    );
    assert!(msg.contains("\"a\"") && msg.contains("\"b\"") && msg.contains("\"c\""));
}

#[test]
fn three_ranges_are_spellable_with_explicit_syms() {
    // …and once the two sides are named, the third range is an ordinary ungated
    // axis: the gated pair is unchanged and the answer is multiplied by its
    // extent, `n`, exactly as the join-free reduction would be.
    let t = Table::new(6);
    let mut d = doc(&t, "row_prior", Spelling::Syms("a", "b"));
    d["models"]["S"]["equations"][0]["rhs"]["ranges"]["c"] = json!({"from": "rows"});
    let prev = set_join_gate_enabled(true);
    let prep = esm_problem(
        &d,
        (0.0, 0.0),
        ProblemOptions {
            model_name: Some("S".into()),
            const_arrays: t.const_arrays(),
            build_providers: Vec::new(),
            ..Default::default()
        },
    )
    .expect("explicit syms resolve a three-candidate axis");
    set_join_gate_enabled(prev);
    let out: Vec<f64> = observed_field(&prep, "out").unwrap().iter().copied().collect();
    let want: Vec<f64> = t.prior_oracle().iter().map(|v| v * t.n as f64).collect();
    assert_eq!(out.len(), 6);
    assert_eq!(bits(&out), bits(&want), "got {out:?}, want {want:?}");
    assert_eq!(out[1], 24.0, "payload[0] = 4, times the 6-wide free axis");
}

#[test]
fn syms_naming_a_symbol_the_node_does_not_bind_is_refused() {
    let t = Table::new(5);
    let d = doc(&t, "row_prior", Spelling::Syms("a", "zzz"));
    let msg = build_err(&d, 5);
    assert!(
        msg.contains("'zzz'") && msg.contains("join.syms"),
        "got {msg}"
    );
}

#[test]
fn syms_contradicting_a_key_that_names_its_own_range_symbol_is_refused() {
    // `on: [["a", "row_id"]]` reads its left key at the range symbol `a` by
    // name. A `syms` putting that side on `b` is a contradiction, not a
    // preference, and resolving it silently either way would be a wrong answer.
    let t = Table::new(5);
    let mut d = doc(&t, "row_prior", Spelling::Syms("b", "a"));
    d["models"]["S"]["equations"][0]["rhs"]["join"][0]["on"] = json!([["a", "row_id"]]);
    let msg = build_err(&d, 5);
    assert!(msg.contains("names a range symbol") && msg.contains("'b'"), "got {msg}");
}
