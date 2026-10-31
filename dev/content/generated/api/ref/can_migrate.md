---
title: "can_migrate"
description: "Stable function · Versions and migration"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Versions and migration](/generated/api/topics/versions)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `can_migrate` | `canMigrate` | `can_migrate` | `can_migrate` | `CanMigrate` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
can_migrate(from_version::AbstractString, to_version::AbstractString)
```

```julia
can_migrate(from_version::AbstractString, to_version::AbstractString) -> Bool
```

Whether [`migrate`](/generated/api/ref/migrate) would succeed for this version pair — i.e. whether
`to_version` is among [`supported_migration_targets`](/generated/api/ref/supported_migration_targets)`(from_version)`.

Deliberately consults the same single source of truth `migrate` does, so a
caller is never told a pair is migratable and then handed a `MigrationError`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/migration.jl#L126)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function canMigrate(sourceVersion: string, targetVersion: string): boolean
```

Check if migration is possible from the source version to target version.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-ts/src/migration.ts#L87)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
can_migrate(from_version: str, to_version: str) -> bool
```

True when [`migrate`](/generated/api/ref/migrate) would succeed for this version pair.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/migration.py#L116)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn can_migrate(from_version: &str, to_version: &str) -> bool
```

Whether [`migrate`](/generated/api/ref/migrate) would succeed for this version pair — i.e. whether
`to_version` is among [`supported_migration_targets`](/generated/api/ref/supported_migration_targets)`(from_version)`.

Deliberately consults the same single source of truth `migrate` does, so a
caller is never told a pair is migratable and then handed a
[`MigrationError`](/generated/api/ref/migration_error).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/migration.rs#L146) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.can_migrate.html)

**Example** (`migrate`)

```rust
// decay.esm is written at format 1.0.0; the current format is a newer
// 1.x, reached by a version-marker bump with no structural change.
assert_eq!(doc.esm, "1.0.0");
assert_eq!(supported_migration_targets(&doc.esm), [SCHEMA_VERSION]);
assert!(can_migrate(&doc.esm, SCHEMA_VERSION));
let migrated = migrate(&doc, SCHEMA_VERSION)?;
assert_eq!(migrated.esm, SCHEMA_VERSION);

// A 0.x document is out of reach: 1.0.0 was a clean break.
assert!(!can_migrate("0.9.0", SCHEMA_VERSION));
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/rust/load.rs#L33-L42">docs/api/examples/rust/load.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func CanMigrate(sourceVersion, targetVersion string) bool
```

CanMigrate reports whether a migration from `sourceVersion` to `targetVersion` is supported.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/migration.go#L173) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CanMigrate)

</div>

</div>
