//! Add a variable and an equation to a model, then serialize and write the
//! document.

use earthsci_ast::{
    ModelVariable, VariableType, add_equation, add_variable, load_path, load_string,
    parse_equation, remove_variable, to_json, write_path,
};
use earthsci_ast_api_examples::fixture;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // region: edit ops=add_variable,add_equation,to_json,write_path
    let mut doc = load_path(fixture("decay.esm"))?;
    let model = &doc.models.as_ref().unwrap()["Decay"];

    // Track the decay product M. Edits return a new model; the input is
    // left unchanged.
    let product = ModelVariable {
        var_type: VariableType::Unknown,
        units: Some("mol".to_string()),
        default: Some(0.0.into()),
        description: Some("Amount produced".to_string()),
        default_units: None,
        element_type: None,
        shape: None,
        location: None,
        distribution: None,
        update: None,
    };
    let model = add_variable(model, "M", product)?;
    let model = add_equation(&model, parse_equation("D(M)/Dt = lambda * N")?)?;
    assert_eq!(model.variables.len(), 4);
    assert_eq!(model.equations.len(), 3);

    // Adding a name that is already declared is an error.
    assert!(add_variable(&model, "N", model.variables["N"].clone()).is_err());

    doc.models.as_mut().unwrap().insert("Decay".to_string(), model);

    let json = to_json(&doc)?;
    assert!(json.contains("\"M\""));

    let out = std::env::temp_dir().join("decay_with_product.esm");
    write_path(&doc, &out)?;
    let reread = load_string(&std::fs::read_to_string(&out)?)?;
    assert_eq!(reread.models.as_ref().unwrap()["Decay"].variables.len(), 4);
    // endregion
    std::fs::remove_file(&out)?; // hide

    // region: remove_variable ops=remove_variable
    let model = &reread.models.as_ref().unwrap()["Decay"];
    let trimmed = remove_variable(model, "half_life")?;
    assert!(!trimmed.variables.contains_key("half_life"));
    // Removing a name that is not there is an error, not a no-op.
    assert!(remove_variable(&trimmed, "half_life").is_err());
    // endregion

    Ok(())
}
