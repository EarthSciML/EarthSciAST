# Recurrence Conformance Fixtures — causal self-reference along one index axis

Cross-port fixtures for **esm-spec §4.3.1.1** / **CONFORMANCE_SPEC §5.19**: an
equation defining an array-shaped unknown `V` whose defining `aggregate` body
reads `index(V, …)` at a strictly earlier position along one of that aggregate's
output axes. The array is then materialized cell by cell, that axis outermost and
ascending, each cell published before the axis advances.

This is the **only** construct in the format whose output cells are not
independent, and that is what the fixture set is shaped around.

## Why these fixtures pin ORDER, not just values

§5.19.3 requires it, and the reason is concrete. The construct's textbook example
is `s[1] = 1`, `s[k] = 2·s[k−1]` → `[1, 2, 4, 8]`, and pinning `[1, 2, 4, 8]`
proves almost nothing: every value is exactly representable, and several *wrong*
orders still terminate on a power of two. A fixture set that stopped there would
pass on a binding that batched the cells, reassociated the body, or carried
binary64 partials through a `Float32` fold.

So each fixture below either pins an order-sensitive value **to the bit** or
covers a shape a cheaper implementation cannot express at all.

| Fixture | What it pins | What fails it |
|---|---|---|
| `01_recurrence_doubling` | the minimal construct: `[1, 2, 4, 8]`, base case as an `ifelse` guard in the body | a binding with no recurrence at all (before this feature the variable never materialized) |
| `02_recurrence_cancellation_ladder` | **the order pin.** `s[k] = s[k−1] + u[k]` over `u = [1e16, 1, −1e16, 1]`: the ascending left fold is `[1e16, 1e16, 0, 1]` | any reassociation or reordering, which reaches `[1e16, 1e16, 1, 2]` |
| `03_recurrence_multi_lag` | two **literal** lags in one body (Fibonacci) | a single-step `acc[i] = f(acc[i−1], body[i])` accumulator, which cannot express it |
| `04_recurrence_banded_lag_fold` | a **symbol-valued** lag under a banded `filter`, with a clamp inside the fold; the in-body reduction order to the bit (`r[3] = −1.0` ascending, `−1.0000000000000002` from the high end) | a pairwise or reverse contraction; a binding admitting only literal lags |
| `05_recurrence_two_axes` | a rank-2 recurrence folding along ONE axis: the carried state is a whole column, so **array-valued** accumulator state needs no extra machinery. Also the sweep order (recurrence axis outermost) | a binding that folds the wrong axis, or iterates the free axis outside the recurrence axis |
| `06_recurrence_float32_state` | the carried value is rounded to the variable's `element_type` **at every cell**: the binary32 fold reaches `s[10] = 1.0000001192092896` | a binding that carries binary64 partials and narrows once at the end, reaching `0.9999999999999999` — a *better* answer than the `real*4` reference, and the hardest kind of wrong to notice |
| `07_recurrence_thirty_eight_lags` | the real lag scale: **38 distinct lags with 38 distinct weights in one node**, clamp firing at 19 of 40 cells and altering 38 of the 40 values. Expected values from an independent ascending fold, not from running the document | a literal-lag-only primitive (would need 38 authored terms); any single carried accumulator (the weights all differ); any linear closed form (the clamp) |
| `08_recurrence_parameter_valued_lag` | a lag **nothing static can bound** (`s[k] = 3·s[k−n]`, `n` a parameter) is ADMITTED | a validator that treats "unproven" as "illegal" — it would reject a document its own evaluator accepts |
| `09_recurrence_through_expression_template` | a self-read reached through an `apply_expression_template` **binding** is still recognized — template applications expand at load (§9.6.4), so the construct composes with templates rather than being evaded by them | a binding that defers template expansion past recognition, where the self-read would be evaluated as a gather on a name nothing binds |

Every assertion in every fixture is at **zero tolerance** (`rel: 0.0, abs: 0.0`).
That is not strictness for its own sake: §5.19.1 argues the value is a fully
determined function of the document, in the same sense a left fold is, so there is
no reassociation left for a binding to choose and a divergence is a defect rather
than a floating-point fact.

## The skip contract

A non-executing port MUST still **validate** every fixture here — accepting all
eight, and rejecting the malformed shapes each binding's own tests construct
(§5.19.5 rejection parity). Rejection parity is the whole of a non-evaluating
binding's duty for this construct, and it cuts both ways: a binding whose
cycle detector or trivial-DAE factoring treats a self-read as a cycle *rejects a
legal document*, which is the same defect as admitting an illegal one.

`skip_bindings` in `manifest.json` records, per fixture, which ports do not
evaluate it and why. A skip is a documented gap, not a pass. As of this
writing: Rust and Python execute all nine; Julia validates them and drives
`rejections.json` but does not evaluate (its array backend class-merges per-cell
kernels and the merge reorders cells, which §5.19.2 forbids — tracked as binding
debt); TypeScript and Go have no array numeric executor at all and validate only.

`rejections.json` beside this file is the negative half: eight malformed
self-references, each pinned on its `(code, path)` pair and driven by **all
five** bindings. It pins no message prose, deliberately — see its `pinned` block.

## What a binding must NOT do

§5.19.2 forbids evaluating a recurrence through any whole-array, vectorized,
fused, tiled, kernel-merged, parallel-prefix or otherwise reordered path, and
there is no equivalence to appeal to: the cells are not independent, so a
reordering computes something else. `O(N)` running accumulation — which §4.3.1
*does* license for a forward prefix scan — is **not** available here as a rewrite
either, because a recurrence's per-lag weights differ and no single carried value
summarizes the history. The sequential sweep is the implementation.
