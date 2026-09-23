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
document that every binding evaluates is what closes it — and it found three real
divergences on its first run (see **Named exclusions** below).

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

The tier found **three disagreements on its first run**, and each contested
operator is split into a fixture of its own so that an exclusion costs the
sibling fixture's 84 assertions — 70 operators, plus the `t` row, the override
arm and the integrated state — nothing.

| Fixture | Binding / compilers | Code | What it means |
|---|---|---|---|
| `boolean_literal_false` | julia / `interpreter`, `native` | `unevaluable_operator` | Julia's tree-walk evaluator carries a rule for the `true` literal op and **none** for `false` |
| `boolean_literal_false` | rust / `interpreter`, `native` | `unlowered_operator` | Rust classes `false` as a REWRITE TARGET and refuses it before evaluation |
| `pow_alias` | rust / `interpreter`, `native` | `unlowered_operator` | Rust classes `pow` as a rewrite target; Julia and Python evaluate it, and to the same number `^` gives |
| `boolean_literal_true` | rust / `native` | `compiler_refused_rule` | Rust's strict `native` has no wholesale lowering for the `true` leaf; its `interpreter` runs it |

The three are not the same KIND of gap, and the ledger keeps them apart. `pow`
and `false` are refused by Rust under `interpreter` too, so they are
disagreements about what the evaluable-core VOCABULARY is
(`esm-libraries-spec.md` §2.5.10 says both are in it). `true` is refused only
by Rust's `native`, so it is an ordinary `native` coverage gap on one leaf.
`pow_alias` is deliberately paired with the sibling fixture's `^(2, 3) = 8`, so
the two documents together say exactly what is and is not agreed — the
arithmetic is, the **alias** is not.

`boolean_literal_false` carries **no golden**, because the reference is one of
the bindings that refuses it. Its `golden_absent_reason` says so, and the
manifest validator requires a named exclusion for the reference binding before
it will accept a null golden: the only reason a fixture may carry no golden is
that the reference cannot produce one. Python is still held to the DOCUMENT's
own expectation, which is an oracle outside every binding; what is missing is
only the cross-compiler drift check.

The manifest records each as a **named exclusion**: the refusal is reported
with the binding, the compiler and the code on every run, and it is green only
because the ledger names it. If a binding gains the rule, the runner prints a
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

* the **refusals**: `grad` is refused before evaluation,
  `unevaluable_operator` names the op, a structural `D` handed to a
  single-expression evaluation is refused rather than answered `0`. Those are
  diagnostics with a code, and `tests/conformance/unevaluable_operator/` and
  `unsupported_construct/` are where they belong. (Rust:
  `tests/evaluate_leaf_ops.rs`, through the public `evaluate`.)
* the inverse-trigonometric and hyperbolic leaves, already gated by
  `tests/conformance/inverse_trig/`, and the degree/radian scale rule, already
  gated by `tests/conformance/` transcendental-scale fixtures. This tier does
  not duplicate them.
