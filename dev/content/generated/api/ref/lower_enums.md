---
title: "lower_enums"
description: "Stable function · Load-time lowering and templates"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Load-time lowering and templates](/generated/api/topics/lowering)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `lower_enums`, `lower_enums!` | `lowerEnums` | `lower_enums` | `lower_enums` | `LowerEnums` |


**Note:** multiple spellings exported by: julia


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

Exported as `lower_enums` and `lower_enums!`. Both names refer to the same operation.

**`lower_enums`**

```julia
lower_enums(file::EsmFile)
```

```julia
lower_enums(file::EsmFile) -> EsmFile
```

The PURE form: return a DEEP COPY of `file` with every `enum` op replaced by
the `const` integer the file's `enums` block assigns it, leaving `file`
untouched. This is the canonical spelling across the bindings (API_SPEC.md §8
item 15); [`lower_enums!`](/generated/api/ref/lower_enums) is the in-place twin under Julia's `!`
convention (§2.2), and is what the load path calls.

Validation (esm-spec §9.3) — every rejection is an
[`EnumLoweringError`](/generated/api/ref/enum_lowering_error):
- an `enum` op whose args are not exactly two strings → `enum_op_malformed`;
- an `enum` op naming an undeclared enum → `unknown_enum`;
- an `enum` op naming a symbol not declared under that enum →
  `unknown_enum_symbol`.

A file with no `enums` block therefore raises `unknown_enum` on the first
`enum` op it contains.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/registered_functions.jl#L1575)

**`lower_enums!`**

```julia
lower_enums!(file::EsmFile)
```

```julia
lower_enums!(file::EsmFile)
```

Walk every expression tree in `file` and replace each `enum` op with a
`const` integer per the file's `enums` block. After this pass runs, no
`enum`-op nodes remain in the in-memory representation.

The in-place twin of [`lower_enums`](/generated/api/ref/lower_enums), which documents the validation
rules and the [`EnumLoweringError`](/generated/api/ref/enum_lowering_error) codes both raise.

Mutates `file` in place; returns the file for convenience.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/registered_functions.jl#L1596)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function lowerEnums(file: EsmFile): EsmFile
```

Resolve every `enum` op in `file` against `file.enums`. Returns the
(possibly identical) input — the rewrite is structural, immutable:
unchanged subtrees are shared with the input.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/lower-enums.ts#L188)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
lower_enums(file: EsmFile) -> EsmFile
```

Return `file` with every `enum` op replaced by a `const` integer
per the file's `enums` block (esm-spec §9.3).

**Pure**: `file` is not modified. The canonical name carries the pure
form in every binding (API_SPEC.md §8 item 15); the in-place twin is
[`lower_enums_mut`](/generated/api/ref/lower_enums_mut) (Julia spells it `lower_enums!`). Node identity
is preserved wherever nothing lowered, so a document with no `enum` ops
comes back as the very same object.

After this pass runs, no `enum`-op nodes remain in the returned document.

Validation (esm-spec §9.3):

- An `enum` op naming an undeclared enum raises
  [`EnumLoweringError`](/generated/api/ref/enum_lowering_error) with `code == "unknown_enum"`.
- An `enum` op naming a symbol not declared under that enum raises
  [`EnumLoweringError`](/generated/api/ref/enum_lowering_error) with `code == "unknown_enum_symbol"`.

[`EnumLoweringError`](/generated/api/ref/enum_lowering_error) subclasses `ValueError`, so existing
`except ValueError` callers continue to catch these.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/registered_functions.py#L800)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn lower_enums(file: &EsmFile) -> Result<EsmFile, EnumLoweringError>
```

Lower every `enum`-op node in `file` to a `{op: "const", value: <int>}`
node using the document's top-level `enums` block, returning a NEW
document. `file` is left untouched.

The canonical entry point (API_SPEC.md §8 items 14 and 15): TYPED, because
every other binding takes a typed document, and PURE, because TypeScript
and Python are pure and the mutating variants take a `_mut` suffix
(Julia's `!`). The in-place raw-JSON pass the loader itself runs is
[`lower_enums_raw`](/generated/api/extension/rust#x-lower_enums_raw).

Pre-condition: the input has been schema-validated and any
`apply_expression_template` ops have already been expanded.

Errors with an [`EnumLoweringError`](/generated/api/ref/enum_lowering_error) carrying one of the diagnostic codes
listed on [`lower_enums_raw`](/generated/api/extension/rust#x-lower_enums_raw).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/lower_enums.rs#L287) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.lower_enums.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func LowerEnums(file *ESMFile) (*ESMFile, error)
```

LowerEnums resolves every `enum` op in the file to a `{op: "const", value: <int>}` node per esm-spec §9.3, and returns the lowered document. The argument is NOT modified.

Canonical `lower_enums` (API\_SPEC.md §8 item 15): the canonical name is the PURE form in every binding, and the mutating twin takes a suffix (`Mut` here, `!` in Julia).

Returns an \*EnumLoweringError if any `enum` op names an undeclared enum or an undeclared symbol; the returned document is nil in that case, so a caller cannot mistake a partially-lowered value for a lowered one — which is the concrete reason the pure form is canonical. LowerEnumsMut, having written into the caller's document as it went, cannot make that promise.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/lower_enums.go#L263) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#LowerEnums)

</div>

</div>
