---
title: "forcing_from_sample"
description: "Stable function · Other"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Other](/generated/api/topics/other)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `forcing_from_sample` | not exported | not exported | `forcing_from_sample` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
forcing_from_sample(sample, name::AbstractString; shape)
forcing_from_sample(sample, slot::ForcingSlot)
```

```julia
forcing_from_sample(sample, name::AbstractString; shape = nothing) -> Array{Float64}
forcing_from_sample(sample, slot::ForcingSlot) -> Vector{Float64}
```

The buffer of the data-fed parameter `name` built from one
[`provider_sample`](/generated/api/extension/julia#x-provider_sample) result: the check and conversion
[`esm_problem`](/generated/api/ref/esm_problem-function) applies to the sample of every provider it binds whole
(a const provider, a discrete provider at each refresh, and a provider that
discovers a loader extent; API_SPEC §5.8, "Forcing sets"). A runtime that
builds its own [`ForcingSet`](/generated/api/ref/forcing_set-type)s from provider samples calls this to get,
bit for bit, the buffer `esm_problem` builds from the same sample. A GATED
provider is not bound whole: `esm_problem` fetches only the rows its gating set
selects, so its buffer is that slab, not this function of a whole sample.

`sample` is what `provider_sample` returned: an `AbstractDict` keyed by
flattened parameter name, from which the `name` entry is taken, or a bare
`AbstractArray` or `Real` (a single-variable sample, which is the field
itself; a `Real` is a 0-d field). The result is a fresh dense
`Array{Float64}` with the field's dimensions, in the order the provider
delivered them (a source's file order, the record dimension first when two
records are delivered), so its linear order is column-major over those
dimensions: the order a forcing set reads a slot's buffer in.

With `shape` (the parameter's declared shape resolved, as a
[`ForcingSlot`](/generated/api/ref/forcing_slot) carries it: any collection of integers, a `Vector` or a
`Tuple`) the field's size must equal it, axis by axis, and an empty shape takes
a field of one value; any other field is a `DimensionMismatch`. `esm_problem`
applies the same check against each parameter's declared shape, wherever that
shape resolves before the build, so a sample it accepts passes here. The
`ForcingSlot` method checks against `slot.shape` and returns the buffer as a
`Vector{Float64}`, ready for [`forcing_set`](/generated/api/ref/forcing_set-function) or
[`replace_forcing`](/generated/api/extension/julia#x-replace_forcing).

A declared `unit_conversion` (esm-spec §8.5) is NOT applied here: a provider
from [`providers_from_document`](/generated/api/extension/julia#x-providers_from_document) applies it when it delivers the sample,
so the sample is already in the parameter's declared units, and applying it
again would apply it twice. A sample with no `name` entry is a `RefreshError`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/ae13cc8f0c7013724cd3011b89390f836e34b5ad/pkg/EarthSciAST.jl/src/data_refresh.jl#L325)

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

```rust
pub fn forcing_from_sample(sample: &HashMap<String, NativeField>, slot: &ForcingSlot) -> Result<Arc<[f64]>, ProviderError>
```

The buffer of `slot` built from one provider sample: the check and the
conversion [`crate::esm_problem`](/generated/api/ref/esm_problem-function) applies to a sample from a provider in
`ProblemOptions::providers`, so a runtime that builds its own
[`ForcingSet`](/generated/api/ref/forcing_set-type)s from provider samples gets, bit for bit, the buffer
`RhsProgram::default_forcing` holds for the same sample (API_SPEC §5.8,
"Forcing sets").

`sample` is what a `crate::provider::CadenceProvider` returned
(`materialize()` for a const provider, `refresh(t)` for a discrete one). It
must hold exactly one field, whatever that field is called: a provider in
`ProblemOptions::providers` feeds the one parameter its key names, so the
field's own name is not read. This differs from the Julia binding, whose
provider samples are keyed by parameter name, because each binding's
provider contract differs. The field's array dimensions, in the order the
provider delivered them (a source's file order, the record dimension first
when two records are delivered), must be `slot.shape`, axis by axis; a 0-d
slot takes an array of exactly one element. `esm_problem` refuses a sample
whose field does not have the parameter's declared shape, at `materialize()`
and at every `refresh(t)`, so the two accept the same samples. The buffer
is the array's values column-major over those dimensions (first index
fastest), the order a forcing set reads a slot's buffer in.

A declared `unit_conversion` (esm-spec §8.5) is NOT applied here: a
provider from `esio_provider::providers_from_document` (feature `esio`) applies
it when it delivers the sample, so the sample is already in the
parameter's declared units, and applying it again would apply it twice.

A provider passed to `esm_problem` in `ProblemOptions::build_providers` is
consumed by the build instead, which also checks the declared shape but
rounds the sample to the document's working precision (`domain.element_type`)
for a Float32 document; this function does not round.

**Errors**

A sample that does not hold exactly one field, or whose field's array does
not have the slot's shape.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/ae13cc8f0c7013724cd3011b89390f836e34b5ad/pkg/earthsci-ast-rs/src/simulate_array/range/forcing.rs#L307) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.forcing_from_sample.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this function.</p>

</div>

</div>
