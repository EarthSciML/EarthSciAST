---
title: "schema_error (type)"
description: "Stable type · Validation"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Validation](/generated/api/topics/validation)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `SchemaError` | `SchemaError` | not exported | not exported | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct SchemaError
SchemaError(path::String, message::String, keyword::String)
SchemaError(path, message, keyword)
```

```julia
SchemaError
```

Represents a validation error with detailed information.
Contains path, message, and keyword from JSON Schema validation.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/validate.jl#L10)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
interface SchemaError {
    path: string;
    message: string;
    keyword: string;
}
```

Schema validation error with JSON Pointer path

**Properties**

- `path` — JSON Pointer path to the error location
- `message` — Human-readable error message
- `keyword` — AJV validation keyword that failed

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/parse.ts#L61)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

<p class="api-absent">Python does not export this type.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this type.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this type.</p>

</div>

</div>
