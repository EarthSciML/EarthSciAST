---
title: "flatten_with_options"
description: "Stable function · Flatten"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Flatten](/generated/api/topics/flatten)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | not exported | not exported | `flatten_with_options` | `FlattenWithOptions` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this function.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this function.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

<p class="api-absent">Python does not export this function.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn flatten_with_options(file: &EsmFile, options: &CouplingImportOptions<'_>) -> Result<FlattenedSystem, FlattenError>
```

Flatten with explicit [`CouplingImportOptions`](/generated/api/ref/coupling_import_options) controlling how
`coupling_import` `ref`s resolve (esm-spec §10.10.3). When the file carries
no `coupling_import` entry this is identical to [`flatten`](/generated/api/ref/flatten); otherwise the
import entries are expanded into concrete edges — spliced in position — as a
§4.7.5 sub-step *before* the coupling-rule step, and flattening proceeds over
the expanded coupling sequence. The `coupling_import` source entry is not
mutated on the caller's `file`; the expansion operates on an internal clone.

**Errors**

Returns `FlattenError::CouplingImport` (carrying a stable §10.11
diagnostic code) if any `coupling_import` fails to resolve or expand;
otherwise the [`FlattenError`](/generated/api/ref/flatten_error) taxonomy of [`flatten`](/generated/api/ref/flatten).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/flatten.rs#L887) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.flatten_with_options.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func FlattenWithOptions(file *ESMFile, opts CouplingImportOptions) (*FlattenedSystem, error)
```

FlattenWithOptions is Flatten with control over how `coupling_import` refs are resolved (esm-spec §10.10). Only needed when the file uses `coupling_import`; a file with no such entries flattens identically under the zero-value options.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/flatten.go#L2743) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#FlattenWithOptions)

</div>

</div>
