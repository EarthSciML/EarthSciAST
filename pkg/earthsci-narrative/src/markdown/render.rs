//! Writing the output page.
//!
//! Every construct and directive is replaced by what it stands for, and
//! everything else is copied through, so the result is ordinary Markdown:
//! KaTeX math in the `\(…\)` and `\[…\]` delimiters the docs site already
//! renders, a variables table, test results, and figures with their SVG
//! inline. Nothing here needs a Hugo shortcode, so the same output would serve
//! any Markdown site.
//!
//! The mathematics is the page's own: a declaration's name and a display's
//! LaTeX are already in the notation of the ESM Markdown format, which KaTeX
//! reads. What the page does not spell out — a variables table, an
//! `::esm-example` — is printed by the core (`earthsci_ast::print_math`).
//!
//! A page whose front matter sets `show_source: true` also shows how it was
//! written: each block of the source that holds a construct — a paragraph with
//! `:var[…]` in it, a `$$` display, an `:::esm-test` container — is printed as
//! a Markdown code block just before what it renders to. A tutorial wants this;
//! a paper written in the format does not, so it is off unless asked for.

use std::fmt::Write as _;

use earthsci_ast::{
    DocumentFormat, expression_names, parse_equation, parse_expression, print_math,
};
use serde_json::Value;

use crate::assemble::{QuantityInfo, Role};
use crate::build::{BuildOutput, ConstructOutput, ElementOutput, Figure, TestOutcome};
use crate::diagnostic::Diagnostic;
use crate::markdown::scan::{self, Directive, Display, Form, Piece};
use crate::markdown::{Construct, ConstructPiece, Page, Part};

/// How to write the output page.
#[derive(Debug, Clone, Default)]
pub struct RenderOptions {
    /// Where the built `.esm` file will be served, for `::esm-download`.
    pub esm_href: Option<String>,
    /// The `.esm` file's name, as the download link shows it.
    pub esm_name: String,
    /// A note placed after the front matter, saying the page is generated.
    pub generated_by: Option<String>,
}

/// Write the output page for a built narrative document.
pub fn render(page: &Page, out: &BuildOutput, opts: &RenderOptions) -> String {
    let mut md = String::new();
    md.push_str(&page.front_matter);
    if let Some(note) = &opts.generated_by {
        let _ = writeln!(md, "<!-- {note} -->\n");
    }

    // Diagnostics are shown where they belong, so the ones left over — the
    // document's own — go at the end where they cannot be missed.
    let mut shown = vec![false; out.diagnostics.len()];
    // A finding about the document itself is shown at the construct its path
    // is in; so are the results of the tests and analyses the document writes.
    let at_construct: Vec<Option<usize>> = out
        .diagnostics
        .iter()
        .map(|d| match d.element {
            None => d.path.as_deref().and_then(|p| page.owner_of(p)),
            Some(_) => None,
        })
        .collect();
    let result_at: Vec<Option<usize>> = out
        .constructs
        .iter()
        .map(|c| page.owner_of(&c.path))
        .collect();
    // The model the page is in the middle of, so that `::esm-variables`
    // tabulates that one, the way a test belongs to the model above it.
    let mut model: Option<&str> = None;
    let mut block = Block {
        show_source: shows_source(&page.front_matter),
        ..Block::default()
    };
    for (at, part) in page.parts.iter().enumerate() {
        match part {
            Part::Text(text) => block.text(&mut md, text),
            Part::Construct(c) => {
                if let Some(name) = c.model.as_deref() {
                    model = Some(name);
                }
                let mut problems = Vec::new();
                for ((d, seen), owner) in out
                    .diagnostics
                    .iter()
                    .zip(shown.iter_mut())
                    .zip(&at_construct)
                {
                    if *owner == Some(at) {
                        *seen = true;
                        problems.push(d.clone());
                    }
                }
                let results: Vec<&ConstructOutput> = out
                    .constructs
                    .iter()
                    .zip(&result_at)
                    .filter(|(_, owner)| **owner == Some(at))
                    .map(|(c, _)| c)
                    .collect();
                block.directive(
                    &mut md,
                    c.raw(),
                    &render_construct(c, &results, &problems),
                    c.form(),
                );
            }
            Part::Broken(d) => block.output(&problem_block(std::slice::from_ref(d))),
            Part::Whole(d) => block.directive(&mut md, &d.raw, &whole(d, out, opts, model), d.form),
            Part::Element(index, directive) => {
                let mut problems = Vec::new();
                for (d, seen) in out.diagnostics.iter().zip(shown.iter_mut()) {
                    if d.element == Some(*index) {
                        *seen = true;
                        problems.push(d.clone());
                    }
                }
                let element = out.elements.get(*index);
                block.directive(
                    &mut md,
                    &directive.raw,
                    &render_element(directive, element, &problems, page, *index),
                    directive.form,
                );
            }
        }
    }
    block.flush(&mut md);
    for (c, owner) in out.constructs.iter().zip(&result_at) {
        if owner.is_none() {
            md.push_str(&construct_results(c));
        }
    }
    let left: Vec<Diagnostic> = out
        .diagnostics
        .iter()
        .zip(&shown)
        .filter(|(_, seen)| !**seen)
        .map(|(d, _)| d.clone())
        .collect();
    if !left.is_empty() {
        md.push_str(&problem_block(&left));
    }
    md
}

/// The block of the page being written: the source it came from and what it
/// renders to, held until a blank line ends it so that, when the page shows
/// its source, the source of the whole block can go first.
#[derive(Default)]
struct Block {
    show_source: bool,
    source: String,
    rendered: String,
    has_directive: bool,
}

impl Block {
    /// Markdown copied through, which ends the block at each blank line.
    fn text(&mut self, md: &mut String, text: &str) {
        for line in text.split_inclusive('\n') {
            if line
                .trim_end_matches('\n')
                .trim_end_matches('\r')
                .trim()
                .is_empty()
            {
                self.flush(md);
                md.push_str(line);
            } else {
                self.output(line);
                self.source.push_str(line);
            }
        }
    }

    /// A directive, written as `raw`, and what it renders to.
    fn directive(&mut self, md: &mut String, raw: &str, rendered: &str, form: Form) {
        if form != Form::Inline {
            self.flush(md);
        }
        self.source.push_str(raw);
        self.output(rendered);
        self.has_directive = true;
        if form != Form::Inline {
            self.flush(md);
        }
    }

    /// Output with no source of its own.
    fn output(&mut self, rendered: &str) {
        self.rendered.push_str(rendered);
    }

    /// Write the block: its source first when the page shows it and the block
    /// holds a directive, then what it renders to.
    fn flush(&mut self, md: &mut String) {
        if self.show_source && self.has_directive {
            md.push_str(&source_block(self.source.trim_matches('\n')));
        }
        md.push_str(&self.rendered);
        self.source.clear();
        self.rendered.clear();
        self.has_directive = false;
    }
}

/// Whether the page's YAML front matter sets `show_source: true`.
fn shows_source(front_matter: &str) -> bool {
    let body = front_matter
        .trim()
        .strip_prefix("---")
        .and_then(|s| s.strip_suffix("---"))
        .unwrap_or("");
    serde_yaml_ng::from_str::<Value>(body)
        .ok()
        .and_then(|v| v.get("show_source").and_then(Value::as_bool))
        .unwrap_or(false)
}

/// Source shown as a fenced Markdown block, in a wrapper the site styles and
/// labels. The fence is longer than any run of backticks in the source, so a
/// code span or fence inside it cannot close it.
fn source_block(source: &str) -> String {
    let mut longest = 0;
    let mut run = 0;
    for c in source.chars() {
        run = if c == '`' { run + 1 } else { 0 };
        longest = longest.max(run);
    }
    let fence = "`".repeat((longest + 1).max(3));
    format!("<div class=\"esm-source\">\n\n{fence}markdown\n{source}\n{fence}\n\n</div>\n\n")
}

/// What a construct of the document renders to.
fn render_construct(
    c: &Construct,
    results: &[&ConstructOutput],
    problems: &[Diagnostic],
) -> String {
    let mut out = match &c.piece {
        ConstructPiece::Directive(d) => match d.name.as_str() {
            // A declaration shows its name, already in LaTeX.
            "var" | "param" | "species" => {
                let latex = d.content.trim_matches('$');
                format!("\\({latex}\\)")
            }
            "subsystem" => {
                let from = d
                    .attrs
                    .get("ref")
                    .and_then(Value::as_str)
                    .map(|r| format!(" from <code>{}</code>", escape(r)))
                    .unwrap_or_default();
                format!(
                    "<p class=\"esm-subsystem\">Subsystem <code>{}</code>{from}</p>\n\n",
                    escape(&d.content)
                )
            }
            // A container of displays: the displays.
            "initialization" | "constraints" | "template" | "rule" => {
                let mut inner = String::new();
                for piece in scan::scan(&d.body, "").pieces {
                    match piece {
                        Piece::Display(display) => inner.push_str(&display_block(&display)),
                        Piece::Text(text) => inner.push_str(&text),
                        _ => {}
                    }
                }
                format!(
                    "<div class=\"esm-{}\">\n\n{}\n</div>\n\n",
                    d.name,
                    inner.trim_matches('\n')
                )
            }
            // A component marker shows nothing: the prose around it says what
            // it is. A plot directive shows its figure, below.
            _ => String::new(),
        },
        ConstructPiece::Display(display) => display_block(display),
        ConstructPiece::Block(b) if b.key == "description" => format!(
            "<div class=\"esm-description\">\n\n{}\n</div>\n\n",
            b.body.trim_end()
        ),
        // Any other field of the document is shown as the YAML it is.
        ConstructPiece::Block(b) => format!("{}\n", b.raw),
    };
    for r in results {
        out.push_str(&construct_results(r));
    }
    if !problems.is_empty() {
        if c.form() == Form::Inline {
            out.push('\n');
        }
        out.push_str(&problem_block(problems));
    }
    out
}

/// A display equation, with its anchor, or a reaction.
fn display_block(d: &Display) -> String {
    let mut out = String::new();
    if let Some(label) = d.attrs.get("#").and_then(Value::as_str) {
        let _ = writeln!(out, "<a id=\"{}\" class=\"esm-eq\"></a>\n", escape(label));
    }
    if d.reaction {
        let _ = writeln!(out, "\\[{}\\]\n", d.latex);
    } else {
        let _ = writeln!(out, "\\[\n{}\n\\]\n", d.latex);
    }
    out
}

/// The result of a test or an analysis the document writes itself.
fn construct_results(c: &ConstructOutput) -> String {
    let mut out = String::new();
    if let Some(test) = &c.test {
        out.push_str(&test_block(test));
    }
    for figure in &c.figures {
        out.push_str(&figure_block(figure, None));
    }
    if c.skipped {
        out.push_str("<div class=\"esm-problem esm-problem--skipped\">Not run: the model this belongs to has errors.</div>\n\n");
    }
    out
}

fn render_element(
    d: &Directive,
    element: Option<&ElementOutput>,
    problems: &[Diagnostic],
    page: &Page,
    index: usize,
) -> String {
    let mut out = String::new();
    if let Some(element) = element {
        if let Some(test) = &element.test {
            out.push_str(&test_block(test));
        }
        let sliders = page.elements[index].get("interactive");
        for figure in &element.figures {
            out.push_str(&figure_block(figure, sliders));
        }
        if element.skipped {
            let _ = writeln!(
                out,
                "<div class=\"esm-problem esm-problem--skipped\">Not run: the model this {} belongs to has errors.</div>\n",
                element.kind
            );
        }
    }
    if !problems.is_empty() {
        // An inline directive is inside a sentence, so its problem block goes
        // on its own lines after it.
        if d.form == Form::Inline {
            out.push('\n');
        }
        out.push_str(&problem_block(problems));
    }
    out
}

/// `::esm-variables`, `::esm-download` and `::esm-example`.
fn whole(d: &Directive, out: &BuildOutput, opts: &RenderOptions, in_scope: Option<&str>) -> String {
    match d.name.as_str() {
        "esm-variables" => {
            // `{model=…}` names a model explicitly; `{model=all}` asks for
            // every one, which is what a page with a single model gets anyway.
            let model = match d.attrs.get("model").and_then(Value::as_str) {
                Some("all") => None,
                Some(name) => Some(name),
                None => in_scope,
            };
            variables_table(
                &out.quantities
                    .iter()
                    .filter(|q| model.is_none_or(|m| q.model == m))
                    .collect::<Vec<_>>(),
            )
        }
        "esm-download" => match &opts.esm_href {
            Some(href) => format!(
                "<p class=\"esm-download\"><a href=\"{}\" download>Download <code>{}</code></a></p>\n",
                escape(href),
                escape(&opts.esm_name)
            ),
            None => String::new(),
        },
        "esm-example" => example_block(&d.content),
        _ => String::new(),
    }
}

/// The table of everything the document declares, each name printed by the
/// core with its model's other names in scope.
fn variables_table(quantities: &[&QuantityInfo]) -> String {
    if quantities.is_empty() {
        return String::new();
    }
    let names_of = |model: &str| -> Vec<String> {
        quantities
            .iter()
            .filter(|q| q.model == model)
            .map(|q| q.name.clone())
            .collect()
    };
    let mut out = String::from("\n| Symbol | Role | Value | Units | Description |\n");
    out.push_str("| --- | --- | --- | --- | --- |\n");
    for q in quantities {
        let role = match q.role {
            Role::State => "state",
            Role::Observed => "observed",
            Role::Undefined => "undefined",
            Role::Parameter => "parameter",
        };
        let _ = writeln!(
            out,
            "| \\({}\\) | {role} | {} | {} | {} |",
            print_math(
                &Value::String(q.name.clone()),
                &names_of(&q.model),
                DocumentFormat::Markdown
            ),
            q.default.map(number).unwrap_or_default(),
            q.units.clone().map(cell).unwrap_or_default(),
            q.description.clone().map(cell).unwrap_or_default(),
        );
    }
    out.push('\n');
    out
}

/// One expression in each of its forms: as written in the text syntax, as the
/// mathematics the ESM Markdown format writes for it (the core's printer,
/// with the expression's own names declared), and as the JSON the format
/// stores. Parsing it here is what keeps a reference page from drifting away
/// from the parser.
fn example_block(text: &str) -> String {
    // An equation and a bare expression are different types, and each is
    // written to JSON the way an `.esm` file stores it.
    let parsed = if text.contains('=') {
        parse_equation(text)
            .map(|eq| serde_json::to_value(&eq))
            .map_err(|e| e.message)
    } else {
        parse_expression(text)
            .map(|expr| serde_json::to_value(&expr))
            .map_err(|e| e.message)
    };
    let parsed = parsed.map(|json| {
        let json = json.unwrap_or_default();
        let names = expression_names(&json);
        (
            print_math(&json, &names, DocumentFormat::Markdown),
            serde_json::to_string_pretty(&json).unwrap_or_default(),
        )
    });
    let (latex, json) = match parsed {
        Ok((latex, json)) => (latex, json),
        Err(message) => {
            return problem_block(&[Diagnostic::error(
                "parse_error",
                format!("`{text}` does not parse: {message}"),
            )]);
        }
    };
    format!(
        "<div class=\"esm-example\">\n\n```text\n{text}\n```\n\n\\[\n{latex}\n\\]\n\n<details class=\"esm-example__json\"><summary>As JSON</summary>\n\n```json\n{json}\n```\n\n</details>\n\n</div>\n"
    )
}

fn test_block(test: &TestOutcome) -> String {
    let (state, word) = if test.passed {
        ("pass", "passed")
    } else {
        ("fail", "failed")
    };
    let mut out = format!(
        "<div class=\"esm-test esm-test--{state}\">\n<p class=\"esm-test__head\">Test <code>{}</code> {word}</p>\n<table>\n<thead><tr><th>Variable</th><th>Time</th><th>Expected</th><th>Actual</th></tr></thead>\n<tbody>\n",
        escape(&test.id)
    );
    for a in &test.assertions {
        let actual = match a.actual {
            Some(actual) => number(actual),
            None => escape(&a.message),
        };
        let _ = writeln!(
            out,
            "<tr class=\"esm-assertion esm-assertion--{}\"><td><code>{}</code></td><td>{}</td><td>{}</td><td>{actual}</td></tr>",
            if a.passed { "pass" } else { "fail" },
            escape(&a.variable),
            number(a.time),
            number(a.expected),
        );
    }
    out.push_str("</tbody>\n</table>\n</div>\n\n");
    out
}

/// A figure, with its SVG inline so the page needs no second request.
///
/// The `<esm-figure>` wrapper is inert until Phase 3's widget is loaded; it
/// carries what that widget needs to re-run the model for a slider.
fn figure_block(figure: &Figure, sliders: Option<&Value>) -> String {
    let Some(svg) = &figure.svg else {
        return String::new();
    };
    let caption = figure.data.description().unwrap_or_default();
    let mut open = format!(
        "<figure class=\"esm-figure\" id=\"fig-{}\">\n",
        escape(&figure.id)
    );
    let interactive = sliders.filter(|s| s.as_array().is_some_and(|a| !a.is_empty()));
    if let Some(sliders) = interactive {
        let _ = writeln!(
            open,
            "<esm-figure data-analysis=\"{}\" data-plot=\"{}\" data-sliders=\"{}\">",
            escape(&figure.analysis),
            escape(&figure.id),
            escape(&sliders.to_string())
        );
    }
    open.push_str(svg);
    open.push('\n');
    if interactive.is_some() {
        open.push_str("</esm-figure>\n");
    }
    if !caption.is_empty() {
        let _ = writeln!(open, "<figcaption>{}</figcaption>", escape(caption));
    }
    open.push_str("</figure>\n\n");
    open
}

fn problem_block(problems: &[Diagnostic]) -> String {
    let mut out = String::from("<div class=\"esm-problems\">\n");
    for d in problems {
        let _ = writeln!(
            out,
            "<p class=\"esm-problem esm-problem--{}\"><strong>{}[{}]</strong> {}</p>",
            d.severity,
            d.severity,
            escape(&d.code),
            escape(&d.message)
        );
    }
    out.push_str("</div>\n\n");
    out
}

/// A number as a reader would write it: no trailing zeros, no exponent for
/// everyday magnitudes.
fn number(v: f64) -> String {
    if v != 0.0 && (v.abs() < 1e-3 || v.abs() >= 1e6) {
        return format!("{v:e}");
    }
    let mut s = format!("{v:.6}");
    if s.contains('.') {
        s = s.trim_end_matches('0').trim_end_matches('.').to_string();
    }
    s
}

/// A table cell: HTML-escaped, and with the `|` that would end it escaped too.
fn cell(text: String) -> String {
    escape(&text).replace('|', "\\|")
}

fn escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            _ => out.push(c),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn numbers_read_naturally() {
        assert_eq!(number(0.1), "0.1");
        assert_eq!(number(100.0), "100");
        assert_eq!(number(6.931471805599453), "6.931472");
        assert_eq!(number(1e-4), "1e-4");
        assert_eq!(number(0.0), "0");
    }

    #[test]
    fn an_example_shows_three_forms() {
        let block = example_block("D(N, t) = -lambda*N");
        assert!(
            block.contains("```text\nD(N, t) = -lambda*N\n```"),
            "{block}"
        );
        assert!(
            block.contains("\\frac{\\mathrm{d} N}{\\mathrm{d} t}"),
            "{block}"
        );
        assert!(block.contains("```json"), "{block}");
    }

    #[test]
    fn an_unparsable_example_says_so() {
        let block = example_block("D(N, ");
        assert!(block.contains("does not parse"), "{block}");
    }
}
