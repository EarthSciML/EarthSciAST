---
title: "Variable classification"
description: "Which variables of a model are integrated states, algebraic unknowns, observed quantities or parameters of each kind (esm-spec section 6.3.1)."
type: "api"
---


These operations belong to the **classification** capability profile: Julia, TypeScript, Python, Rust, Go.

| Operation | Kind | Bindings | Summary |
|---|---|---|---|
| [`algebraic_unknowns`](/generated/api/ref/algebraic_unknowns) | function | Julia, TypeScript, Python, Rust, Go | The unknowns constrained only implicitly (`H*H*SO4 ~ Ksp`) — those an equation never names as a derivative target or a bare-variable LHS (esm-spec §6.3.1). |
| [`apply_dae_contract`](/generated/api/ref/apply_dae_contract) | function | Rust, Go | Run the RFC §12 DAE binding contract on `esm` **in place** and return the classification summary. |
| [`brownian_parameters`](/generated/api/ref/brownian_parameters) | function | Julia, TypeScript, Python, Rust, Go | Parameters whose `update.kind` is `"wiener"` — the SDE noise sources (esm-spec §6.3.1). |
| [`constant_parameters`](/generated/api/ref/constant_parameters) | function | Julia, TypeScript, Python, Rust, Go | Parameters with neither a `distribution` nor an `update` — plain constants. |
| [`declared_system_kind`](/generated/api/ref/declared_system_kind) | function | Julia, TypeScript, Python, Go | The `system_kind` the model DECLARES, verbatim, or `nothing` when the field is absent. |
| [`discrete_parameters`](/generated/api/ref/discrete_parameters) | function | Julia, TypeScript, Python, Rust, Go | Parameters carrying any update OTHER than `wiener` — piecewise-constant between refreshes (esm-spec §6.3.1). |
| [`effective_system_kind`](/generated/api/ref/effective_system_kind) | function | Julia, TypeScript, Python, Go | `declared_system_kind` when the model declares one, otherwise the derived `system_kind`. |
| [`free_parameters`](/generated/api/ref/free_parameters) | function | TypeScript, Python, Rust | Extract free parameters from an expression within a model context |
| [`is_ode_state`](/generated/api/ref/is_ode_state) | function | Julia, TypeScript, Python, Rust, Go | Membership test for `ode_states`. |
| [`observed_definition`](/generated/api/ref/observed_definition) | function | Julia, Go | The defining right-hand side of the observed unknown `name`, or `nothing` when it is not an observed unknown of `model`. |
| [`observed_definitions`](/generated/api/ref/observed_definitions) | function | Julia, TypeScript, Python, Rust | Each observed unknown mapped to its DEFINING EQUATION's right-hand side. |
| [`observed_unknowns`](/generated/api/ref/observed_unknowns) | function | Julia, TypeScript, Python, Rust, Go | The unknowns defined by a bare-variable LHS (`y ~ f(…)`) — eliminable and materializable (esm-spec §6.3.1). |
| [`ode_states`](/generated/api/ref/ode_states) | function | Julia, TypeScript, Python, Rust, Go | The unknowns appearing under `D(·, t)` on some equation LHS — the quantities the solver integrates (esm-spec §6.3.1). |
| [`parameters`](/generated/api/ref/parameters) | function | Julia, TypeScript | Deprecated alias of `parameters` (API_SPEC.md §8 item 6). |
| [`sampled_parameters`](/generated/api/ref/sampled_parameters) | function | Julia, TypeScript, Python, Rust, Go | Parameters with a `distribution` and no `update` — drawn ONCE at setup (uncertainty quantification, ensembles). |
| [`system_kind`](/generated/api/ref/system_kind-function) | function | Julia, TypeScript, Python, Rust, Go | Derive what the `system_kind` field declares (esm-spec §6.3.1). |
| [`unknowns`](/generated/api/ref/unknowns) | function | Julia, TypeScript, Python | Deprecated alias of `unknowns` (API_SPEC.md §8 item 6). |
| [`dae_info`](/generated/api/ref/dae_info) | type | Rust, Go | Summary of DAE classification stamped onto `metadata.dae_info` by `discretize()` per RFC §12. |
| [`system_kind`](/generated/api/ref/system_kind-type) | type | TypeScript, Rust | The MTK system type a model maps to. |
| [`variable_kind`](/generated/api/ref/variable_kind) | type | TypeScript, Rust | The kind of a variable node. |

[All topics](/generated/api)
