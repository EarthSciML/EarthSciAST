---
title: "Versions and migration"
description: "The format and library version constants, and migrating a document written for an older version of the format."
type: "api"
---


| Operation | Kind | Bindings | Summary |
|---|---|---|---|
| [`can_migrate`](/generated/api/ref/can_migrate) | function | Julia, TypeScript, Python, Rust, Go | Whether `migrate` would succeed for this version pair — i.e. whether `to_version` is among `supported_migration_targets``(from_version)`. |
| [`migrate`](/generated/api/ref/migrate) | function | Julia, TypeScript, Python, Rust, Go | Migrate `file` from the version it declares to `target_version`. |
| [`reject_expression_templates_pre_v04`](/generated/api/ref/reject_expression_templates_pre_v04) | function | Julia, TypeScript, Python, Go | Reject `expression_templates` blocks and `apply_expression_template` ops in files declaring `esm` &lt; 0.4.0. |
| [`reject_solver_pre_v11`](/generated/api/ref/reject_solver_pre_v11) | function | Julia, TypeScript, Python, Rust, Go | Reject a top-level `solver` block in a file declaring `esm` &lt; 1.1.0. |
| [`reject_template_imports_pre_v08`](/generated/api/ref/reject_template_imports_pre_v08) | function | Julia, TypeScript, Python, Rust, Go | `expression_template_imports`, top-level `expression_templates` (template-library files), and `metaparameters` arrive at `esm: 0.8.0`; files declaring an earlier version that… |
| [`supported_migration_targets`](/generated/api/ref/supported_migration_targets) | function | Julia, TypeScript, Python, Rust, Go | The schema versions `source_version` can be migrated to. |
| [`migration_error`](/generated/api/ref/migration_error) | error | Julia, TypeScript, Python, Rust, Go | Thrown when `migrate` is asked for a version pair it does not support — including every pair that crosses the 1.0.0 clean break. |
| [`library_version`](/generated/api/ref/library_version) | constant | Julia, TypeScript, Python, Rust, Go | This package's OWN version, read from its `Project.toml` — NOT the `.esm` format version, which is `SCHEMA_VERSION`. |
| [`schema_version`](/generated/api/ref/schema_version) | constant | Julia, TypeScript, Python, Rust, Go | The `.esm` FORMAT version (semver string) this implementation targets — the value written into the `esm` field of freshly constructed files. |

[All topics](/generated/api)
