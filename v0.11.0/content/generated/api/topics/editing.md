---
title: "Editing"
description: "Adding, removing and renaming the parts of a document, and composing, merging and extracting components."
type: "api"
---


| Operation | Kind | Bindings | Summary |
|---|---|---|---|
| [`add_continuous_event`](/generated/api/ref/add_continuous_event) | function | Julia, TypeScript, Python, Go | Add a continuous event to a model. |
| [`add_coupling`](/generated/api/ref/add_coupling) | function | Julia, TypeScript, Python, Rust, Go | Add a coupling entry to an ESM file. |
| [`add_discrete_event`](/generated/api/ref/add_discrete_event) | function | Julia, TypeScript, Python, Go | Add a discrete event to a model. |
| [`add_equation`](/generated/api/ref/add_equation) | function | Julia, TypeScript, Python, Rust, Go | Add a new equation to a model. |
| [`add_reaction`](/generated/api/ref/add_reaction) | function | Julia, TypeScript, Python, Rust, Go | Add a new reaction to a reaction system. |
| [`add_species`](/generated/api/ref/add_species) | function | Julia, TypeScript, Python, Rust, Go | Add a new species to a reaction system. |
| [`add_variable`](/generated/api/ref/add_variable) | function | Julia, TypeScript, Python, Rust, Go | Add a new variable to a model. |
| [`component_exists`](/generated/api/ref/component_exists) | function | TypeScript, Python, Rust | Utility to check if a component exists in the ESM file |
| [`compose`](/generated/api/ref/compose) | function | Julia, TypeScript, Rust, Go | Convenience function to create an operator_compose coupling entry linking two systems. |
| [`extract`](/generated/api/ref/extract) | function | Julia, TypeScript, Python, Go | Extract a single component into a standalone ESM file. |
| [`get_component_type`](/generated/api/ref/get_component_type) | function | TypeScript, Rust | Get the type of a component by its ID |
| [`map_variable`](/generated/api/ref/map_variable) | function | Julia, TypeScript, Go | Convenience function to create a variable_map coupling entry that forwards a variable reference `from` into `to`. |
| [`merge`](/generated/api/ref/merge) | function | TypeScript, Python, Go | Merge two ESM files |
| [`remove_coupling`](/generated/api/ref/remove_coupling) | function | Julia, TypeScript, Python, Rust, Go | Remove a coupling entry by index (1-based). |
| [`remove_equation`](/generated/api/ref/remove_equation) | function | Julia, TypeScript, Python, Rust | Remove an equation from a model. |
| [`remove_event`](/generated/api/ref/remove_event) | function | Julia, TypeScript, Python, Go | Remove events whose `description` field equals `description` from a model. |
| [`remove_reaction`](/generated/api/ref/remove_reaction) | function | Julia, TypeScript, Python, Rust, Go | Remove a reaction by its ID. |
| [`remove_species`](/generated/api/ref/remove_species) | function | Julia, TypeScript, Python, Rust, Go | Remove a species from a reaction system. |
| [`remove_variable`](/generated/api/ref/remove_variable) | function | Julia, TypeScript, Python, Rust, Go | Remove a variable from a model. |
| [`rename_variable`](/generated/api/ref/rename_variable) | function | Julia, TypeScript, Python, Go | Rename a variable throughout the model. |
| [`edit_error`](/generated/api/ref/edit_error) | error | Julia, Rust, Go | Exception thrown when an editing operation cannot be applied — e.g. removing a variable, equation, reaction, event, or coupling entry that does not exist, or extracting a missing… |
| [`entity_not_found_error`](/generated/api/ref/entity_not_found_error) | error | TypeScript, Go | Error thrown when attempting an operation on a non-existent entity |
| [`variable_in_use_error`](/generated/api/ref/variable_in_use_error) | error | TypeScript, Go | Error thrown when attempting to remove a variable that is still referenced |

[All topics](/generated/api)
