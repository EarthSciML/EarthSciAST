//! The data behind one figure: what the analysis runner produces from a §6.7
//! plot, and all the SVG plotter needs to draw it.
//!
//! These are values, not drawings — structural information only, per
//! esm-spec §6.7 ("styling is the viewer's concern"). A missing sample is
//! `None` (JSON `null`), never NaN: it marks a run that failed inside a sweep
//! (analyses RFC R14), and a viewer must draw it as a gap, not a zero.

use serde::Serialize;

/// One figure's data, tagged by plot `type`.
#[allow(clippy::large_enum_variant)]
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum PlotData {
    /// Lines through each series' points.
    Line(XyPlot),
    /// Markers at each series' points.
    Scatter(XyPlot),
    /// One colored cell per point of a two-dimensional sweep.
    Heatmap(HeatmapPlot),
}

impl PlotData {
    /// The plot's id.
    pub fn id(&self) -> &str {
        match self {
            PlotData::Line(p) | PlotData::Scatter(p) => &p.id,
            PlotData::Heatmap(p) => &p.id,
        }
    }
}

/// What an axis shows, for its label.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct AxisInfo {
    /// The variable, parameter or swept parameter on the axis (`t` for time).
    pub variable: String,
    /// The author's label, when given; viewers fall back to the variable name.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    /// The quantity's declared units, when known.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub units: Option<String>,
}

impl AxisInfo {
    /// The text to print beside the axis: the author's label as written, or
    /// the variable name followed by its units in parentheses.
    pub fn display_label(&self) -> String {
        match (&self.label, &self.units) {
            (Some(label), _) => label.clone(),
            (None, Some(units)) if !units.is_empty() && units != "1" => {
                format!("{} ({units})", self.variable)
            }
            (None, _) => self.variable.clone(),
        }
    }
}

/// A line or scatter plot.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct XyPlot {
    /// The plot's id.
    pub id: String,
    /// The plot's description (a figure caption).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// The x axis.
    pub x: AxisInfo,
    /// The y axis. With several series this names the first; each series
    /// names its own variable.
    pub y: AxisInfo,
    /// The series, in legend order.
    pub series: Vec<Series>,
}

/// One series of a line or scatter plot.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Series {
    /// The series' display name: its §6.7 `series` name, or its variable.
    pub name: String,
    /// The variable the series plots.
    pub variable: String,
    /// Under a sweep, the swept parameters' values for this series' run, in
    /// the sweep's dimension order. Empty without a sweep. The legend text is
    /// the viewer's to format (RFC R6).
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub sweep_point: Vec<(String, f64)>,
    /// x values; `None` where the run behind the point failed.
    pub x: Vec<Option<f64>>,
    /// y values, aligned with `x`.
    pub y: Vec<Option<f64>>,
}

/// A heatmap over a two-dimensional parameter sweep.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct HeatmapPlot {
    /// The plot's id.
    pub id: String,
    /// The plot's description (a figure caption).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// The swept parameter across the columns.
    pub x: SweepAxis,
    /// The swept parameter across the rows.
    pub y: SweepAxis,
    /// The quantity mapped to color.
    pub value: ValueInfo,
    /// `z[row][column]`: the value at `y.values[row]`, `x.values[column]`;
    /// `None` where the run failed.
    pub z: Vec<Vec<Option<f64>>>,
}

/// A swept parameter used as a heatmap axis. Cells are evenly spaced whatever
/// the sweep's scale; `scale` says how to space the tick labels' values.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct SweepAxis {
    /// The axis label parts.
    #[serde(flatten)]
    pub info: AxisInfo,
    /// The swept values, in sweep order.
    pub values: Vec<f64>,
    /// `linear` or `log`.
    pub scale: String,
}

/// The quantity a heatmap maps to color.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ValueInfo {
    /// The label parts.
    #[serde(flatten)]
    pub info: AxisInfo,
    /// The time reduction applied (`final`, `max`, `min`, `mean`,
    /// `integral`), when the value is one.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reduce: Option<String>,
    /// The time the value was sampled at, when it was.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub at_time: Option<f64>,
}
