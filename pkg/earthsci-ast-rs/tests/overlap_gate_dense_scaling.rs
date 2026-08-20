//! DENSE-AGGREGATE scaling under the OVERLAP gate (CONFORMANCE_SPEC.md §5.5.6:
//! the gate drives ANY aggregate, not only a `distinct` producer) — the Rust
//! port of the Julia `test/vi_overlap_scaling_test.jl` "overlap-gated DENSE
//! aggregate scaling (both orientations)" testset.
//!
//! Same geometry in both arms: 20 000 unit cells on a 200x100 grid and 200
//! points, each at a DISTINCT cell centre (strict interior, so exactly one
//! broad-phase candidate, kept by the rectangle narrow `filter`). Two
//! orientations, both of which used to walk the full product and reject every
//! non-candidate tuple with a membership test — or, in Rust, not even test it:
//! the dense evaluator DROPPED the clause as a numerically-inert no-op, which
//! was true of the RESULT and left the COST at `O(N_pts * N_cells)`.
//!
//!   (A) MIRRORED — `P[p] = SUM_c […]` reducing over CELLS. Full product
//!       200 * 20 000 = 4 000 000 pairs.
//!   (B) FORWARD  — the projection-pushdown rewrite's own `E[c] = SUM_r […]`
//!       after `desugar_pushdown` re-points it onto the compact support axis
//!       and gates it on the generated `pd_cell__*` envelopes. Full product
//!       |support| * |records| = 200 * 200.
//!
//! Each asserts the VISIT COUNT (`broad_phase::overlap_enum_visits`, bumped only
//! on the gated dense expansion) and, independently, that the values equal a
//! plain-Rust oracle — the driver must remove work without moving a number.

#![cfg(not(target_arch = "wasm32"))]

use std::collections::HashMap;

use earthsci_ast::broad_phase::{overlap_enum_visits, reset_overlap_enum_visits};
use earthsci_ast::prepare::{PrepareOptions, prepare};
use ndarray::{ArrayD, IxDyn};
use serde_json::{Value, json};

const GX: usize = 200;
const GY: usize = 100;
const NCELLS: usize = GX * GY; // 20 000
const NPTS: usize = 200;

fn arr1(v: &[f64]) -> ArrayD<f64> {
    ArrayD::from_shape_vec(IxDyn(&[v.len()]), v.to_vec()).unwrap()
}

/// Unit cells `k -> (a, b)` with `a = (k-1) / GY`, `b = (k-1) % GY`, and NPTS
/// points at distinct cell centres chosen by a deterministic stride.
struct Geom {
    w: Vec<f64>,
    s: Vec<f64>,
    e: Vec<f64>,
    n: Vec<f64>,
    px: Vec<f64>,
    py: Vec<f64>,
    /// 1-based cell index of each point.
    cell_of: Vec<usize>,
}

fn geometry() -> Geom {
    let (mut w, mut s, mut e, mut n) = (
        vec![0.0; NCELLS],
        vec![0.0; NCELLS],
        vec![0.0; NCELLS],
        vec![0.0; NCELLS],
    );
    let mut ab = vec![(0usize, 0usize); NCELLS];
    for k in 0..NCELLS {
        let a = k / GY;
        let b = k % GY;
        w[k] = a as f64;
        e[k] = a as f64 + 1.0;
        s[k] = b as f64;
        n[k] = b as f64 + 1.0;
        ab[k] = (a, b);
    }
    // A stride coprime with NCELLS gives NPTS distinct cells deterministically.
    let stride = 97usize;
    let mut px = vec![0.0; NPTS];
    let mut py = vec![0.0; NPTS];
    let mut cell_of = vec![0usize; NPTS];
    for p in 0..NPTS {
        let k = (p * stride) % NCELLS;
        let (a, b) = ab[k];
        px[p] = a as f64 + 0.5;
        py[p] = b as f64 + 0.5;
        cell_of[p] = k + 1;
    }
    let mut seen: Vec<usize> = cell_of.clone();
    seen.sort_unstable();
    seen.dedup();
    assert_eq!(seen.len(), NPTS, "the stride must pick distinct cells");
    Geom {
        w,
        s,
        e,
        n,
        px,
        py,
        cell_of,
    }
}

fn ix(f: &str, i: &str) -> Value {
    json!({"op": "index", "args": [f, i]})
}

/// `W[c] <= X[r] < E[c] and S[c] <= Y[r] < N[c]`, as an `and` of comparisons.
fn contains(csym: &str, rsym: &str) -> Value {
    json!({"op": "and", "args": [
        {"op": "<=", "args": [ix("src_W", csym), ix("px", rsym)]},
        {"op": "<",  "args": [ix("px", rsym), ix("src_E", csym)]},
        {"op": "<=", "args": [ix("src_S", csym), ix("py", rsym)]},
        {"op": "<",  "args": [ix("py", rsym), ix("src_N", csym)]},
    ]})
}

fn rect_params(set: &str) -> Vec<(&'static str, Value)> {
    vec![
        ("src_W", json!({"type": "parameter", "shape": [set]})),
        ("src_S", json!({"type": "parameter", "shape": [set]})),
        ("src_E", json!({"type": "parameter", "shape": [set]})),
        ("src_N", json!({"type": "parameter", "shape": [set]})),
    ]
}

fn geom_arrays(g: &Geom) -> HashMap<String, ArrayD<f64>> {
    [
        ("src_W".to_string(), arr1(&g.w)),
        ("src_S".to_string(), arr1(&g.s)),
        ("src_E".to_string(), arr1(&g.e)),
        ("src_N".to_string(), arr1(&g.n)),
        ("px".to_string(), arr1(&g.px)),
        ("py".to_string(), arr1(&g.py)),
    ]
    .into_iter()
    .collect()
}

// ---------------------------------------------------------------------------
// (A) MIRRORED orientation — an authored gate on a per-RECORD aggregate.
// ---------------------------------------------------------------------------

#[test]
fn mirrored_dense_aggregate_is_candidate_driven_not_full_product() {
    let g = geometry();
    let mut vars = serde_json::Map::new();
    for (k, v) in rect_params("cells") {
        vars.insert(k.to_string(), v);
    }
    vars.insert(
        "px".into(),
        json!({"type": "parameter", "shape": ["points"]}),
    );
    vars.insert(
        "py".into(),
        json!({"type": "parameter", "shape": ["points"]}),
    );
    // P[p] = SUM_{c in cells} [contains(cell_c, pt_p)] * (W[c] + S[c])
    vars.insert(
        "P".into(),
        json!({
            "type": "observed",
            "shape": ["points"],
            "expression": {
                "op": "aggregate",
                "reduce": "+",
                "output_idx": ["p"],
                "ranges": {"p": {"from": "points"}, "c": {"from": "cells"}},
                "join": [{"overlap": {
                    "src_env": ["px", "py"],
                    "tgt_env": ["src_W", "src_S", "src_E", "src_N"],
                    "eps": 0.0
                }}],
                "filter": contains("c", "p"),
                "args": ["src_W", "src_S", "src_E", "src_N", "px", "py"],
                "expr": {"op": "+", "args": [ix("src_W", "c"), ix("src_S", "c")]}
            }
        }),
    );
    let doc = json!({
        "esm": "1.0.0",
        "metadata": {"name": "dense_overlap_mirror"},
        "index_sets": {
            "points": {"kind": "interval", "size": NPTS},
            "cells": {"kind": "interval", "size": NCELLS}
        },
        "models": {"Mirror": {"variables": Value::Object(vars), "equations": []}}
    });

    let opts = PrepareOptions {
        model_name: Some("Mirror".into()),
        ..Default::default()
    };
    reset_overlap_enum_visits();
    let prep = prepare(&doc, geom_arrays(&g), Vec::new(), &opts).expect("prepare");
    let visits = overlap_enum_visits();

    // ---- values: exact, one term per record --------------------------------
    let got = prep.observed_field("P").expect("P materialized");
    assert_eq!(got.len(), NPTS);
    for (p, (val, &cell)) in got.iter().zip(g.cell_of.iter()).enumerate() {
        let k = cell - 1;
        assert_eq!(*val, g.w[k] + g.s[k], "P[{p}] moved under the driver");
    }

    // ---- scaling: O(|candidates|), not O(N_pts * N_cells) ------------------
    // MEASURED with the driver forced off: 4 000 000 visits (the full product);
    // with it on, 200. A 20 000x cut, matching the Julia reference's figure.
    assert_eq!(
        visits, NPTS as u64,
        "one candidate per point => one visited tuple per output record"
    );
    assert!(
        visits < (NPTS * NCELLS / 1000) as u64,
        "{visits} visits is not a cut against the {} full product",
        NPTS * NCELLS
    );
}

// ---------------------------------------------------------------------------
// (B) FORWARD orientation, through the projection-pushdown REWRITE.
// ---------------------------------------------------------------------------

#[test]
fn rewritten_forward_binning_aggregate_is_candidate_driven() {
    let g = geometry();
    let mut vars = serde_json::Map::new();
    for (k, v) in rect_params("cells") {
        vars.insert(k.to_string(), v);
    }
    vars.insert(
        "px".into(),
        json!({"type": "parameter", "shape": ["records"]}),
    );
    vars.insert(
        "py".into(),
        json!({"type": "parameter", "shape": ["records"]}),
    );
    vars.insert(
        "annual".into(),
        json!({"type": "parameter", "shape": ["records"]}),
    );
    vars.insert(
        "SR".into(),
        json!({"type": "parameter", "shape": ["cells", "rcv"]}),
    );
    // E[c] = SUM_{r in records} ifelse(contains(cell_c, pt_r), 1, 0) * annual[r]
    vars.insert(
        "E".into(),
        json!({
            "type": "observed",
            "shape": ["cells"],
            "expression": {
                "op": "aggregate",
                "reduce": "+",
                "output_idx": ["c"],
                "ranges": {"c": {"from": "cells"}, "r": {"from": "records"}},
                "args": ["src_W", "src_S", "src_E", "src_N", "px", "py", "annual"],
                "expr": {"op": "*", "args": [
                    {"op": "ifelse", "args": [contains("c", "r"), 1.0, 0.0]},
                    ix("annual", "r")
                ]}
            }
        }),
    );
    // conc[o] = SUM_{s in cells} SR[s, o] * E[s]  — the provider-backed mat-vec
    // whose presence is what makes the binning aggregate a FORWARD match.
    vars.insert(
        "conc".into(),
        json!({
            "type": "observed",
            "shape": ["rcv"],
            "expression": {
                "op": "aggregate",
                "reduce": "+",
                "output_idx": ["o"],
                "ranges": {"s": {"from": "cells"}, "o": {"from": "rcv"}},
                "args": ["SR", "E"],
                "expr": {"op": "*", "args": [
                    {"op": "index", "args": ["SR", "s", "o"]},
                    ix("E", "s")
                ]}
            }
        }),
    );
    let doc = json!({
        "esm": "1.0.0",
        "metadata": {"name": "dense_overlap_forward"},
        "index_sets": {
            "records": {"kind": "interval", "size": NPTS},
            "cells": {"kind": "interval", "size": NCELLS},
            "rcv": {"kind": "interval", "size": 2}
        },
        "models": {"Fwd": {"variables": Value::Object(vars), "equations": []}}
    });

    // The rewrite emits the derived gate over the COMPACT-axis envelopes.
    let rewritten = earthsci_ast::pushdown_rewrite::desugar_pushdown(&doc, Some("Fwd"))
        .expect("desugar")
        .into_owned();
    let ov = &rewritten["models"]["Fwd"]["variables"]["E"]["expression"]["join"][0]["overlap"];
    assert_eq!(ov["src_env"], json!(["px", "py"]));
    assert_eq!(
        ov["tgt_env"],
        json!([
            "pd_cell__cells__src_W",
            "pd_cell__cells__src_S",
            "pd_cell__cells__src_E",
            "pd_cell__cells__src_N"
        ])
    );

    let annual: Vec<f64> = (1..=NPTS).map(|i| i as f64).collect();
    let mut arrays = geom_arrays(&g);
    arrays.insert("annual".into(), arr1(&annual));
    arrays.insert(
        "SR".into(),
        ArrayD::from_shape_vec(IxDyn(&[NPTS, 2]), vec![1.0; NPTS * 2]).unwrap(),
    );

    let opts = PrepareOptions {
        model_name: Some("Fwd".into()),
        pushdown_rewrite: true,
        ..Default::default()
    };
    reset_overlap_enum_visits();
    let prep = prepare(&doc, arrays, Vec::new(), &opts).expect("prepare");
    let visits = overlap_enum_visits();

    // ---- the support axis compacted to exactly the occupied cells ----------
    let members = &prep.members["pd_faq__cells"];
    assert_eq!(members.len(), NPTS, "one distinct cell per record");

    // ---- values: every record contributes `annual` to exactly one cell -----
    let e_field = prep.observed_field("E").expect("E materialized");
    assert_eq!(e_field.len(), NPTS);
    let sum: f64 = e_field.iter().sum();
    assert_eq!(sum, annual.iter().sum::<f64>());

    // ---- scaling: O(|candidates|), not O(|support| * |records|) ------------
    // MEASURED with the driver forced off: 40 000 visits (|support| * |records|);
    // with it on, 200. A 200x cut, matching the Julia reference's figure.
    assert_eq!(visits, NPTS as u64);
    assert!(
        visits < (NPTS * NPTS / 100) as u64,
        "{visits} visits is not a cut against the {} full product",
        NPTS * NPTS
    );
}

// ---------------------------------------------------------------------------
// The other two normative drive shapes (§5.5.6): both gated symbols CONTRACTED
// (the pair drive), and both already BOUND (the membership test, whose reject
// arm is where the identity fill is observable).
//
// The micro fixture is the point-in-rectangle one from
// `broad_phase::tests::point_in_rect_candidate_set_matches_julia_golden`:
// 5 points x 4 cells, whose closed broad-phase candidate set is
// `{(1,1),(2,2),(3,1),(3,2),(5,3),(5,4)}` 1-based, of which the half-open
// rectangle containments `W<=x<E, S<=y<N` keep `(1,1)`, `(2,2)`, `(3,2)` and
// `(5,4)` — `(3,1)` and `(5,3)` are the boundary pairs the narrow phase drops.
// ---------------------------------------------------------------------------

const PIR_X: [f64; 5] = [1.0, 3.0, 2.0, 10.0, 6.0];
const PIR_Y: [f64; 5] = [1.0, 3.0, 2.0, 10.0, 6.0];
const PIR_W: [f64; 4] = [0.0, 2.0, 4.0, 6.0];
const PIR_S: [f64; 4] = [0.0, 2.0, 4.0, 6.0];
const PIR_E: [f64; 4] = [2.0, 4.0, 6.0, 8.0];
const PIR_N: [f64; 4] = [2.0, 4.0, 6.0, 8.0];

fn pir_arrays() -> HashMap<String, ArrayD<f64>> {
    [
        ("src_W".to_string(), arr1(&PIR_W)),
        ("src_S".to_string(), arr1(&PIR_S)),
        ("src_E".to_string(), arr1(&PIR_E)),
        ("src_N".to_string(), arr1(&PIR_N)),
        ("px".to_string(), arr1(&PIR_X)),
        ("py".to_string(), arr1(&PIR_Y)),
    ]
    .into_iter()
    .collect()
}

fn pir_vars() -> serde_json::Map<String, Value> {
    let mut vars = serde_json::Map::new();
    for (k, v) in rect_params("cells") {
        vars.insert(k.to_string(), v);
    }
    vars.insert(
        "px".into(),
        json!({"type": "parameter", "shape": ["points"]}),
    );
    vars.insert(
        "py".into(),
        json!({"type": "parameter", "shape": ["points"]}),
    );
    vars
}

fn pir_index_sets() -> Value {
    json!({
        "points": {"kind": "interval", "size": 5},
        "cells": {"kind": "interval", "size": 4},
        "one": {"kind": "interval", "size": 1}
    })
}

fn overlap_clause() -> Value {
    json!([{"overlap": {
        "src_env": ["px", "py"],
        "tgt_env": ["src_W", "src_S", "src_E", "src_N"],
        "eps": 0.0
    }}])
}

/// BOTH gated symbols contracted ⇒ the PAIR drive: the candidate pairs bind
/// both at once, in the exact order the odometer (`c` slow, `r` fast) would
/// have reached them, so the ⊕-accumulation order — and hence the sum — is
/// bit-identical to the filtered full product.
#[test]
fn both_gated_symbols_contracted_drives_from_the_candidate_pairs() {
    let mut vars = pir_vars();
    vars.insert(
        "total".into(),
        json!({
            "type": "observed",
            "shape": ["one"],
            "expression": {
                "op": "aggregate",
                "reduce": "+",
                "output_idx": ["k"],
                "ranges": {
                    "k": {"from": "one"},
                    "c": {"from": "cells"},
                    "r": {"from": "points"}
                },
                "join": overlap_clause(),
                "filter": contains("c", "r"),
                "args": ["src_W", "src_S", "src_E", "src_N", "px", "py"],
                "expr": {"op": "+", "args": [ix("src_W", "c"), ix("px", "r")]}
            }
        }),
    );
    let doc = json!({
        "esm": "1.0.0",
        "metadata": {"name": "overlap_pair_drive"},
        "index_sets": pir_index_sets(),
        "models": {"Pairs": {"variables": Value::Object(vars), "equations": []}}
    });
    let opts = PrepareOptions {
        model_name: Some("Pairs".into()),
        ..Default::default()
    };
    reset_overlap_enum_visits();
    let prep = prepare(&doc, pir_arrays(), Vec::new(), &opts).expect("prepare");
    let visits = overlap_enum_visits();

    // The four contained (point, cell) pairs, folded in the odometer's own
    // order — `c` slow, `r` fast — which is exactly the order the pair drive
    // reproduces: (r1,c1), (r2,c2), (r3,c2), (r5,c4).
    let want = (PIR_W[0] + PIR_X[0])
        + (PIR_W[1] + PIR_X[1])
        + (PIR_W[1] + PIR_X[2])
        + (PIR_W[3] + PIR_X[4]);
    let got = prep.observed_field("total").expect("total materialized");
    assert_eq!(got.len(), 1);
    assert_eq!(got.iter().next().copied().unwrap(), want);
    // 6 candidate pairs drive the walk, not the 4*5 = 20 full product.
    assert_eq!(visits, 6);
}

/// BOTH gated symbols already bound (they are the aggregate's two OUTPUT
/// indices) ⇒ a single membership test per cell. A rejected cell is never
/// visited and must read as the semiring identity — the §5.5.6 IDENTITY FILL,
/// which on a producer never arose (every position is invented) but on a dense
/// aggregate is a correctness requirement.
#[test]
fn both_gated_symbols_bound_is_a_membership_test_with_identity_fill() {
    let mut vars = pir_vars();
    vars.insert(
        "hit".into(),
        json!({
            "type": "observed",
            "shape": ["points", "cells"],
            "expression": {
                "op": "aggregate",
                "reduce": "+",
                "output_idx": ["r", "c"],
                "ranges": {"r": {"from": "points"}, "c": {"from": "cells"}},
                "join": overlap_clause(),
                "args": ["src_W", "src_S", "src_E", "src_N", "px", "py"],
                "expr": {"op": "ifelse", "args": [contains("c", "r"), 1.0, 0.0]}
            }
        }),
    );
    let doc = json!({
        "esm": "1.0.0",
        "metadata": {"name": "overlap_membership"},
        "index_sets": pir_index_sets(),
        "models": {"Member": {"variables": Value::Object(vars), "equations": []}}
    });
    let opts = PrepareOptions {
        model_name: Some("Member".into()),
        ..Default::default()
    };
    reset_overlap_enum_visits();
    let prep = prepare(&doc, pir_arrays(), Vec::new(), &opts).expect("prepare");
    let visits = overlap_enum_visits();

    let got = prep.observed_field("hit").expect("hit materialized");
    assert_eq!(got.shape(), &[5, 4]);
    // The four containments survive; every other position — the two candidate
    // pairs the narrow phase drops as well as the fourteen the gate rejects
    // outright — is the additive identity, not a hole and not NaN.
    let hits = [(0usize, 0usize), (1, 1), (2, 1), (4, 3)];
    for r in 0..5usize {
        for c in 0..4usize {
            let want = if hits.contains(&(r, c)) { 1.0 } else { 0.0 };
            assert_eq!(got[IxDyn(&[r, c])], want, "hit[{r},{c}]");
        }
    }
    // Only the 6 candidate positions evaluate the body at all; the other 14 are
    // filled with the additive identity without a visit.
    assert_eq!(visits, 6);
}
