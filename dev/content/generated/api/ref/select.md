---
title: "select"
description: "Stable function · Other"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Other](/generated/api/topics/other)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `select` | not exported | `select` | not exported | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
select(prog::EarthSciAST.RhsProgram; writes, terms)
```

```julia
select(prog::RhsProgram; writes = :all, terms = :all) -> RhsProgram
```

The program of one operator (API_SPEC §5.8, "Selection"): every flattened
equation keeps the contributions whose #539 origins intersect `terms` (a
vector of [`TermOrigin`](/generated/api/ref/term_origin), matched by equality; `:all` keeps every one),
summed as a left fold in their original order; equations whose target is not
in `writes` (a vector of flattened state names, or `:all`) are dropped, and a
kept equation with no kept contribution writes `0`. The result's `u` covers
`writes` and its `aux` the other states the kept rules read.

A selection of a selection composes: its `terms` keep only the contributions
both selections keep, and its `writes` (`:all` meaning `prog`'s own) must be
variables `prog` writes.

Raises `range_selection_writes_incomplete` when a variable outside `writes` has
a kept contribution.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/range_restricted.jl#L705)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this function.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
select(prog: Any, *, writes: Any = 'all', terms: Any = 'all') -> Any
```

One operator's program, by provenance. Raises `compiler_unavailable`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/range_restricted.py#L51)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this function.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this function.</p>

</div>

</div>
