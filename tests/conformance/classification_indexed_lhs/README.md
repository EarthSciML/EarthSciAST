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

## The flatten buckets — **issue #270**

The golden carries a second, optional section, `flatten_buckets`, authored
against esm-libraries-spec §4.7.5 step 4 rather than minted by a binding. Which
§6.3.1 set classifies an unknown and which flattened MAP it lands in are
different questions, and step 4's two rows are **not** a partition:

> | `state_variables` | … Differential unknowns …, PLUS `algebraic_variables`, PLUS **any arrayed observed that materializes into a buffer**. |
> | `observed_variables` | Unknowns DEFINED by an equation, **bare-LHS or indexed-LHS** (esm-spec §6.3.1). A scalar observed is eliminated by substitution and is NOT in `state_variables`; **an arrayed observed materializes into a buffer and IS**. |

So on this fixture:

```
state_variables     [M.u, M.v, M.wf, M.ws, M.wb, M.im]
observed_variables  [M.wf, M.ws, M.wb, M.sc]
algebraic_variables [M.im]
```

`wf`, `ws` and `wb` are in **both** maps. `sc` is the control in the other
direction — a SCALAR observed, "eliminated by substitution and … NOT in
`state_variables`". `im` is in `state_variables` and `algebraic_variables` at
once, which is the same dual membership §4.7.5 already requires of an algebraic
unknown ("A **subset** of `state_variables` — a DAE solves for them"), so this is
an existing pattern rather than a new one. Lists are in DOCUMENT order, which
step 4 makes normative — the one golden here that is not sorted.

Which observeds count as materializing is read through §6.3.1's own distinction
between the classification and the narrower set it sanctions for INLINING: a
bare-variable LHS is eliminated by substitution and occupies no buffer, an
indexed LHS is by construction arrayed and its consumers index the buffer. The
materialized set is `observed_unknowns \ inlined_unknowns`, which is the set
every binding's own comments already called "materializes into a buffer".

Before #270 was fixed, no binding did this and they missed in two opposite
directions: Python put `wf` and `ws` in `observed_variables` and dropped them
from `state_variables`, while Rust, Go and TypeScript put them in
`state_variables` and dropped them from `observed_variables`. Python was not even
self-consistent — `wb`, whose LHS is the bare `index(wb, i)` of §6.3.1's worked
example, stayed in `state_variables` alone, because its bucket was read off the
strict INLINING set rather than off the classification.

## What this category deliberately does NOT pin

### The cadence of an indexed-LHS observed — **issue #272**

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
invariant. The golden's `models` shape is identical to the `classification`
category's, so a binding can drive both with one reader; `flatten_buckets` is
OPTIONAL and a reader compares it only where a golden carries it.

See also `CONFORMANCE_SPEC.md` §5.34.
