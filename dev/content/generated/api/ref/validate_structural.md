---
title: "validate_structural"
description: "Stable function · Validation"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Validation](/generated/api/topics/validation)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `validate_structural` | not exported | not exported | not exported | `ValidateStructural` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
validate_structural(file::EsmFile)
```

```julia
validate_structural(file::EsmFile) -> Vector{StructuralError}
```

Validate structural consistency of ESM file according to spec Section 3.2.
Checks equation-unknown balance, reference integrity, reaction consistency,
and event consistency.

Error paths use 0-based JSON-Pointer slash style (e.g.
`/models/M/equations/0`), matching the shared cross-language fixtures in
`tests/invalid/expected_errors.json` and the TS/Python bindings.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/validate.jl#L442)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this function.</p>

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

```go
func ValidateStructural(file *ESMFile) *DetailedValidationResult
```

ValidateStructural performs comprehensive structural validation of an ESM file and returns the legacy message-oriented DetailedValidationResult. It runs the same single structural traversal as ValidateStructuralWithCodes and adapts each emitted StructuralError to the legacy ValidationMessage wording (see structuralErrorToLegacyMessage). Unit/dimensional checks are NOT part of this legacy surface — use ValidateStructuralWithCodes or Validate for those.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/validate.go#L290) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ValidateStructural)

</div>

</div>
