---
title: "Causal self-reference along an index axis"
---

# Causal self-reference along an index axis

**Status.** Accepted; implemented in `esm-spec.md` §4.3.1.1, `CONFORMANCE_SPEC.md` §5.19.

**Summary.** An equation that defines an array-shaped unknown may read *that same
array* through `index`, at a strictly earlier position along exactly one of the
defining `aggregate`'s output axes. The array is then materialized cell by cell,
ascending along that axis, and each cell's value is published before the axis
advances. This is a **recurrence primitive**: the body may read any earlier
position, not only the immediately preceding one, and the body is an ordinary
expression, so the recurrence composes with contraction, `filter`, `reduce` and
every scalar op.

---

## 1. The gap this closes

§4.3.1's **cumulative (prefix) reduction** is the canonical spelling of a running
total: an `aggregate` whose `filter` compares the contracted index monotonically
against an output index. It covers every fold whose *terms* are independent of the
result — a running sum, a running maximum, a cumulative product. It does **not**
cover a fold whose next term is a function of the previous *answer*, and
`detect_prefix_scan` says so explicitly: a body that reads the scanned output
symbol is declined, because then "every output cell would have a different summand
for the same `j` and no partial result could be reused".

The simplest computation outside that boundary is

```
s[1] = 1
s[k] = 2 · s[k−1]        →  [1, 2, 4, 8]
```

and before this change the format had no spelling for it. Three consequences,
each measured on the pinned CLI before this RFC:

* written as an `aggregate` whose body reads `index(s, k−1)`, the document
  **validated** and then the variable never materialized;
* written as a `makearray` whose first region is the base case, likewise;
* written on the time axis with `Pre` and a periodic event, or as an implicit
  residual `s − shift(s) = 0`, the run **completed and returned a wrong answer**
  (the initial condition, unchanged) — the array evaluator executes neither
  discrete events nor non-bare-LHS equations.

A recurrence whose body reads only `acc[i−1]` is not enough. The motivating
consumer is a bounded-lag fold — a clamped linear recurrence whose cell at
position `i` reads roughly forty earlier positions with a different weight each,
so no scalar accumulator summarizes the history and no reduction removes the
self-reference. (Substituting its own closed form leaves a deconvolution, which
is a recurrence again.) The primitive therefore has to admit an **arbitrary
bounded lag** along the axis.

A **scalar-valued** self-reference over the axis is nevertheless sufficient, and
that is a conclusion rather than a simplification: the motivating fold's natural
accumulator is a whole vector, but the vector's cells are themselves expressible
in closed form given the scalar sequence, so the minimal addition is a scalar
sequence with an order-`L` dependence, not array-valued accumulator state. This
RFC adds exactly that and no more. (An array-valued accumulator would be a
strictly larger addition: it needs a second, nested notion of "the value so far",
whereas a scalar self-read is just a gather on the array being written.)

## 2. Node shape

**No new op, and no new field.** The recurrence is a property of an *equation*,
recognized structurally:

> An equation whose LHS names an array-shaped unknown `V` (bare, `V ~ …`, or
> indexed through the §4.3 `aggregate` LHS form, `aggregate{expr: V[k]} ~ …`), and
> whose RHS contains one or more `index(V, …)` reads, is a **recurrence
> definition** of `V`.

The RHS must be an `aggregate` whose `output_idx` are the symbols `V` is
materialized over; those symbols and their `ranges` form the **cell frame**. Each
`index(V, …)` read inside the RHS is a **causal self-read**, and its index
arguments are checked against the cell frame.

Three reasons for putting it on the equation rather than in a new node:

1. **The accumulator needs a name.** `acc[i−1]` has to denote something. The
   equation's LHS already names the array being built; a new op would have to
   introduce a second binder for the same object and then keep the two in sync.
2. **§4.3.1 forbids a private scan operator** ("the format ships no separate
   `cumsum` / `scan` operator, and a binding MUST NOT introduce one under a
   private op name"). A recurrence op would be that operator with a longer name.
   The prohibition is about keeping one spelling for one concept, and the concept
   here is the same one: a fold along an axis.
3. **It is unambiguous.** `index(V, k−c)` inside the definition of `V` has exactly
   one possible meaning. There is no other `V` for it to denote — `V` is defined
   by this equation and nowhere else. So an annotation would carry no information
   that the read does not already carry, while a *required* annotation would leave
   the un-annotated form to be rejected for no reason a reader could act on.

### 2.1 Why the lag is derived, not declared

The brief for this work asked how the bounded lag is *declared*. It is not: it is
**derived from the read.** Write `lag = k_d − <the index argument>`. Each index
argument must be affine in its own frame symbol with coefficient 1 — that is the
part that has to be checkable, because it is what makes "which axis, in which
direction" decidable. The lag's integer bounds then follow from literals and the
resolved ranges of the symbols in scope:

| `lag` bounds | Outcome |
|---|---|
| exactly `[0, 0]` | not the recurrence axis (the read stays on this cell) |
| `hi(lag) ≤ 0` | **rejected** — provably same-cell or forward |
| `lo(lag) ≥ 1` | admitted, proved strictly earlier |
| straddling zero | admitted, **runtime-guarded** |
| not provable at all (a parameter, an unresolvable symbol) | admitted, **runtime-guarded** |

The coefficient is the half that must be proved; the lag's sign is not. A
validator proves strictly less than an evaluator — it sees `ranges` before they
are resolved against the registry — so treating "unproven" as "illegal" would
make a binding reject documents its own evaluator accepts. That was in fact the
first implementation's behaviour: the code failed the whole analysis on an
unresolvable symbol while its own comment claimed the opposite, and a sibling
binding's author caught the discrepancy by reading both.

`max_lag` is the maximum `hi(lag)` over every self-read. It is reported — Rust's
`BuildInspection::recurrences` carries `(var, axis, max_lag, lag_proven)` — because
an implementation may legitimately want it (a windowed implementation need retain
only `max_lag` slices instead of the whole axis) but **no evaluation rule depends
on it**. A declared bound would be a second source of truth to check against the
first.

**Why the straddling row is admitted rather than rejected.** An earlier draft of
this design required `lo(lag) ≥ 1` — a static proof for every read. Measurement
killed it: the motivating fold's own spelling is one aggregate whose contracted
index runs from `0`, with the `0` term carrying the additive non-recurrent part and
the remaining terms reading `V` at lag `a` under an `ifelse` guard. That is the
*factored* spelling — the alternative is one hand-written term per lag, which is
exactly the mechanically generated, unfactored document this repo's authoring rules
forbid — and its `lag = a` straddles zero. Rejecting it would have made the
primitive unable to express the computation that motivated it.

Admitting it costs nothing in soundness, and this is the load-bearing observation of
the whole design: **the runtime is sound without the static proof.** A self-read
resolves only against cells the sweep has already *published*; a read of any other
cell — earlier-but-out-of-range, the cell being written, or a later one — has no
value to return and is a fault (§4). So the static check's job is only to reject
what is *provably* wrong (and to identify the axis), not to certify what is right.
A guarded straddling read never evaluates at the cells where it would be
ill-founded; an unguarded one faults at the first cell rather than at the last, and
it faults either way.

## 3. Well-foundedness

A recurrence definition of `V` over cell frame `(k₁ … k_r)` with ranges
`R₁ … R_r` is **well-founded** when all of the following hold. Each is a
`recurrence_not_wellfounded` structural error otherwise.

1. Every self-read is an `index` node whose first argument is the bare name `V`,
   with exactly `r` index arguments.
2. Every index argument is affine in its frame symbol with coefficient 1, and
   there is a single **recurrence axis** `d`, the same for every self-read: at
   position `d` the lag is admitted by §2.1, and at every other position
   `e ≠ d` the lag is exactly zero.
3. `R_d` is a static, ascending, unit-step integer interval. (A ragged or derived
   axis has no total order to fold along, and a non-unit step would make "the
   previous position" ambiguous.)
4. `V` is not read bare anywhere in the RHS — only through `index`. A bare read
   denotes the whole array, which does not exist yet, at any point in the sweep.
5. `V` is an algebraically defined unknown: it carries no `D(V)` equation. (A
   stencil read of an ODE state at `i−1` is a gather on the *solver's* state
   vector, not a self-reference, and is unaffected by this RFC.)

Cross-variable cycles are unchanged and still rejected: the self-edge is dropped
from the observed dependency graph — every binding already drops it — but an edge
between two *distinct* variables still closes a cycle and still raises the
existing cycle diagnostic. Well-foundedness here is only ever about `V` and
itself.

### 3.1 What the validator must reject

| Situation | Code |
|---|---|
| A read provably at the same cell or later on its axis (`index(V, k)`, `index(V, k+1)`) | `recurrence_not_wellfounded` |
| An index argument not affine in its frame symbol with coefficient 1 | `recurrence_not_wellfounded` |
| Self-reads on two different axes, or two self-reads disagreeing on the axis | `recurrence_not_wellfounded` |
| A non-identity index at a non-recurrence axis (`index(V, k−1, j+1)`) | `recurrence_not_wellfounded` |
| Bare `V` in its own RHS | `recurrence_not_wellfounded` |
| Recurrence axis is ragged, derived, or non-unit-step | `recurrence_not_wellfounded` |
| Self-read reached only through a construct that cannot be sequenced cell by cell — a `makearray` region value, a `reshape`/`transpose`/`concat` operand, an `apply_expression_template` target | `recurrence_unsupported_form` |
| RHS is not an `aggregate` over `V`'s axes, or its output ranges are not statically resolvable | `recurrence_unsupported_form` |

The second family exists because a self-read whose position in the tree the
runtime cannot restrict to one cell is not a recurrence the runtime can honour,
and the pre-RFC behaviour for all of these was a plausible wrong number.
`makearray` is the specific case worth naming: its regions are *ordered*, and
§4.3.2's overlap rule is "later entries overwrite earlier ones", which reads like
a licence to define position `k` from position `k−1`. It is not one — the region
order fixes which **write wins**, not the order in which cells are **evaluated**,
and every binding evaluates a region's value expression once, wholesale, for the
whole region. Rejecting it names that distinction instead of leaving an author to
discover it from a wrong answer.

## 4. Evaluation order (normative)

The whole point of the feature is the order, so the order is specified, not left
to the implementation:

1. The cells of `V` are visited with the **recurrence axis as the outermost
   loop, ascending** from `lo(R_d)` to `hi(R_d)`; the remaining axes iterate
   inside it, ascending, in `output_idx` order.
2. At each cell the RHS is evaluated **restricted to that cell**: the cell frame's
   symbols are bound to the cell's coordinates and the aggregate's own
   contraction, `filter` and `reduce` are applied at that cell exactly as they
   are for a non-recurrent aggregate. Restriction is what makes the recurrence
   composable — the body's arithmetic is not special-cased.
3. The cell's value is **published into `V` before the sweep advances**, so a
   later cell's self-read observes it.
4. A recurrence definition MUST NOT be evaluated through any whole-array,
   vectorized, fused, tiled, class-merged or reordered path. There is no
   equivalence to appeal to: the cells are not independent, so any reordering is
   a different computation, and a *reassociation* of the body's arithmetic is a
   different number in binary floating point. Bindings that vectorize or
   class-merge per-cell kernels must decline for these rules specifically.
5. A self-read of a position outside `R_d`, or of a cell not yet published, is a
   **fault**: `E_TREEWALK_RECUR_UNAVAILABLE`. It is never resolved to a value —
   in particular the homogeneous-Dirichlet **zero ghost** of §5.5.5, which every
   other state/observed gather uses out of range, is **never** applied to a causal
   self-read. This follows §5.5.5's own reasoning for const-array gathers: out of
   range there is a bug, not a boundary. Substituting `0` here would be worse than
   in either of those cases, because a recurrence *feeds itself* — one laundered
   zero propagates along the whole axis, and a clamp like `max(x, 0)` in the body
   would erase even a NaN sentinel.

Point 5 is why a base case is written as a **guard inside the body**
(`ifelse(k <= 1, base, f(index(V, k−1)))`) rather than relied on to fall off the
end of the axis. Within a recurrence body a scalar-conditioned `ifelse` evaluates
**only the selected branch** (§4.3.1.1); this is required, not incidental, because
it is what keeps the guarded self-read from being evaluated at the first cell.

Points 1–3 make the value a fully determined function of the document, which is
what licenses the **bit-identical** conformance requirement in §5.2 — the same
argument §4.3.1 makes for the forward prefix scan, applied to a fold whose terms
happen to read the fold's own output.

## 5. Alternatives considered

**A new `recur` / `fold` / `scan` op.** Rejected: §4.3.1 forbids a private scan
op, and the accumulator would need a binder the equation's LHS already provides.

**An explicit `recur: {axis, max_lag}` field on `aggregate`.** Rejected as a
second source of truth (§2.1). Its only real benefit — making the recurrence
visible to a reader skimming the document — is served instead by the diagnostic:
a binding reports each recognized recurrence, its axis and its derived `max_lag`
in build inspection, so the interpretation is auditable without being authored
twice.

**Widening §4.3.1's prefix scan to admit a body that reads the scanned symbol.**
This is the shape the finding that motivated this work originally proposed
(`acc[i] = f(acc[i−1], body[i])`). Rejected on measurement: the motivating fold
needs `acc[i−a]` for `a` up to ~38, and the prefix-scan machinery in all three
executing bindings carries exactly one accumulator value. Widening it to `L`
accumulators is the same work as this RFC with a worse name, and the `O(N)`
running-accumulator rewrite — the reason the scan path exists — does not survive
the widening anyway.

**`makearray` region ordering.** Rejected; see §3.1.

**`Pre` on an index axis.** Rejected: `Pre` is defined against events on the time
axis, the array backend executes no discrete events, and a calculator-shaped
component carries no clock. Adopting a clock would not have unblocked it.

**Solving the recurrence as an implicit system.** Rejected on shape as well as on
availability. Forward substitution on a unit-lower-triangular system is exact;
an iterative root find converges to a tolerance, and the sign of a
near-zero residual can be load-bearing in the motivating consumer.

## 6. Implementation

| Binding | Executes | Path |
|---|---|---|
| Rust | yes | `AlgebraicRule::Recurrence` + `RecurScope` in the per-cell oracle |
| Python | yes (bare-LHS form) | `_RecurScope` + `sweep_recurrence` in `numpy_interpreter.py` |
| Julia | no — see §6.1 | validation only |
| TypeScript | no (no numeric array executor) | validation only |
| Go | no (no numeric array executor) | validation only |

All five implement the **static** half, which is the whole of a non-executing
binding's duty here (§5.19.5) and is pinned across bindings by
`tests/conformance/recurrence/rejections.json`.

### 6.0 The exemption is gated on candidacy — learned the hard way

Every binding has to stop *some* existing check firing on the self-edge, and the
gate for that exemption turned out to be the subtlest thing in the whole design.
It must be **candidacy** — the equation is array-shaped and has at least one
`index` self-read, well founded or not — and both neighbouring choices are wrong,
each losing a different diagnosis:

* gating on the **well-foundedness verdict** (too narrow) means an ill-founded
  read is not exempt, so the pre-existing cycle check fires and pre-empts the
  `recurrence_*` codes. Measured, when a binding implemented the first draft of
  this RFC literally: six negative cases collapsed to a single whole-document
  error;
* gating on **"is it a self-edge at all"** (too wide) swallows equations the
  recurrence check does not own — a scalar `x ~ x + 1`, a bare `s ~ s + 1` — and
  drops the cycle error they used to get.

Both were found by implementers rather than by review, in different bindings, and
neither is visible in a binding's own tests: the narrow one fails nothing locally,
which is exactly why the negative cases are a shared corpus.

Where the check *lives* is incidental — TypeScript keeps the predicate and the
validator at core level, Rust splits them across two files — but the two must
share one implementation, or the gate and the verdict can disagree.

Detection is **structural and opt-in by construction**: a document with no
`index(V, …)` read inside `V`'s own definition takes byte-identical paths to the
pre-RFC runtime. The cost added to every other document is one `Option` field on
the evaluation context (always `None`), one `is_none()` test on the vectorized
overlay's entry gate, and one compile-time walk of each algebraic RHS looking for
a self-read — none of it on the per-step hot path.

### 6.1 Julia

Julia's array backend builds per-cell **independent** kernels and class-merges
them, and the merge reorders cells; its one sequential-across-cells construct is
the prefix scan's post-pass fold over the output vector (`tree_walk/scan.jl`),
whose body is a fixed `combine(acc, du[slot])` rather than an evaluated
expression. A recurrence needs a compiled per-cell body evaluated *inside* the
lane loop, plus an out-of-place mirror. That is a larger change than the other
two executing bindings needed and is tracked as binding debt rather than
half-landed; the conformance fixtures declare Julia a `skip_bindings` port for
this category with that reason, exactly as `20_arrayop_contraction_embedded`
already does for the embedded-aggregate form.

Julia does implement the static half, and its own vacuity probe settled a
question the other bindings could not answer from outside: Julia's cycle
detection does **not** run inside validation (its only in-validation cycle check
is model-to-model coupling; the observed-cycle detector lives on the
`build_evaluator` path), so Julia has Rust's and Go's shape rather than
TypeScript's and either gate reads the same there. It is gated on candidacy
anyway, so the code says candidacy where §6.0 says candidacy.
