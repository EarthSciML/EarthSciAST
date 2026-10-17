//! Unit checking across `{ref}` mount edges, inside an `faq` filter, and through
//! constant-expression exponents (esm-spec §4.8.3, §4.8.4; EarthSciAST#414).
//!
//! The fixtures mount files by relative path, so they are loaded from disk.

use earthsci_ast::*;
use std::path::PathBuf;

fn corpus(rel: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests")
        .join(rel)
}

fn findings(rel: &str) -> (bool, Vec<(String, String)>) {
    let file = load_path(corpus(rel)).unwrap_or_else(|e| panic!("{rel} must load: {e}"));
    let result = validate(&file);
    let errs = result
        .structural_errors
        .iter()
        .map(|e| (e.code.to_string(), e.path.clone()))
        .collect();
    (result.is_valid, errs)
}

#[test]
fn units_fixtures_that_must_validate() {
    for rel in [
        "valid/units_mount_leaf.esm",
        "valid/units_mount_subsystem_consistent.esm",
        "valid/units_mount_toplevel_consistent.esm",
        "valid/units_faq_filter_consistent.esm",
        "valid/units_constant_exponent_folding.esm",
        "valid/units_symbolic_exponent_undeterminable.esm",
    ] {
        let (valid, errs) = findings(rel);
        assert!(valid, "{rel} must validate: {errs:?}");
    }
}

#[test]
fn units_fixtures_that_must_be_rejected_at_their_pins() {
    for (rel, pins) in [
        (
            "invalid/units_mount_subsystem_wrong_dimension.esm",
            &["/models/Probe/variables/probe"][..],
        ),
        (
            "invalid/units_mount_subsystem_scale_mismatch.esm",
            &["/models/Probe/variables/probe"][..],
        ),
        (
            "invalid/units_mount_toplevel_wrong_dimension.esm",
            &["/models/Probe/variables/probe"][..],
        ),
        (
            "invalid/units_mount_toplevel_scale_mismatch.esm",
            &["/models/Probe/variables/probe"][..],
        ),
        (
            "invalid/units_faq_filter_mismatch.esm",
            &["/models/Probe/variables/n_short"][..],
        ),
        (
            "invalid/units_faq_body_mismatch.esm",
            &["/models/Probe/variables/total"][..],
        ),
        (
            "invalid/units_constant_exponent_mismatch.esm",
            &[
                "/models/Powers/variables/T_32",
                "/models/Powers/variables/L_const",
            ][..],
        ),
    ] {
        let (valid, errs) = findings(rel);
        assert!(!valid, "{rel} must be rejected");
        for pin in pins {
            assert!(
                errs.iter()
                    .any(|(code, path)| code == "unit_inconsistency" && path == pin),
                "{rel}: expected unit_inconsistency at {pin}, got {errs:?}"
            );
        }
    }
}

/// `unit_inconsistency` findings of an inline document.
fn unit_errors(doc: serde_json::Value) -> Vec<String> {
    let file = load_string(&doc.to_string()).expect("document must load");
    validate(&file)
        .structural_errors
        .iter()
        .filter(|e| e.code.to_string() == "unit_inconsistency")
        .map(|e| e.path.clone())
        .collect()
}

/// Model `A` reads `B.x` into `y [m]`; it has a subsystem `B` whose `x`
/// declares `sub_units` (or none), and a top-level model `B` declares `x [kg]`.
fn shadowing_doc(sub_units: Option<&str>) -> serde_json::Value {
    let mut sub_x = serde_json::json!({ "type": "parameter" });
    if let Some(u) = sub_units {
        sub_x["units"] = serde_json::json!(u);
    }
    serde_json::json!({
        "esm": "1.2.0",
        "metadata": { "name": "Shadow", "authors": ["test"] },
        "models": {
            "A": {
                "variables": { "y": { "type": "unknown", "units": "m" } },
                "equations": [ { "lhs": "y", "rhs": "B.x" } ],
                "subsystems": {
                    "B": { "variables": { "x": sub_x }, "equations": [] }
                }
            },
            "B": {
                "variables": { "x": { "type": "parameter", "units": "kg" } },
                "equations": []
            }
        }
    })
}

#[test]
fn a_component_relative_path_shadows_a_toplevel_member_even_without_units() {
    // The relative `B.x` declares no units: undeterminable, so no check — it
    // must NOT fall through to the top-level `B.x [kg]`.
    let errs = unit_errors(shadowing_doc(None));
    assert!(errs.is_empty(), "{errs:?}");
    // The relative path wins when it has units, too.
    assert!(unit_errors(shadowing_doc(Some("m"))).is_empty());
    let errs = unit_errors(shadowing_doc(Some("s")));
    assert!(errs.iter().any(|p| p.starts_with("/models/A")), "{errs:?}");
}

/// A first-order reaction `S -> P` whose rate is the scoped reference `rate`.
/// Top-level model `Other` declares `k [other_units]`; the reaction system's
/// own subsystem `Sub` declares `k [sub_units]` when given.
fn reaction_doc(rate: &str, other_units: &str, sub_units: Option<&str>) -> serde_json::Value {
    let mut rs = serde_json::json!({
        "species": {
            "S": { "units": "mol/m^3", "default": 1.0 },
            "P": { "units": "mol/m^3", "default": 0.0 }
        },
        "parameters": {},
        "reactions": [ {
            "id": "R1",
            "substrates": [ { "species": "S", "stoichiometry": 1 } ],
            "products": [ { "species": "P", "stoichiometry": 1 } ],
            "rate": rate
        } ]
    });
    if let Some(units) = sub_units {
        let k = serde_json::json!({ "default": 1.0, "units": units });
        rs["subsystems"] = serde_json::json!({
            "Sub": {
                "species": {
                    "X": { "units": "mol/m^3", "default": 1.0 },
                    "Y": { "units": "mol/m^3", "default": 0.0 }
                },
                "parameters": { "k": k },
                "reactions": [ {
                    "id": "RX",
                    "substrates": [ { "species": "X", "stoichiometry": 1 } ],
                    "products": [ { "species": "Y", "stoichiometry": 1 } ],
                    "rate": "k"
                } ]
            }
        });
    }
    serde_json::json!({
        "esm": "1.2.0",
        "metadata": { "name": "Rates", "authors": ["test"] },
        "models": {
            "Other": {
                "variables": { "k": { "type": "parameter", "units": other_units } },
                "equations": []
            }
        },
        "reaction_systems": { "Chem": rs }
    })
}

#[test]
fn reaction_rates_see_scoped_reference_units() {
    let rxn = "/reaction_systems/Chem/reactions/0";
    // Top-level `Other.k`.
    assert!(unit_errors(reaction_doc("Other.k", "1/s", None)).is_empty());
    let errs = unit_errors(reaction_doc("Other.k", "m", None));
    assert!(errs.iter().any(|p| p == rxn), "{errs:?}");
    // A path relative to the reaction system's own subsystems.
    assert!(unit_errors(reaction_doc("Sub.k", "m", Some("1/s"))).is_empty());
    let errs = unit_errors(reaction_doc("Sub.k", "1/s", Some("m")));
    assert!(errs.iter().any(|p| p == rxn), "{errs:?}");
}
