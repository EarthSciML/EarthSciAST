---
title: "validation_warning"
description: "Stable type · Other"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Other](/generated/api/topics/other)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `ValidationWarning` | `ValidationWarning` | `ValidationWarning` | `ValidationWarning` | `ValidationWarning` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct ValidationWarning
ValidationWarning(code::String, path::String, message::String)
ValidationWarning(code, path, message)
```

```julia
ValidationWarning
```

An advisory validation finding that is not about units: a stable diagnostic
`code`, the JSON `path` it concerns and a `message`. It never changes
`is_valid`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/validation/records.jl#L116)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
interface ValidationWarning {
    code: string;
    path: string;
    message: string;
}
```

An advisory validation finding that is not about units. It never changes
`is_valid`.

**Properties**

- `code` — Stable diagnostic code.
- `path` — JSON pointer to the finding.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/earthsci-ast-ts/src/validate/types.ts#L36)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class ValidationWarning
ValidationWarning(code: str, path: str, message: str)
```

An advisory validation finding that is not about units: a stable
diagnostic `code`, the JSON `path` it concerns and a `message`.
It never changes `is_valid`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/earthsci-ast-py/src/earthsci_ast/validation.py#L125)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct ValidationWarning {
    pub code: String,
    pub path: String,
    pub message: String,
}
```

An advisory validation finding.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/earthsci-ast-rs/src/validate.rs#L76) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.ValidationWarning.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type ValidationWarning struct {
	Code    string `json:"code"`    // Stable diagnostic code
	Path    string `json:"path"`    // RFC 6901 JSON Pointer to the finding
	Message string `json:"message"` // Human-readable description
}
```

ValidationWarning is an advisory validation finding that is not about units. It never changes IsValid.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/earthsci-ast-go/pkg/esm/validate.go#L87) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ValidationWarning)

</div>

</div>
