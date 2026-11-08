# Relational templates (`relational_templates`)

`lib/relational.esm` is a template-library file (esm-spec §9.7.1) carrying the
pure-AST definitions of the `argmin` and `argmax` arg-witness reducers as
match-less expression templates: `argmin(f, n)` and `argmax(f, n)`. `f` is the
candidate value, an expression over the template's loop symbol (`k_argmin_1`,
`k_argmax_1`), and `n` the number of candidates, an integer template
parameter used as a `faq` `ranges` bound (esm-spec §9.6.1). The body is two
`faq` reductions: `m` = the `min` (`max`) of `f` over the candidates, then the
smallest index at which `f == m`, or at which `f` is NaN when `m` is NaN. So a
tie goes to the smallest index (RFC semiring-faq-unified-ir §5.7 rule 6) and,
because one NaN term makes a `min`/`max` reduction NaN (esm-spec §4.2), a NaN
candidate wins at its first occurrence. This tier checks, in every binding with
an inline-test runner and under every compiler, that the expanded templates
return those indices.

## The fixtures

| Fixture | What it pins |
|---|---|
| `argmin_template` | every scenario of `scenarios.json` (32: distinct extremes at the first, middle and last candidate, ties of two and of all, one candidate, signed-zero ties, a subnormal tie, the nearest-generator tie, ±Inf candidates and ties, NaN first, middle and last, NaN against ±Inf, all NaN; for both templates). Candidate `k` is `num[k] / den[k]` over two `const` arrays, so 0/0, 1/0 and -1/0 write the non-finite candidates. Each index is asserted at t = 0 with tolerance 0. |
| `nearest_generator_template_ode` | `value_invention_geometry/fixtures/nearest_generator_ode.esm` with the `argmin` op replaced by the template (the op's `g` renamed to `k_argmin_1`, n = 3). Its golden is bit-identical to that document's. |

`generate.py` writes `scenarios.json` and both fixtures. The goldens are the
Julia interpreter's (`scripts/run-inline-tests-conformance.py --write-golden`).

## Comparison with the op

The op is the oracle, but it is not in this tier: its documents run through
build-time value invention, and a NaN candidate cannot be a caller array in a
JSON document. Each binding's harness runs every scenario through both the
template and the op (Julia `test/relational_templates_test.jl`, Python
`tests/test_relational_templates.py`, Rust `tests/relational_templates.rs`)
and rewrites the nearest-generator fixtures of `tests/valid/faq/` as the
template, comparing the assignment buffers. The op and the template agree on
every scenario except the ones with a NaN after the first candidate, which the
op skips (it compares with `<` / `>` from the first candidate on) and the
template picks. `scenarios.json` records the op's answer there as
`op_expected`.

## Template rewrites of the skolem / rank fixtures (`rewrites/`)

`rewrites/generate.py` writes the `lib/relational.esm` form of every fixture
that uses `skolem`, `rank` or a gated `argmin` (`rewrites/manifest.json` lists
17, with their sources): a `distinct` key becomes `edge_key` / `pair_key` / the
bare component, a bin key read only by `join.on` becomes one integer column
per component with one `on` pair each, `rank(S)` over the set's own members
becomes the loop index, and a joined `argmin` becomes `argmin_where`. The
manifest carries the caller data and what must agree. Each binding's harness
builds both forms (Julia `test/relational_rewrites_test.jl`, Python
`tests/test_relational_rewrites.py`, Rust `tests/relational_rewrites.rs`):
identical members (the template's integer keys decoded back to the op's
tuples), dense IDs (the op's 0-based rank plus one), assignment buffers and
right-hand sides; Go and TypeScript load every rewrite. The two
value_invention_geometry rewrites run in this tier against the op documents'
goldens, and the three value_invention_materialize rewrites (plus
`key_out_of_range`) in that tier.

## What is not here

- A gated arg-witness inside this tier: `NearestGeneratorBinned` is rewritten
  with `argmin_where` in `rewrites/` and compared there.
- An empty candidate set: the op refuses it; the template returns +Inf (the
  identity of the `min` reduction) for n = 0.
- `tests/scoping/loop_binder_shadowing_edges.esm` and the
  `metaparam_structural_field_collision` template fixture carry an `argmin` /
  `argmax` only as structure; they compute no assignment.

## Named exclusions

None. Go and TypeScript are scope-excluded (no inline-test runner); each checks
the expansion of every scenario against the substituted template body
(`pkg/esm/relational_templates_test.go`, `src/relational-templates.test.ts`).
