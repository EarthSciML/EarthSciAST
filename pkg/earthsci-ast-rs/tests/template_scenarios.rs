#![cfg(all(not(target_arch = "wasm32"), feature = "solve"))]
//! The `tests/closed_functions` scenarios through the standard-library templates.
//!
//! Every scenario of `tests/closed_functions/{interp,datetime}/*/expected.json`
//! is applied to its template of `esm:std/interp.esm` or `esm:std/calendar.esm`,
//! loaded and expanded by the normal load path, and evaluated by the interpreter
//! and by the strict native tape. Each query or instant is a state with
//! `D(q) = 0`, so one build serves a whole file and a non-finite value, which
//! no JSON literal can carry, is covered too. The oracle is the template
//! contract of esm-spec §9.8:
//!
//! - interp: each success scenario's `expected`, bit for bit (NaN matching
//!   NaN). The `error_scenarios` are invalid tables (non-monotonic axis, NaN in
//!   an axis, length mismatch); the templates have no contract for them, so
//!   they are not run.
//! - datetime: each `scenarios` and `error_scenarios` instant `t` gives NaN when
//!   `t` is NaN, infinite or `|t| >= 2^52` s, and the scenario's `expected`
//!   otherwise (within the file's tolerance). The domain edges `±(2^52 - 1)`
//!   and `±(2^52 - 0.5)` are checked against an exact integer
//!   proleptic-Gregorian computation (§9.8.2), and `±2^52` against NaN.

use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;

use earthsci_ast::load_string;
use earthsci_ast::simulate_array::ArrayCompiled;
use serde_json::{Value, json};

use crate::common;

const DOMAIN: f64 = 4_503_599_627_370_496.0; // 2^52

fn scenario_dirs(module: &str) -> Vec<PathBuf> {
    let root = common::repo_fixture("closed_functions").join(module);
    let mut dirs: Vec<PathBuf> = fs::read_dir(&root)
        .unwrap_or_else(|e| panic!("read {}: {e}", root.display()))
        .map(|e| e.expect("dir entry").path())
        .filter(|p| p.join("expected.json").is_file())
        .collect();
    dirs.sort();
    dirs
}

fn read_spec(dir: &std::path::Path) -> Value {
    serde_json::from_str(&fs::read_to_string(dir.join("expected.json")).expect("expected.json"))
        .expect("expected.json parses")
}

/// A scenario number: `"NaN"`, `"Inf"` and `"-Inf"` are the non-finite ones.
fn decode(v: &Value) -> f64 {
    match v {
        Value::String(s) => match s.as_str() {
            "NaN" => f64::NAN,
            "Inf" => f64::INFINITY,
            "-Inf" => f64::NEG_INFINITY,
            other => panic!("unrecognized string value {other:?}"),
        },
        other => other
            .as_f64()
            .unwrap_or_else(|| panic!("not a number: {other}")),
    }
}

#[derive(Clone, Copy)]
struct Tolerance {
    abs: f64,
    rel: f64,
}

const EXACT: Tolerance = Tolerance { abs: 0.0, rel: 0.0 };

fn tolerance(spec: &Value) -> Tolerance {
    let get = |k: &str| spec["tolerance"][k].as_f64().unwrap_or(0.0);
    Tolerance {
        abs: get("abs"),
        rel: get("rel"),
    }
}

fn agrees(actual: f64, expected: f64, tol: Tolerance) -> bool {
    if actual.is_nan() || expected.is_nan() {
        return actual.is_nan() && expected.is_nan();
    }
    if tol.abs == 0.0 && tol.rel == 0.0 {
        return actual.to_bits() == expected.to_bits();
    }
    let d = (actual - expected).abs();
    d <= tol.abs || d <= tol.rel * expected.abs().max(1.0)
}

/// One document importing `name` from `library`, with `D(out_k) = rhs[k]` and
/// every name of `queries` a state in `units` with `D(q) = 0`, built once.
struct Probe {
    compiled: ArrayCompiled,
    names: Vec<String>,
    outs: usize,
}

impl Probe {
    fn new(library: &str, name: &str, rhs: &[Value], queries: &[String], units: &str) -> Self {
        let mut variables = serde_json::Map::new();
        let mut equations = Vec::new();
        for q in queries {
            variables.insert(
                q.clone(),
                json!({"type": "unknown", "default": 0.0, "units": units}),
            );
            equations.push(json!({"lhs": {"op": "D", "args": [q], "wrt": "t"}, "rhs": 0.0}));
        }
        for (k, r) in rhs.iter().enumerate() {
            let v = format!("out_{k}");
            variables.insert(
                v.clone(),
                json!({"type": "unknown", "default": 0.0, "units": "1"}),
            );
            equations.push(json!({"lhs": {"op": "D", "args": [v], "wrt": "t"}, "rhs": r}));
        }
        let doc = json!({
            "esm": "2.0.0",
            "metadata": {"name": "template_scenarios", "authors": ["test"]},
            "models": {"M": {
                "expression_template_imports": [{"ref": library, "only": [name]}],
                "variables": variables,
                "equations": equations
            }}
        })
        .to_string();
        let file = load_string(&doc).unwrap_or_else(|e| panic!("{name}: load: {e}"));
        let compiled =
            ArrayCompiled::from_file(&file).unwrap_or_else(|e| panic!("{name}: compile: {e:?}"));
        let names = compiled.state_variable_names().to_vec();
        Probe {
            compiled,
            names,
            outs: rhs.len(),
        }
    }

    fn slot(&self, bare: &str) -> usize {
        self.names
            .iter()
            .position(|n| n == bare || n.split_once('.').map(|x| x.1) == Some(bare))
            .unwrap_or_else(|| panic!("no state {bare:?} in {:?}", self.names))
    }

    /// `(interpreter, native)` values of every `out_k` with the queries set.
    fn eval(&self, queries: &[(String, f64)]) -> Vec<(f64, f64)> {
        let mut u = vec![0.0; self.names.len()];
        for (q, v) in queries {
            u[self.slot(q)] = *v;
        }
        let (oracle, _) = self.compiled.debug_eval_rhs(&u, 0.0, &HashMap::new(), true);
        let mut taped = vec![0.0; self.names.len()];
        let mut scratch = self
            .compiled
            .debug_new_scratch_taped()
            .unwrap_or_else(|e| panic!("strict native: {e}"));
        self.compiled.debug_eval_rhs_into(
            &u,
            0.0,
            &self.compiled.debug_resolve_params(&HashMap::new()),
            &mut taped,
            &mut scratch,
            &mut Default::default(),
        );
        (0..self.outs)
            .map(|k| {
                let s = self.slot(&format!("out_{k}"));
                (oracle[s], taped[s])
            })
            .collect()
    }
}

fn konst(v: &Value) -> Value {
    json!({"op": "const", "args": [], "value": v})
}

fn len(v: &Value) -> usize {
    v.as_array().expect("an array input").len()
}

/// The bindings of one interp scenario and its query states `qx_<k>`,
/// `qy_<k>` with their values.
fn interp_call(name: &str, inputs: &[Value], k: usize) -> (Value, Vec<(String, f64)>) {
    let (qx, qy) = (format!("qx_{k}"), format!("qy_{k}"));
    match name {
        "searchsorted" => (
            json!({"x": qx, "xs": konst(&inputs[1]), "n": len(&inputs[1])}),
            vec![(qx, decode(&inputs[0]))],
        ),
        "linear" => (
            json!({"table": konst(&inputs[0]), "axis": konst(&inputs[1]), "x": qx,
                   "n": len(&inputs[1])}),
            vec![(qx, decode(&inputs[2]))],
        ),
        "bilinear" => (
            json!({"table": konst(&inputs[0]), "axis_x": konst(&inputs[1]),
                   "axis_y": konst(&inputs[2]), "x": qx, "y": qy,
                   "nx": len(&inputs[1]), "ny": len(&inputs[2])}),
            vec![(qx, decode(&inputs[3])), (qy, decode(&inputs[4]))],
        ),
        other => panic!("no interp template {other}"),
    }
}

#[test]
fn interp_scenarios_through_the_stdlib_templates() {
    let dirs = scenario_dirs("interp");
    assert_eq!(dirs.len(), 3, "searchsorted, linear, bilinear");
    let mut checked = 0usize;
    let mut failures = Vec::new();
    for dir in dirs {
        let spec = read_spec(&dir);
        let name = spec["function"]
            .as_str()
            .and_then(|f| f.strip_prefix("interp."))
            .expect("an interp.* fixture")
            .to_string();
        let tol = tolerance(&spec);
        let scenarios = spec["scenarios"].as_array().expect("scenarios");
        let mut rhs = Vec::new();
        let mut queries = Vec::new();
        for (k, sc) in scenarios.iter().enumerate() {
            let inputs = sc["inputs"].as_array().expect("inputs");
            let (bindings, q) = interp_call(&name, inputs, k);
            rhs.push(
                json!({"op": "apply_expression_template", "args": [], "name": name,
                            "bindings": bindings}),
            );
            queries.extend(q);
        }
        let names: Vec<String> = queries.iter().map(|(q, _)| q.clone()).collect();
        let probe = Probe::new("esm:std/interp.esm", &name, &rhs, &names, "1");
        for (sc, (interp, native)) in scenarios.iter().zip(probe.eval(&queries)) {
            let want = decode(&sc["expected"]);
            for (who, got) in [("interpreter", interp), ("native", native)] {
                if !agrees(got, want, tol) {
                    failures.push(format!(
                        "{name}::{} ({who}): got {got:?}, expected {want:?}",
                        sc["name"]
                    ));
                }
            }
            checked += 1;
        }
    }
    assert!(
        failures.is_empty(),
        "interp template mismatches:\n  {}",
        failures.join("\n  ")
    );
    assert!(checked >= 40, "only {checked} interp scenarios checked");
}

/// Howard Hinnant's `civil_from_days`.
fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (yoe + era * 400 + i64::from(m <= 2), m, d)
}

fn is_leap(y: i64) -> bool {
    y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)
}

/// The §9.8.2 value of `field` at an in-domain instant `t`, from integer
/// arithmetic (and, for julian_day, the clause's binary64 formula).
fn exact_field(field: &str, t: f64) -> f64 {
    let ft = t.floor();
    let whole = ft as i64;
    let (days, sod) = (whole.div_euclid(86_400), whole.rem_euclid(86_400));
    let (y, m, d) = civil_from_days(days);
    const CUMULATIVE: [i64; 12] = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334];
    let v = match field {
        "julian_day" => {
            return (days as f64 + 2_440_588.0) + ((sod as f64 - 43_200.0) + (t - ft)) / 86_400.0;
        }
        "year" => y,
        "month" => m,
        "day" => d,
        "hour" => sod / 3600,
        "minute" => (sod / 60) % 60,
        "second" => sod % 60,
        "day_of_year" => CUMULATIVE[(m - 1) as usize] + d + i64::from(m > 2 && is_leap(y)),
        "is_leap_year" => i64::from(is_leap(y)),
        other => panic!("no calendar field {other}"),
    };
    v as f64
}

#[test]
fn exact_calendar_reference_on_known_instants() {
    let fields = [
        "year",
        "month",
        "day",
        "hour",
        "minute",
        "second",
        "day_of_year",
        "julian_day",
        "is_leap_year",
    ];
    let leap_day: Vec<f64> = fields
        .iter()
        .map(|f| exact_field(f, 951_825_600.0))
        .collect();
    assert_eq!(
        leap_day,
        [2000.0, 2.0, 29.0, 12.0, 0.0, 0.0, 60.0, 2_451_604.0, 1.0]
    );
    let before_epoch: Vec<f64> = fields[..7].iter().map(|f| exact_field(f, -1.0)).collect();
    assert_eq!(before_epoch, [1969.0, 12.0, 31.0, 23.0, 59.0, 59.0, 365.0]);
}

fn in_domain(t: f64) -> bool {
    t.is_finite() && t.abs() < DOMAIN
}

#[test]
fn datetime_scenarios_through_the_stdlib_templates() {
    let dirs = scenario_dirs("datetime");
    assert_eq!(dirs.len(), 9, "the nine calendar fields");
    let edges = [
        DOMAIN - 1.0,
        -(DOMAIN - 1.0),
        DOMAIN - 0.5,
        -(DOMAIN - 0.5),
        DOMAIN,
        -DOMAIN,
    ];
    let mut checked = 0usize;
    let mut failures = Vec::new();
    for dir in dirs {
        let spec = read_spec(&dir);
        let field = spec["function"]
            .as_str()
            .and_then(|f| f.strip_prefix("datetime."))
            .expect("a datetime.* fixture")
            .to_string();
        let tol = tolerance(&spec);
        let mut cases: Vec<(String, f64, f64, Tolerance)> = Vec::new();
        for sc in spec["scenarios"].as_array().expect("scenarios") {
            let t = decode(&sc["inputs"][0]);
            let want = if in_domain(t) {
                decode(&sc["expected"])
            } else {
                f64::NAN
            };
            cases.push((sc["name"].to_string(), t, want, tol));
        }
        for sc in spec["error_scenarios"].as_array().expect("error_scenarios") {
            let t = decode(&sc["inputs"][0]);
            assert!(
                !in_domain(t),
                "{field}::{}: an error scenario in the domain",
                sc["name"]
            );
            cases.push((sc["name"].to_string(), t, f64::NAN, tol));
        }
        for t in edges {
            let want = if in_domain(t) {
                exact_field(&field, t)
            } else {
                f64::NAN
            };
            cases.push((format!("domain_edge_{t:?}"), t, want, EXACT));
        }
        let call = json!({"op": "apply_expression_template", "args": [], "name": field,
                          "bindings": {"t": "tq"}});
        let probe = Probe::new(
            "esm:std/calendar.esm",
            &field,
            &[call],
            &["tq".to_string()],
            "s",
        );
        for (sname, t, want, tol) in cases {
            let (interp, native) = probe.eval(&[("tq".to_string(), t)])[0];
            for (who, got) in [("interpreter", interp), ("native", native)] {
                if !agrees(got, want, tol) {
                    failures.push(format!(
                        "{field}::{sname} (t = {t:?}, {who}): got {got:?}, expected {want:?}"
                    ));
                }
            }
            checked += 1;
        }
    }
    assert!(
        failures.is_empty(),
        "calendar template mismatches:\n  {}",
        failures.join("\n  ")
    );
    assert!(checked > 1000, "only {checked} instants checked");
}
