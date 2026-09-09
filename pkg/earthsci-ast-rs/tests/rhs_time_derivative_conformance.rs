//! Cross-language conformance: esm-spec §4.2's right-hand-side structural `D`
//! rule, in both halves.
//!
//! The shared fixtures and the per-assertion outcomes live under
//! `tests/conformance/rhs_time_derivative/` (repo root); the Python runner
//! (`test_rhs_time_derivative_conformance.py`) gates the same manifest.
//!
//! Julia is `scope_excluded`, for reasons in neither its transform nor this
//! rule: its `run_inline_tests` cannot read a 0-D OBSERVED at all, and it does not
//! REFUSE an unresolvable right-hand-side `D`. It does implement the resolve
//! half (`flatten` step 3c), pinned on its side by
//! `rhs_time_derivative_resolution_test.jl` through a state the runner can
//! read. The manifest spells both gaps out.
//!
//! The category pins OUTCOME CLASSES rather than a numeric golden, because half
//! of it has no number to record:
//!
//! * `outcome: "value"` — the resolution answered, from the equations the
//!   system already carries: a state's own tendency, an observed's definition
//!   differentiated by the CHAIN RULE, `0` for a time-invariant name, and the
//!   sum / product / quotient rules through `+ - neg * /`;
//! * `outcome: "refused"` — the resolution answered NOTHING, because the
//!   operand is outside that closed set (`d_of_unsupported`, a `^`) or the
//!   chain is cyclic (`d_of_cycle`). The run MUST be refused with the
//!   `unlowered_operator` diagnostic. There is no actual, and inventing one —
//!   **in particular `0`** — is the defect this half exists to catch.
//!
//! The refusal half is the fragile one, which is why both its fixtures assert
//! `expected: 0.0`: `0` is what all three Rust evaluators returned for *every*
//! unresolvable `D` (`simulate/interpret.rs`, `simulate_array/eval.rs`,
//! `simulate_array/tape/lower.rs`). A binding that answers it passes on the
//! arithmetic and fails here, which is the only way round to catch it.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::{Alg, SolveOptions, load_string, run_inline_tests_with_base_dir};
use std::collections::BTreeSet;
use std::fs;
use std::path::PathBuf;

mod common;

fn category_dir() -> PathBuf {
    common::repo_fixture("conformance/rhs_time_derivative")
}

fn read_json(path: &PathBuf) -> serde_json::Value {
    let text = fs::read_to_string(path).unwrap_or_else(|e| panic!("read {path:?}: {e}"));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("parse {path:?}: {e}"))
}

fn manifest() -> serde_json::Value {
    read_json(&category_dir().join("manifest.json"))
}

/// The manifest is the contract; a binding must not silently drop out of it,
/// and neither half may be quietly dropped.
#[test]
fn manifest_requires_both_bindings_and_both_halves() {
    let m = manifest();
    assert_eq!(m["category"].as_str(), Some("rhs_time_derivative"));
    let required: Vec<&str> = m["bindings_required"]
        .as_array()
        .expect("bindings_required")
        .iter()
        .map(|v| v.as_str().expect("binding name"))
        .collect();
    for b in ["python", "rust"] {
        assert!(required.contains(&b), "manifest must require {b}");
    }
    // Every excluded binding must say WHY, so a GAP cannot masquerade as a
    // design decision.
    for (binding, reason) in m["scope_excluded"].as_object().expect("scope_excluded") {
        assert!(
            !reason.as_str().unwrap_or("").trim().is_empty(),
            "{binding} is excluded with no reason"
        );
    }
    let outcomes: BTreeSet<&str> = m["fixtures"]
        .as_array()
        .expect("fixtures")
        .iter()
        .flat_map(|fx| fx["cases"].as_array().expect("cases"))
        .map(|c| c["outcome"].as_str().expect("outcome"))
        .collect();
    assert_eq!(
        outcomes,
        BTreeSet::from(["refused", "value"]),
        "dropping the refusal half would leave §4.2's \"in particular not 0\" ungated"
    );
}

#[test]
fn rhs_time_derivative_outcomes_match_the_manifest() {
    let dir = category_dir();
    let m = manifest();
    let rs = &m["integrators"]["rust"];
    assert_eq!(rs["solver"].as_str(), Some("Erk"));
    let opts = SolveOptions {
        alg: Alg::Erk,
        reltol: Some(rs["reltol"].as_f64().expect("reltol")),
        abstol: Some(rs["abstol"].as_f64().expect("abstol")),
        ..Default::default()
    };

    for fx in m["fixtures"].as_array().expect("fixtures") {
        let id = fx["id"].as_str().expect("id");
        let esm_path = dir.join(fx["path"].as_str().expect("path"));
        let test_id = fx["test_id"].as_str().expect("test_id");
        let text =
            fs::read_to_string(&esm_path).unwrap_or_else(|e| panic!("read {esm_path:?}: {e}"));
        let file = load_string(&text)
            .unwrap_or_else(|e| panic!("fixture {esm_path:?} does not load: {e}"));
        let results =
            run_inline_tests_with_base_dir(&file, fx["model"].as_str(), &opts, Some(dir.as_path()));

        let cases = fx["cases"].as_array().expect("cases");
        assert_eq!(
            results.len(),
            cases.len(),
            "{id}: ran {} assertions, the manifest declares {}",
            results.len(),
            cases.len()
        );
        for c in cases {
            let idx = c["assertion_idx"].as_u64().expect("assertion_idx") as usize;
            let note = c["note"].as_str().unwrap_or("");
            let r = results
                .iter()
                .find(|r| r.test_id == test_id && r.assertion_idx == idx)
                .unwrap_or_else(|| panic!("{id}#{idx}: no result row"));
            assert_eq!(
                r.variable,
                c["variable"].as_str().expect("variable"),
                "{id}#{idx}: the manifest and the fixture disagree on the variable"
            );
            assert_eq!(
                r.passed,
                c["passed"].as_bool().expect("passed"),
                "{id}#{idx}: verdict {} — {note} ({})",
                r.passed,
                r.message
            );

            match c["outcome"].as_str().expect("outcome") {
                "value" => {
                    let actual = r
                        .actual
                        .unwrap_or_else(|| panic!("{id}#{idx}: no actual ({})", r.message));
                    let want = c["expected"].as_f64().expect("expected");
                    assert!(
                        (actual - want).abs() <= 1e-8 * want.abs().max(1.0),
                        "{id}#{idx}: actual {actual} vs expected {want} — {note}"
                    );
                }
                "refused" => {
                    // A refusal carries NO number. This is the assertion that
                    // catches a binding inventing 0.
                    assert!(
                        r.actual.is_none(),
                        "{id}#{idx}: an unresolvable D must be refused, not answered — \
                         got {:?}. {note}",
                        r.actual
                    );
                    let code = c["diagnostic"].as_str().expect("diagnostic");
                    assert!(
                        r.message.contains(code),
                        "{id}#{idx}: the refusal must carry the `{code}` code \
                         (esm-spec §9.6.3 constraint 6); got: {}",
                        r.message
                    );
                }
                other => panic!("{id}#{idx}: unknown outcome {other:?}"),
            }
        }
    }
}

/// Guard the RESOLVE half against passing for the wrong reason: every tendency
/// assertion must be non-zero, so a binding still answering `D(anything) = 0`
/// cannot satisfy it.
#[test]
fn the_resolve_half_is_not_vacuous() {
    let m = manifest();
    let fx = m["fixtures"]
        .as_array()
        .expect("fixtures")
        .iter()
        .find(|f| f["id"].as_str() == Some("tendency_resolution"))
        .expect("tendency_resolution fixture");
    let mut seen = 0;
    for c in fx["cases"].as_array().expect("cases") {
        let var = c["variable"].as_str().unwrap_or("");
        if var == "dxdt" || var == "dAdt" {
            seen += 1;
            assert_ne!(
                c["expected"].as_f64(),
                Some(0.0),
                "{var}: a zero expectation gates nothing"
            );
        }
    }
    assert!(
        seen >= 2,
        "the resolve half must assert the own-state and the scoped tendency directly"
    );

    // The CHAIN RULE half of the resolution has its own non-vacuity condition:
    // `d_of_observed` must expect a non-zero number. A binding that refuses
    // `D` of an observed — which is what Python and Julia used to do, and what
    // §4.2 said before the rule was stated in full — fails it as an outcome
    // mismatch rather than an arithmetic one.
    let chain = fixture(&m, "d_of_observed");
    let case = &chain["cases"][0];
    assert_eq!(case["outcome"].as_str(), Some("value"));
    assert_ne!(
        case["expected"].as_f64(),
        Some(0.0),
        "the chain-rule case must expect a non-zero derivative"
    );
}

/// The refusal half must keep BOTH of its shapes: an operand outside the closed
/// arithmetic set, and a cyclic chain. They fail differently in an
/// implementation that gets the rule wrong — the first answers a number, the
/// second does not return at all — so neither substitutes for the other.
#[test]
fn the_refusal_half_keeps_both_shapes() {
    let m = manifest();
    for id in ["d_of_unsupported", "d_of_cycle"] {
        let fx = fixture(&m, id);
        assert_eq!(
            fx["cases"][0]["outcome"].as_str(),
            Some("refused"),
            "{id} must stay a refusal"
        );
        assert_eq!(
            fx["cases"][0]["expected"].as_f64(),
            None,
            "{id}: a refusal records no actual, so the manifest states none"
        );
    }
}

fn fixture<'a>(m: &'a serde_json::Value, id: &str) -> &'a serde_json::Value {
    m["fixtures"]
        .as_array()
        .expect("fixtures")
        .iter()
        .find(|f| f["id"].as_str() == Some(id))
        .unwrap_or_else(|| panic!("{id} fixture"))
}
