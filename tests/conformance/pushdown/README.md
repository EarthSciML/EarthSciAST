# Pushdown-rewrite conformance fixtures

Golden documents for the automatic projection-pushdown desugar
(`desugar_pushdown` — Julia `pkg/EarthSciAST.jl/src/pushdown_rewrite.jl`,
Python `earthsci_ast/pushdown_rewrite.py`). Every binding that implements the
rewrite must produce, from the same input document, a rewritten document that
is **deep-equal as parsed JSON** to the committed golden.

## Fixtures

- `fixtures/pushdown_l1.esm` — the 9-cell isrm-shaped L1 document (the exact
  document `pkg/EarthSciAST.jl/test/prepare_pushdown_record_gate_test.jl`
  builds: data_loaders + `variable_map` coupling + a clean model with in-model
  LCC projection observeds, frozen numerics).
- `fixtures/pushdown_gated_dense.esm` — the MINIMAL forward document (one SR
  array, one binning `E[c]`, one `conc[rcv]`). Its golden is the readable
  reference for the `join.overlap` clause the rewrite attaches to the
  **rewritten binning aggregate**: `src_env` the record point coordinates,
  `tgt_env` the generated `pd_cell__*` gathers — the envelopes on the COMPACT
  derived axis the aggregate now ranges over, not the full-grid rects.
- `fixtures/pushdown_mirror.esm` — the same document plus two MIRRORED
  per-record binning aggregates (`plume_top[r]`, `in_grid[r]`), the orientation
  plume rise needs. Its golden pins the second detector arm: the mirrors get
  ONLY a gate, over the document's own full-grid rect factors; no second derived
  set, producer, member factor or `gated_select` entry is emitted for them, and
  their `shape` / `output_idx` / `ranges` are untouched.
- `fixtures/pushdown_envelope_overlap.esm` — the SECOND containment shape. The
  record has EXTENT rather than a position, so the predicate is the 2-D AABB
  overlap test between the cell rectangle and the record's own bounding box
  (`src_W[c] <= rec_xmax[r] ∧ rec_xmin[r] <= src_E[c] ∧ …`) — what a polygon or
  line record needs, with the exact clipped area or length left to the
  aggregate's own narrow phase. Its golden pins that `src_env` is the record's
  FOUR bounds `[rec_xmin, rec_ymin, rec_xmax, rec_ymax]` while everything
  downstream of the parse emits exactly as in `pushdown_gated_dense` — the
  derived set, producer, member factor, cell gathers and `gated_select` are
  arity-agnostic. It also carries a mirror (`overlapping_cells[r]`), because an
  envelope predicate is SYMMETRIC — it parses with either symbol taken as the
  cell — and so, unlike the point shape, cannot decide the orientation on its
  own: that must come from the mat-vec's first axis forward, and from the
  already-fixed `C`/`R` for a mirror.
- `fixtures/pushdown_template_body.esm` — the SAME math as
  `pushdown_gated_dense`, but the binning body is factored through an
  `expression_templates` entry with the four rect factors and the two point
  coordinates passed as **bindings**. Under esm-spec §9.6.4 Option B that
  reference SURVIVES load and reaches `desugar_pushdown` unexpanded. Its golden
  pins the invariant that whether the pushdown fires MUST NOT depend on how the
  author factored the body: the derived set, producer, member factor, cell
  gathers, gate and `gated_select` record are IDENTICAL to the longhand golden —
  the two goldens differ in `E_PM25` and nothing else — while the template
  **body is byte-identical to the input's**. The rewrite re-points the CALL
  SITE's `bindings` onto the generated `pd_cell__*` gathers, never the shared
  body, so Option B's single lowering survives the rewrite. (The generated
  producer `filter` still carries the FULL-GRID rect references, read off the
  expanded body before the call site is rewritten.)
- `fixtures/pushdown_unreadable_join.esm` — a `fires: false` fixture: `E_PM25`
  bins records into `src_cells` with a THREE-dimensional box containment and
  feeds the provider-backed `SR_PM25`, so it is unmistakably in the join
  position, but the recogniser handles 2-D geometry only — three coordinates
  each carrying a min and a max match neither the 2-factor point shape nor the
  4-factor envelope one. The rewrite MUST
  leave the document unchanged AND MUST report why — its golden is the
  `pushdown_diagnostics` list, not a rewritten document.
- `fixtures/isrm.esm` — the real `isrm.esm` (from the isrm.esm repo), loaded
  with its metaparameter defaults and re-emitted via `serialize_esm_file` so
  the committed input is self-contained (no open metaparameters). FROZEN: see
  the re-emission note below.
- `golden/<id>.rewritten.json` — `desugar_pushdown(input)` from the Julia
  reference implementation.

## What the goldens pin about the gate

Two containment SHAPES are recognised — point-in-rectangle (`src_env` arity 2)
and envelope overlap (arity 4) — and both ORIENTATIONS of the binning join
(CONFORMANCE_SPEC.md §5.5.7). Shape and orientation are independent: the shape
decides only `src_env`'s arity, and everything below is per-orientation. The
gate is the SAME clause either way — only which axis the aggregate
outputs differs, and the enumeration driver is orientation-agnostic:

| | forward `E[c] = Σ_r […]` | mirrored `P[r] = Σ_c […]` |
|---|---|---|
| output axis | the compact `pd_support__*` set | the FULL record set (unchanged) |
| gate `tgt_env` | the generated `pd_cell__*` gathers | the document's own rect factors |
| derived set / producer / member factor | emitted | **not** emitted |
| provider `gated_select` | applies | does not apply |

A mirrored aggregate wants every record to keep a value — a record outside the
grid must reduce to the semiring identity `0` — so there is nothing to compact
and a mirrored value-invention would derive a support set nobody reads.

## Adapter contract

For each manifest fixture, a binding adapter MUST:

1. Parse the `input` document (plain JSON parse; the rewrite is a raw
   document→document transform).
2. Run its `desugar_pushdown` (passing `model_name` when the manifest sets
   one; `null` means single-model auto-selection).
3. When the fixture carries a `golden` (the default — `fires` absent or true):
   assert the output **deep-equals** the parsed `golden` — comparison on
   parsed JSON values: object key order is free, numbers compare by value
   (`0` == `0.0`), lists compare element-wise in order — and assert
   **idempotency**: running `desugar_pushdown` on the golden returns it
   UNCHANGED (the provenance-record guard; no `pd_support__pd_support__…`
   second layer).
   When the fixture declares `"fires": false`: assert the rewrite returned the
   input document UNCHANGED (same object / borrowed, per the binding's
   convention).
4. When the fixture carries a `diagnostics` path: assert the binding's
   `pushdown_diagnostics` returns a list deep-equal to that golden. Records
   carry `code`, `variable`, `consumer`, `array`, `index_set`, `reason`
   (`predicate_unparsed` | `surviving_template_reference`), `template` (the
   template name, or `null`) and `consequence`, sorted by
   `(variable, consumer, array)`. The human-readable warning text a binding
   also emits is NOT part of the contract; this record set is.
5. Assert **input purity**: the input document is not mutated by the rewrite
   (the rewrite returns a fresh document).

New fixtures need no adapter code: the manifest drives the loop, and the two
optional keys above (`fires`, `diagnostics`) are the whole vocabulary.

Byte-level equality is deliberately NOT asserted across bindings — the
committed files are canonical JSON (recursively sorted keys, 2-space indent,
shortest-round-trip float encoding) so that *re-emission is byte-stable and
diffs stay reviewable*, not so that every binding's serializer must agree on
bytes (the round_trip category's rationale applies here too).

Determinism note: every list the rewrite emits is document-order-determined
except `metadata.x_esd.pushdown.gated_select.applies_to`, which is
**sorted** by the rewrite (its consumers are membership-based) so bindings
with different map-iteration orders agree.

## Re-emission

```
julia --project=<env with EarthSciAST> scripts/generate-pushdown-goldens.jl
```

The `isrm` pair regenerates its GOLDEN from the committed `fixtures/isrm.esm`,
not from a sibling checkout: upstream `isrm.esm` keeps evolving, and the frozen
fixture — not whatever the checkout currently holds — is the cross-binding
contract. Set `ISRM_ESM_REFRESH=1` (with `ISRM_ESM` pointing at the document,
default a sibling `isrm.esm` checkout) to deliberately re-cut the INPUT fixture;
that is a corpus change in its own right and should not ride another change.

Re-emitting must otherwise be a no-op diff unless the rewrite itself changed; a
changed golden is a cross-binding-visible behavior change and needs the other
bindings' adapters re-run.
