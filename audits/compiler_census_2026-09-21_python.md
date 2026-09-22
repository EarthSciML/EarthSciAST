# Compiler census — Python binding

**Branch** `compiler/census-python`, from `compiler-selection` at `4d03022b9`.
**Date** 2026-09-21.
**Scope** phase 0 of the "Choosing the Compiler" plan, Python binding only.
Corpus: every `.esm` under `EarthSciAST/tests/` and under `EarthSciModels/`.
Code read at `pkg/earthsci-ast-py/src/earthsci_ast/`.

Nothing in `src/` was modified. The one file added is
`pkg/earthsci-ast-py/scripts/compiler_census.py`, the sweep that produced §1.

---

## 0. What this measures, and the one thing that surprised us

The plan's phase 0 asks, for Python: *which rules land per-cell under a
NumPy-for-everything default, and why*. The Python binding has two levels of
choice, neither exposed to a caller.

* **The route.** `_choose_pathway` (`problem.py:741`, called once at
  `problem.py:666`) picks `discrete_providers`, `array`, `loaders` or `scalar`
  from the document's own content. `scalar` is lambdified SymPy; the other three
  are the NumPy interpreter.
* **The tier.** Inside the NumPy route, `_eval_faq` (`numpy_interpreter.py:2311`)
  runs a ladder of whole-box fast paths, each declining by returning `None`, and
  the bottom of the ladder is `_eval_faq_scalar` (`numpy_interpreter.py:3834`) —
  one Python tree walk per output cell per contraction point. Nothing anywhere
  records which tier ran.

Under the planned strict `native` compiler, "whole-box vectorized NumPy for
every document", a landing on `_eval_faq_scalar` is a refusal. So the census
counts landings.

### Headline

* 1217 documents swept, all recorded. **764 build** with `esm_problem` defaults —
  525 `scalar`, 206 `array`, 33 `loaders`, 0 `discrete_providers` — and 730 of
  those also evaluate their right-hand side.
* Under a forced NumPy array pathway: **765 build, 732 evaluate, 719 with zero
  per-cell landings and 13 with per-cell landings.** No document builds under the
  default router and fails to build under forced NumPy.
* **All 13 already route to the NumPy engine today.** Not one document currently
  on the SymPy pathway acquires a per-cell landing when it is moved to NumPy, so
  the refusal surface a strict `native` default creates is the surface that
  already exists, unrecorded, inside today's array pathway.
* **The whole EarthSciModels corpus is clean**: of its 345 buildable documents,
  none contains a single `faq` node and none lands per cell.
* **No cost decline fired anywhere.** Every landing the census saw is a shape the
  fast tiers cannot express (18 nodes) or a recurrence the spec forbids
  vectorizing (3 nodes).

### The one thing that surprised us

**Almost all the landings happen at BUILD, not in the right-hand side** — 18 of
21. The plan's §3.4 says Python's ladder "decides at evaluation time", so
`native` should evaluate the RHS once at construction to turn a landing into a
build error. That is true but incomplete: the const-geometry hoist and the
static-observed materialization evaluate aggregates during `esm_problem` itself,
before any RHS exists. A `native` compiler that probes only `rhs_function` would
pass ten of the thirteen documents that must refuse: only three
have a per-cell landing during the RHS call at all. The census therefore
instruments both phases, and the recorder the plan's §3.3 asks for has to cover
the whole of construction rather than one RHS call.

---

## 1. Corpus census

1217 documents: 859 `.esm` under `EarthSciAST/tests/` and 358 under
`EarthSciModels/`. One subprocess per document, 180 s timeout, 6 GiB
address-space cap, 8 in flight, on a `secondary` compute node.

**Every document produced a record.** No timeout, no crash, no out-of-memory —
including `isrm.esm` and `geoschem_fullchem.esm`, which are the known hazards
elsewhere. They are cheap here because the census builds each document as
authored, with no grid injected; the `isrm.esm-class` out-of-memory is a
grid-injected build, which this sweep does not do. Read the numbers below as
*the documents as they sit in the corpus*, not as the configurations a driver
runs them in.

### 1.1 What builds today

| | tests/ | EarthSciModels/ | total |
|---|---:|---:|---:|
| documents | 859 | 358 | 1217 |
| built with `esm_problem` defaults | 419 | 345 | **764** |
| built **and** right-hand side evaluates at (u0, p, t0) | 389 | 341 | **730** |

Pathway, for the 764 that build:

| pathway | tests/ | EarthSciModels/ | total | of which the RHS also evaluates |
|---|---:|---:|---:|---:|
| `scalar` (lambdified SymPy) | 191 | 334 | **525** | 514 |
| `array` (NumPy interpreter) | 206 | 0 | **206** | 183 |
| `loaders` (cadence-segmented NumPy) | 22 | 11 | **33** | 33 |
| `discrete_providers` | 0 | 0 | **0** | — |

`discrete_providers` never occurs: it needs a caller-supplied provider that
declares refresh times, which no document can ask for on its own.

The 453 documents that do not build are overwhelmingly deliberate — `tests/`
holds 155 documents under `invalid/` plus libraries with no model, version-
compatibility fixtures and future/robustness probes. The leading classes:

| exception / code | count |
|---|---:|
| `StructuralValidationError` | 95 |
| `SchemaValidationError` | 77 |
| `ValueError` | 62 |
| `ExpressionTemplateError` | 54 |
| `UnsupportedConstructError` / `unsupported_construct` | 37 |
| `UnsupportedDimensionalityError` / `unlowered_operator` | 31 |
| `UnreachableSpatialOperatorError` / `unlowered_operator` | 23 |
| `JSONDecodeError` | 18 |
| `ConstArrayOutOfRangeError` | 8 |
| `ValueInventionError` / `derived_index_set_unmaterialized` | 6 |
| `UnsupportedVersionError` | 6 |
| 16 further classes | 1–5 each |

A further 34 build but their right-hand side does not evaluate under the
default router either (22 `SimulationError`, 7 `NameError`, 2 `IndexError`, and
one each of `ValueError`, `TypeError`, `ZeroDivisionError`). Most are documents
that need a provider or an initial condition the census does not supply. They
are excluded from the comparison below rather than counted against either
engine.

### 1.2 Under a forced NumPy array pathway

`_choose_pathway` monkeypatched to return `"array"` for every document (what
issue #425 did; no source edited), then the compiled RHS evaluated once at
(u0, p, t0) through `build.rhs_function(t0, build.y0)`, with the faq ladder
instrumented across BOTH the build and that evaluation.

| | count |
|---|---:|
| builds under forced NumPy | **765** (one more than the default router) |
| builds **and** the RHS evaluates | **732** |
| of those, **zero** per-cell landings | **719** |
| of those, **with** per-cell landings | **13** |
| builds under the default router but NOT under forced NumPy | **0** |
| runnable under the default router but NOT under forced NumPy | **6**, all an artifact — see §1.4 |

The one document that builds only under the forced pathway is
`tests/conformance/operator_compose_merge/fixtures/owner_rename_state_wins_observed_first.esm`,
which the SymPy pathway refuses with `Cyclic algebraic equations detected:
Sink.O3 -> Sink.O3` and the NumPy build accepts.

**The EarthSciModels corpus contributes nothing to the refusal surface.** Of its
345 buildable documents, 334 route to `scalar` and 11 to `loaders`, **none**
contains a single `faq` node, and **none** has a per-cell landing under forced
NumPy. Whatever it costs to move those documents from SymPy to vectorized NumPy,
it is not a refusal.

### 1.3 The 13 documents that walk per cell

Every one of them is `tests/`, and **every one of them already routes to the
NumPy engine today** — 12 to `array`, 1 to `loaders`. Not one document currently
on the SymPy pathway acquires a per-cell landing when it is moved to NumPy. The
refusal surface a strict `native` default creates in Python is therefore the
surface that already exists, unrecorded, inside today's array pathway.

| document (under `tests/`) | default pathway | faq nodes per cell | landings | output cells walked | phase |
|---|---|---:|---:|---:|---|
| `valid/geometry/conservative_regrid_assembly.esm` | array | 1 | 1 | 16 | build |
| `valid/faq/nearest_generator_centroid.esm` | array | 4 | 4 | 13 | build |
| `valid/wildfire_atmosphere_ocean.esm` | array | 1 | 1 | 12 | build |
| `coupling/cross_domain_coupling.esm` | array | 1 | 1 | 12 | build |
| `conformance/pushdown/fixtures/pushdown_polygon_area.esm` | array | 2 | 2 | 6 | build |
| `valid/faq/ragged_member_gather.esm` | array | 1 | 1 | 3 | rhs |
| `conformance/expression_templates/import_rebind_keyed_factors/fixture.esm` | array | 1 | 1 | 3 | rhs |
| `conformance/expression_templates/import_rebind_keyed_factors/expanded.esm` | array | 1 | 1 | 3 | rhs |
| `conformance/build_once_spatial_field/fixtures/build_once_spatial_ode.esm` | array | 1 | 1 | 3 | build |
| `valid/recurrence_causal_self_reference.esm` | array | 1 | 6 | 1 | build |
| `fixtures/recurrence/07_recurrence_thirty_eight_lags.esm` | array | 1 | 40 | 1 | build |
| `fixtures/recurrence/04_recurrence_banded_lag_fold.esm` | array | 1 | 6 | 1 | build |
| `valid/data_sources_ingest_and_select.esm` | loaders | 1 | 1 | 0 | build |

A further 12 documents record a per-cell landing but their forced-NumPy RHS
raises before finishing, so they are not in the table: they are counted in the
decline histogram below and listed in §1.4.

Two things the cell counts do NOT say. First, they are the corpus's own sizes,
which are fixture-scale — the largest per-cell box in the whole corpus is 16
cells. A refusal is a refusal regardless of size, but nothing here measures what
these shapes cost at production resolution. Second, "landings" counts entries
into `_eval_faq_scalar`, not cells walked: the 38-lag recurrence enters 40 times
over a 1-cell output box, because a recurrence sweep re-enters per sweep step.

### 1.4 Why the per-cell landings are mostly at BUILD

| phase | per-cell node landings |
|---|---:|
| build (const-geometry hoist, static-observed materialization) | **18** |
| right-hand side evaluation | **3** |

This is the census's main structural finding and it bears on the plan's §3.4.
The plan proposes that `native` evaluate the RHS once at construction so a
per-cell landing becomes a build error. That is necessary but not sufficient:
six sevenths of the landings happen inside `esm_problem` itself, before any RHS
exists, while the const-geometry hoist and the static observeds are being
materialized. Only three of the thirteen documents in §1.3 land per cell during
the RHS call — `ragged_member_gather.esm` and the two
`import_rebind_keyed_factors` fixtures. A `native` probe that only calls
`rhs_function` would pass the other ten, including all three recurrence
fixtures and both regrid assemblies. The recorder the plan's §3.3 asks for has
to sit at `_eval_faq_scalar` for the whole of construction, not around one RHS
call.

### 1.5 Decline reasons

One count per faq node that landed per cell, over both phases. The chain is read
fastest-tier-first; each entry is the tier and the exact line it returned `None`
from.

| count | chain |
|---:|---|
| 4 | `_eval_faq_batched_leaf@:2254` → `_eval_faq_prefix_scan@:3778` → `_eval_faq_operator_cached@:3488` → `_eval_faq_reduce_vectorized@:3635` |
| 3 | `_eval_faq_batched_leaf@:2254` → `_eval_faq_vectorized@:1742` → `_eval_faq_contraction_broadcast@:2141` |
| 3 | recurrence bypass, `:2430` — no tier attempted |
| 3 | `_eval_faq_batched_leaf@:2259` → `_eval_faq_vectorized@:1693` → `_materialize_map@:1984` |
| 3 | ragged contracted range, `:2555` → `_eval_faq_ragged` — no tier attempted |
| 2 | `_eval_faq_batched_leaf@:2254` → `_eval_faq_prefix_scan@:3778` → `_eval_faq_operator_cached@:3488` → `_eval_faq_reduce_vectorized@:3663` |
| 1 | `_eval_faq_batched_leaf@:2261` → `_eval_faq_vectorized@:1693` → `_materialize_map@:1984` |
| 1 | `_eval_faq_batched_leaf@:2254` → `_eval_faq_vectorized@:1693` → `_eval_faq_contraction_broadcast@:2141` |
| 1 | `_eval_faq_batched_leaf@:2254` → `_eval_faq_vectorized@:1751` → `_eval_faq_contraction_broadcast@:2141` |

Grouped by what the chain means, the whole refusal surface is five things:

| cause | nodes | class (§2) |
|---|---:|---|
| a join/filter-gated node with **no contraction** — every gated tier needs one, and `_materialize_map` is unreachable from the gated branch (`:3635`) | 4 | capability |
| the whole-box contraction's body **rejects array-bound index symbols** (`:2141`), after the einsum path declined on a subscripted parameter (`:1742`) or an unresolvable name (`:1751`) | 5 | capability |
| a recurrence sweep (`:2430`) | 3 | correctness-mandated, CONFORMANCE_SPEC §5.19.2 |
| a ragged contracted range (`:2555`) | 3 | capability |
| the whole-box **pure map** raised a narrow error (`:1984`) — in this corpus always because a loader-injected array was not supplied, so these are census artifacts, not gaps | 4 | capability (unconfirmed) |
| a join key that is not an axis of the combined box (`:3663`) | 2 | capability |

**No document in the corpus hit a cost decline.** `_CONTRACTION_BOX_CAP` was
never exceeded (the largest combined box in the corpus is far under 2²² cells),
`_EINSUM_MAX_LABELS` was never exceeded, and neither kill switch was set. The
cost/capability split the plan's ruling D6 asks phase 0 to produce comes out
almost entirely on the capability side — see §2.10.

### 1.6 The six documents the forced pathway loses, and why they are an artifact

| document | error under forced NumPy |
|---|---|
| `tests/conformance/refresh/fixtures/coupled_refresh_regrid.esm` | `Unresolved symbol: 'M.scale_tgt'` |
| `tests/end_to_end/land_atmosphere_hydrology.esm` | `Unresolved symbol: 'SurfaceEnergyBalance.sensible_heat_flux'` |
| `tests/valid/advection_reaction_loaded_ic_bc.esm` | `index applied to scalar value` |
| `tests/valid/cadence/loader_const_seed.esm` | `index applied to scalar value` |
| `tests/valid/cadence/loader_temporal_seed.esm` | `index applied to scalar value` |
| `tests/valid/data_sources_comprehensive.esm` | `Non-finite derivatives encountered` |

All six route to `loaders` by default. Forcing `_choose_pathway` to `"array"`
skips the cadence-segmented build, so the loader-injected arrays are never
materialized and the symbols that read them resolve to nothing. This is a
property of the CENSUS METHOD, not of the NumPy engine: the plan's phase 3 keeps
"the segmented provider and loader pathways … internal to both `native` and
`interpreter`", so a real `native` would run these documents exactly as today.
They are listed so the number is not mistaken for a refusal.

The remaining 27 documents whose forced-NumPy RHS raises fail under the default
router too — they are the same 27 in the "builds but does not run" bucket of
§1.1 — with one class worth naming because it is a genuine NumPy-pathway defect
rather than a missing input: four `deprecated_op_alias` fixtures and
`valid/faq/cross_model_from_faq.esm` / `node_addressing_from_faq.esm` all raise
`faq output index 'edge' has no declared range`, and four
`expression_templates` fixtures raise `D(TwoGrids.cf): RHS produced 14 elements
for a state of shape (16,)`. Those are bugs in the array build, visible today,
not consequences of anything in this plan.

---

## 2. Decline-site classification

Every decline in the faq ladder, with the class the plan's ruling D6 asks for:

* **capability** — the fast tier cannot express the construct at all; the path
  it lands on walks the tree per cell, so under strict `native` this is a
  refusal.
* **cost** — both the fast and the slow path can express it; a cap or a
  threshold chose. Under `native` a cost decline is only a refusal when the
  landing walks per cell; where the landing is another whole-box tier it is not.
* **correctness-mandated** — the spec requires the per-cell path. Still a
  refusal under `native`, but one that cannot be engineered away.

Two structural notes first, because they decide most of the table.

**A decline is not by itself a landing.** The ladder is seven tiers deep and
most of the declines below hand the node to another *whole-box* tier. Only a
decline by the LAST applicable tier reaches `_eval_faq_scalar`. The rows are
therefore classified by what the node lands on given that every subsequent tier
also declines — which is what the §1 sweep measures directly.

**The codegen tier is never a refusal.** `_codegen_box_fn`
(`numpy_interpreter.py:2030`) and `numpy_codegen.compile_box_body`
(`numpy_codegen.py:381`) sit *inside* `_eval_faq_contraction_broadcast` and
`_materialize_map`; when they decline, the caller falls back to
`_compile_expr(body)`, a compiled closure evaluated over the same whole box. The
answer and the shape are unchanged; only the Tier-1 source specialization is
lost. Every codegen row below is `cost`, and none of them is a `native` refusal.

### 2.1 The dispatcher: bypasses and landings (`_eval_faq`, `numpy_interpreter.py:2311`)

| file:line | trigger | landing | class |
|---|---|---|---|
| `numpy_interpreter.py:2430` → `:2431` | `ctx.recur is not None and not ragged_reduce` — a recurrence sweep | `_eval_faq_scalar`, no tier attempted | **correctness-mandated**. CONFORMANCE_SPEC §5.19.2: a binding "MUST NOT evaluate a recurrence definition through any path that reorders or batches its cells", and "`O(N)` running accumulation … is **not** available here as a rewrite". The comment at `:2421–2429` says the same. A refusal under `native`, permanently. |
| `numpy_interpreter.py:2418` (`overlap_gated`), consumed at `:2450`, `:2497`, `:2524` | any join clause carries a §5.5.6 spatial `overlap` gate | `_eval_faq_scalar` → `_eval_faq_scalar_gate_driven` (`:3902`) | **capability**. The gate DRIVES enumeration rather than filtering it; every dense tier would have to materialize the full `out × reduce` box and mask it, which is the `O(N_c·N_r)` work the broad phase exists to remove (the comment at `:2411–2416` cites 66.3M terms on `isrm.esm`). Declining is deliberate and correct; expressing it whole-box needs a new vectorized driven-enumeration tier, not a threshold change. |
| `numpy_interpreter.py:2555` → `:2556` | `ragged_reduce` — a contracted range resolves to a `_RaggedRange` | `_eval_faq_ragged` (`:2694`), per output cell | **capability**. A ragged bound depends on the enclosing output index via its `offsets` factor (RFC §5.2), so the contracted range is recomputed per output point; there is no dense box to build. |
| `numpy_interpreter.py:2541` | join and/or filter present, and every gated tier declined | `_eval_faq_scalar` with the gate | classified by the declining tier below |
| `numpy_interpreter.py:2634` | plain node, and every ungated tier declined | `_eval_faq_scalar` | classified by the declining tier below |
| `numpy_interpreter.py:2467` | `join`/`filter` **and** a ragged contracted range | raises `NumpyInterpreterError` | already a hard error, not a decline |

### 2.2 `_eval_faq_batched_leaf` (`numpy_interpreter.py:2223`) — the batched geometry leaf

Declines hand the node to the prefix-scan / operator / vectorized-reduce tiers
when gated, or to `_eval_faq_vectorized` when not. Only a node whose body IS the
planar `polygon_intersection_area` narrow phase can use it, so every row is a
shape test rather than a budget.

| file:line | trigger | class |
|---|---|---|
| `:2254` | `reduce_syms` non-empty (the node contracts) | **capability** (this tier is a pure map only) |
| `:2256` | `filter_expr is not None` | **capability** |
| `:2256` | `reducer != "+"` — a non-`sum_product` ⊕ | **capability** |
| `:2259` | body is not a `polygon_intersection_area` node | **capability** |
| `:2261` | `manifold != "planar"`, or arity ≠ 2, or ≠ 2 output symbols | **capability** |
| `:2265` | an operand is not a per-cell `index` ring gather (`_batched_ring_gather` → `None` at `:2166`, `:2169`, `:2173`, `:2175`) | **capability** |
| `:2270` | both operands gather on the same symbol, or a symbol is not a box axis | **capability** |
| `:2277` | the equi-join does not code to a dense box mask (`_join_admits_mask` → `None` at `:2208` candidate-set gate, `:2211` key not a box axis) | **capability** |
| `:2288` | the gather/mask construction raised one of the narrow errors | **capability** |
| `:2294` | `geometry.intersect_polygon_area_batch` itself declined the batch | **capability** |

### 2.3 `_eval_faq_prefix_scan` (`numpy_interpreter.py:3739`) — the O(N) forward scan

The tier's own docstring says every precondition "is a correctness requirement,
not a heuristic". Landing is the dense gated path, which is `O(N²)` time **and**
memory where this is `O(N)`; when that dense path also declines, the landing is
`_eval_faq_scalar`.

| file:line | trigger | class |
|---|---|---|
| `:3778` | the node carries `join` or `distinct` | **capability** |
| `:3780` | the node carries `key` | **capability** |
| `:3783` | no accumulate ufunc for ⊕, or ≠ 1 contracted index, or no output symbols, or an empty output box | **capability** |
| `:3787` | the filter is not exactly a forward comparison (`_match_forward_prefix_filter` → `None` at `:3727`, `:3730`, `:3736`; a REVERSE scan is deliberately not matched, per esm-spec §4.3.1) | **capability** |
| `:3790` | the compared symbols are not the contracted index and an output index | **capability** |
| `:3797` | the contracted range does not resolve | **capability** |
| `:3799` | the contracted range ≠ the scanned output range | **capability** |
| `:3801` | the body reads the scanned symbol, so no partial result is reusable | **capability** |
| `:3816` | the body does not evaluate/broadcast over the reduced box | **capability** |

### 2.4 `_eval_faq_operator_cached` (`numpy_interpreter.py:3452`) — the cached regrid weight operator

Declines land on `_eval_faq_reduce_vectorized`, another whole-box tier, so a
decline here is only a refusal if that tier also declines. `:3488` is the one
row that is a genuine configuration switch rather than a shape test.

| file:line | trigger | class |
|---|---|---|
| `:3488` | `ctx.op_cache is None` (operator caching off) or no `ctx.invariant_names` | **cost** — the same answer comes from the dense tier below; this only forgoes reuse |
| `:3490` | `reducer != "+"`, a `filter`, or no contraction | **capability** |
| `:3494` | more than `_EINSUM_MAX_LABELS` (26) distinct index symbols | **cost** — a hard einsum-alphabet limit, not an expressiveness one; `_EINSUM_MAX_LABELS` at `numpy_interpreter.py:59` |
| `:3502` | the body is not a scaled product of bare-symbol `index` gathers (`_decompose_body_as_scaled_product` → `None` at `:1639`, `:1643`, `:1645`, `:1648`, `:1651`, `:1657`, `:1665`, `:1670`) | **capability** |
| `:3526` | the factors do not split into ≥1 invariant and ≥1 varying term | **capability** (no reusable operator exists) |
| `:3540`, `:3570` | a factor is not a plain array gather (`_gather_operator_factor` → `None` at `:3436` diagonal access, `:3444` name resolves to nothing, `:3446` rank mismatch) | **capability** |
| `:3550` | the join does not code to a dense mask | **capability** |
| `:3554` | no operands at all | **capability** |
| `:3557`, `:3576` | the einsum construction or application raised a narrow error | **capability** |

### 2.5 `_eval_faq_reduce_vectorized` (`numpy_interpreter.py:3580`) — the dense gated reduce

This is the last tier before `_eval_faq_scalar` for a join/filter node, so every
row here IS a refusal under `native`.

| file:line | trigger | class |
|---|---|---|
| `:3635` | ⊕ has no numpy ufunc in `_REDUCE_UFUNCS` | **capability** |
| `:3635` | **no contraction at all** (`not reduce_syms`) | **capability**, and the single most-hit decline in the corpus — see the note below |
| `:3642` | zero index symbols | **capability** |
| `:3657` | a join is present but the caller passed no `raw_ranges` | **capability** (an internal precondition; unreachable from `_eval_faq`, which always passes them) |
| `:3663` | join resolution raised a narrow error | **capability** |
| `:3665` | a join key is not an axis of the combined box (`_join_admits_mask` → `None`), or a gate carries a candidate set (`:2208` — the overlap broad phase) | **capability** |
| `:3684` | the body or the filter does not evaluate and broadcast over the combined box | **capability** — this is the broad catch-all, and the one most likely to be hiding a fixable gap behind a `TypeError` |

**A join- or filter-gated PURE MAP has no whole-box tier at all.** This is the
largest single hole the census found, and it is structural rather than
incidental. Once `join_clauses or filter_expr is not None` at
`numpy_interpreter.py:2452`, the dispatcher runs the gated sub-ladder and then
returns `_eval_faq_scalar` at `:2541`; `_materialize_map` lives in the UNGATED
tail at `:2623` and is unreachable. Inside that sub-ladder every tier requires a
contraction — `_eval_faq_batched_leaf` declines at `:2254`, `_eval_faq_prefix_scan`
needs exactly one contracted index (`:3783`), `_eval_faq_operator_cached` needs
one (`:3490`), and `_eval_faq_reduce_vectorized` needs one (`:3635`). So a node
whose output indices ARE its only ranges, carrying a join and/or a filter, walks
per cell by construction unless its body is exactly the planar
`polygon_intersection_area` the batched leaf recognizes. That shape is the
conservative-regrid narrow phase, and it is what four of the corpus's thirteen
per-cell documents are.

### 2.6 `_eval_faq_vectorized` (`numpy_interpreter.py:1673`) — the einsum path

Reached only for an ungated node with ⊗ = `×` (`numpy_interpreter.py:2581`).
Declines land on `_eval_faq_contraction_broadcast`, still whole-box.

| file:line | trigger | class |
|---|---|---|
| `:1693` | body is not a scaled product of bare-symbol `index` gathers | **capability** |
| `:1712` | more than 26 index symbols | **cost** (`_EINSUM_MAX_LABELS`, `:59`) |
| `:1722` | diagonal access — a variable gathered twice on the same symbol | **capability** |
| `:1742`, `:1747` | a parameter or observed is subscripted | **capability** |
| `:1751` | the name resolves to no array, state, param or observed | **capability** |
| `:1756` | the array's rank ≠ the number of subscripts | **capability** |
| `:1768` | every factor folded to a coefficient and ⊕ is not `+` | **capability** |
| `:1781` | ⊕ is not `+` and the scalar coefficient is not 1 (it would not distribute) | **capability** |
| `:1802`, `:1804` | einsum raised a narrow error, or ⊕ is outside `+`/`*`/`max`/`min` | **capability** |

### 2.7 `_eval_faq_contraction_broadcast` (`numpy_interpreter.py:2075`) — the whole-box contraction

The last tier before `_eval_faq_scalar` for an ungated contracting node.

| file:line | trigger | class |
|---|---|---|
| `:2111` | `_CONTRACT_DISABLE` (`ESS_NP_CONTRACT_DISABLE=1`) | **cost** — an oracle kill switch, retired in phase 2 |
| `:2111` | no contracted symbols (the node is a pure map; `_materialize_map` handles it) | not a decline in substance — the dispatcher only calls this when `reduce_syms` is non-empty (`:2601`) |
| `:2120` | combined `out × reduce` box exceeds `_CONTRACTION_BOX_CAP` = `1 << 22` cells (`:1991`) | **cost** — the archetypal cost decline. Both paths compute the same number; the cap says a ~32 MB slab is too much to materialize. Under `native` this IS a refusal because the landing walks per cell, and it is the one row where moving a threshold, not writing a tier, changes the outcome. |
| `:2141` | the body rejected array-bound index symbols (narrow error tuple) | **capability** |
| `:2148` | the body's result will not broadcast to `out × reduce` | **capability** |

### 2.8 `_materialize_map` (`numpy_interpreter.py:1935`) — the whole-box pure map

The last tier before `_eval_faq_scalar` for an ungated non-contracting node.

| file:line | trigger | class |
|---|---|---|
| `:1960` | no output symbols or an empty output box | **capability** (degenerate; there is nothing to vectorize) |
| `:1984` | the body does not evaluate or broadcast over the box | **capability** — the catch-all for this tier |

### 2.9 The codegen tier — cost only, never a refusal

| file:line | trigger | landing | class |
|---|---|---|---|
| `numpy_interpreter.py:2050` → `:2051` | `node is None` (no cache home the caller can vouch for) or `_CODEGEN_DISABLE` (`ESS_NP_CODEGEN_DISABLE=1`) | `_compile_expr(body)` — the compiled closure, same whole box | **cost** |
| `numpy_interpreter.py:2058` → `:2059` | a `{"from": …}`-ranged node whose resolved box has more than `_CODEGEN_DYN_KEY_CAP` = 4096 total range values (`:2008`) | compiled closure | **cost** |
| `numpy_interpreter.py:2068` → `:2069` | a dynamic node that has already compiled `_CODEGEN_DYN_CAP` = 8 distinct box variants (`:2005`) | compiled closure | **cost** |
| `numpy_codegen.py:159` → `:160` | the emitted body exceeds `_MAX_LINES` = 20000 source lines (`:73`); raises `_Decline`, caught at `:405` | compiled closure | **cost** |
| `numpy_codegen.py:405` → `:409` | `except Exception` — ANY codegen-time failure: a constant-folding subtree that raises, recursion depth, the line cap | compiled closure | **cost**, but this is the one bare `except Exception` in the ladder. It is safe for the ANSWER (the closure tier reproduces the interpreter's behaviour, including its errors, per call) and unsafe for DIAGNOSIS: a `MemoryError` or a genuine bug in the emitter is indistinguishable from a deliberate decline. Worth the same treatment the plan gives Julia's `errors.jl:56` hazard. |
| `numpy_interpreter.py:1888` | `_CODEGEN_DISABLE` in `_materialize_makearray_vectorized` | per-region compiled closure | **cost** |

### 2.10 Summary of the classification

| class | rows | refusal under strict `native`? | hit by the corpus (§1.5) |
|---|---:|---|---|
| correctness-mandated | 1 — `:2430`, recurrence | yes, permanently | yes, 3 nodes |
| capability | 47 | yes, whenever the node reaches `_eval_faq_scalar`, `_eval_faq_scalar_gate_driven` or `_eval_faq_ragged` | yes, 18 nodes across 6 distinct chains |
| cost | 11 | only `:2120` (`_CONTRACTION_BOX_CAP`) and the two kill switches `:2111` / `:1888`; the 6 codegen rows and the 2 einsum-alphabet rows land on another whole-box path, and `:3488` lands on the dense reduce | **no — not one cost decline fired anywhere in 1217 documents** |

The eleven cost rows in full: six codegen declines (§2.9, all landing on the
compiled closure over the same box), two einsum-alphabet limits (`:1712`,
`:3494`), the operator-cache-off gate (`:3488`), the combined-box cap (`:2120`)
and the contraction kill switch (`:2111`).

The practical reading, and the answer to ruling D6 for this binding: **the
Python ladder has almost no cost declines, and the corpus exercises none of
them.** One cap and two kill switches are the entire cost surface, and no
document in `tests/` or `EarthSciModels/` reaches any of the three. Everything
the census actually saw is a shape the fast tier cannot express, or a recurrence
the spec forbids vectorizing. A strict `native` default is therefore not a
threshold-tuning exercise in Python; it is a short list of constructs that need
whole-box implementations written — headed by the gated pure map of §2.5.

---

## 3. Simulation-test classification

Buckets per the plan's §4.2: **1** = document + expected value, moves to a
cross-language fixture; **2** = binding-internal, stays; **3** = refusal or
diagnostic, moves to the golden-free refusal tiers.

69 files under `pkg/earthsci-ast-py/tests/` run a simulation, counting
`esm_problem`, `solve`, `evaluate_rhs`, `simulate`, `run_inline_tests`,
`simulate_states`, and the private engine `simulation_array._simulate_with_numpy`.

### 3.1 Bucket 1 — document + expected value (28 files)

| file | ~tests | reason |
|---|---|---|
| `test_assertion_nonfinite_conformance.py` | 3 | already a shared category: fixture plus per-assertion verdicts under `tests/conformance/assertion_nonfinite/` |
| `test_broadcast_and_index_alignment.py` | 31 | broadcast/alignment value claims end-to-end; ~8 bucket-3 validation-error tests mixed in |
| `test_build_once_spatial_field_conformance.py` | 2 | shared fixture plus an analytic golden trajectory |
| `test_discrete_materialize_conformance.py` | 2 | shared fixture plus an analytic golden; calls `_simulate_with_numpy` directly |
| `test_elementwise_observed_gather_conformance.py` | 3 | shared fixtures plus Julia-minted goldens |
| `test_faq_conformance.py` | 5 | drives `tests/valid/faq/*.esm` inline `tests` blocks; 2 bucket-3 tests |
| `test_faq_simulation.py` | 1 parametrized | pure fixture-driven: Julia-produced `.esm` with inline `tests`/`tolerance`. The cleanest bucket-1 file in the tree |
| `test_loaded_ic_bc_simulation.py` | 1 | end-to-end against the Julia reference; only the Provider seam is Python-specific |
| `test_merged_rename_reach_conformance.py` | 10 | shared manifest `tests/conformance/merged_rename_reach/`; 1 bucket-3 refusal |
| `test_mounted_component_tests.py` | 3 | fixture-backed claim that a leaf's `tests` do not cross a mount edge |
| `test_pde_inline_array_overrides_conformance.py` | 4 | shared goldens; 1 bucket-3 shape-mismatch test |
| `test_pde_inline_dead_observed_conformance.py` | 2 | shared fixture plus a Julia-minted golden |
| `test_pde_inline_ic_param_override_conformance.py` | 3 | shared fixture plus a golden for build-time override scope |
| `test_pde_inline_observed_indexed_lhs_conformance.py` | 3 | shared manifest plus goldens; 1 bucket-3 refusal |
| `test_pde_inline_observed_state_dependent_conformance.py` | 2 | shared manifest plus goldens |
| `test_pde_inline_reference_dimension_names_conformance.py` | 2 | shared manifest plus goldens |
| `test_pde_simulation_conformance.py` | 2 | `evaluate_rhs` against `Lu+b`, trajectory against a matrix exponential |
| `test_refresh_conformance.py` | 3 | shared fixture plus golden regrid/trajectory bands; calls `_simulate_with_numpy` directly |
| `test_rhs_time_derivative_conformance.py` | 5 | shared manifest of outcomes; the refusal half is bucket 3 but shares the manifest |
| `test_scalar_ic_conformance.py` | 4 | shared goldens; 1 routing test (see §3.4) |
| `test_scoped_assertion_variable.py` | 5 | fixture documents plus `run_inline_tests` assertions on scoped names |
| `test_shaped_observed_scalar_broadcast_conformance.py` | 2 | shared fixture plus a Julia-minted golden |
| `test_shaped_parameter_broadcast_conformance.py` | 3 | shared fixture plus a golden; 1 bucket-3 test |
| `test_simulate_algebraic.py` | 9 | inline documents plus expected trajectories for algebraic elimination; 1 bucket-3 cyclic-rejection test |
| `test_simulation_fixtures_blocks.py` | 2 | executes inline `tests` blocks on every `tests/simulation/*.esm`; mirrors the Julia runner |
| `test_static_evaluation_assertions_conformance.py` | 7 | shared goldens for assertion-time evaluation; 3 bucket-3 refusals |
| `test_subsystem_loader_conformance.py` | 2 | shared fixture plus an analytic golden trajectory |
| `test_wildfire_simulation.py` | 2 | end-to-end `tests/valid/wildfire_atmosphere_ocean.esm` with expected regrid and state values |

### 3.2 Bucket 2 — binding-internal (28 files)

| file | ~tests | reason |
|---|---|---|
| `test_build_inspection.py` | 10 | the `BuildInspection` sink and `ragged_factor_scope` internals; 3 of 10 are bucket-1 trajectory checks |
| `test_cse_boolean_piecewise.py` | 7 | `cse=True` SymPy `Piecewise` lowering — a Python-only option |
| `test_dead_observed_skip.py` | 5 | 2 inspection internals, 1 array-RHS tolerance (bucket 1), 2 refusals (bucket 3); genuinely three-way |
| `test_declared_shape_pathway.py` | 8 | router behaviour under a declared `shape`; **deleting the router guts this file** |
| `test_function_tables_evaluation.py` | 16 | ~9 lowering/pass-placement internals, 4 refusals, 2 value checks |
| `test_geometry_simulation.py` | 8 | 4 helper unit tests (`as_ring`, `order_observed_equations`, `time_varying_observeds`) against 3 fixture-driven conformance tests and 1 refusal |
| `test_indexed_lhs_array_observed.py` | 18 | ~9 normalizer/classification internals plus 1 pathway assert, against ~8 spelling-agreement value tests |
| `test_inline_tests.py` | 43 | the runner's own API: `Assertion` parse/serialize, `field_reduce`, `state_cells`, tolerance precedence, dimension binding |
| `test_loader_injection.py` | 7 | `flatten`'s `LoaderField` records and cadence |
| `test_loader_provider.py` | 9 | the `Provider` object seam and `provider_factory` injection |
| `test_numpy_interpreter.py` | 34 | explicitly synthetic `EvalContext`, "without relying on the end-to-end pipeline" |
| `test_numpy_interpreter_join.py` | 21 | synthetic contexts for joins and filters; ~6 bucket-3 rejections |
| `test_observed_field_static.py` | 5 | parametrized over both pathways with `expected_pathway`; **every test asserts routing** |
| `test_overlap_dense_scaling.py` | 5 | gate-driven against full-product allocation counts and bit-identity |
| `test_overlap_env_name_resolution.py` | 7 | dot-suffix name-resolution internals |
| `test_prepare_pushdown.py` | 3 | `pushdown_rewrite=True` record and gate plumbing through `BuildInspection` |
| `test_problem_surface.py` | 16 | the `EsmProblem`/`solve` contract: retcodes, `remake` no-rebuild, stepping, ensembles, no-SciPy-at-import |
| `test_property_model.py` | 6 | Hypothesis: flatten determinism/idempotence and simulate-vs-simulate-via-flatten |
| `test_pushdown_cell_geometry.py` | 5 | rewrite renumbering internals plus an allocation match |
| `test_reaction_system_inline_tests.py` | 12 | ~7 discovery/tolerance-level internals against ~5 value tests |
| `test_simulate_flatten.py` | 10 | 6 caching / `compile_flat_rhs` / `cse` kwarg internals, 3 value tests, 1 refusal |
| `test_simulation.py` | 12 | the legacy SciPy tier: 5 `_expr_to_sympy` unit tests, 5 refusals, 3 trajectory tests |
| `test_simulation_csefalse_decomp.py` | 4 | SymPy `Abs` complex-domain decomposition under `cse=False` |
| `test_simulation_scalar_ops.py` | 28 | 25 `_expr_to_sympy` conversion unit tests; only 3 go through `simulate` |
| `test_solver_block.py` | 9 | the `solver` block reaching `EsmProblem` fields, and the stepping API |
| `test_sympy_bridge_closed_functions.py` | 3 | the SymPy bridge's `fn`/`const` handling specifically |
| `test_variable_map_expression_transform.py` | 12 | parse/schema/flatten structure; 4 refusals; 1 end-to-end simulate |
| `test_wrt_default_omitted.py` | 6 | parse/classification/bridge handling of an absent `wrt` |

Seven more files evaluate AST nodes against a synthetic `EvalContext` without
ever building a document, and are bucket 2 if "runs a simulation" means
"evaluates": `test_numpy_codegen.py`, `test_contraction_broadcast.py`,
`test_shape_inference_interval.py`, `test_cumulative_prefix_scan.py`,
`test_geometry_kernel.py`, `test_numpy_interpreter_self_join.py`,
`test_value_invention_frontdoor.py`. Three of them are the ones §3.4 flags.

### 3.3 Bucket 3 — refusal / diagnostic (13 files)

| file | ~tests | reason |
|---|---|---|
| `test_arrayed_vars.py` | 9 | of the 3 simulating tests, 2 assert a build refusal and 1 asserts `prob.pathway` |
| `test_complex_value_guard.py` | 8 | `ComplexValueError` at the cast on every path; 3 tests are bucket-1 value claims |
| `test_const_array_gather_bounds_conformance.py` | 5 | shared manifest of `E_TREEWALK_CONSTARRAY_OOB` refusals per axis |
| `test_expression_templates.py` | 29 | 12 `pytest.raises`; only 2 tests simulate, and both error before evaluation |
| `test_loader_ingest_and_select.py` | 18 | 9 `pytest.raises` on ingest/`select`/`extent` construction errors |
| `test_override_key_diagnostics_conformance.py` | 4 | a shared category that "carries no numeric golden — it compares DIAGNOSTIC OUTCOMES" |
| `test_override_key_suffix_rule.py` | 11 | 11 `pytest.raises` on §6.6.2 key resolution |
| `test_recurrence_causal_self_reference.py` | 21 | ~9 coded refusals against ~6 pinned-value tests |
| `test_unevaluable_operator.py` | 8 | the coded `unevaluable_operator` diagnostic, checked before evaluation |
| `test_unlowered_operator_gate.py` | 4 | the `unlowered_operator` front-door gate; 2 of 4 also assert `prob.pathway` |
| `test_unsupported_construct_conformance.py` | 4 | shared manifest: continuous event, discrete event, implicit equation |
| `test_value_invention_materialize_conformance.py` | 2 | shared manifest with `value` and `refused` outcomes |

Three files on the task's candidate list turn out not to run a simulation at
all and are excluded: `test_integration.py` (load → validate → print →
substitute), `test_simulation_fixtures.py` (`solve_ivp` appears only in the
module docstring; the tests are serialize round-trips), and
`test_assertion_tolerance_conformance.py` (calls the pure predicate
`_check_assertion` against a golden table — still a bucket-1 conformance
adapter, just not a simulation).

### 3.4 Tests that break when the switches and the router are removed

**No Python test sets or reads an `ESS_*` environment variable.** Zero hits for
`ESS_` across every file under `pkg/earthsci-ast-py/tests/`. Deleting the
variables breaks no test.

What breaks instead: three files assign directly to the module constants the
variables initialize, because those constants are latched at import so setting
the environment afterwards would have no effect.

| file:line | constant | how |
|---|---|---|
| `tests/test_numpy_codegen.py:53-58` | `NI._CODEGEN_DISABLE` | save / assign `True` / restore, in a helper |
| `tests/test_numpy_codegen.py:275-280` | `NI._CODEGEN_DISABLE` | same, in `test_kill_switch_leaves_node_unmarked` (`:261`) |
| `tests/test_numpy_codegen.py:299-305` | `NI._CODEGEN_DISABLE` | same, in `test_error_parity_unresolved_symbol` (`:284`) |
| `tests/test_contraction_broadcast.py:78-83` | `NI._CONTRACT_DISABLE` | save / assign `True` / restore, in a helper |
| `tests/test_shape_inference_interval.py:64-69` | `FL._SHAPE_INTERVAL_DISABLE` | save / assign `True` / restore |
| `tests/test_shape_inference_interval.py:101-106` | `FL._SHAPE_INTERVAL_DISABLE` | save / assign `True` / restore |

Docstrings that go stale with them: `tests/test_numpy_codegen.py:9` and `:262`,
`tests/test_shape_inference_interval.py:9`,
`src/earthsci_ast/numpy_codegen.py:38`.

**No test monkeypatches or overrides `_choose_pathway`.** The only test-side
references are prose: `tests/test_declared_shape_pathway.py:4`,
`tests/test_observed_field_static.py:7`, `:43`, `:109`,
`tests/test_unlowered_operator_gate.py:19`.

Thirteen assertions read `prob.pathway` and break with the router:

| file:line | assertion |
|---|---|
| `tests/test_arrayed_vars.py:139` | `prob.pathway == "array"` |
| `tests/test_declared_shape_pathway.py:211` | `prob.pathway == "array"` |
| `tests/test_declared_shape_pathway.py:238` | `esm_problem(bare, (0.0, 1.0)).pathway == "array"` |
| `tests/test_declared_shape_pathway.py:239` | `esm_problem(agg, (0.0, 1.0)).pathway == "array"` |
| `tests/test_declared_shape_pathway.py:256` | `prob.pathway == "array"` |
| `tests/test_declared_shape_pathway.py:291` | `esm_problem(path, (0.0, 1.0)).pathway == "scalar"` |
| `tests/test_declared_shape_pathway.py:331` | `prob.pathway == "array"` |
| `tests/test_observed_field_static.py:54` | `prob.pathway == expected_pathway` |
| `tests/test_observed_field_static.py:68` | `prob.pathway == expected_pathway` |
| `tests/test_observed_field_static.py:124` | `prob.pathway == expected_pathway` |
| `tests/test_indexed_lhs_array_observed.py:363` | `esm_problem(path, (0.0, 1.0)).pathway == "array"` |
| `tests/test_unlowered_operator_gate.py:173` | `prob.pathway == "scalar"` |
| `tests/test_unlowered_operator_gate.py:183` | `prob.pathway == "array"` |

Plus four indirect routing observables:

| file:line | observable |
|---|---|
| `tests/test_observed_field_static.py:45-48` | the `PATHWAYS` parametrize table itself — `{}` → `"scalar"`, `{"const_arrays": {…}}` → `"array"`. The comment at `:43` calls `const_arrays` "the cheapest way to force `_choose_pathway` onto the NumPy engine"; an explicit `compiler=` replaces the idiom |
| `tests/test_scalar_ic_conformance.py:128` | `assert "N.f[1]" in res.vars` — per-cell variable names used as the array runtime's signature, with a comment that the SymPy path "would report a single `N.f` row" |
| `tests/test_unlowered_operator_gate.py:186` | `test_the_gate_fires_before_any_engine_is_chosen` — its premise ("either kind") is router-shaped |
| `tests/test_discrete_materialize_conformance.py:41,89`; `tests/test_refresh_conformance.py:36,83,119` | import and call `simulation_array._simulate_with_numpy` directly, bypassing the router. These do not break, but they are the existing "pick the engine explicitly" idiom and should become an explicit `compiler=` in the same change |

`test_declared_shape_pathway.py` (8 tests) and `test_observed_field_static.py`
(5 tests) are the two files whose entire premise is routing. With an explicit
`compiler=`, the first becomes moot and the second becomes a cross-compiler
agreement test, which is the better test.

---

## 4. `ESS_*` environment reads in `src/` — the phase 2 retirement list

Four variables, all read with a bare `os.environ.get`. There is no helper and
no name indirection.

| variable | read site | expression | default / on | what it does | kind |
|---|---|---|---|---|---|
| `ESS_NP_CONTRACT_DISABLE` | `numpy_interpreter.py:1994` (constant `_CONTRACT_DISABLE`; consumed at `:2110`) | `os.environ.get("ESS_NP_CONTRACT_DISABLE", "") == "1"` | unset → off; exactly `"1"` → on; read once at import | makes `_eval_faq_contraction_broadcast` return `None` immediately, routing every plain contraction to the per-cell scalar reduce so the two can be diffed bitwise | oracle kill switch |
| `ESS_NP_CODEGEN_DISABLE` | `numpy_interpreter.py:1999` (constant `_CODEGEN_DISABLE`; consumed at `:1888` and `:2050`) | `os.environ.get("ESS_NP_CODEGEN_DISABLE", "") == "1"` | unset → off; exactly `"1"` → on; read once at import | skips the Tier-1 source codegen: the per-region `makearray` cache is not consulted, and `_codegen_box_fn` returns `_compile_expr(body)` outright | oracle kill switch |
| `ESS_SHAPE_INTERVAL_DISABLE` | `flatten.py:3847` (constant `_SHAPE_INTERVAL_DISABLE`; consumed at `:4063`) | `os.environ.get("ESS_SHAPE_INTERVAL_DISABLE", "") == "1"` | unset → off; exactly `"1"` → on; read once at import | disables the interval-arithmetic hull walk in `_collect_index_uses`, falling through to the pointwise enumeration of the full Cartesian aggregate box | oracle kill switch |
| `ESS_OBSERVED_PROGRESS` | `simulation_array.py:825`, inside `_materialize_observeds` (function-local `import os as _os` at `:823`, so re-read per call) | `bool(_os.environ.get("ESS_OBSERVED_PROGRESS"))` | unset → off; **any non-empty value** turns it on, including `"0"` | prints one `[ess-observed] <name>: <elapsed>s shape=<shape>` line to stderr per observed as it materializes (`:849-854`), plus a skipped-unresolved line (`:839-845`). Changes no value and no code path | debug |

Three notes for phase 2.

* **There is no tuning `ESS_*` variable in Python.** The numeric budgets that
  sit beside these switches — `_CONTRACTION_BOX_CAP` (`numpy_interpreter.py:1991`),
  `_CODEGEN_DYN_CAP` and `_CODEGEN_DYN_KEY_CAP` (`:2005`, `:2008`),
  `_EINSUM_MAX_LABELS` (`:59`), `_MAX_LINES` (`numpy_codegen.py:73`) — are
  hard-coded literals with no environment override. The plan's ruling that
  tuning thresholds stay and become documented refusal boundaries applies to
  them as constants, not as variables.
* Three of the four latch at import, so the tests drive the constants instead
  (§3.4). Retiring the variable and the constant is one change, not two.
* `flatten.py:3235` names `ESS_TEMPLATE_REF_DISABLE=1` in a docstring, but the
  Python binding never reads it — that switch exists only in Julia
  (`pkg/EarthSciAST.jl/src/resolve.jl:591`). Same for `ESS_STENCIL_DISABLE`,
  `ESS_CODEGEN_DISABLE` (distinct from the Python `ESS_NP_CODEGEN_DISABLE`) and
  `ESS_TCADENCE_DISABLE`, which appear in repo-root READMEs and benchmark
  scripts. Python owns none of them.

One generic indirection worth knowing about, though it is not an `ESS_*` read:
`json_walk.py:367` in `expand_ref_env` expands `${VAR}` tokens inside an
esm-spec §4.7 ref from whatever name the DOCUMENT gives, so a document could
name an `ESS_*` variable. The name is data, not source, and an unset variable is
left literal so the ref fails to resolve.

---

## 5. Reproducing

```bash
# one document
PYTHONPATH=pkg/earthsci-ast-py/src \
  python3 pkg/earthsci-ast-py/scripts/compiler_census.py --one <doc.esm>

# the sweep (as run; see /scratch/ctessum/compiler-sel/logs/census-python/sweep.sbatch)
PYTHONPATH=pkg/earthsci-ast-py/src \
  python3 pkg/earthsci-ast-py/scripts/compiler_census.py \
    --root tests --root ../EarthSciModels \
    --output census.jsonl --timeout 180 --jobs 8 --memcap 6

# the tables above
python3 pkg/earthsci-ast-py/scripts/compiler_census.py --summarize census.jsonl
```

Raw JSONL is under `/scratch/ctessum/compiler-sel/logs/census-python/` and is
not committed: `census.jsonl` (the run this audit reports, 1217 lines),
`summary.txt` (its aggregation), `sweep.sbatch` (the job), and
`census-buildonly-v1.jsonl` (a first run that did not evaluate the default
pathway's right-hand side, kept only because it is what showed the comparison
was unfair).

One caveat on re-running: the system `python3` resolves `earthsci_ast` to
whichever checkout is on the path first, so set `PYTHONPATH` to the worktree's
`src` and confirm with `python3 -c "import earthsci_ast; print(earthsci_ast.__file__)"`
before trusting a number. Each record carries the binding path it actually
imported, in its `binding` field, for exactly this reason.
