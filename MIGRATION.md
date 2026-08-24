# Migration guide

Breaking changes to the EarthSciAST public API, newest first. Every entry
gives the exact before/after spelling in each binding.

---

## Phase 2 — document I/O and version constants

Three symbols changed, in all five bindings, in one release. The old names are
**deleted**, not deprecated: each of the three was defective in a way a
compatibility shim would have to preserve.

### `load` → `load_path` / `load_string` / `load_document`

`load(<string>)` meant a **file path** in Julia and Go and **JSON text** in
TypeScript and Rust. Python sniffed: `os.path.exists(s)` decided which. One
name, one argument type, opposite meanings, and no type error anywhere to
catch the difference — a program ported between bindings failed at runtime, or,
if the path happened to be valid JSON, did the wrong thing silently.

| Was | Now — read a FILE | Now — parse JSON TEXT | Now — take a PARSED document |
|---|---|---|---|
| Julia `load(path::String)` | `load_path(path)` | `load_string(json)` | `load_document(dict)` |
| Julia `load(io::IO)` | – | `load_string(io)` | – |
| Julia `load(doc::AbstractDict)` | – | – | `load_document(doc)` |
| TypeScript `load(input, opts?)` | `loadPath(path, opts?)` | `loadString(json, opts?)` | `loadDocument(obj, opts?)` |
| Python `load(path_or_string)` | `load_path(path)` | `load_string(json)` | `load_document(dict)` |
| Rust `load(&str)` | `load_path(p)` *(unchanged)* | `load_string(s)` | `load_document(&Value)` |
| Rust `load_with_options(&str, &o)` | `load_path_with_options` *(unchanged)* | `load_string_with_options` | `load_document_with_options` |
| Go `Load(path, opts...)` | `LoadPath(path, opts...)` | `LoadString(json, opts...)` *(unchanged)* | `LoadDocument(map, opts...)` |

All three run the identical pipeline: top-level `{ref}` inlining, version
gates, schema validation, §9.7 template machinery, typed coercion, and nested
subsystem-ref resolution. `load_path` anchors relative refs at the file's own
directory; the other two take `base_path` (Go: `WithBasePath`).

Options move to the entry points they apply to. TypeScript's `canonical` (which
tags numeric literals during JSON DECODING) applies to `loadPath` and
`loadString` only — a `loadDocument` caller has already decoded, and should
run `losslessJsonParse` on the text itself if it wants tagged leaves.

Two sanctioned per-binding decorations:

- **Rust** keeps `*_with_options` twins; it has no default arguments.
- **Julia** gives `load_string` an `::IO` method beside `::AbstractString`. It
  reads the stream to a string and parses that — a method on the canonical
  entry point, not a fourth one.

**If you sniffed on purpose.** A few callers legitimately accept "a path or the
content" — a conformance harness holding fixture text rather than its path is
the usual case. Do the sniff yourself, at your own boundary, where it is
visible:

```python
if isinstance(x, dict):        doc = load_document(x, base_path=base)
elif os.path.exists(x):        doc = load_path(x, base_path=base)
else:                          doc = load_string(x, base_path=base)
```

That is exactly what `earthsci_ast.validate()` now does internally, since its
own documented contract requires it.

### `save` → `to_json` / `to_json_compact` / `write_path`

`save` was pure serialization in TypeScript and Rust, a disk write in Julia,
and both in Python (`path=None` decided). Go alone split them by name — and
used names no other binding used. **No function in this API both writes and
returns the payload any more.**

| Was | Now |
|---|---|
| Julia `save(file, path::String)` | `write_path(file, path)` → `nothing` |
| Julia `save(file, io::IO)` | `write(io, to_json(file))` |
| TypeScript `save(file, opts?)` | `toJson(file, opts?)` |
| TypeScript `SaveOptions` | `ToJsonOptions` |
| Python `save(file)` | `to_json(file)` |
| Python `save(file, path)` | `write_path(file, path)` → `None` |
| Rust `save(&file)` | `to_json(&file)` |
| Rust `save_compact(&file)` | `to_json_compact(&file)` |
| Go `Serialize(file)` | `ToJSON(file)` |
| Go `SerializeCompact(file)` | `ToJSONCompact(file)` |
| Go `SaveToFile(file, path)` | `WritePath(file, path)` |
| Go `SaveCompactToFile(file, path)` | `WritePathCompact(file, path)` |

`to_json_compact` exists in all five rather than being an option, because Rust
and Go have no default arguments and so cannot express `to_json(file,
indent=0)`. Where a binding does have defaults it takes the option as well —
Julia `to_json(file; indent=2)`, Python `to_json(file, *, indent=2)`,
TypeScript `toJson(file, {indent, canonical})` — and `to_json_compact` is a
one-line wrapper over it.

Rust gains an `EsmError::FileWrite` variant. `write_path`'s I/O failures used
to have to be reported through `FileRead`, whose message reads "failed to read
{path}" — the wrong sentence for a failed write.

**Name collision worth knowing about.** `to_json` was already the graph
serializer's name in Julia and Python (TypeScript and Rust had already moved
theirs to `toJsonGraph` / `to_json_graph`). Julia's two dispatch on argument
type and both keep the name. Python's graph serializer is now re-exported as
`to_json_graph`:

```python
from earthsci_ast import to_json_graph   # was: to_json, on a Graph
from earthsci_ast import to_json         # now: the DOCUMENT serializer
```

### `VERSION` / `ESM_FORMAT_VERSION` → `SCHEMA_VERSION` + `LIBRARY_VERSION`

`VERSION` meant the **schema** version in TypeScript and the **package**
version in Rust. Julia exported only `ESM_FORMAT_VERSION` (the schema version,
under a name nobody else used). Python kept the format version private, as
`parse._CURRENT_VERSION`, and as a `(major, minor, patch)` tuple rather than a
string. Go exposed neither.

Two public **string** constants everywhere:

| Was | Now |
|---|---|
| Julia `ESM_FORMAT_VERSION` | `SCHEMA_VERSION` |
| Julia *(none)* | `LIBRARY_VERSION` |
| TypeScript `SCHEMA_VERSION` | `SCHEMA_VERSION` *(unchanged)* |
| TypeScript `VERSION` *(alias of the above)* | `LIBRARY_VERSION` — a **different number** |
| Python `parse._CURRENT_VERSION` *(private tuple)* | `SCHEMA_VERSION` *(public string)* |
| Python `__version__` | `LIBRARY_VERSION` *(`__version__` still works)* |
| Rust `SCHEMA_VERSION` | `SCHEMA_VERSION` *(unchanged)* |
| Rust `VERSION` | `LIBRARY_VERSION` |
| Go `SchemaVersion` | `SchemaVersion` *(unchanged)* |
| Go *(none)* | `LibraryVersion` |

> **⚠ TypeScript callers reading `VERSION`:** it was the SCHEMA version. The
> replacement is `SCHEMA_VERSION`, not `LIBRARY_VERSION`.
>
> **⚠ Rust callers reading `VERSION`:** it was the PACKAGE version. The
> replacement is `LIBRARY_VERSION`, not `SCHEMA_VERSION`.

Python's `_CURRENT_VERSION` tuple still exists as an internal, now derived from
`SCHEMA_VERSION` rather than being the source of truth. `migration.SCHEMA_VERSION`
is re-exported from `parse` rather than computed a second time.

Each constant is derived from that binding's existing source of truth rather
than a second hand-kept copy: `SCHEMA_VERSION` from the bundled schema's `$id`
(TypeScript, Python, Go) or a literal pinned to it by a test (Julia, Rust);
`LIBRARY_VERSION` from `CARGO_PKG_VERSION` (Rust), `pkgversion` (Julia),
`importlib.metadata` (Python), and package.json pinned by a test (TypeScript).
Go's `LibraryVersion` is the exception, and says why at the constant: a Go
module carries no in-tree version manifest — its version is the git tag — so
there is nothing to derive from or pin against.

### Bug fixed in the same round

`EarthSciAST.load(::IO)` in Julia skipped top-level `{ref}` inlining and
`resolve_subsystem_refs!`, which the path and dict methods both ran. A document
loaded from a stream therefore kept its subsystem refs as unresolved
`SubsystemRef`s — and `flatten` **silently skips** an unresolved `SubsystemRef`.
Same bytes, strictly smaller system, no error. All three entry points now share
one pipeline; the successor of `load(::IO)` is `load_string(::IO)`.
