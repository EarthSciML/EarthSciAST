---
title: "load_document"
description: "Stable function · Document I/O"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Document I/O](/generated/api/topics/document-io)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `load_document` | `loadDocument` | `load_document` | `load_document` | `LoadDocument` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
load_document(doc::AbstractDict; base_path, metaparameters)
```

```julia
load_document(doc::AbstractDict; base_path=nothing, metaparameters=Dict{String,Int}()) -> EsmFile
```

Parse an ESM document held in memory as a native Julia dict — the same
document a `.esm` file holds, just already parsed. Runs the identical pipeline
[`load_path`](/generated/api/ref/load_path) runs (top-level `{ref}` inlining, schema validation,
expression-template lowering, coercion, subsystem-ref resolution); `base_path`
anchors the relative refs a file input anchors at its own directory, and
defaults to `pwd()` for that. Left at `nothing` the document has no location of
its own, so a relative `coupling_import` ref resolves against `flatten`'s own
`base_path` instead (esm-spec §10.10 -> §4.7).

Distinct from `coerce_esm_file`, which only coerces: it does not
validate, and it leaves a `{ref}` subsystem as an unresolved `SubsystemRef`
that [`flatten`](/generated/api/ref/flatten) then SKIPS — so a dict must come through here, not
through `coerce_esm_file`, before it is flattened and run.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/resolve.jl#L81)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function loadDocument(doc: object, options?: LoadOptions): EsmFile
```

Parse an ESM document that is ALREADY a JavaScript object — the same
document a `.esm` file holds, just already `JSON.parse`d.

`options.canonical` has no effect here: canonical mode tags numeric
literals during JSON decoding, and this entry point does no decoding.
Callers who want tagged leaves should pass the JSON text to
[`loadString`](/generated/api/ref/load_string) with `canonical: true` instead.

**Parameters**

- `doc` — The already-parsed document
- `options` — Optional load-time settings (see [`LoadOptions`](/generated/api/ref/load_options))

**Returns**

Typed EsmFile object

**Throws**

- [`SchemaValidationError`](/generated/api/ref/schema_validation_error) — When schema validation fails

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/parse.ts#L409)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
load_document(document: dict, *, metaparameters: dict[str, int] | None = None, base_path: str | os.PathLike[str] | None = None) -> EsmFile
```

Parse an ESM document that is ALREADY a Python `dict` — the same
document a `.esm` file holds, just already `json.load`ed.

**Parameters**

- `document` (`dict`) — The already-parsed document.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/parse.py#L2906)

**Example** (`load_document`)

```python
raw = json.loads(text)
from_dict = earthsci_ast.load_document(raw)
assert from_dict.metadata.name == "Decay"
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/python/documents.py#L24-L26">docs/api/examples/python/documents.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn load_document(document: &Value) -> Result<EsmFile, EsmError>
```

Load and parse an ESM document that is ALREADY parsed as a
`serde_json::Value` — the same document a `.esm` file holds, just
already decoded. Runs the identical pipeline [`load_string`](/generated/api/ref/load_string) runs
(subsystem-ref resolution, version gates, schema validation, §9.7
template machinery, typed deserialization).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/parse.rs#L102) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.load_document.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func LoadDocument(document map[string]any, opts ...LoadOption) (*ESMFile, error)
```

LoadDocument parses an ESM document that is ALREADY decoded into a Go map — the same document a `.esm` file holds, just already unmarshalled. It runs the identical pipeline LoadString runs.

One thing it CANNOT recover is declaration order: a map\[string\]any has none, and re-encoding it writes the keys sorted. A document loaded this way therefore flattens with sorted-name order wherever esm-libraries-spec §4.7.5 step 4 asks for document order. Use LoadPath / LoadString when the order matters.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/parse.go#L317) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#LoadDocument)

</div>

</div>
