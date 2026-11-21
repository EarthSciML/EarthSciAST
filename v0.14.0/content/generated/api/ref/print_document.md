---
title: "print_document"
description: "Stable function · Source formats"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Source formats](/generated/api/topics/source-formats)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `print_document` | `printDocument` | `print_document` | `print_document` | `PrintDocument` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
print_document(doc::AbstractDict, format::Symbol)
```

```julia
print_document(doc::AbstractDict, format::Symbol) -> String
```

Print an ESM document in the source format `format`: `:markdown`
([`print_markdown`](/generated/api/ref/print_markdown)) or `:typst` ([`print_typst`](/generated/api/ref/print_typst)).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/pkg/EarthSciAST.jl/src/document_format.jl#L44)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function printDocument(doc: object, format: DocumentFormat): string
```

Print an ESM document in the given format.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/pkg/earthsci-ast-ts/src/document/index.ts#L99)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
print_document(doc: dict, format: DocumentFormat | str) -> str
```

Print an ESM document in the given format (`"markdown"` or
`"typst"`).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/pkg/earthsci-ast-py/src/earthsci_ast/document/__init__.py#L125)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn print_document(doc: &Map<String, Value>, format: DocumentFormat) -> String
```

Print an ESM document in the given format.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/pkg/earthsci-ast-rs/src/document/mod.rs#L74) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.print_document.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func PrintDocument(doc any, format DocumentFormat) string
```

PrintDocument prints an ESM document in the given format.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/pkg/earthsci-ast-go/pkg/esm/document_format.go#L79) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#PrintDocument)

</div>

</div>
