# Array Expression Forms (`array_expression_forms`)

Array expressions and equation spellings that are relabellings of cells.
Normative text is `CONFORMANCE_SPEC.md` §5.45.4; the runner contract is
`CONFORMANCE_SPEC.md` §5.45 and the shared [`../README.md`](../README.md)
adapter discipline.

This tier is one of the **inline-test** family: each fixture is a document that
carries its own §6.6 `tests` block, and each binding runs it through its OWN
inline-test runner under a NAMED compiler. It is driven by
`scripts/run-inline-tests-conformance.py`.

## Why it exists

Three forms name elements of an array without computing anything new:

* `index(reshape(X), k…)`, `index(transpose(X), k…)` and `index(concat(…), k…)`
  (esm-spec §4.3.5) are elements of an operand at other subscripts. `reshape` is
  column-major, `transpose`'s `perm` is 0-based with output axis `d` reading
  operand axis `perm[d]`, and `concat`'s `axis` is 0-based;
* a `broadcast` of anonymous operands of different shapes (§4.3.4) aligns them
  positionally, left-aligned, the lower rank padded with trailing singletons;
* an arrayed definition `faq{i}(index(v, i)) ~ rhs` (§6.3.1) defines the whole of
  an observed `v`, including one whose `shape` was never declared, whose extent
  the frame then gives.

Rust and Python ran the six corpus documents here. Julia refused every one of
them under both of its compilers: the shape ops reached its evaluator with a
bare operand and failed with an unbound variable or a wrong subscript count, and
an arrayed definition of an undeclared-shape observed was an unsupported
equation. Julia now lowers each shape op under an `index` to a gather of its
operand at build time, and normalizes the arrayed definition to `v ~ faq(…)`,
so every compiled tier sees an ordinary gather.

## Shape

| Comparison | Shape (see [`../README.md`](../README.md)) |
|---|---|
| each binding's `actual` vs the document's `expected`, by the runner's own §6.6.3 predicate | **reference-comparing**: every probe integrates a constant tendency (or a linear decay with a closed form), computed outside every binding |
| each binding's `actual` vs `golden/<id>.json` | **reference-comparing**: the golden is the Julia `interpreter` |
| Rust / Python `actual` vs the golden | additionally **cross-binding-agreeing** |

## The fixtures

Six are referenced from `tests/fixtures/faq/` (`11`–`14`, `02`, `04`), which
use literal subscripts. `fixtures/shape_ops_symbolic_subscripts.esm` is authored
here: the same gathers with an `faq` loop symbol as a subscript — through a
`transpose`, a `reshape` that inserts a unit axis, a `broadcast` of a vector
against a reshaped row, and a `concat` whose joined-axis subscript is literal.
Every source value is distinct, so a wrong axis order, element order or operand
reads a different number.

A symbolic subscript through a `reshape` that reorders elements, or on the
joined axis of a `concat`, needs integer division or a per-cell choice of
operand, which has no gather form; Julia refuses both by name
(`E_TREEWALK_SHAPE_OP`), and no fixture here asks for them.

## Named exclusions

None: every binding runs every fixture under both compilers. (Rust's tape once
refused `shape_ops_symbolic_subscripts`; it now lowers a shape-op or `broadcast`
base whole and reads it at the subscripts, as the interpreter's gather does.)

The bare-operator spelling of the positional broadcast (`a + reshape(b, [1, 2])`
with no `broadcast` node) is not a fixture: Python aligns it the NumPy way
(right-aligned) and fails, where §4.3.4 says the bare and `broadcast` spellings
follow one rule. A wrong answer is a failure, not a refusal, so it cannot be a
named exclusion; it is recorded for the cross-binding follow-up instead.

## Running it

```bash
# The always-on guard: no binding needed.
python3 scripts/run-inline-tests-conformance.py \
    --manifest tests/conformance/array_expression_forms/manifest.json --self-test

# Mint the goldens (reference only).
EARTHSCI_INLINE_TESTS_ADAPTER_JULIA="julia pkg/EarthSciAST.jl/scripts/inline_tests_adapter.jl" \
  python3 scripts/run-inline-tests-conformance.py \
    --manifest tests/conformance/array_expression_forms/manifest.json \
    --write-golden --bindings julia --compiler interpreter
```

`scripts/test-conformance.sh` runs the self-test plus one producer stage per
binding per compiler, each naming its `--compiler` explicitly
(`CONFORMANCE_SPEC.md` §5.44.5).
