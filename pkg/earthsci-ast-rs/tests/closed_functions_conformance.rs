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

use crate::common;

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
        #[cfg(feature = "solve")]
        if fn_name.starts_with("interp.") {
            template_form::check_scenario(
                &fn_name,
                scenario["inputs"]
                    .as_array()
                    .expect("scenario.inputs is array"),
                expected_to_f64(&scenario["expected"]),
                &format!("{}::{sname}", expected.display()),
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

/// The `interp.*` scenarios through the pure-AST templates of
/// `lib/interp.esm`: per success scenario, a document that imports the
/// library and applies the template with the scenario's axes and tables as
/// `const` arrays and each axis length as the integer parameter, evaluated by
/// the interpreter and by the strict native tape. Both must give the
/// scenario's expected value bit for bit (NaN matching NaN).
///
/// Each query is taken twice: as a literal in the document (so the build may
/// fold the whole lookup), and as a state the probe sets (so the lookup runs
/// at evaluation time, and a non-finite query, which no literal can carry,
/// is covered too).
#[cfg(feature = "solve")]
mod template_form {
    use std::collections::HashMap;
    use std::path::PathBuf;

    use earthsci_ast::simulate_array::ArrayCompiled;
    use earthsci_ast::{LoadOptions, load_string_with_options};
    use serde_json::{Value, json};

    use super::{expected_to_f64, has_non_finite_string};

    fn repo_root() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
    }

    /// The template name and the parameters the fixture's inputs bind, in
    /// input order (the axis lengths come from the arrays, see [`lengths`]).
    fn signature(fn_name: &str) -> (&'static str, &'static [&'static str]) {
        match fn_name {
            "interp.searchsorted" => ("searchsorted", &["x", "xs"]),
            "interp.linear" => ("linear", &["table", "axis", "x"]),
            "interp.bilinear" => ("bilinear", &["table", "axis_x", "axis_y", "x", "y"]),
            other => panic!("no template for {other}"),
        }
    }

    fn is_query(param: &str) -> bool {
        matches!(param, "x" | "y")
    }

    fn array_len(v: &Value) -> i64 {
        v.as_array().expect("an array input").len() as i64
    }

    /// The axis-length bindings: `n` from the axis (searchsorted's `xs`,
    /// linear's `axis`), `nx`/`ny` from the bilinear axes.
    fn lengths(fn_name: &str, inputs: &[Value]) -> Vec<(&'static str, i64)> {
        match fn_name {
            "interp.searchsorted" => vec![("n", array_len(&inputs[1]))],
            "interp.linear" => vec![("n", array_len(&inputs[1]))],
            "interp.bilinear" => vec![("nx", array_len(&inputs[1])), ("ny", array_len(&inputs[2]))],
            _ => unreachable!(),
        }
    }

    /// The document, with each query either a literal (`as_state = false`) or
    /// a state of the same name with `D(q) = 0`.
    fn document(fn_name: &str, inputs: &[Value], as_state: bool) -> String {
        let (template, params) = signature(fn_name);
        let mut bindings = serde_json::Map::new();
        let mut variables = serde_json::Map::new();
        let mut equations = Vec::new();
        for (param, input) in params.iter().zip(inputs) {
            let bound = if input.is_array() {
                json!({"op": "const", "args": [], "value": input})
            } else if as_state {
                let q = format!("q_{param}");
                variables.insert(q.clone(), json!({"type": "unknown", "default": 0.0}));
                equations.push(json!({"lhs": {"op": "D", "args": [q], "wrt": "t"}, "rhs": 0.0}));
                Value::String(q)
            } else {
                assert!(is_query(param), "{param}: a scalar input is a query");
                input.clone()
            };
            bindings.insert((*param).to_string(), bound);
        }
        for (name, n) in lengths(fn_name, inputs) {
            bindings.insert(name.to_string(), json!(n));
        }
        variables.insert("y".into(), json!({"type": "unknown", "default": 0.0}));
        equations.push(json!({
            "lhs": {"op": "D", "args": ["y"], "wrt": "t"},
            "rhs": {"op": "apply_expression_template", "args": [], "name": template,
                    "bindings": bindings}
        }));
        json!({
            "esm": "1.2.0",
            "metadata": {"name": "interp_template_scenario", "authors": ["test"]},
            "models": {"M": {
                "expression_template_imports": [{"ref": "lib/interp.esm"}],
                "variables": variables,
                "equations": equations
            }}
        })
        .to_string()
    }

    fn same_bits(a: f64, b: f64) -> bool {
        (a.is_nan() && b.is_nan()) || a.to_bits() == b.to_bits()
    }

    fn query_value(v: &Value) -> f64 {
        expected_to_f64(v)
    }

    pub(super) fn check_scenario(fn_name: &str, inputs: &[Value], expected: f64, label: &str) {
        let (_, params) = signature(fn_name);
        // An axis or table entry no document can carry has no template form.
        if inputs
            .iter()
            .any(|v| v.is_array() && has_non_finite_string(v))
        {
            return;
        }
        let literal_ok = !inputs.iter().any(has_non_finite_string);
        for as_state in [false, true] {
            if !as_state && !literal_ok {
                continue;
            }
            let form = if as_state {
                "state query"
            } else {
                "literal query"
            };
            let doc = document(fn_name, inputs, as_state);
            let options = LoadOptions {
                base_path: Some(repo_root()),
                ..Default::default()
            };
            let file = load_string_with_options(&doc, &options)
                .unwrap_or_else(|e| panic!("{label} ({form}): load: {e}"));
            let compiled = ArrayCompiled::from_file(&file)
                .unwrap_or_else(|e| panic!("{label} ({form}): compile: {e:?}"));
            let report = compiled.debug_build_tape_report();
            assert!(
                report.fallbacks.is_empty(),
                "{label} ({form}): rules left the tape: {:?}",
                report.fallbacks
            );
            let names = compiled.state_variable_names().to_vec();
            let slot = |bare: &str| {
                names
                    .iter()
                    .position(|n| n == bare || n.split_once('.').map(|x| x.1) == Some(bare))
                    .unwrap_or_else(|| panic!("{label}: no state {bare:?} in {names:?}"))
            };
            let mut u = vec![0.0; names.len()];
            if as_state {
                for (param, input) in params.iter().zip(inputs) {
                    if !input.is_array() {
                        u[slot(&format!("q_{param}"))] = query_value(input);
                    }
                }
            }
            let iy = slot("y");
            let (oracle, _) = compiled.debug_eval_rhs(&u, 0.0, &HashMap::new(), true);
            let mut taped = vec![0.0; names.len()];
            let mut scratch = compiled
                .debug_new_scratch_taped()
                .unwrap_or_else(|e| panic!("{label} ({form}): strict native: {e}"));
            compiled.debug_eval_rhs_into(
                &u,
                0.0,
                &compiled.debug_resolve_params(&HashMap::new()),
                &mut taped,
                &mut scratch,
                &mut Default::default(),
            );
            for (who, got) in [("interpreter", oracle[iy]), ("native", taped[iy])] {
                assert!(
                    same_bits(got, expected),
                    "{label} ({form}, {who}): template gives {got:?} ({:#x}), expected {expected:?} ({:#x})",
                    got.to_bits(),
                    expected.to_bits()
                );
            }
        }
    }
}

/// The `datetime.*` scenarios through the pure-AST templates of
/// `lib/calendar.esm`. Per function, one document imports the library and
/// defines `D(y) = <name>(tq)` with the instant `tq` a state, so one build
/// serves every scenario and a non-finite instant, which no literal can carry,
/// is covered too; each finite instant is also taken as a literal, so the build
/// may fold the whole decomposition. Every scenario, the
/// `closed_function_overflow` ones included, and the edges of the domain
/// |t| < 2^52 s run through the interpreter and the strict native tape: inside
/// the domain both must give the `fn` form's bits (for `julian_day` that is
/// the pinned formula, which one scenario's `expected` misses by an ulp within
/// the fixture tolerance), outside it NaN.
#[cfg(feature = "solve")]
mod calendar_template_form {
    use std::collections::HashMap;
    use std::fs;
    use std::path::PathBuf;

    use earthsci_ast::simulate_array::ArrayCompiled;
    use earthsci_ast::{
        ClosedArg, LoadOptions, evaluate_closed_function, load_string_with_options,
    };
    use serde_json::{Value, json};

    use super::{closed_value_to_f64, decode_input, fixtures_root};

    const DOMAIN: f64 = 4_503_599_627_370_496.0; // 2^52

    /// Instants at the edge of the domain: the largest whole and fractional
    /// instants inside it, and the bound itself.
    const EDGES: [f64; 6] = [
        DOMAIN - 1.0,
        -(DOMAIN - 1.0),
        DOMAIN - 0.5,
        -(DOMAIN - 0.5),
        DOMAIN,
        -DOMAIN,
    ];

    fn repo_root() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
    }

    fn same_bits(a: f64, b: f64) -> bool {
        (a.is_nan() && b.is_nan()) || a.to_bits() == b.to_bits()
    }

    /// The document applying template `name` to `instant`: a literal, or (for
    /// `None`) the state `tq` with `D(tq) = 0`.
    fn document(name: &str, instant: Option<f64>) -> String {
        let mut variables = serde_json::Map::new();
        let mut equations = Vec::new();
        let bound = match instant {
            Some(t) => json!(t),
            None => {
                variables.insert("tq".into(), json!({"type": "unknown", "default": 0.0}));
                equations.push(json!({"lhs": {"op": "D", "args": ["tq"], "wrt": "t"}, "rhs": 0.0}));
                json!("tq")
            }
        };
        variables.insert("y".into(), json!({"type": "unknown", "default": 0.0}));
        equations.push(json!({
            "lhs": {"op": "D", "args": ["y"], "wrt": "t"},
            "rhs": {"op": "apply_expression_template", "args": [], "name": name,
                    "bindings": {"t": bound}}
        }));
        json!({
            "esm": "1.2.0",
            "metadata": {"name": "calendar_template_scenario", "authors": ["test"]},
            "models": {"M": {
                "expression_template_imports": [{"ref": "lib/calendar.esm", "only": [name]}],
                "variables": variables,
                "equations": equations
            }}
        })
        .to_string()
    }

    struct Probe {
        compiled: ArrayCompiled,
        names: Vec<String>,
    }

    impl Probe {
        fn new(name: &str, instant: Option<f64>, label: &str) -> Self {
            let options = LoadOptions {
                base_path: Some(repo_root()),
                ..Default::default()
            };
            let file = load_string_with_options(&document(name, instant), &options)
                .unwrap_or_else(|e| panic!("{label}: load: {e}"));
            let compiled = ArrayCompiled::from_file(&file)
                .unwrap_or_else(|e| panic!("{label}: compile: {e:?}"));
            let report = compiled.debug_build_tape_report();
            assert!(
                report.fallbacks.is_empty(),
                "{label}: rules left the tape: {:?}",
                report.fallbacks
            );
            let names = compiled.state_variable_names().to_vec();
            Probe { compiled, names }
        }

        fn slot(&self, bare: &str) -> Option<usize> {
            self.names
                .iter()
                .position(|n| n == bare || n.split_once('.').map(|x| x.1) == Some(bare))
        }

        /// `(interpreter, native)` values of the template at instant `t` (or
        /// at the literal the document was built with).
        fn eval(&self, t: f64, label: &str) -> (f64, f64) {
            let mut u = vec![0.0; self.names.len()];
            if let Some(iq) = self.slot("tq") {
                u[iq] = t;
            }
            let iy = self.slot("y").expect("state y");
            let (oracle, _) = self.compiled.debug_eval_rhs(&u, 0.0, &HashMap::new(), true);
            let mut taped = vec![0.0; self.names.len()];
            let mut scratch = self
                .compiled
                .debug_new_scratch_taped()
                .unwrap_or_else(|e| panic!("{label}: strict native: {e}"));
            self.compiled.debug_eval_rhs_into(
                &u,
                0.0,
                &self.compiled.debug_resolve_params(&HashMap::new()),
                &mut taped,
                &mut scratch,
                &mut Default::default(),
            );
            (oracle[iy], taped[iy])
        }
    }

    fn instant(v: &Value) -> f64 {
        match decode_input(v) {
            ClosedArg::Scalar(t) => t,
            other => panic!("a datetime input is a scalar, got {other:?}"),
        }
    }

    #[test]
    fn datetime_scenarios_through_the_calendar_templates() {
        let root = fixtures_root().join("datetime");
        let mut dirs: Vec<PathBuf> = fs::read_dir(&root)
            .expect("read tests/closed_functions/datetime")
            .map(|e| e.expect("dir entry").path())
            .filter(|p| p.is_dir())
            .collect();
        dirs.sort();
        assert_eq!(dirs.len(), 9, "the nine datetime.* functions");
        let mut checked = 0usize;
        for dir in dirs {
            let spec: Value = serde_json::from_str(
                &fs::read_to_string(dir.join("expected.json")).expect("read expected.json"),
            )
            .expect("expected.json is valid JSON");
            let fn_name = spec["function"].as_str().expect("function").to_string();
            let name = fn_name
                .strip_prefix("datetime.")
                .expect("a datetime.* fixture");
            let mut instants: Vec<(String, f64)> = Vec::new();
            for key in ["scenarios", "error_scenarios"] {
                for sc in spec[key].as_array().expect("scenario array") {
                    let sname = sc["name"].as_str().unwrap_or("(unnamed)").to_string();
                    instants.push((sname, instant(&sc["inputs"][0])));
                }
            }
            for t in EDGES {
                instants.push((format!("domain_edge_{t:?}"), t));
            }
            let state_probe = Probe::new(name, None, &format!("{fn_name} (state instant)"));
            for (sname, t) in instants {
                let label = format!("{fn_name}::{sname} (t = {t:?})");
                let want = if t.abs() < DOMAIN {
                    let v = evaluate_closed_function(&fn_name, &[ClosedArg::Scalar(t)])
                        .unwrap_or_else(|e| panic!("{label}: fn form errored: {e}"));
                    closed_value_to_f64(v)
                } else {
                    f64::NAN
                };
                let mut forms = vec![("state instant", state_probe.eval(t, &label))];
                if t.is_finite() {
                    let probe = Probe::new(name, Some(t), &format!("{label} (literal instant)"));
                    forms.push(("literal instant", probe.eval(t, &label)));
                }
                for (form, (interp, native)) in forms {
                    for (who, got) in [("interpreter", interp), ("native", native)] {
                        assert!(
                            same_bits(got, want),
                            "{label} ({form}, {who}): template gives {got:?} ({:#x}), fn form {want:?} ({:#x})",
                            got.to_bits(),
                            want.to_bits()
                        );
                    }
                }
                checked += 1;
            }
        }
        assert!(checked > 1000, "only {checked} instants checked");
    }
}
