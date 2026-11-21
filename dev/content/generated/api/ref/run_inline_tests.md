---
title: "run_inline_tests"
description: "Stable function · Simulation"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Simulation](/generated/api/topics/simulation)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `run_inline_tests` | outside profile | not exported | `run_inline_tests` | outside profile |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
run_inline_tests(inputs; model_name, alg, reltol, abstol, base_dir, compiler, options_for)
```

```julia
run_inline_tests(inputs; model_name=nothing, alg=nothing, reltol=nothing,
                 abstol=nothing, base_dir=nothing, compiler=:native,
                 options_for=nothing)
    -> Vector{AssertionResult}
```

Run every inline test (esm-spec §6.6, including the §6.6.5 field assertions) of
the selected component(s) of `inputs` through [`esm_problem`](/generated/api/ref/esm_problem-function) and `solve`,
and return one [`AssertionResult`](/generated/api/ref/assertion_result) per assertion, carrying the actual
value alongside pass/fail.

`inputs` is a path to a `.esm` file, a loaded [`EsmFile`](/generated/api/ref/esm_file), a directory
(walked recursively for `*.esm`, sorted), or any iterable of those. Results are
concatenated in input order; `models` run before `reaction_systems`.

Per test: `solve(esm_problem(input, (time_span.start, time_span.stop); compiler),
alg; reltol, abstol, saveat=&lt;assertion times>)` with the test's
`initial_conditions` / `parameter_overrides` applied. Each assertion then reads
the asserted variable at its time: a scalar sample, a point sample per `coords`
(1-based index space, nearest index, exact ties rounding down), or a reduction
per `reduce` (error norms against a `reference`: an analytic expression,
evaluated with [`evaluate_cellwise`](/generated/api/ref/evaluate_cellwise), or a
`{type: "from_file", path, format?}` JSON snapshot resolved against `base_dir`).
`base_dir` defaults to the `.esm` file's directory, else the working directory.

Assertion tolerances resolve per field over four levels (esm-spec §6.6.4:
assertion > test > model > `rel=1e-6`), and the pass predicate, wall-time
accounting and JUnit output ([`write_junit_xml`](/generated/api/extension/julia#x-write_junit_xml)) are those of
[`run_esm_tests`](/generated/api/extension/julia#x-run_esm_tests) (both runners share `_run_test_frame!`).

Keywords:
* `alg` — the ODE algorithm for every document. Left `nothing`, each document
  gets `Rosenbrock23` when it declares `solver.stiffness: "high"` (esm-spec §2.2),
  else `Tsit5`; that needs OrdinaryDiffEqRosenbrock or OrdinaryDiffEqTsit5
  loaded, and a document with tests and no available solver raises an
  `ArgumentError`.
* `reltol` / `abstol` — integration tolerances (not the assertion tolerances
  above). Each resolves most-specific first: an `options_for` override, this
  keyword, the document's `solver.reltol` / `solver.abstol`, then
  `DEFAULT_TEST_RELTOL` / `DEFAULT_TEST_ABSTOL`.
* `compiler` — passed to `esm_problem` for every test.
* `options_for` — called once per document, before it is loaded, with its path
  (or the `EsmFile` when there is none); returns an [`InlineTestOptions`](/generated/api/ref/inline_test_options)
  whose non-`nothing` fields override the keywords for that document, or
  `nothing`.

A document that fails to load throws when `inputs` names a single document; in
a batch (an iterable or a directory) it contributes one error row naming the
path instead. `r.file` is the path each row's document was loaded from (`""`
for an in-memory `EsmFile`).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/pkg/EarthSciAST.jl/src/inline_tests.jl#L1236)

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
pub fn run_inline_tests(file: &EsmFile, model_name: Option<&str>, opts: &SolveOptions) -> Vec<AssertionResult>
```

Run every inline test (esm-spec §6.6, including the §6.6.5 PDE
assertions) of the selected model(s) of `file` through the official
simulation pathway ([`crate::problem::esm_problem`](/generated/api/ref/esm_problem-function) /
[`crate::problem::solve`](/generated/api/ref/solve), the array runtime), and return one
[`AssertionResult`](/generated/api/ref/assertion_result) per assertion — carrying the ACTUAL reduction
value alongside pass/fail, so conformance harnesses can record and
cross-compare the numbers.

Per test: simulate over the test's `time_span` (with its
`initial_conditions` / `parameter_overrides` applied and `opts` pinning
the solver family and tolerances; the assertion times become the sampled
`saveat`); then per assertion the asserted variable's field is read
at the assertion time and either point-sampled per its `coords`
(positions in 1-based INDEX space; nearest grid index, exact ties
rounding DOWN — the pinned cross-binding convention) or collapsed per its
`reduce` (error norms evaluate the `reference` — an analytic expression
cellwise via [`evaluate_cellwise`](/generated/api/ref/evaluate_cellwise), or a `{type: "from_file", path,
format?}` JSON snapshot resolved against the working directory; set
`InlineTestOptions::base_dir` to anchor at the .esm file's directory).
An assertion with neither `coords` nor `reduce` samples a scalar state.
Mirrors the Julia binding's `run_inline_tests` 1:1 (tolerances per §6.6.4;
the pass predicate is Julia `isapprox`). Models iterate in sorted name
order for deterministic output.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/pkg/earthsci-ast-rs/src/inline_tests.rs#L3101) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.run_inline_tests.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Not available in Go. Go is outside the simulation capability profile (Julia, Python, Rust): build an RHS and integrate it; TypeScript and Go are deliberately non-simulating.</p>

</div>

</div>
