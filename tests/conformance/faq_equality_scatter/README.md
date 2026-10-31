# Equality-scatter fixtures (`faq_equality_scatter`)

A `faq` whose `filter` pins an output index by equality (`j == e` or `e == j`,
`e` reading no output index) can be evaluated in one pass over its non-output
range keys, scattering each admitted term into cell `e` (esm-spec §4.3.1,
"One-pass scatter for an equality filter"; issue #613). The license holds only
because the result is bit-identical to the naive fold, so that is what this tier
pins: every fixture is an ODE document whose right-hand side is such a `faq`,
and the right-hand side at the document's initial state must equal a golden
computed outside every binding, BIT FOR BIT, under the interpreter and under
`native` alike.

The interpreters keep the naive evaluation. The fixtures are small, so the
dense path is exact on them too; they exist so that the scatter, when a native
compiler takes it, keeps reaching these bits.

## What is measured

Each binding builds the fixture with `compiler = interpreter` and
`compiler = native`, evaluates the right-hand side once at the initial state
(every state at its document default), default parameters, `t = 0`, and
compares each state element's derivative with `golden/<id>.json`:

- `du` maps an element name under the model (`w[2]`, `v[1,3]`, a scalar's
  bare `g`) to its value. The string forms `NaN`, `Infinity` and `-Infinity`
  are allowed, but no golden uses them today: the `max`/`min` fixture reports a
  NaN reduction as `-1` and an empty one as `-2` through an `ifelse`, because a
  binding may refuse a non-finite derivative;
- the comparison is on bits, so `-0.0` and `+0.0` differ.

The goldens are written by `generate.py`, whose oracle is a literal loop in
plain Python floats: for each output cell, visit the contracted indices in
increasing order, test the whole filter, fold the admitted terms into an
accumulator seeded with the additive identity. It imports nothing from any
binding.

```bash
python3 tests/conformance/faq_equality_scatter/generate.py          # rewrite
python3 tests/conformance/faq_equality_scatter/generate.py --check  # committed files are current
```

Every output cell's terms come from ONE varying contracted index, so no golden
depends on the order in which a binding nests two contracted indices (that order
is not pinned across bindings). Every source term is `C[i] * s[i]` with `s` a
state held at 1 (`D(s) = 0`), so the body reads a state and the scatter runs on
the right-hand side, and `C` alternates 1e16 magnitudes with small terms, so any
fold order other than ascending changes the low bits.

## The fixtures

| Fixture | What it pins |
|---|---|
| `plus_cancelling` | `+` over `[1e16, 1, -1e16, 1, …]` in four-term cells, an empty cell (`+0.0`), the issue's band transpose spelled `i + 1 == j` (`e` on the left), and a cell of `-0.0` terms that folds to `+0.0` from the seed |
| `max_min_nan` | `max` and `min` with a NaN (`0/0`) after a number in one cell, first in another, and at a point whose `e` falls outside the range (it must reach no cell), and a `max` that admits nothing (`-Inf`) |
| `two_pinned_2d` | a 2-D output with both indices pinned (`j1 == e1`, `e2 == j2`), three terms per cell, one empty row |
| `one_free` | one output index pinned and one free, with the pinned index first and second in `output_idx` |
| `out_of_range` | `e = i/2` (non-integer for odd `i`, skipped) and `e = i - 3` (below and above the range) |
| `scan_comparison` | `and(j == e, r <= i)`: alone `r <= i` is a reverse scan, but with the equality the node folds ascending; and the forward `i <= 3r` beside an equality |
| `pinned_twice` | `and(j == e1, j == e2)`: the second equality is an ordinary remaining conjunct |
| `nested_rank0` | a rank-0 `faq` in a scatter body that reads the pinned index, and an equality inside a nested rank-0 node on the enclosing index (no output index of its own, so not a scatter) |
| `runtime_map` | `e` reads a parameter, and `e` reads a state: the map is a run-time value |
| `ragged` | a ragged `from`/`of` range under a free parent, `e` reading the position symbol |
| `ragged_contracted_parent` | a ragged range whose parent is contracted, `e` reading the member gathered at the position; each cell's terms come from one row |

## A NaN in a `max` / `min` window

A NaN term makes a `max` / `min` reduction NaN wherever it sits in the window
(esm-spec §4.2), so `max_min_nan`'s NaN cells are NaN (reported as `-1`) in every
binding, under both compilers. Before this tier the three interpreters
disagreed (Julia propagated, Python kept only a leading NaN, Rust skipped every
NaN); they were brought to the §4.2 rule together with it.

## Exclusions

`manifest.json` names, per fixture, the bindings that do not run it today and
why. Each binding's test asserts that an excluded fixture still FAILS there (a
refusal, an error or a wrong value), so a fix turns the stale exclusion red
until it is removed from `generate.py`.

| Fixture | Binding | Why |
|---|---|---|
| `ragged` | Python | the NumPy evaluator refuses a filter over a ragged contracted range |
| `ragged_contracted_parent` | Julia | `E_TREEWALK_UNBOUND_LOOP_VAR` on a ragged range whose parent is contracted, under both compilers |
| `ragged_contracted_parent` | Rust | the interpreter silently returns 0 for cells 2 to 4 (only cell 1 is right); native refuses (the ragged bound's parent is not an output index) |
| `ragged_contracted_parent` | Python | as for `ragged` |

## Who runs it

| Binding | Test | Compilers |
|---|---|---|
| Julia | `pkg/EarthSciAST.jl/test/conformance_faq_equality_scatter_test.jl` | `:interpreter`, `:native` |
| Rust | `pkg/earthsci-ast-rs/tests/faq_equality_scatter_conformance.rs` (native through the tape) | `Interpreter`, `Native` |
| Python | `pkg/earthsci-ast-py/tests/test_faq_equality_scatter.py` | `interpreter`, `native` |

TypeScript and Go have no simulator and do not run this tier.

The scaling tier's `band_transpose` family (`../scaling/`) is the cost check: a
tridiagonal `Jᵀλ` spelled as two equality scatters, up to `N = 10⁶`, against a
one-pass hand loop.
