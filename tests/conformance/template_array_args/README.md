# Templates applied over array arguments (`template_array_args`)

esm-spec §9.6.11: a template parameter the body reads only as a value (never
as an `index` base, a closed function's table or axis, a geometry ring or any
other operand taken whole) is *scalar-role*. When an `apply_expression_template`
application binds an array to one, the application is elementwise. It is
evaluated once per element of the array, with every array-valued scalar-role
argument read at that element, and each element is bit-identical to the scalar
application there. Only an application is lifted: the same reads written by
hand, with no template at the site, are not. This tier checks that, in every
binding with an inline-test runner and under every compiler, for the
`lib/interp.esm` templates: every element must equal the `interp.*` closed
function at that element's argument, at tolerance 0.

## The fixtures

| Fixture | What it applies |
|---|---|
| `lin1d_shaped` | `linear` on a `[c]` parameter, defining an observed declared over `[c]` |
| `lin1d_unshaped` | the same, defining an observed declared without a shape, which takes `[c]` |
| `lin1d_composite` | `linear` inside larger arithmetic (`a * linear(lev) + lev`), and on an expression argument (`lev * 0.5`) |
| `lin3d` | `linear` on a `[x, y, z]` parameter |
| `lin3d_levcol` | `linear` on a `[z]` level column, alone and multiplied by a `[x, y, z]` field, so the column replicates over `x` and `y` (§4.3.4) |
| `bilin_x_array` | `bilinear` with `x` over `[c]` and `y` a scalar |
| `bilin_both_array` | `bilinear` with `x` and `y` both over `[c]` |
| `bilin_2d_grid` | `bilinear` with `x` and `y` both over `[x, y]`, defining an observed declared over `[x, y]` |
| `searchsorted_array` | `searchsorted` on a `[c]` parameter |

Each fixture is the template form of a document whose `fn` form
(`interp.linear`, …) gave the expected values. Every element of every
application is asserted at `t = 0`. An observed declared without a shape is
asserted through a shaped `<name>_out` that reads it element by element, since
§6.6.5 `coords` need a declared shape. The golden is the Julia interpreter's.
The fixtures are generated from the variant pairs by a script that is not
committed. The expected values were read from the Python binding's `fn` form
under `native`, and Julia and Rust give the same bits wherever their `fn` form
runs.

## The coupled case

`coupled/template.esm` is the case §9.6.11 was written
for (its `interp.*` twin was removed with the `fn` op at esm 2.0.0). A 0-D physics component `Phys` declares `lev`, `T` and `cos_sza` as
scalars. Three `variable_map` couplings bind a gridded host's `[x, y, z]`
arrays to them, so `linear(…, lev, …)` and `bilinear(…, T, cos_sza, …)` are
per-cell lookups only after flatten. Inline tests are per-component (§6.6) and
cannot see a coupling, so this pair is not an inline-test fixture. Each
binding's own test builds it under `interpreter` and `native` and compares the
right-hand side at the initial state bit for bit:

- Julia: `test/template_array_args_test.jl`;
- Python: `tests/test_template_array_args.py`;
- Rust: `tests/template_array_args.rs`.

The same tests pin, in each binding:

- the `array_shape_mismatch` refusal of `bilinear` with `x` over `[a]` and `y`
  over `[b]`, and of `linear` with a `const` array query (an anonymous array has
  no index sets to align by);
- that a template over geometry operands (`polygon_intersection_area(a, b)`,
  both array-role) bound to arrays is not lifted;
- that a hand-written `faq` reading a shaped variable by bare name, with no
  template application, is not lifted.

## What is not here

- An application in a differential equation's right-hand side: §9.6.11 lets a
  binding require the application to define a variable, and every fixture does.
