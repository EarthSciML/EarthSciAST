---
title: "parse_unit_conversion"
description: "Stable function · Units"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Units](/generated/api/topics/units)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `parse_unit_conversion` | not exported | `parse_unit_conversion` | not exported | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
parse_unit_conversion(raw; variable_name)
```

```julia
parse_unit_conversion(raw; variable_name) -> Nothing | Float64 | ASTExpr
```

Parse a loader variable's RAW `unit_conversion` (`number | Expression`).

`nothing` (the field is absent, or `null`) means the variable declares no
conversion — so a document that declares none costs nothing and behaves exactly
as it did before this existed.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/unit_conversion.jl#L36)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this function.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
parse_unit_conversion(raw: Any, *, variable_name: str) -> float | ExprNode | None
```

Parse a loader variable's RAW `unit_conversion` (esm-spec §8.5).

The JSON spelling is ONE `Expression`, which admits all three forms: a
plain multiplicative factor, a bare reference string, or a full Expression
AST for a conversion that is not a pure scale — an affine one like °F→K,
which §4.8.1 keeps OUT of the dimensional metadata on purpose ("a unit
conversion that needs the offset is a `unit_conversion` expression, not a
dimensional judgement").

Returns `None` when the variable declares none, so a document that
declares no conversion costs nothing and behaves exactly as before. This is
the raw-document entry point the provider paths use; the typed parse
(`earthsci_ast.parse`) produces the same two shapes.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/data_sources/variables.py#L60)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this function.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this function.</p>

</div>

</div>
