---
title: "extract"
description: "Stable function · Editing"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Editing](/generated/api/topics/editing)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `extract` | `extract` | `extract`, `extract_component_from_file` | not exported | `Extract` |


**Note:** spelling differs from the §2 rule: python=extract_component_from_file (expected extract); multiple spellings exported by: python


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
extract(file::EsmFile, component_name::String)
```

```julia
extract(file::EsmFile, component_name::String) -> EsmFile
```

Extract a single component into a standalone ESM file.

Creates a new file containing only the specified component and any
coupling entries that reference it. Throws [`EditError`](/generated/api/ref/edit_error) if the
component does not exist.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/edit.jl#L511)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function extract(file: EsmFile, componentName: string): EsmFile
```

Extract a specific component from an ESM file into a new file

**Parameters**

- `file` — ESM file to extract from
- `componentName` — Name of the component to extract

**Returns**

New ESM file containing only the specified component

**Throws**

- EntityNotFoundError if component not found

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-ts/src/edit.ts#L537)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

Exported as `extract` and `extract_component_from_file`. Both names refer to the same operation.

**`extract`**

```python
extract(esm_file: EsmFile, component_name: str, validate_after_edit: bool = True) -> EditResult
```

Extract a single component into a standalone ESM file.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/edit.py#L861)

**`extract_component_from_file`**

```python
extract_component_from_file(esm_file: EsmFile, component_name: str, validate_after_edit: bool = True) -> EditResult
```

Deprecated alias for [`extract`](/generated/api/ref/extract). Extract a single component into a standalone ESM file.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/edit.py#L1057)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this function.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func Extract(file ESMFile, componentName string) (ESMFile, error)
```

Extract returns a new file containing only the component `componentName`, together with every coupling entry that references it.

Models and reaction systems are searched, in that order. `data_sources` is deliberately NOT searched: from esm 1.0.0 a data source is not a COMPONENT — it has no variables, is not a coupling endpoint or a subsystem — so there is no such thing as extracting one as a standalone document. A model that consumes a source carries the binding on its own parameter, and extracting that model is what carries the dependency with it.

DIVERGENCE: Julia's `extract` still offers data sources as an extractable component; TypeScript's does not, and TypeScript is followed here for the reason above.

Returns \*EntityNotFoundError when no component of that name exists.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/edit.go#L1180) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#Extract)

</div>

</div>
