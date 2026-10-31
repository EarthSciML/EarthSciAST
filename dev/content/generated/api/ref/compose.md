---
title: "compose"
description: "Stable function · Editing"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Editing](/generated/api/topics/editing)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `compose` | `compose` | not exported | `compose` | `Compose` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
compose(file::EsmFile, system_a::String, system_b::String)
```

```julia
compose(file::EsmFile, system_a::String, system_b::String) -> EsmFile
```

Convenience function to create an operator_compose coupling entry linking two systems.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/edit.jl#L441)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function compose(file: EsmFile, a: string, b: string): EsmFile
```

Compose two systems using a coupling entry

**Parameters**

- `file` — ESM file
- `a` — First system name
- `b` — Second system name

**Returns**

New ESM file with composition coupling added

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-ts/src/edit.ts#L464)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

<p class="api-absent">Python does not export this function.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn compose(a: &CallbackSet, b: &CallbackSet) -> CallbackSet
```

Concatenate two callback sets into a new one.

This is the explicit composition §2.5.4 requires: a `callback` argument to
[`solve`](/generated/api/ref/solve) REPLACES the EsmProblem's set entirely — it does not append, merge or
wrap — so a caller who wants to *extend* rather than replace reads the
existing set back with [`callbacks`](/generated/api/ref/callbacks) and composes:

```text
let cb = compose(callbacks(&prob), &my_extra);
solve(&prob, &SolveOptions { callback: Some(cb), ..Default::default() })
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/problem.rs#L152) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.compose.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func Compose(file ESMFile, a, b string) ESMFile
```

Compose returns a copy of `file` with an `operator_compose` coupling entry linking systems `a` and `b`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/edit.go#L1098) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#Compose)

</div>

</div>
