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
    for surface in ["flatten", "override_keys", "output_selection"] {
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
