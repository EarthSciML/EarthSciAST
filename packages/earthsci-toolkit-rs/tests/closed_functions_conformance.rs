//! Closed function registry — Rust conformance harness adapter (esm-tzp / esm-1vr).
//!
//! Drives the cross-binding fixtures under `tests/closed_functions/<module>/<name>/`
//! from the Rust binding: parse `canonical.esm` (validates the parser's `fn`-op
//! handling), then walk the scenarios in `expected.json` and assert that
//! `evaluate_closed_function` agrees with the reference output within the
//! declared tolerance. The same fixture set runs from each binding's harness;
//! any binding that disagrees with the spec-pinned values fails CI
//! (esm-spec §9.4).

use std::fs;
use std::path::{Path, PathBuf};

use earthsci_toolkit::load;
use earthsci_toolkit::registered_functions::{
    ClosedArg, ClosedFunctionError, ClosedValue, closed_function_names, evaluate_closed_function,
};
use serde_json::Value;

mod common;

fn fixtures_root() -> PathBuf {
    common::repo_fixture("closed_functions")
}

fn decode_input(v: &Value) -> ClosedArg {
    match v {
        Value::String(s) => match s.as_str() {
            "NaN" => ClosedArg::Scalar(f64::NAN),
            "Inf" => ClosedArg::Scalar(f64::INFINITY),
            "-Inf" => ClosedArg::Scalar(f64::NEG_INFINITY),
            other => panic!("unrecognized string input: {other}"),
        },
        Value::Number(n) => ClosedArg::Scalar(n.as_f64().expect("finite scalar")),
        Value::Array(arr) => {
            // 2-D arrays (e.g. the `table` arg of `interp.bilinear`) decode
            // to ClosedArg::Array2D. Detect by peeking at the first inner
            // element; ragged inner rows are preserved (the dispatcher's
            // load-time validator surfaces the diagnostic).
            if matches!(arr.first(), Some(Value::Array(_))) {
                let mut rows: Vec<Vec<f64>> = Vec::with_capacity(arr.len());
                for row_v in arr {
                    let row_arr = match row_v {
                        Value::Array(a) => a,
                        other => panic!("mixed 2-D array entry: {other:?}"),
                    };
                    let mut row_vals = Vec::with_capacity(row_arr.len());
                    for v in row_arr {
                        match v {
                            Value::Number(n) => row_vals.push(n.as_f64().expect("finite entry")),
                            Value::String(s) if s == "NaN" => row_vals.push(f64::NAN),
                            Value::String(s) if s == "Inf" => row_vals.push(f64::INFINITY),
                            Value::String(s) if s == "-Inf" => row_vals.push(f64::NEG_INFINITY),
                            other => panic!("unsupported 2-D row entry: {other:?}"),
                        }
                    }
                    rows.push(row_vals);
                }
                return ClosedArg::Array2D(rows);
            }
            let mut values = Vec::with_capacity(arr.len());
            for v in arr {
                match v {
                    Value::Number(n) => values.push(n.as_f64().expect("finite array entry")),
                    Value::String(s) if s == "NaN" => values.push(f64::NAN),
                    Value::String(s) if s == "Inf" => values.push(f64::INFINITY),
                    Value::String(s) if s == "-Inf" => values.push(f64::NEG_INFINITY),
                    other => panic!("unsupported xs entry: {other:?}"),
                }
            }
            ClosedArg::Array(values)
        }
        Value::Bool(_) => panic!("boolean inputs not allowed"),
        _ => panic!("unsupported input type: {v:?}"),
    }
}

fn within_tol(actual: f64, expected: f64, abs_tol: f64, rel_tol: f64) -> bool {
    if actual.is_nan() && expected.is_nan() {
        return true;
    }
    let diff = (actual - expected).abs();
    diff <= abs_tol || diff <= rel_tol * expected.abs().max(1.0)
}

fn expected_to_f64(v: &Value) -> f64 {
    match v {
        Value::Number(n) => n.as_f64().expect("finite expected"),
        Value::String(s) if s == "NaN" => f64::NAN,
        Value::String(s) if s == "Inf" => f64::INFINITY,
        Value::String(s) if s == "-Inf" => f64::NEG_INFINITY,
        other => panic!("unsupported expected: {other:?}"),
    }
}

fn closed_value_to_f64(v: ClosedValue) -> f64 {
    v.as_f64()
}

#[test]
fn closed_function_registry_v030_set() {
    let names = closed_function_names();
    assert_eq!(names.len(), 12);
    for n in [
        "datetime.year",
        "datetime.month",
        "datetime.day",
        "datetime.hour",
        "datetime.minute",
        "datetime.second",
        "datetime.day_of_year",
        "datetime.julian_day",
        "datetime.is_leap_year",
        "interp.searchsorted",
        "interp.linear",
        "interp.bilinear",
    ] {
        assert!(names.contains(n), "missing closed-function name: {n}");
    }
}

#[test]
fn unknown_closed_function_diagnostic() {
    let err: ClosedFunctionError =
        evaluate_closed_function("datetime.century", &[ClosedArg::Scalar(0.0)]).unwrap_err();
    assert_eq!(err.code, "unknown_closed_function");
}

#[test]
fn cross_binding_conformance_fixtures() {
    let root = fixtures_root();
    assert!(root.is_dir(), "missing fixtures root: {}", root.display());

    let mut module_dirs: Vec<PathBuf> = fs::read_dir(&root)
        .expect("read fixtures root")
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| p.is_dir())
        .collect();
    module_dirs.sort();

    let mut total_scenarios = 0usize;
    let mut total_errors = 0usize;
    for module_dir in module_dirs {
        let mut name_dirs: Vec<PathBuf> = fs::read_dir(&module_dir)
            .expect("read module dir")
            .filter_map(|e| e.ok())
            .map(|e| e.path())
            .filter(|p| p.is_dir())
            .collect();
        name_dirs.sort();
        for name_dir in name_dirs {
            run_fixture(&name_dir, &mut total_scenarios, &mut total_errors);
        }
    }
    assert!(
        total_scenarios > 0,
        "expected at least one fixture scenario under {}",
        root.display()
    );
    // Every fixture exercises at least one boundary case; the searchsorted
    // fixture exercises both error scenarios. Sanity-check that we hit at
    // least one error scenario so silent skips don't pass CI.
    assert!(
        total_errors > 0,
        "expected at least one error scenario across fixtures"
    );
}

fn run_fixture(fixture_dir: &Path, total_scenarios: &mut usize, total_errors: &mut usize) {
    let canonical = fixture_dir.join("canonical.esm");
    let expected = fixture_dir.join("expected.json");
    assert!(canonical.is_file(), "missing {}", canonical.display());
    assert!(expected.is_file(), "missing {}", expected.display());

    // Parser must accept the fixture (i.e. the `fn` op AST is valid under
    // the v0.3.0 schema).
    let json_str = fs::read_to_string(&canonical).expect("read canonical.esm");
    let file = load(&json_str).unwrap_or_else(|e: earthsci_toolkit::EsmError| {
        panic!("parse failed for {}: {e}", canonical.display())
    });
    assert_eq!(
        file.esm,
        "0.3.0",
        "fixture {} esm version not 0.3.0",
        canonical.display()
    );

    let spec_str = fs::read_to_string(&expected).expect("read expected.json");
    let spec: Value = serde_json::from_str(&spec_str).expect("expected.json is valid JSON");
    let fn_name = spec["function"]
        .as_str()
        .unwrap_or_else(|| panic!("{}: missing 'function' field", expected.display()))
        .to_string();
    if !closed_function_names().contains(&fn_name) {
        // Spec-first phased rollout (esm-94w and similar): the spec PR adds
        // the fixture before this binding's implementation lands. Skip
        // rather than fail; the per-language [Impl] bead registers the
        // function and the fixture starts running automatically.
        eprintln!(
            "skipping fixture {}: function {fn_name} not yet implemented in this binding",
            expected.display()
        );
        return;
    }

    let abs_tol = spec
        .get("tolerance")
        .and_then(|t| t.get("abs"))
        .and_then(|v| v.as_f64())
        .unwrap_or(0.0);
    let rel_tol = spec
        .get("tolerance")
        .and_then(|t| t.get("rel"))
        .and_then(|v| v.as_f64())
        .unwrap_or(0.0);

    let scenarios = spec["scenarios"]
        .as_array()
        .unwrap_or_else(|| panic!("{}: 'scenarios' must be an array", expected.display()));
    for scenario in scenarios {
        *total_scenarios += 1;
        let sname = scenario["name"].as_str().unwrap_or("(unnamed)");
        let inputs: Vec<ClosedArg> = scenario["inputs"]
            .as_array()
            .expect("scenario.inputs is array")
            .iter()
            .map(decode_input)
            .collect();
        let actual = evaluate_closed_function(&fn_name, &inputs).unwrap_or_else(|e| {
            panic!(
                "{}::{sname}: closed-function dispatch errored unexpectedly: {e}",
                expected.display()
            )
        });
        let actual_f = closed_value_to_f64(actual);
        let expected_f = expected_to_f64(&scenario["expected"]);
        assert!(
            within_tol(actual_f, expected_f, abs_tol, rel_tol),
            "{}::{sname}: actual={actual_f}, expected={expected_f}, tol abs={abs_tol} rel={rel_tol}",
            expected.display()
        );
    }

    if let Some(errs) = spec.get("error_scenarios").and_then(|v| v.as_array()) {
        for err in errs {
            *total_errors += 1;
            let ename = err["name"].as_str().unwrap_or("(unnamed)");
            let inputs: Vec<ClosedArg> = err["inputs"]
                .as_array()
                .expect("error_scenario.inputs is array")
                .iter()
                .map(decode_input)
                .collect();
            let expected_code = err["expected_error_code"].as_str().unwrap_or_else(|| {
                panic!(
                    "{}::{ename}: missing expected_error_code",
                    expected.display()
                )
            });
            match evaluate_closed_function(&fn_name, &inputs) {
                Ok(v) => panic!(
                    "{}::{ename}: expected error {expected_code} but got {v:?}",
                    expected.display()
                ),
                Err(e) => assert_eq!(
                    e.code,
                    expected_code,
                    "{}::{ename}: error code mismatch (msg: {})",
                    expected.display(),
                    e.message,
                ),
            }
        }
    }
}

// Pin the dispatch arm for unknown closed-function names — this is the
// `unknown_closed_function` diagnostic that callers (incl. validators that
// want to bypass schema and ask the registry directly) MUST surface.
#[test]
fn unknown_closed_function_via_dispatch() {
    let err =
        evaluate_closed_function("datetime.fortnight", &[ClosedArg::Scalar(0.0)]).unwrap_err();
    assert_eq!(err.code, "unknown_closed_function");
}
