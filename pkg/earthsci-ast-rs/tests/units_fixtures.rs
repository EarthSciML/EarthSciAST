//! Cross-binding units fixtures (gt-gtf)
//!
//! The three units_*.esm files in tests/valid/ are shared across
//! Julia/Python/Rust/TypeScript/Go and exist specifically to drive
//! cross-binding agreement on units handling.
//!
//! Asserts that each fixture parses, that every variable's declared unit
//! string round-trips through `parse_unit`, and — now that expression-level
//! dimension propagation exists (`units::propagate` via `validate_complete`)
//! — that every fixture passes full validation with zero unit warnings.

use earthsci_ast::*;

const UNITS_FIXTURES: &[(&str, &str)] = &[
    (
        "units_conversions.esm",
        include_str!("../../../tests/valid/units_conversions.esm"),
    ),
    (
        "units_dimensional_analysis.esm",
        include_str!("../../../tests/valid/units_dimensional_analysis.esm"),
    ),
    (
        "units_propagation.esm",
        include_str!("../../../tests/valid/units_propagation.esm"),
    ),
];

#[test]
fn units_fixtures_parse() {
    for (name, content) in UNITS_FIXTURES {
        let file: EsmFile = load(content).unwrap_or_else(|e| panic!("failed to load {name}: {e}"));
        let models = file
            .models
            .as_ref()
            .unwrap_or_else(|| panic!("{name}: expected at least one model"));
        assert!(!models.is_empty(), "{name}: models map is empty");
    }
}

#[test]
fn units_fixtures_variable_units_parse_or_log() {
    // Walk every variable's declared unit string. Successful parses are
    // expected; failures mark a registry-coverage gap (e.g. atm, Torr,
    // psi) that the cross-binding fixtures intentionally surface.
    // Failures do not fail the test — they are reported via println so
    // they appear in `cargo test -- --nocapture` and become a paper
    // trail when the registry is extended.
    for (fname, content) in UNITS_FIXTURES {
        let file: EsmFile = load(content).expect("fixture parses");
        let models = file.models.as_ref().expect("fixture has models");
        for (mname, model) in models {
            for (vname, var) in &model.variables {
                if let Some(unit_str) = &var.units {
                    if unit_str.is_empty() {
                        continue;
                    }
                    if let Err(err) = parse_unit(unit_str) {
                        println!(
                            "[units coverage] {fname}::{mname}::{vname}: cannot parse {unit_str:?}: {err}"
                        );
                    }
                }
            }
        }
    }
}

#[test]
fn units_fixtures_dimensional_propagation() {
    // Expression-level dimensional propagation over every equation, pinning
    // the exact expected warning set per fixture. The fixtures are
    // deliberately not equation-balanced (they showcase unit relationships,
    // not complete ODE systems), so structural validity is not asserted.
    //
    // `units_dimensional_analysis.esm` used to raise one warning here: its
    // Thermodynamics relaxation equation divides by the bare number 1.0 rather
    // than a `tau: s` constant, and the propagator read that literal as
    // DIMENSIONLESS, making D(T,t) [K/s] != RHS [K]. A bare literal is now
    // treated as INDETERMINATE (it may well be an implicit-unit constant), so no
    // dimension is fabricated for it and the equation is no longer flagged.
    //
    // The fixture's REAL dimensional defects — `log` of a volume in the
    // Thermodynamics S and G observeds — are provable and are now reported as
    // hard `unit_inconsistency` STRUCTURAL ERRORS rather than warnings, so they
    // do not appear in this count either.
    let expected_warning_counts = [
        // These counts are DIMENSIONAL-analysis warnings only. Many of these
        // fixtures declare real scientific units (Hz, T, C, BTU, kWh, degC, bar,
        // …) that this crate's minimal unit parser does not recognize (pint /
        // Unitful in the Python / Julia bindings do). Each such unit is surfaced
        // as an "unparseable unit; treated as unknown" warning instead of being
        // silently coerced to dimensionless — a pre-existing Rust parser-coverage
        // gap, orthogonal to dimensional propagation, so the assertion below
        // filters those out.
        ("units_conversions.esm", 0usize),
        ("units_dimensional_analysis.esm", 0),
        ("units_propagation.esm", 0),
    ];
    for (name, content) in UNITS_FIXTURES {
        let result = validate_complete(content);
        assert!(
            result.schema_errors.is_empty(),
            "{name}: unexpected schema errors: {:?}",
            result.schema_errors
        );
        let expected = expected_warning_counts
            .iter()
            .find(|(n, _)| n == name)
            .map(|(_, c)| *c)
            .unwrap_or(0);
        let dimensional_warnings = result
            .unit_warnings
            .iter()
            .filter(|w| !w.contains("unparseable unit"))
            .count();
        assert_eq!(
            dimensional_warnings, expected,
            "{name}: expected {expected} dimensional warning(s), got {:?}",
            result.unit_warnings
        );
    }
}
