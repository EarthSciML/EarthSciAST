# Shared Conformance Harness

Single source of truth for cross-binding conformance tests. Each binding
(Julia, Python, Rust, TypeScript, Go) provides a thin adapter that loads a
manifest, runs its implementation against the listed fixtures, and asserts
a standardized contract. This replaces the ad-hoc per-binding duplication
where each language reinvented the same round-trip / validation / flatten
checks against overlapping but inconsistent fixture sets (see gt-tvz).

## Directory layout

```
tests/conformance/
├── README.md                       # this file — the adapter contract
└── round_trip/
    └── manifest.json               # fixtures, normalizations, transforms, divergences
```

The fixtures themselves live in the existing corpus (`tests/valid/`,
`tests/fixtures/arrayop/`, etc.). Manifests reference fixtures by path
relative to the repository's `tests/` directory.

## What shape is a conformance stage? Read this before adding one

Every stage in `scripts/test-conformance.sh` is one of three shapes, and
they are **not** equally strong. `check_agreement` in
`scripts/compare-conformance-outputs.py:440` already documents its own
weakness ("five bindings can agree on the wrong answer"); the round-trip
and property stages did not, and both were silently the weakest shape
there is. Pick your shape deliberately:

| Shape | What it proves | What it cannot see |
|---|---|---|
| **Reference-comparing** | Output matches a pinned oracle *outside* the bindings — a committed golden, an analytic solution, an independent reference implementation, or the authored source document. | Nothing structural. This is the strong shape; it can only be wrong if the oracle is wrong. |
| **Cross-binding-agreeing** | All five bindings produce the same answer. | **A shared wrong answer.** Five bindings that all drop the same field agree perfectly. |
| **Self-comparing** | One binding agrees with *itself* on a second pass (idempotence, fixed points). | **Anything lost on the first pass.** The second pass forgets exactly what the first forgot, so the equation holds over an already-damaged document. Weakest shape; never the only gate on a property. |

Classification of every stage in `scripts/test-conformance.sh`:

| Stage | Shape |
|---|---|
| `binding:<lang>` (each binding's own test suite) | mixed — each suite decides; the per-binding round-trip *fidelity* tests are reference-comparing |
| `cross-language comparison` (`compare_outputs`) | **reference-comparing** for declared outcomes and pinned error codes/paths; **cross-binding-agreeing** for `check_agreement` |
| `conformance report` | neither — it renders, it does not assert |
| `property-corpus round-trip` | **reference-comparing** since the source fixture `F` became a participant (was cross-binding-agreeing only) |
| `determinism self-test` | reference-comparing (embedded reference + static golden) |
| `determinism producer (julia/rust/python)` | reference-comparing (byte-identity to the golden) |
| `geometry self-test` | reference-comparing (embedded reference + static golden) |
| `cadence self-test` | reference-comparing (embedded reference classifier + golden) |
| `cadence producer (julia/rust/python)` | reference-comparing (byte-identity to the golden) |
| `PDE-simulation self-test` | reference-comparing (golden reproduces independent analytic anchors) |
| `PDE-simulation producer (julia/rust/python)` | reference-comparing (golden + analytic anchors) |
| `full-pipeline PDE self-test` | reference-comparing (golden vs independent reference integrator) |
| `full-pipeline PDE producer (julia/rust/python)` | reference-comparing (golden + independent reference) |
| `recurrence` (`recurrence/`, driven by each binding's own suite) | **reference-comparing** — every assertion is a value pinned at zero tolerance, several against an INDEPENDENT oracle (`07`'s ascending fold in Python) rather than against another binding. Bit-identity is available here (CONFORMANCE_SPEC §5.19.1), so cross-binding agreement is a consequence of each binding matching the reference, not the test |
| **round-trip** (`round_trip/manifest.json`, below) | **reference-comparing** since the original fixture `F` became the oracle (was self-comparing) |

## Round-trip contract

The oracle is **the authored fixture itself**. Given a fixture `F`, each
binding adapter MUST implement:

```
emitted = save(load(F))

# Parse both as JSON and deep-compare the resulting values.
assert normalize(json_parse(emitted)) == normalize(json_parse(F))
```

This is the **load-preservation** half of esm-spec.md §9.6.4 rule 5, and
it is normative there, not merely a harness policy.

### Why it changed, and what it replaces

This harness used to assert **serializer idempotence** —
`save(load(F))` vs `save(load(save(load(F))))`, passes 2 and 3, with `F`
never a participant. That is the *self-comparing* shape above, and it was
blind to exactly the defect it was the only gate against: a serializer
that silently forgets `metadata.license` is perfectly idempotent about
forgetting it, so the comparison stays green while the document rots.

An empirical audit measured `save(load(F))` against `F` across all five
bindings and found large drop sets — Go 65 fixtures differing, Python 51,
Julia 47, Rust 20. One of them (`Parameter.update`) changed **computed
results**, not annotation: an `update` block is the only channel binding a
parameter to a data source (esm-spec §5.4), so dropping it turned a
data-driven parameter into a constant. None of it was visible to the old
contract.

Idempotence is still required — esm-spec §9.6.4 rule 5 states both, and
neither implies the other — so each adapter asserts it as a second,
cheaper check. It is no longer the *only* check.

### The normalizations

`normalize` is applied to **both** sides, so none of it can hide a drop.
It implements admissions 1 and 2 of esm-spec §9.6.4 rule 5's
load-preservation paragraph. The manifest's `normalizations` array is the
authority; summarized here:

1. Object key order and whitespace are free — comparison is on parsed
   values, not strings.
2. Numbers compare by **mathematical value**, not spelling. A tolerance
   for where the bindings stand today, not a rule the format grants: see
   the manifest entry and `value_diff` in
   `pkg/earthsci-ast-rs/tests/round_trip.rs`. Tighten to a spelling
   comparison once the canonical-number ruling lands in all five.
3. Empty containers (`[]`, `{}`) are dropped from both sides.
4. Two written-out schema defaults the emitters omit are dropped:
   `domain.independent_variable == "t"` and a periodic trigger's
   `initial_offset == 0`.
5. `expect_cadence` is dropped from both sides — a three-way cross-binding
   split, recorded in the manifest rather than hidden.

### The two exemption ledgers — and why they are different

A fixture may be excused from **full equality** by one of two manifest
fields. They mean opposite things and must never be confused:

- **`load_transforms`** — the SPEC REQUIRES this rewrite, so every binding
  performs it and none is at fault. Each entry names the transform, cites
  the clause, and says what it does. Present set: `enum_lowering` (§9.3),
  `eager_template_expansion` (§9.6.4 rule 3), `match_only_registry_drop`
  (§9.6.4 rule 5), `template_import_consumption` (§9.7.6),
  `metaparameter_folding` (§9.7.6 / rule 5 "Instantiating load"),
  `subsystem_ref_resolution` and `index_set_merge` (§4.7).

- **`known_divergences`** — the bindings do NOT agree, and the ones listed
  `nonconformant` are **wrong**. A defect ledger, not a licence. It is a
  **ratchet**: a binding listed `conformant`, and a binding named in
  neither column, stay held to every check the entry relieves for the
  non-conformant ones — so a defect can only ever shrink, and a new
  binding cannot inherit the excuse.

**Precedence when both apply.** `load_transforms` is checked first and
excuses full equality for *every* binding, because the rewrite is
mandated. A `known_divergences` entry on the same fixture then still
binds its `conformant` column to the checks equality does not cover —
field loss and re-loadability. That is not a technicality: the
`inlined_subsystem_default_emitted_as_string` entry exists precisely
because a defect hid inside a subtree that `subsystem_ref_resolution`
legitimately *adds*, where equality is not asserted, and only the
idempotence leg could reach it.

**Do not move a fixture from `known_divergences` into `load_transforms`
to get green.** Laundering a defect as a mandated transform is precisely
the failure this gate exists to prevent. If a fixture fails and the cause
is not one of the transforms above, that is a finding — report it.

### What is checked even on an excused fixture

Every fixture — excused or not — is checked for **field loss** against the
manifest's `preserved_keys`: no key in that set may disappear anywhere in
the document tree. A transform rewrites a *construct*; it does not licence
dropping the document around it. This is the half that still gates the
fixtures that legitimately transform, and it is why an exemption here is a
narrowing rather than a skip.

Each key in `preserved_keys` was a measured drop in at least one binding.
The pattern is taken from
`pkg/earthsci-ast-py/tests/test_roundtrip_against_original.py`
(`RESTORED_KEYS`) and `pkg/EarthSciAST.jl/test/corpus_fidelity_test.jl`.

### What the contract does NOT require

- Byte-identity with the input file.
- A particular key order or whitespace.
- Retention of a field whose authored value carries no distinguishable
  information (an empty collection, a written-out schema default).

### What the contract DOES require

- Every field the author wrote is present **with an equal value**. Key
  presence alone is not preservation.
- Semantic content — variable names, equation structure, species,
  reactions, metadata, data bindings — is never silently dropped.
- The serializer is deterministic, and `emit ∘ load` is a fixed point.

## Manifest schema

`round_trip/manifest.json`:

```json
{
  "category": "round_trip",
  "version": "2.0",
  "normalizations": ["…prose; the authority for `normalize` above…"],
  "preserved_keys": ["reference", "license", "update", "…"],
  "known_divergences": [
    {
      "id": "plot_at_time_dropped",
      "fixtures": ["spatial/pde_tests_analyses"],
      "rule": "esm-spec 9.6.4 rule 5, 'Load preservation'",
      "requirement": "…what the spec demands…",
      "conformant": ["julia", "rust", "typescript"],
      "nonconformant": ["python", "go"],
      "detail": "…why, and what fixing it needs…"
    }
  ],
  "fixtures": [
    {
      "id": "valid/minimal_chemistry",
      "path": "valid/minimal_chemistry.esm",
      "tags": ["core", "reactions"],
      "load_transforms": [
        { "transform": "enum_lowering", "spec": "esm-spec 9.3", "detail": "…" }
      ]
    }
  ]
}
```

Fields:

- `id` — stable identifier used in test output. Slash-separated, no extension.
- `path` — path relative to the `tests/` directory.
- `tags` — free-form labels for filtering (e.g. `core`, `events`,
  `arrayop`). The labels `transforming` and `divergent` mirror the two
  ledgers for quick filtering; the ledgers themselves are authoritative.
- `load_transforms` — optional; spec-mandated rewrites (see above).

## Adapter contract (per binding)

Each binding's test suite MUST provide an adapter that:

1. **Locates the manifest** — relative to the repository root, without
   hardcoding absolute paths. Fail loudly if it is not found.
2. **Resolves fixture paths** — relative to `tests/`.
3. **Normalizes both sides** per the five rules above.
4. **Asserts load preservation** — `save(load(F))` equals `F` — unless the
   fixture carries `load_transforms`, or a `known_divergences` entry names
   THIS binding as `nonconformant`.
5. **Asserts no `preserved_keys` loss** on EVERY fixture, excused or not.
6. **Asserts idempotence** — `save(load(save(load(F))))` equals
   `save(load(F))` — on every fixture. One narrow relief: when a
   `known_divergences` entry names THIS binding `nonconformant` and the
   re-load *throws*, the adapter records a visible **known failure**
   naming the ledger entry instead of a hard failure. That happens when a
   drop removes a **schema-required** field, so the emit is not a valid
   document and there is no second emit to compare — the ledger already
   records that defect, and reporting it twice would only stop the run.
   Never a silent pass; every other fixture hard-fails.
7. **Reports per-fixture pass/fail** using the binding's native test
   framework, labelled by the fixture `id`.
8. **Surfaces an excused fixture that now round-trips cleanly** as a
   visible note, not a failure. A binding that stops applying a permitted
   transform, or that fixes its own defect, is improving; the ledger entry
   is then stale and should be trimmed by hand. (A hard "an excused
   fixture MUST differ" assertion — which the per-binding local fidelity
   tests do use — cannot be shared here, because the bindings genuinely
   differ on which optional transforms they apply. Shared, it would fail
   the *correct* binding.)

Reference implementation:
`pkg/EarthSciAST.jl/test/conformance_round_trip_test.jl`. The adapters run
~150 lines each — larger than the ~40 of the idempotence-only era, because
the contract itself grew a normalization pass and two ledgers. Anything
beyond that is the contract leaking into the adapter: push it back here.

## Adding a fixture

1. Add the `.esm` file under `tests/` in an appropriate category
   subdirectory.
2. Append an entry to `round_trip/manifest.json`. Keep `id` unique.
3. Verify every binding still passes. A fixture that one binding cannot
   round-trip is a legitimate bug — file a bead, don't remove the fixture,
   and don't reach for `load_transforms` unless you can cite the clause
   that REQUIRES the rewrite.
