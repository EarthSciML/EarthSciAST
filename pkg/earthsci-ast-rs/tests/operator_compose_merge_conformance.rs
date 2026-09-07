//! Conformance harness adapter — `operator_compose` merge intent (Rust binding).
//!
//! Drives the shared manifest at
//! `tests/conformance/operator_compose_merge/manifest.json`
//! (esm-libraries-spec §4.7.1 steps 3 and 5; EarthSciML/EarthSciAST#195).
//!
//! Three things are pinned, and they are distinct:
//!
//! 1. An entry that merges NOTHING is `operator_compose_no_merge`, a hard
//!    refusal: such an entry is indistinguishable from one that is not there. A
//!    PARTIAL merge stays a warning, because an operator may legitimately
//!    contribute states of its own alongside the ones it does merge.
//! 2. `require_match` is TRI-STATE and `None` is not `Some(false)` — absent means
//!    "the author has not said" (zero-merge refuses), `true` makes ANY shortfall
//!    fatal, `false` DECLARES a standalone-contributing operator and silences
//!    both. Each state has a non-vacuity anchor, so a binding cannot pass by
//!    being uniformly strict or uniformly lax.
//! 3. A bare-name match that would unify two STATES is
//!    `operator_compose_ambiguous_bare_name`, a refusal: each carries its own
//!    initial condition and the merge keeps one, which is exactly the silent
//!    choice that made the `systems` order matter. Where only one side is a state
//!    the match is unambiguous and the state owns the quantity.
//!
//! Unlike the flatten corpus this category carries no golden: it compares
//! DIAGNOSTIC OUTCOMES, so each binding asserts its own idiomatic surface. Here
//! that is [`capture_coupling_diagnostics`] — the side-effect-free counterpart of
//! the stderr warning stream — and the three `FlattenError` variants.

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

fn case_by_id(m: &Value, id: &str) -> Value {
    cases(m)
        .iter()
        .find(|c| c["id"] == id)
        .unwrap_or_else(|| panic!("manifest has no case {id}"))
        .clone()
}

/// The diagnostic CODE a refusal carries. The three refusals have three
/// different fixes, so collapsing them would still let a caller route wrong —
/// this is what keeps the variant and the manifest's code in step.
fn refusal_code(err: &FlattenError) -> &'static str {
    match err {
        FlattenError::OperatorComposeNoMerge { .. } => "operator_compose_no_merge",
        FlattenError::OperatorComposeRequireMatchUnmatched { .. } => {
            "operator_compose_require_match_unmatched"
        }
        FlattenError::OperatorComposeAmbiguousBareName { .. } => {
            "operator_compose_ambiguous_bare_name"
        }
        other => panic!("not an operator_compose refusal: {other:?}"),
    }
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

/// The observable outcome of a fixture: the refusal's code, or the surviving
/// states paired with their defaults. Compared BETWEEN two runs that must agree,
/// rather than each against a recorded value.
fn outcome_of(case: &Value) -> String {
    let (result, _) = flatten_capturing(case["path"].as_str().expect("case path"));
    match result {
        Err(e) => refusal_code(&e).to_string(),
        Ok(system) => system
            .state_variables
            .iter()
            .map(|(n, v)| format!("{n}={:?}", v.default))
            .collect::<Vec<_>>()
            .join(","),
    }
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
    assert_eq!(m["codes"]["operator_compose_partial_merge"], "warning");
    for code in [
        "operator_compose_no_merge",
        "operator_compose_require_match_unmatched",
        "operator_compose_ambiguous_bare_name",
    ] {
        assert_eq!(m["codes"][code], "error", "{code} must be an error");
        // The manifest names a variant per binding per code; reading Rust's
        // column back keeps the record from drifting away from the code.
        assert!(
            m["diagnostic_surface"]["errors"][code]["rust"]
                .as_str()
                .expect("rust column")
                .starts_with("FlattenError::"),
            "{code}: the manifest must name Rust's FlattenError variant"
        );
    }
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
                let err = result
                    .err()
                    .unwrap_or_else(|| panic!("{id}: expected a refusal"));
                let want = case["code"].as_str().expect("case code");
                assert_eq!(refusal_code(&err), want, "{id}: wrong refusal variant");
                let message = err.to_string();
                assert!(
                    message.starts_with(want),
                    "{id}: the refusal must lead with its machine-readable code: {message}"
                );
                for key in ["unmatched", "unified"] {
                    for name in case[key].as_array().unwrap_or(&Vec::new()) {
                        let name = name.as_str().expect("name");
                        assert!(message.contains(name), "{id}: must NAME {name}: {message}");
                    }
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

/// Every cell of the tri-state table the manifest records has a case.
///
/// The table is the whole of `require_match`'s meaning, and its three states are
/// three different things an author can mean. A column with no case is a column
/// a binding could get wrong without failing anything.
#[test]
fn the_require_match_truth_table_is_covered() {
    let m = manifest();
    let covered: Vec<String> = cases(&m)
        .iter()
        .map(|c| {
            format!(
                "{}|{}",
                match &c["require_match"] {
                    Value::Bool(b) => b.to_string(),
                    other => other.as_str().unwrap_or("?").to_string(),
                },
                c["outcome"].as_str().expect("outcome")
            )
        })
        .collect();
    for want in [
        "absent|refused",
        "absent|warning",
        "absent|clean",
        "true|refused",
        "true|clean",
        "false|clean",
    ] {
        assert!(
            covered.iter().any(|c| c == want),
            "the require_match truth table has no case for {want}"
        );
    }
    assert!(
        !covered.iter().any(|c| c == "false|refused"),
        "`require_match: false` declares that unmatched equations are expected; \
         nothing under it may refuse"
    );
}

/// Issue #195 Symptom 1, in the form that fails under the old rule.
///
/// Two PAIRS of fixtures, each differing ONLY in the `systems` array's order. The
/// tendency is arithmetically identical either way, so the surviving name and
/// default (or the refusal) are the entire observable difference — compared
/// between the two RUNS rather than only against the manifest, so this fails on
/// disagreement even if both were re-recorded.
#[test]
fn flipping_the_systems_order_changes_nothing_observable() {
    let m = manifest();
    for (left, right) in [
        ("ambiguous_bare_name", "ambiguous_bare_name_flipped"),
        (
            "owner_rename_state_wins_observed_first",
            "owner_rename_state_wins_state_first",
        ),
    ] {
        let a = case_by_id(&m, left);
        let b = case_by_id(&m, right);
        let (a_sys, mut b_sys) = (
            a["systems"].as_array().expect("systems").clone(),
            b["systems"].as_array().expect("systems").clone(),
        );
        b_sys.reverse();
        assert_eq!(
            a_sys, b_sys,
            "{left}/{right} must differ ONLY in `systems` order"
        );
        assert_eq!(
            outcome_of(&a),
            outcome_of(&b),
            "flipping `systems` changed the outcome between {left} and {right}"
        );
    }
}

/// The two ways out of an ambiguous bare-name match both still work: `translate`
/// names the surviving spelling outright, and a match where only one side is a
/// STATE is not ambiguous at all. Without this a binding could pass every refusal
/// by refusing the whole bare-name fallback.
#[test]
fn the_ambiguity_refusal_is_not_a_blanket_ban_on_bare_names() {
    let m = manifest();
    for (id, state, default) in [
        ("ambiguous_resolved_by_translate", "Chem.O3", 30.0),
        ("owner_rename_state_wins_observed_first", "Sink.O3", 40.0),
    ] {
        let case = case_by_id(&m, id);
        let (result, _) = flatten_capturing(case["path"].as_str().expect("path"));
        let system = result.unwrap_or_else(|e| panic!("{id}: {e}"));
        assert_eq!(state_names(&system), [state], "{id}");
        assert_eq!(
            system.state_variables[state]
                .default
                .as_ref()
                .and_then(|d| d.as_scalar()),
            Some(default),
            "{id}"
        );
    }
}

/// `require_match` is TRI-STATE, so an explicit `false` must survive the round
/// trip — dropping it as "the default" would silently re-arm the zero-merge
/// refusal on every document that opted out — and an ABSENT flag must stay
/// absent, for the same reason in the other direction.
#[test]
fn require_match_round_trips_including_an_explicit_false() {
    let emitted = |name: &str| -> Value {
        let path = category_dir().join("fixtures").join(name);
        let file = load_path(path.to_str().expect("path is UTF-8")).expect("fixture loads");
        serde_json::to_value(&file).expect("the loaded file serializes")
    };
    assert_eq!(
        emitted("require_match_unmatched.esm")["coupling"][0]["require_match"],
        true
    );
    assert_eq!(
        emitted("no_merge_declared.esm")["coupling"][0]["require_match"],
        false,
        "an explicit `false` must survive the round trip"
    );
    assert!(
        emitted("partial_merge.esm")["coupling"][0]
            .get("require_match")
            .is_none(),
        "an ABSENT flag must stay absent"
    );
}
