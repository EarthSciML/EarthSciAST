---
title: "coupling_role"
description: "Stable type · Document types"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Document types](/generated/api/topics/document-types)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | not exported | not exported | `CouplingRole` | `CouplingRole` |


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

<p class="api-absent">Python does not export this type.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct CouplingRole {
    pub description: Option<String>,
}
```

A coupling-library formal component role (esm-spec §10.9). Present only in
a coupling-library file's top-level `coupling_roles` map; each entry carries
an optional human-readable description. Roles are formal parameters (names,
not types), bound to actual components at a `coupling_import`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/types/components.rs#L634) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.CouplingRole.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type CouplingRole struct {
	Description *string `json:"description,omitempty"`
}
```

CouplingRole is one entry in a coupling-library file's `coupling_roles` map (esm-spec §10.9): a formal component role (a name, not a type), carrying an optional human-readable description. Roles are bound to actual components at a `coupling_import` (esm-spec §10.10).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/types.go#L1002) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CouplingRole)

</div>

</div>
