# An `ic` right-hand side is evaluated at the start of the run (`ic_at_start`)

esm-spec §11.4.2, CONFORMANCE_SPEC §5.56. An `ic` right-hand side is evaluated
once, at `t0 = tspan[0]`. It may read the independent variable `t` (bound to
`t0`), every parameter (scalar or shaped), every data-fed parameter at the value
its provider gives at `t0`, and every observed over those, scalar or
array-valued. It may not read a state: construction refuses that with
`ic_reads_state`.

## Fixtures

| Fixture | What it pins |
|---|---|
| `ic_reads_t.esm` | a 0-D `ic(a) = k*t + 1`, and an array `ic(u) = rate` with the array observed `rate[i] = i + h*t` |
| `ic_reads_t_scalar.esm` | the same on a document with no array state (each binding's scalar runtime), with a 0-D observed `g = 3*k*t` |
| `ic_data_fed.esm` | `ic(m) = dp`, `dp[i,k] = dA[k] + dB[k]*P[i]`, `P[i] = (1 - w)*F[1,i] + w*F[2,i]`, `w = t/dt - floor(t/dt)`: shaped parameters with inline defaults, a two-record data-fed parameter `F`, and a weight computed from `t`; and a 0-D `ic(s) = q*t` with `q` data-fed |
| `ic_reads_state.esm` | refusal: `ic(v) = g` with `g[i] = 2*u[i]` and `u` a state |
| `ic_reads_state_scalar.esm` | refusal: `ic(b) = a + r*t` with `a` a state |

## Cases

`manifest.json` lists each case's fixture, `tspan`, `p`, providers (the
`provider_forcing` format: a field `base + slope * t`, discrete when
`refresh_times` is non-empty) and optional `sample_time`, and either the
initial state expected for every state element (by flattened name) or the
`error_code` construction must raise. Every provider value is a dyadic rational,
so the expected values are exact.

## Who runs it

| Binding | Test file |
|---|---|
| Julia | `pkg/EarthSciAST.jl/test/conformance_ic_at_start_test.jl` |
| Python | `pkg/earthsci-ast-py/tests/test_ic_at_start_conformance.py` |
| Rust | `pkg/earthsci-ast-rs/tests/ic_at_start_conformance.rs` |

TypeScript and Go have no simulator.
