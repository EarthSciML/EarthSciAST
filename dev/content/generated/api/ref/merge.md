---
title: "merge"
description: "Stable function · Editing"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Editing](/generated/api/topics/editing)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | `merge` | `merge`, `merge_esm_files` | not exported | `Merge` |


**Note:** spelling differs from the §2 rule: python=merge_esm_files (expected merge); multiple spellings exported by: python


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this function.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function merge(fileA: EsmFile, fileB: EsmFile): EsmFile
```

Merge two ESM files

**Parameters**

- `fileA` — First ESM file
- `fileB` — Second ESM file

**Returns**

New ESM file with merged content

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-ts/src/edit.ts#L509)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

Exported as `merge` and `merge_esm_files`. Both names refer to the same operation.

**`merge`**

```python
merge(file_a: EsmFile, file_b: EsmFile, validate_after_edit: bool = True) -> EditResult
```

Merge two ESM files.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/edit.py#L855)

**`merge_esm_files`**

```python
merge_esm_files(file_a: EsmFile, file_b: EsmFile, validate_after_edit: bool = True) -> EditResult
```

Deprecated alias for [`merge`](/generated/api/ref/merge). Merge two ESM files.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/edit.py#L1045)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this function.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func Merge(a, b ESMFile) ESMFile
```

Merge returns a new file combining `a` and `b`. On a key collision `b` wins, matching every other binding. Coupling entries are concatenated, a's first.

The result keeps b's `esm` marker and metadata, and b's domain when it declares one.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/edit.go#L1134) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#Merge)

</div>

</div>
