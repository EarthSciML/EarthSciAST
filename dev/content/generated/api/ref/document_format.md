---
title: "document_format"
description: "Stable type · Other"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Other](/generated/api/topics/other)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | `DocumentFormat` | `DocumentFormat` | `DocumentFormat` | `DocumentFormat` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this type.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
type DocumentFormat = 'markdown' | 'typst';
```

Which source format a document is written in.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/pkg/earthsci-ast-ts/src/document/index.ts#L57)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class DocumentFormat(str, Enum)
DocumentFormat.MARKDOWN = 'markdown'
DocumentFormat.TYPST = 'typst'
```

Which source format a document is written in. A plain string
(`"markdown"` / `"typst"`) is accepted wherever a format is.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/pkg/earthsci-ast-py/src/earthsci_ast/document/__init__.py#L60)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub enum DocumentFormat {
    Markdown,
    Typst,
}
```

Which source format a document is written in.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/pkg/earthsci-ast-rs/src/document/mod.rs#L44) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.DocumentFormat.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type DocumentFormat int
func (f DocumentFormat) String() string
```

DocumentFormat is a source format an ESM document can be written in.

**Methods**

```go
func (f DocumentFormat) String() string
```

String names the format.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/pkg/earthsci-ast-go/pkg/esm/document_format.go#L25) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#DocumentFormat)

</div>

</div>
