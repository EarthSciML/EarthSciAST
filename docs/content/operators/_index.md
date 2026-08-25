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
fields — `wrt` on `D`, `dim` on axis-oriented ops, `output_idx`/`ranges` on
`aggregate` — which are listed on each operator's page.

```json
{ "op": "*", "args": ["k", "A", "B"] }
```

means `k·A·B`.

## Two tiers

**Evaluable core (closed).** Every operator documented on these pages, except
the sugar noted below, has a defined evaluator in every binding. The set is
closed: adding one is a specification change. That closure is what lets a
conforming reader in any language evaluate any document without executing
author-supplied code.

**Rewrite-target (open).** `grad`, `div`, `laplacian`, `integral`, a `D` with a
spatial `wrt`, and any operator you invent have **no evaluator**. They must be
eliminated by a [template rewrite](../templates/) before evaluation. A document
may *load* with them present; one that reaches evaluation still carrying them is
rejected with `unlowered_operator`.

A rewrite-target operator gets no privileges: its result dimension is unknown
until it is lowered, and no binding may special-case its name.

## Index

| Op | Arity | Family | Reference |
|---|---|---|---|
| `aggregate` | varies | aggregate | [aggregation](aggregation/) |
| `arrayop` | varies | aggregate | [aggregation](aggregation/) |
| `*` | 1+ | arithmetic | [arithmetic comparison logic](arithmetic-comparison-logic/) |
| `+` | 1+ | arithmetic | [arithmetic comparison logic](arithmetic-comparison-logic/) |
| `-` | 1–2 | arithmetic | [arithmetic comparison logic](arithmetic-comparison-logic/) |
| `/` | 2 | arithmetic | [arithmetic comparison logic](arithmetic-comparison-logic/) |
| `^` | 2 | arithmetic | [arithmetic comparison logic](arithmetic-comparison-logic/) |
| `neg` | 1 | arithmetic | [arithmetic comparison logic](arithmetic-comparison-logic/) |
| `pow` | 2 | arithmetic | [arithmetic comparison logic](arithmetic-comparison-logic/) |
| `broadcast` | varies | array | [arrays](arrays/) |
| `concat` | varies | array | [arrays](arrays/) |
| `index` | varies | array | [arrays](arrays/) |
| `makearray` | varies | array | [arrays](arrays/) |
| `reshape` | varies | array | [arrays](arrays/) |
| `transpose` | varies | array | [arrays](arrays/) |
| `D` | 1+ | calculus | [calculus](calculus/) |
| `div` | varies | calculus | [calculus](calculus/) |
| `grad` | varies | calculus | [calculus](calculus/) |
| `ic` | varies | calculus | [calculus](calculus/) |
| `laplacian` | varies | calculus | [calculus](calculus/) |
| `!=` | 2 | comparison | [arithmetic comparison logic](arithmetic-comparison-logic/) |
| `<` | 2 | comparison | [arithmetic comparison logic](arithmetic-comparison-logic/) |
| `<=` | 2 | comparison | [arithmetic comparison logic](arithmetic-comparison-logic/) |
| `==` | 2 | comparison | [arithmetic comparison logic](arithmetic-comparison-logic/) |
| `>` | 2 | comparison | [arithmetic comparison logic](arithmetic-comparison-logic/) |
| `>=` | 2 | comparison | [arithmetic comparison logic](arithmetic-comparison-logic/) |
| `e` | 0 | constant | [constants and conditionals](constants-and-conditionals/) |
| `false` | 0 | constant | [constants and conditionals](constants-and-conditionals/) |
| `pi` | 0 | constant | [constants and conditionals](constants-and-conditionals/) |
| `true` | 0 | constant | [constants and conditionals](constants-and-conditionals/) |
| `π` | 0 | constant | [constants and conditionals](constants-and-conditionals/) |
| `Pre` | 1 | control | [constants and conditionals](constants-and-conditionals/) |
| `ifelse` | 3 | control | [constants and conditionals](constants-and-conditionals/) |
| `const` | varies | data | [closed functions](closed-functions/) |
| `enum` | varies | data | [closed functions](closed-functions/) |
| `abs` | 1 | elementary | [elementary functions](elementary-functions/) |
| `acos` | 1 | elementary | [elementary functions](elementary-functions/) |
| `acosh` | 1 | elementary | [elementary functions](elementary-functions/) |
| `asin` | 1 | elementary | [elementary functions](elementary-functions/) |
| `asinh` | 1 | elementary | [elementary functions](elementary-functions/) |
| `atan` | 1–2 | elementary | [elementary functions](elementary-functions/) |
| `atan2` | 2 | elementary | [elementary functions](elementary-functions/) |
| `atanh` | 1 | elementary | [elementary functions](elementary-functions/) |
| `ceil` | 1 | elementary | [elementary functions](elementary-functions/) |
| `cos` | 1 | elementary | [elementary functions](elementary-functions/) |
| `cosh` | 1 | elementary | [elementary functions](elementary-functions/) |
| `exp` | 1 | elementary | [elementary functions](elementary-functions/) |
| `floor` | 1 | elementary | [elementary functions](elementary-functions/) |
| `log` | 1 | elementary | [elementary functions](elementary-functions/) |
| `log10` | 1 | elementary | [elementary functions](elementary-functions/) |
| `max` | 2+ | elementary | [elementary functions](elementary-functions/) |
| `min` | 2+ | elementary | [elementary functions](elementary-functions/) |
| `sign` | 1 | elementary | [elementary functions](elementary-functions/) |
| `sin` | 1 | elementary | [elementary functions](elementary-functions/) |
| `sinh` | 1 | elementary | [elementary functions](elementary-functions/) |
| `sqrt` | 1 | elementary | [elementary functions](elementary-functions/) |
| `tan` | 1 | elementary | [elementary functions](elementary-functions/) |
| `tanh` | 1 | elementary | [elementary functions](elementary-functions/) |
| `call` | varies | function | [closed functions](closed-functions/) |
| `fn` | varies | function | [closed functions](closed-functions/) |
| `intersect_polygon` | varies | geometry | [geometry](geometry/) |
| `polygon_intersection_area` | varies | geometry | [geometry](geometry/) |
| `and` | 2+ | logical | [arithmetic comparison logic](arithmetic-comparison-logic/) |
| `not` | 1 | logical | [arithmetic comparison logic](arithmetic-comparison-logic/) |
| `or` | 2+ | logical | [arithmetic comparison logic](arithmetic-comparison-logic/) |
| `skolem` | varies | value invention | [aggregation](aggregation/) |
Arity `varies` means the operator's argument convention is structural and
described on its own page rather than being a simple count.

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
