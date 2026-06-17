//! Conformance: grid_dispatch discretization variants (RFC §7.8, esm-fpb).
//!
//! Verifies the Rust binding parses and schema-validates the PPM
//! grid_dispatch fixture and rejects the structural authoring errors the
//! schema forbids: parent grid_family alongside grid_dispatch, an inline
//! body alongside grid_dispatch, and a variant missing its grid_family.

use earthsci_toolkit::{EsmError, load};

const FIXTURE: &str = include_str!("../../../tests/discretizations/grid_dispatch_ppm.esm");

#[test]
fn grid_dispatch_fixture_loads_and_validates() {
    let parsed = load(FIXTURE).expect("PPM grid_dispatch fixture must load and validate");
    assert_eq!(parsed.esm, "0.3.0");
    assert_eq!(parsed.metadata.name.as_deref(), Some("PpmGridDispatch"));
}

#[test]
fn grid_dispatch_with_parent_grid_family_is_rejected() {
    let doc: serde_json::Value = serde_json::from_str(FIXTURE).unwrap();
    let mut doc = doc;
    doc["discretizations"]["ppm_advection"]["grid_family"] = serde_json::json!("cartesian");
    let bad = serde_json::to_string(&doc).unwrap();
    match load(&bad) {
        Err(EsmError::SchemaValidation(_)) => {}
        other => panic!("expected SchemaValidation error, got {other:?}"),
    }
}

#[test]
fn grid_dispatch_with_inline_stencil_is_rejected() {
    let doc: serde_json::Value = serde_json::from_str(FIXTURE).unwrap();
    let mut doc = doc;
    doc["discretizations"]["ppm_advection"]["stencil"] = serde_json::json!([
        { "selector": { "kind": "cartesian", "axis": "$x", "offset": 0 }, "coeff": 1 }
    ]);
    let bad = serde_json::to_string(&doc).unwrap();
    match load(&bad) {
        Err(EsmError::SchemaValidation(_)) => {}
        other => panic!("expected SchemaValidation error, got {other:?}"),
    }
}

#[test]
fn grid_dispatch_variant_missing_grid_family_is_rejected() {
    let doc: serde_json::Value = serde_json::from_str(FIXTURE).unwrap();
    let mut doc = doc;
    doc["discretizations"]["ppm_advection"]["grid_dispatch"][0]
        .as_object_mut()
        .unwrap()
        .remove("grid_family");
    let bad = serde_json::to_string(&doc).unwrap();
    match load(&bad) {
        Err(EsmError::SchemaValidation(_)) => {}
        other => panic!("expected SchemaValidation error, got {other:?}"),
    }
}
