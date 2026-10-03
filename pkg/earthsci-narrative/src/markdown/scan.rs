//! Finding directives in Markdown text.
//!
//! The syntax is the generic-directives proposal, the one `remark-directive`
//! implements, so a narrative page stays ordinary Markdown that other tools can
//! still read:
//!
//! | Form | Spelling | Used for |
//! | --- | --- | --- |
//! | inline | `:var[N]{units="mol"}` | a quantity named in a sentence |
//! | leaf | `::eq[D(N, t) = -lambda*N]{#eq-decay}` | a display equation |
//! | container | `:::esm-test{#half-life}` … `:::` | a test, analysis or figure |
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

/// A run of the source: either text to copy through, or a directive to render.
// A page holds a handful of directives, so the larger variant costs nothing
// worth boxing it for.
#[allow(clippy::large_enum_variant)]
#[derive(Debug, Clone)]
pub enum Piece {
    /// Markdown to pass through unchanged.
    Text(String),
    /// A directive to replace with rendered output.
    Directive(Directive),
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
            fence = Some(open);
            text.push_str(line);
            i += 1;
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
                Piece::Text(_) => None,
            })
            .collect()
    }

    fn text(source: &str) -> String {
        scan(source, "page.md")
            .pieces
            .into_iter()
            .filter_map(|p| match p {
                Piece::Text(t) => Some(t),
                Piece::Directive(_) => None,
            })
            .collect()
    }

    #[test]
    fn reads_the_three_forms() {
        let source = "\
---
title: Decay
---
Nitrogen :var[N]{default=100 units=\"mol\"} decays.

::eq[D(N, t) = -lambda*N]{#eq-decay}

:::esm-plot{#decay span=\"0..50\"}
y: N
:::
";
        let scan = scan(source, "page.md");
        assert_eq!(scan.front_matter, "---\ntitle: Decay\n---\n");
        assert!(scan.diagnostics.is_empty(), "{:?}", scan.diagnostics);
        let found = directives(source);
        let names: Vec<_> = found.iter().map(|d| d.name.as_str()).collect();
        assert_eq!(names, ["var", "eq", "esm-plot"]);

        assert_eq!(found[0].form, Form::Inline);
        assert_eq!(found[0].content, "N");
        assert_eq!(found[0].attrs["default"], 100.0);
        assert_eq!(found[0].attrs["units"], "mol");
        assert_eq!(found[0].source.line, Some(4));
        assert_eq!(found[0].source.column, Some(10));

        assert_eq!(found[1].form, Form::Leaf);
        assert_eq!(found[1].content, "D(N, t) = -lambda*N");
        assert_eq!(found[1].attrs["#"], "eq-decay");

        assert_eq!(found[2].form, Form::Container);
        assert_eq!(found[2].body, "y: N\n");
        assert_eq!(found[2].attrs["span"], "0..50");
        assert_eq!(found[2].source.end_line, Some(10));
        assert_eq!(text(source), "Nitrogen  decays.\n\n\n");
    }

    #[test]
    fn code_hides_directives() {
        let source = "\
Write `:var[N]{units=\"mol\"}` in a sentence.

```md
::eq[x = 1]
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
