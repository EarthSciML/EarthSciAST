---
title: "expr_node"
description: "Stable type · Expressions"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Expressions](/generated/api/topics/expressions)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | not exported | `ExprNode` | not exported | `ExprNode` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this type.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this type.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class ExprNode
ExprNode(op: str, args: list[Expr] = list(), wrt: str | None = None, dim: str | None = None, var: str | None = None, lower: Expr | None = None, upper: Expr | None = None, output_idx: list[str | int] | None = None, expr: Expr | None = None, reduce: str | None = None, semiring: str | None = None, ranges: dict[str, list[int] | dict[str, Any]] | None = None, join: list[dict[str, Any]] | None = None, filter: Expr | None = None, distinct: bool | None = None, key: Expr | None = None, arg: str | None = None, label: str | None = None, regions: list[list[list[int]]] | None = None, values: list[Expr] | None = None, shape: list[int | str] | None = None, perm: list[int] | None = None, axis: int | None = None, fn: str | None = None, id: str | None = None, expect_cadence: str | None = None, attrs: dict[str, Any] | None = None, manifold: str | None = None, handler_id: str | None = None, name: str | None = None, value: Any | None = None, units: str | None = None, table: str | None = None, table_axes: dict[str, Expr] | None = None, output: int | str | None = None)
```

A node in an expression tree.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/esm_types.py#L19)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/python/documents.py#L111-L138">docs/api/examples/python/documents.py</a></p>

**Example** (`expressions`)

```python
# An expression is a number, a variable name, or an operator node.
exchange = ExprNode(op="*", args=["k", ExprNode(op="-", args=["T_wall", "T_air"])])
assert earthsci_ast.free_variables(exchange) == {"k", "T_wall", "T_air"}

# Text parses to the same tree that to_ascii prints.
parsed = earthsci_ast.parse_expression("k * (T_wall - T_air)")
assert earthsci_ast.to_ascii(parsed) == earthsci_ast.to_ascii(exchange)

# Substitution replaces names with numbers or with other expressions.
fixed = earthsci_ast.substitute(exchange, {"k": 0.05, "T_wall": ExprNode(op="+", args=["T0", 10])})
assert earthsci_ast.to_ascii(fixed) == "0.05 * (T0 + 10 - T_air)"
assert earthsci_ast.free_variables(fixed) == {"T0", "T_air"}
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/python/expressions.py#L8-L19">docs/api/examples/python/expressions.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this type.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type ExprNode struct {
	Op    string  `json:"op"`
	Args  []any   `json:"args"`
	Wrt   *string `json:"wrt,omitempty"`   // for derivatives
	Dim   *string `json:"dim,omitempty"`   // for grad
	Fn    *string `json:"fn,omitempty"`    // for bc wrapper kind encoding
	Var   *string `json:"var,omitempty"`   // integration variable name (for integral)
	Lower any     `json:"lower,omitempty"` // lower integration bound (for integral)
	Upper any     `json:"upper,omitempty"` // upper integration bound (for integral)
	// Name carries the dotted module path of a closed-registry function
	// (esm-spec §4.4 / §9.2) for `fn` op nodes — e.g. "datetime.julian_day".
	Name *string `json:"name,omitempty"`
	// Value carries the inline literal payload of a `const` op node
	// (esm-spec §4.2 / §9.3); `Args` MUST be empty for a const node. Any
	// JSON value (number, integer, or nested array thereof).
	Value any `json:"value,omitempty"`
	// Units is the declared unit of a `const` node's Value (esm-spec §4.8.5,
	// esm 1.2.0): a unit-bearing constant has that dimension and exact scale in
	// dimensional analysis. Legal on no other op.
	Units *string `json:"units,omitempty"`
	// Table is the function_tables entry id targeted by a `table_lookup` op
	// (esm-spec §9.5).
	Table *string `json:"table,omitempty"`
	// TableAxes is the per-axis input-coordinate expression map for a
	// `table_lookup` op. Keys MUST match the names declared on the referenced
	// FunctionTable's Axes; values are arbitrary scalar Expressions. Args MUST
	// be empty for a table_lookup node.
	TableAxes map[string]Expression `json:"axes,omitempty"`
	// Output selects which output of a multi-output table to return for a
	// `table_lookup` op. Either a non-negative integer (0-based index into the
	// leading data dimension) or a string (an entry of the table's Outputs
	// list). Single-output tables MAY omit this (defaults to 0).
	Output any `json:"output,omitempty"`
	// Attrs carries optional named scalar attributes for an OPEN rewrite-target
	// op (esm-spec §4.2). Mirrors the fixed `dim`/`side`/`wrt` slots the core ops
	// use, but is open: a custom op (e.g. `godunov_hamiltonian`) carries its
	// scheme parameters here. Modeled so a rewrite-target op that survives
	// lowering (loading is permissive) round-trips. Evaluable-core ops MUST NOT
	// use `attrs`. Structural `match` rules bind `attrs.<key>` params to matched
	// literals via generic object matching (esm-spec §9.6.1).
	Attrs map[string]any `json:"attrs,omitempty"`

	// Bindings is the param→expression map of an `apply_expression_template` op.
	Bindings map[string]any `json:"bindings,omitempty"`
	// Regions is the list of hyper-rectangular index regions of a `makearray`
	// op; each region is a list of [lo, hi] bound pairs.
	Regions [][][]any `json:"regions,omitempty"`
	// Values is the per-region value list of a `makearray` op (paired with
	// Regions by position).
	Values []any `json:"values,omitempty"`
	// Shape is the target shape of a `reshape` op.
	Shape []any `json:"shape,omitempty"`
	// Perm is the optional permutation of a `transpose` op.
	Perm []any `json:"perm,omitempty"`
	// Axis is the concatenation axis of a `concat` op.
	Axis any `json:"axis,omitempty"`
	// Manifold is the geometry manifold of `intersect_polygon` /
	// `polygon_intersection_area` ops.
	Manifold *string `json:"manifold,omitempty"`
	// OutputIdx are the surviving (free) index names of a `faq` op.
	// `esm:"keepempty"`: esm-schema.json REQUIRES `output_idx` on every
	// aggregate, so an allocated-but-empty list (a full reduction, `sum[] (…)`)
	// must still serialize as `[]` rather than vanishing.
	OutputIdx []any `json:"output_idx,omitempty" esm:"keepempty"`
	// Expr is the reduced sub-expression of a `faq` / `argmin` / `argmax`
	// op.
	Expr any `json:"expr,omitempty"`
	// Reduce is the scalar reduction operator of a `faq` op.
	Reduce *string `json:"reduce,omitempty"`
	// Semiring is the optional named semiring of a `faq` op.
	Semiring *string `json:"semiring,omitempty"`
	// Ranges maps a bound index name to its iteration range for `faq` /
	// `argmin` / `argmax` ops. `esm:"keepempty"`: an allocated-but-empty map (an
	// aggregate authored with no `where` clause) serializes as `{}`, matching
	// the other language bindings; a nil map is still omitted.
	Ranges map[string]any `json:"ranges,omitempty" esm:"keepempty"`
	// Join is the optional list of join clauses of a `faq` op.
	Join []any `json:"join,omitempty"`
	// Filter is the optional predicate of a `faq` op.
	Filter any `json:"filter,omitempty"`
	// Distinct marks a `faq` op as reducing over distinct values.
	Distinct *bool `json:"distinct,omitempty"`
	// Key is the optional grouping key of a `faq` op.
	Key any `json:"key,omitempty"`
	// Label is the optional documentary relation tag of a `skolem` op
	// (esm-spec §4.2; e.g. "edge", "bin", "pair"). Purely documentary — it does
	// NOT affect the emitted key; the key components are the node's Args. Modeled
	// so a label-bearing skolem node round-trips.
	Label *string `json:"label,omitempty"`
	// Arg is the witness index name of an `argmin` / `argmax` op.
	Arg *string `json:"arg,omitempty"`
	// ID is the schema-declared `id` of an ExpressionNode: the stable handle a
	// derived index set names in `index_sets.<x>.from_faq`. Dropping it on a
	// round-trip silently breaks that linkage, so it is modeled explicitly.
	ID *string `json:"id,omitempty"`
	// ExpectCadence is the schema-declared `expect_cadence` of an ExpressionNode
	// ("const" / "temporal" / …): the author's assertion about how often the
	// subtree's value may change. Carried so it round-trips.
	ExpectCadence *string `json:"expect_cadence,omitempty"`
}
```

ExprNode represents an operator node in the expression tree

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/types.go#L14) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ExprNode)

</div>

</div>
