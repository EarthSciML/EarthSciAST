---
title: "parse_typst"
description: "Stable function · Source formats"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Source formats](/generated/api/topics/source-formats)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `parse_typst` | `parseTypst` | `parse_typst` | `parse_typst` | `ParseTypst` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
parse_typst(text::AbstractString)
```

```julia
parse_typst(text::AbstractString) -> OrderedDict{String, Any}
```

Read a Typst ESM document (Lean `Source.Typ.parseTyp`). See
[`parse_markdown`](/generated/api/ref/parse_markdown).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/pkg/EarthSciAST.jl/src/document_format.jl#L391)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function parseTypst(text: string, options?: ParseDocumentOptions): Record<string, unknown>
```

Read a Typst ESM document (`Source.Typ.parseTyp`). See [`parseMarkdown`](/generated/api/ref/parse_markdown).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/pkg/earthsci-ast-ts/src/document/index.ts#L229)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
parse_typst(text: str) -> dict
```

Read a Typst ESM document (`Source.Typ.parseTyp`). See
[`parse_markdown`](/generated/api/ref/parse_markdown).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/pkg/earthsci-ast-py/src/earthsci_ast/document/__init__.py#L306)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn parse_typst(text: &str) -> Result<Value, DiagnosticError>
```

Read a Typst ESM document (`Source.Typ.parseTyp`). See [`parse_markdown`](/generated/api/ref/parse_markdown).

**Errors**

As [`parse_markdown`](/generated/api/ref/parse_markdown).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/pkg/earthsci-ast-rs/src/document/mod.rs#L264) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.parse_typst.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func ParseTypst(text string) (any, error)
```

ParseTypst reads a Typst ESM document (Lean `Source.Typ.parseTyp`). See ParseMarkdown.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/pkg/earthsci-ast-go/pkg/esm/document_format.go#L219) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ParseTypst)

</div>

</div>
