---
title: "Simulation"
description: "Building a problem from a document, integrating it, and reading states and observed quantities from the solution."
type: "api"
---


These operations belong to the **simulation** capability profile: Julia, Python, Rust.

| Operation | Kind | Bindings | Summary |
|---|---|---|---|
| [`callbacks`](/generated/api/ref/callbacks) | function | Julia, Python, Rust | The problem's own callback set — the composition of its data-refresh, output-sink and checkpoint callbacks, or `nothing` when it has none. |
| [`esm_problem`](/generated/api/ref/esm_problem-function) | function | Julia, Python, Rust | Build the ESM simulation problem for `input` over `tspan = (t0, t1)` — the one noun of esm-libraries-spec §2.5. |
| [`evaluate_cellwise`](/generated/api/ref/evaluate_cellwise) | function | Julia, Rust | Evaluate an array-valued expression (elementwise ops over array-producing `faq`/`makearray` nodes — e.g. a grid-geometry template expanded by a §9.7 import, or a §6.6.5 analytic… |
| [`field_reduce`](/generated/api/ref/field_reduce) | function | Julia, Rust | Collapse a spatial field to the scalar a §6.6.5 `reduce` assertion compares (esm-spec §6.6.5): |
| [`init`](/generated/api/ref/init) | function | Python, Rust | Build a stepping `Integrator` over `prob` (esm-libraries-spec §2.5.6). |
| [`observed_field`](/generated/api/ref/observed_field) | function | Julia, Python, Rust | The observed `name` of the problem, as a flat vector in row-major cell order (last index fastest; one element for a scalar observed). |
| [`remake`](/generated/api/ref/remake) | function | Python, Rust | A NEW EsmProblem with the named substitutions applied, everything else shared. |
| [`resolve_tolerances`](/generated/api/ref/resolve_tolerances) | function | Julia, TypeScript, Python, Rust | Resolve integration tolerances most-specific first (esm-spec §2.2.2): |
| [`run_inline_tests`](/generated/api/ref/run_inline_tests) | function | Julia, Rust | Run every inline test (esm-spec §6.6, including the §6.6.5 PDE assertions) of the selected component(s) of `inputs` through the official tree-walk simulation pathway, and return… |
| [`solve`](/generated/api/ref/solve) | function | Python, Rust | Run `prob` to completion and return its `Solution`. |
| [`step`](/generated/api/ref/step) | function | Python, Rust | Advance `integrator` one accepted step — the spec's `step!`. |
| [`assertion_result`](/generated/api/ref/assertion_result) | type | Julia, Rust | Outcome of one `(file, container, test, assertion_idx)` evaluation — the ONE result type both inline-test runners produce (`run_esm_tests` over the MTK engine and… |
| [`callback_set`](/generated/api/ref/callback_set) | type | Python, Rust | An ordered, immutable set of callbacks, declared on a `EsmProblem`. |
| [`compiler`](/generated/api/ref/compiler) | type | Python, Rust | The type a caller's `compiler` keyword takes. |
| [`compiler_report`](/generated/api/ref/compiler_report) | type | Julia, Python, Rust | What a build did, per rule. |
| [`ensemble_problem`](/generated/api/ref/ensemble_problem) | type | Python, Rust | A `EsmProblem` plus a per-trajectory rewrite (esm-libraries-spec §2.5.8). |
| [`esm_problem`](/generated/api/ref/esm_problem-type) | type | Julia, Python, Rust | The ESM simulation problem: the right-hand side `f!` the chosen `compiler` built — the compiled tree walk under `:native` / `:interpreter`, the compiled StableHLO program under… |
| [`inline_test_options`](/generated/api/ref/inline_test_options) | type | Julia, Rust | Per-document overrides for `run_inline_tests`, returned by its `options_for` callback. |
| [`integrator`](/generated/api/ref/integrator) | type | Python, Rust | A stepping integrator over a `EsmProblem` (esm-libraries-spec §2.5.6). |
| [`return_code`](/generated/api/ref/return_code) | type | Python, Rust | The SciML `ReturnCode` vocabulary (API_SPEC §4, esm-libraries-spec §2.5.3), which is how a run reports its outcome in every simulating binding. |
| [`solution`](/generated/api/ref/solution) | type | Python, Rust | What `earthsci_ast.problem.solve` returns. |
| [`simulate_error`](/generated/api/ref/simulate_error) | error | Julia, Rust | Exception thrown when a simulation Problem cannot be built or run (API_SPEC §5.8): `esm_problem` given a missing file or an unsupported input, an override in `p` / `u0` that… |
| [`default_abstol`](/generated/api/ref/default_abstol) | constant | TypeScript, Rust | Binding default absolute tolerance (API_SPEC §5.8) — the bottom of the §2.2.2 chain, used when neither the caller nor `solver.abstol` sets one. |
| [`default_reltol`](/generated/api/ref/default_reltol) | constant | TypeScript, Rust | Binding default relative tolerance (API_SPEC §5.8) — the bottom of the §2.2.2 chain, used when neither the caller nor `solver.reltol` sets one. |

[All topics](/generated/api)
