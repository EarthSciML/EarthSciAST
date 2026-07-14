//! Units tests
//!
//! Parsing, dimensional consistency, and conversion tests for the units module.
//! Consolidated from `basic_functionality::test_units` and
//! `analysis_features::test_units_functionality`.

use earthsci_ast::*;
use std::collections::HashMap;
use std::path::PathBuf;

mod common;

fn fixture_path(name: &str) -> PathBuf {
    common::repo_fixture(&format!("valid/{name}"))
}

#[test]
fn parse_basic() {
    parse_unit("m").expect("Failed to parse m");
    parse_unit("cm").expect("Failed to parse cm");
}

#[test]
fn parse_compound() {
    parse_unit("m/s").expect("Failed to parse m/s");
    parse_unit("mol/L").expect("Failed to parse mol/L");
}

#[test]
fn dimensional_consistency_pass() {
    let m = parse_unit("m").expect("Failed to parse m");
    let cm = parse_unit("cm").expect("Failed to parse cm");
    check_dimensional_consistency(&m, &cm).expect("m and cm should be dimensionally consistent");
}

#[test]
fn dimensional_consistency_fail() {
    let m_per_s = parse_unit("m/s").expect("Failed to parse m/s");
    let mol_per_l = parse_unit("mol/L").expect("Failed to parse mol/L");
    assert!(
        check_dimensional_consistency(&m_per_s, &mol_per_l).is_err(),
        "Should detect dimensional inconsistency between m/s and mol/L"
    );
}

#[test]
fn convert_same_dimension() {
    let m = parse_unit("m").expect("Failed to parse m");
    let cm = parse_unit("cm").expect("Failed to parse cm");
    let conversion = convert_units(1.0, &m, &cm).expect("Failed to convert m to cm");
    assert!(
        (conversion - 100.0).abs() < 1e-10,
        "1 m should equal 100 cm"
    );
}

#[test]
fn convert_cross_dimension_fails() {
    let m_per_s = parse_unit("m/s").expect("Failed to parse m/s");
    let mol_per_l = parse_unit("mol/L").expect("Failed to parse mol/L");
    assert!(
        convert_units(1.0, &m_per_s, &mol_per_l).is_err(),
        "Converting m/s to mol/L should fail"
    );
}

/// Canonical bead example: given `h` with units `m` and `v` with units `m/s`,
/// verify that `D(h) ~ v` is dimensionally consistent via expression-level
/// propagation.
///
/// `t` is DECLARED here: an undeclared independent variable leaves the
/// derivative's dimension indeterminate (no time unit is assumed), in which case
/// only the weaker time-ratio rule applies.
#[test]
fn propagate_dh_equals_v() {
    let mut env: HashMap<String, Unit> = HashMap::new();
    env.insert("h".to_string(), parse_unit("m").unwrap());
    env.insert("v".to_string(), parse_unit("m/s").unwrap());
    env.insert("t".to_string(), parse_unit("s").unwrap());

    let dh = Expr::Operator(ExpressionNode {
        op: "D".to_string(),
        args: vec![Expr::Variable("h".to_string())],
        wrt: Some("t".to_string()),
        ..ExpressionNode::default()
    });

    let eq = Equation {
        lhs: dh,
        rhs: Expr::Variable("v".to_string()),
    };

    validate_equation_dimensions(&eq, &env).expect("D(h)/dt should match v (both are m/s)");
}

/// Loading the fixture `units_propagation.esm` and validating it should
/// surface no dimensional warnings — all observed-variable expressions have
/// matching declared units.
#[test]
fn validate_units_propagation_fixture_warning_free() {
    let path = fixture_path("units_propagation.esm");
    let json = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("failed to read {}: {}", path.display(), e));

    let result = validate_complete(&json);
    let dim_warnings: Vec<_> = result
        .unit_warnings
        .iter()
        .filter(|w| w.contains("Dimension mismatch"))
        .collect();
    assert!(
        dim_warnings.is_empty(),
        "Fixture should be dimensionally consistent; got: {dim_warnings:?}"
    );
}

// ESM-specific units standard (docs/units-standard.md): every binding must
// accept these and agree on dimensions so cross-binding documents resolve
// identically.

#[test]
fn esm_mole_fraction_family_is_dimensionless() {
    for unit_str in &["ppm", "ppmv", "ppb", "ppbv", "ppt", "pptv"] {
        let u = parse_unit(unit_str).unwrap_or_else(|e| panic!("Failed to parse {unit_str}: {e}"));
        assert!(
            u.is_dimensionless(),
            "{unit_str} should be dimensionless per ESM standard"
        );
    }
    // Aliases must share dimension with their base form — cross-binding
    // agreement depends on `ppmv + ppm` not flagging a mismatch.
    assert!(
        parse_unit("ppm")
            .unwrap()
            .is_compatible(&parse_unit("ppmv").unwrap())
    );
    assert!(
        parse_unit("ppb")
            .unwrap()
            .is_compatible(&parse_unit("ppbv").unwrap())
    );
    assert!(
        parse_unit("ppt")
            .unwrap()
            .is_compatible(&parse_unit("pptv").unwrap())
    );
}

#[test]
fn esm_mol_per_mol_is_dimensionless() {
    let u = parse_unit("mol/mol").expect("Failed to parse mol/mol");
    assert!(u.is_dimensionless(), "mol/mol must be dimensionless");
    assert!(u.is_compatible(&parse_unit("ppm").unwrap()));
}

#[test]
fn esm_molec_count_atom_composes() {
    // `molec` is a dimensionless count atom; the composite `molec/cm^3` is
    // what actually carries dimension in the ESM standard.
    let molec = parse_unit("molec").expect("Failed to parse molec");
    assert!(molec.is_dimensionless());

    let num_density = parse_unit("molec/cm^3").expect("Failed to parse molec/cm^3");
    // Equivalent to `1/cm^3`, i.e. inverse-volume (Length^-3).
    let inv_volume = parse_unit("1/cm^3").unwrap_or_else(|_| {
        // The existing parser may not accept "1/cm^3"; fall back to m^-3.
        parse_unit("cm^3").unwrap().power(-1)
    });
    assert!(
        num_density.is_compatible(&inv_volume),
        "molec/cm^3 should be dimensionally equivalent to 1/cm^3"
    );
}

#[test]
fn esm_dobson_is_areal_number_density() {
    let dobson = parse_unit("Dobson").expect("Failed to parse Dobson");
    // Standard: NOT dimensionless — Length^-2 (since molec is a count atom).
    assert!(
        !dobson.is_dimensionless(),
        "Dobson must not be dimensionless"
    );
    let molec_per_m2 = parse_unit("molec/m^2").expect("Failed to parse molec/m^2");
    assert!(
        dobson.is_compatible(&molec_per_m2),
        "Dobson should be dimensionally equivalent to molec/m^2"
    );
    // DU is an alias for Dobson.
    let du = parse_unit("DU").expect("Failed to parse DU");
    assert!(du.is_compatible(&dobson));
}
