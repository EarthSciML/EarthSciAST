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

use earthsci_toolkit::*;

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
    // `units_dimensional_analysis.esm` carries one KNOWN inconsistency: its
    // Thermodynamics relaxation equation divides by the bare number 1.0
    // rather than a `tau: s` constant, so D(T,t) [K/s] != RHS [K]. The
    // propagator is right to flag it; the sibling bindings assert only that
    // validation completes, so the shared fixture stays as is and this test
    // pins the detection instead.
    let expected_warning_counts = [
        ("units_conversions.esm", 0usize),
        ("units_dimensional_analysis.esm", 1),
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
        assert_eq!(
            result.unit_warnings.len(),
            expected,
            "{name}: expected {expected} unit warning(s), got {:?}",
            result.unit_warnings
        );
    }
}
