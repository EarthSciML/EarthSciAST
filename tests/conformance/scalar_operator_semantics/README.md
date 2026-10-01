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
| each binding's `actual` vs the document's `expected`, by the runner's own §6.6.3 predicate, and the binding's `passed` agreeing with it | **reference-comparing** — the authored value is arithmetic, computed outside every binding |
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

## The angle fixture

`angle_array_element.esm` pins the array-element half of esm-spec §4.8.3's
angle conversion: a circular function whose argument is an element of an array
declared in `deg` receives that element in radians, exactly as it would a bare
`deg` variable. Julia, Python, Go and TypeScript read the argument's unit with
the checker's rules, which have none for `index` or `faq` (§4.8.4), so their
flatten pass left `cos(index(lat, i))` unconverted, and Julia and Python
evaluated cos(60 radians) = −0.952 where 0.5 is right. The fixture asserts, per
cell and against the arithmetic rather than a binding:

* `cos` of an element of a `deg` parameter, over [0, 60, 90]°;
* `sin` of an element of an observed that an `faq` defines in `deg`;
* `sin` of each element inside a reducing `faq` body, summed (1 + √3/2);
* the `rad` control, the same angles declared in radians, which must NOT be
  converted: it tells "the scale is applied" apart from "applied twice".

The scalar half is `tests/simulation/angle_units_degrees.esm`, pinned by each
binding's own transcendental-scale tests.

## Named exclusions

The tier found **three disagreements on its first run**, and each contested
operator was split into a fixture of its own so that an exclusion cost the
sibling fixture's 84 assertions — 70 operators, plus the `t` row, the override
arm and the integrated state — nothing.

| Fixture | Binding / compilers | What it was | Fixed by |
|---|---|---|---|
| `boolean_literal_false` | julia / `interpreter`, `native` | Julia's tree-walk evaluator carried a rule for the `true` literal op and **none** for `false` (`unevaluable_operator`) | issue #460 |
| `boolean_literal_false` | rust / `interpreter`, `native` | Rust classed `false` as a REWRITE TARGET and refused it before evaluation (`unlowered_operator`) | issue #461 |
| `pow_alias` | rust / `interpreter`, `native` | Rust classed `pow` as a rewrite target; Julia and Python evaluated it, to the same number `^` gives (`unlowered_operator`) | issue #461 |
| `boolean_literal_true` | rust / `native` | Rust's strict `native` had no wholesale lowering for the `true` leaf; its `interpreter` ran it (`compiler_refused_rule`) | issue #462 |

All three are fixed, so the ledger is **empty** and every fixture is required
under `interpreter` and `native` in all three executing bindings.
`boolean_literal_false` carries a golden minted from the Julia `interpreter`
like the others. `esm-spec.md` §4.2 lists both literals and both power
spellings, so the vocabulary the bindings now agree on is the one the spec
states. The split fixtures stay: `pow_alias` beside the sibling fixture's
`^(2, 3) = 8` is what pins that the two spellings agree.

The manifest records a refusal as a **named exclusion**: it is reported with
the binding, the compiler and the code on every run, and it is green only
because the ledger names it. If a binding gains the rule, the runner prints a
"stale exclusion" note rather than failing the binding that got better, and the
entry is then trimmed by hand and `required` widened — exclusions only go away.

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
  `tests/conformance/inverse_trig/`, and the SCALAR degree/radian scale rule,
  already pinned by each binding's transcendental-scale tests against
  `tests/simulation/angle_units_degrees.esm`. This tier does not duplicate
  them; `angle_array_element` covers only the array-element half (above).
