---
title: "expand_coupling_imports"
description: "Stable function · Load-time lowering and templates"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Load-time lowering and templates](/generated/api/topics/lowering)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `expand_coupling_imports` | `expandCouplingImports` | `expand_coupling_imports` | `expand_coupling_imports` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
expand_coupling_imports(file::EsmFile; base_path, load_ref)
```

```julia
expand_coupling_imports(file::EsmFile; base_path=".", load_ref=nothing)
    -> Vector{CouplingEntry}
```

Expand every `CouplingImport` entry in `file.coupling` into concrete edges,
splicing them in the position of the import entry (esm-spec §10.10.3). Returns
the effective coupling vector; a file with no `coupling_import` entries returns
`file.coupling` unchanged (same object, so no reload) and needs no options.

`base_path` anchors the import `ref`s. `load_ref` is an optional resolver
`(ref, base_path) -> raw JSON doc` (tests supply an in-memory resolver); it
defaults to `_default_coupling_load_ref`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/coupling_imports.jl#L519)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function expandCouplingImports(file: EsmFile, options?: CouplingImportOptions): CouplingEntry[] | undefined
```

Expand every `coupling_import` entry in `file.coupling` into concrete edges,
splicing them in the position of the import entry (esm-spec §10.10.3).
Returns the effective coupling array, or `undefined` if the file has no
`coupling` block. Non-import entries pass through untouched; a file with no
`coupling_import` entries needs no `options` and returns `file.coupling`
verbatim.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-ts/src/coupling-imports.ts#L524)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
expand_coupling_imports(esm_file: Any, base_path: str = '.', load_ref: LoadRefFn | None = None) -> list[Any]
```

Expand every `coupling_import` entry in `esm_file.coupling` into
concrete (typed) coupling edges, splicing them in the position of the import
entry (esm-spec §10.10.3).

Non-import entries pass through untouched; a file with no `coupling_import`
entries returns its coupling list verbatim and never touches disk (so no
`load_ref` is needed). `load_ref(ref, base_path)` returns a parsed
coupling-library document; the default reads it from disk relative to
`base_path`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/coupling_imports.py#L427)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn expand_coupling_imports(file: &EsmFile, options: &CouplingImportOptions<'_>) -> Result<Option<Vec<CouplingEntry>>, DiagnosticError>
```

Expand every `coupling_import` entry in `file.coupling` into concrete edges,
splicing them in the position of the import entry (esm-spec §10.10.3).
Returns the effective coupling array, or `None` if the file has no `coupling`
block. Non-import entries pass through untouched; a file with no
`coupling_import` entries returns a clone of `file.coupling` verbatim.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/coupling_imports.rs#L569) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.expand_coupling_imports.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this function.</p>

</div>

</div>
