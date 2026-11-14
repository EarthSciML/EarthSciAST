//! The time integrators `esm simulate` runs a dynamic document on.
//!
//! Each is a [`Backend`] behind a cargo feature of this crate, and the
//! features are additive: `diffsol` (on by default) is the solver
//! `earthsci-ast` links, and `integrator` is EarthSciIntegrator. With both in
//! the build, `--backend` picks one per run; with one, it is the default; with
//! neither, [`select`] refuses and names the features to build with. That
//! refusal comes only when a document has something to integrate: [`choose`]
//! checks the command line before anything is loaded, and lets a build with
//! no integrator through, so a static document still evaluates.
//!
//! Both answer with an [`earthsci_ast::Solution`], so everything after the
//! integration (the summary lines, `--output` in either format) is shared.

use earthsci_ast::{EsmFile, EsmProblem, Solution, SolveOptions};
use std::path::{Path, PathBuf};

/// One integration of a dynamic document. Each backend reads what it needs:
/// diffsol the Problem, the integrator the document's path and the interval.
#[cfg_attr(
    not(all(feature = "diffsol", feature = "integrator")),
    allow(dead_code)
)]
pub struct SimulateRun<'a> {
    /// The document, as named on the command line.
    pub file: &'a Path,
    /// The document as `earthsci-ast` loaded it, with every metaparameter its
    /// data sources measure closed: the index-set sizes the Problem was built
    /// with.
    pub esm_file: &'a EsmFile,
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

/// The backend `--backend` names, or this build's default when it names none
/// (`None` when this build has no time integrator at all). Refuses a name
/// that is unknown or not in this build, and integrator options given with
/// diffsol: none of that depends on the document, so the command line is
/// checked before anything is loaded.
pub fn choose(
    name: Option<&str>,
    integrator: &IntegratorOptions,
) -> Result<Option<&'static str>, String> {
    let known = ["diffsol", "integrator"];
    let name: &'static str = match name {
        Some(n) => {
            let n = n.to_ascii_lowercase();
            match known.iter().find(|k| **k == n) {
                Some(k) => k,
                None => {
                    return Err(format!(
                        "unknown backend {n:?}: expected one of {}",
                        known.join(", ")
                    ));
                }
            }
        }
        None => match available().first() {
            Some(n) => n,
            None => return Ok(None),
        },
    };
    if !available().contains(&name) {
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
    Ok(Some(name))
}

/// The backend [`choose`] picked. Called only once a document turns out to
/// have something to integrate, so a build with no time integrator refuses
/// here, not before.
pub fn select(
    choice: Option<&'static str>,
    integrator: IntegratorOptions,
) -> Result<Box<dyn Backend>, String> {
    #[cfg(not(feature = "integrator"))]
    let _ = integrator;
    match choice {
        None => Err(
            "this document has differential equations to integrate, and \
                     this build of `esm` has no time integrator: rebuild with \
                     `--features diffsol` or `--features integrator`"
                .into(),
        ),
        #[cfg(feature = "diffsol")]
        Some("diffsol") => Ok(Box::new(Diffsol)),
        #[cfg(feature = "integrator")]
        Some("integrator") => Ok(Box::new(integrator::Integrator(integrator))),
        Some(other) => unreachable!("`choose` admits only a backend in this build, not {other}"),
    }
}

/// The esm major version EarthSciIntegrator reads. It depends on its own
/// `earthsci-ast` (0.10, schema 1.3.0), not this workspace's, so a document
/// in esm 2.x is refused by its planner. Raise this when an integrator
/// release built on `earthsci-ast` 0.12 or later is the one linked here.
#[cfg(feature = "integrator")]
pub const INTEGRATOR_ESM_MAJOR: u64 = 1;

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
            reads_format(&run.esm_file.esm)?;
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
            same_index_sets(run.esm_file, &planned.model)?;
            planned
                .write(&dir)
                .map_err(|e| format!("writing the plan to {}: {e}", dir.display()))?;

            let data = DataOptions {
                model: Some(model),
                ..Default::default()
            };
            let lp = load_plan_with::<f64>(&dir, &data).map_err(|e| e.to_string())?;
            // Labeled before integrating, so a state that cannot be labeled is
            // refused before the run rather than after it.
            let (names, dofs) = columns(run.prob, &planned.model, &lp.state_dofs, lp.problem.n)?;
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

    /// Refuse a document in an esm format newer than the integrator's own
    /// `earthsci-ast` reads ([`super::INTEGRATOR_ESM_MAJOR`]), before its
    /// planner fails on it with a schema-version error.
    fn reads_format(esm: &str) -> Result<(), String> {
        let major = esm.split('.').next().and_then(|m| m.parse::<u64>().ok());
        match major {
            Some(m) if m <= super::INTEGRATOR_ESM_MAJOR => Ok(()),
            _ => Err(format!(
                "the integrator backend reads esm {}.x documents only, and this \
                 document is esm {esm}: the EarthSciIntegrator release linked \
                 here is built on an older `earthsci-ast`. Run it with \
                 `--backend diffsol`, or wait for an EarthSciIntegrator release \
                 built on `earthsci-ast` 0.12",
                super::INTEGRATOR_ESM_MAJOR
            )),
        }
    }

    /// The integrator re-reads the document from disk with its own
    /// `earthsci-ast`, so it never sees a metaparameter this command closed
    /// from the document's data (`close_declared_extents`). Refuse when an
    /// index set the integrator planned over has a different size than the
    /// one the Problem was built with, rather than integrate another grid.
    fn same_index_sets(
        file: &earthsci_ast::EsmFile,
        planned: &earthsci_integrator_planner::model::ModelInfo,
    ) -> Result<(), String> {
        let ours = file.index_sets.as_ref();
        for (name, &theirs) in &planned.index_sets {
            let Some(size) = ours.and_then(|o| o.get(name)).and_then(|s| s.size) else {
                continue;
            };
            if size != theirs {
                return Err(format!(
                    "index set {name} has {size} elements in the Problem `esm` built \
                     (sized by the document's data) but {theirs} in the integrator's \
                     plan, which reads the document without its data; the \
                     integrator backend cannot run this document"
                ));
            }
        }
        Ok(())
    }

    /// Column names and the plan DOF each reads, in the order `earthsci-ast`
    /// lays the state out, so `--output` matches the diffsol backend's.
    ///
    /// Matched by element NAME, not position: the planner names every DOF the
    /// way `earthsci-ast` names a state element (`X`, `X[i,j]`), in its own
    /// canonical order. Its numbering is first checked against the loaded
    /// plan's, and any element one side has and the other lacks is refused
    /// rather than written under the wrong name.
    fn columns(
        prob: &earthsci_ast::EsmProblem,
        model: &earthsci_integrator_planner::model::ModelInfo,
        state_dofs: &std::collections::BTreeMap<String, Vec<usize>>,
        n: usize,
    ) -> Result<(Vec<String>, Vec<usize>), String> {
        let dofs = earthsci_integrator_planner::numeric::Dofs::new(model);
        let consistent = dofs.n == n
            && dofs.states.len() == state_dofs.len()
            && dofs.states.iter().all(|(name, (start, ext))| {
                let len: usize = ext.iter().product();
                state_dofs
                    .get(name)
                    .is_some_and(|d| d.iter().copied().eq(*start..start + len))
            });
        if !consistent {
            return Err(
                "the integrator's loaded plan numbers its state differently from its \
                 planner, so its results cannot be labeled"
                    .into(),
            );
        }
        let at: HashMap<String, usize> = dofs
            .element_names()
            .into_iter()
            .enumerate()
            .map(|(j, name)| (name, j))
            .collect();
        let names = prob.state_variable_names();
        if names.len() != at.len() {
            return Err(format!(
                "the Problem `esm` built has {} state elements and the integrator's \
                 plan {}; the integrator backend cannot label this document's results",
                names.len(),
                at.len()
            ));
        }
        let mut cols = Vec::with_capacity(names.len());
        for name in &names {
            let j = at.get(name).ok_or_else(|| {
                format!(
                    "the state element {name} of the Problem `esm` built is not in the \
                     integrator's plan; the integrator backend cannot label this \
                     document's results"
                )
            })?;
            cols.push(*j);
        }
        Ok((names, cols))
    }
}
