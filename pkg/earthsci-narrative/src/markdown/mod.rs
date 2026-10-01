//! The Markdown front end: a page of prose with directives in it becomes a
//! narrative [`Document`](crate::element::Document), and then a page of
//! ordinary Markdown with the mathematics, test results and figures filled in.
//!
//! ```text
//! Nitrogen :var[N]{default=100 units="mol"} decays at rate
//! :param[lambda]{default=0.1 units="1/s"}:
//!
//! ::eq[D(N, t) = -lambda*N]{#eq-decay}
//!
//! :::esm-plot{#decay span="0..50" y=N}
//! description: Decay of N.
//! :::
//! ```
//!
//! [`scan`] finds the directives, [`parse`] turns them into elements, and
//! [`render`] writes the output page from a [`BuildOutput`](crate::build::BuildOutput).
//! The directives this crate owns are the four model words — `model`, `var`,
//! `param` and `eq` — and the `esm-` namespace. Any other directive is passed
//! through exactly as written, so a page may use its own alongside these.

// As in `scan`: the only error here is a `Diagnostic`, carried by value.
#![allow(clippy::result_large_err)]

pub mod render;
pub mod scan;

use serde_json::{Map, Value};

use crate::diagnostic::Diagnostic;
use crate::element::FORMAT_VERSION;
use scan::{Directive, Form, Piece};

pub use render::{RenderOptions, render};
pub use scan::scan;

/// A narrative Markdown page, ready to build.
#[derive(Debug, Clone)]
pub struct Page {
    /// The source file, as it names itself in diagnostics.
    pub file: String,
    /// The document's name, and the default name of its one model.
    pub name: String,
    /// The page's YAML front matter, delimiters included.
    pub front_matter: String,
    /// The page in order.
    pub parts: Vec<Part>,
    /// The elements, in the order the document holds them.
    pub elements: Vec<Value>,
    /// Problems with the directives themselves.
    pub diagnostics: Vec<Diagnostic>,
}

/// A piece of the output page.
#[derive(Debug, Clone)]
pub enum Part {
    /// Markdown copied through unchanged.
    Text(String),
    /// A directive that became the element at this index.
    Element(usize, Directive),
    /// A directive the renderer answers from the whole build, such as
    /// `::esm-variables`.
    Whole(Directive),
    /// A directive that could not be read.
    Broken(Diagnostic),
}

impl Page {
    /// The narrative document this page defines.
    pub fn document(&self) -> Value {
        serde_json::json!({
            "version": FORMAT_VERSION,
            "name": self.name,
            "elements": self.elements,
        })
    }
}

/// Read a Markdown page. `file` names it in diagnostics and `name` is the
/// document's name, usually the file's stem.
pub fn parse(source: &str, file: &str, name: &str) -> Page {
    let found = scan::scan(source, file);
    let mut page = Page {
        file: file.to_string(),
        name: name.to_string(),
        front_matter: found.front_matter,
        parts: Vec::new(),
        elements: Vec::new(),
        diagnostics: found.diagnostics,
    };
    for piece in found.pieces {
        match piece {
            Piece::Text(text) => page.parts.push(Part::Text(text)),
            Piece::Directive(d) => match element_of(&d) {
                Ok(Some(element)) => {
                    page.elements.push(element);
                    page.parts.push(Part::Element(page.elements.len() - 1, d));
                }
                // A directive of ours that declares nothing, or one that
                // belongs to another tool.
                Ok(None) if OURS.contains(&d.name.as_str()) => page.parts.push(Part::Whole(d)),
                Ok(None) => page.parts.push(Part::Text(d.raw)),
                Err(e) => {
                    page.diagnostics.push(e.clone());
                    page.parts.push(Part::Broken(e));
                }
            },
        }
    }
    page
}

/// The directives this crate renders but that declare no element.
const OURS: [&str; 3] = ["esm-example", "esm-variables", "esm-download"];

/// The element a directive declares, if it declares one.
fn element_of(d: &Directive) -> Result<Option<Value>, Diagnostic> {
    let bad = |message: String| {
        let mut e = Diagnostic::error("bad_directive", message);
        e.source = Some(d.source.clone());
        e
    };
    let kind = match d.name.as_str() {
        "model" | "var" | "param" | "eq" => d.name.as_str(),
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

    let mut fields = match kind {
        // A test, an analysis or a plot is written in the esm-spec §6.6 / §6.7
        // shapes, as YAML, with the attributes as shorthand for its shortest
        // fields.
        "test" | "analysis" | "plot" => body_fields(d, &bad)?,
        _ => Map::new(),
    };
    for (key, value) in &d.attrs {
        fields.insert(key.clone(), value.clone());
    }
    // `#id` means whichever field identifies this kind of element.
    if let Some(id) = fields.remove("#") {
        fields.insert(
            match kind {
                "eq" => "label",
                "model" | "var" | "param" => "name",
                _ => "id",
            }
            .to_string(),
            id,
        );
    }
    if !d.content.is_empty() {
        let field = if kind == "eq" { "text" } else { "name" };
        fields.insert(field.to_string(), Value::String(d.content.clone()));
    }
    expand_shorthands(&mut fields, &bad)?;

    fields.insert("kind".to_string(), Value::String(kind.to_string()));
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

    fn elements(source: &str) -> Vec<Value> {
        let page = parse(source, "page.md", "Page");
        assert!(page.diagnostics.is_empty(), "{:?}", page.diagnostics);
        page.elements
    }

    #[test]
    fn directives_become_elements() {
        let found = elements(
            "\
::model[Decay]{description=\"First-order decay\"}

Nitrogen :var[N]{default=100 units=\"mol\"} decays at rate :param[lambda]{default=0.1}.

::eq[D(N, t) = -lambda*N]{#eq-decay}

:::esm-test{#half-life span=\"0..10\"}
assertions:
  - variable: N
    time: 6.931471805599453
    expected: 50
    tolerance: {rel: 0.001}
:::
",
        );
        assert_eq!(found[0]["kind"], "model");
        assert_eq!(found[0]["name"], "Decay");
        assert_eq!(found[0]["description"], "First-order decay");
        assert_eq!(found[1]["kind"], "var");
        assert_eq!(found[1]["name"], "N");
        assert_eq!(found[1]["default"], 100.0);
        assert_eq!(found[2]["name"], "lambda");
        assert_eq!(found[3]["kind"], "eq");
        assert_eq!(found[3]["text"], "D(N, t) = -lambda*N");
        assert_eq!(found[3]["label"], "eq-decay");
        assert_eq!(found[3]["source"]["line"], 5);
        assert_eq!(found[4]["kind"], "test");
        assert_eq!(found[4]["id"], "half-life");
        assert_eq!(
            found[4]["time_span"],
            serde_json::json!({"start": 0.0, "end": 10.0})
        );
        assert_eq!(found[4]["assertions"][0]["expected"], 50.0);
    }

    #[test]
    fn sliders_and_spans() {
        let found = elements(
            "::esm-plot{#rates span=\"0..50\" y=N sliders=\"lambda=0.01..1 log, k=0..2\"}\n",
        );
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
        let page = parse(":::note\nCareful.\n:::\n", "page.md", "Page");
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
}
