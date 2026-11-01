---
title: "to_json_compact"
description: "Stable function · Document I/O"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Document I/O](/generated/api/topics/document-io)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `to_json_compact` | `toJsonCompact` | `to_json_compact` | `to_json_compact` | `ToJSONCompact` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
to_json_compact(file::EsmFile)
```

```julia
to_json_compact(file::EsmFile) -> String
```

The single-line wire form. Exists in every binding for call-site parity —
Rust and Go have no default arguments and so cannot express
`to_json(file, indent=0)`.

In THIS binding it returns exactly what [`to_json`](/generated/api/ref/to_json) returns, because
JSON3 already emits the compact form (see `to_json`).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/serialize.jl#L604)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function toJsonCompact(file: EsmFile, options?: ToJsonOptions): string
```

[`toJson`](/generated/api/ref/to_json) with no indentation — the single-line wire form. Present in
every binding, because Rust and Go have no default arguments and so cannot
express `toJson(file, { indent: 0 })`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/serialize.ts#L114)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
to_json_compact(esm_file: EsmFile) -> str
```

[`to_json`](/generated/api/ref/to_json) with no indentation — the single-line wire form.

Present in every binding, because Rust and Go have no default arguments
and so cannot express `to_json(file, indent=0)`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/serialize.py#L1277)

**Example** (`to_json_compact`)

```python
compact = earthsci_ast.to_json_compact(doc)
assert "\n" not in compact and compact.startswith('{"esm":')
assert json.loads(compact) == json.loads(earthsci_ast.to_json(doc))
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/python/documents.py#L143-L145">docs/api/examples/python/documents.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn to_json_compact(esm_file: &EsmFile) -> Result<String, EsmError>
```

Serialize an ESM file to compact JSON string (no pretty printing)

This function is similar to [`to_json`](/generated/api/ref/to_json) but produces compact JSON without
extra whitespace, suitable for storage or transmission. It is a separate
function rather than a `to_json(file, opts)` flag because Rust has no
default arguments and a one-field options struct plus a
`to_json_with_options` twin is heavier than the pair.

**Arguments**

* `esm_file` - The ESM file to serialize

**Returns**

* `Ok(String)` - Successfully serialized compact JSON string
* `Err(EsmError)` - Serialization error

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/serialize.rs#L96) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.to_json_compact.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func ToJSONCompact(file *ESMFile) (string, error)
```

ToJSONCompact validates an ESM file and returns it as a compact canonical JSON string (no indentation). A separate function rather than a ToJSON option because Go has no default arguments.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/serialize.go#L132) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ToJSONCompact)

</div>

</div>
