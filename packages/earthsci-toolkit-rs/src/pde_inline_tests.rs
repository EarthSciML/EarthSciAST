//! pde_inline_tests — the §6.6.5-capable inline-test runner over the
//! vectorized array simulation pathway (the Rust mirror of the Julia
//! binding's `pde_inline_tests.jl` and the Python `pde_inline_tests.py`).
//!
//! A PDE model's inline tests (esm-spec §6.6.5) assert REDUCTIONS of a
//! spatial field — `reduce: L2_error | Linf_error` against an analytic
//! `reference` expression, or the pure collapsers `mean | max | min` —
//! rather than scalar point samples. This module drives the official
//! [`crate::simulate::simulate`] pipeline (which dispatches array/spatial
//! files to the vectorized `simulate_array` runtime) and collapses fields
//! per assertion.
//!
//! Public surface (1:1 with the Julia / Python references):
//!
//! - [`evaluate_cellwise`] — official per-cell evaluation of an array-valued
//!   build-time expression (grid geometry / §6.6.5 analytic references)
//!   through the same array evaluator the simulator uses for
//!   coordinate-expression `ic` seeding.
//! - [`field_reduce`] — the §6.6.5 reduction semantics (relative L2,
//!   absolute Linf, mean/max/min).
//! - [`state_cells`] — (cell-index-tuple, state-row) pairs of one array
//!   state, sorted by cell tuple.
//! - [`run_pde_tests`] — run every inline test of the selected model(s);
//!   returns per-assertion results carrying the ACTUAL reduction values
//!   (conformance runners record these).

use std::collections::HashMap;

use serde::Serialize;

use crate::simulate::{SimulateOptions, Solution, simulate};
use crate::simulate_array::{Value, eval_buildtime_field};
use crate::types::{AssertionReference, EsmFile, Expr, IndexSet, Model, Tolerance};

/// esm-spec §6.6.4: the default relative tolerance when neither the
/// assertion, its test, nor the model declares one (same constant as the
/// Julia run_tests reference).
pub const DEFAULT_REL_TOL: f64 = 1e-6;

/// Outcome of one §6.6.5 inline-test assertion evaluated through the
/// simulation pathway. `actual` is the computed reduction value (`None` when
/// the simulation or reduction itself failed); `message` carries the diff or
/// error text for non-passing results. Field-for-field identical to the
/// Julia `PdeAssertionResult` / Python `PdeAssertionResult`, and
/// `Serialize`-able so conformance runners can record it directly.
#[derive(Debug, Clone, Serialize)]
pub struct PdeAssertionResult {
    /// Owning model name.
    pub model: String,
    /// The inline test's `id`.
    pub test_id: String,
    /// 1-based position of the assertion within the test.
    pub assertion_idx: usize,
    /// Asserted variable name.
    pub variable: String,
    /// Assertion time.
    pub time: f64,
    /// The §6.6.5 `reduce` kind (`None` for a scalar point sample).
    pub reduce: Option<String>,
    /// Expected scalar value.
    pub expected: f64,
    /// Computed reduction value (`None` on simulation/reduction failure).
    pub actual: Option<f64>,
    /// Resolved relative tolerance (esm-spec §6.6.4 precedence).
    pub rtol: f64,
    /// Resolved absolute tolerance (esm-spec §6.6.4 precedence).
    pub atol: f64,
    /// Whether the assertion passed.
    pub passed: bool,
    /// Diff or error text for non-passing results (empty when passed).
    pub message: String,
}

/// Evaluate an array-valued expression (elementwise ops over array-producing
/// `aggregate`/`makearray` nodes — e.g. a grid-geometry template expanded by
/// a §9.7 import, or a §6.6.5 analytic `reference`) at each 1-based integer
/// cell of `cells`, returning one `f64` per cell.
///
/// This is the public entry to the same build-time machinery the simulator
/// uses to seed coordinate-expression `ic` fields
/// ([`crate::simulate_array::eval_buildtime_field`]); state references are
/// not in scope. A scalar (const-folded) result broadcasts. Mirrors the
/// Julia `evaluate_cellwise` / Python `evaluate_cellwise` 1:1.
pub fn evaluate_cellwise(
    expr: &Expr,
    cells: &[Vec<i64>],
    index_sets: &HashMap<String, IndexSet>,
) -> Result<Vec<f64>, String> {
    let value = eval_buildtime_field(expr, index_sets).map_err(|e| e.to_string())?;
    match value {
        Value::Scalar(s) => Ok(vec![s; cells.len()]),
        Value::Array(arr) => {
            let mut out = Vec::with_capacity(cells.len());
            for cell in cells {
                if cell.len() != arr.ndim() {
                    return Err(format!(
                        "evaluate_cellwise: cell {cell:?} has {} indices but the field has ndim={}",
                        cell.len(),
                        arr.ndim()
                    ));
                }
                let mut idx = Vec::with_capacity(cell.len());
                for (d, &c) in cell.iter().enumerate() {
                    if c < 1 || (c as usize) > arr.shape()[d] {
                        return Err(format!(
                            "evaluate_cellwise: cell {cell:?} is outside the field's shape {:?}",
                            arr.shape()
                        ));
                    }
                    idx.push((c - 1) as usize);
                }
                out.push(arr[ndarray::IxDyn(&idx)]);
            }
            Ok(out)
        }
    }
}

/// Collapse a spatial field to the scalar a §6.6.5 `reduce` assertion
/// compares (esm-spec §6.6.5); semantics identical to the Julia / Python
/// references:
///
/// - `"L2_error"`  — `‖actual − reference‖₂ / ‖reference‖₂` (relative L2 over
///   the domain; requires `reference`).
/// - `"Linf_error"` — `max |actual − reference|` (absolute supremum norm;
///   requires `reference`).
/// - `"mean" | "max" | "min"` — pure collapsers of `actual`.
///
/// `"integral"` requires the grid measure and is not implemented here.
pub fn field_reduce(kind: &str, actual: &[f64], reference: Option<&[f64]>) -> Result<f64, String> {
    match kind {
        "L2_error" | "Linf_error" => {
            let r = reference
                .ok_or_else(|| format!("field_reduce: `{kind}` requires a reference field"))?;
            if r.len() != actual.len() {
                return Err(format!(
                    "field_reduce: actual has {} cells but reference has {}",
                    actual.len(),
                    r.len()
                ));
            }
            if kind == "L2_error" {
                let refnorm = r.iter().map(|v| v * v).sum::<f64>().sqrt();
                if refnorm == 0.0 {
                    return Err("field_reduce: L2_error reference has zero norm".to_string());
                }
                let diffnorm = actual
                    .iter()
                    .zip(r.iter())
                    .map(|(a, b)| (a - b) * (a - b))
                    .sum::<f64>()
                    .sqrt();
                Ok(diffnorm / refnorm)
            } else {
                Ok(actual
                    .iter()
                    .zip(r.iter())
                    .map(|(a, b)| (a - b).abs())
                    .fold(0.0f64, f64::max))
            }
        }
        "mean" => {
            if actual.is_empty() {
                return Err("field_reduce: empty field".to_string());
            }
            Ok(actual.iter().sum::<f64>() / actual.len() as f64)
        }
        "max" => {
            if actual.is_empty() {
                return Err("field_reduce: empty field".to_string());
            }
            Ok(actual.iter().copied().fold(f64::NEG_INFINITY, f64::max))
        }
        "min" => {
            if actual.is_empty() {
                return Err("field_reduce: empty field".to_string());
            }
            Ok(actual.iter().copied().fold(f64::INFINITY, f64::min))
        }
        other => Err(format!("field_reduce: unsupported reduce kind '{other}'")),
    }
}

/// Split an element name of the form `stem[1,2,…]` into `(stem, cell)`;
/// `None` for a scalar name (no bracketed all-integer suffix).
fn parse_cell_name(name: &str) -> Option<(&str, Vec<i64>)> {
    let open = name.rfind('[')?;
    let inner = name.strip_suffix(']')?.get(open + 1..)?;
    if inner.is_empty() {
        return None;
    }
    let mut cell = Vec::new();
    for part in inner.split(',') {
        if part.is_empty() || !part.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        cell.push(part.parse::<i64>().ok()?);
    }
    Some((&name[..open], cell))
}

/// Collect the (cell-index-tuple, row) pairs of one array state from the
/// simulation's element names (`element_names[row]` is the name of state row
/// `row`, e.g. `"Heat.u[3]"`). Flattening may prefix element names with the
/// owning model; a name matches when its element stem equals `variable`
/// bare, or `model.variable` qualified. Sorted by cell tuple so callers get
/// a deterministic pairing (identical to the Julia / Python `state_cells`).
pub fn state_cells(
    element_names: &[String],
    variable: &str,
    model: &str,
) -> Vec<(Vec<i64>, usize)> {
    let qualified = format!("{model}.{variable}");
    let mut out: Vec<(Vec<i64>, usize)> = Vec::new();
    for (row, name) in element_names.iter().enumerate() {
        let Some((stem, cell)) = parse_cell_name(name) else {
            continue;
        };
        let bare = stem.split_once('.').map(|(_, b)| b).unwrap_or(stem);
        if stem != qualified && stem != variable && bare != variable {
            continue;
        }
        out.push((cell, row));
    }
    out.sort_by(|a, b| a.0.cmp(&b.0));
    out
}

/// Row of a SCALAR state by bare or model-qualified name; `None` if absent.
fn scalar_slot(element_names: &[String], variable: &str, model: &str) -> Option<usize> {
    let qualified = format!("{model}.{variable}");
    for (row, name) in element_names.iter().enumerate() {
        let bare = name.split_once('.').map(|(_, b)| b).unwrap_or(name);
        if name == &qualified || name == variable || bare == variable {
            return Some(row);
        }
    }
    None
}

/// esm-spec §6.6.4 precedence: assertion > test > model > default
/// `rel=1e-6` (identical to the Julia / Python references). Returns
/// `(rtol, atol)`; an unset bound within the winning tolerance is `0.0`.
pub fn resolve_tolerance(
    model_tol: Option<&Tolerance>,
    test_tol: Option<&Tolerance>,
    assertion_tol: Option<&Tolerance>,
) -> (f64, f64) {
    match [assertion_tol, test_tol, model_tol]
        .into_iter()
        .flatten()
        .next()
    {
        Some(candidate) => (candidate.rel.unwrap_or(0.0), candidate.abs.unwrap_or(0.0)),
        None => (DEFAULT_REL_TOL, 0.0),
    }
}

/// Julia `isapprox` semantics: `|a − e| ≤ max(atol, rtol·max(|a|, |e|))`
/// (exact equality when both tolerances are zero) — the same pass predicate
/// the Julia / Python `run_pde_tests` use.
pub fn check_assertion(actual: f64, expected: f64, rtol: f64, atol: f64) -> bool {
    if rtol == 0.0 && atol == 0.0 {
        return actual == expected;
    }
    (actual - expected).abs() <= f64::max(atol, rtol * f64::max(actual.abs(), expected.abs()))
}

/// Index of the saved output time matching `t` to within
/// `1e-9 · max(1, |t|)`; `Err` when the trajectory holds no such sample.
fn time_index(times: &[f64], t: f64) -> Result<usize, String> {
    let mut best: Option<(usize, f64)> = None;
    for (i, &tv) in times.iter().enumerate() {
        let d = (tv - t).abs();
        if best.map(|(_, bd)| d < bd).unwrap_or(true) {
            best = Some((i, d));
        }
    }
    let (i, d) = best.ok_or_else(|| format!("no saved state at t={t} (empty trajectory)"))?;
    if d <= 1e-9 * f64::max(1.0, t.abs()) {
        Ok(i)
    } else {
        Err(format!("no saved state at t={t} (nearest {})", times[i]))
    }
}

/// Evaluate one assertion against a solved trajectory; `Err` carries the
/// reason text (recorded verbatim into the result's `message`).
fn eval_assertion(
    sol: &Solution,
    assertion: &crate::types::ModelTestAssertion,
    model_name: &str,
    index_sets: &HashMap<String, IndexSet>,
) -> Result<f64, String> {
    let ti = time_index(&sol.time, assertion.time)?;
    if assertion.coords.is_some() {
        return Err("`coords` point-sampling is not supported by run_pde_tests".to_string());
    }
    let Some(reduce) = &assertion.reduce else {
        let slot = scalar_slot(&sol.state_variable_names, &assertion.variable, model_name)
            .ok_or_else(|| format!("scalar state '{}' not found", assertion.variable))?;
        return Ok(sol.state[slot][ti]);
    };
    let cells = state_cells(&sol.state_variable_names, &assertion.variable, model_name);
    if cells.is_empty() {
        return Err(format!(
            "array state '{}' has no cells in var_map",
            assertion.variable
        ));
    }
    let field: Vec<f64> = cells.iter().map(|(_, row)| sol.state[*row][ti]).collect();
    let reference = match &assertion.reference {
        None => None,
        Some(AssertionReference::Expression(expr)) => {
            let cell_tuples: Vec<Vec<i64>> = cells.iter().map(|(c, _)| c.clone()).collect();
            Some(evaluate_cellwise(expr, &cell_tuples, index_sets)?)
        }
        Some(AssertionReference::FromFile(_)) => {
            return Err(
                "only inline-expression `reference` is supported (from_file references are not)"
                    .to_string(),
            );
        }
    };
    field_reduce(reduce, &field, reference.as_deref())
}

/// Run every inline test of one model, appending per-assertion results.
fn run_model_tests(
    file: &EsmFile,
    model_name: &str,
    model: &Model,
    index_sets: &HashMap<String, IndexSet>,
    opts: &SimulateOptions,
    results: &mut Vec<PdeAssertionResult>,
) {
    let Some(tests) = &model.tests else {
        return;
    };
    for t in tests {
        let mut times: Vec<f64> = t.assertions.iter().map(|a| a.time).collect();
        times.sort_by(f64::total_cmp);
        times.dedup();
        let mut run_opts = opts.clone();
        run_opts.output_times = Some(times);
        let params = t.parameter_overrides.clone().unwrap_or_default();
        let ics = t.initial_conditions.clone().unwrap_or_default();
        let sim = simulate(
            file,
            (t.time_span.start, t.time_span.end),
            &params,
            &ics,
            &run_opts,
        )
        .map_err(|e| format!("simulate failed: {e}"));
        for (i, a) in t.assertions.iter().enumerate() {
            let (rtol, atol) = resolve_tolerance(
                model.tolerance.as_ref(),
                t.tolerance.as_ref(),
                a.tolerance.as_ref(),
            );
            let outcome = match &sim {
                Err(msg) => Err(msg.clone()),
                Ok(sol) => eval_assertion(sol, a, model_name, index_sets)
                    .map_err(|msg| format!("assertion evaluation failed: {msg}")),
            };
            let (actual, passed, message) = match outcome {
                Err(msg) => (None, false, msg),
                Ok(actual) => {
                    let ok = check_assertion(actual, a.expected, rtol, atol);
                    let msg = if ok {
                        String::new()
                    } else {
                        format!(
                            "actual={actual} expected={} (rtol={rtol}, atol={atol})",
                            a.expected
                        )
                    };
                    (Some(actual), ok, msg)
                }
            };
            results.push(PdeAssertionResult {
                model: model_name.to_string(),
                test_id: t.id.clone(),
                assertion_idx: i + 1,
                variable: a.variable.clone(),
                time: a.time,
                reduce: a.reduce.clone(),
                expected: a.expected,
                actual,
                rtol,
                atol,
                passed,
                message,
            });
        }
    }
}

/// Run every inline test (esm-spec §6.6, including the §6.6.5 PDE
/// assertions) of the selected model(s) of `file` through the official
/// simulation pathway ([`crate::simulate::simulate`], which routes
/// array/spatial files to the vectorized array runtime), and return one
/// [`PdeAssertionResult`] per assertion — carrying the ACTUAL reduction
/// value alongside pass/fail, so conformance harnesses can record and
/// cross-compare the numbers.
///
/// Per test: simulate over the test's `time_span` (with its
/// `initial_conditions` / `parameter_overrides` applied and `opts` pinning
/// the solver family and tolerances; the assertion times become the sampled
/// `output_times`); then per assertion the asserted variable's field is read
/// at the assertion time and collapsed per its `reduce` (error norms
/// evaluate the analytic `reference` expression cellwise via
/// [`evaluate_cellwise`]). An assertion with neither `coords` nor `reduce`
/// samples a scalar state. `coords` point-sampling and `from_file`
/// references are not supported and yield failed results with explanatory
/// messages. Mirrors the Julia binding's `run_pde_tests` 1:1 (tolerances per
/// §6.6.4; the pass predicate is Julia `isapprox`). Models iterate in sorted
/// name order for deterministic output.
pub fn run_pde_tests(
    file: &EsmFile,
    model_name: Option<&str>,
    opts: &SimulateOptions,
) -> Vec<PdeAssertionResult> {
    let mut results = Vec::new();
    let Some(models) = &file.models else {
        return results;
    };
    let index_sets = file.index_sets.clone().unwrap_or_default();
    let mut names: Vec<&String> = models.keys().collect();
    names.sort();
    for mname in names {
        if let Some(selected) = model_name
            && selected != mname
        {
            continue;
        }
        run_model_tests(file, mname, &models[mname], &index_sets, opts, &mut results);
    }
    results
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parse::load;
    use crate::simulate::SolverChoice;
    use crate::types::ExpressionNode;
    use serde_json::json;

    const N: i64 = 8;

    /// Cell-center coordinates x_i = (i - 1/2)/N over the `x` index set —
    /// the §9.7 grid-geometry aggregate shape (post-import expansion).
    fn x_coord_aggregate() -> serde_json::Value {
        json!({
            "op": "aggregate", "args": [], "output_idx": ["i"],
            "ranges": {"i": {"from": "x"}},
            "expr": {"op": "*",
                     "args": [{"op": "-", "args": ["i", 0.5]},
                              {"op": "/", "args": [1, N]}]},
        })
    }

    fn cos_pi_x() -> serde_json::Value {
        json!({"op": "cos",
               "args": [{"op": "*",
                         "args": [std::f64::consts::PI, x_coord_aggregate()]}]})
    }

    /// A lifted field decay model du_i/dt = -u_i seeded by the coordinate
    /// expression ic(u) = cos(pi x_i); exact solution e^{-t} cos(pi x_i).
    /// (The same document the Python port's tests are built on.)
    fn decay_doc() -> serde_json::Value {
        let idx = json!({"op": "index", "args": ["u", "i"]});
        json!({
            "esm": "0.8.0",
            "metadata": {"name": "pde_inline_decay"},
            "index_sets": {"x": {"kind": "interval", "size": N}},
            "models": {"M": {
                "variables": {
                    "u": {"type": "state", "units": "1", "shape": ["x"]},
                },
                "equations": [
                    {"lhs": {"op": "ic", "args": ["u"]}, "rhs": cos_pi_x()},
                    {"lhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
                             "ranges": {"i": [1, N]},
                             "expr": {"op": "D", "args": [idx], "wrt": "t"}},
                     "rhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
                             "ranges": {"i": [1, N]},
                             "expr": {"op": "*", "args": [-1, idx]}}},
                ],
                "tests": [{
                    "id": "decay",
                    "time_span": {"start": 0.0, "end": 1.0},
                    "assertions": [
                        {"variable": "u", "time": 0.0, "expected": 0.0,
                         "tolerance": {"abs": 1e-12}, "reduce": "L2_error",
                         "reference": cos_pi_x()},
                        {"variable": "u", "time": 1.0, "expected": 0.0,
                         "tolerance": {"abs": 1e-8}, "reduce": "L2_error",
                         "reference": {"op": "*",
                                       "args": [{"op": "exp", "args": [-1]},
                                                cos_pi_x()]}},
                        {"variable": "u", "time": 1.0, "expected": 0.0,
                         "tolerance": {"abs": 1e-9}, "reduce": "mean"},
                    ],
                }],
            }},
        })
    }

    fn tight_opts() -> SimulateOptions {
        SimulateOptions {
            solver: SolverChoice::Erk,
            reltol: 1e-12,
            abstol: 1e-14,
            ..Default::default()
        }
    }

    #[test]
    fn assertion_reduce_reference_parse_and_roundtrip() {
        let file = load(&decay_doc().to_string()).expect("decay doc loads");
        let models = file.models.as_ref().unwrap();
        let a = &models["M"].tests.as_ref().unwrap()[0].assertions[0];
        assert_eq!(a.reduce.as_deref(), Some("L2_error"));
        assert!(a.coords.is_none());
        match a.reference.as_ref().expect("reference parsed") {
            AssertionReference::Expression(expr) => match expr.as_ref() {
                Expr::Operator(node) => assert_eq!(node.op, "cos"),
                other => panic!("expected operator reference, got {other:?}"),
            },
            other => panic!("expected inline-expression reference, got {other:?}"),
        }
        // Round-trip: the §6.6.5 keys serialize back; the pure-collapser
        // form still omits `reference`.
        let ser = serde_json::to_value(&file).expect("serializes");
        let asserts = &ser["models"]["M"]["tests"][0]["assertions"];
        assert_eq!(asserts[0]["reduce"], "L2_error");
        assert_eq!(asserts[0]["reference"]["op"], "cos");
        assert_eq!(asserts[2]["reduce"], "mean");
        assert!(asserts[2].get("reference").is_none());
    }

    #[test]
    fn assertion_from_file_reference_roundtrips_verbatim() {
        let mut doc = decay_doc();
        doc["models"]["M"]["tests"][0]["assertions"][0]["reference"] =
            json!({"type": "from_file", "path": "ref.nc", "format": "netcdf"});
        let file = load(&doc.to_string()).expect("from_file reference parses");
        let models = file.models.as_ref().unwrap();
        let a = &models["M"].tests.as_ref().unwrap()[0].assertions[0];
        match a.reference.as_ref().expect("reference parsed") {
            AssertionReference::FromFile(ff) => {
                assert_eq!(ff.ref_type, "from_file");
                assert_eq!(ff.path, "ref.nc");
                assert_eq!(ff.format.as_deref(), Some("netcdf"));
            }
            other => panic!("expected from_file reference, got {other:?}"),
        }
        let ser = serde_json::to_value(&file).expect("serializes");
        assert_eq!(
            ser["models"]["M"]["tests"][0]["assertions"][0]["reference"],
            json!({"type": "from_file", "path": "ref.nc", "format": "netcdf"})
        );
    }

    #[test]
    fn evaluate_cellwise_grid_geometry() {
        let file = load(&decay_doc().to_string()).expect("decay doc loads");
        let models = file.models.as_ref().unwrap();
        let a = &models["M"].tests.as_ref().unwrap()[0].assertions[0];
        let Some(AssertionReference::Expression(expr)) = &a.reference else {
            panic!("expected inline reference");
        };
        let index_sets = file.index_sets.clone().unwrap();
        let cells: Vec<Vec<i64>> = (1..=N).map(|i| vec![i]).collect();
        let vals = evaluate_cellwise(expr, &cells, &index_sets).expect("evaluates");
        for (i, v) in (1..=N).zip(&vals) {
            let want = (std::f64::consts::PI * (i as f64 - 0.5) / N as f64).cos();
            assert!((v - want).abs() < 1e-15, "cell {i}: {v} vs {want}");
        }
        // A const-folding scalar broadcasts.
        let two = Expr::Operator(ExpressionNode {
            op: "+".to_string(),
            args: vec![Expr::Integer(1), Expr::Integer(1)],
            ..Default::default()
        });
        assert_eq!(
            evaluate_cellwise(&two, &cells, &index_sets).unwrap(),
            vec![2.0; N as usize]
        );
    }

    #[test]
    fn field_reduce_semantics() {
        let actual = [1.0, 2.0, 3.0];
        let reference = [1.0, 2.0, 5.0];
        let l2 = field_reduce("L2_error", &actual, Some(&reference)).unwrap();
        assert!((l2 - 2.0 / 30.0f64.sqrt()).abs() < 1e-15);
        assert_eq!(
            field_reduce("Linf_error", &actual, Some(&reference)).unwrap(),
            2.0
        );
        assert_eq!(field_reduce("mean", &actual, None).unwrap(), 2.0);
        assert_eq!(field_reduce("max", &actual, None).unwrap(), 3.0);
        assert_eq!(field_reduce("min", &actual, None).unwrap(), 1.0);
        assert!(field_reduce("L2_error", &actual, None).is_err()); // reference required
        assert!(field_reduce("L2_error", &actual, Some(&[0.0, 0.0, 0.0])).is_err()); // zero norm
        assert!(field_reduce("integral", &actual, None).is_err());
    }

    #[test]
    fn state_cells_matching_and_order() {
        let names: Vec<String> = ["M.v[1]", "w", "wat", "M.u[1]", "M.u[2]", "x[oops]"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        // Reorder rows so numeric cell sorting is observable: u[10] before u[2].
        let names2: Vec<String> = ["M.u[2]", "M.u[1]", "M.u[10]", "M.v[1]", "w"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        let cells = state_cells(&names2, "u", "M");
        assert_eq!(
            cells,
            vec![(vec![1], 1), (vec![2], 0), (vec![10], 2)] // numeric cell order
        );
        assert_eq!(state_cells(&names2, "u", "Other"), cells); // bare-stem match
        assert_eq!(state_cells(&names, "w", "M"), vec![]); // scalars never match
        assert_eq!(state_cells(&names, "x", "M"), vec![]); // non-integer suffix
        assert_eq!(scalar_slot(&names, "w", "M"), Some(1));
    }

    #[test]
    fn tolerance_precedence_and_isapprox_semantics() {
        let model_tol = Tolerance {
            rel: Some(1e-2),
            abs: None,
        };
        let test_tol = Tolerance {
            rel: None,
            abs: Some(1e-3),
        };
        let assertion_tol = Tolerance {
            rel: Some(1e-6),
            abs: Some(1e-9),
        };
        assert_eq!(
            resolve_tolerance(Some(&model_tol), Some(&test_tol), Some(&assertion_tol)),
            (1e-6, 1e-9)
        );
        assert_eq!(
            resolve_tolerance(Some(&model_tol), Some(&test_tol), None),
            (0.0, 1e-3)
        );
        assert_eq!(resolve_tolerance(Some(&model_tol), None, None), (1e-2, 0.0));
        assert_eq!(resolve_tolerance(None, None, None), (DEFAULT_REL_TOL, 0.0));
        // Julia isapprox: |a-e| <= max(atol, rtol*max(|a|,|e|)).
        assert!(check_assertion(1.0000009, 1.0, 1e-6, 0.0));
        assert!(!check_assertion(1.000002, 1.0, 1e-6, 0.0));
        assert!(check_assertion(0.0, 1e-10, 0.0, 1e-9));
        assert!(check_assertion(2.0, 2.0, 0.0, 0.0)); // exact-equality mode
        assert!(!check_assertion(2.0, 2.0000001, 0.0, 0.0));
    }

    #[test]
    fn run_pde_tests_decay_field() {
        let file = load(&decay_doc().to_string()).expect("decay doc loads");
        let results = run_pde_tests(&file, Some("M"), &tight_opts());
        assert_eq!(
            results.iter().map(|r| r.assertion_idx).collect::<Vec<_>>(),
            vec![1, 2, 3]
        );
        // t=0: the ic seeding IS the reference — identical evaluation
        // machinery on both sides, so the diff is exactly zero.
        assert!(results[0].passed, "t=0: {}", results[0].message);
        assert!(results[0].actual.unwrap() < 1e-14);
        // t=1: integrator-level error only.
        assert!(results[1].passed, "t=1: {}", results[1].message);
        assert!(results[1].actual.unwrap() < 1e-8);
        assert!(results[2].passed, "mean: {}", results[2].message);
        assert!(results[2].actual.unwrap().abs() < 1e-9);
        assert!(
            results
                .iter()
                .all(|r| matches!(r.reduce.as_deref(), Some("L2_error") | Some("mean")))
        );
        assert!(
            results
                .iter()
                .all(|r| r.model == "M" && r.test_id == "decay")
        );
    }

    #[test]
    fn run_pde_tests_reports_failing_assertion_with_actual() {
        let mut doc = decay_doc();
        // An impossible expectation: the decayed field cannot still match
        // its initial state at t=1 to 1e-12.
        doc["models"]["M"]["tests"][0]["assertions"] = json!([
            {"variable": "u", "time": 1.0, "expected": 0.0,
             "tolerance": {"abs": 1e-12}, "reduce": "L2_error",
             "reference": cos_pi_x()},
        ]);
        let file = load(&doc.to_string()).expect("doc loads");
        let results = run_pde_tests(&file, Some("M"), &tight_opts());
        assert_eq!(results.len(), 1);
        let r = &results[0];
        assert!(!r.passed);
        let want = 1.0 - (-1.0f64).exp();
        let actual = r.actual.expect("actual recorded on failure");
        assert!(
            (actual - want).abs() <= 1e-6 * want,
            "actual {actual} vs {want}"
        );
        assert!(r.message.contains("actual="));
    }

    #[test]
    fn coordinate_expression_ic_seeds_grid() {
        // The §11.4.1 case-3 seeding path in isolation: u(0) = cos(pi x_i).
        let file = load(&decay_doc().to_string()).expect("decay doc loads");
        let mut opts = tight_opts();
        opts.output_times = Some(vec![0.0]);
        let sol = simulate(&file, (0.0, 1.0), &HashMap::new(), &HashMap::new(), &opts)
            .expect("simulates");
        let cells = state_cells(&sol.state_variable_names, "u", "M");
        assert_eq!(cells.len(), N as usize);
        for (cell, row) in &cells {
            let want = (std::f64::consts::PI * (cell[0] as f64 - 0.5) / N as f64).cos();
            let got = sol.state[*row][0];
            assert!((got - want).abs() < 1e-15, "cell {cell:?}: {got} vs {want}");
        }
    }
}
