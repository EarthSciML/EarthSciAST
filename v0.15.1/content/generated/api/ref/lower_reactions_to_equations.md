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

The equations a set of reactions induces by mass-action kinetics,
`D(X) = Σ_j stoich_Xj · rate_j`, for `derive_odes` and `flatten` alike. The
tree is the canonical form esm-libraries-spec §4.6.2 pins byte for byte across
the bindings (`tests/conformance/reactions/lowering_form.json`): an n-ary `+`
over the species' terms in reaction order, each term the bare rate law or
`stoich * rate` with an integer literal for an integral coefficient. The
left-hand side is `D(X)` with `wrt` `"t"` whatever the domain.

No equation is emitted for a RESERVOIR (`constant: true`, §7.4), which is held
fixed but still read in every rate law it appears in, nor for a species whose
net stoichiometry is zero in every reaction (one in no reaction, or a
catalyst): esm-spec §6.3.1 classifies by complement, so leaving the equation
out makes it the algebraic unknown it is, where `D(X) = 0` would make it a
differential unknown that never moves.

A substrate or product the system does not declare is `undefined_species`
(esm-spec §7.2), a `ParseError`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/reactions.jl#L179)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/earthsci-ast-rs/src/reactions.rs#L35) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.lower_reactions_to_equations.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this function.</p>

</div>

</div>
