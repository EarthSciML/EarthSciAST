# Broadcast and Index Alignment (`broadcast_alignment`)

The gate for esm-spec §4.3.4's **name-based operand alignment** in an
array-level equation, for the scope boundary that rule has, and for the
one-operand `broadcast` node. Normative text is `CONFORMANCE_SPEC.md` §5.45.3;
the runner contract (manifest schema, adapter CLI, outcomes, golden format) is
`CONFORMANCE_SPEC.md` §5.45 and the shared
[`../README.md`](../README.md) adapter discipline.

This tier is one of the **inline-test** family: its fixtures are documents that
carry their own §6.6 `tests` blocks, and each binding runs them through its OWN
inline-test runner under a NAMED compiler. It is driven by
`scripts/run-inline-tests-conformance.py`.

## The rule, and the three ways it was got wrong

An operand of a bare array-level expression aligns to the result by **index-set
name**. It supplies the axes it is declared over, **replicates** along the ones
it is not, and **transposes** when its declaration order differs from the
result's. A `broadcast` node is governed by the same rule as the bare spelling.

An operand whose shape is **anonymous** — one that names no index sets, such
as a `makearray`, a shape op, a `const` array, or a `faq` whose output indices
range over inline intervals — stays **positional** (esm-spec §4.3.4 rule 2).
That is the rule's boundary, and it is a rule in its own right rather than an
omission. A `faq` whose output indices range `{"from": <index set>}` is not
anonymous: it names those index sets and is placed by them, like a declared
variable (`nested_producer_union`).

Every executing binding got the alignment half wrong, in its own vocabulary and
in **opposite directions** (EarthSciML/EarthSciAST#100):

* **Rust** flattened the operand into the result's linear layout, laying a
  rank-1 `[lat]` operand along `lon` and zero-filling the third `lon` cell.
* **Python** right-aligned, the way NumPy broadcasting does.
* Both produced fields that are finite, plausible and wrong — which is why a
  smoke test could not see it and a pinned value can.

Separately (#101) a **one-operand** `broadcast` dropped its `fn` and behaved as
the identity, turning a negated flux into an un-negated one: same magnitude,
wrong sign, still finite.

## Shape

| Comparison | Shape (see [`../README.md`](../README.md)) |
|---|---|
| each binding's `actual` vs the document's `expected`, by the runner's own §6.6.3 predicate, and the binding's `passed` agreeing with it | **reference-comparing** — the authored expectation is hand-computed from §4.3.4 and lives outside every binding |
| each binding's `actual` vs `golden/<id>.json` | **reference-comparing** — the golden is the Julia `interpreter`, which shares no code with the compiled or vectorized tiers it gates |
| Rust / Python `actual` vs the golden | additionally **cross-binding-agreeing** |

Gating both is the point. An assertion whose band is loose enough to admit two
different answers passes for both bindings and still reports the disagreement,
because the goldens do not move.

## Directory layout

```
tests/conformance/broadcast_alignment/
├── README.md                 # this file — the contract
├── manifest.json             # fixtures, tolerances, the `required` ledger, the exclusions
├── fixtures/<id>.esm         # the documents authored HERE
└── golden/<id>.json          # the Julia-interpreter actual for every assertion (none for a fault fixture)
```

Four of the thirteen fixtures are **referenced, not authored**:
`tests/valid/array_broadcast/*.esm` already carried the §4.3.4 documents and
their inline `tests` blocks, and copying them would have created a second place
to keep them in step. A fifth, `permuted_static_alias`, replays a saved
differential document from `tests/differential/shaped/`. The other eight are
authored here because no shared document covered them:

| Fixture | What it holds | Migrated from |
|---|---|---|
| `bare_rank_lift` | a `[lat]` operand replicates along `lon` and `lev` | already shared |
| `bare_mixed_rank_product` | `[lon,lat]` × `[lev]` forms the outer product over the union | already shared |
| `bare_axis_permuted_operand` | an equal-rank operand declared `[lat,lon]` **transposes** | already shared |
| `broadcast_node_mixed_rank` | the `broadcast` spelling of `bare_mixed_rank_product`, cell for cell | already shared |
| `anonymous_shape_positional` | a `faq` over inline intervals names no index sets, so its axes are ANONYMOUS and stay positional, beside a named operand in the same document | `broadcast_alignment_test.jl` testset (j) |
| `unary_broadcast_fn` | `broadcast(fn: "-", [x])` ≡ the bare `-(x)`, both reaching `exp(0.3)` | the #101 arms of `broadcast_alignment_test.jl` and `test_broadcast_and_index_alignment.py` |
| `observed_expression_aligned` | alignment reaches THROUGH an observed's body | `test_observed_expression_is_aligned_too` (Python), `array_shaped_observed_broadcasts_by_name` (Rust) |
| `static_named_broadcast` | state-free: `[rows]` and `[cols]` parameters of unequal extents align by name into a `[cols, rows]` and a `[rows, cols]` result | authored here |
| `nested_producer_union` | state-free: an undeclared result spans the union of its operands' index sets, a `faq` over `{from: lat}` contributing `lat` as a whole definition, under `k *`, or as an operand of the result itself; declared and transposed results place it by name; a `faq` that is a declared result's whole definition transposes or replicates by name | authored here |
| `undeclared_operand_state` | a whole-array `D(x) = w + c` with `x` over `[lon, lat]` and `w` an undeclared observed spanning `[lat]` places `w` by name | authored here |
| `faq_producer_foreign_index_set` | **fault**: `k * faq` over `{from: lon}` in a result declared over `[lat]` only is `array_shape_mismatch`, as for a declared operand over `lon` | authored here |
| `faq_whole_rhs_foreign_index_set` | **fault**: the same with the `faq` the whole right-hand side | authored here |
| `permuted_static_alias` | state-free: a bare alias whose declared axes reverse its operand's reads its cells in its own axis order | `tests/differential/shaped/` replay |

Each authored fixture with state integrates a **constant tendency from a zero
initial condition**, so `dp(t=1)` reads the array-level right-hand side back
cell by cell and no integrator stands between the rule and the number. The
exception is `unary_broadcast_fn`, which is a scalar exponential per cell so
that a dropped `fn` lands on `exp(-0.3)` instead of `exp(0.3)` — two numbers
4.5e-1 apart. The state-free fixtures assert their observeds at `t = 0`, and
are the ones the Lean model scores.

## Tolerances

`tolerances.golden_rtol` / `golden_atol` bound a producer's `actual` against the
Julia-interpreter golden. They are **separate from, and tighter than**, each
assertion's own §6.6.4 band: the assertion states what the PHYSICS is and is
gated at the document's tolerance — by the runner's own §6.6.3 predicate over
the reported `actual`, with the binding's `passed` required to agree — while the
golden band states how far two evaluations of the same arithmetic may drift.

## The two ledgers

Per fixture, `required` (binding → the compilers that MUST run THIS document)
and `named_exclusions` (binding + compiler → the refusal that is expected, with
its code) answer opposite questions and are never merged. A fixture that both
requires and excludes the same pair is a manifest error the self-test rejects.

A refusal is a **named exclusion** — reported with the binding, the compiler,
the fixture and the code, and green — or a **failure**. It is never a silent
skip and never a fallback. A Julia or Rust `native` refusal can be a named
exclusion only for a construct outside `native`'s scope
(`unsupported_construct`, `unlowered_operator`; `API_SPEC.md` §5.8); any other
is a failure. Python is exempt from that rule.

The ledger is **empty**. It first held two entries, measured on 2026-09-22:
Rust's strict `native` refused `broadcast_node_mixed_rank` and
`unary_broadcast_fn` with `compiler_refused_rule`, because its tape had no
wholesale lowering for the array-level `broadcast` node. The tape now lowers a
`broadcast` node as the bare `{op: fn, args}` node it means (issue #462), both
fixtures are required under `native`, and Rust's `tests/array_level_broadcast.rs`
no longer forces `Compiler::Interpreter`.

Everything is `required` for `interpreter` and `native` in all three executing
bindings.

The two `faq_*_foreign_index_set` fixtures carry `expected_fault` instead of a
golden: their conforming outcome is the build refusing with
`array_shape_mismatch`, so a compiler their `required` map names passes only by
declining with that code, and an answer to their assertions (the laundered
positional read they pin) is red. Julia's build spells the same refusal
`E_TREEWALK_ARRAY_SHAPE_MISMATCH`, the build-time twin of `validate()`'s code,
and `expected_fault.binding_codes` records that spelling.

## Running it

```bash
# The always-on guard: no binding needed.
python3 scripts/run-inline-tests-conformance.py \
    --manifest tests/conformance/broadcast_alignment/manifest.json --self-test

# Mint the goldens (reference only).
EARTHSCI_INLINE_TESTS_ADAPTER_JULIA="julia pkg/EarthSciAST.jl/scripts/inline_tests_adapter.jl" \
  python3 scripts/run-inline-tests-conformance.py \
    --manifest tests/conformance/broadcast_alignment/manifest.json \
    --write-golden --bindings julia --compiler interpreter
```

`scripts/test-conformance.sh` runs the self-test plus one producer stage per
binding per compiler, each naming its `--compiler` explicitly
(`CONFORMANCE_SPEC.md` §5.44.5).

## What did NOT move here, and why

`broadcast_alignment_test.jl`, `array_level_broadcast.rs` and
`test_broadcast_and_index_alignment.py` keep everything that is not a value
claim about a document:

* the `validate()` findings for an operand over an index set absent from the
  result, and for the `broadcast` `fn` contract (unknown / missing /
  non-scalar / arity). Those are diagnostics with a code, a JSON pointer and a
  `details` map — `tests/invalid/expected_errors.json` and each binding's
  structural-validation suite are where they belong, not an inline `tests`
  block, which can only carry a number.
* bit-identity between two spellings of the same document, which is a
  comparison of two runs and not a statement a document can make about itself.
* the internal predicates (`_is_scalar_op`, `_broadcast_fn_problem`,
  `is_elementwise_op`, `align_expression`) and the ModelingToolkit exporter's
  own `fn` vocabulary.
