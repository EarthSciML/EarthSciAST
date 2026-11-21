---
title: "subsystem_ref"
description: "Stable type · Other"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Other](/generated/api/topics/other)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `SubsystemRef` | not exported | not exported | `SubsystemRef` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct SubsystemRef <: EarthSciAST.SubsystemNode
SubsystemRef(ref::String, bindings::Dict{String, Int64}, expression_template_imports::Vector{Any}, index_set_rename::Union{Nothing, OrderedCollections.OrderedDict{String, String}}, url_substitutions)
SubsystemRef(ref, bindings, expression_template_imports, index_set_rename, url_substitutions)
SubsystemRef(ref::AbstractString, bindings::AbstractDict, injected::AbstractVector, index_set_rename::Union{Nothing, AbstractDict})
SubsystemRef(ref::AbstractString, bindings::AbstractDict, injected::AbstractVector)
SubsystemRef(ref::AbstractString, bindings::AbstractDict)
SubsystemRef(ref::AbstractString)
```

```julia
SubsystemRef(ref::String)
SubsystemRef(ref::String, bindings::Dict{String,Int})
```

Unresolved reference to an external ESM file used as a subsystem (esm-spec §4.7).
Produced by `coerce_model` for a `{"ref": "..."}` subsystem entry and replaced
in place by `resolve_subsystem_refs!` with the loaded `Model`.
A `SubsystemRef` only survives parsing when references are not resolved (e.g.
`load_string` without a base path); `load_path` always resolves them.
`bindings` closes the referenced document's open metaparameters at this edge
(esm-spec §9.7.6 binding site 3 — e.g. a convergence wrapper instantiating a
problem file at a given size). `expression_template_imports` are the raw
§9.7.2 import entries injected into the REFERENCED component's own template
scope (esm-spec §9.7.10 form A — assembler-chosen discretization for a mounted
PDE leaf); they are threaded into the referenced document's load and consumed by
the §9.6.3 fixpoint, so a resolved subsystem round-trips as the lowered inline
component and the field does not survive `parse → emit`.
`index_set_rename` translates the mounted document's index-set names into the
mounting document's vocabulary at load (esm-spec §4.7 "Mount-edge index-set
renaming") — the §9.7.7 renaming mechanism at a component-mount edge, restricted
to index sets. Like the two fields above it is consumed at the mount and does not
survive `parse → emit`.
`url_substitutions` binds the bare `{name}` placeholders of the mounted
document's `data_sources` locations (esm-spec §4.7 "Binding a data source's
location at the mount"). Kept RAW (`nothing` when absent) so its shape is
checked at the edge, with the edge's diagnostics; consumed at the mount like the
fields above.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/pkg/EarthSciAST.jl/src/types.jl#L1449)

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
pub struct SubsystemRef {
    pub target: String,
    pub edge: Map<String, Value>,
}
```

An unresolved `{"ref": …}` mount edge (schema `SubsystemRef`).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/pkg/earthsci-ast-rs/src/types/subsystem.rs#L32) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.SubsystemRef.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this type.</p>

</div>

</div>
