# Cross-Binding Determinism Conformance

The adversarial harness for the **cross-binding determinism contract** —
`CONFORMANCE_SPEC.md` §5.5, the normative form of RFC
`semiring-faq-unified-ir` §5.7.

## Why this exists

`earthsci-toolkit` is **parallel native implementations** (Julia, Rust,
Python, …) verified by a conformance suite — not one core behind FFI. The
value-invention primitives (`skolem`, `distinct`, `rank`) and value-equality /
group-by joins produce **index sets and dense IDs that other nodes consume**.
Two bindings that disagree on the *order* or *numbering* of those outputs
produce **different models**, not merely different formatting. So the existing
"95% graph structure, minor formatting differences acceptable" tolerance
(§5.2) is *too weak* here: relational index sets and dense-ID arrays demand
**byte-identical** agreement.

This directory holds the durable artifact that makes that guarantee testable:
a static golden example plus an adversarial harness that proves order-,
duplicate-, and orientation-independence.

## Layout

```
tests/conformance/determinism/
├── README.md         # this file — the contract + adapter interface
└── manifest.json     # the static golden example (inputs + expected outputs)
```

The runner is `scripts/run-determinism-conformance.py` (a self-contained
sibling of `scripts/run-grid-conformance.py`). It embeds the **reference
implementation** of the primitives — the contract as code — and the committed
golden in `manifest.json` is hand-derived and checked against it.

## Two phases

The producers do not exist yet: the M2 value-equality joins and the M3
relational engine (`distinct` / `skolem` / `rank`) land them. So the harness
runs in two phases, exactly like the grid-conformance runner's `--self-test`:

1. **Now (skeleton, gated by `--self-test`).** The runner asserts the contract
   against its embedded reference implementation and the golden example. It
   verifies:
   - every binding-neutral output equals the committed golden **byte-for-byte**;
   - every adversarial input variant (permuted, duplicated, reversed
     orientation) **collapses to the identical golden output**;
   - the rank base-pin round-trips (a 1-based Julia emission normalizes back to
     the canonical 0-based numbering);
   - the harness actually **rejects** non-conforming output (unsorted /
     first-seen order; float key components) — a harness that cannot detect a
     violation is worthless.

   This is wired into `scripts/test-conformance.sh` as
   `run_determinism_conformance_self_test` and runs green parallel to M1.

2. **Later (M2 / M3, per-binding producers).** Each binding ships a thin
   adapter. The default run mode invokes every registered adapter on this same
   manifest and asserts its serialized index sets + dense IDs are byte-identical
   to the golden (after base normalization) and to each other. As producers
   land, move the binding from `bindings_optional` to `bindings_required` so a
   missing or mismatching producer fails CI.

## The contract (summary — normative text is `CONFORMANCE_SPEC.md` §5.5)

Every emitted set, key, and dense ID is a **pure function of a defined total
order over tuples**. No observable output may depend on hash-table iteration
order or a language-native hash value.

1. **Total order** — lexicographic over tuple fields; integers by value;
   strings by Unicode code-point (== UTF-8 byte) order, *not* locale collation;
   **floats forbidden in keys** (normalize `-0.0`→`0.0`, reject `NaN` via the
   existing `canonicalize` if a float is truly unavoidable).
2. **`distinct`** — sort by the total order, drop *adjacent* duplicates. Output
   order **is** the sorted order, never first-seen / insertion order.
3. **`rank`** — dense IDs by position in the sorted `distinct` sequence.
   Conformance asserts the **canonical 0-based numbering**; each binding emits
   in its native base and converts at the boundary. Bases pinned in
   `manifest.json#rank_base_pin`: **Julia 1-based, Rust 0-based, Python
   0-based** (Go / TS: additive schema only, no producer).
4. **`skolem`** — a canonical **tuple**, not a hash. Symmetric relations sort
   their components (undirected edge → `(min, max)`); directed relations
   preserve order. Dense IDs then come from `rank`.
5. **`join` / group-by aggregate** — hash only to *bucket*; emit **sorted by
   the canonical key**. The semiring `⊕` is associative + commutative (every
   registry `⊕` is), so input/parallel order cannot change a result; for a
   float `⊕`, reduce each bucket sequentially in canonical order.

## Adapter contract (per binding, M2/M3)

The runner discovers an adapter for binding `B` from, in order:

1. `$EARTHSCI_DETERMINISM_ADAPTER_<B>` (tokenized with `shlex.split`), then
2. `earthsci-determinism-adapter-<B>` on `PATH`.

It invokes the adapter as:

```
<adapter> --manifest <manifest.json> --output <result.json>
```

The adapter MUST, for each fixture, run its binding's real producers over the
fixture's `inputs.canonical` payload and write:

```json
{
  "binding": "rust",
  "fixtures": {
    "edge_enumeration": {
      "index_set": [[1,2],[1,3],[2,3],[2,4],[3,4]],
      "serialized": "[[1,2],[1,3],[2,3],[2,4],[3,4]]",
      "dense_ids_canonical": [0,1,2,3,4]
    }
  }
}
```

- `serialized` is the canonical byte form: compact JSON (`,`/`:` separators, no
  spaces), UTF-8 (no `\uXXXX` escaping), tuples as arrays — the same
  canonical-JSON discipline as the round-trip idempotence contract.
- `dense_ids_canonical` is emitted in the binding's **native** base; the runner
  normalizes via `rank_base_pin` before comparison.
- Adapters SHOULD also run the `inputs.variants` and confirm each collapses to
  the same output; the runner checks variant-collapse for the reference
  implementation today and will check it per-binding once producers exist.

Keep the adapter thin (target ≲ 100 lines, like the round-trip adapters). If it
grows, the contract is leaking into the adapter — push it back into the binding
or this document.

## Adding a fixture

1. Author the input(s) and **hand-derive** the expected golden (do not dump it
   from the reference implementation — the point is that
   reference-output == hand-derived-golden is a real check).
2. Add the fixture to `manifest.json` with `inputs.canonical`, at least one
   adversarial `inputs.variants` entry, and the `expected` block.
3. Run `python3 scripts/run-determinism-conformance.py --self-test` until green.

## Related

- `CONFORMANCE_SPEC.md` §5.5 — the normative contract.
- `docs/content/rfcs/semiring-faq-unified-ir.md` §5.7 + Appendix A.5 — the
  contract's home and per-language rationale / hash-randomization footguns.
- `tests/conformance/grids/README.md` — the sibling grid-conformance harness
  this one mirrors.
