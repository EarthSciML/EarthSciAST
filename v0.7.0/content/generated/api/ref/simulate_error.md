---
title: "simulate_error"
description: "Stable error · Simulation"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** error · **Topic:** [Simulation](/generated/api/topics/simulation)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `SimulateError` | outside profile | not exported | `SimulateError` | outside profile |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct SimulateError <: EarthSciASTError
SimulateError(msg::String, code::String)
SimulateError(msg, code)
SimulateError(msg::AbstractString)
```

```julia
SimulateError(msg::AbstractString)
SimulateError(msg::String, code::String)
```

Exception thrown when a simulation Problem cannot be built or run (API_SPEC
§5.8): [`esm_problem`](/generated/api/ref/esm_problem-function) given a missing file or an unsupported input, an
override in `p` / `u0` that names no variable or collides with another, a
document with no models, a provider or compiler that cannot serve the request,
an [`observed_field`](/generated/api/ref/observed_field) read of a name that is not an evaluable observed,
or `solve` called without the solver extension loaded.

`msg` is the human-readable description. `code` is the [`ERROR_CODES`](/generated/api/ref/error_codes)
value when the failure has one, such as `"compiler_unknown"` or
`"compiler_unavailable"` for a `compiler =` selection that cannot be honoured,
and `""` otherwise. `showerror` prints `SimulateError: <code>: <msg>`, omitting
the code when it is empty.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/simulate.jl#L47)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">Not available in TypeScript. TypeScript is outside the simulation capability profile (Julia, Python, Rust): build an RHS and integrate it; TypeScript and Go are deliberately non-simulating.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

<p class="api-absent">Python does not export this error.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub enum SimulateError {
    Compile(CompileError),
    DiffsolError { details: String },
    ToleranceNotMet,
    NotDynamic { details: String },
    CompilerUnavailable { compiler: &'static str, details: String },
    RangeRestriction { code: &'static str, message: String },
    DataSourceUnbound { parameter: String, data_source: String },
    Cancelled { details: String },
    UnsubstitutableBinding { name: String, class: String },
    InvalidTimeSpan { start: f64, end: f64 },
    InvalidParameter { name: String },
    AmbiguousParameter { name: String, candidates: Vec<String> },
    CollidingParameterKeys { name: String, keys: Vec<String> },
    InvalidInitialCondition { name: String },
    AmbiguousInitialCondition { name: String, candidates: Vec<String> },
    CollidingInitialConditionKeys { name: String, keys: Vec<String> },
    InvalidFieldInitialCondition { name: String, details: String },
    ProviderError { name: String, details: String },
}

impl SimulateError { pub fn is_cancelled(&self) -> bool }
```

Errors raised building an [`crate::problem::EsmProblem`](/generated/api/ref/esm_problem-type) or running
[`crate::problem::solve`](/generated/api/ref/solve).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/simulate/errors.rs#L15) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.SimulateError.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Not available in Go. Go is outside the simulation capability profile (Julia, Python, Rust): build an RHS and integrate it; TypeScript and Go are deliberately non-simulating.</p>

</div>

</div>
