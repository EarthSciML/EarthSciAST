---
title: "solver_external_location"
description: "Stable function · Other"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Other](/generated/api/topics/other)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `solver_external_location` | `solverExternalLocation` | `solver_external_location` | `solver_external_location` | `SolverExternalLocation` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
solver_external_location(file::EsmFile; base_path)
```

```julia
solver_external_location(file::EsmFile; base_path=nothing) -> Union{String,Nothing}
```

Where the document's `solver.external` points (esm-spec §2.2.6), or `nothing`
when its `solver` block carries no `external`.

| Form | Test on the string | Location |
|---|---|---|
| URL | matches `^[A-Za-z][A-Za-z0-9+.-]*://` | unchanged |
| Absolute path | begins with `/`, or a drive letter `C:/` / `C:\` | dot segments removed, percent-encoded, prefixed `file://` |
| Relative path | anything else | joined onto *D*, dot segments removed, percent-encoded, prefixed `file://` |

Percent-encoding writes each byte of the path's UTF-8 encoding outside
`A-Za-z0-9-._~/:` as `%XX`, `%` included: the input is a path, not a URL. A
drive-letter path resolves to `file:///C:/…`.

*D* is `base_path` when given (a relative `base_path` is taken against the
working directory), else the directory recorded at load on the document — the
directory of the file read, or the working directory for a string load — else,
for a document built in memory, the working directory now.

Purely lexical (RFC 3986 §5.2.4, never `realpath`): it never touches the
filesystem or the network, and a location that does not exist resolves
normally. The document keeps the authored string; this is the only place the
resolved form appears. Only the root document's block is consulted — a mounted
document's `solver` block does not cross the mount (§4.7).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/solver.jl#L158)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function solverExternalLocation(file: EsmFile, base?: string): string | null
```

The location `solver.external` names, resolved by esm-spec §2.2.6, or `null`
when the root document's `solver` block carries none.

A URL (`scheme://…`) is returned unchanged. An absolute path — `/…`, or a
drive-letter `C:/…` / `C:\…` — has its dot segments removed, is
percent-encoded and is prefixed `file://` (`file:///C:/…` for a drive).
Anything else is joined onto the base, dot segments removed,
percent-encoded, and prefixed `file://`. Percent-encoding writes each byte of
the path's UTF-8 encoding outside `A-Za-z0-9-._~/:` as `%XX`, `%` included:
the input is a path, not a URL.

The base is `base` when given — a relative one is taken against the working
directory — and otherwise the directory recorded at load: the directory of
the file `loadPath` read, the `basePath` load option, or the working
directory of a `loadString` / `loadDocument`. A document built in memory
resolves against the working directory.

Purely lexical: it never touches the filesystem, and a location that does not
exist resolves normally. The authored string stays in the document and is
what `toJson` writes; the resolved location is never written back. A mounted
leaf's `solver` block does not cross the mount, so only the root's
`external` is consulted.

**Throws**

- [`EsmMachineryError`](/generated/api/extension/typescript#x-esmmachineryerror) — `solver_external_unresolved` when `external`
    carries `${` (only reachable for a document built in memory; load refuses it).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-ts/src/solver.ts#L189)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
solver_external_location(esm_file: EsmFile, base: str | os.PathLike[str] | None = None) -> str | None
```

Where the document's `solver.external` points (esm-spec §2.2.6).

Returns `None` when the document has no `external`. Otherwise:

- a URL (`scheme://…`) is returned unchanged;
- an absolute path (`/…`, or a drive-letter `C:/…` / `C:\…`) has
  its dot segments removed, is percent-encoded and is prefixed `file://`
  (`file:///C:/…` for a drive);
- anything else is joined onto *D*, dot segments removed, percent-encoded,
  and prefixed `file://`.

Percent-encoding writes each byte of the path's UTF-8 encoding outside
`A-Za-z0-9-._~/:` as `%XX`, `%` included: the input is a path, not a
URL.

*D* is `base` when given (a relative `base` is taken against the
process working directory), else the directory the loader recorded: the
directory of the file read, or the working directory for a string load or
a document built in memory.

Purely lexical (RFC 3986 §5.2.4): never `realpath`, never touches the
filesystem, so a location that does not exist resolves normally. The
document keeps, and `emit` writes, the authored string.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/solver.py#L235)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn solver_external_location(file: &EsmFile, base: Option<&Path>) -> Result<Option<String>, DiagnosticError>
```

Where the document's `solver.external` points (esm-spec §2.2.6), or
`Ok(None)` when the document names no run configuration.

A URL (`scheme://…`) is returned unchanged. An absolute path — `/…`, or a
drive-letter `C:/…` / `C:\…` — has its dot segments removed, is
percent-encoded and is prefixed `file://` (`file:///C:/…` for a drive).
Anything else is joined onto the base first: `base` when given (a relative
`base` is taken against the process working directory), otherwise the
directory recorded at load (`EsmFile::document_base`), otherwise, for a
document built in memory, the process working directory. Percent-encoding
writes each byte of the path's UTF-8 encoding outside `A-Za-z0-9-._~/:` as
`%XX`, `%` included: the input is a path, not a URL.

Purely lexical (RFC 3986 §5.2.4): never `realpath`, never the filesystem or
the network, so a location that does not exist resolves like any other.
The document is not changed — `emit` writes the authored string.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/solver.rs#L226) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.solver_external_location.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func SolverExternalLocation(file *ESMFile, base string) (string, error)
```

SolverExternalLocation resolves the document's `solver.external` to a location by esm-spec §2.2.6, or returns "" when the root document's `solver` block carries none (an authored `external` is never empty).

A URL (`scheme://…`) is returned unchanged. An absolute path -- `/…`, or a drive-letter `C:/…` / `C:\…` -- has its dot segments removed, is percent-encoded and is prefixed `file://` (`file:///C:/…` for a drive). Anything else is joined onto the base, dot segments removed, percent-encoded, and prefixed `file://`. Percent-encoding writes each byte of the path's UTF-8 encoding outside `A-Za-z0-9-._~/:` as %XX, `%` included: the input is a path, not a URL. The base is `base` when it is non-empty -- a relative one is taken against the process working directory -- and otherwise the directory recorded at load: the directory of the file LoadPath read, the WithBasePath directory, or the working directory of a bare LoadString / LoadDocument.

Resolution is lexical and never touches the filesystem: a location that does not exist resolves normally. A mounted leaf's `solver` block does not cross the mount, so only the root's `external` is ever consulted.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/solver.go#L217) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#SolverExternalLocation)

</div>

</div>
