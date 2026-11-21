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
FlattenMetadata(source_systems::Vector{String}, coupling_rules_applied::Vector{String}, dimension_promotions_applied::Vector{NamedTuple}, opaque_coupling_refs::Vector{String}, merged_variable_renames::OrderedCollections.OrderedDict{String, String})
FlattenMetadata(source_systems, coupling_rules_applied, dimension_promotions_applied, opaque_coupling_refs, merged_variable_renames)
FlattenMetadata(; ...)
FlattenMetadata(source_systems::Vector{String}; ...)
FlattenMetadata(source_systems::Vector{String}, coupling_rules_applied::Vector{String}; dimension_promotions_applied, opaque_coupling_refs, merged_variable_renames)
```

```julia
FlattenMetadata
```

Provenance metadata for a flattened system.

Fields:
- `source_systems::Vector{String}`: names of the component systems that were
  flattened (sorted for determinism).
- `coupling_rules_applied::Vector{String}`: human-readable summary of each
  coupling entry applied.
- `dimension_promotions_applied::Vector{NamedTuple}`: records of each dimension
  promotion — e.g. `(variable="Chem.O3", source_domain=nothing, target_domain="grid2d", kind=:broadcast)`.
- `opaque_coupling_refs::Vector{String}`: opaque runtime references recorded
  for `operator_apply` and `callback` couplings.
- `merged_variable_renames::OrderedDict{String,String}`: every state spelling an
  `operator_compose` renaming match DELETED, mapped onto the survivor it was
  folded into (issue #230). The flattener's own retarget reaches equation ASTs;
  this is the map a CONSUMER that addresses a state by name needs — a
  `parameter_overrides` / `initial_conditions` key, an output selection — to
  resolve a spelling the merge moved out from under it. Empty for a document
  with no renaming merge, which is the overwhelming majority.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/flatten.jl#L27)

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
    couplingRewrittenNames: Set<string>;
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
- `couplingRewrittenNames` — Every name a COUPLING rule rewrote OUT of the flattened equations: a
  `variable_map`'s substituted target, plus every merged-away spelling of
  `FlattenMetadata.mergedVariableRenames`.
  
  Only the registry guard reads it. A surviving `expression_templates` body
  is authored source that no equation walk reaches, so a body naming one of
  these is REFUSED rather than resolved (see `checkRegistryCouplingRewrites`,
  CONFORMANCE_SPEC §5.35). Unlike `mergedVariableRenames` this is not a
  consumer-facing map: it says a name is GONE, not where it went.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-ts/src/flatten.ts#L361)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class FlattenMetadata
FlattenMetadata(source_systems: list[str] = list(), coupling_rules: list[str] = list(), operator_applies: list[str] = list(), callbacks: list[str] = list(), merged_variable_renames: dict[str, str] = dict(), coupling_rewritten_names: set[str] = set())
```

Provenance metadata for a FlattenedSystem.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/flatten.py#L481)

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
}
```

Provenance metadata for a flattening pipeline run.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/flatten.rs#L419) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.FlattenMetadata.html)

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
	// CouplingRewrittenNames is every name a COUPLING rule rewrote out of the
	// flattened equations: a `variable_map`'s substituted target, and every
	// merged-away spelling above.
	//
	// Only the registry guard reads it — a surviving expression-template body is
	// authored source no substitution reaches, so a body naming one of these is
	// REFUSED rather than resolved (checkRegistryCouplingRewrites,
	// CONFORMANCE_SPEC §5.35). Not a consumer-facing map, unlike
	// MergedVariableRenames: it says a name is GONE, not where it went.
	CouplingRewrittenNames map[string]bool
}
```

FlattenMetadata records provenance information about the flattening operation.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/flatten.go#L379) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#FlattenMetadata)

</div>

</div>
