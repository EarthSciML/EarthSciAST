---
title: "canonicalize_document"
description: "Stable function · Source formats"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Source formats](/generated/api/topics/source-formats)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `canonicalize_document` | `canonicalizeDocument` | `canonicalize_document` | `canonicalize_document` | `CanonicalizeDocument` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
canonicalize_document(doc::AbstractDict)
```

```julia
canonicalize_document(doc::AbstractDict) -> OrderedDict{String, Any}
```

The document-level canonical step: every units string of a decoded document
(the JSON object `to_json` writes and `load_document` reads, e.g. from
`JSON3.read`) takes the canonical unit spelling (esm-spec §4.8.2, Lean
`Esm.Units.canon`).

That is every `units` and `default_units` string of a variable, species,
parameter, coordinate or `const` node, wherever it sits: nested subsystems,
template bodies, tests, coupling entries. Free-form objects (`metadata`,
`x_esd`, `attrs`, `config`, `reader_options`) are not respelled, and neither are
the keys of name-keyed maps. A `const` node whose units spell `1` loses them: a
scalar one becomes the bare literal, an array one a `const` without `units`.
The deprecated ops are rewritten (esm-spec §4.2): a `neg` node with one argument
becomes unary `-`, a `pow` node with two becomes `^`, and a `broadcast` of `neg`
with one argument maps `-`. Every number, free-form objects included, takes its
canonical form (CONFORMANCE §5.5.3.1): an integral value in `Int64` is an
integer (`2.0` is `2`, `-0.0` is `0`). The input is not mutated, key order is
kept, and nothing else changes. These are the rules of Lean
`Adapter.Doc.spellRules` and `Adapter.Doc.conv`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/pkg/EarthSciAST.jl/src/canonicalize.jl#L645)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function canonicalizeDocument<T>(doc: T): T
```

The document-level canonical step: every units string of a document takes
the canonical unit spelling (esm-spec §4.8.2, Lean `Esm.Units.canon`).

That is every `units` and `default_units` string of a variable, species,
parameter, coordinate or `const` node, wherever it sits: nested subsystems,
template bodies, tests, coupling entries. Free-form objects (`metadata`,
`x_esd`, `attrs`, `config`, `reader_options`) are not respelled, and neither
are the keys of name-keyed maps. A `const` node whose units spell `1` loses
them: a scalar one becomes the bare literal, an array one a `const` without
`units`. The deprecated ops are rewritten (esm-spec §4.2): a `neg` node with
one argument becomes unary `-`, a `pow` node with two becomes `^`, and a
`broadcast` of `neg` with one argument maps `-`. Every number, free-form
objects included, takes its canonical form (CONFORMANCE §5.5.3.1): a
`NumericLiteral` or `bigint` whose value is integral and in Int64 is an
integer (`2.0` is `2`): an int literal, or past 2^53 a `bigint` of the exact
integer; any other is a float literal, and `-0` is `0`; a plain number
already holds the nearest binary64 of its token. Takes the decoded JSON
document (an `EsmFile` is one; plain numbers, or the tagged literals and
bigints of `losslessJsonParse`); the input is not mutated and nothing else
changes.
These are the rules of Lean `Adapter.Doc.spellRules` and `Adapter.Doc.conv`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/pkg/earthsci-ast-ts/src/canonicalize.ts#L619)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
canonicalize_document(doc: Any) -> Any
```

The document-level canonical step (esm-spec §4.8.2): every units string of a
decoded document (the JSON object `to_json` writes and `load_document` reads)
takes the canonical unit spelling (Lean `Esm.Units.canon`).

That is every `units` and `default_units` string of a variable,
species, parameter, coordinate or `const` node, wherever it sits:
nested subsystems, template bodies, tests, coupling entries. Free-form
objects (`metadata`, `x_esd`, `attrs`, `config`,
`reader_options`) are not respelled, and neither are the keys of
name-keyed maps. A `const` node whose units spell `1` loses them: a
scalar one becomes the bare literal, an array one a `const` without
`units`. The deprecated ops are rewritten (esm-spec §4.2): a `neg` node
with one argument becomes unary `-`, a `pow` node with two becomes
`^`, and a `broadcast` of `neg` with one argument maps `-`. Every
number, free-form objects included, takes its canonical form (CONFORMANCE
§5.5.3.1): an integral value in Int64 is an integer (`2.0` is `2`).
The input is not mutated; nothing else changes. These are the rules of
Lean `Adapter.Doc.spellRules` and `Adapter.Doc.conv`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/pkg/earthsci-ast-py/src/earthsci_ast/canonicalize.py#L606)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn canonicalize_document(doc: &Value) -> Value
```

The document-level canonical step: every units string of a decoded document
(the JSON value `to_json` writes and `load_document` reads) takes the
canonical unit spelling (esm-spec §4.8.2, Lean `Esm.Units.canon`).

That is every `units` and `default_units` string of a variable, species,
parameter, coordinate or `const` node, wherever it sits: nested subsystems,
template bodies, tests, coupling entries. Free-form objects (`metadata`,
`x_esd`, `attrs`, `config`, `reader_options`) are not respelled, and neither
are the keys of name-keyed maps. A `const` node whose units spell `1` loses
them: a scalar one becomes the bare literal, an array one a `const` without
`units`. The deprecated operators are rewritten (esm-spec §4.2): a `neg`
node with one argument becomes unary `-`, a `pow` node with two becomes `^`,
and a `broadcast` of `neg` with one argument maps `-`. Every number,
free-form objects included, takes its canonical form (CONFORMANCE
§5.5.3.1): an integral value in `Int64` is an integer (`0.0` is `0`). Nothing
else changes. These are the rules of Lean `Adapter.Doc.spellRules` (the
spelling rules) and `Adapter.Doc.conv` (the numbers).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/pkg/earthsci-ast-rs/src/canonicalize.rs#L929) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.canonicalize_document.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func CanonicalizeDocument(doc any) any
```

CanonicalizeDocument is the document-level canonical step: every units string of a decoded document (the JSON value ToJSON writes and LoadDocument reads, as produced by encoding/json into `any`) takes the canonical unit spelling (esm-spec §4.8.2, Lean `Esm.Units.canon`).

That is every `units` and `default_units` string of a variable, species, parameter, coordinate or `const` node, wherever it sits: nested subsystems, template bodies, tests, coupling entries. Free-form objects (`metadata`, `x_esd`, `attrs`, `config`, `reader_options`) are not respelled, and neither are the keys of name-keyed maps. A `const` node whose units spell `1` loses them: a scalar one becomes the bare literal, an array one a `const` without `units`. The deprecated ops are rewritten (esm-spec §4.2): a `neg` node with one argument becomes unary `-`, a `pow` node with two becomes `^`, and a `broadcast` of `neg` with one argument maps `-`. Every number, free-form objects included, takes its canonical form (CONFORMANCE §5.5.3.1): an integral value in Int64 is an int64 (`2.0` is `2`, `-0.0` is `0`), any other finite value a float64. A json.Number (a decoder with UseNumber) that is an integer token in Int64 is that int64 exactly, past 2^53 too; any other token is read as the nearest float64 (one below the smallest subnormal is 0); a token beyond the binary64 range (`1e400`) has no nearest float64 and is kept as written. The input is not mutated and nothing else changes. These are the rules of Lean `Adapter.Doc.spellRules` and `Adapter.Doc.conv`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/ffd5aee2f868adb510050bd5d203a6fdc4b9749b/pkg/earthsci-ast-go/pkg/esm/canonicalize_document.go#L56) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CanonicalizeDocument)

</div>

</div>
