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
