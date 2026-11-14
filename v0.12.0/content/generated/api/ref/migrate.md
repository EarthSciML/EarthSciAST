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
migrate(doc::AbstractDict, target_version::AbstractString)
```

```julia
migrate(file::EsmFile, target_version::AbstractString) -> EsmFile
```

Migrate `file` from the version it declares to `target_version`.

Every supported step is a pure version-marker bump with no structural
transform: an additive-line source (`2.0.0 … <current>`), or a 1.x source that
uses none of the constructs esm 2.0.0 removed, advanced to the current schema
version (see this file's header). Any other version pair — a 0.x source
included — throws [`MigrationError`](/generated/api/ref/migration_error), as does a 1.x document using a
removed construct (code `removed_op`; the codemod rewrites those). Content-level
changes are not performed; they are modeling decisions, not mechanical
migrations.

`EsmFile` is immutable, so the input is necessarily left alone: a NEW `EsmFile`
carrying the updated `esm` marker and every other field unchanged is returned.

**Throws**
- `MigrationError` if the file declares no version, if the pair is not one
  [`can_migrate`](/generated/api/ref/can_migrate) accepts, or (code `removed_op`) if a 1.x file uses a
  construct 2.0.0 removed.

    migrate(doc::AbstractDict, target_version) -> Dict{String, Any}

The same relabel on a raw JSON document (as `JSON3.read` returns it), for a
1.x document the loader refuses because it uses a removed construct: refused
with the same `removed_op` error, naming the construct's path. Returns a copy
with the `esm` marker changed and every other key unchanged.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/00808ba516066c29654f9613e987190c0347e352/pkg/EarthSciAST.jl/src/migration.jl#L227)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function migrate(file: EsmFile, targetVersion: string): EsmFile
```

Migrate an ESM file from its current schema version to the target version.

Every supported step is a pure version-marker bump with no structural
transform: an additive-line source (`2.0.0 … <current>`), or a 1.x source
that uses none of the constructs esm 2.0.0 removed, advanced to the current
schema version (see the module header). A 1.x source that uses one throws
[`MigrationError`](/generated/api/ref/migration_error) with code `removed_op`, naming the construct, where it
sits, and the codemod that rewrites it. Any other version pair — a 0.x source
included — throws [`MigrationError`](/generated/api/ref/migration_error). The input file is never mutated; a
new object with the updated `esm` marker is returned.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/00808ba516066c29654f9613e987190c0347e352/pkg/earthsci-ast-ts/src/migration.ts#L158)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
migrate
```

Command line for the esm 2.0.0 codemod: `python -m earthsci_ast.migrate`.

A thin entry point over `earthsci_ast.migration.main`. The project ships
one command-line tool, the Rust `esm` binary; the codemod has a single
reference implementation, in Python, so its command line is this module.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/00808ba516066c29654f9613e987190c0347e352/pkg/earthsci-ast-py/src/earthsci_ast/migrate.py)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn migrate(file: &EsmFile, target_version: &str) -> Result<EsmFile, MigrationError>
```

Migrate an ESM file from the version it declares to `target_version`.

Every supported step is a pure version-marker bump with no structural
transform: an additive-line source (`2.0.0 … <current>`) advanced to the
current schema version, or a 1.x source relabelled to it (see the module
header). A 1.x document that uses an op 2.0.0 removed is refused with a
`removed_op` message naming the op, its path and the codemod. Any other
version pair — a 0.x source included — yields a [`MigrationError`](/generated/api/ref/migration_error).
Content-level changes are not performed here.

The input is never mutated: a clone carrying the updated `esm` marker and
every other field unchanged is returned.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/00808ba516066c29654f9613e987190c0347e352/pkg/earthsci-ast-rs/src/migration.rs#L191) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.migrate.html)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/00808ba516066c29654f9613e987190c0347e352/docs/api/examples/rust/load.rs#L33-L42">docs/api/examples/rust/load.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func Migrate(file *ESMFile, targetVersion string) (*ESMFile, error)
```

Migrate migrates an ESM file from its declared schema version to `targetVersion`.

Every supported step is a pure version-marker bump with no structural transform: a source on the additive line or the 1.x line advanced to the current schema version (see the file header). A 1.x document that uses a removed op returns a \*MigrationError whose Code is `removed_op`, naming the op, where it is, and the codemod; errors.As finds the underlying diagnostic as a DiagnosticError. Any other version pair — a 0.x source included — returns a \*MigrationError. Content-level changes are not performed; they are modeling decisions, not mechanical migrations.

The input file is never mutated: a shallow copy carrying the updated `esm` marker is returned. A shallow copy is exactly what the marker bump needs and exactly what the other bindings do (`{...file, esm}` in TypeScript) — since nothing else is written, the copy and the original may share their component maps and slices.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/00808ba516066c29654f9613e987190c0347e352/pkg/earthsci-ast-go/pkg/esm/migration.go#L229) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#Migrate)

</div>

</div>
