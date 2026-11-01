---
title: "map_variable"
description: "Stable function · Editing"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Editing](/generated/api/topics/editing)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `map_variable` | `mapVariable` | not exported | not exported | `MapVariable` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
map_variable(file::EsmFile, from::String, to::String; transform)
```

```julia
map_variable(file::EsmFile, from::String, to::String; transform="identity") -> EsmFile
```

Convenience function to create a variable_map coupling entry that forwards a
variable reference `from` into `to`. `transform` names the transform function
(e.g. `"identity"`, `"affine"`) or is an `ASTExpr` operator node evaluated on the
source value (esm-spec §10.4 expression transform).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/edit.jl#L451)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function mapVariable(file: EsmFile, from: string, to: string, transform?: CouplingVariableMap['transform']): EsmFile
```

Map a variable from one system to another with optional transformation

**Parameters**

- `file` — ESM file
- `from` — Source variable reference
- `to` — Target variable reference
- `transform` — Optional transformation: one of the named transform strings,
    or an Expression operator node evaluated in the flattened coupled system's
    scope (esm-spec §8.6 — the regridding form)

**Returns**

New ESM file with variable mapping coupling added

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/edit.ts#L483)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

<p class="api-absent">Python does not export this function.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this function.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func MapVariable(file ESMFile, from, to string, transform Expression) ESMFile
```

MapVariable returns a copy of `file` with a `variable_map` coupling entry forwarding `from` into `to`.

`transform` is either one of the named transform strings ("param\_to\_var", "identity", "additive", "multiplicative", "conversion\_factor") or an Expression operator node evaluated in the flattened coupled system's scope (esm-spec §8.6 — the regridding form). Pass nil for the default, "param\_to\_var" — the default TypeScript uses.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/edit.go#L1113) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#MapVariable)

</div>

</div>
