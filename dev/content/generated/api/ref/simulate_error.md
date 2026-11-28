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
SimulateError(msg::AbstractString)
SimulateError(msg::AbstractString, code::AbstractString)
```

```julia
SimulateError(msg, code = "")
```

Exception thrown when a simulation Problem cannot be built or run (API_SPEC
§5.8): [`esm_problem`](/generated/api/ref/esm_problem-function) given a missing file or an unsupported input, an
override in `p` / `u0` that names no variable, is ambiguous or collides with
another, a document with no models, a provider or compiler that cannot serve
the request, an [`observed_field`](/generated/api/ref/observed_field) read of a name that is not an
evaluable observed, or `solve` called without the solver extension loaded. The
ModelingToolkit and Catalyst constructors (`ModelingToolkit.System`,
`Catalyst.ReactionSystem`) raise it too, for a document construct they cannot
lower.

Fields: `code`, the [`ERROR_CODES`](/generated/api/ref/error_codes) value when the failure has one (such
as `compiler_unknown`, `override_key_ambiguous` or `unsupported_construct`) and
`""` otherwise, then `msg`, the human-readable description.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/EarthSciAST.jl/src/simulate.jl#L41)

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
    ToleranceBelowWorkingPrecision { source_name: &'static str, reltol: f64, floor: f64 },
    ToleranceNotMet,
    NotDynamic { details: String },
    CompilerUnavailable { compiler: &'static str, details: String },
    RangeRestriction { code: &'static str, message: String },
    Strip { code: &'static str, message: String },
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
    IcReadsState { name: String, details: String },
    IcSystemUnbalanced { details: String },
    ProviderError { name: String, details: String },
}

impl SimulateError { pub fn code(&self) -> Option<&'static str> }

impl SimulateError { pub fn is_cancelled(&self) -> bool }
```

Errors raised building an [`crate::problem::EsmProblem`](/generated/api/ref/esm_problem-type) or running
[`crate::problem::solve`](/generated/api/ref/solve).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/simulate/errors.rs#L15) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.SimulateError.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Not available in Go. Go is outside the simulation capability profile (Julia, Python, Rust): build an RHS and integrate it; TypeScript and Go are deliberately non-simulating.</p>

</div>

</div>
