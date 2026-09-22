//! The element format: what a front end extracts from a narrative document.
//!
//! A front end (the Typst package, the Markdown preprocessor) walks its
//! document and emits one [`Element`] per model construct it finds — a model
//! heading, a variable or parameter mentioned in prose, an equation, a test, an
//! analysis, a figure — in document order, each with the [`SourceSpan`] it came
//! from. The whole list is a [`Document`], serialized as JSON:
//!
//! ```json
//! {
//!   "version": 1,
//!   "elements": [
//!     {"kind": "model", "name": "Decay"},
//!     {"kind": "var", "name": "N", "default": 100, "units": "mol"},
//!     {"kind": "param", "name": "lambda", "default": 0.1, "units": "1/s"},
//!     {"kind": "eq", "text": "D(N, t) = -lambda*N", "label": "eq-decay"},
//!     {"kind": "plot", "time_span": {"start": 0, "end": 50}, "y": "N"}
//!   ]
//! }
//! ```
//!
//! This is the contract with both front ends, so it is versioned
//! ([`FORMAT_VERSION`]) and strict: an unknown field is an error on the element
//! that carries it, not silently dropped. Tests and analyses use the
//! esm-spec §6.6 / §6.7 shapes unchanged; only `plot`, which bundles a run
//! configuration with one figure, has shapes of its own.
//!
//! Every element may carry two fields besides its own:
//!
//! - `source`: where the element came from, echoed on its diagnostics.
//! - `model`: the model the element belongs to. Without it, an element
//!   belongs to the model named by the nearest `model` element before it, or,
//!   before the first one, to the first model in the document. A document with
//!   no `model` element has one implicit model.

use std::fmt;

use earthsci_ast::{
    ModelAnalysis, ModelTest, ParameterSweep, PlotAxis, PlotSeries, PlotValue, TimeSpan,
};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

/// The element-format version this crate reads and writes.
pub const FORMAT_VERSION: u32 = 1;

/// A narrative document's model content, as a front end extracted it.
#[derive(Debug, Clone, Serialize)]
pub struct Document {
    /// Always [`FORMAT_VERSION`].
    pub version: u32,
    /// The assembled file's `metadata.name`; defaults to the first model's name.
    pub name: Option<String>,
    /// The assembled file's `metadata.description`.
    pub description: Option<String>,
    /// The assembled file's `metadata.authors`.
    pub authors: Vec<String>,
    /// The elements, in document order.
    pub elements: Vec<Element>,
}

/// One model construct found in a narrative document.
#[derive(Debug, Clone, Serialize)]
pub struct Element {
    /// What the element declares.
    #[serde(flatten)]
    pub kind: ElementKind,
    /// The model the element names explicitly, overriding document scope.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// Where the element came from.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<SourceSpan>,
}

/// The element kinds, tagged by `kind` in JSON.
// A document holds tens of elements, so the size of the largest variant
// (a test) costs nothing worth boxing it for.
#[allow(clippy::large_enum_variant)]
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ElementKind {
    /// Starts a model; the elements after it belong to it.
    Model(ModelElement),
    /// A state or observed variable (an esm `unknown`).
    Var(QuantityElement),
    /// A parameter.
    Param(QuantityElement),
    /// An equation in the text syntax.
    Eq(EqElement),
    /// An esm-spec §6.6 inline test.
    Test(ModelTest),
    /// An esm-spec §6.7 analysis.
    Analysis(ModelAnalysis),
    /// A figure: one plot, with either its own run configuration or a
    /// reference to an `analysis` element.
    Plot(PlotElement),
}

impl ElementKind {
    /// The `kind` tag.
    pub fn name(&self) -> &'static str {
        match self {
            ElementKind::Model(_) => "model",
            ElementKind::Var(_) => "var",
            ElementKind::Param(_) => "param",
            ElementKind::Eq(_) => "eq",
            ElementKind::Test(_) => "test",
            ElementKind::Analysis(_) => "analysis",
            ElementKind::Plot(_) => "plot",
        }
    }
}

/// Where an element came from. Every field is optional because front ends know
/// different things: a Markdown preprocessor knows lines and columns, while a
/// Typst document knows only labels.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SourceSpan {
    /// The source file, as the front end names it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file: Option<String>,
    /// 1-based first line.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line: Option<u32>,
    /// 1-based first column, in characters.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub column: Option<u32>,
    /// 1-based last line.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub end_line: Option<u32>,
    /// 1-based column just past the element, in characters.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub end_column: Option<u32>,
    /// A document label near the element (a Typst `<label>`, a Markdown `#id`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
}

impl fmt::Display for SourceSpan {
    /// `file:line:column`, with whatever parts are known, or `<label>`.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let mut parts = Vec::new();
        if let Some(file) = &self.file {
            parts.push(file.clone());
        }
        if let Some(line) = self.line {
            parts.push(line.to_string());
            if let Some(column) = self.column {
                parts.push(column.to_string());
            }
        }
        if parts.is_empty()
            && let Some(label) = &self.label
        {
            return write!(f, "<{label}>");
        }
        write!(f, "{}", parts.join(":"))
    }
}

/// A `model` element.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ModelElement {
    /// The model's name, its key under `models`.
    pub name: String,
    /// The model's `description`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

/// A `var` or `param` element.
///
/// The same name may be declared more than once, as prose mentions a quantity
/// again: the declarations merge, and only a conflicting value is an error.
/// A mention that sets nothing is just a reference.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct QuantityElement {
    /// The variable's name, as the equations spell it.
    pub name: String,
    /// Initial value (`var`) or value (`param`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default: Option<f64>,
    /// Units, in the esm unit syntax.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub units: Option<String>,
    /// What the quantity is, in prose.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

/// An `eq` element.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EqElement {
    /// The equation in the text syntax, e.g. `D(N, t) = -lambda*N`.
    pub text: String,
    /// A label for cross-references, e.g. `eq-decay`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    /// A note on the equation, kept as its esm `_comment`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

/// A `plot` element: one figure.
///
/// A plot either names an `analysis` element, and joins its `plots`, or
/// carries its own run configuration (`time_span`, and optionally
/// `parameters`, `initial_state` and `parameter_sweep`), from which the
/// assembler makes a one-plot analysis with the plot's id.
///
/// `x` and `y` take the §6.7 axis objects, or a bare variable name as
/// shorthand (`"y": "N"`, `"y": ["A", "B"]`). `x` defaults to time, `t`, and
/// `type` to `line`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PlotElement {
    /// The plot's id; generated from its position when absent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    /// The `analysis` element whose run this plot draws.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub analysis: Option<String>,
    /// `line` (default), `scatter` or `heatmap`.
    #[serde(rename = "type", default, skip_serializing_if = "Option::is_none")]
    pub plot_type: Option<String>,
    /// The caption, kept as the plot's `description`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// The x axis; defaults to `t`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub x: Option<AxisSpec>,
    /// The y axis, or several for a multi-series plot.
    pub y: YSpec,
    /// A heatmap's color channel.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value: Option<PlotValue>,
    /// Named series of a multi-series plot.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub series: Option<Vec<PlotSeries>>,
    /// Own run: the simulated interval.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub time_span: Option<TimeSpan>,
    /// Own run: parameter overrides.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parameters: Option<std::collections::HashMap<String, f64>>,
    /// Own run: initial-state overrides.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub initial_state: Option<Value>,
    /// Own run: a Cartesian parameter sweep.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parameter_sweep: Option<ParameterSweep>,
    /// Parameters a reader may vary in an interactive figure.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub interactive: Vec<Slider>,
}

/// One plot axis: a §6.7 axis object, or a bare variable name.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum AxisSpec {
    /// `"N"`.
    Name(String),
    /// `{"variable": "N", "label": "..."}`.
    Axis(PlotAxis),
}

impl AxisSpec {
    /// The §6.7 axis object.
    pub fn to_axis(&self) -> PlotAxis {
        match self {
            AxisSpec::Name(variable) => PlotAxis {
                variable: variable.clone(),
                label: None,
            },
            AxisSpec::Axis(axis) => axis.clone(),
        }
    }
}

/// A plot's `y`: one axis or several.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum YSpec {
    /// A single axis.
    One(AxisSpec),
    /// Several axes, one series each.
    Many(Vec<AxisSpec>),
}

/// A parameter a reader may vary in an interactive figure.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Slider {
    /// The parameter, as the equations spell it.
    pub parameter: String,
    /// Smallest value.
    pub min: f64,
    /// Largest value.
    pub max: f64,
    /// `linear` (default) or `log`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scale: Option<String>,
}

/// A document that could not be read at all. Problems confined to one element
/// are not errors here: they become diagnostics on that element when the
/// document is assembled.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReadError(pub String);

impl fmt::Display for ReadError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for ReadError {}

/// An element that failed to parse, kept in place so indices stay aligned
/// with the front end's list.
#[derive(Debug, Clone, PartialEq)]
pub struct ElementError {
    /// The element's index.
    pub index: usize,
    /// Its `kind`, when it had a readable one.
    pub kind: Option<String>,
    /// Its `source`, when that was readable.
    pub source: Option<SourceSpan>,
    /// What was wrong.
    pub message: String,
}

impl Document {
    /// Read a document from JSON.
    ///
    /// The document itself must be well formed. Each element is read on its
    /// own: an element that fails to parse is returned in the second list,
    /// with its index, rather than failing the whole document, so a front end
    /// can show the problem next to the element that has it.
    pub fn from_json(text: &str) -> Result<(Document, Vec<ElementError>), ReadError> {
        let value: Value =
            serde_json::from_str(text).map_err(|e| ReadError(format!("not JSON: {e}")))?;
        Document::from_value(value)
    }

    /// [`Document::from_json`] for an already-parsed value.
    pub fn from_value(value: Value) -> Result<(Document, Vec<ElementError>), ReadError> {
        let Value::Object(mut top) = value else {
            return Err(ReadError("a document must be a JSON object".to_string()));
        };
        let version = match top.remove("version") {
            Some(Value::Number(n)) if n.as_u64() == Some(u64::from(FORMAT_VERSION)) => {
                FORMAT_VERSION
            }
            Some(other) => {
                return Err(ReadError(format!(
                    "unsupported element-format version {other}; this build reads version {FORMAT_VERSION}"
                )));
            }
            None => return Err(ReadError("the document has no `version`".to_string())),
        };
        let name = take_string(&mut top, "name")?;
        let description = take_string(&mut top, "description")?;
        let authors = match top.remove("authors") {
            None | Some(Value::Null) => Vec::new(),
            Some(v) => {
                serde_json::from_value(v).map_err(|e| ReadError(format!("`authors`: {e}")))?
            }
        };
        let raw_elements = match top.remove("elements") {
            Some(Value::Array(items)) => items,
            Some(_) => return Err(ReadError("`elements` must be an array".to_string())),
            None => return Err(ReadError("the document has no `elements`".to_string())),
        };
        if let Some(key) = top.keys().next() {
            return Err(ReadError(format!("unknown document field `{key}`")));
        }

        let mut elements = Vec::with_capacity(raw_elements.len());
        let mut errors = Vec::new();
        for (index, raw) in raw_elements.into_iter().enumerate() {
            match Element::from_value(raw) {
                Ok(element) => elements.push(Some(element)),
                Err(mut error) => {
                    error.index = index;
                    errors.push(error);
                    elements.push(None);
                }
            }
        }
        // A failed element stays in the list as an inert placeholder, so the
        // indices diagnostics use are the front end's own.
        let elements = elements
            .into_iter()
            .map(|e| e.unwrap_or_else(Element::placeholder))
            .collect();
        Ok((
            Document {
                version,
                name,
                description,
                authors,
                elements,
            },
            errors,
        ))
    }
}

impl<'de> Deserialize<'de> for Document {
    /// Strict: any element that fails to parse fails the document. Use
    /// [`Document::from_value`] to keep going past bad elements.
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let value = Value::deserialize(d)?;
        let (doc, errors) = Document::from_value(value).map_err(serde::de::Error::custom)?;
        if let Some(e) = errors.first() {
            return Err(serde::de::Error::custom(format!(
                "element {}: {}",
                e.index, e.message
            )));
        }
        Ok(doc)
    }
}

impl Element {
    /// Read one element from its JSON object.
    #[allow(clippy::result_large_err)]
    fn from_value(value: Value) -> Result<Element, ElementError> {
        let fail =
            |kind: Option<String>, source: Option<SourceSpan>, message: String| ElementError {
                index: 0,
                kind,
                source,
                message,
            };
        let Value::Object(mut fields) = value else {
            return Err(fail(
                None,
                None,
                "an element must be a JSON object".to_string(),
            ));
        };
        // `source` first, so every later error can carry it.
        let source = match fields.remove("source") {
            None | Some(Value::Null) => None,
            Some(v) => Some(
                serde_json::from_value::<SourceSpan>(v)
                    .map_err(|e| fail(None, None, format!("`source`: {e}")))?,
            ),
        };
        let kind = match fields.remove("kind") {
            Some(Value::String(s)) => s,
            Some(_) => return Err(fail(None, source, "`kind` must be a string".to_string())),
            None => return Err(fail(None, source, "the element has no `kind`".to_string())),
        };
        let model = match fields.remove("model") {
            None | Some(Value::Null) => None,
            Some(Value::String(s)) => Some(s),
            Some(_) => {
                return Err(fail(
                    Some(kind),
                    source,
                    "`model` must be a string".to_string(),
                ));
            }
        };
        let body = Value::Object(fields);
        let parsed = match kind.as_str() {
            "model" => serde_json::from_value(body).map(ElementKind::Model),
            "var" => serde_json::from_value(body).map(ElementKind::Var),
            "param" => serde_json::from_value(body).map(ElementKind::Param),
            "eq" => serde_json::from_value(body).map(ElementKind::Eq),
            "test" => serde_json::from_value(body).map(ElementKind::Test),
            "analysis" => serde_json::from_value(body).map(ElementKind::Analysis),
            "plot" => serde_json::from_value(body).map(ElementKind::Plot),
            other => {
                return Err(fail(
                    Some(kind.clone()),
                    source,
                    format!(
                        "unknown element kind `{other}` (expected model, var, param, eq, test, analysis or plot)"
                    ),
                ));
            }
        };
        match parsed {
            Ok(kind) => Ok(Element {
                kind,
                model,
                source,
            }),
            Err(e) => Err(fail(Some(kind.clone()), source, format!("{kind}: {e}"))),
        }
    }

    /// The inert stand-in for an element that failed to parse: a reference to
    /// no quantity, which assembles to nothing.
    fn placeholder() -> Element {
        Element {
            kind: ElementKind::Var(QuantityElement {
                name: String::new(),
                default: None,
                units: None,
                description: None,
            }),
            model: None,
            source: None,
        }
    }

    /// Whether this is the stand-in [`Document::from_value`] leaves for an
    /// element that failed to parse.
    pub fn is_placeholder(&self) -> bool {
        matches!(&self.kind, ElementKind::Var(q) if q.name.is_empty())
    }
}

fn take_string(map: &mut Map<String, Value>, key: &str) -> Result<Option<String>, ReadError> {
    match map.remove(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) => Ok(Some(s)),
        Some(_) => Err(ReadError(format!("`{key}` must be a string"))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn reads_every_kind() {
        let doc = json!({
            "version": 1,
            "name": "Decay",
            "elements": [
                {"kind": "model", "name": "Decay", "source": {"file": "a.md", "line": 3}},
                {"kind": "var", "name": "N", "default": 100, "units": "mol"},
                {"kind": "param", "name": "lambda", "default": 0.1},
                {"kind": "eq", "text": "D(N, t) = -lambda*N", "label": "eq-decay"},
                {"kind": "test", "id": "t1", "time_span": {"start": 0, "end": 1},
                 "assertions": [{"variable": "N", "time": 1, "expected": 90.5}]},
                {"kind": "analysis", "id": "a1", "time_span": {"start": 0, "end": 1}},
                {"kind": "plot", "time_span": {"start": 0, "end": 1}, "y": ["N", {"variable": "lambda"}],
                 "model": "Decay"}
            ]
        });
        let (doc, errors) = Document::from_value(doc).unwrap();
        assert!(errors.is_empty(), "{errors:?}");
        let kinds: Vec<_> = doc.elements.iter().map(|e| e.kind.name()).collect();
        assert_eq!(
            kinds,
            ["model", "var", "param", "eq", "test", "analysis", "plot"]
        );
        assert_eq!(
            doc.elements[0].source.as_ref().unwrap().to_string(),
            "a.md:3"
        );
        assert_eq!(doc.elements[6].model.as_deref(), Some("Decay"));
    }

    #[test]
    fn a_bad_element_keeps_its_index() {
        let doc = json!({
            "version": 1,
            "elements": [
                {"kind": "var", "name": "N"},
                {"kind": "var", "nme": "M", "source": {"line": 7}},
                {"kind": "eqn", "text": "x = 1"},
                {"kind": "param", "name": "k"}
            ]
        });
        let (doc, errors) = Document::from_value(doc).unwrap();
        assert_eq!(doc.elements.len(), 4);
        assert!(doc.elements[1].is_placeholder());
        assert_eq!(errors.len(), 2);
        assert_eq!(errors[0].index, 1);
        assert!(
            errors[0].message.contains("unknown field `nme`"),
            "{}",
            errors[0].message
        );
        assert_eq!(errors[0].source.as_ref().unwrap().line, Some(7));
        assert_eq!(errors[1].index, 2);
        assert!(errors[1].message.contains("unknown element kind `eqn`"));
    }

    #[test]
    fn rejects_other_versions() {
        let err = Document::from_value(json!({"version": 2, "elements": []})).unwrap_err();
        assert!(err.0.contains("version 2"), "{err}");
    }

    #[test]
    fn round_trips_through_serde() {
        let text = r#"{"version":1,"name":null,"description":null,"authors":[],"elements":[{"kind":"eq","text":"x = 1","source":{"label":"eq:x"}}]}"#;
        let doc: Document = serde_json::from_str(text).unwrap();
        assert_eq!(
            doc.elements[0].source.as_ref().unwrap().to_string(),
            "<eq:x>"
        );
        let json = serde_json::to_value(&doc).unwrap();
        let again: Document = serde_json::from_value(json.clone()).unwrap();
        assert_eq!(json, serde_json::to_value(&again).unwrap());
    }
}
