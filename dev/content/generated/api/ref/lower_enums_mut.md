---
title: "lower_enums_mut"
description: "Stable function · Load-time lowering and templates"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Load-time lowering and templates](/generated/api/topics/lowering)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | not exported | `lower_enums_mut` | `lower_enums_mut` | `LowerEnumsMut` |


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

```python
lower_enums_mut(file: EsmFile) -> EsmFile
```

In-place twin of [`lower_enums`](/generated/api/ref/lower_enums): lower every `enum` op in `file`
itself, and return it (API_SPEC.md §8 item 15).

The `_mut` suffix is the cross-binding spelling for a mutating variant whose
canonical name is pure — Julia writes the same thing as `lower_enums!`.
Use this when a caller elsewhere already holds a reference to `file` (or
to one of its models) and must see the lowered trees; the load path in
`earthsci_ast.parse` is exactly that case.

Raises the same [`EnumLoweringError`](/generated/api/ref/enum_lowering_error) as [`lower_enums`](/generated/api/ref/lower_enums), and
raises it BEFORE grafting anything, so a document that fails to lower is
left untouched rather than half-lowered.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/registered_functions.py#L842)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn lower_enums_mut(file: &mut EsmFile) -> Result<(), EnumLoweringError>
```

[`lower_enums`](/generated/api/ref/lower_enums), applied in place. The `_mut` spelling API_SPEC.md §8 item
15 assigns to a mutating variant (Julia spells the same thing
`lower_enums!`).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/lower_enums.rs#L306) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.lower_enums_mut.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func LowerEnumsMut(file *ESMFile) error
```

LowerEnumsMut is LowerEnums applied IN PLACE: it walks every expression tree in the file and resolves each `enum` op to a `{op: "const", value: <int>}` node per esm-spec §9.3, mutating the file and returning nil, or returning an \*EnumLoweringError if any enum op references an undeclared enum or symbol.

On error the file is left PARTIALLY LOWERED — the pass writes as it walks and does not roll back. A caller that cannot tolerate that wants LowerEnums.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/lower_enums.go#L370) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#LowerEnumsMut)

</div>

</div>
