//! Flatten a coupled document into one system and list what it contains.

use earthsci_ast::{flatten, load_path, to_ascii};
use earthsci_ast_api_examples::fixture;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // region: flatten ops=flatten
    let doc = load_path(fixture("coupled.esm"))?;
    let flat = flatten(&doc)?;

    // Every name is namespaced by its model.
    let states: Vec<&String> = flat.state_variables.keys().collect();
    let params: Vec<&String> = flat.parameters.keys().collect();
    println!("states: {states:?}\nparameters: {params:?}");
    assert_eq!(states, ["Heater.T", "Box.T_air"]);
    assert!(flat.parameters.contains_key("Heater.rate") && flat.parameters.contains_key("Box.k"));

    // The variable_map coupling substitutes the heater's state Heater.T
    // wherever the box read its wall temperature Box.T_wall.
    for eq in &flat.equations {
        println!("{}", to_ascii(eq));
    }
    assert_eq!(flat.equations.len(), 2);
    let box_eq = to_ascii(&flat.equations[1]);
    assert_eq!(box_eq, "D(Box.T_air)/Dt = Box.k * (Heater.T - Box.T_air)");
    // endregion

    Ok(())
}
