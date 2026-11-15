//! One call from a document to everything a front end shows: the `.esm` file,
//! diagnostics, test results and figures.
//!
//! A document comes in one of three ways:
//!
//! - [`build_text`]: the text of an `.esm` document in the ESM Markdown or
//!   Typst format, read by the core (`earthsci_ast::parse_document`).
//! - [`build_document`]: an `.esm` document as JSON; [`build_onto`] adds
//!   narrative's own tests, analyses and figures to one, which is what the
//!   Markdown front end does.
//! - [`build_json`], [`build`], [`build_value`]: narrative's internal element
//!   format, which the Typst plugin's `build` takes.
//!
//! Every [`BuildOutput`] has one [`ElementOutput`] per input element, in the
//! same order, so a front end renders element `i` from `elements[i]` without
//! matching anything up; the results of the tests and analyses the document
//! writes itself are in [`BuildOutput::constructs`], by JSON pointer.

use std::collections::HashSet;

use earthsci_ast::{
    AssertionResult, DocumentFormat, EsmFile, SolveOptions, parse_document, parse_math, print_math,
    run_inline_tests,
};
use serde::Serialize;
use serde_json::{Value, json};

use crate::analysis::{RunFailure, RunOptions, run_analysis};
use crate::assemble::{Assembly, ElementInfo, QuantityInfo, assemble, assemble_onto, check};
use crate::diagnostic::Diagnostic;
use crate::element::{Document, ElementError, ElementKind, FORMAT_VERSION};
use crate::plot_data::PlotData;
use crate::svg::{SvgOptions, render_svg};

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
    /// The results of the tests and analyses no element owns: the ones the
    /// document writes itself.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub constructs: Vec<ConstructOutput>,
    /// Every declared quantity, for a variables table.
    pub quantities: Vec<QuantityInfo>,
}

/// The result of a test or an analysis the document writes itself.
#[derive(Debug, Clone, Default, Serialize)]
pub struct ConstructOutput {
    /// Where it is in the `.esm` document, as a JSON pointer:
    /// `/models/{model}/tests/{i}` or `/models/{model}/analyses/{i}`.
    pub path: String,
    /// A test's results.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub test: Option<TestOutcome>,
    /// An analysis's figures.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub figures: Vec<Figure>,
    /// It was not run, because its model has errors.
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub skipped: bool,
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
///
/// The LaTeX and the Typst are the core's printers (`earthsci_ast::print_math`),
/// the notation of the ESM Markdown and Typst formats, with the element's model's
/// declared names in scope.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Math {
    /// Typst math (the text between `$ … $`).
    pub typst: String,
    /// LaTeX, as KaTeX reads it.
    pub latex: String,
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

/// An output with no document in it, only `diagnostic`.
pub(crate) fn failed(diagnostic: Diagnostic) -> BuildOutput {
    BuildOutput {
        version: FORMAT_VERSION,
        ok: false,
        esm: Value::Null,
        diagnostics: vec![diagnostic],
        elements: Vec::new(),
        constructs: Vec::new(),
        quantities: Vec::new(),
    }
}

/// Read an `.esm` document written in the ESM Markdown or Typst format with
/// the core, and build it: validate it, run its tests and analyses, draw its
/// figures. A text the core refuses yields an output with one diagnostic, the
/// core's.
pub fn build_text(text: &str, format: DocumentFormat, opts: &BuildOptions) -> BuildOutput {
    match parse_document(text, format) {
        Ok(esm) => build_document(esm, opts),
        Err(e) => failed(Diagnostic::error(e.code.to_string(), e.message)),
    }
}

/// Build an `.esm` document: validate it, run its tests and analyses, draw its
/// figures.
pub fn build_document(esm: Value, opts: &BuildOptions) -> BuildOutput {
    let doc = json!({"version": FORMAT_VERSION, "elements": []});
    build_onto(esm, doc, opts)
}

/// Add the `test`, `analysis` and `plot` elements of `doc` (the element format,
/// as JSON) to the `.esm` document `esm`, and build the result.
#[doc(hidden)]
pub fn build_onto(esm: Value, doc: Value, opts: &BuildOptions) -> BuildOutput {
    match Document::from_value(doc) {
        Ok((doc, errors)) => {
            let assembly = assemble_onto(esm, &doc);
            build_assembly(&doc, &errors, assembly, opts)
        }
        Err(e) => failed(Diagnostic::error("invalid_document", e.0)),
    }
}

/// Read a document in the element format from JSON and build it. A document
/// that cannot be read at all yields an output with one diagnostic and
/// nothing else.
#[doc(hidden)]
pub fn build_json(text: &str, opts: &BuildOptions) -> BuildOutput {
    match Document::from_json(text) {
        Ok((doc, errors)) => build_with_errors(&doc, &errors, opts),
        Err(e) => failed(Diagnostic::error("invalid_document", e.0)),
    }
}

/// Build a document in the element format.
#[doc(hidden)]
pub fn build(doc: &Document, opts: &BuildOptions) -> BuildOutput {
    build_with_errors(doc, &[], opts)
}

/// [`build_json`] for a document a front end has already assembled as JSON.
#[doc(hidden)]
pub fn build_value(doc: Value, opts: &BuildOptions) -> BuildOutput {
    match Document::from_value(doc) {
        Ok((doc, errors)) => build_with_errors(&doc, &errors, opts),
        Err(e) => failed(Diagnostic::error("invalid_document", e.0)),
    }
}

fn build_with_errors(doc: &Document, errors: &[ElementError], opts: &BuildOptions) -> BuildOutput {
    let assembly = assemble(doc);
    build_assembly(doc, errors, assembly, opts)
}

fn build_assembly(
    doc: &Document,
    errors: &[ElementError],
    mut assembly: Assembly,
    opts: &BuildOptions,
) -> BuildOutput {
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
                math_of(&element.kind, &names_in(&assembly.quantities, info))
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
    let mut constructs = Vec::new();
    if let Some(file) = &file {
        let mut run = Runs {
            file,
            assembly: &assembly,
            broken: &broken,
            elements: &mut elements,
            constructs: &mut constructs,
            extra: &mut extra,
        };
        if opts.run_tests {
            run.tests();
        }
        if opts.run_analyses {
            run.analyses(opts);
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
        constructs,
        quantities: assembly.quantities,
    }
}

/// The names declared in an element's model.
fn names_in(quantities: &[QuantityInfo], info: &ElementInfo) -> Vec<String> {
    quantities
        .iter()
        .filter(|q| Some(&q.model) == info.model.as_ref())
        .map(|q| q.name.clone())
        .collect()
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
        let Some(i) = d.element else {
            // A finding in a document read by the core: it breaks the model it
            // is in, unless it is in one of the model's tests or analyses.
            match d.path.as_deref().and_then(model_part) {
                Some((model, rest)) => {
                    if !(rest.starts_with("tests") || rest.starts_with("analyses")) {
                        broken.insert(model);
                    }
                    continue;
                }
                None => return all(),
            }
        };
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

/// The model a JSON pointer into a model points into, and the rest of the
/// pointer after `/models/{model}/`.
fn model_part(path: &str) -> Option<(String, &str)> {
    let rest = path.strip_prefix("/models/")?;
    let (model, rest) = rest.split_once('/').unwrap_or((rest, ""));
    Some((model.replace("~1", "/").replace("~0", "~"), rest))
}

/// A `var` or `param`'s name, or an `eq`'s equation, as math, with `names`
/// (its model's declarations) in scope.
fn math_of(kind: &ElementKind, names: &[String]) -> Option<Math> {
    let json = match kind {
        ElementKind::Var(q) | ElementKind::Param(q) => Value::String(q.name.clone()),
        ElementKind::Eq(eq) => parse_math(&eq.math, names, DocumentFormat::Typst).ok()?,
        _ => return None,
    };
    Some(Math {
        typst: print_math(&json, names, DocumentFormat::Typst),
        latex: print_math(&json, names, DocumentFormat::Markdown),
    })
}

/// The element whose content is exactly at `/models/{model}/{rest}`.
fn element_at(assembly: &Assembly, model: &str, rest: &str) -> Option<usize> {
    let path = format!("/models/{model}/{rest}");
    assembly
        .elements
        .iter()
        .position(|e| e.path.as_deref() == Some(path.as_str()))
}

/// Running a loaded document's tests and analyses, and putting each result
/// where it belongs: on the element that wrote the test or analysis, or, for
/// one the document writes itself, in [`BuildOutput::constructs`].
struct Runs<'a> {
    file: &'a EsmFile,
    assembly: &'a Assembly,
    broken: &'a HashSet<String>,
    elements: &'a mut [ElementOutput],
    constructs: &'a mut Vec<ConstructOutput>,
    extra: &'a mut Vec<Diagnostic>,
}

impl Runs<'_> {
    /// Report `d` on each of `owners`, or, when no element owns what it is
    /// about, at the JSON pointer `path`.
    fn report(&mut self, owners: &[usize], path: &str, d: Diagnostic) {
        if owners.is_empty() {
            self.extra.push(d.with_path(path.to_string()));
            return;
        }
        for &index in owners {
            let mut d = d.clone();
            d.element = Some(index);
            d.source = self.assembly.source_of(index);
            if d.path.is_none() {
                d.path = self.elements[index].info.path.clone();
            }
            self.extra.push(d);
        }
    }

    /// The construct output at `path`, made on first use.
    fn construct(&mut self, path: &str) -> &mut ConstructOutput {
        match self.constructs.iter().position(|c| c.path == path) {
            Some(at) => &mut self.constructs[at],
            None => {
                self.constructs.push(ConstructOutput {
                    path: path.to_string(),
                    ..ConstructOutput::default()
                });
                self.constructs.last_mut().expect("just pushed")
            }
        }
    }

    fn tests(&mut self) {
        let file = self.file;
        for (model_name, model) in file.models.iter().flatten() {
            let Some(tests) = &model.tests else { continue };
            let base = format!(
                "/models/{}",
                model_name.replace('~', "~0").replace('/', "~1")
            );
            if self.broken.contains(model_name) {
                // The elements' own tests are marked skipped by the caller.
                for at in 0..tests.len() {
                    if element_at(self.assembly, model_name, &format!("tests/{at}")).is_none() {
                        self.construct(&format!("{base}/tests/{at}")).skipped = true;
                    }
                }
                continue;
            }
            let results = run_inline_tests(file, Some(model_name), &SolveOptions::default());
            for (at, test) in tests.iter().enumerate() {
                let path = format!("{base}/tests/{at}");
                let owner = element_at(self.assembly, model_name, &format!("tests/{at}"));
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
                    let d = Diagnostic::error(
                        "test_failed",
                        format!("test `{}` failed: {what}", test.id),
                    );
                    self.report(owner.as_slice(), &path, d);
                }
                let outcome = TestOutcome {
                    id: test.id.clone(),
                    passed,
                    assertions,
                };
                match owner {
                    Some(index) => self.elements[index].test = Some(outcome),
                    None => self.construct(&path).test = Some(outcome),
                }
            }
        }
    }

    fn analyses(&mut self, opts: &BuildOptions) {
        let file = self.file;
        for (model_name, model) in file.models.iter().flatten() {
            let base = format!(
                "/models/{}",
                model_name.replace('~', "~0").replace('/', "~1")
            );
            for (at, analysis) in model.analyses.iter().flatten().enumerate() {
                let path = format!("{base}/analyses/{at}");
                // The analysis element, when the author wrote one; otherwise the
                // plot element whose own run this is.
                let analysis_element =
                    element_at(self.assembly, model_name, &format!("analyses/{at}"));
                let assembly = self.assembly;
                let plot_element = |plot_at: usize| {
                    element_at(
                        assembly,
                        model_name,
                        &format!("analyses/{at}/plots/{plot_at}"),
                    )
                };
                let owners: Vec<usize> = analysis_element
                    .into_iter()
                    .chain(
                        (0..analysis.plots.as_ref().map_or(0, Vec::len)).filter_map(plot_element),
                    )
                    .collect();
                if self.broken.contains(model_name) {
                    // The elements' own analyses are marked skipped by the caller.
                    if owners.is_empty() {
                        self.construct(&path).skipped = true;
                    }
                    continue;
                }
                let result = match run_analysis(file, model_name, analysis, &opts.run) {
                    Ok(result) => result,
                    Err(e) => {
                        let d = Diagnostic::error(
                            e.code.clone(),
                            format!("analysis `{}`: {}", analysis.id, e.message),
                        );
                        self.report(&owners, &path, d);
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
                // element for a plot written inside the analysis; with neither,
                // the analysis is the document's own.
                let owner_of_plot = |id: &str| {
                    let plot_at = plot_ids.iter().position(|p| *p == id);
                    plot_at.and_then(plot_element).or(analysis_element)
                };
                for data in result.plots {
                    let svg = opts.render_svg.then(|| render_svg(&data, &opts.svg));
                    let figure = Figure {
                        id: data.id().to_string(),
                        analysis: analysis.id.clone(),
                        svg,
                        failures: result.failures.clone(),
                        data,
                    };
                    match owner_of_plot(&figure.id) {
                        Some(index) => self.elements[index].figures.push(figure),
                        None if owners.is_empty() => self.construct(&path).figures.push(figure),
                        None => {}
                    }
                }
                for e in &result.plot_errors {
                    let d = Diagnostic::error(
                        e.code.clone(),
                        format!("plot `{}`: {}", e.plot, e.message),
                    );
                    match owner_of_plot(&e.plot) {
                        Some(index) => self.report(&[index], &path, d),
                        None if owners.is_empty() => self.report(&[], &path, d),
                        None => {}
                    }
                }
                if !result.failures.is_empty() {
                    let d = Diagnostic::warning(
                        "run_failed",
                        format!(
                            "{} of {} runs of analysis `{}` failed, leaving gaps: {}",
                            result.failures.len(),
                            result.runs.len(),
                            analysis.id,
                            result.failures[0].message
                        ),
                    );
                    self.report(&owners, &path, d);
                }
            }
        }
    }
}
