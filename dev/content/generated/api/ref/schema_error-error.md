---
title: "schema_error (error)"
description: "Stable error · Validation"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** error · **Topic:** [Validation](/generated/api/topics/validation)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | not exported | not exported | `SchemaError` | `SchemaError` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this error.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this error.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

<p class="api-absent">Python does not export this error.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct SchemaError {
    pub path: String,
    pub message: String,
    pub keyword: String,
}
```

A schema validation error

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/validate.rs#L96) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.SchemaError.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type SchemaError struct {
	Path    string `json:"path"`    // RFC 6901 JSON Pointer to the offending location (as reported by the schema validator)
	Message string `json:"message"` // Human-readable description
	Keyword string `json:"keyword"` // JSON Schema keyword that failed
}
```

SchemaError represents a JSON Schema violation

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/validate.go#L11) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#SchemaError)

</div>

</div>
