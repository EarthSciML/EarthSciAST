---
title: "inline_test_options"
description: "Stable type · Simulation"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Simulation](/generated/api/topics/simulation)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `InlineTestOptions` | outside profile | not exported | `InlineTestOptions` | outside profile |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct InlineTestOptions
InlineTestOptions(; model_name, alg, reltol, abstol, base_dir, initial_conditions, parameter_overrides, compiler)
InlineTestOptions(model_name::Union{Nothing, AbstractString}, alg, reltol::Union{Nothing, Float64}, abstol::Union{Nothing, Float64}, base_dir::Union{Nothing, AbstractString}, initial_conditions::Union{Nothing, AbstractDict}, parameter_overrides::Union{Nothing, AbstractDict}, compiler::Union{Nothing, Symbol})
InlineTestOptions(model_name, alg, reltol, abstol, base_dir, initial_conditions, parameter_overrides, compiler)
```

```julia
InlineTestOptions(; model_name=nothing, alg=nothing, reltol=nothing,
                  abstol=nothing, base_dir=nothing,
                  initial_conditions=nothing, parameter_overrides=nothing)
```

Per-document overrides for [`run_inline_tests`](/generated/api/ref/run_inline_tests), returned by its
`options_for` callback.

Every field is optional, and a field left `nothing` INHERITS the value passed
to `run_inline_tests` itself — so a callback that cares about one document's
solver and nothing else returns `InlineTestOptions(alg=Rodas5())` and the rest
of the run is unchanged.

This record exists so that site-specific policy stays at the site. A CI gate
over a model corpus routinely carries basename-keyed tables — a stiff-solver
map, an initial-condition seed for the documents whose tests do not state one
— and each of those is a reason the gate could not call the library entry and
re-implemented esm-spec §6.6 instead. One callback absorbs all of them without
this module learning anything about the corpus.

`initial_conditions` / `parameter_overrides` are SEEDS: they are laid BENEATH
each test's own maps, so a test that states a value keeps it and a test that is
silent gets the caller's. They are merged with the test's map before
`_scope_to_component` runs, and so are keyed and resolved exactly like a test's
own keys — which is what makes the precedence well defined.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/inline_tests.jl#L2690)

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
pub struct InlineTestOptions {
    pub model_name: Option<String>,
    pub solve: SolveOptions,
    pub base_dir: Option<PathBuf>,
    pub test_filter: Option<String>,
    pub initial_conditions: HashMap<String, InlineValue>,
    pub parameter_overrides: HashMap<String, InlineValue>,
    pub compiler: Option<Compiler>,
}
```

Per-document overrides for [`run_inline_tests_paths`](/generated/api/extension/rust#x-run_inline_tests_paths), returned by its
`options_for` callback.

This record exists so that site-specific policy stays at the site. A CI gate
over a model corpus routinely carries basename-keyed tables — a
stiff-solver map, an initial-condition seed for the documents whose tests do
not state one — and each of those is a reason the gate could not call the
library entry and re-implemented esm-spec §6.6 instead. One callback absorbs
all of them without this module learning anything about the corpus.

`initial_conditions` / `parameter_overrides` are SEEDS: they are laid
BENEATH each test's own maps, so a test that states a value keeps it and a
test that is silent gets the caller's. They are merged with the test's map
before `scope_to_component` runs, and so are keyed and resolved exactly
like a test's own keys — which is what makes the precedence well defined.

`base_dir` left `None` defaults to the document's own parent directory,
which is what anchors a §6.6.5 `from_file` reference at the `.esm` file
rather than at the process's working directory.

There is deliberately no `cse` field: unlike the Python binding, this
crate's problem builder exposes no common-subexpression knob — its CSE is
unconditional internal machinery — and a field that silently did nothing
would be worse than its absence.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/inline_tests.rs#L3075) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.InlineTestOptions.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Not available in Go. Go is outside the simulation capability profile (Julia, Python, Rust): build an RHS and integrate it; TypeScript and Go are deliberately non-simulating.</p>

</div>

</div>
