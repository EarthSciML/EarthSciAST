# Compiler census — Rust binding

**Branch** `compiler/census-rust`, cut from `compiler-selection` at `4d03022b9`.
**Date** 2026-09-21.
**Scope** phase 0 of the "Choosing the Compiler" plan, Rust half. Every `.esm`
document under `pkg/earthsci-ast-rs/tests/` (859) and in `EarthSciModels` (358);
every decline site in the tape, the whole-array overlay and the per-cell
oracle's join-gate planner; every simulation test file; every `ESS_*` /
`EARTHSCI_*` environment read.

Nothing in the crate was changed. The one addition is
`pkg/earthsci-ast-rs/examples/compiler_census.rs`, the harness §1 is measured
with; raw JSON Lines live under
`/scratch/ctessum/compiler-sel/logs/census-rust/` and are not committed.

The plan's `native` compiler is **the array runtime's tape for every document**,
including the 0-D ones today's router sends to `Backend::Scalar` (its ruling D3:
"Rust's scalar interpreter does not count as native"), refusing any document
that leaves a rule on the per-cell path (its ruling D1). Ruling D6 narrows that:
a *cost*-class decline is refused only when the path it lands on walks the tree
per cell. §1 measures how far that is from true today; §2 classifies every site
against D6.

---

## 1. Corpus census

### 1.0 Method

`examples/compiler_census.rs`, one process per document, a 180 s timeout and a
10 GiB address-space cap each, 4 at a time on one compute node. For every
document it records

* **(a) default routing** — `esm_problem(path, (0,1), ProblemOptions::default())`
  and its `backend_kind()`, or the error variant if construction fails;
* **(b) the array runtime forced** — the document's precision environment armed
  and an annotated copy taken exactly as `simulate::driver::build_array_compiled`
  does, then `ArrayCompiled` built and `debug_build_tape_report()` read, whether
  or not `is_array_file` would have routed here. This is what `native` will do.
* `tape_disabled()`'s document condition (a per-variable `element_type`), the
  observed cadence partition, and wall time for each phase.

One deliberate departure from `build_array_compiled`: it sends a document to
`flatten` only when `models.len() > 1`, so a document whose whole content is a
`reaction_systems` block (**no** `models` at all until flattening lowers its
reactions) hits `ArrayCompiled::from_file`'s `"File has no models to simulate"`
guard (`simulate_array/compile.rs:392`). Production never notices, because
`is_array_file` is false for those documents and they route to
`Backend::Scalar`. The census flattens whenever `models.len() != 1`, because
`native` must handle them. **That one change moved 25 documents — `pollu`,
`superfast`, `geoschem_fullchem` and the rest of the pure-chemistry corpus —
from "cannot build" to "builds, fully taped."** It is a one-line routing fix in
`build_array_compiled`, not a lowering gap.

Raw JSON Lines: `/scratch/ctessum/compiler-sel/logs/census-rust/census.jsonl`
(1217 lines), aggregated by `aggregate.py` into `aggregate.txt` beside it.

### 1.1 Headline

| | documents |
|---|---|
| corpus | **1217** (859 under `tests/`, 358 in `EarthSciModels`) |
| fail to LOAD (schema-invalid fixtures, bad JSON, structural) | 178 |
| forced-array build FAILS | 231 — of which **55 are library fragments** with no models and no reactions, and 133 already fail under today's default routing too; 176 are genuine refusals |
| **forced-array BUILDS** | **808** |
| of those, **zero fallback** | **663 (82%)** |
| of those, **≥ 1 fallback rule** | **145 (18%)** |
| killed or timed out | **0** — nothing in either corpus OOMs or hangs at build; `isrm.esm` builds in 6 ms |
| `tape_disabled()` true for the document | **1** (`tests/fixtures/recurrence/06_recurrence_float32_state.esm`, the only per-variable `element_type` document in the corpus) |

Build cost is negligible: 808 forced-array builds (load + compile + tape) total
**2.5 s**, median 1 ms, slowest 172 ms (`geoschem_fullchem.esm`). Whatever is
expensive about this stack, it is not building the tape.

The 2026-09-13 census that the plan quotes found 137 of 189 zero-fallback (72%).
Over this 6× larger corpus the rate is 82%.

### 1.2 Default routing today

| `backend_kind()` | documents |
|---|---|
| `static` (no differential equations — nothing to integrate) | 762 |
| `scalar` (`Backend::Scalar`, the 0-D interpreter) | 187 |
| `array` (`Backend::Array`) | 99 |
| construction fails | 169 |

**The population `native` actually has to serve is the 286 that get a compiled
right-hand side today** — the 99 `array` plus the 187 `scalar`. A `static`
document has no right-hand side, so no compiler is chosen for it; its numbers
are reported below for completeness but are not refusals.

| | documents |
|---|---|
| get a compiled right-hand side today | **286** |
| forced-array build succeeds | 277 (9 fail) |
| **zero fallback → `native` accepts** | **227 (79%)** |
| **`native` refuses** | **59 (21%)** — 50 for at least one fallback rule, 9 because the build itself fails |

### 1.3 Ruling D3 — is the tape ready to be `native` for 0-D documents?

Nearly. Of the **187** documents the router sends to `Backend::Scalar`:

* **171 (91%) the tape lowers with zero fallbacks**;
* **7** have fallback rules;
* **9** fail the forced-array build.

The 7 with fallbacks:

| rules | document | reason |
|---|---|---|
| 9/9 | `tests/valid/scoped_refs_nested.esm` | `wholesale: unresolved symbol (forcing/NaN sentinel?)` |
| 7/10 | `tests/valid/reaction_system_only.esm` | same |
| 5/6 | `tests/scoping/hierarchical_scoped_references.esm` | same |
| 2/2 | `tests/valid/data_sources_comprehensive.esm` | same |
| 1/1 | `tests/closed_functions/interp/linear/canonical.esm` | `closed function has no tape lowering` |
| 1/1 | `tests/closed_functions/interp/bilinear/canonical.esm` | same |
| 1/1 | `tests/closed_functions/interp/searchsorted/canonical.esm` | same |

The 9 build failures are three named causes, none of them 0-D-specific:
`table_lookup` as an evaluable-core op with no array evaluator (4:
`tests/conformance/function_tables/*`), continuous/discrete events and an SDE
(3: `tests/events/*`, `tests/fixtures/sde/ornstein_uhlenbeck.esm`), an
unlowered `D` (1), and an undefined variable (1, an `invalid/` fixture that
should fail).

So the distance from D3 is **16 documents and about four distinct pieces of
work**: the `interp.*` closed-function family, the forcing/NaN-sentinel symbol
resolution, `table_lookup`, and events. The last two are refusals today under
every backend and stay refusals.

### 1.4 Where the per-cell work actually happens — build path versus RHS path

`debug_build_tape_report()` alone does not answer this: an `Instr::Fallback`
says a rule is on the per-cell path, not how often that path runs. Attributing
each fallback to its **cadence tier** does. Over all 808 built documents:

| tier | fallback rules | documents | when it runs |
|---|---|---|---|
| **CONST** | **873** | 96 | once per solve, at setup |
| **RHS rule** | **100** | 47 | **every RHS call, per cell** |
| **CONTINUOUS observed** | **84** | 8 | **every RHS call** |
| DISCRETE | 0 | 0 | — |

Restricted to the 286 documents that get a compiled right-hand side:

| tier | fallback rules | documents |
|---|---|---|
| RHS rule | 76 | 31 |
| CONST | 25 | 19 |
| CONTINUOUS observed | 6 | 4 |

By document, of the 50 that `native` would refuse for a fallback: **34 have a
fallback on the RHS path** and **16 fall back only at setup**.

**And there is a larger build-path surface that the tape report cannot see at
all.** `solve` calls `hoist_static_observeds`
(`simulate_array/driver.rs:518` → `:697`) **before** `build_solve_tape`
(`:530`), and that hoist evaluates every CONST-tier observed through
`materialize_observeds_into` (`rhs.rs:465`) → the whole-array overlay with the
per-cell oracle beneath it. **The tape is not involved.** A document whose tape
is perfectly lowered still evaluates its static observeds off-tape once per
solve, and if the overlay declines any of them, per cell.

* **507 of the 808 built documents have at least one CONST-tier observed**;
  3399 CONST-tier observed rules in total. 82 of those documents are in the
  compiled-right-hand-side population.
* The same off-tape path runs at three more points: the per-segment DISCRETE
  seed (`driver.rs:1026`), the build-observability snapshot
  (`driver.rs:733`), and **output-time observed materialization at every
  output node** (`driver.rs:1381` and `:1496`, `append_observed_trajectories`).
* Construction has its own scalar evaluations outside the array runtime:
  `static_observed_fields` (`problem.rs:1676`) runs the **scalar interpreter**
  over a state-free document's observeds at `t0`, and build-time constant
  folding goes through `eval_expression` (`simulate_array/compile.rs:2957`,
  `:3383`) and `area_faq.rs:153`.

If `native` must refuse per-cell evaluation wherever it happens, these sites
need the same gate as `Instr::Fallback`, and they are not behind it today.

### 1.5 Fallback-reason histogram

Normalised deepest bail reason (identifiers collapsed to `` `X` ``, numbers to
`N`); "rules" counts rule instances, "docs" counts documents.

| rules | docs | reason |
|---|---|---|
| 463 | 46 | ``op: closed function `X` has no tape lowering (esm-spec §9.2)`` |
| 333 | 14 | ``variable: observed `X` has a statically-unknown shape (fallback producer)`` |
| 121 | 22 | ``wholesale: unresolved symbol (forcing/NaN sentinel?) `X`` |
| 35 | 13 | ``wholesale: unsupported op `X`` |
| 14 | 8 | `faq: empty output box` |
| 10 | 10 | `observed: causal self-reference (recurrence) — sequential sweep only` |
| 9 | 9 | `makearray: region value box does not match the region` |
| 8 | 8 | `index: const-array gather out of range (§5.5.5)` |
| 7 | 5 | `aggregate: carries an overlap join gate that drives enumeration` |
| 6 | 6 | ``op: unsupported operator `X`/N`` |
| 5 | 5 | `contracted: non-static contraction dim` |
| 3 | 3 | `reduction: non-static contraction dim (Derived { from_faq: "overlap_clip" })` |
| 3 | 1 | `ifelse: branch value boxes differ under a runtime scalar condition` |
| 1 | 1 | `reduction: rank-0 reduction with a filter` |
| 1 | 1 | `makearray: empty region` |
| 1 | 1 | `index: base is a scalar but N index args given` |
| 36 | 21 | ``variable: unresolved symbol (forcing/loop-bind?): <name>`` (25 distinct names: `emis_annual`, `TotalPop`, `Advection.u_wind`, the `SR_*` source-receptor fields, …) |

Two reasons carry 75% of all fallback rules, and both are narrow:

* **`closed function has no tape lowering`** is **exactly three functions** —
  `interp.linear` (405 rules), `interp.bilinear` (57), `interp.searchsorted` (1).
  One lowering family retires 463 of the corpus's 1057 fallback rules.
* **`observed has a statically-unknown shape`** is a **cascade**, not a decline:
  it fires when a rule reads an observed that is already a fallback
  (`lower.rs:567`, `:1883`). 327 of its 333 instances are CONST-tier, i.e.
  downstream of the `interp.*` gap in the same documents.

The named-operator gaps are small and enumerable: wholesale `broadcast` (20),
`polygon_intersection_area` (6+6), `intersect_polygon` (3), `reshape` (2),
`concat` (2), `transpose` (2).

Split by tier, the reasons are almost disjoint. On the **RHS path** the top
reasons are `wholesale: unresolved symbol` (37), `wholesale: unsupported op`
(26), `makearray: region value box does not match the region` (9) and the
overlap join gate (7). At **setup** they are `closed function` (454) and the
shape cascade (327).

### 1.6 Top 20 documents by fallback count

| fallbacks / rules | routes to | document |
|---|---|---|
| 272/286 | static | `EarthSciModels/components/atmospheric_deposition/wesley_dry_gas.esm` |
| 211/240 | static | `EarthSciModels/components/gaschem/fastjx/fastjx_interp_troposphere.esm` |
| 192/251 | static | `EarthSciModels/components/gaschem/fastjx/fastjx.esm` |
| 76/85 | static | `EarthSciModels/components/earthsci_data/nei2016_monthly.esm` |
| 20/24 | static | `EarthSciModels/components/atmospheric_deposition/wesley1989/surface_resistance.esm` |
| 18/18 | static | `EarthSciModels/registered_functions/calc_direct_fluxes.esm` |
| 16/27 | static | `tests/conformance/pushdown/fixtures/isrm.esm` |
| 14/19 | static | `tests/conformance/pushdown/fixtures/pushdown_l1.esm` |
| 12/14 | **array** | `tests/valid/array_broadcast/broadcast_node_mixed_rank.esm` |
| 12/27 | static | `EarthSciModels/components/atmospheric_deposition/dry_aerosol.esm` |
| 9/9 | **scalar** | `tests/valid/scoped_refs_nested.esm` |
| 7/10 | **scalar** | `tests/valid/reaction_system_only.esm` |
| 6/12 | **array** | `tests/conformance/shaped_observed_scalar_broadcast/fixtures/scalar_rhs_broadcast.esm` |
| 6/87 | static | `EarthSciModels/components/aerosol/cloud_chemistry/cloud_chemistry.esm` |
| 6/7 | static | `EarthSciModels/components/wildland_fire/fuel_model_lookup.esm` |
| 6/98 | static | `EarthSciModels/components/aerosol/cloud_chemistry/cloud_chemistry_fixed_ph.esm` |
| 5/5 | fails today | `tests/coupling/callback_examples.esm` |
| 5/8 | **array** | `tests/fixtures/faq/27_broadcast_unary.esm` |
| 5/6 | **scalar** | `tests/scoping/hierarchical_scoped_references.esm` |
| 4/9 | static | `EarthSciModels/components/earthsci_data/geosfp.esm` |

Fourteen of the twenty route to `static` and so are not `native`'s problem
today — but they are where `interp.*` lives, and they are exactly the
documents whose CONST observeds are evaluated off the tape at setup (§1.4).

### 1.7 Build failures under the forced array runtime

231 documents load but do not build. 55 are library fragments (`"No models or
reaction systems to flatten"`). The rest, by cause:

| count | cause |
|---|---|
| 52 | `unlowered_operator` — `grad` (19), `D` (14), `laplacian` (9), a template's own placeholder op (5), `integral` (2), `div` (2). Pre-discretization documents; a discretization rewrite has to run first. Already a hard error today. |
| 43 | `unsupported_construct` — implicit equations (10), continuous events (11), discrete events (7) and their variants. Already a hard error today. |
| 29 | `InterpreterBuildError` — mostly `Unknown variable …` in `tests/invalid/` fixtures that are supposed to fail. |
| 8 | `unevaluable_operator: 'table_lookup'` |
| 8 | `UnsupportedFeatureError` — discrete parameters, SDE |
| 8 | `derived_index_set_unmaterialized` (value invention) |
| 6 | `Reaction`/flatten errors |
| 12 | one-offs: coupling imports, variable-map endpoints, array shape mismatch, `operator_compose`, observed cycles, dimensionality, domain units, broadcast fn |

133 of the 231 already fail under today's default routing, so they are not new
refusals. The route split: 720 documents built through `from_file`, 88 through
`flatten`, 106 failed on `from_file`, 125 failed in or after `flatten`.

---

## 2. Decline sites — where a document leaves the fast tier

### 2.0 The tiers, and what "landing path" means

Three tiers sit under `Backend::Array`, and one under `Backend::Scalar`:

1. **the tape** (`src/simulate_array/tape/`) — a flat instruction program built
   once per solve, fused into strip-mined kernel groups. Built rule by rule;
   a rule that cannot be lowered is rolled back
   (`lower.rs:2529`/`2557`, then `2531`/`2559`) and replaced by a single `Instr::Fallback { rule }`
   whose `RuleStatus::Fallback(reason)` carries the **deepest** `bail_tape!`
   text reached while trying.
2. **the whole-array overlay** (`src/simulate_array/vectorized.rs`) — array-at-a-time
   kernels, re-analysed from the AST on **every** RHS call.
3. **the per-cell oracle** (`tape/exec/oracle.rs`, `eval.rs`) — the AST
   interpreter, walked once per output cell per RHS call.
4. `Backend::Scalar` (`src/simulate/`) — the 0-D interpreter, outside this
   stack entirely.

**The landing path is not the same for the two rule kinds, and this matters
for D6.** `Instr::Fallback` dispatches on `RuleKind` at `tape/exec/interp.rs:336`:

* an **observed** rule goes to `materialize_observeds_pass` (`rhs.rs:524`),
  which *does* try the whole-array overlay first (`rhs.rs:677`, guarded to
  1-origin, non-empty, non-`force_scalar`) and only then walks per cell;
* an **RHS (state-derivative)** rule goes to `run_rhs_oracle`
  (`tape/exec/oracle.rs:16`), which **never tries the overlay** — it is a
  70-line `CartesianTuples` walk calling `reduce_contraction` once per output
  cell. The overlay attempt for RHS rules lives only in
  `evaluate_rhs_legacy` (`rhs.rs:1072`, the `!force_scalar` arm feeding `try_eval_faq_vectorized` at `rhs.rs:1078`), the pre-tape path taken when
  `tape_disabled()`.

So: **every `bail_tape!` on an RHS rule walks the tree per cell at RHS time**,
with no intermediate tier. Under D6 `native` must refuse all of them,
regardless of class.

### 2.1 `bail_tape!` — the 75 sites in `tape/lower.rs`

Class legend, as used below:

* **capability** — the tape has no form for this construct (or has one whose
  result would not be bit-identical). The landing path walks the tree at RHS
  time; `native` must refuse.
* **cost** — both tiers can express it and a cap, threshold or heuristic chose
  the slow one. The landing path still walks the tree at RHS time in every case
  found, so D6 refuses these too — but they are the sites a *raised cap* could
  retire without new lowering work.
* **build-only** — a defensive guard on a degenerate or malformed AST (a
  missing required member, a wrong arity, a zero-extent box). No schema-valid
  document with work to do reaches it, so it costs nothing at RHS time; it is
  listed for completeness and to keep the 75 accounted for.

| site | fn | reason string (the deepest-bail text the report prints) | trigger | class |
|---|---|---|---|---|
| `lower.rs:567` | `resolve_var` | variable: observed `{name}` has a statically-unknown shape (fallback producer) | reads an observed that is ITSELF a fallback rule (`ObsVal::External{shape:None}`) — shape unknown at build — cascade | **capability** |
| `lower.rs:576` | `resolve_var` | variable: unresolved symbol (forcing/loop-bind?): {name} | a symbol that resolves to neither state, observed, parameter nor loop bind (a run-time forcing) | **capability** |
| `lower.rs:608` | `lower_op_code` | op: `{}` precision boundary (the tape resolves kernels at execution) | a `Precision` boundary node (esm-spec §11.3.1) — the tape resolves kernels at execution and fuses across rules | **capability** |
| `lower.rs:614` | `lower_op_code` | op: `{}` with no arguments | an operator node with zero arguments — degenerate AST | build-only |
| `lower.rs:629` | `lower_op_code` | op: `neg` with no arguments | `neg` with zero arguments — degenerate AST | build-only |
| `lower.rs:639` | `lower_op_code` | op: array-valued `const` | `const` whose value is an array, inside a boxed (per-cell) context | **capability** |
| `lower.rs:643` | `lower_op_code` | op: comparison `{}` with arity {} | a comparison with arity != 2 — degenerate AST | build-only |
| `lower.rs:656` | `lower_op_code` | op: unary `{}` with arity {} | a unary op with arity != 1 — degenerate AST | build-only |
| `lower.rs:669` | `lower_op_code` | op: `broadcast` with no `fn` | `broadcast` with no `fn` member — degenerate AST | build-only |
| `lower.rs:672` | `lower_op_code` | op: broadcast fn `{fn_name}` is not a scalar operator | `broadcast` over a non-scalar operator — `op_registry::check_broadcast_fn` rejects this at build | build-only |
| `lower.rs:677` | `lower_op_code` | op: unsupported operator `{}`/{} | **any operator with no tape lowering** (the open coverage frontier) — the catch-all arm | **capability** |
| `lower.rs:695` | `emit_bin` | combine: array operand boxes differ ({sa:?}@{oa:?} vs {sb:?}@{ob:?}) | two array operands whose boxes (shape@origin) differ — no implicit broadcast/align in the tape | **capability** |
| `lower.rs:789` | `emit_const_array` | wholesale: rank-0 array-valued `const` | wholesale rank-0 array-valued `const` — degenerate | build-only |
| `lower.rs:792` | `emit_const_array` | wholesale: empty array-valued `const` | wholesale empty array-valued `const` — degenerate | build-only |
| `lower.rs:870` | `lower_closed_fn` | op: closed function `{name}` on an array-valued argument (the registry takes a scalar `t_utc`) | a §9.2 closed function applied to an array argument — the registry takes a scalar `t_utc` | **capability** |
| `lower.rs:885` | `lower_wholesale_closed_fn` | wholesale: closed function `{name}` on an array-valued argument (the registry takes a scalar `t_utc`) | same, on the wholesale path | **capability** |
| `lower.rs:898` | `closed_fn_name` | op: `fn` with no `name` | `fn` with no `name` — degenerate AST | build-only |
| `lower.rs:913` | `closed_fn_name` | op: closed function `{name}` has no tape lowering (esm-spec §9.2) | a §9.2 closed function with no tape lowering — per-function coverage gap | **capability** |
| `lower.rs:919` | `closed_fn_name` | op: closed function `{name}` with arity {} | a closed function with the wrong arity — degenerate AST | build-only |
| `lower.rs:925` | `closed_fn_name` | op: closed function `{name}` under a Float32 document (the calendar decomposition is exact integer arithmetic in binary64, and the tape resolves its kernels at execution) | a §9.2 closed function under a `Float32` document — calendar decomposition must stay exact binary64 | **capability** |
| `lower.rs:1240` | `lower_ifelse` | op: `ifelse` with arity {} | `ifelse` with arity != 3 — degenerate AST | build-only |
| `lower.rs:1287` | `emit_select` | select: branch boxes differ | `ifelse` whose two branch boxes differ | **capability** |
| `lower.rs:1300` | `emit_select` | select: operand box does not match the condition box | `ifelse` whose operand box does not match the condition box | **capability** |
| `lower.rs:1329` | `lower_index` | index: no arguments | `index` with no arguments — degenerate AST | build-only |
| `lower.rs:1340` | `lower_index` | index: base is a scalar but {n} index args given | `index` on a scalar base with subscripts — degenerate AST | build-only |
| `lower.rs:1345` | `lower_index` | index: arg count != source rank ({n} args vs rank {src_ndim}) | `index` arg count != source rank (partial or over-specified index) — a partial index is legal — cf. the wholesale mirror at 2041 | **capability** |
| `lower.rs:1371` | `lower_index` | index: axis {d} is neither an affine/wrap map of an unclaimed output symbol nor a constant select | **an index axis that is neither an affine/wrap map of an unclaimed output symbol nor a constant select** — the main gather frontier | **capability** |
| `lower.rs:1380` | `lower_index` | index: const-array gather with an out-of-range fixed axis (§5.5.5) | const-array gather with an out-of-range FIXED axis (§5.5.5) — out-of-range semantics are per-cell | **capability** |
| `lower.rs:1425` | `lower_index` | index: const-array gather entirely out of range on an axis (§5.5.5) | const-array gather entirely out of range on an axis (§5.5.5) | **capability** |
| `lower.rs:1432` | `lower_index` | index: const-array gather partially out of range on an axis (§5.5.5) | const-array gather partially out of range on an axis (§5.5.5) | **capability** |
| `lower.rs:1447` | `lower_index` | index: periodic wrap axis is not a full-period roll | a periodic-wrap axis that is not a full-period roll | **capability** |
| `lower.rs:1509` | `lower_makearray` | makearray: no `regions` | `makearray` with no `regions` — degenerate AST | build-only |
| `lower.rs:1512` | `lower_makearray` | makearray: no `values` | `makearray` with no `values` — degenerate AST | build-only |
| `lower.rs:1515` | `lower_makearray` | makearray: empty or mismatched regions/values | `makearray` with empty or mismatched regions/values — degenerate AST | build-only |
| `lower.rs:1519` | `lower_makearray` | makearray: region rank != output box rank | `makearray` region rank != output box rank — degenerate AST | build-only |
| `lower.rs:1525` | `lower_makearray` | makearray: ragged region rank | `makearray` ragged region rank — degenerate AST | build-only |
| `lower.rs:1529` | `lower_makearray` | makearray: unfolded (symbolic) region bound | a `makearray` region bound that is still symbolic (unfolded) | **capability** |
| `lower.rs:1555` | `lower_makearray` | makearray: unfolded (symbolic) region bound | same, on the second (value) pass | **capability** |
| `lower.rs:1566` | `lower_makearray` | makearray: empty region | an empty `makearray` region — degenerate | build-only |
| `lower.rs:1584` | `lower_makearray` | makearray: region value box does not match the region | a region value whose box does not match its region | **capability** |
| `lower.rs:1617` | `lower_nested_aggregate` | aggregate: node carries no `expr` body | an aggregate node with no `expr` body — degenerate AST | build-only |
| `lower.rs:1626` | `lower_nested_aggregate` | aggregate: rank-0 output (scalar reduction, nested in a box) | a rank-0 (scalar) reduction NESTED inside a box — the wholesale rank-0 case IS lowered (2100+) | **capability** |
| `lower.rs:1631` | `lower_nested_aggregate` | aggregate: carries an overlap join gate that drives enumeration | an aggregate carrying an overlap join gate that DRIVES enumeration — no driven form on the tape; see §2.4 | **capability** |
| `lower.rs:1635` | `lower_nested_aggregate` | aggregate: nested body depends on an enclosing bound index `{name}` | a nested aggregate body that reads an enclosing bound index | **capability** |
| `lower.rs:1664` | `lower_faq` | faq: empty output box | `faq` with an empty output box — nothing to compute | build-only |
| `lower.rs:1715` | `lower_faq` | faq: body reduced to a bare whole-array view (oracle scalarizes it) | a `faq` body that reduced to a bare whole-array view — the oracle scalarizes it; semantics differ | **capability** |
| `lower.rs:1723` | `lower_faq` | faq: result box does not match the output box | a `faq` result box that does not match the output box | **capability** |
| `lower.rs:1746` | `lower_contracted` | contracted: boolean reduction (or/and) not vectorized | a boolean (`or`/`and`) contraction — no combine kernel | **capability** |
| `lower.rs:1751` | `lower_contracted` | contracted: contraction rank out of range ({nc}) | contraction rank 0, **or rank > `MAXC` = 4** — MAXC is a fixed-array implementation cap, mirrored at vectorized.rs:504 | **cost** |
| `lower.rs:1761` | `lower_contracted` | contracted: non-static contraction dim ({other:?}) | a non-static (ragged / derived-bound) contraction dimension | **capability** |
| `lower.rs:1883` | `resolve_wholesale_var` | variable: observed `{name}` has a statically-unknown shape (fallback producer) | wholesale read of an observed that is itself a fallback rule — cascade | **capability** |
| `lower.rs:1891` | `resolve_wholesale_var` | wholesale: unresolved symbol (forcing/NaN sentinel?) `{name}` | wholesale unresolved symbol (forcing / NaN sentinel) | **capability** |
| `lower.rs:1999` | `lower_wholesale_op` | wholesale: unsupported op `{other}` | **any wholesale op with no tape lowering** — the wholesale catch-all arm | **capability** |
| `lower.rs:2022` | `lower_wholesale_index` | wholesale: index base is a scalar but has {} subscripts | wholesale `index` on a scalar base with subscripts — degenerate AST | build-only |
| `lower.rs:2028` | `lower_wholesale_index` | wholesale: index base is not origin-1 | a wholesale `index` base that is not origin-1 | **capability** |
| `lower.rs:2034` | `lower_wholesale_index` | wholesale: non-literal index argument | a non-literal wholesale index argument | **capability** |
| `lower.rs:2041` | `lower_wholesale_index` | wholesale: partial index yields a sub-array | a partial wholesale index (yields a sub-array) | **capability** |
| `lower.rs:2054` | `lower_wholesale_index` | index: const-array gather out of range (§5.5.5) | wholesale const-array gather out of range (§5.5.5) | **capability** |
| `lower.rs:2075` | `lower_wholesale_aggregate` | aggregate: carries an overlap join gate that drives enumeration | a wholesale aggregate carrying a driving overlap join gate — see §2.4 | **capability** |
| `lower.rs:2132` | `lower_scalar_reduction` | reduction: rank-0 reduction with a filter (the oracle SKIPS excluded tuples; a mask-to-identity fold is not bit-identical) | a rank-0 reduction WITH a `filter` — the oracle SKIPS excluded tuples; a mask-to-identity fold is not bit-identical | **capability** |
| `lower.rs:2138` | `lower_scalar_reduction` | reduction: boolean reduction (or/and) has no combine kernel | a boolean (`or`/`and`) scalar reduction — no combine kernel | **capability** |
| `lower.rs:2159` | `lower_scalar_reduction` | reduction: non-static contraction dim ({other:?}) | a non-static contraction dimension in a scalar reduction | **capability** |
| `lower.rs:2183` | `lower_scalar_reduction` | reduction: body reduced to a bare whole-array view | a scalar-reduction body that reduced to a bare whole-array view | **capability** |
| `lower.rs:2191` | `lower_scalar_reduction` | reduction: body box does not match the contraction window | a scalar-reduction body box that does not match the contraction window | **capability** |
| `lower.rs:2244` | `lower_wholesale_makearray` | makearray: empty bounding-box axis (per-cell path) | `makearray` with an empty bounding-box axis — degenerate | build-only |
| `lower.rs:2247` | `lower_wholesale_makearray` | makearray: prefix-scan region value (per-cell path) | a `makearray` region value that is a prefix scan | **capability** |
| `lower.rs:2278` | `lower_prefix_scan` | scan: boolean reduction not compiled (per-cell path) | a boolean prefix scan — not compiled | **capability** |
| `lower.rs:2286` | `lower_prefix_scan` | scan: empty output box (per-cell path) | a prefix scan with an empty output box — degenerate | build-only |
| `lower.rs:2398` | `lower_branchy_ifelse` | ifelse: branch value boxes differ under a runtime scalar condition | an `ifelse` whose branch VALUE boxes differ under a runtime scalar condition | **capability** |
| `lower.rs:2825` | `lower_observed_rule` | observed: causal self-reference (recurrence) — sequential sweep only (esm-spec §4.3.1.1, CONFORMANCE_SPEC §5.19.2) | an observed with a causal self-reference (recurrence) — sequential sweep only — esm-spec §4.3.1.1, CONFORMANCE_SPEC §5.19.2 | **capability** |
| `lower.rs:2841` | `lower_observed_rule` | observed: rank-0 ArrayLoop | a rank-0 `ArrayLoop` observed — degenerate | build-only |
| `lower.rs:2844` | `lower_observed_rule` | observed: non-unit-origin output ranges (per-cell path) | an observed with non-unit-origin output ranges | **capability** |
| `lower.rs:2847` | `lower_observed_rule` | observed: empty padded box (per-cell path) | an observed with an empty padded box — degenerate | build-only |
| `lower.rs:2942` | `lower_rhs_rule` | rule: LHS is not a constant per-axis shift of the output indices | an RHS rule whose LHS is not a constant per-axis shift of the output indices (a scatter) | **capability** |
| `lower.rs:2945` | `lower_rhs_rule` | rule: shifted output box does not fit the variable block | an RHS rule whose shifted output box does not fit the variable block | **capability** |

**Totals: 48 capability, 1 cost, 26 build-only.**

The one **cost** site is `lower.rs:1751` — `const MAXC: usize = 4`
(`lower.rs:1748`), a fixed-size-array cap on contraction rank, mirrored
verbatim in the overlay at `vectorized.rs:502`/`:504`. A rank-5 contraction is
expressible on both tiers; only the `[i64; 4]` scratch stops it. Its landing
path is the per-cell oracle, so D6 refuses it anyway.

The two rows to watch are the catch-alls: `lower.rs:677`
(`op: unsupported operator {op}/{arity}`) and `lower.rs:1999`
(`wholesale: unsupported op {op}`). Every operator the tape has not been taught
arrives at one of those two, so their share of the fallback histogram in §1 is
the size of the open lowering frontier.

Two rows are *cascades* rather than declines in their own right:
`lower.rs:567` and `lower.rs:1883` fire when a rule reads an observed that is
**itself** already a fallback (`ObsVal::External { shape: None }`). One genuine
decline can therefore show up as many fallback rules in the report, and the
histogram in §1 counts the cascade separately for that reason.

### 2.2 The whole-array overlay — `bail_vec!` and `return None` in `vectorized.rs`

Every decline here lands on the **per-cell oracle**. There is no tier below it.
`bail_vec!` (`vectorized.rs:115`) records the site in a thread-local log (only
when `ESS_VEC_DEBUG` is set) and returns `None`.

| site | fn | trigger | class |
|---|---|---|---|
| `vectorized.rs:357` | `try_eval_faq_vectorized` | `vec_disabled()` — the `ESS_VEC_DISABLE` kill switch | **cost** |
| `vectorized.rs:365` | `try_eval_faq_vectorized` | `faq` with an empty output box | build-only |
| `vectorized.rs:429` | `try_eval_faq_vectorized` | body reduced to a bare whole-array view (the oracle scalarizes it) | **capability** |
| `vectorized.rs:439` | `try_eval_faq_vectorized` | result box does not match the output box | **capability** |
| `vectorized.rs:497` | `eval_vec_contracted` | boolean (`or`/`and`) contraction — no combine kernel | **capability** |
| `vectorized.rs:505` | `eval_vec_contracted` | contraction rank 0, **or rank > `MAXC` = 4** (`:502`) | **cost** |
| `vectorized.rs:516` | `eval_vec_contracted` | non-static (ragged / derived-bound) contraction dim | **capability** |
| `vectorized.rs:1178` | `eval_vec_nested_aggregate` | aggregate node with no `expr` body | build-only |
| `vectorized.rs:1181` | `eval_vec_nested_aggregate` | rank-0 (scalar) reduction nested in a box | **capability** |
| `vectorized.rs:1187` | `eval_vec_nested_aggregate` | aggregate carrying an overlap join gate that drives enumeration (`has_drivable_overlap`, `eval.rs:4423`) | **capability** |
| `vectorized.rs:1196` | `eval_vec_nested_aggregate` | nested body reads an enclosing bound index | **capability** |
| `vectorized.rs:1515` | `eval_vec_index` | `index` with no arguments | build-only |
| `vectorized.rs:1541` | `eval_vec_index` | arg count != source rank (partial / over-specified index) | **capability** |
| `vectorized.rs:1601` | `eval_vec_index` | **an index axis that is neither an affine/wrap map of an unclaimed output symbol nor a constant select** — the main gather frontier | **capability** |
| `vectorized.rs:1624` | `eval_vec_index` | const-array gather with an out-of-range fixed axis (§5.5.5) | **capability** |
| `vectorized.rs:1677` | `eval_vec_index` | const-array gather entirely out of range on an axis | **capability** |
| `vectorized.rs:1690` | `eval_vec_index` | const-array gather partially out of range on an axis | **capability** |
| `vectorized.rs:1707` | `eval_vec_index` | periodic-wrap axis that is not a full-period roll | **capability** |
| `vectorized.rs:1834` | `eval_vec_index` | broadcast of the gathered value to the output box failed | **capability** |
| `vectorized.rs:1898` | `eval_vec_makearray` | `makearray` with no `regions` | build-only |
| `vectorized.rs:1902` | `eval_vec_makearray` | `makearray` with no `values` | build-only |
| `vectorized.rs:1905` | `eval_vec_makearray` | empty or mismatched regions/values | build-only |
| `vectorized.rs:1909` | `eval_vec_makearray` | region rank != output box rank | build-only |
| `vectorized.rs:1918` | `eval_vec_makearray` | a single region of the wrong rank | build-only |
| `vectorized.rs:1922` | `eval_vec_makearray` | region bound still symbolic (unfolded) | **capability** |
| `vectorized.rs:1941` | `eval_vec_makearray` | region bound still symbolic, second (value) pass | **capability** |
| `vectorized.rs:1953` | `eval_vec_makearray` | a zero-extent region | build-only |
| `vectorized.rs:1981` | `eval_vec_makearray` | region value box does not match its region | **capability** |
| `vectorized.rs:240` | `lhs_constant_shifts` | the rule's LHS index expressions are not constant per-axis shifts (a scatter) | **capability** |
| `vectorized.rs:268`, `:275`, `:279` | `subblock_dest` | the shifted output block does not fit inside the variable's array | **capability** |
| `vectorized.rs:1010` | `eval_vec_op_code` | comparison with arity != 2 | build-only |
| `vectorized.rs:1023` | `eval_vec_op_code` | `ifelse` with arity != 3 | build-only |
| `vectorized.rs:1056` | `eval_vec_op_code` | unary op with arity != 1 | build-only |
| `vectorized.rs:1079` | `eval_vec_op_code` | `broadcast` over a non-scalar operator (`op_registry::check_broadcast_fn` normally rejects this at build) | build-only |
| `vectorized.rs:1381` | `vec_combine_with` | array ∘ array whose boxes (shape@origin) differ | **capability** |
| `vectorized.rs:1444` | `vec_select` | `ifelse` whose branch boxes differ | **capability** |
| `vectorized.rs:2176`, `:2279` | `join`, `affine_terms` | a nonlinear (`sym·sym`) index expression | **capability** |

Not counted as declines, listed so the `return None` grep is accounted for:

* `vectorized.rs:118`, `:122` — `describe_expr`, a diagnostic string helper.
* `vectorized.rs:587`, `:595`, `:636`, `:666`, `:674`, `:1970`, `:2186` —
  propagations of an inner decline that has already recorded its own reason
  (they exist to return pooled buffers before unwinding).
* `vectorized.rs:2220`, `:2227`, `:2231`, `:2235` (`offset_in_axis`),
  `:2316`, `:2320`, `:2324` (`parse_wrap_axis`), `:2344` (`as_cmp_const`),
  `:2387` (`old_role`) — pattern-match predicates whose failure is *reported*
  by the named bail at `:1601` or `:1707`.

### 2.3 `tape_disabled()` — `tape/exec/mod.rs:86`

Two conditions, checked in this order:

| condition | site | effect | class |
|---|---|---|---|
| `crate::precision::has_variable_overrides()` — the document declares a per-variable `element_type` (esm-spec §11.3.1) | `tape/exec/mod.rs:99` | **no tape at all**; every RHS call runs `evaluate_rhs_legacy`, i.e. the overlay-then-oracle pair | **capability** — the tape resolves kernels at execution from one thread-local precision and fuses *across* rules, so a subtree in a precision its neighbours are not is the one thing it cannot express |
| `ESS_TAPE_DISABLE=1` / `=true` | `tape/exec/mod.rs:103` (`OnceLock`) | same | **cost** (a kill switch; bit-identical either way) |

Note the ordering: the precision check is **before** the `OnceLock`, so it is a
per-call thread-local read, and it is not cached.

### 2.4 The join-gate planner and the overlap gate

**These are unreachable from the tape.** Both the boxed and the wholesale
aggregate lowerings refuse a node with a driving gate up front
(`lower.rs:1631`, `lower.rs:2075`, via `ReduceSpec::has_drivable_overlap`,
`eval.rs:4423`), and the overlay mirrors that refusal at `vectorized.rs:1187`.
Every decision in this section therefore happens **inside the per-cell
oracle**, on documents that have already left the fast tier. They change how
expensive the oracle is, never whether a document is taped.

`resolve_join_gates` (`eval.rs:3137`), called from `eval.rs:4519`:

| site | trigger | landing path | class |
|---|---|---|---|
| `eval.rs:3143` | `!join_gate_enabled()` — `ESS_JOIN_GATE_DISABLE` (`broad_phase.rs:402`), or `set_join_gate_enabled(false)` per thread | no gates: the oracle walks the untouched full product, decided by the lowered `filter` | **cost** (kill switch) |
| `eval.rs:3164` | an overlap clause whose `sym_src`/`sym_tgt` were not resolved at build (`join::resolve_overlap_join_syms`) | that clause contributes no gate | **capability** (build-time resolution failed; nothing to price) |
| `eval.rs:3168` | `src_env`/`tgt_env` empty | same | build-only |
| `eval.rs:3174` | an envelope factor that is not array data in this context (`env_factor_len` → `None`) | same | **capability** |
| `eval.rs:3192` | `evict_to_budget(gate_cache_pair_budget())` — `ESS_GATE_CACHE_PAIRS`, default 4 000 000 pairs (`broad_phase.rs:484`, `DEFAULT_GATE_CACHE_PAIRS`) | the index is rebuilt on the next evaluation instead of being reused | **cost** (a memory cap; answers unchanged) |
| `eval.rs:3197` | `build_overlap_index` returned `None` | that clause contributes no gate | **capability** |
| `eval.rs:3242` | an `on` gate whose `cols_l`/`cols_r` mismatch or are empty | no gate | build-only |
| `eval.rs:3245` | `equality_cache_key` unavailable | no gate | **capability** |
| `eval.rs:3287` | `equality_sides` — the columns cannot be read as exact-equality keys here; the decline is memoised into `EQ_GATE_CACHE` as `None` | no gate | **capability** |
| **`eval.rs:3342`** | **the planner decline**: `!gates.is_empty() && matches >= floor && matches > space * ratio` — `ESS_GATE_PLAN_RATIO` (default 4) and `ESS_GATE_PLAN_FLOOR` (default 1 000 000), both `broad_phase.rs:509`/`:528`, constants at `broad_phase.rs:544`/`:548` | the equality is still applied — `crate::join` lowered it into the node's `filter` — so the oracle walks wider and returns the same numbers | **cost** |

The planner decline is the only place in the crate where a *heuristic*, rather
than an expressivity limit, picks the slower path for a document that is
otherwise fine. It is guarded three ways (never the only gate; never below the
floor; only above the ratio), and `broad_phase.rs:506` records why declining is
always safe.

### 2.5 Per-cell evaluation that happens OFF the tape

The tape only governs the right-hand-side closure. These call sites evaluate
model expressions through the whole-array overlay — and, when it declines, the
per-cell oracle — with no tape involved and no entry in any fallback report.
`native` must gate them too; today nothing does. §1.4 measures the exposure.

| site | what it evaluates | when | class |
|---|---|---|---|
| `simulate_array/driver.rs:697` (`hoist_static_observeds`, called at `:518`) | every CONST-tier observed, via `materialize_observeds_into` (`rhs.rs:465`, `force_scalar: false`) | once per solve, **before** `build_solve_tape` at `:530` | **capability** — 507 of 808 built documents have at least one such rule |
| `simulate_array/driver.rs:1026` | the DISCRETE (segment-invariant) observed seed | once per segment | **capability** |
| `simulate_array/driver.rs:1381` | the observed-rank probe cone for `append_observed_trajectories` | once per solve | **capability** |
| `simulate_array/driver.rs:1496` | the varying observed rules at **every output node** | once per saved time point | **capability** |
| `simulate_array/driver.rs:733` (`fill_solve_inspection`) | a t0 snapshot of the varying regrid observeds | once, when `inspect` is set | build-only |
| `problem.rs:1676` (`static_observed_fields`) | a state-free document's observeds at `t0`, through the **scalar interpreter** (`Compiled::evaluate_static_observeds`) | at construction | **capability** — this is the `Backend::Static` path D3 does not mention |
| `simulate_array/compile.rs:2957`, `:3383` | build-time constant folding (`eval_expression`) | at build | build-only |
| `area_faq.rs:153` | a geometry `area` aggregate at build | at build | build-only |
| `simulate_array/compile.rs:3515` (`run_value_invention`) | derived index sets / value-invented arrays | at build | build-only |

The first four share one function, `materialize_observeds_pass` (`rhs.rs:524`),
whose per-cell arm is `rhs.rs:728` and whose overlay attempt is `rhs.rs:677`.
That single function is the choke point a strict `native` would gate — the same
role `Instr::Fallback` plays on the right-hand-side path.


---

## 3. Test-file classification

Buckets: **(1) fixture** — "this document produces these values"; the assertion
is about model semantics and belongs in a cross-language fixture.
**(2) binding-internal** — it asserts something only Rust can observe
(allocations, progress callbacks, tape/overlay internals, API surface, env A/B).
**(3) refusal/diagnostic** — it asserts a build or solve is refused with a
particular code or wording; no golden trajectory.

Two scope corrections to the list the task carried:

* `tests/nonadvancing_run_skips_the_solver.rs` **does not exist on this
  branch** — it is on `perf/issue-438-nonadvancing-run`.
* The keyword list (`esm_problem` / `solve` / `ArrayCompiled` / …) misses the
  largest entry point: **40 test files run simulations through
  `run_inline_tests` / `run_inline_tests_with_base_dir`**, including four of the
  six `pde_inline_*_conformance.rs` files. Three more shell out to
  `CARGO_BIN_EXE_esm`.

97 files build and/or run something. Rough split: **≈52 fixture, ≈29
binding-internal, ≈16 refusal/diagnostic.**

| file (`pkg/earthsci-ast-rs/tests/`) | tests | bucket | reason |
|---|---|---|---|
| `alias_observed_export_order.rs` | 4 | binding-internal | tape export ordering, taped RHS vs per-cell oracle through `debug_eval_rhs` / `debug_new_scratch_taped` |
| `array_level_broadcast.rs` | 11 | fixture | §4.3.4 name-based broadcast values over shared fixtures (2 structural refusals, 2 bare-vs-aggregate bit identity) |
| `array_observed_output.rs` | 5 | binding-internal | Rust `OutputPlan` / CLI gridding of a requested array observed, not a trajectory golden |
| `arrayed_vars.rs` | 7 | fixture | shape/location round-trips through `esm_problem`, never solves (2 undeclared-axis refusals) |
| `assertion_nonfinite_conformance.rs` | 1 | fixture | shared category: non-finite actuals fail every finite expectation |
| `build_once_spatial_field_conformance.rs` | 2 | fixture | shared analytic golden, CONFORMANCE_SPEC §5.12 |
| `cli_data_source_ingest.rs` | 10 | binding-internal | drives the `esm` binary; CLI / exit-code contract (3 refusal) |
| `cli_static_evaluation_output.rs` | 6 | binding-internal | `esm simulate` output-file/format contract (3 refusal) |
| `cli_test_command.rs` | 11 | binding-internal | `esm test` verdict classification and exit codes (4 refusal) |
| `const_array_gather_bounds_conformance.rs` | 1 | refusal | shared category: an out-of-range const gather fails with the spec code |
| `const_array_gather_oob.rs` | 6 | refusal | fail-closed const gathers (4 of 6); 2 pin zero-ghost / periodic numerics |
| `coupled_array_seam.rs` | 5 | binding-internal | the `ArrayCompiled::from_flattened` Rust entry-point surface (1 refusal) |
| `coupled_const_array_fold.rs` | 4 | fixture | two spellings of one table must give the same number (issue #207) |
| `coupling_imports.rs` | 21 | fixture | import→edge expansion and flatten equivalence, ported from the TS reference (6 refusals, 1 solve) |
| `cse_equivalence.rs` | 3 | binding-internal | CSE bit identity vs the per-cell oracle + grid-independent `kernel_op_count` |
| `cumulative_prefix_scan.rs` | 11 | binding-internal | scan-vs-triangular-oracle identity, linear-work and `Instant::now` timing (≈6 of 11; ≈5 are value fixtures) |
| `data_output_derivation.rs` | 6 | binding-internal | Rust output-plan derivation over real flat state names (2 refusals) |
| `data_output_zarr_roundtrip.rs` | 1 | binding-internal | plan → EarthSciIO Zarr v3 write and read-back |
| `discrete_materialize_conformance.rs` | 2 | fixture | shared analytic golden, §5.13 |
| `elementwise_observed_gather_conformance.rs` | 1 | fixture | shared Julia-minted golden |
| `evaluable_core_gate.rs` | 7 | refusal | "no document both validates and panics": every unevaluable core op must end in a diagnostic |
| `expression_templates_conformance.rs` | 11 | refusal | 2 of 11 gate unlowered ops through `Compiled::from_file`; the other 9 compare expanded ASTs and run nothing |
| `faq_conformance.rs` | 12 | fixture | the four M1 worked-example fixtures and their inline assertions |
| `faq_simulate.rs` | 10 | fixture | semiring / index-set evaluation values (2 reject an undeclared `from`) |
| `field_ic_unlowered_operator.rs` | 2 | refusal | an unlowered op in a field `ic` is refused at build (1 positive control) |
| `function_tables_inline_tests.rs` | 5 | fixture | `table_lookup` evaluates like its hand-lowered twin (2 out-of-bounds refusals) |
| `geometry_simulate_conformance.rs` | 4 | fixture | shared geometry fixtures simulate against goldens, §5.8 |
| `inline_test_build_memo.rs` | 10 | binding-internal | build-memo cache keying and "a filter skips the build" — a Rust runner optimisation |
| `inline_test_reference_mount_name.rs` | 2 | fixture | mount-relative `reference` resolves (issue #408); 1 unbound-typo refusal |
| `interpret.rs` | 16 | fixture | operator-by-operator numeric values for the scalar interpreter (2 refusals) |
| `inverse_trig_conformance.rs` | 2 | fixture | shared inverse-trig / hyperbolic leaf-op goldens |
| `join_gate_cache_budget.rs` | 3 | binding-internal | resident-pair budget: build counts, eviction/rebuild, setter returns the previous value |
| `join_on_conjunctive_gate.rs` | 3 | fixture | §5.24 conjunctive-gate values and identity fill |
| `join_on_equality_gate.rs` | 12 | fixture | §5.5.8 gate values (4 of 12 are gate on/off bit identity or visit-counter scaling → binding-internal) |
| `join_on_equality_gate_bench.rs` | 3 | binding-internal | `#[ignore]`d wall-clock measurements, self-described as measurements not assertions |
| `join_on_self_join.rs` | 11 | fixture | self-join semantics and values (4 refusals, 2 gate bit-identity / work counters) |
| `loaded_ic_bc_simulation.rs` | 1 | fixture | full pre-discretization + loader PDE pipeline with provider injection |
| `loader_ingest_and_select.rs` | 18 | fixture | §8.9 loader-ingest values off real FF10 / Zarr fixtures (6 refusals) |
| `m2_join_filter.rs` | 7 | fixture | join + filter values through the real pipeline (1 build refusal, 1 byte-identity control) |
| `merged_rename_reach_conformance.rs` | 9 | fixture | shared `merged_rename_reach` manifest (1 refusal) |
| `mounted_component_tests.rs` | 3 | fixture | §6.6: a mounted leaf's inline tests do not run in the assembly |
| `observed_cadence_tier.rs` | 1 | binding-internal | `debug_cadence_partition` CONST / DISCRETE / CONTINUOUS classification |
| `observed_cycle.rs` | 6 | refusal | an observed dependency cycle is named at validate and at build (4 of 6) plus a corpus sweep |
| `observed_field_static.rs` | 6 | binding-internal | `observed_field` name resolution / API surface on a state-free document (2 refusals) |
| `observed_trajectory.rs` | 10 | binding-internal | `observed_trajectory` / `observed_trajectories` API surface: spellings, bulk form, remake, bindings (2 refusals) |
| `overlap_gate_dense_scaling.rs` | 4 | binding-internal | visited-tuple counts prove candidate-driven, not full-product, evaluation |
| `override_key_diagnostics_conformance.rs` | 1 | refusal | shared manifest of unrecognized-override-key raises |
| `pde_const_hoist.rs` | 2 | binding-internal | const-hoist store vs oracle through `debug_eval_rhs`, plus parameter-change invalidation |
| `pde_inline_array_overrides_conformance.rs` | 3 | fixture | shared golden (1 shape-mismatch build error) |
| `pde_inline_dead_observed_conformance.rs` | 1 | fixture | shared Julia-minted golden |
| `pde_inline_ic_param_override_conformance.rs` | 2 | fixture | shared golden plus local/qualified override-key spellings |
| `pde_inline_observed_indexed_lhs_conformance.rs` | 2 | fixture | shared golden (1 refusal) |
| `pde_inline_observed_state_dependent_conformance.rs` | 1 | fixture | shared golden |
| `pde_inline_reference_dimension_names_conformance.rs` | 1 | fixture | shared golden |
| `pde_vectorized_eval.rs` | 14 | binding-internal | the no-scalarization contract: `kernel_op_count` grid-independence + vectorized-vs-oracle identity (≈9 of 14) |
| `pde_zero_alloc.rs` | 1 | binding-internal | counting global allocator (`ALLOC_COUNT`): zero allocations in the steady-state RHS |
| `ppm_template_chain.rs` | 3 | fixture | a deep PPM template chain loads, lowers deterministically and simulates a few steps |
| `precision_element_type.rs` | 10 | fixture | Float32 per-operation rounding semantics §11.3 (4 refusals) |
| `prepare_progress.rs` | 5 | binding-internal | `prepare` progress observer, cancellation, bit identity under observation |
| `prepare_pushdown_l1.rs` | 2 | fixture | Rust port of the Julia pushdown test against a frozen fixture and a step-0 oracle |
| `problem_surface.rs` | 20 | binding-internal | the `EsmProblem` / `solve` Rust API surface: remake, ensemble, callbacks, retcodes, stepping (5 refusals) |
| `pushdown_cell_geometry.rs` | 5 | fixture | §5.5.7 cell-axis arrays, one of a Julia/Python/Rust triple (1 refusal) |
| `reaction_system_inline_tests.rs` | 7 | fixture | §7.2 `reaction_systems[].tests` are discovered and run |
| `recurrence_causal_self_reference.rs` | 26 | refusal | §4.3.1.1: 13 of 26 are named rejections, the other ≈13 are evaluation fixtures — genuinely two-bucket |
| `refresh_conformance.rs` | 2 | fixture | shared refresh golden, §5.10 |
| `reserved_index_symbol.rs` | 7 | refusal | `reserved_index_symbol` rejected at load (4 of 7) plus loading controls |
| `reservoir_constant_species.rs` | 1 | fixture | shared cross-binding §7.4 reservoir fixture |
| `rhs_time_derivative.rs` | 9 | fixture | RHS `D(x,t)` resolves to the tendency (2 refusals) |
| `rhs_time_derivative_conformance.rs` | 4 | fixture | shared manifest, both the resolve and the refusal halves |
| `scalar_ic_conformance.rs` | 2 | fixture | shared golden, §11.4 `ic` seeding and precedence |
| `scalar_operand_in_faq.rs` | 3 | fixture | a 0-D declaration reads as a number inside a `faq` (1 named subscript fault) |
| `scalar_param_array_default.rs` | 1 | refusal | an array `default` on a scalar parameter must fail closed as `E_TREEWALK_UNBOUND_NAME`, not fabricate 0.0 |
| `scoped_assertion_variable.rs` | 5 | fixture | scoped assertion `variable` resolution across mounts (1 refusal) |
| `segmented_refresh_solve.rs` | 4 | binding-internal | segmented-solve driver harness: state threading and per-segment refresh counters (1 closed-form fixture) |
| `shaped_observed_scalar_broadcast_conformance.rs` | 1 | fixture | shared golden, §4.3.4 |
| `shaped_parameter_broadcast_conformance.rs` | 2 | fixture | shared golden, §6.3 / §6.6.2 |
| `simulate.rs` | 18 | refusal | 11 of 18 are `test_error_*` construct rejections; the other 7 are analytic / literature trajectory goldens — the clearest split file |
| `simulate_progress.rs` | 7 | binding-internal | `SolveOptions::progress` observer and cancel across both stepping loops |
| `solver_block.rs` | 5 | binding-internal | §2.2 solver-block round-trip and tolerance resolution onto the Rust problem, never solves (1 version refusal) |
| `static_evaluation_assertions_conformance.rs` | 9 | fixture | shared golden plus §6.6.3 static-time semantics (3 refusals) |
| `subsystem_loader_conformance.rs` | 2 | fixture | shared analytic golden, §5.11 |
| `subsystem_mount_join_names.rs` | 2 | fixture | a mounted leaf keeps its `join.on` key columns end to end |
| `tape_check_mode.rs` | 1 | binding-internal | `ESS_TAPE_CHECK=N` dual-path env A/B verification |
| `tape_exec.rs` | 2 | binding-internal | tape invalidation discipline; taped RHS vs the interpreter |
| `tape_fallback_reporting.rs` | 2 | binding-internal | `SolutionMetadata::tape_fallbacks` naming — the only fallback-reporting assertions in the suite |
| `tape_kill_switch.rs` | 1 | binding-internal | `ESS_TAPE_DISABLE=1` env kill-switch A/B equivalence |
| `tests_blocks_execution.rs` | 1 | fixture | runs the inline `tests` blocks of `tests/simulation/*.esm`, mirroring the Julia runner |
| `transcendental_scale_conformance.rs` | 5 | fixture | §4.8.3 degree/radian scale on both the flatten and the array route (2 refusals) |
| `undeclared_operand_gate.rs` | 6 | refusal | §5.23: an unbound operand is an error on every route, in the same words |
| `unsupported_construct_conformance.rs` | 1 | refusal | shared manifest: continuous / discrete events and implicit equations refused |
| `value_invention_materialize_conformance.rs` | 2 | fixture | shared manifest, the value and the refused halves |
| `value_invention_simulate.rs` | 2 | fixture | two value-invention (relational output) models simulate end to end |
| `variable_map_expression_transform.rs` | 11 | refusal | 6 of 11 are load/validate/flatten rejections; 1 end-to-end solve; the rest serde round-trips |
| `vec_coverage_frontier.rs` | 9 | binding-internal | pins which constructs vectorize and which fall back, through `VecStats.scalar_rules` / `vectorized_rules` |
| `wasm_suite.rs` | 9 | binding-internal | the same models under `wasm32-unknown-unknown` in Node — the claim is that the wasm build works |
| `wildfire_simulation.rs` | 2 | fixture | the coupled wildfire/atmosphere/ocean fixture's trajectory and its inline tests |
| `wrt_default_omitted.rs` | 3 | fixture | an omitted `wrt` integrates exactly as `wrt: t` (issue #407); 1 display-path test |
| `xla_compiled_rhs.rs` | 6 | binding-internal | compiled XLA RHS vs the interpreter, device-resident path and GPU — a backend A/B (1 fallback refusal) |

Excluded after inspection (matched the search, run no simulation):
`assertion_tolerance_conformance.rs` (a pure §6.6.3 pass-predicate over a golden
table) and `cli_units_command.rs` (a dimensional-analysis report).
`tests/performance.rs` counts allocations but never simulates.

### 3.1 Tape / overlay internals in tests

**No test calls `debug_build_tape_report`.** Its only callers are
`src/wasm.rs:590`, `examples/tape_report.rs:59` and the new
`examples/compiler_census.rs:142`. Fallback reporting is pinned in exactly one
file, `tests/tape_fallback_reporting.rs`, through
`SolutionMetadata::tape_fallbacks` (two tests). If `native` is to refuse on a
fallback, that refusal has almost no existing test surface to inherit.

What the suite does probe: `debug_new_scratch_taped` / `debug_eval_rhs_into` /
`debug_resolve_params` / `fallback_rules` (tape_exec, tape_kill_switch,
tape_check_mode, pde_zero_alloc, alias_observed_export_order);
`debug_new_scratch` / `debug_eval_rhs(force_scalar)` (cse_equivalence,
pde_const_hoist, pde_vectorized_eval, vec_coverage_frontier,
segmented_refresh_solve, xla_compiled_rhs); `kernel_op_count` grid-independence
(cse_equivalence, pde_vectorized_eval); `ALLOC_COUNT` (pde_zero_alloc);
wall clock (join_on_equality_gate_bench `#[ignore]`d, cumulative_prefix_scan);
gate visit counters (join_on_equality_gate, join_on_conjunctive_gate,
join_gate_cache_budget, overlap_gate_dense_scaling).

30 files build a compiled object directly rather than through `esm_problem`:
`ArrayCompiled::from_file` in 16, `from_flattened` in 8, `from_model` in 1
(simulate.rs), `Compiled::from_file` in 5.

### 3.2 Tests that set or read an `ESS_*` variable

These are the tests the phase-2 switch retirement touches.

| test file | test fn | variable | set / read |
|---|---|---|---|
| `tests/tape_kill_switch.rs:94` | `ess_tape_disable_reverts_wholesale_to_the_legacy_path` | `ESS_TAPE_DISABLE` | SET (`unsafe { set_var(.., "1") }`; safe only because it is the only test in its binary and the set precedes `OnceLock` init) |
| `tests/tape_check_mode.rs:170` | `ess_tape_check_runs_both_paths_without_panicking` | `ESS_TAPE_CHECK` | SET (`"5"`, same single-test-binary rationale) |
| `tests/join_gate_cache_budget.rs:439` | `the_budget_setter_reports_the_previous_setting` | `ESS_GATE_CACHE_PAIRS` | READ (`var_os(..).is_none()` guard; skips the default assertion when set) |
| `tests/xla_compiled_rhs.rs:279` | `gpu_requested()` helper, used by `compiled_rhs_on_the_gpu` (`:304`) | `EARTHSCI_XLA_PLATFORM` | READ (skips unless `gpu`/`cuda`) |
| `src/simulate_array/tape/tests.rs:1486` | `export_demotion_skips_unread_publishes` | `ESS_TAPE_CHECK` | READ (early-returns when set) |
| `src/simulate_array/tape/tests.rs:1243` | `ab_model_file_if_available` | `TAPE_AB_MODEL` | READ (opt-in A/B gate) |
| `src/simulate_array/tape/tests.rs:1247` | `ab_model_file_if_available` | `TAPE_AB_MP` | READ (metaparameter spec for the same) |

No other `ESS_*` switch has any test. In particular `ESS_VEC_DISABLE`,
`ESS_CSE_DISABLE`, `ESS_TAPE_FUSE_DISABLE`, `ESS_TAPE_FUSE_MODE`,
`ESS_TAPE_BIN3`, `ESS_TAPE_EXTPAIR_DISABLE`, `ESS_TAPE_SIMD_*`,
`ESS_OUTOBS_PRUNE_DISABLE`, `ESS_JOIN_GATE_DISABLE`, `ESS_JOIN_GATE_STATS`,
`ESS_GATE_PLAN_RATIO` and `ESS_GATE_PLAN_FLOOR` are named only in comments, or
exercised through a programmatic setter (`set_join_gate_enabled`,
`set_gate_cache_pair_budget`, the `#[cfg(test)]` `set_gate_plan`), or not at
all. `cse_equivalence.rs`, `vec_coverage_frontier.rs`,
`join_on_equality_gate.rs`, `join_on_equality_gate_bench.rs` and
`alias_observed_export_order.rs` mention switches in comments without reading
them.

Other variables set in tests, unrelated to the switches:
`tests/cli_data_source_ingest.rs:315` sets `ESM_CACHE_DIR` on a subprocess, and
`tests/env_var_refs.rs` sets seven `ESM_RS_ENVREF_*` names through an
`EnvVar` RAII guard (`:31`) under a process-wide `ENV_LOCK` (`:20`) to exercise
esm-spec §4.7 `${VAR}` ref expansion.

---

## 4. Environment reads in `src/` — the phase-2 retirement list

21 distinct `ESS_*` / `EARTHSCI_*` variables. `ESS_OPS`, `ESS_SPELLINGS` and
`ESS_SYMS` turn up in a naive grep and are **not** variables — they are tails of
const names (`VI_ARGWITNESS_OPS`, `SCALED_DIMENSIONLESS_SPELLINGS`). There is no
`option_env!` anywhere.

| variable | read site | accessor | default | values | kind | effect | cached |
|---|---|---|---|---|---|---|---|
| `ESS_TAPE_DISABLE` | `tape/exec/mod.rs:103` | `tape_disabled()` | false | `1`\|`true` | oracle kill switch | no tape is built or installed; every RHS call runs the legacy interpreter | `OnceLock` |
| `ESS_TAPE_CHECK` | `tape/exec/mod.rs:173` | `tape_check_calls()` | `0` | `u64` | dual-run verify | for the first N calls of each taped scratch, runs both paths and asserts bitwise-equal `dy` (`rhs.rs:842`); also forces `Export` publishes back on | `OnceLock` |
| `ESS_TAPE_SIMD_DISABLE` | `tape/exec/mod.rs:134` | `simd_level()` | false | `1`\|`true` | device selection | forces the generic SSE-2 fused-loop clone; bit-identical | `OnceLock` |
| `ESS_TAPE_SIMD_LEVEL` | `tape/exec/mod.rs:143` | `simd_level()` | widest detected | `generic`\|`avx2`\|`avx512` | device selection | caps clone selection below the detected width | `OnceLock` |
| `ESS_TAPE_FUSE_DISABLE` | `tape/fuse.rs:58` | `fuse_disabled()` | false | `1`\|`true` | oracle kill switch | builds the unfused tape program; bitwise identical | `OnceLock` |
| `ESS_TAPE_FUSE_MODE` | `tape/exec/fused.rs:31` | `fuse_elem_mode()` | false (chunked) | `elem` | oracle kill switch | runs fused groups through the per-element micro-op interpreter | `OnceLock` |
| `ESS_TAPE_BIN3` | `tape/fuse.rs:666` | `SuperopCfg::from_env()` | false (off; measured slower) | `1`\|`true` | tuning threshold | lets the peephole merge three-op `+ - * /` chains into `MicroOp::Bin3` | `OnceLock` |
| `ESS_TAPE_EXTPAIR_DISABLE` | `tape/fuse.rs:667` | `SuperopCfg::from_env()` | false → `ext_pairs = true` | `1`\|`true` | tuning threshold | reverts `Bin2` merging to the bare arithmetic square, dropping mask/clamp pairs | `OnceLock` |
| `ESS_VEC_DISABLE` | `vectorized.rs:65` | `vec_disabled()` | false | non-empty, `!= "0"` | oracle kill switch | turns the whole-array overlay off everywhere, including `eval_faq`; the run is the pure per-cell oracle | `OnceLock` |
| `ESS_VEC_DEBUG` | `vectorized.rs:49` | `vec_trace_on()` | false | non-empty, `!= "0"` | debug logger | records a tag at every overlay bail site, innermost first | `OnceLock` |
| `ESS_CSE_DISABLE` | `cse.rs:239` | `cse_disabled()` | false | `1`\|`true` | oracle kill switch | `CseRt::class_of` returns `None` everywhere; un-memoized walk | `OnceLock` |
| `ESS_CSE_PARANOID` | `cse.rs:251` | `cse_paranoid()` | false | `1`\|`true` | dual-run verify | cross-checks the resolved class table against the map on every node visit | `OnceLock` |
| `ESS_OUTOBS_PRUNE_DISABLE` | `simulate_array/driver.rs:1755` | `outobs_prune_disabled()` | false | `1`\|`true` | oracle kill switch | materializes the full varying rule set at every output node instead of the dependency-cone-pruned subset | `OnceLock` |
| `ESS_JOIN_GATE_DISABLE` | `broad_phase.rs:402` | `join_gate_env_disabled()` → `join_gate_enabled()` | false (driver on) | non-empty, `!= "0"` | oracle kill switch | gated aggregates walk the full product and let the lowered `filter` decide | `OnceLock` then a thread-local `Cell` (`set_join_gate_enabled`) |
| `ESS_JOIN_GATE_STATS` | `broad_phase.rs:603` | `join_gate_stats_enabled()` | false | non-empty, `!= "0"` | debug logger | prints a per-gated-`faq` leaf-visit/cost line, and the planner's decline lines (`eval.rs:3344`) | `OnceLock` |
| `ESS_GATE_CACHE_PAIRS` | `broad_phase.rs:484` | `gate_cache_pair_budget()` | 4 000 000 pairs (~64 MB, `broad_phase.rs:479`) | `usize` | tuning threshold | resident-pair budget of the two join-gate index caches | `OnceLock` + thread-local `Cell` |
| `ESS_GATE_PLAN_RATIO` | `broad_phase.rs:551` via `env_u128`, from `:513` | `gate_plan_ratio()` | `4` | `u128` | tuning threshold | how far a gate may overshoot the pair space it narrows before the planner declines it | **no `OnceLock`** — thread-local `Cell` only |
| `ESS_GATE_PLAN_FLOOR` | `broad_phase.rs:551` via `env_u128`, from `:533` | `gate_plan_floor()` | 1 000 000 pairs | `u128` → `usize` | tuning threshold | gates smaller than this are never declined | **no `OnceLock`** — thread-local `Cell` only |
| `EARTHSCI_XLA_PLATFORM` | `xla_runtime.rs:154` | `client()` | CPU | `cpu`\|`gpu`\|`cuda`; anything else is a hard error | device selection | picks the PJRT client | `OnceLock<Result<…>>` (caches the failure too) |
| `EARTHSCI_XLA_GPU_MEMORY_FRACTION` | `xla_runtime.rs:156` | `client()` | `0.75` | `f64` | tuning threshold | fraction of device memory the GPU client may take | inside the same `OnceLock`, GPU arm only |
| `EARTHSCI_XLA_GPU_PREALLOCATE` | `xla_runtime.rs:160` | `client()` | false | `1`\|`true` | tuning threshold | GPU client preallocates its pool | inside the same `OnceLock`, GPU arm only |

By kind: **6 oracle kill switches**, 2 dual-run verifies, 2 debug loggers,
7 tuning thresholds, 4 device selections.

Other-prefix reads in `src/`, outside the retirement list but worth recording:

| variable | read site | note |
|---|---|---|
| `XLA_EXTENSION_DIR` | `xla_runtime.rs:190` (`var_os`), `build.rs:29` | chooses only the wording of a GPU-startup failure hint at run time; a real build-time dependency in `build.rs` |
| `ESM_DAE_SUPPORT` | `dae.rs:84` | gates document acceptance; `0`\|`false`\|`no`\|`off` disable. **Re-read on every call, no cache** |
| `ESM_CACHE_DIR` | `bin/esm_impl.rs:3710` | CLI, `esio` feature; EarthSciIO cache root |
| `ESM_CONFORMANCE_MANIFEST` | `bin/esm_impl.rs:4392` | CLI; conformance manifest path |
| *any name a document writes* | `ref_loading.rs:1445` (`expand_env_refs`) | esm-spec §4.7 `${VAR}` expansion inside a `ref`. The name comes from the `.esm` file, so this is an unbounded read surface — the one env read that is not a switch at all |

Two facts for phase 2: `ESS_GATE_PLAN_RATIO` and `ESS_GATE_PLAN_FLOOR` are the
only knobs that reach the environment without a `OnceLock`, and they are also
the only ones with no test coverage of any kind (only the `#[cfg(test)]`
`set_gate_plan` at `broad_phase.rs:566`).

---

## 5. Summary

1. **The tape is closer to being `native` than the plan assumed.** Over 1217
   documents, 808 build under a forced array runtime and **663 (82%) have zero
   fallback rules** — against 137 of 189 (72%) in the 2026-09-13 census.
   Restricted to the 286 documents that get a compiled right-hand side today,
   `native` would **accept 227 (79%) and refuse 59**.

2. **Ruling D3 is 91% true for 0-D documents already.** Of 187 `Backend::Scalar`
   documents the tape lowers 171 with no fallback. The 16 it does not split into
   four named pieces of work, two of which (`table_lookup`, events) are refusals
   under every backend today anyway.

3. **One routing line, not a lowering gap, blocks the whole chemistry corpus.**
   `build_array_compiled` flattens only when `models.len() > 1`, so a
   reaction-only document (no `models` at all) hits `from_file`'s "File has no
   models to simulate". Flattening whenever `models.len() != 1` moved 25
   documents — `pollu`, `superfast`, `geoschem_fullchem` — from "cannot build"
   to "builds, fully taped".

4. **Two reasons carry three quarters of all fallback rules, and both are
   narrow.** `closed function has no tape lowering` is exactly three functions
   (`interp.linear` 405 rules, `interp.bilinear` 57, `interp.searchsorted` 1),
   and `observed has a statically-unknown shape` (333) is the cascade
   downstream of them. One lowering family retires 463 of 1057.

5. **The per-cell work is mostly NOT on the right-hand-side path, and the tape
   report cannot see the part that matters.** 873 of the 1057 fallback rules are
   CONST-tier, evaluated once at setup; 184 are on the right-hand-side path. But
   `hoist_static_observeds` runs **before** `build_solve_tape` and evaluates
   every CONST-tier observed off the tape entirely — 507 of 808 built documents
   have at least one — as do the per-segment seed, the output-node
   materialization and `static_observed_fields`. A strict `native` has to gate
   `materialize_observeds_pass`, not only `Instr::Fallback`.

6. **Almost every decline site is a capability, not a cost.** Of the 75
   `bail_tape!` sites, 48 are capability, 26 are defensive guards on degenerate
   AST, and **one** is a cost cap (`MAXC = 4` on contraction rank). In the
   overlay the only cost sites are that same cap and the `ESS_VEC_DISABLE` kill
   switch. The join-gate planner's decline (`eval.rs:3342`) is the one genuine
   heuristic — and it is unreachable from the tape, because a node with a
   driving gate is refused before it (`lower.rs:1631`, `:2075`). **Ruling D6
   costs almost nothing here**: every cost-class landing path walks the tree per
   cell, so `native` refuses them regardless.

7. **Nothing OOMs.** Zero documents were killed or timed out; all 808 builds
   together take 2.5 s. The `isrm.esm` OOM recorded in earlier sweeps did not
   reproduce at build.

8. **Fallback reporting has almost no test surface to inherit.** No test calls
   `debug_build_tape_report`; `tests/tape_fallback_reporting.rs` is the only
   file asserting on `SolutionMetadata::tape_fallbacks`, with two tests.
