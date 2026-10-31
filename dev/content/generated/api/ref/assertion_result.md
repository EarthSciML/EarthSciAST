---
title: "assertion_result"
description: "Stable type · Simulation"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Simulation](/generated/api/topics/simulation)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `AssertionResult` | outside profile | not exported | `AssertionResult` | outside profile |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct AssertionResult
AssertionResult(file::String, container_kind::Symbol, container_name::String, test_id::String, assertion_idx::Int64, variable::String, time::Float64, expected::Float64, actual::Union{Nothing, Float64}, status::AssertionStatus, message::String, duration_s::Float64, reduce::Union{Nothing, String}, rtol::Float64, atol::Float64)
AssertionResult(file, container_kind, container_name, test_id, assertion_idx, variable, time, expected, actual, status, message, duration_s, reduce, rtol, atol)
AssertionResult(file, container_kind::Symbol, container_name, test_id, assertion_idx::Integer, variable, time::Real, expected::Real, actual, status::AssertionStatus, message, duration_s::Real)
```

```julia
AssertionResult
```

Outcome of one `(file, container, test, assertion_idx)` evaluation — the ONE
result type both inline-test runners produce ([`run_esm_tests`](/generated/api/extension/julia#x-run_esm_tests) over the
MTK engine and [`run_inline_tests`](/generated/api/ref/run_inline_tests) over the tree-walk solve engine).

`message` carries the diff or error text for non-`PASS` results.
`duration_s` is this assertion's even share of its test's wall time (solve +
all samples), so summing `duration_s` over a test's assertions recovers the
test's duration (the JUnit testcase `time`).

§6.6.5 fields: `reduce` is the assertion's declared field reduction (`nothing`
for a plain scalar assertion — always `nothing` from the MTK runner);
`rtol`/`atol` are the RESOLVED §6.6.4 tolerances the pass predicate used
(`0.0`/`0.0` on results synthesized before tolerance resolution, e.g. a
parse/compile failure). The trailing three fields have defaults, so a
12-argument positional construction that omits them is accepted.

Virtual properties: `r.passed` (`status == PASS`) and `r.model` (alias of
`container_name`).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/run_tests.jl#L107)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">Not available in TypeScript. TypeScript is outside the simulation capability profile (Julia, Python, Rust): build an RHS and integrate it; TypeScript and Go are deliberately non-simulating.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

<p class="api-absent">Python does not export this type.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct AssertionResult {
    pub model: String,
    pub test_id: String,
    pub assertion_idx: usize,
    pub variable: String,
    pub time: f64,
    pub reduce: Option<String>,
    pub expected: f64,
    pub actual: Option<f64>,
    pub rtol: f64,
    pub atol: f64,
    pub passed: bool,
    pub message: String,
    pub file: String,
}
```

Outcome of one §6.6.5 inline-test assertion evaluated through the
simulation pathway. `actual` is the computed reduction value (`None` when
the simulation or reduction itself failed); `message` carries the diff or
error text for non-passing results. Field-for-field identical to the
Julia `AssertionResult` / Python `AssertionResult`, and
`Serialize`-able so conformance runners can record it directly.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/inline_tests.rs#L221) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.AssertionResult.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Not available in Go. Go is outside the simulation capability profile (Julia, Python, Rust): build an RHS and integrate it; TypeScript and Go are deliberately non-simulating.</p>

</div>

</div>
