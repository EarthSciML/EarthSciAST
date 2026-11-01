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
run_inline_tests(inputs; model_name=nothing, alg=nothing,
                 reltol=DEFAULT_TEST_RELTOL, abstol=DEFAULT_TEST_ABSTOL,
                 base_dir=nothing, options_for=nothing)
    -> Vector{AssertionResult}
```

Run every inline test (esm-spec §6.6, including the §6.6.5 PDE assertions) of
the selected component(s) of `inputs` through the official tree-walk simulation
pathway, and return one [`AssertionResult`](/generated/api/ref/assertion_result) per assertion — carrying
the ACTUAL reduction value alongside pass/fail, so conformance harnesses can
record and cross-compare the numbers.

`inputs` is a path to a `.esm` file, a loaded [`EsmFile`](/generated/api/ref/esm_file), a DIRECTORY
(walked recursively for `*.esm`, sorted), or any iterable of those. Results are
concatenated in input order.

Both kinds of test-bearing component are run: `models` first, then
`reaction_systems`, which the schema gives the same `tests` member.

Per test: `solve(esm_problem(input, (time_span.start, time_span.stop)), alg;
reltol, abstol, saveat=&lt;assertion times>)` with the test's `initial_conditions`
/ `parameter_overrides` applied; then per assertion the asserted variable's field
is read at the assertion time and either point-sampled per its `coords`
(positions in 1-based INDEX space; nearest grid index, exact ties rounding
DOWN — the pinned cross-binding convention) or collapsed per its `reduce`
(error norms evaluate the `reference` — an analytic expression cellwise via
[`evaluate_cellwise`](/generated/api/ref/evaluate_cellwise), or a `{type: "from_file", path, format?}` JSON
snapshot resolved against `base_dir`). An assertion with neither `coords` nor
`reduce` samples a scalar state. `base_dir` defaults to the .esm file's
directory when the document came from a path, else the working directory.

`options_for` is the seam for site-specific policy. It is called once per
resolved document — with the document's path when it came from one, else the
`EsmFile`, and BEFORE the document is loaded, so a basename-keyed callback is
asked about an unreadable file too and wants a default rather than an indexing
error — and returns an [`InlineTestOptions`](/generated/api/ref/inline_test_options) whose non-`nothing`
fields override the keywords above for that document (or `nothing` to change
nothing). It exists so that a corpus gate's basename-keyed tables — a
stiff-solver map, an initial-condition seed — can stay in the gate instead of
forcing it to re-implement §6.6 to get at them.

A document that fails to LOAD throws when `inputs` names a single document,
exactly as before. In a BATCH — an iterable or a directory — it instead
contributes one ERROR row naming the path, so one unreadable file cannot cost
the run every other file's verdicts. Every OTHER row names its document too:
`r.file` is the path the document was loaded from (and `""` only for a document
handed over as an in-memory `EsmFile`, which has no path), so a corpus run's
rows are attributable one by one rather than only in bulk.

Tolerances resolve per esm-spec §6.6.4 — PER FIELD over four levels
(assertion > test > model > the implementation default `rel=1e-6`), each of
`rel` and `abs` taken from the innermost level that declares it; the pass
predicate is the same `isapprox` check `run_esm_tests`
uses, and the results are the same [`AssertionResult`](/generated/api/ref/assertion_result) type the MTK
runner produces — both runners are the SAME frame (`_run_test_frame!` in
run_tests.jl) with different execution engines plugged in, so tolerance
resolution, the pass predicate, per-test wall-time accounting, and JUnit
emission ([`write_junit_xml`](/generated/api/extension/julia#x-write_junit_xml)) cannot drift apart. `alg` names the ODE algorithm (e.g. `Tsit5()` with
OrdinaryDiffEqTsit5 loaded) — the solve runs in the SciMLBase extension. It may
be left `nothing`, and then each document gets the algorithm
`_pick_solver` picks for it: the stiff `Rosenbrock23` when the document
declares `solver.stiffness: "high"` (esm-spec §2.2), else the non-stiff
`Tsit5`. That is what lets ONE corpus-wide call run a stiff document and a
non-stiff one — a caller who passes an `alg` is naming it for every document in
the batch, which a stiff member of that batch cannot survive. Leaving it unset
does require one of those solver packages to be loaded: with neither available
and no `alg` named, a document that HAS tests to run throws an `ArgumentError`
saying so. A document with no tests never reaches the pick, so a corpus of
mostly test-free documents costs nothing and cannot fail on this.
`reltol`/`abstol` default to `nothing`, and that is load bearing rather than
merely tidy: it is what keeps the DOCUMENT's own opinion expressible. Each
resolves per esm-spec §2.2.2, most-specific first — an `options_for` override,
then the keyword here, then this document's `solver.reltol` / `solver.abstol`
(§2.2), then the shared inline-test defaults `DEFAULT_TEST_RELTOL` /
`DEFAULT_TEST_ABSTOL`. The runner defaults sit at the BOTTOM of the chain
because they are binding defaults, not a caller's opinion, so a document that
declares its own integration accuracy gets it without every caller naming it.
Passing a value explicitly overrides the document, which is why a concrete
default here would silently have suppressed it. These are INTEGRATION
tolerances and are a different quantity from the §6.6.4 assertion tolerance
above.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/inline_tests.jl#L2822)

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
format?}` JSON snapshot resolved against the working directory; use
[`run_inline_tests_with_base_dir`](/generated/api/extension/rust#x-run_inline_tests_with_base_dir) to anchor at the .esm file's directory).
An assertion with neither `coords` nor `reduce` samples a scalar state.
Mirrors the Julia binding's `run_inline_tests` 1:1 (tolerances per §6.6.4;
the pass predicate is Julia `isapprox`). Models iterate in sorted name
order for deterministic output.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/inline_tests.rs#L2831) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.run_inline_tests.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Not available in Go. Go is outside the simulation capability profile (Julia, Python, Rust): build an RHS and integrate it; TypeScript and Go are deliberately non-simulating.</p>

</div>

</div>
