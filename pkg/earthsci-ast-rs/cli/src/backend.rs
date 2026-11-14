//! The time integrators `esm simulate` runs a dynamic document on.
//!
//! Each is a [`Backend`] behind a cargo feature of this crate, and the
//! features are additive: `diffsol` (on by default) is the solver
//! `earthsci-ast` links, and `integrator` is EarthSciIntegrator. With both in
//! the build, `--backend` picks one per run; with one, it is the default; with
//! neither, [`select`] refuses and names the features to build with.
//!
//! Both answer with an [`earthsci_ast::Solution`], so everything after the
//! integration (the summary lines, `--output` in either format) is shared.

use earthsci_ast::{EsmProblem, Solution, SolveOptions};
use std::path::{Path, PathBuf};

/// One integration of a dynamic document. Each backend reads what it needs:
/// diffsol the Problem, the integrator the document's path and the interval.
#[cfg_attr(not(feature = "integrator"), allow(dead_code))]
pub struct SimulateRun<'a> {
    /// The document, as named on the command line.
    pub file: &'a Path,
    /// The Problem `earthsci-ast` built for it over [`Self::tspan`].
    pub prob: &'a EsmProblem,
    /// The solve options the command built (`--observed` among them).
    pub opts: &'a SolveOptions,
    /// The run interval, in seconds of model time.
    pub tspan: (f64, f64),
}

/// A time integrator `esm simulate` can run on.
pub trait Backend {
    /// The name `--backend` selects it by.
    fn name(&self) -> &'static str;
    /// Integrate `run`, or say why not.
    fn simulate(&self, run: &SimulateRun<'_>) -> Result<Solution, String>;
}

/// The options only EarthSciIntegrator reads. Given with the diffsol backend
/// they are refused rather than ignored.
#[derive(Debug, Clone, Default)]
pub struct IntegratorOptions {
    /// A run configuration (EarthSciIntegrator spec/run-config.md). Without
    /// one, a single adaptive leaf over every operator runs under a fixed
    /// macro step of [`Self::dt`].
    pub run_config: Option<PathBuf>,
    /// The fixed macro step of the default run configuration, in seconds;
    /// default a hundredth of the run interval.
    pub dt: Option<f64>,
    /// Where the plan is written; default a fresh directory under the system
    /// temporary directory, removed after the run.
    pub plan_dir: Option<PathBuf>,
}

impl IntegratorOptions {
    fn is_empty(&self) -> bool {
        self.run_config.is_none() && self.dt.is_none() && self.plan_dir.is_none()
    }
}

/// The `--backend` names this build accepts, in order of preference.
pub fn available() -> &'static [&'static str] {
    &[
        #[cfg(feature = "diffsol")]
        "diffsol",
        #[cfg(feature = "integrator")]
        "integrator",
    ]
}

/// The backend `--backend` names, or this build's default when it names none.
pub fn select(
    name: Option<&str>,
    integrator: IntegratorOptions,
) -> Result<Box<dyn Backend>, String> {
    let known = ["diffsol", "integrator"];
    let name = match name {
        Some(n) => n.to_ascii_lowercase(),
        None => match available().first() {
            Some(n) => (*n).to_string(),
            None => {
                return Err("this build of `esm` has no time integrator: rebuild \
                            with `--features diffsol` or `--features integrator`"
                    .into());
            }
        },
    };
    if !known.contains(&name.as_str()) {
        return Err(format!(
            "unknown backend {name:?}: expected one of {}",
            known.join(", ")
        ));
    }
    if !available().contains(&name.as_str()) {
        return Err(format!(
            "backend {name:?} is not in this build of `esm`: rebuild with \
             `--features {name}`"
        ));
    }
    if name == "diffsol" && !integrator.is_empty() {
        return Err(
            "--run-config, --dt and --plan-dir configure the `integrator` \
                    backend; the diffsol backend takes none of them"
                .into(),
        );
    }
    match name.as_str() {
        #[cfg(feature = "diffsol")]
        "diffsol" => Ok(Box::new(Diffsol)),
        #[cfg(feature = "integrator")]
        "integrator" => Ok(Box::new(integrator::Integrator(integrator))),
        _ => unreachable!("an available solver has a backend"),
    }
}

/// `earthsci_ast::solve`: diffsol, with the method the document's `solver`
/// block (or the binding default) names.
#[cfg(feature = "diffsol")]
pub struct Diffsol;

#[cfg(feature = "diffsol")]
impl Backend for Diffsol {
    fn name(&self) -> &'static str {
        "diffsol"
    }

    fn simulate(&self, run: &SimulateRun<'_>) -> Result<Solution, String> {
        earthsci_ast::solve(run.prob, run.opts).map_err(|e| format!("solve failed: {e}"))
    }
}

#[cfg(feature = "integrator")]
mod integrator {
    use super::{Backend, IntegratorOptions, SimulateRun};
    use earthsci_ast::{ReturnCode, Solution, SolutionMetadata};
    use earthsci_integrator::forcing::DataOptions;
    use earthsci_integrator::planned::load_plan_with;
    use earthsci_integrator::schedule::RunSpec;
    use earthsci_integrator_planner::Planned;
    use earthsci_integrator_planner::astdiff::AstDiffBands;
    use std::collections::HashMap;
    use std::path::{Path, PathBuf};

    /// EarthSciIntegrator: plan the run configuration against the document,
    /// write the plan, load it and run it forward.
    pub struct Integrator(pub IntegratorOptions);

    /// A plan directory the run made itself, removed when the run ends.
    struct Scratch(PathBuf);

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn absolute(p: &Path) -> Result<PathBuf, String> {
        std::fs::canonicalize(p).map_err(|e| format!("{}: {e}", p.display()))
    }

    impl Backend for Integrator {
        fn name(&self) -> &'static str {
            "integrator"
        }

        fn simulate(&self, run: &SimulateRun<'_>) -> Result<Solution, String> {
            if !run.opts.output_observed.is_empty() {
                return Err("--observed is evaluated along a diffsol solve only; \
                            the integrator backend writes the state"
                    .into());
            }
            let model = absolute(run.file)?;
            let (dir, _scratch) = match &self.0.plan_dir {
                Some(d) => {
                    std::fs::create_dir_all(d).map_err(|e| format!("{}: {e}", d.display()))?;
                    (d.clone(), None)
                }
                None => {
                    let d = std::env::temp_dir().join(format!(
                        "esm-integrator-plan-{}-{}",
                        std::process::id(),
                        std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                            .map(|d| d.as_nanos())
                            .unwrap_or(0)
                    ));
                    std::fs::create_dir_all(&d).map_err(|e| format!("{}: {e}", d.display()))?;
                    (d.clone(), Some(Scratch(d)))
                }
            };
            let planned = match &self.0.run_config {
                Some(rc) => plan(&check_model(rc, &model)?, run.tspan)?,
                None => default_plan(&dir, &model, run.tspan, self.0.dt)?,
            };
            planned
                .write(&dir)
                .map_err(|e| format!("writing the plan to {}: {e}", dir.display()))?;

            let data = DataOptions {
                model: Some(model),
                ..Default::default()
            };
            let lp = load_plan_with::<f64>(&dir, &data).map_err(|e| e.to_string())?;
            // A resolved plan writes a fixed step in seconds.
            let step_dt = lp
                .run_config
                .step
                .as_ref()
                .and_then(|s| s.dt.as_ref()?.as_f64());
            let saveat = output_times(step_dt, lp.tspan);
            let spec = RunSpec::<f64>::with_problem_and_tstops(
                lp.problem,
                &lp.run_config,
                lp.tspan,
                saveat.as_deref(),
                lp.timeline.refresh_times(),
            )
            .map_err(|e| e.to_string())?;
            let u0 = spec.u0();
            let p = spec.problem.p.clone();
            let fwd = spec
                .forward(&u0, &p)
                .map_err(|e| format!("integration failed: {e}"))?;

            let (names, dofs) = columns(run.prob, &lp.state_dofs);
            Ok(Solution {
                time: fwd.outputs.iter().map(|o| o.0).collect(),
                state: dofs
                    .iter()
                    .map(|&j| fwd.outputs.iter().map(|o| o.1[j]).collect())
                    .collect(),
                state_variable_names: names,
                retcode: ReturnCode::Success,
                metadata: SolutionMetadata {
                    alg: "earthsci-integrator".into(),
                    n_rhs_calls: fwd.rhs_calls as usize,
                    n_accepted_steps: fwd.accepted as usize,
                    n_rejected_steps: fwd.rejected as usize,
                    ..Default::default()
                },
            })
        }
    }

    /// The run configuration `rc`, after checking it names the document the
    /// command was given: the planner reads the run configuration's `model`,
    /// so a different one would silently integrate another document.
    fn check_model(rc: &Path, model: &Path) -> Result<PathBuf, String> {
        let text = std::fs::read_to_string(rc).map_err(|e| format!("{}: {e}", rc.display()))?;
        let doc: serde_json::Value =
            serde_json::from_str(&text).map_err(|e| format!("{}: {e}", rc.display()))?;
        let named = doc["model"]
            .as_str()
            .ok_or_else(|| format!("{}: no `model`", rc.display()))?;
        let base = rc.parent().unwrap_or(Path::new("."));
        let named = absolute(&base.join(named))?;
        if named != model {
            return Err(format!(
                "{} integrates {}, not {}",
                rc.display(),
                named.display(),
                model.display()
            ));
        }
        Ok(rc.to_path_buf())
    }

    /// Plan the run configuration at `rc` over `tspan`. The caller's interval
    /// overrides the run configuration's and the document's
    /// (spec/run-config.md §1.1).
    fn plan(rc: &Path, tspan: (f64, f64)) -> Result<Planned, String> {
        let options = earthsci_integrator_planner::Options {
            time: Some(serde_json::json!({"start": tspan.0, "end": tspan.1})),
        };
        earthsci_integrator_planner::plan(rc, &options, &AstDiffBands)
            .map_err(|e| format!("the integrator's planner refused the run: {e}"))
    }

    /// The plan used without `--run-config`: ONE leaf over every operator of
    /// the model, stepping adaptively with the method the planner picks and
    /// global step-size control, inside fixed macro steps of `dt`.
    ///
    /// Not the integrator's own default schedule (`"auto"`, one leaf per
    /// locality, spec/run-config.md §4.1): that gives a pointwise leaf
    /// per-cell step-size control, which the integrator's runtime refuses
    /// until its milestone M3, and its runtime needs a fixed macro step. The
    /// model's operators are what `"auto"` plans, so it is planned once to
    /// find them.
    fn default_plan(
        dir: &Path,
        model: &Path,
        tspan: (f64, f64),
        dt: Option<f64>,
    ) -> Result<Planned, String> {
        let dt = dt.unwrap_or((tspan.1 - tspan.0) / 100.0);
        if !(dt.is_finite() && dt > 0.0) {
            return Err(format!(
                "--dt must be a positive number of seconds, not {dt}"
            ));
        }
        let write = |schedule: serde_json::Value| -> Result<PathBuf, String> {
            let rc = serde_json::json!({
                "esm_integrator": earthsci_integrator::SPEC_VERSION,
                "model": model.to_string_lossy(),
                "schedule": schedule,
                "step": {"dt": dt},
            });
            let path = dir.join("run.json");
            std::fs::write(&path, serde_json::to_vec_pretty(&rc).expect("JSON"))
                .map_err(|e| format!("{}: {e}", path.display()))?;
            Ok(path)
        };
        let operators: Vec<String> = plan(&write("auto".into())?, tspan)?
            .operators
            .into_keys()
            .collect();
        plan(
            &write(serde_json::json!({
                "leaf": operators,
                "alg": "auto",
                "control": {"dt_scope": "global"},
            }))?,
            tspan,
        )
    }

    /// Output at every macro-step boundary under a fixed `step.dt`, and at the
    /// end of the run otherwise. Under a fixed step an output time must fall
    /// on a boundary (spec/run-config.md §8 rule 9), so these always do.
    fn output_times(dt: Option<f64>, tspan: (f64, f64)) -> Option<Vec<f64>> {
        let dt = dt?;
        let mut t = Vec::new();
        let mut k = 1u64;
        loop {
            let tk = tspan.0 + k as f64 * dt;
            if tk >= tspan.1 - 100.0 * f64::EPSILON * tspan.1.abs().max(1.0) {
                t.push(tspan.1);
                break;
            }
            t.push(tk);
            k += 1;
        }
        Some(t)
    }

    /// Column names and the plan DOF each reads, in the order `earthsci-ast`
    /// lays the state out, so `--output` matches the diffsol solver's. A
    /// state the Problem does not list the same number of elements for is
    /// named `name[k]` (1-based) instead, after the Problem's columns.
    fn columns(
        prob: &earthsci_ast::EsmProblem,
        state_dofs: &std::collections::BTreeMap<String, Vec<usize>>,
    ) -> (Vec<String>, Vec<usize>) {
        let mut cells: HashMap<&str, Vec<&str>> = HashMap::new();
        let flat = prob.state_variable_names();
        for n in &flat {
            let base = n.split('[').next().unwrap_or(n);
            cells.entry(base).or_default().push(n);
        }
        let mut placed: HashMap<&str, usize> = HashMap::new();
        let (mut names, mut dofs) = (Vec::new(), Vec::new());
        for n in &flat {
            let base = n.split('[').next().unwrap_or(n);
            let Some(d) = state_dofs.get(base) else {
                continue;
            };
            if d.len() != cells[base].len() {
                continue;
            }
            let k = placed.entry(base).or_insert(0);
            names.push(n.clone());
            dofs.push(d[*k]);
            *k += 1;
        }
        for (name, d) in state_dofs {
            if placed.contains_key(name.as_str()) {
                continue;
            }
            if d.len() == 1 {
                names.push(name.clone());
                dofs.push(d[0]);
            } else {
                for (k, &j) in d.iter().enumerate() {
                    names.push(format!("{name}[{}]", k + 1));
                    dofs.push(j);
                }
            }
        }
        (names, dofs)
    }
}
