---
title: "term_origin"
description: "Stable type · Other"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Other](/generated/api/topics/other)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `TermOrigin` | `TermOrigin` | `TermOrigin` | `TermOrigin` | `TermOrigin` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct TermOrigin
TermOrigin(component, coupling)
TermOrigin(; component, coupling)
```

```julia
TermOrigin(; component=nothing, coupling=nothing)
```

Who authored one [`Contribution`](/generated/api/ref/contribution). Exactly one field is set:

- `component`: the full dotted path of the model, subsystem or reaction system
  whose equation contained the expression (`"Atmosphere.Chemistry"`);
- `coupling`: the 0-based index of the coupling entry that wrote the expression
  itself, in the coupling sequence AFTER `coupling_import` expansion (the
  sequence `metadata.coupling_rules_applied` lists).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/term_provenance.jl#L21)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
type TermOrigin = {
    component: string;
} | {
    coupling: number;
};
```

Who authored one contribution to a flattened equation. Exactly one of the two
keys is present: `component` is the full dotted path of the model, subsystem
or reaction system whose equation contained the expression
(`"Atmosphere.Chemistry"`); `coupling` is the 0-based index of the coupling
entry that wrote the expression itself, counted in the coupling sequence
AFTER `coupling_import` expansion (the sequence `metadata.couplingRules`
lists).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-ts/src/flatten-contributions.ts#L22)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class TermOrigin
TermOrigin(component: str | None = None, coupling: int | None = None)
TermOrigin.to_json() -> dict[str, Any]
```

Who authored one contribution to a flattened equation (esm-libraries-spec
§4.7.5, "Per-term provenance").

Exactly one of the two fields is set: `component` is the full dotted path
of the model, subsystem or reaction system whose equation contained the
expression (`"Atmosphere.Chemistry"`); `coupling` is the 0-based index of
the coupling entry that wrote the expression itself, counted in the coupling
sequence AFTER `coupling_import` expansion (the sequence
`metadata.coupling_rules` lists).

**Members**

- `to_json` — The corpus form: `{"component": path}` or `{"coupling": index}`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/flatten.py#L319)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub enum TermOrigin {
    Component { component: String },
    Coupling { coupling: usize },
}
```

Who authored one [`Contribution`](/generated/api/ref/contribution) to a flattened equation
(esm-libraries-spec §4.7.5, "Per-term provenance").

Serialized untagged, as `{"component": "<dotted path>"}` or
`{"coupling": <k>}`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/flatten.rs#L463) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.TermOrigin.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type TermOrigin struct {
	Component string `json:"component,omitempty"`
	Coupling  *int   `json:"coupling,omitempty"`
}
```

TermOrigin names who authored one contribution to a flattened equation. Exactly one field is set: Component is the full dotted path of the model, subsystem or reaction system whose equation contained the expression ("Atmosphere.Chemistry"); Coupling is the 0-based index of the coupling entry that wrote the expression itself, counted in the coupling sequence AFTER coupling\_import expansion (the sequence FlattenMetadata.CouplingRules lists).

Its JSON form is the corpus form: {"component": path} or {"coupling": k}.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/flatten_contributions.go#L18) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#TermOrigin)

</div>

</div>
