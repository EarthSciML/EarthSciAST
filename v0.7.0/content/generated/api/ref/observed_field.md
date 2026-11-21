---
title: "observed_field"
description: "Stable function · Simulation"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Simulation](/generated/api/topics/simulation)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `observed_field` | outside profile | `observed_field` | `observed_field` | outside profile |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
observed_field(prob::EsmProblem, name::AbstractString; u, t)
```

```julia
observed_field(prob::EsmProblem, name; u = nothing, t = nothing) -> Vector{Float64}
```

The observed `name` of the problem, as a flat vector in row-major cell order
(last index fastest; one element for a scalar observed).

With no `u`, it is the field the BUILD defines: a state-free observed evaluated
with the parameters the problem was built with, at `t = 0` unless `t` is given.
With `u` — a state vector laid out like `prob.u0`, such as `sol.u[k]` — it is
the observed at that state and time `t` (default `0`), which is how a
STATE-DEPENDENT observed is read; `t` is `sol.t[k]` for a saved solution point.
A read at a state or time binds the problem's own parameters `prob.p`, so on a
`remake(prob; p = …)` it answers with the substituted values.

Under `compiler = :native` the value comes from a program compiled once per
problem and name — the same array cascade as the right-hand side, run over the
state — so a read costs one pass over the field whatever `u` and `t` are. Under
`compiler = :interpreter` it is the build-time cellwise evaluator, the oracle the
compiled program agrees with bit for bit. The first read of a name files an
`:observed` row in [`compiler_report`](/generated/api/extension/julia#x-compiler_report) naming the route
(`:output_compiled`, or `:output_compiled_once` / `:output_percell` for the
cellwise evaluator); an observed native cannot compile is refused by name.

Two arguments (API_SPEC §5.8): the problem owns its own
[`BuildInspection`](/generated/api/extension/julia#x-buildinspection), so none is passed here. Pass your own via
`esm_problem(...; inspect = insp)` if you also want to read the sink directly.
`u` and `t` are keywords, not arguments: the result has the rank of the field
whatever they are, which API_SPEC §5.8 lets a binding that can overload spell
this way.

Resolution is the cross-binding rule of API_SPEC §5.8, in precedence order:

1. **Exact hit** — `name` is a flattened observed name (`"ISRM.deathsK"`).
2. **Bare name** — `name` carries no `.`, and the document has exactly ONE
   component; it then resolves to the unique observed with that tail
   (`"deathsK"`).

A bare name against a MULTI-component document is refused, with every qualified
candidate named, rather than bound to an arbitrary one.

Throws a `SimulateError` when `name` is not an evaluable observed (an unsized
axis, or not an observed at all), or when it reads the state and no `u` was
given.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/simulate.jl#L1811)

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
observed_field(prob: EsmProblem, name: str)
```

Evaluate/read the state-free observed `name` at BUILD time through the
EsmProblem's own graph — the const-geometry hoist already materialized it; this
resolves the name against those products. Raises [`SimulationError`](/generated/api/extension/python#x-simulationerror)
when `name` is not a build-time-evaluable observed of the EsmProblem.

Resolution is the cross-binding rule of API_SPEC §5.8, in precedence order:

1. **Exact hit** — `name` is a flattened field name (`Sites.North.u`).
2. **Bare name** — `name` carries no `.`, and the problem has exactly
   ONE component; it then resolves to the unique field with that tail.

A bare name against a MULTI-component problem is refused, with every
qualified candidate named, rather than bound to an arbitrary one.

Two arguments in every binding (API_SPEC §5.8): build observability moved to
a construction-time seam, so no caller has to thread a BuildInspection
through to read a field back.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/problem.py#L2643)

**Example** (`observed_field`)

```python
# What the build computed for an observed that does not depend on the state.
assert math.isclose(earthsci_ast.observed_field(prob, "half_life"), half_life)
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/docs/api/examples/python/simulate.py#L31-L32">docs/api/examples/python/simulate.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn observed_field(prob: &EsmProblem, name: &str) -> Result<ArrayD<f64>, SimulateError>
```

The build-time field named `name`, from `prob`'s construction.

Resolution is the cross-binding rule of API_SPEC §5.8
(`resolve_observed_key`), in precedence order:

1. **Exact hit** — `name` is a stored key.
2. **Component-qualified hit** — `name` is a stored key's `qualify`d
   spelling (`ISRM.E_PM25` for the pipeline's `E_PM25`).
3. **Bare name** — `name` carries no `.`, and the problem has exactly ONE
   component; it then resolves to the unique field with that tail.

A bare name against a MULTI-component problem is refused rather than bound
to an arbitrary candidate. Reads the build pipeline's fields, the state-free
static evaluation's fields, and — when `ProblemOptions::inspect` was set —
the array runtime's materialized setup arrays. One arity, `(prob, name)`,
in every binding.

Also answers for a DATA-FED parameter (esm-spec §5.4) the build pipeline
ingested, with the values its provider supplied, when the caller named it
in `ProblemOptions::retain_data_fields`; an observed of the same spelling
wins.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/problem.rs#L1246) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.observed_field.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Not available in Go. Go is outside the simulation capability profile (Julia, Python, Rust): build an RHS and integrate it; TypeScript and Go are deliberately non-simulating.</p>

</div>

</div>
