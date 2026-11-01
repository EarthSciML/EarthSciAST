---
title: "output_error"
description: "Stable error · Runtime I/O"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** error · **Topic:** [Runtime I/O](/generated/api/topics/runtime-io)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `OutputError` | outside profile | not exported | `OutputError` | outside profile |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct OutputError <: EarthSciASTError
OutputError(msg::String, code::String)
OutputError(msg, code)
OutputError(msg::AbstractString)
```

```julia
OutputError(msg)
OutputError(msg, code)
```

Thrown by the streaming-output surface: an unimplemented Sink protocol method, a
malformed snapshot, an output request that designates no single variable, or a
call to [`build_output_callback`](/generated/api/extension/julia#x-build_output_callback) before the `DiffEqCallbacks` /
`SciMLBase` extension is loaded. The output-side mirror of
[`RefreshError`](/generated/api/extension/julia#x-refresherror).

`code` is the registered diagnostic code (an [`ERROR_CODES`](/generated/api/ref/error_codes) value) for
the failures that carry one, and `""` otherwise.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/data_output.jl#L28)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">Not available in TypeScript. TypeScript is outside the runtime I/O capability profile (Julia, Python, Rust): data-source providers, refresh cadence, output sinks, checkpoints.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

<p class="api-absent">Python does not export this error.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub enum OutputError {
    DuplicateScalar { base: String, count: usize },
    RaggedRank { base: String, got: usize, expected: usize },
    ZeroIndex { base: String, axis: usize },
    SparseGrid { base: String, shape: Vec<usize>, got: usize, want: usize },
    DuplicateCell { base: String, cell: Vec<usize> },
    DimCountMismatch { base: String, dims: Vec<String>, declared: usize, shape: Vec<usize>, actual: usize },
    DimLengthMismatch { base: String, axis: usize, dim: String, size: usize, len: usize },
    DimLengthConflict { dim: String, first: String, a: usize, second: String, b: usize },
    TimeDimCollision { base: String, dim: String },
    CoordLengthMismatch { name: String, got: usize, want: usize },
    UnknownObserved { name: String },
    AmbiguousRequest { name: String, candidates: Vec<String> },
    BufferLength { base: String, what: &'static str, got: usize, want: usize },
}

impl OutputError { pub fn code(&self) -> Option<&'static str> }
```

Failure deriving an [`OutputPlan`](/generated/api/ref/output_plan) — the output-side mirror of the loader
seam's errors. Every variant names the offending variable or dimension:
a mislabeled axis is silently wrong science, so these fail loudly.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/data_output.rs#L115) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.OutputError.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Not available in Go. Go is outside the runtime I/O capability profile (Julia, Python, Rust): data-source providers, refresh cadence, output sinks, checkpoints.</p>

</div>

</div>
