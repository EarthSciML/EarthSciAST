---
title: "print_markdown"
description: "Stable function · Source formats"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Source formats](/generated/api/topics/source-formats)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `print_markdown` | `printMarkdown` | `print_markdown` | `print_markdown` | `PrintMarkdown` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
print_markdown(doc::AbstractDict)
```

```julia
print_markdown(doc::AbstractDict) -> String
```

Print an ESM document as Markdown: YAML front matter, LaTeX math in `$$`
displays, remark directives for components, declarations and reactions, and
fenced `esm:` blocks for every field without a native spelling (Lean
`Source.Md.printMd`).

`doc` is a decoded JSON document (the object `load` reads, e.g. from
`JSON3.read`). It is put in canonical form first ([`canonicalize_document`](/generated/api/ref/canonicalize_document),
then every object's keys sorted), so two documents that canonicalize alike
print alike, and `parse_markdown(print_markdown(d)) == canonicalize_document(d)`.

```julia
julia> print_markdown(JSON3.read(read("model.esm", String)))
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/pkg/EarthSciAST.jl/src/document_format.jl#L13)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function printMarkdown(doc: object): string
```

Print an ESM document as Markdown (`Source.Md.printMd`).

`doc` is the JSON document value (plain numbers, or the `NumericLiteral`
leaves and `bigint`s of `losslessJsonParse`). It is put in canonical form first
(`canonicalizeDocument`), so two documents that canonicalize alike print
alike, and `parseMarkdown(printMarkdown(d))` is `canonicalizeDocument(d)`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/pkg/earthsci-ast-ts/src/document/index.ts#L89)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
print_markdown(doc: dict) -> str
```

Print an ESM document as Markdown (`Source.Md.printMd`).

`doc` is the decoded JSON document. It is put in canonical form first
([`canonicalize_document`](/generated/api/ref/canonicalize_document)), so two documents that
canonicalize alike print alike, and `parse_markdown(print_markdown(d))` is
`canonicalize_document(d)`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/pkg/earthsci-ast-py/src/earthsci_ast/document/__init__.py#L108)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn print_markdown(doc: &Map<String, Value>) -> String
```

Print an ESM document as Markdown (`Source.Md.printMd`).

The document is put in canonical form first (`canonicalize_document`), so
two documents that canonicalize alike print alike, and
`parse_markdown(&print_markdown(d))` is `canonicalize_document(d)`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/pkg/earthsci-ast-rs/src/document/mod.rs#L63) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.print_markdown.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func PrintMarkdown(doc any) string
```

PrintMarkdown prints an ESM document as Markdown (Lean `Source.Md.printMd`).

doc is a decoded document (the value CanonicalizeDocument takes: a map\[string\]any as encoding/json produces, numbers as float64, json.Number or int64). It is put in canonical form first, so two documents that canonicalize alike print alike, and ParseMarkdown(PrintMarkdown(d)) is CanonicalizeDocument(d).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/pkg/earthsci-ast-go/pkg/esm/document_format.go#L72) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#PrintMarkdown)

</div>

</div>
