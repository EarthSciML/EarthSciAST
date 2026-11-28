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
struct SubsystemRefError <: EarthSciAST._LoadDiagnostic
SubsystemRefError(code::String, message::String, path::String, file::String, details::Dict{String, Any}, ref::String, subsystem::String, parent_model::String)
SubsystemRefError(code, message, path, file, details, ref, subsystem, parent_model)
SubsystemRefError(message::AbstractString; code, ref, subsystem, parent_model, path, file, details)
```

```julia
SubsystemRefError <: EarthSciASTError
```

A §4.7 mount that cannot be resolved: its file is missing, unreadable or does
not hold exactly the component asked for, or the mounts form a cycle. `code`
is required (`unresolved_subsystem_ref`, `ambiguous_subsystem_ref`,
`element_type_uncarried`). After the common fields (see `_LoadDiagnostic`)
come the `ref` as written and, for the `subsystems.<k>` form, the mount site
(`subsystem`, `parent_model`), which `validate` renders as
`/models/<parent_model>/subsystems/<subsystem>`.

    SubsystemRefError(message; code, ref = "", subsystem = "", parent_model = "", path = "", file = "", details = Dict())

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/load_errors.jl#L87)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/earthsci-ast-py/src/earthsci_ast/parse.py#L136)

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
