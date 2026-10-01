//! Turn a [`Document`]'s elements into an `.esm` document.
//!
//! Element order does not matter: papers often use a quantity before they
//! define it ("… where N is the amount of nitrogen"), so the whole document is
//! gathered first and checked as a whole. Every problem becomes a
//! [`Diagnostic`] on the element that caused it, and the assembler keeps going
//! so a front end can show all of them at once.
//!
//! [`check`] then runs the core loader and validator over the result and maps
//! their findings back to elements by the JSON pointer each element's content
//! landed at.

use std::collections::{BTreeMap, HashMap, HashSet};

use earthsci_ast::{
    EsmFile, Expr, ModelAnalysis, ModelTest, Plot, PlotAxis, PlotY, SCHEMA_VERSION,
    StructuralErrorCode, load_document, parse_equation, parse_expression, validate,
};
use serde::Serialize;
use serde_json::{Map, Value, json};

use crate::diagnostic::Diagnostic;
use crate::element::{
    Document, ElementKind, EqElement, FORMAT_VERSION, PlotElement, QuantityElement, Slider,
    SourceSpan, YSpec,
};

/// The name of the independent variable, which needs no declaration.
pub const TIME: &str = "t";

/// The model name used when a document names none.
pub const IMPLICIT_MODEL: &str = "Model";

/// An assembled document.
#[derive(Debug, Clone)]
pub struct Assembly {
    /// The `.esm` document.
    pub esm: Value,
    /// The assembler's findings, in element order. [`check`] adds the core
    /// validator's.
    pub diagnostics: Vec<Diagnostic>,
    /// What became of each element, aligned with `Document::elements`.
    pub elements: Vec<ElementInfo>,
    /// Every declared quantity, model by model, in declaration order.
    pub quantities: Vec<QuantityInfo>,
    /// JSON pointer → the element whose content is there, for mapping the
    /// validator's findings back.
    paths: Vec<(String, usize)>,
    /// Each element's source, for the diagnostics [`check`] adds.
    sources: Vec<Option<SourceSpan>>,
}

/// What became of one element.
#[derive(Debug, Clone, Default, Serialize)]
pub struct ElementInfo {
    /// The model the element belongs to.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// Where its content is in the `.esm` document, as a JSON pointer.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    /// For a `plot`: the analysis that runs it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub analysis: Option<String>,
    /// For a `plot`: its id.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub plot: Option<String>,
}

/// How a quantity takes part in its model.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Role {
    /// A variable an equation's time derivative defines.
    State,
    /// A variable an algebraic equation defines.
    Observed,
    /// A variable no equation defines.
    Undefined,
    /// A parameter.
    Parameter,
}

/// One declared quantity, for a variables table.
#[derive(Debug, Clone, Serialize)]
pub struct QuantityInfo {
    /// Its model.
    pub model: String,
    /// Its name.
    pub name: String,
    /// How it takes part in the model.
    pub role: Role,
    /// Initial value or value.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub default: Option<f64>,
    /// Units.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub units: Option<String>,
    /// Prose description.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// The elements that declare it, first declaration first.
    pub elements: Vec<usize>,
}

/// Assemble a document. Never fails: problems are diagnostics, and whatever
/// could be assembled is in `esm`.
pub fn assemble(doc: &Document) -> Assembly {
    Assembler::new(doc).run()
}

/// Load and validate an assembly with the core, adding the core's findings to
/// its diagnostics. Returns the loaded file when it loads.
pub fn check(assembly: &mut Assembly) -> Option<EsmFile> {
    let (file, found) = match load_document(&assembly.esm) {
        Ok(file) => {
            let result = validate(&file);
            let mut found = Vec::new();
            for e in &result.schema_errors {
                found
                    .push(Diagnostic::error("schema", e.message.clone()).with_path(e.path.clone()));
            }
            for e in &result.structural_errors {
                found.push(
                    Diagnostic::error(e.code.to_string(), e.message.clone())
                        .with_path(e.path.clone()),
                );
                if matches!(e.code, StructuralErrorCode::UndefinedVariable) {
                    found.last_mut().unwrap().code = UNDECLARED.to_string();
                }
            }
            for w in &result.unit_warnings {
                found.push(
                    Diagnostic::warning(w.code.clone(), w.message.clone())
                        .with_path(w.path.clone()),
                );
            }
            (Some(file), found)
        }
        Err(e) => {
            // A load failure is usually a schema violation; `validate_text`
            // re-enumerates those one by one, with paths.
            let text = serde_json::to_string(&assembly.esm).expect("a Value always serializes");
            let result = earthsci_ast::validate_text(&text, None);
            let mut found: Vec<Diagnostic> = result
                .schema_errors
                .iter()
                .map(|s| Diagnostic::error("schema", s.message.clone()).with_path(s.path.clone()))
                .chain(result.structural_errors.iter().map(|s| {
                    Diagnostic::error(s.code.to_string(), s.message.clone())
                        .with_path(s.path.clone())
                }))
                .collect();
            if found.is_empty() {
                found.push(Diagnostic::error("load", e.to_string()));
            }
            (None, found)
        }
    };
    for mut d in found {
        let owner = d.path.as_deref().and_then(|p| assembly.owner_of(p));
        if let Some(index) = owner {
            // The assembler already explained an undeclared name on this
            // element, with a suggestion and the spot in the text.
            let explained = assembly
                .diagnostics
                .iter()
                .any(|a| a.element == Some(index) && a.code == d.code);
            if explained && d.code == UNDECLARED {
                continue;
            }
            d.element = Some(index);
            d.source = assembly.sources[index].clone();
        }
        assembly.diagnostics.push(d);
    }
    // Keep element order, so a front end can walk diagnostics alongside the
    // document; document-level findings go last.
    assembly
        .diagnostics
        .sort_by_key(|d| d.element.unwrap_or(usize::MAX));
    file
}

impl Assembly {
    /// Whether any diagnostic is an error.
    pub fn has_errors(&self) -> bool {
        self.diagnostics.iter().any(Diagnostic::is_error)
    }

    /// The source of the element at `index`.
    pub fn source_of(&self, index: usize) -> Option<SourceSpan> {
        self.sources.get(index).cloned().flatten()
    }

    /// The element whose content contains the JSON pointer `path`: the one
    /// recorded at the longest prefix of it.
    pub fn owner_of(&self, path: &str) -> Option<usize> {
        self.paths
            .iter()
            .filter(|(p, _)| {
                path == p || (path.starts_with(p.as_str()) && path[p.len()..].starts_with('/'))
            })
            .max_by_key(|(p, _)| p.len())
            .map(|&(_, i)| i)
    }
}

const UNDECLARED: &str = "undeclared_name";

/// One model being gathered.
struct ModelBuild {
    name: String,
    description: Option<(String, usize)>,
    /// The `model` elements that name it.
    elements: Vec<usize>,
    quantities: Vec<Quantity>,
    by_name: HashMap<String, usize>,
    equations: Vec<(usize, Expr, Expr, Option<String>)>,
    tests: Vec<(usize, ModelTest)>,
    analyses: Vec<(Option<usize>, ModelAnalysis)>,
    plots: Vec<(usize, PlotElement)>,
}

struct Quantity {
    name: String,
    param: bool,
    default: Option<(f64, usize)>,
    units: Option<(String, usize)>,
    description: Option<(String, usize)>,
    elements: Vec<usize>,
}

struct Assembler<'a> {
    doc: &'a Document,
    models: Vec<ModelBuild>,
    by_name: HashMap<String, usize>,
    diagnostics: Vec<Diagnostic>,
    info: Vec<ElementInfo>,
    paths: Vec<(String, usize)>,
    labels: BTreeMap<String, (String, usize)>,
    interactive: Map<String, Value>,
}

impl<'a> Assembler<'a> {
    fn new(doc: &'a Document) -> Self {
        Assembler {
            doc,
            models: Vec::new(),
            by_name: HashMap::new(),
            diagnostics: Vec::new(),
            info: vec![ElementInfo::default(); doc.elements.len()],
            paths: Vec::new(),
            labels: BTreeMap::new(),
            interactive: Map::new(),
        }
    }

    fn source(&self, index: usize) -> Option<&SourceSpan> {
        self.doc.elements[index].source.as_ref()
    }

    fn error(&mut self, index: usize, code: &str, message: String) -> &mut Diagnostic {
        let d = Diagnostic::error(code, message).at(index, self.source(index));
        self.diagnostics.push(d);
        self.diagnostics.last_mut().unwrap()
    }

    fn warning(&mut self, index: usize, code: &str, message: String) {
        let d = Diagnostic::warning(code, message).at(index, self.source(index));
        self.diagnostics.push(d);
    }

    /// Where the `index`th element was, for "first declared at …" notes.
    fn place(&self, index: usize) -> String {
        match self.source(index).map(|s| s.to_string()) {
            Some(s) if !s.is_empty() => s,
            _ => format!("element {index}"),
        }
    }

    fn run(mut self) -> Assembly {
        self.declare_models();
        self.gather();
        for m in 0..self.models.len() {
            self.check_equations(m);
            self.resolve_plots(m);
            self.check_ids(m);
        }
        let esm = self.emit();
        let quantities = self.quantity_infos();
        let mut diagnostics = self.diagnostics;
        diagnostics.sort_by_key(|d| d.element.unwrap_or(usize::MAX));
        Assembly {
            esm,
            diagnostics,
            elements: self.info,
            quantities,
            paths: self.paths,
            sources: self.doc.elements.iter().map(|e| e.source.clone()).collect(),
        }
    }

    /// Create a model for every `model` element, or the implicit one.
    fn declare_models(&mut self) {
        for (index, element) in self.doc.elements.iter().enumerate() {
            if let ElementKind::Model(m) = &element.kind {
                if !is_identifier(&m.name) {
                    self.error(
                        index,
                        "invalid_name",
                        format!(
                            "`{}` is not a valid model name; use letters, digits and underscores",
                            m.name
                        ),
                    );
                    continue;
                }
                let at = self.model_slot(&m.name);
                self.models[at].elements.push(index);
                if let Some(text) = &m.description {
                    match &self.models[at].description {
                        None => self.models[at].description = Some((text.clone(), index)),
                        Some((first, _)) if first == text => {}
                        Some((_, first)) => {
                            let first = self.place(*first);
                            self.error(
                                index,
                                "conflicting_declaration",
                                format!(
                                    "model `{}` already has a different description, at {first}",
                                    m.name
                                ),
                            );
                        }
                    }
                }
            }
        }
        if self.models.is_empty() {
            let name = self
                .doc
                .name
                .as_deref()
                .filter(|n| is_identifier(n))
                .unwrap_or(IMPLICIT_MODEL)
                .to_string();
            self.model_slot(&name);
        }
    }

    fn model_slot(&mut self, name: &str) -> usize {
        if let Some(&at) = self.by_name.get(name) {
            return at;
        }
        self.models.push(ModelBuild {
            name: name.to_string(),
            description: None,
            elements: Vec::new(),
            quantities: Vec::new(),
            by_name: HashMap::new(),
            equations: Vec::new(),
            tests: Vec::new(),
            analyses: Vec::new(),
            plots: Vec::new(),
        });
        self.by_name.insert(name.to_string(), self.models.len() - 1);
        self.models.len() - 1
    }

    /// Assign every element to its model and gather its content there.
    fn gather(&mut self) {
        let doc = self.doc;
        let mut current: Option<usize> = None;
        for (index, element) in doc.elements.iter().enumerate() {
            if element.is_placeholder() {
                continue;
            }
            let model = if let ElementKind::Model(m) = &element.kind {
                current = self.by_name.get(&m.name).copied();
                current
            } else if let Some(name) = &element.model {
                match self.by_name.get(name) {
                    Some(&at) => Some(at),
                    None => {
                        let known = self
                            .models
                            .iter()
                            .map(|m| m.name.as_str())
                            .collect::<Vec<_>>();
                        let hint = suggest(name, known.iter().copied())
                            .map(|s| format!("; did you mean `{s}`?"))
                            .unwrap_or_default();
                        self.error(
                            index,
                            "unknown_model",
                            format!("no model is named `{name}`{hint}"),
                        );
                        continue;
                    }
                }
            } else {
                Some(current.unwrap_or(0))
            };
            let Some(m) = model else { continue };
            self.info[index].model = Some(self.models[m].name.clone());
            match &element.kind {
                ElementKind::Model(_) => {
                    self.record(format!("/models/{}", pointer(&self.models[m].name)), index);
                }
                ElementKind::Var(q) => self.declare(m, index, q, false),
                ElementKind::Param(q) => self.declare(m, index, q, true),
                ElementKind::Eq(eq) => self.equation(m, index, eq),
                ElementKind::Test(t) => self.models[m].tests.push((index, t.clone())),
                ElementKind::Analysis(a) => self.models[m].analyses.push((Some(index), a.clone())),
                ElementKind::Plot(p) => self.models[m].plots.push((index, p.clone())),
            }
        }
    }

    fn record(&mut self, path: String, index: usize) {
        if !self.paths.iter().any(|(p, _)| *p == path) {
            self.paths.push((path.clone(), index));
        }
        if self.info[index].path.is_none() {
            self.info[index].path = Some(path);
        }
    }

    fn declare(&mut self, m: usize, index: usize, q: &QuantityElement, param: bool) {
        let what = if param { "param" } else { "var" };
        if q.name == TIME {
            self.error(
                index,
                "reserved_name",
                format!("`{TIME}` is the independent variable (time) and cannot be declared"),
            );
            return;
        }
        if !matches!(parse_expression(&q.name), Ok(Expr::Variable(ref v)) if *v == q.name) {
            self.error(
                index,
                "invalid_name",
                format!("`{}` is not a name the equation syntax can use", q.name),
            );
            return;
        }
        let model = &mut self.models[m];
        let at = match model.by_name.get(&q.name) {
            Some(&at) => at,
            None => {
                model.quantities.push(Quantity {
                    name: q.name.clone(),
                    param,
                    default: None,
                    units: None,
                    description: None,
                    elements: Vec::new(),
                });
                model
                    .by_name
                    .insert(q.name.clone(), model.quantities.len() - 1);
                model.quantities.len() - 1
            }
        };
        let first = model.quantities[at].elements.first().copied();
        if model.quantities[at].param != param {
            let other = if param { "var" } else { "param" };
            let first = self.place(first.unwrap());
            self.error(
                index,
                "conflicting_declaration",
                format!(
                    "`{}` is declared with `{other}` at {first}, so it cannot also be a `{what}`",
                    q.name
                ),
            );
            return;
        }
        let quantity = &mut self.models[m].quantities[at];
        quantity.elements.push(index);
        let mut conflicts = Vec::new();
        merge(
            &mut quantity.default,
            q.default,
            index,
            |a, b| a == b,
            "default",
            &mut conflicts,
        );
        merge(
            &mut quantity.units,
            q.units.clone(),
            index,
            |a, b| a == b,
            "units",
            &mut conflicts,
        );
        merge(
            &mut quantity.description,
            q.description.clone(),
            index,
            |a, b| a == b,
            "description",
            &mut conflicts,
        );
        let path = format!(
            "/models/{}/variables/{}",
            pointer(&self.models[m].name),
            pointer(&q.name)
        );
        self.record(path, index);
        for (field, first) in conflicts {
            let first = self.place(first);
            self.error(
                index,
                "conflicting_declaration",
                format!(
                    "`{}` already has a different {field}, set at {first}",
                    q.name
                ),
            );
        }
    }

    fn equation(&mut self, m: usize, index: usize, eq: &EqElement) {
        match parse_equation(&eq.text) {
            Ok(parsed) => {
                let model = &mut self.models[m];
                model
                    .equations
                    .push((index, parsed.lhs, parsed.rhs, eq.description.clone()));
                let path = format!(
                    "/models/{}/equations/{}",
                    pointer(&model.name),
                    model.equations.len() - 1
                );
                if let Some(label) = &eq.label {
                    if let Some((_, first)) = self.labels.get(label) {
                        let first = self.place(*first);
                        self.error(
                            index,
                            "duplicate_label",
                            format!("the label `{label}` is already used at {first}"),
                        );
                    } else {
                        self.labels.insert(label.clone(), (path.clone(), index));
                    }
                }
                self.record(path, index);
            }
            Err(e) => {
                let end = (e.pos + 1).min(eq.text.chars().count()).max(e.pos);
                self.error(
                    index,
                    "parse_error",
                    format!("cannot read the equation: {}", e.message),
                )
                .span = Some(crate::diagnostic::TextSpan { start: e.pos, end });
            }
        }
    }

    /// Names, definitions and uses in one model's equations.
    fn check_equations(&mut self, m: usize) {
        let mut defined: HashMap<String, Vec<(usize, bool)>> = HashMap::new();
        let mut used: HashSet<String> = HashSet::new();
        let equations = std::mem::take(&mut self.models[m].equations);
        for (index, lhs, rhs, _) in &equations {
            let text = match &self.doc.elements[*index].kind {
                ElementKind::Eq(eq) => eq.text.clone(),
                _ => unreachable!("only eq elements hold equations"),
            };
            match defined_by(lhs) {
                Some((name, derivative)) => {
                    defined.entry(name).or_default().push((*index, derivative));
                }
                None if matches!(lhs, Expr::Operator(n) if n.op == "D") => {
                    self.error(
                        *index,
                        "unsupported_equation",
                        "only a time derivative of one variable, `D(x, t)`, can stand on the left"
                            .to_string(),
                    );
                }
                None => {}
            }
            let mut names = Vec::new();
            collect_names(lhs, &mut names);
            collect_names(rhs, &mut names);
            let mut reported = HashSet::new();
            for name in names {
                used.insert(name.clone());
                if name == TIME || self.models[m].by_name.contains_key(&name) {
                    continue;
                }
                if !reported.insert(name.clone()) {
                    continue;
                }
                let model = &self.models[m];
                let candidates = model
                    .quantities
                    .iter()
                    .map(|q| q.name.as_str())
                    .chain(std::iter::once(TIME));
                let hint = match suggest(&name, candidates) {
                    Some(s) => format!("; did you mean `{s}`?"),
                    None => "; declare it with `var` or `param`".to_string(),
                };
                let message = format!("`{name}` is not declared in model `{}`{hint}", model.name);
                let span = find_name(&text, &name);
                let d = self.error(*index, UNDECLARED, message);
                if let Some((start, end)) = span {
                    d.span = Some(crate::diagnostic::TextSpan { start, end });
                }
            }
        }
        self.models[m].equations = equations;

        let model_name = self.models[m].name.clone();
        let quantities: Vec<(String, bool, bool, Vec<usize>)> = self.models[m]
            .quantities
            .iter()
            .map(|q| {
                (
                    q.name.clone(),
                    q.param,
                    q.default.is_some(),
                    q.elements.clone(),
                )
            })
            .collect();
        for (name, param, has_default, elements) in quantities {
            let first = elements[0];
            let defs = defined.get(&name).cloned().unwrap_or_default();
            if param {
                for &(eq, _) in &defs {
                    self.error(
                        eq,
                        "defines_parameter",
                        format!("`{name}` is a parameter, so no equation can define it; declare it with `var` instead"),
                    );
                }
                if !has_default {
                    self.warning(
                        first,
                        "missing_value",
                        format!("parameter `{name}` has no value; give it a `default`"),
                    );
                }
            } else {
                match defs.as_slice() {
                    [] => {
                        self.error(
                            first,
                            "no_equation",
                            format!(
                                "no equation defines `{name}` in model `{model_name}`; add one, or declare it with `param` if it is constant"
                            ),
                        );
                    }
                    [(_, derivative), rest @ ..] => {
                        for &(eq, _) in rest {
                            let first_eq = self.place(defs[0].0);
                            self.error(
                                eq,
                                "duplicate_definition",
                                format!(
                                    "`{name}` is already defined by the equation at {first_eq}"
                                ),
                            );
                        }
                        if *derivative && !has_default {
                            self.warning(
                                first,
                                "missing_initial_value",
                                format!("`{name}` has no initial value; give it a `default`"),
                            );
                        }
                    }
                }
            }
            if !used.contains(&name) {
                self.warning(
                    first,
                    "unused_declaration",
                    format!("`{name}` is declared but no equation uses it"),
                );
            }
        }
    }

    /// Attach each plot to its analysis, or make it one.
    fn resolve_plots(&mut self, m: usize) {
        let plots = std::mem::take(&mut self.models[m].plots);
        for (index, p) in plots {
            let ordinal = self.doc.elements[..=index]
                .iter()
                .filter(|e| matches!(e.kind, ElementKind::Plot(_)))
                .count();
            let id = p.id.clone().unwrap_or_else(|| format!("plot-{ordinal}"));
            self.info[index].plot = Some(id.clone());
            let plot_type = p.plot_type.clone().unwrap_or_else(|| "line".to_string());
            if !matches!(plot_type.as_str(), "line" | "scatter" | "heatmap") {
                let message = if plot_type.starts_with("field_") {
                    format!("`{plot_type}` plots are not supported yet")
                } else {
                    format!("unknown plot type `{plot_type}` (expected line, scatter or heatmap)")
                };
                self.error(index, "unsupported_plot", message);
                continue;
            }
            let plot = Plot {
                id: id.clone(),
                plot_type,
                description: p.description.clone(),
                x: p.x.as_ref().map(|x| x.to_axis()).unwrap_or(PlotAxis {
                    variable: TIME.to_string(),
                    label: None,
                }),
                y: match &p.y {
                    YSpec::One(axis) => PlotY::Axis(axis.to_axis()),
                    YSpec::Many(axes) => PlotY::Axes(axes.iter().map(|a| a.to_axis()).collect()),
                },
                value: p.value.clone(),
                series: p.series.clone(),
                at_time: None,
                pinned_coords: None,
                contours: None,
            };
            let own_run = p.time_span.is_some()
                || p.parameters.is_some()
                || p.initial_state.is_some()
                || p.parameter_sweep.is_some();
            let at = if let Some(analysis) = &p.analysis {
                if own_run {
                    self.error(
                        index,
                        "conflicting_plot_run",
                        format!(
                            "the plot draws analysis `{analysis}`, so it cannot also set `time_span`, `parameters`, `initial_state` or `parameter_sweep`"
                        ),
                    );
                    continue;
                }
                let model = &self.models[m];
                match model.analyses.iter().position(|(_, a)| a.id == *analysis) {
                    Some(at) => at,
                    None => {
                        let hint =
                            suggest(analysis, model.analyses.iter().map(|(_, a)| a.id.as_str()))
                                .map(|s| format!("; did you mean `{s}`?"))
                                .unwrap_or_default();
                        let message =
                            format!("model `{}` has no analysis `{analysis}`{hint}", model.name);
                        self.error(index, "unknown_analysis", message);
                        continue;
                    }
                }
            } else {
                let Some(time_span) = p.time_span.clone() else {
                    self.error(
                        index,
                        "missing_time_span",
                        "the plot needs a `time_span`, or an `analysis` to draw".to_string(),
                    );
                    continue;
                };
                self.models[m].analyses.push((
                    None,
                    ModelAnalysis {
                        id: id.clone(),
                        description: None,
                        initial_state: p.initial_state.clone(),
                        parameters: p.parameters.clone(),
                        time_span,
                        parameter_sweep: p.parameter_sweep.clone(),
                        plots: Some(Vec::new()),
                        expression_template_imports: Vec::new(),
                    },
                ));
                self.models[m].analyses.len() - 1
            };
            let analysis = &mut self.models[m].analyses[at].1;
            let plots = analysis.plots.get_or_insert_with(Vec::new);
            plots.push(plot);
            let plot_at = plots.len() - 1;
            self.info[index].analysis = Some(analysis.id.clone());
            let path = format!(
                "/models/{}/analyses/{at}/plots/{plot_at}",
                pointer(&self.models[m].name)
            );
            self.record(path.clone(), index);
            self.check_sliders(m, index, &p.interactive);
            if !p.interactive.is_empty() {
                self.interactive.insert(
                    path,
                    serde_json::to_value(&p.interactive).expect("sliders serialize"),
                );
            }
        }
    }

    fn check_sliders(&mut self, m: usize, index: usize, sliders: &[Slider]) {
        for s in sliders {
            let model = &self.models[m];
            let is_param = model
                .by_name
                .get(&s.parameter)
                .is_some_and(|&q| model.quantities[q].param);
            if !is_param {
                let message = format!(
                    "`{}` is not a parameter of model `{}`",
                    s.parameter, model.name
                );
                self.error(index, "unknown_parameter", message);
            }
            let log = match s.scale.as_deref() {
                None | Some("linear") => false,
                Some("log") => true,
                Some(other) => {
                    self.error(
                        index,
                        "invalid_slider",
                        format!("unknown slider scale `{other}` (expected linear or log)"),
                    );
                    continue;
                }
            };
            // `partial_cmp` so a NaN bound is rejected too.
            let ordered = s.min.partial_cmp(&s.max) == Some(std::cmp::Ordering::Less);
            if !ordered || (log && s.min <= 0.0) {
                self.error(
                    index,
                    "invalid_slider",
                    format!(
                        "the slider for `{}` needs min < max{}",
                        s.parameter,
                        if log {
                            ", both positive for a log scale"
                        } else {
                            ""
                        }
                    ),
                );
            }
        }
    }

    /// Test and analysis ids must be unique within a model.
    fn check_ids(&mut self, m: usize) {
        let mut seen: HashMap<String, usize> = HashMap::new();
        let tests: Vec<(usize, String)> = self.models[m]
            .tests
            .iter()
            .map(|(i, t)| (*i, t.id.clone()))
            .collect();
        for (index, id) in tests {
            if let Some(&first) = seen.get(&id) {
                let first = self.place(first);
                self.error(
                    index,
                    "duplicate_id",
                    format!("a test with id `{id}` is already at {first}"),
                );
            } else {
                seen.insert(id, index);
            }
        }
        let mut seen: HashMap<String, Option<usize>> = HashMap::new();
        let analyses: Vec<(Option<usize>, String)> = self.models[m]
            .analyses
            .iter()
            .map(|(i, a)| (*i, a.id.clone()))
            .collect();
        for (index, id) in analyses {
            match seen.get(&id) {
                Some(first) => {
                    let first = first
                        .map(|f| self.place(f))
                        .unwrap_or_else(|| "a plot".to_string());
                    let at = index.or_else(|| self.plot_element(m, &id)).unwrap_or(0);
                    self.error(
                        at,
                        "duplicate_id",
                        format!("an analysis with id `{id}` is already defined by {first}"),
                    );
                }
                None => {
                    seen.insert(id, index);
                }
            }
        }
    }

    /// The plot element that made the analysis `id`, for a plot's own run.
    fn plot_element(&self, m: usize, id: &str) -> Option<usize> {
        let name = &self.models[m].name;
        (0..self.info.len()).find(|&i| {
            self.info[i].model.as_deref() == Some(name.as_str())
                && self.info[i].analysis.as_deref() == Some(id)
                && self.info[i].plot.as_deref() == Some(id)
        })
    }

    /// Write the `.esm` document, recording where tests and analyses landed.
    fn emit(&mut self) -> Value {
        let mut models = Map::new();
        for m in 0..self.models.len() {
            let model = &self.models[m];
            let mut variables = Map::new();
            for q in &model.quantities {
                let mut v = Map::new();
                v.insert(
                    "type".into(),
                    json!(if q.param { "parameter" } else { "unknown" }),
                );
                if let Some((units, _)) = &q.units {
                    v.insert("units".into(), json!(units));
                }
                if let Some((default, _)) = q.default {
                    v.insert("default".into(), json!(default));
                }
                if let Some((description, _)) = &q.description {
                    v.insert("description".into(), json!(description));
                }
                variables.insert(q.name.clone(), Value::Object(v));
            }
            let equations: Vec<Value> = model
                .equations
                .iter()
                .map(|(_, lhs, rhs, comment)| {
                    let mut e = json!({"lhs": lhs, "rhs": rhs});
                    if let Some(c) = comment {
                        e["_comment"] = json!(c);
                    }
                    e
                })
                .collect();
            let mut body = Map::new();
            body.insert("variables".into(), Value::Object(variables));
            body.insert("equations".into(), Value::Array(equations));
            if !model.tests.is_empty() {
                let tests: Vec<&ModelTest> = model.tests.iter().map(|(_, t)| t).collect();
                body.insert(
                    "tests".into(),
                    serde_json::to_value(tests).expect("tests serialize"),
                );
            }
            if !model.analyses.is_empty() {
                let analyses: Vec<&ModelAnalysis> = model.analyses.iter().map(|(_, a)| a).collect();
                body.insert(
                    "analyses".into(),
                    serde_json::to_value(analyses).expect("analyses serialize"),
                );
            }
            models.insert(model.name.clone(), Value::Object(body));

            let base = format!("/models/{}", pointer(&model.name));
            let tests: Vec<usize> = model.tests.iter().map(|(i, _)| *i).collect();
            let analyses: Vec<Option<usize>> = model.analyses.iter().map(|(i, _)| *i).collect();
            for (at, index) in tests.into_iter().enumerate() {
                self.record(format!("{base}/tests/{at}"), index);
            }
            for (at, index) in analyses.into_iter().enumerate() {
                if let Some(index) = index {
                    self.record(format!("{base}/analyses/{at}"), index);
                }
            }
        }

        let mut metadata = Map::new();
        let name = self
            .doc
            .name
            .clone()
            .unwrap_or_else(|| self.models[0].name.clone());
        metadata.insert("name".into(), json!(name));
        let description = self
            .doc
            .description
            .clone()
            .or_else(|| match self.models.as_slice() {
                [only] => only.description.as_ref().map(|(d, _)| d.clone()),
                _ => None,
            });
        if let Some(d) = description {
            metadata.insert("description".into(), json!(d));
        }
        if !self.doc.authors.is_empty() {
            metadata.insert("authors".into(), json!(self.doc.authors));
        }
        metadata.insert("x_esd".into(), json!({"narrative": self.provenance()}));
        json!({
            "esm": SCHEMA_VERSION,
            "metadata": metadata,
            "models": models,
        })
    }

    /// `metadata.x_esd.narrative`: where each piece came from, equation
    /// labels, and the interactive controls, versioned with the element format.
    fn provenance(&self) -> Value {
        let mut sources: Vec<(usize, &String)> = self
            .paths
            .iter()
            .map(|(p, i)| (*i, p))
            .filter(|(i, _)| self.doc.elements[*i].source.is_some())
            .collect();
        sources.sort();
        let sources: Vec<Value> = sources
            .into_iter()
            .map(|(i, p)| json!({"path": p, "element": i, "source": self.doc.elements[i].source}))
            .collect();
        let labels: Map<String, Value> = self
            .labels
            .iter()
            .map(|(label, (path, _))| (label.clone(), json!(path)))
            .collect();
        // The schema gives a model no description field, so it is kept here.
        let models: Map<String, Value> = self
            .models
            .iter()
            .filter_map(|m| {
                let (d, _) = m.description.as_ref()?;
                Some((m.name.clone(), json!({"description": d})))
            })
            .collect();
        let mut out = Map::new();
        out.insert("version".into(), json!(FORMAT_VERSION));
        if !models.is_empty() {
            out.insert("models".into(), Value::Object(models));
        }
        if !sources.is_empty() {
            out.insert("sources".into(), Value::Array(sources));
        }
        if !labels.is_empty() {
            out.insert("labels".into(), Value::Object(labels));
        }
        if !self.interactive.is_empty() {
            out.insert(
                "interactive".into(),
                Value::Object(self.interactive.clone()),
            );
        }
        Value::Object(out)
    }

    fn quantity_infos(&self) -> Vec<QuantityInfo> {
        let mut out = Vec::new();
        for model in &self.models {
            let mut roles: HashMap<&str, Role> = HashMap::new();
            for (_, lhs, _, _) in &model.equations {
                if let Some((name, derivative)) = defined_by(lhs)
                    && let Some(&q) = model.by_name.get(&name)
                {
                    let role = if derivative {
                        Role::State
                    } else {
                        Role::Observed
                    };
                    roles
                        .entry(model.quantities[q].name.as_str())
                        .or_insert(role);
                }
            }
            for q in &model.quantities {
                out.push(QuantityInfo {
                    model: model.name.clone(),
                    name: q.name.clone(),
                    role: if q.param {
                        Role::Parameter
                    } else {
                        roles
                            .get(q.name.as_str())
                            .copied()
                            .unwrap_or(Role::Undefined)
                    },
                    default: q.default.map(|(v, _)| v),
                    units: q.units.as_ref().map(|(v, _)| v.clone()),
                    description: q.description.as_ref().map(|(v, _)| v.clone()),
                    elements: q.elements.clone(),
                });
            }
        }
        out
    }
}

/// Merge one attribute of a repeated declaration: the first value set wins,
/// and a later, different value is a conflict with the element that set it.
fn merge<T>(
    slot: &mut Option<(T, usize)>,
    value: Option<T>,
    index: usize,
    same: impl Fn(&T, &T) -> bool,
    field: &'static str,
    conflicts: &mut Vec<(&'static str, usize)>,
) {
    let Some(value) = value else { return };
    match slot {
        None => *slot = Some((value, index)),
        Some((first, at)) if !same(first, &value) => conflicts.push((field, *at)),
        Some(_) => {}
    }
}

/// The variable an equation's left-hand side defines, and whether through its
/// time derivative.
fn defined_by(lhs: &Expr) -> Option<(String, bool)> {
    match lhs {
        Expr::Variable(v) => Some((v.clone(), false)),
        Expr::Operator(node) if node.op == "D" => match (node.args.as_slice(), node.wrt.as_deref())
        {
            ([Expr::Variable(v)], None | Some(TIME)) => Some((v.clone(), true)),
            _ => None,
        },
        _ => None,
    }
}

/// Every variable name an expression reads, in order of appearance.
fn collect_names(expr: &Expr, out: &mut Vec<String>) {
    match expr {
        Expr::Variable(v) => {
            if !matches!(v.as_str(), "Infinity" | "-Infinity" | "NaN") {
                out.push(v.clone());
            }
        }
        Expr::Number(_) | Expr::Integer(_) => {}
        Expr::Operator(node) => {
            for a in &node.args {
                collect_names(a, out);
            }
            for e in [&node.lower, &node.upper, &node.expr, &node.filter]
                .into_iter()
                .flatten()
            {
                collect_names(e, out);
            }
            for v in node.values.iter().flatten() {
                collect_names(v, out);
            }
        }
    }
}

/// A plain identifier: a letter or underscore, then letters, digits and
/// underscores.
fn is_identifier(s: &str) -> bool {
    let mut chars = s.chars();
    matches!(chars.next(), Some(c) if c.is_alphabetic() || c == '_')
        && chars.all(|c| c.is_alphanumeric() || c == '_')
}

/// Escape one JSON-pointer reference token (RFC 6901).
fn pointer(token: &str) -> String {
    token.replace('~', "~0").replace('/', "~1")
}

fn is_name_char(c: char) -> bool {
    c.is_alphanumeric() || c == '_' || c == '.'
}

/// The character range of the first whole-word occurrence of `name` in
/// `text`.
fn find_name(text: &str, name: &str) -> Option<(usize, usize)> {
    let chars: Vec<char> = text.chars().collect();
    let target: Vec<char> = name.chars().collect();
    let n = target.len();
    (0..chars.len().saturating_sub(n - 1)).find_map(|i| {
        let whole = chars[i..i + n] == target[..]
            && (i == 0 || !is_name_char(chars[i - 1]))
            && (i + n == chars.len() || !is_name_char(chars[i + n]));
        whole.then_some((i, i + n))
    })
}

/// The closest candidate to a misspelled `name`, if one is close enough to be
/// a likely typo: a different case, or about one edit in three characters.
/// Every one-letter name is one edit from every other, so those match only by
/// case.
fn suggest<'s>(name: &str, candidates: impl Iterator<Item = &'s str>) -> Option<String> {
    let len = name.chars().count();
    let limit = (len / 3).max(1);
    candidates
        .map(|c| {
            let d = if c.to_lowercase() == name.to_lowercase() {
                0
            } else {
                edit_distance(name, c)
            };
            (d, c)
        })
        .filter(|&(d, _)| d <= limit && d < len)
        .min()
        .map(|(_, c)| c.to_string())
}

/// Levenshtein distance, in characters.
fn edit_distance(a: &str, b: &str) -> usize {
    let a: Vec<char> = a.chars().collect();
    let b: Vec<char> = b.chars().collect();
    let mut row: Vec<usize> = (0..=b.len()).collect();
    for i in 1..=a.len() {
        let mut prev = row[0];
        row[0] = i;
        for j in 1..=b.len() {
            let cost = usize::from(a[i - 1] != b[j - 1]);
            let next = (row[j] + 1).min(row[j - 1] + 1).min(prev + cost);
            prev = row[j];
            row[j] = next;
        }
    }
    row[b.len()]
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn doc(elements: Value) -> Document {
        let (doc, errors) =
            Document::from_value(json!({"version": 1, "elements": elements})).unwrap();
        assert!(errors.is_empty(), "{errors:?}");
        doc
    }

    fn codes(a: &Assembly) -> Vec<(Option<usize>, &str)> {
        a.diagnostics
            .iter()
            .map(|d| (d.element, d.code.as_str()))
            .collect()
    }

    #[test]
    fn decay_assembles_and_validates() {
        let d = doc(json!([
            {"kind": "model", "name": "Decay", "description": "First-order decay"},
            {"kind": "eq", "text": "D(N, t) = -lambda*N", "label": "eq-decay"},
            {"kind": "var", "name": "N", "default": 100, "units": "mol", "source": {"line": 4}},
            {"kind": "param", "name": "lambda", "default": 0.1, "units": "1/s"},
            {"kind": "var", "name": "N"},
            {"kind": "test", "id": "half", "time_span": {"start": 0, "end": 10},
             "assertions": [{"variable": "N", "time": 10, "expected": 36.79, "tolerance": {"rel": 1e-3}}]},
            {"kind": "plot", "time_span": {"start": 0, "end": 50}, "y": "N"}
        ]));
        let mut a = assemble(&d);
        let file = check(&mut a);
        assert!(
            file.is_some(),
            "{:?}\n{}",
            a.diagnostics,
            serde_json::to_string_pretty(&a.esm).unwrap()
        );
        assert!(a.diagnostics.is_empty(), "{:?}", a.diagnostics);
        assert_eq!(a.esm["metadata"]["description"], "First-order decay");
        let model = &a.esm["models"]["Decay"];
        assert_eq!(model["variables"]["N"]["type"], "unknown");
        assert_eq!(model["variables"]["N"]["default"], 100.0);
        assert_eq!(model["variables"]["lambda"]["type"], "parameter");
        assert_eq!(model["equations"][0]["lhs"]["op"], "D");
        assert_eq!(model["analyses"][0]["id"], "plot-1");
        assert_eq!(model["analyses"][0]["plots"][0]["x"]["variable"], "t");
        assert_eq!(
            a.elements[1].path.as_deref(),
            Some("/models/Decay/equations/0")
        );
        assert_eq!(
            a.elements[4].path.as_deref(),
            Some("/models/Decay/variables/N")
        );
        assert_eq!(a.elements[5].path.as_deref(), Some("/models/Decay/tests/0"));
        assert_eq!(
            a.elements[6].path.as_deref(),
            Some("/models/Decay/analyses/0/plots/0")
        );
        let narrative = &a.esm["metadata"]["x_esd"]["narrative"];
        assert_eq!(narrative["labels"]["eq-decay"], "/models/Decay/equations/0");
        assert_eq!(narrative["sources"][0]["element"], 2);
        let n = a.quantities.iter().find(|q| q.name == "N").unwrap();
        assert_eq!(n.role, Role::State);
        assert_eq!(n.elements, vec![2, 4]);
    }

    #[test]
    fn undeclared_names_point_at_the_text() {
        let d = doc(json!([
            {"kind": "var", "name": "N", "default": 1},
            {"kind": "param", "name": "lambda", "default": 0.1},
            {"kind": "eq", "text": "D(N) = -lamda*N"}
        ]));
        let mut a = assemble(&d);
        check(&mut a);
        let undeclared: Vec<_> = a
            .diagnostics
            .iter()
            .filter(|d| d.code == UNDECLARED)
            .collect();
        assert_eq!(undeclared.len(), 1, "{:?}", a.diagnostics);
        let d = undeclared[0];
        assert_eq!(d.element, Some(2));
        assert!(d.message.contains("did you mean `lambda`"), "{}", d.message);
        assert_eq!(d.span.map(|s| (s.start, s.end)), Some((8, 13)));
    }

    #[test]
    fn declarations_merge_and_conflict() {
        let d = doc(json!([
            {"kind": "var", "name": "N", "default": 1, "units": "mol"},
            {"kind": "var", "name": "N", "units": "mol"},
            {"kind": "var", "name": "N", "default": 2},
            {"kind": "param", "name": "N"},
            {"kind": "eq", "text": "D(N) = -N"}
        ]));
        let a = assemble(&d);
        assert_eq!(
            codes(&a),
            [
                (Some(2), "conflicting_declaration"),
                (Some(3), "conflicting_declaration")
            ]
        );
    }

    #[test]
    fn definition_checks() {
        let d = doc(json!([
            {"kind": "var", "name": "x", "default": 1},
            {"kind": "var", "name": "y"},
            {"kind": "var", "name": "z", "default": 0},
            {"kind": "var", "name": "w"},
            {"kind": "param", "name": "k"},
            {"kind": "eq", "text": "D(x) = -k*x"},
            {"kind": "eq", "text": "D(x) = -x"},
            {"kind": "eq", "text": "D(k) = 1"},
            {"kind": "eq", "text": "D(w) = x"},
            {"kind": "eq", "text": "z = x + y"}
        ]));
        let a = assemble(&d);
        assert_eq!(
            codes(&a),
            [
                (Some(1), "no_equation"),
                (Some(3), "missing_initial_value"),
                (Some(4), "missing_value"),
                (Some(6), "duplicate_definition"),
                (Some(7), "defines_parameter"),
            ]
        );
    }

    #[test]
    fn scoping_follows_model_elements() {
        let d = doc(json!([
            {"kind": "param", "name": "k", "default": 1},
            {"kind": "model", "name": "A"},
            {"kind": "var", "name": "x", "default": 1},
            {"kind": "eq", "text": "D(x) = -k*x"},
            {"kind": "model", "name": "B"},
            {"kind": "var", "name": "y", "default": 1},
            {"kind": "eq", "text": "D(y) = -y"},
            {"kind": "var", "name": "x", "model": "A"},
            {"kind": "var", "name": "q", "model": "C"}
        ]));
        let a = assemble(&d);
        let models: Vec<_> = a.elements.iter().map(|e| e.model.as_deref()).collect();
        assert_eq!(
            models,
            [
                Some("A"),
                Some("A"),
                Some("A"),
                Some("A"),
                Some("B"),
                Some("B"),
                Some("B"),
                Some("A"),
                None
            ]
        );
        assert_eq!(codes(&a), [(Some(8), "unknown_model")]);
        assert!(a.esm["models"]["A"]["variables"]["k"].is_object());
    }

    #[test]
    fn implicit_model_takes_the_document_name() {
        let (d, _) = Document::from_value(json!({
            "version": 1, "name": "Box",
            "elements": [{"kind": "var", "name": "x", "default": 1}, {"kind": "eq", "text": "D(x) = -x"}]
        }))
        .unwrap();
        let a = assemble(&d);
        assert!(a.esm["models"]["Box"].is_object());
        assert_eq!(a.esm["metadata"]["name"], "Box");
    }

    #[test]
    fn parse_errors_carry_a_span() {
        let d = doc(json!([{"kind": "eq", "text": "D(x) = -k*"}]));
        let a = assemble(&d);
        let d = &a.diagnostics[0];
        assert_eq!(d.code, "parse_error");
        assert!(d.span.is_some());
    }

    #[test]
    fn plots_join_named_analyses() {
        let d = doc(json!([
            {"kind": "var", "name": "x", "default": 1},
            {"kind": "param", "name": "k", "default": 1},
            {"kind": "eq", "text": "D(x) = -k*x"},
            {"kind": "plot", "id": "p", "analysis": "run", "y": "x"},
            {"kind": "analysis", "id": "run", "time_span": {"start": 0, "end": 1}},
            {"kind": "plot", "analysis": "runs", "y": "x"},
            {"kind": "plot", "analysis": "run", "y": "x", "time_span": {"start": 0, "end": 1}},
            {"kind": "plot", "y": "x"},
            {"kind": "plot", "id": "run", "y": "x", "time_span": {"start": 0, "end": 1},
             "interactive": [{"parameter": "k", "min": 0.1, "max": 10, "scale": "log"},
                             {"parameter": "x", "min": 1, "max": 0}]}
        ]));
        let mut a = assemble(&d);
        assert_eq!(
            codes(&a),
            [
                (Some(5), "unknown_analysis"),
                (Some(6), "conflicting_plot_run"),
                (Some(7), "missing_time_span"),
                (Some(8), "unknown_parameter"),
                (Some(8), "invalid_slider"),
                (Some(8), "duplicate_id"),
            ]
        );
        assert!(a.diagnostics[0].message.contains("did you mean `run`"));
        assert_eq!(
            a.esm["models"]["Model"]["analyses"][0]["plots"][0]["id"],
            "p"
        );
        assert_eq!(
            a.elements[3].path.as_deref(),
            Some("/models/Model/analyses/0/plots/0")
        );
        let interactive = &a.esm["metadata"]["x_esd"]["narrative"]["interactive"];
        assert!(interactive["/models/Model/analyses/1/plots/0"].is_array());
        check(&mut a);
    }

    #[test]
    fn validator_findings_map_to_elements() {
        let d = doc(json!([
            {"kind": "var", "name": "x", "default": 1},
            {"kind": "eq", "text": "D(x) = -x"},
            {"kind": "test", "id": "t", "time_span": {"start": 0, "end": 1},
             "assertions": [{"variable": "Q", "time": 1, "expected": 1}]}
        ]));
        let mut a = assemble(&d);
        check(&mut a);
        assert_eq!(a.diagnostics.len(), 1, "{:?}", a.diagnostics);
        assert_eq!(a.diagnostics[0].element, Some(2));
        assert_eq!(
            a.diagnostics[0].path.as_deref(),
            Some("/models/Model/tests/0/assertions/0/variable")
        );
    }

    #[test]
    fn helpers() {
        assert_eq!(edit_distance("lamda", "lambda"), 1);
        assert_eq!(
            suggest("lamda", ["N", "lambda"].into_iter()).as_deref(),
            Some("lambda")
        );
        assert_eq!(suggest("q", ["N", "lambda"].into_iter()), None);
        assert_eq!(
            suggest("n", ["N", "lambda"].into_iter()).as_deref(),
            Some("N")
        );
        assert_eq!(find_name("k1*k + k", "k"), Some((3, 4)));
        assert_eq!(find_name("x", "x"), Some((0, 1)));
        assert_eq!(find_name("xy", "x"), None);
        assert_eq!(pointer("a/b~c"), "a~1b~0c");
    }
}
