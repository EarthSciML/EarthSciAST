//! ESM documents as Markdown and Typst source text.
//!
//! An `.esm` document can be written as Markdown (LaTeX math, remark-directive
//! directives, YAML front matter and container bodies) or as Typst (Typst math,
//! `esm` package functions, Typst dictionaries). Both formats are lossless:
//! printing a document and reading it back gives the document again, and prose
//! between the constructs never changes what is read.
//!
//! The specification of both formats is the Lean model in `formal/`:
//! `formal/Esm/Document/Notation.lean` is the notation table, and this module
//! is a port of the executable definitions under `formal/Esm/Document/`, laid
//! out file by file:
//!
//! | Rust | Lean |
//! |---|---|
//! | [`json`] | `Json.lean` (the value type, canonical numbers) |
//! | [`number`] | `Number.lean` |
//! | [`strings`] | `Strings.lean` |
//! | [`yaml`] | `Yaml.lean` |
//! | [`typst_dict`] | `TypstDict.lean` |
//! | [`math`] | `Math/*.lean` |
//! | [`source`] | `Source/*.lean` |
//!
//! The Rust readers also bound what Lean leaves unbounded (nesting depth,
//! the number range); [`limits`] says how, and why each is Rust's own.
//!
//! The golden set every binding reproduces is
//! `tests/conformance/document_format/` (CONFORMANCE_SPEC §5.58).

pub(crate) mod json;
pub(crate) mod limits;
pub(crate) mod math;
pub(crate) mod number;
pub(crate) mod source;
pub(crate) mod strings;
pub(crate) mod typst_dict;
pub(crate) mod yaml;

use crate::canonicalize::canonicalize_document;
use crate::diagnostic::{DiagnosticError, codes};

/// Which source format a document is written in.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum DocumentFormat {
    /// Markdown with LaTeX math.
    Markdown,
    /// Typst.
    Typst,
}

/// The document value the printers take: `canonicalize_document` applied, then
/// every object's keys sorted, as the Lean printers require (`Source.canonDoc`).
fn printable(doc: &serde_json::Map<String, serde_json::Value>) -> json::Json {
    let canon = canonicalize_document(&serde_json::Value::Object(doc.clone()));
    json::sort_keys(&json::from_serde(&canon))
}

/// Print an ESM document as Markdown (`Source.Md.printMd`).
///
/// The document is put in canonical form first (`canonicalize_document`), so
/// two documents that canonicalize alike print alike, and
/// `parse_markdown(&print_markdown(d))` is `canonicalize_document(d)`.
pub fn print_markdown(doc: &serde_json::Map<String, serde_json::Value>) -> String {
    source::print_md(&printable(doc))
}

/// Print an ESM document as Typst (`Source.Typ.printTyp`). See
/// [`print_markdown`].
pub fn print_typst(doc: &serde_json::Map<String, serde_json::Value>) -> String {
    source::print_typ(&printable(doc))
}

/// Print an ESM document in the given format.
pub fn print_document(
    doc: &serde_json::Map<String, serde_json::Value>,
    format: DocumentFormat,
) -> String {
    match format {
        DocumentFormat::Markdown => print_markdown(doc),
        DocumentFormat::Typst => print_typst(doc),
    }
}

/// Print one expression, or one equation, as math under a set of declared
/// names: LaTeX for [`DocumentFormat::Markdown`] (`Math.printLatex`), Typst
/// math for [`DocumentFormat::Typst`] (`Math.printTypst`).
///
/// `expr` is an ESM expression (a number, a name or an operator node) or an
/// equation, an object with `lhs` and `rhs` (other fields, such as
/// `_comment`, are not printed), which prints as its two sides around `=` as
/// in a document (`Source.eqExpr`). `names` plays the part of
/// the variables a component declares: a name in it prints in its declared
/// shape, and the printer avoids spellings that would collide with it. The
/// result is what a document display holds, without its delimiters; it is
/// meant for showing one expression outside a document, so no template is in
/// scope.
pub fn print_math(expr: &serde_json::Value, names: &[String], format: DocumentFormat) -> String {
    let e = json::sort_keys(&json::from_serde(&canonicalize_document(expr)));
    let sides = match &e {
        json::Json::Obj(kvs) => math::expr::look("lhs", kvs).zip(math::expr::look("rhs", kvs)),
        _ => None,
    };
    let e = match sides {
        Some((lhs, rhs)) => json::Json::Obj(vec![
            (
                "args".to_string(),
                json::Json::Arr(vec![lhs.clone(), rhs.clone()]),
            ),
            ("op".to_string(), json::Json::Str("==".to_string())),
        ]),
        None => e,
    };
    let sym = math::Sym {
        names: names.to_vec(),
        templates: Vec::new(),
    };
    match format {
        DocumentFormat::Markdown => math::print_latex(&sym, &e),
        DocumentFormat::Typst => math::print_typst(&sym, &e),
    }
}

/// The variable names an expression or an equation uses, in order of first
/// use: its string leaves under `lhs`, `rhs` and `args`, and a reference's
/// `bindings` values. These are the
/// `names` to give [`print_math`] to show an expression on its own, with its
/// names declared.
pub fn expression_names(expr: &serde_json::Value) -> Vec<String> {
    fn walk(v: &serde_json::Value, out: &mut Vec<String>) {
        match v {
            serde_json::Value::String(name) if !out.contains(name) => out.push(name.clone()),
            serde_json::Value::Array(items) => items.iter().for_each(|i| walk(i, out)),
            serde_json::Value::Object(fields) => {
                for key in ["lhs", "rhs", "args"] {
                    if let Some(child) = fields.get(key) {
                        walk(child, out);
                    }
                }
                // A reference reads the names its bindings read (esm-spec
                // §9.6.4), in parameter order by name.
                if let Some(serde_json::Value::Object(b)) = fields.get("bindings") {
                    let mut keys: Vec<&String> = b.keys().collect();
                    keys.sort();
                    for k in keys {
                        walk(&b[k], out);
                    }
                }
            }
            _ => {}
        }
    }
    let mut out = Vec::new();
    walk(expr, &mut out);
    out
}

/// Why [`parse_math`] refused a text, and where in it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MathError {
    /// Stable cross-binding diagnostic code: `removed_op` or `parse_error`.
    pub code: &'static str,
    /// Human-readable description (binding-local prose).
    pub message: String,
    /// For text that is not math, the 0-based character offset in the text
    /// where reading went wrong: the first character no token of the math
    /// starts with, or the start of the furthest token the parser reached (the
    /// text's length in characters when the math ends too soon). `None` for a
    /// refusal of the text as a whole: a removed operator, or a bound of the
    /// reader.
    pub at: Option<usize>,
}

impl std::fmt::Display for MathError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "[{}] {}", self.code, self.message)?;
        if let Some(at) = self.at {
            write!(f, " (at character {at})")?;
        }
        Ok(())
    }
}

impl std::error::Error for MathError {}

/// Read one expression, or one equation, written as math under a set of
/// declared names: LaTeX for [`DocumentFormat::Markdown`] (`Math.parseLatex`),
/// Typst math for [`DocumentFormat::Typst`] (`Math.parseTypst`). The inverse
/// of [`print_math`]: `parse_math(&print_math(e, names, f), names, f)` is `e`
/// in canonical form.
///
/// `text` is what a document display holds, without its delimiters. Text
/// whose top is `=` reads as an equation, an object with `lhs` and `rhs`, as
/// a display does (`Source.eqSides`); any other text reads as an expression.
/// `names` plays the part of the variables a component declares: it decides
/// how a run of letters reads (in LaTeX, `RT` is the name `RT` when it is
/// declared, the product of `R` and `T` when they are). No template is in
/// scope.
///
/// # Errors
///
/// A [`MathError`] with code `removed_op` when the math uses an operator
/// removed from the format (spec §4.2), and `parse_error` for any other text
/// that is not math, with where in the text reading went wrong, and for one
/// past a bound of the Rust reader ([`limits`]): nested too deeply, or
/// holding a number beyond the binary64 range.
pub fn parse_math(
    text: &str,
    names: &[String],
    format: DocumentFormat,
) -> Result<serde_json::Value, MathError> {
    let sym = math::Sym {
        names: names.to_vec(),
        templates: Vec::new(),
    };
    let cs: Vec<char> = text.chars().collect();
    let (read, found) = limits::reading(|| {
        let (sf, lexed) = match format {
            DocumentFormat::Markdown => (math::token::Sf::Latex, math::latex::lex_at(&cs)),
            DocumentFormat::Typst => (math::token::Sf::Typst, math::typst::lex_at(&cs)),
        };
        let (toks, starts) = lexed?;
        limits::track(&toks);
        Ok((math::parse_toks(sf, &sym, &toks), starts))
    });
    let (e, at) = match read {
        Ok((e, starts)) => {
            let at = found
                .reach
                .map(|i| starts.get(i).copied().unwrap_or(cs.len()));
            (e, at)
        }
        Err(at) => (None, Some(at)),
    };
    let e = e.map(|e| match source::equation::split_eq(e) {
        Ok((lhs, rhs)) => json::Json::Obj(vec![("lhs".to_string(), lhs), ("rhs".to_string(), rhs)]),
        Err(e) => e,
    });
    if e.is_none() && found.removed_op.is_none() && !found.too_deep {
        return Err(MathError {
            code: codes::PARSE_ERROR,
            message: match format {
                DocumentFormat::Markdown => "not an ESM expression in LaTeX math".to_string(),
                DocumentFormat::Typst => "not an ESM expression in Typst math".to_string(),
            },
            at,
        });
    }
    checked(e, found, format).map_err(|d| MathError {
        code: d.code,
        message: d.message,
        at: None,
    })
}

/// Read a Markdown ESM document (`Source.Md.parseMd`). The result is in
/// canonical form.
///
/// # Errors
///
/// A [`DiagnosticError`] with code `removed_op` when the document's math uses
/// an operator removed from the format (spec §4.2), and `parse_error` for any
/// other text that is not a Markdown ESM document, and for one past a bound
/// of the Rust reader ([`limits`]): nested too deeply, or holding a number
/// beyond the binary64 range.
pub fn parse_markdown(text: &str) -> Result<serde_json::Value, DiagnosticError> {
    read(text, DocumentFormat::Markdown)
}

/// Read a Typst ESM document (`Source.Typ.parseTyp`). See [`parse_markdown`].
///
/// # Errors
///
/// As [`parse_markdown`].
pub fn parse_typst(text: &str) -> Result<serde_json::Value, DiagnosticError> {
    read(text, DocumentFormat::Typst)
}

/// Read an ESM document written in the given format.
///
/// # Errors
///
/// As [`parse_markdown`].
pub fn parse_document(
    text: &str,
    format: DocumentFormat,
) -> Result<serde_json::Value, DiagnosticError> {
    read(text, format)
}

/// One construct of a document's source text: where its content is in the
/// document the text reads as, and where the text writes it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ConstructSource {
    /// The JSON pointer of the construct's content: `/models/Decay` for a
    /// `::model[Decay]` directive, `/models/Decay/variables/N` for a
    /// declaration, `/models/Decay/equations/0` for an equation,
    /// `/models/Decay/analyses/0` for a plot, `/models/Decay/equations` for an
    /// ```` ```esm:equations ```` block.
    pub pointer: String,
    /// The byte range of the construct in the text.
    pub span: std::ops::Range<usize>,
}

/// Read an ESM document as [`parse_document`] does, with where each of its
/// constructs is: one [`ConstructSource`] per pointer, in the order the text
/// writes them. A construct that reads as several entries (a display holding
/// several equations, a container of initialization equations or
/// constraints, a table of declarations) gives one per entry, all with its
/// span. Prose, front matter and anything else that is not a construct of
/// the format gives none.
///
/// # Errors
///
/// As [`parse_markdown`].
pub fn parse_document_with_sources(
    text: &str,
    format: DocumentFormat,
) -> Result<(serde_json::Value, Vec<ConstructSource>), DiagnosticError> {
    let (read, found) = limits::reading(|| match format {
        DocumentFormat::Markdown => source::parse_md_sourced(text),
        DocumentFormat::Typst => source::parse_typ_sourced(text),
    });
    let (doc, spans) = match read {
        Some((d, s)) => (Some(d), s),
        None => (None, Vec::new()),
    };
    let doc = checked(doc, found, format)?;
    let spans = spans
        .into_iter()
        .map(|(pointer, span)| ConstructSource { pointer, span })
        .collect();
    Ok((doc, spans))
}

fn read(text: &str, format: DocumentFormat) -> Result<serde_json::Value, DiagnosticError> {
    let (doc, found) = limits::reading(|| match format {
        DocumentFormat::Markdown => source::parse_md(text),
        DocumentFormat::Typst => source::parse_typ(text),
    });
    checked(doc, found, format)
}

/// The document a read returned, as a `serde_json` value, or the refusal.
fn checked(
    doc: Option<json::Json>,
    found: limits::Findings,
    format: DocumentFormat,
) -> Result<serde_json::Value, DiagnosticError> {
    let too_deep = found.too_deep
        || doc
            .as_ref()
            .is_some_and(|d| limits::json_depth(d) > limits::MAX_JSON_DEPTH);
    if too_deep {
        return Err(DiagnosticError {
            code: codes::PARSE_ERROR,
            message: format!(
                "the document nests too deeply for the reader (at most {} constructs open at once, and {} levels of arrays and objects)",
                limits::MAX_NESTING,
                limits::MAX_JSON_DEPTH
            ),
        });
    }
    match doc {
        Some(d) => json::to_serde(&d).map_err(|n| DiagnosticError {
            code: codes::PARSE_ERROR,
            message: format!(
                "the number `{}` is outside the binary64 range",
                number::print(&n).into_iter().collect::<String>()
            ),
        }),
        None => Err(refusal(found.removed_op, format)),
    }
}

/// The diagnostic for a text the reader refused. The Lean reader refuses every
/// bad input alike; the code comes from the specification: a removed operator
/// the math writes in the call form or the escape form is refused by name
/// (CONFORMANCE §7.1), everything else is a parse error.
fn refusal(removed_op: Option<&str>, format: DocumentFormat) -> DiagnosticError {
    match removed_op {
        Some(op) => DiagnosticError {
            code: codes::REMOVED_OP,
            message: format!("`{op}` was removed from the format (esm-spec §4.2)"),
        },
        None => DiagnosticError {
            code: codes::PARSE_ERROR,
            message: match format {
                DocumentFormat::Markdown => "not an ESM Markdown document".to_string(),
                DocumentFormat::Typst => "not an ESM Typst document".to_string(),
            },
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MD_HEAD: &str = "---\nesm: \"2.3.0\"\nname: \"fixture\"\n---\n\n::model[M]\n\n:param[$k$]{}\n\n:var[$y$]{}\n\n";
    const TYP_HEAD: &str = "#import \"@preview/esm:0.1.0\": *\n#show: esm-document.with(esm: \"2.3.0\", name: \"fixture\")\n\n#model(\"M\")\n\n#param($k$)\n\n#var($y$)\n\n";

    fn md(body: &str) -> String {
        format!("{MD_HEAD}{body}")
    }

    fn typ(body: &str) -> String {
        format!("{TYP_HEAD}{body}")
    }

    fn code(r: Result<serde_json::Value, DiagnosticError>) -> (&'static str, String) {
        let e = r.expect_err("refused");
        (e.code, e.message)
    }

    fn math_code(r: Result<serde_json::Value, MathError>) -> (&'static str, String) {
        let e = r.expect_err("refused");
        (e.code, e.message)
    }

    #[test]
    fn parse_math_reads_an_expression_or_an_equation() {
        let names = vec!["RT".to_string(), "k".to_string(), "y".to_string()];
        let e = parse_math("RT + k", &names, DocumentFormat::Markdown).unwrap();
        assert_eq!(e, serde_json::json!({"op": "+", "args": ["RT", "k"]}));
        // With its letters declared instead, a run of letters in LaTeX is
        // their product; with neither, it is not read.
        let rt = vec!["R".to_string(), "T".to_string()];
        let e = parse_math("RT", &rt, DocumentFormat::Markdown).unwrap();
        assert_eq!(e, serde_json::json!({"op": "*", "args": ["R", "T"]}));
        assert!(parse_math("RT", &[], DocumentFormat::Markdown).is_err());
        let e = parse_math("y = 2 k", &names, DocumentFormat::Typst).unwrap();
        assert_eq!(
            e,
            serde_json::json!({"lhs": "y", "rhs": {"op": "*", "args": [2, "k"]}})
        );
        for (text, format) in [
            ("y = k", DocumentFormat::Markdown),
            ("(dif y)/(dif t) = -k y", DocumentFormat::Typst),
        ] {
            let e = parse_math(text, &names, format).unwrap();
            assert_eq!(print_math(&e, &names, format), text);
        }
    }

    #[test]
    fn parse_math_refuses_as_a_document_read_does() {
        let names = vec!["k".to_string()];
        let (c, _) = math_code(parse_math("k +", &names, DocumentFormat::Markdown));
        assert_eq!(c, codes::PARSE_ERROR);
        let (c, _) = math_code(parse_math("1.0e400 k", &names, DocumentFormat::Typst));
        assert_eq!(c, codes::PARSE_ERROR);
        let (c, m) = math_code(parse_math(
            "\\operatorname{arrayop}(k)",
            &names,
            DocumentFormat::Markdown,
        ));
        assert_eq!(c, codes::REMOVED_OP, "{m}");
        let deep = format!("{}k{}", "(".repeat(50_000), ")".repeat(50_000));
        let (c, _) = math_code(parse_math(&deep, &names, DocumentFormat::Typst));
        assert_eq!(c, codes::PARSE_ERROR);
    }

    #[test]
    fn parse_math_says_where_the_math_goes_wrong() {
        let names = vec!["k".to_string(), "y".to_string()];
        let at = |text: &str, format| parse_math(text, &names, format).unwrap_err().at;
        // A character no token starts with.
        assert_eq!(at("y = k ? 2", DocumentFormat::Typst), Some(6));
        assert_eq!(at("y = k \\@", DocumentFormat::Markdown), Some(6));
        assert_eq!(at("λ = k", DocumentFormat::Typst), Some(0));
        // The token the parser stops at.
        assert_eq!(at("y = k ) + 1", DocumentFormat::Typst), Some(6));
        assert_eq!(at("y = k ) + 1", DocumentFormat::Markdown), Some(6));
        // Math that ends too soon goes wrong at its end.
        assert_eq!(at("y = -k +", DocumentFormat::Typst), Some(8));
        assert_eq!(at("y = -k +", DocumentFormat::Markdown), Some(8));
        // A one-token index read on its own still counts in the whole text.
        assert_eq!(at("y_k = k )", DocumentFormat::Typst), Some(8));
        // A refusal of the whole text has no place.
        let e = parse_math(
            "\\operatorname{arrayop}(k)",
            &names,
            DocumentFormat::Markdown,
        );
        assert_eq!(e.unwrap_err().at, None);
    }

    #[test]
    fn a_number_beyond_binary64_is_refused_not_zeroed() {
        let (c, m) = code(parse_markdown(&md("$$\ny = 1.0e400 k\n$$\n")));
        assert_eq!(c, codes::PARSE_ERROR);
        assert!(m.contains("1.0e400") && m.contains("binary64"), "{m}");
        let (c, _) = code(parse_typst(&typ("$ y = 1.0e400 k $\n")));
        assert_eq!(c, codes::PARSE_ERROR);
        // An exponent past `u32` is not read as `10^0`.
        let (c, _) = code(parse_markdown(&md("$$\ny = 1.0e4294967296 k\n$$\n")));
        assert_eq!(c, codes::PARSE_ERROR);
        // Below the smallest subnormal: zero, as the JSON readers read it.
        let d = parse_markdown(&md("$$\ny = 1.0e-400 k\n$$\n")).unwrap();
        assert_eq!(
            d["models"]["M"]["equations"][0]["rhs"]["args"][0],
            serde_json::json!(0)
        );
    }

    #[test]
    fn deep_nesting_is_refused_without_exhausting_the_stack() {
        let n = 50_000;
        let deep = |open: &str, close: &str| {
            format!("$$\ny = {}k{}\n$$\n", open.repeat(n), close.repeat(n))
        };
        for text in [
            md(&deep("(", ")")),
            md(&deep("\\frac{", "}{k}")),
            md(&deep("-", "")),
            md(&deep("\\left(", "\\right)")),
            typ(&format!("$ y = {}k{} $\n", "(".repeat(n), ")".repeat(n))),
        ] {
            let format = if text.starts_with("---") {
                DocumentFormat::Markdown
            } else {
                DocumentFormat::Typst
            };
            let (c, m) = code(parse_document(&text, format));
            assert_eq!(c, codes::PARSE_ERROR);
            assert!(m.contains("nests too deeply"), "{m}");
        }
        // A chain that nests the value, not the reader.
        let chain = format!("$$\ny = k{}\n$$\n", " - k".repeat(n));
        let (_, m) = code(parse_markdown(&md(&chain)));
        assert!(m.contains("nests too deeply"), "{m}");
        // A deep YAML block and a deep flow collection.
        let mut yaml = String::from("```esm:metaparameters\nx:\n");
        for i in 1..2000 {
            yaml.push_str(&" ".repeat(2 * i));
            yaml.push_str("-\n");
        }
        yaml.push_str("```\n");
        let (_, m) = code(parse_markdown(&md(&yaml)));
        assert!(m.contains("nests too deeply"), "{m}");
        let flow = format!(
            ":var[$z$]{{default='{}1{}'}}\n",
            "[".repeat(n),
            "]".repeat(n)
        );
        let (_, m) = code(parse_markdown(&md(&flow)));
        assert!(m.contains("nests too deeply"), "{m}");
        // Ordinary nesting reads.
        let ok = format!("$$\ny = {}k{}\n$$\n", "(".repeat(20), ")".repeat(20));
        assert!(parse_markdown(&md(&ok)).is_ok());
    }

    #[test]
    fn the_deepest_nesting_read_fits_a_wasm_sized_stack() {
        // The Typst plugin runs on a 1 MiB stack. The deepest brackets and
        // fractions the reader accepts must read there, in an unoptimized
        // build whose frames are larger than the plugin's.
        let deepest = |open: &str, close: &str| {
            (1..)
                .map(|n| {
                    md(&format!(
                        "$$\ny = {}k{}\n$$\n",
                        open.repeat(n),
                        close.repeat(n)
                    ))
                })
                .take_while(|t| parse_markdown(t).is_ok())
                .last()
                .expect("one level reads")
        };
        let texts = [deepest("(", ")"), deepest("\\frac{", "}{k}")];
        std::thread::Builder::new()
            .stack_size(1 << 20)
            .spawn(move || {
                for t in &texts {
                    parse_markdown(t).unwrap();
                    print_markdown(parse_markdown(t).unwrap().as_object().unwrap());
                }
            })
            .unwrap()
            .join()
            .expect("read within 1 MiB of stack");
    }

    #[test]
    fn a_removed_operator_counts_only_in_math() {
        let removed = "$$\ny = \\operatorname{arrayop}(k)\n$$\n";
        assert_eq!(code(parse_markdown(&md(removed))).0, codes::REMOVED_OP);
        // Prose and code that mention one do not hide the real error.
        for prose in [
            "The old `\\operatorname{arrayop}` is gone.\n\n",
            "```\n\\esm{arrayop}{}{k}\n```\n\n",
            "Write \\operatorname{fn} no more.\n\n",
        ] {
            let text = md(&format!("{prose}$$\ny = k +\n$$\n"));
            assert_eq!(code(parse_markdown(&text)).0, codes::PARSE_ERROR, "{prose}");
        }
        let typ_removed = typ("$ y = op(\"fn\")(k) $\n");
        assert_eq!(code(parse_typst(&typ_removed)).0, codes::REMOVED_OP);
        // `stop("fn")` is not `op("fn")`, and prose is not math.
        for prose in ["Call stop(\"fn\") here.\n\n", "No more op(\"rank\").\n\n"] {
            let text = typ(&format!("{prose}$ y = k + $\n"));
            assert_eq!(code(parse_typst(&text)).0, codes::PARSE_ERROR, "{prose}");
        }
    }

    #[test]
    fn sources_point_at_what_each_construct_reads_as() {
        let text = md(concat!(
            "$$\n\\begin{aligned}y &= k \\\\\ny &= 2 k\\end{aligned}\n$$\n\n",
            "$$\ny = 3 k\n$$\n\n",
            "$$\n\\operatorname{loss}(r, v) \\coloneqq -r v\n$$\n",
        ));
        let (doc, found) = parse_document_with_sources(&text, DocumentFormat::Markdown).unwrap();
        assert_eq!(doc, parse_markdown(&text).unwrap());
        let at = |p: &str| {
            let s = found
                .iter()
                .find(|s| s.pointer == p)
                .unwrap_or_else(|| panic!("{p}"));
            &text[s.span.clone()]
        };
        assert!(at("/models/M").starts_with("::model[M]"));
        assert_eq!(at("/models/M/variables/k"), ":param[$k$]{}");
        assert!(at("/models/M/equations/0").contains("aligned"));
        assert_eq!(at("/models/M/equations/0"), at("/models/M/equations/1"));
        assert!(at("/models/M/equations/2").contains("3 k"));
        assert!(at("/models/M/operators/loss").contains("coloneqq"));
    }
}
