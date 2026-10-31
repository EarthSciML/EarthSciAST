---
title: "migration_error"
description: "Stable error · Versions and migration"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** error · **Topic:** [Versions and migration](/generated/api/topics/versions)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `MigrationError` | `MigrationError` | `MigrationError` | `MigrationError` | `MigrationError` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct MigrationError <: EarthSciASTError
MigrationError(message::String)
MigrationError(message)
```

```julia
MigrationError <: EarthSciASTError
```

Thrown when [`migrate`](/generated/api/ref/migrate) is asked for a version pair it does not support —
including every pair that crosses the 1.0.0 clean break.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/migration.jl#L42)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
class MigrationError extends EsmDiagnosticError
new MigrationError(message: string): MigrationError
```

Error thrown when migration fails.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-ts/src/migration.ts#L37)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class MigrationError(EarthSciAstError)
```

Raised when an ESM document cannot be migrated to the requested version.

Derives from [`EarthSciAstError`](/generated/api/ref/earth_sci_ast_error) like every other
exception in this package, so `except EarthSciAstError` catches it.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/migration.py#L71)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct MigrationError {
    pub message: String,
    pub from_version: String,
    pub to_version: String,
}
```

Migration error that occurs when migration fails.

Carries the endpoint versions alongside the message so a caller can report
the pair without re-deriving it (Go's `MigrationError` mirrors these fields).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/migration.rs#L60) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.MigrationError.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type MigrationError struct {
	Message     string
	FromVersion string
	ToVersion   string
}

func (e *MigrationError) Error() string
```

MigrationError is returned when a migration cannot be performed. It carries the endpoint versions alongside the message so a caller can report the pair without re-deriving it (mirrors the Rust binding's `MigrationError` fields).

**Methods**

```go
func (e *MigrationError) Error() string
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/migration.go#L67) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#MigrationError)

</div>

</div>
