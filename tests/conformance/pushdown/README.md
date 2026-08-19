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
- `fixtures/isrm.esm` — the real `isrm.esm` (from the isrm.esm repo), loaded
  with its metaparameter defaults and re-emitted via `serialize_esm_file` so
  the committed input is self-contained (no open metaparameters). FROZEN: see
  the re-emission note below.
- `golden/<id>.rewritten.json` — `desugar_pushdown(input)` from the Julia
  reference implementation.

## What the goldens pin about the gate

Both orientations of the binning join are recognised (CONFORMANCE_SPEC.md
§5.5.7). The gate is the SAME clause either way — only which axis the aggregate
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
3. Assert the output **deep-equals** the parsed `golden` — comparison on
   parsed JSON values: object key order is free, numbers compare by value
   (`0` == `0.0`), lists compare element-wise in order.
4. Assert **idempotency**: running `desugar_pushdown` on the golden returns
   it UNCHANGED (the provenance-record guard; no
   `pd_support__pd_support__…` second layer).
5. Assert **input purity**: the input document is not mutated by the rewrite
   (the rewrite returns a fresh document).

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
