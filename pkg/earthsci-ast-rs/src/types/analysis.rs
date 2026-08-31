use super::*;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// Numerical comparison tolerance used by inline model tests.
///
/// Either or both of `abs` / `rel` may be set. An assertion passes when any
/// set bound is satisfied:
/// `|actual - expected| <= abs`  OR
/// `|actual - expected| / max(|expected|, epsilon) <= rel`.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Tolerance {
    /// Absolute tolerance bound.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub abs: Option<f64>,

    /// Relative tolerance bound.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rel: Option<f64>,
}

/// Simulation time interval used by inline model tests.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TimeSpan {
    /// Start of the simulation window (in the component's time units).
    pub start: f64,

    /// End of the simulation window (in the component's time units).
    pub end: f64,
}

/// The `reference` solution of an error-norm assertion (esm-spec §6.6.5):
/// either an inline Expression evaluated over the component's domain
/// coordinates, or a `{type: "from_file", path, format?}` shape pointing at a
/// precomputed snapshot (parsed and carried verbatim; not evaluated by this
/// binding). Untagged: the `from_file` object shape is tried first — an
/// Expression operator node always carries `op`, so the two never collide.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum AssertionReference {
    /// `{type: "from_file", path, format?}` precomputed-snapshot pointer.
    FromFile(FromFileReference),
    /// Inline analytic Expression over the domain coordinates (boxed — an
    /// [`Expr`] is large, and most assertions carry no reference at all).
    Expression(Box<Expr>),
}

/// The `{type: "from_file", path, format?}` shape of a §6.6.5 assertion
/// `reference` (schema `Assertion.reference` oneOf, second branch).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FromFileReference {
    /// Discriminator; the schema pins it to the constant `"from_file"`.
    #[serde(rename = "type")]
    pub ref_type: String,

    /// Path of the precomputed reference snapshot.
    pub path: String,

    /// Optional file-format hint (e.g. `"netcdf"`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub format: Option<String>,
}

/// A single scalar `(variable, time, expected)` check inside a [`ModelTest`],
/// or one of its §6.6.5 PDE-aware variants: `coords` point-samples an array
/// state at physical coordinates, `reduce` collapses the variable's spatial
/// field to a scalar (`L2_error`/`Linf_error` against `reference`, or the
/// pure collapsers `integral`/`mean`/`max`/`min`). `coords` and `reduce` are
/// mutually exclusive per the schema.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ModelTestAssertion {
    /// Name of the variable or species to check.
    pub variable: String,

    /// Simulation time at which to evaluate the assertion.
    pub time: f64,

    /// Expected scalar value of the variable at the given time.
    pub expected: f64,

    /// Per-assertion tolerance override. Takes precedence over test-level
    /// and model-level defaults when present.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tolerance: Option<Tolerance>,

    /// Spatial-point evaluation (esm-spec §6.6.5): index-set / dimension name
    /// → numeric coordinate at which to sample the field. Mutually exclusive
    /// with `reduce`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub coords: Option<HashMap<String, f64>>,

    /// Domain reduction (esm-spec §6.6.5): one of `integral`, `mean`, `max`,
    /// `min`, `L2_error`, `Linf_error`. The error norms require `reference`.
    /// Mutually exclusive with `coords`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reduce: Option<String>,

    /// Reference (analytic or precomputed) solution required by the
    /// error-norm reductions (esm-spec §6.6.5).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reference: Option<AssertionReference>,
}

/// Inline validation test for a [`Model`] (schema gt-cc1).
///
/// Defines the run configuration — initial conditions, parameter overrides,
/// simulation time span — and a list of scalar assertions that must hold.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ModelTest {
    /// Identifier unique within this component's `tests` array.
    pub id: String,

    /// Human-readable description of what this test verifies.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,

    /// Initial-value overrides for state variables, keyed by variable name.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub initial_conditions: Option<HashMap<String, f64>>,

    /// Parameter overrides, keyed by parameter name.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parameter_overrides: Option<HashMap<String, f64>>,

    /// Simulation time interval for this test.
    pub time_span: TimeSpan,

    /// Test-level default tolerance applied to assertions that do not
    /// override it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tolerance: Option<Tolerance>,

    /// Scalar `(variable, time)` checks that define the pass/fail criterion.
    pub assertions: Vec<ModelTestAssertion>,

    /// esm-spec §9.7.10 form C / §6.6.6: raw §9.7.2 import entries injected into
    /// the ENCLOSING component's template scope for THIS test's run only — the
    /// discretization a discretization-agnostic PDE leaf is lowered under in the
    /// per-test ephemeral build ([`crate::pde_inline_tests::ephemeral_injected_file`]).
    /// Authored per-run config (a peer of `parameter_overrides` / `tolerance`),
    /// so unlike a component's own imports it DOES survive `parse → emit`; the
    /// enclosing component round-trips with its rewrite-targets intact. Empty
    /// for a non-PDE / discretization-free test.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub expression_template_imports: Vec<serde_json::Value>,
}

/// Generated range of values for one [`SweepDimension`] (schema `SweepRange`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SweepRange {
    /// First value of the range.
    pub start: f64,

    /// Last value of the range.
    pub stop: f64,

    /// Number of values (≥ 2 per the schema).
    pub count: i64,

    /// `"linear"` (default) | `"log"` spacing.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scale: Option<String>,
}

/// One axis of a [`ParameterSweep`] (schema `SweepDimension`): exactly one of
/// `values` / `range` is present.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SweepDimension {
    /// Name of the parameter to vary (local to the enclosing component).
    pub parameter: String,

    /// Enumerated values for this axis; mutually exclusive with `range`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub values: Option<Vec<f64>>,

    /// Generated range for this axis; mutually exclusive with `values`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub range: Option<SweepRange>,
}

/// A parameter-sweep specification on a [`ModelAnalysis`] (schema
/// `ParameterSweep`). Only Cartesian-product sweeps exist: the run count is
/// the product of the dimensions' lengths.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ParameterSweep {
    /// Combination strategy; the schema pins it to the constant `"cartesian"`.
    #[serde(rename = "type")]
    pub sweep_type: String,

    /// The swept axes, one per parameter.
    pub dimensions: Vec<SweepDimension>,
}

/// Axis specification of an analysis [`Plot`] (schema `PlotAxis`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PlotAxis {
    /// Variable or parameter name (local or subsystem-scoped).
    pub variable: String,

    /// Human-readable axis label; viewers fall back to the variable name.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
}

/// A [`Plot`]'s `y` field (schema `Plot.y` oneOf): a single axis, or an array
/// of axes for inline multi-series line/scatter plots. Untagged: an object is
/// the single-axis form, an array the multi-series form — the two JSON shapes
/// never collide.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum PlotY {
    /// Single y-axis.
    Axis(PlotAxis),
    /// Inline multi-series axes (≥ 1 per the schema).
    Axes(Vec<PlotAxis>),
}

/// A scalar value derived from a trajectory, used for heatmap / color
/// channels (schema `PlotValue`). Exactly one of `at_time` / `reduce` should
/// be given.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PlotValue {
    /// Variable whose trajectory is reduced to a scalar per run.
    pub variable: String,

    /// Simulation time at which to sample the variable.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub at_time: Option<f64>,

    /// Time-reduction: `max` | `min` | `mean` | `integral` | `final`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reduce: Option<String>,
}

/// A single named series of a multi-series line/scatter [`Plot`] (schema
/// `PlotSeries`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PlotSeries {
    /// Series display name.
    pub name: String,

    /// Variable plotted by this series.
    pub variable: String,
}

/// A plot specification of a [`ModelAnalysis`] (schema `Plot`). Structural
/// information only — axes, series selection, value reductions; styling is
/// the viewer's concern.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Plot {
    /// Identifier unique within the analysis's `plots` array.
    pub id: String,

    /// `"line"` | `"scatter"` | `"heatmap"` | `"field_slice"` | `"field_snapshot"`.
    #[serde(rename = "type")]
    pub plot_type: String,

    /// Human-readable description.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,

    /// X-axis specification.
    pub x: PlotAxis,

    /// Y-axis specification: single axis or inline multi-series array.
    pub y: PlotY,

    /// Color channel for heatmap / field_snapshot plots.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value: Option<PlotValue>,

    /// Multiple named series for line/scatter plots.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub series: Option<Vec<PlotSeries>>,

    /// For field_slice / field_snapshot: simulation time at which to extract
    /// the spatial field.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub at_time: Option<f64>,

    /// For field plots: non-plotted spatial dimension name → the numeric
    /// coordinate at which to slice.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pinned_coords: Option<HashMap<String, f64>>,

    /// Iso-levels to overlay as contour lines on a field plot.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub contours: Option<Vec<f64>>,
}

/// Inline illustrative analysis of how to run the enclosing component
/// (schema `Analysis`): run configuration plus plots derived from the
/// result. Carried by [`Model::analyses`] and [`ReactionSystem::analyses`],
/// the same way [`ModelTest`] serves both components' `tests`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ModelAnalysis {
    /// Identifier unique within this component's `analyses` array.
    pub id: String,

    /// Human-readable description of what this analysis illustrates.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,

    /// Initial state for this run: either the legacy flat scalar-override map
    /// (name → number) or the esm-spec §11.4 `{type, values}` discriminated
    /// union, whose `expression` form carries per-cell expression ASTs. Held
    /// as raw JSON so both branches pass through verbatim (the same
    /// raw-where-verbatim-is-the-contract treatment as
    /// [`ModelTest::expression_template_imports`]).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub initial_state: Option<serde_json::Value>,

    /// Parameter overrides, keyed by parameter name (local to this component).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parameters: Option<HashMap<String, f64>>,

    /// Simulation time interval for this analysis.
    pub time_span: TimeSpan,

    /// Optional parameter sweep: when present the analysis is a family of
    /// runs, one per Cartesian combination.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parameter_sweep: Option<ParameterSweep>,

    /// Plot specifications derived from this analysis's run(s).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub plots: Option<Vec<Plot>>,

    /// esm-spec §9.7.10 / §6.7 per-run template-library imports — authored
    /// per-run configuration that survives `parse → emit`, exactly as on
    /// [`ModelTest::expression_template_imports`].
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub expression_template_imports: Vec<serde_json::Value>,
}
