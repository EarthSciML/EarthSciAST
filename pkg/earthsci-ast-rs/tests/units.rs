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

    let result = validate_complete(&json, None);
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

/// Every distinct `units` string that appears in the shared VALID corpus
/// (`tests/valid/**`, harvested exhaustively), plus the unicode/whitespace
/// spellings the normalizer must fold.
///
/// This list is the contract that makes an unparseable unit a HARD ERROR safe:
/// once a unit string that does not resolve is a `unit_parse_error`, ANY gap in
/// the registry stops being a silent "dimension unknown, skip the check" and
/// becomes a REJECTION of a legitimate file. Rust previously could not read
/// `mg ug um nm atm degC °C Hz V bar rad yr mL BTU kWh erg Torr psi C F T` —
/// all real units, all in valid fixtures — so this guard is what keeps the
/// severity promotion honest.
const CORPUS_VALID_UNITS: &[&str] = &[
    "1",
    "1/(atm*s)",
    "1/(cm^3*s)",
    "1/K",
    "1/day",
    "1/h",
    "1/m^3",
    "1/min",
    "1/s",
    "1/year",
    "BTU",
    "C",
    "F/m",
    "Hz",
    "J",
    "J/(K*m*s)",
    "J/(kg*K)",
    "J/(m^2*K)",
    "J/(mol*K)",
    "J/K",
    "J/m^3",
    "J/mol",
    "K",
    "K*m^3/(kg*s)",
    "K/m",
    "K/s",
    "L",
    "L/(mol*s)",
    "L/h",
    "L/mol/s",
    "L^2/mol^2/s",
    "N",
    "N*s/m",
    "N/m",
    "N/m^3",
    "Pa",
    "Pa*s",
    "Pa/s",
    "T",
    "Torr",
    "V",
    "V*s",
    "V/m",
    "W/(m^2*K^4)",
    "W/m^2",
    "W/m^3",
    "atm",
    "bar",
    "cal",
    "cm",
    "cm^3",
    "day",
    "degC",
    "degF",
    "dimensionless",
    "dm^3",
    "erg",
    "g/(s*km^2)",
    "g/(s*m^2)",
    "g/m^2",
    "h",
    "individuals",
    "individuals/km^2",
    "kJ/(mol*K)",
    "kJ/mol",
    "kWh",
    "kcal",
    "kg",
    "kg*m/s",
    "kg*m/s^2",
    "kg*m^2/s^2",
    "kg*m^2/s^3",
    "kg/(m^2*s)",
    "kg/kg",
    "kg/m^2",
    "kg/m^2/s",
    "kg/m^3",
    "kg/s",
    "km",
    "km^2/(individuals*year)",
    "km^2/year",
    "m",
    "m/s",
    "m/s^2",
    "mL",
    "m^2",
    "m^2/(kg*day)",
    "m^2/m^2",
    "m^2/s",
    "m^2/s^2",
    "m^3",
    "m^3/(mol*s)",
    "m^6/(mol^2*s)",
    "mg",
    "mg/(m^2*h)",
    "mg/L",
    "mm",
    "mmHg",
    "mol",
    "mol/(L*K)",
    "mol/(m^3*s)",
    "mol/L",
    "mol/m^3",
    "mol/mol",
    "mol/mol/s",
    "mol^3/m^9",
    "molec/cm^3",
    "nm",
    "ppb",
    "ppb/min",
    "ppb^-1 s^-1",
    "ppb^-2/min",
    "ppbv",
    "ppm",
    "ppm/h",
    "psi",
    "s",
    "s/m",
    "ug/m^3",
    "um",
    "units/L",
    "units/s",
    "vehicles/km^2",
    "°C",
    "μg/(m^3*s)",
    "μg/m^3",
    "μmol/(m^2*s)",
];

#[test]
fn every_unit_string_in_the_valid_corpus_parses() {
    let unreadable: Vec<_> = CORPUS_VALID_UNITS
        .iter()
        .filter(|u| parse_unit(u).is_err())
        .collect();
    assert!(
        unreadable.is_empty(),
        "these unit strings appear in tests/valid/** but the registry cannot read them, \
         so a `unit_parse_error` would reject a VALID file: {unreadable:?}"
    );
}

/// The §4.8 discriminators from `tests/valid/units_registry_grammar.esm`, pinned
/// directly on the parser so a regression names the rule it broke instead of
/// just failing a fixture.
///
/// Each assertion is a way a real binding has actually gotten §4.8 wrong.
#[test]
fn units_registry_grammar_discriminators() {
    let dim_eq = |a: &str, b: &str| {
        let (ua, ub) = (parse_unit(a).unwrap(), parse_unit(b).unwrap());
        assert!(
            ua.is_compatible(&ub),
            "{a} should have the same dimension as {b}"
        );
    };
    let dim_ne = |a: &str, b: &str| {
        let (ua, ub) = (parse_unit(a).unwrap(), parse_unit(b).unwrap());
        assert!(!ua.is_compatible(&ub), "{a} must NOT have {b}'s dimension");
    };

    // `C` IS THE COULOMB: charge × field is a newton. Were `C` Celsius, this
    // would be kg·m·K·s⁻³·A⁻¹.
    dim_eq("C*V/m", "N");

    // `*` and `/` are ONE precedence level, LEFT to RIGHT. The two spellings
    // are DIFFERENT dimensions — K's exponent flips sign.
    dim_eq("J/mol*K/K", "J/mol");
    dim_eq("J/(mol*K)*K", "J/mol");
    dim_ne("J/mol*K", "J/(mol*K)");

    // WHITESPACE IS MULTIPLICATION.
    dim_eq("ppb^-1 s^-1", "1/s");

    // RATIONAL exponents — the SDE noise intensity — and `sqrt` HALVES.
    dim_eq("1/s^0.5", "s^(-1/2)");
    dim_eq("m^2/s^2", "m^2/s^2");
    assert!(
        parse_unit("m^2/s^2")
            .unwrap()
            .power_rational(earthsci_ast::Rational::new(1, 2))
            .is_compatible(&parse_unit("m/s").unwrap()),
        "sqrt must halve a dimension"
    );

    // UNICODE normalisation: superscripts, middot, dot-operator, micro, °C, Ω.
    dim_eq("W/m²", "kg/s^3");
    dim_eq("J/(kg·K)", "m^2/(s^2*K)");
    dim_eq("kg⋅m/s", "kg*m/s");
    dim_eq("µg/m^3", "ug/m^3");
    dim_eq("°C", "K");
    dim_eq("Ω*m", "Ohm*m");

    // COUNTS ARE DIMENSIONLESS — a number density, not an amount of substance,
    // and `units` is a COUNT noun, not micro-nit (a luminance).
    dim_eq("molec/cm^3", "1/m^3");
    // `molecule` is a COUNT (dimensionless), so a bimolecular rate constant is
    // m³·s⁻¹ — it does NOT carry the mol axis an amount-of-substance would add.
    dim_eq("cm³/(molecule*s)", "m^3/s");
    dim_ne("cm³/(molecule*s)", "m^3/(mol*s)");
    dim_eq("units/L", "1/m^3");
    dim_ne("units/L", "cd/m^5");

    // The Dobson unit is a COLUMN density: dimension m⁻², scale 2.6867e20.
    dim_eq("DU", "1/m^2");
    dim_eq("Dobson", "1/m^2");

    // Long forms and the registry additions resolve.
    dim_eq("meters/hour", "m/s");
    dim_eq("Celsius", "K");
    dim_eq("percent", "%");
    dim_eq("uatm", "Pa");
    dim_eq("psu", "dimensionless");
    dim_eq("degrees", "rad");
}

/// The superscript digits are NOT one contiguous Unicode block: `¹` (U+00B9),
/// `²` (U+00B2) and `³` (U+00B3) live in Latin-1 Supplement, while `⁰` and
/// `⁴`–`⁹` live in Superscripts and Subscripts (U+2070…). A character-class
/// range like `[⁰-⁹]` therefore silently drops exactly the three exponents that
/// actually occur in real unit strings — `m²`, `cm³`, `W/m²` — while passing a
/// unit test written against `⁴`. All ten are enumerated, plus superscript
/// minus `⁻` (U+207B).
#[test]
fn every_superscript_digit_normalizes() {
    for (sup, ascii) in [
        ("⁰", "0"),
        ("¹", "1"),
        ("²", "2"),
        ("³", "3"),
        ("⁴", "4"),
        ("⁵", "5"),
        ("⁶", "6"),
        ("⁷", "7"),
        ("⁸", "8"),
        ("⁹", "9"),
    ] {
        let sup_unit = parse_unit(&format!("m{sup}")).expect("superscript must parse");
        let ascii_unit = parse_unit(&format!("m^{ascii}")).expect("ascii must parse");
        assert_eq!(sup_unit, ascii_unit, "m{sup} should equal m^{ascii}");
    }
    // Superscript MINUS — a negative exponent, e.g. a number density m⁻³.
    assert_eq!(
        parse_unit("m⁻³").unwrap(),
        parse_unit("m^-3").unwrap(),
        "m⁻³ should equal m^-3"
    );
}

/// With `rad` as a base axis the circular functions are NOT symmetric.
///
/// FORWARD circular map an angle to a ratio (accept rad or dimensionless,
/// return dimensionless); INVERSE circular map a ratio to an ANGLE (require
/// dimensionless, RETURN rad). Asserting a dimensionless result for `acos` while
/// `rad` is an axis makes a `zenith: "rad"` computed by `acos(...)` a guaranteed
/// false mismatch.
#[test]
fn trig_angle_rules() {
    use earthsci_ast::{Expr, ExpressionNode};

    let angle = parse_unit("rad").unwrap();
    let mut env = HashMap::new();
    env.insert("theta".to_string(), angle.clone());
    env.insert("ratio".to_string(), parse_unit("dimensionless").unwrap());
    env.insert("mass".to_string(), parse_unit("kg").unwrap());

    let call = |name: &str, arg: &str| {
        Expr::Operator(ExpressionNode {
            op: name.to_string(),
            args: vec![Expr::Variable(arg.to_string())],
            ..ExpressionNode::default()
        })
    };

    // Inverse circular RETURN an angle.
    for f in ["asin", "acos", "atan"] {
        let unit = Unit::propagate(&call(f, "ratio"), &env)
            .unwrap_or_else(|e| panic!("{f}(ratio) should propagate: {e}"));
        assert!(
            unit.is_compatible(&angle),
            "{f} must RETURN an angle (rad), got {unit:?}"
        );
    }

    // Forward circular accept an angle and return a pure number.
    for f in ["sin", "cos", "tan"] {
        let unit = Unit::propagate(&call(f, "theta"), &env)
            .unwrap_or_else(|e| panic!("{f}(theta) should propagate: {e}"));
        assert!(unit.is_dimensionless(), "{f} must return a pure number");
        // ... but still reject a dimensional argument.
        assert!(
            Unit::propagate(&call(f, "mass"), &env).is_err(),
            "{f}(kg) must be rejected"
        );
    }
}

/// A bare `d` is NOT a unit (esm-spec §4.8.1). The canonical spelling of the day
/// is `day`; a one-letter `d` reads as the deci- prefix or as a differential, so
/// admitting it would make the symbol ambiguous at every site. Pinned as an
/// EXCLUSION so it cannot creep back into the registry.
#[test]
fn bare_d_is_not_a_unit() {
    assert!(
        parse_unit("d").is_err(),
        "`d` must not resolve — the day is spelled `day`"
    );
    assert!(parse_unit("day").is_ok());
}
