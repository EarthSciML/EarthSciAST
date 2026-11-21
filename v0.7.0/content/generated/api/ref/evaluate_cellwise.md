---
title: "evaluate_cellwise"
description: "Stable function · Simulation"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Simulation](/generated/api/topics/simulation)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `evaluate_cellwise` | outside profile | not exported | `evaluate_cellwise` | outside profile |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
evaluate_cellwise(expr::ASTExpr, cells::AbstractVector{<:AbstractVector{<:Integer}}; const_arrays, registered_functions, params, blas_accel, t)
```

```julia
evaluate_cellwise(expr, cells; const_arrays=Dict(), registered_functions=Dict(),
                  params=Dict()) -> Vector{Float64}
```

Evaluate an array-valued expression (elementwise ops over array-producing
`faq`/`makearray` nodes — e.g. a grid-geometry template expanded by a
§9.7 import, or a §6.6.5 analytic `reference`) at each 1-based integer cell of
`cells`, returning one Float64 per cell. This is the public entry to the same
build-time machinery `build_evaluator` uses to seed coordinate-expression `ic`
fields.

STATE references are not in scope. Model PARAMETERS (load-time constants) ARE:
pass their resolved values as `params` (name → value, e.g. a build's
`BuildInspection.params`) and a parameter-dependent expression resolves. This
is what lets a parameter-backed rank≥2 observed / analytic reference be
asserted directly (esm-spec §6.6.5) instead of erroring with
`E_TREEWALK_UNBOUND_VARIABLE`.

TIME is its own argument, `t`, and NOT a `params` entry: the compiler maps the
name `t` to the evaluator's time slot rather than to a parameter read, so a
`params` entry spelled `"t"` never reaches a time-dependent body. It defaults
to `0.0`, which is the right value for every build-time caller; a §6.6
assertion passes its own `time` (esm-spec §6.6.3), which is what makes an
observed that is a function of `t` — a solar declination, an hour angle — read
correctly away from the start of the span.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/inline_tests.jl#L545)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">Not available in TypeScript. TypeScript is outside the simulation capability profile (Julia, Python, Rust): build an RHS and integrate it; TypeScript and Go are deliberately non-simulating.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

<p class="api-absent">Python does not export this function.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn evaluate_cellwise(expr: &Expr, cells: &[Vec<i64>], index_sets: &HashMap<String, IndexSet>, params: &HashMap<String, f64>) -> Result<Vec<f64>, String>
```

Evaluate an array-valued expression (elementwise ops over array-producing
`faq`/`makearray` nodes — e.g. a grid-geometry template expanded by
a §9.7 import, or a §6.6.5 analytic `reference`) at each 1-based integer
cell of `cells`, returning one `f64` per cell.

This is the public entry to the same build-time machinery the simulator
uses to seed coordinate-expression `ic` fields
(`crate::simulate_array::eval_buildtime_field`).

STATE references are not in scope. Model PARAMETERS (load-time constants)
ARE: pass their resolved values as `params` (name → value, e.g. a build's
`BuildInspection::params`) and a parameter-dependent expression resolves
(esm-spec §6.6.5). A scalar (const-folded) result broadcasts. Mirrors the
Julia `evaluate_cellwise` / Python `evaluate_cellwise` 1:1.

Always the reference evaluator, whatever compiler built the model: the
runner calls this for an assertion's analytic `reference`, which is the
test's oracle rather than the model, and so is outside the compiler's
refusal. The same kind of expression seeding a model's `ic` is the model's,
and is exercised and gated at construction instead
([`crate::problem::esm_problem`](/generated/api/ref/esm_problem-function)).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/inline_tests.rs#L284) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.evaluate_cellwise.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Not available in Go. Go is outside the simulation capability profile (Julia, Python, Rust): build an RHS and integrate it; TypeScript and Go are deliberately non-simulating.</p>

</div>

</div>
