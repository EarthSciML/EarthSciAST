//! Parse units, convert values between them, and check that an equation is
//! dimensionally consistent.

use earthsci_ast::{
    build_unit_env, convert_units, load_path, parse_equation, parse_unit,
    validate_equation_dimensions,
};
use earthsci_ast_api_examples::fixture;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // region: convert_units ops=parse_unit,convert_units
    let km = parse_unit("km")?;
    let m = parse_unit("m")?;
    assert_eq!(convert_units(2.5, &km, &m)?, 2500.0);

    // Incompatible dimensions are an error.
    assert!(convert_units(1.0, &km, &parse_unit("s")?).is_err());
    // endregion

    // region: validate_equation_dimensions ops=build_unit_env,validate_equation_dimensions
    let doc = load_path(fixture("decay.esm"))?;
    let model = &doc.models.as_ref().unwrap()["Decay"];
    let (env, failures) = build_unit_env(&model.variables);
    assert!(failures.is_empty());

    // half_life = log(2) / lambda: seconds on both sides.
    validate_equation_dimensions(&model.equations[1], &env)?;
    // half_life is in s but lambda is in 1/s.
    let wrong = parse_equation("half_life = lambda")?;
    let err = validate_equation_dimensions(&wrong, &env).unwrap_err();
    println!("{err}");
    assert!(err.to_string().contains("mismatch"));
    // endregion

    Ok(())
}
