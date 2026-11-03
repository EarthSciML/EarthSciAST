# Run-time providers and the forcing they give (`provider_forcing`)

What a Problem built with run-time data providers (`providers`, the
construction option of `esm_problem`) reads for a data-fed parameter, and what
`rhs_program` takes from it as the default forcing set. API_SPEC.md §5.8,
"Forcing sets" ("Default"), is the surface; esm-libraries-spec.md §2.5.2 says
providers are sampled at construction.

There is one document, `fixtures/provider_forcing.esm`: a model `Fed` whose
right-hand side `D(u[i]) = s E[i, 2] - k u[i]` reads a gridded `E[x, y]` and a
scalar `s`, both fed by the data source `met` and both with scalar defaults.
Every value a provider delivers is a dyadic rational, so the right-hand side at
`u = 1` is exact and `du_default` can be written down.

## Who runs it

| Binding | Test file |
|---|---|
| Julia | `pkg/EarthSciAST.jl/test/conformance_provider_forcing_test.jl` |
| Rust | `pkg/earthsci-ast-rs/tests/provider_forcing_conformance.rs` |

Python's `rhs_program` raises `compiler_unavailable`; TypeScript and Go have no
simulator.

## Providers

Each entry of a case's `providers` is passed under its `key`. It delivers one
field, keyed by `key`, whose value at time `t` is `base + slope * t`
elementwise. `base` is nested row-major (outer list = first index) over
`shape`; a 0-d field is one number. An empty `refresh_times` makes it a const
provider, and otherwise it is discrete with those refresh times.

- Julia: `provider_sample(p, t)` returns `Dict(key => field)` (a 0-d field as a
  one-element vector) and `provider_refresh_times(p)` the times.
- Rust: a `CadenceProvider` whose `materialize()` returns the field (const
  providers only, `slope = 0`), whose `refresh(t)` returns `Some` of the field
  at `t`, and whose `refresh_times()` returns the times.

Every Problem is built with `compiler = native` and the manifest's `tspan`, and
with `sample_time` when a case gives one.

## Checks every case runs

1. `forcing_slots(prog)` equals `forcing_slots` (name, shape and kind, in
   order).
2. Each buffer of `default_forcing_set(prog)` / `prog.default_forcing()` equals
   `default_forcing[slot]`, column-major, bitwise.
3. The program's right-hand side at the default state (`u = 1`), the default
   parameter vector, `t = tspan[0]` and the default forcing set equals
   `du_default` bitwise.
4. The Problem's own right-hand side (Julia `prob.f!`; Rust
   `debug_eval_rhs_into` on the Problem's compiled model with a taped scratch)
   at its initial state, its parameters and `t = tspan[0]` equals `du_default`
   bitwise.

## Cases

| Case | What it pins |
|---|---|
| `no_providers` | the control: each declared default is the value |
| `const_qualified_keys` | const providers keyed by the qualified names `Fed.E`, `Fed.s` on a document with one model |
