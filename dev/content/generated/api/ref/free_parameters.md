---
title: "free_parameters"
description: "Stable function · Variable classification"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Variable classification](/generated/api/topics/classification)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | `freeParameters` | `free_parameters` | `free_parameters` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this function.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function freeParameters(expr: Expr, model: Model): Set<string>
```

Extract free parameters from an expression within a model context

**Parameters**

- `expr` — Expression to analyze
- `model` — Model context to determine parameter vs state variables

**Returns**

Set of parameter names referenced in the expression

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-ts/src/expression.ts#L69)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
free_parameters(expr: Expr, model: Model) -> set[str]
```

Extract free parameters from an expression.

A parameter is a free variable that has type="parameter" in the model.

**Parameters**

- `expr` (`Expr`) — Expression to analyze
- `model` (`Model`) — Model containing variable type information

**Returns**

- `set[str]` — Set of parameter names found in the expression

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/expression.py#L63)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn free_parameters(expr: &Expr) -> HashSet<String>
```

Extract all free parameters from an expression

This is currently the same as free_variables since we don't distinguish
parameters from variables at the expression level.

**Arguments**

* `expr` - The expression to analyze

**Returns**

* Set of parameter names referenced in the expression

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/expression.rs#L33) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.free_parameters.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this function.</p>

</div>

</div>
