# Cross-Binding Cadence-Partition Conformance

The harness for the **dependency-partition (cadence) contract** —
`CONFORMANCE_SPEC.md` §5.7, the normative form of RFC
`semiring-faq-unified-ir` §6.1.

## Why this exists

The partition pass is the ESS analogue of ModelingToolkit's
`structural_simplify` / observed-variable elimination, generalized from two
phases to three. It classifies **every node** by the *cadence* at which its
value can change — `const ⊏ discrete ⊏ continuous`, `class(node) = max` over
inputs — and schedules each class into its own phase: a **folded artifact**
(`CONST`), a **per-event handler** (`DISCRETE`), and the **hot per-step
`_Node` tree** (`CONTINUOUS`). The boundary is derived from the data-dependency
DAG, never declared.

Because the classification is a **compile-time** property that drives *which
code runs in which phase*, two bindings that disagree on a node's class, on the
**set of materialization points** (where the frontier cut fires), or on the
bytes of a **`CONST`-folded buffer** produce *different models* — different hot
loops, different per-event work — not merely different formatting. So the §5.2
"95% graph structure, minor formatting acceptable" tolerance is *too weak*
here, exactly as for the §5.5 determinism contract this directory mirrors. The
partition is **normative spec**, asserted directly.

This directory holds the durable artifact that makes that guarantee testable: a
static golden plus a reference harness that proves class-, materialization-, and
fold-agreement.

## Layout

```
tests/conformance/cadence/
├── README.md         # this file — the contract + adapter interface
└── manifest.json     # the static golden (per fixture: class summary,
                      #   materialization-point set, CONST-fold buffers)
```

The fixtures themselves are valid ESM files under
`tests/valid/cadence/` (`mixed_stencil.esm`, `pure_topology.esm`,
`pure_pointwise.esm`, `discrete_remesh_stencil.esm`, and the loader-seeded pair
`loader_temporal_seed.esm` / `loader_const_seed.esm`) — they validate against the
schema with no evaluator
(like `tests/valid/aggregate/discrete_variable_refresh.esm`) and carry an
`expect_cadence` assertion on every meaningful node. The runner is
`scripts/run-cadence-conformance.py` (a self-contained sibling of
`scripts/run-determinism-conformance.py`). It embeds the **reference
classifier + folder** — the §5.7 contract as code — and the committed golden in
`manifest.json` is hand-derived and checked against it.

## The fixtures (RFC §6.1)

| Fixture | Class profile | Exercises |
|---|---|---|
| `mixed_stencil` | all three classes, both thresholds | the gather split `index(u, index(nbr,i,k))` (inner topology `CONST`, outer load `CONTINUOUS`); `CONST` topology fold + `DISCRETE` per-event materialization + `CONTINUOUS` hot contraction |
| `pure_topology` | all `CONST` | empty hot tree — the whole edge-enumeration folds into the artifact (the mechanism by which an unstructured-mesh discretization drops its imperative edge construction) |
| `pure_pointwise` | all `CONTINUOUS` | empty per-event handler, no materialization; the analytic continuous-`t` forcing `sin(omega·t)` stays `CONTINUOUS` (not `DISCRETE`) — classify by cadence, not by role |
| `discrete_remesh_stencil` | `DISCRETE` topology + `CONTINUOUS` hot path | the §6.1 worked-trace **discrete-mesh path** (ess-my4.3.10): `mixed_stencil` with the topology (`nbr`/`coeff`) declared `discrete` (an AMR remesh-reloadable mesh) so the SAME topology gathers materialize at the `DISCRETE→CONTINUOUS` threshold — recomputed by the per-event handler on each remesh event instead of folding once at compile. With `mixed_stencil` (CONST topology) this is the const-vs-discrete topology pair: "mesh primitives as document literals → topology folds at compile; reloaded/refined mesh → same nodes are DISCRETE and re-run on the remesh event." |
| `loader_temporal_seed` | loader-seeded `DISCRETE` + `CONTINUOUS` hot path | **loader-seeded cadence** (RFC `pure-io-data-loaders` §4.6, ess-v9a.5): a `discrete` variable fed by a `data_ingest` refresh whose source `DataLoader` declares a `temporal` block seeds `DISCRETE` (refresh trigger = the loader's update times) and materializes at `DISCRETE→CONTINUOUS` (bind provenance, recomputed on each ingest). |
| `loader_const_seed` | loader-seeded `CONST` + `CONTINUOUS` hot path | the matched-pair sibling: IDENTICAL model, but the loader declares **no** `temporal`, so the SAME `discrete`+`data_ingest` variable is refined to `CONST` (folds at bind, never refreshes) and materializes at `CONST→CONTINUOUS`; the per-event handler is empty. Toggling the loader's `temporal` block alone flips the variable between the two cadences. |

The numeric tail of the §7.3 worked example — the downstream `sum_product`
geometric FAQ that consumes the materialized edge set as a *primitive* index set
(`area_eff[i] = Σ_{e∈edges} …`) — lives in
`tests/valid/aggregate/area_eff_edge_faq.esm` and is evaluated numerically by all
three bindings via the aggregate-conformance suites (its inline `tests` golden is
the cross-binding numeric check). The full §7.3 chain in one document (enumerate →
skolem/distinct → rank → ragged `edges_of_cell` inversion → `area_eff`) is the
structural fixture `tests/valid/aggregate/edge_enumeration_area_eff.esm`.

## Two phases

All three producers have landed — Julia (`ess-my4.3.7`,
`EarthSciSerialization.Cadence`), Rust (`ess-my4.3.8`), and Python
(`ess-my4.3.9`) — and all three adapters are now wired into
`scripts/test-conformance.sh` (`run_cadence_conformance_{julia,rust,python}`,
ess-my4.3.10). The harness still runs in two phases, exactly like the determinism
and grid-conformance runners' `--self-test`:

1. **Now (skeleton, gated by `--self-test`).** The runner asserts the contract
   against its embedded reference classifier + folder and the golden. It
   verifies:
   - **class agreement** — the reference-derived class of every annotated node
     equals both the node's own `expect_cadence` assertion and the golden class
     summary;
   - **materialization set** — the frontier the reference derives (cadence drops
     across expression edges) matches the golden materialization-point set, and
     the hot-tree / per-event-handler emptiness matches;
   - **`CONST`-fold byte-identity** — the buffers the reference folds serialize
     **byte-for-byte** to the golden;
   - the harness actually **rejects** non-conforming input — a wrong
     `expect_cadence`, a `CONTINUOUS` relational node (guard 2), a `from_faq`
     cycle in the `≤DISCRETE` graph (guard 1), and a float topology key.

   This is wired into `scripts/test-conformance.sh` as
   `run_cadence_conformance_self_test` and runs green before any producer exists.

2. **Later (per-binding producers).** Each binding ships a thin adapter. The
   default run mode invokes every registered adapter on this same manifest and
   asserts its class map, materialization set, and `CONST`-folded buffers are
   identical to the golden and to each other. The Julia adapter
   (`packages/EarthSciSerialization.jl/scripts/cadence_adapter.jl`) is wired
   into `scripts/test-conformance.sh` as `run_cadence_conformance_julia` (it
   sets `$EARTHSCI_CADENCE_ADAPTER_JULIA` and runs `--bindings julia`); the
   Julia package's own `test/cadence_test.jl` asserts the same golden directly.
   The Rust adapter
   (`packages/earthsci-toolkit-rs/src/bin/earthsci-cadence-adapter-rust.rs`,
   `run_cadence_conformance_rust`) and the Python adapter
   (`packages/earthsci_toolkit/src/earthsci_toolkit/cli/cadence_adapter.py`,
   `run_cadence_conformance_python`) are wired the same way; each binding's own
   suite (`cadence_conformance.rs`, `test_cadence_partition.py`) also asserts the
   golden directly. All three stay `bindings_optional` so a bare runner invocation
   without the adapter on `PATH` is skipped, not failed — but a *mismatch* fails.
   Promote each to `bindings_required` once its adapter is guaranteed present in
   CI so a *missing* producer also fails.

## The contract (summary — normative text is `CONFORMANCE_SPEC.md` §5.7)

1. **Cadence lattice** — `const ⊏ discrete ⊏ continuous`. `class(node) = max`
   (the lattice join) over inputs. Leaves seed from their declared role: `state`
   → `continuous`, `parameter` / literal → `const`, `discrete` → `discrete`; the
   independent variable `t` is `continuous`.
2. **Gather rule** — `class(index(A, e…)) = max(class(A), class(e…))`. The index
   expressions are classed **independently of the array**, so a stencil splits:
   `index(nbr,i,k)` is `CONST` while `index(u, index(nbr,i,k))` is `CONTINUOUS`.
3. **Frontier cut** — a node whose class is strictly lower than its parent's is
   a **materialization point**: the maximal lower-cadence sub-DAG below that edge
   is evaluated in its phase, stored in a buffer, and referenced by the parent.
   `CONST → {DISCRETE, CONTINUOUS}` folds into the artifact; `DISCRETE →
   CONTINUOUS` materializes into a per-event buffer. A bare scalar-constant leaf
   is not a buffer (it inlines as a literal — the pre-existing constant-fold).
4. **Provenance** — a `CONST`/`DISCRETE` leaf whose bytes are inline folds at
   **compile**; one loaded from an external resource folds at **bind**. Same
   algebra, a sub-tag only.
5. **Guards (checked)** — (1) the `≤DISCRETE` subgraph is acyclic (a cycle is an
   implicit solve, out of scope — reject naming the cycle); (2) no
   `distinct`/`join`/`skolem`/`rank` node may classify `CONTINUOUS`; (3) an
   `expect_cadence` assertion that disagrees with the derived class is an error.

## Adapter contract (per binding)

The runner discovers an adapter for binding `B` from, in order:

1. `$EARTHSCI_CADENCE_ADAPTER_<B>` (tokenized with `shlex.split`), then
2. `earthsci-cadence-adapter-<B>` on `PATH`.

It invokes the adapter as:

```
<adapter> --manifest <manifest.json> --output <result.json>
```

The adapter MUST run its binding's real partition pass over each fixture and
write, per fixture:

```json
{
  "binding": "julia",
  "fixtures": {
    "mixed_stencil": {
      "class_summary": { "const": 2, "discrete": 1, "continuous": 6 },
      "materialization_points": [
        { "threshold": "const->continuous" },
        { "threshold": "const->continuous" },
        { "threshold": "discrete->continuous" }
      ],
      "const_fold_buffers": {
        "nbr_idx": "[[1,3,0],[2,0,1],[3,1,2],[0,2,3]]",
        "coeff": "[[1,1,0],[1,1,0],[1,1,0],[1,1,0]]"
      }
    }
  }
}
```

- `class_summary` counts annotated nodes by derived class.
- `materialization_points[].threshold` is the cadence drop (`const->continuous`,
  `discrete->continuous`, or `const->artifact` for a top-level output buffer);
  the runner compares the threshold **multiset**.
- `const_fold_buffers` maps each buffer label to its **canonical byte form**:
  compact JSON (`,`/`:` separators, no spaces), UTF-8 (no `\uXXXX`), arrays for
  tuples — the same canonical-JSON discipline as the round-trip / determinism
  contracts. Compared **byte-for-byte**.

Keep the adapter thin (target ≲ 100 lines, like the round-trip / determinism
adapters). If it grows, the contract is leaking into the adapter — push it back
into the binding or this document.

## Adding a fixture

1. Author the ESM file under `tests/valid/cadence/` with an `expect_cadence`
   assertion on each meaningful node, and **hand-derive** the golden class
   summary, materialization-point set, and `CONST`-fold buffers (do not dump
   them from the reference — `reference-output == hand-derived-golden` is the
   real check).
2. Add the fixture to `manifest.json` with `class_summary`,
   `materialization_points`, and a `const_fold` block (`inputs` + `expected`).
3. Run `python3 scripts/run-cadence-conformance.py --self-test` until green.

## Related

- `CONFORMANCE_SPEC.md` §5.7 — the normative contract.
- `docs/content/rfcs/semiring-faq-unified-ir.md` §6.1 — the contract's home
  (cadence classes, propagation, frontier cut, three execution outputs, guards).
- `tests/conformance/determinism/README.md` — the sibling determinism harness
  this one mirrors; the §5.5 total order fixes `distinct`/`skolem`/`rank` output,
  which `pure_topology` reuses (its edge set is the determinism `edge_enumeration`
  golden).
