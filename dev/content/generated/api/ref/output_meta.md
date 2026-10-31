---
title: "output_meta"
description: "Stable type · Runtime I/O"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Runtime I/O](/generated/api/topics/runtime-io)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `OutputMeta` | outside profile | not exported | `OutputMeta` | outside profile |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct OutputMeta
OutputMeta(model_name::String, index_sets::Dict{String, Int64}, var_dims::Dict{String, Vector{String}}, var_attrs::Dict{String, Dict{String, Any}}, var_types::Dict{String, String}, coordinates::Dict{String, Any}, time_dim::String)
OutputMeta(model_name, index_sets, var_dims, var_attrs, var_types, coordinates, time_dim)
```

```julia
OutputMeta
```

The document-derived output metadata carried by an [`EsmProblem`](/generated/api/ref/esm_problem-type) so a
streaming sink can name axes and emit CF coordinates (RFC §7–§8). Distilled from
the flattened run document by [`derive_output_meta`](/generated/api/ref/derive_output_meta).

* `model_name::String` — the first flattened model's key (namespacing prefix of
  the `var_map`'s base names).
* `index_sets::Dict{String,Int}` — index-set name → axis length (interval `size`;
  categorical member count).
* `var_dims::Dict{String,Vector{String}}` — base variable name → its declared
  `shape` (ordered index-set / dim names). Absent for scalars. Keyed by BOTH the
  bare name and its `Model.`-qualified form, because a flat state's element names
  are namespaced on the coupled/flattened path and bare on the single-model path;
  a bare name two models would make ambiguous is dropped, so an ambiguous lookup
  falls back to positional axis names rather than guessing.
* `var_attrs::Dict{String,Dict{String,Any}}` — base variable name → CF variable
  attributes retained from the doc (`units`, `standard_name`, `description` when
  present). Keyed like `var_dims`.
* `var_types::Dict{String,String}` — base variable name → its DERIVED kind
  (`"observed"` for an unknown a bare-variable-LHS equation defines, else the
  declared `"unknown"` / `"parameter"`), so observed fields can be gated on the
  caller's request list (RFC decision 8). Derived rather than read off the
  declaration because esm 1.0.0 declares only two types (esm-spec §6.3.1).
  Keyed like `var_dims`.
* `coordinates::Dict{String,Any}` — the additive `coordinates` registry (§8.3),
  verbatim: entry name → `{values|source, standard_name, units, axis}`. Empty when
  the document declares none.
* `time_dim::String` — the record-axis name: the document's
  `domain.independent_variable` (RFC §7), falling back to `"time"`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/data_output.jl#L513)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">Not available in TypeScript. TypeScript is outside the runtime I/O capability profile (Julia, Python, Rust): data-source providers, refresh cadence, output sinks, checkpoints.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

<p class="api-absent">Python does not export this type.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct OutputMeta {
    pub model_names: Vec<String>,
    pub index_sets: BTreeMap<String, usize>,
    pub var_dims: BTreeMap<String, Vec<String>>,
    pub var_attrs: BTreeMap<String, Map<String, Value>>,
    pub var_types: BTreeMap<String, VariableType>,
    pub observed_unknowns: BTreeSet<String>,
    pub coordinates: BTreeMap<String, Coordinate>,
    pub time_dim: String,
}

impl OutputMeta { pub fn dims_of(&self, base: &str) -> Option<&Vec<String>> }

impl OutputMeta { pub fn type_of(&self, base: &str) -> Option<&VariableType> }

impl OutputMeta { pub fn is_observed(&self, base: &str) -> bool }

impl OutputMeta { pub fn attrs_of(&self, base: &str) -> Option<&JsonMap<String, JsonValue>> }
```

The document slice a streaming writer needs so it can name axes and emit CF
coordinates (RFC §7–§8) without importing the document model. Distilled from
an [`EsmFile`](/generated/api/ref/esm_file) by [`derive_output_meta`](/generated/api/ref/derive_output_meta); the Rust mirror of Julia's
`OutputMeta`.

The `var_*` maps are keyed by BOTH the bare variable name and its
`Model.`-qualified form, because a flat state's element names are namespaced
on the coupled/flattened path and bare on the single-model path. A bare key
that two models would make ambiguous is dropped, so an ambiguous lookup
falls back to positional axis names rather than guessing.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/data_output.rs#L563) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.OutputMeta.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Not available in Go. Go is outside the runtime I/O capability profile (Julia, Python, Rust): data-source providers, refresh cadence, output sinks, checkpoints.</p>

</div>

</div>
