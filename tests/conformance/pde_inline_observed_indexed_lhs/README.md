# `pde_inline_observed_indexed_lhs`

The INDEXED LHS spelling of an ARRAY-shaped observed (esm-spec §6.3.1;
CONFORMANCE_SPEC §5.30). Normative prose lives in CONFORMANCE_SPEC — this file
records what the fixture is for, and the one thing about this category that is
unusual.

## What it pins

§6.3.1 admits **two** LHS spellings for the equation that DEFINES an unknown —
bare (`y ~ f(…)`) and indexed (`y[i] ~ f(…)`, "which defines the whole array
`y`") — and states the criterion semantically: the defining form is read through
the LHS's **base name**, so "an arrayed definition is observed exactly as its
scalar counterpart is". Neither spelling is restricted by rank.

`fixtures/observed_indexed_lhs.esm` writes **every** array observed the indexed
way, and asserts those observeds **directly** — not merely the states they
drive. Asserting the observeds is the point: it is what makes the fixture state
the §6.3.1 contract rather than the weaker intersection the bindings happened to
agree on. The states are asserted alongside, so a binding that answers the
observeds but drops them out of the dynamics (or the reverse) still fails.

The two observeds are a **controlled pair**, and both halves must be kept:

| | class | definition | routed by a binding as |
|---|---|---|---|
| `wf` | STATE-FREE | `wf[k] ~ 2·k` | build-materialized |
| `ws` | STATE-DEPENDENT | `ws[k] ~ 3·u[k]` | evaluated at the sampled state |

Those are the two paths bindings route differently, so fixing one does not pass
the category.

Both right-hand sides are exactly integrable — `D(u) = wf = 2k` is a per-cell
constant, so `u[k](t) = 2·k·t`; `D(v) = ws = 3·u` is then linear in `t`, so
`v[k](t) = 3·k·t²` — hence every pinned solver family of order ≥ 2 reproduces
the goldens to machine precision. **A divergence in this category is a semantics
divergence, never an integrator one.**

Julia is the reference binding; `golden/observed_indexed_lhs.json` was minted by
its `run_pde_tests` (Tsit5, reltol 1e-12, abstol 1e-14).

## Python: red on `main`, fixed by PR #237, pending merge

Julia and Rust pass all fourteen assertions. **Python passes 7 of 14 on `main`**
(at `71e25b380`, where this category was authored) and **14 of 14 on PR #237**
at `57b72acad`. It is deliberately kept in `bindings_required` rather than
`scope_excluded`: it has a real runner, so the category states the contract and
lets the binding be red until the fix lands, instead of being defined down to
what passes today.

So this is not a standing divergence — it is a **fixed defect awaiting a merge**.
The category's Python leg is red until #237 merges and green immediately after.

### The defect

Three symptoms, one root cause. `flatten._collect_model` read observed-ness from
`classification.inlined_unknowns` — the strict `y ~ f(…)` set that §6.3.1
sanctions **for inlining specifically** — and used it as if it were the
classification. §6.3.1 says that set "does not narrow the partition".

That is the same mistake, in a different binding, that #250 fixes on the Julia
side: there the tree-walk build's owner buckets each tested the syntactic
`eq.lhs isa VarExpr`. Two bindings, one wrong substitution, found independently.

The three symptoms on `main`:

1. **An indexed-LHS array observed is not readable by an assertion.** `wf` and
   `ws` answer `0.0` at every time instead of their field values. (Assertions
   1–6 and 8 catch this. Assertion 7 passes even on `main`, because `ws(0)` is
   genuinely zero — see the note on assertion 7 below.)
2. **An indexed LHS with a PER-CELL right-hand side is silently dropped.**
   `aggregate{k}(w[k]) ~ 2*u[k]`, with no `aggregate` on the right, raises
   `RuntimeWarning: unrecognized algebraic equation … was not applied to the ODE
   RHS; any state it constrains stays frozen at its initial value` — and the
   state does stay frozen at its initial value.
3. **An indexed-LHS observed feeding a WHOLE-ARRAY derivative is dropped the
   same way.** `D(u) ~ wf` leaves `u` at its initial value; spelling the
   derivative `aggregate{k}(D(u[k])) ~ aggregate{k}(wf[k])` — which is what this
   fixture does — makes it integrate.

Complete reproducer documents for all three are in the body of **PR #250**, which
introduced this category.

### Measured, not assumed — at both heads

Each of the three reproducers, plus this whole fixture, was run against #237's
`pkg/earthsci-ast-py/src` extracted with `git archive` and put on `PYTHONPATH`:

| #237 head | the three reproducers | this fixture |
|---|---|---|
| `67504523` (earlier) | all three fail, identically to `main` | 7 / 14 |
| `57b72acad` (current) | **all three pass** | **14 / 14** |

The earlier head is recorded because divergence 3 reads exactly like #237's
title ("a declared `shape` routes to the array pathway, whatever the equation
spelling") and was nonetheless not covered by it then — worth knowing that the
title was not sufficient evidence, and that the later commit is what actually
closes it.

### No mechanism marks this red-until-merge

The manifest's `tags` are free-form strings with no runner behind them, and the
Python adapter carries no `xfail` — an `xfail` would flip to an unexpected-pass
failure the moment #237 merges, which is worse than a red leg that turns green.
So the tag `red-on-main-until-pr-237` is documentation only, and the actual
signal is this section plus the adapter docstring. Nothing needs to be removed
from the fixture when #237 merges; only this prose goes stale, and the tag
should be dropped then.

## A note on assertion 7, and one on `_comment`

**Assertion 7 (`ws` at `t = 0`) is deliberately non-discriminating** — a binding
that always answers zero passes it, and Python did on `main`. It is kept because
it pins the state-dependent observed at the trajectory START, a distinct sample
from the mid- and end-trajectory ones. **Assertion 8 (`ws` at `t = 0.5`) is its
discriminating partner**, added so that `ws` is checked at three distinct times
and only one of them can be passed by accident. Do not read assertion 7 alone as
evidence of conformance.

**The schema rejects `_comment` inside an `assertion` object.** It is fine on an
`equation`, but inside an assertion it fails the `oneOf` and the diagnostic dumps
the entire model rather than pointing at the offending key. Put per-assertion
prose in the test's `description` instead.

## Runners

| Binding | Adapter |
|---|---|
| Julia | `pkg/EarthSciAST.jl/test/conformance_pde_inline_observed_indexed_lhs_test.jl` |
| Python | `pkg/earthsci-ast-py/tests/test_pde_inline_observed_indexed_lhs_conformance.py` |
| Rust | `pkg/earthsci-ast-rs/tests/pde_inline_observed_indexed_lhs_conformance.rs` |

Go and TypeScript are rewrite-only ports with no simulator and no inline-test
runner, and are `scope_excluded` in the manifest.
