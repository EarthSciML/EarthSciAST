# Interpolation templates (`interp_templates`)

`lib/interp.esm` is a template-library file (esm-spec §9.7.1) carrying the
pure-AST interpolation (what the three 1.x `interp.*` closed functions
computed) as match-less
expression templates: `searchsorted(x, xs, n)`, `linear(table, axis, x, n)` and
`bilinear(table, axis_x, axis_y, x, y, nx, ny)`. Each finds its cell by a `faq`
comparison count over `k` in `[1, n]`, the axis length being an integer template
parameter used as a `ranges` bound (esm-spec §9.6.1), and evaluates in the order
esm-spec 1.x §9.2 pinned for the matching function. This tier checks, in every binding
with an inline-test runner and under every compiler, that the expanded template
reproduces the pinned `binary64` reference values of `tests/closed_functions`.

## The fixtures

The documents live beside the scenarios they apply, and the manifest references
them:

| Fixture | Document | Scenarios |
|---|---|---|
| `searchsorted_template` | `tests/closed_functions/interp/searchsorted/template.esm` | 10: clamp below, clamp above (n + 1), interior entry, between entries, last entry, one-entry axis, a run of equal entries (on it and just below it), equal neighbours elsewhere, an empty axis (n = 0) |
| `linear_template` | `tests/closed_functions/interp/linear/template.esm` | 10: clamp below and above, first, interior and last knot, blends in the first and an interior cell, a two-knot table, a non-uniform axis, negative values |
| `bilinear_template` | `tests/closed_functions/interp/bilinear/template.esm` | 11: clamp below and above on both axes, the last corner, an interior knot on both axes, knot in one axis with a blend in the other (both ways), blends in both, clamp on one axis only (both ways), a 2 x 2 table, a non-uniform axis |

Each scenario is one algebraic unknown `r_<scenario>` defined by an
`apply_expression_template` call: the arrays are `const` nodes, each axis length
an integer, and the query a parameter `x_<scenario>` (and `y_<scenario>`) whose
default is the scenario's input. The model's `tolerance` is `{abs: 0, rel: 0}`,
so each assertion passes only on the exact value of `expected.json`. The golden
is the Julia interpreter's.

## What is not here

- The NaN-query scenarios: JSON cannot write a NaN default. The per-binding
  harnesses that ran them through the expanded template compared it with the
  `fn` form and were deleted with it at esm 2.0.0; Go still checks the
  expansion of every scenario.
- The `error_scenarios`: the templates do not repeat the load-time axis checks
  the removed `fn` form made, so a malformed axis has no template counterpart.
- That a template parameter in a `ranges` tuple is substituted at all:
  `tests/conformance/expression_templates/ranges_param/` pins that expansion
  structurally in all five bindings, Go and TypeScript included.

## Named exclusions

None. Go and TypeScript are scope-excluded: neither has an inline-test runner.
