//! Conformance harness adapter — `operator_compose` merge intent (Rust binding).
//!
//! Drives the shared manifest at
//! `tests/conformance/operator_compose_merge/manifest.json`
//! (esm-libraries-spec §4.7.1 steps 3 and 5; EarthSciML/EarthSciAST#195).
//!
//! Three things are pinned, and they are distinct:
//!
//! 1. The merge TALLY is reported — `operator_compose_no_merge` when nothing
//!    landed, `operator_compose_partial_merge` when only some did, both naming
//!    the unmatched dependent variables. Step 5 still preserves the equations;
//!    it is no longer SILENT about doing so, because silence made "merged
//!    everything" and "merged nothing" the same observable outcome.
//! 2. `require_match: true` promotes either to a hard refusal, and a PARTIAL
//!    match refuses exactly as a zero match does. `require_match_satisfied` is
//!    the non-vacuity anchor that keeps the flag from being simply always-fatal.
//! 3. The BARE-NAME fallback's surviving spelling follows the state's OWNER —
//!    the component the document declares first — not `systems[0]`, so an entry
//!    means the same thing in either argument order.
//!
//! Unlike the flatten corpus this category carries no golden: it compares
//! DIAGNOSTIC OUTCOMES, so each binding asserts its own idiomatic surface. Here
//! that is [`capture_coupling_diagnostics`] — the side-effect-free counterpart
//! of the stderr warning stream — and `FlattenError::OperatorComposeRequireMatchUnmatched`.

use earthsci_ast::{
    FlattenError, FlattenedSystem, capture_coupling_diagnostics, flatten, load_path,
};
use serde_json::Value;
use std::path::{Path, PathBuf};

fn category_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/conformance/operator_compose_merge")
}

/// A missing manifest is a hard failure, not a skip: the manifest IS the
/// contract this file exists to enforce.
fn manifest() -> Value {
    let raw = std::fs::read_to_string(category_dir().join("manifest.json"))
        .expect("the operator_compose_merge manifest is readable");
    serde_json::from_str(&raw).expect("the operator_compose_merge manifest parses")
}

fn cases(m: &Value) -> &Vec<Value> {
    m["cases"].as_array().expect("`cases` is an array")
}

/// Flatten the fixture at `rel`, returning the result and only this category's
/// diagnostics.
fn flatten_capturing(rel: &str) -> (Result<FlattenedSystem, FlattenError>, Vec<String>) {
    let path = category_dir().join(rel);
    let file = load_path(path.to_str().expect("fixture path is UTF-8")).expect("fixture loads");
    let (out, diagnostics) = capture_coupling_diagnostics(|| flatten(&file));
    let diagnostics = diagnostics
        .into_iter()
        .filter(|d| d.starts_with("operator_compose_"))
        .collect();
    (out, diagnostics)
}

fn state_names(system: &FlattenedSystem) -> Vec<String> {
    system.state_variables.keys().cloned().collect()
}

#[test]
fn the_manifest_is_not_empty_and_covers_this_binding() {
    // A manifest that silently listed zero cases would make every assertion in
    // this file vacuously green.
    let m = manifest();
    assert!(!cases(&m).is_empty(), "the manifest recorded no cases");
    assert!(
        m["bindings_required"]
            .as_array()
            .expect("`bindings_required` is an array")
            .iter()
            .any(|b| b == "rust"),
        "rust is not in bindings_required; if this category stops covering Rust, \
         say so in scope_excluded rather than letting it drift"
    );
    let mut codes: Vec<&str> = m["codes"]
        .as_object()
        .expect("`codes` is an object")
        .keys()
        .map(String::as_str)
        .collect();
    codes.sort_unstable();
    assert_eq!(
        codes,
        [
            "operator_compose_no_merge",
            "operator_compose_partial_merge",
            "operator_compose_require_match_unmatched",
        ]
    );
}

#[test]
fn the_manifest_outcomes_hold() {
    let m = manifest();
    for case in cases(&m) {
        let id = case["id"].as_str().expect("case id");
        let rel = case["path"].as_str().expect("case path");
        let (result, found) = flatten_capturing(rel);

        match case["outcome"].as_str().expect("case outcome") {
            "refused" => {
                let err = result.expect_err(&format!("{id}: expected a refusal"));
                let FlattenError::OperatorComposeRequireMatchUnmatched { ref unmatched, .. } = err
                else {
                    panic!("{id}: expected OperatorComposeRequireMatchUnmatched, got {err:?}");
                };
                let message = err.to_string();
                assert!(
                    message.starts_with(case["code"].as_str().expect("case code")),
                    "{id}: the refusal must lead with its machine-readable code: {message}"
                );
                for name in case["unmatched"].as_array().expect("`unmatched`") {
                    let name = name.as_str().expect("unmatched name");
                    assert!(
                        unmatched.contains(name),
                        "{id}: the refusal must NAME {name}; got {unmatched}"
                    );
                }
                continue;
            }
            "clean" => {
                let system =
                    result.unwrap_or_else(|e| panic!("{id}: expected a clean flatten: {e}"));
                assert!(
                    found.is_empty(),
                    "{id}: expected no diagnostic, got {found:?}"
                );
                check_states(id, case, &system);
            }
            "warning" => {
                let system = result
                    .unwrap_or_else(|e| panic!("{id}: expected a warning, not a refusal: {e}"));
                assert_eq!(
                    found.len(),
                    1,
                    "{id}: expected one diagnostic, got {found:?}"
                );
                let message = &found[0];
                assert!(
                    message.starts_with(case["code"].as_str().expect("case code")),
                    "{id}: wrong code: {message}"
                );
                // The tally and the unmatched names are the content that makes
                // the diagnostic actionable; a code with no names is a shrug.
                let tally = format!(
                    "merged {} of {} equations",
                    case["merged"].as_u64().expect("`merged`"),
                    case["authored"].as_u64().expect("`authored`")
                );
                assert!(
                    message.contains(&tally),
                    "{id}: missing tally {tally}: {message}"
                );
                for name in case["unmatched"].as_array().expect("`unmatched`") {
                    let name = name.as_str().expect("unmatched name");
                    assert!(message.contains(name), "{id}: must NAME {name}: {message}");
                }
                check_states(id, case, &system);
            }
            other => panic!("{id}: unknown outcome {other}"),
        }
    }
}

fn check_states(id: &str, case: &Value, system: &FlattenedSystem) {
    if let Some(expected) = case["state_variables"].as_array() {
        let expected: Vec<&str> = expected.iter().map(|v| v.as_str().expect("name")).collect();
        assert_eq!(state_names(system), expected, "{id}: state variables");
    }
    if let Some(name) = case["surviving_state"].as_str() {
        let want = case["surviving_default"]
            .as_f64()
            .expect("`surviving_default`");
        let got = system.state_variables[name]
            .default
            .as_ref()
            .and_then(|d| d.as_scalar())
            .unwrap_or_else(|| panic!("{id}: surviving state {name} lost its default"));
        assert_eq!(got, want, "{id}: surviving default");
    }
}

/// Issue #195 Symptom 1, in the form that fails under the old rule.
///
/// Two fixtures with identical models in identical declaration order, differing
/// ONLY in the `systems` array's order. The tendency is arithmetically identical
/// either way, so the surviving NAME and its DEFAULT are the entire observable
/// difference — compared between the two RUNS rather than only against the
/// manifest, so this fails on disagreement even if both were re-recorded.
#[test]
fn flipping_the_systems_order_changes_nothing_observable() {
    let m = manifest();
    let by_id = |id: &str| -> Value {
        cases(&m)
            .iter()
            .find(|c| c["id"] == id)
            .unwrap_or_else(|| panic!("manifest has no case {id}"))
            .clone()
    };
    let a = by_id("owner_rename_operator_first");
    let b = by_id("owner_rename_mechanism_listed_first");
    assert_eq!(
        a["models_declared"], b["models_declared"],
        "the two fixtures must differ ONLY in `systems` order"
    );

    let surviving = |case: &Value| -> (String, f64) {
        let id = case["id"].as_str().expect("case id");
        let (result, _) = flatten_capturing(case["path"].as_str().expect("case path"));
        let system = result.unwrap_or_else(|e| panic!("{id}: {e}"));
        let names = state_names(&system);
        assert_eq!(
            names.len(),
            1,
            "{id}: expected one surviving state, got {names:?}"
        );
        let default = system.state_variables[&names[0]]
            .default
            .as_ref()
            .and_then(|d| d.as_scalar())
            .unwrap_or_else(|| panic!("{id}: surviving state lost its default"));
        (names[0].clone(), default)
    };
    assert_eq!(
        surviving(&a),
        surviving(&b),
        "flipping `systems` changed the surviving state or its initial condition"
    );
}

/// The companion to the test above, and what keeps it from being trivial: the
/// same `systems` order with the models declared the other way round must
/// produce the OTHER name. A binding that hard-coded either answer, or that kept
/// renaming onto `systems[0]`, fails one of the two.
#[test]
fn declaration_order_decides_not_argument_order() {
    let m = manifest();
    let by_id = |id: &str| -> Value {
        cases(&m)
            .iter()
            .find(|c| c["id"] == id)
            .expect("case")
            .clone()
    };
    let a = by_id("owner_rename_operator_first");
    let b = by_id("owner_rename_mechanism_declared_first");
    assert_eq!(
        a["systems"], b["systems"],
        "the two fixtures must share a `systems` order"
    );

    let names = |case: &Value| -> Vec<String> {
        let (result, _) = flatten_capturing(case["path"].as_str().expect("case path"));
        state_names(&result.expect("clean flatten"))
    };
    assert_eq!(names(&a), ["Sink.O3"]);
    assert_eq!(names(&b), ["Chem.O3"]);
}

/// `require_match` is a document field, so it must reach the emitted form — a
/// flag that silently vanished on save would make the refusal unreproducible
/// from the file the author kept — and the schema DEFAULT must NOT be written
/// out, which would put a key on every existing fixture and break load
/// preservation.
#[test]
fn require_match_survives_a_round_trip() {
    let emitted = |name: &str| -> Value {
        let path = category_dir().join("fixtures").join(name);
        let file = load_path(path.to_str().expect("path is UTF-8")).expect("fixture loads");
        serde_json::to_value(&file).expect("the loaded file serializes")
    };
    assert_eq!(
        emitted("require_match_unmatched.esm")["coupling"][0]["require_match"],
        true
    );
    assert!(
        emitted("no_merge.esm")["coupling"][0]
            .get("require_match")
            .is_none(),
        "the `false` default must NOT be emitted"
    );
}
