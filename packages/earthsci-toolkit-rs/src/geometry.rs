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

/// Bridge to the s2geometry **Emscripten** module (s2bindings.rs `wasm/dist`) on
/// wasm. The native `s2bindings` crate compiles vendored abseil + s2geometry C++
/// and cannot target `wasm32-unknown-unknown`; the s2 wasm build is instead a
/// separate Emscripten ES module exposing a JS API. So on wasm the spherical
/// clip/area are delegated to that module through a small synchronous interface
/// the host installs on `globalThis.__earthsci_s2` (see `js/s2_interop.mjs`):
///
/// * `clip(a, b)` — flat `[lon,lat,…]` shells → flat `[lon,lat,…]` overlap-shell
///   vertices (holes dropped, empty for disjoint), degrees.
/// * `area(ring)` — flat `[lon,lat,…]` shell → steradians.
///
/// Going through `globalThis` keeps this crate free of any bundler/module-path
/// coupling (identical in node and the browser) and lets a missing module
/// surface as a clean [`GeometryError`] rather than a wasm instantiation
/// failure. The host awaits s2's async `load()` once and installs these sync
/// wrappers before running any spherical model.
#[cfg(all(target_arch = "wasm32", feature = "wasm"))]
mod s2_wasm {
    use super::GeometryError;
    use js_sys::{Float64Array, Function, Reflect};
    use wasm_bindgen::{JsCast, JsValue};

    fn flatten(v: &[(f64, f64)]) -> Vec<f64> {
        let mut out = Vec::with_capacity(v.len() * 2);
        for &(lon, lat) in v {
            out.push(lon);
            out.push(lat);
        }
        out
    }

    /// Resolve `globalThis.__earthsci_s2[name]` to a callable, plus the object to
    /// bind as `this`. A missing/undefined interface is the "s2 not wired" case.
    fn method(name: &str) -> Result<(JsValue, Function), GeometryError> {
        let global: JsValue = js_sys::global().into();
        let obj = Reflect::get(&global, &JsValue::from_str("__earthsci_s2"))
            .map_err(|_| GeometryError::new("globalThis lookup failed"))?;
        if obj.is_undefined() || obj.is_null() {
            return Err(GeometryError::new(
                "spherical/geodesic geometry on wasm needs the s2bindings module; \
                 call installS2() from js/s2_interop.mjs to set globalThis.__earthsci_s2",
            ));
        }
        let f = Reflect::get(&obj, &JsValue::from_str(name))
            .map_err(|_| GeometryError::new("s2 method lookup failed"))?
            .dyn_into::<Function>()
            .map_err(|_| {
                GeometryError::new(format!("globalThis.__earthsci_s2.{name} is not a function"))
            })?;
        Ok((obj, f))
    }

    pub(super) fn clip(
        a: &[(f64, f64)],
        b: &[(f64, f64)],
    ) -> Result<Vec<(f64, f64)>, GeometryError> {
        let (this, f) = method("clip")?;
        let fa = Float64Array::from(flatten(a).as_slice());
        let fb = Float64Array::from(flatten(b).as_slice());
        let res = f
            .call2(&this, fa.as_ref(), fb.as_ref())
            .map_err(|e| GeometryError::new(format!("s2 clip threw: {e:?}")))?;
        let flat = res
            .dyn_into::<Float64Array>()
            .map_err(|_| GeometryError::new("s2 clip did not return a Float64Array"))?
            .to_vec();
        Ok(flat.chunks_exact(2).map(|c| (c[0], c[1])).collect())
    }

    pub(super) fn area(ring: &[(f64, f64)]) -> Result<f64, GeometryError> {
        let (this, f) = method("area")?;
        let fr = Float64Array::from(flatten(ring).as_slice());
        let res = f
            .call1(&this, fr.as_ref())
            .map_err(|e| GeometryError::new(format!("s2 area threw: {e:?}")))?;
        res.as_f64()
            .ok_or_else(|| GeometryError::new("s2 area did not return a number"))
    }
}

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
    // Coerce both operands to their distinct-vertex rings BEFORE the backend
    // clip (esm-spec §8.6.1): a padded ring — e.g. an MPAS pentagon stored in a
    // hexagon-shaped `[cells, NVERT, 2]` slot with its final vertex repeated to
    // fill the rectangle — MUST be accepted and evaluated as the deduplicated
    // ring. Dedup happens here because backend tolerance differs (the planar
    // clip tolerates zero-length edges; S2 rejects them as "degenerate
    // (duplicate vertex)"), and the op's cross-binding contract cannot depend
    // on that. Mirrors the Julia `_as_ring` at the top of `intersect_polygon`.
    let a = as_ring(a, "poly_a")?;
    let b = as_ring(b, "poly_b")?;
    match manifold {
        Manifold::Spherical | Manifold::Geodesic => intersect_spherical(&a, &b),
        Manifold::Planar => Ok(intersect_planar_convex(&a, &b)),
    }
}

/// Drop consecutive duplicate vertices — INCLUDING the wrap pair (a closing
/// `ring[last] ≈ ring[0]` duplicate) — from a ring, leaving its `n` distinct
/// vertices with implicit closure. `allclose`-based (atol 1e-8, rtol 1e-5) so
/// the drop decisions match the Julia/Python siblings exactly. Mirrors the
/// Julia `_dedup_consecutive`.
fn dedup_consecutive(ring: &[(f64, f64)]) -> Vec<(f64, f64)> {
    let n = ring.len();
    if n <= 1 {
        return ring.to_vec();
    }
    let mut out: Vec<(f64, f64)> = Vec::with_capacity(n);
    out.push(ring[0]);
    for &pt in &ring[1..] {
        let last = *out.last().unwrap();
        if !allclose_pt(pt, last) {
            out.push(pt);
        }
    }
    if out.len() >= 2 && allclose_pt(out[0], *out.last().unwrap()) {
        out.pop();
    }
    out
}

/// Coerce a clip operand to its `n` *distinct* lon/lat vertices: drop
/// consecutive duplicates and a closing wrap pair ([`dedup_consecutive`]), then
/// require ≥3 distinct vertices — fewer is a degenerate ring, rejected. Mirrors
/// the Julia `_as_ring` (esm-spec §8.6.1).
fn as_ring(poly: &[(f64, f64)], who: &str) -> Result<Vec<(f64, f64)>, GeometryError> {
    let arr = dedup_consecutive(poly);
    if arr.len() < 3 {
        return Err(GeometryError::new(format!(
            "intersect_polygon {who} needs >=3 distinct vertices, got {}",
            arr.len()
        )));
    }
    Ok(arr)
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

/// On `wasm32` the native S2 C++ backend can't be linked, so a spherical clip is
/// delegated to the s2bindings Emscripten module via [`s2_wasm`] (the host must
/// have installed `globalThis.__earthsci_s2`). The planar path stays pure-Rust.
#[cfg(all(target_arch = "wasm32", feature = "wasm"))]
fn intersect_spherical(
    a: &[(f64, f64)],
    b: &[(f64, f64)],
) -> Result<Vec<(f64, f64)>, GeometryError> {
    s2_wasm::clip(a, b)
}

/// Without the `wasm` feature there is no JS-interop bridge (js-sys / wasm-bindgen
/// are off), so a spherical clip on wasm is a runtime error — the planar path
/// remains fully available.
#[cfg(all(target_arch = "wasm32", not(feature = "wasm")))]
fn intersect_spherical(
    _a: &[(f64, f64)],
    _b: &[(f64, f64)],
) -> Result<Vec<(f64, f64)>, GeometryError> {
    Err(GeometryError::new(
        "spherical/geodesic intersect_polygon on wasm requires the `wasm` feature \
         (which bridges to the s2bindings Emscripten module)",
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
    // Drop consecutive / wrap duplicate vertices the clip can emit (esm-spec
    // §8.6.1), so the returned overlap is `n` distinct vertices — matching the
    // Julia `_planar_clip`, which ends with `_dedup_consecutive`.
    dedup_consecutive(&output)
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
    // (On wasm32 a stub below returns a runtime GeometryError instead, the
    // same pattern as `polygon_area`, so the two public fns gate uniformly.)
    // Dedup consecutive / wrap duplicate vertices before the S2 constructor —
    // S2 rejects zero-length edges as degenerate (esm-spec §8.6.1). A ring with
    // fewer than 3 distinct vertices is a degenerate / empty clip: area 0.
    let ring = dedup_consecutive(ring);
    if ring.len() < 3 {
        return Ok(0.0);
    }
    let p = SphericalPolygon::from_lon_lat(&ring).map_err(|e| GeometryError::new(e.to_string()))?;
    Ok(p.area())
}

/// On wasm (with the `wasm` feature) `spherical_area` delegates to the
/// s2bindings Emscripten module via [`s2_wasm`]. It mirrors the native path's
/// dedup + degenerate-ring handling so a `< 3`-distinct-vertex ring is `0.0`
/// without ever crossing the JS boundary.
#[cfg(all(target_arch = "wasm32", feature = "wasm"))]
pub fn spherical_area(ring: &[(f64, f64)]) -> Result<f64, GeometryError> {
    let ring = dedup_consecutive(ring);
    if ring.len() < 3 {
        return Ok(0.0);
    }
    s2_wasm::area(&ring)
}

/// Without the `wasm` feature there is no JS-interop bridge, so `spherical_area`
/// on wasm is a runtime error — the stub keeps the public surface uniform.
#[cfg(all(target_arch = "wasm32", not(feature = "wasm")))]
pub fn spherical_area(_ring: &[(f64, f64)]) -> Result<f64, GeometryError> {
    Err(GeometryError::new(
        "spherical_area on wasm requires the `wasm` feature (which bridges to the \
         s2bindings Emscripten module)",
    ))
}

/// Unsigned `polygon_area` of an overlap ring under `manifold` — the imperative
/// **cross-check oracle** for the `polygon_area` `sum_product` FAQ (RFC §8.1).
/// Planar ⇒ shoelace / Gauss–Green; spherical / geodesic ⇒ the great-circle-edge
/// area in **steradians** (unit sphere) via `s2geometry`. A degenerate (< 3
/// vertex) ring — an empty clip — is `0.0`. The conservative-regridding assembly
/// ([`crate::regrid`]) now computes the build-once factor `A_ij` through the FAQ
/// ([`crate::area_faq::polygon_area_faq`]); this function is the same value that
/// FAQ encodes, kept as the independent oracle (mirrors Python `geometry.polygon_area`).
///
/// Target-agnostic: the spherical arm defers to [`spherical_area`], which is the
/// native S2 kernel off wasm and the s2bindings Emscripten bridge on wasm (a
/// runtime error only when the wasm `wasm` feature / s2 module is absent).
pub fn polygon_area(ring: &[(f64, f64)], manifold: Manifold) -> Result<f64, GeometryError> {
    match manifold {
        Manifold::Planar => Ok(shoelace_area(ring)),
        Manifold::Spherical | Manifold::Geodesic => spherical_area(ring),
    }
}

// --------------------------------------------------------------------------- //
// Polar-edge densification — opt-in pre-clip (RFC §B.4 / CONFORMANCE_SPEC §5.8.4)
// --------------------------------------------------------------------------- //

/// Default tolerance (degrees of latitude) for judging an edge to lie along a
/// parallel in [`densify_parallel_edges`]. Matches the Julia/Python kernels'
/// `lat_atol` default so the three bindings densify identical rings identically.
pub const DEFAULT_LAT_ATOL: f64 = 1e-9;

/// Subdivide each *parallel* edge (constant latitude) of a lon/lat `ring` into
/// great-circle segments at most `max_segment_deg` degrees of longitude wide,
/// inserting the intermediate vertices **on the parallel** (linear in lon/lat).
///
/// The `spherical` / `geodesic` manifolds model every polygon edge — the clip's
/// and the `polygon_area` FAQ's — as a **great-circle geodesic** (§5.8.4, RFC
/// §B.4). A lon/lat cell edge running along a parallel is a *small circle*, not a
/// great circle, so a single wide great-circle edge bows off the parallel and a
/// coarse polar cell carries a real area error: ≈4% for a 30° cell next to the
/// pole, ≈1% at 15°, scaling with the **square of the cell's longitude width**.
/// Replacing one wide parallel edge with many short great-circle chords that each
/// stay on the parallel drives that error toward zero — the standard mitigation
/// (XIOS) for coarse polar lon/lat grids.
///
/// This is an **opt-in pre-clip** step: apply it to each operand before
/// [`intersect_polygon`] (and the `polygon_area` FAQ) when polar accuracy
/// matters. It is **off by default** — nothing in the evaluator calls it — so the
/// default clip / area behaviour is unchanged. Only parallel edges are touched: a
/// meridian already lies on a great circle, and a slanted edge is not a parallel,
/// so both are returned whole. `max_segment_deg` must be positive; `lat_atol`
/// (degrees, default [`DEFAULT_LAT_ATOL`]) is the tolerance for judging an edge to
/// lie along a parallel. Returns the densified ring as `n` *distinct* `(lon, lat)`
/// vertices (implicit closure preserved). Mirrors Julia/Python
/// `densify_parallel_edges`.
pub fn densify_parallel_edges(
    ring: &[(f64, f64)],
    max_segment_deg: f64,
    lat_atol: f64,
) -> Result<Vec<(f64, f64)>, GeometryError> {
    // Reject a non-positive *or NaN* cap, matching the Julia/Python `> 0` guard
    // (`NaN > 0` is false there, so NaN is rejected — keep that branch explicit).
    if max_segment_deg <= 0.0 || max_segment_deg.is_nan() {
        return Err(GeometryError::new(format!(
            "densify_parallel_edges max_segment_deg must be positive, got {max_segment_deg}"
        )));
    }
    let r = as_distinct_ring(ring)?;
    let n = r.len();
    let mut out: Vec<(f64, f64)> = Vec::with_capacity(n);
    for i in 0..n {
        let (ax, ay) = r[i];
        let (bx, by) = r[(i + 1) % n];
        out.push((ax, ay));
        let dlon = bx - ax;
        if (ay - by).abs() <= lat_atol && dlon.abs() > max_segment_deg {
            // |dlon| > max_segment_deg ⇒ nseg ≥ 2, so ≥1 interior vertex is added.
            let nseg = (dlon.abs() / max_segment_deg).ceil() as usize;
            for k in 1..nseg {
                let t = k as f64 / nseg as f64;
                out.push((ax + t * dlon, ay + t * (by - ay)));
            }
        }
    }
    Ok(out)
}

/// numpy-`allclose`-style point comparison (`atol = 1e-8`, `rtol = 1e-5`, the
/// relative term scaled by `b`) — the closure-stripping test shared with the
/// Julia/Python `_as_ring` siblings.
fn allclose_pt(a: (f64, f64), b: (f64, f64)) -> bool {
    (a.0 - b.0).abs() <= 1e-8 + 1e-5 * b.0.abs() && (a.1 - b.1).abs() <= 1e-8 + 1e-5 * b.1.abs()
}

/// Coerce an input ring to its `n` *distinct* lon/lat vertices: drop a closing
/// duplicate final vertex (`ring[last] ≈ ring[0]`) so closure stays implicit,
/// then require ≥3 vertices. Mirrors the Julia/Python `_as_ring` coercion that
/// `densify_parallel_edges` applies before walking the edges.
fn as_distinct_ring(ring: &[(f64, f64)]) -> Result<&[(f64, f64)], GeometryError> {
    let r = if ring.len() >= 2 && allclose_pt(ring[0], ring[ring.len() - 1]) {
        &ring[..ring.len() - 1]
    } else {
        ring
    };
    if r.len() < 3 {
        return Err(GeometryError::new(format!(
            "densify_parallel_edges ring needs ≥3 distinct vertices, got {}",
            r.len()
        )));
    }
    Ok(r)
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

    // ----- §8.6.1 padded / degenerate operand rings -----

    #[test]
    fn planar_clip_accepts_padded_rings() {
        // Two squares each padded with repeated trailing vertices (the
        // rectangular-storage padding a mixed-valence mesh needs). The clip MUST
        // equal the deduplicated-ring clip: the [1.5,2.5]x[1.5,2.5] box, area 1.
        let a = [
            (0.5, 0.5),
            (2.5, 0.5),
            (2.5, 2.5),
            (0.5, 2.5),
            (0.5, 2.5), // padding: final vertex repeated once
        ];
        let b = [
            (1.5, 1.5),
            (3.5, 1.5),
            (3.5, 3.5),
            (1.5, 3.5),
            (1.5, 3.5), // padding: final vertex repeated twice
            (1.5, 3.5),
        ];
        let ring = intersect_polygon(&a, &b, Manifold::Planar).expect("padded planar clip");
        assert!(
            (shoelace_area(&ring) - 1.0).abs() < TOL,
            "area {}",
            shoelace_area(&ring)
        );
    }

    #[test]
    fn as_ring_rejects_sub_three_distinct() {
        // A ring collapsing to < 3 distinct vertices after dedup is degenerate.
        let degenerate = [(0.0, 0.0), (1.0, 1.0), (1.0, 1.0), (0.0, 0.0)];
        assert!(intersect_polygon(&degenerate, &degenerate, Manifold::Planar).is_err());
    }

    /// The pin-3 unblock: an MPAS-style padded ring (trailing duplicate
    /// vertices) MUST now clip in S2. Before the dedup coercion, S2 rejected the
    /// zero-length edge with "Edge N is degenerate (duplicate vertex)".
    #[cfg(not(target_arch = "wasm32"))]
    #[test]
    fn spherical_clip_accepts_padded_rings() {
        // The s2bindings octant example, each operand padded with a repeated
        // trailing vertex — the exact degenerate-edge input that failed before.
        let a = [(0.0, 0.0), (90.0, 0.0), (0.0, 90.0), (0.0, 90.0)];
        let b = [
            (45.0, 0.0),
            (135.0, 0.0),
            (45.0, 90.0),
            (45.0, 90.0),
            (45.0, 90.0),
        ];
        let ring = intersect_polygon(&a, &b, Manifold::Spherical)
            .expect("padded spherical clip must succeed (S2 no longer sees the degenerate edge)");
        assert!(
            ring.len() >= 3,
            "expected a non-empty spherical overlap ring"
        );
        let area = spherical_area(&ring).expect("spherical area");
        assert!(
            (area - std::f64::consts::FRAC_PI_4).abs() < 1e-9,
            "padded spherical overlap area was {area}, expected π/4"
        );
        // Identical to the unpadded rings' clip area.
        let a_u = [(0.0, 0.0), (90.0, 0.0), (0.0, 90.0)];
        let b_u = [(45.0, 0.0), (135.0, 0.0), (45.0, 90.0)];
        let ring_u = intersect_polygon(&a_u, &b_u, Manifold::Spherical).expect("unpadded");
        assert!((spherical_area(&ring).unwrap() - spherical_area(&ring_u).unwrap()).abs() < 1e-12);
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

    // ----- Polar-edge densification (RFC §B.4 / §5.8.4) -----
    //
    // The area oracle below is a **pure** spherical-excess fan (Van
    // Oosterom–Strackee) — the same great-circle-edge area model Python's pure
    // `polygon_area` uses, exact for great-circle edges. It needs NO s2bindings
    // backend, so the densification test runs on every target.

    fn lonlat_to_unit(lon_deg: f64, lat_deg: f64) -> (f64, f64, f64) {
        let lon = lon_deg.to_radians();
        let lat = lat_deg.to_radians();
        let cos_lat = lat.cos();
        (cos_lat * lon.cos(), cos_lat * lon.sin(), lat.sin())
    }

    fn triangle_excess(a: (f64, f64, f64), b: (f64, f64, f64), c: (f64, f64, f64)) -> f64 {
        let cross = (
            b.1 * c.2 - b.2 * c.1,
            b.2 * c.0 - b.0 * c.2,
            b.0 * c.1 - b.1 * c.0,
        );
        let triple = a.0 * cross.0 + a.1 * cross.1 + a.2 * cross.2;
        let dot_ab = a.0 * b.0 + a.1 * b.1 + a.2 * b.2;
        let dot_bc = b.0 * c.0 + b.1 * c.1 + b.2 * c.2;
        let dot_ca = c.0 * a.0 + c.1 * a.1 + c.2 * a.2;
        2.0 * triple.atan2(1.0 + dot_ab + dot_bc + dot_ca)
    }

    /// Pure spherical-excess area (steradians, unit sphere) via a great-circle
    /// fan triangulation — the backend-free oracle mirroring Python's pure
    /// `polygon_area` spherical body.
    fn spherical_excess_area(ring: &[(f64, f64)]) -> f64 {
        let n = ring.len();
        if n < 3 {
            return 0.0;
        }
        let v: Vec<(f64, f64, f64)> = ring
            .iter()
            .map(|&(lo, la)| lonlat_to_unit(lo, la))
            .collect();
        let mut total = 0.0;
        for i in 1..n - 1 {
            total += triangle_excess(v[0], v[i], v[i + 1]);
        }
        total.abs()
    }

    /// Closed-form true area of a lon/lat cell whose top and bottom run along
    /// parallels (the small-circle ground truth): `Δlon · (sin lat2 − sin lat1)`.
    fn true_cell_area(lon1: f64, lon2: f64, lat1: f64, lat2: f64) -> f64 {
        (lon2 - lon1).to_radians() * (lat2.to_radians().sin() - lat1.to_radians().sin())
    }

    #[test]
    fn densification_reduces_coarse_polar_cell_area_error() {
        // A 30°-wide coarse cell at high latitude.
        let cell = [(0.0, 60.0), (30.0, 60.0), (30.0, 80.0), (0.0, 80.0)];
        let a_true = true_cell_area(0.0, 30.0, 60.0, 80.0);
        let a_coarse = spherical_excess_area(&cell);
        let err_coarse = (a_coarse - a_true).abs() / a_true;
        // The undensified great-circle cell really is off by a few percent
        // (≈3.6% here — the ~4% the RFC quotes for a 30° polar cell).
        assert!(err_coarse > 0.02, "err_coarse was {err_coarse}");
        // Densify the parallels to ≤1° segments → the error collapses.
        let dense = densify_parallel_edges(&cell, 1.0, DEFAULT_LAT_ATOL).expect("densify");
        assert!(dense.len() > cell.len(), "vertices were inserted");
        let a_dense = spherical_excess_area(&dense);
        let err_dense = (a_dense - a_true).abs() / a_true;
        assert!(err_dense < err_coarse, "densification reduces the error");
        assert!(
            err_dense < 1e-3,
            "converges to the true area: err_dense {err_dense}"
        );
        // Monotone: finer densification ⇒ smaller error.
        let dense5 = densify_parallel_edges(&cell, 5.0, DEFAULT_LAT_ATOL).expect("densify");
        let err_5 = (spherical_excess_area(&dense5) - a_true).abs() / a_true;
        assert!(
            err_dense < err_5 && err_5 < err_coarse,
            "monotone densification: {err_dense} < {err_5} < {err_coarse}"
        );
    }

    #[test]
    fn densification_only_touches_parallel_edges_and_is_opt_in() {
        // Two meridian edges (constant lon) + two 1°-wide parallel edges.
        let quad = [(0.0, 0.0), (0.0, 10.0), (1.0, 10.0), (1.0, 0.0)];
        let dense = densify_parallel_edges(&quad, 0.5, DEFAULT_LAT_ATOL).expect("densify");
        // Only the two parallels split (1° > 0.5° ⇒ one interior point each); the
        // two 10° meridians are left whole — a meridian is already a great circle.
        assert_eq!(dense.len(), 4 + 2);
        // A cell already finer than the segment cap is unchanged.
        assert_eq!(
            densify_parallel_edges(&quad, 5.0, DEFAULT_LAT_ATOL)
                .unwrap()
                .len(),
            4
        );
        // Off-by-default opt-in: a non-positive cap is rejected.
        assert!(densify_parallel_edges(&quad, 0.0, DEFAULT_LAT_ATOL).is_err());
    }

    #[test]
    fn densified_vertices_stay_on_the_parallel() {
        // Inserted vertices lie exactly on the parallel (constant latitude).
        let cell = [(0.0, 70.0), (40.0, 70.0), (40.0, 71.0), (0.0, 71.0)];
        let dense = densify_parallel_edges(&cell, 10.0, DEFAULT_LAT_ATOL).expect("densify");
        // Every vertex shares a latitude with one of the two parallel edges.
        for &(_, lat) in &dense {
            assert!(
                (lat - 70.0).abs() < 1e-9 || (lat - 71.0).abs() < 1e-9,
                "vertex latitude {lat} is not on either parallel"
            );
        }
    }

    #[test]
    fn densify_strips_closing_duplicate_and_rejects_degenerate() {
        // An explicitly-closed quad (last vertex repeats the first) is coerced to
        // its 4 distinct vertices before densifying — matching Julia/Python `_as_ring`.
        let closed = [
            (0.0, 50.0),
            (20.0, 50.0),
            (20.0, 51.0),
            (0.0, 51.0),
            (0.0, 50.0),
        ];
        let dense = densify_parallel_edges(&closed, 5.0, DEFAULT_LAT_ATOL).expect("densify");
        // 4 distinct corners + 3 interior points on each of the two 20°-wide
        // parallels (20°/5° = 4 segments ⇒ 3 inserts each).
        assert_eq!(dense.len(), 4 + 3 + 3);
        // A ring with fewer than 3 distinct vertices is rejected.
        let degenerate = [(0.0, 0.0), (1.0, 0.0)];
        assert!(densify_parallel_edges(&degenerate, 1.0, DEFAULT_LAT_ATOL).is_err());
    }
}
