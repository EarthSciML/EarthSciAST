---
title: "parse_markdown"
description: "Stable function · Source formats"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Source formats](/generated/api/topics/source-formats)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `parse_markdown` | `parseMarkdown` | `parse_markdown` | `parse_markdown` | `ParseMarkdown` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
parse_markdown(text::AbstractString)
```

```julia
parse_markdown(text::AbstractString) -> OrderedDict{String, Any}
```

Read a Markdown ESM document (Lean `Source.Md.parseMd`). The result is a
decoded JSON document in canonical form, as [`canonicalize_document`](/generated/api/ref/canonicalize_document)
returns it with every object's keys sorted. A byte-order mark is dropped, and
CRLF line endings are read as LF when the first line ends in CRLF.

Throws a [`ParseError`](/generated/api/ref/parse_error) whose `code` is `"removed_op"` when the
document's math writes an operator removed from the format (esm-spec §4.2) in
the call or the escape form, and `"parse_error"` for any other text that is not
a Markdown ESM document, and for one past a bound of the reader: more than 128
constructs (brackets, fractions, signs, flow collections, YAML levels, …) open
at once, a value nested more than 127 arrays and objects deep, or a number
beyond the binary64 range, and for a text that is not valid UTF-8. A name nothing declares is not a parse error: an
undeclared reference is the validator's finding.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/pkg/EarthSciAST.jl/src/document_format.jl#L372)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function parseMarkdown(text: string, options?: ParseDocumentOptions): Record<string, unknown>
```

Read a Markdown ESM document (`Source.Md.parseMd`). The result is in canonical
form.

**Throws**

- [`EsmDiagnosticError`](/generated/api/extension/typescript#x-esmdiagnosticerror) — with code `removed_op` when the document's math
    uses an operator removed from the format (esm-spec §4.2), and `parse_error`
    for any other text that is not a Markdown ESM document, and for one past a
    bound of the reader (`limits.ts`): nested too deeply, or holding a number
    beyond the binary64 range.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/pkg/earthsci-ast-ts/src/document/index.ts#L221)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
parse_markdown(text: str) -> dict
```

Read a Markdown ESM document (`Source.Md.parseMd`). The result is the
decoded JSON document, in canonical form (CONFORMANCE §5.5.3.1: an integral
number in Int64 is an `int`, any other a `float`).

Raises `ParseError` whose `code` is
`removed_op` when the text uses an operator removed from the format (spec
§4.2), and `parse_error` for any other text that is not a Markdown ESM
document.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/pkg/earthsci-ast-py/src/earthsci_ast/document/__init__.py#L293)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn parse_markdown(text: &str) -> Result<Value, DiagnosticError>
```

Read a Markdown ESM document (`Source.Md.parseMd`). The result is in
canonical form.

**Errors**

A `DiagnosticError` with code `removed_op` when the document's math uses
an operator removed from the format (spec §4.2), and `parse_error` for any
other text that is not a Markdown ESM document, and for one past a bound
of the Rust reader (`limits`): nested too deeply, or holding a number
beyond the binary64 range.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/pkg/earthsci-ast-rs/src/document/mod.rs#L255) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.parse_markdown.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func ParseMarkdown(text string) (any, error)
```

ParseMarkdown reads a Markdown ESM document (Lean `Source.Md.parseMd`). The result is in canonical form, the representation CanonicalizeDocument returns (map\[string\]any, \[\]any, int64 for an integer, float64 for a decimal).

A text that is not a Markdown ESM document returns a \*DocumentFormatError with code `removed_op` when the document's math uses an operator removed from the format (esm-spec §4.2), and `parse_error` for any other text, and for one past a bound of the reader: nested too deeply (more than 128 reader constructs open at once, or more than 127 levels of arrays and objects), or holding a number beyond the binary64 range.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/pkg/earthsci-ast-go/pkg/esm/document_format.go#L215) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ParseMarkdown)

</div>

</div>
