---
title: "functional_update"
description: "Stable type · Document types"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Document types](/generated/api/topics/document-types)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `FunctionalUpdate` | not exported | `FunctionalUpdate` | `FunctionalUpdate` | `FunctionalUpdate` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct FunctionalUpdate
FunctionalUpdate(handler_id::AbstractString; read_vars, read_params, config)
```

```julia
FunctionalUpdate
```

A registered handler that computes a parameter's new value when its update
fires (esm-spec §5.5). It lives on the parameter it writes, so it carries no
list of written variables. `handler_id` is the only registration mechanism in
the format.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/types.jl#L909)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this type.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class FunctionalUpdate
FunctionalUpdate(handler_id: str, read_vars: list[str] = list(), read_params: list[str] = list(), config: dict[str, Any] = dict())
```

A registered handler computing a parameter's new value when its update
fires (esm-spec §5.4). It lives ON the parameter it writes, so it needs no
write list: `read_vars` / `read_params` name what the handler reads and
`config` carries its static configuration.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/esm_types.py#L383)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct FunctionalUpdate {
    pub handler_id: String,
    pub read_vars: Option<Vec<String>>,
    pub read_params: Option<Vec<String>>,
    pub config: Option<Value>,
}
```

A registered handler computing a parameter's new value when its update
fires (esm-spec §5.5). The 0.x event `functional_affect`, relocated onto the
parameter it writes — which is why it needs no `modified_params` list: it
writes exactly one thing, the parameter carrying it.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/types/model.rs#L953) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.FunctionalUpdate.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type FunctionalUpdate struct {
	HandlerID  string         `json:"handler_id"`
	ReadVars   []string       `json:"read_vars,omitempty"`
	ReadParams []string       `json:"read_params,omitempty"`
	Config     map[string]any `json:"config,omitempty"`
}
```

FunctionalUpdate is a registered handler that computes a parameter's new value when its update fires (esm-spec 5.5). It is the 0.x event `functional_affect` relocated onto the parameter it writes: a handler's only write channel was `modified_params`, so moving it here REMOVED that list rather than relocating it.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/types.go#L344) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#FunctionalUpdate)

</div>

</div>
