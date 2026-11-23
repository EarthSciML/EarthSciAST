//! Narrative pages: an `.esm` document written in the ESM Markdown format,
//! with narrative's own directives for tests, figures and tables, becomes a
//! page of ordinary Markdown with the mathematics, test results and figures
//! filled in.
//!
//! ```text
//! ---
//! esm: "2.2.0"
//! name: "decay"
//! title: "Decay"
//! ---
//!
//! ::model[Decay]
//!
//! Nitrogen :var[$N$]{default=100 units="mol"} decays at rate
//! :param[$\lambda$]{default=0.1 units="1/s"}:
//!
//! $$
//! \frac{\mathrm{d} N}{\mathrm{d} t} = -\lambda N
//! $$ {#eq-decay}
//!
//! :::esm-plot{#decay span="0..50" y=N}
//! description: Decay of N.
//! :::
//! ```
//!
//! The core reads the page (`earthsci_ast::parse_markdown`): everything that
//! is not a construct of the ESM Markdown format — prose, equation labels,
//! narrative's directives — is prose to it. Front matter keys the ESM
//! `metadata` does not define (`title`, `weight`, `show_source`, …) are the
//! site's, and are dropped from the document.
//!
//! Narrative's directives are the `esm-` namespace: `esm-test`,
//! `esm-analysis` and `esm-plot` add a test, an analysis or a figure to the
//! model in scope (the nearest `::model[…]` above), in the esm-spec §6.6 /
//! §6.7 shapes with a few shorthands; `esm-variables`, `esm-download` and
//! `esm-example` render from the whole build. Any other directive that is not
//! part of the ESM Markdown format is passed through exactly as written.
//!
//! [`scan`] finds where each construct is, [`parse`] reads the page,
//! [`build`] builds it, and [`render`] writes the output page.

// As in `scan`: the only error here is a `Diagnostic`, carried by value.
#![allow(clippy::result_large_err)]

pub mod render;
pub mod scan;

use std::collections::BTreeMap;

use earthsci_ast::{ConstructSource, DocumentFormat, SCHEMA_VERSION, parse_document_with_sources};
use serde_json::{Map, Value};

use crate::build::{BuildOptions, BuildOutput, build_onto, failed};
use crate::diagnostic::Diagnostic;
use crate::element::{FORMAT_VERSION, SourceSpan};
use scan::{Block, Directive, Display, Form, Piece};

pub use render::{RenderOptions, render};
pub use scan::scan;

/// A narrative Markdown page, ready to build.
#[derive(Debug, Clone)]
pub struct Page {
    /// The source file, as it names itself in diagnostics.
    pub file: String,
    /// The document's name when its front matter gives none.
    pub name: String,
    /// The page's YAML front matter, delimiters included.
    pub front_matter: String,
    /// The page in order.
    pub parts: Vec<Part>,
    /// The `.esm` document the page writes, as the core read it (with the
    /// site's front matter keys dropped), or `None` when the core refused the
    /// page.
    pub esm: Option<Value>,
    /// Narrative's own tests, analyses and figures, as elements, in page
    /// order.
    pub elements: Vec<Value>,
    /// Problems with the page itself: the core's refusal, and directives that
    /// could not be read.
    pub diagnostics: Vec<Diagnostic>,
}

/// A piece of the output page.
#[derive(Debug, Clone)]
pub enum Part {
    /// Markdown copied through unchanged.
    Text(String),
    /// A narrative directive that became the element at this index.
    Element(usize, Directive),
    /// A narrative directive the renderer answers from the whole build, such
    /// as `::esm-variables`.
    Whole(Directive),
    /// A directive that could not be read.
    Broken(Diagnostic),
    /// A construct of the ESM Markdown format: part of the document itself.
    Construct(Construct),
}

/// A construct of the ESM Markdown format, where the page has it.
#[derive(Debug, Clone)]
pub struct Construct {
    /// What was written.
    pub piece: ConstructPiece,
    /// Where its content is in the `.esm` document, as JSON pointers, as the
    /// core read the page: `/models/Decay/equations/0` for the first equation
    /// in model `Decay`. Most constructs have one; a display of several
    /// equations, or a container, has one for each entry it reads as; and a
    /// construct of a page the core refused has none. Diagnostics and results
    /// at or under one of them are shown here.
    pub paths: Vec<String>,
    /// The model the construct is in, if any.
    pub model: Option<String>,
}

/// The three spellings a construct can have.
#[derive(Debug, Clone)]
pub enum ConstructPiece {
    /// A directive: a component, a declaration, a subsystem, a plot, or a
    /// container of displays.
    Directive(Directive),
    /// A display equation or a reaction.
    Display(Display),
    /// An ```` ```esm:<key> ```` block.
    Block(Block),
}

impl Construct {
    /// Exactly what was written.
    pub fn raw(&self) -> &str {
        match &self.piece {
            ConstructPiece::Directive(d) => &d.raw,
            ConstructPiece::Display(d) => &d.raw,
            ConstructPiece::Block(b) => &b.raw,
        }
    }

    /// Where it was written.
    pub fn source(&self) -> &SourceSpan {
        match &self.piece {
            ConstructPiece::Directive(d) => &d.source,
            ConstructPiece::Display(d) => &d.source,
            ConstructPiece::Block(b) => &b.source,
        }
    }

    /// How it sits in the page: a declaration is inline, the rest own lines.
    pub fn form(&self) -> Form {
        match &self.piece {
            ConstructPiece::Directive(d) => d.form,
            _ => Form::Leaf,
        }
    }
}

impl Page {
    /// Narrative's own tests, analyses and figures, in the element format.
    #[doc(hidden)]
    pub fn document(&self) -> Value {
        serde_json::json!({
            "version": FORMAT_VERSION,
            "name": self.name,
            "elements": self.elements,
        })
    }

    /// The construct with a path that is the longest prefix of the JSON
    /// pointer `path`, as an index into [`Page::parts`]: where a diagnostic or
    /// a result at `path` is shown.
    pub fn owner_of(&self, path: &str) -> Option<usize> {
        let mut best: Option<(usize, usize)> = None;
        for (i, part) in self.parts.iter().enumerate() {
            let Part::Construct(c) = part else { continue };
            for p in &c.paths {
                let under =
                    path == p || (path.starts_with(p.as_str()) && path[p.len()..].starts_with('/'));
                if under && best.is_none_or(|(len, _)| p.len() > len) {
                    best = Some((p.len(), i));
                }
            }
        }
        best.map(|(_, i)| i)
    }
}

/// Build a page: the document the core read, with the page's own tests,
/// analyses and figures added, validated, tested and plotted.
///
/// A diagnostic about the document itself carries the source of the
/// construct it is shown at; the page's own problems are added at the end.
pub fn build(page: &Page, opts: &BuildOptions) -> BuildOutput {
    let mut out = match &page.esm {
        // A page that writes nothing but its front matter — a reference page
        // of examples, say — is not a model, so there is nothing to validate.
        Some(esm) if page.elements.is_empty() && !writes(esm) => {
            let mut out = failed(Diagnostic::error("not_built", "nothing to build"));
            out.diagnostics.clear();
            out.ok = true;
            out.esm = esm.clone();
            out
        }
        Some(esm) => build_onto(esm.clone(), page.document(), opts),
        None => {
            let mut out = failed(Diagnostic::error("not_built", "the page was not built"));
            out.diagnostics.clear();
            out
        }
    };
    for d in &mut out.diagnostics {
        if d.element.is_none()
            && d.source.is_none()
            && let Some(at) = d.path.as_deref().and_then(|p| page.owner_of(p))
            && let Part::Construct(c) = &page.parts[at]
        {
            d.source = Some(c.source().clone());
        }
    }
    out.diagnostics.extend(page.diagnostics.iter().cloned());
    out
}

/// Whether a document writes anything besides its format version and metadata.
pub fn writes(esm: &Value) -> bool {
    esm.as_object()
        .is_some_and(|doc| doc.keys().any(|k| k != "esm" && k != "metadata"))
}

/// The `metadata` fields of esm-spec; every other front matter key is the
/// site's.
const METADATA_KEYS: [&str; 12] = [
    "name",
    "description",
    "authors",
    "license",
    "created",
    "modified",
    "tags",
    "references",
    "system_class",
    "dae_info",
    "discretized_from",
    "x_esd",
];

/// The document a page writes, from what the core read: the site's front
/// matter keys dropped, and the format version and the name filled in when
/// the page leaves them out.
fn finish(mut esm: Value, name: &str) -> Value {
    if let Some(doc) = esm.as_object_mut() {
        doc.entry("esm")
            .or_insert_with(|| Value::String(SCHEMA_VERSION.to_string()));
        let metadata = doc
            .entry("metadata")
            .or_insert_with(|| Value::Object(Map::new()));
        if let Some(metadata) = metadata.as_object_mut() {
            metadata.retain(|k, _| METADATA_KEYS.contains(&k.as_str()));
            metadata
                .entry("name")
                .or_insert_with(|| Value::String(name.to_string()));
        }
    }
    esm
}

/// The component in scope while walking a page.
struct Scope {
    /// `models` or `reaction_systems`.
    field: &'static str,
    name: String,
}

/// Where the core found each construct of the page: for each line, the
/// constructs that start on it, in order, each with its JSON pointers. A
/// construct that owns its line is alone on it; inline declarations share a
/// line in the order they are written.
#[derive(Default)]
struct Sources(BTreeMap<u32, std::collections::VecDeque<Vec<String>>>);

impl Sources {
    /// The core's constructs of `text`, which is the page after `skip`
    /// lines the page does not have.
    fn new(text: &str, skip: usize, found: Vec<ConstructSource>) -> Sources {
        let mut by_line: BTreeMap<u32, std::collections::VecDeque<Vec<String>>> = BTreeMap::new();
        let mut last: Option<std::ops::Range<usize>> = None;
        for ConstructSource { pointer, span } in found {
            let before = &text[..span.start];
            let line = before.matches('\n').count() - skip + 1;
            let group = by_line.entry(line as u32).or_default();
            // The entries of one construct share its span, and come together.
            match group.back_mut() {
                Some(ps) if last.as_ref() == Some(&span) => ps.push(pointer),
                _ => group.push_back(vec![pointer]),
            }
            last = Some(span);
        }
        Sources(by_line)
    }

    /// The pointers of the next construct on `line`.
    fn take(&mut self, line: Option<u32>) -> Vec<String> {
        line.and_then(|l| self.0.get_mut(&l)?.pop_front())
            .unwrap_or_default()
    }
}

/// Read a Markdown page. `file` names it in diagnostics and `name` is the
/// document's name when its front matter gives none, usually the file's stem.
pub fn parse(source: &str, file: &str, name: &str) -> Page {
    let found = scan::scan(source, file);
    let mut page = Page {
        file: file.to_string(),
        name: name.to_string(),
        front_matter: found.front_matter,
        parts: Vec::new(),
        esm: None,
        elements: Vec::new(),
        diagnostics: found.diagnostics,
    };
    // The core reads a document from its front matter on; a page without
    // any is read as one that sets nothing but the format version.
    let prefix = if page.front_matter.is_empty() {
        format!("---\nesm: \"{SCHEMA_VERSION}\"\n---\n\n")
    } else {
        String::new()
    };
    let text = format!("{prefix}{source}");
    let mut sources = Sources::default();
    match parse_document_with_sources(&text, DocumentFormat::Markdown) {
        Ok((esm, found)) => {
            page.esm = Some(finish(esm, name));
            sources = Sources::new(&text, prefix.matches('\n').count(), found);
        }
        Err(e) => {
            let mut d = Diagnostic::error(
                e.code.to_string(),
                format!(
                    "the page is not an ESM Markdown document: {} (front matter is the format's YAML, every string double-quoted; equations are `$$` displays; declarations name their quantity in math, `:var[$N$]`)",
                    e.message
                ),
            );
            d.source = Some(SourceSpan {
                file: Some(file.to_string()),
                ..SourceSpan::default()
            });
            page.diagnostics.push(d);
        }
    }

    let mut scope: Option<Scope> = None;
    for piece in found.pieces {
        match piece {
            Piece::Text(text) => page.parts.push(Part::Text(text)),
            Piece::Display(d) => {
                let paths = sources.take(d.source.line);
                page.parts.push(Part::Construct(Construct {
                    piece: ConstructPiece::Display(d),
                    paths,
                    model: model_of(&scope),
                }));
            }
            Piece::Block(b) => {
                let paths = sources.take(b.source.line);
                page.parts.push(Part::Construct(Construct {
                    piece: ConstructPiece::Block(b),
                    paths,
                    model: model_of(&scope),
                }));
            }
            Piece::Directive(d) => directive(&mut page, &mut scope, &mut sources, d),
        }
    }
    page
}

fn model_of(scope: &Option<Scope>) -> Option<String> {
    scope
        .as_ref()
        .filter(|s| s.field == "models")
        .map(|s| s.name.clone())
}

/// A construct or narrative directive found in the page.
fn directive(page: &mut Page, scope: &mut Option<Scope>, sources: &mut Sources, d: Directive) {
    let bad = |message: String| {
        let mut e = Diagnostic::error("bad_directive", message);
        e.source = Some(d.source.clone());
        e
    };
    let construct = |sources: &mut Sources, scope: &Option<Scope>, d: Directive| {
        Part::Construct(Construct {
            paths: sources.take(d.source.line),
            piece: ConstructPiece::Directive(d),
            model: model_of(scope),
        })
    };
    match (d.name.as_str(), d.form) {
        ("model" | "reaction-system", Form::Leaf) => {
            if !d.attrs.is_empty() {
                page.diagnostics.push(bad(format!(
                    "`::{}[…]` takes no attributes; a description goes in an ```` ```esm:description ```` block after it",
                    d.name
                )));
            }
            let field = if d.name == "model" {
                "models"
            } else {
                "reaction_systems"
            };
            *scope = Some(Scope {
                field,
                name: d.content.clone(),
            });
            page.parts.push(construct(sources, scope, d));
        }
        ("var" | "param" | "species", Form::Inline) => {
            if !(d.content.starts_with('$') && d.content.ends_with('$') && d.content.len() > 1) {
                let e = bad(format!(
                    "a declaration names its quantity in math: `:{}[${}$]`, not `:{}[{}]`",
                    d.name, d.content, d.name, d.content
                ));
                page.diagnostics.push(e.clone());
                page.parts.push(Part::Broken(e));
                return;
            }
            page.parts.push(construct(sources, scope, d));
        }
        ("subsystem" | "plot", Form::Leaf)
        | ("initialization" | "constraints" | "template" | "rule", Form::Container) => {
            page.parts.push(construct(sources, scope, d));
        }
        ("eq", Form::Leaf) => {
            let e = bad(
                "`::eq[…]` is no longer read; write the equation as a display in LaTeX: a line `$$`, the equation (`\\frac{\\mathrm{d} N}{\\mathrm{d} t} = -\\lambda N`), and a line `$$`, with `{#label}` after it for an anchor"
                    .to_string(),
            );
            page.diagnostics.push(e.clone());
            page.parts.push(Part::Broken(e));
        }
        _ => match element_of(&d, model_of(scope)) {
            Ok(Some(element)) => {
                page.elements.push(element);
                page.parts.push(Part::Element(page.elements.len() - 1, d));
            }
            // A directive of ours that declares nothing, or one that belongs
            // to another tool.
            Ok(None) if OURS.contains(&d.name.as_str()) => page.parts.push(Part::Whole(d)),
            Ok(None) => page.parts.push(Part::Text(d.raw)),
            Err(e) => {
                page.diagnostics.push(e.clone());
                page.parts.push(Part::Broken(e));
            }
        },
    }
}

/// The directives this crate renders but that declare no element.
const OURS: [&str; 3] = ["esm-example", "esm-variables", "esm-download"];

/// The element a narrative directive declares, if it declares one, in
/// `model`.
fn element_of(d: &Directive, model: Option<String>) -> Result<Option<Value>, Diagnostic> {
    let bad = |message: String| {
        let mut e = Diagnostic::error("bad_directive", message);
        e.source = Some(d.source.clone());
        e
    };
    let kind = match d.name.as_str() {
        "esm-test" => "test",
        "esm-analysis" => "analysis",
        "esm-plot" => "plot",
        // Everything else in the `esm-` namespace is ours, so a misspelling is
        // a mistake rather than another tool's directive.
        name if OURS.contains(&name) => return Ok(None),
        name if name.starts_with("esm-") => {
            return Err(bad(format!(
                "unknown directive `{name}` (expected esm-test, esm-analysis, esm-plot, esm-example, esm-variables or esm-download)"
            )));
        }
        _ => return Ok(None),
    };

    // A test, an analysis or a plot is written in the esm-spec §6.6 / §6.7
    // shapes, as YAML, with the attributes as shorthand for its shortest
    // fields.
    let mut fields = body_fields(d, &bad)?;
    for (key, value) in &d.attrs {
        fields.insert(key.clone(), value.clone());
    }
    // `#id` is the element's id.
    if let Some(id) = fields.remove("#") {
        fields.insert("id".to_string(), id);
    }
    expand_shorthands(&mut fields, &bad)?;

    fields.insert("kind".to_string(), Value::String(kind.to_string()));
    if let Some(model) = model
        && !fields.contains_key("model")
    {
        fields.insert("model".to_string(), Value::String(model));
    }
    fields.insert(
        "source".to_string(),
        serde_json::to_value(&d.source).expect("a source span serializes"),
    );
    Ok(Some(Value::Object(fields)))
}

/// A container's YAML body as a JSON object.
fn body_fields(
    d: &Directive,
    bad: &impl Fn(String) -> Diagnostic,
) -> Result<Map<String, Value>, Diagnostic> {
    if d.body.trim().is_empty() {
        if d.form == Form::Container && d.attrs.is_empty() {
            return Err(bad(format!(
                "the `:::{}` directive is empty; give it a body or attributes",
                d.name
            )));
        }
        return Ok(Map::new());
    }
    match yaml_to_json(&d.body) {
        Ok(Value::Object(map)) => Ok(map),
        Ok(_) => Err(bad(format!(
            "the body of `:::{}` must be a YAML mapping of fields",
            d.name
        ))),
        Err(e) => Err(bad(format!("cannot read the body of `:::{}`: {e}", d.name))),
    }
}

fn yaml_to_json(body: &str) -> Result<Value, String> {
    serde_yaml_ng::from_str::<Value>(body).map_err(|e| e.to_string())
}

/// Rewrite the attribute shorthands into the fields they stand for.
fn expand_shorthands(
    fields: &mut Map<String, Value>,
    bad: &impl Fn(String) -> Diagnostic,
) -> Result<(), Diagnostic> {
    // `span="0..50"` is `time_span: {start: 0, end: 50}`.
    if let Some(span) = fields.remove("span") {
        let text = span.as_str().unwrap_or_default().to_string();
        let (start, end) = text
            .split_once("..")
            .ok_or_else(|| bad(format!("`span` is written `start..end`, not `{text}`")))?;
        let number = |s: &str| {
            s.trim()
                .parse::<f64>()
                .map_err(|_| bad(format!("`{s}` in `span` is not a number")))
        };
        fields.insert(
            "time_span".to_string(),
            serde_json::json!({"start": number(start)?, "end": number(end)?}),
        );
    }
    // `sliders="lambda=0.01..1 log, k=0..2"` is the `interactive` list.
    if let Some(sliders) = fields.remove("sliders") {
        let text = sliders.as_str().unwrap_or_default().to_string();
        let mut list = Vec::new();
        for one in text.split(',').filter(|s| !s.trim().is_empty()) {
            let (parameter, range) = one.trim().split_once('=').ok_or_else(|| {
                bad(format!(
                    "a slider is written `parameter=min..max [log]`, not `{}`",
                    one.trim()
                ))
            })?;
            let (range, scale) = match range.trim().split_once(char::is_whitespace) {
                Some((range, scale)) => (range, Some(scale.trim().to_string())),
                None => (range.trim(), None),
            };
            let (min, max) = range.split_once("..").ok_or_else(|| {
                bad(format!(
                    "the range of slider `{parameter}` is written `min..max`, not `{range}`"
                ))
            })?;
            let number = |s: &str| {
                s.trim().parse::<f64>().map_err(|_| {
                    bad(format!(
                        "`{s}` in the range of slider `{parameter}` is not a number"
                    ))
                })
            };
            let mut slider = serde_json::json!({
                "parameter": parameter.trim(),
                "min": number(min)?,
                "max": number(max)?,
            });
            if let Some(scale) = scale {
                slider["scale"] = Value::String(scale);
            }
            list.push(slider);
        }
        fields.insert("interactive".to_string(), Value::Array(list));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn page(source: &str) -> Page {
        let page = parse(source, "page.md", "Page");
        assert!(page.diagnostics.is_empty(), "{:?}", page.diagnostics);
        page
    }

    /// A page the core reads.
    fn page_ok(source: &str) -> Page {
        let page = page(source);
        assert!(page.esm.is_some());
        page
    }

    const DECAY: &str = r#"---
esm: "2.2.0"
title: "Decay"
---

::model[Decay]

Nitrogen :var[$N$]{default=100 units="mol"} decays at rate :param[$\lambda$]{default=0.1}.

$$
\frac{\mathrm{d} N}{\mathrm{d} t} = -\lambda N
$$ {#eq-decay}

:::esm-test{#half-life span="0..10"}
assertions:
  - variable: N
    time: 6.931471805599453
    expected: 50
    tolerance: {rel: 0.001}
:::
"#;

    #[test]
    fn the_core_reads_the_document() {
        let page = page(DECAY);
        let esm = page.esm.as_ref().unwrap();
        assert_eq!(esm["esm"], "2.2.0");
        // The site's front matter keys are not the document's.
        assert_eq!(esm["metadata"], serde_json::json!({"name": "Page"}));
        let model = &esm["models"]["Decay"];
        assert_eq!(model["variables"]["N"]["default"], 100);
        assert_eq!(model["variables"]["lambda"]["type"], "parameter");
        assert_eq!(model["equations"][0]["lhs"]["op"], "D");
    }

    #[test]
    fn constructs_know_where_their_content_is() {
        let page = page(DECAY);
        let paths: Vec<_> = page
            .parts
            .iter()
            .filter_map(|p| match p {
                Part::Construct(c) => Some(c.paths.clone()),
                _ => None,
            })
            .flatten()
            .collect();
        assert_eq!(
            paths,
            [
                "/models/Decay",
                "/models/Decay/variables/N",
                "/models/Decay/variables/lambda",
                "/models/Decay/equations/0",
            ]
        );
        assert_eq!(
            page.owner_of("/models/Decay/equations/0/rhs"),
            page.owner_of("/models/Decay/equations/0")
        );
        assert!(page.owner_of("/models/Other").is_none());
    }

    /// The paths of the page's constructs, by the first line of each.
    fn paths_of(page: &Page) -> Vec<(String, Vec<String>)> {
        page.parts
            .iter()
            .filter_map(|p| match p {
                Part::Construct(c) => Some((c.raw().to_string(), c.paths.clone())),
                _ => None,
            })
            .collect()
    }

    fn paths_at<'a>(paths: &'a [(String, Vec<String>)], first: &str) -> &'a [String] {
        &paths
            .iter()
            .find(|(l, _)| l.starts_with(first))
            .unwrap_or_else(|| panic!("no construct starting {first}: {paths:?}"))
            .1
    }

    const BOX_HEAD: &str = "---\nesm: \"2.3.0\"\n---\n\n::model[Box]\n\n:var[$c$]{default=0} and :param[$u$]{default=1}.\n\n";

    #[test]
    fn paths_follow_the_core_through_a_display_of_several_equations() {
        let page = page(&format!(
            "{BOX_HEAD}$$\n\\begin{{aligned}}c &= u \\\\\nc &= 2 u\\end{{aligned}}\n$$\n\n$$\n\\frac{{\\mathrm{{d}} c}}{{\\mathrm{{d}} t}} = -u c\n$$\n"
        ));
        let paths = paths_of(&page);
        assert_eq!(
            paths_at(&paths, "$$\n\\begin").to_vec(),
            ["/models/Box/equations/0", "/models/Box/equations/1"]
        );
        assert_eq!(
            paths_at(&paths, "$$\n\\frac").to_vec(),
            ["/models/Box/equations/2"]
        );
        // The two declarations on one line, in order.
        assert_eq!(
            paths_at(&paths, ":var").to_vec(),
            ["/models/Box/variables/c"]
        );
        assert_eq!(
            paths_at(&paths, ":param").to_vec(),
            ["/models/Box/variables/u"]
        );
    }

    #[test]
    fn a_plot_never_takes_the_place_of_an_analyses_block() {
        let text = format!(
            "{BOX_HEAD}```esm:analyses\n- id: \"run\"\n  time_span:\n    end: 10\n    start: 0\n```\n\n::plot{{id=\"p\" time_span='{{end: 5, start: 0}}'}}\n"
        );
        let page = parse(&text, "page.md", "Page");
        // The core does not read a field from both a block and entries.
        assert!(page.esm.is_none());
        let paths = paths_of(&page);
        assert!(
            !paths.iter().any(|(l, ps)| l.starts_with("::plot")
                && ps.contains(&"/models/Box/analyses/0".to_string())),
            "{paths:?}"
        );
        // A plot alone is the model's first analysis.
        let page = page_ok(&format!(
            "{BOX_HEAD}::plot{{id=\"p\" time_span='{{end: 5, start: 0}}'}}\n"
        ));
        assert_eq!(
            paths_at(&paths_of(&page), "::plot").to_vec(),
            ["/models/Box/analyses/0"]
        );
    }

    #[test]
    fn displays_never_take_the_place_of_an_equations_block() {
        let text = format!(
            "{BOX_HEAD}```esm:equations\n- lhs: \"c\"\n  rhs: \"u\"\n```\n\n$$\nc = 2 u\n$$\n"
        );
        let page = parse(&text, "page.md", "Page");
        // The core does not read a field from both a block and entries.
        assert!(page.esm.is_none());
        let paths = paths_of(&page);
        assert!(
            !paths.iter().any(|(l, ps)| l.starts_with("$$")
                && ps.contains(&"/models/Box/equations/0".to_string())),
            "{paths:?}"
        );
    }

    #[test]
    fn a_template_display_is_a_template_not_an_equation() {
        let page = page_ok(&format!(
            "{BOX_HEAD}$$\n\\operatorname{{loss}}(r, v) \\coloneqq -r v\n$$\n\n$$\nc = \\operatorname{{loss}}(u, c)\n$$\n"
        ));
        let paths = paths_of(&page);
        assert_eq!(
            paths_at(&paths, "$$\n\\operatorname{loss}(r").to_vec(),
            ["/models/Box/operators/loss"]
        );
        assert_eq!(
            paths_at(&paths, "$$\nc =").to_vec(),
            ["/models/Box/equations/0"]
        );
    }

    #[test]
    fn narrative_directives_become_elements_of_the_model_in_scope() {
        let page = page(DECAY);
        let found = &page.elements;
        assert_eq!(found.len(), 1);
        assert_eq!(found[0]["kind"], "test");
        assert_eq!(found[0]["model"], "Decay");
        assert_eq!(found[0]["id"], "half-life");
        assert_eq!(
            found[0]["time_span"],
            serde_json::json!({"start": 0.0, "end": 10.0})
        );
        assert_eq!(found[0]["assertions"][0]["expected"], 50.0);
        assert_eq!(found[0]["source"]["line"], 14);
    }

    #[test]
    fn sliders_and_spans() {
        let found =
            page("::esm-plot{#rates span=\"0..50\" y=N sliders=\"lambda=0.01..1 log, k=0..2\"}\n")
                .elements;
        assert_eq!(
            found[0]["interactive"],
            serde_json::json!([
                {"parameter": "lambda", "min": 0.01, "max": 1.0, "scale": "log"},
                {"parameter": "k", "min": 0.0, "max": 2.0},
            ])
        );
        assert_eq!(found[0]["time_span"]["end"], 50.0);
        assert_eq!(found[0]["y"], "N");
    }

    #[test]
    fn other_directives_pass_through() {
        let page = page(":::note\nCareful.\n:::\n");
        assert!(page.elements.is_empty());
        let Part::Text(text) = &page.parts[0] else {
            panic!("{:?}", page.parts)
        };
        assert_eq!(text, ":::note\nCareful.\n:::\n");
    }

    #[test]
    fn a_misspelled_esm_directive_is_an_error() {
        let page = parse("::esm-plt{y=N}\n", "page.md", "Page");
        assert_eq!(page.diagnostics.len(), 1);
        assert!(
            page.diagnostics[0].message.contains("unknown directive"),
            "{}",
            page.diagnostics[0].message
        );
    }

    #[test]
    fn a_bad_span_is_an_error() {
        let page = parse("::esm-plot{#p span=\"0-50\" y=N}\n", "page.md", "Page");
        assert!(
            page.diagnostics[0].message.contains("start..end"),
            "{}",
            page.diagnostics[0].message
        );
        assert_eq!(page.diagnostics[0].source.as_ref().unwrap().line, Some(1));
    }

    #[test]
    fn the_old_syntax_says_what_replaced_it() {
        let page = parse(
            "::model[Decay]\n\nAmount :var[N]{default=1}.\n\n::eq[D(N, t) = -N]{#eq}\n",
            "page.md",
            "Page",
        );
        // The core refuses the page, and each old directive says what to write.
        assert!(page.esm.is_none());
        let messages: Vec<&str> = page
            .diagnostics
            .iter()
            .map(|d| d.message.as_str())
            .collect();
        assert!(
            messages
                .iter()
                .any(|m| m.contains("not an ESM Markdown document")),
            "{messages:?}"
        );
        assert!(
            messages.iter().any(|m| m.contains("`:var[$N$]`")),
            "{messages:?}"
        );
        assert!(
            messages
                .iter()
                .any(|m| m.contains("`::eq[…]` is no longer read")),
            "{messages:?}"
        );
    }

    #[test]
    fn metadata_keys_are_the_schemas() {
        let schema: Value = serde_json::from_str(
            &std::fs::read_to_string(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../../esm-schema.json"
            ))
            .expect("the repository's schema"),
        )
        .unwrap();
        let mut keys: Vec<&str> = schema["$defs"]["Metadata"]["properties"]
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect();
        let mut ours = METADATA_KEYS.to_vec();
        keys.sort_unstable();
        ours.sort_unstable();
        assert_eq!(keys, ours);
    }
}
