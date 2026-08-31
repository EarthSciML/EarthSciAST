---
title: "Analyses (§6.7): settling the semantics an executor would need"
description: "esm-spec §6.7 specifies the shape of an analysis but not its meaning. Exactly one construct — Cartesian sweep enumeration — is implementable against the text today; the output time grid, the four time reductions, off-grid sampling, plot behavior under a sweep, sweep-point ordering, override-key resolution, pinned_coords' coordinate space, the output contract, and failure handling are all undefined, and each of them changes output bytes. This RFC proposes a ruling for each. Fourteen items: twelve are prose-only, one is a schema description touch, one is an optional schema addition that can wait. It settles meaning; it does not schedule an executor."
---

> **Status:** Draft proposal — **rulings only**. Nothing here is a landed
> change, and nothing here schedules an implementation. The recommendation in
> §9 is that no executor be built now; the value of the RFC is that the
> fourteen questions below stop being re-derived from scratch every time
> someone looks at §6.7.
>
> **Spec baseline:** `esm-spec.md` §6.7 (lines 2001–2178), schema
> `$defs.Analysis` / `Plot` / `PlotValue` / `ParameterSweep`.
> **Related:** gt-y8ts (per-binding structural validation of `tests` /
> `analyses`, filed with `1a9279cd3`, never done — see §8).

---

## 1. Summary

§6.7 defines an **inline analysis**: a run configuration (initial state,
parameter overrides, time span, optional Cartesian parameter sweep) paired with
structural plot specifications. Its framing sentence is deliberately modest:

> An analysis is an illustrative run (or family of runs) showing how the
> component is intended to be used. Analyses do not produce pass/fail
> outcomes — they produce trajectories and plots. (`esm-spec.md:2003`)

The block round-trips today in four of five bindings. What it does **not** have
is a meaning. Reading §6.7 as an executor would, exactly one construct is
specified well enough to implement against: Cartesian sweep enumeration
(`:2071`, `:2077–2078`), plus the purely syntactic `y`-array → `series` rewrite
(`:2106–2108`). Everything an executor would have to decide is either handed
back to the runtime —

> whether the runtime interpolates or snaps to the nearest sample is a runtime
> concern, not part of this specification (`:2133`)

— or simply not addressed. That is defensible for a block the spec calls
viewer-facing. It is **not** defensible for a repo whose entire premise is that
five bindings agree byte-for-byte, because every one of the fourteen items in
§4–§7 below changes an emitted number.

This RFC proposes an answer to each. The headline is that settling them is
cheap:

| Cost class | Count | Items |
|---|---|---|
| **Prose-only** (spec text; no schema, no version bump) | 12 | R2–R4, R6–R14 |
| **Schema description touch** (PATCH) | 1 | R5 |
| **New optional schema property** (MINOR) | 1 | R1's `saveat`, and it is **deferrable** |
| **Should stay undefined** | 3 sub-items | series *labels*, on-disk output layout, styling |

Two of the fourteen turn out to need no new ruling at all — they are answered by
text the spec already contains, and this RFC's contribution there is only to say
where (§5.1, §7.1).

Three places where the existing spec text is **self-contradictory or
self-invalidating** are flagged in §3.

## 2. What §6.7 does and does not settle

Settled well enough to implement:

| Construct | Where |
|---|---|
| Cartesian product is the only sweep combination; run count is the product of dimension lengths | `:2071` |
| A dimension carries exactly one of `values` or `range` | `:2078` |
| `y`-array shorthand rewrites to `y[0]` + a `series` list, with explicit `series` winning | `:2106–2108` |
| `at_time` wins over `reduce` when both are present | `:2131` |
| `field_snapshot` ignores `value.at_time` / `value.reduce` in favor of the plot-level `at_time` | `:2099` |
| Non-plotted spatial dimensions MUST be pinned | `:2089–2090`, `:2102` |

Deliberately left to the viewer, and this RFC agrees it should stay there:

> Only **structural** information is recorded: axes, series selection, and value
> reduction. Styling — colors, fonts, legend placement, themes — is the viewer's
> concern. (`:2082`)

Not settled, and the subject of this RFC: everything in §4–§7.

## 3. Contradictions in the existing text

Three, flagged before the rulings because two of the rulings are *resolutions*
of a contradiction rather than choices between free options.

### 3.1 `pinned_coords` vs. `coords`: physical or index space?

`Plot.pinned_coords` is documented as mapping a dimension "to the **numeric
coordinate** at which to slice" (schema) / "to a numeric coordinate"
(`esm-spec.md:2102`). Its sibling construct on assertions, `Assertion.coords`,
is documented in the *opposite* direction and emphatically so:

> Map from spatial index-set (dimension) name to a **1-based, fractional
> index-space position** along that interval index set — **not a physical
> coordinate** (§6.6.5 convention 1). (`esm-spec.md:1908`)

Two spatially-pinning constructs, added for the same PDE work, one paragraph of
spec apart, in two different coordinate spaces, with neither cross-referencing
the other. Resolved in **R12**.

### 3.2 "Plot axes are flexible" vs. the heatmap grid

`:2104` says:

> Any unknown, parameter, or swept-parameter name is allowed for `x`, `y`, and
> (for heatmaps) the `value.variable`.

Read literally this permits `type: "heatmap"` with `x: {variable: "t"}` and no
sweep at all. But §6.7.5 defines the heatmap by the sweep grid — "for each
Cartesian combination … places that scalar at **the corresponding grid cell**"
(`:2149`) — which has no referent unless `x` and `y` name swept dimensions. The
flexibility sentence and the worked example cannot both be right for heatmaps.
Resolved in **R7**.

### 3.3 One concept, two spellings

Tests carry `initial_conditions` / `parameter_overrides`; analyses carry
`initial_state` / `parameters`. These are the same two maps with the same
semantics against the same flattened system, and §6.6.2's override-key
resolution rule — the one MUST-level rule in this whole area — is written
naming only the test spellings. This RFC does **not** propose renaming
(it would be a MAJOR break for zero semantic gain, cf. D7 in
`unified-variable-model.md`); it proposes that §6.6.2 be generalized to name
both pairs (**R11**).

## 4. Rulings — the time axis

These five are one cluster. R1 is load-bearing: R2, R3, R4 and R5 are all
statements about a grid, and there is no grid until R1 says what it is.

### R1. The output time grid is uniform over `time_span`, defaulting to 101 points

`$defs.Analysis` has exactly six properties beyond `id`/`description`:
`initial_state`, `parameters`, `time_span`, `parameter_sweep`, `plots`,
`expression_template_imports`. There is no `saveat`, no sample count, no solver
tolerance. Yet a `line` plot of a variable against `t` *is* an output grid — the
plot has as many points as the run emitted.

| Option | Verdict |
|---|---|
| (a) Solver-natural steps | **Reject.** Julia's Tsit5 and Rust's diffsol BDF will never take the same steps. Every line plot would have a different point count per binding, and every grid-dependent reduction would differ numerically. This is the option that makes cross-binding agreement structurally impossible. |
| (b) A fixed uniform grid pinned in prose | **Recommend.** Deterministic, needs no schema change, available today. |
| (c) A new `saveat` property | **Recommend as an additive escape hatch, deferred.** |

**Ruling.** An analysis emits its trajectories on a **uniform grid over
`[time_span.start, time_span.end]`, inclusive of both endpoints**, obtained by
evaluating the solver's dense output at those times — *not* by reporting the
solver's own steps. The default point count is **101** (100 intervals). A future
optional `saveat` property (a number read as a step, or an array read as
explicit times) MAY override it.

Two things about this ruling matter more than the number 101.

**First**, dense-output evaluation onto a pinned grid is the only mechanism by
which a Tsit5 run and a BDF run can agree at all: they agree to solver tolerance
at times both were asked about, and they agree about nothing if each reports its
own steps.

**Second**, and this is the design goal that makes the arbitrariness of "101"
acceptable: **R2 and R3 are deliberately specified so that the grid does not
affect a scalar output.** A time-weighted mean and a trapezoid integral are
grid-*convergent*, so a change of default (or an author's `saveat`) perturbs
them only by discretization error, never categorically. The one place the grid
genuinely leaks into a scalar is `max`/`min` (R2), and that leak is acknowledged
rather than papered over. So 101 sets plot resolution, and almost nothing else.

**Cost.** The default is prose-only. `saveat` is a MINOR schema addition
(new optional field, per SCHEMA_CHANGE_PROCEDURE's bump table) touching the
`Analysis` type in all five bindings — and **no other ruling in this RFC depends
on it**. Recommend the prose default now and `saveat` only if an executor is
ever built.

### R2. `mean` is time-weighted; `max`/`min`/`final` are over the emitted grid

`PlotValue.reduce` accepts `max`, `min`, `mean`, `integral`, `final`, described
only as "max/min/mean over the run, time integral, or the final value"
(schema) — which does not distinguish an arithmetic mean of samples from a time
average.

**Ruling.** `mean` is the **time-weighted** average
`(∫ u dt) / (time_span.end − time_span.start)`, computed by the trapezoid rule
over the emitted grid — i.e. exactly `integral / (end − start)` under R3.
`max`, `min` and `final` are taken over the **emitted samples**.

Reasoning. "Mean concentration over the hour" is a time average; that is what an
author means, and it is the only reading under which a non-uniform `saveat`
does not silently produce a wrong number. It also gives one definition instead
of two: `mean` is a derived spelling of `integral`, not a separate reduction. On
a uniform grid the two candidate readings differ only in the half-weighting of
the two endpoint samples, so choosing now is nearly free — and choosing later,
after `saveat` exists, would be a breaking change to emitted values.

`max`/`min` over the emitted samples is grid-dependent in a way `mean` is not:
a sharp peak between two samples is missed. The exact alternative (root-finding
on `du/dt` over the dense output) is not something any binding does, and would
be solver-dependent anyway. Under R1's pinned grid the sample-wise maximum is at
least *deterministic across bindings*, which is the property this repo needs.
Determinism, not exactness, is the contract — state that in the spec rather than
implying an exact extremum.

`final` is the value at `time_span.end`, which R1's endpoint-inclusive grid
guarantees is an emitted sample. This is why `:2131` is right to call `final`
the preferred idiom.

**Also flag**, in the spec: `mean` in §6.6.5 (assertions) reduces over **space**;
`mean` in §6.7.4 (analyses) reduces over **time**. Same word, different axis,
different measure. They should each cross-reference the other so nobody
"unifies" them.

### R3. `integral` is the physical-time integral, *deliberately* unlike the assertion `integral`

The sibling assertion reduction was never pinned in the spec either; it was
pinned in implementation comments, identically across three bindings
(`pkg/earthsci-ast-rs/src/pde_inline_tests.rs:18–42`, and the Julia/Python
mirrors), with the reason stated plainly: "the esm-spec leaves these open, so
determinism requires pinning them." Convention 2 there is:

> `integral` reduce — the uniform-cell Riemann sum under a **UNIT total domain
> measure** per axis: `integral = Σ field / N_cells = mean(field)`. Authors of
> non-unit physical domains must scale the expectation until the spec grows a
> measure concept.

**Ruling.** The analysis `integral` is `∫ u dt` over `[start, end]` **in the
component's time units**, by the trapezoid rule over the emitted grid,
**not normalized**.

This does not match the assertion pinning, and the divergence is principled
rather than sloppy. The unit-measure convention exists because the spec has no
*spatial* measure: cell widths are not derivable from an index set, so §6.6.5
had no honest alternative to normalizing and telling authors to scale. Time has
no such gap — `time_span` supplies real bounds in real units, so `∫ u dt` is
well-defined with no invented measure. Adopting the unit-measure convention
here would discard information the format actually has, purely for verbal
consistency with a workaround.

The consequence to write down explicitly, because it will otherwise burn
someone: within assertions `mean == integral`; within analyses
`mean == integral / (end − start)`. Each is right for its axis; neither should
be "fixed" to look like the other. If the spec ever grows a spatial measure
concept, the §6.6.5 convention should converge on *this* one, not the reverse.

### R4. `at_time` interpolates linearly on the emitted grid

`:2133` explicitly declines this. A cross-binding corpus cannot leave it open:
snap and interpolate give different numbers, and *which* sample snapping picks
depends on R1's arbitrary point count.

**Ruling.** `at_time` is evaluated by **linear interpolation between the two
bracketing emitted samples**. `at_time` outside `[time_span.start,
time_span.end]` is an error (the schema already says "must lie within" for the
field-plot `at_time` at `:2101`; extend that to `PlotValue.at_time`).

Two deliberate choices inside this ruling:

- **Interpolate rather than snap**, because snapping makes a scalar output
  depend on the grid count — reintroducing exactly the coupling R1 was
  constructed to remove.
- **Interpolate on the *emitted* grid, not on the solver's dense output**, even
  though the dense output is more accurate. Tsit5's interpolant and a BDF's are
  different polynomials of different order; interpolating there would put
  solver identity back into an output byte. Choosing the lower-order,
  reproducible option is the point.

Note that `:2131` already anticipates this reading — it recommends `final`
because it "does not require the runtime to interpolate onto a specific output
time," which presumes interpolation is what `at_time` otherwise does.

**This is the only ruling in the RFC that reverses existing spec text** rather
than filling a silence. `:2133` would be replaced.

### R5. Absent both `at_time` and `reduce`, `PlotValue` defaults to `reduce: "final"`

The schema requires only `variable` on `PlotValue`, and both spec and schema say
"exactly one of `at_time` or `reduce` **should** be specified" — `should`, not
`must`. A document with neither is schema-legal and semantically undefined.

**Ruling.** Default to `reduce: "final"`.

Reasoning: it is the spec's own stated preferred idiom (`:2131`); it is the only
candidate needing no additional information; and it keeps every currently-valid
document valid. The alternative — making one of the two required — is a MAJOR
schema change (tightening) that would invalidate files for no benefit.

**Cost.** The ruling is prose. Optionally, tighten the schema *description* to
state the default (PATCH). Do **not** add a `required`/`oneOf`.

## 5. Rulings — plots over a sweep

### 5.1 R6. `line`/`scatter` under a sweep: one series per (declared series × sweep point)

The fixture already asserts the intended behavior in its own prose —
`tests/valid/tests_analyses_comprehensive.esm` describes its sweep line plot as
"Population trajectories for **each** r in the sweep, overlaid on one axis."
The spec body never says this.

**Ruling.** Under a sweep, a `line`/`scatter` plot emits the Cartesian product
of its resolved series list (after the `y`-array rewrite) and the sweep points.
Each emitted series carries its **structural** sweep coordinate — the
`{parameter: value}` map and the integer grid index of its run — alongside its
data.

**The human-readable label is not specified, and should not be.** It is exactly
the "styling is the viewer's concern" case at `:2082`: a viewer that knows the
units can render `r = 0.5 s⁻¹`, and a spec-mandated label string would have to
pin float formatting, which is a genuine cross-binding hazard (`1e-6` formats as
`0.000001` in Rust's `Display`, `1e-06` in Python's `repr` and Go's `%g`). Emit
the coordinate; let the viewer name it. This is one of the sub-items that
should stay undefined.

The alternatives — plotting the first sweep point only, or erroring — are both
worse: the first silently discards 99% of the runs behind a plausible-looking
picture, and the second makes the fixture's own documented intent illegal.

### 5.2 R7. A `heatmap` requires a sweep, and its `x`/`y` MUST name swept dimensions

This is the §3.2 contradiction. §6.7.5's "the corresponding grid cell" has no
meaning without a sweep grid.

**Ruling.** `type: "heatmap"` with no `parameter_sweep`, or whose `x.variable`
or `y.variable` does not name a swept dimension, is a **validation error** —
diagnosable statically, before any run. Narrow `:2104` so the "any name is
allowed" flexibility is scoped to `line`/`scatter` axes and to the heatmap's
`value.variable` (which is correctly free — it names a model variable, not an
axis).

Suggested diagnostic codes, following the existing naming style:
`analysis_heatmap_requires_sweep`, `analysis_plot_axis_not_swept`.

Note this is **validator work, not schema work** — "`x.variable` names a swept
parameter" is a cross-field constraint JSON Schema cannot express. That is true
of most of §5 and §6, and it is why gt-y8ts (§8) is the natural home for them.

### 5.3 R8. A `heatmap` requires the sweep to have exactly the two plotted dimensions

**Ruling.** If any swept dimension is named by neither `x` nor `y`, that is a
validation error. A 1-D sweep with a heatmap is already an error under R7.

Reasoning: the two silent alternatives — take the first slice along the extra
dimension, or reduce over it — both discard runs, and §6.7 provides no
construct to say *which* slice or *which* reduction. An error is the only
honest answer given the available vocabulary.

Record, but do not add: the natural future extension is to let `pinned_coords`
pin extra **sweep** dimensions the way it pins extra **spatial** ones. That is
a coherent design and costs a schema description widening; it should wait until
someone actually wants a 3-D sweep rendered as a heatmap.

### 5.4 R9. Sweep enumeration is row-major over `dimensions` in declaration order

§6.7.5 says "the corresponding grid cell" and never defines the correspondence.
Ordering determines output ordering, so it is an output byte.

**Ruling (R9a — point order).** Sweep points are enumerated **row-major
(odometer order)** over `parameter_sweep.dimensions` in declaration order, with
the **last** dimension varying fastest. Run index `n` maps to grid index
`(i₀, …, i_{k−1})` by the usual mixed-radix decomposition. Within a dimension,
`values` are visited in **authored order** — never sorted, because an author may
have ordered them deliberately and sorting would silently reorder a plot's
axis.

**Ruling (R9b — range arithmetic).** The `range` form's arithmetic is not given
in the spec, only its intent. Pin it:

- `linear`: `v_i = start + i · (stop − start) / (count − 1)`, `i ∈ [0, count)`
- `log`: `v_i = exp( log(start) + i · (log(stop) − log(start)) / (count − 1) )`

Both endpoint-inclusive; `count ≥ 2` is already enforced by the schema, so
`count − 1` is safe. This is a last-ulp pin — `exp(lerp(log))` and
`start · (stop/start)^(i/(n−1))` are mathematically identical and numerically
are not — and it only matters if a conformance golden ever compares exactly.
Pin it anyway; it costs one sentence and it is the kind of thing that is
impossible to change later.

## 6. Rulings — run configuration

### 6.1 R10. A swept parameter overrides `analysis.parameters` — and the spec already says so

**This item needs no new ruling.** §6.7.1's own normative example settles it:
it declares `parameters: {"k_NO_O3": 1.8e-5}` and *also* sweeps `k_NO_O3` over
`{start: 1e-6, stop: 1e-4, count: 10, scale: "log"}` (`:2016–2027`). Any rule
other than "the sweep wins" makes the spec's own worked example either an error
or a no-op sweep.

**Ruling.** `analysis.parameters` sets the baseline for the analysis; a sweep
dimension varies its parameter away from that baseline. Not an error. Add one
clarifying sentence to §6.7.3 pointing at the example.

This reading has a pleasant property worth naming: deleting `parameter_sweep`
from any analysis leaves a runnable single-run analysis at the declared
baseline.

### 6.2 R11. §6.6.2 override-key resolution extends to analyses

§6.6.2 (`esm-spec.md:1880–1896`) specifies a three-rule precedence for resolving
locally-spelled override keys against a flattened system (exact hit → dotted key
with flattened trailing segment → bare key uniquely matching one trailing
segment), and a MUST-level rule that an unresolvable key is rejected with an
`unknown`-vs-`ambiguous` distinction. It is written naming `parameter_overrides`
and `initial_conditions` — the test spellings (§3.3).

**Ruling.** The same rules apply verbatim to `analysis.parameters`,
`analysis.initial_state`, and `parameter_sweep.dimensions[].parameter`.
Generalize §6.6.2's paragraph to name all of them rather than duplicating it
into §6.7.

Reasoning. The rule is a property of *name resolution against a flattened
system*, not of the `tests` construct; nothing in it is test-specific. §6.6.2's
own rationale — that silent ignoring "produces a wrong answer rather than a
missing one" — applies with at least equal force here: an unrecognized key in an
analysis means the plot shows the default configuration while claiming to show
the overridden one, with no verdict line to hint otherwise.

The **sweep-parameter case is the strongest of the three**. A mistyped sweep
parameter produces N *successful* runs that are all identical, rendered as a
perfectly flat heatmap — a wrong picture that looks like a finding.

**Cost.** Prose-only, and cheap in the one binding that would execute first:
Rust already has this factored out as
`simulate::canonicalize_override_keys` (`pkg/earthsci-ast-rs/src/simulate/override_keys.rs`),
with Julia's `_canonicalize_override_keys` and Python's `canonicalize_override_keys`
as documented mirrors. The change is a call site, not an algorithm. Because
flattening is in the **core** capability profile, TypeScript and Go can enforce
the key-resolution *validation* even though they never simulate.

## 7. Rulings — field plots, output, and failure

### 7.1 R12. `pinned_coords` is a physical coordinate; the spec's own example proves it

The §3.1 contradiction. Options are physical space (as `pinned_coords`' own text
says) or index space (as the sibling `coords` says).

**Ruling.** **Physical coordinate**, as written. Resolve an off-grid coordinate
to the **nearest cell center**, with exact half-way ties rounding **down**
toward the lower index — reusing §6.6.5 convention 1's tie rule for the *snap*
even though the space differs. A coordinate outside the dimension's extent is an
error.

Four reasons, the second of which is close to decisive:

1. `pinned_coords`' text says "numeric coordinate" in both the spec and the
   schema, is the later-written of the two, and is unambiguous on its face.
2. **The spec's own example is invalid under the index-space reading.**
   `:2176` gives `"pinned_coords": {"z": 0.0}`. Index sets are 1-based
   (§6.6.5 convention 1), so index `0.0` is out of range — the example would be
   an error. As a physical coordinate, `z = 0.0` is the natural domain edge and
   the example reads correctly.
3. Analyses are viewer-facing by the spec's own framing. A plot caption says
   "slice at z = 0 m"; it does not say "slice at cell 1."
4. The reason `coords` is index-space does not transfer. An assertion is a claim
   about *numerical behavior at grid points* and must stay stable when the
   physical extent changes; a plot is a claim about *physics* and must stay
   stable when the resolution changes. Opposite requirements, opposite answers.

**Snap rather than interpolate here**, unlike R4, because the other axes of a
field plot *are* the grid: the plot's purpose is to show the discrete solution,
and "a slice through the field" ordinarily means a row of cells. Spatial
interpolation would also require cell geometry the plot spec does not carry.
The plot-level `at_time` on field plots still interpolates, per R4 — time and
space differ here, and the spec should say why in one sentence rather than
leaving a reader to assume an inconsistency.

Whichever way this is ruled, **the two paragraphs must cross-reference each
other.** Two spatially-pinning constructs one section apart in different
coordinate spaces is a trap regardless of which space each one picks.

### 7.2 R13. Specify the *value* an execution produces; do not specify a directory layout

No output contract for analyses exists anywhere — not in `esm-spec.md`, not in
`CONFORMANCE_SPEC.md` (which mentions analyses only descriptively, at §2.2.5),
not in `API_SPEC.md`.

**Ruling.** If an executor is ever built, its contract is a **library return
value** with a specified shape, plus **one canonical JSON serialization** of
that shape for tooling and conformance. Do **not** mandate an on-disk layout
(a file per analysis, a directory per component, naming conventions): that is
CLI ergonomics, it varies legitimately between bindings, and this repo's
cross-binding contract has always been on values.

Illustrative — **not** a normative schema, and deliberately not written as one:

```jsonc
{
  "analysis": "rate_constant_sweep",
  "grid": [0.0, 36.0, /* … */ 3600.0],        // R1
  "runs": [
    { "index": [0, 0],                          // R9a grid index
      "sweep_point": { "j_NO2": 0.001, "k_NO_O3": 1e-6 },
      "retcode": "success",                     // R14
      "series": { "O3": [/* … */], "NO": [/* … */] } }
  ],
  "plots": [ { "id": "o3_vs_rates", "type": "heatmap", "data": /* … */ } ]
}
```

Two notes on placement. First, this is an **output** document, so it costs a
spec appendix, **not** a change to `esm-schema.json` and **not** a format
version bump — a meaningfully cheaper class of change than it first appears.
Second, `streaming-output-sinks.md` is already designing where trajectory
output goes; an analysis result should be expressed through that machinery
rather than inventing a parallel writer. If that RFC lands first, R13 mostly
reduces to "an analysis result is N sink writes plus a manifest."

### 7.3 R14. A failing run inside a sweep punches a hole; a failing single run is an error

**Ruling.**

- **Under a sweep:** continue. Record the failing run's retcode, emit `null`
  (JSON has no NaN) for every plot cell that run would have filled, and make the
  analysis result carry a non-empty failure list so a caller can distinguish
  "ran clean" from "ran with holes."
- **With no sweep:** a failing run is an **error**. There is nothing to salvage
  and an empty plot would be indistinguishable from a flat one.

Reasoning. Finding where a model breaks is frequently the *point* of a sweep —
aborting at run 137 of 200 destroys 199 good runs precisely at the interesting
boundary, and a heatmap with a hole in the stiff corner is informative output,
not a failure. But silence is unacceptable: a hole that is not also reported
structurally is indistinguishable from a hole in the model's physics. Emit
both.

The `null`-not-NaN detail is an output byte and belongs in the spec text:
bindings that hold NaN internally must serialize it as `null`, and a viewer
must treat `null` as "no run," not "zero."

## 8. Related work: gt-y8ts

`1a9279cd3` (the PDE extension that added `field_slice`, `field_snapshot`,
`at_time`, and `pinned_coords`) filed a follow-up, **gt-y8ts**, for per-binding
**structural validation** of the `tests` and `analyses` blocks. It was never
done — the identifier appears nowhere in the tree.

That ticket is the natural home for R7, R8, R11 and the range/extent checks in
R9b and R12, all of which are static, run-free, and expressible as validator
rules. It is worth doing **independently of any executor**, which is the single
most useful observation in this RFC: today a heatmap with no sweep, a
`pinned_coords` key naming a dimension that is not in the domain, an `at_time`
outside `time_span`, and a sweep over a misspelled parameter all validate
cleanly and travel in a published component. Validation is a prerequisite for
execution, but its value does not depend on execution ever happening.

## 9. Cross-binding cost

Current state of §6.7 support:

| Binding | Profile (`API_SPEC.md:165–177`) | §6.7 today |
|---|---|---|
| Rust | core + classification + **simulation** + runtime I/O | Typed (`src/types/analysis.rs`), round-trips (`tests/round_trip.rs:550`) |
| Python | core + classification + **simulation** + runtime I/O | Typed (`esm_types.py:670`), round-trips (`test_roundtrip.py:320`) |
| Julia | core + classification + **simulation** + runtime I/O | **No `Analysis` type at all.** Schema-validated on load, not exposed to consumers; the MTK exporter emits an empty placeholder array (`test/mtk_export_test.jl:103`) |
| TypeScript | core + classification (**non-simulating**) | Typed (`src/generated.ts:1242`), parse-tested |
| Go | core + classification (**non-simulating**) | Typed, round-trips (`tests_analyses_roundtrip_test.go`) |

`API_SPEC.md:172` is explicit: "**TypeScript and Go are deliberately
non-simulating.** … A `simulate` missing from Go is conformance, not a gap."
So no execution ruling below can imply work in those two.

| Ruling | Class | Julia | Python | Rust | TS | Go |
|---|---|---|---|---|---|---|
| R1 default grid | prose | exec | exec | exec | — | — |
| R1 `saveat` | **schema (MINOR)** | type | type | type | type | type |
| R2 `mean`, `max`/`min`/`final` | prose | exec | exec | exec | — | — |
| R3 `integral` | prose | exec | exec | exec | — | — |
| R4 `at_time` interpolation | prose (**reverses `:2133`**) | exec | exec | exec | — | — |
| R5 default `reduce` | prose + schema **description** (PATCH) | exec | exec | exec | — | — |
| R6 series per sweep point | prose | exec | exec | exec | — | — |
| R7 heatmap requires sweep | prose | **validate** | **validate** | **validate** | **validate** | **validate** |
| R8 heatmap dimensionality | prose | validate | validate | validate | validate | validate |
| R9a/R9b enumeration | prose | exec | exec | exec | — | — |
| R10 sweep beats `parameters` | prose (clarification of existing example) | exec | exec | exec | — | — |
| R11 override-key resolution | prose | validate + exec | validate + exec | validate + exec | validate | validate |
| R12 `pinned_coords` space | prose (**resolves a contradiction**) | exec | exec | exec | validate | validate |
| R13 output contract | spec appendix (**not** `esm-schema.json`) | exec | exec | exec | — | — |
| R14 failure handling | prose | exec | exec | exec | — | — |

Three observations:

1. **The validation column is the cheap, five-binding column.** R7, R8, R11 and
   part of R12 are static checks that every binding can already perform, because
   flatten and parse are both in the core profile. This is gt-y8ts.
2. **The execution column is a three-binding column, and Julia's entry is
   larger than the others' because Julia has no types yet.** Julia owes a parse
   / round-trip implementation of §6.7 regardless of any ruling here; it is the
   one binding that cannot even carry an analysis through `parse → emit` today.
3. **Only one ruling touches `esm-schema.json` in a version-bumping way**, and
   it is the one that can be deferred indefinitely.

## 10. Recommendation

**Adopt the rulings as spec prose. Do not build an executor now.**

Reading §6.7 end to end, these blocks are declarative metadata for external
tooling, and the spec says so in as many words: analyses "do not produce
pass/fail outcomes," only "structural information is recorded," and styling "is
the viewer's concern." Nothing consumes an analysis inside this repo. The
construct exists so that a plotting front-end, a documentation generator, or a
model browser can render a component's intended use without the `.esm` author
having to ship a notebook alongside it. That is a good reason for the block to
exist and a poor reason for five bindings to grow an execution engine — and an
RFC that quietly converted `analyses` into one would be overreaching past what
the spec asks for.

So the value of settling these fourteen items is **not** that it unblocks a
build. It is that:

- The questions stop recurring. Each one has now been derived from scratch at
  least twice; writing the answer down once is cheaper than deriving it a third
  time.
- **Twelve of fourteen are free** — spec prose, no schema, no version bump, no
  binding work until someone executes. One more is a schema *description*. The
  only expensive item is deferrable and nothing depends on it.
- The two genuine defects surface and get fixed on their own merits: the
  `pinned_coords` / `coords` contradiction (§3.1) is a live authoring trap
  independent of execution, and the heatmap flexibility sentence (§3.2)
  contradicts the worked example three paragraphs later.
- gt-y8ts becomes actionable, and it is worth doing on its own: today a
  meaningless analysis validates cleanly and ships inside a published
  component.

Concretely, in priority order:

1. **Fix the contradictions** (§3.1, §3.2) and add the `mean`-axis
   cross-reference from R2. Pure defect repair; do this whatever else happens.
2. **Land R2–R12, R14 as spec prose.** No schema change, no bump, no binding
   work. This is the body of the RFC and it is nearly free.
3. **Do gt-y8ts** — R7, R8, R11 and the static parts of R9b/R12 as validator
   rules in all five bindings. Independently valuable.
4. **Give Julia the `Analysis` types**, closing the one round-trip gap in the
   five-binding parse/emit contract.
5. **Defer R1's `saveat` and R13's output appendix** until an executor is
   actually wanted. Neither blocks anything above.

If the answer to "should we execute analyses?" is ever yes, R1 through R14 are
what that executor would be written against, and the reason this document says
so now is that answering them *before* someone starts is the only way five
bindings end up agreeing.
