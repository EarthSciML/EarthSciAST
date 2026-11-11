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
| `nearest_generator_template_ode` | the nearest-generator document of `value_invention_geometry` (`fixtures/nearest_generator_ode.esm`) with its arg-witness written as the `argmin` template (loop symbol `k_argmin_1`, n = 3). Its golden is bit-identical to that document's. |

`generate.py` writes `scenarios.json` and both fixtures. The goldens are the
Julia interpreter's (`scripts/run-inline-tests-conformance.py --write-golden`).

## Binding harnesses

Each binding's harness runs every scenario of `scenarios.json` through the
expanded template and checks the `expected` index (Julia
`test/relational_templates_test.jl`, Python `tests/test_relational_templates.py`,
Rust `tests/relational_templates.rs`); a NaN candidate cannot be a caller array
in a JSON document, so those scenarios are covered there rather than only by
the fixture. `op_expected`, where a scenario has it, records what the
`argmin` / `argmax` operator form removed at esm 2.0.0 returned: it compared
with `<` / `>` from the first candidate on, so it skipped a NaN after the
first candidate, which the template picks.

## Template rewrites of the former skolem / rank fixtures (`rewrites/`)

`rewrites/` holds the hand-written `lib/relational.esm` form, made in phase 3,
of every fixture that used `skolem`, `rank` or a gated `argmin`
(`rewrites/manifest.json` lists 13 with their sources): a `distinct` key becomes
`edge_key` / `pair_key` / the bare component, a bin key read only by `join.on`
becomes one integer column per component with one `on` pair each, `rank(S)` over
the set's own members becomes the loop index (1-based), and a joined `argmin`
becomes `argmin_where`. `skolem_distinct_rank` also looks up each face edge's
rank among the derived `edges` set with `rank_of_set` over `{"from": "edges"}`.
The ops were removed at esm 2.0.0 and the source fixtures were converted by the
codemod (`python -m earthsci_ast.migrate`), which writes the same forms except
that a two-component key is the directed `pair_key` and a set's own rank keeps
the operator's 0-based value (`e - 1`). The goldens (`golden/<id>.json`) were
computed from the op forms by the Python interpreter before the removal; they
pin what both the rewrites and the converted sources must give. The manifest
carries the caller data and what must agree; Go and TypeScript load every
rewrite. The two value_invention_geometry rewrites run in this tier against that
tier's goldens.

## What is not here

- A gated arg-witness inside this tier: `NearestGeneratorBinned` is rewritten
  with `argmin_where` in `rewrites/` and compared there.
- An empty candidate set: the template returns +Inf (the identity of the
  `min` reduction) for n = 0.
- `tests/scoping/loop_binder_shadowing_edges.esm` and the
  `metaparam_structural_field_collision` template fixture carry an `argmin` /
  `argmax` only for their structure (scoping, a metaparameter collision); no
  assignment is checked there.

## Named exclusions

None. Go and TypeScript are scope-excluded (no inline-test runner); each checks
the expansion of every scenario against the substituted template body
(`pkg/esm/relational_templates_test.go`, `src/relational-templates.test.ts`).
