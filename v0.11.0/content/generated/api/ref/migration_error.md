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
MigrationError(message::AbstractString; code, path)
```

```julia
MigrationError <: EarthSciASTError
```

Thrown when [`migrate`](/generated/api/ref/migrate) is asked for a version pair it does not support —
including every pair that crosses the 1.0.0 clean break — or for a 1.x document
that uses a construct esm 2.0.0 removed. `code` is the diagnostic code: empty
for an unsupported version pair, `removed_op` for a removed construct, whose
`path` it names.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/2a98137b2fc6eb951597ae89e22e993e87bee65a/pkg/EarthSciAST.jl/src/migration.jl#L51)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
class MigrationError extends EsmDiagnosticError
new MigrationError(message: string, code?: string): MigrationError
```

Error thrown when migration fails. `code` is `removed_op` when a 1.x document
is refused for using a construct esm 2.0.0 removed.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/2a98137b2fc6eb951597ae89e22e993e87bee65a/pkg/earthsci-ast-ts/src/migration.ts#L47)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class MigrationError(EarthSciAstError)
MigrationError(message: str, code: str | None = None)
```

Raised when an ESM document cannot be migrated to the requested version.

`code` is `"removed_op"` when [`migrate`](/generated/api/ref/migrate) refuses because the
document uses an operator or field esm 2.0.0 removed, and `None` otherwise.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/2a98137b2fc6eb951597ae89e22e993e87bee65a/pkg/earthsci-ast-py/src/earthsci_ast/migration.py#L135)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/2a98137b2fc6eb951597ae89e22e993e87bee65a/pkg/earthsci-ast-rs/src/migration.rs#L70) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.MigrationError.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type MigrationError struct {
	Message     string
	FromVersion string
	ToVersion   string
	// Code is the diagnostic code of a refusal that has one: `removed_op` for a
	// 1.x document that uses a construct esm 2.0.0 removed. Empty otherwise.
	Code string
	// contains filtered or unexported fields
}

func (e *MigrationError) Error() string

func (e *MigrationError) Unwrap() error
```

MigrationError is returned when a migration cannot be performed. It carries the endpoint versions alongside the message so a caller can report the pair without re-deriving it (mirrors the Rust binding's `MigrationError` fields).

**Methods**

```go
func (e *MigrationError) Error() string
```

```go
func (e *MigrationError) Unwrap() error
```

Unwrap returns the diagnostic behind a coded refusal, so errors.As reaches it as a DiagnosticError.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/2a98137b2fc6eb951597ae89e22e993e87bee65a/pkg/earthsci-ast-go/pkg/esm/migration.go#L68) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#MigrationError)

</div>

</div>
