---
title: "structural_error"
description: "Stable error · Validation"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** error · **Topic:** [Validation](/generated/api/topics/validation)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | not exported | not exported | `StructuralError` | `StructuralError` |


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
pub struct StructuralError {
    pub path: String,
    pub code: StructuralErrorCode,
    pub message: String,
    pub details: Value,
}
```

A structural validation error

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/validate.rs#L107) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.StructuralError.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type StructuralError struct {
	// Path is an RFC 6901 JSON Pointer to the offending component
	// ("/models/x/equations/0", "/reaction_systems/x/reactions/0/substrates/1/species"),
	// matching SchemaError.Path and the shared invalid-fixture goldens. The
	// document root is the empty string "".
	Path    string         `json:"path"`
	Code    string         `json:"code"`    // Machine-readable error code
	Message string         `json:"message"` // Human-readable description
	Details map[string]any `json:"details"` // Additional context
	// Level is "warning" for advisory findings that do NOT invalidate the
	// document (e.g. a species listed twice in a reaction), or "" / "error"
	// for hard errors. It is omitempty so hard errors keep their original wire
	// shape; only warnings carry an explicit level.
	Level string `json:"level,omitempty"`
}
```

StructuralError represents equation/unknown balance, reference integrity issues

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/validate.go#L18) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#StructuralError)

</div>

</div>
