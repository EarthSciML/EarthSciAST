---
title: "parse_document"
description: "Stable function · Source formats"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Source formats](/generated/api/topics/source-formats)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `parse_document` | `parseDocument` | `parse_document` | `parse_document` | `ParseDocument` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
parse_document(text::AbstractString, format::Symbol)
```

```julia
parse_document(text::AbstractString, format::Symbol) -> OrderedDict{String, Any}
```

Read an ESM document written in the source format `format`: `:markdown`
([`parse_markdown`](/generated/api/ref/parse_markdown)) or `:typst` ([`parse_typst`](/generated/api/ref/parse_typst)).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/pkg/EarthSciAST.jl/src/document_format.jl#L182)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function parseDocument(text: string, format: DocumentFormat, options?: ParseDocumentOptions): Record<string, unknown>
```

Read an ESM document written in the given format. See [`parseMarkdown`](/generated/api/ref/parse_markdown).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/pkg/earthsci-ast-ts/src/document/index.ts#L234)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
parse_document(text: str, format: DocumentFormat | str) -> dict
```

Read an ESM document written in the given format (`"markdown"` or
`"typst"`). See [`parse_markdown`](/generated/api/ref/parse_markdown).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/pkg/earthsci-ast-py/src/earthsci_ast/document/__init__.py#L312)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn parse_document(text: &str, format: DocumentFormat) -> Result<Value, DiagnosticError>
```

Read an ESM document written in the given format.

**Errors**

As [`parse_markdown`](/generated/api/ref/parse_markdown).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/pkg/earthsci-ast-rs/src/document/mod.rs#L273) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.parse_document.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func ParseDocument(text string, format DocumentFormat) (any, error)
```

ParseDocument reads an ESM document written in the given format. See ParseMarkdown.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/pkg/earthsci-ast-go/pkg/esm/document_format.go#L223) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ParseDocument)

</div>

</div>
