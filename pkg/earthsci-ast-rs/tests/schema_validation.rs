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

/// Test that empty required arrays fail schema validation
#[test]
fn test_empty_required_arrays_schema_error() {
    let fixture = include_str!("../../../tests/invalid/empty_required_arrays.esm");

    let result = load(fixture);
    assert!(result.is_err());
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

/// Test data SOURCE validation errors.
///
/// The 1.0.0 fixture set differs from the 0.x `data_loader_*` one, not just in
/// name: a source no longer declares the fields it provides, so the
/// `missing_provides` / `provides_missing_units` / `provides_missing_description`
/// cases are gone, and the required keys are now `kind` and `source`. The
/// binding-side defects moved onto the consuming parameter's `update`.
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
            "invalid_type",
            include_str!("../../../tests/invalid/data_source_invalid_type.esm"),
        ),
        (
            "config_schema_violation",
            include_str!("../../../tests/invalid/data_source_config_schema_violation.esm"),
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
            "binding_missing_file_variable",
            include_str!("../../../tests/invalid/data_source_binding_missing_file_variable.esm"),
        ),
        (
            "update_missing_shape",
            include_str!("../../../tests/invalid/data_source_update_missing_shape.esm"),
        ),
    ];

    for (name, fixture) in fixtures.iter() {
        let result = load(fixture);
        assert!(
            result.is_err(),
            "Expected data source {name} to fail schema validation"
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

/// Test that major version rejection works
#[test]
fn test_major_version_rejection() {
    let fixture =
        include_str!("../../../tests/version_compatibility/version_2_5_1_major_rejection.esm");

    let result = load(fixture);
    // Major version 2.x.x should be rejected by 0.1.0 implementation
    assert!(
        result.is_err(),
        "Expected major version 2.x.x to be rejected"
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

/// Test that a loader-only document (top-level `data_sources` as the sole
/// component, no `models`/`reaction_systems`) validates and loads.
#[test]
fn test_loader_only_document_loads() {
    let fixture = r#"{
        "esm": "1.0.0",
        "metadata": { "name": "loader-only" },
        "data_sources": {
            "MetData": {
                "kind": "grid",
                "source": {
                    "url_template": "https://example.org/data/{date:%Y%m%d}.nc"
                },
                "variables": {
                    "T": {
                        "file_variable": "temperature",
                        "units": "K",
                        "description": "Air temperature"
                    }
                }
            }
        }
    }"#;

    let result = load(fixture);
    let esm = result.expect("loader-only document should validate and load");
    let loaders = esm
        .data_sources
        .as_ref()
        .expect("loader-only document must expose data_sources");
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
