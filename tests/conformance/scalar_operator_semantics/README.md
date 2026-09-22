# Scalar Operator Semantics (`scalar_operator_semantics`)

What each **scalar operator** of esm-spec §9.2's evaluable core COMPUTES,
pinned once for every binding. Normative text is `CONFORMANCE_SPEC.md` §5.45.4;
the runner contract is `CONFORMANCE_SPEC.md` §5.45 and the shared
[`../README.md`](../README.md) adapter discipline.

This tier is one of the **inline-test** family: its fixtures are documents that
carry their own §6.6 `tests` blocks, and each binding runs them through its OWN
inline-test runner under a NAMED compiler. It is driven by
`scripts/run-inline-tests-conformance.py`.

## Why it exists

The operator VOCABULARY is named in esm-spec §9.2 and its tier membership is
gated by the registry corpus. What nothing shared said is what any of it is
**worth**. `sign(0)` is `0`, not `+1`. `7/2` is `3.5`, not `3`. A false
comparison is `0.0`, not the second operand. `atan2`'s argument order is
`(y, x)`. `log` is natural. Each binding pinned all of that privately, against
its own evaluator, in its own vocabulary:

| Binding | Where it was pinned | Against what |
|---|---|---|
| Julia | `test/tree_walk_test.jl` testsets 1–5 | `build_evaluator` over hand-built AST nodes |
| Rust | `tests/interpret.rs` | `interpret()` over a `ResolvedExpr` tree |
| Python | `tests/test_simulation_scalar_ops.py` | `_expr_to_sympy` unit conversions |

Three private op tables and no cross-binding gate is exactly the shape in which
two bindings disagree for a year and nothing notices. Authoring the rules as ONE
document that every binding evaluates is what closes it — and it found a real
divergence on its first run (see **Named exclusions** below).

## Shape

| Comparison | Shape (see [`../README.md`](../README.md)) |
|---|---|
| each binding's §6.6.3 verdict vs the document's `expected` | **reference-comparing** — the authored value is arithmetic, computed outside every binding |
| each binding's `actual` vs `golden/<id>.json` | **reference-comparing** — the golden is the Julia `interpreter` |
| Rust / Python `actual` vs the golden | additionally **cross-binding-agreeing** |

## The fixture, and why it is algebraic

`scalar_operator_semantics.esm` declares one **observed** per operator, whose
operands are declared **parameters** rather than folded literals, and asserts
every one at a single static evaluation (`CONFORMANCE_SPEC.md` §5.43). There is
one integrated state, `probe`, so that a trajectory harness has a trajectory;
nothing else in the document carries an integrator's error, which is why the
golden band here is the `algebraic` class (`§5.38.2`) rather than a trajectory
tier's.

Non-vacuity is structural, in three places:

* every operand is a **parameter**, and a second test
  (`operator_values_under_overrides`) re-asserts a subset under
  `parameter_overrides`. A binding that folded the declared defaults at build
  time and ignored the overrides lands on the first test's numbers and fails.
* `time_value` asserts the bare name `t` at **3.5**, not at the span start, so
  a runner that evaluates every assertion at `t0` cannot pass it (§5.43).
* `arctangent_quadrant` asserts `atan2(1, -3)`, whose value separates the
  argument order that `atan2(1, 1)` cannot.

## Named exclusions

`boolean_literal_false.esm` is **split out of** the main fixture and holds the
`false` literal op alone. Julia's tree-walk evaluator carries an evaluation rule
for `true` and **none** for `false`, so it refuses that document with
`unevaluable_operator` under both `interpreter` and `native` (measured
2026-09-22). `false` is in the evaluable core
(`esm-libraries-spec.md` §2.5.10), so this is a gap to close, not a boundary —
and splitting it into its own fixture is what makes the exclusion cost the other
57 operators nothing.

The manifest records it as a **named exclusion**: the refusal is reported with
the binding, the compiler and the code on every run, and it is green only
because the ledger names it. If Julia gains the rule, the runner prints a
"stale exclusion" note rather than failing the binding that got better, and the
entry should then be trimmed by hand and `required` widened.

## Running it

```bash
python3 scripts/run-inline-tests-conformance.py \
    --manifest tests/conformance/scalar_operator_semantics/manifest.json --self-test

EARTHSCI_INLINE_TESTS_ADAPTER_JULIA="julia pkg/EarthSciAST.jl/scripts/inline_tests_adapter.jl" \
  python3 scripts/run-inline-tests-conformance.py \
    --manifest tests/conformance/scalar_operator_semantics/manifest.json \
    --write-golden --bindings julia --compiler interpreter
```

## What did NOT move here, and why

The per-binding op-table tests keep everything that is not a value claim a
document can make:

* the **refusals**: `ResolvedExpr::op("grad", …)` cannot be built,
  `unevaluable_operator` names the op, a structural `D` on the scalar evaluator
  is refused rather than answered `0`. Those are diagnostics with a code, and
  `tests/conformance/unevaluable_operator/` and `unsupported_construct/` are
  where they belong.
* the **slot-addressed** evaluation tests (`ResolvedExpr::State(1)`,
  `Param(0)`, `Observed(0)`), which assert an internal calling convention.
* the inverse-trigonometric and hyperbolic leaves, already gated by
  `tests/conformance/inverse_trig/`, and the degree/radian scale rule, already
  gated by `tests/conformance/` transcendental-scale fixtures. This tier does
  not duplicate them.
