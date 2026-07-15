# Agent Instructions

## Simulation runner pathway (ABSOLUTE)

EarthSciAST hosts the rule engine and the simulation runners that consume it.
There is **one and only one** pathway from a model artifact to a numerical
result. Every contributor — and every AI agent — must use it.

### The single pathway

```
.esm JSON → parse → AST (canonical form)
         → AST transforms (canonicalize, flatten, discretize, substitute, …)
         → official simulation runner (consumes AST directly, no shortcuts)
```

No step is allowed to bypass the AST. The runner does not receive a
pre-numericised, pre-tabulated, or imperatively rewritten form of the
rules; it walks the same canonical AST that the rule engine produced.

### Official ESS Julia simulation runners

A binding **may** ship more than one official runner. Each must satisfy
all four invariants below:

1. **AST-pure.** Walks the canonical AST directly. No imperative shortcut,
   no materialised rule output that bypasses the AST.
2. **No per-rule-shape dispatch.** No `if rule.kind == flux_1d_ppm then …`
   branches at the runner layer. All rule-shape handling happens in
   `discretize` (production), upstream of the runner.
3. **Documented use case.** Docs state when to choose this runner over the
   alternatives (system size, performance, feature support).
4. **Public API.** Invokable by users — not just by test infrastructure.

Current Julia runners:

- **ModelingToolkit (`mtk_export.jl` + extensions)** — default for
  small-to-medium ODE/DAE systems. Compiles via MTK's symbolic pipeline
  (tearing, structural simplification, codegen). Best when MTK's
  compile-time scales acceptably.
- **`tree_walk.jl`** — AST tree-walker producing
  `f!(du, u, p, t)` directly, bypassing MTK codegen. Use for discretized
  PDEs whose scalar count exceeds MTK's tearing/codegen ceiling, where
  MTK compile time becomes the bottleneck. Audit + formal documentation
  is tracked under `esm-qrj`; see that bead for status.

### Official per-binding runners (cross-language)

Each binding has its own official runner(s) consuming the same canonical AST:

| Binding    | Official runner(s)                                                                        | File(s) |
|------------|-------------------------------------------------------------------------------------------|---------|
| Julia      | ModelingToolkit; `tree_walk.jl`                                                           | `pkg/EarthSciAST.jl/src/mtk_export.jl`, `tree_walk.jl` |
| Python     | `numpy_interpreter` (AST evaluator); `simulation.simulate()` (SciPy backend)              | `pkg/earthsci-ast-py/src/earthsci_ast/numpy_interpreter.py`, `simulation.py` |
| Rust       | `simulate` (diffsol scalar ODE); `simulate_array` (ndarray array-op runtime)              | `pkg/earthsci-ast-rs/src/simulate.rs`, `simulate_array.rs` |
| TypeScript | `codegen` (canonical-AST → JS lowering)                                                   | `pkg/earthsci-ast-ts/src/codegen.ts` |
| Go         | (none — `earthsci-ast-go` is parse + validate only by design)                               | — |

If a binding lacks a runner, that gap is filed as a bead, not patched
around with a one-off evaluator.

### Prohibitions (ABSOLUTE)

- **No new test-only evaluators.** If a test wants to compare numerical
  output against a reference, it runs the official pathway above. Tests do
  not get their own parallel evaluator.
- **No new doc-only / example-only evaluators.** Examples consume the same
  pathway users would.
- **No imperative shortcut paths inside a runner.** A runner that special-
  cases a rule shape, flattens an AST node into a hand-rolled numeric
  kernel, or short-circuits the AST walk for "speed" violates invariant
  #1 and must be fixed or rejected.
- **No per-rule-shape dispatch at the runner layer.** Rule-shape handling
  belongs in `discretize`. If a rule shape doesn't materialize correctly
  through the production pipeline, the bug is in the production pipeline.
