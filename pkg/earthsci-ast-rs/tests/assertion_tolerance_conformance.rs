//! Rust adapter for the SHARED `assertion_tolerance` conformance category
//! (CONFORMANCE_SPEC §5.32, `tests/conformance/assertion_tolerance/`).
//!
//! The category's subject is the esm-spec §6.6.3 pass predicate as a PURE
//! FUNCTION of `(actual, expected, rel, abs)`. Every other assertion category
//! is a simulation category: it computes an actual and then compares it, so it
//! can only exercise the predicate at the pairs an integrator happens to
//! produce — and those all sit in the `|actual| <= |expected|` region, where
//! `rel*max(|a|,|e|)` and `rel*|e|` compute the same number. The readings
//! differ only on an OVERSHOOT, which no fixture in any category reaches. This
//! adapter feeds the discriminating pairs directly.
//!
//! It calls [`earthsci_ast::check_assertion`] — the same function
//! `run_pde_tests` calls. An adapter that re-derived the predicate here would
//! be testing itself, which is the defect the category exists to close.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::check_assertion;
use serde_json::Value;
use std::path::PathBuf;

mod common;

fn category_dir() -> PathBuf {
    common::repo_fixture("conformance/assertion_tolerance")
}

fn read_json(name: &str) -> Value {
    let path = category_dir().join(name);
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("reading {}: {e}", path.display()));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("parsing {}: {e}", path.display()))
}

/// A golden `actual`/`expected` is either a JSON number or one of exactly three
/// strings. An unrecognised value is a HARD ERROR: silently skipping a case
/// would let the category shrink without anything going red.
fn number(v: &Value, case_id: &str, field: &str) -> f64 {
    match v {
        Value::Number(n) => n
            .as_f64()
            .unwrap_or_else(|| panic!("{case_id}: {field} is not representable as f64")),
        Value::String(s) => match s.as_str() {
            "+inf" => f64::INFINITY,
            "-inf" => f64::NEG_INFINITY,
            "nan" => f64::NAN,
            other => panic!(
                "{case_id}: {field} is the string {other:?}; the golden's encoding \
                 admits only \"+inf\", \"-inf\" and \"nan\""
            ),
        },
        other => panic!("{case_id}: {field} is {other:?}, expected a number or a string"),
    }
}

#[test]
fn rust_is_required_and_the_manifest_says_so() {
    let m = read_json("manifest.json");
    assert_eq!(m["category"], "assertion_tolerance");
    assert_eq!(m["reference_binding"], "analytic");
    let required: Vec<&str> = m["bindings_required"]
        .as_array()
        .expect("bindings_required")
        .iter()
        .map(|v| v.as_str().expect("binding name"))
        .collect();
    assert!(
        required.contains(&"rust"),
        "Rust must be in bindings_required: it has a §6.6.3 predicate and a runner that uses it"
    );
    assert!(
        m["scope_excluded"]["rust"].is_null(),
        "Rust must not be scope_excluded"
    );
}

#[test]
fn every_golden_case_matches_the_binding_predicate() {
    let golden = read_json("golden/predicate_verdicts.json");
    let cases = golden["cases"].as_array().expect("golden `cases` array");
    assert!(!cases.is_empty(), "golden carries no cases");

    let mut failures: Vec<String> = Vec::new();
    let (mut n_pass, mut n_fail) = (0usize, 0usize);
    for case in cases {
        let id = case["id"].as_str().expect("case id");
        let actual = number(&case["actual"], id, "actual");
        let expected = number(&case["expected"], id, "expected");
        let rel = case["rel"].as_f64().unwrap_or_else(|| panic!("{id}: rel"));
        let abs = case["abs"].as_f64().unwrap_or_else(|| panic!("{id}: abs"));
        let want = case["passed"]
            .as_bool()
            .unwrap_or_else(|| panic!("{id}: passed"));
        if want {
            n_pass += 1
        } else {
            n_fail += 1
        }

        let got = check_assertion(actual, expected, rel, abs);
        if got != want {
            failures.push(format!(
                "{id}: check_assertion({actual}, {expected}, rel={rel}, abs={abs}) = {got}, \
                 golden says {want} — {}",
                case["why"].as_str().unwrap_or("")
            ));
        }
    }

    assert!(
        failures.is_empty(),
        "{} of {} §6.6.3 predicate cases disagree with the golden:\n{}",
        failures.len(),
        cases.len(),
        failures.join("\n")
    );
    // Non-vacuity: a golden of one verdict would be satisfied by a constant.
    assert!(n_pass > 0 && n_fail > 0, "golden must carry both verdicts");
}

#[test]
fn the_golden_can_still_see_every_known_wrong_reading() {
    // The generator counts, per known WRONG reading of §6.6.3, how many cases
    // change verdict under it. A zero would mean the case list had quietly
    // stopped being able to see that defect — which is how the ~12 ad-hoc
    // harnesses in #223 stayed green for years.
    let golden = read_json("golden/predicate_verdicts.json");
    let d = &golden["readings_discriminated"];
    for reading in [
        "asymmetric",
        "sum_form",
        "epsilon_floor",
        "no_finiteness_guard",
    ] {
        let n = d[reading]
            .as_u64()
            .unwrap_or_else(|| panic!("readings_discriminated.{reading} missing"));
        assert!(
            n > 0,
            "no golden case discriminates the `{reading}` reading of §6.6.3"
        );
    }
}
