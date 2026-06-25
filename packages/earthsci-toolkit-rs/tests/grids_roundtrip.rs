//! Round-trip tests for §6 grids top-level schema support (gt-5kq3).
//!
//! Loads each conformance fixture under `tests/grids/`, serializes it back,
//! and asserts JSON-value equality after normalizing both sides through
//! `serde_json::Value`. A final test mutates one fixture in-memory to point
//! at a missing loader and asserts the parser rejects it.

use earthsci_toolkit::{EsmFile, load, save};
use serde_json::Value;

/// Recursively normalize all JSON numbers to floats, so integer-literal
/// `64` compares equal to float-serialized `64.0` (the `Parameter.default`
/// field in the types module is `Option<f64>`, which normalizes integer
/// inputs to floats on serialize — that is pre-existing behavior across
/// the crate, not specific to grids).
fn normalize_numbers(v: &mut Value) {
    match v {
        Value::Number(n) => {
            if let Some(f) = n.as_f64() {
                *n = serde_json::Number::from_f64(f).unwrap_or_else(|| n.clone());
            }
        }
        Value::Array(arr) => arr.iter_mut().for_each(normalize_numbers),
        Value::Object(map) => map.values_mut().for_each(normalize_numbers),
        _ => {}
    }
}

/// Load a fixture, save it, reparse, and assert structural JSON equality.
fn assert_roundtrip(fixture: &str) {
    let parsed: EsmFile = load(fixture).expect("fixture should load cleanly");
    let serialized = save(&parsed).expect("serialization should succeed");

    // Compare as `serde_json::Value` so key ordering and whitespace don't
    // matter; the fixture retains at least `esm`, `metadata`, `models`, and
    // `grids` sections through the round-trip.
    let mut original: Value = serde_json::from_str(fixture).expect("fixture is valid JSON");
    let mut reparsed: Value = serde_json::from_str(&serialized).expect("output is valid JSON");
    normalize_numbers(&mut original);
    normalize_numbers(&mut reparsed);

    // The `grids` section must be preserved verbatim (modulo int/float
    // normalization of Parameter.default) — that is the acceptance
    // criterion for gt-5kq3.
    assert_eq!(
        original.get("grids"),
        reparsed.get("grids"),
        "grids section must round-trip unchanged"
    );

    // Sanity: re-loading the serialized form must succeed.
    let _: EsmFile = load(&serialized).expect("reparse after save should succeed");
}

#[test]
fn roundtrip_cartesian() {
    let fixture = include_str!("../../../tests/grids/cartesian_uniform.esm");
    assert_roundtrip(fixture);
}

#[test]
fn roundtrip_unstructured() {
    let fixture = include_str!("../../../tests/grids/unstructured_mpas.esm");
    assert_roundtrip(fixture);
}

/// A projected native grid: family `"cartesian"` with a `lambert_conformal`
/// `crs` (WRF parameters, spherical datum). Asserts the `crs` descriptor
/// survives the round-trip verbatim (ess-v9a.2).
#[test]
fn roundtrip_lambert_conformal() {
    let fixture = include_str!("../../../tests/grids/lambert_conformal.esm");
    assert_roundtrip(fixture);
}

/// Rewriting the MPAS connectivity loader name to something not in
/// `data_loaders` must cause `load` to fail (unknown-loader reference per
/// §6.4 wiring).
#[test]
fn rejects_unknown_loader() {
    let fixture = include_str!("../../../tests/grids/unstructured_mpas.esm");
    let mutated = fixture.replace(
        "\"loader\": \"mpas_mesh\"",
        "\"loader\": \"does_not_exist\"",
    );
    assert_ne!(
        fixture, mutated,
        "test mutation must actually change the fixture"
    );

    let err = load(&mutated).expect_err("load should reject unknown loader");
    let msg = format!("{err}");
    assert!(
        msg.contains("does_not_exist") || msg.contains("unknown data_loader"),
        "error should mention the bad loader name: got {msg}"
    );
}
