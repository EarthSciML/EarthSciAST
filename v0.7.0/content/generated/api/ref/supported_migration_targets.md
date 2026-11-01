---
title: "supported_migration_targets"
description: "Stable function · Versions and migration"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Versions and migration](/generated/api/topics/versions)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `supported_migration_targets` | `getSupportedMigrationTargets`, `supportedMigrationTargets` | `supported_migration_targets` | `get_supported_migration_targets`, `supported_migration_targets` | `SupportedMigrationTargets` |


**Note:** spelling differs from the §2 rule: rust=get_supported_migration_targets (expected supported_migration_targets); typescript=getSupportedMigrationTargets (expected supportedMigrationTargets); multiple spellings exported by: rust, typescript


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
supported_migration_targets(source_version::AbstractString)
```

```julia
supported_migration_targets(source_version::AbstractString) -> Vector{String}
```

The schema versions `source_version` can be migrated to.

- A version on the additive line `1.0.0 … <current schema version>` →
  `[SCHEMA_VERSION]` (a no-op marker bump to the current schema).
- Everything else — including EVERY 0.x version, which 1.0.0's clean break puts
  out of reach of a marker bump, plus newer-than-current, other majors, and
  malformed strings — → `String[]`.

Named without the `get` prefix its TypeScript twin (`getSupportedMigrationTargets`)
carries; the behaviour is identical.

**Examples**
```julia
supported_migration_targets("1.0.0")   # ["1.0.0"]
supported_migration_targets("0.9.0")   # String[]  — the clean break
supported_migration_targets("2.0.0")   # String[]
supported_migration_targets("1.0")     # String[]  — malformed
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/migration.jl#L96)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

Exported as `getSupportedMigrationTargets` and `supportedMigrationTargets`. Both names refer to the same operation.

**`getSupportedMigrationTargets`**

```typescript
function getSupportedMigrationTargets(sourceVersion: string): string[]
```

**Deprecated.** Use `supportedMigrationTargets`.

---

**Deprecated.** Use [`supportedMigrationTargets`](/generated/api/ref/supported_migration_targets). The canonical name is
`supported_migration_targets`, with no `get` prefix. Kept for one minor per
API_SPEC.md §10; removed at the next major.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-ts/src/migration.ts#L114)

**`supportedMigrationTargets`**

```typescript
function supportedMigrationTargets(sourceVersion: string): string[]
```

Get the list of schema versions that a given source version can migrate to.

- any version on the additive line `1.0.0 … <current schema version>` →
  `[SCHEMA_VERSION]` (a no-op marker bump to the current schema).
- everything else — including EVERY 0.x version, which 1.0.0's clean break
  puts out of reach of a marker bump — → `[]`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-ts/src/migration.ts#L100)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
supported_migration_targets(from_version: str) -> list[str]
```

The schema versions `from_version` can migrate to.

* a version on the additive line `1.0.0 … <current schema version>` →
  `[SCHEMA_VERSION]` (a no-op marker bump to the current schema);
* everything else — including EVERY 0.x version, which 1.0.0's clean break
  puts out of reach of a marker bump — → `[]`.

The canonical name of TypeScript's `getSupportedMigrationTargets`: the
harmonized API drops the `get` prefix.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/migration.py#L99)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

Exported as `get_supported_migration_targets` and `supported_migration_targets`. Both names refer to the same operation.

**`get_supported_migration_targets`**

```rust
pub fn get_supported_migration_targets(from_version: &str) -> Vec<String>
```

**Deprecated** since 0.2.0: renamed to `supported_migration_targets` (API_SPEC.md phase-6 G-2)

Deprecated alias of [`supported_migration_targets`](/generated/api/ref/supported_migration_targets).

Every binding spells this `supported_migration_targets` (API_SPEC.md §8).
This alias is deprecated and will be removed at the next major
(API_SPEC.md §10).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/migration.rs#L136) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.get_supported_migration_targets.html)

**`supported_migration_targets`**

```rust
pub fn supported_migration_targets(from_version: &str) -> Vec<String>
```

The schema versions `from_version` can be migrated to.

- any version on the additive line `1.0.0 … <current schema version>` →
  `[SCHEMA_VERSION]` (a no-op marker bump to the current schema);
- everything else — including EVERY 0.x version, which 1.0.0's clean break
  puts out of reach of a marker bump, plus newer-than-current, other majors
  and malformed strings — → an empty vector.

This is the single source of truth for the whole module: [`can_migrate`](/generated/api/ref/can_migrate) is
membership in this list and [`migrate`](/generated/api/ref/migrate) refuses whatever it omits.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/migration.rs#L120) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.supported_migration_targets.html)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/docs/api/examples/rust/load.rs#L33-L42">docs/api/examples/rust/load.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func SupportedMigrationTargets(sourceVersion string) []string
```

SupportedMigrationTargets returns the schema versions `sourceVersion` can be migrated to.

- any version on the additive line `1.0.0 … <current schema version>` → [`SchemaVersion`](/generated/api/ref/schema_version) (a no-op marker bump to the current schema).
- everything else — including EVERY 0.x version, which 1.0.0's clean break puts out of reach of a marker bump — → an empty slice.

The canonical name drops TypeScript's `get` prefix.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/migration.go#L164) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#SupportedMigrationTargets)

</div>

</div>
