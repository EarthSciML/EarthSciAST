//! Run an esm-spec §6.7 analysis and reduce its runs to plot data.
//!
//! This is the first executor of analyses. It follows the rulings of
//! `docs/content/rfcs/analyses-execution-semantics.md` (R1–R14), cited inline:
//!
//! - R1: every run is sampled on one uniform grid over `time_span`, both ends
//!   included, 101 points unless [`RunOptions::points`] says otherwise.
//! - R2–R5: `mean` is time-weighted, `integral` is the trapezoid integral in
//!   the component's time units, `max`/`min`/`final` are over the grid,
//!   `at_time` interpolates linearly on the grid, and a value with neither
//!   `at_time` nor `reduce` means `reduce: final`.
//! - R6: under a sweep, a line or scatter plot has one series per declared
//!   series and sweep point, each carrying its sweep coordinate.
//! - R7, R8: a heatmap needs a sweep of exactly the two parameters on its axes.
//! - R9: sweep points are enumerated row-major, last dimension fastest, with
//!   the range arithmetic pinned.
//! - R10: a swept parameter overrides `parameters`.
//! - R11: override keys resolve like a test's (the core does this).
//! - R14: a failed run inside a sweep leaves a hole (`None`) and is listed in
//!   [`AnalysisResult::failures`]; a failed single run is an error.
//!
//! One extension: a line or scatter plot whose `x` names a swept parameter
//! plots each run's reduced `y` (by the plot's `value`, default `final`)
//! against that parameter, one series per point of the other dimensions.
//!
//! Field plots (`field_slice`, `field_snapshot`) are not supported yet.

use std::collections::HashMap;

use earthsci_ast::{
    Alg, Compile, EsmFile, EsmProblem, ModelAnalysis, Plot, PlotAxis, PlotY, ProblemOptions,
    Remake, SimulateError, SolveOptions, SweepDimension, esm_problem, remake, solve,
};
use serde::{Serialize, Serializer};
use serde_json::Value;

use crate::assemble::TIME;
use crate::plot_data::{AxisInfo, HeatmapPlot, PlotData, Series, SweepAxis, ValueInfo, XyPlot};

/// The default number of output points per run (RFC R1).
pub const DEFAULT_POINTS: usize = 101;

/// How to run analyses.
#[derive(Debug, Clone)]
pub struct RunOptions {
    /// Output points per run, both ends of `time_span` included (RFC R1).
    pub points: usize,
    /// The solver; the core's default when `None`.
    pub alg: Option<Alg>,
    /// Relative integration tolerance; the document's or the core's default
    /// when `None`.
    pub reltol: Option<f64>,
    /// Absolute integration tolerance; as `reltol`.
    pub abstol: Option<f64>,
}

impl Default for RunOptions {
    fn default() -> Self {
        RunOptions {
            points: DEFAULT_POINTS,
            alg: None,
            reltol: None,
            abstol: None,
        }
    }
}

/// An analysis that could not run at all.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct AnalysisError {
    /// A stable identifier for the kind of problem.
    pub code: String,
    /// What went wrong.
    pub message: String,
}

impl AnalysisError {
    fn new(code: &str, message: impl Into<String>) -> Self {
        AnalysisError {
            code: code.to_string(),
            message: message.into(),
        }
    }
}

impl std::fmt::Display for AnalysisError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for AnalysisError {}

/// The outcome of one analysis (RFC R13's value, not a file layout).
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct AnalysisResult {
    /// The analysis id.
    pub analysis: String,
    /// The model it ran.
    pub model: String,
    /// The output times every run was sampled at.
    pub grid: Vec<f64>,
    /// One record per run, in sweep order.
    pub runs: Vec<RunRecord>,
    /// The plots that could be drawn, in the analysis's order.
    pub plots: Vec<PlotData>,
    /// The plots that could not, with why.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub plot_errors: Vec<PlotError>,
    /// The runs that failed (only under a sweep; RFC R14).
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub failures: Vec<RunFailure>,
}

/// One run of an analysis.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct RunRecord {
    /// The run's grid index, one entry per sweep dimension; empty without a
    /// sweep.
    pub index: Vec<usize>,
    /// The swept parameters' values for this run, in dimension order.
    #[serde(serialize_with = "pairs_as_map")]
    pub sweep_point: Vec<(String, f64)>,
    /// The solver's return code, e.g. `Success`.
    pub retcode: String,
}

/// A run that failed inside a sweep.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct RunFailure {
    /// The run's position in [`AnalysisResult::runs`].
    pub run: usize,
    /// What went wrong.
    pub message: String,
}

/// A plot that could not be drawn.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct PlotError {
    /// The plot id.
    pub plot: String,
    /// A stable identifier for the kind of problem.
    pub code: String,
    /// What is wrong.
    pub message: String,
}

fn pairs_as_map<S: Serializer>(pairs: &[(String, f64)], s: S) -> Result<S::Ok, S::Error> {
    use serde::ser::SerializeMap;
    let mut map = s.serialize_map(Some(pairs.len()))?;
    for (k, v) in pairs {
        map.serialize_entry(k, v)?;
    }
    map.end()
}

/// One sweep dimension, expanded.
struct Dimension {
    parameter: String,
    values: Vec<f64>,
    log: bool,
}

/// The values of one sweep dimension (RFC R9b), or why it is malformed.
fn dimension_values(d: &SweepDimension) -> Result<Dimension, String> {
    let (values, log) = match (&d.values, &d.range) {
        (Some(values), None) => {
            if values.is_empty() {
                return Err(format!("the sweep over `{}` has no values", d.parameter));
            }
            (values.clone(), false)
        }
        (None, Some(r)) => {
            let log = match r.scale.as_deref() {
                None | Some("linear") => false,
                Some("log") => true,
                Some(other) => {
                    return Err(format!(
                        "unknown sweep scale `{other}` for `{}` (expected linear or log)",
                        d.parameter
                    ));
                }
            };
            if r.count < 2 {
                return Err(format!(
                    "the sweep over `{}` needs a count of at least 2",
                    d.parameter
                ));
            }
            if log && (r.start <= 0.0 || r.stop <= 0.0) {
                return Err(format!(
                    "a log sweep over `{}` needs a positive start and stop",
                    d.parameter
                ));
            }
            let n = r.count as usize;
            let step = |i: usize| i as f64 / (n - 1) as f64;
            let values = (0..n)
                .map(|i| {
                    if log {
                        (r.start.ln() + step(i) * (r.stop.ln() - r.start.ln())).exp()
                    } else {
                        r.start + step(i) * (r.stop - r.start)
                    }
                })
                .collect();
            (values, log)
        }
        _ => {
            return Err(format!(
                "the sweep over `{}` needs exactly one of `values` and `range`",
                d.parameter
            ));
        }
    };
    Ok(Dimension {
        parameter: d.parameter.clone(),
        values,
        log,
    })
}

/// Every grid index of a sweep, row-major with the last dimension fastest
/// (RFC R9a).
fn sweep_indices(sizes: &[usize]) -> Vec<Vec<usize>> {
    let total: usize = sizes.iter().product();
    (0..total)
        .map(|mut n| {
            let mut index = vec![0; sizes.len()];
            for (k, &size) in sizes.iter().enumerate().rev() {
                index[k] = n % size;
                n /= size;
            }
            index
        })
        .collect()
}

/// A time series reduced to one number (RFC R2–R5).
fn reduce(
    grid: &[f64],
    values: &[f64],
    reduce: Option<&str>,
    at_time: Option<f64>,
) -> Result<f64, String> {
    if let Some(t) = at_time {
        return interpolate(grid, values, t);
    }
    let integral = || {
        grid.windows(2)
            .zip(values.windows(2))
            .map(|(t, v)| (t[1] - t[0]) * (v[0] + v[1]) / 2.0)
            .sum::<f64>()
    };
    let span = grid.last().unwrap() - grid[0];
    Ok(match reduce.unwrap_or("final") {
        "final" => *values.last().unwrap(),
        "max" => values.iter().copied().fold(f64::NEG_INFINITY, f64::max),
        "min" => values.iter().copied().fold(f64::INFINITY, f64::min),
        "integral" => integral(),
        "mean" => integral() / span,
        other => {
            return Err(format!(
                "unknown reduction `{other}` (expected final, max, min, mean or integral)"
            ));
        }
    })
}

/// Linear interpolation on the grid (RFC R4).
fn interpolate(grid: &[f64], values: &[f64], t: f64) -> Result<f64, String> {
    let (first, last) = (grid[0], *grid.last().unwrap());
    if !(first..=last).contains(&t) {
        return Err(format!(
            "time {t} is outside the run's time span [{first}, {last}]"
        ));
    }
    let k = grid.partition_point(|&g| g <= t).clamp(1, grid.len() - 1);
    let (t0, t1) = (grid[k - 1], grid[k]);
    let w = if t1 > t0 { (t - t0) / (t1 - t0) } else { 0.0 };
    Ok(values[k - 1] + w * (values[k] - values[k - 1]))
}

/// A variable the plots read, and where its values come from.
#[derive(Clone)]
enum Source {
    /// The time grid.
    Time,
    /// A swept parameter.
    Swept(usize),
    /// A row of the solution, by its name in the solution.
    Row(String),
}

/// Resolve a locally spelled name against qualified names from the core:
/// an exact match, then `model.name`, then a unique `….name`.
fn resolve_name(name: &str, model: &str, known: &[String]) -> Option<String> {
    if known.iter().any(|k| k == name) {
        return Some(name.to_string());
    }
    let qualified = format!("{model}.{name}");
    if known.contains(&qualified) {
        return Some(qualified);
    }
    let suffix = format!(".{name}");
    let mut matches = known.iter().filter(|k| k.ends_with(&suffix));
    match (matches.next(), matches.next()) {
        (Some(only), None) => Some(only.clone()),
        _ => None,
    }
}

/// Run one analysis of `model` in `file`.
///
/// Problems confined to one plot are reported in
/// [`AnalysisResult::plot_errors`]; an error return means nothing could be
/// run.
pub fn run_analysis(
    file: &EsmFile,
    model: &str,
    analysis: &ModelAnalysis,
    opts: &RunOptions,
) -> Result<AnalysisResult, AnalysisError> {
    let span = &analysis.time_span;
    if !(span.start.is_finite() && span.end.is_finite() && span.end > span.start) {
        return Err(AnalysisError::new(
            "invalid_time_span",
            format!(
                "the time span [{}, {}] must run forward",
                span.start, span.end
            ),
        ));
    }
    let dims = match &analysis.parameter_sweep {
        None => Vec::new(),
        Some(sweep) => {
            if sweep.sweep_type != "cartesian" {
                return Err(AnalysisError::new(
                    "invalid_sweep",
                    format!(
                        "unknown sweep type `{}` (only cartesian sweeps exist)",
                        sweep.sweep_type
                    ),
                ));
            }
            sweep
                .dimensions
                .iter()
                .map(dimension_values)
                .collect::<Result<Vec<_>, _>>()
                .map_err(|m| AnalysisError::new("invalid_sweep", m))?
        }
    };
    let variables = file
        .models
        .as_ref()
        .and_then(|m| m.get(model))
        .map(|m| &m.variables)
        .ok_or_else(|| {
            AnalysisError::new("unknown_model", format!("no model is named `{model}`"))
        })?;
    let units_of = |name: &str| variables.get(name).and_then(|v| v.units.clone());

    let baseline: HashMap<String, f64> = analysis.parameters.clone().unwrap_or_default();
    let u0 = match &analysis.initial_state {
        None => HashMap::new(),
        Some(Value::Object(map)) => map
            .iter()
            .map(|(k, v)| {
                v.as_f64().map(|x| (k.clone(), x)).ok_or_else(|| {
                    AnalysisError::new(
                        "unsupported_initial_state",
                        format!("the initial state of `{k}` must be a number"),
                    )
                })
            })
            .collect::<Result<_, _>>()?,
        Some(_) => {
            return Err(AnalysisError::new(
                "unsupported_initial_state",
                "only a map from variable to number is supported as an initial state",
            ));
        }
    };

    let tspan = (span.start, span.end);
    let build = |p: HashMap<String, f64>| -> Result<EsmProblem, AnalysisError> {
        esm_problem(
            file,
            tspan,
            ProblemOptions {
                p,
                u0: u0.clone(),
                model_name: Some(model.to_string()),
                compile: Compile::Always,
                ..Default::default()
            },
        )
        .map_err(|e| {
            AnalysisError::new("build_failed", format!("the model could not be built: {e}"))
        })
    };
    let base = build(baseline.clone())?;

    // Which solution rows the plots need, and which names they are.
    let states = base.state_variable_names();
    let observed = base.observed_variable_names();
    let known: Vec<String> = states.iter().chain(&observed).cloned().collect();
    let parameters = base.parameter_names();
    let source_of = |name: &str| -> Result<Source, String> {
        if name == TIME {
            return Ok(Source::Time);
        }
        if let Some(k) = dims.iter().position(|d| d.parameter == name) {
            return Ok(Source::Swept(k));
        }
        match resolve_name(name, model, &known) {
            Some(row) => Ok(Source::Row(row)),
            None if resolve_name(name, model, &parameters).is_some() => Err(format!(
                "`{name}` is a parameter that is not swept, so it is constant; plot a variable instead"
            )),
            None => Err(format!("`{name}` is not a variable of model `{model}`")),
        }
    };

    let plots = analysis.plots.clone().unwrap_or_default();
    let mut specs = Vec::new();
    let mut plot_errors = Vec::new();
    for plot in &plots {
        match PlotSpec::new(plot, &dims, &source_of, span.start, span.end) {
            Ok(spec) => specs.push(spec),
            Err((code, message)) => plot_errors.push(PlotError {
                plot: plot.id.clone(),
                code: code.to_string(),
                message,
            }),
        }
    }
    let mut rows: Vec<String> = Vec::new();
    for spec in &specs {
        for source in spec.sources() {
            if let Source::Row(r) = source
                && !rows.contains(r)
            {
                rows.push(r.clone());
            }
        }
    }

    let mut solve_opts = SolveOptions::default();
    if let Some(alg) = opts.alg {
        solve_opts.alg = alg;
    }
    solve_opts.reltol = opts.reltol;
    solve_opts.abstol = opts.abstol;
    solve_opts.sample_evenly(span.start, span.end, opts.points);
    let grid = solve_opts
        .saveat
        .clone()
        .expect("sample_evenly sets saveat");
    solve_opts.output_observed = rows
        .iter()
        .filter(|r| observed.contains(r))
        .cloned()
        .collect();

    // Run every sweep point (or the one baseline run).
    let sizes: Vec<usize> = dims.iter().map(|d| d.values.len()).collect();
    let indices = if dims.is_empty() {
        vec![Vec::new()]
    } else {
        sweep_indices(&sizes)
    };
    let mut runs = Vec::with_capacity(indices.len());
    let mut outputs: Vec<Option<HashMap<String, Vec<f64>>>> = Vec::with_capacity(indices.len());
    let mut failures = Vec::new();
    for index in indices {
        let point: Vec<(String, f64)> = index
            .iter()
            .zip(&dims)
            .map(|(&i, d)| (d.parameter.clone(), d.values[i]))
            .collect();
        let outcome = run_once(
            &base,
            &build,
            &baseline,
            &point,
            &parameters,
            model,
            &solve_opts,
            &rows,
            grid.len(),
        );
        let (retcode, output) = match outcome {
            Ok((retcode, output)) => (retcode, Some(output)),
            Err((retcode, message)) => {
                if dims.is_empty() {
                    return Err(AnalysisError::new("run_failed", message));
                }
                failures.push(RunFailure {
                    run: runs.len(),
                    message,
                });
                (retcode, None)
            }
        };
        runs.push(RunRecord {
            index,
            sweep_point: point,
            retcode,
        });
        outputs.push(output);
    }

    let ctx = Context {
        grid: &grid,
        dims: &dims,
        runs: &runs,
        outputs: &outputs,
        units_of: &units_of,
    };
    let mut drawn = Vec::new();
    for spec in &specs {
        match spec.draw(&ctx) {
            Ok(data) => drawn.push(data),
            Err(message) => plot_errors.push(PlotError {
                plot: spec.plot.id.clone(),
                code: "plot_failed".to_string(),
                message,
            }),
        }
    }
    // Keep the analysis's plot order in the errors too.
    plot_errors.sort_by_key(|e| plots.iter().position(|p| p.id == e.plot));

    Ok(AnalysisResult {
        analysis: analysis.id.clone(),
        model: model.to_string(),
        grid,
        runs,
        plots: drawn,
        plot_errors,
        failures,
    })
}

/// A run's return code and the rows the plots need, or its return code and
/// why it failed.
type RunOutcome = Result<(String, HashMap<String, Vec<f64>>), (String, String)>;

/// Solve one sweep point, returning the needed rows, or the return code and
/// why it failed.
#[allow(clippy::too_many_arguments)]
fn run_once(
    base: &EsmProblem,
    build: &dyn Fn(HashMap<String, f64>) -> Result<EsmProblem, AnalysisError>,
    baseline: &HashMap<String, f64>,
    point: &[(String, f64)],
    parameters: &[String],
    model: &str,
    solve_opts: &SolveOptions,
    rows: &[String],
    samples: usize,
) -> RunOutcome {
    let remade;
    let prob = if point.is_empty() {
        base
    } else {
        // RFC R10: the swept values override the analysis's parameters. Remake
        // reuses the compiled model; a parameter baked into the build needs a
        // fresh one.
        let mut p = HashMap::new();
        for (name, value) in point {
            let key = resolve_name(name, model, parameters).unwrap_or_else(|| name.clone());
            p.insert(key, *value);
        }
        remade = match remake(
            base,
            &Remake {
                p,
                ..Default::default()
            },
        ) {
            Ok(prob) => prob,
            Err(SimulateError::UnsubstitutableBinding { .. }) => {
                let mut p = baseline.clone();
                p.extend(point.iter().cloned());
                build(p).map_err(|e| ("Failure".to_string(), e.message))?
            }
            Err(e) => return Err(("Failure".to_string(), e.to_string())),
        };
        &remade
    };
    let sol = solve(prob, solve_opts)
        .map_err(|e| ("Failure".to_string(), format!("the solver failed: {e}")))?;
    let retcode = sol.retcode.name().to_string();
    if !sol.retcode.is_success() {
        return Err((
            retcode.clone(),
            format!("the solver stopped early ({retcode})"),
        ));
    }
    if sol.time.len() != samples {
        return Err((
            "Failure".to_string(),
            format!(
                "the solver returned {} samples, not {samples}",
                sol.time.len()
            ),
        ));
    }
    let mut out = HashMap::new();
    for row in rows {
        let at = sol
            .state_variable_names
            .iter()
            .position(|n| n == row)
            .ok_or_else(|| {
                (
                    "Failure".to_string(),
                    format!("the solution has no `{row}`"),
                )
            })?;
        out.insert(row.clone(), sol.state[at].clone());
    }
    Ok((retcode, out))
}

/// What the plots need from the runs.
struct Context<'a> {
    grid: &'a [f64],
    dims: &'a [Dimension],
    runs: &'a [RunRecord],
    outputs: &'a [Option<HashMap<String, Vec<f64>>>],
    units_of: &'a dyn Fn(&str) -> Option<String>,
}

impl Context<'_> {
    fn axis(&self, axis: &PlotAxis) -> AxisInfo {
        AxisInfo {
            variable: axis.variable.clone(),
            label: axis.label.clone(),
            units: if axis.variable == TIME {
                None
            } else {
                (self.units_of)(&axis.variable)
            },
        }
    }

    /// A trajectory of `source` in run `r`, or `None` when the run failed.
    fn trajectory(&self, source: &Source, r: usize) -> Option<Vec<f64>> {
        match source {
            Source::Time => Some(self.grid.to_vec()),
            Source::Swept(k) => Some(vec![self.runs[r].sweep_point[*k].1; self.grid.len()]),
            Source::Row(row) => self.outputs[r].as_ref().map(|o| o[row].clone()),
        }
    }
}

/// A plot checked against its analysis, ready to draw.
struct PlotSpec<'p> {
    plot: &'p Plot,
    x: Source,
    /// (series name, variable, source).
    series: Vec<(String, String, Source)>,
    value_reduce: Option<String>,
    value_at: Option<f64>,
    heatmap: Option<(usize, usize, Source)>,
}

type SpecError = (&'static str, String);

impl<'p> PlotSpec<'p> {
    fn new(
        plot: &'p Plot,
        dims: &[Dimension],
        source_of: &dyn Fn(&str) -> Result<Source, String>,
        start: f64,
        end: f64,
    ) -> Result<Self, SpecError> {
        let bad = |m: String| ("invalid_plot", m);
        let value_reduce = plot.value.as_ref().and_then(|v| v.reduce.clone());
        let value_at = plot.value.as_ref().and_then(|v| v.at_time);
        if let Some(t) = value_at
            && !(start..=end).contains(&t)
        {
            return Err(bad(format!(
                "`at_time` {t} is outside the time span [{start}, {end}]"
            )));
        }
        match plot.plot_type.as_str() {
            "line" | "scatter" => {
                let x = source_of(&plot.x.variable).map_err(bad)?;
                // An explicit `series` wins over a `y` array (§6.7).
                let declared: Vec<(String, String)> = match (&plot.series, &plot.y) {
                    (Some(series), _) => series
                        .iter()
                        .map(|s| (s.name.clone(), s.variable.clone()))
                        .collect(),
                    (None, PlotY::Axis(a)) => vec![(
                        a.label.clone().unwrap_or_else(|| a.variable.clone()),
                        a.variable.clone(),
                    )],
                    (None, PlotY::Axes(axes)) => axes
                        .iter()
                        .map(|a| {
                            (
                                a.label.clone().unwrap_or_else(|| a.variable.clone()),
                                a.variable.clone(),
                            )
                        })
                        .collect(),
                };
                if declared.is_empty() {
                    return Err(bad("the plot has no series".to_string()));
                }
                let mut series = Vec::new();
                for (name, variable) in declared {
                    let source = source_of(&variable).map_err(bad)?;
                    series.push((name, variable, source));
                }
                if matches!(x, Source::Swept(_))
                    && series.iter().any(|(_, _, s)| !matches!(s, Source::Row(_)))
                {
                    return Err(bad(
                        "against a swept parameter, every series must plot a variable".to_string(),
                    ));
                }
                Ok(PlotSpec {
                    plot,
                    x,
                    series,
                    value_reduce,
                    value_at,
                    heatmap: None,
                })
            }
            "heatmap" => {
                // RFC R7, R8.
                if dims.is_empty() {
                    return Err((
                        "heatmap_requires_sweep",
                        "a heatmap needs a parameter sweep".to_string(),
                    ));
                }
                let axis = |a: &PlotAxis| {
                    dims.iter().position(|d| d.parameter == a.variable).ok_or_else(|| {
                        (
                            "plot_axis_not_swept",
                            format!("a heatmap axis must be a swept parameter, and `{}` is not swept", a.variable),
                        )
                    })
                };
                let PlotY::Axis(y) = &plot.y else {
                    return Err(bad("a heatmap has one y axis".to_string()));
                };
                let (xd, yd) = (axis(&plot.x)?, axis(y)?);
                if xd == yd || dims.len() != 2 {
                    return Err((
                        "heatmap_dimensions",
                        "a heatmap needs a sweep of exactly two parameters, one on each axis"
                            .to_string(),
                    ));
                }
                let value = plot
                    .value
                    .as_ref()
                    .ok_or_else(|| bad("a heatmap needs a `value` to color by".to_string()))?;
                let source = source_of(&value.variable).map_err(bad)?;
                if !matches!(source, Source::Row(_)) {
                    return Err(bad(format!(
                        "a heatmap colors by a variable, and `{}` is not one",
                        value.variable
                    )));
                }
                Ok(PlotSpec {
                    plot,
                    x: Source::Swept(xd),
                    series: Vec::new(),
                    value_reduce,
                    value_at,
                    heatmap: Some((xd, yd, source)),
                })
            }
            other if other.starts_with("field_") => Err((
                "unsupported_plot",
                format!("`{other}` plots are not supported yet"),
            )),
            other => Err(("unsupported_plot", format!("unknown plot type `{other}`"))),
        }
    }

    fn sources(&self) -> Vec<&Source> {
        let mut out = vec![&self.x];
        out.extend(self.series.iter().map(|(_, _, s)| s));
        if let Some((_, _, s)) = &self.heatmap {
            out.push(s);
        }
        out
    }

    fn scalar(&self, ctx: &Context, source: &Source, r: usize) -> Result<Option<f64>, String> {
        match ctx.trajectory(source, r) {
            None => Ok(None),
            Some(values) => reduce(
                ctx.grid,
                &values,
                self.value_reduce.as_deref(),
                self.value_at,
            )
            .map(Some),
        }
    }

    fn draw(&self, ctx: &Context) -> Result<PlotData, String> {
        let plot = self.plot;
        if let Some((xd, yd, source)) = &self.heatmap {
            let (nx, ny) = (ctx.dims[*xd].values.len(), ctx.dims[*yd].values.len());
            let mut z = vec![vec![None; nx]; ny];
            for (r, run) in ctx.runs.iter().enumerate() {
                z[run.index[*yd]][run.index[*xd]] = self.scalar(ctx, source, r)?;
            }
            let sweep_axis = |d: usize, axis: &PlotAxis| SweepAxis {
                info: ctx.axis(axis),
                values: ctx.dims[d].values.clone(),
                scale: if ctx.dims[d].log { "log" } else { "linear" }.to_string(),
            };
            let PlotY::Axis(y) = &plot.y else {
                unreachable!("checked in new")
            };
            let value = plot.value.as_ref().expect("checked in new");
            return Ok(PlotData::Heatmap(HeatmapPlot {
                id: plot.id.clone(),
                description: plot.description.clone(),
                x: sweep_axis(*xd, &plot.x),
                y: sweep_axis(*yd, y),
                value: ValueInfo {
                    info: ctx.axis(&PlotAxis {
                        variable: value.variable.clone(),
                        label: None,
                    }),
                    reduce: if self.value_at.is_some() {
                        None
                    } else {
                        Some(
                            self.value_reduce
                                .clone()
                                .unwrap_or_else(|| "final".to_string()),
                        )
                    },
                    at_time: self.value_at,
                },
                z,
            }));
        }

        let mut series = Vec::new();
        if let Source::Swept(xd) = self.x {
            // One series per declared series and point of the other
            // dimensions, each run reduced to one y value.
            let others: Vec<usize> = (0..ctx.dims.len()).filter(|&k| k != xd).collect();
            let mut groups: Vec<(Vec<usize>, Vec<usize>)> = Vec::new();
            for (r, run) in ctx.runs.iter().enumerate() {
                let key: Vec<usize> = others.iter().map(|&k| run.index[k]).collect();
                match groups.iter_mut().find(|(k, _)| *k == key) {
                    Some((_, members)) => members.push(r),
                    None => groups.push((key, vec![r])),
                }
            }
            for (name, variable, source) in &self.series {
                for (_, members) in &groups {
                    let mut members = members.clone();
                    members.sort_by_key(|&r| ctx.runs[r].index[xd]);
                    let mut x = Vec::new();
                    let mut y = Vec::new();
                    for &r in &members {
                        x.push(Some(ctx.runs[r].sweep_point[xd].1));
                        y.push(self.scalar(ctx, source, r)?);
                    }
                    let first = members[0];
                    series.push(Series {
                        name: name.clone(),
                        variable: variable.clone(),
                        sweep_point: others
                            .iter()
                            .map(|&k| ctx.runs[first].sweep_point[k].clone())
                            .collect(),
                        x,
                        y,
                    });
                }
            }
        } else {
            // RFC R6: every declared series in every run.
            for (name, variable, source) in &self.series {
                for (r, run) in ctx.runs.iter().enumerate() {
                    let gap = || vec![None; ctx.grid.len()];
                    let some = |v: Vec<f64>| v.into_iter().map(Some).collect::<Vec<_>>();
                    series.push(Series {
                        name: name.clone(),
                        variable: variable.clone(),
                        sweep_point: run.sweep_point.clone(),
                        x: ctx.trajectory(&self.x, r).map(some).unwrap_or_else(gap),
                        y: ctx.trajectory(source, r).map(some).unwrap_or_else(gap),
                    });
                }
            }
        }
        let first_y = match &plot.y {
            PlotY::Axis(a) => a.clone(),
            PlotY::Axes(axes) => axes.first().cloned().unwrap_or(PlotAxis {
                variable: self.series[0].1.clone(),
                label: None,
            }),
        };
        let xy = XyPlot {
            id: plot.id.clone(),
            description: plot.description.clone(),
            x: ctx.axis(&plot.x),
            y: ctx.axis(&first_y),
            series,
        };
        Ok(if plot.plot_type == "scatter" {
            PlotData::Scatter(xy)
        } else {
            PlotData::Line(xy)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use earthsci_ast::{SweepRange, load_string};

    #[test]
    fn range_arithmetic_is_pinned() {
        let d = dimension_values(&SweepDimension {
            parameter: "k".into(),
            values: None,
            range: Some(SweepRange {
                start: 1e-6,
                stop: 1e-4,
                count: 3,
                scale: Some("log".into()),
            }),
        })
        .unwrap();
        // exp(lerp(log)) is the pinned arithmetic (RFC R9b); it can miss even
        // the endpoints by an ulp.
        assert!((d.values[0] - 1e-6).abs() < 1e-20);
        assert!((d.values[1] - 1e-5).abs() < 1e-18);
        assert!((d.values[2] - 1e-4).abs() < 1e-17);
        let d = dimension_values(&SweepDimension {
            parameter: "k".into(),
            values: None,
            range: Some(SweepRange {
                start: 0.0,
                stop: 1.0,
                count: 5,
                scale: None,
            }),
        })
        .unwrap();
        assert_eq!(d.values, vec![0.0, 0.25, 0.5, 0.75, 1.0]);
    }

    #[test]
    fn sweep_order_is_row_major() {
        assert_eq!(
            sweep_indices(&[2, 3]),
            vec![
                vec![0, 0],
                vec![0, 1],
                vec![0, 2],
                vec![1, 0],
                vec![1, 1],
                vec![1, 2]
            ]
        );
    }

    #[test]
    fn reductions() {
        let grid = [0.0, 1.0, 2.0];
        let v = [0.0, 2.0, 1.0];
        assert_eq!(reduce(&grid, &v, None, None), Ok(1.0));
        assert_eq!(reduce(&grid, &v, Some("max"), None), Ok(2.0));
        assert_eq!(reduce(&grid, &v, Some("min"), None), Ok(0.0));
        assert_eq!(reduce(&grid, &v, Some("integral"), None), Ok(2.5));
        assert_eq!(reduce(&grid, &v, Some("mean"), None), Ok(1.25));
        assert_eq!(reduce(&grid, &v, None, Some(0.5)), Ok(1.0));
        assert_eq!(reduce(&grid, &v, None, Some(2.0)), Ok(1.0));
        assert!(reduce(&grid, &v, None, Some(3.0)).is_err());
        assert!(reduce(&grid, &v, Some("median"), None).is_err());
    }

    fn comprehensive() -> EsmFile {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../tests/valid/tests_analyses_comprehensive.esm"
        );
        load_string(&std::fs::read_to_string(path).unwrap()).unwrap()
    }

    fn analysis<'a>(file: &'a EsmFile, model: &str, id: &str) -> &'a ModelAnalysis {
        file.models.as_ref().unwrap()[model]
            .analyses
            .as_ref()
            .unwrap()
            .iter()
            .find(|a| a.id == id)
            .unwrap()
    }

    #[test]
    fn single_run_line_and_scatter() {
        let file = comprehensive();
        let a = analysis(&file, "LogisticGrowth", "single_run");
        let r = run_analysis(&file, "LogisticGrowth", a, &RunOptions::default()).unwrap();
        assert!(r.plot_errors.is_empty(), "{:?}", r.plot_errors);
        assert_eq!(r.grid.len(), DEFAULT_POINTS);
        assert_eq!((r.grid[0], *r.grid.last().unwrap()), (0.0, 30.0));
        assert_eq!(r.runs.len(), 1);
        let PlotData::Line(line) = &r.plots[0] else {
            panic!()
        };
        assert_eq!(line.series.len(), 1);
        assert_eq!(line.x.label.as_deref(), Some("time (s)"));
        let y = &line.series[0].y;
        // Logistic growth from 1 toward K = 100 at r = 0.5.
        let exact = |t: f64| 100.0 / (1.0 + 99.0 * (-0.5 * t).exp());
        for (t, v) in r.grid.iter().zip(y) {
            assert!((v.unwrap() - exact(*t)).abs() < 1e-2 * exact(*t), "t={t}");
        }
        assert!(matches!(r.plots[1], PlotData::Scatter(_)));
    }

    #[test]
    fn sweeps_make_heatmaps_and_overlays() {
        let file = comprehensive();
        let a = analysis(&file, "LogisticGrowth", "rK_heatmap_sweep");
        let r = run_analysis(&file, "LogisticGrowth", a, &RunOptions::default()).unwrap();
        assert!(r.plot_errors.is_empty(), "{:?}", r.plot_errors);
        assert!(r.failures.is_empty());
        assert_eq!(r.runs.len(), 50);
        let PlotData::Heatmap(h) = &r.plots[0] else {
            panic!()
        };
        assert_eq!((h.x.values.len(), h.y.values.len()), (10, 5));
        assert_eq!(h.y.scale, "log");
        // Final N approaches K for every r over 50 time units, except the
        // slowest growth rates.
        let k_last = *h.y.values.last().unwrap();
        let n = h.z[4][9].unwrap();
        assert!((n - k_last).abs() < 0.01 * k_last, "{n} vs {k_last}");

        let a = analysis(&file, "LogisticGrowth", "enumerated_r_sweep");
        let r = run_analysis(&file, "LogisticGrowth", a, &RunOptions::default()).unwrap();
        let PlotData::Line(line) = &r.plots[0] else {
            panic!()
        };
        assert_eq!(line.series.len(), 7);
        assert_eq!(line.series[2].sweep_point, vec![("r".to_string(), 0.5)]);
    }

    #[test]
    fn plot_problems_stay_with_their_plot() {
        let file = load_string(
            r#"{"esm": "1.2.0", "metadata": {"name": "D"}, "models": {"D": {
                "variables": {"x": {"type": "unknown", "default": 1.0},
                              "k": {"type": "parameter", "default": 0.5}},
                "equations": [{"lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                               "rhs": {"op": "*", "args": [{"op": "-", "args": ["k"]}, "x"]}}]}}}"#,
        )
        .unwrap();
        let a: ModelAnalysis = serde_json::from_value(serde_json::json!({
            "id": "a", "time_span": {"start": 0, "end": 2},
            "parameter_sweep": {"type": "cartesian",
                "dimensions": [{"parameter": "k", "values": [0.5, 1.0, 2.0]}]},
            "plots": [
                {"id": "heat", "type": "heatmap", "x": {"variable": "k"}, "y": {"variable": "x"},
                 "value": {"variable": "x"}},
                {"id": "final", "type": "line", "x": {"variable": "k"}, "y": {"variable": "x"}},
                {"id": "flat", "type": "line", "x": {"variable": "t"}, "y": {"variable": "q"}}
            ]
        }))
        .unwrap();
        let r = run_analysis(&file, "D", &a, &RunOptions::default()).unwrap();
        let errors: Vec<_> = r
            .plot_errors
            .iter()
            .map(|e| (e.plot.as_str(), e.code.as_str()))
            .collect();
        assert_eq!(
            errors,
            [("heat", "plot_axis_not_swept"), ("flat", "invalid_plot")]
        );
        // Final x against the swept k: exp(-2k).
        let PlotData::Line(line) = &r.plots[0] else {
            panic!()
        };
        assert_eq!(line.series.len(), 1);
        for (k, x) in line.series[0].x.iter().zip(&line.series[0].y) {
            let expected = (-2.0 * k.unwrap()).exp();
            assert!((x.unwrap() - expected).abs() < 1e-3 * expected);
        }
    }
}
