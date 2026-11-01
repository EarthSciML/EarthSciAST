---
title: "esm_problem (function)"
description: "Stable function · Simulation"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Simulation](/generated/api/topics/simulation)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `esm_problem` | outside profile | `esm_problem` | `esm_problem` | outside profile |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
esm_problem(input, tspan; p, u0, providers, model_name, metaparameters, base_path, compiler, sample_time, runtime_array_parameters, const_arrays, param_arrays, inspect, materialize_out, pushdown_rewrite, seed_ic!, sinks, snapshot, pre_write, checkpoint_predicates, checkpoint_sinks, terminate_on_checkpoint)
```

```julia
esm_problem(input, tspan; p=Dict(), u0=nothing, kwargs...) -> EsmProblem
```

Build the ESM simulation problem for `input` over `tspan = (t0, t1)` — the one
noun of esm-libraries-spec §2.5. Construction runs everything deterministic per
document ONCE (coerce `input` to a runnable document: load → flatten → shape
transforms; materialize provider fields; build the tree-walk evaluator; seed the
initial state; compose the problem's callbacks) and returns an
[`EsmProblem`](/generated/api/ref/esm_problem-type) that `solve` integrates as often as you like.

`input` may be a path to an `.esm` file, a native ESM `Dict`, a loaded
[`EsmFile`](/generated/api/ref/esm_file), or a [`FlattenedSystem`](/generated/api/ref/flattened_system). The first three are AUTHORED
documents and are FLATTENED, so every name below (and every solution index) is
the flattener's namespaced one — `"Chem.A"`, not `"A"`. Only a
`FlattenedSystem` skips the flattener, that being the type whose whole meaning
is "already flattened". **Snapshot semantics**: the document is fully parsed
here, so mutating `input` afterwards does not affect the problem (forcing arrays
are aliased by design; see [`EsmProblem`](/generated/api/ref/esm_problem-type)).

Stable keyword arguments (API_SPEC §5.8 — the bindings that fix a DOCUMENT):

* `p::AbstractDict` — parameter overrides. Baked into the build (they feed
  build-time constant folding), which is why EVERY class of parameter can be set
  here — including the `:structural` ones a `remake` must refuse (see
  [`parameter_classes`](/generated/api/extension/julia#x-parameter_classes)). A purely `:numeric` change need not rebuild:
  pass it to `remake(prob; p = …)`, which swaps `p`. Keys may be spelled LOCALLY
  (`pert_amp`, the form esm-spec §6.6 pins for a test's `parameter_overrides`)
  or with the flattener's namespacing (`Chem.pert_amp`); both resolve to the
  same parameter. The resolved values also bind the BUILD-TIME evaluation scope
  (esm-spec §6.6.5): a coordinate-expression `ic` and an inline assertion
  `reference` see the override, not the declared default.
* `u0` — the initial state. Either an `AbstractDict` of per-element or broadcast
  overrides applied on top of the document's own initial conditions (keys spelled
  `"M.y"`, `"M.f[1,2]"`, or a bare array name `"M.f"` broadcasting one value over
  every cell), or an `AbstractVector` replacing the seeded vector outright.
* `providers::AbstractDict` — `<Loader>.<var> => data Provider`, the loaded-data
  injection seam. CONST providers ([`provider_is_const`](/generated/api/extension/julia#x-provider_is_const)) are materialized
  once at build time into `const_arrays` under their loader variable name — so a
  scoped-reference `ic(Sys.sp) ~ Model.param` folds the seeded field into `u0`
  and a loader→consumer `variable_map` binding resolves the consumer gather from
  it. DISCRETE providers get a live buffer plus a [`build_refresh_callback`](/generated/api/extension/julia#x-build_refresh_callback)
  on the problem, so their forcing refreshes in place at its cadence.
* `model_name` — select one model when the document holds several.
* `metaparameters::AbstractDict` — binds the document's open metaparameters at
  the loader API (esm-spec §9.7.6 binding site 3), exactly as
  [`load_path`](/generated/api/ref/load_path)`(path; metaparameters=…)` does. Pass them HERE rather than
  pre-`load`ing, so a loader that discovers its own extent can close one first
  (below); a caller binding that CONTRADICTS a discovered extent is an error.
* `base_path::AbstractString = pwd()` — the directory a native `Dict` input's
  relative `{ref}`s resolve against (a path input anchors them at its own
  directory).
* `sample_time::Real = tspan[1]` — the `t` at which providers are sampled for
  the build. A CONST provider is time-invariant by contract; DISCRETE buffers
  seeded here are re-seeded at each run's `t0` anyway.
* `compiler::Symbol` — which strategy builds the right-hand side, over the
  closed vocabulary `:interpreter`, `:native`, `:xla`, `:mtk`, `:sympy`
  (esm-libraries-spec §2.5.10). Unnamed, it is `:native`. Read back with
  [`compiler`](/generated/api/extension/julia#x-compiler)`(prob)` and [`compiler_report`](/generated/api/extension/julia#x-compiler_report)`(prob)`.

  **`:native` (the default) is STRICT.** It is this package's compiled tiers —
  the affine stencil build, the `RuntimeGeneratedFunctions` emitter and the
  whole-array forms — for every document whatever its shape, and never a quiet
  demotion to a slower path. It covers the whole evaluable core, and the only
  documents it may refuse are those carrying a construct outside its scope,
  each refused by name: events, implicit equations and SDE noise
  (`unsupported_construct`; `:mtk` runs the first two) and a spatial operator
  with no discretization rule (`unlowered_operator`, refused under every
  compiler). Every compiler-driven conformance tier requires `:native` for
  every fixture, so any other refusal is a defect in this package.

  The strictness is enforced as a BUILD error, `compiler_refused_rule`, naming
  the rule and the deepest decline reason, raised at exactly three points —
  each one a compiled tier declining where it must not:

  1. **An access kernel both codegen emissions declined.** Such a kernel runs
     on `_run_acc_kernel!` — a tree walk once per output cell, on every
     right-hand-side call. A decline by the PRIMARY emission alone is not a
     refusal: the overflow emission retries under an unbounded node budget and
     also serves Float64, so the budget reason cannot recur.
  2. **An equation the whole-array contraction tier ACCEPTED.** On that tier
     success is what leaves an interpreter in the right-hand side: its runner
     evaluates the body once per output cell and no codegen tier ever sees the
     section. This is compiler backlog, not a property of the document.
  3. **A construction-time or output-time materialization that resolves and
     compiles the expression once per cell** — the per-cell arms of the setup
     MAP, of the whole-array setup materializer, of the coordinate-expression
     initial-condition seed and of the faq initialization-equation seed, which
     are reached only when the compiled fill (each filled through the
     right-hand-side cascade and emitted code, once) and any compile-once form
     decline, and the build-time observed evaluator's per-cell arm. §2.5.10
     puts every evaluation a compiler performs for the problem under the same
     rule, not the right-hand side alone.

  What it does NOT refuse: a per-cell BUILD (an equation scalarized one output
  cell at a time whose cell entries are then compiled — that costs build time
  and nothing per step), a `_StencilFallback` on its own (its landing is a
  per-cell build), and a compile-once setup sweep that evaluates an already
  compiled node per cell.

  `:interpreter` is the reference and carries no performance promise: every
  fast tier off, one tree walk per output cell. Pick it to check another
  compiler. It keeps the build-time
  MEMOS (the template expansion memo, the reference-preserving template image),
  which change build wall time and not one evaluated bit.

  **`:mtk` is the specialty compiler that works only for some documents**, and
  it is the one that runs EVENTS and IMPLICIT EQUATIONS — the constructs
  CONFORMANCE_SPEC §5.39 has every other evaluator refuse with
  `unsupported_construct`. It needs `using ModelingToolkit` (without it, the
  answer is `compiler_unavailable` naming that), and it builds
  `ModelingToolkit.System(flatten(input))` → `mtkcompile` → `ODEProblem`, which
  is what `solve` then integrates, so the compiled system's events, mass matrix
  and observed equations are all in force. What it REFUSES by name
  (`compiler_refused_rule`) is the document content it cannot express: a
  parameter or field fed by LOADED DATA (a `providers` entry, a `const_arrays`
  / `param_arrays` argument, `pushdown_rewrite = true`), a CONTINUOUS spatial
  dimension (a PDE, which needs `ModelingToolkit.PDESystem` and a
  discretization), a geometry operator, and a time derivative of an expression.
  Two consequences a caller sees: every parameter classifies `:structural`
  (the value is read where `mtkcompile` can see it and is baked into the
  compiled problem, so `esm_problem(…; p = …)` sets it and `remake(prob; p = …)`
  refuses), and a solution is indexed with the COMPILED SYSTEM's symbols rather
  than the flattened ESM spelling — `prob.var_map` and
  [`observed_field`](/generated/api/ref/observed_field) are the document-named surface there. See the
  Simulation Runners page for the whole story.

  `:xla` and `:sympy` raise `compiler_unavailable` from this entry point,
  naming what to load or which binding has them; a value outside the vocabulary
  raises `compiler_unknown`.

  Naming `:native` is exactly the default: no environment variable selects an
  evaluation strategy, so the keyword is the whole answer (esm-libraries-spec
  §2.5.10). The `ESS_*` variables that remain are tuning thresholds — under a
  strict `native` each is a refusal boundary: moving one off its default can
  make `native` refuse an in-scope document, a defect, rather than run it
  more slowly.

Julia extension-seam keywords (§2.5.2 explicitly allows these; NOT stable API):
`const_arrays`, `param_arrays` (forwarded to the build — the
regridder source polygons and the live forcing buffers), `inspect` (share the
problem's [`BuildInspection`](/generated/api/extension/julia#x-buildinspection) with the caller), `materialize_out` (a
caller-owned [`DiscreteMaterializer`](/generated/api/extension/julia#x-discretematerializer)), `pushdown_rewrite`, `seed_ic!`
(an `(u0, var_map) -> nothing` hook for array ICs that need grid geometry; runs
after `u0`, see [`seed_expression_ic!`](/generated/api/extension/julia#x-seed_expression_ic)), and the streaming-output set
`sinks` / `snapshot` / `pre_write` / `checkpoint_predicates` /
`checkpoint_sinks` / `terminate_on_checkpoint`.

`runtime_array_parameters::Bool = false` makes every shaped parameter with a
value (a declared `default`, a scalar broadcast over its grid, an inline
override in `p`, or a caller's `const_arrays` entry) a live buffer holding that
value rather than build-time data: it appears in
[`forcing_buffers`](/generated/api/extension/julia#x-forcing_buffers)`(prob)`, and a program of the Problem
([`rhs_program`](/generated/api/ref/rhs_program)) takes it as a [`ForcingSlot`](/generated/api/ref/forcing_slot) of kind
`:array_parameter` whose default buffer is that value, so a caller evaluates at
another field without a rebuild. Off, those parameters are folded into the
build as before. Either way, a shaped parameter the caller binds through
`param_arrays` is a live buffer, and a program's slot of kind `:array_parameter`
unless the parameter is externally fed.

`pushdown_rewrite::Bool = false` opts in to the automatic projection-pushdown
desugar (`desugar_pushdown`) at the PUBLIC entry point. The rewrite runs
on the authored document BEFORE flattening (the pattern is authored in the
un-namespaced model), and the engine then derives every provider gate from the
rewrite's own `metadata.x_esd.pushdown` record: a `providers` entry that the
document's coupling routes onto a rewritten array is DEFERRED and fetched
pre-sliced to the invented support set — the caller hand-authors no gate dict.

**Callbacks** (§2.5.4). A discrete provider contributes a refresh callback, a
non-empty `sinks` an output callback, and non-empty `checkpoint_predicates` a
checkpoint callback; they are composed into ONE callback set on the problem.
Read it back with [`callbacks`](/generated/api/ref/callbacks). A `callback` argument to `solve`
REPLACES it entirely — it does not append, merge, or wrap:

```julia
solve(prob, Tsit5(); callback = CallbackSet(callbacks(prob), my_extra))
```

**Loader-discovered extents** (esm-spec §8.9.4, CONFORMANCE_SPEC §5.5). A
provider reporting a [`provider_extent_metaparameter`](/generated/api/extension/julia#x-provider_extent_metaparameter) is sampled ONCE
here, ahead of everything else, and the length of its delivered record axis
binds that metaparameter for the load below — so `size: "N_REC"` is sized by the
data itself. That array is REUSED when the provider is injected (never sampled
twice); providers of one loader disagreeing on the count is an error naming
both, and a `metaparameters` binding contradicting the discovered value is an
error rather than a silent preference for either. Because the metaparameter must
still be OPEN, `input` must be a path or a native `Dict` — an already-`load`ed
`EsmFile` has closed it already, which is an error rather than a silent
fallback.

Per-RUN knobs (`alg`, `abstol`, `reltol`, `saveat`, `callback`, `maxiters`)
belong to `solve(prob, alg; …)`; §2.5.9 keeps the solver out of construction, so
this call needs neither SciMLBase nor an OrdinaryDiffEq package.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/simulate.jl#L1145)

**Example** (`simulate`)

```julia
prob = esm_problem(joinpath(FIXTURES, "decay.esm"), (0.0, 10.0))
@assert prob isa EsmProblem

λ = 0.1
sol = solve(prob, Tsit5(); saveat = [0.0, log(2) / λ, 10.0], reltol = 1.0e-8)
@assert sol.retcode == ReturnCode.Success

# A solution is indexed by the flattened variable name, as a Symbol.
N = sol[Symbol("Decay.N")]
@assert N[1] == 100.0
@assert isapprox(N[2], 50.0; rtol = 1.0e-5)  # half left after one half-life

# Observed variables are read off the problem. half_life is a scalar field.
half_life = only(observed_field(prob, "half_life"))
@assert half_life ≈ log(2) / λ
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/docs/api/examples/julia/simulate.jl#L8-L22">docs/api/examples/julia/simulate.jl</a></p>

**Example** (`esm_problem_parameters`)

```julia
# Override a parameter's default at construction.
faster = esm_problem(
    joinpath(FIXTURES, "decay.esm"), (0.0, 10.0);
    p = Dict("lambda" => 0.2)
)
@assert only(observed_field(faster, "half_life")) ≈ log(2) / 0.2
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/docs/api/examples/julia/simulate.jl#L26-L31">docs/api/examples/julia/simulate.jl</a></p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">Not available in TypeScript. TypeScript is outside the simulation capability profile (Julia, Python, Rust): build an RHS and integrate it; TypeScript and Go are deliberately non-simulating.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
esm_problem(input: Any, tspan: tuple[float, float], *, p: dict[str, float] | None = None, u0: dict[str, float] | None = None, providers: dict[str, Any] | None = None, model_name: str | None = None, metaparameters: dict[str, int] | None = None, base_path: str | None = None, sample_time: float | None = None, const_arrays: dict[str, Any] | None = None, cse: bool = True, callback: Any = None, loader_provider: LoaderProvider | None = None, provider_factory: Callable | None = None, inspect: BuildInspection | None = None, pushdown_rewrite: bool = False, compiler: str | None = None) -> EsmProblem
```

Build a document into a runnable [`EsmProblem`](/generated/api/ref/esm_problem-type) (esm-libraries-spec §2.5.2).

This runs the whole deterministic-per-document pipeline ONCE — the pushdown
rewrite, load, flatten, loader-extent discovery, the gated fetch of provider
data, and the compile of the right-hand side — and returns the EsmProblem
[`solve`](/generated/api/ref/solve) runs. Nothing is integrated here, and SciPy is not needed
(§2.5.9).

**Parameters**

- `input` (`Any`) — The document: a path to an `.esm` file, a native `dict`, an
  [`EsmFile`](/generated/api/ref/esm_file), or an already-flattened
  [`FlattenedSystem`](/generated/api/ref/flattened_system). The last two are
  rejected when `pushdown_rewrite=True` — the rewrite needs the raw
  authored document, before the typed parse.
- `tspan` (`tuple[float, float]`) — `(t_start, t_end)`, the integration interval.
- `p` (`dict[str, float] | None`) — Parameter bindings, keyed by either the dot-namespaced name
  (`"Chem.k1"`) or the bare name (`"k1"`). A key naming no single
  parameter is an error here, not a silently unperturbed run
  (esm-spec §6.6.2).
- `u0` (`dict[str, float] | None`) — Initial state, keyed the same way. Falls back to each variable's `ic`
  equation, then its declared default.
- `providers` (`dict[str, Any] | None`) — `{"<ModelPath>.<param>": provider}` — the loaded-data injection seam,
  keyed by the CONSUMING parameter's flattened name, the only spelling
  that names one loaded field and every one (a source declares no
  variables of its own, esm-spec §8.5). A provider is an EarthSciIO
  `Provider` (`materialize()` / `refresh_times()`), a callable
  `(t) -> array`, or an object exposing `sample(t)`. CONST providers
  are materialized once here; a gated provider is DEFERRED and fetched
  pre-sliced after value-invention; a DISCRETE provider is re-sampled per
  cadence segment during [`solve`](/generated/api/ref/solve).
- `model_name` (`str | None`) — Which model to build when the document holds several.
- `metaparameters` (`dict[str, int] | None`) — Closes the document's open metaparameters at load. A loader that
  declares its own `extent` closes one from the DATA instead, and a
  caller binding that contradicts the discovered value is an error.
- `base_path` (`str | None`) — Directory imports resolve against. Defaults to the input file's own
  directory.
- `sample_time` (`float | None`) — The build-time clock a provider is sampled at. Defaults to `tspan[0]`
  — the start of the run is the moment the build describes.
- `const_arrays` (`dict[str, Any] | None`) — Extra caller-supplied arrays merged into the build registry.
- `cse` (`bool`) — Share common subexpressions when lambdifying the rhs / algebraic /
  observed functions. Applies to `compiler="sympy"` and to NO other
  compiler — it names SymPy's own CSE pass, and the vectorized NumPy
  compilers have no lambdification to share subexpressions across.
  `True` is the production setting; `False` bypasses the pass for
  diagnostic comparisons. Compiles for each setting are cached separately
  on the flattened system.
- `callback` (`Any`) — The EsmProblem's [`CallbackSet`](/generated/api/ref/callback_set). A `callback` passed to
  [`solve`](/generated/api/ref/solve) REPLACES this set entirely (§2.5.4).
- `loader_provider`, `provider_factory` — The data-loader seams (RFC pure-io-data-loaders §4.3), consulted only
  when the flattened system has `loader_fields`.
- `inspect` (`BuildInspection | None`) — Optional [`BuildInspection`](/generated/api/extension/python#x-buildinspection)
  observability sink, filled with the build-time products. Build
  observability is an extension seam, not stable API (API_SPEC §5.8).
- `pushdown_rewrite` (`bool`) — Opt into the projection-pushdown desugar on the raw authored document.
- `compiler` (`str | None`) — WHICH strategy builds the right-hand side, over §5.8's closed
  vocabulary — `"native"`, `"interpreter"`, `"xla"`, `"mtk"`,
  `"sympy"`. `None` means `"native"`, and the default is STRICT.

  * `"native"` — whole-box vectorized NumPy for EVERY document, scalar
    ones included. A rule the vectorized tiers cannot express is a BUILD
    error naming the rule and the deepest decline reason
    (`compiler_refused_rule`), never a quiet demotion to the per-cell
    tree walk. Construction evaluates the const-geometry hoist, the
    right-hand side once at `(u0, p, t0)`, and the output-time observed
    pass once, so the refusal is a construction error wherever the
    per-cell walk would have been reached (esm-libraries-spec §2.5.10).
    `native` covers the whole evaluable core: the only documents it may
    refuse are those carrying a construct outside its scope — events,
    implicit equations and SDE noise (`unsupported_construct`) and a
    spatial operator with no discretization rule
    (`unlowered_operator`, refused under every compiler). The
    conformance tiers hold Julia and Rust `native` to that for every
    fixture; this binding is exempt, and its `native` gaps are
    recorded there as named exclusions.
  * `"interpreter"` — the reference: every fast tier off, the per-cell
    `faq` evaluator for every aggregate, source codegen and the
    shape-inference interval hull off. No performance promise of any
    kind; it exists to check the others, and it is bit-identical to
    `"native"` on every document both run.
  * `"sympy"` — the lambdified SymPy SCALAR right-hand side. Refuses an
    array document (an array op anywhere, or a resolvable declared
    `shape`) and an algebraic constraint it cannot solve. `cse`
    applies to this compiler and no other.
  * `"xla"` / `"mtk"` — in the vocabulary, not provided here:
    `compiler_unavailable`, never answered by building something else.

  The cadence-segmented loader and discrete-provider mechanics are
  INTERNAL to both `native` and `interpreter`: a document whose
  forcing refreshes still rebuilds per segment, with that compiler's
  tiers. What the compiler names is how a rule is evaluated, not how
  often.

**Raises**

- [`UnsupportedDimensionalityError`](/generated/api/extension/python#x-unsupporteddimensionalityerror) — If the flattened system still has a spatial independent variable — a
  spatial operator that was never discretized into an `faq` stencil
  (esm-spec §4.7.6.12). Discretized PDEs fold the spatial axis into array
  dimensions, leaving `independent_variables == ["t"]`, and build
  normally.
- `UnknownParameterError`, `AmbiguousParameterError` — If a `p` key names no single parameter.
- [`SimulationError`](/generated/api/extension/python#x-simulationerror) — If the compile fails. A compile error is an error, not a return code:
  [`ReturnCode`](/generated/api/ref/return_code) describes RUNS.
- [`CompilerUnknownError`](/generated/api/extension/python#x-compilerunknownerror), [`CompilerUnavailableError`](/generated/api/extension/python#x-compilerunavailableerror), [`CompilerRefusedRuleError`](/generated/api/extension/python#x-compilerrefusedruleerror) — The three ways naming a `compiler` fails (esm-spec §9.6.6). All are
  [`SimulationError`](/generated/api/extension/python#x-simulationerror) subclasses carrying the
  registry code on `.code`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/problem.py#L442)

**Example** (`simulate`)

```python
doc = earthsci_ast.load_path(FIXTURES / "decay.esm")
prob = earthsci_ast.esm_problem(doc, (0.0, 10.0))

half_life = math.log(2) / 0.1
sol = earthsci_ast.solve(prob, saveat=[0.0, half_life, 10.0])
assert sol.retcode == earthsci_ast.ReturnCode.Success

# A solution is indexed by variable name.
n = sol["N"]
print("N at t = 0, ln 2 / λ, 10:", n)
assert math.isclose(n[1], 50.0, rel_tol=1e-3)
assert math.isclose(n[-1], 100.0 * math.exp(-1.0), rel_tol=1e-3)

# Observed variables are read the same way.
assert math.isclose(sol["half_life"][-1], half_life, rel_tol=1e-9)
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/docs/api/examples/python/simulate.py#L12-L26">docs/api/examples/python/simulate.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn esm_problem<'a>(input: impl Into<ProblemInput<'a>>, tspan: (f64, f64), opts: ProblemOptions) -> Result<EsmProblem, SimulateError>
```

Build a [`EsmProblem`](/generated/api/ref/esm_problem-type) (§2.5.2).

Absorbs the whole deterministic-per-document pipeline — the pushdown
rewrite, value invention, the gated fetch of provider data, CONST-provider
materialization, and the compile of the right-hand side — and takes the
bindings that fix a *document*: parameters, initial state, data providers,
metaparameters, and the model to build when the file holds several.

**Does not require the solver.** With the `solve` Cargo feature off this
still builds; only [`solve`](/generated/api/ref/solve) and the stepping entry points need `diffsol`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/problem.rs#L1746) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.esm_problem.html)

**Example** (`simulate`)

```rust
let path = fixture("decay.esm");
let prob = esm_problem(path.as_path(), (0.0, 10.0), ProblemOptions::default())?;

// Sample the solution at t = ln 2 / λ, one half-life in.
let lambda = 0.1_f64;
let t_half = 2.0_f64.ln() / lambda;
let opts = SolveOptions {
    saveat: Some(vec![0.0, t_half]),
    ..Default::default()
};
let sol = solve(&prob, &opts)?;
assert_eq!(sol.retcode, ReturnCode::Success);

// States are read by name; a bare name resolves when it is unique.
let n = sol.get("N").expect("N is a state");
assert!((n[0] - 100.0).abs() < 1e-9);
assert!((n[1] - 50.0).abs() < 1e-3, "N(ln 2 / λ) = {}", n[1]);

// half_life is an observed: computed from the solution, not stored in it.
let half_life = observed_trajectory(&prob, &sol, "half_life")?;
assert!(half_life.iter().all(|h| (h - t_half).abs() < 1e-9));
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/docs/api/examples/rust/simulate.rs#L13-L33">docs/api/examples/rust/simulate.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Not available in Go. Go is outside the simulation capability profile (Julia, Python, Rust): build an RHS and integrate it; TypeScript and Go are deliberately non-simulating.</p>

</div>

</div>
