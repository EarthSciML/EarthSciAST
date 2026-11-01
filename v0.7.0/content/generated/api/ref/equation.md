---
title: "equation"
description: "Stable type · Document types"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Document types](/generated/api/topics/document-types)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `Equation` | not exported | `Equation` | `Equation` | `Equation` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct Equation
Equation(lhs::ASTExpr, rhs::ASTExpr; _comment)
```

```julia
Equation(lhs::ASTExpr, rhs::ASTExpr; _comment=nothing)
```

Mathematical equation with left-hand side and right-hand side expressions.
Used for differential equations and algebraic constraints.
Optional `_comment` provides a human-readable description.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/types.jl#L697)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this type.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class Equation
Equation(lhs: Expr, rhs: Expr, _comment: str | None = None)
```

Mathematical equation with left and right hand sides.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/esm_types.py#L302)

**Example** (`edit`)

```python
# Edits return a new model in `modified_object`; the input is left unchanged.
edited = earthsci_ast.add_variable(
    model, "N0", ModelVariable(type="parameter", units="mol", default=100.0)
).modified_object
edited = earthsci_ast.add_variable(
    edited, "fraction", ModelVariable(type="unknown", units="1")
).modified_object
step = earthsci_ast.add_equation(
    edited, Equation(lhs="fraction", rhs=ExprNode(op="/", args=["N", "N0"]))
)
assert step.success, step.errors
doc.models["Decay"] = step.modified_object
assert "fraction" not in model.variables  # the original model is untouched

assert earthsci_ast.validate(doc).is_valid
assert earthsci_ast.observed_unknowns(doc.models["Decay"]) == ["fraction", "half_life"]

text = earthsci_ast.to_json(doc)
assert json.loads(text)["models"]["Decay"]["equations"][-1] == {
    "lhs": "fraction",
    "rhs": {"op": "/", "args": ["N", "N0"]},
}

with tempfile.TemporaryDirectory() as tmp:
    out = Path(tmp) / "decay_edited.esm"
    earthsci_ast.write_path(doc, out)
    reread = earthsci_ast.load_path(out)
assert list(reread.models["Decay"].variables) == ["N", "lambda", "half_life", "N0", "fraction"]
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/docs/api/examples/python/documents.py#L111-L138">docs/api/examples/python/documents.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct Equation {
    pub lhs: Expr,
    pub rhs: Expr,
    pub comment: Option<String>,
}
```

Differential equation

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/types/model.rs#L1027) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.Equation.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type Equation struct {
	LHS Expression `json:"lhs"`
	RHS Expression `json:"rhs"`
	// Comment is the schema-sanctioned `_comment` annotation (esm-schema.json
	// `$defs/Equation`): free prose the author attached to THIS equation. The
	// core carries no meaning for it, but it is authored content, so dropping
	// it on parse → emit silently strips every equation annotation from a
	// document edited through this binding. `omitempty`: the key is optional
	// and absent from the overwhelming majority of equations, so emitting a
	// null (or an empty string) for the unannotated case would add noise to
	// every document — and `"_comment": null` fails the schema's `string` type.
	//
	// Rebuilds that construct a NEW Equation from an old one (substitution,
	// namespacing, flattening) must carry it across explicitly; a fresh
	// Equation{LHS, RHS} literal would drop it.
	Comment *string `json:"_comment,omitempty"`
}

func (e *Equation) UnmarshalJSON(data []byte) error
```

Equation represents a mathematical equation with LHS and RHS

**Methods**

```go
func (e *Equation) UnmarshalJSON(data []byte) error
```

Custom JSON unmarshaling for Equation

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/types.go#L127) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#Equation)

</div>

</div>
