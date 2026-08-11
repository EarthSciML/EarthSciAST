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
- `fixtures/isrm.esm` — the real `isrm.esm` (from the isrm.esm repo), loaded
  with its metaparameter defaults and re-emitted via `serialize_esm_file` so
  the committed input is self-contained (no open metaparameters).
- `golden/<id>.rewritten.json` — `desugar_pushdown(input)` from the Julia
  reference implementation.

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

`ISRM_ESM` points at the isrm.esm document (default: a sibling `isrm.esm`
checkout). Re-emitting must be a no-op diff unless the rewrite itself changed;
a changed golden is a cross-binding-visible behavior change and needs the
other bindings' adapters re-run.
