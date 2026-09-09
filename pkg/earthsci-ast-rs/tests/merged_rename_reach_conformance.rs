//! Conformance harness adapter — merged-away rename REACH (Rust binding).
//!
//! Drives the shared manifest at
//! `tests/conformance/merged_rename_reach/manifest.json`
//! (esm-libraries-spec §4.7.1 step 4 and §4.7.5 step 3 ordering;
//! EarthSciML/EarthSciAST#230).
//!
//! An `operator_compose` renaming match folds `B.x` into `A.x`, deleting `B.x`
//! and rewriting every equation off it. That rewrite reaches equation ASTs and
//! nothing else, and `operator_compose` entries run BEFORE `couple` and
//! `variable_map` — so a later entry's `from` / `to`, plain scoped-reference
//! STRINGS on the entry object, could still name a spelling that no longer
//! exists. This file pins that they RESOLVE to the survivor, on both surfaces
//! the manifest defines:
//!
//! * `flatten` — a later `couple` connector lands on the survivor's tendency
//!   instead of matching nothing and being dropped in SILENCE; a later
//!   `variable_map` substitutes the survivor instead of injecting a name the
//!   flattened system cannot resolve.
//! * `override_keys` — a caller's initial-condition key naming the dead spelling
//!   addresses the survivor instead of designating nothing.
//! * `output_selection` — a name-keyed READ of the finished run resolves to the
//!   survivor's row instead of reporting a variable that never existed.
//!
//! Like `operator_compose_merge` the category carries no golden: what it pins is
//! REACH, asserted as structure.

use earthsci_ast::{FlattenedSystem, flatten, load_path, to_ascii};
use serde_json::Value;
use std::path::{Path, PathBuf};

fn category_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/conformance/merged_rename_reach")
}

/// A missing manifest is a hard failure, not a skip: the manifest IS the
/// contract this file exists to enforce.
fn manifest() -> Value {
    let raw = std::fs::read_to_string(category_dir().join("manifest.json"))
        .expect("the merged_rename_reach manifest is readable");
    serde_json::from_str(&raw).expect("the merged_rename_reach manifest parses")
}

fn cases_for(m: &Value, surface: &str) -> Vec<Value> {
    m["cases"]
        .as_array()
        .expect("`cases` is an array")
        .iter()
        .filter(|c| c["surface"] == surface)
        .cloned()
        .collect()
}

fn flatten_case(case: &Value) -> FlattenedSystem {
    let path = category_dir().join(case["path"].as_str().expect("`path` is a string"));
    let file = load_path(&path).unwrap_or_else(|e| panic!("loading {}: {e}", path.display()));
    flatten(&file).unwrap_or_else(|e| panic!("flattening {}: {e}", path.display()))
}

/// The dependent variable an equation LHS defines, if any.
fn dependent(lhs: &earthsci_ast::Expr) -> Option<String> {
    match lhs {
        earthsci_ast::Expr::Variable(v) => Some(v.clone()),
        earthsci_ast::Expr::Operator(node) if node.op == "D" => {
            node.args.first().and_then(dependent)
        }
        _ => None,
    }
}

#[test]
fn the_manifest_is_not_empty_and_names_this_binding() {
    // Zero cases would make every test below vacuously green.
    let m = manifest();
    assert!(!cases_for(&m, "flatten").is_empty(), "no flatten cases");
    assert!(
        !cases_for(&m, "override_keys").is_empty(),
        "no override_keys cases"
    );
    assert!(
        !cases_for(&m, "output_selection").is_empty(),
        "no output_selection cases"
    );
    for surface in [
        "flatten",
        "override_keys",
        "output_selection",
        "events_and_updates",
        "template_registry",
        "inline_tests",
    ] {
        let bindings = m["surfaces"][surface]["bindings"]
            .as_array()
            .expect("`bindings` is an array");
        assert!(
            bindings.iter().any(|b| b == "rust"),
            "the {surface} surface must bind Rust"
        );
    }
    assert_eq!(
        m["merged_variable_renames_field"]["rust"],
        "FlattenMetadata::merged_variable_renames"
    );
}

#[test]
fn the_merge_records_which_names_it_deleted() {
    // The rename map is what a consumer addressing a state by name resolves
    // through, so it is part of the flattened form's contract, not a private
    // detail of the merge.
    for case in cases_for(&manifest(), "flatten") {
        let flat = flatten_case(&case);
        let expected = case["merged_variable_renames"]
            .as_object()
            .expect("`merged_variable_renames` is an object");
        assert_eq!(
            flat.metadata.merged_variable_renames.len(),
            expected.len(),
            "{}: rename-map size",
            case["id"]
        );
        for (gone, survivor) in expected {
            assert_eq!(
                flat.metadata.merged_variable_renames.get(gone.as_str()),
                survivor.as_str().map(String::from).as_ref(),
                "{}: {gone} must retarget onto {survivor}",
                case["id"]
            );
        }
    }
}

#[test]
fn the_merged_away_name_survives_nowhere() {
    // Not in the variable tables, not in any equation. A reference left behind
    // is a reference to nothing.
    for case in cases_for(&manifest(), "flatten") {
        let flat = flatten_case(&case);
        let want: Vec<&str> = case["state_variables"]
            .as_array()
            .expect("`state_variables` is an array")
            .iter()
            .map(|v| v.as_str().expect("a state name"))
            .collect();
        let got: Vec<&str> = flat.state_variables.keys().map(String::as_str).collect();
        assert_eq!(got, want, "{}: state variables", case["id"]);

        for gone in case["no_equation_references"]
            .as_array()
            .expect("`no_equation_references` is an array")
        {
            let gone = gone.as_str().expect("a name");
            assert!(!flat.state_variables.contains_key(gone));
            assert!(!flat.parameters.contains_key(gone));
            assert!(!flat.observed_variables.contains_key(gone));
            for eq in &flat.equations {
                let rendered = format!("{} = {}", to_ascii(&eq.lhs), to_ascii(&eq.rhs));
                assert!(
                    !rendered.contains(gone),
                    "{}: equation still references the merged-away {gone}: {rendered}",
                    case["id"]
                );
            }
        }
    }
}

#[test]
fn the_later_entry_lands_on_the_survivor() {
    // The non-vacuity anchor for the test above: dropping the entry's reference
    // outright would satisfy "the dead name survives nowhere" by doing nothing
    // at all.
    for case in cases_for(&manifest(), "flatten") {
        let flat = flatten_case(&case);
        let target = case["tendency_of"].as_str().expect("`tendency_of`");
        let eq = flat
            .equations
            .iter()
            .find(|e| dependent(&e.lhs).as_deref() == Some(target))
            .unwrap_or_else(|| panic!("{}: no equation defines {target}", case["id"]));
        let rendered = to_ascii(&eq.rhs);
        for name in case["tendency_references"]
            .as_array()
            .expect("`tendency_references` is an array")
        {
            let name = name.as_str().expect("a name");
            assert!(
                rendered.contains(name),
                "{}: D({target}) must reference {name}, got {rendered}",
                case["id"]
            );
        }
    }
}

#[cfg(feature = "solve")]
#[test]
fn an_override_key_naming_the_merged_away_state_resolves() {
    // esm-spec §6.6.2's key resolution reaches through the merge's rename map.
    // Both halves are asserted: the key lands on the survivor, and the value is
    // the CALLER's rather than the state's declared default — which is what an
    // unresolved key silently left in place.
    use earthsci_ast::{ProblemInput, ProblemOptions, SolveOptions, esm_problem, solve};
    use std::collections::HashMap;

    for case in cases_for(&manifest(), "override_keys") {
        let path = category_dir().join(case["path"].as_str().expect("`path` is a string"));
        let u0: HashMap<String, f64> = case["initial_conditions"]
            .as_object()
            .expect("`initial_conditions` is an object")
            .iter()
            .map(|(k, v)| (k.clone(), v.as_f64().expect("a number")))
            .collect();
        let prob = esm_problem(
            ProblemInput::Path(&path),
            (0.0, 1.0),
            ProblemOptions {
                u0,
                ..Default::default()
            },
        )
        .unwrap_or_else(|e| panic!("{}: building: {e}", case["id"]));
        let sol = solve(&prob, &SolveOptions::default())
            .unwrap_or_else(|e| panic!("{}: solving: {e}", case["id"]));

        for (name, want) in case["resolves_to"].as_object().expect("`resolves_to`") {
            let i = sol
                .state_variable_names
                .iter()
                .position(|n| n == name)
                .unwrap_or_else(|| panic!("{}: no state named {name}", case["id"]));
            let got = sol.state[i][0];
            let want = want.as_f64().expect("a number");
            assert!(
                (got - want).abs() < 1e-9,
                "{}: {name} must start at {want} (the caller's value under the merged-away \
                 spelling), got {got}",
                case["id"]
            );
        }
    }
}

#[cfg(feature = "solve")]
#[test]
fn a_name_keyed_read_of_the_result_resolves() {
    // The solution is the one object a caller reading a trajectory by name
    // holds — the flattened system is not in its hand — so the merge's map
    // rides along on `SolutionMetadata`.
    //
    // Three things are pinned, and the third keeps the first two honest: the
    // read lands on the survivor's row, it is the SAME row (not merely some
    // row), and the reported row NAMES still carry only the surviving spelling,
    // because resolving a read must not invent a name the flattened system does
    // not declare.
    use earthsci_ast::{ProblemInput, ProblemOptions, SolveOptions, esm_problem, solve};

    for case in cases_for(&manifest(), "output_selection") {
        let path = category_dir().join(case["path"].as_str().expect("`path` is a string"));
        let prob = esm_problem(
            ProblemInput::Path(&path),
            (0.0, 1.0),
            ProblemOptions::default(),
        )
        .unwrap_or_else(|e| panic!("{}: building: {e}", case["id"]));
        let sol = solve(&prob, &SolveOptions::default())
            .unwrap_or_else(|e| panic!("{}: solving: {e}", case["id"]));

        let dead = case["read_by_name"].as_str().expect("`read_by_name`");
        let survivor = case["same_row_as"].as_str().expect("`same_row_as`");
        let got = sol.get(dead).unwrap_or_else(|| {
            panic!(
                "{}: '{dead}' must resolve through the merge map; rows are {:?}",
                case["id"], sol.state_variable_names
            )
        });
        let want = sol
            .get(survivor)
            .unwrap_or_else(|| panic!("{}: no row named '{survivor}'", case["id"]));
        assert_eq!(
            got, want,
            "{}: '{dead}' must read the SAME row as '{survivor}'",
            case["id"]
        );

        for gone in case["absent_from_row_names"]
            .as_array()
            .expect("`absent_from_row_names` is an array")
        {
            let gone = gone.as_str().expect("a name");
            assert!(
                !sol.state_variable_names.iter().any(|n| n == gone),
                "{}: resolving a read must not add '{gone}' to the row names",
                case["id"]
            );
        }
    }
}

/// Neither an event nor an `update` rule is an equation, and both address the
/// state BY NAME.
///
/// The affect's `lhs` is the sharp one: it is a plain `String`, so a walk that
/// maps only EXPRESSIONS rewrites the affect's RHS and leaves its target
/// pointing at a state the flattened system no longer declares.
#[test]
fn the_rename_reaches_events_and_variable_updates() {
    let m = manifest();
    let cases = cases_for(&m, "events_and_updates");
    assert!(
        !cases.is_empty(),
        "no events_and_updates cases in the manifest"
    );
    for case in &cases {
        let flat = flatten_case(case);
        let id = case["id"].as_str().unwrap_or("?");

        for (gone, survivor) in case["merged_variable_renames"]
            .as_object()
            .expect("`merged_variable_renames` is an object")
        {
            assert_eq!(
                flat.metadata.merged_variable_renames.get(gone.as_str()),
                Some(&survivor.as_str().expect("survivor is a string").to_string()),
                "{id}: {gone} must be recorded as merged away"
            );
        }

        let mut affects: Vec<(String, String)> = Vec::new();
        for ev in &flat.continuous_events {
            for a in &ev.affects {
                affects.push((a.lhs.clone(), to_ascii(&a.rhs)));
            }
        }
        for ev in &flat.discrete_events {
            for a in ev.affects.iter().flatten() {
                affects.push((a.lhs.clone(), to_ascii(&a.rhs)));
            }
        }
        let want = case["event_affects"]
            .as_array()
            .expect("`event_affects` is an array");
        assert_eq!(affects.len(), want.len(), "{id}: affect count");
        for (got, w) in affects.iter().zip(want) {
            assert_eq!(
                got.0,
                w["lhs"].as_str().expect("lhs is a string"),
                "{id}: the affect writes to {:?} — an affect `lhs` is a plain NAME \
                 string, not an expression",
                got.0
            );
            for name in w["rhs_references"]
                .as_array()
                .expect("rhs_references is an array")
            {
                let name = name.as_str().expect("a reference is a string");
                assert!(
                    got.1.contains(name),
                    "{id}: affect RHS must reference {name}"
                );
            }
        }

        let mut update_text = String::new();
        for (var_name, wanted) in case["variable_updates"]
            .as_object()
            .expect("`variable_updates` is an object")
        {
            let var = flat
                .parameters
                .get(var_name.as_str())
                .or_else(|| flat.state_variables.get(var_name.as_str()))
                .unwrap_or_else(|| panic!("{id}: no variable {var_name}"));
            // `for_each_expression` is the type's own walk over the two slots
            // that can name a variable — the `when` trigger and the value
            // `expression` — so this cannot drift as the union grows.
            // The VARIABLE's own walk over every Expression position an
            // `update` rule carries — the `when` trigger, the `expression`
            // value form, a `from` binding's `unit_conversion` — so this cannot
            // drift as the rule union grows.
            let mut rendered = String::new();
            var.for_each_expression(&mut |expr| {
                rendered.push_str(&to_ascii(expr));
                rendered.push(' ');
            });
            for name in wanted.as_array().expect("wanted is an array") {
                let name = name.as_str().expect("a reference is a string");
                assert!(
                    rendered.contains(name),
                    "{id}: {var_name}'s update must reference {name}, got {rendered}"
                );
            }
            update_text.push_str(&rendered);
        }

        // The dead spelling survives in NEITHER, in EITHER form: not the
        // qualified name a collect-time namespacing carries through, and not the
        // bare local a coupling-time one leaves behind.
        let mut haystack = update_text;
        for (lhs, rhs) in &affects {
            haystack.push_str(lhs);
            haystack.push(' ');
            haystack.push_str(rhs);
            haystack.push(' ');
        }
        for gone in case["absent_from_events_and_updates"]
            .as_array()
            .expect("`absent_from_events_and_updates` is an array")
        {
            let gone = gone.as_str().expect("a name is a string");
            assert!(
                !haystack.split_whitespace().any(|tok| tok
                    .trim_matches(|c: char| { !c.is_alphanumeric() && c != '.' && c != '_' })
                    == gone),
                "{id}: {gone} still appears in an event or an update: {haystack}"
            );
        }
    }
}

/// The ONE surface that refuses rather than resolves.
///
/// A surviving registry body is authored source that expands at the build
/// boundary, so it can neither be left alone (it would expand into a name the
/// flattened system does not declare) nor rewritten (the flattened registry
/// would then disagree with the expand-at-load image). Flatten refuses.
#[test]
fn a_registry_body_naming_the_merged_away_state_is_refused() {
    let m = manifest();
    let cases = cases_for(&m, "template_registry");
    assert!(
        !cases.is_empty(),
        "no template_registry cases in the manifest"
    );
    for case in &cases {
        let id = case["id"].as_str().unwrap_or("?");
        let path = category_dir().join(case["path"].as_str().expect("`path` is a string"));
        let file = load_path(&path).unwrap_or_else(|e| panic!("loading {}: {e}", path.display()));
        let err = flatten(&file).expect_err(&format!("{id}: flatten must REFUSE"));
        let text = err.to_string();
        let want = case["raises"].as_str().expect("`raises` is a string");
        assert!(
            text.contains(want),
            "{id}: the diagnostic must carry {want}, got {text}"
        );
        for name in case["names_in_message"].as_array().expect("array") {
            let name = name.as_str().expect("a name is a string");
            assert!(
                text.contains(name),
                "{id}: the diagnostic must name {name} — naming the offending \
                 reference is what turns it into a fix"
            );
        }
    }
}

/// Both halves of the inline-test surface, pinned by one assertion.
///
/// That it RESOLVES at all is the assertion half — unresolved it reports
/// `scalar state ... not found`. That the actual is the caller's value rather
/// than the survivor's declared default is the `initial_conditions` half: a key
/// that silently resolved to nothing would leave the run at that default and
/// the test would still return a verdict.
#[test]
#[cfg(feature = "solve")]
fn an_inline_test_naming_the_merged_away_state_resolves() {
    let m = manifest();
    let cases = cases_for(&m, "inline_tests");
    assert!(!cases.is_empty(), "no inline_tests cases in the manifest");
    for case in &cases {
        let id = case["id"].as_str().unwrap_or("?");
        let path = category_dir().join(case["path"].as_str().expect("`path` is a string"));
        let file = load_path(&path).unwrap_or_else(|e| panic!("loading {}: {e}", path.display()));
        let results = earthsci_ast::run_inline_tests(&file, None, &Default::default());
        let want_id = case["test_id"].as_str().expect("`test_id` is a string");
        let result = results
            .iter()
            .find(|r| r.test_id == want_id)
            .unwrap_or_else(|| panic!("{id}: no result for test {want_id}"));
        assert_eq!(
            result.passed,
            case["passes"].as_bool().expect("`passes` is a bool"),
            "{id}: {}",
            result.message
        );
        let actual = result
            .actual
            .unwrap_or_else(|| panic!("{id}: no actual value"));
        let expected = case["expected"].as_f64().expect("`expected` is a number");
        let stale = case["default_without_resolution"]
            .as_f64()
            .expect("`default_without_resolution` is a number");
        assert!(
            (actual - expected).abs() < 1e-6,
            "{id}: read {actual}; {stale} is what an unresolved initial-condition key \
             silently leaves in place"
        );
        assert!(
            (actual - stale).abs() > 1e-6,
            "{id}: read the stale default {stale}"
        );
    }
}
