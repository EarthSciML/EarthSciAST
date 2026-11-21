---
title: "add_coupling"
description: "Stable function · Editing"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Editing](/generated/api/topics/editing)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `add_coupling` | `addCoupling` | `add_coupling`, `add_coupling_to_file` | `add_coupling` | `AddCoupling` |


**Note:** spelling differs from the §2 rule: python=add_coupling_to_file (expected add_coupling); multiple spellings exported by: python


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
add_coupling(file::EsmFile, entry::CouplingEntry)
```

```julia
add_coupling(file::EsmFile, entry::CouplingEntry) -> EsmFile
```

Add a coupling entry to an ESM file.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/edit.jl#L412)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function addCoupling(file: EsmFile, entry: CouplingEntry): EsmFile
```

Add a coupling entry to an ESM file

**Parameters**

- `file` — ESM file to add coupling to
- `entry` — Coupling entry to add

**Returns**

New ESM file with coupling added

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-ts/src/edit.ts#L428)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

Exported as `add_coupling` and `add_coupling_to_file`. Both names refer to the same operation.

**`add_coupling`**

```python
add_coupling(esm_file: EsmFile, coupling: CouplingEntry, validate_after_edit: bool = True) -> EditResult
```

Add a coupling entry to an ESM file.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/edit.py#L841)

**`add_coupling_to_file`**

```python
add_coupling_to_file(esm_file: EsmFile, coupling: CouplingEntry, validate_after_edit: bool = True) -> EditResult
```

Deprecated alias for [`add_coupling`](/generated/api/ref/add_coupling). Add a coupling entry to an ESM file.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/edit.py#L1021)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn add_coupling(esm_file: &EsmFile, coupling: CouplingEntry) -> EditResult<EsmFile>
```

Add a coupling entry to an ESM file

**Arguments**

* `esm_file` - The ESM file to modify
* `coupling` - The coupling entry to add

**Returns**

* `EditResult<EsmFile>` - New ESM file with the added coupling entry

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/edit.rs#L479) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.add_coupling.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func AddCoupling(file ESMFile, entry CouplingEntry) ESMFile
```

AddCoupling returns a copy of `file` with `entry` appended to its coupling list.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/edit.go#L1074) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#AddCoupling)

</div>

</div>
