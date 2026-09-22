//! One call from elements to everything a front end shows: the `.esm` file,
//! diagnostics, rendered math, test results and figures.
//!
//! [`build`] is what both front ends call. Its [`BuildOutput`] has one
//! [`ElementOutput`] per input element, in the same order, so a front end
//! renders element `i` from `elements[i]` without matching anything up.

use std::collections::HashSet;

use earthsci_ast::{
    AssertionResult, EsmFile, Expr, SolveOptions, parse_equation, run_inline_tests, to_latex,
    to_unicode,
};
use serde::Serialize;
use serde_json::Value;

use crate::analysis::{RunFailure, RunOptions, run_analysis};
use crate::assemble::{Assembly, ElementInfo, QuantityInfo, assemble, check};
use crate::diagnostic::Diagnostic;
use crate::element::{Document, ElementError, ElementKind, FORMAT_VERSION};
use crate::plot_data::PlotData;
use crate::svg::{SvgOptions, render_svg};
use crate::typst_math::{equation_to_typst, name_to_typst};

/// What [`build`] does beyond assembling and validating.
#[derive(Debug, Clone)]
pub struct BuildOptions {
    /// Run the inline tests.
    pub run_tests: bool,
    /// Run the analyses and plots.
    pub run_analyses: bool,
    /// Draw each figure as SVG (otherwise only its data is returned).
    pub render_svg: bool,
    /// How to draw figures.
    pub svg: SvgOptions,
    /// How to run analyses.
    pub run: RunOptions,
}

impl Default for BuildOptions {
    fn default() -> Self {
        BuildOptions {
            run_tests: true,
            run_analyses: true,
            render_svg: true,
            svg: SvgOptions::default(),
            run: RunOptions::default(),
        }
    }
}

/// Everything a front end needs to render a narrative document.
#[derive(Debug, Clone, Serialize)]
pub struct BuildOutput {
    /// The element-format version.
    pub version: u32,
    /// Whether the document has no errors (a failing test is an error).
    pub ok: bool,
    /// The assembled `.esm` document.
    pub esm: Value,
    /// Every problem, in element order.
    pub diagnostics: Vec<Diagnostic>,
    /// One entry per input element, in the same order.
    pub elements: Vec<ElementOutput>,
    /// Every declared quantity, for a variables table.
    pub quantities: Vec<QuantityInfo>,
}

/// What one element renders as.
#[derive(Debug, Clone, Default, Serialize)]
pub struct ElementOutput {
    /// The element's `kind`.
    pub kind: String,
    /// Its model, and where its content is in the `.esm` document.
    #[serde(flatten)]
    pub info: ElementInfo,
    /// A `var` or `param`'s name, or an `eq`'s equation, as math.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub math: Option<Math>,
    /// A `test`'s results.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub test: Option<TestOutcome>,
    /// A `plot`'s figure, or an `analysis`'s own plots.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub figures: Vec<Figure>,
    /// Whether any error is attached to this element.
    pub has_errors: bool,
    /// For a `test`, `analysis` or `plot`: it was not run, because its model
    /// has errors.
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub skipped: bool,
}

/// Math in each notation a front end might want.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Math {
    /// Typst math (the text between `$ … $`).
    pub typst: String,
    /// LaTeX, as KaTeX reads it.
    pub latex: String,
    /// Unicode text.
    pub unicode: String,
}

/// A test's results.
#[derive(Debug, Clone, Serialize)]
pub struct TestOutcome {
    /// The test id.
    pub id: String,
    /// Whether every assertion passed.
    pub passed: bool,
    /// One result per assertion.
    pub assertions: Vec<AssertionResult>,
}

/// One drawn figure.
#[derive(Debug, Clone, Serialize)]
pub struct Figure {
    /// The plot id.
    pub id: String,
    /// The analysis that ran it.
    pub analysis: String,
    /// The plot's data.
    pub data: PlotData,
    /// The figure as a standalone SVG document, when requested.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub svg: Option<String>,
    /// Runs of the sweep behind it that failed, leaving gaps.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub failures: Vec<RunFailure>,
}

/// Read a document from JSON and build it. A document that cannot be read at
/// all yields an output with one diagnostic and nothing else.
pub fn build_json(text: &str, opts: &BuildOptions) -> BuildOutput {
    match Document::from_json(text) {
        Ok((doc, errors)) => build_with_errors(&doc, &errors, opts),
        Err(e) => BuildOutput {
            version: FORMAT_VERSION,
            ok: false,
            esm: Value::Null,
            diagnostics: vec![Diagnostic::error("invalid_document", e.0)],
            elements: Vec::new(),
            quantities: Vec::new(),
        },
    }
}

/// Build a document.
pub fn build(doc: &Document, opts: &BuildOptions) -> BuildOutput {
    build_with_errors(doc, &[], opts)
}

fn build_with_errors(doc: &Document, errors: &[ElementError], opts: &BuildOptions) -> BuildOutput {
    let mut assembly = assemble(doc);
    for e in errors {
        let mut d = Diagnostic::error("invalid_element", e.message.clone());
        d.element = Some(e.index);
        d.source = e.source.clone();
        assembly.diagnostics.push(d);
    }
    let file = check(&mut assembly);

    let mut elements: Vec<ElementOutput> = doc
        .elements
        .iter()
        .zip(&assembly.elements)
        .enumerate()
        .map(|(i, (element, info))| ElementOutput {
            // An element that failed to parse keeps the kind it claimed.
            kind: match errors.iter().find(|e| e.index == i) {
                Some(e) => e.kind.clone().unwrap_or_default(),
                None => element.kind.name().to_string(),
            },
            info: info.clone(),
            math: if element.is_placeholder() {
                None
            } else {
                math_of(&element.kind)
            },
            ..Default::default()
        })
        .collect();

    // Running a model whose declarations or equations are wrong only buries
    // those errors under solver failures, so such a model's tests and
    // analyses are skipped. An error on a test or plot stops only that one.
    let broken = broken_models(doc, &assembly, file.is_none());
    for (element, out) in doc.elements.iter().zip(elements.iter_mut()) {
        let runs = matches!(
            element.kind,
            ElementKind::Test(_) | ElementKind::Analysis(_) | ElementKind::Plot(_)
        );
        let skip = |model: &Option<String>| model.as_ref().is_none_or(|m| broken.contains(m));
        out.skipped = runs && skip(&out.info.model) && (opts.run_tests || opts.run_analyses);
    }
    let mut extra = Vec::new();
    if let Some(file) = &file {
        if opts.run_tests {
            run_tests(file, &assembly, &broken, &mut elements, &mut extra);
        }
        if opts.run_analyses {
            run_analyses(file, &assembly, &broken, opts, &mut elements, &mut extra);
        }
    }
    let mut diagnostics = assembly.diagnostics;
    diagnostics.extend(extra);
    diagnostics.sort_by_key(|d| d.element.unwrap_or(usize::MAX));
    for d in diagnostics.iter().filter(|d| d.is_error()) {
        if let Some(i) = d.element
            && let Some(e) = elements.get_mut(i)
        {
            e.has_errors = true;
        }
    }
    BuildOutput {
        version: FORMAT_VERSION,
        ok: !diagnostics.iter().any(Diagnostic::is_error),
        esm: assembly.esm,
        diagnostics,
        elements,
        quantities: assembly.quantities,
    }
}

/// The models with an error in a declaration or equation, or every model when
/// the document has an error no element owns or did not load.
fn broken_models(doc: &Document, assembly: &Assembly, unloaded: bool) -> HashSet<String> {
    let all = || {
        assembly
            .elements
            .iter()
            .filter_map(|e| e.model.clone())
            .collect()
    };
    if unloaded {
        return all();
    }
    let mut broken = HashSet::new();
    for d in assembly.diagnostics.iter().filter(|d| d.is_error()) {
        let Some(i) = d.element else { return all() };
        let defines = matches!(
            doc.elements.get(i).map(|e| &e.kind),
            Some(
                ElementKind::Model(_)
                    | ElementKind::Var(_)
                    | ElementKind::Param(_)
                    | ElementKind::Eq(_)
            )
        );
        if defines && let Some(m) = &assembly.elements[i].model {
            broken.insert(m.clone());
        }
    }
    broken
}

fn math_of(kind: &ElementKind) -> Option<Math> {
    match kind {
        ElementKind::Var(q) | ElementKind::Param(q) => {
            let expr = Expr::Variable(q.name.clone());
            Some(Math {
                typst: name_to_typst(&q.name),
                latex: to_latex(&expr),
                unicode: to_unicode(&expr),
            })
        }
        ElementKind::Eq(eq) => parse_equation(&eq.text).ok().map(|parsed| Math {
            typst: equation_to_typst(&parsed),
            latex: to_latex(&parsed),
            unicode: to_unicode(&parsed),
        }),
        _ => None,
    }
}

/// The element whose content is exactly at `/models/{model}/{rest}`.
fn element_at(assembly: &Assembly, model: &str, rest: &str) -> Option<usize> {
    let path = format!("/models/{model}/{rest}");
    assembly
        .elements
        .iter()
        .position(|e| e.path.as_deref() == Some(path.as_str()))
}

fn run_tests(
    file: &EsmFile,
    assembly: &Assembly,
    broken: &HashSet<String>,
    elements: &mut [ElementOutput],
    extra: &mut Vec<Diagnostic>,
) {
    for (model_name, model) in file.models.iter().flatten() {
        if broken.contains(model_name) {
            continue;
        }
        let Some(tests) = &model.tests else { continue };
        let results = run_inline_tests(file, Some(model_name), &SolveOptions::default());
        for (at, test) in tests.iter().enumerate() {
            let Some(index) = element_at(assembly, model_name, &format!("tests/{at}")) else {
                continue;
            };
            let assertions: Vec<AssertionResult> = results
                .iter()
                .filter(|r| r.model == *model_name && r.test_id == test.id)
                .cloned()
                .collect();
            let passed = !assertions.is_empty() && assertions.iter().all(|a| a.passed);
            for a in assertions.iter().filter(|a| !a.passed) {
                let what = match a.actual {
                    Some(actual) => format!(
                        "`{}` at t = {} is {actual}, expected {} (rtol {}, atol {})",
                        a.variable, a.time, a.expected, a.rtol, a.atol
                    ),
                    None => format!("`{}` at t = {}: {}", a.variable, a.time, a.message),
                };
                let mut d =
                    Diagnostic::error("test_failed", format!("test `{}` failed: {what}", test.id));
                d.element = Some(index);
                d.source = assembly.source_of(index);
                d.path = elements[index].info.path.clone();
                extra.push(d);
            }
            elements[index].test = Some(TestOutcome {
                id: test.id.clone(),
                passed,
                assertions,
            });
        }
    }
}

fn run_analyses(
    file: &EsmFile,
    assembly: &Assembly,
    broken: &HashSet<String>,
    opts: &BuildOptions,
    elements: &mut [ElementOutput],
    extra: &mut Vec<Diagnostic>,
) {
    for (model_name, model) in file.models.iter().flatten() {
        if broken.contains(model_name) {
            continue;
        }
        for (at, analysis) in model.analyses.iter().flatten().enumerate() {
            // The analysis element, when the author wrote one; otherwise the
            // plot element whose own run this is.
            let analysis_element = element_at(assembly, model_name, &format!("analyses/{at}"));
            let plot_element = |plot_at: usize| {
                element_at(
                    assembly,
                    model_name,
                    &format!("analyses/{at}/plots/{plot_at}"),
                )
            };
            let owners: Vec<usize> = analysis_element
                .into_iter()
                .chain((0..analysis.plots.as_ref().map_or(0, Vec::len)).filter_map(plot_element))
                .collect();
            let result = match run_analysis(file, model_name, analysis, &opts.run) {
                Ok(result) => result,
                Err(e) => {
                    for &index in &owners {
                        let mut d = Diagnostic::error(
                            e.code.clone(),
                            format!("analysis `{}`: {}", analysis.id, e.message),
                        );
                        d.element = Some(index);
                        d.source = assembly.source_of(index);
                        extra.push(d);
                    }
                    continue;
                }
            };
            let plot_ids: Vec<&str> = analysis
                .plots
                .iter()
                .flatten()
                .map(|p| p.id.as_str())
                .collect();
            // A plot's figure goes to its plot element, or to the analysis
            // element for a plot written inside the analysis.
            let owner_of_plot = |id: &str| {
                let plot_at = plot_ids.iter().position(|p| *p == id)?;
                plot_element(plot_at).or(analysis_element)
            };
            for data in result.plots {
                let Some(index) = owner_of_plot(data.id()) else {
                    continue;
                };
                let svg = opts.render_svg.then(|| render_svg(&data, &opts.svg));
                elements[index].figures.push(Figure {
                    id: data.id().to_string(),
                    analysis: analysis.id.clone(),
                    data,
                    svg,
                    failures: result.failures.clone(),
                });
            }
            for e in &result.plot_errors {
                let Some(index) = owner_of_plot(&e.plot) else {
                    continue;
                };
                let mut d =
                    Diagnostic::error(e.code.clone(), format!("plot `{}`: {}", e.plot, e.message));
                d.element = Some(index);
                d.source = assembly.source_of(index);
                extra.push(d);
            }
            if !result.failures.is_empty() {
                for &index in &owners {
                    let mut d = Diagnostic::warning(
                        "run_failed",
                        format!(
                            "{} of {} runs of analysis `{}` failed, leaving gaps: {}",
                            result.failures.len(),
                            result.runs.len(),
                            analysis.id,
                            result.failures[0].message
                        ),
                    );
                    d.element = Some(index);
                    d.source = assembly.source_of(index);
                    extra.push(d);
                }
            }
        }
    }
}
