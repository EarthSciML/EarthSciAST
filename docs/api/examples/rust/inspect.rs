//! List a document's models and variables, and classify the variables.

use earthsci_ast::{
    SystemKind, VariableType, algebraic_unknowns, constant_parameters, is_ode_state, load_path,
    observed_unknowns, ode_states, system_kind,
};
use earthsci_ast_api_examples::fixture;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // region: inspect ops=ode_states,observed_unknowns,algebraic_unknowns,constant_parameters,is_ode_state,system_kind
    let doc = load_path(fixture("decay.esm"))?;
    let model = &doc.models.as_ref().unwrap()["Decay"];

    // Declared variables, in document order, with their declared type.
    for (name, var) in &model.variables {
        println!("{name}: {:?} [{}]", var.var_type, var.units.as_deref().unwrap_or(""));
    }
    assert_eq!(model.variables.keys().collect::<Vec<_>>(), ["N", "lambda", "half_life"]);
    assert_eq!(model.variables["lambda"].var_type, VariableType::Parameter);

    // Both N and half_life are declared `unknown`; their equations decide
    // the class. `D(N) = ...` makes N a state, `half_life = ...` makes
    // half_life an observed.
    assert_eq!(ode_states(model), ["N"]);
    assert_eq!(observed_unknowns(model), ["half_life"]);
    assert!(algebraic_unknowns(model).is_empty());
    assert_eq!(constant_parameters(model), ["lambda"]);
    assert!(is_ode_state(model, "N") && !is_ode_state(model, "half_life"));
    assert_eq!(system_kind(model), SystemKind::Ode);
    // endregion

    Ok(())
}
