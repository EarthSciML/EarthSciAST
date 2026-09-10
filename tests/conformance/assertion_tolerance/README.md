# Assertion-predicate conformance (`tests/conformance/assertion_tolerance/`)

Cross-binding conformance for **esm-spec §6.6.3**'s pass predicate, asserted as
what it is: a **pure function of four numbers**.

```
pass(actual, expected, rel, abs) =
      actual == expected
   OR ( actual and expected are both FINITE
        AND NOT (rel == 0 AND abs == 0)
        AND |actual − expected| ≤ max(abs, rel · max(|actual|, |expected|)) )
```

## Why this set exists

Every other assertion fixture in the corpus is a **simulation**: it integrates a
document, produces an actual, and then compares it. That shape can only exercise
the predicate at the pairs an integrator happens to produce — and those all sit
in the `|actual| ≤ |expected|` region, where the symmetric bound
`rel·max(|a|,|e|)` and the `|expected|`-only bound `rel·|e|` **compute the same
number**. The two readings differ only on an *overshoot*, by a margin of order
`rel`, which no fixture in any category reaches. That is why 8031 corpus
assertions agreed unanimously while the bindings' harnesses disagreed with the
bindings themselves (#193, #223): the corpus never reaches the seam.

A data-only category reaches it in one line, because it does not have to *arrive*
at a discriminating pair — it can simply state one.

| Case | `rel·max(\|a\|,\|e\|)` | `rel·\|e\|` | `abs + rel·\|e\|` |
|---|---|---|---|
| `a=1.6, e=1.0, rel=0.5, abs=0` | 0.8 → **PASS** | 0.5 → FAIL | 0.5 → FAIL |
| `a=1.5, e=1.0, rel=0.3, abs=0.3` | 0.45 → **FAIL** | 0.3 → FAIL | 0.6 → PASS |

## The golden

`golden/predicate_verdicts.json`. Each entry in `cases` is one
`(actual, expected, rel, abs)` tuple plus the required `passed` verdict, the
reason it is in the list, and — when it differs from one — which known wrong
reading it discriminates.

The verdicts are **analytic**. They are computed by
`scripts/gen-assertion-tolerance-golden.py` from §6.6.3 written out longhand,
not read off any binding, so this is a *reference-comparing* fixture in the
sense of `tests/conformance/README.md` rather than a cross-binding agreement.

### Encoding

JSON has no infinite or NaN literal, so `actual` and `expected` are **either a
JSON number or one of exactly three strings**: `"+inf"`, `"-inf"`, `"nan"`.
Nothing else is ever a string, and an adapter that meets an unrecognised one
MUST fail rather than skip the case.

CONFORMANCE_SPEC §5.20 declines this encoding for the `assertion_nonfinite`
category, on the ground that re-parsing strings would make the golden's format
the thing under test. That reasoning is specific to a category whose subject is
*what a runner computes*: there, the string would stand in for a value the
document was supposed to produce, and a mis-parse would look like a simulation
divergence. Here the numbers are **inputs**, the vocabulary is three closed
tokens, and a mis-parse cannot be mistaken for anything — it fails loudly in the
adapter, before the predicate is called.

### Non-vacuity

`readings_discriminated` in the golden counts, per known wrong reading, how many
cases change verdict under it:

| Wrong reading | Where it was found | Cases that see it |
|---|---|---|
| `asymmetric` — scale by `\|expected\|` alone | 9 of the ~12 harnesses in #223 | 6 |
| `sum_form` — `abs + rel·\|expected\|` (numpy `isclose`) | Rust `wildfire_simulation.rs`, `loaded_ic_bc_simulation.rs`; the form #193 flagged | 7 |
| `epsilon_floor` — `max(…, ε)` on the scale | 1e-12 in five Python harnesses, `f64::MIN_POSITIVE` in two Rust ones | 3 |
| `no_finiteness_guard` — plus "both non-finite ⇒ equal" | the three Rust `approximately_equal` harnesses | 7 |

The generator **asserts every one of those counts is nonzero**, so the case list
cannot quietly stop being able to see a defect. The golden is 22 pass / 21 fail,
and each discriminating pass case is paired with a fail case in the same region,
so a binding cannot satisfy half the list by loosening or tightening everything.

## Adapters

| Binding | File | Predicate under test |
|---|---|---|
| Julia | `pkg/EarthSciAST.jl/test/conformance_assertion_tolerance_test.jl` | `EarthSciAST._check_assertion` |
| Python | `pkg/earthsci-ast-py/tests/test_assertion_tolerance_conformance.py` | `earthsci_ast.inline_tests._check_assertion` |
| Rust | `pkg/earthsci-ast-rs/tests/assertion_tolerance_conformance.rs` | `earthsci_ast::check_assertion` |
| TypeScript | `pkg/earthsci-ast-ts/src/assertion-tolerance-conformance.test.ts` | `checkAssertion` (`src/assertion-tolerance.ts`) |
| Go | `pkg/earthsci-ast-go/pkg/esm/assertion_tolerance_scope_test.go` | — (scope only) |

Each adapter calls **the same function its own inline-test harnesses call**. An
adapter that re-derived the predicate locally would be testing itself; that is
the defect this category exists to close.

Go is `scope_excluded`: it has no assertion predicate anywhere — not in
production, not in its own tests — because it parses a `tests` block as data and
never evaluates one. Its scope test asserts that exclusion, so giving Go a
predicate goes red here until Go is moved into `bindings_required` with a real
adapter. That is the §5.20 pattern and the reason for it: an exclusion is
invisible by construction, so it has to be asserted somewhere.

## What this category does NOT prove

That any runner actually *calls* the predicate. `assertion_nonfinite`
(CONFORMANCE_SPEC §5.20) is the end-to-end half — it drives a document whose
arithmetic overflows through each binding's real inline-test runner. Neither
category subsumes the other, and both are needed.
