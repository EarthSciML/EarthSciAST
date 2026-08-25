---
title: "Operators"
description: "The expression vocabulary: what each operator does, its arguments, and its result."
---

An expression is one of four things:

| Form | JSON | Meaning |
|---|---|---|
| Number | `2`, `1.5e-9` | A literal. Integer and float tokens are distinguished. |
| Variable | `"O3"` | A reference to a variable, parameter, species, or index. |
| Operator node | `{"op": …, "args": […]}` | An application. |
| Scoped reference | `"Chem.O3"` | A dotted path into a subsystem. |

An operator node always has `op` and `args`. Some operators take extra named
fields — `wrt` on `D`, `output_idx`/`ranges` on `aggregate`, `regions`/`values`
on `makearray` — which are listed on each operator's page.

**Text**
```text
k * A * B
```
**JSON**
```json
{ "op": "*", "args": ["k", "A", "B"] }
```

## Two tiers

**Evaluable core (closed).** The operators in the index below have a defined
evaluator in every binding. The set is closed: adding one is a specification
change. That closure is what lets a conforming reader in any language evaluate
any document without executing author-supplied code.

**Rewrite-target (open).** `grad`, `div`, `laplacian`, `integral`, a `D` with a
spatial `wrt`, and any operator you invent have **no evaluator**. They must be
eliminated by a [template rewrite](../templates/) before evaluation. A document
may *load* with them present; one that reaches evaluation still carrying them is
rejected with `unlowered_operator`.

A rewrite-target operator gets no privileges: its result dimension is unknown
until it is lowered, and no binding may special-case its name. A custom op
carries its scheme parameters in `attrs` rather than in dedicated fields.

## Text form

Every example on these pages is one expression shown two ways: a block labelled
**Text**, the notation an author writes, followed by a block labelled **JSON**,
the node it denotes. They are not two different examples, and they are not
independent — each pair is checked with the shipped `parse_expression` and
`to_ascii`, which are inverses, so the text parses to exactly the JSON shown and
the JSON prints back to exactly the text.

Multiplication is always explicit (`k * A`, never `kA`), because identifiers are
multi-letter.

A **JSON block with no Text partner** is a form the text notation cannot spell
today. `broadcast` and `enum` have no surface of their own — the first prints as
the operator it applies, the second as a dotted name that re-parses as a scoped
variable reference. `neg` shares the surface of unary `-`. And a few forms lose
a field on the way out: a `D` carrying trailing boundary operands, a `grad`
carrying `dim`, and an `overlap` join. Whole `.esm` documents are shown as JSON
throughout; the text notation covers expressions and equations, not files.

## Index

| Op | Arity | Reference |
|---|---|---|
| `+` | n-ary | [arithmetic, comparison, logic](arithmetic-comparison-logic/) |
| `-` | 1 or 2 | [arithmetic, comparison, logic](arithmetic-comparison-logic/) |
| `*` | n-ary | [arithmetic, comparison, logic](arithmetic-comparison-logic/) |
| `/` | 2 | [arithmetic, comparison, logic](arithmetic-comparison-logic/) |
| `^` | 2 | [arithmetic, comparison, logic](arithmetic-comparison-logic/) |
| `neg` | 1 | [arithmetic, comparison, logic](arithmetic-comparison-logic/) |
| `==` `!=` `<` `<=` `>` `>=` | 2 | [arithmetic, comparison, logic](arithmetic-comparison-logic/) |
| `and` `or` | 2+ | [arithmetic, comparison, logic](arithmetic-comparison-logic/) |
| `not` | 1 | [arithmetic, comparison, logic](arithmetic-comparison-logic/) |
| `exp` `log` `log10` `sqrt` | 1 | [elementary functions](elementary-functions/) |
| `abs` `sign` `floor` `ceil` | 1 | [elementary functions](elementary-functions/) |
| `sin` `cos` `tan` `asin` `acos` | 1 | [elementary functions](elementary-functions/) |
| `atan` | 1 or 2 | [elementary functions](elementary-functions/) |
| `atan2` | 2 | [elementary functions](elementary-functions/) |
| `sinh` `cosh` `tanh` `asinh` `acosh` `atanh` | 1 | [elementary functions](elementary-functions/) |
| `min` `max` | 2+ | [elementary functions](elementary-functions/) |
| `ifelse` | 3 | [constants and conditionals](constants-and-conditionals/) |
| `Pre` | 1 | [constants and conditionals](constants-and-conditionals/) |
| `const` | 0 (`value` field) | [constants and conditionals](constants-and-conditionals/) |
| `true` | 0 | [constants and conditionals](constants-and-conditionals/) |
| `enum` | 2 string literals | [constants and conditionals](constants-and-conditionals/) |
| `D` | 1 (structural) | [calculus](calculus/) |
| `ic` | 1 | [calculus](calculus/) |
| `index` | 1+ | [arrays](arrays/) |
| `makearray` | 0 (`regions`/`values`) | [arrays](arrays/) |
| `broadcast` | 1+ (`fn` field) | [arrays](arrays/) |
| `reshape` `transpose` | 1 | [arrays](arrays/) |
| `concat` | 1+ | [arrays](arrays/) |
| `aggregate` | structural | [aggregation](aggregation/) |
| `argmin` `argmax` | structural | [aggregation](aggregation/) |
| `skolem` | n-ary | [aggregation](aggregation/) |
| `rank` | 1 | [aggregation](aggregation/) |
| `intersect_polygon` | 2 | [geometry](geometry/) |
| `polygon_intersection_area` | 2 | [geometry](geometry/) |
| `fn` | n-ary (`name` field) | [closed functions](closed-functions/) |
| `table_lookup` | 0 (`table`/`axes`) | [closed functions](closed-functions/) |
| `apply_expression_template` | structural (`bindings`) | [expression templates](../templates/) |

Arity `structural` means the operator's operands live in dedicated fields rather
than in `args`, and are described on its own page.

Rewrite-target sugar — `grad`, `div`, `laplacian`, `integral`, and a spatial
`D` — is covered on the [calculus](calculus/) page. It is *not* part of the set
above.

## Dimensional rules

Dimensional analysis follows the operator, and findings are **warnings**: a
dimensional problem never makes a document invalid.

| Class | Operators | Rule |
|---|---|---|
| transcendental | `exp`, `log`, `log10`, `sinh`, `cosh`, `tanh`, `asinh`, `acosh`, `atanh` | argument must be dimensionless; result dimensionless |
| circular | `sin`, `cos`, `tan` | argument must be an angle; result dimensionless |
| inverse circular | `asin`, `acos`, `atan`, `atan2` | argument dimensionless; result an angle |
| comparison | `<`, `<=`, `>`, `>=`, `==`, `!=` | operands must share a dimension; result dimensionless |
| boolean | `and`, `or`, `not` | operands dimensionless; result dimensionless |

Everything else either propagates its operands' dimension (`+`, `-`, `min`,
`max`, `ifelse`) or combines them (`*`, `/`, `^`). A rewrite-target operator has
no rule, so a checker reports `unknown` and skips the enclosing check.
