---
title: "esm_problem (type)"
description: "Stable type · Simulation"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Simulation](/generated/api/topics/simulation)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `EsmProblem` | outside profile | `EsmProblem` | `EsmProblem` | outside profile |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct EsmProblem
EsmProblem(f!::Function, u0::Vector{Float64}, tspan::Tuple{Float64, Float64}, p, var_map::AbstractDict{String, Int64}, param_buffers::Dict{String, Any}, discrete_providers::Dict{String, Any}, dm::DiscreteMaterializer, n_equations::Int64, buffer_time::Base.RefValue{Float64}, dirty::Base.RefValue{Bool}, output_meta::OutputMeta, run_doc::Dict{String, Any}, run_file::Base.RefValue{Any}, param_classes::Dict{String, Symbol}, inspection::BuildInspection, callback, tstops::Vector{Float64}, save_everystep::Bool, sinks::Vector{Any}, lifecycle_sinks::Vector{Any}, symcache::Base.RefValue{Any}, merged_renames::OrderedCollections.OrderedDict{String, String})
EsmProblem(f!, u0, tspan, p, var_map, param_buffers, discrete_providers, dm, n_equations, buffer_time, dirty, output_meta, run_doc, run_file, param_classes, inspection, callback, tstops, save_everystep, sinks, lifecycle_sinks, symcache, merged_renames)
```

```julia
EsmProblem
```

The ESM simulation problem: the right-hand side `f!` the chosen `compiler`
built — the compiled tree walk under `:native` / `:interpreter`, the compiled
StableHLO program under `:xla` — the seeded initial state `u0`, the integration interval `tspan`, the parameter carrier `p`, the
`var_map`, the live forcing buffers, the discrete-provider/refresh scaffolding,
and the problem's own callback set — everything deterministic per document,
built exactly once by [`esm_problem`](/generated/api/ref/esm_problem-function).

```julia
using EarthSciAST, OrdinaryDiffEqTsit5
prob = esm_problem("model.esm", (0.0, 1.0); p = Dict("M.k" => 2.5))
sol  = solve(prob, Tsit5())
sol.retcode                     # SciMLBase.ReturnCode.Success
sol[Symbol("M.y")]              # that state element's trajectory, BY NAME
prob2 = remake(prob; tspan = (0.0, 5.0))   # no re-load / re-flatten / re-build
```

Snapshot semantics: the input document is fully parsed and compiled at
construction, so mutations to the input (e.g. editing the `Dict` you passed)
afterwards are NOT seen. Forcing arrays (`const_arrays` / `param_arrays`) are
the exception by design: they are captured BY REFERENCE (the live-buffer
refresh contract), not copied.

Repeated runs are independent: `u0` is copied per run, and discrete forcing
buffers are re-seeded from their providers at each run's `t0` (with the
[`DiscreteMaterializer`](/generated/api/extension/julia#x-discretematerializer) caches recomputed) whenever a previous run may
have refreshed them or the start time changed.

Parameter overrides split by CLASS (see [`parameter_classes`](/generated/api/extension/julia#x-parameter_classes)):
`:numeric` ones may be passed to `remake(prob; p = …)` and are applied by
swapping `p` (cheap, and AD-transparent — no rebuild). `:structural`,
`:const_folded` and `:forcing` ones throw: their values were consumed at BUILD
time (or never reach `p` at all), so call [`esm_problem`](/generated/api/ref/esm_problem-function) again.

Fields are an extension seam, not stable API; `var_map`, `p`, `u0`, `tspan`
and `output_meta` are the ones downstream code reads.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/simulate.jl#L797)

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
class EsmProblem
EsmProblem(flat: FlattenedSystem, tspan: tuple[float, float], p: dict[str, float] = dict(), u0: dict[str, float] = dict(), compiler: str = 'native', compiler_report: CompilerReport = CompilerReport(), engine: str = 'scalar', build: _NumpyRhsBuild | None = None, scalar_build: _ScalarRhsBuild | None = None, scalar_build_error: Exception | None = None, const_arrays: dict[str, np.ndarray] = dict(), providers: dict[str, Any] | None = None, gated_provider_keys: list[str] = list(), doc: dict | None = None, solver: Any = None, model_name: str | None = None, metaparameters: dict[str, int] = dict(), sample_time: float = 0.0, cse: bool = True, loader_provider: Any = None, provider_factory: Any = None, inspect: BuildInspection | None = None, callbacks: CallbackSet = CallbackSet(), static_cache: dict[str, Any] = dict(), segment_seed: Any = None)
EsmProblem.observed_field(name: str)
```

A document, built and ready to run (esm-libraries-spec §2.5.2).

Construct one with [`esm_problem`](/generated/api/ref/esm_problem-function); do not instantiate it directly. It
holds everything deterministic-per-document — the flattened system, the
materialized provider arrays, and the compiled right-hand side — so that
[`solve`](/generated/api/ref/solve) only varies the per-run knobs, and a parameter sweep pays the
build cost once.

`p` and `u0` are the SciML spellings of the parameter and initial-state
bindings; both fix the DOCUMENT, so both live here rather than on
[`solve`](/generated/api/ref/solve). `callbacks` is the EsmProblem's callback set — read it
back with [`callbacks`](/generated/api/ref/callbacks).

**Members**

- `observed_field` — Convenience for `observed_field(prob, name)`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/problem.py#L335)

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
pub struct EsmProblem {
    /* private fields */
}

impl EsmProblem { pub fn solver(&self) -> Option<&Solver> }

impl EsmProblem { pub fn tspan(&self) -> (f64, f64) }

impl EsmProblem { pub fn p(&self) -> &HashMap<String, f64> }

impl EsmProblem { pub fn u0(&self) -> &HashMap<String, f64> }

impl EsmProblem { pub fn model_name(&self) -> Option<&str> }

impl EsmProblem { pub fn document(&self) -> &JsonValue }

impl EsmProblem { pub fn compiler(&self) -> Compiler }

impl EsmProblem { pub fn compiler_report(&self) -> &CompilerReport }

impl EsmProblem { pub fn backend_kind(&self) -> &'static str }

impl EsmProblem { pub fn precision(&self) -> Precision }

impl EsmProblem { pub fn is_dynamic(&self) -> bool }

impl EsmProblem { pub fn state_variable_names(&self) -> Vec<String> }

impl EsmProblem { pub fn parameter_names(&self) -> Vec<String> }

impl EsmProblem { pub fn members(&self) -> &HashMap<String, Vec<i64>> }

impl EsmProblem { pub fn extents(&self) -> &HashMap<String, i64> }

impl EsmProblem { pub fn gated_provider_keys(&self) -> &[String] }

impl EsmProblem { pub fn take_inspection(&self) -> BuildInspection }

impl EsmProblem { pub fn observed_fields(&self) -> &HashMap<String, ArrayD<f64>> }

impl EsmProblem { pub fn observed_variable_names(&self) -> Vec<String> }

impl EsmProblem { pub fn observed_field_names(&self) -> Vec<String> }
```

A simulation problem: a document, an interval, and the bindings that fix
the document rather than the run.

Built once by [`esm_problem`](/generated/api/ref/esm_problem-function); run by [`solve`](/generated/api/ref/solve) (or stepped by [`init`](/generated/api/ref/init)).
Re-parameterized without rebuilding by [`remake`](/generated/api/ref/remake).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/problem.rs#L777) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.EsmProblem.html)

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
