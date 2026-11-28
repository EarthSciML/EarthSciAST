---
title: "flatten_metadata"
description: "Stable type · Flatten"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Flatten](/generated/api/topics/flatten)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `FlattenMetadata` | `FlattenMetadata` | `FlattenMetadata` | `FlattenMetadata` | `FlattenMetadata` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct FlattenMetadata
FlattenMetadata(source_systems::Vector{String}, coupling_rules_applied::Vector{String}, dimension_promotions_applied::Vector{NamedTuple}, opaque_coupling_refs::Vector{String}, merged_variable_renames::OrderedCollections.OrderedDict{String, String}, reserved_liftings::Vector{Tuple{String, String, String}})
FlattenMetadata(source_systems, coupling_rules_applied, dimension_promotions_applied, opaque_coupling_refs, merged_variable_renames, reserved_liftings)
FlattenMetadata(; ...)
FlattenMetadata(source_systems::Vector{String}; ...)
FlattenMetadata(source_systems::Vector{String}, coupling_rules_applied::Vector{String}; dimension_promotions_applied, opaque_coupling_refs, merged_variable_renames, reserved_liftings)
```

```julia
FlattenMetadata
```

Provenance metadata for a flattened system.

Fields:
- `source_systems::Vector{String}`: names of the component systems that were
  flattened, in document order (models, then reaction systems).
- `coupling_rules_applied::Vector{String}`: human-readable summary of each
  coupling entry applied.
- `dimension_promotions_applied::Vector{NamedTuple}`: always empty; no flatten
  pass records into it.
- `opaque_coupling_refs::Vector{String}`: opaque runtime references recorded
  for `operator_apply` and `callback` couplings.
- `merged_variable_renames::OrderedDict{String,String}`: every state spelling an
  `operator_compose` renaming match DELETED, mapped onto the survivor it was
  folded into. The flattener's own retarget reaches equation ASTs;
  this is the map a CONSUMER that addresses a state by name needs — a
  `parameter_overrides` / `initial_conditions` key, an output selection — to
  resolve a spelling the merge moved out from under it. Empty for a document
  with no renaming merge, which is the overwhelming majority.
- `reserved_liftings::Vector{NTuple{3,String}}`: every `variable_map` whose
  `lifting` esm-spec §10.5 reserves (`mean`, `integral`), as
  `(from, to, lifting)` in coupling order after `coupling_import` expansion.
  Flatten leaves such an edge's source unreduced, so a build refuses the system
  (`_refuse_reserved_liftings`), from a flattened system as from a document.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/flatten.jl#L36)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
interface FlattenMetadata {
    sourceSystems: string[];
    couplingRules: string[];
    operatorApplies: string[];
    callbacks: string[];
    mergedVariableRenames: Record<string, string>;
}
```

Metadata describing the origin of the flattened system.

**Properties**

- `sourceSystems` — Names of all top-level source systems, in document order.
- `couplingRules` — Human-readable descriptions of every coupling rule, in array order.
- `operatorApplies` — `operator_apply` entries, recorded as opaque runtime references.
- `callbacks` — `callback` entries, recorded as opaque runtime references.
- `mergedVariableRenames` — Every state spelling an `operator_compose` renaming match DELETED, mapped
  onto the survivor it was folded into (issue #230).
  
  The flattener's own retarget reaches equation ASTs; this is the map a
  CONSUMER that addresses a state by name needs — a `parameter_overrides` /
  `initial_conditions` key, an output selection — to resolve a spelling the
  merge moved out from under it. Empty for a document with no renaming merge,
  which is the overwhelming majority.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/earthsci-ast-ts/src/flatten.ts#L413)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class FlattenMetadata
FlattenMetadata(source_systems: list[str] = list(), coupling_rules: list[str] = list(), operator_applies: list[str] = list(), callbacks: list[str] = list(), merged_variable_renames: dict[str, str] = dict(), reserved_liftings: list[tuple[str, str, str]] = list())
```

Provenance metadata for a FlattenedSystem.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/earthsci-ast-py/src/earthsci_ast/flatten.py#L553)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct FlattenMetadata {
    pub source_systems: Vec<String>,
    pub coupling_rules_applied: Vec<String>,
    pub dimension_promotions_applied: Vec<DimensionPromotionRecord>,
    pub implicit_interface_inferred: bool,
    pub merged_variable_renames: IndexMap<String, String>,
    pub coupling_rewritten_names: BTreeSet<String>,
    pub bound_inputs: IndexMap<String, (String, Option<f64>)>,
    pub reserved_liftings: Vec<(String, String, String)>,
}
```

Provenance metadata for a flattening pipeline run.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/earthsci-ast-rs/src/flatten.rs#L451) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.FlattenMetadata.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type FlattenMetadata struct {
	SourceSystems []string // names of systems that were flattened
	CouplingRules []string // descriptions of coupling rules applied
	// OperatorApplies are the `operator_apply` coupling entries, recorded as
	// opaque runtime references (§4.7.5 step 3).
	OperatorApplies []string
	// Callbacks are the `callback` coupling entries, likewise.
	Callbacks []string
	// MergedVariableRenames maps every state spelling an `operator_compose`
	// renaming match DELETED onto the survivor it was folded into (issue #230).
	//
	// The flattener's own retarget reaches equation ASTs; this is the map a
	// CONSUMER that addresses a state by name needs — a parameter_overrides /
	// initial_conditions key, an output selection — to resolve a spelling the
	// merge moved out from under it. Nil for a document with no renaming merge,
	// which is the overwhelming majority.
	MergedVariableRenames map[string]string
}
```

FlattenMetadata records provenance information about the flattening operation.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/earthsci-ast-go/pkg/esm/flatten.go#L418) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#FlattenMetadata)

</div>

</div>
