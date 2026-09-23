```@meta
CurrentModule = EarthSciAST
```

# Simulation Runners

A simulation runner is the machinery that turns canonical-form AST into a
right-hand side. EarthSciAST.jl has several, and which one runs is an explicit
argument: `esm_problem(…; compiler = …)`, over a closed vocabulary
shared with the Python and Rust bindings. `API_SPEC.md` §5.8 is the contract and
`esm-libraries-spec.md` §2.5.10 is the normative text; this page says what each
value means in Julia and how much of it is reachable today.

| `compiler` | Role | Julia runner | Status |
|---|---|---|---|
| `:native` | The universally fast option, with no heavy external dependency — hence the default. Every kernel lands on a codegen, affine or whole-array tier; a rule that would need a per-cell tree walk is a build error naming the rule and the reason, never a quiet demotion. | the tiered tree-walk build (`RuntimeGeneratedFunctions` codegen, already a package dependency) | **live.** It is what you get when you name nothing |
| `:interpreter` | Deliberately simple: the correctness check for the other compilers. Every fast tier off, complete over the evaluable core, no performance promise of any kind. | the same tree walk with the per-cell runner for every kernel | **live.** Ask for it by name; no environment variable selects it |
| `:xla` | Specialty: needs a heavy external dependency. StableHLO emitted directly and compiled through Reactant; a hard error on anything it cannot lower. | the direct emitter in the Reactant extension | **live.** `esm_problem(…; compiler = :xla)` with `using Reactant` in the session; `compiler_unavailable` naming Reactant without it |
| `:mtk` | Specialty: only some documents — but it is the one runner that executes **events and implicit equations**. | `ModelingToolkit.System(model)` via the package extension | **planned as a compiler.** The extension is live and supported; it is not yet something `esm_problem` can be asked for |
| `:sympy` | Specialty: Python only, and there only for scalar documents. | — | `compiler_unavailable` |

**What is reachable today, and what is not.** `esm_problem` / `solve` build the
tree-walk evaluator under `:native` or `:interpreter`, and the compiled
StableHLO program under `:xla`. ModelingToolkit is the one value the stable
entry point still cannot reach.

No environment variable selects an evaluation strategy. The `ESS_*` variables
that remain are tuning thresholds — a node budget, a per-function size cap, a
threading floor, a tier's admission floor — and under a strict `:native` each
is a **refusal boundary**: crossing it produces `compiler_refused_rule` rather
than a quiet demotion, so moving one changes which documents build. Two
experimental emission tiers ship off and are opted into by name
(`ESS_CG_SUBCALL_FN`, `ESS_NESTED_TEMPLATE_BOUNDARY`); neither is an oracle,
and nothing in the corpus depends on either.

`:mtk` is still reached through its own entry point, below. ModelingToolkit in
particular is not the default of the public simulation API and is not reachable
from it: a document run through `esm_problem` without `compiler = :xla` is run
by the tree-walk build.

Each runner consumes the canonical-form AST emitted by [`discretize`](@ref) and
walks it generically — none contains per-rule-shape dispatch — and each meets
the [criteria for an official ESS simulation runner](#official-runner-criteria).

## Pathway

The pathway is the same whichever runner builds the right-hand side:

```
.esm JSON
  → parse / load             # JSON → AST (EarthSciAST parsers)
  → discretize               # rule application (RFC §11)
  → SIMULATION RUNNER        # the tree-walk build, MTK.System(...), or the emitter
  → ODEProblem / solve       # SciML solver of choice
```

Rule application (the canonical pipeline of `canonicalize → rule engine →
canonicalize → DAE classification`) lives in [`discretize`](@ref). After it
runs, the document carries canonical-form AST. The runner walks that AST
generically; it never inspects rule kinds.

## `tree_walk` — when MTK's compile time becomes prohibitive

[`esm_problem`](@ref) is the entry point, and the Problem it returns carries
everything a run needs:

```julia
using EarthSciAST
using OrdinaryDiffEqTsit5

prob = esm_problem("model.esm", (0.0, 10.0))   # load → discretize → build → seed
sol  = solve(prob, Tsit5())

x_final = sol[Symbol("Model.x")][end]          # indexed BY NAME
```

`prob.var_map` is the state-name → index lookup, for a caller that wants to
probe the raw state vector rather than index the solution by name; `prob.f!`,
`prob.u0`, `prob.p` and `prob.tspan` are the same objects the old five-tuple
handed back.

!!! note "`build_evaluator` has been retired"
    `build_evaluator` was the public entry point here and is not any more
    (`API_SPEC.md` §8 item 23): it is private behind `esm_problem`, with a
    deprecated alias that warns once and forwards, kept for one minor version.
    A caller reassembling a run out of its five-tuple reads the same values off
    the Problem; `forcing_buffers` and `forcing_buffer_index` take the Problem;
    the build-inspection record's compiler half is [`compiler_report`](@ref),
    which a Problem and a `BuildInspection` both answer; and the compiled
    right-hand side that `form = :oop` handed a backend is
    `esm_problem(…; compiler = :xla)`.

## `:xla` — the compiled StableHLO right-hand side

With `using Reactant` in the session, `compiler = :xla` builds the document out
of place — the compiled tree-walk intermediate representation is what the
direct emitter lowers — emits StableHLO from it op by op, compiles that program
ONCE per build on an XLA client, and wraps the executable in the in-place
`f!(du, u, p, t)` every Problem carries:

```julia
using EarthSciAST, Reactant, OrdinaryDiffEqTsit5

prob = esm_problem("model.esm", (0.0, 10.0); compiler = :xla)
sol  = solve(prob, Tsit5())                    # every step runs the compiled program
compiler(prob)                                 # :xla
compiler_report(prob)                          # …the rhs_program row names the device
```

`u`, `p` and `t` are program INPUTS, so one compile serves every step, every
stage and every save, and `remake(prob; p = …)` re-parameterizes without a
retrace. The integrator owns `u` and `du` as ordinary host vectors, so each call
copies the state onto the device and the derivative back; keeping the state
resident across steps would mean owning the time loop, which is an integrator
rather than a right-hand side.

`EARTHSCI_JULIA_XLA_DEVICE` picks the client — `cpu` (the default, always
available) or `gpu` — and the build's `compiler_report` records which one ran,
as the tier `:xla_direct_cpu` / `:xla_direct_gpu` on the row for the assembled
program. It is not an evaluation strategy and nothing else reads it: the same
StableHLO module compiles on either platform. Both of its failures are answered
before the document is loaded: any other value is an `ArgumentError` (a typo is
a configuration error, not a missing compiler), and `gpu` in a process with no
GPU client is `compiler_unavailable`.

**A stiff algorithm needs no setting.** A compiled device program cannot be
differentiated on the host, so an `:xla` Problem hands `solve` its own
finite-difference Jacobian and time derivative through the compiled program
(n + 1 calls per Jacobian for n states). `solve(prob, Rosenbrock23())` runs as
written, and so does `run_inline_tests(doc; compiler = :xla)` on a document
that declares `solver.stiffness: "high"`.

**It refuses rather than falls back**, always with a `compiler_refused_rule`
naming the rule and the reason:

* anything the emitter cannot lower, with the construct and the rule it came
  from taken straight off the emitter's own hard error;
* a call whose element type is not `Float64`. `solve` on the Problem never
  makes one, but a caller who builds its own `ODEProblem` from `prob.f!` and
  lets a stiff algorithm forward-differentiate it does; name a finite-difference
  Jacobian there (`autodiff = AutoFiniteDiff()`) or build `compiler = :native`;
* a document binding LIVE FORCING BUFFERS (`param_arrays`, or a discrete data
  provider). The compiled program takes those as arguments and needs them
  re-synced to the device at each cadence boundary, which this entry point does
  not wire yet; the buffer-free form would bake the build-time forcing in as a
  constant and run the whole simulation against it, which is a wrong number with
  nothing in the result to say so. Refused before the build starts.

`compiler = :xla` builds only through `esm_problem`. The lower-level build asked
for `compiler = :xla` in the in-place form is an `ArgumentError`, because the
in-place evaluator is `native`'s and returning it under an `:xla` report would
be a fallback.

### Single-expression entry point — `evaluate_expr`

For callers that need to evaluate one AST expression at a given set of
numeric bindings (e.g. units fixture consumption tests, or `simplify`'s
constant-folding step), [`evaluate_expr`](@ref) reuses the same compile
+ walker pipeline the Problem's build uses:

```julia
val = evaluate_expr(expr, Dict("x" => 2.0, "y" => 3.0))
```

Adding an op to the walker transparently extends `evaluate_expr` — there
is no parallel dispatch table. Unbound variables raise
`UnboundVariableError`; everything else surfaces as `TreeWalkError`.

### Performance characteristics

- **Build time independent of system size.** The build walks each
  equation's RHS once at build time and produces a compact compiled-IR tree
  (`_Node`) where ops are `Symbol` (pointer compare), state references have
  their `u`-index baked in, parameter references have their `Val{sym}` type
  parameter baked in for monomorphic `NamedTuple` access, and literals are
  pre-promoted to `Float64`. There is no symbolic simplification, tearing, or
  codegen pass. A 4096-equation 64×64 advection model builds in well under a
  second on commodity hardware (see `test/tree_walk_test.jl` —
  `Large 2D advection` — which asserts `t_build < 5 s` and `t_solve < 30 s`
  for 100 Tsit5 steps under CI padding).
- **Per-step cost is one type-stable closure call** that iterates `rhs_list`
  and dispatches on `_Node.kind`/`_Node.op`. Observed-variable RHSes are
  inlined at build time (substituted to a fixed point), so the runtime hot
  path never re-resolves observers.
- **No structural simplification.** Trade-off: MTK can eliminate observed
  variables, alias-equate states, and tear DAEs; `tree_walk` does not. If
  your model benefits from structural simplification and fits comfortably in
  MTK's compile budget, prefer MTK.

### Supported ops

`tree_walk` consumes scalarized canonical-form AST. It supports the full
arithmetic, comparison, logical, elementary-function, and `fn` (closed
function registry) op set per `esm-spec` §4 / §9.2:

- Arithmetic: `+`, `-`, `*`, `/`, `^` / `pow`
- Comparison: `<`, `<=`, `>`, `>=`, `==`, `!=`
- Logical: `and`, `or`, `not`, `ifelse`
- Elementary: `sin`, `cos`, `tan`, `asin`, `acos`, `atan` (1- and 2-arg),
  `atan2`, `exp`, `log`, `log10`, `sqrt`, `abs`, `sign`, `floor`, `ceil`,
  n-ary `min`, n-ary `max`
- Constants: `pi` / `π`, `e`
- Closed functions (`fn` op): `interp.searchsorted`, `interp.linear`,
  `interp.bilinear`, the `datetime.*` family, etc.

!!! warning "Closed functions must be total"
    A closed function **must be total over real inputs**: it returns a value
    for every finite argument and **never throws** — an out-of-domain input
    yields `NaN` (or a spec-pinned clamp), not an exception. The vectorized
    access-kernel form — `f!`'s wherever a kernel plans vectorizable, and the
    compiled backend's always — evaluates a closed `fn` eagerly for **every**
    cell, then blends, including cells a guard (`ifelse`/`and`/`or`) discards.
    The scalar reference walk short-circuits instead, so a `fn` that throws
    off-domain is observable only as a difference between tiers, and is a
    **contract violation by the function author, not an evaluator bug**. The
    built-in `datetime.*` / `interp.*` set honors this contract.

Array-typed ops outside a position that consumes them (`faq`, `makearray`,
`reshape`, `transpose`, `concat`) and the value-invention ops (`skolem`,
`rank`, `distinct`, `argmin`, `argmax`) are refused while the evaluator is
built with `unevaluable_operator`; PDE ops (`grad`, `div`, `laplacian`) are
refused with `unlowered_operator` (esm-spec §9.6.6). Either way they must be
discretized, scalarized or materialized **before** the build. The `D` op is only
permitted in equation LHS (the time-derivative marker).

### Errors

[`TreeWalkError`](@ref) is raised when the walker encounters an
unsupported construct. Codes are stable (`E_TREEWALK_*`, plus the two
cross-binding operator codes):

| Code | Cause |
|---|---|
| `unevaluable_operator` | An evaluable-core op the walker has no rule for (an array or value-invention op an earlier stage should have eliminated). Cross-binding code, raised at build (esm-spec §9.6.6). |
| `unlowered_operator` | A rewrite-target op (`grad`, a spatial or right-hand-side `D`, a user op) that no rewrite rule lowered. Cross-binding code (esm-spec §9.6.6). |
| `E_TREEWALK_UNSUPPORTED_OP` | An internal pipeline defect: the removed `call` op, or an `index` that reached compilation unresolved. |
| `E_TREEWALK_UNSUPPORTED_SHAPE` | A variable still has `shape` set — the model is not yet scalarized. |
| `E_TREEWALK_UNSUPPORTED_BROWNIAN` | Brownian variables are not supported by the deterministic ODE walker. |
| `unsupported_construct` | The model declares a continuous event, a discrete event, or an implicit equation (an expression LHS such as `s - f(s) ~ 0`). The walker runs none of them; use the ModelingToolkit runner, which does (esm-spec §9.6.6). |
| `E_TREEWALK_UNSUPPORTED_EQUATION` | Any other equation LHS that is neither `D(state, wrt=t)` nor an observed-variable assignment. |
| `E_TREEWALK_UNBOUND_VARIABLE` | Free variable is neither a state, parameter, nor `t`. |
| `E_TREEWALK_DUPLICATE_DERIVATIVE` | More than one equation defines `D(state, wrt=t)` for the same state. |
| `E_TREEWALK_OBSERVED_CYCLE` | Observed variables form a substitution cycle. |
| `E_TREEWALK_FN_*` | Closed-function arity / argument-shape error. |

## `ModelingToolkit` — events, implicit equations, structural simplification

The `EarthSciASTMTKExt` package extension activates automatically when
`ModelingToolkit` is loaded and provides `ModelingToolkit.System(model)` /
`ModelingToolkit.PDESystem(model)`. It is the one runner that executes
continuous events, discrete events and implicit equations — the constructs the
tree walk refuses with `unsupported_construct` — and the one that performs
structural simplification. It is reached through its own entry point; making it
`esm_problem(…; compiler = :mtk)` is planned. See
[ModelingToolkit / Catalyst integration](index.md#ModelingToolkit-/-Catalyst-integration)
in the manual home page.

## [Official-runner criteria](@id official-runner-criteria)

A simulation runner qualifies as an *official ESS Julia simulation runner*
if and only if all of:

1. It is **documented as such** in the binding's official docs.
2. It **consumes the AST directly** — no shortcut to imperative compute, no
   materialized rule output that bypasses the AST.
3. It has **no per-rule-shape dispatch** in the runner itself. Rule
   application happens in `discretize`; the runner receives canonical-form
   AST and walks it generically. There is no `if rule.kind == "..." then ...`
   branching inside the runner.
4. It has a **documented use case** — when to choose it over the other
   runners.
5. It is **invokable as a public simulation API** by users (not just by
   tests).

The tree-walk build and the MTK path both meet all five.
