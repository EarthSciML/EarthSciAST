---
title: "desugar_pushdown"
description: "Stable function · Load-time lowering and templates"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Load-time lowering and templates](/generated/api/topics/lowering)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | not exported | `desugar_pushdown` | `desugar_pushdown` | not exported |


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
desugar_pushdown(esm: dict, model_name: str | None = None) -> dict
```

Recognise the projection-pushdown pattern in `esm`'s named model and,
when it matches, return a NEW document with the four constructs desugared
in (a `kind:"derived"` index set, a `distinct:true` overlap-gated
producer aggregate, a `member_factor` const parameter, and an
inspectable `gated_select` record) plus the reduction axis of the
matched E / A / conc nodes re-pointed onto the generated derived set.
Returns `esm` UNCHANGED (the same object) when no model is selected, the
pattern does not match, or the reduction's semiring is not the additive
`(+, 0)` monoid (the soundness guard).

IDEMPOTENT: a document already carrying the provenance record
`metadata.x_esd.pushdown` is returned unchanged — the generated
constructs would otherwise re-match and stack a second
`pd_support__pd_support__…` layer.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/pushdown_rewrite.py#L1367)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn desugar_pushdown<'a>(esm: &'a Value, model_name: Option<&str>) -> Result<Cow<'a, Value>, PushdownRewriteError>
```

Recognise the projection-pushdown pattern in `esm`'s named model and, when
it matches, return a NEW document (`Cow::Owned`) with the four constructs
desugared in (a `kind:"derived"` index set, a `distinct:true` overlap-gated
producer aggregate, a `member_factor` const parameter, and an inspectable
`gated_select` record) plus the reduction axis of the matched E / A / conc
nodes re-pointed onto the generated derived set. Returns the input
UNCHANGED (`Cow::Borrowed`) when no model is selected, the pattern does not
match, or the reduction's semiring is not the additive `(+, 0)` monoid
(the soundness guard).

IDEMPOTENT: a document already carrying the provenance record
`metadata.x_esd.pushdown` is returned unchanged — the generated constructs
would otherwise re-match and stack a second `pd_support__pd_support__…`
layer.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/pushdown_rewrite.rs#L1935) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.desugar_pushdown.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this function.</p>

</div>

</div>
