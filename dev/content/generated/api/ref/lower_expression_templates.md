---
title: "lower_expression_templates"
description: "Stable function · Load-time lowering and templates"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Load-time lowering and templates](/generated/api/topics/lowering)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `lower_expression_templates` | `lowerExpressionTemplates` | `lower_expression_templates` | not exported | `LowerExpressionTemplates` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
lower_expression_templates(raw_data)
```

```julia
lower_expression_templates(raw_data) -> OrderedDict{String,Any}
```

Run the §9.6.3 rewrite fixpoint over `raw_data` against each component-local
`expression_templates` block (esm-spec §9.6.4, Option B): auto `match` rules
fire, EAGER (target-bearing) `apply_expression_template` references are
expanded, NON-EAGER references survive as leaves, and each component's
registered `expression_templates` block is RETAINED on the returned tree. The
output is the rewritten native `OrderedDict{String,Any}` document, ready for
`coerce_esm_file`. A file with no template machinery is returned UNCHANGED
(the same object, by identity — callers use that to detect the fast path).

Throws [`ExpressionTemplateError`](/generated/api/ref/expression_template_error) on any of:

- file declares `esm` &lt; 0.4.0 but uses templates
- `apply_expression_template` references an undeclared template name, or a
  `match` rewrite rule (only match-less templates are invocable by name)
- bindings do not exactly match the template's `params`
- template-body references form a cycle or exceed
  `MAX_TEMPLATE_EXPANSION_DEPTH` (nested body references themselves are legal,
  esm-spec §9.7.3)
- the `match`-rule fixpoint fails to converge within `MAX_REWRITE_PASSES`
- declaration is malformed (params missing, body missing, etc.)

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/lower_expression_templates.jl#L1735)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function lowerExpressionTemplates<T extends object>(file: T): T
```

Load the file under Option B (reference preservation, esm-spec §9.6.4): fire
auto-applied `match` rules and eagerly expand target-bearing references to a
fixpoint per component (outermost-first, priority-ordered, bounded — §9.6.3),
but leave NON-eager `apply_expression_template` references intact (they
denote their expansion, §9.6.4 rule 2). The per-component
`expression_templates` registries are RETAINED — they are what [`expandDocument`](/generated/api/ref/expand_document) consumes (rule 2) and emit materializes (rule 5). Call-site
checks (§9.6.9), the reference-aware geometry-manifold check, and the
registration-time makearray-region check run on the reference-preserving form.

Returns a new file object; the input is not mutated.

Pre-condition: the input has been schema-validated.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-ts/src/lower-expression-templates.ts#L1842)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
lower_expression_templates(file: dict) -> dict
```

Run the load-time rewrite fixpoint (esm-spec §9.6.3) over `file`,
Option B (reference-preserving, esm-spec §9.6.4).

Per component, an outermost-first / priority-ordered / bounded-fixpoint
rewrite (`_rewrite_to_fixpoint`) fires the component's `match`
rewrite rules and EAGERLY expands target-bearing
`apply_expression_template` references (§9.6.4 rule 3), while NON-eager
references SURVIVE the fixpoint (§9.6.4 rule 4). The per-component
`expression_templates` blocks are RETAINED — emit materializes them
(§9.6.4 rule 5) and [`expand_document`](/generated/api/ref/expand_document) consumes them. Returns a new
dict (does not mutate input). Rejects a file whose rewriting does not
converge within `MAX_REWRITE_PASSES` passes with
`rewrite_rule_nonterminating`; call sites are checked for unknown template
/ bindings mismatch (§9.6.9).

Pre-condition: the input has been schema-validated.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/lower_expression_templates.py#L1272)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this function.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func LowerExpressionTemplates(view map[string]any) error
```

LowerExpressionTemplates runs the outermost-first + priority + bounded-fixpoint rewrite over `view` and strips the `expression_templates` blocks. Mutates `view` in place. Declaration order for `match`-rule tie-breaking is recovered via sorted-name fallback (an already-decoded map has no key order); callers with the raw JSON string should use the load path (`applyExpressionTemplatesToJSON`), which recovers genuine declaration order.

Pre-condition: the input has been schema-validated.

esm-spec §9.6.4 (Option B): lowering itself PRESERVES surviving `apply_expression_template` references and per-component registries; this entry point then Expands them in place (RFC out-of-line-expression-templates §7.7 Expand-at-build), so callers see the Option-A image (references replaced by their expansion, registries stripped) exactly as before. The reference-preserving form is available via ResolveAndLowerReferencePreserving (raw §9.7 pipeline) or EmitReferencePreserving (canonical emitted bytes).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/lower_expression_templates.go#L1393) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#LowerExpressionTemplates)

</div>

</div>
