#![cfg(not(target_arch = "wasm32"))]
//! Conservative-regridding **assembly** conformance for the Rust binding (bead
//! ess-my4.4.12; RFC `semiring-faq-unified-ir` §A.8 / Appendix B.5;
//! CONFORMANCE_SPEC.md §5.8).
//!
//! This is the Rust half of the M4 tolerance-based cross-binding gate: it
//! evaluates the end-to-end regridder ([`ConservativeRegridder`]) and asserts the
//! §5.8 contract in priority order —
//!
//! 1. **Invariants (exact anchors, §5.8.3)** — partition-of-unity `Σ_i W_ij = 1`
//!    (exact by construction) and global mass conservation
//!    `Σ_j A_j·F_tgt[j] = Σ_i A_i·F_src[i]`.
//! 2. **Per-pair areas / weights (tolerance, §5.8.2)** — each overlap area `A_ij`
//!    agrees with an **independent** reference within `atol + rtol·A_ref`, with the
//!    sliver floor. For the planar manifold the reference is the analytic overlap
//!    area; for the spherical manifold it is the closed-form Van Oosterom–Strackee
//!    spherical-excess of the **same** clipped ring — an independent oracle for the
//!    S2 area, so this exercises [`area_tolerance_ok`] on real clipped geometry.
//!
//! Rust and Python share the **same S2 core**, so they agree to a far tighter
//! `rtol` than either does with Julia/GeometryOps; the cross-binding spec
//! tolerance (calibrated to the loosest GeometryOps-vs-S2 pair) is owned by the
//! gate bead (`ess-my4.4.8`). The S2-vs-excess `rtol` used here is correspondingly
//! tight.

use earthsci_toolkit::geometry::{self, Manifold};
use earthsci_toolkit::{ConservativeRegridder, area_tolerance_ok};

// Tight tolerance for the exact invariants (partition-of-unity, conservation).
const INVARIANT_TOL: f64 = 1e-12;
// S2-vs-independent-excess area agreement (a tight same-S2-model pair).
const AREA_RTOL: f64 = 1e-9;

// --------------------------------------------------------------------------- //
// Planar gate — analytic overlap areas
// --------------------------------------------------------------------------- //

fn planar_cell(x0: f64, x1: f64, y0: f64, y1: f64) -> Vec<(f64, f64)> {
    vec![(x0, y0), (x1, y0), (x1, y1), (x0, y1)]
}

#[test]
fn planar_invariants_and_area_tolerance() {
    // Source: two unit cells [0,1]×[0,1], [1,2]×[0,1].
    // Target: [0,1.5]×[0,1], [1.5,2]×[0,1] — same domain, fractional overlaps.
    let src = vec![
        planar_cell(0.0, 1.0, 0.0, 1.0),
        planar_cell(1.0, 2.0, 0.0, 1.0),
    ];
    let tgt = vec![
        planar_cell(0.0, 1.5, 0.0, 1.0),
        planar_cell(1.5, 2.0, 0.0, 1.0),
    ];
    let r = ConservativeRegridder::build(&src, &tgt, Manifold::Planar).expect("build");

    // (1) Invariants: partition-of-unity and conservation.
    for (j, &pou) in r.partition_of_unity().iter().enumerate() {
        assert!(
            (pou - 1.0).abs() < INVARIANT_TOL,
            "target {j} partition-of-unity = {pou}, expected 1"
        );
    }
    let f_src = [2.0, 9.0];
    let f_tgt = r.apply(&f_src);
    assert!(
        (r.target_mass(&f_tgt) - r.source_mass(&f_src)).abs() < INVARIANT_TOL,
        "mass not conserved: tgt {} vs src {}",
        r.target_mass(&f_tgt),
        r.source_mass(&f_src)
    );
    // The meshes tile a common domain, so the covered source areas are the true
    // unit-cell areas → conservation is physical, not just by-construction.
    for (i, &ai) in r.source_areas().iter().enumerate() {
        assert!(
            (ai - 1.0).abs() < INVARIANT_TOL,
            "source {i} covered area {ai} != 1"
        );
    }

    // (2) Per-pair area tolerance against the analytic overlaps:
    //     A_00 = 1.0, A_10 = 0.5, A_11 = 0.5.
    let analytic = |i: usize, j: usize| -> f64 {
        match (i, j) {
            (0, 0) => 1.0,
            (1, 0) => 0.5,
            (1, 1) => 0.5,
            _ => 0.0,
        }
    };
    for ov in r.overlaps() {
        let reference = analytic(ov.src, ov.tgt);
        assert!(
            area_tolerance_ok(ov.area, reference, AREA_RTOL, 1.0),
            "A_{}{} = {} outside tolerance of analytic {reference}",
            ov.src,
            ov.tgt,
            ov.area
        );
    }
}

// --------------------------------------------------------------------------- //
// Spherical (S2) gate — invariants + S2-vs-excess area tolerance
// --------------------------------------------------------------------------- //

/// Lon-lat (degrees) → unit vector on the sphere.
fn unit(lon_deg: f64, lat_deg: f64) -> [f64; 3] {
    let lon = lon_deg.to_radians();
    let lat = lat_deg.to_radians();
    let cl = lat.cos();
    [cl * lon.cos(), cl * lon.sin(), lat.sin()]
}

/// Van Oosterom–Strackee signed solid angle of triangle `a,b,c` on the unit
/// sphere — exact for great-circle edges, so it matches an S2 area. Mirrors
/// Python `geometry._spherical_triangle_excess`.
fn triangle_excess(a: [f64; 3], b: [f64; 3], c: [f64; 3]) -> f64 {
    let cross = [
        b[1] * c[2] - b[2] * c[1],
        b[2] * c[0] - b[0] * c[2],
        b[0] * c[1] - b[1] * c[0],
    ];
    let triple = a[0] * cross[0] + a[1] * cross[1] + a[2] * cross[2];
    let dot = |u: [f64; 3], v: [f64; 3]| u[0] * v[0] + u[1] * v[1] + u[2] * v[2];
    2.0 * triple.atan2(1.0 + dot(a, b) + dot(b, c) + dot(c, a))
}

/// Independent spherical area (steradians) of a lon-lat ring via a great-circle
/// fan triangulation — the closed-form reference for the S2 `polygon_area`.
fn excess_area(ring: &[(f64, f64)]) -> f64 {
    if ring.len() < 3 {
        return 0.0;
    }
    let verts: Vec<[f64; 3]> = ring.iter().map(|&(lon, lat)| unit(lon, lat)).collect();
    let mut total = 0.0;
    for i in 1..verts.len() - 1 {
        total += triangle_excess(verts[0], verts[i], verts[i + 1]);
    }
    total.abs()
}

/// A spherical **sector** from the equator to the north pole, bounded by the
/// meridians `lon0` and `lon1` — the equator and both meridians are **great
/// circles**, so a meridian split is an *exact* great-circle cut shared by both
/// grids. This deliberately avoids the great-circle-edge modelling error of a
/// lat-lon parallel (RFC §B.4): a wide cell's parallel top-edge is a single
/// great-circle chord that does **not** equal the union of two narrower chords, so
/// a lat-lon source cell does **not** tile exactly into narrower target pieces.
/// Sectors have no parallel edges, so tiling-completeness is exact and the
/// physical-conservation anchor is testable. Shape mirrors the octant in
/// `geometry_conformance::public_spherical_clip_via_s2_and_area`.
fn sector(lon0: f64, lon1: f64) -> Vec<(f64, f64)> {
    vec![(lon0, 0.0), (lon1, 0.0), (lon0, 90.0)]
}

/// Area of an equator-to-pole sector of longitudinal width `width_deg` in
/// steradians: `(width / 360)·2π = width_rad`.
fn sector_area(width_deg: f64) -> f64 {
    width_deg.to_radians()
}

#[test]
fn spherical_invariants_and_area_tolerance() {
    // Source sectors S0=lon[0,40], S1=lon[40,80]; target sectors T0=lon[0,60],
    // T1=lon[60,80] — same hemisphere wedge. Overlaps: (0,0)=sector[0,40] (all of
    // S0), (1,0)=sector[40,60], (1,1)=sector[60,80]; T0 mixes S0 + part of S1.
    let src = vec![sector(0.0, 40.0), sector(40.0, 80.0)];
    let tgt = vec![sector(0.0, 60.0), sector(60.0, 80.0)];
    let r = ConservativeRegridder::build(&src, &tgt, Manifold::Spherical).expect("build");

    // (1) Invariants — the exact anchors (§5.8.3).
    for (j, &pou) in r.partition_of_unity().iter().enumerate() {
        assert!(
            (pou - 1.0).abs() < INVARIANT_TOL,
            "target {j} partition-of-unity = {pou}, expected 1"
        );
    }
    let f_src = [4.0, 11.0];
    let f_tgt = r.apply(&f_src);
    assert!(
        (r.target_mass(&f_tgt) - r.source_mass(&f_src)).abs() < INVARIANT_TOL,
        "spherical mass not conserved"
    );
    // Tiling completeness: covered source area == true source-cell area. Exact for
    // sectors (all great-circle edges); this is the physically meaningful half of
    // conservation (§5.8.3) that the lat-lon edge model would only satisfy
    // approximately (§B.4).
    for (i, &ai) in r.source_areas().iter().enumerate() {
        let true_area = geometry::polygon_area(&src[i], Manifold::Spherical).unwrap();
        assert!(
            (ai - true_area).abs() < 1e-9,
            "source {i} covered area {ai} != true area {true_area}"
        );
    }

    // (2) Per-pair area tolerance (§5.8.2): each S2 overlap area agrees with the
    //     independent Van Oosterom–Strackee excess of the same clipped ring AND
    //     with the analytic sector area.
    let analytic = |i: usize, j: usize| match (i, j) {
        (0, 0) => sector_area(40.0),
        (1, 0) => sector_area(20.0),
        (1, 1) => sector_area(20.0),
        _ => 0.0,
    };
    let mut survivors = 0;
    for ov in r.overlaps() {
        let ring =
            geometry::intersect_polygon(&src[ov.src], &tgt[ov.tgt], Manifold::Spherical).unwrap();
        assert!(
            area_tolerance_ok(ov.area, excess_area(&ring), AREA_RTOL, 1.0),
            "A_{}{} = {} outside tolerance of excess reference {}",
            ov.src,
            ov.tgt,
            ov.area,
            excess_area(&ring)
        );
        assert!(
            area_tolerance_ok(ov.area, analytic(ov.src, ov.tgt), AREA_RTOL, 1.0),
            "A_{}{} = {} outside tolerance of analytic {}",
            ov.src,
            ov.tgt,
            ov.area,
            analytic(ov.src, ov.tgt)
        );
        survivors += 1;
    }
    assert_eq!(
        survivors, 3,
        "expected 3 surviving overlaps, got {survivors}"
    );
}

#[test]
fn spherical_clip_crosses_antimeridian() {
    // A source band straddling the antimeridian (lon 170 → -170) must be clipped on
    // the sphere, not the plane (a flat clip would treat the seam as a 340° span and
    // produce garbage). S2 joins consecutive vertices by the *shorter* great-circle
    // arc, so the edge (170,·)→(-170,·) crosses the seam as a 20° arc — the band is
    // expressible with in-range longitudes, no >180° coordinate needed. The two
    // target halves T0=lon[170,180], T1=lon[-180,-170] each lie fully inside the
    // band, so each clip returns that target exactly — the spherical-correctness
    // adversarial case (§5.8.6).
    let src = vec![vec![
        (170.0, 0.0),
        (-170.0, 0.0),
        (-170.0, 20.0),
        (170.0, 20.0),
    ]];
    let tgt = vec![
        vec![(170.0, 0.0), (180.0, 0.0), (180.0, 20.0), (170.0, 20.0)],
        vec![(-180.0, 0.0), (-170.0, 0.0), (-170.0, 20.0), (-180.0, 20.0)],
    ];
    let r = ConservativeRegridder::build(&src, &tgt, Manifold::Spherical).expect("build");
    // Both target halves overlap the source band across the seam: two surviving
    // overlaps, each equal to its (fully contained) target's own area.
    assert_eq!(
        r.overlaps().len(),
        2,
        "antimeridian band should clip into 2 overlaps"
    );
    for ov in r.overlaps() {
        let tgt_area = geometry::polygon_area(&tgt[ov.tgt], Manifold::Spherical).unwrap();
        assert!(ov.area > 0.0, "antimeridian overlap area must be positive");
        assert!(
            area_tolerance_ok(ov.area, tgt_area, AREA_RTOL, 1.0),
            "seam overlap {} != contained target area {tgt_area}",
            ov.area
        );
    }
    // Partition-of-unity and by-construction conservation hold across the seam.
    for &pou in &r.partition_of_unity() {
        assert!((pou - 1.0).abs() < INVARIANT_TOL);
    }
    let f_tgt = r.apply(&[7.0]);
    assert!((r.target_mass(&f_tgt) - r.source_mass(&[7.0])).abs() < INVARIANT_TOL);
}
