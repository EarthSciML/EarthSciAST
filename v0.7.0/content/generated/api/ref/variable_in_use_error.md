---
title: "variable_in_use_error"
description: "Stable error · Editing"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** error · **Topic:** [Editing](/generated/api/topics/editing)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | `VariableInUseError` | not exported | not exported | `VariableInUseError` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this error.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
class VariableInUseError extends EsmDiagnosticError
new VariableInUseError(variableName: string, references: string[]): VariableInUseError
```

Error thrown when attempting to remove a variable that is still referenced

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-ts/src/edit.ts#L31)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

<p class="api-absent">Python does not export this error.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this error.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type VariableInUseError struct {
	EditError
	VariableName string
	References   []string
}
```

VariableInUseError reports an attempt to remove a name that is still referenced. References lists the sites, in discovery order, using the same human-readable labels the TypeScript binding emits. Mirrors TypeScript's `VariableInUseError`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/edit.go#L107) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#VariableInUseError)

</div>

</div>
