---
title: "resolve_template_machinery"
description: "Stable function · Load-time lowering and templates"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Load-time lowering and templates](/generated/api/topics/lowering)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `resolve_template_machinery` | `resolveTemplateMachinery` | `resolve_template_machinery` | `resolve_template_machinery` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
resolve_template_machinery(raw_data, base_path::AbstractString; metaparameters, load_ref, mount_declared, mounted_leaf)
```

```julia
resolve_template_machinery(raw_data, base_path;
                           metaparameters=Dict{String,Int}(), load_ref=nothing,
                           mount_declared=nothing, mounted_leaf=false)
```

Resolve every esm-spec §9.7 construct of the ROOT document `raw_data`
(relative import refs resolve against `base_path`): imports recursively with
per-edge instantiation, `index_sets` merge, metaparameter close
(`metaparameters` is the loader-API binding site 4; already-closed edge
bindings win, then API bindings, then defaults) and fold, expression-position
substitution, and — for a root library file — §9.7.3 body composition.

`load_ref` is an optional import-edge resolver
`(ref, base_dir, origin) -> (raw_doc, target_base_dir)` — a test seam
mirroring [`expand_coupling_imports`](/generated/api/ref/expand_coupling_imports)'s kwarg; `nothing` (the default)
uses the file/URL loader `_load_import_raw`.

Returns an order-preserving native tree ready for
[`lower_expression_templates`](/generated/api/ref/lower_expression_templates) with `expression_template_imports`
consumed — that IS an import edge — and the top-level `expression_templates` /
`metaparameters` DECLARATIONS restored VERBATIM from a pre-folding snapshot
(esm-spec §9.6.4 rule 5: Option A expands call sites, it does not delete
declarations; a template-library file MUST round-trip to itself). `nothing`
when the document carries no §9.7 machinery (the fast path).

`mount_declared` widens the §9.7.6 site-4 check to the names declared by the
documents this one mounts — see
`_collect_mount_declared_metaparameters`. `mounted_leaf` says this call
IS a §4.7 mount edge, so an index-set `size` this scope cannot close stays
symbolic for the MOUNTING registry to close (§9.7.6 site 5).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/template_imports.jl#L2431)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function resolveTemplateMachinery(rawData: unknown, basePath: string, options?: TemplateResolveOptions): JsonObject | null
```

Resolve every esm-spec §9.7 construct of the ROOT document `rawData`
(relative import refs resolve against `basePath`): imports recursively
with per-edge instantiation, `index_sets` merge, metaparameter close
(`options.metaparameters` is the loader-API binding site 4;
already-closed edge bindings win, then API bindings, then defaults) and
fold, expression-position substitution, and — for a root library file —
§9.7.3 body composition.

Returns an order-preserving plain-object tree ready for
`lowerExpressionTemplates` with `expression_template_imports`,
`metaparameters`, and top-level `expression_templates` consumed (Option A
round-trip: none survives `parse → emit`), or `null` when the document
carries no §9.7 machinery and needs no rewrite.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/template-imports.ts#L2168)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
resolve_template_machinery(raw: Any, base_path: str, metaparameters: dict[str, int] | None = None, *, mount_declared: frozenset[str] | None = None, mounted_leaf: bool = False) -> dict[str, Any] | None
```

Resolve every esm-spec §9.7 construct of the ROOT document `raw`
(relative import refs resolve against `base_path`): imports recursively
with per-edge instantiation, `index_sets` merge, metaparameter close
(`metaparameters` is the loader-API binding site 4; already-closed edge
bindings win, then API bindings, then defaults) and fold,
expression-position substitution, and — for a root library file — §9.7.3
body composition.

Returns a new order-preserving dict tree ready for
[`lower_expression_templates`](/generated/api/ref/lower_expression_templates)
with `expression_template_imports` consumed — that IS an import edge — and
the top-level `expression_templates` / `metaparameters` DECLARATIONS
restored VERBATIM from a pre-folding snapshot (esm-spec §9.6.4 rule 5:
Option A expands call sites, it does not delete declarations). `None` when
the document carries no §9.7 machinery. Does not
mutate the input.

`mount_declared` widens the site-4 check to the names declared by the
documents this one mounts — see
`collect_mount_declared_metaparameters`. `mounted_leaf` says this
call IS a §4.7 mount edge, so index-set sizes this scope cannot close stay
symbolic for the mounting registry to close (§9.7.6 site 5).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/template_imports.py#L2327)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn resolve_template_machinery(raw_data: &Value, base_path: &Path, metaparameters: &BTreeMap<String, i64>) -> Result<Option<Value>, ExpressionTemplateError>
```

Resolve every esm-spec §9.7 construct of the ROOT document `raw_data`
(relative import refs resolve against `base_path`): imports recursively
with per-edge instantiation, `index_sets` merge, metaparameter close
(`metaparameters` is the loader-API binding site 4; already-closed edge
bindings win, then API bindings, then defaults) and fold,
expression-position substitution, and — for a root library file — §9.7.3
body-reference validation.

Returns an order-preserving JSON tree ready for
`crate::lower_expression_templates::lower_expression_templates` with
`expression_template_imports` consumed, and the top-level
`expression_templates` / `metaparameters` DECLARATIONS restored verbatim from
a pre-folding snapshot (esm-spec §9.6.4 rule 5 — Option A expands call sites,
it does not delete declarations). `Ok(None)` when the document carries no
§9.7 machinery.

The document is processed as six named phases (each a helper below, in
this exact order): top-level scope resolution, per-component imports,
metaparameter close, name-collision check, expression-position
substitution, and structural-site folding.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/template_imports.rs#L2730) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.resolve_template_machinery.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this function.</p>

</div>

</div>
