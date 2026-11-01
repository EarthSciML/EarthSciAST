---
title: "closed_function_names"
description: "Stable function · Expressions"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Expressions](/generated/api/topics/expressions)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `closed_function_names` | `closedFunctionNames` | not exported | `closed_function_names` | `ClosedFunctionNames` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
closed_function_names()
```

```julia
closed_function_names() -> Set{String}
```

Return the v0.3.0 closed function set. Bindings MUST reject any `fn`-op
`name` not in this set. The set is intentionally narrow; new entries
require a spec rev (esm-spec §9.1).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/registered_functions.jl#L133)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function closedFunctionNames(): readonly string[]
```

Names that bindings MUST recognize (derived from the dispatch table keys).

A FUNCTION, matching Julia's `closed_function_names()`, Rust's
`closed_function_names()` and Go's `ClosedFunctionNames()` — API_SPEC.md §8
item 4. TypeScript alone exposed this as a constant array, so a caller
writing binding-agnostic code had to special-case it.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/closed-functions.ts#L594)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

<p class="api-absent">Python does not export this function.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn closed_function_names() -> &'static HashSet<String>
```

The closed function set. Bindings MUST reject any `fn`-op `name`
not in this set (esm-spec §9.1). Derived from `CLOSED_FUNCTIONS`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/registered_functions.rs#L156) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.closed_function_names.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func ClosedFunctionNames() []string
```

ClosedFunctionNames returns the v0.3.0 closed function set as a sorted slice. Useful for error messages and round-trip validation tests.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/registered_functions.go#L102) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ClosedFunctionNames)

</div>

</div>
