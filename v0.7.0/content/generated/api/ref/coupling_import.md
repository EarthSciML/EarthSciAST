---
title: "coupling_import"
description: "Stable type · Document types"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Document types](/generated/api/topics/document-types)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `CouplingImport` | not exported | `CouplingImport` | not exported | `CouplingImport` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct CouplingImport <: CouplingEntry
CouplingImport(ref::String; ...)
CouplingImport(ref::String, bind::AbstractDict; description)
```

```julia
CouplingImport <: CouplingEntry
```

Reuse of a coupling-library file (esm-spec §10.9, §10.10). Names a library by
`ref` and binds each of the library's declared roles to a component in the
assembly via `bind` (role name → a top-level `models`/`reaction_systems` key,
or a dotted `Parent.Child` subsystem path). At flatten the
import expands into concrete `variable_map`/`couple`/`operator_compose`/`event`
edges by substituting the bound actual for every role-named top-level segment
(`expand_coupling_imports`); the entry itself round-trips intact.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/types.jl#L1979)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this type.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class CouplingImport(BaseCouplingEntry)
CouplingImport(coupling_type: CouplingType, description: str | None = None, ref: str | None = None, bind: dict[str, str] = dict())
```

Coupling entry that imports a coupling-library file (esm-spec §10.10).

`ref` is a §4.7 reference to a coupling-library file (a document with a
top-level `coupling_roles` map); `bind` maps every declared role name to
an assembly component (a top-level models/reaction_systems key
or a dotted `Parent.Child` subsystem path). The entry declares no wiring of
its own — at flatten (`earthsci_ast.coupling_imports`) it expands into
concrete edges spliced in its position, while the source entry is preserved
for round-trip.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/esm_types.py#L1156)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this type.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type CouplingImport struct {
	Type        string            `json:"type"` // "coupling_import"
	Ref         string            `json:"ref"`
	Bind        map[string]string `json:"bind,omitempty"`
	Description *string           `json:"description,omitempty"`
}

func (c CouplingImport) CouplingType() string
```

CouplingImport reuses a coupling-library file (esm-spec §10.9, §10.10): it imports the library named by `Ref` and binds each of its declared roles to a component in the assembly via `Bind` (role name -&gt; scoped component reference). At flatten (esm-spec §10.10.3) the import expands into concrete variable\_map / couple / operator\_compose / event edges by substituting the bound actual for every role-named top-level segment; the entry itself round-trips intact. Carries no `expression_template_imports` (injection is a property of the wiring entries, not of an import indirection).

**Methods**

```go
func (c CouplingImport) CouplingType() string
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/types.go#L989) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CouplingImport)

</div>

</div>
