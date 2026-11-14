---
title: "remove_coupling"
description: "Stable function · Editing"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Editing](/generated/api/topics/editing)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `remove_coupling` | `removeCoupling` | `remove_coupling`, `remove_coupling_from_file` | `remove_coupling` | `RemoveCoupling` |


**Note:** spelling differs from the §2 rule: python=remove_coupling_from_file (expected remove_coupling); multiple spellings exported by: python


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
remove_coupling(file::EsmFile, index::Int64)
```

```julia
remove_coupling(file::EsmFile, index::Int) -> EsmFile
```

Remove a coupling entry by index (1-based).
Throws [`EditError`](/generated/api/ref/edit_error) if the index is out of bounds.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/edit.jl#L424)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function removeCoupling(file: EsmFile, index: number): EsmFile
```

Remove a coupling entry from an ESM file by index

**Parameters**

- `file` — ESM file to remove coupling from
- `index` — Index of coupling entry to remove

**Returns**

New ESM file with coupling removed

**Throws**

- EntityNotFoundError if index is out of bounds

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-ts/src/edit.ts#L443)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

Exported as `remove_coupling` and `remove_coupling_from_file`. Both names refer to the same operation.

**`remove_coupling`**

```python
remove_coupling(esm_file: EsmFile, index: int, validate_after_edit: bool = True) -> EditResult
```

Remove a coupling entry from an ESM file.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/edit.py#L849)

**`remove_coupling_from_file`**

```python
remove_coupling_from_file(esm_file: EsmFile, index: int, validate_after_edit: bool = True) -> EditResult
```

Deprecated alias for [`remove_coupling`](/generated/api/ref/remove_coupling). Remove a coupling entry from an ESM file.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/edit.py#L1033)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn remove_coupling(esm_file: &EsmFile, index: usize) -> EditResult<EsmFile>
```

Remove a coupling entry from an ESM file by index

**Arguments**

* `esm_file` - The ESM file to modify
* `index` - Index of the coupling entry to remove

**Returns**

* `EditResult<EsmFile>` - New ESM file without the coupling entry

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/edit.rs#L498) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.remove_coupling.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func RemoveCoupling(file ESMFile, index int) (ESMFile, error)
```

RemoveCoupling returns a copy of `file` without the coupling entry at `index`. Indices are 0-based.

Returns \*EntityNotFoundError when the index is out of range.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/edit.go#L1084) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#RemoveCoupling)

</div>

</div>
