---
title: "metadata"
description: "Stable type · Document types"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Document types](/generated/api/topics/document-types)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `Metadata` | not exported | `Metadata` | `Metadata` | `Metadata` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct Metadata
Metadata(name::String; description, authors, license, created, modified, tags, references, system_class, dae_info, discretized_from, x_esd)
```

```julia
Metadata
```

Authorship, provenance, and description metadata.

Carries every property esm-schema.json's `Metadata` defines — it too sets
`additionalProperties: false`, so the list is closed. Beyond the authorship
block that is the three discretization diagnostics (`system_class`, `dae_info`,
`discretized_from`; RFC §12) and `x_esd`.

`x_esd`'s schema description is NORMATIVE about this struct's job: it is a
reserved extension point whose contents "core tooling MUST NOT assign meaning
to" and "MUST preserve … across parse → emit like any other metadata field".
All four are therefore kept VERBATIM and never interpreted.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/types.jl#L2277)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this type.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class Metadata
Metadata(title: str, description: str | None = None, authors: list[str] = list(), created: str | None = None, modified: str | None = None, version: str = '1.0', references: list[Reference] = list(), keywords: list[str] = list(), custom: dict[str, Any] = dict(), license: str | None = None, system_class: str | None = None, dae_info: dict[str, Any] | None = None, discretized_from: dict[str, Any] | None = None, x_esd: dict[str, Any] | None = None)
Metadata.name: str  # property
```

Metadata about the model or dataset.

**Members**

- `name` — Alias for title field (matches JSON 'name' key).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/esm_types.py#L1263)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct Metadata {
    pub name: Option<String>,
    pub description: Option<String>,
    pub authors: Option<Vec<String>>,
    pub license: Option<String>,
    pub created: Option<String>,
    pub modified: Option<String>,
    pub tags: Option<Vec<String>>,
    pub references: Option<Vec<Reference>>,
    pub system_class: Option<String>,
    pub dae_info: Option<DaeInfo>,
    pub discretized_from: Option<DiscretizedFrom>,
    pub x_esd: Option<Value>,
}
```

Metadata section

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/types/document.rs#L290) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.Metadata.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type Metadata struct {
	Name        string  `json:"name"`
	Description *string `json:"description,omitempty"`
	// Authors is OPTIONAL (the schema requires only `name`), so it must be
	// omitted when absent rather than emitted as `"authors": null` — a null fails
	// the schema's `array` type, which made every author-less document
	// UNSERIALIZABLE: it round-tripped into a form the schema rejects. Surfaced by
	// the template-library round-trip (§9.6.4 rule 5), whose fixtures declare no
	// authors.
	Authors    []string    `json:"authors,omitempty"`
	License    *string     `json:"license,omitempty"`
	Created    *string     `json:"created,omitempty"`
	Modified   *string     `json:"modified,omitempty"`
	Tags       []string    `json:"tags,omitempty"`
	References []Reference `json:"references,omitempty"`
	// SystemClass, DAEInfo and DiscretizedFrom are the three diagnostics a
	// `discretize()` pass stamps onto a derived document (esm-schema.json
	// `$defs/Metadata`; discretization RFC §12). They are ordinary metadata as
	// far as this binding is concerned: it neither produces nor reads them, but
	// a document that arrives carrying them must leave carrying them. All three
	// are `omitempty` — every one is optional, and hardly any document (none
	// authored by hand) carries any of them.
	//
	// The two object-valued ones are held as raw JSON rather than typed structs.
	// The schema declares their known properties but does NOT set
	// `additionalProperties: false` on either, so a producer may stamp keys this
	// binding has never heard of — and a typed model would drop exactly those,
	// which is the defect class this modelling exists to close. Raw JSON also
	// keeps their integers spelled as integers; see XESD below.
	SystemClass     *string         `json:"system_class,omitempty"` // "ode" | "dae"
	DAEInfo         json.RawMessage `json:"dae_info,omitempty"`
	DiscretizedFrom json.RawMessage `json:"discretized_from,omitempty"`
	// XESD is the reserved extension point for downstream-catalog metadata
	// (esm-spec §3). Its schema description is NORMATIVE and explicit: the core
	// spec never interprets, validates, or transforms its contents, and "core
	// tooling MUST NOT assign meaning to them and MUST preserve them across
	// parse → emit like any other metadata field."
	//
	// Held as raw JSON — the same device ESMFile.Metaparameters uses — because
	// that is what makes "preserve" literal. A typed model would fix a shape the
	// spec deliberately leaves free, and a `map[string]any` would round every
	// integer in the block through float64 and re-emit `1` as `1.0`;
	// canonicalizeValue passes a json.RawMessage through untouched.
	// `omitempty`: a zero-length RawMessage is an absent key, not a null.
	XESD json.RawMessage `json:"x_esd,omitempty"`
}
```

Metadata represents file metadata

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/types.go#L1057) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#Metadata)

</div>

</div>
