//! Derive the ODEs of a reaction system and its stoichiometric matrix.

use earthsci_ast::{derive_odes, load_path, ode_states, stoichiometric_matrix, to_ascii};
use earthsci_ast_api_examples::fixture;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // region: reactions ops=derive_odes
    let doc = load_path(fixture("ozone.esm"))?;
    let system = &doc.reaction_systems.as_ref().unwrap()["Ozone"];

    // derive_odes turns the reactions into an ordinary model: one
    // differential equation per species, with mass-action rate laws.
    let model = derive_odes(system)?;
    for eq in &model.equations {
        println!("{}", to_ascii(eq));
    }
    let mut states = ode_states(&model);
    states.sort();
    assert_eq!(states, ["NO", "NO2", "O3"]);
    let no2 = model.equations.iter().find(|eq| to_ascii(&eq.lhs) == "D(NO2)/Dt").unwrap();
    assert_eq!(to_ascii(&no2.rhs), "k1 * NO * O3 + -1 * jNO2 * NO2");
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
