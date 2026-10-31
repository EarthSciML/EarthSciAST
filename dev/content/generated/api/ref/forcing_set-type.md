---
title: "forcing_set (type)"
description: "Stable type · Other"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Other](/generated/api/topics/other)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `ForcingSet` | not exported | not exported | `ForcingSet` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
mutable struct ForcingSet
ForcingSet(slots::Vector{ForcingSlot}, bufs::Vector{Vector{Float64}}, epoch::UInt64)
ForcingSet(slots, bufs, epoch)
```

```julia
ForcingSet
```

The forcing inputs of an evaluation (API_SPEC §5.8): one column-major buffer per
[`forcing_slots`](/generated/api/extension/julia#x-forcing_slots) entry, in slot order, and an epoch no other set in the
process carries. Never mutated: the set holds its buffers by reference, so
writing into one after building the set is undefined behaviour (the epoch would
not change); build a new set instead ([`replace_forcing`](/generated/api/extension/julia#x-replace_forcing) shares every
other buffer). Build one with [`forcing_set`](/generated/api/ref/forcing_set-function) or
[`default_forcing_set`](/generated/api/ref/default_forcing_set).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/rhs_program.jl#L70)

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
pub struct ForcingSet {
    /* private fields */
}

impl ForcingSet { pub fn new(prog: &RhsProgram, bufs: Vec<Arc<[f64]>>) -> Result<ForcingSet, RhsError> }

impl ForcingSet { pub fn replace(&self, slot: usize, buf: Arc<[f64]>) -> Result<ForcingSet, RhsError> }

impl ForcingSet { pub fn epoch(&self) -> u64 }

impl ForcingSet { pub fn slots(&self) -> &[ForcingSlot] }

impl ForcingSet { pub fn buffer(&self, k: usize) -> &[f64] }
```

The forcing a program evaluation reads (API_SPEC §5.8): one immutable
buffer per `RhsProgram::forcing_slots` entry, stamped with a
process-unique epoch. Refresh is a swap: `Self::replace` makes a new set
(a new epoch) sharing every other buffer, and a call on the new set
re-runs what reads forcing. Cheap to clone; `Send + Sync`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/simulate_array/range/forcing.rs#L173) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.ForcingSet.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this type.</p>

</div>

</div>
