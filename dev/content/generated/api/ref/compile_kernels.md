---
title: "compile_kernels"
description: "Stable function · Other"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Other](/generated/api/topics/other)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `compile_kernels` | not exported | `compile_kernels` | `compile_kernels` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
compile_kernels(prob::EsmProblem, specs)
```

```julia
compile_kernels(prob::EsmProblem, specs) -> KernelSet
```

Compile kernel specs (API_SPEC §5.8, "Kernel specs") against `prob`'s build:
each spec a `Dict` or a JSON string, `specs` a vector of them or one JSON array
string. The reserved name `rhs`, with no outputs, is the stripped right-hand
side. Refuses with `kernel_output_unresolved` and `affect_reads_post_value`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/ae13cc8f0c7013724cd3011b89390f836e34b5ad/pkg/EarthSciAST.jl/src/strip_expose.jl#L789)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this function.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
compile_kernels(prob: Any, specs: Any) -> Any
```

Standalone kernels (API_SPEC §5.8) are compiled by Julia and Rust only.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/ae13cc8f0c7013724cd3011b89390f836e34b5ad/pkg/earthsci-ast-py/src/earthsci_ast/strip.py#L555)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn compile_kernels(prob: &EsmProblem, specs: &[KernelSpec]) -> Result<KernelSet, SimulateError>
```

Compile `specs` against `prob`'s (stripped) build (API_SPEC §5.8). The
reserved name `rhs`, with no outputs, is the stripped right-hand side.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/ae13cc8f0c7013724cd3011b89390f836e34b5ad/pkg/earthsci-ast-rs/src/simulate_array/range/kernels.rs#L466) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.compile_kernels.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this function.</p>

</div>

</div>
