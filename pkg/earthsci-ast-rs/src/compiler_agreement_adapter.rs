//! Core of the Rust adapter for the `compiler_agreement` conformance tier
//! (`tests/conformance/compiler_agreement/README.md`, CONFORMANCE_SPEC §5.44).
//!
//! The tier asks each binding to integrate the same documents once per
//! compiler and report the trajectory, so that a strict `native` default can be
//! checked against the `interpreter` reference of the SAME binding as well as
//! across bindings. Agreement is numerical and the runner's to judge; nothing
//! here inspects an emitted program.
//!
//! The adapter passes `--compiler` straight to
//! [`crate::problem::esm_problem`] and never interprets it — an adapter that
//! chose a build itself would be reimplementing the thing under test. What it
//! does decide is the three answers the contract allows it to give:
//!
//!   * a **refusal** (`compiler_refused_rule`) is that fixture's
//!     `{"status": "refused", "rule": …, "reason": …}`, and the run continues
//!     with the next fixture — a compiler that cannot lower one document has
//!     said nothing about the others;
//!   * a **`compiler_unavailable`** is the WHOLE output's
//!     `{"status": "unavailable", "reason": …}`, because it is a fact about
//!     this binding and this build rather than about a document;
//!   * anything else that throws is that fixture's `{"error": …}`.
//!
//! The logic lives in the library rather than in `src/bin/` so that a test can
//! drive exactly the path the binary runs, the same split
//! [`crate::compiled_rhs_adapter`] uses.

use std::collections::HashMap;
use std::fs;
use std::path::Path;

use serde_json::{Map, Value, json};

pub use crate::adapter_support::Report;
use crate::adapter_support::{
    self, Answer, Manifest, Tier, bare, nearest_index, number, required_compiler, solver_alg,
    time_key,
};
use crate::compile_error::CompileError;
use crate::problem::{Compiler, ProblemOptions, Rhs, esm_problem, observed_trajectories, solve};
use crate::simulate::{SimulateError, Solution, SolveOptions};
use crate::types::EsmFile;

/// The adapter's parsed command line: `--manifest <m> --output <o>
/// --compiler <c>`.
pub type Args = adapter_support::Args<Compiler>;

/// Parse `--manifest <m> --output <o> --compiler <c>`, rejecting anything else
/// ([`required_compiler`]).
pub fn parse_args<I: IntoIterator<Item = String>>(args: I) -> Result<Args, String> {
    adapter_support::parse_args(args, Some("--compiler"), required_compiler)
}

/// This tier under one compiler.
pub struct CompilerAgreement(pub Compiler);

/// The tier the binary's `--compiler` names ([`required_compiler`]).
pub fn configure(value: Option<&str>) -> Result<CompilerAgreement, String> {
    required_compiler(value).map(CompilerAgreement)
}

/// The run one fixture describes: what to seed, how long for, and when to save.
struct Run {
    u0: HashMap<String, f64>,
    p: HashMap<String, f64>,
    tspan: (f64, f64),
    saveat: Vec<f64>,
    observed: Vec<String>,
}

fn number_map(v: Option<&Value>, what: &str) -> Result<HashMap<String, f64>, String> {
    let Some(v) = v else {
        return Ok(HashMap::new());
    };
    if v.is_null() {
        return Ok(HashMap::new());
    }
    let obj = v
        .as_object()
        .ok_or_else(|| format!("{what} is not an object"))?;
    obj.iter()
        .map(|(k, val)| {
            val.as_f64()
                .map(|x| (k.clone(), x))
                .ok_or_else(|| format!("{what}[{k:?}] is not a number"))
        })
        .collect()
}

fn f64_list(v: &Value, what: &str) -> Result<Vec<f64>, String> {
    v.as_array()
        .ok_or_else(|| format!("{what} is not an array"))?
        .iter()
        .map(|x| {
            x.as_f64()
                .ok_or_else(|| format!("{what} holds a non-number"))
        })
        .collect()
}

fn string_list(v: Option<&Value>, what: &str) -> Result<Vec<String>, String> {
    let Some(v) = v else {
        return Ok(Vec::new());
    };
    if v.is_null() {
        return Ok(Vec::new());
    }
    v.as_array()
        .ok_or_else(|| format!("{what} is not an array"))?
        .iter()
        .map(|x| {
            x.as_str()
                .map(str::to_string)
                .ok_or_else(|| format!("{what} holds a non-string"))
        })
        .collect()
}

/// The run of a `"from": "inline_tests"` fixture, read from the DOCUMENT.
///
/// The manifest restates nothing about such a run, so the document stays the
/// single source of truth for it: the seeds, the overrides and the time span
/// are the named test's own, and the save times are its assertion times —
/// which is where its analytic anchor lives, so a trajectory saved anywhere
/// else could not be held to it.
fn inline_test_run(file: &EsmFile, model: &str, test_id: &str) -> Result<Run, String> {
    let models = file
        .models
        .as_ref()
        .ok_or_else(|| format!("document declares no models, so it has no {model:?}"))?;
    let m = models
        .get(model)
        .ok_or_else(|| format!("document has no model {model:?}"))?;
    let test = m
        .tests
        .iter()
        .flatten()
        .find(|t| t.id == test_id)
        .ok_or_else(|| format!("model {model:?} has no inline test {test_id:?}"))?;

    // A shaped seed is carried as inline row-major data rather than as one
    // number per element, and dropping it silently would run the fixture from
    // the document's defaults under a name that says otherwise.
    let scalar_u0 = test.scalar_initial_conditions();
    if let Some(ics) = &test.initial_conditions
        && ics.len() != scalar_u0.len()
    {
        return Err(format!(
            "inline test {test_id:?} carries a non-scalar initial condition, which this \
             adapter does not expand"
        ));
    }
    let scalar_p = test.scalar_parameter_overrides();
    if let Some(po) = &test.parameter_overrides
        && po.len() != scalar_p.len()
    {
        return Err(format!(
            "inline test {test_id:?} carries a non-scalar parameter override, which this \
             adapter does not expand"
        ));
    }

    let mut saveat: Vec<f64> = test.assertions.iter().map(|a| a.time).collect();
    saveat.sort_by(f64::total_cmp);
    saveat.dedup();
    if saveat.is_empty() {
        return Err(format!("inline test {test_id:?} asserts nothing"));
    }
    Ok(Run {
        u0: scalar_u0,
        p: scalar_p,
        tspan: (test.time_span.start, test.time_span.end),
        saveat,
        observed: Vec::new(),
    })
}

/// The run a fixture entry describes, from whichever source defines it.
fn fixture_run(fx: &Value, file: &EsmFile, model: &str) -> Result<Run, String> {
    let tr = &fx["trajectory"];
    match tr["from"].as_str() {
        Some("manifest") => {
            let tspan = f64_list(&tr["tspan"], "trajectory.tspan")?;
            if tspan.len() != 2 {
                return Err("trajectory.tspan must be [t0, t1]".to_string());
            }
            let mut run = Run {
                u0: number_map(tr.get("initial_conditions"), "initial_conditions")?,
                p: number_map(tr.get("parameter_overrides"), "parameter_overrides")?,
                tspan: (tspan[0], tspan[1]),
                saveat: f64_list(&tr["saveat"], "trajectory.saveat")?,
                observed: string_list(tr.get("observed"), "trajectory.observed")?,
            };
            if run.saveat.is_empty() {
                return Err("trajectory.saveat is empty".to_string());
            }
            run.observed.dedup();
            Ok(run)
        }
        Some("inline_tests") => {
            let test_id = tr["test_id"]
                .as_str()
                .ok_or("trajectory.test_id missing for a `from: inline_tests` fixture")?;
            let mut run = inline_test_run(file, model, test_id)?;
            run.observed = string_list(tr.get("observed"), "trajectory.observed")?;
            Ok(run)
        }
        other => Err(format!(
            "trajectory.from is {other:?}; the contract allows \"manifest\" or \"inline_tests\""
        )),
    }
}

/// The rows a solution carries at the fixture's save times.
fn state_rows(sol: &Solution, saveat: &[f64]) -> Result<Value, String> {
    let mut rows = Map::new();
    for &t in saveat {
        let idx = nearest_index(&sol.time, t).ok_or("the solution has no time grid")?;
        let mut row = Map::new();
        for (r, name) in sol.state_variable_names.iter().enumerate() {
            row.insert(bare(name).to_string(), number(sol.state[r][idx]));
        }
        rows.insert(time_key(t), Value::Object(row));
    }
    Ok(Value::Object(rows))
}

/// One series per observed field the fixture names, at the same save times.
fn observed_series(
    prob: &crate::problem::EsmProblem,
    sol: &Solution,
    run: &Run,
) -> Result<Value, String> {
    let mut out = Map::new();
    if run.observed.is_empty() {
        return Ok(Value::Object(out));
    }
    let series = observed_trajectories(prob, sol, &run.observed)
        .map_err(|e| format!("observed_trajectories: {e}"))?;
    for (name, values) in series {
        let mut m = Map::new();
        for &t in &run.saveat {
            let idx = nearest_index(&sol.time, t).ok_or("the solution has no time grid")?;
            let v = values
                .get(idx)
                .copied()
                .ok_or_else(|| format!("observed {name:?} has no sample at t={t}"))?;
            m.insert(time_key(t), number(v));
        }
        out.insert(bare(&name).to_string(), Value::Object(m));
    }
    Ok(Value::Object(out))
}

fn run_fixture(fx: &Value, manifest: &Manifest, compiler: Compiler) -> Result<Answer, String> {
    let path = manifest.fixture_path(fx)?;
    let text = fs::read_to_string(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    let file = crate::load_string(&text).map_err(|e| format!("load: {e:?}"))?;
    let model = fx["model"].as_str().ok_or("fixture.model missing")?;
    let run = fixture_run(fx, &file, model)?;

    let integration = &fx["integration"];
    let opts = SolveOptions {
        alg: solver_alg(&file),
        reltol: integration["reltol"].as_f64(),
        abstol: integration["abstol"].as_f64(),
        saveat: Some(run.saveat.clone()),
        maxiters: Some(1_000_000),
        ..Default::default()
    };
    let prob = match esm_problem(
        &file,
        run.tspan,
        ProblemOptions {
            p: run.p.clone(),
            u0: run.u0.clone(),
            model_name: Some(model.to_string()),
            // The tier compares TRAJECTORIES, so a fixture whose `D` equations
            // only become an integrable system when a harness asks for one
            // must still get a right-hand side.
            rhs: Rhs::Always,
            compiler: Some(compiler),
            ..Default::default()
        },
    ) {
        Ok(p) => p,
        Err(SimulateError::Compile(CompileError::CompilerRefusedRule { rule, reason, .. })) => {
            return Ok(Answer::Entry(json!({
                "status": "refused",
                "rule": rule,
                "reason": reason,
            })));
        }
        Err(SimulateError::CompilerUnavailable { details, .. }) => {
            return Ok(Answer::Unavailable(details));
        }
        Err(e) => return Err(format!("SimulateError: {e}")),
    };

    let sol = match solve(&prob, &opts) {
        Ok(s) => s,
        // A refusal is raised at CONSTRUCTION (§2.5.10), so one reaching the
        // solve is still the same fact and is reported the same way rather
        // than as an error.
        Err(SimulateError::Compile(CompileError::CompilerRefusedRule { rule, reason, .. })) => {
            return Ok(Answer::Entry(json!({
                "status": "refused",
                "rule": rule,
                "reason": reason,
            })));
        }
        Err(e) => return Err(format!("SimulateError: {e}")),
    };

    let state_order: Vec<String> = sol
        .state_variable_names
        .iter()
        .map(|n| bare(n).to_string())
        .collect();
    Ok(Answer::Entry(json!({
        "state_order": state_order,
        "state": state_rows(&sol, &run.saveat)?,
        "observed": observed_series(&prob, &sol, &run)?,
    })))
}

impl Tier for CompilerAgreement {
    fn header(&self) -> Option<(&'static str, &'static str)> {
        Some(("compiler", self.0.as_str()))
    }

    fn run_fixture(&self, fx: &Value, manifest: &Manifest) -> Result<Answer, String> {
        run_fixture(fx, manifest, self.0)
    }
}

/// Run a whole manifest under one compiler and build the report
/// ([`adapter_support::run_manifest`]): a fixture that throws is its own
/// `error` entry, and the first `compiler_unavailable` replaces the whole
/// payload.
pub fn run_manifest(manifest_path: &Path, compiler: Compiler) -> Result<Report, String> {
    adapter_support::run_manifest(&CompilerAgreement(compiler), manifest_path)
}
