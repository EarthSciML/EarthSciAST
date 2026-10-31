---
title: "expr"
description: "Stable type · Expressions"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Expressions](/generated/api/topics/expressions)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | not exported | `Expr` | `Expr` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this type.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this type.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
Expr = Union[int, float, str, ExprNode]
```

An expression (esm-spec §4): a numeric literal (`int` or `float`), a
variable or parameter reference (`str`), or an operator node
([`ExprNode`](/generated/api/ref/expr_node)) whose `args` are themselves expressions.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/esm_types.py#L166)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub enum Expr {
    Integer(i64),
    Number(f64),
    Variable(String),
    Operator(Arc<ExpressionNode>),
}

impl Expr { pub fn to_unicode(&self) -> String }

impl Expr { pub fn operator(node: ExpressionNode) -> Expr }

impl Expr { pub fn node_mut(&mut self) -> Option<&mut ExpressionNode> }
```

Mathematical expression: a number literal, variable reference, or operator node.

Per discretization RFC §5.4.1, integer and float literals are distinct AST
node kinds. On the wire (§5.4.6 round-trip parse rule), a JSON-number
token containing `.`, `e`, or `E` deserializes to `Expr::Number`; a token
matching the integer grammar `-?(0|[1-9][0-9]*)` deserializes to
`Expr::Integer`. The hand-written `Deserialize` impl below dispatches on
the incoming JSON token type directly, which is what an
`#[serde(untagged)]` derive would decide by trying `Integer` before
`Number`: strict integer JSON tokens bind to `Integer`, float tokens to
`Number`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/types/expression.rs#L16) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.Expr.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this type.</p>

</div>

</div>
