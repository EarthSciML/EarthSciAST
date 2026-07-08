# Shared Conformance Harness

Single source of truth for cross-binding conformance tests. Each binding
(Julia, Python, Rust, TypeScript, Go) provides a thin adapter that loads a
manifest, runs its implementation against the listed fixtures, and asserts
a standardized contract. This replaces the ad-hoc per-binding duplication
where each language reinvented the same round-trip / validation / flatten
checks against overlapping but inconsistent fixture sets (see gt-tvz).

## Status

**Phase 1 (gt-tvz)** — proof of concept: round-trip category only, Julia
binding ported. Existing per-binding round-trip tests are **not** deleted;
they remain in place until the harness has caught a real regression (per
the scope limits in gt-tvz). Subsequent phases port Rust, Python, Go,
TypeScript, then expand to `validation`, `flatten`, `display`.

## Directory layout

```
tests/conformance/
├── README.md                       # this file — the adapter contract
└── round_trip/
    └── manifest.json               # canonical list of fixtures to round-trip
```

The fixtures themselves live in the existing corpus (`tests/valid/`,
`tests/fixtures/arrayop/`, etc.). Manifests reference fixtures by path
relative to the repository's `tests/` directory.

## Round-trip contract

The round-trip harness enforces **serializer idempotence**: once a fixture
has been parsed and re-serialized once (canonicalizing it through the
binding), every subsequent load/save cycle MUST produce byte-for-byte
identical JSON after normalization.

Given a fixture `F`, each binding adapter MUST implement:

```
first_json  = save(load(F))           # canonical form after one pass
second_json = save(load(first_json))  # second pass

# Parse both as JSON and deep-compare the resulting values.
assert json_parse(first_json) == json_parse(second_json)
```

This is **stronger** than structural equality on the in-memory model
(which bindings implement differently) and **weaker** than
byte-identity with the original file (which would forbid any
normalization — e.g., reordering map keys, canonicalizing whitespace).
It is the same invariant every mature serialization format relies on.

### What the contract does NOT require

- The serializer output does not have to equal the input file byte-for-byte.
- Optional / default-valued fields may be omitted on re-emit.
- Map ordering is free — comparison is on parsed JSON values, not strings.

### What the contract DOES require

- Required fields survive the round-trip.
- Semantic content (variable names, equation structure, species, reactions,
  metadata) is not silently dropped.
- The serializer is deterministic: same input model → same JSON output.

## Manifest schema

`round_trip/manifest.json`:

```json
{
  "category": "round_trip",
  "version": "1.0",
  "description": "…",
  "fixtures": [
    {
      "id": "valid/minimal_chemistry",
      "path": "valid/minimal_chemistry.esm",
      "tags": ["core", "reactions"]
    }
  ]
}
```

Fields:

- `id` — stable identifier used in test output. Slash-separated, no extension.
- `path` — path relative to the `tests/` directory.
- `tags` — free-form labels for filtering (e.g., `core`, `events`,
  `arrayop`). Bindings MAY skip fixtures by tag if they do not yet
  implement a feature; they MUST NOT silently pass on a skipped fixture.

## Adapter contract (per binding)

Each binding's test suite MUST provide an adapter that:

1. **Locates the manifest** — relative to the repository root, without
   hardcoding absolute paths. The adapter should fail loudly if the
   manifest is not found.
2. **Resolves fixture paths** — relative to `tests/`.
3. **Runs each fixture** through the contract above (`save(load(save(load(F))))`
   idempotence).
4. **Reports per-fixture pass/fail** using the binding's native test
   framework (so failures surface in CI). Use the fixture `id` as the
   test case label.
5. **Skips by tag when justified** — if a binding cannot yet handle a
   tag, document the skip in-code and open a bead for the gap.

Reference implementation: see
`pkg/EarthSciAST.jl/test/conformance_round_trip_test.jl`.
The Julia adapter is ~40 lines; any binding's adapter should be of
comparable size. If an adapter grows beyond ~100 lines, the contract
is probably being pushed into the adapter rather than the harness —
push it back into this document instead.

## Adding a fixture

1. Add the `.esm` file under `tests/` in an appropriate category
   subdirectory.
2. Append an entry to `round_trip/manifest.json`. Keep `id` unique.
3. Verify every ported binding still passes. A fixture that one binding
   cannot round-trip is a legitimate bug — file a bead, don't remove
   the fixture.

## Deleting per-binding duplicates

Per gt-tvz scope limits, do NOT delete existing per-binding round-trip
tests until the harness has caught at least one real regression across
two bindings. Once that bar is met, a follow-up bead should remove the
duplication.
