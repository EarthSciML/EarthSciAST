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
| `:xla` | Specialty: needs a heavy external dependency. StableHLO emitted directly and compiled through Reactant; a hard error on anything it cannot lower. | the direct emitter in the Reactant extension | **planned.** Reachable today only through [`build_evaluator`](@ref)`(…; form = :oop)`, not from `esm_problem` |
| `:mtk` | Specialty: only some documents — but it is the one runner that executes **events and implicit equations**. Data handed in at the call, a continuous spatial dimension, a geometry operator and a time derivative of an expression are refused by name. | `ModelingToolkit.System` → `mtkcompile` → `ODEProblem`, through the package extension | **live** with `ModelingToolkit` loaded. `esm_problem(…; compiler = :mtk)`; without the package it is `compiler_unavailable` naming it |
| `:sympy` | Specialty: Python only, and there only for scalar documents. | — | `compiler_unavailable` |

**What is reachable today, and what is not.** `esm_problem` / `solve` build the
tree-walk evaluator under `:native` or `:interpreter`, and the ModelingToolkit
system under `:mtk` when that package is loaded. The Reactant emitter is the one
the stable entry point still does not reach.

No environment variable selects an evaluation strategy. The `ESS_*` variables
that remain are tuning thresholds — a node budget, a per-function size cap, a
threading floor, a tier's admission floor — and under a strict `:native` each
is a **refusal boundary**: crossing it produces `compiler_refused_rule` rather
than a quiet demotion, so moving one changes which documents build. Two
experimental emission tiers ship off and are opted into by name
(`ESS_CG_SUBCALL_FN`, `ESS_NESTED_TEMPLATE_BOUNDARY`); neither is an oracle,
and nothing in the corpus depends on either.

`:xla` is still reached through its own entry point, below. ModelingToolkit is
reached BOTH ways: `compiler = :mtk` builds a problem through it, and the
`ModelingToolkit.System` / `PDESystem` constructors remain the direct route for
a caller who wants the symbolic system itself. Neither is the default — a
document run through `esm_problem` with no `compiler` is run by the tree-walk
build.

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
discretized, scalarized or materialized **before** `build_evaluator`. The `D` op is only
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
| `unsupported_construct` | The model declares a continuous event, a discrete event, or an implicit equation (an expression LHS such as `s - f(s) ~ 0`). The walker runs none of them, so `:native` and `:interpreter` both refuse; build with `compiler = :mtk`, which runs all three (esm-spec §9.6.6). |
| `E_TREEWALK_UNSUPPORTED_EQUATION` | Any other equation LHS that is neither `D(state, wrt=t)` nor an observed-variable assignment. |
| `E_TREEWALK_UNBOUND_VARIABLE` | Free variable is neither a state, parameter, nor `t`. |
| `E_TREEWALK_DUPLICATE_DERIVATIVE` | More than one equation defines `D(state, wrt=t)` for the same state. |
| `E_TREEWALK_OBSERVED_CYCLE` | Observed variables form a substitution cycle. |
| `E_TREEWALK_FN_*` | Closed-function arity / argument-shape error. |

## `compiler = :mtk` — events, implicit equations, structural simplification

The `EarthSciASTMTKExt` package extension activates automatically when
`ModelingToolkit` is loaded. It is the one runner that executes continuous
events, discrete events and implicit equations — the constructs the tree walk
refuses with `unsupported_construct` — and the one that performs structural
simplification.

```julia
using EarthSciAST, ModelingToolkit, OrdinaryDiffEqTsit5
prob = esm_problem("sawtooth.esm", (0.0, 2.5); compiler = :mtk)
sol  = solve(prob, Tsit5())           # the event fires; the tree walk refuses this document
```

The build is `ModelingToolkit.System(flatten(file))` → `mtkcompile` →
`ODEProblem`, and `solve` integrates THAT problem, so the compiled system's
events, mass matrix and observed equations are all in force. The
[`EsmProblem`](@ref) around it is the ordinary one: `u0`, `p`, `tspan`,
`var_map`, `callbacks`, `remake`, [`compiler_report`](@ref) and
[`observed_field`](@ref) all work, and streaming-output sinks compose with the
compiled system's own event callbacks rather than replacing them.

**What it refuses, by name.** "Only some documents" is a statement about
refusals, not about coverage that drifts. `compiler_refused_rule` names the rule
and the reason for:

* a parameter or field fed by LOADED DATA — a `providers` entry, a
  `const_arrays` / `param_arrays` array handed in at the call, or
  `pushdown_rewrite = true`. A ModelingToolkit system carries symbols and
  equations; a loaded field has nowhere to land in it.
* a CONTINUOUS spatial dimension. That is a PDE, and it needs
  `ModelingToolkit.PDESystem` plus a discretizer this compiler does not run. A
  document already discretized into an `arrayop` stencil has no spatial
  independent variable and builds normally.
* a geometry operator (`polygon_intersection_area`, `intersect_polygon`), which
  is resolved against loaded polygons at build time and has no symbolic form.
* `D(<expression>)` — a time derivative of an expression credits no state, so it
  is an implicit equation spelled wrong; ModelingToolkit rejects the system and
  this names the equation instead.

**Two differences from the other compilers, both deliberate.**

1. **Parameters bake at build.** Every parameter is `:structural` in
   [`parameter_classes`](@ref): its value is read where `mtkcompile` can see it
   and is baked into the compiled problem, so `esm_problem(…; p = …)` sets it
   and `remake(prob; p = …)` refuses, naming the parameter. That is the class's
   ordinary meaning, not a special case.
2. **Solution indexing is ModelingToolkit's own.** A solution carries the
   compiled system as its index provider, so `sol[sym]` takes that system's
   symbols — a flattened `Chem.A` is `Chem_A` there, because a dot is not a
   Julia identifier character. The DOCUMENT's spelling reaches you through
   `prob.var_map` (name → the slot that indexes `sol.u[i]`) and through
   `observed_field(prob, name)`, which answers out of the compiled system's
   observed equations. Substituting a translating index provider breaks
   ModelingToolkit's own initialization, which reads that field back as a
   `System`.

`ModelingToolkit.System(model)` / `ModelingToolkit.PDESystem(model)` remain the
direct route to the symbolic system itself. See
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
