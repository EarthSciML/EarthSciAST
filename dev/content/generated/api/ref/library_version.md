---
title: "library_version"
description: "Stable constant · Versions and migration"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** constant · **Topic:** [Versions and migration](/generated/api/topics/versions)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `LIBRARY_VERSION` | `LIBRARY_VERSION` | `LIBRARY_VERSION` | `LIBRARY_VERSION` | `LibraryVersion` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
const LIBRARY_VERSION::String
```

```julia
LIBRARY_VERSION
```

This package's OWN version, read from its `Project.toml` — NOT the `.esm`
format version, which is [`SCHEMA_VERSION`](/generated/api/ref/schema_version). The two are unrelated
numbers.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/types.jl#L31)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
const LIBRARY_VERSION: "0.7.0"
```

The package's OWN version — distinct from [`SCHEMA_VERSION`](/generated/api/ref/schema_version), which is
the `.esm` FORMAT version this build implements. The two are unrelated
numbers; every binding exposes both, under these two names.

package.json is the source of truth. It cannot be imported here —
tsconfig's `rootDir` is `./src`, and a runtime read would break browser
hosts — so the value is mirrored, and `version.test.ts` fails the build if
the mirror drifts. Same arrangement Rust uses for its `SCHEMA_VERSION`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/version.ts#L11)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
LIBRARY_VERSION: str = __version__
```

This package's OWN version -- the cross-binding spelling of `__version__`.
Distinct from [`SCHEMA_VERSION`](/generated/api/ref/schema_version), the `.esm` FORMAT version; the two are
unrelated numbers.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/__init__.py#L482)

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
pub const LIBRARY_VERSION: &str = "0.7.0";
```

This crate's OWN version — NOT the `.esm` format version, which is
[`SCHEMA_VERSION`](/generated/api/ref/schema_version). The two are unrelated numbers. Every binding exposes
both, under these two names.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/lib.rs#L431) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/constant.LIBRARY_VERSION.html)

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
const LibraryVersion = "0.7.0"
```

LibraryVersion is this Go module's OWN version — NOT the `.esm` format version, which is SchemaVersion. The two are unrelated numbers, and until this split Go exposed neither under a shared name while TypeScript and Rust both exported a `VERSION` that meant the SCHEMA version in one and the PACKAGE version in the other. Every binding now exposes exactly SchemaVersion and LibraryVersion.

Unlike the other four bindings, a Go module carries no in-tree version manifest — a module's version is the git tag the proxy resolves — so there is nothing to derive this from and no file a test could pin it against. It is maintained by hand alongside the repo-wide release version, which the release process bumps in lockstep with the Julia Project.toml, the Rust Cargo.toml, the npm package.json and the Python pyproject.toml.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/version.go#L16) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#LibraryVersion)

</div>

</div>
