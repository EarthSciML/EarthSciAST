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
esm_problem(input, tspan; p, u0, providers, model_name, metaparameters, base_path, compiler, sample_time, runtime_array_parameters, strip, const_arrays, param_arrays, inspect, materialize_out, pushdown_rewrite, program_build, seed_ic!, sinks, snapshot, pre_write, checkpoint_predicates, checkpoint_sinks, terminate_on_checkpoint)
```

```julia
esm_problem(input, tspan; p=Dict(), u0=nothing, kwargs...) -> EsmProblem
```

Build the simulation problem for `input` over `tspan = (t0, t1)`
(esm-libraries-spec §2.5). Construction loads, flattens and shape-transforms the
document, materializes provider fields, builds the evaluator, seeds the initial
state and composes the callbacks once; `solve` then integrates the returned
[`EsmProblem`](/generated/api/ref/esm_problem-type) as often as you like.

`input` is a path to an `.esm` file, a native ESM `Dict`, a loaded
[`EsmFile`](/generated/api/ref/esm_file) or a [`FlattenedSystem`](/generated/api/ref/flattened_system). All but a `FlattenedSystem` are
flattened, so every name below and every solution index is namespaced
(`"Chem.A"`, not `"A"`). The document is parsed here: mutating `input` afterwards
does not affect the problem (forcing arrays are aliased; see [`EsmProblem`](/generated/api/ref/esm_problem-type)).
Two problems may be built at once on two tasks; one problem's `f!` is not to be
called from several threads at once.

Keywords (API_SPEC §5.8):

* `p::AbstractDict` — parameter overrides, baked into the build, so every class
  of parameter can be set here, including the `:structural` ones `remake` refuses
  ([`parameter_classes`](/generated/api/extension/julia#x-parameter_classes)). Keys may be local (`pert_amp`) or namespaced
  (`Chem.pert_amp`). The values also bind build-time evaluation (esm-spec §6.6.5):
  a coordinate-expression `ic` and an inline assertion `reference` see them.
* `u0` — an `AbstractDict` of overrides applied on top of the document's initial
  conditions (`"M.y"`, `"M.f[1,2]"`, or `"M.f"` broadcasting one value over every
  cell), or an `AbstractVector` replacing the seeded state.
* `providers::AbstractDict` — `<Loader>.<var> => data Provider`. Const providers
  ([`provider_is_const`](/generated/api/extension/julia#x-provider_is_const)) are materialized once into `const_arrays`;
  discrete providers get a live buffer and a [`build_refresh_callback`](/generated/api/extension/julia#x-build_refresh_callback). A
  key naming a data-fed parameter may be local or namespaced (esm-spec §6.6.2).
  A scalar parameter fed this way has no slot in `p`.
* `model_name` — the model to build when the document holds several.
* `metaparameters::AbstractDict` — binds open metaparameters, as
  [`load_path`](/generated/api/ref/load_path)`(path; metaparameters=…)` does (esm-spec §9.7.6).
* `base_path::AbstractString = pwd()` — where a `Dict` input's relative `{ref}`s
  resolve (a path input uses its own directory).
* `sample_time::Real = tspan[1]` — the `t` at which providers are sampled for the
  build. An `ic` right-hand side reads data-fed parameters at `tspan[1]` whatever
  `sample_time` is (esm-libraries-spec §2.5.2).
* `compiler::Symbol = :native` — one of `:native`, `:interpreter`, `:xla`, `:mtk`,
  `:sympy` (esm-libraries-spec §2.5.10); read back with [`compiler`](/generated/api/extension/julia#x-compiler) and
  [`compiler_report`](/generated/api/extension/julia#x-compiler_report). `:native` is strict: where one of its compiled tiers
  declines, the build raises `compiler_refused_rule` naming the rule and reason
  instead of falling back to a slower path. It refuses events, implicit equations
  and SDE noise with `unsupported_construct`. `:interpreter` is the reference tree
  walk with no performance promise. `:mtk` needs `using ModelingToolkit`, runs
  events and implicit equations, refuses loaded data, a continuous spatial
  dimension, a geometry operator and a time derivative of an expression
  (`compiler_refused_rule`), classifies every parameter `:structural`, and indexes
  its solution by the compiled system's symbols (`prob.var_map` and
  [`observed_field`](/generated/api/ref/observed_field) give the document names). `:xla` needs `using Reactant`.
  A compiler this session cannot run raises `compiler_unavailable` (`:sympy`
  always does in Julia); a value outside the vocabulary raises `compiler_unknown`.
  Both are raised before the document is loaded. The Simulation Runners page has
  the details.
* `strip` — classes of construct to remove before the build (`"algebraic"`,
  `"continuous_events"`, `"discrete_events"`, `"parameter_updates"`); the removed
  constructs are on the problem ([`stripped`](/generated/api/ref/stripped)) and `solve` refuses a problem
  that lost any. `:native` and `:interpreter` only.
* `program_build::Bool = false` — build the right-hand side as the whole-model
  program [`rhs_program`](/generated/api/ref/rhs_program) returns, so `rhs_program(prob)` does not lower the
  model again. Evaluations are bitwise those of that program. A state-free field
  over a live forcing buffer is recomputed on every call rather than per refresh,
  and every externally fed parameter is read from a live buffer (classified
  `:forcing`, absent from `prob.p`). Needs `:native` or `:interpreter`; refuses
  `materialize_out`.
* `runtime_array_parameters::Bool = false` — keep every shaped parameter with a
  value as a live buffer ([`forcing_buffers`](/generated/api/extension/julia#x-forcing_buffers)) instead of folding it, so a
  program of the problem takes it as a [`ForcingSlot`](/generated/api/ref/forcing_slot) of kind
  `:array_parameter`. A shaped parameter bound through `param_arrays` is a live
  buffer either way.
* `pushdown_rewrite::Bool = false` — apply `desugar_pushdown` to the
  authored document before flattening; a provider routed onto a rewritten array
  is then fetched pre-sliced to its support set.

Julia extension-seam keywords (allowed by §2.5.2; not stable API): `const_arrays`,
`param_arrays` (forwarded to the build), `inspect` (a fresh
[`BuildInspection`](/generated/api/extension/julia#x-buildinspection) the build fills; one record per call),
`materialize_out` (a caller-owned [`DiscreteMaterializer`](/generated/api/extension/julia#x-discretematerializer)), `seed_ic!` (an
`(u0, var_map) -> nothing` hook run after `u0`; see
[`seed_expression_ic!`](/generated/api/extension/julia#x-seed_expression_ic)), and the streaming-output set `sinks`, `snapshot`,
`pre_write`, `checkpoint_predicates`, `checkpoint_sinks`,
`terminate_on_checkpoint`.

**Callbacks** (§2.5.4). Discrete providers, `sinks` and `checkpoint_predicates`
contribute refresh, output and checkpoint callbacks, composed into one set read
back with [`callbacks`](/generated/api/ref/callbacks). A `callback` passed to `solve` replaces that set:

```julia
prob = esm_problem("model.esm", (0.0, 10.0); p = Dict("Chem.k" => 2.0))
sol = solve(prob, Tsit5(); callback = CallbackSet(callbacks(prob), my_extra))
```

**Loader-discovered extents** (esm-spec §8.9.4). A provider reporting a
[`provider_extent_metaparameter`](/generated/api/extension/julia#x-provider_extent_metaparameter) is sampled once, first, and its record
count binds that metaparameter for the load; the sample is reused at injection.
Providers of one loader disagreeing on the count, or a `metaparameters` binding
contradicting it, is an error, and `input` must then be a path or a `Dict` (an
`EsmFile` has its metaparameters closed already).

Per-run settings (`alg`, `abstol`, `reltol`, `saveat`, `callback`, `maxiters`)
belong to `solve(prob, alg; …)`; this call needs neither SciMLBase nor an
OrdinaryDiffEq package.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/pkg/EarthSciAST.jl/src/simulate.jl#L1193)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/docs/api/examples/julia/simulate.jl#L8-L22">docs/api/examples/julia/simulate.jl</a></p>

**Example** (`esm_problem_parameters`)

```julia
# Override a parameter's default at construction.
faster = esm_problem(
    joinpath(FIXTURES, "decay.esm"), (0.0, 10.0);
    p = Dict("lambda" => 0.2)
)
@assert only(observed_field(faster, "half_life")) ≈ log(2) / 0.2
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/docs/api/examples/julia/simulate.jl#L26-L31">docs/api/examples/julia/simulate.jl</a></p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">Not available in TypeScript. TypeScript is outside the simulation capability profile (Julia, Python, Rust): build an RHS and integrate it; TypeScript and Go are deliberately non-simulating.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
esm_problem(input: Any, tspan: tuple[float, float], *, p: dict[str, float] | None = None, u0: dict[str, float] | None = None, providers: dict[str, Any] | None = None, model_name: str | None = None, metaparameters: dict[str, int] | None = None, base_path: str | None = None, sample_time: float | None = None, const_arrays: dict[str, Any] | None = None, cse: bool = True, callback: Any = None, loader_provider: LoaderProvider | None = None, provider_factory: Callable | None = None, inspect: BuildInspection | None = None, pushdown_rewrite: bool = False, compiler: str | None = None, strip: Iterable[str] = ()) -> EsmProblem
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
- `strip` (`Iterable[str]`) — The construct classes construction removes and hands back instead of
  refusing (API_SPEC §5.8, "Strip and expose"): `"continuous_events"`,
  `"discrete_events"`, `"parameter_updates"`, `"algebraic"`. Empty,
  the default, changes nothing. Read what was removed with
  [`stripped`](/generated/api/ref/stripped); [`solve`](/generated/api/ref/solve) and [`init`](/generated/api/ref/init)
  refuse a Problem anything was removed from. `"native"` and
  `"interpreter"` only; the input must be a path, a `dict` or an `EsmFile`.

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/pkg/earthsci-ast-py/src/earthsci_ast/problem.py#L450)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/docs/api/examples/python/simulate.py#L12-L26">docs/api/examples/python/simulate.py</a></p>

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/pkg/earthsci-ast-rs/src/problem/mod.rs#L1285) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.esm_problem.html)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/docs/api/examples/rust/simulate.rs#L13-L33">docs/api/examples/rust/simulate.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Not available in Go. Go is outside the simulation capability profile (Julia, Python, Rust): build an RHS and integrate it; TypeScript and Go are deliberately non-simulating.</p>

</div>

</div>
