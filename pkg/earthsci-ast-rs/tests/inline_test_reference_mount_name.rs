//! esm-spec §6.6.5 build-time scope: an assertion `reference` reads a MOUNTED
//! SUBSYSTEM's parameter under the mount-relative spelling (issue #408).
//!
//! The defect: within one model, `sub.g` — a constant reached through the
//! subsystem mount `sub` — resolved in every equation but not inside a test
//! assertion's `reference`, where it raised
//! `E_TREEWALK_UNBOUND_NAME: 'sub.g' … bound by NOTHING in scope`. Only the
//! model-qualified `P.sub.g` worked there, because the reference scope aliased
//! the flattened `P.sub.g` to its bare tail `g` and to nothing in between. Two
//! scopes in one document disagreed about what `sub.g` means, with the
//! assertion's the narrower and nothing saying so.
//!
//! Why the mount-relative spelling is the one that must work: it is what a
//! component's own equations use, and the only spelling a mount edge rewrites.
//! The model-qualified form is NOT rewritten, so a component whose test
//! references `P.sub.g` stops resolving the moment it is mounted under any key
//! but `P` — the opposite of what the mount-relative form exists for.
//!
//! The scope is now the flattened name plus its unambiguous DOTTED SUFFIXES,
//! the same alias set §6.6.2 rule 3 already gave an override key (which is why
//! `parameter_overrides: {"sub.g": …}` resolved all along). The shared fixture
//! `tests/valid/inline_test_reference_mount_name.esm` pins the positive case
//! for every binding that sweeps the corpus; the negative controls below pin
//! that the widening did not turn the check into "accept anything dotted".

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::{Alg, SolveOptions, load_string, run_inline_tests};
use std::fs;

mod common;

const FIXTURE: &str = "valid/inline_test_reference_mount_name.esm";

fn opts() -> SolveOptions {
    SolveOptions {
        alg: Alg::Erk,
        reltol: Some(1e-12),
        abstol: Some(1e-14),
        ..Default::default()
    }
}

fn fixture_json() -> serde_json::Value {
    let path = common::repo_fixture(FIXTURE);
    let text = fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {path:?}: {e}"));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("parse {path:?}: {e}"))
}

#[test]
fn reference_resolves_a_mounted_parameter_by_its_mount_name() {
    let file = common::load_repo_fixture(FIXTURE);
    let results = run_inline_tests(&file, Some("P"), &opts());
    assert_eq!(results.len(), 3, "three assertions in the fixture");
    for r in &results {
        assert!(
            r.passed,
            "{}[{}] ({}): {}",
            r.test_id, r.assertion_idx, r.variable, r.message
        );
    }
    // Assertion 0 spells the constant `sub.g` and assertion 2 spells the same
    // constant `P.sub.g`. One parameter, one number — bit for bit.
    let mount_relative = results[0].actual.expect("mount-relative actual");
    let model_qualified = results[2].actual.expect("model-qualified actual");
    assert_eq!(
        mount_relative, model_qualified,
        "the two spellings must name one constant"
    );
    assert_eq!(mount_relative, 0.5, "|1 - 2| / 2 over three uniform cells");
}

/// The negative control. Widening the reference scope to the unambiguous dotted
/// SUFFIXES of a flattened name must not weaken it into binding anything that
/// merely looks qualified: a name that is a suffix of no flattened name stays
/// UNBOUND, so a typo errors instead of quietly reducing against a zero field.
#[test]
fn a_typo_near_a_mounted_parameter_is_still_unbound() {
    for typo in ["sub.gg", "nope.g", "gg"] {
        let mut doc = fixture_json();
        let tests = doc["models"]["P"]["tests"].as_array_mut().expect("tests");
        tests.truncate(1);
        let assertions = tests[0]["assertions"].as_array_mut().expect("assertions");
        assertions.truncate(1);
        assertions[0]["reference"] = serde_json::Value::String(typo.to_string());
        let file = load_string(&doc.to_string()).expect("mutated fixture loads");
        let results = run_inline_tests(&file, Some("P"), &opts());
        assert_eq!(results.len(), 1);
        assert!(!results[0].passed, "'{typo}' must not resolve");
        assert!(
            results[0].message.contains(typo),
            "'{typo}' must be named in the diagnostic, got: {}",
            results[0].message
        );
    }
}
