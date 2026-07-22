//! PLANAR spatial-index broad phase — conservative candidate generation.
//!
//! Phase 3a of projection-pushdown, ported from the Julia reference
//! `pkg/EarthSciAST.jl/src/broad_phase.jl`. A reusable, deterministic
//! broad-phase seam returning a CONSERVATIVE SUPERSET of the `(query × cell)`
//! index pairs whose 2-D bounding boxes (envelopes) intersect. The overlap
//! join-gate (`crate::value_invention`) consumes it to replace a uniform-grid
//! bin-equality gate with envelope candidacy.
//!
//! Two layers, so there is a reference oracle:
//!
//!   1. CORE — [`broad_phase_candidates_bruteforce`]: the dependency-free
//!      `O(nq·nc)` reference method AND the conformance oracle. Walks every pair
//!      and tests envelope intersection.
//!   2. FAST — [`broad_phase_candidates`]: an `rstar` R*-tree over the cell
//!      envelopes, queried by the (eps-inflated) query envelopes. `rstar` is
//!      pure Rust (WASM-clean), and its `AABB` intersection predicate is CLOSED
//!      (`<=`/`>=`, edge-touching admitted) — identical to the brute-force test
//!      — so the fast path returns a vector byte-identical to the core for the
//!      same `eps`. [`broad_phase_candidates_bruteforce`] is retained as the
//!      self-conformance oracle (see the `rstar == brute-force` tests).
//!
//! ENVELOPE CONVENTION. A feature envelope is `(xmin, ymin, xmax, ymax)` — an
//! [`Envelope`] = `[f64; 4]`. (Note this ORDER differs from `geometry.rs`'s
//! internal ring bbox `(xmin, xmax, ymin, ymax)`; the 1-name ring arm below
//! remaps.) The intersection predicate is CLOSED (edge-touching boxes are
//! candidates), matching the negation of a planar bbox-disjoint reject: at
//! `eps=0` this candidate set is exactly the set of pairs a closed AABB overlap
//! does not reject.
//!
//! `eps` SEMANTICS. Both envelopes of a pair are inflated OUTWARD by `eps`
//! before testing: `xmin -= eps, ymin -= eps, xmax += eps, ymax += eps`.
//! `eps >= 0` grows the candidate set (monotone): `candidates(eps=δ) ⊇
//! candidates(eps=0)`. `eps` is a slack knob to keep near-touching /
//! float-fuzzy pairs conservative.

use std::collections::HashMap;

use ndarray::ArrayD;
use rstar::{AABB, RTree, RTreeObject};

/// A feature envelope `(xmin, ymin, xmax, ymax)`.
pub type Envelope = [f64; 4];

/// Inflate an envelope outward by `eps` on every side.
#[inline]
fn inflate(e: &Envelope, eps: f64) -> Envelope {
    [e[0] - eps, e[1] - eps, e[2] + eps, e[3] + eps]
}

/// Closed-interval AABB intersection per axis (edge-touching admitted). This is
/// bit-for-bit the predicate `rstar`'s `AABB::intersects` applies, so the
/// brute-force core and the R*-tree fast path agree.
#[inline]
fn envelopes_intersect(a: &Envelope, b: &Envelope) -> bool {
    a[0] <= b[2] && b[0] <= a[2] && a[1] <= b[3] && b[1] <= a[3]
}

/// CORE brute-force reference: every `(qi, cj)` — 0-based positions in
/// `query_envs` / `cell_envs` — whose 2-D envelopes intersect after inflating
/// BOTH outward by `eps`. The result is sorted ascending by `(qi, cj)` for
/// determinism.
///
/// This is a CONSERVATIVE SUPERSET of true geometric overlaps: any pair of
/// features whose geometries actually overlap has intersecting envelopes and so
/// appears here (with `eps >= 0`). Missing a true overlap is impossible by
/// construction — the envelope of a geometry contains it. It is BOTH the
/// dependency-free fallback AND the conformance oracle for [`broad_phase_candidates`].
pub fn broad_phase_candidates_bruteforce(
    query_envs: &[Envelope],
    cell_envs: &[Envelope],
    eps: f64,
) -> Vec<(usize, usize)> {
    let mut out: Vec<(usize, usize)> = Vec::new();
    if query_envs.is_empty() || cell_envs.is_empty() {
        return out;
    }
    for (qi, q) in query_envs.iter().enumerate() {
        let qi_env = inflate(q, eps);
        for (cj, c) in cell_envs.iter().enumerate() {
            let cj_env = inflate(c, eps);
            if envelopes_intersect(&qi_env, &cj_env) {
                out.push((qi, cj));
            }
        }
    }
    // Emitted in (qi, cj) ascending order already; sort pins the determinism
    // contract independent of loop structure.
    out.sort_unstable();
    out
}

/// A cell envelope wrapped as an `rstar` tree object carrying its 0-based
/// position. The AABB is pre-inflated by `eps` at build time so the tree query
/// mirrors the brute-force per-pair symmetric inflation exactly.
struct CellEnv {
    idx: usize,
    aabb: AABB<[f64; 2]>,
}

impl RTreeObject for CellEnv {
    type Envelope = AABB<[f64; 2]>;
    fn envelope(&self) -> Self::Envelope {
        self.aabb
    }
}

/// FAST PATH: an `rstar` R*-tree over the (eps-inflated) `cell_envs`, queried by
/// each (eps-inflated) query envelope. Returns every envelope-intersecting
/// `(qi, cj)` 0-based pair, SORTED ascending by `(qi, cj)` — byte-identical to
/// [`broad_phase_candidates_bruteforce`] for the same `eps` (the tree's `AABB`
/// intersection is CLOSED, matching the core).
pub fn broad_phase_candidates(
    query_envs: &[Envelope],
    cell_envs: &[Envelope],
    eps: f64,
) -> Vec<(usize, usize)> {
    let mut out: Vec<(usize, usize)> = Vec::new();
    if query_envs.is_empty() || cell_envs.is_empty() {
        return out;
    }
    // Bulk-load the tree over the eps-inflated cell AABBs.
    let objects: Vec<CellEnv> = cell_envs
        .iter()
        .enumerate()
        .map(|(idx, c)| {
            let e = inflate(c, eps);
            CellEnv {
                idx,
                aabb: AABB::from_corners([e[0], e[1]], [e[2], e[3]]),
            }
        })
        .collect();
    let tree = RTree::bulk_load(objects);
    for (qi, q) in query_envs.iter().enumerate() {
        let e = inflate(q, eps);
        let query_aabb = AABB::from_corners([e[0], e[1]], [e[2], e[3]]);
        for hit in tree.locate_in_envelope_intersecting(query_aabb) {
            out.push((qi, hit.idx));
        }
    }
    out.sort_unstable();
    out
}

/// Build per-position `(xmin, ymin, xmax, ymax)` envelopes from named
/// const-array envelope factors, mirroring the Julia
/// `_envelope_vectors_from_cols`. `env_names` is 1, 2, or 4 factor names; each
/// is looked up in `arrays`:
///   * 4 names → rectangles `[xmin, ymin, xmax, ymax]` (e.g. ISRM cells `[W,S,E,N]`),
///   * 2 names → points `[x, y]` → degenerate envelope `(x, y, x, y)`,
///   * 1 name  → a `[pos, verts, coord]` 3-D ring factor → AABB over the ring
///     vertices, remapped from `(xmin, xmax, ymin, ymax)` to
///     `(xmin, ymin, xmax, ymax)`.
pub fn envelope_vectors(
    env_names: &[String],
    arrays: &HashMap<String, ArrayD<f64>>,
) -> Result<Vec<Envelope>, String> {
    let k = env_names.len();
    let col = |name: &str| -> Result<&ArrayD<f64>, String> {
        arrays
            .get(name)
            .ok_or_else(|| format!("overlap-join env factor {name:?} not supplied in const arrays"))
    };
    match k {
        4 => {
            let (a, b, c, d) = (
                col(&env_names[0])?,
                col(&env_names[1])?,
                col(&env_names[2])?,
                col(&env_names[3])?,
            );
            let n = a.len();
            if b.len() != n || c.len() != n || d.len() != n {
                return Err(format!(
                    "overlap-join 4-factor rect envelope factors must share a length; got \
                     {}, {}, {}, {}",
                    a.len(),
                    b.len(),
                    c.len(),
                    d.len()
                ));
            }
            let (av, bv, cv, dv) = (flat(a), flat(b), flat(c), flat(d));
            Ok((0..n).map(|p| [av[p], bv[p], cv[p], dv[p]]).collect())
        }
        2 => {
            let (x, y) = (col(&env_names[0])?, col(&env_names[1])?);
            let n = x.len();
            if y.len() != n {
                return Err(format!(
                    "overlap-join 2-factor point envelope factors must share a length; got {}, {}",
                    x.len(),
                    y.len()
                ));
            }
            let (xv, yv) = (flat(x), flat(y));
            Ok((0..n).map(|p| [xv[p], yv[p], xv[p], yv[p]]).collect())
        }
        1 => ring_envelopes(col(&env_names[0])?),
        other => Err(format!(
            "overlap-join env must name 1 (rings), 2 (point [x,y]), or 4 \
             (rect [xmin,ymin,xmax,ymax]) const-array factors; got {other}"
        )),
    }
}

/// A contiguous view of an ndarray's elements in row-major order (all envelope
/// factors here are dense 1-D columns, so this is the column itself).
fn flat(a: &ArrayD<f64>) -> Vec<f64> {
    a.iter().copied().collect()
}

/// A `[pos, verts, coord]` ring factor → one AABB envelope per position,
/// remapping the ring bbox `(xmin, xmax, ymin, ymax)` to
/// `(xmin, ymin, xmax, ymax)` (mirrors `_ring_envelopes` / `_ring_xybbox`).
fn ring_envelopes(rings: &ArrayD<f64>) -> Result<Vec<Envelope>, String> {
    let shape = rings.shape();
    if shape.len() != 3 {
        return Err(format!(
            "overlap-join single-factor env expects a [pos, verts, coord] 3-D ring array; \
             got a {}-D factor",
            shape.len()
        ));
    }
    let (npos, nverts, ncoord) = (shape[0], shape[1], shape[2]);
    if ncoord < 2 || nverts == 0 {
        return Err(format!(
            "overlap-join ring factor must be [pos, verts>=1, coord>=2]; got shape {shape:?}"
        ));
    }
    let mut out: Vec<Envelope> = Vec::with_capacity(npos);
    for p in 0..npos {
        let mut xmin = rings[ndarray::IxDyn(&[p, 0, 0])];
        let mut xmax = xmin;
        let mut ymin = rings[ndarray::IxDyn(&[p, 0, 1])];
        let mut ymax = ymin;
        for v in 1..nverts {
            let x = rings[ndarray::IxDyn(&[p, v, 0])];
            let y = rings[ndarray::IxDyn(&[p, v, 1])];
            if x < xmin {
                xmin = x;
            }
            if x > xmax {
                xmax = x;
            }
            if y < ymin {
                ymin = y;
            }
            if y > ymax {
                ymax = y;
            }
        }
        out.push([xmin, ymin, xmax, ymax]);
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use ndarray::IxDyn;

    fn arr(shape: &[usize], data: Vec<f64>) -> ArrayD<f64> {
        ArrayD::from_shape_vec(IxDyn(shape), data).expect("shape matches data")
    }

    fn ca(pairs: Vec<(&str, ArrayD<f64>)>) -> HashMap<String, ArrayD<f64>> {
        pairs.into_iter().map(|(k, v)| (k.to_string(), v)).collect()
    }

    fn names(ns: &[&str]) -> Vec<String> {
        ns.iter().map(|s| s.to_string()).collect()
    }

    /// The point-in-rectangle micro fixture from the Julia
    /// `overlap_gate_conformance_test.jl`: 5 points × 4 cells, whose closed
    /// broad-phase candidate set is exactly `{(0,0),(1,1),(2,0),(2,1),(4,2),(4,3)}`
    /// (0-based here; `{(1,1),(2,2),(3,1),(3,2),(5,3),(5,4)}` 1-based in Julia).
    fn pir_envelopes() -> (Vec<Envelope>, Vec<Envelope>) {
        let arrays = ca(vec![
            ("X", arr(&[5], vec![1.0, 3.0, 2.0, 10.0, 6.0])),
            ("Y", arr(&[5], vec![1.0, 3.0, 2.0, 10.0, 6.0])),
            ("W", arr(&[4], vec![0.0, 2.0, 4.0, 6.0])),
            ("S", arr(&[4], vec![0.0, 2.0, 4.0, 6.0])),
            ("E", arr(&[4], vec![2.0, 4.0, 6.0, 8.0])),
            ("N", arr(&[4], vec![2.0, 4.0, 6.0, 8.0])),
        ]);
        let src = envelope_vectors(&names(&["X", "Y"]), &arrays).unwrap();
        let tgt = envelope_vectors(&names(&["W", "S", "E", "N"]), &arrays).unwrap();
        (src, tgt)
    }

    #[test]
    fn point_in_rect_candidate_set_matches_julia_golden() {
        let (src, tgt) = pir_envelopes();
        let got = broad_phase_candidates(&src, &tgt, 0.0);
        // 0-based analogue of the Julia golden {(1,1),(2,2),(3,1),(3,2),(5,3),(5,4)}.
        assert_eq!(got, vec![(0, 0), (1, 1), (2, 0), (2, 1), (4, 2), (4, 3)]);
    }

    #[test]
    fn rstar_equals_bruteforce_on_pir() {
        let (src, tgt) = pir_envelopes();
        for &eps in &[0.0, 0.5, 1.0, 2.5] {
            assert_eq!(
                broad_phase_candidates(&src, &tgt, eps),
                broad_phase_candidates_bruteforce(&src, &tgt, eps),
                "rstar != brute-force at eps={eps}"
            );
        }
    }

    #[test]
    fn conservativeness_and_monotonicity_in_eps() {
        let (src, tgt) = pir_envelopes();
        let c0 = broad_phase_candidates(&src, &tgt, 0.0);
        let c1 = broad_phase_candidates(&src, &tgt, 1.0);
        // eps grows the candidate set (superset).
        for pair in &c0 {
            assert!(c1.contains(pair), "eps=1 dropped a eps=0 candidate {pair:?}");
        }
        assert!(c1.len() >= c0.len());
        // The true strict containments (p0∈c0, p1∈c1) are always candidates.
        assert!(c0.contains(&(0, 0)));
        assert!(c0.contains(&(1, 1)));
    }

    #[test]
    fn rstar_equals_bruteforce_random_stress() {
        // A deterministic LCG driving a spread of rectangles; rstar and the
        // brute-force oracle must agree pair-for-pair at several eps.
        let mut state: u64 = 0x9E3779B97F4A7C15;
        let mut next = || {
            state = state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            ((state >> 33) as f64) / (1u64 << 31) as f64 // in [0, 1)
        };
        let mk = |n: usize, next: &mut dyn FnMut() -> f64| -> Vec<Envelope> {
            (0..n)
                .map(|_| {
                    let x0 = next() * 10.0;
                    let y0 = next() * 10.0;
                    let w = next() * 2.0;
                    let h = next() * 2.0;
                    [x0, y0, x0 + w, y0 + h]
                })
                .collect()
        };
        let query = mk(40, &mut next);
        let cells = mk(60, &mut next);
        for &eps in &[0.0, 0.1, 0.75, 3.0] {
            assert_eq!(
                broad_phase_candidates(&query, &cells, eps),
                broad_phase_candidates_bruteforce(&query, &cells, eps),
                "rstar != brute-force at eps={eps}"
            );
        }
    }

    #[test]
    fn empty_inputs_yield_empty() {
        let some = vec![[0.0, 0.0, 1.0, 1.0]];
        assert!(broad_phase_candidates(&[], &some, 0.0).is_empty());
        assert!(broad_phase_candidates(&some, &[], 0.0).is_empty());
        assert!(broad_phase_candidates_bruteforce(&[], &some, 0.0).is_empty());
    }

    #[test]
    fn ring_envelope_arm_builds_aabb() {
        // Two triangles as [pos, verts, coord]: pos0 spans x∈[0,2] y∈[0,1],
        // pos1 spans x∈[3,5] y∈[2,4].
        let rings = arr(
            &[2, 3, 2],
            vec![
                0.0, 0.0, 2.0, 0.0, 1.0, 1.0, // pos0 verts
                3.0, 2.0, 5.0, 2.0, 4.0, 4.0, // pos1 verts
            ],
        );
        let arrays = ca(vec![("rings", rings)]);
        let envs = envelope_vectors(&names(&["rings"]), &arrays).unwrap();
        assert_eq!(envs, vec![[0.0, 0.0, 2.0, 1.0], [3.0, 2.0, 5.0, 4.0]]);
    }
}
