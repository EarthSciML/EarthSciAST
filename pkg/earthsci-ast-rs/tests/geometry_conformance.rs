#![cfg(not(target_arch = "wasm32"))]
//! Geometry-kernel conformance for the Rust binding (bead ess-my4.4.11; RFC
//! `semiring-faq-unified-ir` §8.1, Appendix B.2; CONFORMANCE_SPEC.md §5.8).
//!
//! Folds the Rust binding into the shared geometry conformance set on two levels:
//!
//! * **Structural** — every `tests/{valid,invalid}/geometry/*.esm` fixture loads
//!   (valid) or is rejected at schema-validation (invalid) through the shared
//!   loader, mirroring the Go `geometry_fixtures_test.go` / TS
//!   `geometry-fixtures.test.ts` suites and the Rust aggregate-fixture tests.
//!   The invalid fixtures isolate a single `intersect_polygon` schema violation
//!   (missing `manifold`, a third operand, an out-of-enum `manifold`).
//!
//! * **Public kernel API** — `intersect_polygon` and the area oracles clip and
//!   measure real polygons (spherical → s2geometry via `s2bindings`, planar →
//!   Sutherland–Hodgman). The end-to-end FAQ evaluation through the array
//!   runtime lives in `simulate_array`'s `geometry_eval_tests`.

use std::path::PathBuf;

use earthsci_ast::geometry::{self, Manifold};
use earthsci_ast::load;

mod common;

fn geometry_fixture_dir(kind: &str) -> PathBuf {
    common::repo_fixture(kind).join("geometry")
}

fn esm_fixtures(dir: &PathBuf) -> Vec<PathBuf> {
    let mut files: Vec<PathBuf> = std::fs::read_dir(dir)
        .unwrap_or_else(|e| panic!("read_dir {dir:?}: {e}"))
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().and_then(|s| s.to_str()) == Some("esm"))
        .collect();
    files.sort();
    files
}

// ---------------------------------------------------------------------------
// Structural: fold the shared geometry fixtures into the Rust conformance set.
// ---------------------------------------------------------------------------

#[test]
fn valid_geometry_fixtures_load() {
    let dir = geometry_fixture_dir("valid");
    let files = esm_fixtures(&dir);
    assert!(
        !files.is_empty(),
        "no valid geometry fixtures under {dir:?}"
    );
    for path in &files {
        let json = std::fs::read_to_string(path).unwrap_or_else(|e| panic!("read {path:?}: {e}"));
        load(&json).unwrap_or_else(|e| {
            panic!(
                "{} should validate, got: {e}",
                path.file_name().unwrap().to_string_lossy()
            )
        });
    }
}

#[test]
fn invalid_geometry_fixtures_rejected() {
    let dir = geometry_fixture_dir("invalid");
    let files = esm_fixtures(&dir);
    assert!(
        !files.is_empty(),
        "no invalid geometry fixtures under {dir:?}"
    );
    for path in &files {
        let json = std::fs::read_to_string(path).unwrap_or_else(|e| panic!("read {path:?}: {e}"));
        assert!(
            load(&json).is_err(),
            "{} is a schema violation and must be rejected by the loader",
            path.file_name().unwrap().to_string_lossy()
        );
    }
}

// ---------------------------------------------------------------------------
// Public kernel API: clip + area oracles on real polygons.
// ---------------------------------------------------------------------------

#[test]
fn public_planar_clip_and_shoelace_area() {
    let a = [(0.0, 0.0), (2.0, 0.0), (2.0, 2.0), (0.0, 2.0)];
    let b = [(1.0, 1.0), (3.0, 1.0), (3.0, 3.0), (1.0, 3.0)];
    let ring = geometry::intersect_polygon(&a, &b, Manifold::Planar).expect("planar clip");
    assert!((geometry::shoelace_area(&ring) - 1.0).abs() < 1e-9);
}

#[test]
fn public_spherical_clip_via_s2_and_area() {
    // The s2bindings README example: two octant sectors overlap in π/4 sr.
    let a = [(0.0, 0.0), (90.0, 0.0), (0.0, 90.0)];
    let b = [(45.0, 0.0), (135.0, 0.0), (45.0, 90.0)];
    let ring = geometry::intersect_polygon(&a, &b, Manifold::Spherical).expect("spherical clip");
    assert!(ring.len() >= 3, "s2 spherical clip should be non-empty");
    let area = geometry::spherical_area(&ring).expect("spherical area");
    assert!(
        (area - std::f64::consts::FRAC_PI_4).abs() < 1e-9,
        "area {area}"
    );
}

#[test]
fn public_geodesic_matches_spherical() {
    // §5.8.4: geodesic edges are great circles, so they clip via the same S2
    // path as spherical (compared same-manifold only).
    let a = [(10.0, 10.0), (40.0, 10.0), (40.0, 40.0), (10.0, 40.0)];
    let b = [(25.0, 25.0), (55.0, 25.0), (55.0, 55.0), (25.0, 55.0)];
    let sph = geometry::intersect_polygon(&a, &b, Manifold::Spherical).expect("spherical");
    let geo = geometry::intersect_polygon(&a, &b, Manifold::Geodesic).expect("geodesic");
    assert_eq!(sph, geo);
}
