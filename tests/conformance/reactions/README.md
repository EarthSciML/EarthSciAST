# Reaction conformance corpus

`species_order.json` pins **species ORDER** in the two Analysis-tier reaction
operations — `derive_odes` and `stoichiometric_matrix` — across all five
bindings. Canonical order is **declaration order**: the order the document
writes the `species` object's keys in. See `API_SPEC.md` §5.10.

Unlike `tests/conformance/graph/cases.json`, this corpus is **hand-written**.
There is no generator and no oracle binding — the expected values were derived
from the documents themselves and cross-checked against the bindings, not
captured from one of them.

## What it pins, and what it does not

| Pinned | Not pinned |
|---|---|
| the ROW order of `stoichiometric_matrix` | the return *shape* of `stoichiometric_matrix` (TypeScript returns `{matrix, species, reactions}`; the other four return a bare matrix — a separate divergence recorded in §5.10) |
| the EQUATION order of the model `derive_odes` returns | column order beyond "reactions in declaration order", which no binding disputes |
| that a reservoir species (`constant: true`) still occupies a matrix row but contributes no equation | the derived model's `variables` iteration order, which is a map in most bindings and unobservable |

## Why it exists

Five bindings diverged here for the length of the project and nothing failed.
Measured at the start of phase 6b:

| | `derive_odes` | `stoichiometric_matrix` |
|---|---|---|
| Julia | declaration | declaration |
| Python | declaration | declaration |
| TypeScript | declaration | declaration |
| Rust | declaration | **sorted by name** |
| Go | **sorted by name** | **sorted by name** |

Species order is observable — it *is* the matrix's row order and the derived
model's equation order — so it is a contract. Nothing in `tests/` asserted it,
which is exactly why the drift went unnoticed.

## Anti-vacuity

Every case declares its species in an order that is **not** their sorted order,
and each case carries both `species_declaration_order` and
`species_sorted_order` so a reader can see the two differ. `reverse_alphabetical`
declares them in exactly reverse sorted order, so a sorting binding returns the
rows and the equations fully reversed and cannot pass by partial coincidence.

**Do not drive `derive_odes` through `ode_states` / `ODEStates`.** That
operation sorts its result by design (esm-spec §6.3.1), so an assertion built on
it passes vacuously in every binding. Read the equation list directly and take
each LHS `D(<species>, t)` node's first argument.

## Drivers

| Binding | Test |
|---|---|
| Julia | `pkg/EarthSciAST.jl/test/reaction_species_order_test.jl` |
| TypeScript | `pkg/earthsci-ast-ts/src/reaction-species-order.test.ts` |
| Python | `pkg/earthsci-ast-py/tests/test_reaction_species_order.py` |
| Rust | `pkg/earthsci-ast-rs/tests/reaction_species_order.rs` |
| Go | `pkg/earthsci-ast-go/pkg/esm/reaction_species_order_test.go` |
