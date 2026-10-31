---
title: "coupling_import_options"
description: "Stable type · Document types"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Document types](/generated/api/topics/document-types)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | `CouplingImportOptions` | not exported | `CouplingImportOptions` | `CouplingImportOptions` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this type.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
interface CouplingImportOptions {
    basePath?: string;
    loadRef?: (ref: string, basePath: string) => unknown;
}
```

Options controlling how `coupling_import` refs are resolved at flatten.

**Properties**

- `basePath` — Directory the import `ref`s resolve against. Defaults to '.'.
- `loadRef` — Resolve a `ref` string to a parsed coupling-library document. Defaults to a
  synchronous Node `fs` reader. Tests may supply an in-memory resolver.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-ts/src/coupling-imports.ts#L48)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

<p class="api-absent">Python does not export this type.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct CouplingImportOptions<'a> {
    pub base_path: String,
    pub load_ref: Option<Box<dyn Fn(&str, &str) -> Result<Value, DiagnosticError> + 'a>>,
}
```

Options controlling how `coupling_import` refs are resolved at flatten.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/coupling_imports.rs#L46) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.CouplingImportOptions.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type CouplingImportOptions struct {
	// BasePath is the directory import `ref`s resolve against. Defaults to ".".
	BasePath string
	// LoadRef resolves a `ref` string to a parsed coupling-library document
	// (raw JSON view). Defaults to a filesystem reader. Tests may supply an
	// in-memory resolver.
	LoadRef func(ref, basePath string) (map[string]any, error)
}
```

CouplingImportOptions controls how `coupling_import` refs are resolved at flatten (mirrors the TS CouplingImportOptions).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/coupling_imports.go#L50) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CouplingImportOptions)

</div>

</div>
