//! Schema validation error tests for invalid fixtures
//!
//! Tests that invalid ESM files properly fail schema validation with appropriate error messages.

use earthsci_ast::*;

/// Test that missing ESM version fails schema validation
#[test]
fn test_missing_esm_version_schema_error() {
    let fixture = include_str!("../../../tests/invalid/missing_esm_version.esm");

    let result = load(fixture);
    assert!(result.is_err());

    if let Err(EsmError::SchemaValidation(schema_err)) = result {
        // Should contain information about missing esm field
        assert!(schema_err.contains("esm") || schema_err.to_lowercase().contains("version"));
    } else {
        panic!("Expected schema validation error for missing ESM version");
    }
}

/// Test that missing required fields fail schema validation
#[test]
fn test_missing_required_fields_schema_error() {
    let fixture = include_str!("../../../tests/invalid/missing_required_fields.esm");

    let result = load(fixture);
    assert!(result.is_err());

    match result {
        Err(EsmError::SchemaValidation(_)) => {
            // Expected schema error
        }
        Err(other) => panic!("Expected schema error, got: {other:?}"),
        Ok(_) => panic!("Expected parsing to fail for missing required fields"),
    }
}

/// Test that wrong data types fail schema validation
#[test]
fn test_wrong_data_types_schema_error() {
    let fixture = include_str!("../../../tests/invalid/wrong_data_types.esm");

    let result = load(fixture);
    assert!(result.is_err());

    match result {
        Err(EsmError::SchemaValidation(_)) | Err(EsmError::JsonParse(_)) => {
            // Either schema or JSON parse error is acceptable for wrong data types
        }
        Err(other) => panic!("Expected schema/JSON parse error, got: {other:?}"),
        Ok(_) => panic!("Expected parsing to fail for wrong data types"),
    }
}

/// Test that invalid enum values fail schema validation
#[test]
fn test_invalid_enum_values_schema_error() {
    let fixture = include_str!("../../../tests/invalid/invalid_enum_values.esm");

    let result = load(fixture);
    assert!(result.is_err());
}

/// `empty_required_arrays.esm` is a STRUCTURAL defect, not a schema one: an
/// empty `authors` array is valid and so is an empty `equations` array, but a
/// model declaring an unknown with no defining equation is unbalanced
/// (esm-spec §4.9.4).
#[test]
fn test_empty_required_arrays_is_an_unbalanced_system() {
    let fixture = include_str!("../../../tests/invalid/empty_required_arrays.esm");

    let r = earthsci_ast::validate_complete(fixture, None);
    assert!(r.schema_errors.is_empty(), "{:?}", r.schema_errors);
    assert!(
        r.structural_errors.iter().any(|e| matches!(
            e.code,
            earthsci_ast::StructuralErrorCode::EquationCountMismatch
        )),
        "expected equation_count_mismatch, got {:?}",
        r.structural_errors
    );
}

/// Test various metadata validation errors
#[test]
fn test_metadata_validation_errors() {
    let fixtures = [
        (
            "missing_metadata",
            include_str!("../../../tests/invalid/missing_metadata.esm"),
        ),
        (
            "missing_metadata_name",
            include_str!("../../../tests/invalid/missing_metadata_name.esm"),
        ),
        (
            "invalid_date_format",
            include_str!("../../../tests/invalid/invalid_date_format.esm"),
        ),
        (
            "malformed_doi",
            include_str!("../../../tests/invalid/malformed_doi.esm"),
        ),
        (
            "invalid_url_format",
            include_str!("../../../tests/invalid/invalid_url_format.esm"),
        ),
        (
            "extra_metadata_fields",
            include_str!("../../../tests/invalid/extra_metadata_fields.esm"),
        ),
        (
            "invalid_metadata_types",
            include_str!("../../../tests/invalid/invalid_metadata_types.esm"),
        ),
        (
            "empty_reference_fields",
            include_str!("../../../tests/invalid/empty_reference_fields.esm"),
        ),
    ];

    for (name, fixture) in fixtures.iter() {
        let result = load(fixture);
        assert!(result.is_err(), "Expected {name} to fail validation");
    }
}

/// Test data SOURCE validation errors (esm 1.0.0: `data_loaders` became
/// `data_sources`, a source declares no variables, and the consuming parameter
/// carries the `update` that names it).
///
/// `data_source_undefined_reference.esm` is deliberately NOT here: from 1.0.0
/// it is schema-VALID and reaches structural validation, where
/// `structural_validation.rs` asserts its `data_source_undefined` finding.
#[test]
fn test_data_source_validation_errors() {
    let fixtures = [
        (
            "missing_kind",
            include_str!("../../../tests/invalid/data_source_missing_kind.esm"),
        ),
        (
            "missing_source",
            include_str!("../../../tests/invalid/data_source_missing_source.esm"),
        ),
        (
            "legacy_variables",
            include_str!("../../../tests/invalid/data_source_legacy_variables.esm"),
        ),
        (
            "legacy_spatial",
            include_str!("../../../tests/invalid/data_source_legacy_spatial.esm"),
        ),
        (
            "invalid_type",
            include_str!("../../../tests/invalid/data_source_invalid_type.esm"),
        ),
        (
            "config_schema_violation",
            include_str!("../../../tests/invalid/data_source_config_schema_violation.esm"),
        ),
        (
            "update_missing_shape",
            include_str!("../../../tests/invalid/data_source_update_missing_shape.esm"),
        ),
        (
            "binding_missing_file_variable",
            include_str!("../../../tests/invalid/data_source_binding_missing_file_variable.esm"),
        ),
    ];

    for (name, fixture) in fixtures.iter() {
        let result = load(fixture);
        assert!(
            result.is_err(),
            "Expected data loader {name} to fail validation"
        );
    }
}

/// Test version compatibility validation errors
#[test]
fn test_version_compatibility_validation_errors() {
    let fixtures = [
        (
            "invalid_version_string",
            include_str!("../../../tests/version_compatibility/invalid_version_string.esm"),
        ),
        (
            "missing_version_field",
            include_str!("../../../tests/version_compatibility/missing_version_field.esm"),
        ),
        (
            "malformed_version_number",
            include_str!("../../../tests/version_compatibility/malformed_version_number.esm"),
        ),
        (
            "version_with_prerelease",
            include_str!("../../../tests/version_compatibility/version_with_prerelease.esm"),
        ),
    ];

    for (name, fixture) in fixtures.iter() {
        let result = load(fixture);
        // Note: Some version compatibility issues might be warnings rather than hard errors
        // depending on implementation, but generally malformed versions should fail
        if name.contains("malformed") || name.contains("invalid") {
            assert!(result.is_err(), "Expected {name} to fail validation");
        }
    }
}

/// A document whose MAJOR version this library does not implement is rejected
/// (esm-libraries-spec §8), on BOTH sides of the supported major.
#[test]
fn test_major_version_rejection() {
    // Ahead of this library.
    let ahead =
        include_str!("../../../tests/version_compatibility/version_2_5_1_major_rejection.esm");
    assert!(
        load(ahead).is_err(),
        "Expected major version 2.x.x to be rejected"
    );

    // ...and behind it. esm 1.0.0 is a clean break with no deprecation path, so
    // a 0.x document is refused rather than half-read: its `state` / `observed`
    // / `discrete` variable types and its `data_loaders` block no longer mean
    // anything here.
    let behind = include_str!("../../../tests/version_compatibility/version_0_1_0_pre_break.esm");
    assert!(
        load(behind).is_err(),
        "Expected major version 0.x.x to be rejected"
    );
}

/// Test coupling validation errors
#[test]
fn test_coupling_validation_errors() {
    let fixtures = [
        (
            "circular_coupling",
            include_str!("../../../tests/invalid/circular_coupling.esm"),
        ),
        (
            "coupling_resolution_errors",
            include_str!("../../../tests/invalid/coupling_resolution_errors.esm"),
        ),
    ];

    for (name, fixture) in fixtures.iter() {
        let result = load(fixture);
        assert!(
            result.is_err(),
            "Expected coupling {name} to fail validation"
        );
    }
}

/// Test that a source-catalog document (top-level `data_sources` as the sole
/// block, no `models`/`reaction_systems`) validates and loads.
///
/// From esm 1.0.0 a source declares NO variables: the consuming parameter binds
/// a `file_variable` and owns the units, so the catalog is pure I/O.
#[test]
fn test_source_catalog_document_loads() {
    let fixture = r#"{
        "esm": "1.0.0",
        "metadata": { "name": "source-catalog" },
        "data_sources": {
            "MetData": {
                "kind": "grid",
                "source": {
                    "url_template": "https://example.org/data/{date:%Y%m%d}.nc"
                },
                "temporal": { "frequency": "PT1H", "file_period": "P1D" }
            }
        }
    }"#;

    let result = load(fixture);
    let esm = result.expect("source-catalog document should validate and load");
    let loaders = esm
        .data_sources
        .as_ref()
        .expect("source-catalog document must expose data_sources");
    assert_eq!(loaders.len(), 1);
    assert!(loaders.contains_key("MetData"));
    assert!(
        esm.models.is_none(),
        "loader-only document must not have a models block"
    );
}

/// Test comprehensive error coverage
#[test]
fn test_complete_error_coverage() {
    let fixture = include_str!("../../../tests/invalid/complete_error_coverage.esm");

    let result = load(fixture);
    assert!(
        result.is_err(),
        "Expected complete error coverage fixture to fail"
    );
}
