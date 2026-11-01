---
title: "resolve_subsystem_refs"
description: "Stable function · Load-time lowering and templates"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Load-time lowering and templates](/generated/api/topics/lowering)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `resolve_subsystem_refs!` | `resolveSubsystemRefs` | `resolve_subsystem_refs` | `resolve_subsystem_refs` | `ResolveSubsystemRefs` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
resolve_subsystem_refs!(file::EsmFile, base_path::String; loader_metaparameters, root_env, model_envs)
```

```julia
resolve_subsystem_refs!(file::EsmFile, base_path::String) -> EsmFile
```

Resolve all subsystem references in-place. Walks all models and reaction_systems,
and for each subsystem that was parsed from a `{"ref": "..."}` object, loads the
referenced file and replaces the subsystem content.

**Use the returned file.** A mounted document's `data_sources` merge into the
mounting document (esm-spec §4.7 "A mounted document's data sources"). When
`file` declares a `data_sources` registry they merge into it in place and the
return value is `file` itself; when it declares none, `EsmFile` being
immutable, there is no registry to merge into, and the return value is a
rebuilt `EsmFile` carrying them — `file` is still resolved in place but lacks
those sources. Write `file = resolve_subsystem_refs!(file, base_path)`.

References can be:
- Local file paths (resolved relative to `base_path`)
- Remote URLs starting with `http://` or `https://`

Circular references are detected and raise a `SubsystemRefError`.

**Arguments**
- `file::EsmFile`: the parsed ESM file to resolve references in
- `base_path::String`: directory path for resolving relative file references

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/resolve.jl#L2098)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function resolveSubsystemRefs(file: EsmFile, basePath: string, loaderMetaparameters?: Readonly<Record<string, number>>): Promise<void>
```

Async resolution — the only entry point that can reach a REMOTE
(`http(s)://`) ref, since `fetch` cannot be awaited synchronously.

It is a thin shell around the SYNC core: fetch every reachable ref into a
cache first, then run the one and only resolution walk against that cache.
There is deliberately no second walk implementing the same semantics — index-set
merging, the §4.7 single-component invariant, template-machinery lowering,
cycle detection and component inlining exist in exactly one place, so the sync
and async paths cannot drift apart.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/ref-loading.ts#L333)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
resolve_subsystem_refs(esm_file: EsmFile, base_path: str, loader_metaparameters: dict[str, int] | None = None, parent_metaparameters: dict[str, int] | None = None) -> None
```

Resolve all subsystem references in an ESM file.

Walks all subsystems in models and reaction_systems. For each subsystem
value with a `ref` field:

- If the ref starts with `http://` or `https://`, the content is
  fetched via urllib.
- Otherwise the ref is resolved relative to *base_path* and read from
  the filesystem.

The referenced file is parsed, the single top-level model or reaction
system is extracted, and the reference is replaced with the resolved
content. Resolution is recursive, and circular references are detected.

**Parameters**

- `esm_file` (`EsmFile`) — The parsed ESM file to resolve references in (modified in place)
- `base_path` (`str`) — The base directory for resolving relative file paths

**Raises**

- [`CircularReferenceError`](/generated/api/ref/circular_reference_error) — If circular subsystem references are detected
- [`SubsystemRefError`](/generated/api/ref/subsystem_ref_error) — If a reference cannot be resolved or is invalid

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/parse.py#L2507)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn resolve_subsystem_refs(file: &mut EsmFile, base_path: &Path) -> Result<(), DiagnosticError>
```

Resolve every subsystem `{ "ref": ... }` in a TYPED document, in place.

The canonical entry point (API_SPEC.md §8 item 14): Julia
(`resolve_subsystem_refs!`), Python and TypeScript all take a typed
document and mutate it; this binding alone took an untyped
`serde_json::Value`. Implemented over [`resolve_subsystem_refs_raw`](/generated/api/extension/rust#x-resolve_subsystem_refs_raw) —
`file` is rendered to JSON, resolved, and read back — so the two agree by
construction.

**Arguments**

* `file` - the document to resolve (modified in place)
* `base_path` - directory to resolve relative file paths against

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/ref_loading.rs#L136) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.resolve_subsystem_refs.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func ResolveSubsystemRefs(file *ESMFile, basePath string) error
```

ResolveSubsystemRefs walks all subsystem maps in models and reaction systems, resolving any entries that contain a "ref" field by loading and inlining the referenced ESM file content.

Resolution rules:

- If ref starts with http:// or https://, fetch the file over HTTP.
- Otherwise, the ref is resolved as a local file path relative to basePath.
- Referenced files are parsed recursively, so nested refs are resolved.
- Circular references are detected and reported as errors.

The function modifies file in-place, replacing reference objects with the resolved model or reaction system content.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/subsystem_ref.go#L25) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ResolveSubsystemRefs)

</div>

</div>
