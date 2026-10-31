---
title: "The unified variable model: two declared types, everything else derived"
description: "Collapse the five declared variable types (state, parameter, observed, brownian, discrete), the separate data-loader component kind, and the discrete_parameters event list into exactly two declared types — unknown and parameter. An unknown's behavior is given by equations; a parameter carries a value or distribution and an optional update block. ODE-state-ness, observed-ness, noise, and refresh cadence all become derived classifications that every binding computes with the same functions."
---

Status: accepted
Target format version: 1.0.0 (breaking; no deprecation path, no compatibility shims)

## Summary

Before 1.0.0 the format carried five declared variable types (`state`,
`parameter`, `observed`, `brownian`, `discrete`), a separate top-level
`data_loaders` component kind, and a `discrete_parameters` list that let events
mutate parameters. Five constructs described what is really two things: a
quantity the solver solves for, and a quantity supplied to it.

1.0.0 collapses them to exactly two declared types:

| Type | Meaning |
|---|---|
| `unknown` | The solver solves for it. Its behavior is given by **equations**, never by a field on the variable. |
| `parameter` | Supplied to the solver. Its value is a number or a `distribution`, and it MAY carry an `update` block saying when and from what it refreshes. |

Everything else is **derived** from the equations and the update blocks, and
every binding exposes the same classification functions to derive it.

## What each removed construct becomes

| Removed | Replacement |
|---|---|
| `type: "state"` | `type: "unknown"` that appears under `D(·, t)` on some equation LHS |
| `type: "observed"` + `expression` | `type: "unknown"` + a bare-variable-LHS equation `{"lhs": "v", "rhs": …}` |
| `type: "brownian"` (+ `noise_kind`, `correlation_group`) | `type: "parameter"` + `distribution` + `update: {"kind": "wiener", …}` |
| `type: "discrete"` (+ `refresh`) | `type: "parameter"` + `update: {"kind": "schedule" \| "data_ingest" \| "remesh", …}` |
| top-level `data_loaders` component | top-level `data_sources` registry + `update: {"kind": "data", "from": {…}}` |
| `discrete_parameters` on events | `update: {"kind": "condition", …}` on the parameter itself |

## Decisions

These were settled with the format owner before implementation; they are
recorded here because several of them close off otherwise-reasonable designs.

### D1. Classification covers everything the solver needs

Not just ODE states. Every binding exposes the same set, all derived, none
declared. See "Classification API" below.

### D2. `data_sources` is a registry, not a component

The shared parts of an ingest — `source`, `temporal`, `select`,
`record_filter`, `extent`, `reader_options`, `codes`, `determinism` — stay in
one document-scoped `data_sources` entry, because several of their guarantees
are inherently loader-wide and cannot be expressed per-variable:

- `record_filter` computes the surviving-record mask **once** per source and
  applies it to every parameter drawing from that source. This is what makes it
  impossible for two columns of one points table to fall out of alignment.
- `extent` binds **one** metaparameter from that single shared record count.

But `data_sources` entries are no longer components. Dropped with them:

- data loaders as coupling endpoints,
- data loaders as `subsystems` entries,
- loader-only `.esm` files referenced by `ref`,
- `"Loader.var"` scoped-name resolution (a source has no variables to resolve).

A model that needs external data declares a parameter with `update.from`.

### D3. Distributions are a closed set, with explicit correlation

`normal`, `lognormal`, `uniform`. Multivariate correlation is **schema-encoded**
via a `cov` matrix rather than left to opaque `correlation_group` tags — this
closes the gap the pre-1.0.0 schema explicitly deferred ("the spec does not
currently encode the correlation matrix itself; that is left to a future
extension").

A `distribution` with no `update` is sampled **once at setup** (the UQ /
ensemble case). A `distribution` with `update: {"kind": "wiener"}` is a driving
stochastic process, resampled per step with √dt increment scaling (the SDE
case). The cadence is what distinguishes them.

### D4. Events affect unknowns; parameters carry their own updates

`discrete_events` and `continuous_events` keep their triggers and affect
equations, but may only affect **unknowns** — state resets such as the bouncing
ball's `v ~ -0.8*v`. Any mutation of a parameter moves onto that parameter as
`update: {"kind": "condition", …}`. `discrete_parameters` is removed entirely.
Coupling-level events (§5.6) narrow to unknowns the same way.

### D4a. A parameter may carry several update rules

Discovered while converting the corpus, and a correction to D4 as first drafted.
D4 moved parameter mutation onto the parameter, but a parameter could then carry
only ONE update — while before 1.0.0 any number of events could write one
parameter. That is not a rare shape: 50 parameters in the shared corpus were
written by two or more events, including a seasonal modifier set by four
transitions and counters incremented on several schedules.

Resolving those by splitting one parameter into several would have changed the
models rather than re-expressing them, because the equations read one name. So
`update` accepts an ordered array of two or more rules, applied in declaration
order. A single rule must still be written as the object form (a one-element
array is invalid) so each update set has exactly one spelling; `wiener` is
object-form only, since a driving noise process is the parameter's whole value.

The same conversion showed `ReactionSystem.parameters` had no `shape` field,
which made the discrete-cadence contract unsatisfiable there and left D6's "one
parameter concept across the format" only half true. `Parameter` now carries
`shape` and the same conditional as `ModelVariable`.

### D5. `_var` ranges over ODE states

The operator-composition placeholder expands over `ode_states(model)` as
computed by the classification function — exactly the set that was
`type: "state"` before. Zero behavior change: an advection operator still
applies only to transported quantities, never to derived diagnostics.

### D6. ReactionSystem: parameters aligned, species untouched

`ReactionSystem.parameters` gains the same `distribution` / `update` capability
as model parameters, so there is one parameter concept across the format.
`species` stay a distinct construct — they carry stoichiometric meaning in
`reactions` that `unknown` does not capture, and reaction species are always
ODE states anyway.

### D7. Internal vocabulary is not renamed

The bindings keep saying "observed" for the derived category of unknowns
defined by a bare-variable LHS. It is the ModelingToolkit term, its runtime
meaning is unchanged, and renaming ~2958 internal occurrences across ~250 files
would add enormous mechanical churn for no semantic gain. What changes is that
nothing *reads a declared type* any more — every such site calls a
classification function instead.

### D8. Version bump is schema/spec only

The `.esm` format version goes to 1.0.0. The six binding package versions are a
separate release decision and are left alone.

## Classification API

Every binding exposes these, spelled in its own idiom (`ode_states` in
Julia/Python/Rust/Go, `odeStates` in TypeScript). All are pure functions of a
model; none read a declared type that no longer exists.

### Unknowns

| Function | Returns |
|---|---|
| `ode_states(model)` | unknowns appearing under `D(·, t)` on some equation LHS |
| `observed_unknowns(model)` | unknowns defined by a bare-variable LHS (`y ~ f(…)`) — eliminable / materializable |
| `algebraic_unknowns(model)` | unknowns constrained only implicitly (`H*H*SO4 ~ Ksp`) |
| `is_ode_state(model, name)` | membership test for the above |

The three sets partition the unknowns.

### Parameters

| Function | Returns |
|---|---|
| `brownian_parameters(model)` | parameters whose `update.kind` is `wiener` — the SDE noise sources |
| `discrete_parameters(model)` | parameters with a non-`wiener` `update` block — piecewise-constant between refreshes |
| `sampled_parameters(model)` | parameters with a `distribution` and no `update` — drawn once at setup |
| `constant_parameters(model)` | parameters with neither — plain constants |

The four sets partition the parameters.

### Derived system kind

`system_kind(model)` derives what the `system_kind` field used to declare:

- any `brownian_parameters` ⇒ `"sde"`
- no time-derivative equation at all ⇒ `"nonlinear"`
- a spatial domain + differential operators ⇒ `"pde"`
- otherwise ⇒ `"ode"`

The explicit `system_kind` field remains authoritative when present; the
derivation is what a binding uses when it is absent, and what a validator
cross-checks against when it is.

## Equation balance (§4.9.4) under the unified model

The check was already **unknowns vs equations**, credited by LHS form
(derivative, bare-variable, or implicit-constraint). That rule is unchanged and
now applies uniformly: former observed variables contribute both an unknown and
an equation, so a document that balanced before still balances after conversion.
