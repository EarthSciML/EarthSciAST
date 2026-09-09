# `classification_indexed_lhs` — the indexed LHS defines an observed, at every rank

esm-spec §6.3.1 admits **two** LHS spellings for the equation that DEFINES an
unknown, and restricts neither by rank:

> `observed_unknowns(model)` — unknowns **defined** by an equation whose LHS
> names them — a bare-variable LHS (`y ~ f(…)`) or an indexed-variable LHS
> (`y[i] ~ f(…)`, which defines the whole array `y`) — eliminable, materializable

and states the criterion semantically rather than syntactically:

> The defining form is read through the LHS's **base name** — the variable an
> `index` node indexes is the variable that LHS defines — so an arrayed
> definition is observed exactly as its scalar counterpart is.

This category exists because **four of the five bindings got that wrong
independently**, and no shared fixture could have caught any of them: the
`classification` category next door contains no `index` or `aggregate` LHS at
all, so the indexed spelling was unpinned everywhere.

- Julia — issue #232, PR #250 (the tree-walk build's owner buckets)
- Python — issue #232, PR #276 (`flatten._normalize_indexed_observed_lhs` + `classification._base_name`)
- Go and TypeScript — PR #268 (`definedVariableName` / `baseVariableName`)
- Rust — already correct; `lhs_form` peels both shells

## The fixture

One model, `M`, over `lev` (4 cells). Seven unknowns, chosen so that a binding
cannot pass by widening indiscriminately:

| Variable | LHS spelling | Must classify as |
|---|---|---|
| `wf` | `aggregate{k}(index(wf, k))`, **state-free** RHS | observed |
| `ws` | `aggregate{k}(index(ws, k))`, **state-dependent** RHS | observed |
| `wb` | `index(wb, i)` — §6.3.1's own worked-example spelling | observed |
| `sc` | bare `sc` — the rank-0 control | observed |
| `u`, `v` | `aggregate{k}(D(u[k]))` — the **same shell**, over a `D` | ODE state |
| `im` | `im*im ~ c0` — a genuine expression LHS | algebraic |

`u` and `v` are the point of the design. Their derivative LHSs wear exactly the
`aggregate` shell that `wf` and `ws` wear, so a reader that unwraps it
indiscriminately steals them out of `ode_states` and calls them observed. The
correct rule is narrow: unwrap an `aggregate` whose `expr` is an `index`, never
one whose `expr` is a `D`. Every binding's *derivative* reader already peeled
this shell; four of five *observed* readers did not, and that asymmetry is the
whole content of the category.

`wf` and `ws` are a controlled pair — state-free versus state-reading — because
those are the two classes bindings route differently downstream, so a partial fix
does not pass.

The golden is **authored** against the spec, not minted by a binding.

## Expected failures

None. All five bindings pass.

This category was authored while the Python half was still open, and kept python
in `bindings_required` rather than moving it to `scope_excluded` — defining the
contract down to what already passes is the weaker use of the mechanism (PR
#250's precedent). Python answered `observed_unknowns = ['sc', 'wb']` and
`algebraic_unknowns = ['im', 'wf', 'ws']` — missing both aggregate-indexed
observeds — until PR #276 (issue #232's Python half) landed
`classification._base_name`'s aggregate unwrap. Julia and Rust were already
correct; Go and TypeScript are corrected in PR #268.

## What this category deliberately does NOT pin

Two things were left out on purpose. Both are omissions, not oversights.

### 1. Which flatten bucket an arrayed observed lands in — **issue #270**

esm-libraries-spec §4.7.5 says an arrayed observed is in **both**
`state_variables` (it materializes into a buffer the solver allocates) and
`observed_variables` (an equation defines it). No binding does that, and they
miss in two opposite directions. Measured on this fixture: Python puts `wf` and
`ws` in `observed_variables` and drops them from `state_variables`, while Rust,
Go and TypeScript put them in `state_variables` and drop them from
`observed_variables`. Python is not even self-consistent — `wb`, whose LHS is the
bare `index(wb, i)` of §6.3.1's worked example, stays in `state_variables` there,
because only the `aggregate` spelling is normalized upstream.
Dual membership is not expressible in any of them today, because each assigns one
role per variable with a single `switch`.

That is a four-binding data-model decision with two defensible directions, so it
is out of scope here and filed as **#270**. Pinning it in this category would
force the decision by fixture rather than by triage.

### 2. The cadence of an indexed-LHS observed — **issue #272**

This is the consequence §6.3.1 names in as many words: `algebraic_unknowns` seeds
the CONTINUOUS cadence partition, whereas an observed's cadence resolves through
its defining RHS, "so misclassifying an arrayed definition as algebraic pushes
build-time work (const-backed geometry and regridding arrays) onto the
per-timestep hot path". `wf` in this fixture is state-free and must fold at bind
(`const`); while it was mis-credited as algebraic it seeded `continuous`.

It is not pinned here because the **cadence conformance oracle itself** —
`scripts/run-cadence-conformance.py` and Julia's mirror in
`pkg/EarthSciAST.jl/src/cadence.jl` — carries the same strict bare-LHS gate, and
seven existing fixtures under `tests/valid/cadence/` already have `index` /
`aggregate` LHSs whose goldens were minted against that behaviour. Correcting the
oracle means re-deriving those goldens, which is its own piece of work: **#272**.

The consequence is pinned **per-binding** in the meantime — Go's
`TestObservedUnknownsSeeThroughIndexedLHSSpellings` and TypeScript's
`'folds a state-free arrayed observed at bind'` both assert
`cadence(w) == const` — which is what made #272 visible in the first place.

## Contract for a binding runner

Read `manifest.json`, and for each fixture compare the three unknown sets, the
four parameter sets and `system_kind` against the golden, plus the partition
invariant. The golden's shape is identical to the `classification` category's, so
a binding can drive both with one reader.

See also `CONFORMANCE_SPEC.md` §5.34.
