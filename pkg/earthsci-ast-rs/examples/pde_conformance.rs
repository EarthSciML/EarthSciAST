//! pde_conformance — drive the official simulation / evaluation pathways for
//! the EarthSciDiscretizations cross-binding conformance categories and emit
//! the resulting numbers as JSON on stdout.
//!
//! ```text
//! cargo run --example pde_conformance -- pde-tests <problem.esm> \
//!     --model <name> --solver Erk --reltol 1e-10 --abstol 1e-12
//! cargo run --example pde_conformance -- convergence <problem.esm> \
//!     --model <name> --assert-time 0.1 --solver Erk --reltol 1e-10 \
//!     --abstol 1e-12 --norms L2_error,Linf_error \
//!     --resolutions '[{"n":16,"bindings":{"N":16}},…]'
//! cargo run --example pde_conformance -- reproject <library.esm> <points.json>
//! cargo run --example pde_conformance -- regrid <fixture.esm> \
//!     --model <name> --solver Erk --reltol 1e-10 --abstol 1e-12
//! ```
//!
//! Every number comes from official `earthsci_ast` entry points over the
//! one canonical pipeline (`.esm` → `load` → §9.7 import/metaparameter
//! resolution → §9.6.3 rewrite fixpoint → official runner):
//!
//! - `pde-tests`   [`earthsci_ast::pde_inline_tests::run_pde_tests`] —
//!   the §6.6/§6.6.5 inline tests through [`earthsci_ast::simulate`].
//! - `convergence` [`earthsci_ast::parse::load_path_with_options`] once
//!   per resolution (loader-API metaparameter binding, esm-spec §9.7.6 site
//!   4) → `simulate` → `evaluate_cellwise(reference)` → `field_reduce`.
//! - `reproject`   a runner-built invocation document importing the library
//!   (the manifest's `fixture: null` contract), loaded so §9.7.3 body
//!   composition inlines the template bodies, then
//!   [`earthsci_ast::evaluate`] per golden point (mirrors the Julia /
//!   Python runners' wrapper-doc scheme).
//! - `regrid`      the fixture's exact-invariant inline tests via
//!   `run_pde_tests`, the recorded regridded/invariant state fields at t=1
//!   via `simulate_with_inspection` + `state_cells`, and the per-pair
//!   `A_ij`/`A_j`/`W_ij` setup arrays read from the official
//!   [`earthsci_ast::simulate_array::BuildInspection`] surface
//!   (CONFORMANCE_SPEC §5.8; mirrors run-julia.jl's `run_regridding`).

use std::collections::{BTreeMap, HashMap};
use std::path::Path;
use std::process::ExitCode;

use earthsci_ast::evaluate;
use earthsci_ast::parse::{LoadOptions, load_path, load_path_with_options, load_with_options};
use earthsci_ast::pde_inline_tests::{
    evaluate_cellwise, field_reduce, run_pde_tests, state_cells,
};
use earthsci_ast::simulate::{
    SimulateOptions, SolverChoice, simulate, simulate_with_inspection,
};
use earthsci_ast::simulate_array::BuildInspection;
use earthsci_ast::types::{AssertionReference, EsmFile, Expr};
use serde_json::{Value, json};

fn parse_solver(name: &str) -> Result<SolverChoice, String> {
    match name {
        "Bdf" => Ok(SolverChoice::Bdf),
        "Sdirk" => Ok(SolverChoice::Sdirk),
        "Erk" => Ok(SolverChoice::Erk),
        other => Err(format!("unknown solver '{other}' (want Bdf|Sdirk|Erk)")),
    }
}

/// Shared `--flag value` scanner: collect flags into a map, positionals in
/// order.
fn split_args(args: &[String]) -> Result<(Vec<String>, HashMap<String, String>), String> {
    let mut positional = Vec::new();
    let mut flags = HashMap::new();
    let mut it = args.iter();
    while let Some(a) = it.next() {
        if let Some(name) = a.strip_prefix("--") {
            let v = it.next().ok_or_else(|| format!("--{name} needs a value"))?;
            flags.insert(name.to_string(), v.clone());
        } else {
            positional.push(a.clone());
        }
    }
    Ok((positional, flags))
}

fn flag<'a>(flags: &'a HashMap<String, String>, name: &str) -> Result<&'a str, String> {
    flags
        .get(name)
        .map(String::as_str)
        .ok_or_else(|| format!("missing required --{name}"))
}

fn sim_options(flags: &HashMap<String, String>) -> Result<SimulateOptions, String> {
    Ok(SimulateOptions {
        solver: parse_solver(flag(flags, "solver")?)?,
        reltol: flag(flags, "reltol")?
            .parse()
            .map_err(|e| format!("--reltol: {e}"))?,
        abstol: flag(flags, "abstol")?
            .parse()
            .map_err(|e| format!("--abstol: {e}"))?,
        ..Default::default()
    })
}

// ---------------------------------------------------------------------------
// pde-tests — the problem's inline §6.6/§6.6.5 tests via run_pde_tests.
// ---------------------------------------------------------------------------

fn cmd_pde_tests(positional: &[String], flags: &HashMap<String, String>) -> Result<Value, String> {
    let [problem] = positional else {
        return Err(
            "usage: pde-tests <problem.esm> --model … --solver … --reltol … --abstol …".to_string(),
        );
    };
    let file = load_path(problem).map_err(|e| format!("{problem}: {e}"))?;
    let model = flag(flags, "model")?;
    let opts = sim_options(flags)?;
    let results = run_pde_tests(&file, Some(model), &opts);
    Ok(json!({
        "assertions": results,
    }))
}

// ---------------------------------------------------------------------------
// regrid — the fixture's exact-invariant inline tests, the regridded field,
// and the per-pair build-time setup arrays (A_ij / A_j / W_ij) read from the
// official BuildInspection surface — the §5.8 per-pair gates. Mirrors
// run-julia.jl's `run_regridding` record field-for-field.
// ---------------------------------------------------------------------------

/// Fetch one named setup array from the build inspection. Flattening prefixes
/// each observed with its owning model (`"Regrid.A_ij"`), so try the qualified
/// name, then the bare name, then a unique `".<name>"` suffix match (the same
/// lookup ladder as run-julia.jl's `_setup_array`).
fn setup_array<'a>(
    insp: &'a BuildInspection,
    model: &str,
    name: &str,
) -> Result<&'a ndarray::ArrayD<f64>, String> {
    let qualified = format!("{model}.{name}");
    if let Some(a) = insp
        .setup_arrays
        .get(&qualified)
        .or_else(|| insp.setup_arrays.get(name))
    {
        return Ok(a);
    }
    let suffix = format!(".{name}");
    let hits: Vec<&String> = insp
        .setup_arrays
        .keys()
        .filter(|k| k.ends_with(&suffix))
        .collect();
    if hits.len() == 1 {
        return Ok(&insp.setup_arrays[hits[0]]);
    }
    let mut have: Vec<&String> = insp.setup_arrays.keys().collect();
    have.sort();
    Err(format!(
        "setup array '{name}' not exposed by the build (have: {have:?})"
    ))
}

/// Row-major nested lists for JSON emission (`[i][j]` like the manifest
/// triples); requires a rank-2 array.
fn rows(arr: &ndarray::ArrayD<f64>, name: &str) -> Result<Vec<Vec<f64>>, String> {
    if arr.ndim() != 2 {
        return Err(format!("setup array '{name}' has rank {}", arr.ndim()));
    }
    let (n, m) = (arr.shape()[0], arr.shape()[1]);
    Ok((0..n)
        .map(|i| (0..m).map(|j| arr[ndarray::IxDyn(&[i, j])]).collect())
        .collect())
}

fn cmd_regrid(positional: &[String], flags: &HashMap<String, String>) -> Result<Value, String> {
    let [fixture] = positional else {
        return Err(
            "usage: regrid <fixture.esm> --model … --solver … --reltol … --abstol …".to_string(),
        );
    };
    let file = load_path(fixture).map_err(|e| format!("{fixture}: {e}"))?;
    let model = flag(flags, "model")?;
    let opts = sim_options(flags)?;
    let results = run_pde_tests(&file, Some(model), &opts);
    let passed = !results.is_empty() && results.iter().all(|r| r.passed);
    // regrid_state integrates the constant regridded field from 0 over [0,1],
    // so state(1) IS the regridded field F_tgt.
    let mut insp = BuildInspection::default();
    let mut run_opts = opts.clone();
    run_opts.output_times = Some(vec![1.0]);
    let sol = simulate_with_inspection(
        &file,
        (0.0, 1.0),
        &HashMap::new(),
        &HashMap::new(),
        &run_opts,
        &mut insp,
    )
    .map_err(|e| format!("simulate: {e}"))?;
    let ti = sol.time.len() - 1;
    let mut out = serde_json::Map::new();
    out.insert("assertions".to_string(), json!(results));
    out.insert("passed".to_string(), json!(passed));
    for var in ["regrid_state", "pou_state", "cons_state"] {
        let cells = state_cells(&sol.state_variable_names, var, model);
        if cells.is_empty() {
            return Err(format!("state '{var}' has no cells in the solution"));
        }
        let field: Vec<f64> = cells.iter().map(|(_, row)| sol.state[*row][ti]).collect();
        out.insert(format!("{var}_at_1"), json!(field));
    }
    // Per-pair setup arrays (manifest §5.8 gates): the raw overlap-area
    // matrix, its filtered row-sums, and the normalized weights — the
    // build-once geometry the runtime materializes at setup, emitted verbatim
    // (row-major [i][j], 1-based like the manifest triples).
    let a_ij = setup_array(&insp, model, "A_ij")?;
    out.insert("A_ij".to_string(), json!(rows(a_ij, "A_ij")?));
    let a_j = setup_array(&insp, model, "A_j")?;
    if a_j.ndim() != 1 {
        return Err(format!("setup array 'A_j' has rank {}", a_j.ndim()));
    }
    out.insert(
        "A_j".to_string(),
        json!(a_j.iter().copied().collect::<Vec<f64>>()),
    );
    let w_ij = setup_array(&insp, model, "W_ij")?;
    out.insert("W_ij".to_string(), json!(rows(w_ij, "W_ij")?));
    Ok(Value::Object(out))
}

// ---------------------------------------------------------------------------
// convergence — one load per resolution (§9.7.6 binding site 4), error norms
// vs the problem's own §6.6.5 analytic reference at the assert time.
// ---------------------------------------------------------------------------

/// The problem's L2_error assertion at `assert_time` — the declaration the
/// sweep takes its asserted variable and analytic `reference` from (same
/// selection rule as the Julia / Python conformance runners).
fn reference_assertion(
    file: &EsmFile,
    model: &str,
    assert_time: f64,
) -> Result<(String, Expr), String> {
    let m = file
        .models
        .as_ref()
        .and_then(|ms| ms.get(model))
        .ok_or_else(|| format!("model '{model}' not found"))?;
    for t in m.tests.as_deref().unwrap_or(&[]) {
        for a in &t.assertions {
            if a.time == assert_time && a.reduce.as_deref() == Some("L2_error") {
                return match &a.reference {
                    Some(AssertionReference::Expression(e)) => {
                        Ok((a.variable.clone(), e.as_ref().clone()))
                    }
                    _ => Err("reference assertion carries no inline expression".to_string()),
                };
            }
        }
    }
    Err(format!(
        "problem declares no L2_error assertion at t={assert_time} to take the reference from"
    ))
}

fn cmd_convergence(
    positional: &[String],
    flags: &HashMap<String, String>,
) -> Result<Value, String> {
    let [problem] = positional else {
        return Err(
            "usage: convergence <problem.esm> --model … --assert-time … --solver … \
                    --reltol … --abstol … --norms … --resolutions <json>"
                .to_string(),
        );
    };
    let model = flag(flags, "model")?;
    let assert_time: f64 = flag(flags, "assert-time")?
        .parse()
        .map_err(|e| format!("--assert-time: {e}"))?;
    let norms: Vec<String> = flag(flags, "norms")?
        .split(',')
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .collect();
    let resolutions: Vec<Value> = serde_json::from_str(flag(flags, "resolutions")?)
        .map_err(|e| format!("--resolutions: {e}"))?;
    let base_opts = sim_options(flags)?;

    let mut errors = Vec::new();
    for res in &resolutions {
        let n = res["n"]
            .as_i64()
            .ok_or("resolution entry needs an integer 'n'")?;
        let mut bindings: BTreeMap<String, i64> = BTreeMap::new();
        for (k, v) in res["bindings"]
            .as_object()
            .ok_or("resolution entry needs a 'bindings' object")?
        {
            bindings.insert(
                k.clone(),
                v.as_i64()
                    .ok_or_else(|| format!("binding '{k}' must be an integer"))?,
            );
        }
        let file = load_path_with_options(problem, &bindings)
            .map_err(|e| format!("{problem} (n={n}): {e}"))?;
        let (variable, reference) = reference_assertion(&file, model, assert_time)?;
        let mut opts = base_opts.clone();
        opts.output_times = Some(vec![assert_time]);
        let sol = simulate(
            &file,
            (0.0, assert_time),
            &HashMap::new(),
            &HashMap::new(),
            &opts,
        )
        .map_err(|e| format!("simulate (n={n}): {e}"))?;
        let ti = sol.time.len() - 1;
        let cells = state_cells(&sol.state_variable_names, &variable, model);
        if cells.is_empty() {
            return Err(format!("state '{variable}' has no cells at n={n}"));
        }
        let field: Vec<f64> = cells.iter().map(|(_, row)| sol.state[*row][ti]).collect();
        let cell_tuples: Vec<Vec<i64>> = cells.iter().map(|(c, _)| c.clone()).collect();
        let index_sets = file.index_sets.clone().unwrap_or_default();
        // Analytic convergence reference over domain dimensions (no parameters).
        let no_params: HashMap<String, f64> = HashMap::new();
        let reference_field = evaluate_cellwise(&reference, &cell_tuples, &index_sets, &no_params)?;
        let mut row = serde_json::Map::new();
        row.insert("n".to_string(), json!(n));
        for norm in &norms {
            row.insert(
                norm.clone(),
                json!(field_reduce(norm, &field, Some(&reference_field))?),
            );
        }
        errors.push(Value::Object(row));
    }
    Ok(json!({"assert_time": assert_time, "errors": errors}))
}

// ---------------------------------------------------------------------------
// reproject — evaluate the library's public templates at every golden point
// through the official pathway: a runner-BUILT invocation document importing
// the library, loaded so §9.7.3 body composition inlines the template
// bodies, then `evaluate` per point.
// ---------------------------------------------------------------------------

/// The runner-built invocation document (the manifest's `fixture: null`
/// contract): four observed variables applying the library's public
/// templates with this parameter set's CRS constants bound.
fn reproj_wrapper_doc(lib_file_name: &str, params: &Value) -> Result<Value, String> {
    let mut crs = serde_json::Map::new();
    for key in ["lat_1", "lat_2", "lat_0", "lon_0", "R"] {
        let v = params[key]
            .as_f64()
            .ok_or_else(|| format!("parameter set is missing numeric '{key}'"))?;
        crs.insert(key.to_string(), json!(v));
    }
    let mkapply = |tpl: &str, args: [&str; 2]| -> Value {
        let mut bindings = crs.clone();
        for a in args {
            bindings.insert(a.to_string(), json!(a));
        }
        json!({"op": "apply_expression_template", "args": [], "name": tpl,
               "bindings": bindings})
    };
    Ok(json!({
        "esm": "0.8.0",
        "metadata": {"name": "lambert_conformal_eval",
                     "description": "Runner-built template invocation (manifest fixture: null)."},
        "models": {"Reproject": {
            "expression_template_imports": [{"ref": lib_file_name}],
            "variables": {
                "lon": {"type": "parameter", "units": "deg", "default": 0.0},
                "lat": {"type": "parameter", "units": "deg", "default": 0.0},
                "x": {"type": "parameter", "units": "m", "default": 0.0},
                "y": {"type": "parameter", "units": "m", "default": 0.0},
                "fwd_x": {"type": "observed", "units": "m",
                          "expression": mkapply("lambert_conformal_forward_x", ["lon", "lat"])},
                "fwd_y": {"type": "observed", "units": "m",
                          "expression": mkapply("lambert_conformal_forward_y", ["lon", "lat"])},
                "inv_lon": {"type": "observed", "units": "deg",
                            "expression": mkapply("lambert_conformal_inverse_lon", ["x", "y"])},
                "inv_lat": {"type": "observed", "units": "deg",
                            "expression": mkapply("lambert_conformal_inverse_lat", ["x", "y"])},
            },
            "equations": []
        }}
    }))
}

/// The four composed (import-inlined) expressions of one parameter set.
fn reproj_expressions(lib: &Path, params: &Value) -> Result<HashMap<String, Expr>, String> {
    let lib_name = lib
        .file_name()
        .and_then(|s| s.to_str())
        .ok_or("library path has no file name")?;
    let doc = reproj_wrapper_doc(lib_name, params)?;
    let options = LoadOptions {
        base_path: Some(lib.parent().unwrap_or_else(|| Path::new(".")).to_path_buf()),
        ..Default::default()
    };
    let file = load_with_options(&doc.to_string(), &options)
        .map_err(|e| format!("wrapper doc load: {e}"))?;
    let model = file
        .models
        .as_ref()
        .and_then(|ms| ms.get("Reproject"))
        .ok_or("wrapper doc lost its Reproject model")?;
    let mut out = HashMap::new();
    for name in ["fwd_x", "fwd_y", "inv_lon", "inv_lat"] {
        let expr = model
            .variables
            .get(name)
            .and_then(|v| v.expression.clone())
            .ok_or_else(|| format!("wrapper variable '{name}' has no composed expression"))?;
        out.insert(name.to_string(), expr);
    }
    Ok(out)
}

fn eval_at(expr: &Expr, bindings: &HashMap<String, f64>) -> Result<f64, String> {
    evaluate(expr, bindings).map_err(|missing| format!("unbound variables: {missing:?}"))
}

fn cmd_reproject(positional: &[String]) -> Result<Value, String> {
    let [library, points] = positional else {
        return Err("usage: reproject <library.esm> <points.json>".to_string());
    };
    let lib = Path::new(library);
    let gold: Value = serde_json::from_str(
        &std::fs::read_to_string(points).map_err(|e| format!("{points}: {e}"))?,
    )
    .map_err(|e| format!("{points}: {e}"))?;

    let mut exprs: HashMap<String, HashMap<String, Expr>> = HashMap::new();
    for (setname, params) in gold["parameter_sets"]
        .as_object()
        .ok_or("points.json has no parameter_sets")?
    {
        exprs.insert(setname.clone(), reproj_expressions(lib, params)?);
    }
    let set_exprs = |pt: &Value| -> Result<&HashMap<String, Expr>, String> {
        let set = pt["set"].as_str().ok_or("point has no 'set'")?;
        exprs
            .get(set)
            .ok_or_else(|| format!("point references unknown set '{set}'"))
    };

    let mut forward = Vec::new();
    for pt in gold["forward"].as_array().ok_or("no forward points")? {
        let e = set_exprs(pt)?;
        let b: HashMap<String, f64> = HashMap::from([
            ("lon".to_string(), pt["lon"].as_f64().ok_or("lon")?),
            ("lat".to_string(), pt["lat"].as_f64().ok_or("lat")?),
        ]);
        forward.push(json!({"set": pt["set"], "lon": b["lon"], "lat": b["lat"],
                            "x": eval_at(&e["fwd_x"], &b)?,
                            "y": eval_at(&e["fwd_y"], &b)?}));
    }
    let mut inverse = Vec::new();
    for pt in gold["inverse"].as_array().ok_or("no inverse points")? {
        let e = set_exprs(pt)?;
        let b: HashMap<String, f64> = HashMap::from([
            ("x".to_string(), pt["x"].as_f64().ok_or("x")?),
            ("y".to_string(), pt["y"].as_f64().ok_or("y")?),
        ]);
        inverse.push(json!({"set": pt["set"], "x": b["x"], "y": b["y"],
                            "lon": eval_at(&e["inv_lon"], &b)?,
                            "lat": eval_at(&e["inv_lat"], &b)?}));
    }
    let mut roundtrip = Vec::new();
    for pt in gold["roundtrip"].as_array().ok_or("no roundtrip points")? {
        let e = set_exprs(pt)?;
        let b: HashMap<String, f64> = HashMap::from([
            ("lon".to_string(), pt["lon"].as_f64().ok_or("lon")?),
            ("lat".to_string(), pt["lat"].as_f64().ok_or("lat")?),
        ]);
        let xa = eval_at(&e["fwd_x"], &b)?;
        let ya = eval_at(&e["fwd_y"], &b)?;
        let b2: HashMap<String, f64> =
            HashMap::from([("x".to_string(), xa), ("y".to_string(), ya)]);
        roundtrip.push(json!({"set": pt["set"], "lon": b["lon"], "lat": b["lat"],
                              "lon_rt": eval_at(&e["inv_lon"], &b2)?,
                              "lat_rt": eval_at(&e["inv_lat"], &b2)?}));
    }
    Ok(json!({"forward": forward, "inverse": inverse, "roundtrip": roundtrip}))
}

// ---------------------------------------------------------------------------
// Main.
// ---------------------------------------------------------------------------

fn run() -> Result<(), String> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let Some((mode, rest)) = args.split_first() else {
        return Err(
            "usage: pde_conformance <pde-tests|convergence|reproject|regrid> …".to_string(),
        );
    };
    let (positional, flags) = split_args(rest)?;
    let out = match mode.as_str() {
        "pde-tests" => cmd_pde_tests(&positional, &flags)?,
        "convergence" => cmd_convergence(&positional, &flags)?,
        "reproject" => cmd_reproject(&positional)?,
        "regrid" => cmd_regrid(&positional, &flags)?,
        other => return Err(format!("unknown mode '{other}'")),
    };
    println!(
        "{}",
        serde_json::to_string_pretty(&out).map_err(|e| e.to_string())?
    );
    Ok(())
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("error: {e}");
            ExitCode::FAILURE
        }
    }
}
