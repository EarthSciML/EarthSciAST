# Pointwise `faq` Filter (`faq_pointwise_filter`)

What a `faq` node's `filter` does when the node has **no contracted index**.
Normative text is `CONFORMANCE_SPEC.md` §5.45.4; the runner contract is
`CONFORMANCE_SPEC.md` §5.45 and the shared [`../README.md`](../README.md)
adapter discipline.

This tier is one of the **inline-test** family: its fixture is a document that
carries its own §6.6 `tests` block, and each binding runs it through its OWN
inline-test runner under a NAMED compiler. It is driven by
`scripts/run-inline-tests-conformance.py`.

## Why it exists

esm-schema defines `filter` as the predicate that restricts which index
combinations contribute a term: a combination for which it is false contributes
the semiring's additive identity 0̄ (RFC semiring-faq-unified-ir §5.3). With no
contracted index each output cell is exactly one combination, so a false
predicate makes that cell 0̄.

Rust and Python applied it. Julia applied it where a `faq` is read in
expression position (`index(faq(…), i)`), but its array-equation path, which
every compiled tier and the interpreter's per-cell reference share, dropped a
filter whenever the node contracted nothing. The same document therefore gave
`a = [3, 5, 7, 9, 11]` in Julia and `[0, 0, 7, 9, 11]` in the other two
bindings, with no diagnostic. Every existing filter fixture filtered a
CONTRACTION, which Julia did apply, so nothing shared noticed.

## Shape

| Comparison | Shape (see [`../README.md`](../README.md)) |
|---|---|
| each binding's `actual` vs the document's `expected`, by the runner's own §6.6.3 predicate | **reference-comparing**: the authored values are arithmetic (the rate is constant, so the state at t = 1 is the rate), computed outside every binding |
| each binding's `actual` vs `golden/<id>.json` | **reference-comparing**: the golden is the Julia `interpreter`, minted after its fix and only because it matched the authored values |
| Rust / Python `actual` vs the golden | additionally **cross-binding-agreeing** |

## The fixture

`pointwise_filter.esm` has two constant-rate array states over `x` (size 5):

* `a` carries the filter in its own array equation,
  `D(a[i]) = 2i + 1 where i >= 3`, so `a(1) = [0, 0, 7, 9, 11]`;
* `b` reads it through an array observed, `w[i] = 10 i where i <= 2` and
  `D(b[i]) = w[i]`, so `b(1) = [10, 20, 0, 0, 0]`. This is the path a
  materialized observed takes, which in Julia wraps the producer in an identity
  gather before the array-equation path sees it.

Every cell is asserted, the filtered-out ones included. A binding that ignores
a filter without a contracted index reads `2i + 1` and `10 i` at every cell and
fails five assertions. The golden band is the integrator's (`1e-12` relative):
the values are small integers up to the solver's rounding.

## Named exclusions

None. The fixture is required under `interpreter` and `native` in all three
executing bindings.

## Running it

```bash
python3 scripts/run-inline-tests-conformance.py \
    --manifest tests/conformance/faq_pointwise_filter/manifest.json --self-test

EARTHSCI_INLINE_TESTS_ADAPTER_JULIA="julia pkg/EarthSciAST.jl/scripts/inline_tests_adapter.jl" \
  python3 scripts/run-inline-tests-conformance.py \
    --manifest tests/conformance/faq_pointwise_filter/manifest.json \
    --bindings julia --compiler native
```

## What did NOT move here

Julia's bit-for-bit agreement between its compiled forms and its interpreter on
the same construct is a property of one binding's compilers rather than of the
document's meaning, so it stays in that binding's own tests
(`pkg/EarthSciAST.jl/test/array_contraction_table_test.jl`, and the faq
initialization-equation case in `percell_route_refusal_test.jl`).
