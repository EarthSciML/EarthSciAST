//! Conservative-regridding geometry kernel — the `intersect_polygon` leaf op
//! (RFC `semiring-faq-unified-ir` §8.1, Appendix B.2; CONFORMANCE_SPEC.md §5.8).
//!
//! `intersect_polygon` clips two lon/lat polygon rings and returns the overlap
//! vertex ring of **data-dependent length**. It is the one required new op of
//! the M4 geometry split; `polygon_area` is *not* a new op — it is an ordinary
//! `sum_product` FAQ over the clipped ring (planar shoelace / spherical excess),
//! evaluated by the M1 aggregate machinery ([`crate::simulate_array`]).
//!
//! # Manifold-aware clipping
//!
//! The clip is governed by the node's required `manifold` flag (§5.8.4):
//!
//! * [`Manifold::Spherical`] / [`Manifold::Geodesic`] — edges are **great-circle
//!   arcs**; the clip is delegated to Google's `s2geometry` engine via the
//!   [`s2bindings`] crate. This is the same S2 core that backs Python's
//!   `spherely`, so the Rust and Python bindings share a geometry kernel and
//!   agree to a much tighter tolerance than either does with Julia/GeometryOps
//!   (CONFORMANCE_SPEC.md §5.8.2). A flat lon/lat clip is wrong at the poles and
//!   the antimeridian, which is exactly why the kernel is required.
//! * [`Manifold::Planar`] — edges are **straight lines in the lon/lat plane**;
//!   the clip is a pure-Rust Sutherland–Hodgman convex-polygon intersection.
//!   Exact and dependency-free, used where a flat interpretation is intended
//!   (and as the exact analytic anchor for the `polygon_area` shoelace FAQ).
//!
//! Two bindings may be compared only under the **same** declared manifold
//! (§5.8.4): `spherical` and `geodesic` both clip on great-circle edges here.
//!
//! # Coordinates and rings
//!
//! Vertices are `(longitude, latitude)` pairs in **degrees** (`x = lon`,
//! `y = lat`) — the GeoJSON / GeometryOps order. Rings are **implicitly closed**:
//! each vertex appears once and the final edge joins the last vertex back to the
//! first. A disjoint or edge-touching clip yields an **empty** ring (length 0).

#[cfg(not(target_arch = "wasm32"))]
use s2bindings::SphericalPolygon;

/// The geometric interpretation of an `intersect_polygon` node's edges — the
/// value of its required `manifold` flag (RFC §8.1; CONFORMANCE_SPEC.md §5.8.4).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Manifold {
    /// Straight edges in the flat lon/lat plane (Sutherland–Hodgman clip).
    Planar,
    /// Great-circle edges on the sphere (S2 clip).
    Spherical,
    /// Geodesic edges. On the sphere these coincide with great-circle arcs, so
    /// the kernel clips them via the same S2 path as [`Manifold::Spherical`];
    /// the distinction is preserved only for same-manifold comparison (§5.8.4).
    Geodesic,
}

impl Manifold {
    /// Parse the schema `manifold` flag string. Returns `None` for any value
    /// outside the closed `{planar, spherical, geodesic}` enum.
    pub fn from_flag(s: &str) -> Option<Manifold> {
        match s {
            "planar" => Some(Manifold::Planar),
            "spherical" => Some(Manifold::Spherical),
            "geodesic" => Some(Manifold::Geodesic),
            _ => None,
        }
    }

    /// The schema flag string for this manifold.
    pub fn as_str(&self) -> &'static str {
        match self {
            Manifold::Planar => "planar",
            Manifold::Spherical => "spherical",
            Manifold::Geodesic => "geodesic",
        }
    }
}

/// An error from the geometry kernel — a degenerate input ring, a failed clip,
/// or (on `wasm32`) the absence of the native spherical backend. Wraps the
/// human-readable reason reported by the underlying engine.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GeometryError {
    message: String,
}

impl GeometryError {
    pub(crate) fn new(message: impl Into<String>) -> Self {
        GeometryError {
            message: message.into(),
        }
    }

    /// The underlying failure reason.
    pub fn message(&self) -> &str {
        &self.message
    }
}

impl std::fmt::Display for GeometryError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "geometry kernel error: {}", self.message)
    }
}

impl std::error::Error for GeometryError {}

/// Clip polygon `a` against polygon `b` on the given `manifold`, returning the
/// overlap ring as `(lon, lat)` degree vertices. The ring is implicitly closed
/// and has data-dependent length; a disjoint / edge-touching clip returns an
/// **empty** `Vec` (§8.1, §5.8.2).
///
/// This is the evaluator for the `intersect_polygon` leaf op. `polygon_area`
/// over the returned ring is a separate `sum_product` FAQ (not computed here).
pub fn intersect_polygon(
    a: &[(f64, f64)],
    b: &[(f64, f64)],
    manifold: Manifold,
) -> Result<Vec<(f64, f64)>, GeometryError> {
    match manifold {
        Manifold::Spherical | Manifold::Geodesic => intersect_spherical(a, b),
        Manifold::Planar => Ok(intersect_planar_convex(a, b)),
    }
}

/// Spherical / geodesic clip via Google's `s2geometry` (the `s2bindings` crate).
/// The overlap of two convex cells is a single shell ring; any shell loops are
/// concatenated in S2's output order (interior on the left).
#[cfg(not(target_arch = "wasm32"))]
fn intersect_spherical(
    a: &[(f64, f64)],
    b: &[(f64, f64)],
) -> Result<Vec<(f64, f64)>, GeometryError> {
    let pa = SphericalPolygon::from_lon_lat(a).map_err(|e| GeometryError::new(e.to_string()))?;
    let pb = SphericalPolygon::from_lon_lat(b).map_err(|e| GeometryError::new(e.to_string()))?;
    let clip = pa
        .intersection(&pb)
        .map_err(|e| GeometryError::new(e.to_string()))?;
    if clip.is_empty() {
        return Ok(Vec::new());
    }
    let mut verts = Vec::new();
    for ring in clip.rings() {
        if !ring.is_hole {
            verts.extend(ring.vertices);
        }
    }
    Ok(verts)
}

/// On `wasm32` the native S2 backend is unavailable (the `s2bindings` C++
/// superbuild does not target wasm), so a spherical clip is an error there.
/// The planar path remains fully available.
#[cfg(target_arch = "wasm32")]
fn intersect_spherical(
    _a: &[(f64, f64)],
    _b: &[(f64, f64)],
) -> Result<Vec<(f64, f64)>, GeometryError> {
    Err(GeometryError::new(
        "spherical/geodesic intersect_polygon requires the native s2bindings backend, \
         which is not built for wasm32",
    ))
}

/// Planar Sutherland–Hodgman intersection of a subject polygon against a convex
/// clip polygon, both as `(lon, lat)` vertices in the flat plane. Correct when
/// the clip polygon `b` is convex (conservative-regridding cells are convex
/// quads); the result is their convex overlap, empty when disjoint.
fn intersect_planar_convex(subject: &[(f64, f64)], clip: &[(f64, f64)]) -> Vec<(f64, f64)> {
    if subject.len() < 3 || clip.len() < 3 {
        return Vec::new();
    }
    // Orient the clip ring counter-clockwise so "inside" is consistently the
    // left half-plane of each directed clip edge, regardless of input winding.
    let clip = orient_ccw(clip);
    let mut output: Vec<(f64, f64)> = subject.to_vec();
    for i in 0..clip.len() {
        if output.is_empty() {
            break;
        }
        let edge_a = clip[i];
        let edge_b = clip[(i + 1) % clip.len()];
        let input = std::mem::take(&mut output);
        let n = input.len();
        for j in 0..n {
            let cur = input[j];
            let prev = input[(j + n - 1) % n];
            let cur_in = is_left_of(edge_a, edge_b, cur);
            let prev_in = is_left_of(edge_a, edge_b, prev);
            if cur_in {
                if !prev_in && let Some(ip) = line_segment_clip(prev, cur, edge_a, edge_b) {
                    output.push(ip);
                }
                output.push(cur);
            } else if prev_in && let Some(ip) = line_segment_clip(prev, cur, edge_a, edge_b) {
                output.push(ip);
            }
        }
    }
    output
}

/// Signed area of a planar ring (positive ⇒ counter-clockwise), via the
/// shoelace formula. This is the closed form the planar `polygon_area` FAQ
/// computes; exposed as a reference oracle for the FAQ evaluation tests.
pub fn shoelace_signed_area(ring: &[(f64, f64)]) -> f64 {
    let n = ring.len();
    if n < 3 {
        return 0.0;
    }
    let mut acc = 0.0;
    for i in 0..n {
        let (x0, y0) = ring[i];
        let (x1, y1) = ring[(i + 1) % n];
        acc += x0 * y1 - x1 * y0;
    }
    0.5 * acc
}

/// Unsigned planar polygon area (|shoelace|). The reference value for the
/// planar `polygon_area` `sum_product` FAQ.
pub fn shoelace_area(ring: &[(f64, f64)]) -> f64 {
    shoelace_signed_area(ring).abs()
}

/// Spherical polygon area in **steradians** (unit sphere, range `[0, 4π]`) via
/// `s2geometry`. The reference value for the spherical `polygon_area` FAQ /
/// the §5.8.2 tolerance anchor. Multiply by `R²` for a physical area.
#[cfg(not(target_arch = "wasm32"))]
pub fn spherical_area(ring: &[(f64, f64)]) -> Result<f64, GeometryError> {
    if ring.len() < 3 {
        return Ok(0.0);
    }
    let p = SphericalPolygon::from_lon_lat(ring).map_err(|e| GeometryError::new(e.to_string()))?;
    Ok(p.area())
}

/// Unsigned `polygon_area` of an overlap ring under `manifold` — the value the
/// `polygon_area` `sum_product` FAQ computes (RFC §8.1). Planar ⇒ shoelace /
/// Gauss–Green; spherical / geodesic ⇒ the great-circle-edge area in **steradians**
/// (unit sphere) via `s2geometry`. A degenerate (< 3 vertex) ring — an empty clip —
/// is `0.0`. This is the reference area the conservative-regridding assembly
/// ([`crate::regrid`]) consumes as the build-once factor `A_ij`, the same formula
/// the FAQ body encodes (mirrors Python `geometry.polygon_area`).
#[cfg(not(target_arch = "wasm32"))]
pub fn polygon_area(ring: &[(f64, f64)], manifold: Manifold) -> Result<f64, GeometryError> {
    match manifold {
        Manifold::Planar => Ok(shoelace_area(ring)),
        Manifold::Spherical | Manifold::Geodesic => spherical_area(ring),
    }
}

/// On `wasm32` only the planar area is available (the S2 backend is not built for
/// wasm); a spherical / geodesic `polygon_area` is an error there.
#[cfg(target_arch = "wasm32")]
pub fn polygon_area(ring: &[(f64, f64)], manifold: Manifold) -> Result<f64, GeometryError> {
    match manifold {
        Manifold::Planar => Ok(shoelace_area(ring)),
        Manifold::Spherical | Manifold::Geodesic => Err(GeometryError::new(
            "spherical/geodesic polygon_area requires the native s2bindings backend, \
             which is not built for wasm32",
        )),
    }
}

/// The B.5 / §5.8.2 **sliver floor** factor: `atol ≈ 1e-15·R²`. Near-tangent
/// overlaps are the regime where two clippers legitimately disagree on whether a
/// tiny intersection even exists, so sub-`atol` areas are treated as
/// equal-to-zero. Mirrors Python `geometry.SLIVER_ATOL_FACTOR`.
pub const SLIVER_ATOL_FACTOR: f64 = 1e-15;

/// The absolute sliver floor `atol = 1e-15·R²` for a sphere radius /
/// characteristic length `radius` (§5.8.2). On the unit sphere (`radius = 1`) this
/// is `1e-15` steradians; for a physical area multiply the characteristic length
/// into `radius`.
pub fn sliver_atol(radius: f64) -> f64 {
    SLIVER_ATOL_FACTOR * radius * radius
}

/// The combined relative + absolute area-agreement gate with a sliver floor
/// (B.5 / CONFORMANCE_SPEC.md §5.8.2):
///
/// ```text
/// |A_x − A_ref| ≤ atol + rtol·|A_ref|,   atol = 1e-15·radius²
/// ```
///
/// Sub-`atol` areas are snapped to zero first, so a "present-but-tiny" overlap and
/// an "absent" one **both pass** — the snapping / tie-break regime MUST NOT fail
/// conformance (§5.8.2). `rtol` is empirically calibrated to the **loosest** binding
/// pair (GeometryOps-vs-S2); Rust and Python share the S2 core and agree far
/// tighter. This is the Rust analogue of Python `geometry.area_tolerance_ok`, the
/// primitive that folds the Rust binding into the cross-binding tolerance gate.
pub fn area_tolerance_ok(area_x: f64, area_ref: f64, rtol: f64, radius: f64) -> bool {
    let atol = sliver_atol(radius);
    let a_x = if area_x.abs() <= atol { 0.0 } else { area_x };
    let a_ref = if area_ref.abs() <= atol {
        0.0
    } else {
        area_ref
    };
    (a_x - a_ref).abs() <= atol + rtol * a_ref.abs()
}

/// Orient a ring counter-clockwise (positive signed area).
fn orient_ccw(ring: &[(f64, f64)]) -> Vec<(f64, f64)> {
    if shoelace_signed_area(ring) < 0.0 {
        ring.iter().rev().copied().collect()
    } else {
        ring.to_vec()
    }
}

/// Is point `p` on or to the left of the directed edge `a → b`? (Inside test for
/// a counter-clockwise clip polygon.) Uses the 2-D cross product.
fn is_left_of(a: (f64, f64), b: (f64, f64), p: (f64, f64)) -> bool {
    let cross = (b.0 - a.0) * (p.1 - a.1) - (b.1 - a.1) * (p.0 - a.0);
    cross >= 0.0
}

/// Intersection of the segment `p → q` with the **infinite line** through the
/// clip edge `a → b` (the Sutherland–Hodgman edge clip). `None` when the segment
/// is parallel to the edge.
fn line_segment_clip(
    p: (f64, f64),
    q: (f64, f64),
    a: (f64, f64),
    b: (f64, f64),
) -> Option<(f64, f64)> {
    let r = (q.0 - p.0, q.1 - p.1);
    let s = (b.0 - a.0, b.1 - a.1);
    let denom = r.0 * s.1 - r.1 * s.0;
    if denom == 0.0 {
        return None;
    }
    // Parameter t along p→q where it meets the infinite line a–b.
    let t = ((a.0 - p.0) * s.1 - (a.1 - p.1) * s.0) / denom;
    Some((p.0 + t * r.0, p.1 + t * r.1))
}

#[cfg(test)]
mod tests {
    use super::*;

    const TOL: f64 = 1e-9;

    #[test]
    fn manifold_flag_round_trips() {
        for s in ["planar", "spherical", "geodesic"] {
            assert_eq!(Manifold::from_flag(s).unwrap().as_str(), s);
        }
        assert!(Manifold::from_flag("ellipsoidal").is_none());
        assert!(Manifold::from_flag("").is_none());
    }

    #[test]
    fn planar_clip_of_overlapping_unit_squares() {
        // [0,2]×[0,2] ∩ [1,3]×[1,3] = [1,2]×[1,2], area 1.
        let a = [(0.0, 0.0), (2.0, 0.0), (2.0, 2.0), (0.0, 2.0)];
        let b = [(1.0, 1.0), (3.0, 1.0), (3.0, 3.0), (1.0, 3.0)];
        let ring = intersect_polygon(&a, &b, Manifold::Planar).expect("planar clip");
        assert!(ring.len() >= 3, "expected a non-degenerate overlap ring");
        assert!(
            (shoelace_area(&ring) - 1.0).abs() < TOL,
            "area was {}",
            shoelace_area(&ring)
        );
    }

    #[test]
    fn planar_clip_of_disjoint_squares_is_empty() {
        let a = [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)];
        let b = [(5.0, 5.0), (6.0, 5.0), (6.0, 6.0), (5.0, 6.0)];
        let ring = intersect_polygon(&a, &b, Manifold::Planar).expect("planar clip");
        assert!(ring.is_empty());
        assert_eq!(shoelace_area(&ring), 0.0);
    }

    #[test]
    fn planar_clip_winding_insensitive() {
        // Same squares, clip wound clockwise — result must be unchanged.
        let a = [(0.0, 0.0), (2.0, 0.0), (2.0, 2.0), (0.0, 2.0)];
        let b_cw = [(1.0, 1.0), (1.0, 3.0), (3.0, 3.0), (3.0, 1.0)];
        let ring = intersect_polygon(&a, &b_cw, Manifold::Planar).expect("planar clip");
        assert!((shoelace_area(&ring) - 1.0).abs() < TOL);
    }

    #[cfg(not(target_arch = "wasm32"))]
    #[test]
    fn spherical_clip_of_octant_sectors_matches_analytic() {
        // Two quarter-hemisphere sectors; overlap is the lon∈[45,90] northern
        // sector = π/4 steradians (the s2bindings README example).
        let a = [(0.0, 0.0), (90.0, 0.0), (0.0, 90.0)];
        let b = [(45.0, 0.0), (135.0, 0.0), (45.0, 90.0)];
        let ring = intersect_polygon(&a, &b, Manifold::Spherical).expect("spherical clip");
        assert!(
            ring.len() >= 3,
            "expected a non-empty spherical overlap ring"
        );
        let area = spherical_area(&ring).expect("spherical area");
        assert!(
            (area - std::f64::consts::FRAC_PI_4).abs() < 1e-9,
            "spherical overlap area was {area}, expected π/4"
        );
    }

    #[cfg(not(target_arch = "wasm32"))]
    #[test]
    fn geodesic_manifold_uses_the_spherical_path() {
        let a = [(0.0, 0.0), (90.0, 0.0), (0.0, 90.0)];
        let b = [(45.0, 0.0), (135.0, 0.0), (45.0, 90.0)];
        let sph = intersect_polygon(&a, &b, Manifold::Spherical).expect("spherical");
        let geo = intersect_polygon(&a, &b, Manifold::Geodesic).expect("geodesic");
        assert_eq!(
            sph, geo,
            "geodesic clips along great circles, same as spherical"
        );
    }

    #[test]
    fn polygon_area_dispatches_on_manifold() {
        // The unit-overlap square: planar shoelace area 1.
        let ring = [(1.0, 1.0), (2.0, 1.0), (2.0, 2.0), (1.0, 2.0)];
        assert!((polygon_area(&ring, Manifold::Planar).unwrap() - 1.0).abs() < TOL);
        // A spherical octant triangle is π/2 steradians on the unit sphere.
        #[cfg(not(target_arch = "wasm32"))]
        {
            let octant = [(0.0, 0.0), (90.0, 0.0), (0.0, 90.0)];
            let area = polygon_area(&octant, Manifold::Spherical).unwrap();
            assert!(
                (area - std::f64::consts::FRAC_PI_2).abs() < 1e-9,
                "area {area}"
            );
        }
    }

    // §5.8.2 area-tolerance gate (mirrors Python `test_geometry_kernel.py`).
    #[test]
    fn tolerance_exact_match_passes() {
        assert!(area_tolerance_ok(1.0, 1.0, 1e-12, 1.0));
    }

    #[test]
    fn tolerance_sub_atol_slivers_are_zero() {
        // "present-but-tiny" and "absent" both pass: below the 1e-15 floor.
        assert!(area_tolerance_ok(1e-20, 0.0, 1e-12, 1.0));
        assert!(area_tolerance_ok(0.0, 1e-20, 1e-12, 1.0));
    }

    #[test]
    fn tolerance_gross_disagreement_fails() {
        assert!(!area_tolerance_ok(1.0, 2.0, 1e-9, 1.0));
    }

    #[test]
    fn tolerance_relative_band_scales_with_reference() {
        // A 1e-6 relative error passes at rtol 1e-5 but fails at rtol 1e-7.
        assert!(area_tolerance_ok(1.0 + 1e-6, 1.0, 1e-5, 1.0));
        assert!(!area_tolerance_ok(1.0 + 1e-6, 1.0, 1e-7, 1.0));
    }

    #[test]
    fn sliver_floor_scales_with_radius_squared() {
        assert_eq!(sliver_atol(1.0), 1e-15);
        assert!((sliver_atol(1000.0) - 1e-15 * 1e6).abs() < 1e-30);
    }
}
