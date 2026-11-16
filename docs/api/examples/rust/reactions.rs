//! Derive the ODEs of a reaction system and its stoichiometric matrix.

use earthsci_ast::{
    DocumentFormat, derive_odes, expression_names, load_path, ode_states, print_math,
    stoichiometric_matrix,
};
use earthsci_ast_api_examples::fixture;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // region: reactions ops=derive_odes,print_math
    let doc = load_path(fixture("ozone.esm"))?;
    let system = &doc.reaction_systems.as_ref().unwrap()["Ozone"];

    // derive_odes turns the reactions into an ordinary model: one
    // differential equation per species, with mass-action rate laws.
    let model = derive_odes(system)?;
    // Print them as LaTeX, which spells chemical names more readably than
    // Typst does.
    let latex: Vec<String> = model
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
    let mut states = ode_states(&model);
    states.sort();
    assert_eq!(states, ["NO", "NO2", "O3"]);
    assert_eq!(
        latex[2],
        r"\frac{\mathrm{d} \mathrm{NO_{2}}}{\mathrm{d} t} = \mathit{k1} \mathrm{NO} \mathrm{O_{3}} + -1 \left(\mathit{jNO2} \mathrm{NO_{2}}\right)"
    );
    assert_eq!(model.equations.len(), 3);
    // endregion

    // region: stoichiometric_matrix ops=stoichiometric_matrix
    // Rows are species in declaration order (O3, NO, NO2), columns reactions
    // (R1: NO + O3 -> NO2, R2: NO2 -> NO + O3).
    let s = stoichiometric_matrix(system);
    assert_eq!(s, [[-1.0, 1.0], [-1.0, 1.0], [1.0, -1.0]]);
    // endregion

    Ok(())
}
