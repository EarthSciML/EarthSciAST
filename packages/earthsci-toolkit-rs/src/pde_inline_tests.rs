//! pde_inline_tests — the §6.6.5-capable inline-test runner over the
//! vectorized array simulation pathway (the Rust mirror of the Julia
//! binding's `pde_inline_tests.jl` and the Python `pde_inline_tests.py`).
//!
//! A PDE model's inline tests (esm-spec §6.6.5) assert REDUCTIONS of a
//! spatial field — `reduce: L2_error | Linf_error` against a `reference`,
//! or the pure collapsers `integral | mean | max | min` — or point-sample it
//! via `coords`. This module drives the official
//! [`crate::simulate::simulate`] pipeline (which dispatches array/spatial
//! files to the vectorized `simulate_array` runtime) and collapses fields
//! per assertion.
//!
//! Cross-binding pinned conventions (identical in the Julia / Python / Rust
//! bindings; the esm-spec leaves these open, so determinism requires
//! pinning):
//!
//! 1. `coords` point-sampling — coords values are positions in INDEX space
//!    (1-based, fractional allowed) along the named interval index sets;
//!    sampling picks the NEAREST grid index, with exact half-way ties
//!    rounding DOWN toward the lower index (`idx = ceil(c - 1/2)`). Keys
//!    must name the asserted field's index sets; a strict subset pins only
//!    when every remaining dimension has exactly one sample; the resolved
//!    index must lie in `1..=size`. Mutually exclusive with `reduce`.
//! 2. `integral` reduce — the uniform-cell Riemann sum under a UNIT total
//!    domain measure per axis: `integral = Σ field / N_cells = mean(field)`.
//!    Authors of non-unit physical domains must scale the expectation until
//!    the spec grows a measure concept. This is exactly the measure
//!    convention under which the relative-L2 reduction is measure-free (the
//!    per-cell measure cancels between numerator and denominator).
//! 3. `from_file` references — `{type: "from_file", path, format?}`: `path`
//!    resolves relative to the .esm file's directory (the
//!    [`run_pde_tests_with_base_dir`] `base_dir`; [`run_pde_tests`] resolves
//!    against the working directory); the default and only v1 `format` is
//!    "json" — a row-major nested JSON array exactly matching the field's
//!    shape (validated; mismatch is a clear error). The loaded array is used
//!    exactly like an evaluated inline reference in the error-norm
//!    reductions.
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
use std::path::Path;

use serde::Serialize;

use crate::simulate::{SimulateOptions, Solution, simulate_with_inspection};
use crate::simulate_array::{BuildInspection, Value, eval_buildtime_field};
use crate::types::{
    AssertionReference, EsmFile, Expr, FromFileReference, IndexSet, Model, Tolerance, VariableType,
};

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
/// - `"integral"` — the uniform-cell Riemann sum under a UNIT total domain
///   measure per axis: `Σ field / N_cells`, i.e. exactly `mean`. This is the
///   pinned cross-binding convention (the same measure convention under which
///   the relative-L2 reduction is measure-free); non-unit physical domains
///   must be scaled by the author until the spec grows a measure concept.
/// - `"mean" | "max" | "min"` — pure collapsers of `actual`.
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
        "mean" | "integral" => {
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

/// A §6.6.5 assertion may target an ARRAY OBSERVED (e.g. a rule output
/// surfaced "for direct assertion", like the MPAS `div_flux`) rather than a
/// state: an observed carries no ODE slot, so its field is read from the
/// [`BuildInspection`]'s `setup_arrays` — the STATE-FREE observed arrays the
/// run materialized through the official observed machinery. State-free
/// observeds only: a state- or time-dependent observed is absent from
/// `setup_arrays` by construction, so this returns `None` and the caller
/// errors like before (mirroring the Julia `_observed_field`, whose
/// `evaluate_cellwise` leaves a state reference unbound). Cells are enumerated
/// from the declared shape's interval index sets, in sorted (lexicographic)
/// order. Returns `(field, cells)` or `None` when the variable is not such an
/// observed.
fn observed_field(
    file: &EsmFile,
    model_name: &str,
    variable: &str,
    insp: &BuildInspection,
    index_sets: &HashMap<String, IndexSet>,
) -> Option<(Vec<f64>, Vec<Vec<i64>>)> {
    let v = file
        .models
        .as_ref()?
        .get(model_name)?
        .variables
        .get(variable)?;
    if v.var_type != VariableType::Observed {
        return None;
    }
    let shape = v.shape.as_ref()?;
    if shape.is_empty() {
        return None;
    }
    let mut exts: Vec<usize> = Vec::with_capacity(shape.len());
    for s in shape {
        let iset = index_sets.get(s)?;
        if iset.kind != "interval" {
            return None;
        }
        exts.push(usize::try_from(iset.size?).ok()?);
    }
    // Flattening prefixes observed names with the owning model; the
    // single-model path keeps the bare name.
    let qualified = format!("{model_name}.{variable}");
    let arr = insp
        .setup_arrays
        .get(&qualified)
        .or_else(|| insp.setup_arrays.get(variable))?;
    if arr.ndim() != exts.len()
        || arr
            .shape()
            .iter()
            .zip(&exts)
            .any(|(have, want)| have < want)
    {
        return None;
    }
    // Lexicographically ordered 1-based cell tuples (row-major enumeration is
    // lexicographic), matching the Julia reference's sorted CartesianIndices.
    let total: usize = exts.iter().product();
    let mut cells: Vec<Vec<i64>> = Vec::with_capacity(total);
    let mut cur = vec![1i64; exts.len()];
    for _ in 0..total {
        cells.push(cur.clone());
        for d in (0..exts.len()).rev() {
            if (cur[d] as usize) < exts[d] {
                cur[d] += 1;
                break;
            }
            cur[d] = 1;
        }
    }
    let field: Vec<f64> = cells
        .iter()
        .map(|c| {
            let idx: Vec<usize> = c.iter().map(|&i| (i - 1) as usize).collect();
            arr[ndarray::IxDyn(&idx)]
        })
        .collect();
    Some((field, cells))
}

/// The asserted variable's declared spatial shape (ordered index-set names).
/// `Err` when the variable is missing or scalar — a `coords` assertion is
/// ill-formed on a 0-D variable per esm-spec §6.6.5 (identical to the Julia
/// reference's `_variable_shape`).
fn variable_shape(file: &EsmFile, model_name: &str, variable: &str) -> Result<Vec<String>, String> {
    let model = file
        .models
        .as_ref()
        .and_then(|ms| ms.get(model_name))
        .ok_or_else(|| format!("model '{model_name}' not found"))?;
    let v = model
        .variables
        .get(variable)
        .ok_or_else(|| format!("variable '{variable}' is not declared in model '{model_name}'"))?;
    match &v.shape {
        Some(shape) if !shape.is_empty() => Ok(shape.clone()),
        _ => Err(format!(
            "`coords` requires a spatially-shaped variable; '{variable}' is scalar"
        )),
    }
}

/// Resolve a §6.6.5 `coords` map to a concrete 1-based cell tuple over
/// `shape` (the field's ordered index-set names), per the pinned
/// cross-binding convention: coords values are positions in INDEX space
/// (1-based, fractional allowed) along interval index sets; sampling =
/// nearest grid index with exact half-way ties rounding DOWN
/// (`idx = ceil(c - 1/2)`). A strict subset of dimensions may be pinned only
/// when every remaining dimension is singleton (identical to the Julia
/// reference's `_coords_cell`).
fn coords_cell(
    coords: &HashMap<String, f64>,
    shape: &[String],
    index_sets: &HashMap<String, IndexSet>,
) -> Result<Vec<i64>, String> {
    for k in coords.keys() {
        if !shape.iter().any(|s| s == k) {
            return Err(format!(
                "`coords` names unknown dimension '{k}' (field dimensions: {})",
                shape.join(", ")
            ));
        }
    }
    let mut cell = Vec::with_capacity(shape.len());
    for s in shape {
        let size = index_sets
            .get(s)
            .filter(|iset| iset.kind == "interval")
            .and_then(|iset| iset.size)
            .ok_or_else(|| {
                format!(
                    "`coords` sampling requires interval index sets with a \
                     declared size; '{s}' is not one"
                )
            })?;
        match coords.get(s) {
            Some(&c) => {
                let idx = (c - 0.5).ceil() as i64; // nearest index; exact ties round DOWN
                if idx < 1 || idx > size {
                    return Err(format!(
                        "`coords` position {c} along '{s}' resolves to index \
                         {idx}, outside 1..{size}"
                    ));
                }
                cell.push(idx);
            }
            None => {
                if size != 1 {
                    return Err(format!(
                        "`coords` leaves dimension '{s}' unpinned with {size} \
                         samples; a strict subset pins only when every \
                         remaining dimension is singleton"
                    ));
                }
                cell.push(1);
            }
        }
    }
    Ok(cell)
}

/// Walk a row-major nested JSON array to the value at 1-based `cell`,
/// validating each level's extent against `exts` (the field's per-dimension
/// extents). The full Cartesian cell sweep visits every node, so ragged or
/// mis-sized payloads always surface a shape-mismatch error.
fn nested_at(data: &serde_json::Value, cell: &[i64], exts: &[usize]) -> Result<f64, String> {
    let mut node = data;
    for (d, &i) in cell.iter().enumerate() {
        let arr = node.as_array().ok_or_else(|| {
            format!(
                "from_file reference shape mismatch along dimension {}: \
                 expected a nested array of length {}",
                d + 1,
                exts[d]
            )
        })?;
        if arr.len() != exts[d] {
            return Err(format!(
                "from_file reference shape mismatch along dimension {}: \
                 expected length {}, found {}",
                d + 1,
                exts[d],
                arr.len()
            ));
        }
        node = &arr[(i - 1) as usize];
    }
    node.as_f64().ok_or_else(|| {
        format!(
            "from_file reference shape mismatch at cell [{}]: expected a number",
            cell.iter()
                .map(|c| c.to_string())
                .collect::<Vec<_>>()
                .join(",")
        )
    })
}

/// Load a `{type: "from_file", path, format?}` reference (esm-spec §6.6.5)
/// as the per-cell reference field over `cell_tuples`, per the pinned
/// cross-binding convention: `path` resolves relative to `base_dir` (the
/// .esm file's directory; `None` resolves against the working directory);
/// the default and only v1 `format` is "json" — a row-major nested array
/// exactly matching the field's shape (identical to the Julia reference's
/// `_from_file_reference`).
fn from_file_reference(
    ff: &FromFileReference,
    base_dir: Option<&Path>,
    cell_tuples: &[Vec<i64>],
) -> Result<Vec<f64>, String> {
    let fmt = ff
        .format
        .as_deref()
        .map(str::to_lowercase)
        .unwrap_or_else(|| "json".to_string());
    if fmt != "json" {
        return Err(format!(
            "from_file reference format '{fmt}' is not supported (v1 supports \"json\" only)"
        ));
    }
    let p = Path::new(&ff.path);
    let resolved = if p.is_absolute() {
        p.to_path_buf()
    } else {
        base_dir.unwrap_or_else(|| Path::new(".")).join(p)
    };
    if !resolved.is_file() {
        return Err(format!(
            "from_file reference file not found: {}",
            resolved.display()
        ));
    }
    let text = std::fs::read_to_string(&resolved)
        .map_err(|e| format!("from_file reference read failed: {e}"))?;
    let data: serde_json::Value = serde_json::from_str(&text)
        .map_err(|e| format!("from_file reference is not valid JSON: {e}"))?;
    if cell_tuples.is_empty() {
        return Err("from_file reference: field has no cells".to_string());
    }
    let nd = cell_tuples[0].len();
    let exts: Vec<usize> = (0..nd)
        .map(|d| {
            cell_tuples
                .iter()
                .map(|c| c[d].max(0) as usize)
                .max()
                .unwrap_or(0)
        })
        .collect();
    cell_tuples
        .iter()
        .map(|c| nested_at(&data, c, &exts))
        .collect()
}

/// Evaluate one assertion against a solved trajectory; `Err` carries the
/// reason text (recorded verbatim into the result's `message`).
fn eval_assertion(
    sol: &Solution,
    assertion: &crate::types::ModelTestAssertion,
    model_name: &str,
    index_sets: &HashMap<String, IndexSet>,
    file: &EsmFile,
    insp: &BuildInspection,
    base_dir: Option<&Path>,
) -> Result<f64, String> {
    let ti = time_index(&sol.time, assertion.time)?;
    if assertion.coords.is_some() && assertion.reduce.is_some() {
        return Err("`coords` and `reduce` are mutually exclusive".to_string());
    }
    if assertion.coords.is_none() && assertion.reduce.is_none() {
        let slot = scalar_slot(&sol.state_variable_names, &assertion.variable, model_name)
            .ok_or_else(|| format!("scalar state '{}' not found", assertion.variable))?;
        return Ok(sol.state[slot][ti]);
    }
    // `coords` validation runs BEFORE field materialization so a coords
    // assertion on a scalar variable fails with the §6.6.5 coords-specific
    // message (identical to the Julia reference).
    let coords_target = match &assertion.coords {
        Some(coords) => {
            let shape = variable_shape(file, model_name, &assertion.variable)?;
            Some(coords_cell(coords, &shape, index_sets)?)
        }
        None => None,
    };
    let cells = state_cells(&sol.state_variable_names, &assertion.variable, model_name);
    let (field, cell_tuples): (Vec<f64>, Vec<Vec<i64>>) = if !cells.is_empty() {
        (
            cells.iter().map(|(_, row)| sol.state[*row][ti]).collect(),
            cells.iter().map(|(c, _)| c.clone()).collect(),
        )
    } else {
        // No ODE slots: try a state-free ARRAY OBSERVED (a rule output
        // asserted directly, §6.6.5).
        observed_field(file, model_name, &assertion.variable, insp, index_sets).ok_or_else(
            || {
                format!(
                    "array state '{}' has no cells in var_map",
                    assertion.variable
                )
            },
        )?
    };
    if let Some(target) = coords_target {
        let pos = cell_tuples
            .iter()
            .position(|c| *c == target)
            .ok_or_else(|| {
                format!(
                    "no grid sample at cell [{}] of '{}'",
                    target
                        .iter()
                        .map(|c| c.to_string())
                        .collect::<Vec<_>>()
                        .join(","),
                    assertion.variable
                )
            })?;
        return Ok(field[pos]);
    }
    let reduce = assertion
        .reduce
        .as_ref()
        .expect("reduce is set on the non-coords array path");
    let reference = match &assertion.reference {
        None => None,
        Some(AssertionReference::Expression(expr)) => {
            Some(evaluate_cellwise(expr, &cell_tuples, index_sets)?)
        }
        Some(AssertionReference::FromFile(ff)) => {
            Some(from_file_reference(ff, base_dir, &cell_tuples)?)
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
    base_dir: Option<&Path>,
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
        // Build-observability sink: assertions on ARRAY OBSERVEDS (no ODE
        // slot) read their state-free materialized field from here
        // (`observed_field`).
        let mut insp = BuildInspection::default();
        let sim = simulate_with_inspection(
            file,
            (t.time_span.start, t.time_span.end),
            &params,
            &ics,
            &run_opts,
            &mut insp,
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
                Ok(sol) => eval_assertion(sol, a, model_name, index_sets, file, &insp, base_dir)
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
/// at the assertion time and either point-sampled per its `coords`
/// (positions in 1-based INDEX space; nearest grid index, exact ties
/// rounding DOWN — the pinned cross-binding convention) or collapsed per its
/// `reduce` (error norms evaluate the `reference` — an analytic expression
/// cellwise via [`evaluate_cellwise`], or a `{type: "from_file", path,
/// format?}` JSON snapshot resolved against the working directory; use
/// [`run_pde_tests_with_base_dir`] to anchor at the .esm file's directory).
/// An assertion with neither `coords` nor `reduce` samples a scalar state.
/// Mirrors the Julia binding's `run_pde_tests` 1:1 (tolerances per §6.6.4;
/// the pass predicate is Julia `isapprox`). Models iterate in sorted name
/// order for deterministic output.
pub fn run_pde_tests(
    file: &EsmFile,
    model_name: Option<&str>,
    opts: &SimulateOptions,
) -> Vec<PdeAssertionResult> {
    run_pde_tests_with_base_dir(file, model_name, opts, None)
}

/// [`run_pde_tests`] with an explicit `base_dir` anchoring `from_file`
/// reference paths (esm-spec §6.6.5, pinned convention: relative to the .esm
/// file's directory). `None` resolves relative paths against the working
/// directory — callers that loaded the document from a path should pass that
/// path's parent, matching the Julia / Python bindings' default.
pub fn run_pde_tests_with_base_dir(
    file: &EsmFile,
    model_name: Option<&str>,
    opts: &SimulateOptions,
    base_dir: Option<&Path>,
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
        run_model_tests(
            file,
            mname,
            &models[mname],
            &index_sets,
            opts,
            base_dir,
            &mut results,
        );
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
        assert!(field_reduce("wat", &actual, None).is_err()); // unknown kind
    }

    /// Pinned cross-binding convention: `integral` is the uniform-cell
    /// Riemann sum under a UNIT total domain measure per axis — Σ field /
    /// N_cells, exactly `mean` (NOT the bare sum).
    #[test]
    fn field_reduce_integral_is_unit_measure_mean() {
        let f = [1.0, 2.0, 3.0];
        assert_eq!(field_reduce("integral", &f, None).unwrap(), 2.0);
        assert_eq!(
            field_reduce("integral", &f, None).unwrap(),
            field_reduce("mean", &f, None).unwrap()
        );
        let g: Vec<f64> = (1..=8).map(|i| (i as f64 - 0.5) / 8.0).collect();
        assert_eq!(field_reduce("integral", &g, None).unwrap(), 0.5);
        assert!(field_reduce("integral", &[], None).is_err());
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
        let sol =
            crate::simulate::simulate(&file, (0.0, 1.0), &HashMap::new(), &HashMap::new(), &opts)
                .expect("simulates");
        let cells = state_cells(&sol.state_variable_names, "u", "M");
        assert_eq!(cells.len(), N as usize);
        for (cell, row) in &cells {
            let want = (std::f64::consts::PI * (cell[0] as f64 - 0.5) / N as f64).cos();
            let got = sol.state[*row][0];
            assert!((got - want).abs() < 1e-15, "cell {cell:?}: {got} vs {want}");
        }
    }

    /// §6.6.5 assertions may target a state-free ARRAY OBSERVED directly (a
    /// rule output surfaced "for direct assertion", like the MPAS `div_flux`
    /// max/min): the field is read from the BuildInspection's materialized
    /// state-free setup arrays. A STATE-DEPENDENT observed must keep erroring
    /// exactly like before (its build-time snapshot would be stale).
    fn observed_assert_doc() -> serde_json::Value {
        let g = json!({"op": "aggregate", "args": [], "output_idx": ["i"],
                       "ranges": {"i": {"from": "x"}},
                       "expr": {"op": "*", "args": ["i", "i"]}});
        let h = json!({"op": "aggregate", "args": ["u"], "output_idx": ["i"],
                       "ranges": {"i": {"from": "x"}},
                       "expr": {"op": "+",
                                "args": [{"op": "index", "args": ["u", "i"]}, 1]}});
        json!({
            "esm": "0.8.0",
            "metadata": {"name": "observed_assertions"},
            "index_sets": {"x": {"kind": "interval", "size": 3}},
            "models": {"M": {
                "variables": {
                    "u": {"type": "state", "units": "1", "shape": ["x"]},
                    "g": {"type": "observed", "units": "1", "shape": ["x"],
                          "expression": g},
                    "h": {"type": "observed", "units": "1", "shape": ["x"],
                          "expression": h},
                },
                "equations": [
                    {"lhs": {"op": "ic", "args": ["u"]}, "rhs": 0.0},
                    {"lhs": {"op": "D", "args": ["u"], "wrt": "t"}, "rhs": 0.0},
                ],
                "tests": [{
                    "id": "obs",
                    "time_span": {"start": 0.0, "end": 1.0},
                    "assertions": [
                        {"variable": "g", "time": 1.0, "expected": 9.0,
                         "tolerance": {"abs": 1e-12}, "reduce": "max"},
                        {"variable": "g", "time": 1.0, "expected": 1.0,
                         "tolerance": {"abs": 1e-12}, "reduce": "min"},
                        {"variable": "h", "time": 1.0, "expected": 1.0,
                         "tolerance": {"abs": 1e-12}, "reduce": "max"},
                    ],
                }],
            }},
        })
    }

    #[test]
    fn state_free_array_observed_assertions_evaluate_directly() {
        let file = load(&observed_assert_doc().to_string()).expect("doc loads");
        let results = run_pde_tests(&file, Some("M"), &tight_opts());
        assert_eq!(results.len(), 3);
        // g = [1, 4, 9] (index arithmetic, exact): max and min pass with the
        // exact reductions recorded.
        assert!(results[0].passed, "g max: {}", results[0].message);
        assert_eq!(results[0].actual, Some(9.0));
        assert!(results[1].passed, "g min: {}", results[1].message);
        assert_eq!(results[1].actual, Some(1.0));
        // h reads the state u, so it is NOT state-free: the assertion errors
        // with the pre-existing no-cells message rather than consuming a
        // stale build-time snapshot.
        assert!(!results[2].passed);
        assert!(
            results[2].message.contains("has no cells in var_map"),
            "unexpected message: {}",
            results[2].message
        );
        assert_eq!(results[2].actual, None);
    }

    // -----------------------------------------------------------------------
    // §6.6.5 coords point-sampling (pinned convention: 1-based INDEX space,
    // nearest grid index, exact half-way ties round DOWN)
    // -----------------------------------------------------------------------

    fn coords_assert(coords: serde_json::Value, time: f64, expected: f64) -> serde_json::Value {
        json!({"variable": "u", "time": time, "expected": expected,
               "tolerance": {"abs": 1e-9}, "coords": coords})
    }

    fn decay_doc_with(assertions: serde_json::Value) -> serde_json::Value {
        let mut doc = decay_doc();
        doc["models"]["M"]["tests"][0]["assertions"] = assertions;
        doc
    }

    #[test]
    fn run_pde_tests_coords_sampling_nearest_ties_down() {
        let u = |i: f64| (std::f64::consts::PI * (i - 0.5) / N as f64).cos();
        let mut doc = decay_doc_with(json!([
            coords_assert(json!({"x": 3}), 0.0, u(3.0)),
            coords_assert(json!({"x": 3.5}), 0.0, u(3.0)), // tie → lower index 3
            coords_assert(json!({"x": 2.5}), 0.0, u(2.0)), // tie → 2
            coords_assert(json!({"x": 5.6}), 0.0, u(6.0)), // nearest → 6
            coords_assert(json!({"x": 8.5}), 0.0, u(8.0)), // tie at top edge → 8
        ]));
        doc["models"]["M"]["tests"][0]["assertions"]
            .as_array_mut()
            .unwrap()
            .push({
                let mut a = coords_assert(json!({"x": 3}), 1.0, (-1.0f64).exp() * u(3.0));
                a["tolerance"] = json!({"abs": 1e-8});
                a
            });
        let file = load(&doc.to_string()).expect("doc loads");
        let results = run_pde_tests(&file, Some("M"), &tight_opts());
        assert_eq!(results.len(), 6);
        for r in &results {
            assert!(r.passed, "assertion {}: {}", r.assertion_idx, r.message);
            assert!(r.reduce.is_none());
        }
        assert_eq!(results[0].actual, results[1].actual);
    }

    #[test]
    fn run_pde_tests_coords_validation_rejections() {
        let file = load(
            &decay_doc_with(json!([
                coords_assert(json!({"y": 1.0}), 0.0, 0.0),
                coords_assert(json!({"x": 0.4}), 0.0, 0.0), // → index 0
                coords_assert(json!({"x": 8.6}), 0.0, 0.0), // → index 9
            ]))
            .to_string(),
        )
        .expect("doc loads");
        let results = run_pde_tests(&file, Some("M"), &tight_opts());
        assert_eq!(results.len(), 3);
        for r in &results {
            assert!(!r.passed);
            assert_eq!(r.actual, None);
        }
        assert!(results[0].message.contains("names unknown dimension 'y'"));
        assert!(results[1].message.contains("outside 1..8"));
        assert!(results[1].message.contains("resolves to index 0"));
        assert!(results[2].message.contains("resolves to index 9"));
    }

    #[test]
    fn run_pde_tests_coords_on_scalar_variable_rejected() {
        // coords on a scalar (0-D) variable is ill-formed per §6.6.5.
        let doc = json!({
            "esm": "0.8.0",
            "metadata": {"name": "scalar_coords"},
            "models": {"M": {
                "variables": {"z": {"type": "state", "units": "1", "default": 1.0}},
                "equations": [
                    {"lhs": {"op": "D", "args": ["z"], "wrt": "t"}, "rhs": 0.0}],
                "tests": [{
                    "id": "scalar",
                    "time_span": {"start": 0.0, "end": 1.0},
                    "assertions": [{"variable": "z", "time": 1.0, "expected": 1.0,
                                    "tolerance": {"abs": 1e-9},
                                    "coords": {"x": 1.0}}],
                }],
            }},
        });
        let file = load(&doc.to_string()).expect("doc loads");
        let results = run_pde_tests(&file, Some("M"), &tight_opts());
        assert_eq!(results.len(), 1);
        assert!(!results[0].passed);
        assert!(
            results[0]
                .message
                .contains("requires a spatially-shaped variable"),
            "unexpected message: {}",
            results[0].message
        );
    }

    #[test]
    fn coords_and_reduce_are_mutually_exclusive_at_load() {
        let doc = decay_doc_with(json!([
            {"variable": "u", "time": 0.0, "expected": 0.0,
             "coords": {"x": 1}, "reduce": "mean"},
        ]));
        assert!(load(&doc.to_string()).is_err(), "schema must reject");
    }

    /// du_ij/dt = 1 with u(0) = 0, so u(t) = t everywhere: pins the
    /// strict-subset rule — pinning only `x` is legal iff `y` is singleton.
    fn doc_2d(ny: i64) -> serde_json::Value {
        let idx = json!({"op": "index", "args": ["u", "i", "j"]});
        let ranges = json!({"i": [1, 4], "j": [1, ny]});
        json!({
            "esm": "0.8.0",
            "metadata": {"name": "pde_inline_2d"},
            "index_sets": {"x": {"kind": "interval", "size": 4},
                           "y": {"kind": "interval", "size": ny}},
            "models": {"M": {
                "variables": {"u": {"type": "state", "units": "1",
                                    "shape": ["x", "y"]}},
                "equations": [
                    {"lhs": {"op": "ic", "args": ["u"]}, "rhs": 0.0},
                    {"lhs": {"op": "aggregate", "args": [],
                             "output_idx": ["i", "j"], "ranges": ranges,
                             "expr": {"op": "D", "args": [idx], "wrt": "t"}},
                     "rhs": {"op": "aggregate", "args": [],
                             "output_idx": ["i", "j"], "ranges": ranges,
                             "expr": 1.0}},
                ],
                "tests": [{
                    "id": "subset",
                    "time_span": {"start": 0.0, "end": 1.0},
                    "assertions": [{"variable": "u", "time": 1.0,
                                    "expected": 1.0,
                                    "tolerance": {"abs": 1e-8},
                                    "coords": {"x": 2}}],
                }],
            }},
        })
    }

    #[test]
    fn coords_strict_subset_requires_singleton_remainder() {
        let ok_file = load(&doc_2d(1).to_string()).expect("doc loads");
        let ok = run_pde_tests(&ok_file, Some("M"), &tight_opts());
        assert_eq!(ok.len(), 1);
        assert!(ok[0].passed, "{}", ok[0].message);
        assert!((ok[0].actual.unwrap() - 1.0).abs() < 1e-8);

        let bad_file = load(&doc_2d(3).to_string()).expect("doc loads");
        let bad = run_pde_tests(&bad_file, Some("M"), &tight_opts());
        assert_eq!(bad.len(), 1);
        assert!(!bad[0].passed);
        assert!(
            bad[0]
                .message
                .contains("leaves dimension 'y' unpinned with 3 samples"),
            "unexpected message: {}",
            bad[0].message
        );
    }

    // -----------------------------------------------------------------------
    // §6.6.5 from_file references (pinned convention: path relative to the
    // .esm file's directory / explicit base_dir; v1 format json — row-major
    // nested array in field shape)
    // -----------------------------------------------------------------------

    fn from_file_assert(reference: serde_json::Value, reduce: &str) -> serde_json::Value {
        json!({"variable": "u", "time": 0.0, "expected": 0.0,
               "tolerance": {"abs": 1e-12}, "reduce": reduce,
               "reference": reference})
    }

    fn ic_cos_values() -> Vec<f64> {
        (1..=N)
            .map(|i| (std::f64::consts::PI * (i as f64 - 0.5) / N as f64).cos())
            .collect()
    }

    #[test]
    fn from_file_reference_happy_path() {
        let dir = tempfile::tempdir().expect("tempdir");
        std::fs::write(
            dir.path().join("ref.json"),
            serde_json::to_string(&ic_cos_values()).unwrap(),
        )
        .unwrap();
        let doc = decay_doc_with(json!([
            from_file_assert(json!({"type": "from_file", "path": "ref.json"}), "L2_error"),
            from_file_assert(
                json!({"type": "from_file", "path": "ref.json", "format": "json"}),
                "Linf_error"
            ),
        ]));
        let file = load(&doc.to_string()).expect("doc loads");
        let results =
            run_pde_tests_with_base_dir(&file, Some("M"), &tight_opts(), Some(dir.path()));
        assert_eq!(results.len(), 2);
        // Identical evaluation machinery seeded the ic, so the diff is 0.
        for r in &results {
            assert!(r.passed, "assertion {}: {}", r.assertion_idx, r.message);
            assert_eq!(r.actual, Some(0.0));
        }
    }

    #[test]
    fn from_file_reference_shape_mismatch() {
        let dir = tempfile::tempdir().expect("tempdir");
        let vals = ic_cos_values();
        std::fs::write(
            dir.path().join("short.json"),
            serde_json::to_string(&vals[..7]).unwrap(),
        )
        .unwrap();
        let file = load(
            &decay_doc_with(json!([from_file_assert(
                json!({"type": "from_file", "path": "short.json"}),
                "L2_error"
            )]))
            .to_string(),
        )
        .expect("doc loads");
        let r = &run_pde_tests_with_base_dir(&file, Some("M"), &tight_opts(), Some(dir.path()))[0];
        assert!(!r.passed);
        assert!(
            r.message
                .contains("shape mismatch along dimension 1: expected length 8, found 7"),
            "unexpected message: {}",
            r.message
        );

        // Deeper nesting than the field's rank.
        let nested: Vec<Vec<f64>> = vals.iter().map(|&v| vec![v]).collect();
        std::fs::write(
            dir.path().join("deep.json"),
            serde_json::to_string(&nested).unwrap(),
        )
        .unwrap();
        let file = load(
            &decay_doc_with(json!([from_file_assert(
                json!({"type": "from_file", "path": "deep.json"}),
                "L2_error"
            )]))
            .to_string(),
        )
        .expect("doc loads");
        let r = &run_pde_tests_with_base_dir(&file, Some("M"), &tight_opts(), Some(dir.path()))[0];
        assert!(!r.passed);
        assert!(
            r.message.contains("expected a number"),
            "unexpected message: {}",
            r.message
        );
    }

    #[test]
    fn from_file_reference_missing_file_and_format() {
        let dir = tempfile::tempdir().expect("tempdir");
        let file = load(
            &decay_doc_with(json!([from_file_assert(
                json!({"type": "from_file", "path": "nope.json"}),
                "L2_error"
            )]))
            .to_string(),
        )
        .expect("doc loads");
        let r = &run_pde_tests_with_base_dir(&file, Some("M"), &tight_opts(), Some(dir.path()))[0];
        assert!(!r.passed);
        assert!(
            r.message.contains("file not found"),
            "unexpected message: {}",
            r.message
        );

        std::fs::write(dir.path().join("ref.json"), "[1,2,3,4,5,6,7,8]").unwrap();
        let file = load(
            &decay_doc_with(json!([from_file_assert(
                json!({"type": "from_file", "path": "ref.json", "format": "netcdf"}),
                "L2_error"
            )]))
            .to_string(),
        )
        .expect("doc loads");
        let r = &run_pde_tests_with_base_dir(&file, Some("M"), &tight_opts(), Some(dir.path()))[0];
        assert!(!r.passed);
        assert!(
            r.message.contains("format 'netcdf' is not supported"),
            "unexpected message: {}",
            r.message
        );
    }

    // -----------------------------------------------------------------------
    // Shared executable fixture (identical input across the three bindings)
    // -----------------------------------------------------------------------

    #[test]
    fn shared_fixture_pde_inline_assertions_exec() {
        let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/spatial/pde_inline_assertions_exec.esm");
        assert!(fixture.is_file(), "missing shared fixture {fixture:?}");
        let text = std::fs::read_to_string(&fixture).expect("fixture reads");
        let file = load(&text).expect("fixture loads");
        let results =
            run_pde_tests_with_base_dir(&file, Some("M"), &tight_opts(), fixture.parent());
        assert_eq!(results.len(), 7);
        for r in &results {
            assert!(r.passed, "assertion {}: {}", r.assertion_idx, r.message);
        }
        // The two tie-sampling coords assertions hit the SAME cell.
        assert_eq!(results[0].actual, results[1].actual);
        // integral == mean == 0 for the symmetric cosine field.
        assert!(results[4].actual.unwrap().abs() < 1e-12);
        // from_file error norms are ~0 against the committed exact snapshot.
        assert!(results[5].actual.unwrap() < 1e-12);
        assert!(results[6].actual.unwrap() < 1e-12);
    }
}
