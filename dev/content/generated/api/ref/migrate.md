---
title: "migrate"
description: "Stable function · Versions and migration"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Versions and migration](/generated/api/topics/versions)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `migrate` | `migrate` | `migrate` | `migrate` | `Migrate` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
migrate(file::EsmFile, target_version::AbstractString)
```

```julia
migrate(file::EsmFile, target_version::AbstractString) -> EsmFile
```

Migrate `file` from the version it declares to `target_version`.

Every supported step is a pure version-marker bump with no structural
transform: an additive-line source (`1.0.0 … <current>`) advanced to the current
schema version (see this file's header). Any other version pair — a 0.x source
included — throws [`MigrationError`](/generated/api/ref/migration_error). Content-level changes are not
performed; they are modeling decisions, not mechanical migrations.

`EsmFile` is immutable, so the input is necessarily left alone: a NEW `EsmFile`
carrying the updated `esm` marker and every other field unchanged is returned.

**Throws**
- `MigrationError` if the file declares no version, or if the pair is not one
  [`can_migrate`](/generated/api/ref/can_migrate) accepts.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/migration.jl#L139)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function migrate(file: EsmFile, targetVersion: string): EsmFile
```

Migrate an ESM file from its current schema version to the target version.

Every supported step is a pure version-marker bump with no structural
transform: an additive-line source (`1.0.0 … <current>`) advanced to the
current schema version (see the module header). Any other version pair — a
0.x source included — throws [`MigrationError`](/generated/api/ref/migration_error). Content-level changes
are not performed; they are modeling decisions, not mechanical migrations.
The input file is never mutated; a new object with the updated `esm` marker
is returned.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-ts/src/migration.ts#L127)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
migrate(file: EsmFile, target_version: str) -> EsmFile
```

Migrate `file` to `target_version`.

Every supported step is a pure version-marker bump with no structural
transform: an additive-line source (`1.0.0 … <current>`) advanced to the
current schema version (see the module docstring). Any other version pair —
a 0.x source included — raises [`MigrationError`](/generated/api/ref/migration_error). Content-level
changes are not performed; they are modeling decisions, not mechanical
migrations.

The input file is never mutated: a new [`EsmFile`](/generated/api/ref/esm_file)
carrying the updated marker is returned, sharing the original's sub-objects
(a shallow copy, matching TypeScript's object spread).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/migration.py#L121)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn migrate(file: &EsmFile, target_version: &str) -> Result<EsmFile, MigrationError>
```

Migrate an ESM file from the version it declares to `target_version`.

Every supported step is a pure version-marker bump with no structural
transform: an additive-line source (`1.0.0 … <current>`) advanced to the
current schema version (see the module header). Any other version pair — a
0.x source included — yields a [`MigrationError`](/generated/api/ref/migration_error). Content-level changes are
not performed; they are modeling decisions, not mechanical migrations.

The input is never mutated: a clone carrying the updated `esm` marker and
every other field unchanged is returned.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/migration.rs#L162) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.migrate.html)

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
func Migrate(file *ESMFile, targetVersion string) (*ESMFile, error)
```

Migrate migrates an ESM file from its declared schema version to `targetVersion`.

Every supported step is a pure version-marker bump with no structural transform: an additive-line source (`1.0.0 … <current>`) advanced to the current schema version (see the file header). Any other version pair — a 0.x source included — returns a \*MigrationError. Content-level changes are not performed; they are modeling decisions, not mechanical migrations.

The input file is never mutated: a shallow copy carrying the updated `esm` marker is returned. A shallow copy is exactly what the marker bump needs and exactly what the other bindings do (`{...file, esm}` in TypeScript) — since nothing else is written, the copy and the original may share their component maps and slices.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/migration.go#L196) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#Migrate)

</div>

</div>
