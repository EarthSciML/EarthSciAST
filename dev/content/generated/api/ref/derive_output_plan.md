---
title: "derive_output_plan"
description: "Stable function · Runtime I/O"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Runtime I/O](/generated/api/topics/runtime-io)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `derive_output_plan` | outside profile | not exported | `derive_output_plan` | outside profile |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
derive_output_plan(doc::AbstractDict, var_map::AbstractDict; observed)
derive_output_plan(var_map::AbstractDict, meta::OutputMeta; observed)
```

```julia
derive_output_plan(doc, var_map; observed = String[]) -> OutputPlan
derive_output_plan(var_map, meta::OutputMeta; observed = String[]) -> OutputPlan
```

Derive the whole output plan for a run (RFC §7–§9) — the Julia mirror of
`earthsci_ast::data_output::derive_output_plan`.

* `doc` — the (flattened) run document: axis names, axis lengths, CF attributes,
  the `coordinates` registry, and the record-axis name.
* `var_map` — the flat state-element name → flat index map.
* `observed` — the caller-named observed/derived fields to write alongside the
  state (RFC decision 8): output is the state PLUS these, not every observed
  field. A name selects the variable it names exactly; failing that, the ONE
  variable whose last dotted segment equals the name's (so `flux` selects
  `Box.flux`). A name whose last segment several variables share is refused with
  code `ambiguous_output_name`, and a name with no slot in the flat state is
  refused too — silently dropping or silently choosing a requested output is
  worse than refusing. A name an `operator_compose` merge deleted is NOT resolved
  here: the caller resolves it through `merged_variable_renames` first
  (CONFORMANCE_SPEC §5.17.4).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/data_output.jl#L892)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">Not available in TypeScript. TypeScript is outside the runtime I/O capability profile (Julia, Python, Rust): data-source providers, refresh cadence, output sinks, checkpoints.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

<p class="api-absent">Python does not export this function.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn derive_output_plan(doc: &EsmFile, slot_names: &[String], observed: &[String]) -> Result<OutputPlan, OutputError>
```

Derive the whole output plan for a run.

* `doc` — the (flattened) run document: axis names, axis lengths, CF
  attributes, and the `coordinates` registry.
* `slot_names` — the flat state-element names, index = flat index. This is
  `Solution::state_variable_names` / `ArrayCompiled::state_variable_names`,
  including any observed rows the runner appended.
* `observed` — the caller-named observed/derived fields to write alongside
  the state (RFC decision 8). Output is state PLUS these, not every observed
  field. A name selects the variable it names exactly; failing that, the
  ONE variable whose last dotted segment equals the name's (so `flux`
  selects `Box.flux`). A name an `operator_compose` merge deleted is NOT
  resolved here: the caller resolves it through `merged_variable_renames`
  first (CONFORMANCE_SPEC §5.17.4).

**Errors**
`OutputError::UnknownObserved` when a requested observed field has no slot
in `slot_names`; `OutputError::AmbiguousRequest` when a request names no
variable exactly and its last segment is shared; otherwise see [`derive_output_gridding`](/generated/api/ref/derive_output_gridding),
`apply_output_meta` and [`plan_dimension_coordinates`](/generated/api/ref/plan_dimension_coordinates).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/data_output.rs#L1016) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.derive_output_plan.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Not available in Go. Go is outside the runtime I/O capability profile (Julia, Python, Rust): data-source providers, refresh cadence, output sinks, checkpoints.</p>

</div>

</div>
