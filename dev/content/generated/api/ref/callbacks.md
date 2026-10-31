---
title: "callbacks"
description: "Stable function · Simulation"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Simulation](/generated/api/topics/simulation)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `callbacks` | outside profile | `callbacks` | `callbacks` | outside profile |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
callbacks(prob::EsmProblem)
```

```julia
callbacks(prob::EsmProblem)
```

The problem's own callback set — the composition of its data-refresh, output-sink
and checkpoint callbacks, or `nothing` when it has none.

Stable API in every simulation-capable binding, for one reason (§2.5.4): a
`callback` argument to `solve` **REPLACES** this set entirely — it does not
append, merge, or wrap. Silent composition is the more dangerous default (two
callbacks both writing output, or both mutating the same buffer, produce a wrong
run rather than an error), so a caller who wants to EXTEND reads the set back
and composes explicitly:

```julia
solve(prob, Tsit5(); callback = CallbackSet(callbacks(prob), my_extra_callback))
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/simulate.jl#L2246)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">Not available in TypeScript. TypeScript is outside the simulation capability profile (Julia, Python, Rust): build an RHS and integrate it; TypeScript and Go are deliberately non-simulating.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
callbacks(prob: EsmProblem) -> CallbackSet
```

The EsmProblem's callback set (esm-libraries-spec §2.5.4).

Stable API in every simulation-capable binding for one reason: a `callback`
argument to [`solve`](/generated/api/ref/solve) REPLACES this set, so without a way to read it back
a EsmProblem-level callback would be impossible to extend. Compose explicitly:

```python
solve(prob, callback=callbacks(prob) + my_extra_callback)
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/problem.py#L2175)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn callbacks(prob: &EsmProblem) -> &CallbackSet
```

The callbacks declared on `prob` (§2.5.4).

Stable API in every simulation-capable binding, and for a specific reason:
a `callback` argument to [`solve`](/generated/api/ref/solve) REPLACES this set entirely, so without a
way to read it back, a EsmProblem-level callback would be impossible to extend.
See [`compose`](/generated/api/ref/compose).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/problem.rs#L1024) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.callbacks.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Not available in Go. Go is outside the simulation capability profile (Julia, Python, Rust): build an RHS and integrate it; TypeScript and Go are deliberately non-simulating.</p>

</div>

</div>
