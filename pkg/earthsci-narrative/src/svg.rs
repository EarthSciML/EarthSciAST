//! Figures as SVG.

use crate::plot_data::PlotData;

/// How to draw a figure.
#[derive(Debug, Clone, PartialEq)]
pub struct SvgOptions {
    /// Width, in SVG user units (CSS pixels).
    pub width: f64,
    /// Height, in SVG user units (CSS pixels).
    pub height: f64,
}

impl Default for SvgOptions {
    fn default() -> Self {
        SvgOptions {
            width: 480.0,
            height: 300.0,
        }
    }
}

/// Draw one figure as a standalone SVG document.
pub fn render_svg(_plot: &PlotData, _opts: &SvgOptions) -> String {
    todo!("SVG plotter")
}
