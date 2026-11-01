---
title: "schema_version"
description: "Stable constant · Versions and migration"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** constant · **Topic:** [Versions and migration](/generated/api/topics/versions)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `SCHEMA_VERSION` | `SCHEMA_VERSION` | `SCHEMA_VERSION` | `SCHEMA_VERSION` | `SchemaVersion` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
const SCHEMA_VERSION::String
```

```julia
SCHEMA_VERSION
```

The `.esm` FORMAT version (semver string) this implementation targets — the
value written into the `esm` field of freshly constructed files. Files loaded
from disk keep whatever version they declare; this constant is only the default
for documents the library itself creates (flatten wrappers, MTK/Catalyst
export). Must track the version on the first line of `esm-spec.md` and in the
bundled schema's `$id`, which the `SCHEMA_VERSION tracks the bundled schema`
test enforces.

Spelled `ESM_FORMAT_VERSION` until the bindings converged: TypeScript, Rust and
Go all called this `SCHEMA_VERSION`, and Julia was the only one that did not.
NOT the version of this PACKAGE — that is [`LIBRARY_VERSION`](/generated/api/ref/library_version).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/types.jl#L14)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
const SCHEMA_VERSION: string
```

The schema version this library implements, derived from the embedded
schema's `$id` (https://earthsciml.org/schemas/esm/&lt;version>/esm.schema.json)
so it cannot hand-drift from the canonical esm-schema.json. The package
version in package.json is kept in lockstep.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/parse.ts#L106)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
SCHEMA_VERSION: str = _bundled_schema_version()
```

The `.esm` FORMAT version this library implements — NOT the version of the
library itself, which is `earthsci_ast.LIBRARY_VERSION`. Every binding
exports it under this name (API_SPEC.md §6).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/parse.py#L258)

**Example** (`version_constants`)

```python
print("format version:", earthsci_ast.SCHEMA_VERSION)
print("library version:", earthsci_ast.LIBRARY_VERSION)
assert earthsci_ast.SCHEMA_VERSION.count(".") == 2
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/python/documents.py#L31-L33">docs/api/examples/python/documents.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub const SCHEMA_VERSION: &str = "1.3.0";
```

ESM schema version supported by this implementation. Must track the
version in `esm-schema.json`'s `$id` / esm-spec.md; the
`schema_version_matches_bundled_schema` test enforces it, and
`parse::library_version()` (major-compat gating) derives from it.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/lib.rs#L436) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/constant.SCHEMA_VERSION.html)

**Example** (`version_constants`)

```rust
// The `.esm` format version this library reads and writes, and the
// version of the library itself: two unrelated numbers.
println!("format {SCHEMA_VERSION}, library {LIBRARY_VERSION}");
assert_eq!(SCHEMA_VERSION.split('.').count(), 3);
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/rust/load.rs#L26-L29">docs/api/examples/rust/load.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
var SchemaVersion = func() string {
	m := schemaIDVersionRe.FindSubmatch(embeddedSchema)
	if m == nil {
		panic("embedded ESM schema $id does not carry a version")
	}
	return string(m[1])
}()
```

SchemaVersion is the schema version this library implements, derived from the embedded schema's `$id` so it cannot hand-drift from the canonical esm-schema.json. Mirrors TypeScript's `SCHEMA_VERSION`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/migration.go#L56) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#SchemaVersion)

</div>

</div>
