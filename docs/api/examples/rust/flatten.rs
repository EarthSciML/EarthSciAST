//! Flatten a coupled document into one system and list what it contains.

use earthsci_ast::{DocumentFormat, expression_names, flatten, load_path, print_math};
use earthsci_ast_api_examples::fixture;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // region: flatten ops=flatten,print_math
    let doc = load_path(fixture("coupled.esm"))?;
    let flat = flatten(&doc)?;

    // Every name is namespaced by its model.
    let states: Vec<&String> = flat.state_variables.keys().collect();
    let params: Vec<&String> = flat.parameters.keys().collect();
    println!("states: {states:?}\nparameters: {params:?}");
    assert_eq!(states, ["Heater.T", "Box.T_air"]);
    assert!(flat.parameters.contains_key("Heater.rate") && flat.parameters.contains_key("Box.k"));

    // The param_to_var coupling replaces the box's wall-temperature
    // parameter Box.T_wall with the heater's state Heater.T: the parameter
    // is gone, and the box's equation reads Heater.T instead.
    assert!(!flat.parameters.contains_key("Box.T_wall"));
    // LaTeX prints the dotted names more readably than Typst does.
    let latex: Vec<String> = flat
        .equations
        .iter()
        .map(|eq| {
            let eq = serde_json::to_value(eq).unwrap();
            print_math(&eq, &expression_names(&eq), DocumentFormat::Markdown)
        })
        .collect();
    for eq in &latex {
        println!("{eq}");
    }
    assert_eq!(latex.len(), 2);
    assert_eq!(
        latex[1],
        r"\frac{\mathrm{d} \mathit{Box}.T_{\mathrm{air}}}{\mathrm{d} t} = \mathit{Box}.k \left(\mathit{Heater}.T - \mathit{Box}.T_{\mathrm{air}}\right)"
    );
    // endregion

    Ok(())
}
