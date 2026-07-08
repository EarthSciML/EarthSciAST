---
title: "A semiring-parameterized FAQ IR for ESS arrayops"
description: "Concrete proposal to generalize the ESS arrayop node into a Functional-Aggregate-Query IR over semirings — unifying tensor contraction (ESM/ESD discretization), relational select-multiply-aggregate (ESI), and the data-dependent index-set construction (mesh topology) that currently must live in imperative grid code."
---

> **Status:** Draft proposal (concrete IR). **Bead:** unassigned.
> **Target repo:** EarthSciAST (`pkg/EarthSciAST.jl`, the
> `arrayop` IR and `tree_walk.jl` evaluator). Relocated here from
> EarthSciDiscretizations `docs/content/rfcs/`.

---

## 1. Summary

ESS already evaluates one specialization of a much broader declarative
operation. This RFC proposes generalizing the `arrayop` node from a
fixed **sum-product contraction over dense, name-matched index sets** into a
**Functional Aggregate Query (FAQ) node parameterized by a semiring**, with three
additive capabilities: data-dependent index sets, value-equality joins, and
content-addressed (Skolem) key construction.

Because the generalized node is no longer "an array operation" (its Boolean
specialization produces an *index set*, not an array), the concept is renamed
**`AggregateQuery`** — a semiring FAQ — with the serialized tag becoming
`"op": "aggregate"` and `"op": "arrayop"` retained as a **deprecated alias** so
existing files keep parsing (§5.6).

The payoff: a single IR whose specializations are (a) today's tensor/stencil
discretization (ESM/ESD), (b) relational select-multiply-aggregate
(EarthSciInventory's `aggregate(derive(join…))`), and (c) the mesh-topology
construction (edge enumeration, connectivity inversion) that **cannot** be
expressed as an einsum today and is therefore stranded in imperative grid code.
Every existing `arrayop` remains valid as the `sum_product` / dense / no-join
special case — the change is a conservative superset.

## 2. Motivation

Two findings from the ESD unstructured-grid work motivate this.

**(a) ESS's evaluator is already most of the way here.** The MPAS/DUO
nearest-neighbour diffusion rules rely on an ESD-side rewrite
(`_rewrite_unstructured_arrayop!`, `_unstructured_const_arrays`) that flattens a
variable-valence FVM coefficient into a precomputed `coeff` array. Inspection of
`tree_walk.jl` shows this rewrite is **redundant with ESS**: `build_evaluator`
already supports (i) **per-cell dynamic reduction bounds** — expression-valued
contracted ranges like `index(n_edges_on_cell, i) - 1`, expanded per output cell
via `_expand_int_range_dyn` — and (ii) **nested gather** — `index(A, index(B,i,k))`
into both state arrays and `const_arrays`, with arithmetic, resolved by
`_resolve_indices`/`_eval_const_int`. So the FVM coefficient could be evaluated
symbolically from primitive mesh arrays with no flattening at all. The IR, not the
evaluator, is the limiting factor: there is no way to *declare* the semiring, the
data-dependent index set, or the joins that a general unstructured operator needs.

**(b) The relational half already exists next door.** EarthSciInventory (ESI) is a
closed relational-algebra AST (`select, filter, map_dim, derive, join, aggregate,
union`) over categorical index sets, reusing ESM's scalar Expression AST for
per-row math. Its core motif — `Emission = Σ Activity × BaseRate × ∏ adjustments`
= `aggregate(derive(join…))` — is **the same formal object** as the FVM stencil
`Σ_k coeff·(u[nbr]−u[i])`: aggregate, in a semiring, a product of factors each
defined on a subset of the index variables. ESI is that operation over a
*categorical* index space; ESD's discretization is it over a *geometric* one. They
were built as separate formats meeting "at the emissions socket." From the IR's
view the socket is just a change of index space.

This RFC names the common parent and proposes ESS adopt it as the `arrayop` IR, so
ESM/ESD/ESI specialize one evaluator instead of three.

## 3. Background — what `arrayop` is today

The current node (as produced by `discretize.jl` and consumed by `tree_walk.jl`):

```json
{
  "op": "arrayop",
  "reduce": "+",
  "output_idx": ["i"],
  "ranges": { "i": [1, 64], "k": [1, 5] },
  "expr":  { "op": "*", "args": [ /* coeff */, /* operand */ ] },
  "args":  [ "..." ]
}
```

Semantics: for each output tuple in `output_idx`, reduce `expr` over the
*contracted* indices (range keys not in `output_idx`) using `reduce`. Contraction
is **positional**: indices combine by sharing a name. Supported reducers today are
`{+, *, max, min}`. Range bounds may be constants or scalar expressions
(`[1, index(valence, i)]`). Factors are state arrays and injected `const_arrays`
(coords, Fornberg weights, mesh metrics). This is a **dense, name-matched,
sum-product (and a few sibling) contraction** — i.e. einsum plus a handful of
reducers and an escape hatch for dynamic bounds.

## 4. The formalism

A **Functional Aggregate Query** computes, over an index space, an aggregate (in a
commutative semiring `(⊕, ⊗)`) of a product of *factors*, each a function of a
subset of the index variables:

```
out[free] = ⊕_{bound}  ⊗_f  factor_f(vars_f)
```

Specializations:

| Semiring `(⊕, ⊗)` | Factors | Index space | = |
|---|---|---|---|
| `(+, ×)` over ℝ | dense arrays | rectilinear/sparse grid | **einsum / ESD discretization** |
| `(+, ×)` / `(min,+)` / … over ℝ | keyed tables | categorical | **ESI inventory pipeline** |
| `(∨, ∧)` over 𝔹 | relations | tuples | **relational join / existence / dedup** |

The Boolean-semiring row is exactly what einsum lacks and what mesh-topology
construction needs (a join/dedup *is* a Boolean FAQ). The one operation outside
even FAQ is **value invention** — minting a fresh key for each distinct tuple
(numbering the discovered edge set). The declarative answer is a **Skolem
function**: name a thing by its content (`edge(min(u,v), max(u,v))`) rather than by
an allocated counter; ESI already does the bounded form of this with its
`composite` index sets and `pack` expression. Optional dense renumbering is then a
separate `rank` pass, not part of the logic.

## 5. Proposed IR

Generalize `arrayop` with **optional, additive** fields. Absence of every new
field reproduces today's semantics exactly.

```json
{
  "op": "aggregate",                  // canonical; "arrayop" still parses (deprecated alias, §5.6)
  "semiring": "sum_product",          // NEW: named (⊕, ⊗). Default = today.
  "output_idx": ["i"],
  "ranges": {
    "i": { "from": "cells" },          // NEW: index set by name (or [lo,hi] as today)
    "k": { "from": "edges_of_cell", "of": ["i"] }   // data-dependent / ragged
  },
  "join":  [ { "on": [["e", "edge_id"]] } ],   // NEW: value-equality across factors
  "reduce": "+",                        // retained; = semiring ⊕ when `semiring` absent
  "expr":  { "op": "*", "args": [ /* … */ ] },
  "args":  [ "..." ]
}
```

### 5.1 Semiring
A named `(⊕, ⊗)` pair. A semiring is fully specified by its two operators **and
their identity elements** `(0̄, 1̄)` — the latter are normative, not decorative:
they are the value an empty `⊕`-reduction returns and the value an empty
`⊗`-product returns, so every binding must agree on them or empty/degenerate
index sets diverge. (The current evaluator already encodes the `sum_product` row
implicitly: `_combine_with_reducer` returns `0.0` for an empty `+` and `1.0` for
an empty `*`.) The initial registry is closed and exhaustive — adding a semiring
is a spec change, not a per-file extension:

| `semiring` | ⊕ (`reduce`) | 0̄ (⊕-identity / empty reduce) | ⊗ | 1̄ (⊗-identity / empty product) | Value domain | Role |
|---|---|---|---|---|---|---|
| `sum_product` *(default)* | `+` | `0` | `×` | `1` | ℝ | today's einsum / ESD discretization |
| `max_product` | `max` | `-∞` | `×` | `1` | ℝ≥0 | best-path / saturation |
| `min_sum` *(tropical)* | `min` | `+∞` | `+` | `0` | ℝ∪{+∞} | shortest-path / cost |
| `max_sum` | `max` | `-∞` | `+` | `0` | ℝ∪{-∞} | longest-path |
| `bool_and_or` *(relational)* | `∨` (OR) | `false` | `∧` (AND) | `true` | 𝔹 | existence / join / `distinct` (§5.5) |

Notes that bindings MUST honor: (1) the `reduce` field names ⊕ only; the matching
⊗ and both identities come from this table, never from the file. (2) `±∞`
identities are represented per binding (`Inf`/`-Inf` in Julia, `f64::INFINITY` in
Rust, `np.inf` in Python) and are the *result* of an empty reduction — they are
never written into a file or a Skolem key (floats are forbidden in keys, §A.5).
(3) `bool_and_or` is the only semiring whose node may be **index-set-producing**
rather than array-producing (§5.5, §6); its ⊕/⊗ spelling is fixed as OR/AND here
to remove the ordering ambiguity. The
non-semiring statistical reducers ESI needs (`count`, `mean`, `weighted_mean`)
are **derived sugar**, not core: they desugar to a small fixed combination of
semiring-primitive FAQs (`count` = `sum_product` of `1`; `mean` = `sum / count`;
`weighted_mean` = `Σ wx / Σ w`) emitted by the front end before the IR is
evaluated. This keeps the evaluator's algebraic core closed under exactly the
semiring laws — the optimizer, type-checker, and partition pass (§6.1) reason
about a handful of true semirings, never a growing set of special-cased
reducers — while ESI still gets its statistics. `reduce` stays as a shorthand for
`⊕` when `semiring` is omitted, preserving existing files.

### 5.2 Index sets (`from`)
A range value may be a dense interval `[lo, hi]` (today), **or** a reference to a
declared index set. An index set is one of:
- a **dense interval** (grid axis) — ESM `domain.spatial`;
- a **categorical enumeration** — ESI `index_sets` (`county`, `fuelType`);
- a **data-derived set** — materialized from another FAQ (§5.5), e.g. the edge set
  discovered from the face→vertex relation.

`of: ["i"]` expresses a **ragged / dependent** inner set (the edges of cell `i`),
which the evaluator already handles via per-cell dynamic bounds. This single
mechanism unifies ESM grid dims and ESI categorical dims.

**Where index sets are declared.** A `{ "from": <name> }` reference resolves
against a single document-scoped registry, `index_sets`, that **unifies** today's
two separate declaration sites — ESM `domain.spatial` dims and ESI `index_sets` —
under one shape (both remain accepted as aliases for back-compat). Each entry is
one of the three kinds in the list above:

```json
"index_sets": {
  "cells":         { "kind": "interval",    "size": 64 },
  "county":        { "kind": "categorical", "members": ["..."] },
  "edges":         { "kind": "derived",     "from_faq": "<id of a §5.5 node>" },
  "edges_of_cell": { "kind": "ragged", "of": ["cells"],
                     "offsets": "n_edges_on_cell", "values": "edge_of_cell" }
}
```

A reference resolves by name to exactly one entry; the resolver MUST error on an
undeclared name (no implicit interval inference) so that a typo can't silently
become an empty set.

**How a ragged set binds to its backing array.** A `kind: "ragged"` set is the
named, first-class form of the per-cell dynamic bound the evaluator already
expands (`_expand_int_range_dyn`). It binds to **two keyed factors (§5.4)** drawn
from `args`/`const_arrays`: an `offsets`/length factor giving `|set(i)|` for each
parent tuple `i` (e.g. MPAS `nEdgesOnCell`), and a `values` factor giving the
member at `(i, k)` for `k ∈ 1…|set(i)|` (e.g. `edgesOnCell`). Iterating
`{from:"edges_of_cell", of:["i"]}` is therefore exactly the existing
`[1, index(n_edges_on_cell, i)]` dynamic bound plus a gather through the `values`
factor — no new evaluator path, only a name and a declared binding. CSR/offset
layout (`offsets[i]…offsets[i+1]`) is the canonical encoding; a fixed-valence
grid is the degenerate constant-`offsets` case.

### 5.3 Value-equality joins (`on`)
Today factors combine only by sharing an index *name* (positional). `join.on`
adds combination by **value equality of key columns**, subsuming ESI `join` and
making connectivity gathers first-class instead of nested-`index` tricks. A
positional einsum is the degenerate case (join on the shared index itself).

The relational semantics are fixed (not implementation-defined), because
multiplicity changes the aggregate's *value*, not just its performance:

- **Join kind: inner only.** `join.on` is an **inner equi-join**: a contributed
  product term exists only for index combinations whose key columns are equal on
  *every* listed pair. Rows with no match contribute **nothing** — which, under any
  semiring, is the additive identity `0̄` (§5.1), so a missing match adds zero to a
  `sum_product` aggregate and leaves a `min_sum` aggregate at `+∞`. There is no
  outer/left-join variant in v1; a "keep unmatched with a default" need is expressed
  explicitly with a `filter`/`ifelse`, not by a join mode.
- **Cardinality: many-to-many is defined, not an error.** If a key value occurs `m`
  times on the left and `n` times on the right, the join yields all `m·n` combined
  tuples, each contributing one `⊗`-product term to the enclosing `⊕`-reduction
  (standard relational-algebra / FAQ semantics). This is intentional — categorical
  disaggregation (ESI) relies on it — so it is **specified, not guarded against**. The
  one obligation it places on the author: the surrounding semiring's `⊕` must be the
  intended way to combine duplicates (it is, for the supported associative-commutative
  ⊕s — §A.5).
- **Key columns must be exact-equality types.** Join keys are integer IDs or
  categorical-member ids (strings compared by Unicode code point, §A.5);
  **floating-point join keys are forbidden**, for the same reason floats are
  forbidden in Skolem keys — equality is not portable across bindings. A spatial /
  inequality ("theta") join is explicitly **out of scope** for `join.on` (§8.1, §A.8
  treat it as a separate spatial-index operator).
- **Null / missing keys.** A key column that is absent or null on a row makes that
  row unmatchable: it joins to nothing and therefore contributes `0̄`. Nulls never
  compare equal (not even to each other). Emitting `null` into a key column is a
  front-end error, surfaced at build time, not silently dropped.

### 5.4 Keyed factors
Unify "const array", "state array", and "ESI table" as one concept: a **keyed
factor** mapping an index tuple to a value. `const_arrays` (mesh metrics, coords)
and ESI `tables` become the same kind of `arg`. No evaluator change for the dense
case; tables are factors keyed by categorical tuples.

### 5.5 Skolem keys and `distinct`
Two primitives close the value-invention gap:
- `{"op": "skolem", "args": ["edge", v_lo, v_hi]}` — a deterministic,
  content-addressed key. Generalizes ESI `pack`.
- `distinct: true` on an index-set-producing `arrayop` under the `bool_and_or`
  semiring — set semantics (dedup) materializing a **data-derived index set**.

Together: enumerate the unique edges (`distinct` Boolean FAQ over faces), name each
by a Skolem key, and expose the result as an index set that a geometric FAQ
(§5.2) consumes. An optional `{"op": "rank"}` assigns dense integers for the
array backend. **The order and numbering these primitives produce are fixed by the
normative determinism rules in §5.7** — they are part of the IR's semantics, not a
binding's discretion.

### 5.6 Node name (`op` tag) and concept name
"ArrayOp" describes only the dense sum-product specialization; the generalized
node also expresses categorical joins, dedup, Skolem key minting, and — in its
Boolean specialization — produces an *index set* rather than an array. The name is
therefore updated, with the **serialized tag** and the **concept name** treated as
two separate concerns:

- **Concept / type name:** `AggregateQuery` (documented as "a semiring FAQ"). Used
  in prose, schema titles, and any new evaluator type. `faq` is deliberately *not*
  used as an identifier — it reads as "frequently asked questions" to anyone who
  hasn't read the FAQ literature — though FAQ is cited as the formal pedigree.
- **Serialized `op` tag:** canonical value becomes `"aggregate"`, chosen because it
  is a readable word (matching this IR's node-tag convention — `index`, `skolem`,
  `rank` — not the terse expression-operator symbols `+`/`*`) and because it
  **reuses ESI's existing `aggregate` op**, so the cross-format unification is
  legible at the tag level (ESI's `aggregate(derive(join…))` collapses into one
  `aggregate` node).
- **`arrayop` as a deprecated alias:** the evaluator and schema continue to accept
  `"op": "arrayop"` as an exact synonym for `"op": "aggregate"`. Existing files are
  unaffected (preserving the §9 strict-superset promise); the alias is marked
  deprecated and files migrate on their own schedule. No deprecation window is
  forced — the alias may live indefinitely, since a serialization tag is an
  identifier, not a description.

### 5.7 Cross-binding determinism (normative)

The value-invention primitives of §5.5 (`distinct`, `skolem`, `rank`), the
arg-witness reducers (`argmin`/`argmax`, rule 6), and the
joins of §5.3 produce **index sets, dense IDs, and assignment buffers that other
nodes consume**, so
two bindings that disagree on their order or numbering produce *different models*,
not merely different formatting. Because `EarthSciAST` is parallel native
implementations (Julia, Rust, Python, …) verified by a conformance suite — not one
core behind FFI — this determinism is **normative spec, stated here**, not an
implementation detail deferred to an appendix. (Appendix A.5 keeps the per-language
*rationale* and the hash-randomization footguns; the rules below are the contract.)

**Governing principle.** Every emitted set, key, dense ID, and arg-witness index is
a **pure function of a defined total order over tuples**. No observable output may
depend on hash-table iteration order or a language-native hash value.

1. **Total order.** Lexicographic over tuple fields: integers by value; strings by
   Unicode code-point (UTF-8 byte) order, *not* locale collation. **Floats are
   forbidden in keys** (keep keys integer/categorical IDs); if a float is
   unavoidable it MUST be normalized (`-0.0`→`0.0`, NaN rejected) via the existing
   `canonicalize` float formatting before comparison.
2. **`distinct`** = sort by the total order, then drop adjacent duplicates. The
   output order **is** the sorted order — never first-seen / insertion order
   (non-portable: Rust `HashSet` is randomly seeded, Julia `Dict`/`Set` order is
   unspecified, Python `set` order is `PYTHONHASHSEED`-sensitive).
3. **`rank`** = dense IDs assigned by position in the sorted `distinct` sequence.
   The numbering **base is pinned in `CONFORMANCE_SPEC.md`** (Julia 1-based,
   Rust/Python 0-based); conformance asserts on the canonical numbering and each
   binding converts at its boundary.
4. **`skolem`** = a **canonical tuple**, not a hash: for a symmetric relation sort
   the components (undirected edge `(min(u,v), max(u,v))`), for a directed one
   preserve order. The dense ID then comes from `rank`. Hashing stays off the
   determinism-critical path entirely. (If a fixed-width fingerprint is ever truly
   required, it MUST be a seed-pinned portable hash — e.g. XXH3-64 seed 0 — over a
   canonical byte serialization, **never** a native `hash()`/`Base.hash`.)
5. **`join` / group-by aggregate.** Hashing may be used only to *bucket*; the
   emitted result MUST be sorted by the canonical key. The semiring `⊕` used to
   combine duplicates must be associative + commutative (all registry ⊕s are), so
   input and parallel order cannot change the result; for floating-point ⊕, do the
   final reduction sequentially in canonical order to avoid last-ULP drift.
6. **Arg-witness reducers (`argmin` / `argmax`).** A build-time reduction over a
   contracted candidate range that emits the **arg** — the witnessing index — not
   the reduced value: `assign[i] = argmin_g dist(point_i, gen_g)`, the
   nearest-generator INDEX (the SCVT assignment step). This is **net-new**: the
   closed semiring registry (§5.1) reduces to *values* and the value-invention
   primitives `distinct`/`skolem`/`rank` produce *sets* — neither yields the arg.
   The tie-break is **normative: the smallest arg (the smallest candidate id) wins**
   when two candidates have an equal reduced value (`<` selects for `argmin`, `>`
   for `argmax`; on an exact tie the smaller index). Like every rule here the
   output is a pure function of a total order — the tie comparison is explicit,
   never enumeration order — so the emitted integer buffer is byte-identical across
   bindings. The reduced value is an ordinary FAQ over the candidate factors (e.g.
   a squared-distance metric); a float value is permitted because it participates
   only in the *comparison*, never in a key, and identical IEEE arithmetic in the
   same operation order is bit-exact (use the squared metric, not `sqrt`, to keep
   ties exact). An empty candidate set is an error (no index witnesses an empty
   argmin). The buffer is a CONST/DISCRETE build-time materialization off the hot
   path (§6.1) — the Lloyd/SCVT outer loop re-invokes the build with updated
   generators; a state-dependent (continuous) arg-witness is rejected by guard 2,
   exactly like a continuous `distinct`.
7. **Grouped reduction over an arg-witness key (the SCVT centroid step).** A
   group-by aggregate (rule 5) MAY be keyed on an arg-witness assignment buffer
   (rule 6): the per-generator density-weighted centroid
   `num[g] = Σ_{p : assign[p]=g} ρ_p·x_p`, `den[g] = Σ_{p : assign[p]=g} ρ_p`,
   `centroid[g] = num[g]/den[g]`. The group KEY is the *value-dependent* `assign`
   buffer, not a loop index — so this is a value-equality group-by, and like every
   rule-5 reduction it MUST bucket by the canonical integer key and do the
   floating-point `⊕` sequentially in canonical value order (byte-reproducible);
   an empty group folds to the semiring's `0̄` (so an unattended generator has
   `den=0` and a NaN centroid the caller detects). Because the key is a build-time
   value-invention buffer, the whole step is materialized **off the hot path**
   through the value-invention front-door — the same CONST/DISCRETE point (§6.1)
   as the `assign` buffer it consumes — and is dropped from the ODE; the Lloyd/SCVT
   outer loop re-invokes the build. `num`/`den` (grouped) and `centroid`
   (elementwise `num/den`) are pure functions of the inputs and the rule-5/rule-6
   total orders, so they are byte/tolerance-identical across bindings. A grouped or
   derived buffer that reads live ODE `state` is rejected by guard 2 (its inputs
   must be CONST/DISCRETE), exactly like a continuous arg-witness.

Conformance (the suite must add this — it currently asserts only *semantic* graph
equivalence and tolerates "minor formatting differences"): feed identical mesh /
table inputs to all bindings and assert **byte-identical serialized index sets,
identical dense-ID arrays, identical arg-witness assignment buffers, and
identical grouped-reduction / centroid buffers**, including adversarial inputs
(duplicate edges, reversed orientation, permuted input order, equidistant ties)
to prove order-independence.

## 6. Evaluator changes

Most of this already exists; the deltas are bounded.

| Capability | Status in `tree_walk.jl` | Delta |
|---|---|---|
| Dynamic / ragged reduction bounds | **Present** (`_expand_int_range_dyn`) | none |
| Nested gather into arrays + const_arrays | **Present** (`_resolve_indices`, `_eval_const_int`) | none |
| Reducers `+, *, max, min` | **Present** (`_NK_CONTRACTION`) | parameterize by `semiring` |
| Transcendental ops in bodies (`acos`, `sqrt`, …) | **Present** (`_eval_node`) | none |
| Value-equality joins | absent | resolve `join.on` at build time → gather/merge |
| Named / data-derived index sets | partial (dense + dynamic bound) | index-set registry + materialization |
| Skolem keys / `distinct` / `rank` | absent | new resolve passes (build-time) |
| Node `op` tag | `arrayop` only | accept `aggregate` (canonical) + `arrayop` (deprecated alias) at dispatch |

Crucially, the existing model — **build-time unroll → compiled `_Node` tree, with
constants inlined as literals** — is preserved. Joins, Skolem keys, and
data-derived sets are all resolved at build time, producing the same compiled
artifact. Performance characteristics for existing rules are unchanged.

### 6.1 The dependency-partition pass (cadence classes)

Making value-invention and topology *first-class in the IR* (rather than a
hand-factored preprocessing stage) raises one fair objection: relational work over
a large mesh — enumerating edges, inverting connectivity, deduplicating with
`distinct` — must never run inside the per-timestep RHS. The resolution is a
**dependency-partition pass** that classifies every node by the *cadence* at which
its value can change and schedules each class into its own evaluation phase. It is
the direct analogue of ModelingToolkit's `structural_simplify`/observed-variable
elimination, generalized from two phases to three.

#### Cadence classes

Every value is determined at one of three cadences, forming a total order:

| Class | Changes | Evaluated | Phase | MTK analogue |
|---|---|---|---|---|
| `CONST` | never | once | folded into the artifact | true parameter / literal |
| `DISCRETE` | only at discrete events (piecewise-constant between them) | at setup + on each refresh event, memoized between | per-event handler | callback-updated parameter (`PresetTimeCallback`, `tstops`) |
| `CONTINUOUS` | every step | every RHS call | hot `_Node` tree | integrated state `u` |

`CONST ⊏ DISCRETE ⊏ CONTINUOUS`; the class of a node is the **maximum** (join)
over its inputs' classes. The boundary is derived by the compiler from the
data-dependency DAG, never declared by the author. Two points fix the semantics:

- **Named by cadence, not by role.** `CONTINUOUS` means "changes every step," not
  "the unknown we solve for." Its dominant inhabitant is the integrated state `u`,
  but an *explicit continuous-`t` forcing* (`sin(2πt)`, an analytic diurnal cycle)
  is also `CONTINUOUS` — it is not piecewise-constant between events and must be
  recomputed every step. Classifying by cadence rather than by "solved-for" keeps
  such forcings out of `DISCRETE`, where they would silently go stale between events.
- **There is no "grid" class.** With topology first-class (§5.5), the mesh is *not*
  a primitive input — it is `aggregate` nodes (`distinct`, `join`, `rank`) over the
  mesh primitive arrays. When those primitives are document literals the entire
  topology partition is `CONST` and folds into the artifact; when the mesh is
  reloaded or refined at discrete events (AMR, moving meshes) the same topology
  nodes are `DISCRETE` and re-run on the remesh event. "Grid" is a *consequence* of
  where its leaves sit, not a category of its own.

**Seeding the leaves — a new `discrete` variable kind.** A node's class is `max`
over its inputs, so the chain bottoms out at *declared* leaf cadences. Two of the
three already exist in ESM: state variables seed `CONTINUOUS`, and
parameters/literals seed `CONST`. But **`DISCRETE` has no existing role to derive
from** — nothing in the current schema expresses "shape fixed at setup, values
refreshed at discrete events," so the partition would be forced to mis-seed every
such input as `CONST` (wrong — it would never refresh) or `CONTINUOUS` (wrong — it
would recompute every step). v1 therefore **adds a new `discrete` variable kind to
the schema**, a third variable role beside state and parameter. A `discrete`
variable declares its **fixed shape** (the index sets / dims that *are* known ahead
of time) and, optionally, the **refresh trigger** that drives its per-event
recompute (a `tstops` schedule, a data-ingest event, an AMR remesh hook). Loaded
met/BC fields, emission inventories that update on a schedule, and reloadable mesh
topology are all declared `discrete`; the partition then seeds them `DISCRETE` and
the `max`-propagation does the rest. This is the **one genuinely new declaration**
the partition pass requires — the §6.1 design is otherwise derived, not declared.

The compile-fold-vs-setup-fold distinction, by contrast, is a **provenance
sub-tag**, not a declared class: a `CONST`/`DISCRETE` leaf whose bytes are inline in
the document folds at compile time; one loaded from an external resource (NetCDF
mesh/met, §A.8) folds at bind. Same algebra, same propagation.

#### Propagation

Walk the inter-node DAG bottom-up; `class(n) = max` over inputs. The DAG spans
**all** nodes — edges include expression child→parent, a node→an index set it
references (`ranges[*].from`), a `kind:"derived"` set→its `from_faq` node, and a
`join.on` factor→the factor it names. (This is why node addressing — referencing a
node by id — is a hard prerequisite: the pass cannot be built until `from_faq` and
join references are real edges in this DAG.)

One propagation rule carries the design. For a **gather** `index(A, e₁…eₖ)`, the
index expressions are classified *independently of the array*:

```
class(index(A, e…)) = max( class(A), class(e₁), …, class(eₖ) )
```

This is what lets a stencil split across phases: in
`index(u, index(edgesOnCell, i, k))` the inner neighbour-selection is `CONST`
(topology) while the outer value load is `CONTINUOUS` (it touches `u`).

#### The frontier cut (now at two thresholds)

The boundary is drawn *through* nodes, not around them: wherever a lower-cadence
child feeds a higher-cadence parent, the maximal lower-cadence sub-DAG below that
edge is a **materialization point** — evaluated in its phase, stored in a buffer,
and referenced by the parent. With three classes the cut fires at two thresholds:

- **`CONST → {DISCRETE, CONTINUOUS}`** — fold once into the artifact (the
  deduplicated edge set, `nbr_idx`, `coeff`, …).
- **`DISCRETE → CONTINUOUS`** — materialize into a buffer the hot path reads as a
  constant, recomputed by the per-event handler when the underlying data refreshes
  (met slices, reloaded BCs, a remeshed topology).

This generalizes the constant-fold `build_evaluator` already performs
(`_resolve_indices` inlining non-state gathers to literals) — applied once at the
`CONST` threshold and again at the `DISCRETE` one.

#### Three execution outputs

Instead of today's single compiled tree, the pass emits:

1. **Folded artifact** (`CONST`) — literals plus precomputed index/coefficient
   buffers baked in.
2. **Per-event handler** (`DISCRETE`) — recomputes its buffers on each
   refresh/remesh event; the relational engine (§A.5) and any reloaded-data folds
   run here, off the hot path. Empty when nothing is event-driven.
3. **Per-step `_Node` tree** (`CONTINUOUS`) — identical in shape to today's
   `build_evaluator` output for existing rules, with frontier references replaced by
   buffer loads. Performance for existing rules is therefore unchanged.

#### Why this needs no tearing, plus the guards

Each partition is **pure feed-forward** (topology → geometry → coeff;
loaded-data → derived fields), so the pass needs partial evaluation by cadence, not
MTK-style equation tearing. This is made a *checked* property:

- **Acyclicity.** The `≤ DISCRETE` subgraph must be a DAG; a cycle means an
  implicit/iterative solve, which is out of scope (use a `call` handler). Reject
  with a diagnostic naming the cycle.
- **No relational engine on the hot path.** A `distinct`/`join`/`skolem`/`rank`
  node that classifies `CONTINUOUS` is rejected — state-dependent topology may not
  run per step in v1. The guarantee is enforced, not hoped for.
- **Optional author assertion.** `expect_cadence: const|discrete|continuous` on a
  node is a test/diagnostic hook only; the pass errors if the derived class
  disagrees. It changes no semantics.

#### Worked trace — FVM diffusion

`out[i] = Σ_{k∈edges_of_cell(i)} coeff(i,k)·(u[nbr(i,k)] − u[i])`, mesh primitives
as document literals:

| Sub-DAG | Class | Fate |
|---|---|---|
| edge set / `nbr = index(edgesOnCell,i,k)` / ragged `offsets` | `CONST` | folded → `nbr_idx`, `offsets` literals |
| `coeff(i,k)` over coordinates | `CONST` | folded → `coeff` literal array |
| `u[nbr_idx[i,k]] − u[i]` | `CONTINUOUS` | hot `_Node` |
| `Σ_k coeff[i,k] ⊗ (…)` | `CONTINUOUS` (reduces continuous terms over a const-fixed range) | hot contraction (`_NK_CONTRACTION`) |

The hot tree's shape is identical to today's compiled stencil; the topology FAQ ran
once at compile. If instead the mesh is reloaded at AMR events, the first two rows
become `DISCRETE` and move from the artifact into the per-event handler — nothing
else changes. This is the concrete mechanism by which ESD drops
`_rewrite_unstructured_arrayop!` and its imperative edge/connectivity construction
(§2a, §9).

#### Conformance and caching

The partition is a compile-time classification, so conformance asserts it directly:
all bindings must agree on every node's class, the set of materialization points,
and the byte-identical `CONST`-folded buffers (ties to §5.7). Add three fixtures: a
mixed stencil (above), a pure-topology rule (all `CONST`/`DISCRETE`, empty hot
tree), and a pure-pointwise rule (all `CONTINUOUS`). `DISCRETE` buffers are keyed by
`(materialization-point id, event-epoch)`; v1 memoizes within a build and
recomputes a buffer only when its event fires. Incremental/shared rebuild of
materialized sets across events is the deferred `structural_simplify`-grade
refinement (§9).

The one net-new runtime surface remains the **setup/per-event relational engine**
(hash/sort for `distinct`/`join`/`skolem`/`rank`) that ESS lacks today (it does
only the numeric tree-walk + Tullio). It runs off the hot path but is real new
code — see §9 for the v1 scoping decision and **Appendix A** for the per-language
library choices (Julia stdlib, Rust `indexmap`, Python NumPy — all already
depended-on) and the cross-binding determinism spec the conformance suite requires.

## 7. Worked examples

### 7.1 Today's FVM diffusion (unchanged)
`semiring: sum_product` (default), `reduce: "+"`, ragged `k` bound. Identical to
the current `nn_diffusion_*` arrayop — and, per §2(a), the ESD coefficient flatten
becomes unnecessary because the gathered weight evaluates symbolically.

### 7.2 ESI-style `aggregate(derive(join…))`
```json
{ "op": "aggregate", "semiring": "sum_product",
  "output_idx": ["county", "pollutant"],
  "ranges": { "county": {"from": "county"}, "pollutant": {"from": "pollutant"},
              "src": {"from": "sourceType"}, "fuel": {"from": "fuelType"} },
  "join": [ {"on": [["src","sourceType"],["fuel","fuelType"]]} ],
  "reduce": "+",
  "expr": { "op": "*", "args": [ "activity", "base_rate", "temp_adj" ] },
  "args": [ "activity", "base_rate", "temp_adj" ] }
```
The MOVES running-exhaust contraction as one FAQ over categorical index sets —
ESI expressed in the ESS IR, no new evaluator concepts.

### 7.3 Mesh-edge enumeration (the operation einsum can't do)
```json
{ "op": "aggregate", "semiring": "bool_and_or", "distinct": true,
  "output_idx": ["edge"],
  "ranges": { "f": {"from": "faces"}, "a": {"from": "face_vertices", "of": ["f"]},
              "b": {"from": "face_vertices", "of": ["f"]} },
  "filter": { "op": "<", "args": ["a", "b"] },
  "key":    { "op": "skolem", "args": ["edge", "a", "b"] },
  "expr":   { "op": "true" }, "args": [ "faces" ] }
```
Produces the deduplicated edge index set, content-addressed by vertex pair. A
follow-on `rank` densifies it; `edges_of_cell` (§5.2) is the inversion join. The
geometric FAQ in §7.1 then consumes `edges` as a primitive index set — and the
DUO `area_eff = ¼Σ dc·dv` becomes an ordinary `sum_product` FAQ over it rather
than imperative Julia.

## 8. Schema deltas

Additive only (Draft 2020-12). On the `AggregateQuery` object (`op` ∈
`{"aggregate", "arrayop"}`, the latter a deprecated alias — §5.6):
- `op`: the `op` enum gains `"aggregate"` as the canonical value and **retains**
  `"arrayop"` as an accepted synonym; both resolve to the same node.
- `semiring`: `string` (enum of registered names). Optional; default `sum_product`.
- `ranges[*]`: allow `{ "from": string, "of"?: string[] }` **in addition to**
  the existing `[lo, hi]` tuple.
- `join`: optional array of `{ "on": [[string, string], …] }`.
- `distinct`: optional `boolean`.
- `key`: optional Expression (Skolem term) for index-set-producing nodes.
- `filter`: optional Expression predicate (already meaningful for ESI parity).

New Expression ops: `skolem` (variadic), `rank` (unary over an index set), `true`.
Index sets gain a registry entry mirroring ESM `domain` dims and ESI `index_sets`.

**New variable kind (`discrete`).** Beyond the `AggregateQuery` object, v1 adds a
third **variable role** to the model schema, beside state (`CONTINUOUS`) and
parameter (`CONST`): a `discrete` variable, whose **shape is fixed at setup** but
whose **values refresh at discrete events**. It is the declared seed for the
`DISCRETE` cadence class that the §6.1 partition pass schedules into a per-event
handler; without it the schema cannot express loaded met/BC fields, scheduled
inventories, or reloadable mesh topology, and the pass would be forced to mis-seed
them as `CONST` or `CONTINUOUS`. A `discrete` variable declares its dims / index
sets and an **optional refresh-trigger descriptor** (e.g. a `tstops` schedule, a
data-ingest event, or an AMR remesh hook); the trigger drives *when* its per-event
buffer is recomputed and is otherwise inert to the algebra. This is additive — a
file declaring no `discrete` variables validates and partitions exactly as today
(two cadences, §9 strict-superset promise).

**Concrete patch.** Against the current schema, where `arrayop` is an `op` enum
value on `$defs/ExpressionNode` (`additionalProperties: false`, so each new field
must be declared), the additive Draft-2020-12 changes are:

```jsonc
// $defs/ExpressionNode
{
  "properties": {
    // 1. op enum gains the canonical + value-invention tags ("arrayop" stays).
    "op": { "enum": [ /* …existing… */, "aggregate", "skolem", "rank", "true" ] },

    // 2. named semiring; absent ⇒ sum_product (today). Closed enum (§5.1).
    "semiring": {
      "type": "string",
      "enum": ["sum_product", "max_product", "min_sum", "max_sum", "bool_and_or"],
      "default": "sum_product"
    },

    // 3. ranges[*] becomes a union: existing [lo,hi]/[lo,step,hi] tuple,
    //    OR a reference to a declared index set (§5.2), optionally ragged.
    "ranges": {
      "additionalProperties": {
        "oneOf": [
          { "type": "array", "items": { "type": "integer" },
            "minItems": 2, "maxItems": 3 },                 // unchanged: today
          { "type": "object", "additionalProperties": false,
            "required": ["from"],
            "properties": {
              "from": { "type": "string" },                 // index_sets key
              "of":   { "type": "array", "items": { "type": "string" } }
            } }
        ]
      }
    },

    // 4. value-equality joins (§5.3): inner equi-join, key pairs [factorIdx, col].
    "join": {
      "type": "array",
      "items": { "type": "object", "additionalProperties": false,
        "required": ["on"],
        "properties": { "on": {
          "type": "array", "minItems": 1,
          "items": { "type": "array", "items": { "type": "string" },
                     "minItems": 2, "maxItems": 2 } } } }
    },

    // 5. value-invention + predicate fields (§5.5).
    "distinct": { "type": "boolean", "default": false },
    "key":      { "$ref": "#/$defs/Expression" },   // Skolem term
    "filter":   { "$ref": "#/$defs/Expression" }    // boolean predicate
  }
}
```

```jsonc
// NEW $defs/IndexSet + document-scoped registry (referenced from Model/Domain).
"IndexSet": {
  "type": "object", "required": ["kind"], "additionalProperties": false,
  "properties": {
    "kind": { "enum": ["interval", "categorical", "derived", "ragged"] },
    "size":    { "type": "integer" },                       // interval
    "members": { "type": "array" },                         // categorical
    "from_faq":{ "type": "string" },                        // derived (§5.5 node id)
    "of":      { "type": "array", "items": { "type": "string" } }, // ragged parents
    "offsets": { "type": "string" },                        // ragged: length/CSR factor
    "values":  { "type": "string" }                         // ragged: member factor
  },
  "allOf": [
    { "if": { "properties": { "kind": { "const": "interval" } } },
      "then": { "required": ["size"] } },
    { "if": { "properties": { "kind": { "const": "categorical" } } },
      "then": { "required": ["members"] } },
    { "if": { "properties": { "kind": { "const": "derived" } } },
      "then": { "required": ["from_faq"] } },
    { "if": { "properties": { "kind": { "const": "ragged" } } },
      "then": { "required": ["of", "offsets", "values"] } }
  ]
}
// on $defs/Model (and accepted as an alias of Domain.spatial / ESI index_sets):
"index_sets": { "type": "object", "additionalProperties": { "$ref": "#/$defs/IndexSet" } }
```

All of the above are additive: a file using none of the new keys validates
exactly as today (the §9 strict-superset promise). The conformance fixtures in
`tests/` gain a `valid/aggregate/` set (one fixture per worked example, §7) and an
`invalid/aggregate/` set (undeclared `from` name, float join key, `null` in a key
column, missing ragged `offsets`/`values`) so each rule above is exercised both
ways.

### 8.1 Required geometry op: `intersect_polygon` (leaf) + `polygon_area` (FAQ)

Conservative regridding's overlap-area factor `A_ij = area(cell_i ∩ cell_j)`
decomposes into a **kernel leaf** and an **in-formalism aggregate**, drawn at the same
boundary that makes `acos` a leaf but `Σ coeff·acos(…)` a FAQ:

- **`intersect_polygon` — required kernel-factor leaf.**
  `{"op": "intersect_polygon", "args": [poly_a, poly_b]}` returns the vertex ring of
  the geometric intersection `A ∩ B`. This is the part that genuinely *cannot* be
  expressed as a semiring aggregate: polygon clipping (Sutherland–Hodgman /
  great-circle overlay) is an iterative, control-flow-heavy transformation producing
  an ordered ring of **data-dependent length**, with robustness (exact predicates /
  snap-rounding) that lives in *how* the floating point is evaluated. The IR
  orchestrates it; the evaluator provides the implementation (the same status as
  `acos`/`sqrt`). It carries a `manifold` flag (planar / spherical / geodesic), and
  its cross-binding conformance is **tolerance-based**, not bit-for-bit. The
  `spherical` / `geodesic` manifolds model **every edge as a great-circle geodesic**
  — including a lon-lat edge along a parallel, which is a *small circle*, not a great
  circle — so a coarse polar cell carries an edge-model area error (≈4% for a 30°
  cell next to the pole, scaling with the square of the cell's longitude width); the
  optional `densify_parallel_edges` pre-clip step (Appendix B.4), off by default,
  drives it toward zero. This great-circle-edge assumption is part of the op contract
  (`esm-schema.json` `manifold` description).
- **`polygon_area` — an ordinary `sum_product` FAQ, not a new op.** The area of a
  vertex ring is `½ Σ_k (x_k·y_{k+1} − x_{k+1}·y_k)` (planar shoelace / Gauss–Green)
  or the spherical-excess sum `Σ angles − (n−2)π`, i.e. a `sum_product` aggregate over
  the ring index set — structurally identical to the DUO `area_eff` example (§7.3).
  It needs only the existing scalar leaf primitives (`acos`/`atan2`/`sqrt`) for the
  spherical case, no new op.

This split mirrors `GeometryOps.jl`'s own `intersection` / `area` separation, and it
**shrinks the opaque surface to the clip alone**. The payoff: because `polygon_area`
is an ordinary FAQ, the regridding weight's dependence on mesh **vertex coordinates is
differentiable and XLA-traceable in-formalism**. The clip's combinatorial structure is
piecewise-constant in the coordinates — it changes only at degenerate configurations —
so holding it fixed and differentiating the area FAQ is exactly the correct adjoint:
differentiable conservative-regridding weights w.r.t. geometry fall out of the existing
FAQ AD, with `intersect_polygon` as a non-differentiated structural leaf.

So the **required** new op is just `intersect_polygon`; `polygon_area` rides the
existing aggregate machinery. Per-language library choices for the leaf
(GeometryOps / spherely / a new Rust S2 binding) and the tolerance-based conformance
design are in **Appendix B**; why the clip cannot be pushed further into the
formalism, and the worked conservative-regridding decomposition, are in **Appendix A**
(§A.8).

## 9. Backward compatibility & migration

- **Strict superset.** Every current `arrayop` is the `sum_product` / dense /
  no-join / no-key case. Files without the new fields are unaffected; the schema
  changes are additive; the evaluator's existing paths are untouched.
- **v1 scope — all three capabilities, including topology.** v1 lands (1) the
  `semiring` parameter + index-set registry (pure refactor of existing reducers),
  (2) `join.on` resolution, **and** (3) `distinct` + `skolem` + `rank`
  value-invention — i.e. data-dependent index sets, value-equality joins, and
  topology construction all ship together. The static/dynamic partition (§6.1) is
  v1, not deferred: with topology first-class, a basic partition is *required* so
  topology FAQs fold into the static partition and never reach the hot path.
- **v1 topology engine.** v1 implements the build-time relational engine (hash/sort
  execution of `distinct`/`join`/`skolem`) so topology FAQs are evaluated natively
  by the setup-time partition. This makes the unified IR self-hosting on day one:
  ESD drops `_rewrite_unstructured_arrayop!` **and** the imperative
  edge/connectivity construction once v1 lands and rules reference mesh primitives
  directly (see §2a, §7.3). The later sophistication is
  *not* the engine but the **caching/incrementality** of materialized static sets
  (shared, incrementally-rebuilt index sets to bound setup cost on large meshes) —
  the `structural_simplify`-grade refinement of the §6.1 partition.
- **Node rename (alias, not a break):** the canonical tag becomes
  `"op": "aggregate"` (concept/type `AggregateQuery`), with `"op": "arrayop"`
  retained as a deprecated synonym at both the schema and evaluator-dispatch level
  (§5.6). Existing files need no edit; rule emitters switch to `"aggregate"` going
  forward. No deprecation window is forced.
- **Cross-format:** this is the concrete shape of the "future `earthsci-core`
  shared AST" ESI's spec anticipates — ESM/ESD/ESI would import one IR + one
  evaluator.

## 10. Non-goals, risks, open questions

- **Non-goal:** a query optimizer. FAQ admits worst-case-optimal join planning;
  this RFC proposes the *IR*, not a planner. Build-time unroll is retained.
- **Risk — build-time blowup (resolved by §6.1):** data-derived sets over large
  meshes unrolled eagerly could be slow to *compile*. This is now scoped to the
  **static partition only**, which runs once at setup (a `structural_simplify`-style
  one-time cost), never per step. Mitigation: materialize index sets eagerly and
  **cache** them (the static partition is precisely the memoizable unit); the later
  refinement is incremental/shared index sets, and a streaming
  (Finch/indexed-streams-style) backend remains a possible further step.
- **Risk — surface bikeshedding:** the JSON keys above are illustrative; the
  semantic generalization is the proposal, not the spelling.
- **Resolved — statistical aggregators:** `count`/`mean`/`weighted_mean` are **not**
  admitted as core reducers; they are **derived sugar** that desugars to
  semiring-primitive FAQs before evaluation (§5.1). The evaluator's algebraic core
  stays closed under exactly the semiring laws.
- **Resolved — where value-invention lives:** `distinct`/`skolem`/`rank` are
  **first-class in the IR**, not a separate hand-factored preprocessing stage. The
  hot-path concern that motivates a separate stage is instead handled by the
  compiler-derived **static/dynamic partition** (§6.1, the MTK observed-variable
  analogue), which keeps the per-step `f!` exactly as lean as a hand-factored stage
  would — generalizing a constant-fold ESS already performs — without forcing the
  author to draw the boundary.

## 11. References

- Abo Khamis, Ngo, Rudra. *FAQ: Questions Asked Frequently* (PODS 2016) — the
  semiring-FAQ framework that subsumes einsum and relational aggregation.
- Kovach et al. *Indexed Streams* (POPL 2023) — a fused IR for sparse contraction
  **and** relational joins.
- Finch.jl / TACO — structured/ragged-array compilers generalizing einsum to
  data-dependent index sets.
- Nested Relational Calculus / Datalog± (value invention, the chase) — the
  formal home of Skolem key construction.
- In-repo: `EarthSciAST/src/tree_walk.jl` (`build_evaluator`,
  `_resolve_indices`, `_expand_int_range_dyn`); ESS RFC
  `per-cell-metric-binding-eval` (per-cell metric binding); ESD
  `discretizations/finite_difference/nn_diffusion_{mpas,duo}.json` and
  `src/ode_problem.jl` (`_unstructured_*`, the machinery this would retire);
  EarthSciInventory `esi-spec.md` (the relational AST and `pack` Skolem precedent).

## 12. Appendices

The two appendices below are implementation studies supporting the specification
above: Appendix A covers the build-time relational engine (§§5.5, 6.1) and Appendix B
the `intersect_polygon` kernel (§8.1), across the Julia, Rust, and Python
implementations of `EarthSciAST`. They are grounded in inspection of the
`EarthSciAST`, `ConservativeRegridding.jl`, and `GeometryOps.jl` source.

> **Note on source-level claims.** The appendices cite specifics (dependency lists,
> file and symbol names, version numbers) from repositories outside this RFC's host
> repo. These are well-cited but secondary; spot-check them before treating them as
> authoritative.

---

## Appendix A — The build-time relational engine across ESS bindings

*Setup-time `distinct` / `join` / `skolem` / `rank` / group-by, the cross-binding
determinism spec, and the conservative-regridding case study.*

### A.1 What this engine is, and the constraint that shapes it

The unified IR makes mesh topology first-class: `distinct` (edge enumeration),
`join` (connectivity inversion), `skolem` (content-addressed keys), and `rank`
(dense renumbering) become declarable operations (§5.5). The static/dynamic
partition (§6.1) runs these **once at setup**, off the per-timestep hot path,
to materialize index sets that the numeric stencil then consumes. The engine needs
exactly five primitives over integer-keyed tuples (vertex/cell IDs, scale
10⁴–10⁷, one-time):

1. **`distinct`** — deduplicate tuples (unique mesh edges from face→vertex lists).
2. **`join`** — value-equality equi-join (connectivity inversion, *edges of cell i*).
3. **`skolem`** — deterministic content-addressed key from a tuple.
4. **`rank`** — dense integer renumbering of a distinct set (assign IDs to deduped tuples).
5. **group-by + semiring aggregate** (sum/min/max) over those sets.

**The decisive constraint comes from the ESS architecture.** `EarthSciAST` is
**not one core with FFI bindings** — it is *parallel native implementations* per
language (`EarthSciAST.jl`, `earthsci-ast-rs`, `earthsci_ast`
(Python), plus TS/Go), each conforming to a shared contract and verified by a
cross-binding conformance suite (`scripts/test-conformance.sh` against
`CONFORMANCE_SPEC.md`). Therefore the hard problem is **bit-for-bit determinism
across three independent implementations**: identical deduped sets, identical dense
IDs, identical skolem keys. That, not raw speed, governs every choice below.

### A.2 Recommendation in one line

**Do not adopt a heavy relational library or a shared embedded engine. In each
binding, hand-roll the five primitives on the data structure that language already
depends on, and enforce a single cross-binding *determinism spec* (canonical
sort-based ordering + canonical-tuple skolem keys).** The relational logic is
~100 lines per language; the value is in the spec, which no library provides for
free.

This also matches what the ESS codebase already does: the primitives exist
informally in two of the three bindings and only need to be unified and made
deterministic (§A.4).

### A.3 Why not a shared engine (DuckDB / Polars / Arrow)

A shared engine is the obvious "identical semantics for free" idea. It is rejected
here, for the reasons in the table.

| Engine | Julia | Python | Rust | Same core? | Weight | Verdict |
|---|---|---|---|---|---|---|
| **DuckDB** (1.5.2, 2026) | `DuckDB.jl` ✅ | `duckdb` ✅ | `duckdb-rs` ✅ | **Yes** (one C++ engine via C API) | Heavy: native `libduckdb` ~25–60 MB/platform | **Rejected** — only true 3-language same-core option, but contradicts the parallel-native architecture, adds a heavy native dep to all three packages, and *still requires* `ORDER BY`-everything discipline + conformance tests. Buys less than it appears. |
| **Polars** | `Polars.jl` ✗ (~30★, unmaintained since ~2023) | `polars` ✅ | `polars` crate ✅ | Shared Rust core in **2 of 3** | Medium–heavy | **Rejected** — no mature Julia binding; can't anchor 3-way conformance. (`maintain_order` has also had optimizer escapes.) |
| **Arrow / Acero** | `Arrow.jl` ✗ (format/IO only, no Acero) | `pyarrow` ✅ (Acero) | `arrow-rs` ✗ (uses DataFusion) | **No** (three different execution stacks) | Medium | **Rejected** — not uniform across the three. |

DuckDB remains worth keeping as a **throwaway oracle** during conformance-test
development (`SELECT DISTINCT … ORDER BY …`, `dense_rank() OVER (ORDER BY …)`) to
cross-check the hand-rolled output — but not as a shipped dependency.

### A.4 Per-binding recommendation (and what already exists)

Each binding should add a small `relational` module using the structure it
*already* depends on. The cross-binding agreement comes from §A.5, not the library.

#### Julia — stdlib `Dict`/`Set`/`sort` (+ `OrderedCollections`, already a dep)
`EarthSciAST.jl` (v0.6.0, Julia ≥1.10) deps are lean — `JSON3`,
`OrderedCollections`, `Tullio`, `Unitful`; **no DataFrames/DuckDB**. The evaluator
is two-phase: build-time `_compile` / `build_evaluator` and hot-path `_eval_node`;
the engine slots in as a build-time topology pre-pass beside `_compile`. **`src/graph.jl`
already hand-rolls distinct (`Set{String}`), joins (composite-key strings), and
group-by (`Dict` node-maps) — but with no `rank` and no ordering guarantees.** The
work is to formalize that and pin the order. `sort` is stable by default since
Julia 1.9. *Reject* DataFrames.jl (multi-second TTFX, "undefined" join/group order)
and DuckDB.jl (native binary) for production.

#### Rust — `indexmap` (already a dep) + canonical sort
`earthsci-ast-rs` (v0.6.0, edition 2024) already depends on
`indexmap = "2"`, `ndarray`, `smallvec`; **no polars/datafusion/arrow**. It already
encodes the exact discipline needed: `src/performance.rs` does sort-then-enumerate
for reproducible dense indices (**that is `rank`**), and `src/canonicalize.rs`
sorts args on a stable key and has `format_canonical_float` (**that is
`skolem`/`distinct`**). Add `src/relational.rs` using `IndexSet`/`IndexMap` (whose
iteration order is insertion order, *independent of the hasher*) and
`sort_unstable` on the full tuple. *Reject* `polars`/`datafusion`/`arrow` (heavy,
out of proportion) and never let a non-portable fast hasher (`ahash`,
`rustc-hash`/FxHash) drive emitted order or keys.

#### Python — NumPy (already a dep) `lexsort`/`unique`/`searchsorted`
`earthsci_ast` already hard-depends on NumPy/SciPy/xarray; **no
pandas/polars/duckdb/pyarrow**. The evaluator is a NumPy AST interpreter
(`numpy_interpreter.py`); spatial/mesh ops are contractually lowered at setup
(`UnreachableSpatialOperatorError`) — exactly this engine's slot. Relational code is
**greenfield** here. Build the five primitives on `np.unique(axis=0)` (lexicographically
sorted unique rows), `np.lexsort`, and `searchsorted`-based joins; reuse the
existing `canonicalize.py` total order. *Reject* pandas (dtype coercion, shifting
sort defaults) and bare `set`/`hash()` (PYTHONHASHSEED-sensitive).

### A.5 The cross-binding determinism spec (rationale for the normative §5.7)

> The contract itself is now **normative §5.7** in the main body. This appendix
> retains the per-language rationale, the hash-randomization footguns, and the
> conformance-suite detail that motivate each rule there.

The determinism contract is what makes the three implementations'
outputs byte-identical. **Governing principle: every emitted set
is a pure function of a defined total order over tuples; no observable output ever
depends on hash-table iteration order or a language-native hash value.**

1. **Total order.** Lexicographic over tuple fields, documented per type: integers
   by value; **strings by Unicode code-point (UTF-8 byte) order**, not locale
   collation; floats *forbidden in keys* (keep keys integer IDs) — if unavoidable,
   reuse `canonicalize`'s float formatting and reject NaN, normalize `-0.0`→`0.0`.
2. **`distinct`** = sort by the total order, drop adjacent duplicates. Output order
   is the sorted order — **never insertion / first-seen order** (not portable: Rust
   `HashSet` is randomly seeded, Julia `Dict` order is unspecified, Python `set`
   order is PYTHONHASHSEED-sensitive).
3. **`rank`** = dense IDs by position in the sorted distinct sequence. **Pin the
   base in `CONFORMANCE_SPEC.md`** (Julia is 1-based, Rust/Python 0-based): assert
   on the canonical numbering and convert at the binding boundary.
4. **`skolem`** = a **canonical tuple**, not a hash. For an undirected edge use
   `(min(u,v), max(u,v))`; generalize to "sort components for symmetric relations,
   preserve order for directed." The dense ID then comes from `rank`. This keeps
   hashing out of the determinism-critical path entirely.
   - *If* a fixed-width fingerprint is genuinely required, specify a **portable,
     seed-pinned, non-cryptographic hash** (XXH3-64, seed 0 — native impls in all
     three: `xxhash-rust`, `xxhash`, `XXhash.jl`; or BLAKE2/SHA via `hashlib`) over
     a **canonical byte serialization** (fixed field order, little-endian ints,
     UTF-8 strings, length-prefixed). **Never** a language-native `hash()` /
     `Base.hash` / `DefaultHasher`.
5. **`join` / group-by aggregate.** Use hashing only to *bucket*; **sort the
   emitted result by the canonical key**. Semiring combines must be associative +
   commutative (sum, min, max, count, boolean-or) so input/parallel order can't
   change results. Beware floating-point parallel reduction (last-ULP drift): keep
   exact/integer semirings, or do the final reduce sequentially in canonical order.

#### The randomization footguns this neutralizes
- **Rust:** `HashMap`/`HashSet` default to SipHash-1-3 with a per-instance random
  seed → "arbitrary" iteration order.
- **Python:** `hash()` of str/bytes is SipHash with per-process `PYTHONHASHSEED`.
- **Julia:** `Dict`/`Set` iteration order is an unspecified implementation detail;
  `Base.hash` is process-seeded and not cross-version/cross-language stable.

Each footgun affects *only* hash-table iteration order and runtime hash values.
Sorting the output and using content-defined keys makes every primitive a pure
function of its input multiset, immune to all three.

#### Conformance-suite additions
`CONFORMANCE_SPEC.md` currently asserts *semantic* equivalence for graphs and
tolerates "minor formatting differences"; the bit-for-bit guarantee for relational
index sets is **new spec to add**. Tests should feed identical mesh inputs to all
three implementations and assert **byte-identical serialized index sets and
identical dense-ID arrays**, including adversarial inputs: duplicate edges, reversed
edge orientation, and permuted input order (to prove order-independence).

### A.6 Reference API shape (canonical-sort convention)

Identical semantics in all three languages; only syntax differs. Hash structures
are used purely to bucket/dedup; the emitted order always comes from a sort on the
full tuple.

```
skolem_edge(a, b)      = (a <= b) ? (a, b) : (b, a)        # canonical tuple, no hash
distinct(tuples)       = sort(unique(tuples))               # total order, dedup
rank(distinct_sorted)  = { t -> i (+1 if 1-based) for i, t in enumerate(sorted) }
join(left, right, key) = bucket right by key; probe; emit sorted by canonical key
group_agg(rows, ⊕)     = bucket by group key; ⊕ within bucket; emit sorted by key
```

Concrete sketches per language (`indexmap::IndexSet` + `sort_unstable` in Rust;
`Set`+`sort!` in Julia; `np.unique(axis=0)`/`np.lexsort`/`searchsorted` in Python)
should live next to each binding's `relational` module.

### A.7 Net recommendation

- **Architecture:** parallel native implementations, mirroring the toolkit. No
  shared engine, no heavy DataFrame/SQL dependency.
- **Libraries (all already depended-on):** Julia stdlib `Dict`/`Set`/`sort`
  (+`OrderedCollections`); Rust `indexmap`; Python NumPy.
- **The real work:** write §A.5 into `CONFORMANCE_SPEC.md` and back it with
  adversarial cross-binding tests. The five primitives are small and stable; the
  determinism spec is the durable artifact.
- **Effort:** ~100 lines per binding plus the spec; in Rust and Julia much of it is
  consolidating patterns (`performance.rs`/`canonicalize.rs`, `graph.jl`) that
  already exist; Python is greenfield but NumPy covers it directly.

### A.8 Case study: conservative regridding (`ConservativeRegridding.jl` / `EarthSciData.jl`)

First-order conservative (area-weighted) regridding is a clean fourth specialization
of the IR — the same formal object as the FVM stencil and the ESI emissions
contraction, with the index space being *cell-overlap pairs between two grids*. The
mapping below is **verified against the `JuliaGeo/ConservativeRegridding.jl`
and `EarthSciML/EarthSciData.jl` source**, not just the abstract formula.

**The operation.** `F_target[j] = (1/A_j)·Σ_i A_ij·F_source[i]`, with
`A_ij = area(src_i ∩ tgt_j)` and `A_j = Σ_i A_ij`. In `ConservativeRegridding.jl`
this is a `Regridder` built once — a `SparseArrays` matrix of **raw overlap areas
`A_ij`** with row-sums stored as `dst_areas` — and applied by
`mul!(dst, intersections, src); dst ./= dst_areas`: a sparse matrix-vector product
plus a normalization divide. Build-once / apply-many is explicit in the API.

**FAQ decomposition (verified piece by piece):**

| Piece | `ConservativeRegridding.jl` reality | IR mapping | Partition |
|---|---|---|---|
| overlap pairs `{(i,j):A_ij>0}` | STR-tree dual depth-first search (`dual_depth_first_search`) — not O(n·m) | data-derived index set via a **spatial (theta) join**, executed by a spatial-index physical operator | static |
| `A_ij` | `GeometryOps.intersection` (Foster–Hormann planar / Sutherland–Hodgman spherical) + `GeometryOps.area`, `Manifold`-selectable | the **`intersect_polygon` kernel leaf** + **`polygon_area` FAQ** (§8.1) — mirroring the `intersection`/`area` split | static |
| `A_j = Σ_i A_ij` | sparse row-sums → `dst_areas` | **group-by-`j` `sum_product` FAQ** | static |
| apply `Σ_i A_ij·F_src[i]` | `LinearAlgebra.mul!(dst, intersections, src)` | **`sum_product` FAQ** over the overlap set (sparse mat-vec) | dynamic (if `F_src` is time-varying) |
| `/A_j` | `dst ./= dst_areas` (or folded into the matrix at build, `normalize=true`) | elementwise; foldable to build time | static fold or dynamic |

Four of the five pieces are native FAQs; the fifth — `A_ij` — splits into the
`intersect_polygon` kernel leaf and the `polygon_area` FAQ, which is exactly why §8.1
makes `intersect_polygon` a required op. The build-once/apply-many split the package
already enforces *is* the static/dynamic partition (§6.1).

**The two boundaries, confirmed by the source:**

1. **Spatial join ≠ equi-join.** The overlap set is built with an **STR-tree dual
   DFS** — a spatial-index-accelerated theta-join — confirming the IR's equi-only
   `join.on` does not cover it. The declarative form is either the
   bin-Skolem-equi-join idiom or a first-class spatial-join kind backed by an
   STR/R-tree physical operator (a planner concern). The IR expresses *that* there
   is an overlap join; the spatial index is the operator that executes it.
2. **The clip is an opaque kernel; the area is not.** `GeometryOps.jl` already
   separates `intersection` (the polygon clip) from `area`. The IR mirrors this:
   `intersect_polygon` is the kernel leaf (iterative clipping, robustness-critical,
   not expressible as a semiring aggregate), while `polygon_area` is an ordinary
   `sum_product` FAQ over the clipped ring (shoelace / Gauss–Green / spherical excess)
   — which makes the weight differentiable w.r.t. geometry in-formalism (§8.1).
   Only the clip's conformance is tolerance-based (floating-point), and it carries the
   planar-vs-spherical `Manifold` flag. Implementation options for the clipping leaf
   across the three bindings are the subject of **Appendix B**.

**`EarthSciData.jl` (verified):**
- **Non-staggered grids** use `ConservativeRegridding.jl` directly — the regridder is
  built once at `DataSetInterpolator` init and reused every step → the decomposition
  above.
- **Temporal interpolation** is a multilinear-in-time blend of cached slices
  (`DataSetInterpolator`/`TemporalCache`, temporal-first then spatial) → another
  `sum_product` FAQ (weighted sum of two time-slice factors). Its NetCDF loading /
  slice caching is data-source plumbing, **outside** the formalism (analogous to ESI
  table loading).
- **Staggered grids** use a separate `InterpolatingRegridder` (B-spline
  interpolation), *not* conservative regridding — a different operator. It is also a
  `sum_product` interpolation FAQ, but over a B-spline stencil with its own
  interpolation-weight factor rather than `intersect_polygon`. A second EarthSciData
  operator with its own kernel.

**Net:** conservative regridding's numeric core (overlap-area `sum_product` apply +
normalization group-by + temporal-interp blend) is native to the IR and inherits the
differentiability / XLA-tracing properties of any `sum_product` FAQ (the
apply is a sparse mat-vec / `segment_sum` over precomputed indices). Its two non-FAQ
pieces — the spatial-index join operator and the `intersect_polygon` geometry kernel
— are exactly what the IR *coordinates* rather than subsumes. ConservativeRegridding's
`Regridder` is, in effect, a hand-built materialization of this static partition;
emitting it as ESS IR would unify it with ESM/ESD/ESI under one evaluator.

### A.9 References

- ESS repo (`main`): `pkg/EarthSciAST.jl/{Project.toml,src/tree_walk.jl,src/graph.jl}`,
  `pkg/earthsci-ast-rs/{Cargo.toml,src/performance.rs,src/canonicalize.rs}`,
  `pkg/earthsci-ast-py/{pyproject.toml,src/earthsci_ast/numpy_interpreter.py,canonicalize.py}`,
  `CONFORMANCE_SPEC.md` — <https://github.com/EarthSciML/EarthSciAST>.
- Determinism: Rust `HashMap` SipHash randomization (`std::collections::HashMap`
  docs); PEP 456 (Python SipHash / hash randomization); `indexmap` hasher-independent
  order (docs.rs/indexmap); Julia `sort` stability (≥1.9).
- Cross-language hashing: xxHash / XXH3 (`xxhash-rust`, `xxhash` PyPI, `XXhash.jl`).
- Engines surveyed: DuckDB 1.5.2 (`DuckDB.jl`, `duckdb`, `duckdb-rs`); Polars
  (`polars` crate + PyPI; `Polars.jl` unmaintained); Apache Arrow / Acero
  (`pyarrow` only; `Arrow.jl` format-only; Rust DataFusion).
- Cross-references: §6.1 (static/dynamic partition), §9 (v1 topology engine).

---

## Appendix B — The `intersect_polygon` kernel across ESS bindings

*Per-language spherical polygon-clipping implementations and the tolerance-based
cross-binding conformance design.*

### B.1 Scope and the constraint that shapes it

Conservative regridding's overlap-area factor `A_ij = area(cell_i ∩ cell_j)` splits
(§8.1) into a **kernel leaf** — `intersect_polygon(a, b)`, which clips two cell
polygons and returns the intersection vertex ring — and an **in-formalism aggregate**,
`polygon_area`, an ordinary `sum_product` FAQ over that ring (shoelace / Gauss–Green /
spherical excess). **This appendix concerns the leaf**, `intersect_polygon`: the
iterative, robustness-critical polygon clipping that cannot be expressed as a semiring
aggregate and so must be an evaluator-provided primitive (the same status as
`acos`/`sqrt`). It runs at **setup time** to build the regridding weights.

Earth-science grids are on the **sphere** (lat-lon, cubed-sphere), so the kernel must
in general do **spherical** polygon clipping (great-circle / parallel-meridian edges);
treating lat-lon as a flat plane is wrong near the poles and the antimeridian.

**Geometry forces tolerance-based conformance.** The relational engine (Appendix A) is
made bit-for-bit identical across bindings by sorting integer tuples. This kernel
cannot be: it produces a **floating-point area from polygon clipping**, and FP
clipping is irreducibly implementation-dependent — intersection ordering, area
summation order, robust-predicate strategy, and snapping all differ between
implementations. Bit-for-bit identity across independent geometry implementations is
**unachievable**, and it is **not pursued**: each binding uses its language's best
native spherical-geometry stack, and cross-binding conformance is **tolerance-based**
(§B.5). This deliberately rules out chasing bit-identity through a single shared C++
core or through computing weights once and serializing them.

### B.2 Per-binding implementation

Each binding builds the clip with the best spherical-geometry tool available in its
ecosystem.

#### Julia — GeometryOps.jl
`GeometryOps.jl` (0.1.x line, JuliaGeo) does **native, non-approximate spherical**
polygon intersection + area: `Spherical()` manifold, `ConvexConvexSutherlandHodgman`
clipping, `area(Spherical(), …)` via Girard's theorem (`Planar()` and `Geodesic()`
also available). Pure Julia, no C++ binary. It is what `ConservativeRegridding.jl`
calls internally, so the Julia binding reuses the stack its ecosystem already trusts.

```julia
import GeometryOps as GO
using GeoInterface
function intersect_polygon(a, b)               # a, b :: spherical polygons (lon/lat)
    GO.intersection(GO.ConvexConvexSutherlandHodgman(GO.Spherical()), a, b;
                    target = GeoInterface.PolygonTrait())
end
```

#### Python — spherely
`spherely` provides vectorized NumPy bindings to **Google S2** via `s2geography`: true
spherical clipping and area with a shapely-style API.

```python
import spherely
def intersect_polygon(a, b):                   # a, b :: spherely geographies
    return spherely.intersection(a, b)
```

`spherely` is pre-1.0, so pin the version and track its releases; the underlying
`s2geography`/`s2geometry` C++ API is the stable surface beneath it.

#### Rust — a new S2 binding library (to be developed)
Rust has **no usable spherical polygon clipper today**: `geo`/`i_overlay` are planar;
`georust/geos` is planar (GEOS); the pure-Rust `s2` port has polygon boolean ops
unimplemented; `sphersgeo` is explicitly non-rigorous (§B.3). The recommendation is to
**develop a new Rust binding to the S2 C++ core** — FFI to `s2geography` /
`s2geometry`, the same engine `spherely` wraps — exposing `intersect_polygon` and the
spherical area. This is net-new work, justified because:

- it is the only route to a correct spherical clip in Rust;
- binding `s2geography` (a GEOS-like C++ API over S2) is the lowest-effort path, and it
  puts the Rust and Python bindings on the **same S2 core**, so those two agree closely
  by construction (GeometryOps in Julia is the looser-tolerance comparison — §B.5);
- it is reusable beyond ESS — the Rust geospatial ecosystem currently lacks exactly
  this, so the binding has standalone value.

```rust
// new crate (e.g. `s2geography-rs`): thin FFI over the s2geography C++ API
pub fn intersect_polygon(a: &S2Geog, b: &S2Geog) -> S2Geog { /* FFI: InitToIntersection */ }
```

### B.3 The library landscape (why Rust needs new work)

No existing library is both natively spherical *and* available across all three
languages — which is why Julia and Python have off-the-shelf choices while Rust
requires a new binding.

| Option | Julia | Python | Rust | Geometry | Role |
|---|---|---|---|---|---|
| **GeometryOps.jl** | ✅ native | — | — | Spherical (Girard) | **Julia choice** |
| **S2 (via s2geography)** | ✗ (JSoC proposal only) | ✅ `spherely` | ✗ → **new binding** | Spherical (exact) | **Python choice; Rust binding to be built** |
| GEOS | LibGEOS.jl | shapely | `georust/geos` | **Planar** | Not used (planar ⇒ wrong for the sphere) |
| `geo` / `i_overlay` | — | — | ✅ | **Planar** | Not used (planar; intersection planar-only) |
| pure-Rust `s2` port | — | — | ⚠ | Spherical | Unusable (polygon boolean ops unimplemented) |
| `sphersgeo` | — | — | ⚠ | Spherical | Unusable (explicitly non-rigorous) |

GEOS is the only engine with bindings in all three languages, but it is **planar** and
so is not used; the pure-Rust S2 port and `sphersgeo` are incomplete. Hence the plan:
**Julia → GeometryOps, Python → spherely, Rust → a new `s2geography` FFI binding.**

### B.4 Spherical vs planar — the accuracy axis

The clip must be done on the sphere, never on a flat lat-lon plane (poles and the
antimeridian break the plane). The established earth-science regridders confirm this
with two equivalent paradigms: **line-integral via Green/divergence theorem**
(SCRIP/Jones 1999; TempestRemap, with Gauss–Green) and **spherical polygon clipping +
spherical-triangle (excess) summation** (YAC/CDO; ESMF effectively). They agree at the
core (a triangle's spherical excess *is* the contour integral of its boundary).
GeometryOps and S2 both follow the second paradigm; ESMF/TempestRemap/YAC operate in
**3D Cartesian on the unit sphere**, which removes the pole singularity and antimeridian
seam.

**The dominant error source is the edge model, and it is a real design decision here.**
A lat-lon cell edge running along a parallel is a *small circle*, **not a great
circle** — but S2, GeometryOps, ESMF (`GREAT_CIRCLE`) and TempestRemap all treat every
edge as a geodesic. Per the GMD 2024 "Truly conserving…" analysis, assuming
great-circle edges for a 30° lat-lon cell adjacent to the pole gives a **~4% area
error** (≈17% at 60° width, ≈1% at 15°); the fractional error scales with the **square
of the cell's longitude width**, so it is severe only for coarse polar cells and
**2+ orders of magnitude smaller at typical few-degree climate resolution**. Only
**YAC** natively distinguishes great-circle vs latitude-parallel edges per grid; the
standard mitigation elsewhere (XIOS) is to **densify** a parallel edge into many short
great-circle segments. So the clip op's `manifold`/edge contract **states the
great-circle-edge assumption explicitly** (§8.1, `esm-schema.json`), and ESS **offers**
densification for coarse lat-lon grids where polar accuracy matters: the per-binding
kernels expose `densify_parallel_edges(ring, max_segment_deg)`, which subdivides each
parallel edge into great-circle segments at most `max_segment_deg` wide (vertices
inserted *on* the parallel). It is an opt-in pre-clip step, **off by default** so the
great-circle-edge behaviour is unchanged unless requested; densifying a 30° polar cell
to 1° segments cuts its area error from ≈3.6% to <0.01% (a fixture in the Julia and
Python geometry suites). Because GeometryOps (Julia) and S2 (Python,
Rust) both make the great-circle-edge assumption, the three bindings share the *same
geometric model* — their differences are floating-point, not modelling, which keeps the
§B.5 tolerances small.

### B.5 Conformance: tolerance-based, with a conservation invariant

Since exact cross-binding equality is unachievable (§B.1), the conformance suite for
the clip kernel (and the weights built from it) is **tolerance-based**:

1. **Combined relative + absolute tolerance per area:**
   `|a_x − a_ref| ≤ atol + rtol·a_ref`, with an **empirically calibrated** `rtol` and a
   real `atol ≈ 1e-15·R²` to absorb **slivers** — near-tangent overlaps where two
   clippers legitimately disagree on whether a tiny intersection even exists. Treat
   sub-`atol` areas as equal-to-zero ("present-but-tiny" and "absent" both pass); that
   regime is where snapping/tie-breaking diverges and it does not affect weights. Note
   the Python and Rust bindings share the **same S2 core** and will agree to a much
   tighter `rtol` than either agrees with Julia/GeometryOps; the spec tolerance must
   accommodate the loosest pair (a GeometryOps-vs-S2 comparison).
2. **The physically meaningful gate is conservation, not per-cell agreement.**
   Make the primary conformance test the invariants — global mass conservation
   `Σ_j A_j·F_target[j] = Σ_i A_i·F_source[i]` and partition-of-unity `Σ_i W_ij = 1` —
   to a tight tolerance; per-pair `A_ij` equality is secondary, since it is the
   unstable sliver regime. A subtlety the precedent surfaces: first-order
   conservation is exact *only if computed cell areas equal true areas*, which edge
   approximations violate; established tools restore exact conservation with a
   **post-hoc global-mean/area correction** rather than perfect geometry, and the
   residual shrinks with resolution. `ConservativeRegridding.jl` sidesteps the
   normalization half of this by dividing by `dst_areas = Σ_i A_ij` (the row-sum of
   *computed* overlap areas), not the true target-cell area — so `Σ_i W_ij = 1` holds
   **by construction** regardless of edge error. ESS should follow that
   construction; conservation tolerance is then application-set and
   resolution-dependent, not a fixed epsilon.
3. **Declare the manifold.** The geometry interpretation (`Planar` / `Spherical` /
   `Geodesic`) is part of the op's contract (matching `ConservativeRegridding.jl`'s
   `Manifold`); two bindings can only be compared under the same manifold.

### B.6 Recommendation

1. **Conformance is tolerance-based, not bit-for-bit.** Floating-point clipping cannot
   be made bit-identical across independent implementations; do not pursue a shared C++
   core or single-reference serialized weights to force it. Use the combined
   relative/absolute tolerance with a sliver floor, and gate primarily on the
   conservation / partition-of-unity invariants (§B.5).
2. **Julia → GeometryOps.jl** (`Spherical()` manifold; native spherical, the
   `ConservativeRegridding.jl` stack).
3. **Python → spherely** (S2 via `s2geography`; pin the pre-1.0 version).
4. **Rust → a new S2 binding library** (FFI to `s2geography`/`s2geometry`). No native
   Rust spherical clipper exists, the pure-Rust S2 port is incomplete, and binding the
   C++ S2 core also puts Rust on the same engine as Python — so this is both the only
   correct option and the one that tightens cross-binding agreement. Treat it as
   net-new work with standalone value to the Rust geospatial ecosystem.
5. **Op contract:** `intersect_polygon` carries a `manifold` flag; its conformance is
   declared tolerance-based (not bit-for-bit) in `CONFORMANCE_SPEC.md`, with the
   conservation / partition-of-unity invariants as the primary cross-binding tests.

### B.7 References

- Verified source: `JuliaGeo/ConservativeRegridding.jl` (GeometryOps-based,
  `Manifold`-selectable spherical/planar; STR-tree overlap; sparse `A_ij`),
  `JuliaGeo/GeometryOps.jl` (`Spherical()`/`Planar()`/`Geodesic()`, Girard area),
  `EarthSciML/EarthSciData.jl` (uses ConservativeRegridding for non-staggered grids).
- Julia: GeometryOps.jl <https://github.com/JuliaGeo/GeometryOps.jl> (native spherical
  clip + Girard area).
- Python: spherely (S2 via s2geography) <https://github.com/benbovy/spherely>;
  s2geography <https://github.com/paleolimbot/s2geography>; s2geometry
  <https://github.com/google/s2geometry>.
- Rust (current, all inadequate for the spherical clip): `geo` 0.33 / `i_overlay` 7.x
  (planar; geodesic *area* only); `georust/geos` (GEOS, planar); `s2` (yjh0502,
  pure-Rust port — polygon boolean ops unimplemented); `sphersgeo` (STScI, non-rigorous).
  The recommendation is a new FFI binding to s2geography.
- Spherical-regridding precedent: SCRIP/Jones 1999 (line integral, Lambert near
  poles); TempestRemap / Ullrich & Taylor 2015 (great-circle edges, Gauss–Green,
  overlap mesh) <https://github.com/ClimateGlobalChange/tempestremap>; ESMF
  (`GREAT_CIRCLE` vs `CART`, 3D-Cartesian) <https://earthsystemmodeling.org/regrid/>;
  YAC/Hanke et al. 2016 (search-and-clip, great-circle *and* latitude edges per grid);
  xESMF + sparselt (sparse-weight apply); "Truly conserving…" GMD 17:415 (2024) — edge
  model & 4–17% polar area error, post-hoc conservation correction; "Accurate and
  Robust Geometric Algorithms for Regridding on the Sphere" (EGUsphere 2026-636).
- Cross-references: §8.1 (the op); §A.8 (the case study).
