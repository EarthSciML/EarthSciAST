# Agent instructions — EarthSciAST.jl (Julia binding)

This file scopes the workspace-level rule from `<workspace>/CLAUDE.md`
("Simulation Pathway — ABSOLUTE Rule") to the Julia binding.

## Official ESS Julia simulation runners

The Julia binding ships **two** official ESS simulation runners. Both
consume the canonical-form AST emitted by `discretize` and walk it
generically. A binding is allowed to host more than one runner as long as
each meets the workspace criteria.

| Runner | Public API | Source | Use when |
|---|---|---|---|
| ModelingToolkit (MTK) | `ModelingToolkit.System(model::Model)` (`EarthSciASTMTKExt`) | `ext/EarthSciASTMTKExt/` | **Default.** Production runtime — full structural simplification, observed-variable handling, full SciML solver / sensitivity / event ecosystem. |
| `tree_walk` | `build_evaluator(model_or_dict)` for ODE RHS, `evaluate_expr(expr, bindings)` for a single AST expression | `src/tree_walk.jl` | Very large discretized PDE systems whose scalar count exceeds MTK's `structural_simplify` / tearing / codegen ceiling. Build time is independent of system size; no symbolic simplification pass. `evaluate_expr` shares the runner's compile + walker pipeline, so per-expression callers (units fixture consumption, `simplify` constant folding) live on the same dispatch table — no shadow evaluator. |

The user-facing description (when to choose, performance characteristics,
supported ops, error codes, public API surface) lives in
`docs/src/simulation-runners.md`. **Do not duplicate that content here**;
update the docs page.

## What the runner does NOT do

Per the workspace rule, neither runner may:

1. Shortcut to imperative compute. The runner walks the AST directly.
2. Materialize rule output and bypass the AST. Rule application is
   `discretize`'s job; the runner consumes the result.
3. Branch on rule shape (e.g. `if rule.kind == "flux_1d_ppm" then ...`).
   Dispatch is on AST `op`, never on the rule that produced the op.

If you find yourself adding a per-rule-shape branch inside `tree_walk.jl`
or an MTK extension function, stop — file a bead against the rule engine
or `discretize` instead. The simulation runner stays generic.

## Forbidden patterns (recognize and refuse)

| Anti-pattern | Description |
|---|---|
| Test-path evaluator | A "verify" / "validate" / "MMS convergence" code path that re-evaluates rule AST through a separate dispatch table. Replace by driving the canonical pipeline + evaluating the resulting AST through `build_evaluator` (or MTK). |
| Per-rule-shape dispatch in non-production code | Branches like `if stencil_kind == "cartesian" then ...` outside the production rule engine. Forbidden, even in tests. |
| Homebrew doc-build simulator | Documentation tools that integrate ODEs through their own pipeline. Doc builds may simulate, but only via an official runner. |
| Reference-value generator written separately from the production runner | Conformance regen scripts that hand-walk stencils. Goldens MUST come from the canonical pipeline. |
| Shadow evaluator under "validation" framing | `tree_walk.jl` is the official ESS Julia evaluator. Do not stand up a parallel evaluator and call it "validation". |

## When in doubt

Ask: does the proposed code path go through (a) ESS rule application via
`discretize` and (b) one of the documented official ESS Julia simulation
runners? If no to either, it is the anti-pattern. Reframe to use the
canonical pipeline; if the canonical pipeline is missing capability, file a
bead to extend it (the production path), not to write a side channel.
