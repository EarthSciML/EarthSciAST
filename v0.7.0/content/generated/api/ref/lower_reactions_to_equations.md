---
title: "lower_reactions_to_equations"
description: "Stable function · Reactions"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Reactions](/generated/api/topics/reactions)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `lower_reactions_to_equations` | not exported | not exported | `lower_reactions_to_equations` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
lower_reactions_to_equations(reactions::Vector{Reaction}, species::Vector{Species})
```

```julia
lower_reactions_to_equations(reactions, species) -> Vector{Equation}
```

Produce the ODE equations induced by a set of reactions using standard
mass-action kinetics: `d[X]/dt = Σ (stoich_ij * rate_j)`.

Shared by `derive_odes` (reaction → Model) and `flatten` (EsmFile → FlattenedSystem)
so there is exactly one place that turns stoichiometry into equations.

The tree is the canonical form esm-libraries-spec §4.6.2 pins byte for byte
across the bindings (`tests/conformance/reactions/lowering_form.json`): an
n-ary `+` over the species' terms in reaction order, each term the bare rate
law or `stoich * rate` with an integer literal for an integral coefficient.

The LHS is always `D(X, t)` symbolically, regardless of the document's
domain — dimension promotion (§4.7.6) is applied by `flatten`, not here.
Spatial operators are added downstream when coupling adds them.

A species with `constant: true` is a RESERVOIR (§7.4): it is held fixed, so no
`D(X, t)` equation is emitted for it, while it still contributes its
concentration to every rate law it appears in. It is therefore skipped as an
equation TARGET only — it stays in `species` so `mass_action_rate` keeps
reading it as a substrate/product factor.

A species whose NET stoichiometry is zero in every reaction likewise gets no
equation — usually because it appears in no reaction at all, but a catalyst
(equal substrate and product stoichiometry everywhere it appears) meets the same
test. Its rate is the empty sum, and emitting `D(X, t) = 0` for it would make it
a differential unknown that never moves; esm-spec §6.3.1 classifies by
COMPLEMENT, so leaving the equation out is what makes it the ALGEBRAIC unknown it
is. See the comment at the skip below.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/flatten.jl#L430)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this function.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

<p class="api-absent">Python does not export this function.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn lower_reactions_to_equations(reactions: &[Reaction], species: &IndexMap<String, Species>) -> Result<Vec<Equation>, DeriveError>
```

Lower a reaction network to an ODE equation list.

Produces one `D(species, t) = Σ(net_stoichiometry · rate)` equation per species
per spec §4.7.5 step 1. Reusable from both [`derive_odes`](/generated/api/ref/derive_odes) and
[`crate::flatten::flatten`](/generated/api/ref/flatten) so the reaction-to-equation core lives in one place.

Each reaction's base rate is enhanced with mass-action concentration factors
per spec §7.4 (the `rate` field is the coefficient; the runner always
multiplies by the substrate product). Net stoichiometry combines substrate
and product contributions for each species.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/reactions.rs#L35) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.lower_reactions_to_equations.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this function.</p>

</div>

</div>
