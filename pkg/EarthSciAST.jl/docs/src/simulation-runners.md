```@meta
CurrentModule = EarthSciAST
```

# Simulation Runners

EarthSciAST.jl ships **two official ESS simulation runners** for the
Julia binding. Both consume the canonical-form AST emitted by [`discretize`](@ref)
and walk it generically — neither runner contains per-rule-shape dispatch.

| Runner | When to use | Public API |
|---|---|---|
| **ModelingToolkit (MTK)** | Default. Production runtime with full structural simplification, observed-variable handling, and access to the full SciML solver / sensitivity / event ecosystem. | `ModelingToolkit.System(model)` (via package extension) |
| **`tree_walk`** | Very large discretized PDE systems whose scalar count exceeds MTK's `structural_simplify` / tearing / codegen ceiling. Compile time is independent of system size — the path produces an `f!` closure by interpreting the AST directly, with no symbolic simplification pass. | [`build_evaluator`](@ref) |

Both runners are official options. Both meet the
[criteria for an official ESS simulation runner](#official-runner-criteria)
defined at the workspace level: they consume the AST directly, contain no
shortcut to imperative compute, perform no per-rule-shape dispatch, and are
invokable as a public simulation API.

## Pathway

The pathway is the same for both runners:

```
.esm JSON
  → parse / load             # JSON → AST (EarthSciAST parsers)
  → discretize               # rule application (RFC §11)
  → SIMULATION RUNNER        # MTK.System(...) or build_evaluator(...)
  → ODEProblem / solve       # SciML solver of choice
```

Rule application (the canonical pipeline of `canonicalize → rule engine →
canonicalize → DAE classification`) lives in [`discretize`](@ref). After it
runs, the document carries canonical-form AST. The runner walks that AST
generically; it never inspects rule kinds.

## `tree_walk` — when MTK's compile time becomes prohibitive

[`build_evaluator`](@ref) is the public entry point. It accepts a `Model`, an
`EsmFile`, or a raw `AbstractDict` (the output of [`discretize`](@ref)) and
returns a tuple ready to plug into `OrdinaryDiffEq.ODEProblem`:

```julia
using EarthSciAST
using OrdinaryDiffEqTsit5

esm_dict     = JSON3.read(read("model.esm", String))   # parse
discretized  = discretize(esm_dict)                    # rule application
f!, u0, p, tspan, var_map = build_evaluator(discretized)

prob = ODEProblem(f!, u0, tspan, p)
sol  = solve(prob, Tsit5())

x_final = sol.u[end][var_map["x"]]
```

The returned `var_map` is the state-name → index lookup so callers can probe
the solution at specific variables.

### Single-expression entry point — `evaluate_expr`

For callers that need to evaluate one AST expression at a given set of
numeric bindings (e.g. units fixture consumption tests, or `simplify`'s
constant-folding step), [`evaluate_expr`](@ref) reuses the same compile
+ walker pipeline as `build_evaluator`:

```julia
val = evaluate_expr(expr, Dict("x" => 2.0, "y" => 3.0))
```

Adding an op to the walker transparently extends `evaluate_expr` — there
is no parallel dispatch table. Unbound variables raise
`UnboundVariableError`; everything else surfaces as `TreeWalkError`.

### Performance characteristics

- **Build time independent of system size.** `build_evaluator` walks each
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

Array-typed ops (`arrayop`, `makearray`, `broadcast`, `reshape`,
`transpose`, `concat`, `index`, `bc`) and PDE ops (`grad`, `div`,
`laplacian`) raise `E_TREEWALK_UNSUPPORTED_OP` on encounter — they must be
discretized and scalarized **before** `build_evaluator`. The `D` op is only
permitted in equation LHS (the time-derivative marker).

### Errors

[`TreeWalkError`](@ref) is raised when the walker encounters an
unsupported construct. Codes are stable (`E_TREEWALK_*`):

| Code | Cause |
|---|---|
| `E_TREEWALK_UNSUPPORTED_OP` | Op cannot be evaluated by the scalar walker (typically a PDE / array op that should have been rewritten by `discretize`). |
| `E_TREEWALK_UNSUPPORTED_SHAPE` | A variable still has `shape` set — the model is not yet scalarized. |
| `E_TREEWALK_UNSUPPORTED_BROWNIAN` | Brownian variables are not supported by the deterministic ODE walker. |
| `E_TREEWALK_UNSUPPORTED_EQUATION` | Equation LHS is neither `D(state, wrt=t)` nor an observed-variable assignment (algebraic constraints fall outside the ODE walker). |
| `E_TREEWALK_UNBOUND_VARIABLE` | Free variable is neither a state, parameter, nor `t`. |
| `E_TREEWALK_DUPLICATE_DERIVATIVE` | More than one equation defines `D(state, wrt=t)` for the same state. |
| `E_TREEWALK_OBSERVED_CYCLE` | Observed variables form a substitution cycle. |
| `E_TREEWALK_FN_*` | Closed-function arity / argument-shape error. |

## `ModelingToolkit` — the default

For most ESS users MTK is the right runner. The
`EarthSciASTMTKExt` package extension activates automatically when
`ModelingToolkit` is loaded and provides `ModelingToolkit.System(model)` /
`ModelingToolkit.PDESystem(model)`. See
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

Both `tree_walk` and the MTK path meet all five.
