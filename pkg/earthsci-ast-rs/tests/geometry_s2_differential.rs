//! Differential test: the pure-Rust `s2rst` geometry kernel vs Google's C++
//! `s2geometry` (via `s2bindings`), on the two operations the
//! conservative-regridding path actually depends on — `polygon_area` and the
//! `intersect_polygon` overlap area (CONFORMANCE_SPEC.md §5.8).
//!
//! # Why this file exists
//!
//! §5.8.2 sets the cross-binding area tolerance from the **loosest** binding pair
//! (Julia/GeometryOps vs S2) and relies on Rust and Python agreeing far tighter
//! than that, because both run S2. Rust now runs a *port* of S2 rather than the
//! C++ original, so "both run S2" is an assertion that needs a test rather than a
//! comment. This is that test: it links BOTH kernels into one binary and diffs
//! them directly, so a regression in the port shows up here — as a geometry
//! failure with a named shape — instead of silently shifting a regridding weight
//! in a downstream conformance run.
//!
//! `s2bindings` is otherwise no longer a dependency of this crate (it needs a
//! CMake + abseil + OpenSSL C++ superbuild and cannot target wasm32), so the
//! whole file is behind the opt-in `s2-cpp` feature:
//!
//! ```text
//! cargo test --features s2-cpp --test geometry_s2_differential
//! ```
//!
//! Run it when bumping the pinned `s2rst` version, or when auditing the kernel.

#![cfg(feature = "s2-cpp")]

use earthsci_ast::geometry::{self, Manifold, area_tolerance_ok, sliver_atol};
use s2bindings::SphericalPolygon;

/// `rtol` for the s2rst-vs-C++ pair. This is NOT the §5.8.2 spec tolerance (which
/// is calibrated to the GeometryOps-vs-S2 pair): it is deliberately three orders
/// tighter, because two implementations of the *same* S2 algorithms must agree to
/// near floating-point noise. Loosening it is a signal worth investigating, not a
/// maintenance chore.
const RTOL: f64 = 1e-12;

/// Unit sphere: areas are steradians, so the §5.8.2 sliver floor is `1e-15·1²`.
const RADIUS: f64 = 1.0;

// --------------------------------------------------------------------------- //
// C++ reference kernel (the oracle)
// --------------------------------------------------------------------------- //

fn cpp_area(ring: &[(f64, f64)]) -> f64 {
    SphericalPolygon::from_lon_lat(ring)
        .expect("C++ S2 polygon construction")
        .area()
}

/// The C++ overlap area: clip, drop holes, then measure the shell — the exact
/// composition `geometry::intersect_polygon` + `geometry::polygon_area` performs,
/// so the two sides are compared end-to-end rather than op-by-op.
fn cpp_clip_area(a: &[(f64, f64)], b: &[(f64, f64)]) -> f64 {
    let pa = SphericalPolygon::from_lon_lat(a).expect("C++ S2 poly a");
    let pb = SphericalPolygon::from_lon_lat(b).expect("C++ S2 poly b");
    let clip = pa.intersection(&pb).expect("C++ S2 intersection");
    if clip.is_empty() {
        return 0.0;
    }
    let mut verts = Vec::new();
    for r in clip.rings() {
        if !r.is_hole {
            verts.extend(r.vertices);
        }
    }
    if verts.len() < 3 {
        return 0.0;
    }
    cpp_area(&verts)
}

// --------------------------------------------------------------------------- //
// Fixtures — the regimes §5.8 calls out as the ones that actually differ
// --------------------------------------------------------------------------- //

/// A lon/lat polygon ring: `(lon, lat)` vertices in degrees, implicitly closed.
type Ring = Vec<(f64, f64)>;

/// A named clip fixture: the pair of operand rings the two kernels are diffed on.
type ClipCase = (&'static str, Ring, Ring);

/// A lon/lat cell as a 4-vertex ring (the conservative-regridding operand shape).
fn quad(lon0: f64, lat0: f64, dlon: f64, dlat: f64) -> Ring {
    vec![
        (lon0, lat0),
        (lon0 + dlon, lat0),
        (lon0 + dlon, lat0 + dlat),
        (lon0, lat0 + dlat),
    ]
}

/// Single rings for the `polygon_area` diff. Spans the scales a regrid sees
/// (whole-octant down to a 0.1° cell) plus the two places a flat clip is wrong:
/// hard against the pole, and across the antimeridian.
fn area_fixtures() -> Vec<(&'static str, Ring)> {
    vec![
        (
            "octant triangle",
            vec![(0.0, 0.0), (90.0, 0.0), (0.0, 90.0)],
        ),
        ("30x30 mid-latitude quad", quad(10.0, 10.0, 30.0, 30.0)),
        ("1deg cell @ 40N", quad(-89.0, 40.0, 1.0, 1.0)),
        ("0.1deg cell @ 40N", quad(-89.0, 40.0, 0.1, 0.1)),
        ("polar quad @ 89N", quad(0.0, 89.0, 10.0, 1.0)),
        ("polar quad @ 89S", quad(0.0, -90.0, 10.0, 1.0)),
        (
            "antimeridian-spanning quad",
            vec![(179.0, 10.0), (-179.0, 10.0), (-179.0, 11.0), (179.0, 11.0)],
        ),
        ("equatorial band quad", quad(-30.0, -0.5, 60.0, 1.0)),
    ]
}

/// Operand pairs for the overlap-area diff.
fn clip_fixtures() -> Vec<ClipCase> {
    vec![
        (
            "two octant sectors",
            vec![(0.0, 0.0), (90.0, 0.0), (0.0, 90.0)],
            vec![(45.0, 0.0), (135.0, 0.0), (45.0, 90.0)],
        ),
        (
            "30x30 quads, corner overlap",
            quad(10.0, 10.0, 30.0, 30.0),
            quad(25.0, 25.0, 30.0, 30.0),
        ),
        (
            "1deg source vs 0.75deg target @ 40N",
            quad(-89.0, 40.0, 1.0, 1.0),
            quad(-88.6, 40.4, 0.75, 0.75),
        ),
        (
            "near-pole overlap @ 88N",
            quad(0.0, 88.0, 20.0, 2.0),
            quad(10.0, 88.5, 20.0, 1.5),
        ),
        (
            "antimeridian overlap",
            vec![(179.0, 10.0), (-179.0, 10.0), (-179.0, 11.0), (179.0, 11.0)],
            vec![(179.5, 10.2), (-179.5, 10.2), (-179.5, 10.8), (179.5, 10.8)],
        ),
        (
            "containment (target inside source)",
            quad(0.0, 0.0, 10.0, 10.0),
            quad(2.0, 2.0, 3.0, 3.0),
        ),
        (
            "near-tangent sliver",
            quad(0.0, 0.0, 1.0, 1.0),
            quad(0.9999, 0.9999, 1.0, 1.0),
        ),
        (
            "disjoint",
            quad(0.0, 0.0, 1.0, 1.0),
            quad(5.0, 5.0, 1.0, 1.0),
        ),
        (
            "edge-touching (shared boundary, zero overlap)",
            quad(0.0, 0.0, 1.0, 1.0),
            quad(1.0, 0.0, 1.0, 1.0),
        ),
    ]
}

// --------------------------------------------------------------------------- //
// The diffs
// --------------------------------------------------------------------------- //

#[test]
fn polygon_area_matches_cpp_s2() {
    for (name, ring) in area_fixtures() {
        let rust = geometry::spherical_area(&ring).expect("s2rst area");
        let cpp = cpp_area(&ring);
        assert!(
            area_tolerance_ok(rust, cpp, RTOL, RADIUS),
            "{name}: s2rst area {rust} vs C++ S2 {cpp} (abs diff {:.3e}, rtol {RTOL})",
            (rust - cpp).abs()
        );
    }
}

#[test]
fn overlap_area_matches_cpp_s2() {
    for (name, a, b) in clip_fixtures() {
        let ring = geometry::intersect_polygon(&a, &b, Manifold::Spherical).expect("s2rst clip");
        let rust = geometry::polygon_area(&ring, Manifold::Spherical).expect("s2rst overlap area");
        let cpp = cpp_clip_area(&a, &b);
        assert!(
            area_tolerance_ok(rust, cpp, RTOL, RADIUS),
            "{name}: s2rst overlap {rust} vs C++ S2 {cpp} (abs diff {:.3e}, rtol {RTOL})",
            (rust - cpp).abs()
        );
    }
}

#[test]
fn empty_and_nonempty_clips_agree_with_cpp_s2() {
    // Sharper than the area diff: the two kernels must make the SAME call about
    // whether an overlap exists at all — modulo the §5.8.2 sliver floor, where
    // "present-but-tiny" and "absent" are defined to be the same answer.
    for (name, a, b) in clip_fixtures() {
        let ring = geometry::intersect_polygon(&a, &b, Manifold::Spherical).expect("s2rst clip");
        let rust = geometry::polygon_area(&ring, Manifold::Spherical).expect("s2rst overlap area");
        let cpp = cpp_clip_area(&a, &b);
        let floor = sliver_atol(RADIUS);
        let (rust_present, cpp_present) = (rust > floor, cpp > floor);
        assert_eq!(
            rust_present, cpp_present,
            "{name}: s2rst says overlap-present={rust_present} (area {rust}), \
             C++ S2 says {cpp_present} (area {cpp}); both are above the {floor:e} sliver floor, \
             so this is a real disagreement about whether the cells overlap"
        );
    }
}

#[test]
fn geodesic_and_spherical_are_the_same_kernel_under_both_engines() {
    // §5.8.4: geodesic edges are great circles, so the two manifolds clip
    // identically — a property the port must preserve exactly, not to tolerance.
    for (_, a, b) in clip_fixtures() {
        let sph = geometry::intersect_polygon(&a, &b, Manifold::Spherical).expect("spherical");
        let geo = geometry::intersect_polygon(&a, &b, Manifold::Geodesic).expect("geodesic");
        assert_eq!(sph, geo);
    }
}
