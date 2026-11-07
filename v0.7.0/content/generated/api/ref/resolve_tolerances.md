---
title: "resolve_tolerances"
description: "Stable function · Simulation"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Simulation](/generated/api/topics/simulation)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `resolve_tolerances` | `resolveTolerances` | `resolve_tolerances` | `resolve_tolerances` | outside profile |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
resolve_tolerances(solver; abstol, reltol)
```

```julia
resolve_tolerances(solver; abstol=nothing, reltol=nothing) -> (abstol, reltol)
```

Resolve integration tolerances most-specific first (esm-spec §2.2.2):

1. An explicit argument at the `solve` call site — wins outright.
2. Otherwise the document's `solver.abstol` / `solver.reltol`.
3. Otherwise the binding default (`reltol` 1e-4, `abstol` 1e-6).

The two resolve INDEPENDENTLY, so a document declaring only `reltol` leaves
`abstol` on the default — the same per-field fall-through §6.6.4 uses.

These are INTEGRATION tolerances, a DIFFERENT QUANTITY from the `Tolerance`
an assertion is COMPARED at (§6.6.4), which resolves on its own chain.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/solver.jl#L520)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function resolveTolerances(solver: Solver | undefined | null, opts?: { abstol?: number; reltol?: number }): { abstol: number; reltol: number }
```

Resolve integration tolerances most-specific first (esm-spec §2.2.2):

1. An explicit argument at the call site — wins outright.
2. Otherwise the document's `solver.abstol` / `solver.reltol`.
3. Otherwise the binding default (`reltol` 1e-4, `abstol` 1e-6).

The two resolve INDEPENDENTLY, so a document declaring only `reltol` leaves
`abstol` on the default — the same per-field fall-through §6.6.4 uses.

These are INTEGRATION tolerances, a different quantity from the `tolerance`
object an assertion is COMPARED at (§6.6.4).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-ts/src/solver.ts#L499)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
resolve_tolerances(solver: Any, abstol: float | None = None, reltol: float | None = None) -> tuple[float, float]
```

Resolve integration tolerances most-specific first (esm-spec §2.2.2).

`solver` may be a [`Solver`](/generated/api/ref/solver), the raw
`solver` block as a dict (what `EsmProblem.doc` carries), or `None`.

1. An explicit argument at the `solve()` call site — wins outright.
2. Otherwise the document's `solver.abstol` / `solver.reltol`.
3. Otherwise the binding default (`reltol` 1e-4, `abstol` 1e-6).

The two tolerances resolve INDEPENDENTLY: a document that declares only
`reltol` leaves `abstol` to fall through to the default, exactly as
§6.6.4 merges its own chain per field.

These are INTEGRATION tolerances. They are a different quantity from the
`tolerance` object an assertion is compared at (§6.6.4), which resolves
on its own chain and is not touched here.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/solver.py#L699)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn resolve_tolerances(solver: Option<&Solver>, abstol: Option<f64>, reltol: Option<f64>) -> (f64, f64)
```

Resolve integration tolerances most-specific first (esm-spec §2.2.2):

1. An explicit argument at the `solve` call site — wins outright.
2. Otherwise the document's `solver.abstol` / `solver.reltol`.
3. Otherwise the binding default (`reltol` 1e-4, `abstol` 1e-6).

The two resolve INDEPENDENTLY, so a document declaring only `reltol` leaves
`abstol` on the default — the same per-field fall-through §6.6.4 uses.

These are INTEGRATION tolerances, a different quantity from the `tolerance`
object an assertion is COMPARED at (§6.6.4).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/solver.rs#L786) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.resolve_tolerances.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Not available in Go. Go is outside the simulation capability profile (Julia, Python, Rust): build an RHS and integrate it; TypeScript and Go are deliberately non-simulating.</p>

</div>

</div>
