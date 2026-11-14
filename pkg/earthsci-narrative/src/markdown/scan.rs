//! Finding the constructs of a page in Markdown text, for rendering it.
//!
//! What a page *means* is read by the core (`earthsci_ast::parse_markdown`);
//! this scanner only finds where each construct is, so the renderer can put
//! its output there. It knows the directive syntax of the generic-directives
//! proposal, the one `remark-directive` implements, which both the ESM
//! Markdown format and narrative's own `esm-` directives use:
//!
//! | Form | Spelling | Used for |
//! | --- | --- | --- |
//! | inline | `:var[$N$]{units="mol"}` | a quantity named in a sentence |
//! | leaf | `::model[Decay]`, `::esm-variables{}` | a component, a table |
//! | container | `:::esm-test{#half-life}` … `:::` | a test, analysis or figure |
//!
//! and two constructs of the ESM Markdown format that are not directives: a
//! display equation (a line `$$`, its LaTeX, a line `$$`, optionally followed
//! by a label `{#eq-x}`) or a reaction (`$$\ce{…}$$ {#R1}` on one line), and
//! a fenced block whose info string is `esm:<key>`.
//!
//! A leaf directive owns its line and a container owns its lines, so both are
//! block-level. Everything else is passed through untouched — including
//! anything inside a fenced code block or an inline code span, so that a page
//! can show a directive without triggering it.

// Every failure here is a `Diagnostic`, which the rest of the crate also
// carries by value; boxing it in these few functions alone would buy nothing.
#![allow(clippy::result_large_err)]

use serde_json::{Map, Value};

use crate::diagnostic::Diagnostic;
use crate::element::SourceSpan;

/// How a directive was written, which decides how its output is placed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Form {
    /// `:name[…]{…}`, inside a line of prose.
    Inline,
    /// `::name[…]{…}`, alone on its line.
    Leaf,
    /// `:::name{…}` … `:::`, over several lines.
    Container,
}

/// One directive, as written.
#[derive(Debug, Clone)]
pub struct Directive {
    /// The name after the colons, e.g. `var` or `esm-plot`.
    pub name: String,
    /// How it was written.
    pub form: Form,
    /// The `[…]` content, empty when there was none.
    pub content: String,
    /// The `{…}` attributes, in the order written.
    pub attrs: Map<String, Value>,
    /// A container's body, the lines between the fences.
    pub body: String,
    /// Exactly what was written, so a directive this crate does not own can be
    /// passed through untouched.
    pub raw: String,
    /// Where it came from.
    pub source: SourceSpan,
}

/// A display of the ESM Markdown format: an equation, or a reaction.
#[derive(Debug, Clone)]
pub struct Display {
    /// The LaTeX between the `$$` delimiters, without the line breaks that
    /// frame it.
    pub latex: String,
    /// Whether it is a reaction line, `$$\ce{…}$$`.
    pub reaction: bool,
    /// The `{…}` after the closing `$$`: an equation's label (`#`), or a
    /// reaction's id (`#`) and other fields.
    pub attrs: Map<String, Value>,
    /// Exactly what was written.
    pub raw: String,
    /// Where it came from.
    pub source: SourceSpan,
}

/// A fenced block of the ESM Markdown format, ```` ```esm:<key> ````.
#[derive(Debug, Clone)]
pub struct Block {
    /// The key in the info string, `description` or a field's name, as
    /// written (a quoted key keeps its quotes).
    pub key: String,
    /// The lines between the fences.
    pub body: String,
    /// Exactly what was written.
    pub raw: String,
    /// Where it came from.
    pub source: SourceSpan,
}

/// A run of the source: text to copy through, or a construct to render.
// A page holds a handful of directives, so the larger variant costs nothing
// worth boxing it for.
#[allow(clippy::large_enum_variant)]
#[derive(Debug, Clone)]
pub enum Piece {
    /// Markdown to pass through unchanged.
    Text(String),
    /// A directive to replace with rendered output.
    Directive(Directive),
    /// A display equation or a reaction.
    Display(Display),
    /// An ```` ```esm:<key> ```` block.
    Block(Block),
}

/// What [`scan`] found.
#[derive(Debug, Clone, Default)]
pub struct Scan {
    /// The page's YAML front matter, delimiters included, when it has any.
    pub front_matter: String,
    /// The page in order, with every directive lifted out.
    pub pieces: Vec<Piece>,
    /// Malformed directives.
    pub diagnostics: Vec<Diagnostic>,
}

/// Split Markdown into text and directives.
///
/// `file` names the source in the [`SourceSpan`] of every directive found, and
/// so in the diagnostics that later attach to them.
pub fn scan(source: &str, file: &str) -> Scan {
    let mut out = Scan::default();
    let lines: Vec<&str> = source.split_inclusive('\n').collect();
    let mut i = 0;

    // Front matter is a `---` fence at the very top. It is copied through
    // verbatim rather than parsed: the build has no business rewriting a page's
    // Hugo metadata.
    if lines.first().is_some_and(|l| l.trim_end() == "---")
        && let Some(end) = lines.iter().skip(1).position(|l| l.trim_end() == "---")
    {
        out.front_matter = lines[..=end + 1].concat();
        i = end + 2;
    }

    let mut text = String::new();
    // The delimiter of the fenced code block being passed through, if any.
    let mut fence: Option<String> = None;
    while i < lines.len() {
        let line = lines[i];
        let trimmed = line.trim_start();

        if let Some(open) = &fence {
            text.push_str(line);
            if trimmed.starts_with(open.as_str()) {
                fence = None;
            }
            i += 1;
            continue;
        }
        if let Some(open) = opening_fence(trimmed) {
            if let Some((block, next)) = read_block(&lines, i, &open, file) {
                flush(&mut text, &mut out.pieces);
                out.pieces.push(Piece::Block(block));
                i = next;
                continue;
            }
            fence = Some(open);
            text.push_str(line);
            i += 1;
            continue;
        }

        if line.starts_with("$$")
            && let Some((display, next)) = read_display(&lines, i, file)
        {
            flush(&mut text, &mut out.pieces);
            out.pieces.push(Piece::Display(display));
            i = next;
            continue;
        }

        // A block directive must start its line; the indent, if any, is
        // dropped along with it.
        if trimmed.starts_with("::") {
            let colons = trimmed.len() - trimmed.trim_start_matches(':').len();
            let line_no = i as u32 + 1;
            if colons >= 3 {
                match read_container(&lines, i, file, line_no) {
                    Ok((directive, next)) => {
                        flush(&mut text, &mut out.pieces);
                        out.pieces.push(Piece::Directive(directive));
                        i = next;
                        continue;
                    }
                    Err(d) => {
                        out.diagnostics.push(d);
                        // Fall through: an unterminated container is left in
                        // the page as the text it is.
                    }
                }
            } else if let Some(directive) =
                read_leaf(line, trimmed, file, line_no, &mut out.diagnostics)
            {
                flush(&mut text, &mut out.pieces);
                out.pieces.push(Piece::Directive(directive));
                i += 1;
                continue;
            }
        }

        scan_line(line, file, i as u32 + 1, &mut text, &mut out);
        i += 1;
    }
    flush(&mut text, &mut out.pieces);
    out
}

/// The delimiter that would close this fenced code block.
fn opening_fence(trimmed: &str) -> Option<String> {
    for mark in ["```", "~~~"] {
        if trimmed.starts_with(mark) {
            let run = trimmed.len() - trimmed.trim_start_matches(&mark[..1]).len();
            return Some(mark[..1].repeat(run));
        }
    }
    None
}

/// Read an ```` ```esm:<key> ```` block opened by the fence `open` on line
/// `start`, returning it and the line after it. `None` for any other fence,
/// and for one that is never closed (which is left in the page as text).
fn read_block(lines: &[&str], start: usize, open: &str, file: &str) -> Option<(Block, usize)> {
    let info = lines[start].trim_start()[open.len()..].trim_end();
    let key = info.strip_prefix("esm:")?;
    if !open.starts_with('`') || key.is_empty() {
        return None;
    }
    let mut body = String::new();
    for (offset, line_text) in lines.iter().enumerate().skip(start + 1) {
        let t = line_text.trim();
        if t.starts_with(open) && t.chars().all(|c| c == '`') {
            let mut source = span(file, start as u32 + 1);
            source.end_line = Some(offset as u32 + 1);
            return Some((
                Block {
                    key: key.to_string(),
                    body,
                    raw: lines[start..=offset].concat(),
                    source,
                },
                offset + 1,
            ));
        }
        body.push_str(line_text);
    }
    None
}

/// Read a display that starts line `start` (which starts with `$$`): a
/// reaction, `$$\ce{…}$$ {…}` on one line, or an equation, a line `$$`, its
/// LaTeX, then a line starting `$$` with an optional `{…}` after it.
/// Returns it and the line after it; `None` when the line is neither.
fn read_display(lines: &[&str], start: usize, file: &str) -> Option<(Display, usize)> {
    let first = lines[start].trim_end_matches(['\n', '\r']);
    let source = span(file, start as u32 + 1);
    if first.starts_with("$$\\ce{") {
        let close = first[2..].rfind("$$")? + 2;
        let (attrs, _) =
            read_attrs(first[close + 2..].trim_start(), file, start as u32 + 1).ok()?;
        return Some((
            Display {
                latex: first[2..close].to_string(),
                reaction: true,
                attrs,
                raw: lines[start].to_string(),
                source,
            },
            start + 1,
        ));
    }
    if first.trim_end() != "$$" {
        return None;
    }
    let mut latex = String::new();
    for (offset, line_text) in lines.iter().enumerate().skip(start + 1) {
        let t = line_text.trim_end_matches(['\n', '\r']);
        if let Some(after) = t.strip_prefix("$$") {
            let (attrs, _) = read_attrs(after.trim(), file, offset as u32 + 1).unwrap_or_default();
            let mut source = source;
            source.end_line = Some(offset as u32 + 1);
            return Some((
                Display {
                    latex: latex.trim_end_matches(['\n', '\r']).to_string(),
                    reaction: false,
                    attrs,
                    raw: lines[start..=offset].concat(),
                    source,
                },
                offset + 1,
            ));
        }
        latex.push_str(line_text);
    }
    None
}

fn flush(text: &mut String, pieces: &mut Vec<Piece>) {
    if !text.is_empty() {
        pieces.push(Piece::Text(std::mem::take(text)));
    }
}

/// Read `::name[content]{attrs}` from a line that starts with `::`.
fn read_leaf(
    line_text: &str,
    trimmed: &str,
    file: &str,
    line: u32,
    diagnostics: &mut Vec<Diagnostic>,
) -> Option<Directive> {
    let rest = trimmed.strip_prefix("::")?;
    let (name, after) = read_name(rest)?;
    let mut at = 0;
    let content = read_bracketed(&after[at..], '[', ']').map(|(c, used)| {
        at += used;
        c
    });
    let attrs = match read_attrs(&after[at..], file, line) {
        Ok((attrs, used)) => {
            at += used;
            attrs
        }
        Err(d) => {
            diagnostics.push(d);
            return None;
        }
    };
    // Anything but whitespace after the directive means this line is prose
    // that happens to start with colons, so leave it alone.
    if !after[at..].trim().is_empty() {
        return None;
    }
    Some(Directive {
        name,
        form: Form::Leaf,
        content: content.unwrap_or_default(),
        attrs,
        body: String::new(),
        raw: line_text.to_string(),
        source: span(file, line),
    })
}

/// Read `:::name{attrs}` … `:::`, returning the directive and the line after it.
fn read_container(
    lines: &[&str],
    start: usize,
    file: &str,
    line: u32,
) -> Result<(Directive, usize), Diagnostic> {
    let trimmed = lines[start].trim_start();
    let opening = trimmed.len() - trimmed.trim_start_matches(':').len();
    let rest = &trimmed[opening..];
    let bad = |message: String| {
        let mut d = Diagnostic::error("bad_directive", message);
        d.source = Some(span(file, line));
        d
    };
    let (name, after) = read_name(rest)
        .ok_or_else(|| bad("a container directive needs a name after its colons".to_string()))?;
    let mut at = 0;
    let content = read_bracketed(&after[at..], '[', ']').map(|(c, used)| {
        at += used;
        c
    });
    let (attrs, used) = read_attrs(&after[at..], file, line)?;
    at += used;
    if !after[at..].trim().is_empty() {
        return Err(bad(format!(
            "unexpected `{}` after the `:::{name}` directive",
            after[at..].trim()
        )));
    }

    // The closing fence is a line of at least as many colons and nothing else.
    let mut body = String::new();
    for (offset, line_text) in lines.iter().enumerate().skip(start + 1) {
        let t = line_text.trim();
        if t.len() >= opening && t.chars().all(|c| c == ':') {
            let mut source = span(file, line);
            source.end_line = Some(offset as u32 + 1);
            return Ok((
                Directive {
                    name,
                    form: Form::Container,
                    content: content.unwrap_or_default(),
                    attrs,
                    body,
                    raw: lines[start..=offset].concat(),
                    source,
                },
                offset + 1,
            ));
        }
        body.push_str(line_text);
    }
    Err(bad(format!(
        "the `:::{name}` directive is never closed; add a line of `{}`",
        ":".repeat(opening)
    )))
}

/// Find inline directives in one line of prose.
fn scan_line(line: &str, file: &str, line_no: u32, text: &mut String, out: &mut Scan) {
    let bytes = line.as_bytes();
    let mut at = 0;
    while at < line.len() {
        // A code span hides whatever it contains, so a page can show a
        // directive without running it.
        if bytes[at] == b'`' {
            let ticks = line[at..].len() - line[at..].trim_start_matches('`').len();
            let close = line[at + ticks..]
                .find(&"`".repeat(ticks))
                .map(|p| at + ticks + p + ticks);
            let end = close.unwrap_or(line.len());
            text.push_str(&line[at..end]);
            at = end;
            continue;
        }
        if bytes[at] != b':' || line[at..].starts_with("::") {
            let next = line[at + 1..]
                .find([':', '`'])
                .map_or(line.len(), |p| at + 1 + p);
            text.push_str(&line[at..next]);
            at = next;
            continue;
        }
        match read_inline(&line[at..], file, line_no, at as u32 + 1) {
            Ok(Some((directive, used))) => {
                flush(text, &mut out.pieces);
                out.pieces.push(Piece::Directive(directive));
                at += used;
            }
            Ok(None) => {
                text.push(':');
                at += 1;
            }
            Err(d) => {
                out.diagnostics.push(d);
                text.push(':');
                at += 1;
            }
        }
    }
}

/// Read `:name[content]{attrs}` at the start of `s`, with the bytes it used.
fn read_inline(
    s: &str,
    file: &str,
    line: u32,
    column: u32,
) -> Result<Option<(Directive, usize)>, Diagnostic> {
    let rest = &s[1..];
    let Some((name, after)) = read_name(rest) else {
        return Ok(None);
    };
    let mut at = 0;
    // An inline directive without content is just a colon and a word.
    let Some((content, used)) = read_bracketed(after, '[', ']') else {
        return Ok(None);
    };
    at += used;
    let (attrs, used) = read_attrs(&after[at..], file, line)?;
    at += used;
    let mut source = span(file, line);
    source.column = Some(column);
    let used = s.len() - after.len() + at;
    Ok(Some((
        Directive {
            name,
            form: Form::Inline,
            content,
            attrs,
            body: String::new(),
            raw: s[..used].to_string(),
            source,
        },
        used,
    )))
}

/// A directive name: a letter, then letters, digits, `-` or `_`.
fn read_name(s: &str) -> Option<(String, &str)> {
    let end = s
        .find(|c: char| !(c.is_ascii_alphanumeric() || c == '-' || c == '_'))
        .unwrap_or(s.len());
    let name = &s[..end];
    if name.is_empty() || !name.starts_with(|c: char| c.is_ascii_alphabetic()) {
        return None;
    }
    Some((name.to_string(), &s[end..]))
}

/// Read a `[…]` or `{…}` group, honouring nesting and `\` escapes.
fn read_bracketed(s: &str, open: char, close: char) -> Option<(String, usize)> {
    let mut chars = s.char_indices();
    if chars.next()?.1 != open {
        return None;
    }
    let mut depth = 1;
    let mut content = String::new();
    let mut escaped = false;
    for (at, c) in chars {
        if escaped {
            // Only the group's own delimiters are escapable; every other
            // backslash belongs to the content (`\lambda`, a LaTeX name).
            if c != open && c != close && c != '\\' {
                content.push('\\');
            }
            content.push(c);
            escaped = false;
            continue;
        }
        match c {
            '\\' => escaped = true,
            _ if c == open => {
                depth += 1;
                content.push(c);
            }
            _ if c == close => {
                depth -= 1;
                if depth == 0 {
                    return Some((content, at + c.len_utf8()));
                }
                content.push(c);
            }
            _ => content.push(c),
        }
    }
    None
}

/// Read `{#id key=value key="value" flag}`.
fn read_attrs(s: &str, file: &str, line: u32) -> Result<(Map<String, Value>, usize), Diagnostic> {
    let mut attrs = Map::new();
    let Some((inside, used)) = read_bracketed(s, '{', '}') else {
        return Ok((attrs, 0));
    };
    let bad = |message: String| {
        let mut d = Diagnostic::error("bad_directive", message);
        d.source = Some(span(file, line));
        d
    };
    let mut rest = inside.trim();
    while !rest.is_empty() {
        if let Some(after) = rest.strip_prefix('#') {
            let (id, tail) = split_word(after);
            if id.is_empty() {
                return Err(bad("`#` needs an identifier after it".to_string()));
            }
            attrs.insert("#".to_string(), Value::String(id.to_string()));
            rest = tail.trim_start();
            continue;
        }
        let (key, tail) = split_key(rest);
        if key.is_empty() {
            return Err(bad(format!("cannot read the attribute at `{rest}`")));
        }
        let tail = tail.trim_start();
        let Some(tail) = tail.strip_prefix('=') else {
            // A bare word is a flag, as in `{log}`.
            attrs.insert(key.to_string(), Value::Bool(true));
            rest = tail.trim_start();
            continue;
        };
        let tail = tail.trim_start();
        let (raw, tail) = match tail.chars().next() {
            Some(quote @ ('"' | '\'')) => {
                let end = tail[1..]
                    .find(quote)
                    .ok_or_else(|| bad(format!("attribute `{key}` has no closing {quote}")))?;
                (&tail[1..1 + end], &tail[end + 2..])
            }
            _ => split_word(tail),
        };
        attrs.insert(key.to_string(), scalar(raw));
        rest = tail.trim_start();
    }
    Ok((attrs, used))
}

/// An attribute value: JSON where it reads as JSON, text otherwise, so that
/// `default=100` is a number and `units="mol"` is a string.
fn scalar(raw: &str) -> Value {
    match serde_json::from_str::<Value>(raw) {
        Ok(v @ (Value::Number(_) | Value::Bool(_) | Value::Null | Value::Array(_))) => v,
        _ => Value::String(raw.to_string()),
    }
}

fn split_word(s: &str) -> (&str, &str) {
    let end = s.find(char::is_whitespace).unwrap_or(s.len());
    (&s[..end], &s[end..])
}

fn split_key(s: &str) -> (&str, &str) {
    let end = s
        .find(|c: char| !(c.is_ascii_alphanumeric() || c == '-' || c == '_'))
        .unwrap_or(s.len());
    (&s[..end], &s[end..])
}

fn span(file: &str, line: u32) -> SourceSpan {
    SourceSpan {
        file: Some(file.to_string()),
        line: Some(line),
        ..SourceSpan::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn directives(source: &str) -> Vec<Directive> {
        scan(source, "page.md")
            .pieces
            .into_iter()
            .filter_map(|p| match p {
                Piece::Directive(d) => Some(d),
                _ => None,
            })
            .collect()
    }

    fn text(source: &str) -> String {
        scan(source, "page.md")
            .pieces
            .into_iter()
            .filter_map(|p| match p {
                Piece::Text(t) => Some(t),
                _ => None,
            })
            .collect()
    }

    #[test]
    fn reads_the_three_forms() {
        let source = "\
---
title: Decay
---
Nitrogen :var[$N$]{default=100 units=\"mol\"} decays.

::model[Decay]

:::esm-plot{#decay span=\"0..50\"}
y: N
:::
";
        let scan = scan(source, "page.md");
        assert_eq!(scan.front_matter, "---\ntitle: Decay\n---\n");
        assert!(scan.diagnostics.is_empty(), "{:?}", scan.diagnostics);
        let found = directives(source);
        let names: Vec<_> = found.iter().map(|d| d.name.as_str()).collect();
        assert_eq!(names, ["var", "model", "esm-plot"]);

        assert_eq!(found[0].form, Form::Inline);
        assert_eq!(found[0].content, "$N$");
        assert_eq!(found[0].attrs["default"], 100.0);
        assert_eq!(found[0].attrs["units"], "mol");
        assert_eq!(found[0].source.line, Some(4));
        assert_eq!(found[0].source.column, Some(10));

        assert_eq!(found[1].form, Form::Leaf);
        assert_eq!(found[1].content, "Decay");

        assert_eq!(found[2].form, Form::Container);
        assert_eq!(found[2].body, "y: N\n");
        assert_eq!(found[2].attrs["span"], "0..50");
        assert_eq!(found[2].source.end_line, Some(10));
        assert_eq!(text(source), "Nitrogen  decays.\n\n\n");
    }

    #[test]
    fn reads_displays_reactions_and_blocks() {
        let source = "\
::model[M]

$$
\\frac{\\mathrm{d} c}{\\mathrm{d} t} = -u c
$$ {#eq-loss}

$$\\ce{NO + O3 ->[{$k$}] NO2}$$ {#R1 name=\"titration\"}

```esm:tests
- id: \"t\"
```

```yaml
not: ours
```
";
        let pieces = scan(source, "page.md").pieces;
        let displays: Vec<&Display> = pieces
            .iter()
            .filter_map(|p| match p {
                Piece::Display(d) => Some(d),
                _ => None,
            })
            .collect();
        assert_eq!(displays.len(), 2);
        assert_eq!(
            displays[0].latex,
            "\\frac{\\mathrm{d} c}{\\mathrm{d} t} = -u c"
        );
        assert!(!displays[0].reaction);
        assert_eq!(displays[0].attrs["#"], "eq-loss");
        assert_eq!(displays[0].source.line, Some(3));
        assert_eq!(displays[0].source.end_line, Some(5));
        assert_eq!(displays[1].latex, "\\ce{NO + O3 ->[{$k$}] NO2}");
        assert!(displays[1].reaction);
        assert_eq!(displays[1].attrs["#"], "R1");
        assert_eq!(displays[1].attrs["name"], "titration");
        let blocks: Vec<&Block> = pieces
            .iter()
            .filter_map(|p| match p {
                Piece::Block(b) => Some(b),
                _ => None,
            })
            .collect();
        assert_eq!(blocks.len(), 1);
        assert_eq!(blocks[0].key, "tests");
        assert_eq!(blocks[0].body, "- id: \"t\"\n");
        assert!(text(source).contains("```yaml\nnot: ours\n```\n"));
    }

    #[test]
    fn code_hides_directives() {
        let source = "\
Write `:var[$N$]{units=\"mol\"}` in a sentence.

```md
::model[M]
:::esm-plot{y=x}
:::
```

Done.
";
        assert!(directives(source).is_empty());
        assert_eq!(text(source), source);
    }

    #[test]
    fn a_colon_in_prose_is_prose() {
        let source = "Note: this is prose, 10:30, and a ratio 3:1.\n";
        assert!(directives(source).is_empty());
        assert_eq!(text(source), source);
    }

    #[test]
    fn reports_a_container_that_never_closes() {
        let scan = scan("intro\n\n:::esm-test{#t}\nid: t\n", "page.md");
        assert_eq!(scan.diagnostics.len(), 1);
        assert!(
            scan.diagnostics[0].message.contains("never closed"),
            "{}",
            scan.diagnostics[0].message
        );
        assert_eq!(scan.diagnostics[0].source.as_ref().unwrap().line, Some(3));
    }

    #[test]
    fn brackets_and_escapes_inside_content() {
        let found = directives("::eq[D(c[i], t) = -k*c[i]]{#eq-i}\n");
        assert_eq!(found[0].content, "D(c[i], t) = -k*c[i]");
        let found = directives("Text :var[x]{description=\"a \\] bracket\"} more.\n");
        assert_eq!(found[0].attrs["description"], "a \\] bracket");
    }

    #[test]
    fn attribute_values_keep_their_types() {
        let found = directives("::esm-plot{#p y=[\"A\",\"B\"] count=3 log default=1e-3}\n");
        let a = &found[0].attrs;
        assert_eq!(a["y"], serde_json::json!(["A", "B"]));
        assert_eq!(a["count"], 3.0);
        assert_eq!(a["log"], true);
        assert_eq!(a["default"], 1e-3);
    }
}
