---
title: "subsystem_ref_error"
description: "Stable error · Load-time lowering and templates"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** error · **Topic:** [Load-time lowering and templates](/generated/api/topics/lowering)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `SubsystemRefError` | not exported | `SubsystemRefError` | not exported | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct SubsystemRefError <: EarthSciASTError
SubsystemRefError(message::AbstractString; code, ref, subsystem, parent_model)
```

```julia
SubsystemRefError
```

Exception thrown when subsystem reference resolution fails.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/resolve.jl#L2055)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this error.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class SubsystemRefError(EarthSciAstError)
SubsystemRefError(message: str, code: str = '', path: str = '')
```

Exception raised when a subsystem reference cannot be resolved.

Carries the shared diagnostic `code` and JSON-Pointer `path` so that
[`earthsci_ast.validation.validate`](/generated/api/ref/validate) can surface it as a *structural*
finding rather than an opaque `parse` blob at `$`. The cross-language
contract (`tests/invalid/expected_errors.json`) pins these fixtures as
`"schema_errors": []` plus one coded structural error at the pointer of the
offending mount — e.g. `unresolved_subsystem_ref` @
`/models/Atmosphere/subsystems/Missing`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/parse.py#L130)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this error.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this error.</p>

</div>

</div>
