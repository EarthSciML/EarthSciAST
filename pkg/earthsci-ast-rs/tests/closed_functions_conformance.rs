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

use earthsci_ast::adapter_support::{ClosedArgLiteral, check_closed_function_args};
use earthsci_ast::load_string;
use earthsci_ast::{
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
    // the current schema).
    let json_str = fs::read_to_string(&canonical).expect("read canonical.esm");
    let file = load_string(&json_str).unwrap_or_else(|e: earthsci_ast::EsmError| {
        panic!("parse failed for {}: {e}", canonical.display())
    });
    // The shared corpus is stamped 1.0.0 and is NOT restamped as the library
    // advances: the 1.x line is additive, so an older minor stays loadable and a
    // fixture bumped to the library's own version would stop exercising that.
    // Pinning SCHEMA_VERSION here only worked while the two coincided.
    assert_eq!(
        file.esm,
        "1.0.0",
        "fixture {} esm version not 1.0.0",
        canonical.display(),
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
        if fn_name.starts_with("interp.") {
            let label = format!("{}::{sname}", expected.display());
            check_at_load(
                &fn_name,
                scenario["inputs"]
                    .as_array()
                    .expect("scenario.inputs is array"),
                None,
                &label,
            );
        }
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
            let raw_inputs = err["inputs"]
                .as_array()
                .expect("error_scenario.inputs is array");
            let expected_code = err["expected_error_code"].as_str().unwrap_or_else(|| {
                panic!(
                    "{}::{ename}: missing expected_error_code",
                    expected.display()
                )
            });
            let label = format!("{}::{ename}", expected.display());
            if fn_name.starts_with("interp.") {
                check_at_load(&fn_name, raw_inputs, Some(expected_code), &label);
            }
            // The evaluator's registry raises the same code, for the inputs a
            // `ClosedArg` can carry (rank 2 at most).
            if raw_inputs.iter().any(|v| literal_rank(v) > 2) {
                continue;
            }
            let inputs: Vec<ClosedArg> = raw_inputs.iter().map(decode_input).collect();
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

/// The nesting depth of a fixture input: 0 for a scalar (a number or a
/// `"NaN"`/`"Inf"`/`"-Inf"` string), 1 + the deepest element for an array.
fn literal_rank(v: &Value) -> usize {
    match v {
        Value::Array(items) => 1 + items.iter().map(literal_rank).max().unwrap_or(0),
        _ => 0,
    }
}

fn literal_number(v: &Value) -> Option<f64> {
    match v {
        Value::Number(n) => n.as_f64(),
        Value::String(s) => match s.as_str() {
            "NaN" => Some(f64::NAN),
            "Inf" => Some(f64::INFINITY),
            "-Inf" => Some(f64::NEG_INFINITY),
            _ => None,
        },
        _ => None,
    }
}

/// A fixture input as the load-time check sees a `const` argument holding it
/// (`"NaN"`, `"Inf"`, `"-Inf"` decoded to those values, which no document can
/// carry).
fn decode_literal(v: &Value) -> ClosedArgLiteral {
    let numbers =
        |items: &[Value]| -> Option<Vec<f64>> { items.iter().map(literal_number).collect() };
    match v {
        Value::Array(items) => {
            if let Some(flat) = numbers(items) {
                return ClosedArgLiteral::Array(flat);
            }
            items
                .iter()
                .map(|row| row.as_array().and_then(|r| numbers(r)))
                .collect::<Option<Vec<_>>>()
                .map_or(ClosedArgLiteral::OtherRank, ClosedArgLiteral::Array2D)
        }
        other => {
            literal_number(other).map_or(ClosedArgLiteral::OtherRank, ClosedArgLiteral::Scalar)
        }
    }
}

fn has_non_finite_string(v: &Value) -> bool {
    match v {
        Value::String(_) => true,
        Value::Array(items) => items.iter().any(has_non_finite_string),
        _ => false,
    }
}

/// Drive one scenario through the esm-spec §9.2 load-time argument check
/// (ruling Q-106): `expected_code` is the code it must raise, `None` that it
/// must pass. Every input becomes a `const` argument. The check runs on the
/// literals directly, and — when no input needs a non-finite value, which no
/// document can carry — on a document whose one equation is that `fn` node,
/// through `load_string`, which must refuse it with the code (or load it).
fn check_at_load(fn_name: &str, inputs: &[Value], expected_code: Option<&str>, label: &str) {
    let literals: Vec<ClosedArgLiteral> = inputs.iter().map(decode_literal).collect();
    let got = check_closed_function_args(fn_name, &literals).err();
    assert_eq!(
        got.as_ref().map(|e| e.code.as_str()),
        expected_code,
        "{label}: load-time argument check ({got:?})"
    );
    if inputs.iter().any(has_non_finite_string) {
        return;
    }
    let args: Vec<Value> = inputs
        .iter()
        .map(|v| serde_json::json!({"op": "const", "args": [], "value": v}))
        .collect();
    let doc = serde_json::json!({
        "esm": "1.0.0",
        "metadata": {"name": "closed_fn_load_check", "authors": ["test"]},
        "models": {"M": {
            "variables": {"y": {"type": "unknown", "default": 0.0}},
            "equations": [{
                "lhs": {"op": "D", "args": ["y"], "wrt": "t"},
                "rhs": {"op": "fn", "name": fn_name, "args": args}
            }]
        }}
    });
    let loaded = load_string(&doc.to_string());
    match expected_code {
        Some(code) => {
            let msg = loaded
                .expect_err(&format!("{label}: the document must be refused at load"))
                .to_string();
            assert!(msg.contains(&format!("[{code}]")), "{label}: got: {msg}");
        }
        None => {
            loaded.unwrap_or_else(|e| panic!("{label}: the document must load: {e}"));
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
