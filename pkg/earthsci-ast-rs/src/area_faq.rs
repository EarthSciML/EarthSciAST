//! `polygon_area` as a `sum_product` FAQ over the clipped ring (RFC
//! `semiring-faq-unified-ir` §8.1; `CONFORMANCE_SPEC.md` §5.8; bead ess-d4g.1).
//!
//! **FAQ = Functional Aggregate Query** — the RFC's name for a semiring
//! aggregate (`⊕` over `⊗`-products) expressed in the unified IR; "the area
//! FAQ" below means "polygon area written as such an aggregate".
//!
//! `polygon_area` is **not** a new op: the area of a clipped vertex ring is an
//! ordinary `sum_product` aggregate over the ring index set. This module builds
//! that FAQ as an [`Expr`] and evaluates it through the **same** generic aggregate
//! machinery the array simulator uses ([`eval_expression`]) — so the production
//! conservative-regridding area ([`crate::regrid`]) is the FAQ, and the imperative
//! [`crate::geometry::polygon_area`] / `shoelace_area` / `spherical_area`
//! functions are only its cross-check oracle.
//!
//! Two manifolds, the same aggregate shape (the planar sibling and the spherical
//! sibling are tolerance-identical across the Julia / Python / Rust bindings):
//!
//! * **planar** — the Gauss–Green shoelace `0.5·Σ_v (x_v·y_{v+1} − x_{v+1}·y_v)`.
//! * **spherical / geodesic** — the great-circle fan triangulation
//!   `Σ_v E(v_1, v_v, v_{v+1})` of Van Oosterom–Strackee spherical excesses
//!   `E = 2·atan2(a·(b×c), 1 + a·b + b·c + c·a)`, built from the `sin` / `cos` /
//!   `atan2` scalar leaves (no new primitive).
//!
//! The ring is passed CLOSED (`n+1` rows, first vertex repeated) so the wrap edge
//! `v→1` is the ordinary 1-based `v+1` lookup, and the contraction ranges over the
//! `n` distinct vertices `[1, n]`. Ranging the full ring is exact for the
//! spherical fan: the two degenerate endpoints (`v=1` ⇒ `E(v_1,v_1,v_2)`, `v=n` ⇒
//! `E(v_1,v_n,v_1)`) carry zero excess, collapsing the sum to the `Σ_{i=2}^{n-1}`
//! fan the oracle computes — the same trick the shoelace uses for its wrap edge.

use std::collections::HashMap;

use ndarray::{ArrayD, IxDyn};
use serde_json::{Value as Json, json};

use crate::geometry::Manifold;
use crate::simulate_array::{Value, eval_expression};
use crate::types::Expr;

/// Coordinate column `c` (1 = lon, 2 = lat) of clip-ring vertex `idx` — `index`
/// is 1-based, columns 1-based, over the `overlap_clip` ring input.
fn col(idx: &Json, c: i64) -> Json {
    json!({ "op": "index", "args": ["overlap_clip", idx, c] })
}

/// Unit 3-vector AST `(cosφ·cosλ, cosφ·sinλ, sinφ)` of clip-ring vertex `idx`,
/// converting lon/lat degrees with the same `·(π/180)` factor `f64::to_radians`
/// applies, so the FAQ matches the imperative excess oracle bit-for-bit.
fn unit_vec(idx: &Json) -> [Json; 3] {
    let d = std::f64::consts::PI / 180.0;
    let lon = json!({ "op": "*", "args": [col(idx, 1), d] });
    let lat = json!({ "op": "*", "args": [col(idx, 2), d] });
    let cos_lat = json!({ "op": "cos", "args": [lat.clone()] });
    [
        json!({ "op": "*", "args": [cos_lat.clone(), { "op": "cos", "args": [lon.clone()] }] }),
        json!({ "op": "*", "args": [cos_lat, { "op": "sin", "args": [lon] }] }),
        json!({ "op": "sin", "args": [lat] }),
    ]
}

/// AST for the 3-vector dot product `u·v`.
fn dot3(u: &[Json; 3], v: &[Json; 3]) -> Json {
    json!({ "op": "+", "args": [
        { "op": "*", "args": [u[0].clone(), v[0].clone()] },
        { "op": "*", "args": [u[1].clone(), v[1].clone()] },
        { "op": "*", "args": [u[2].clone(), v[2].clone()] },
    ] })
}

/// AST for the 3-vector cross product `u×v`.
fn cross3(u: &[Json; 3], v: &[Json; 3]) -> [Json; 3] {
    [
        json!({ "op": "-", "args": [{ "op": "*", "args": [u[1].clone(), v[2].clone()] }, { "op": "*", "args": [u[2].clone(), v[1].clone()] }] }),
        json!({ "op": "-", "args": [{ "op": "*", "args": [u[2].clone(), v[0].clone()] }, { "op": "*", "args": [u[0].clone(), v[2].clone()] }] }),
        json!({ "op": "-", "args": [{ "op": "*", "args": [u[0].clone(), v[1].clone()] }, { "op": "*", "args": [u[1].clone(), v[0].clone()] }] }),
    ]
}

/// AST for the Van Oosterom–Strackee signed solid angle of triangle `a,b,c`:
/// `2·atan2(a·(b×c), 1 + a·b + b·c + c·a)`.
fn spherical_excess(a: &[Json; 3], b: &[Json; 3], c: &[Json; 3]) -> Json {
    let triple = dot3(a, &cross3(b, c));
    let denom = json!({ "op": "+", "args": [1.0, dot3(a, b), dot3(b, c), dot3(c, a)] });
    json!({ "op": "*", "args": [2.0, { "op": "atan2", "args": [triple, denom] }] })
}

/// The planar `polygon_area` FAQ over the closed clip ring (Gauss–Green shoelace),
/// an ordinary `sum_product` aggregate (§8.1).
pub(crate) fn shoelace_faq_node(n: usize) -> Expr {
    let v: Json = json!("v");
    let v_next: Json = json!({ "op": "+", "args": ["v", 1] });
    serde_json::from_value(json!({
        "op": "aggregate", "args": [], "semiring": "sum_product", "output_idx": [],
        "ranges": { "v": [1, n] },
        "expr": { "op": "*", "args": [0.5, { "op": "-", "args": [
            { "op": "*", "args": [col(&v, 1), col(&v_next, 2)] },
            { "op": "*", "args": [col(&v_next, 1), col(&v, 2)] },
        ] }] },
    }))
    .expect("shoelace area FAQ node is well-formed")
}

/// The spherical `polygon_area` FAQ over the closed clip ring (great-circle fan of
/// Van Oosterom–Strackee excesses), an ordinary `sum_product` aggregate (§8.1) —
/// the spherical sibling of [`shoelace_faq_node`]. Unit sphere (steradians).
pub(crate) fn spherical_excess_faq_node(n: usize) -> Expr {
    let apex = unit_vec(&json!(1));
    let here = unit_vec(&json!("v"));
    let next = unit_vec(&json!({ "op": "+", "args": ["v", 1] }));
    serde_json::from_value(json!({
        "op": "aggregate", "args": [], "semiring": "sum_product", "output_idx": [],
        "ranges": { "v": [1, n] },
        "expr": spherical_excess(&apex, &here, &next),
    }))
    .expect("spherical area FAQ node is well-formed")
}

/// Unsigned `polygon_area` of an overlap `ring` under `manifold`, evaluated as a
/// `sum_product` FAQ through the generic aggregate machinery ([`eval_expression`]).
///
/// The ring is closed internally (`n+1` rows) so the wrap edge is an ordinary
/// `v+1` lookup, registered as the `overlap_clip` input the FAQ contracts over.
/// A degenerate (`< 3` vertex) ring — an empty clip — is `0.0`. Planar ⇒ shoelace;
/// spherical / geodesic ⇒ the great-circle-edge area in **steradians** (unit
/// sphere) — the same value [`crate::geometry::polygon_area`] computes, now the
/// cross-check oracle.
pub fn polygon_area_faq(ring: &[(f64, f64)], manifold: Manifold) -> f64 {
    let n = ring.len();
    if n < 3 {
        return 0.0;
    }
    // Close the ring: append the first vertex so edge n→1 is `index(ring, n+1)`.
    let mut flat: Vec<f64> = Vec::with_capacity((n + 1) * 2);
    for &(x, y) in ring {
        flat.push(x);
        flat.push(y);
    }
    flat.push(ring[0].0);
    flat.push(ring[0].1);
    let clip = ArrayD::from_shape_vec(IxDyn(&[n + 1, 2]), flat).expect("closed ring is [n+1, 2]");

    let faq = match manifold {
        Manifold::Planar => shoelace_faq_node(n),
        Manifold::Spherical | Manifold::Geodesic => spherical_excess_faq_node(n),
    };
    let mut inputs: HashMap<String, ArrayD<f64>> = HashMap::new();
    inputs.insert("overlap_clip".to_string(), clip);
    // The FAQ node is built HERE (`shoelace_faq_node` / `spherical_excess_faq_node`)
    // out of evaluable-core ops only, so `eval_expression`'s operator gate cannot
    // reject it — it is not user input.
    let value = eval_expression(&faq, &inputs, &[], &[], 0.0)
        .expect("the polygon-area FAQ node is built from evaluable ops by construction");
    match value {
        Value::Scalar(s) => s.abs(),
        // A scalar aggregate (empty output_idx) always reduces to a scalar.
        Value::Array(_) => unreachable!("scalar polygon_area FAQ must reduce to a scalar"),
    }
}

#[cfg(all(test, not(target_arch = "wasm32")))]
mod tests {
    use super::*;
    use crate::geometry;
    use std::f64::consts::PI;

    const TIGHT: f64 = 1e-12;

    #[test]
    fn planar_area_faq_matches_shoelace_oracle() {
        // A general (non-rectangular) ring exercises every shoelace term.
        let ring = [(0.0, 0.0), (4.0, 0.0), (4.0, 3.0), (1.0, 5.0), (0.0, 3.0)];
        let faq = polygon_area_faq(&ring, Manifold::Planar);
        assert!((faq - geometry::shoelace_area(&ring)).abs() < TIGHT);
    }

    #[test]
    fn spherical_area_faq_octant_is_pi_over_two() {
        // A spherical octant triangle has area π/2 steradians on the unit sphere.
        let octant = [(0.0, 0.0), (90.0, 0.0), (0.0, 90.0)];
        let faq = polygon_area_faq(&octant, Manifold::Spherical);
        assert!((faq - PI / 2.0).abs() < TIGHT, "octant FAQ {faq} vs π/2");
    }

    #[test]
    fn spherical_area_faq_matches_s2_oracle() {
        // The Van Oosterom–Strackee fan (the FAQ) agrees with s2geometry's own
        // spherical area of the same ring to the great-circle tolerance — both
        // model great-circle edges (§5.8.4).
        let ring = [(10.0, 20.0), (30.0, 22.0), (28.0, 40.0), (8.0, 38.0)];
        for manifold in [Manifold::Spherical, Manifold::Geodesic] {
            let faq = polygon_area_faq(&ring, manifold);
            let oracle = geometry::polygon_area(&ring, manifold).unwrap();
            assert!(
                geometry::area_tolerance_ok(faq, oracle, 1e-9, 1.0),
                "{manifold:?} FAQ {faq} vs s2 oracle {oracle}",
            );
        }
    }

    #[test]
    fn degenerate_ring_is_zero_area() {
        let two = [(0.0, 0.0), (1.0, 1.0)];
        assert_eq!(polygon_area_faq(&two, Manifold::Planar), 0.0);
        assert_eq!(polygon_area_faq(&two, Manifold::Spherical), 0.0);
    }
}
