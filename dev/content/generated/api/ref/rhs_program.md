---
title: "rhs_program"
description: "Stable function · Other"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Other](/generated/api/topics/other)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `rhs_program` | not exported | `rhs_program` | `rhs_program` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
rhs_program(prob::EsmProblem)
```

```julia
rhs_program(prob::EsmProblem) -> RhsProgram
```

The Problem's right-hand side as a program value (API_SPEC §5.8): the whole
model over the whole domain, with `u` every state of the Problem (in the
Problem's flat layout) and `aux` empty. [`select`](/generated/api/ref/select) narrows it to one
operator; [`halo`](/generated/api/ref/halo), [`restrict`](/generated/api/ref/restrict) and [`lanes`](/generated/api/ref/lanes) restrict it.

Its inputs besides the state are a parameter vector ([`parameters`](/generated/api/ref/parameters)) and
a [`ForcingSet`](/generated/api/ref/forcing_set-type) ([`forcing_slots`](/generated/api/extension/julia#x-forcing_slots)): every externally fed
parameter, and under `runtime_array_parameters` every shaped parameter with a
value, is read from the set, never from build-time data.
[`default_forcing_set`](/generated/api/ref/default_forcing_set) holds the Problem's forcing as it is now.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/range_restricted.jl#L675)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this function.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
rhs_program(prob: Any) -> Any
```

The Problem's right-hand side as a program value. Raises `compiler_unavailable`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/range_restricted.py#L36)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn rhs_program(prob: &EsmProblem) -> Result<RhsProgram, SimulateError>
```

The right-hand side `prob` compiled, as a program `RhsProgram::select`,
`RhsProgram::halo`, `RhsProgram::tile` and `RhsProgram::lanes`
accept (API_SPEC §5.8). Its names are the flattened (dot-namespaced)
names on every route; it writes every state.

`native` and `interpreter` problems are accepted; any other compiler is
`compiler_unavailable`. Under `native` a rule the tape cannot express is
`compiler_refused_rule`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/simulate_array/range/mod.rs#L507) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.rhs_program.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this function.</p>

</div>

</div>
