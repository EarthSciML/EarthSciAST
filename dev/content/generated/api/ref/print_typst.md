---
title: "print_typst"
description: "Stable function · Source formats"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Source formats](/generated/api/topics/source-formats)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `print_typst` | `printTypst` | `print_typst` | `print_typst` | `PrintTypst` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
print_typst(doc::AbstractDict)
```

```julia
print_typst(doc::AbstractDict) -> String
```

Print an ESM document as Typst (Lean `Source.Typ.printTyp`): the `esm` Typst
package's `esm-document` header, Typst math displays and the package's
functions for components, declarations and reactions. See
[`print_markdown`](/generated/api/ref/print_markdown).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/EarthSciAST.jl/src/document_format.jl#L33)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function printTypst(doc: object): string
```

Print an ESM document as Typst (`Source.Typ.printTyp`). See [`printMarkdown`](/generated/api/ref/print_markdown).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-ts/src/document/index.ts#L96)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
print_typst(doc: dict) -> str
```

Print an ESM document as Typst (`Source.Typ.printTyp`). See
[`print_markdown`](/generated/api/ref/print_markdown).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-py/src/earthsci_ast/document/__init__.py#L119)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn print_typst(doc: &Map<String, Value>) -> String
```

Print an ESM document as Typst (`Source.Typ.printTyp`). See
[`print_markdown`](/generated/api/ref/print_markdown).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/document/mod.rs#L69) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.print_typst.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func PrintTypst(doc any) string
```

PrintTypst prints an ESM document as Typst (Lean `Source.Typ.printTyp`). See PrintMarkdown.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-go/pkg/esm/document_format.go#L76) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#PrintTypst)

</div>

</div>
