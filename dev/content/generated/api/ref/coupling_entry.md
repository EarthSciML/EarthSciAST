---
title: "coupling_entry"
description: "Stable type · Document types"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Document types](/generated/api/topics/document-types)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `CouplingEntry` | not exported | `CouplingEntry` | `CouplingEntry` | `CouplingEntry` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
abstract type CouplingEntry
```

```julia
abstract type CouplingEntry end
```

Abstract base type for coupling entries that connect model components.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/types.jl#L1837)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this type.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
CouplingEntry = Union[OperatorComposeCoupling, CouplingCouple, VariableMapCoupling, OperatorApplyCoupling, CallbackCoupling, EventCoupling, CouplingImport]
```

One entry of a document's `coupling` list (esm-spec §10): any of the
coupling dataclasses, told apart by their `coupling_type` field
(`CouplingType`), which is the wire `type` discriminator.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/esm_types.py#L1177)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub enum CouplingEntry {
    OperatorCompose { systems: Vec<String>, translate: Option<Value>, lifting: Option<String>, require_match: Option<bool>, description: Option<String> },
    Couple { systems: Vec<String>, connector: Value, lifting: Option<String>, description: Option<String> },
    VariableMap { from: String, to: String, transform: VariableMapTransform, factor: Option<f64>, lifting: Option<String>, description: Option<String> },
    OperatorApply { operator: String, description: Option<String> },
    Callback { callback_id: String, config: Option<Value>, description: Option<String> },
    Event { event_type: String, name: Option<String>, conditions: Option<Vec<Expr>>, trigger: Option<DiscreteEventTrigger>, affects: Option<Vec<AffectEquation>>, affect_neg: Option<Vec<AffectEquation>>, root_find: Option<RootFindDirection>, reinitialize: Option<bool>, description: Option<String> },
    CouplingImport { reference: String, bind: Option<HashMap<String, String>>, description: Option<String> },
}
```

Coupling entry with discriminated union based on type field

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/types/components.rs#L478) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.CouplingEntry.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type CouplingEntry interface {
	CouplingType() string
}
```

CouplingEntry represents different types of coupling rules This is a discriminated union based on the "type" field

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/types.go#L866) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CouplingEntry)

</div>

</div>
