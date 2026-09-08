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

## Python is EXPECTED TO FAIL this category today

This is the unusual part. **Python is deliberately kept in
`bindings_required`** even though it does not yet pass. It has a real runner, so
`scope_excluded` would be the wrong mechanism: the point of a conformance
category is to state the contract and let a non-conforming binding be red
against it, not to define the contract down to what already passes.

Python currently fails the six non-zero observed assertions (1–6), returning
`0.0` for both `wf` and `ws`, and passes the seven state assertions. Three
distinct divergences are involved, all on this same spelling:

1. **An indexed-LHS array observed is not readable by an assertion.** Asserting
   `wf` or `ws` at any time returns `0.0` instead of the field's value. (This is
   what assertions 1–6 catch. Assertion 7 passes only because `ws(0)` is
   genuinely zero.)
2. **An indexed LHS with a PER-CELL right-hand side is silently dropped.**
   `aggregate{k}(w[k]) ~ 2*u[k]`, with no `aggregate` on the right, raises
   `RuntimeWarning: unrecognized algebraic equation … was not applied to the ODE
   RHS; any state it constrains stays frozen at its initial value` — and the
   state does stay frozen at its initial value.
3. **An indexed-LHS observed feeding a WHOLE-ARRAY derivative is dropped the
   same way.** `D(u) ~ wf` leaves `u` at its initial value; spelling the
   derivative `aggregate{k}(D(u[k])) ~ aggregate{k}(wf[k])` — which is what this
   fixture does — makes it integrate.

All three are Python-side and are being folded into **PR #237** ("a declared
`shape` routes to the array pathway, whatever the equation spelling", issue
#231). Complete reproducer documents for each are in the body of **PR #250**,
which introduced this category.

**Measured, not assumed:** all three reproducers were run against #237 at head
`67504523`, and it closes **none** of them — each fails there exactly as it does
on `main`, and this fixture scores the same 7/13 either way. Divergence 3 in
particular looked like #237's subject from the title, and is not (yet) covered by
it. So this category goes green for Python only once that work actually reaches
these three shapes; the numbers above are the check to re-run.

Julia and Rust pass all thirteen assertions.

## Runners

| Binding | Adapter |
|---|---|
| Julia | `pkg/EarthSciAST.jl/test/conformance_pde_inline_observed_indexed_lhs_test.jl` |
| Python | `pkg/earthsci-ast-py/tests/test_pde_inline_observed_indexed_lhs_conformance.py` |
| Rust | `pkg/earthsci-ast-rs/tests/pde_inline_observed_indexed_lhs_conformance.rs` |

Go and TypeScript are rewrite-only ports with no simulator and no inline-test
runner, and are `scope_excluded` in the manifest.
