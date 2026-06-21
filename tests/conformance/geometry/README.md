# Cross-Binding Conservative-Regridding Geometry Conformance

The adversarial harness for the **conservative-regridding geometry tolerance
contract** — `CONFORMANCE_SPEC.md` §5.8, the normative form of RFC
`semiring-faq-unified-ir` §8.1 and Appendix B.5.

> **Per-binding adapters RETIRED (bead ess-3lj.3).** The imperative
> conservative-regridding assemblies (`conservative_regrid.jl` / `regrid.rs` /
> `conservative_regrid.py`) and their `$EARTHSCI_GEOMETRY_ADAPTER_<BINDING>`
> adapters have been deleted in favor of a single end-to-end-evaluable document,
> `tests/valid/geometry/conservative_regrid_overlap_join.esm`, driven through the
> evaluator (Julia evaluates it end-to-end in
> `test/geometry_overlap_join_conformance_test.jl`; the broad phase + `polygon_area`
> FAQ run per-binding in Julia/Python/Rust). The harness below remains as the
> **`--self-test`** contract guard (embedded reference + static golden); the
> `--bindings <producer>` mode and the adapter sections in this file are
> **historical**. The golden `manifest.json` still backs the self-test.

## Why this exists

`earthsci-toolkit` is **parallel native implementations** (Julia/GeometryOps,
Python/S2, …) verified by a conformance suite — not one core behind FFI. The
conservative regridder (`F_tgt[j] = (1/A_j)·Σ_i A_ij·F_src[i]`) is the place
where the two stacks' geometry kernels meet, and they will **not** agree
bit-for-bit on overlap areas: a great-circle clip on the sphere and a
GeometryOps clip legitimately disagree in the sliver regime. So this gate is the
deliberate **inverse** of the byte-identity contracts in §5.5–§5.7. It asserts:

1. **Exact (combinatorial).** The integer **bin-Skolem candidate overlap-pair
   index set** — the broad-phase spatial join — is **byte-identical** across
   bindings (governed by the §5.5 determinism contract). This is the one hard
   anchor, and it is manifold-independent (pure integer binning).
2. **Exact (physical invariants).** Global **conservation** and
   **partition-of-unity** are the **primary** gate (§5.8.3). Partition-of-unity
   `Σ_i W_ij = 1` is exact by construction (the weights are normalized by the
   row-sum of the *computed* overlap areas); conservation is exact where the
   target tiles the source domain.
3. **Tolerance (geometry).** Per-pair overlap **areas** `A_ij` and the
   **weights** built from them satisfy a combined relative + absolute tolerance
   with a **sliver floor** `atol ≈ 1e-15·R²` — sub-`atol` areas snap to zero, so
   "present-but-tiny" and "absent" both pass (§5.8.2).

## Layout

```
tests/conformance/geometry/
├── README.md         # this file — the contract + adapter interface
└── manifest.json     # the static golden example (inputs + expected outputs)
```

The runner is `scripts/run-geometry-conformance.py` (a self-contained sibling of
`scripts/run-determinism-conformance.py`). It embeds the **reference
implementation** — a pure-Python bin-Skolem broad phase plus a planar
Sutherland–Hodgman clip + shoelace area — and the committed golden in
`manifest.json` is hand-derived and checked against it.

## The fixtures (adversarial)

| id | manifold | what it stresses |
|----|----------|------------------|
| `planar_coarsen` | planar | clean 4→1 tiling; conservation + partition-of-unity exact |
| `planar_tiling_tangent_slivers` | planar | edge-tangent zero-area slivers inside a tiling — candidates that MUST floor to zero; the diagonal survives; permuted-order variant |
| `planar_partial_overlap` | planar | a genuine fractional area (0.25) through the tolerance check; conservation legitimately not exact |
| `planar_disjoint` | planar | far-apart cells share no bin — the **empty** candidate set |
| `spherical_polar` | spherical | pole-touching great-circle-edge cells; candidate set + partition-of-unity, areas gated cross-binding |

## Two phases

1. **Now (skeleton, gated by `--self-test`).** The runner asserts the contract
   against its embedded reference implementation and the golden example:
   - the candidate set reproduces the golden **byte-for-byte** (planar AND
     spherical — binning is manifold-independent);
   - every adversarial **permuted-input-order** variant **collapses to the
     identical candidate set** after the index remap;
   - the planar areas + invariants reproduce the golden, and the tangent slivers
     floor to zero;
   - the harness actually **rejects** non-conforming output — an incomplete
     candidate set, a float in a bin key, an area outside tolerance, a broken
     partition-of-unity residual.

   This is wired into `scripts/test-conformance.sh` as
   `run_geometry_conformance_self_test` and runs green parallel to the producers.

2. **Producers (live — the M4 assemblies ess-my4.4.6 / .4.7 have landed).** Each
   binding ships a thin adapter. The run mode invokes every registered adapter on
   this same manifest — over the canonical input AND every variant — and asserts
   its candidate set is byte-identical to the golden (after base normalization),
   its invariants hold to tolerance, and its per-pair areas agree with the golden
   (and, run together, with the reference binding). Julia + Python are
   `bindings_required`; Rust is optional until its S2 FFI lands
   (ess-my4.4.10/.11/.12).

## Adapter interface

The runner discovers a binding's adapter via
`$EARTHSCI_GEOMETRY_ADAPTER_<BINDING>` (or `earthsci-geometry-adapter-<binding>`
on `PATH`) and calls:

```
<adapter> --manifest <manifest.json> --output <result.json>
```

The adapter reads the manifest and, for **every** fixture, writes:

```json
{
  "binding": "<name>",
  "fixtures": {
    "<fixture id>": {
      "candidate_pairs": [[i, j], ...],          // NATIVE base (see base_pin)
      "areas": [[i, j, A_ij], ...],              // post-floor, native base
      "partition_of_unity_max_residual": 0.0,
      "conservation_residual": 0.0,              // when the fixture pins F_src + src_areas
      "variants": { "<vname>": { "candidate_pairs": [[i, j], ...] } }
    }
  }
}
```

Conventions:

- **Base normalization.** `candidate_overlap_pairs` returns positional indices
  into the input arrays. Julia is 1-based, Python is 0-based. Each adapter emits
  in its **native** base and declares it via the manifest's `base_pin`; the
  harness normalizes `(i, j)` to canonical 0-based before serializing/comparing.
- **Candidate set first.** The broad phase is pure integer binning and needs no
  geometry backend, so the candidate set is **always** emitted — it is the
  PRIMARY byte-identical anchor.
- **Backend degradation.** The narrow-phase clip needs a backend the broad phase
  does not (Julia's GeometryOps extension, Python's optional `spherely`/S2). When
  it is absent — typically for the spherical fixture — the adapter emits
  `"narrow_phase_unavailable": "<reason>"` instead of `areas` /
  `partition_of_unity_max_residual`, and the runner skips the area + invariant
  sub-checks for that fixture while still gating the candidate set. The planar
  fixtures need no backend, so they always run.

Keep adapters thin: the contract lives in the assembly modules
(`packages/EarthSciSerialization.jl/src/conservative_regrid.jl`,
`packages/earthsci_toolkit/src/earthsci_toolkit/conservative_regrid.py`), not in
the adapter.

## Tolerances

The manifest's `tolerances` block carries the documented defaults. The spec pins
exactly **one** numeric literal — `atol ≈ 1e-15·R²`, the sliver floor (`R` =
each fixture's `characteristic_length`). `area_rtol` is empirically calibrated
and MUST accommodate the loosest binding pair (GeometryOps-vs-S2); the
conservation tolerance is application-set and resolution-dependent; the
partition-of-unity epsilon is tight because it is exact by construction. These
are configurable inputs, not hard-coded epsilons.
