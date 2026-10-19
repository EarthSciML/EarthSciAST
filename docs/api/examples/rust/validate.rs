//! Validate a good document, then read the errors a bad one reports.

use earthsci_ast::{load_path, validate, validate_text};
use earthsci_ast_api_examples::fixture;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // region: validate ops=validate,validate_text
    let good = load_path(fixture("decay.esm"))?;
    let result = validate(&good);
    assert!(result.is_valid);
    assert!(result.schema_errors.is_empty() && result.structural_errors.is_empty());

    // invalid.esm is well-formed JSON that matches the schema, so it loads;
    // validation then reports the undeclared variable `k` as a structural
    // error. Validation returns a result object, it does not fail.
    let bad = load_path(fixture("invalid.esm"))?;
    let result = validate(&bad);
    assert!(!result.is_valid);
    for err in &result.structural_errors {
        println!("{}: [{:?}] {}", err.path, err.code, err.message);
    }
    assert!(result.structural_errors.iter().any(|e| e.message.contains("'k'")));

    // `validate_text` starts from the JSON text, so a document that does not
    // even load is reported in the same result shape instead of as an error.
    let text = std::fs::read_to_string(fixture("invalid.esm"))?;
    let from_text = validate_text(&text, None);
    assert!(!from_text.is_valid);
    let not_json = validate_text("{ \"esm\": ", None);
    assert!(!not_json.is_valid);
    // endregion

    Ok(())
}
