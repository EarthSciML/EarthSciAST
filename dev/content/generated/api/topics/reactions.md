---
title: "Reactions"
description: "Deriving ordinary differential equations from a reaction system, and its stoichiometric matrices."
type: "api"
---


| Operation | Kind | Bindings | Summary |
|---|---|---|---|
| [`derive_odes`](/generated/api/ref/derive_odes) | function | Julia, TypeScript, Python, Rust, Go | Generate an ODE model from a reaction system using standard mass action kinetics. |
| [`lower_reactions_to_equations`](/generated/api/ref/lower_reactions_to_equations) | function | Julia, Rust | Produce the ODE equations induced by a set of reactions using standard mass-action kinetics: `d[X]/dt = Σ (stoich_ij * rate_j)`. |
| [`product_matrix`](/generated/api/ref/product_matrix) | function | TypeScript, Python | Compute product stoichiometric matrix from a reaction system |
| [`stoichiometric_matrix`](/generated/api/ref/stoichiometric_matrix) | function | Julia, TypeScript, Python, Rust, Go | Compute the net stoichiometric matrix (species × reactions). |
| [`substrate_matrix`](/generated/api/ref/substrate_matrix) | function | TypeScript, Python | Compute substrate stoichiometric matrix from a reaction system |

[All topics](/generated/api)
