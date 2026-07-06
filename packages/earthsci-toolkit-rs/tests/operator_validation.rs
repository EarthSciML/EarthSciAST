use earthsci_toolkit::*;

#[test]
fn test_invalid_operator_without_required_fields() {
    // Test that operator without required fields fails
    let operator_json = r#"{
        "operator_id": "dry_deposition"
    }"#;

    let result: Result<Operator, _> = serde_json::from_str(operator_json);
    assert!(
        result.is_err(),
        "Should fail without required needed_vars field"
    );
}

#[test]
fn test_schema_compliant_operator_succeeds() {
    // Test that schema-compliant JSON now works
    let schema_compliant_json = r#"{
        "operator_id": "dry_deposition",
        "needed_vars": ["wind_speed", "temperature"],
        "modifies": ["O3", "NO2"],
        "config": {},
        "description": "Dry deposition operator"
    }"#;

    let result: Result<Operator, _> = serde_json::from_str(schema_compliant_json);
    assert!(result.is_ok(), "Schema-compliant JSON should now succeed");

    let operator = result.unwrap();
    assert_eq!(operator.operator_id, "dry_deposition");
    assert_eq!(operator.needed_vars, vec!["wind_speed", "temperature"]);
    assert_eq!(
        operator.modifies,
        Some(vec!["O3".to_string(), "NO2".to_string()])
    );
}

#[test]
fn test_minimal_operator() {
    // Test minimal valid operator with only required fields
    let minimal_json = r#"{
        "operator_id": "simple_op",
        "needed_vars": ["var1"]
    }"#;

    let result: Result<Operator, _> = serde_json::from_str(minimal_json);
    assert!(result.is_ok(), "Minimal operator should succeed");

    let operator = result.unwrap();
    assert_eq!(operator.operator_id, "simple_op");
    assert_eq!(operator.needed_vars, vec!["var1"]);
    assert_eq!(operator.modifies, None);
    assert!(operator.reference.is_none());
    assert_eq!(operator.config, None);
    assert_eq!(operator.description, None);
}
