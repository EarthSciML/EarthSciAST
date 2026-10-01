//! Figures as SVG.
//!
//! [`render_svg`] draws one [`PlotData`] as a standalone SVG document. The same
//! drawing is embedded in Typst documents (through Typst's SVG loader), inlined
//! into Hugo pages, and redrawn in the browser by the interactive widget, so it
//! keeps to SVG that all of them render alike: presentation attributes (no
//! `<style>`, no classes), plain `<text>` in a generic font family, and no ids,
//! gradients, scripts or external resources. Ids matter because several
//! figures inlined into one HTML page share one id namespace.
//!
//! The output is deterministic: coordinates are rounded to two decimals and
//! nothing depends on hash order, so one input always gives the same bytes.
//!
//! Colors: series take an Okabe–Ito order that clears color-vision-deficiency
//! checks for adjacent pairs; a sweep over one variable is colored along
//! viridis instead, so the order of the swept values shows; heatmaps use
//! viridis. A failed run (a `None` sample) is a gap in a line and a light gray
//! cell in a heatmap, never a zero.

use std::fmt::Write as _;

use crate::plot_data::{AxisInfo, HeatmapPlot, PlotData, Series, SweepAxis, ValueInfo, XyPlot};

/// How to draw a figure.
#[derive(Debug, Clone, PartialEq)]
pub struct SvgOptions {
    /// Width, in SVG user units (CSS pixels).
    pub width: f64,
    /// Height, in SVG user units (CSS pixels).
    pub height: f64,
    /// The `font-family` of every label.
    pub font_family: String,
    /// The font size of every label, in SVG user units.
    pub font_size: f64,
    /// The page color behind the figure, or `None` for a transparent one.
    pub background: Option<String>,
}

impl Default for SvgOptions {
    fn default() -> Self {
        SvgOptions {
            width: 480.0,
            height: 300.0,
            font_family: "sans-serif".to_string(),
            font_size: 11.0,
            background: Some("#ffffff".to_string()),
        }
    }
}

/// Draw one figure as a standalone SVG document.
pub fn render_svg(plot: &PlotData, opts: &SvgOptions) -> String {
    let opts = sanitize(opts);
    let title = match plot {
        PlotData::Line(p) | PlotData::Scatter(p) => p.description.as_deref().unwrap_or(&p.id),
        PlotData::Heatmap(p) => p.description.as_deref().unwrap_or(&p.id),
    };
    let mut canvas = Canvas::new(&opts, title);
    match plot {
        PlotData::Line(p) => draw_xy(&mut canvas, p, Mark::Line, &opts),
        PlotData::Scatter(p) => draw_xy(&mut canvas, p, Mark::Point, &opts),
        PlotData::Heatmap(p) => draw_heatmap(&mut canvas, p, &opts),
    }
    canvas.finish()
}

// ---------------------------------------------------------------------------
// Style
// ---------------------------------------------------------------------------

/// Axis titles and legend text.
const INK: &str = "#1f1f1f";
/// Tick labels and notes.
const INK_MUTED: &str = "#4d4d4d";
/// Axis lines and ticks.
const AXIS: &str = "#737373";
/// Grid lines: recessive, so the data leads.
const GRID: &str = "#e6e6e6";
/// A heatmap cell whose run failed.
const NO_DATA: &str = "#d9d9d9";

/// Categorical series colors (Okabe–Ito, in an order whose adjacent pairs stay
/// distinct under the common color-vision deficiencies).
const PALETTE: [&str; 6] = [
    "#0072b2", "#d55e00", "#009e73", "#e69f00", "#cc79a7", "#56b4e9",
];

/// Dash patterns, the second encoding once colors repeat or a sweep runs over
/// several variables.
const DASHES: [Option<&str>; 4] = [None, Some("6 3"), Some("2 2.5"), Some("8 3 2 3")];

/// Viridis at 17 evenly spaced points (matplotlib's table), interpolated
/// linearly in between.
const VIRIDIS: [u32; 17] = [
    0x440154, 0x48186a, 0x472d7b, 0x424086, 0x3b528b, 0x33638d, 0x2c728e, 0x26818e, 0x21908c,
    0x1f9f88, 0x28ae80, 0x3ebc74, 0x5dc963, 0x82d34c, 0xabdc32, 0xd5e21a, 0xfde725,
];

/// Where a sequential series coloring stops along viridis: its last, palest
/// stretch is too light to read as a line on white.
const SEQUENTIAL_END: f64 = 0.85;

/// Tick length.
const TICK: f64 = 4.0;
/// Space between a tick and its label.
const TICK_GAP: f64 = 3.0;
/// Outer padding.
const PAD: f64 = 8.0;
/// Estimated advance of one character, as a fraction of the font size. Sans
/// digits are 0.55 em; a little more keeps estimates on the safe side.
const CHAR_EM: f64 = 0.6;

/// Viridis at `t` in `[0, 1]`, as `#rrggbb`.
fn viridis(t: f64) -> String {
    let t = if t.is_finite() {
        t.clamp(0.0, 1.0)
    } else {
        0.0
    };
    let pos = t * (VIRIDIS.len() - 1) as f64;
    let i = (pos.floor() as usize).min(VIRIDIS.len() - 2);
    let f = pos - i as f64;
    let channel = |c: u32, shift: u32| ((c >> shift) & 0xff) as f64;
    let mix = |shift: u32| {
        let a = channel(VIRIDIS[i], shift);
        let b = channel(VIRIDIS[i + 1], shift);
        (a + (b - a) * f).round() as u8
    };
    format!("#{:02x}{:02x}{:02x}", mix(16), mix(8), mix(0))
}

/// One series' stroke.
#[derive(Debug, Clone, PartialEq)]
struct Style {
    color: String,
    dash: Option<&'static str>,
}

/// Colors and dashes for each series.
///
/// A sweep over one series (every series swept, all one name) is colored
/// along viridis in series order, so the swept values' order reads off the
/// colors. Otherwise each distinct series name takes the next categorical
/// color; under a sweep the dash pattern then tells the sweep points of one
/// name apart, and without one it tells apart names whose colors repeat.
fn series_styles(series: &[Series]) -> Vec<Style> {
    let swept = !series.is_empty() && series.iter().all(|s| !s.sweep_point.is_empty());
    let mut names: Vec<&str> = Vec::new();
    for s in series {
        if !names.contains(&s.name.as_str()) {
            names.push(&s.name);
        }
    }
    if swept && names.len() == 1 {
        let n = series.len();
        return (0..n)
            .map(|i| Style {
                color: viridis(if n > 1 {
                    SEQUENTIAL_END * i as f64 / (n - 1) as f64
                } else {
                    0.0
                }),
                dash: None,
            })
            .collect();
    }
    let mut seen = vec![0usize; names.len()];
    series
        .iter()
        .map(|s| {
            let k = names.iter().position(|n| *n == s.name).unwrap_or(0);
            let dash = if swept {
                let rank = seen[k];
                seen[k] += 1;
                rank
            } else {
                k / PALETTE.len()
            };
            Style {
                color: PALETTE[k % PALETTE.len()].to_string(),
                dash: DASHES[dash % DASHES.len()],
            }
        })
        .collect()
}

/// Each series' legend text: its name, its swept values (`r = 0.5`), or both
/// when the series do not all plot one variable under one name.
fn legend_labels(series: &[Series]) -> Vec<String> {
    let one = series
        .iter()
        .all(|s| s.variable == series[0].variable && s.name == series[0].name);
    series
        .iter()
        .map(|s| {
            if s.sweep_point.is_empty() {
                s.name.clone()
            } else {
                let point = sweep_text(&s.sweep_point);
                if one {
                    point
                } else {
                    format!("{}, {point}", s.name)
                }
            }
        })
        .collect()
}

/// `r = 0.5, K = 100`.
fn sweep_text(point: &[(String, f64)]) -> String {
    point
        .iter()
        .map(|(p, v)| format!("{p} = {}", format_value(*v)))
        .collect::<Vec<_>>()
        .join(", ")
}

// ---------------------------------------------------------------------------
// Numbers
// ---------------------------------------------------------------------------

/// A coordinate: at most two decimals, trailing zeros dropped.
fn coord(v: f64) -> String {
    let v = if v.is_finite() { v } else { 0.0 };
    trim_zeros(format!("{v:.2}"))
}

/// Drop trailing fractional zeros (`1.50` → `1.5`, `2.00` → `2`), and the
/// sign of a zero.
fn trim_zeros(s: String) -> String {
    let s = if s.contains('.') {
        s.trim_end_matches('0').trim_end_matches('.').to_string()
    } else {
        s
    };
    if s == "-0" { "0".to_string() } else { s }
}

/// Typographic minus signs for display.
fn minus(s: String) -> String {
    s.replace('-', "\u{2212}")
}

/// A single value for display — a swept value, a time — to three significant
/// digits, without float noise (`0.30000000000000004` → `0.3`), and in
/// scientific notation (`1e−6`, `2.5e4`) when very small or large.
fn format_value(v: f64) -> String {
    if !v.is_finite() {
        return if v.is_nan() {
            "NaN".to_string()
        } else if v > 0.0 {
            "∞".to_string()
        } else {
            "\u{2212}∞".to_string()
        };
    }
    if v == 0.0 {
        return "0".to_string();
    }
    let m = v.abs();
    if !(1e-3..1e5).contains(&m) {
        return scientific(v, 2);
    }
    let e = m.log10().floor() as i32;
    let decimals = (2 - e).max(0) as usize;
    minus(trim_zeros(format!("{v:.decimals$}")))
}

/// `v` as `mantissa e exponent`, with at most `decimals` mantissa decimals and
/// trailing zeros dropped.
fn scientific(v: f64, decimals: usize) -> String {
    if v == 0.0 {
        return "0".to_string();
    }
    let mut e = v.abs().log10().floor() as i32;
    let mut mantissa = v / 10f64.powi(e);
    // Rounding can carry the mantissa to 10 (9.996 → "10.00").
    let rounded: f64 = format!("{mantissa:.decimals$}").parse().unwrap_or(mantissa);
    if rounded.abs() >= 10.0 {
        e += 1;
        mantissa = v / 10f64.powi(e);
    }
    let m = trim_zeros(format!("{mantissa:.decimals$}"));
    minus(format!("{m}e{e}"))
}

/// Tick positions along one axis, from Heckbert's nice-numbers algorithm.
#[derive(Debug, Clone, PartialEq)]
struct Ticks {
    /// The axis' lower end: the first tick.
    lo: f64,
    /// The axis' upper end: the last tick.
    hi: f64,
    /// The spacing between ticks.
    step: f64,
    /// The ticks, `lo` to `hi`.
    values: Vec<f64>,
}

/// A "nice" number near `x` (1, 2 or 5 times a power of ten): the nearest one
/// when `round`, else the smallest one at least `x`.
fn nice_num(x: f64, round: bool) -> f64 {
    let exp = x.log10().floor();
    let f = x / 10f64.powf(exp);
    let nf = if round {
        if f < 1.5 {
            1.0
        } else if f < 3.0 {
            2.0
        } else if f < 7.0 {
            5.0
        } else {
            10.0
        }
    } else if f <= 1.0 {
        1.0
    } else if f <= 2.0 {
        2.0
    } else if f <= 5.0 {
        5.0
    } else {
        10.0
    };
    nf * 10f64.powf(exp)
}

/// A data range widened to one an axis can show: an empty or zero-width range
/// gets room around it.
fn padded(min: f64, max: f64) -> (f64, f64) {
    if !(min.is_finite() && max.is_finite()) {
        return (0.0, 1.0);
    }
    let (min, max) = if min <= max { (min, max) } else { (max, min) };
    if max > min {
        // A range far below the values' own precision reads as constant.
        let scale = min.abs().max(max.abs());
        if (max - min) > scale * 1e-12 {
            return (min, max);
        }
    }
    if min == 0.0 {
        (-1.0, 1.0)
    } else {
        let d = min.abs() * 0.1;
        (min - d, max + d)
    }
}

/// Loose nice ticks covering `[min, max]`, about `target` of them.
fn nice_ticks(min: f64, max: f64, target: usize) -> Ticks {
    let (min, max) = padded(min, max);
    let target = target.max(2);
    let range = nice_num(max - min, false);
    let step = nice_num(range / (target - 1) as f64, true);
    // The tolerance keeps a data end that is a multiple of the step
    // (2e-6 / 5e-7 = 4.000000000000001) from gaining a whole empty step.
    let lo = (min / step + 1e-9).floor() * step;
    let hi = (max / step - 1e-9).ceil() * step;
    let n = ((hi - lo) / step).round().max(1.0) as usize;
    let values = (0..=n)
        .map(|i| {
            let v = lo + i as f64 * step;
            if v.abs() < step * 1e-9 { 0.0 } else { v }
        })
        .collect();
    Ticks {
        lo,
        hi: lo + n as f64 * step,
        step,
        values,
    }
}

/// How one axis formats its tick labels: one notation, one exponent and one
/// number of decimals for every tick, set by the axis range and tick spacing
/// (`0.5e−6, 1.0e−6, 1.5e−6`, never `5e−7, 1e−6, 1.5e−6`).
#[derive(Debug, Clone, Copy, PartialEq)]
struct TickFormat {
    /// Scientific notation, with this exponent for every tick.
    exponent: Option<i32>,
    /// Decimals shown: of the value, or of the mantissa in scientific notation.
    decimals: usize,
}

impl TickFormat {
    fn new(lo: f64, hi: f64, step: f64) -> TickFormat {
        let m = lo.abs().max(hi.abs());
        let step_exp = (step.log10() + 1e-9).floor() as i32;
        if m >= 1e5 || (m > 0.0 && m < 1e-3) {
            let exponent = (m.log10() + 1e-9).floor() as i32;
            TickFormat {
                exponent: Some(exponent),
                decimals: (exponent - step_exp).clamp(0, 6) as usize,
            }
        } else {
            TickFormat {
                exponent: None,
                decimals: (-step_exp).max(0) as usize,
            }
        }
    }

    fn for_ticks(ticks: &Ticks) -> TickFormat {
        TickFormat::new(ticks.lo, ticks.hi, ticks.step)
    }

    fn format(&self, v: f64) -> String {
        let decimals = self.decimals;
        let (mantissa, suffix) = match self.exponent {
            // A zero tick is plain `0` on a scientific axis.
            Some(_) if v == 0.0 => return "0".to_string(),
            Some(e) => (v / 10f64.powi(e), format!("e{e}")),
            None => (v, String::new()),
        };
        let s = format!("{mantissa:.decimals$}");
        // No "−0.0": a zero tick has no sign.
        let s = if s
            .trim_start_matches('-')
            .chars()
            .all(|c| c == '0' || c == '.')
        {
            s.trim_start_matches('-').to_string()
        } else {
            s
        };
        minus(format!("{s}{suffix}"))
    }
}

/// Estimated width of `s` in the label font.
fn text_width(s: &str, font_size: f64) -> f64 {
    s.chars().count() as f64 * font_size * CHAR_EM
}

/// `s` shortened with an ellipsis to fit `width`.
fn fit(s: &str, width: f64, font_size: f64) -> String {
    // The epsilon keeps a label that exactly fills `width` from losing a
    // character to rounding.
    let max = (width / (font_size * CHAR_EM) + 1e-6).floor().max(1.0) as usize;
    if s.chars().count() <= max {
        s.to_string()
    } else {
        let mut t: String = s.chars().take(max.saturating_sub(1)).collect();
        t.push('…');
        t
    }
}

// ---------------------------------------------------------------------------
// Canvas
// ---------------------------------------------------------------------------

#[derive(Clone, Copy)]
enum Anchor {
    Start,
    Middle,
    End,
}

impl Anchor {
    fn attr(self) -> &'static str {
        match self {
            Anchor::Start => "start",
            Anchor::Middle => "middle",
            Anchor::End => "end",
        }
    }
}

/// The SVG being written.
struct Canvas {
    out: String,
    font_size: f64,
}

fn escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            // Characters XML 1.0 forbids outright.
            c if (c as u32) < 0x20 && !matches!(c, '\t' | '\n' | '\r') => {}
            c => out.push(c),
        }
    }
    out
}

impl Canvas {
    fn new(opts: &SvgOptions, title: &str) -> Canvas {
        let (w, h) = (coord(opts.width), coord(opts.height));
        let mut out = String::new();
        let _ = write!(
            out,
            r#"<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" font-family="{}" font-size="{}" role="img">"#,
            escape(&opts.font_family),
            coord(opts.font_size),
        );
        let _ = write!(out, "<title>{}</title>", escape(title));
        if let Some(bg) = &opts.background {
            let _ = write!(
                out,
                r#"<rect x="0" y="0" width="{w}" height="{h}" fill="{}"/>"#,
                escape(bg)
            );
        }
        Canvas {
            out,
            font_size: opts.font_size,
        }
    }

    fn finish(mut self) -> String {
        self.out.push_str("</svg>");
        self.out
    }

    fn line(&mut self, x1: f64, y1: f64, x2: f64, y2: f64, stroke: &str, width: f64) {
        let _ = write!(
            self.out,
            r#"<line x1="{}" y1="{}" x2="{}" y2="{}" stroke="{stroke}" stroke-width="{}"/>"#,
            coord(x1),
            coord(y1),
            coord(x2),
            coord(y2),
            coord(width),
        );
    }

    fn rect(&mut self, x: f64, y: f64, w: f64, h: f64, fill: &str) {
        let _ = write!(
            self.out,
            r#"<rect x="{}" y="{}" width="{}" height="{}" fill="{fill}"/>"#,
            coord(x),
            coord(y),
            coord(w.max(0.0)),
            coord(h.max(0.0)),
        );
    }

    fn outline(&mut self, x: f64, y: f64, w: f64, h: f64, stroke: &str, width: f64) {
        let _ = write!(
            self.out,
            r#"<rect x="{}" y="{}" width="{}" height="{}" fill="none" stroke="{stroke}" stroke-width="{}"/>"#,
            coord(x),
            coord(y),
            coord(w.max(0.0)),
            coord(h.max(0.0)),
            coord(width),
        );
    }

    fn circle(&mut self, cx: f64, cy: f64, r: f64, fill: &str, ring: Option<&str>) {
        let ring = match ring {
            Some(color) => format!(r#" stroke="{color}" stroke-width="1""#),
            None => String::new(),
        };
        let _ = write!(
            self.out,
            r#"<circle cx="{}" cy="{}" r="{}" fill="{fill}"{ring}/>"#,
            coord(cx),
            coord(cy),
            coord(r),
        );
    }

    /// A polyline through `points`, which must hold at least two.
    fn polyline(&mut self, points: &[(f64, f64)], style: &Style, width: f64) {
        let mut d = String::new();
        for (i, (x, y)) in points.iter().enumerate() {
            let _ = write!(
                d,
                "{}{},{}",
                if i == 0 { "M" } else { " L" },
                coord(*x),
                coord(*y)
            );
        }
        let dash = match style.dash {
            Some(pattern) => format!(r#" stroke-dasharray="{pattern}""#),
            None => String::new(),
        };
        let _ = write!(
            self.out,
            r#"<path d="{d}" fill="none" stroke="{}" stroke-width="{}" stroke-linejoin="round" stroke-linecap="round"{dash}/>"#,
            style.color,
            coord(width),
        );
    }

    /// Text whose baseline sits `font_size × 0.35` below `y`, so it is centered
    /// on `y` vertically without relying on `dominant-baseline`.
    fn text(&mut self, x: f64, y: f64, s: &str, anchor: Anchor, fill: &str) {
        let _ = write!(
            self.out,
            r#"<text x="{}" y="{}" text-anchor="{}" fill="{fill}">{}</text>"#,
            coord(x),
            coord(y + self.font_size * 0.35),
            anchor.attr(),
            escape(s),
        );
    }

    /// Text reading upward, centered on `(x, y)`.
    fn vertical_text(&mut self, x: f64, y: f64, s: &str, fill: &str) {
        let bx = x + self.font_size * 0.35;
        let _ = write!(
            self.out,
            r#"<text x="{0}" y="{1}" transform="rotate(-90 {0} {1})" text-anchor="middle" fill="{fill}">{2}</text>"#,
            coord(bx),
            coord(y),
            escape(s),
        );
    }
}

/// Options with nonsensical sizes replaced by the defaults.
fn sanitize(opts: &SvgOptions) -> SvgOptions {
    let d = SvgOptions::default();
    let ok = |v: f64| v.is_finite() && v > 0.0;
    SvgOptions {
        width: if ok(opts.width) { opts.width } else { d.width },
        height: if ok(opts.height) {
            opts.height
        } else {
            d.height
        },
        font_family: opts.font_family.clone(),
        font_size: if ok(opts.font_size) {
            opts.font_size
        } else {
            d.font_size
        },
        background: opts.background.clone(),
    }
}

// ---------------------------------------------------------------------------
// Line and scatter plots
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, PartialEq)]
enum Mark {
    Line,
    Point,
}

/// A series' drawable points: `None` where either coordinate is missing or
/// not finite.
fn points_of(s: &Series) -> Vec<Option<(f64, f64)>> {
    s.x.iter()
        .zip(&s.y)
        .map(|(x, y)| match (x, y) {
            (Some(x), Some(y)) if x.is_finite() && y.is_finite() => Some((*x, *y)),
            _ => None,
        })
        .collect()
}

/// The smallest and largest of `values`, or `None` when there are none.
fn extent(values: impl Iterator<Item = f64>) -> Option<(f64, f64)> {
    values.fold(None, |acc, v| match acc {
        None => Some((v, v)),
        Some((lo, hi)) => Some((lo.min(v), hi.max(v))),
    })
}

/// The y axis title. An author's label is used as written. Without one, the
/// axis is titled by its variable when every series plots that variable; when
/// the series plot different variables the legend names them and the axis
/// carries no title, rather than a title naming only the first.
fn y_title(plot: &XyPlot) -> String {
    if plot.y.label.is_some() || plot.series.iter().all(|s| s.variable == plot.y.variable) {
        plot.y.display_label()
    } else {
        String::new()
    }
}

/// About how many ticks fit along an axis `length` long, one per `spacing`.
fn tick_target(length: f64, spacing: f64, max: usize) -> usize {
    ((length / spacing).round() as usize).clamp(2, max)
}

/// The ticks for data spanning `[lo, hi]`: of the nice tick sets for every
/// count from 2 to `max` that `fits`, the one whose axis overshoots the data
/// least, and among equals the one nearest `preferred` ticks (the denser one
/// when two are equally near). Loose nice ticks can stretch an axis well past
/// its data (0–60 for data ending at 50); some other count usually lands on
/// the data's ends. A set of only two ticks, which leaves an axis nearly
/// unmarked, is chosen only when no denser one fits; when none fits at all,
/// two ticks it is.
fn choose_ticks(
    lo: f64,
    hi: f64,
    preferred: usize,
    max: usize,
    fits: impl Fn(&Ticks) -> bool,
) -> Ticks {
    let (dlo, dhi) = padded(lo, hi);
    let span = dhi - dlo;
    let mut best: Option<(f64, usize, Ticks)> = None;
    let candidates: Vec<Ticks> = (2..=max.max(2))
        .map(|target| nice_ticks(lo, hi, target))
        .filter(|t| fits(t))
        .collect();
    let dense = candidates.iter().any(|t| t.values.len() >= 3);
    for ticks in candidates {
        if dense && ticks.values.len() < 3 {
            continue;
        }
        let overshoot = ((ticks.hi - ticks.lo) / span - 1.0).max(0.0);
        let distance = ticks.values.len().abs_diff(preferred);
        let better = match &best {
            None => true,
            Some((o, d, t)) => {
                overshoot < o - 1e-9
                    || (overshoot <= o + 1e-9
                        && (distance < *d
                            || (distance == *d && ticks.values.len() > t.values.len())))
            }
        };
        if better {
            best = Some((overshoot, distance, ticks));
        }
    }
    best.map_or_else(|| nice_ticks(lo, hi, 2), |(_, _, t)| t)
}

/// Ticks for the x axis whose labels fit side by side along `length`.
fn x_ticks(lo: f64, hi: f64, length: f64, fs: f64) -> (Ticks, Vec<String>) {
    let labels_of = |ticks: &Ticks| -> Vec<String> {
        let format = TickFormat::for_ticks(ticks);
        ticks.values.iter().map(|v| format.format(*v)).collect()
    };
    let fits = |ticks: &Ticks| {
        let widest = labels_of(ticks)
            .iter()
            .map(|l| text_width(l, fs))
            .fold(0.0, f64::max);
        ticks.values.len() as f64 * (widest + fs * 1.5) <= length
    };
    let ticks = choose_ticks(lo, hi, tick_target(length, fs * 6.0, 10), 10, fits);
    let labels = labels_of(&ticks);
    (ticks, labels)
}

fn draw_xy(c: &mut Canvas, plot: &XyPlot, mark: Mark, opts: &SvgOptions) {
    let fs = opts.font_size;
    let (w, h) = (opts.width, opts.height);
    let points: Vec<Vec<Option<(f64, f64)>>> = plot.series.iter().map(points_of).collect();
    let drawn = || points.iter().flatten().flatten();
    let x_extent = extent(drawn().map(|p| p.0));
    let y_extent = extent(drawn().map(|p| p.1));
    let has_data = x_extent.is_some();
    let (x_lo, x_hi) = x_extent.unwrap_or((0.0, 1.0));
    let (y_lo, y_hi) = y_extent.unwrap_or((0.0, 1.0));

    let styles = series_styles(&plot.series);
    let mut labels = if plot.series.len() > 1 {
        legend_labels(&plot.series)
    } else {
        Vec::new()
    };
    let swatch = 18.0;
    let legend_width = if labels.is_empty() {
        0.0
    } else {
        let widest = labels.iter().map(|l| text_width(l, fs)).fold(0.0, f64::max);
        (swatch + 6.0 + widest).min(w * 0.35)
    };
    for label in &mut labels {
        *label = fit(label, legend_width - swatch - 6.0, fs);
    }

    let x_title = plot.x.display_label();
    let y_title = y_title(plot);

    // Vertical layout.
    let top = PAD + fs * 0.6;
    let x_title_height = if x_title.is_empty() { 0.0 } else { fs * 1.7 };
    let bottom = TICK + TICK_GAP + fs + x_title_height + PAD;
    let plot_h = (h - top - bottom).max(fs * 2.0);
    let y_ticks = choose_ticks(y_lo, y_hi, tick_target(plot_h, fs * 3.5, 8), 8, |t| {
        t.values.len() as f64 * fs * 1.8 <= plot_h
    });
    let y_format = TickFormat::for_ticks(&y_ticks);
    let y_labels: Vec<String> = y_ticks.values.iter().map(|v| y_format.format(*v)).collect();
    let y_label_width = y_labels
        .iter()
        .map(|l| text_width(l, fs))
        .fold(0.0, f64::max);

    // Horizontal layout. The last x tick label hangs half its width past the
    // plot area; the legend, beside the plot area, sits above it.
    let y_title_width = if y_title.is_empty() { 0.0 } else { fs * 1.7 };
    let left = PAD + y_title_width + y_label_width + TICK + TICK_GAP;
    let legend_room = if labels.is_empty() {
        0.0
    } else {
        legend_width + 14.0
    };
    let mut right = PAD + legend_room.max(fs * 2.0);
    let mut plot_w = (w - left - right).max(fs * 2.0);
    let (mut x_ticks_, mut x_labels) = x_ticks(x_lo, x_hi, plot_w, fs);
    let overhang = x_labels.last().map_or(0.0, |l| text_width(l, fs) / 2.0);
    if overhang > right - PAD && overhang > legend_room {
        right = PAD + overhang;
        plot_w = (w - left - right).max(fs * 2.0);
        (x_ticks_, x_labels) = x_ticks(x_lo, x_hi, plot_w, fs);
    }

    let sx = |v: f64| left + (v - x_ticks_.lo) / (x_ticks_.hi - x_ticks_.lo) * plot_w;
    let sy = |v: f64| top + plot_h - (v - y_ticks.lo) / (y_ticks.hi - y_ticks.lo) * plot_h;
    let base = top + plot_h;

    // Grid and axis lines, under the data.
    for v in &y_ticks.values {
        let y = sy(*v);
        c.line(left, y, left + plot_w, y, GRID, 1.0);
    }
    c.line(left, top, left, base, AXIS, 1.0);
    c.line(left, base, left + plot_w, base, AXIS, 1.0);

    // Data.
    for (series_points, style) in points.iter().zip(&styles) {
        match mark {
            Mark::Line => {
                let mut run: Vec<(f64, f64)> = Vec::new();
                let flush = |run: &mut Vec<(f64, f64)>, c: &mut Canvas| {
                    match run.len() {
                        0 => {}
                        // An isolated sample between two gaps is still data.
                        1 => c.circle(run[0].0, run[0].1, 2.0, &style.color, None),
                        _ => c.polyline(run, style, 2.0),
                    }
                    run.clear();
                };
                for p in series_points {
                    match p {
                        Some((x, y)) => run.push((sx(*x), sy(*y))),
                        None => flush(&mut run, c),
                    }
                }
                flush(&mut run, c);
            }
            Mark::Point => {
                let ring = opts.background.as_deref().unwrap_or("#ffffff");
                for (x, y) in series_points.iter().flatten() {
                    c.circle(sx(*x), sy(*y), 3.5, &style.color, Some(ring));
                }
            }
        }
    }
    if !has_data {
        c.text(
            left + plot_w / 2.0,
            top + plot_h / 2.0,
            "no data",
            Anchor::Middle,
            INK_MUTED,
        );
    }

    // Ticks and their labels.
    for (v, label) in y_ticks.values.iter().zip(&y_labels) {
        let y = sy(*v);
        c.line(left - TICK, y, left, y, AXIS, 1.0);
        c.text(left - TICK - TICK_GAP, y, label, Anchor::End, INK_MUTED);
    }
    let x_label_y = base + TICK + TICK_GAP + fs * 0.5;
    for (v, label) in x_ticks_.values.iter().zip(&x_labels) {
        let x = sx(*v);
        c.line(x, base, x, base + TICK, AXIS, 1.0);
        c.text(x, x_label_y, label, Anchor::Middle, INK_MUTED);
    }
    if !x_title.is_empty() {
        c.text(
            left + plot_w / 2.0,
            x_label_y + fs * 1.55,
            &x_title,
            Anchor::Middle,
            INK,
        );
    }
    if !y_title.is_empty() {
        c.vertical_text(PAD, top + plot_h / 2.0, &y_title, INK);
    }

    // Legend, beside the plot area.
    if !labels.is_empty() {
        let x0 = left + plot_w + 14.0;
        let row = fs * 1.5;
        let fits = ((plot_h / row).floor() as usize).max(1);
        let (shown, more) = legend_rows(labels.len(), fits);
        for (slot, i) in shown.iter().enumerate() {
            let y = top + (slot as f64 + 0.5) * row;
            let style = &styles[*i];
            match mark {
                Mark::Line => c.polyline(&[(x0, y), (x0 + swatch, y)], style, 2.0),
                Mark::Point => c.circle(x0 + swatch / 2.0, y, 3.5, &style.color, None),
            }
            c.text(x0 + swatch + 6.0, y, &labels[*i], Anchor::Start, INK);
        }
        if more > 0 {
            let y = top + (shown.len() as f64 + 0.5) * row;
            c.text(
                x0 + swatch + 6.0,
                y,
                &format!("({more} more)"),
                Anchor::Start,
                INK_MUTED,
            );
        }
    }
}

/// Which of `n` legend entries to show in `fits` rows: all when they fit, else
/// an evenly spaced selection that keeps the first and last, with one row left
/// for a note saying how many were left out.
fn legend_rows(n: usize, fits: usize) -> (Vec<usize>, usize) {
    if n <= fits {
        return ((0..n).collect(), 0);
    }
    let slots = fits.saturating_sub(1).max(1);
    if slots == 1 {
        return (vec![0], n - 1);
    }
    let mut shown: Vec<usize> = (0..slots)
        .map(|k| ((k as f64) * (n - 1) as f64 / (slots - 1) as f64).round() as usize)
        .collect();
    shown.dedup();
    let more = n - shown.len();
    (shown, more)
}

// ---------------------------------------------------------------------------
// Heatmaps
// ---------------------------------------------------------------------------

/// The color bar's title: the value's label and how it was taken from each
/// run — `N (final)`, `N (mol, max)`, `N at t = 5`.
fn value_title(value: &ValueInfo) -> String {
    let info: &AxisInfo = &value.info;
    let units = info
        .units
        .as_deref()
        .filter(|u| !u.is_empty() && *u != "1" && info.label.is_none());
    let base = info.label.clone().unwrap_or_else(|| info.variable.clone());
    if let Some(t) = value.at_time {
        let at = format!("{base} at t = {}", format_value(t));
        return match units {
            Some(u) => format!("{at} ({u})"),
            None => at,
        };
    }
    match (units, value.reduce.as_deref()) {
        (Some(u), Some(r)) => format!("{base} ({u}, {r})"),
        (Some(u), None) => format!("{base} ({u})"),
        (None, Some(r)) => format!("{base} ({r})"),
        (None, None) => base,
    }
}

/// Which of `n` evenly spaced cell labels to show so that labels `size` wide
/// fit along `length`: every `k`-th, starting with the first.
fn label_stride(n: usize, size: f64, length: f64) -> usize {
    if n == 0 || length <= 0.0 {
        return 1;
    }
    ((n as f64 * size / length).ceil() as usize).max(1)
}

fn sweep_labels(axis: &SweepAxis) -> Vec<String> {
    axis.values.iter().map(|v| format_value(*v)).collect()
}

fn draw_heatmap(c: &mut Canvas, plot: &HeatmapPlot, opts: &SvgOptions) {
    let fs = opts.font_size;
    let (w, h) = (opts.width, opts.height);
    let cols = plot.x.values.len();
    let rows = plot.y.values.len();
    let cell = |r: usize, col: usize| -> Option<f64> {
        plot.z
            .get(r)
            .and_then(|row| row.get(col))
            .copied()
            .flatten()
            .filter(|v| v.is_finite())
    };
    let z_extent = extent((0..rows).flat_map(|r| (0..cols).filter_map(move |col| cell(r, col))));
    let any_missing = (0..rows).any(|r| (0..cols).any(|col| cell(r, col).is_none()));
    let (z_lo, z_hi) = padded_z(z_extent);

    let x_title = plot.x.info.display_label();
    let y_title = plot.y.info.display_label();
    let value_title = value_title(&plot.value);
    let x_labels = sweep_labels(&plot.x);
    let y_labels = sweep_labels(&plot.y);

    // Color bar ticks: nice values inside the data range only.
    let bar_ticks: Vec<f64> = if z_extent.is_some() {
        let t = nice_ticks(z_lo, z_hi, 5);
        t.values
            .iter()
            .copied()
            .filter(|v| *v >= z_lo - t.step * 1e-9 && *v <= z_hi + t.step * 1e-9)
            .collect()
    } else {
        Vec::new()
    };
    let bar_format = {
        let t = nice_ticks(z_lo, z_hi, 5);
        TickFormat::for_ticks(&t)
    };
    let bar_labels: Vec<String> = bar_ticks.iter().map(|v| bar_format.format(*v)).collect();
    let bar_label_width = bar_labels
        .iter()
        .map(|l| text_width(l, fs))
        .fold(0.0, f64::max);

    // Layout.
    let top = PAD + fs * 0.6;
    let x_title_height = if x_title.is_empty() { 0.0 } else { fs * 1.7 };
    let bottom = TICK + TICK_GAP + fs + x_title_height + PAD;
    let plot_h = (h - top - bottom).max(fs * 2.0);
    let y_label_width = y_labels
        .iter()
        .map(|l| text_width(l, fs))
        .fold(0.0, f64::max);
    let y_title_width = if y_title.is_empty() { 0.0 } else { fs * 1.7 };
    let left = PAD + y_title_width + y_label_width + TICK + TICK_GAP;
    let bar_gap = 14.0;
    let bar_w = 12.0;
    let note = "failed run";
    let note_width = if any_missing {
        12.0 + text_width(note, fs)
    } else {
        0.0
    };
    let bar_block =
        (bar_w + TICK + TICK_GAP + bar_label_width + fs * 0.6 + fs * 1.2).max(note_width);
    let right = PAD + bar_gap + bar_block;
    let plot_w = (w - left - right).max(fs * 2.0);
    let base = top + plot_h;

    // Cells, row 0 at the bottom.
    if cols > 0 && rows > 0 {
        let cw = plot_w / cols as f64;
        let ch = plot_h / rows as f64;
        // A hairline of page color between cells, once cells are big enough
        // to spare it.
        let inset = if cw >= 6.0 && ch >= 6.0 { 0.5 } else { 0.0 };
        for r in 0..rows {
            for col in 0..cols {
                let fill = match cell(r, col) {
                    Some(v) => viridis((v - z_lo) / (z_hi - z_lo)),
                    None => NO_DATA.to_string(),
                };
                let x = left + col as f64 * cw;
                let y = base - (r + 1) as f64 * ch;
                c.rect(
                    x + inset,
                    y + inset,
                    cw - 2.0 * inset,
                    ch - 2.0 * inset,
                    &fill,
                );
            }
        }

        // Tick labels at cell centers, thinned to fit.
        let x_widest = x_labels
            .iter()
            .map(|l| text_width(l, fs))
            .fold(0.0, f64::max);
        let x_stride = label_stride(cols, x_widest + fs, plot_w);
        let x_label_y = base + TICK + TICK_GAP + fs * 0.5;
        for (col, label) in x_labels.iter().enumerate().step_by(x_stride) {
            let x = left + (col as f64 + 0.5) * cw;
            c.line(x, base, x, base + TICK, AXIS, 1.0);
            c.text(x, x_label_y, label, Anchor::Middle, INK_MUTED);
        }
        let y_stride = label_stride(rows, fs * 1.6, plot_h);
        for (r, label) in y_labels.iter().enumerate().step_by(y_stride) {
            let y = base - (r as f64 + 0.5) * ch;
            c.line(left - TICK, y, left, y, AXIS, 1.0);
            c.text(left - TICK - TICK_GAP, y, label, Anchor::End, INK_MUTED);
        }
    }
    if z_extent.is_none() {
        c.text(
            left + plot_w / 2.0,
            top + plot_h / 2.0,
            "no data",
            Anchor::Middle,
            INK_MUTED,
        );
    }
    if !x_title.is_empty() {
        c.text(
            left + plot_w / 2.0,
            base + TICK + TICK_GAP + fs * 2.05,
            &x_title,
            Anchor::Middle,
            INK,
        );
    }
    if !y_title.is_empty() {
        c.vertical_text(PAD, top + plot_h / 2.0, &y_title, INK);
    }

    // Color bar, beside the cells; the failed-run key sits under it.
    let bar_x = left + plot_w + bar_gap;
    let note_room = if any_missing { fs * 1.8 } else { 0.0 };
    let bar_h = (plot_h - note_room).max(fs);
    if z_extent.is_some() {
        let slices = 64;
        let slice = bar_h / slices as f64;
        // Unantialiased slices, each reaching one unit into the one below:
        // antialiased edges would show as faint seams across the bar.
        c.out.push_str(r#"<g shape-rendering="crispEdges">"#);
        for k in 0..slices {
            let t = (k as f64 + 0.5) / slices as f64;
            let y = top + bar_h - (k + 1) as f64 * slice;
            let overlap = if k == 0 { 0.0 } else { 1.0 };
            c.rect(bar_x, y, bar_w, slice + overlap, &viridis(t));
        }
        c.out.push_str("</g>");
        c.outline(bar_x, top, bar_w, bar_h, AXIS, 0.5);
        for (v, label) in bar_ticks.iter().zip(&bar_labels) {
            let y = top + bar_h - (v - z_lo) / (z_hi - z_lo) * bar_h;
            c.line(bar_x + bar_w, y, bar_x + bar_w + TICK, y, AXIS, 1.0);
            c.text(
                bar_x + bar_w + TICK + TICK_GAP,
                y,
                label,
                Anchor::Start,
                INK_MUTED,
            );
        }
        c.vertical_text(
            bar_x + bar_w + TICK + TICK_GAP + bar_label_width + fs * 0.6,
            top + bar_h / 2.0,
            &value_title,
            INK,
        );
    }
    if any_missing {
        let y = top + plot_h - fs * 0.5;
        c.rect(bar_x, y - 5.0, 10.0, 10.0, NO_DATA);
        c.text(bar_x + 14.0, y, note, Anchor::Start, INK_MUTED);
    }
}

/// The color scale's range: the data range, or a padded one around a single
/// value.
fn padded_z(extent: Option<(f64, f64)>) -> (f64, f64) {
    match extent {
        None => (0.0, 1.0),
        Some((lo, hi)) => padded(lo, hi),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::plot_data::{AxisInfo, HeatmapPlot, SweepAxis, ValueInfo};

    fn axis(variable: &str) -> AxisInfo {
        AxisInfo {
            variable: variable.to_string(),
            label: None,
            units: None,
        }
    }

    fn series(name: &str, x: &[Option<f64>], y: &[Option<f64>]) -> Series {
        Series {
            name: name.to_string(),
            variable: name.to_string(),
            sweep_point: Vec::new(),
            x: x.to_vec(),
            y: y.to_vec(),
        }
    }

    fn xy(series: Vec<Series>) -> XyPlot {
        XyPlot {
            id: "p".to_string(),
            description: None,
            x: axis("t"),
            y: axis("N"),
            series,
        }
    }

    /// Tags balance, and the document is one `<svg>` element with a viewBox.
    fn assert_well_formed(svg: &str) {
        assert!(
            svg.starts_with("<svg xmlns=\"http://www.w3.org/2000/svg\""),
            "{svg}"
        );
        assert!(svg.contains("viewBox=\"0 0 "), "{svg}");
        assert!(svg.ends_with("</svg>"));
        let mut stack: Vec<String> = Vec::new();
        let mut rest = svg;
        while let Some(start) = rest.find('<') {
            let end = rest[start..].find('>').expect("unclosed tag") + start;
            let tag = &rest[start + 1..end];
            if let Some(name) = tag.strip_prefix('/') {
                assert_eq!(stack.pop().as_deref(), Some(name), "mismatched </{name}>");
            } else if !tag.ends_with('/') {
                let name = tag.split_whitespace().next().unwrap().to_string();
                stack.push(name);
            }
            rest = &rest[end + 1..];
        }
        assert!(stack.is_empty(), "unclosed: {stack:?}");
        assert!(!svg.contains("NaN") && !svg.contains("inf"), "{svg}");
    }

    #[test]
    fn nice_ticks_cover_the_range_with_round_steps() {
        let t = nice_ticks(0.0, 100.0, 6);
        assert_eq!(t.values, vec![0.0, 20.0, 40.0, 60.0, 80.0, 100.0]);
        let t = nice_ticks(0.0, 50.0, 6);
        assert_eq!((t.lo, t.hi, t.step), (0.0, 50.0, 10.0));
        let t = nice_ticks(0.67, 99.3, 5);
        assert!(t.lo <= 0.67 && t.hi >= 99.3);
        assert_eq!(t.step, 20.0);
        let t = nice_ticks(-0.3, 0.7, 6);
        assert_eq!(t.step, 0.2);
        assert!(t.values.contains(&0.0));
        // A constant series still gets an axis.
        let t = nice_ticks(5.0, 5.0, 5);
        assert!(t.lo < 5.0 && t.hi > 5.0);
        let t = nice_ticks(0.0, 0.0, 5);
        assert!(t.lo < 0.0 && t.hi > 0.0);
    }

    #[test]
    fn chosen_ticks_hug_the_data() {
        // Four ticks would give 0–60 for data ending at 50; six land on 50.
        let t = choose_ticks(0.0, 50.0, 4, 10, |t| t.values.len() <= 6);
        assert_eq!((t.lo, t.hi), (0.0, 50.0));
        // 0–50 by 10 and 0–50 by 50 are both two ticks off; the denser wins.
        assert_eq!(t.values.len(), 6);
        // A data end on a step boundary gets no extra step.
        let t = nice_ticks(0.0, 2e-6, 5);
        assert_eq!(t.values.len(), 5);
        // Two ticks only when nothing denser fits.
        let t = choose_ticks(0.0, 50.0, 2, 10, |t| t.values.len() <= 6);
        assert_eq!(t.values.len(), 6);
        // Nothing fits: two ticks, never a panic.
        let t = choose_ticks(0.0, 50.0, 4, 10, |_| false);
        assert!(t.values.len() >= 2);
    }

    #[test]
    fn tick_labels_share_decimals_and_drop_float_noise() {
        let t = nice_ticks(0.0, 1.0, 6);
        let f = TickFormat::for_ticks(&t);
        let labels: Vec<_> = t.values.iter().map(|v| f.format(*v)).collect();
        assert_eq!(labels, ["0.0", "0.2", "0.4", "0.6", "0.8", "1.0"]);
        let f = TickFormat::new(-1.0, 1.0, 0.5);
        assert_eq!(f.format(-0.5), "\u{2212}0.5");
        assert_eq!(f.format(-0.0), "0.0");
        assert_eq!(f.format(0.1 + 0.2), "0.3");
        let f = TickFormat::new(0.0, 100.0, 20.0);
        assert_eq!(f.format(40.0), "40");
    }

    #[test]
    fn tick_labels_go_scientific_at_the_extremes() {
        let t = nice_ticks(0.0, 3e-6, 4);
        let f = TickFormat::for_ticks(&t);
        let labels: Vec<_> = t.values.iter().map(|v| f.format(*v)).collect();
        assert_eq!(labels, ["0", "2e\u{2212}6", "4e\u{2212}6"]);
        let f = TickFormat::new(0.0, 3e4 * 10.0, 5e4);
        assert_eq!(f.format(2.5e5), "2.5e5");
        assert_eq!(f.format(1e5), "1.0e5");
        let t = nice_ticks(0.0, 2e-6, 5);
        let f = TickFormat::for_ticks(&t);
        let labels: Vec<_> = t.values.iter().map(|v| f.format(*v)).collect();
        assert_eq!(
            labels,
            [
                "0",
                "0.5e\u{2212}6",
                "1.0e\u{2212}6",
                "1.5e\u{2212}6",
                "2.0e\u{2212}6"
            ]
        );
    }

    #[test]
    fn values_print_to_three_significant_digits() {
        assert_eq!(format_value(0.1 + 0.2), "0.3");
        assert_eq!(format_value(31.622776601683793), "31.6");
        assert_eq!(format_value(316.22776601683796), "316");
        assert_eq!(format_value(1000.0), "1000");
        assert_eq!(format_value(0.5), "0.5");
        assert_eq!(format_value(-2.0), "\u{2212}2");
        assert_eq!(format_value(1e-6), "1e\u{2212}6");
        assert_eq!(format_value(2.5e4), "25000");
        assert_eq!(format_value(2.5e5), "2.5e5");
        assert_eq!(format_value(9.999e5), "1e6");
        assert_eq!(format_value(0.0), "0");
    }

    #[test]
    fn a_missing_sample_breaks_the_line() {
        let s = series(
            "N",
            &[Some(0.0), Some(1.0), Some(2.0), Some(3.0), Some(4.0)],
            &[Some(1.0), Some(2.0), None, Some(3.0), Some(4.0)],
        );
        let svg = render_svg(&PlotData::Line(xy(vec![s])), &SvgOptions::default());
        assert_well_formed(&svg);
        assert_eq!(svg.matches("<path ").count(), 2, "{svg}");
    }

    #[test]
    fn an_isolated_sample_is_drawn_as_a_dot() {
        let s = series(
            "N",
            &[Some(0.0), Some(1.0), Some(2.0)],
            &[None, Some(2.0), Some(f64::NAN)],
        );
        let svg = render_svg(&PlotData::Line(xy(vec![s])), &SvgOptions::default());
        assert_well_formed(&svg);
        assert_eq!(svg.matches("<path ").count(), 0);
        assert_eq!(svg.matches("<circle ").count(), 1);
    }

    #[test]
    fn scatter_skips_missing_points() {
        let s = series(
            "N",
            &[Some(0.0), None, Some(2.0), Some(3.0)],
            &[Some(1.0), Some(2.0), Some(f64::INFINITY), Some(4.0)],
        );
        let svg = render_svg(&PlotData::Scatter(xy(vec![s])), &SvgOptions::default());
        assert_well_formed(&svg);
        assert_eq!(svg.matches("<circle ").count(), 2);
    }

    #[test]
    fn sweep_legends_name_the_swept_values() {
        let swept = |name: &str, r: f64| Series {
            sweep_point: vec![("r".to_string(), r)],
            ..series(name, &[Some(0.0), Some(1.0)], &[Some(0.0), Some(r)])
        };
        let one = vec![swept("N", 0.1), swept("N", 0.30000000000000004)];
        assert_eq!(legend_labels(&one), ["r = 0.1", "r = 0.3"]);
        let styles = series_styles(&one);
        assert_ne!(styles[0].color, styles[1].color);
        assert!(styles.iter().all(|s| s.dash.is_none()));

        let two = vec![swept("A", 0.5), swept("B", 0.5), swept("A", 1.0)];
        assert_eq!(
            legend_labels(&two),
            ["A, r = 0.5", "B, r = 0.5", "A, r = 1"]
        );
        let styles = series_styles(&two);
        assert_eq!(styles[0].color, styles[2].color);
        assert_ne!(styles[0].dash, styles[2].dash);

        let mut point = swept("N", 0.5);
        point.sweep_point.push(("K".to_string(), 1000.0));
        assert_eq!(sweep_text(&point.sweep_point), "r = 0.5, K = 1000");

        let svg = render_svg(&PlotData::Line(xy(one)), &SvgOptions::default());
        assert_well_formed(&svg);
        assert!(svg.contains(">r = 0.3<"), "{svg}");
    }

    #[test]
    fn a_single_series_has_no_legend() {
        let s = series("N", &[Some(0.0), Some(1.0)], &[Some(1.0), Some(2.0)]);
        let svg = render_svg(&PlotData::Line(xy(vec![s])), &SvgOptions::default());
        // One path, the data: no legend swatch.
        assert_eq!(svg.matches("<path ").count(), 1);
    }

    #[test]
    fn categorical_colors_repeat_with_a_new_dash() {
        let many: Vec<Series> = (0..8)
            .map(|i| series(&format!("s{i}"), &[Some(0.0)], &[Some(i as f64)]))
            .collect();
        let styles = series_styles(&many);
        assert_eq!(styles[0].color, styles[6].color);
        assert_ne!(styles[0].dash, styles[6].dash);
    }

    #[test]
    fn long_legends_are_thinned_but_keep_both_ends() {
        let (shown, more) = legend_rows(20, 6);
        assert_eq!(shown.first(), Some(&0));
        assert_eq!(shown.last(), Some(&19));
        assert_eq!(shown.len() + more, 20);
        assert!(shown.len() < 6);
        assert_eq!(legend_rows(3, 6), (vec![0, 1, 2], 0));
    }

    #[test]
    fn degenerate_inputs_do_not_panic() {
        let opts = SvgOptions::default();
        let empty = render_svg(&PlotData::Line(xy(Vec::new())), &opts);
        assert_well_formed(&empty);
        assert!(empty.contains(">no data<"));
        let blank = series("N", &[None, None], &[None, Some(1.0)]);
        assert_well_formed(&render_svg(&PlotData::Scatter(xy(vec![blank])), &opts));
        let flat = series("N", &[Some(0.0), Some(1.0)], &[Some(3.0), Some(3.0)]);
        assert_well_formed(&render_svg(&PlotData::Line(xy(vec![flat])), &opts));
        let point = series("N", &[Some(2.0)], &[Some(0.0)]);
        assert_well_formed(&render_svg(&PlotData::Line(xy(vec![point])), &opts));
        let tiny = SvgOptions {
            width: 0.0,
            height: f64::NAN,
            font_size: -1.0,
            ..SvgOptions::default()
        };
        let s = series("N", &[Some(0.0), Some(1.0)], &[Some(1.0), Some(2.0)]);
        assert_well_formed(&render_svg(&PlotData::Line(xy(vec![s])), &tiny));
        let ragged = HeatmapPlot {
            id: "h".to_string(),
            description: None,
            x: sweep("r", &[1.0, 2.0]),
            y: sweep("K", &[]),
            value: value("N"),
            z: vec![vec![Some(1.0)]],
        };
        assert_well_formed(&render_svg(&PlotData::Heatmap(ragged), &opts));
    }

    fn sweep(variable: &str, values: &[f64]) -> SweepAxis {
        SweepAxis {
            info: axis(variable),
            values: values.to_vec(),
            scale: "linear".to_string(),
        }
    }

    fn value(variable: &str) -> ValueInfo {
        ValueInfo {
            info: axis(variable),
            reduce: Some("final".to_string()),
            at_time: None,
        }
    }

    #[test]
    fn heatmap_draws_failed_cells_gray() {
        let plot = HeatmapPlot {
            id: "h".to_string(),
            description: Some("Final N <by> r & K".to_string()),
            x: sweep("r", &[0.1, 0.2, 0.3]),
            y: sweep("K", &[10.0, 100.0]),
            value: value("N"),
            z: vec![
                vec![Some(1.0), Some(2.0), Some(3.0)],
                vec![Some(4.0), None, Some(6.0)],
            ],
        };
        let svg = render_svg(&PlotData::Heatmap(plot), &SvgOptions::default());
        assert_well_formed(&svg);
        // The failed cell and the key beside the color bar.
        assert_eq!(svg.matches(&format!("fill=\"{NO_DATA}\"")).count(), 2);
        assert!(svg.contains(">failed run<"));
        assert!(svg.contains("<title>Final N &lt;by&gt; r &amp; K</title>"));
        // The lowest value takes the bottom of the scale, the highest the top.
        assert!(svg.contains(&format!("fill=\"{}\"", viridis(0.0))));
        assert!(svg.contains(&format!("fill=\"{}\"", viridis(1.0))));
    }

    #[test]
    fn heatmap_row_zero_is_at_the_bottom() {
        let plot = HeatmapPlot {
            id: "h".to_string(),
            description: None,
            x: sweep("r", &[1.0]),
            y: sweep("K", &[1.0, 2.0]),
            value: value("N"),
            z: vec![vec![Some(0.0)], vec![Some(1.0)]],
        };
        let svg = render_svg(&PlotData::Heatmap(plot), &SvgOptions::default());
        let low = svg.find(&format!("fill=\"{}\"", viridis(0.0))).unwrap();
        let high = svg.find(&format!("fill=\"{}\"", viridis(1.0))).unwrap();
        let y_of = |at: usize| -> f64 {
            let tag = &svg[svg[..at].rfind('<').unwrap()..at];
            let y = tag.split("y=\"").nth(1).unwrap();
            y[..y.find('"').unwrap()].parse().unwrap()
        };
        assert!(y_of(low) > y_of(high), "row 0 should be drawn below row 1");
    }

    #[test]
    fn value_titles_name_the_reduction() {
        let mut v = value("N");
        assert_eq!(value_title(&v), "N (final)");
        v.info.units = Some("mol".to_string());
        assert_eq!(value_title(&v), "N (mol, final)");
        v.reduce = None;
        v.at_time = Some(5.0);
        assert_eq!(value_title(&v), "N at t = 5 (mol)");
        v.info.label = Some("population".to_string());
        assert_eq!(value_title(&v), "population at t = 5");
    }

    #[test]
    fn output_is_deterministic() {
        let s = series(
            "N",
            &[Some(0.0), Some(1.0 / 3.0), Some(2.0)],
            &[Some(1.0), Some(2.0 / 3.0), Some(0.1)],
        );
        let plot = PlotData::Line(xy(vec![s.clone(), series("M", &s.x, &s.y)]));
        let a = render_svg(&plot, &SvgOptions::default());
        let b = render_svg(&plot, &SvgOptions::default());
        assert_eq!(a, b);
        assert_well_formed(&a);
        // Coordinates carry at most two decimals.
        assert!(!a.contains(".333"));
    }

    #[test]
    fn viridis_ends_match_the_table() {
        assert_eq!(viridis(0.0), "#440154");
        assert_eq!(viridis(1.0), "#fde725");
        assert_eq!(viridis(0.5), "#21908c");
        assert_eq!(viridis(f64::NAN), "#440154");
    }
}
