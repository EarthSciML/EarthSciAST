---
title: "callback_set"
description: "Stable type · Simulation"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Simulation](/generated/api/topics/simulation)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | outside profile | `CallbackSet` | `CallbackSet` | outside profile |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this type.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">Not available in TypeScript. TypeScript is outside the simulation capability profile (Julia, Python, Rust): build an RHS and integrate it; TypeScript and Go are deliberately non-simulating.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class CallbackSet(tuple)
CallbackSet.__add__(other: Any) -> CallbackSet
CallbackSet.__call__(t: Any, y: Any) -> None
```

An ordered, immutable set of callbacks, declared on a [`EsmProblem`](/generated/api/ref/esm_problem-type).

A callback is a callable `(t, y)` — `t` the output-time vector and `y`
the matching state/observed block — invoked once the run has produced its
output nodes, and after every `Integrator.step`. Callbacks belong to
the *document* (refreshing a provider buffer, writing an output stream), not
to a particular run's tolerances, which is why they are declared at
construction.

A `callback` argument to [`solve`](/generated/api/ref/solve) REPLACES this set entirely — it
does not append, merge, or wrap (§2.5.4). Silent composition is the more
dangerous default: a caller overriding a EsmProblem-level callback would
otherwise get both, and two callbacks that each write output produce a wrong
run rather than an error. To EXTEND rather than replace, read the set back
and compose explicitly:

```python
solve(prob, callback=callbacks(prob) + my_extra_callback)
```

**Members**

- `__add__` — Explicit composition — the sanctioned way to EXTEND a EsmProblem's set.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/problem.py#L279)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct CallbackSet {
    /* private fields */
}

impl CallbackSet { pub fn new() -> Self }

impl CallbackSet { pub fn of(name: impl Into<String>, f: CallbackFn) -> Self }

impl CallbackSet { pub fn push(&mut self, name: impl Into<String>, f: CallbackFn) -> &mut Self }

impl CallbackSet { pub fn len(&self) -> usize }

impl CallbackSet { pub fn is_empty(&self) -> bool }

impl CallbackSet { pub fn names(&self) -> Vec<&str> }

impl CallbackSet { pub fn invoke(&self, p: &Progress<'_>) -> Flow }
```

The callbacks declared on a [`EsmProblem`](/generated/api/ref/esm_problem-type).

Callbacks live on the EsmProblem, not on a run: a callback that refreshes
provider buffers or writes an output stream belongs to the *document*, not
to a particular run's tolerances (§2.5.4).

Entries are named so that `CallbackSet::names` can tell a caller what a
EsmProblem already carries before they decide whether to replace it.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/problem.rs#L80) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.CallbackSet.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Not available in Go. Go is outside the simulation capability profile (Julia, Python, Rust): build an RHS and integrate it; TypeScript and Go are deliberately non-simulating.</p>

</div>

</div>
