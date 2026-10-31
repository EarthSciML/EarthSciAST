---
title: "validate_schema"
description: "Stable function · Validation"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Validation](/generated/api/topics/validation)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `validate_schema` | `validateSchema` | not exported | not exported | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
validate_schema(data)
```

```julia
validate_schema(data::Any) -> Vector{SchemaError}
```

Validate `data` (a native JSON tree of `Dict`/`Vector`/scalars) against the ESM
schema. Returns an empty vector when valid; otherwise ONE `SchemaError` per
schema violation (CONFORMANCE_SPEC §7.1.2), each carrying:

- `path` — the RFC-6901 JSON Pointer of the offending node (document root `""`,
  0-based array indices);
- `keyword` — the JSON-Schema keyword that failed (`required`, `type`, `enum`,
  `minItems`, `oneOf`, `additionalProperties`, …);
- `message` — free human-readable text (not part of the conformance contract).

Unlike JSONSchema.jl's single-issue `validate`, this enumerates leaf failures
INSIDE failed `oneOf`/`anyOf`/`allOf`/`if` branches (see
`_collect_schema_errors!`), matching TypeScript's AJV `allErrors` output.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/validate.jl#L403)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function validateSchema(data: unknown): SchemaError[]
```

Validate data against the ESM schema

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-ts/src/parse.ts#L138)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

<p class="api-absent">Python does not export this function.</p>

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
