# Review — RFC: First-class sampled function tables (esm-jcj)

**Reviewer:** polecat `guzzle` (no prior authorship of this proposal)
**Bead:** esm-jcj
**Companion RFC under separate review:** esm-ylm (in-file AST templates)
**Spec baseline:** `esm-spec.md` v0.3.0 (`interp.linear` / `interp.bilinear` already
in §9.2; `call`-op extension point already removed by `closed-function-registry.md`)
**Date:** 2026-04-28
**Scope:** review the `tables` block proposal end-to-end against the v0.3.0 spec
surface; flag design-level issues, propose a minimal op set, and pin acceptance
criteria.

---

## Summary

The motivating evidence is sound: 18 photolysis variables in
`components/gaschem/fastjx.esm` each inline a 61×23 flux slab plus the same
two axes, totaling on the order of 28 k floats × 18 ≈ 0.5 M floats of
literally-duplicated data per file. Lifting the data once and referencing it
by name is the right move. The RFC correctly frames this as the *data*
analogue of the templates RFC and correctly distinguishes itself from
dsc-acj's "no per-language hidden runtime" line — `tables` lifts JSON
literals, not behavior.

**Verdict:** Approve direction. Reject the proposed five-op surface
(`table_ref`, `axis_ref`, `table_slice`, plus implicit per-axis ops) — collapse
to a single `lookup` op (or just `table_ref` whose load-time semantics include
slicing). Three normative gaps must be closed before schema work begins:

1. **Lowering contract.** `interp.linear` / `interp.bilinear` currently require
   `table` and `axis` arguments to be `const`-op nodes (§9.2, error codes
   `interp_table_not_const` / `interp_axis_not_const`). The RFC must say
   either (a) `table_ref` lowers to `const` at load time and the "literal
   const-array source" predicate is widened to admit it, or (b) the §9.2
   load-time error codes are renamed and the predicate documented. Without
   this, every fastjx use site fails schema-time validation.
2. **Storage redundancy.** The example carries both nested `data: [[[...]]]`
   and `shape: [61, 23, 18]`. One must be canonical; the other is at most an
   assertion the loader checks. Pick nested-array canonical (matches existing
   `const`-op convention) and treat `shape` as redundant assertion only.
3. **Axis identity, not just axis name.** A binding-side cache keyed on
   `(table_name, axis_name)` is correct only if axis identity is structural
   (same `values` array ⇒ same axis). The RFC needs a normative rule for
   when two `axes` declarations are *the same axis* — by-name within a single
   `tables` block, or content-hash. Otherwise the "axes declared once,
   reusable across tables" claim leaks into binding-defined behavior.

The migration target (fastjx 1.2 MB → <500 KB) is achievable; the
acceptance criteria as written do not exercise the cross-binding numeric
contract beyond Julia + Python and should be tightened to all five bindings
that already implement `interp.linear`/`interp.bilinear`.

---

## Per-section verdict

### Problem framing — **Accept**

The 198-of-245-variables / 18-redundant-axes count is what motivates *first-
class* tables rather than a CPP-style include. dsc-acj's "self-describing in
isolation" property is preserved at the use site (the `interp.bilinear` fn
node still appears beside the variable; only the bulk-data argument is named
rather than inlined). The boundary between this RFC and esm-ylm
(operations vs. data) is drawn cleanly enough that someone landing one in
absence of the other still gets a coherent file.

One framing nit: the description says "the operation that reads a table
(`interp.linear`, `interp.bilinear`, future `interp.trilinear`) stays
inlined per variable — only the data is lifted." `interp.trilinear` is not
in the v0.3.0 closed function set. Mentioning it as an aside is fine, but
the RFC should not depend on it; if `tables` lands in v0.4.0 and trilinear
arrives later, the RFC's value proposition (cutting fastjx from 1.2 MB) is
already realized via existing 2-D blends.

### Constraints (1–5) — **Accept with one tightening**

Constraints (1)–(4) are correct: in-file, named-and-immutable, axes
first-class, parse-time shape validation, no computed tables.

Constraint (5) "Existing inlined `const` arrays continue to work" is the
right backward-compat stance, but the RFC should add an explicit
non-promotion clause: **`tables` is opt-in; loaders MUST NOT silently
hoist inline `const` arrays into the `tables` block during round-trip.**
A lossy canonicalization here would surprise the editor (earthsci-ast-editor) and
the existing fixture corpus. See "Round-tripping" below.

### Op surface — **Reject as written, propose smaller alternative**

The proposal sketch introduces three new ops:

| Op | Sketch role |
|---|---|
| `table_ref` | Reference a whole table |
| `axis_ref` | Reference a named axis of a table |
| `table_slice` | Slice a sub-array along a named axis at a literal index |

This is too many primitives for the actual demand. Recommend collapsing to
**one op**, `table_ref`, with optional `axis` and `index` fields that
together specify "the array I want". The `axis_ref` case is just
`table_ref` returning the axis array; `table_slice` is `table_ref` with
`axis` + literal `index` set. Concretely:

```jsonc
// Equivalent to the sketch's table_ref(Z_all):
{ "op": "table_ref", "table": "Z_all" }

// Equivalent to axis_ref(Z_all, "P"):
{ "op": "table_ref", "table": "Z_all", "axis": "P" }

// Equivalent to table_slice(Z_all, "lambda_idx", 1):
{ "op": "table_ref", "table": "Z_all", "axis": "lambda_idx", "index": 1 }
```

Rationale:

- **Conformance cost is per-op, not per-form.** Each new `op` enum value
  costs five binding implementations plus fixture coverage. One op with two
  optional fields is one entry in the §4 table and one set of fixtures
  exercising the three forms.
- **Lowering is uniform.** All three forms lower at load time to a literal
  rectangular slice of the table's `data` array. The loader needs one code
  path: resolve `table` → array; if `axis`+`index` set, slice along that
  axis at that integer index; if only `axis` set, return the axis values
  array; otherwise return the whole `data` array.
- **The op stays opaque to symbolic layers.** This is the same trick
  `interp.linear` uses (`@register_symbolic` to avoid alias-elimination
  blowup). One op = one `@register_symbolic` registration.

If the WG finds three names more *readable* at use sites, keep the
distinction in the doc generator (render `table_ref` with `axis` set as
"axis P of Z_all" and so on) without splitting the schema. The schema
optimizes for binding cost; the doc generator optimizes for human reading.

### Lowering contract vs. existing `interp.*` — **Critical, must fix**

§9.2's `interp.linear` and `interp.bilinear` entries explicitly require
`table` and `axis` to be `const`-op arrays:

> `table` and the axis array(s) MUST be `const`-op arrays of finite floats.
> Loaders MUST resolve their nested shapes at load time. ... Bindings MUST
> reject violations at file-load time with the diagnostic codes listed
> under "Errors" below. Loading MUST fail.

> `interp_table_not_const` / `interp_axis_not_const`: The `table` or any
> axis argument is not a literal `const`-op array (e.g. it is a variable
> reference or a non-`const` expression).

If `tables` lands as drafted, every fastjx variable like

```jsonc
"F_1": { "expression": { "op": "fn", "name": "interp.bilinear",
  "args": [
    { "op": "table_ref", "table": "Z_all", "axis": "lambda_idx", "index": 1 },
    { "op": "table_ref", "table": "Z_all", "axis": "P" },
    ...
  ] } }
```

fails the `interp_table_not_const` / `interp_axis_not_const` check, because
`table_ref` is a node, not a `const`. Two clean fixes:

**Option A (preferred): widen the predicate, not the diagnostic.** Replace
"MUST be a `const`-op array" with "MUST resolve at load time to a literal
finite-float array of the required shape". The error codes stay, and the
predicate body lists the admissible source ops: `const`, and `table_ref`
when the referenced table contains literal data. Both spec text in §9.2 and
schema `if/then` rules around the `interp.*` invocations need editing in
lockstep with this RFC.

**Option B: fold tables into the `const`-op evaluator.** Treat `table_ref`
purely as load-time syntactic sugar that the loader rewrites into the
equivalent `const` node before validation runs. This keeps §9.2 unchanged
but makes the stored AST identical to the inline-const form — which then
defeats the in-memory deduplication claim ("Avoid copying"). Reject.

Option A is the right path. The RFC must include the §9.2 spec edits in its
"Implementation impact" list; right now it lists only "add table_ref ... ops
to ExpressionNode `op` enum", which is half the work.

### Axis identity — **Critical, must specify**

The RFC says axes are "declared once, reusable across tables. A table either
references shared axes by name or carries its own." The example sketches
this:

```jsonc
"Z_all": {
  "axes": [
    { "name": "P", ... },
    { "name": "cos_sza", ... },
    { "name": "lambda_idx", ... }
  ],
  ...
},
"P_axis": {
  "axes": [{ "name": "index", ... }],
  "data": [...]
}
```

But this leaves underspecified:

1. Do `Z_all`'s `P` axis and a hypothetical separate top-level axis named
   `P_axis` denote the same axis? (Answer should be: no, distinct.) The
   shared-axis claim collapses to "axes are inline within each table" which
   is fine for v1.
2. If two tables both declare `axes: [{name: "P", values: [...]}]` with
   identical `values`, are bindings allowed to share the underlying array?
   This matters for memory in fastjx (shared `P` axis across photolysis
   tables).

Recommend the v1 rule: **axes are scoped to their declaring table; cross-
table sharing is by content equality** (loader MAY deduplicate when two
axes have the same `values` array, MUST NOT when they differ). Defer named-
top-level-axes (a separate top-level `axes` block) to v2 if the deduplica-
tion rule proves insufficient. Open question 4 in the RFC asks this — pin
the answer.

### Storage layout (`data` vs. `shape`) — **Pin one canonical form**

The example carries both nested `data` and `shape: [61, 23, 18]`. Inline
`const` already uses nested arrays as canonical, with shape implicit in the
nesting. Pin the same convention: **`data` is the canonical, nested
representation. `shape`, if present, is a redundant assertion the loader
verifies; it MUST NOT diverge from the actual nesting.** This matches the
existing v0.3.0 schema's `const`-op handling and avoids any "is this row-
major or column-major" ambiguity (open question 2).

If at some point a flat-plus-shape representation is wanted for very large
tables (because nested-array JSON parsing is O(n) but emits more
intermediate objects), file a follow-up RFC; do not do both at once.

### Axis units checking (open question 3) — **Defer to v2**

Yes, axes should carry `units`. No, the v1 spec MUST NOT make
`interp.bilinear` validate that its scalar `x` argument's units match
`axis_x.units`. The §4 AST has no unit system. Adding one through the back
door of `interp.*` validation creates an asymmetry where unit-checking
exists for `tables`-fed lookups but not for inline-const-fed lookups. v1
records `units` as advisory metadata for the doc generator; a future
RFC can promote this to load-time validation if a units RFC lands first.

### Round-tripping (open question 5) — **Preserve, do not canonicalize**

The editor (`earthsci-ast-editor`), the Go round-trip implementation
(`pkg/earthsci-ast-go`), and the existing `tests/` corpus all expect
that loading and re-saving a file yields the same JSON modulo whitespace.
Auto-promoting inline `const` arrays into a `tables` block during save
would break dozens of fixtures and surprise human authors. **Tables are
opt-in. The format preserves what the author wrote.** The migration of
fastjx from inline-const → tables is a one-time author-driven refactor,
recorded as its own bead, not a load-time rewrite.

### Doc generator concerns — **Tighten**

The RFC's "render tables compactly (shape + axes + sparkline of one slice,
not the full data dump)" is the right spirit but underspecified. Concretely
the doc generator should render:

- A table header: `Z_all  shape: [61, 23, 18]  ≈ 28k entries`
- Axes block: name, units, length, range (`P: 1.0 .. 10000.0 Pa, 61 pts,
  log-spaced`).
- A single representative slice (e.g. `data[:][:][0]` for the first
  λ-index) rendered as a heatmap or as a 5×5 corner-and-center sample.
- A back-reference list: which variables reference this table (computed
  by walking expressions for `table_ref` nodes pointing at this name).

The back-reference list is the doc-generator analogue of "self-describing
at the use site": from the table page, a reader sees every consumer.

### Acceptance criteria — **Tighten to all five bindings**

The RFC states acceptance as:

> Julia + Python evaluators load fastjx with tables and produce numerically
> identical j-rates to current inline-const form (mdl-09u soak test passes).

`interp.linear` and `interp.bilinear` are already required to be
implemented in all five bindings (Julia, Python, Rust, Go, TypeScript) per
§9.2. Tightening:

> All five bindings MUST load `tests/conformance/tables/` fixtures and
> produce results bit-equivalent to the inline-const form per the §9.2
> tolerance contract (`abs: 0, rel: 0` on non-FMA paths, `abs: 0, rel:
> 4e-16` on mixed-FMA cross-binding). The fastjx component (mdl-09u) is the
> integration test, not the conformance gate.

This avoids the trap where Go or TS skip the migration "because no one
runs fastjx in those bindings yet" and the file becomes a
Julia/Python-only artifact.

---

## Open question dispositions

| RFC OQ | Disposition |
|---|---|
| 1. Op naming: too many ops? | **Yes**, collapse to one `table_ref` op with optional `axis` + `index`. See "Op surface" above. |
| 2. Data layout: row-major / column-major / shape-tagged? | **Nested-array canonical, shape advisory.** Matches inline `const`. |
| 3. Axis units: enforced or advisory? | **Advisory in v1.** Promote to enforcement only after a units RFC lands. |
| 4. Shared-axes scope: per-table or hoisted? | **Per-table in v1, dedup by content-equality.** Defer top-level `axes` block to v2. |
| 5. Round-tripping: preserve inline-const or canonicalize? | **Preserve.** Tables are opt-in; the loader does not rewrite inline `const`. |

---

## Items added to "Implementation impact" that the RFC misses

The RFC's impact list covers schema and bindings but misses a few:

- **§9.2 spec edits.** Widen the "MUST be a `const`-op array" predicate on
  `interp.linear` / `interp.bilinear` to admit `table_ref` nodes that
  resolve to literal data at load. Update the `interp_table_not_const` /
  `interp_axis_not_const` diagnostic descriptions accordingly. (Not
  optional — without this, the migration target file fails validation.)
- **Schema if/then rules.** The current schema enforces the `const`-op
  predicate via JSON-schema conditionals around `op: fn`. These need
  updating in lockstep with §9.2.
- **Conformance fixtures.** A new `tests/conformance/tables/` directory
  with at least: (a) round-trip fixtures (load+save preserves the file),
  (b) shape-mismatch rejection fixtures, (c) cross-binding numeric
  fixtures replicating a small fastjx-style 2-D lookup with both inline
  and table-referenced inputs, asserted bit-equivalent.
- **`earthsci-ast-editor` UI.** The editor today renders `const` arrays inline;
  it needs a tables panel. Not blocking spec acceptance, but should be
  tracked as a follow-up bead.
- **Schema version bump.** `tables` is a new top-level block + new op =
  minor version bump (v0.4.0 territory). Files declaring `esm: "0.3.0"`
  MUST NOT carry `tables`; loaders pinned to v0.3.0 reject. The migration
  bead for fastjx must change the file's `esm` version too.

---

## Composition with esm-ylm (templates RFC)

The RFC notes that templates and tables compose: a template like
`actinic_flux(lambda_idx)` (templates RFC) expands to an
`interp.bilinear(table_ref(Z_all, axis=lambda_idx, index=$param), ...)`
node (this RFC). Two coordination items:

1. **Order of evaluation.** Template expansion happens before fn-arg
   `const`-op validation (templates produce concrete AST). After
   expansion, every `table_ref` site is fully literal — `index` is a
   resolved integer, not a template parameter — so the load-time
   predicate widening (Option A above) is sufficient. No ordering
   surprises.
2. **Self-description.** When the doc generator renders a templated
   variable, it should show the post-expansion form, not the templated
   form, so that the `table_ref` back-reference list is complete. This is
   a templates-RFC concern but worth flagging in both reviews.

Neither RFC blocks the other for landing. They share fixtures
(`tests/conformance/tables/` + `tests/conformance/templates/`) but have
independent op surfaces.

---

## Acceptance gate (what "v1 ships" means)

Before the schema PR for `tables` lands, the spec PR must:

1. Add §2 top-level `tables` field with the per-table object schema (axes,
   data; optional shape assertion).
2. Add §4 `table_ref` op entry with the three forms (whole table, axis,
   slice) collapsed under one op as proposed.
3. Edit §9.2 `interp.linear` / `interp.bilinear` to admit `table_ref` as a
   "literal source" alongside `const`. Update error code descriptions.
4. Add a §9.2 cross-reference at the §4 `table_ref` entry pointing to
   "valid arguments to `interp.*` lookups".
5. Pin the round-trip rule: tables are opt-in; loaders MUST NOT auto-
   promote inline `const` to a `tables` entry on save.
6. Land at least three conformance fixtures under
   `tests/conformance/tables/` exercising load, shape-mismatch rejection,
   and the bilinear-via-table-slice case.

The fastjx migration (mdl-09u or its successor) is then a one-shot bead
that consumes v1 and demonstrates the >50% size reduction.

---

## What to reject in v1

- Computed tables (`data` is a `const`-equivalent literal, not an
  expression).
- Cross-file imports (no `ref:` field on a table).
- External storage backends (HDF5/NetCDF/Zarr).
- Top-level shared-axes block (per-table axes only; defer hoisting).
- Tables in `data_loaders` (use `data_loaders` for runtime gridded data;
  use `tables` for inline literals only — the boundary should be in the
  spec text).
- `interp.trilinear` (separate closed-function-registry RFC; do not bundle).

These are explicit non-goals in the RFC body and should remain so.

---

## Closing note on the closed-set principle

`tables` does not violate §9.1's closed-set principle. The closed set is a
*function* registry — it constrains what callables an `.esm` may invoke,
and the rationale (cross-binding bit-equivalence) is about behavioral
parity. `tables` adds *data*, not behavior. The behavior path runs through
existing `interp.linear` / `interp.bilinear` entries whose semantics are
already pinned. If anything, `tables` strengthens the invariant: today,
the same numerical content is inlined 18× with no schema-level guarantee
the copies agree (a typo in any single copy is silent); under `tables`,
there is one source of truth and 18 references, so cross-use-site numeric
equivalence becomes a structural property rather than a discipline.

The closed-set discipline applies only when someone proposes a *new* op
whose body could have been written in AST. `table_ref` is not such an op
— there is no AST form for "bulk-data reference". It belongs in §4
because it is a data primitive, not a function call.
