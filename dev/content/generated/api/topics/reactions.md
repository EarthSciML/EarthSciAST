---
title: "Reactions"
description: "Deriving ordinary differential equations from a reaction system, and its stoichiometric matrices."
type: "api"
---


| Operation | Kind | Bindings | Summary |
|---|---|---|---|
| [`derive_odes`](/generated/api/ref/derive_odes) | function | Julia, TypeScript, Python, Rust, Go | The reaction system as a model (esm-spec §7.4): its variables (`reaction_variables`), each species without a `default`, `description` or `units` given… |
| [`lower_reactions_to_equations`](/generated/api/ref/lower_reactions_to_equations) | function | Julia, Rust | The equations a set of reactions induces by mass-action kinetics, `D(X) = Σ_j stoich_Xj · rate_j`, for `derive_odes` and `flatten` alike. |
| [`product_matrix`](/generated/api/ref/product_matrix) | function | TypeScript, Python | Compute product stoichiometric matrix from a reaction system |
| [`stoichiometric_matrix`](/generated/api/ref/stoichiometric_matrix) | function | Julia, TypeScript, Python, Rust, Go | The net stoichiometric matrix, species × reactions: `S[i, j]` is species `i`'s product coefficients minus its substrate coefficients in reaction `j`, positive for production. |
| [`substrate_matrix`](/generated/api/ref/substrate_matrix) | function | TypeScript, Python | Compute substrate stoichiometric matrix from a reaction system |

[All topics](/generated/api)
