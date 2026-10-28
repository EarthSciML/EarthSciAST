# Reaction conformance corpus

Two hand-written corpora, each driven by a test in all five bindings:

- `species_order.json` — the species ORDER of `derive_odes` and
  `stoichiometric_matrix` (below);
- `lowering_form.json` — the exact expression TREE a reaction system lowers to,
  in `derive_odes` and in `flatten` (see the end of this file).

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

---

# `lowering_form.json`: the lowered tree

Pins the exact expression tree of esm-libraries-spec §4.6.2 — the rate law
`k · ∏ Sᵢ^nᵢ` as one n-ary `*` with `k` first, each species' term as the bare
rate law for a net coefficient of 1 and `coefficient * rate` otherwise, one
n-ary `+` per species, integer literals for integral coefficients and
exponents, and nothing simplified. Derived documents copy flattened terms
verbatim, so a binding that lowers the same reaction to a different tree writes
different bytes.

Like `species_order.json` it is **hand-written**: the expected trees follow from
the §4.6.2 rules applied to each document, and were cross-checked against all
five bindings. The corpus' `how_to_drive` field is the driver contract.

| Case | What it covers |
|---|---|
| `photostationary_loss_and_production` | unit stoichiometry: loss `-1 * rate`, production the bare rate law; a parameter rate and an expression rate; several reactions per species |
| `stoichiometry_and_rate_forms` | non-unit stoichiometry (`A ^ 2`, coefficient `-2`), a species on both sides (net `+1`), a catalyst (net 0, no term), fractional coefficients and exponents, source and sink reactions, a reservoir factor, an inert species (no equation), integer, float and literal-`1` rates |
| `repeated_species_entries` | a species listed twice on one side (`A + A` gives `k1 * A * A` and coefficient `-2`; `B + B` as products gives `+2`), and a substrate listed twice against a product whose `P - S` is a tiny nonzero float, kept as a term |
| `lifted_pointwise` | the network lifted pointwise onto a grid by `operator_compose`; only the reaction system's contribution is compared, because the lift's `faq` range spelling is not pinned here |

Numbers compare by value AND kind: an integer literal in the corpus must be an
integer literal in the binding (CONFORMANCE_SPEC §5.5.3.1 rule 3). TypeScript
numbers have no kind, so its driver compares by value only.

| Binding | Test |
|---|---|
| Julia | `pkg/EarthSciAST.jl/test/reaction_lowering_form_test.jl` |
| TypeScript | `pkg/earthsci-ast-ts/src/reaction-lowering-form.test.ts` |
| Python | `pkg/earthsci-ast-py/tests/test_reaction_lowering_form.py` |
| Rust | `pkg/earthsci-ast-rs/tests/reaction_lowering_form.rs` |
| Go | `pkg/earthsci-ast-go/pkg/esm/reaction_lowering_form_test.go` |
