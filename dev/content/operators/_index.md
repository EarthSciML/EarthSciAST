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
fields — `wrt` on `D`, `output_idx`/`ranges` on `faq`, `regions`/`values`
on `makearray` — which are listed on each operator's page.

**LaTeX**
```latex
k A B
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

**Rewrite-target (open).** `integral`, a `D` with a spatial `wrt`, and any
operator you invent have **no evaluator**. They must be
eliminated by a [template rewrite](../templates/) before evaluation. A document
may *load* with them present; one that reaches evaluation still carrying them is
rejected with `unlowered_operator`.

A rewrite-target operator gets no privileges: its result dimension is unknown
until it is lowered, and no binding may special-case its name. A custom op
carries its scheme parameters in `attrs` rather than in dedicated fields.

## Document math

Most examples on these pages are one expression shown two ways: a block
labelled **LaTeX**, the math an ESM Markdown document writes for it (the
content of a `$$` display), followed by a block labelled **JSON**, the node it
denotes. They are not two different examples: the LaTeX is what
`print_math(json, expression_names(json), markdown)` prints for the JSON, and
`parse_math` reads it back to exactly that JSON (a top-level `=` reads back as
an equation's two sides). The pairs were produced by the printer, and nothing
checks them automatically afterwards; the JSON is the definition. A Typst
document writes the same expression in Typst math (`print_math` with format
`typst`).

A name of more than one letter is read only when the component declares it, so
juxtaposition is multiplication (`k A B`), and a multi-letter name prints
italic (`\mathit{lat}`) or with an upright subscript (`x_{\mathrm{min}}`).

Array nodes have notation too. A `makearray` is a bracketed table, each row a
value and the region it fills,
`\left[\begin{array}{l|l} v_{1} & [2, N - 1] \\ v_{2} & [1, 1] \times [2, N] \end{array}\right]`
(Typst `mat(delim: "[", augment: #1, …)`). The shape operators `broadcast`,
`reshape`, `transpose` and `concat`, and a `faq` with a non-default semiring or a
`join`, are written in the call form with their fields as named arguments,
`\operatorname{reshape}(A; \mathrm{shape} = [2, 3])`. Only a node that carries an
`id` or `expect_cadence`, or has a field whose key is not an identifier, is still
written in the generic `\esm{op}{fields}{args}` form (Typst `esm.node(…)`), which
carries the node's fields as JSON and which KaTeX does not render; such a page shows
the JSON alone. Whole `.esm` documents are shown as JSON throughout.

## Index

| Op | Arity | Reference |
|---|---|---|
| `+` | n-ary | [arithmetic, comparison, logic](arithmetic-comparison-logic/) |
| `-` | 1 or 2 | [arithmetic, comparison, logic](arithmetic-comparison-logic/) |
| `*` | n-ary | [arithmetic, comparison, logic](arithmetic-comparison-logic/) |
| `/` | 2 | [arithmetic, comparison, logic](arithmetic-comparison-logic/) |
| `^` | 2 | [arithmetic, comparison, logic](arithmetic-comparison-logic/) |
| `neg` (deprecated) | 1 | [arithmetic, comparison, logic](arithmetic-comparison-logic/) |
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
| `faq` | structural | [aggregation](aggregation/) |
| `apply_expression_template` | structural (`bindings`) | [expression templates](../templates/) |

Arity `structural` means the operator's operands live in dedicated fields rather
than in `args`, and are described on its own page.

The operators esm 2.0.0 removed (`fn`, `table_lookup`, `skolem`, `rank`, the
`argmin`/`argmax` operator forms, the two polygon operators, and `aggregate`, the
old spelling of `faq`) are rejected at load with `removed_op`; [removed operators](closed-functions/) lists the
standard-library template that replaces each, and [geometry](geometry/) covers
polygon overlap areas.

The rewrite targets `integral` and a spatial `D` are covered on the
[calculus](calculus/) page. They are *not* part of the set above.

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
