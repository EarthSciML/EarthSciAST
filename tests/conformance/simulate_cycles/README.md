# Simulate-Cycle Conformance Fixtures (esm-sph)

Cross-binding fail-fast contract: models containing cycles in their
algebraic equations MUST be rejected by every binding, not silently
solved with default-valued intermediates. This category sits alongside
`tests/simulation/` (which carries the happy-path conformance fixtures
for the abs / min / max / pow / algebraic-elimination patterns) and
guards the unhappy path that the audit captured under escalation
`hq-wisp-ywi` from polecat nux.

> **The validate-layer counterpart is `observed_cycle`** (esm-spec §4.9.6,
> issue #181). A cycle among a model's *observed* unknowns is a function of the
> equations alone, so from that section on it is a hard **structural** error
> every binding reports from `validate` — before any build — naming the
> observeds on the cycle. The corpus fixture is
> `tests/invalid/observed_cycle_array_elementwise.esm`, pinned in
> `tests/invalid/expected_errors.json`. This category is unchanged and still
> useful: it pins the *build/simulate* half of the contract, which a document
> that skipped `validate` still has to satisfy, and it covers algebraic cycles
> reached through routes the observed graph does not describe.

## Fixture format

Each fixture is a JSON document with shape:

```jsonc
{
  "id": "<short-id>",
  "description": "<human-readable note>",
  "input": { /* an .esm-shaped document */ },
  "expect": {
    "kind": "error",
    "rationale": "<why this must error>",
    "message_must_contain_one_of": ["cycle", "algebraic loop", ...]
  },
  "tags": [...],
  "bindings_required": [...],
  "bindings_optional": [...]
}
```

## Per-binding contract (when picked up)

A binding's runner MUST:

1. Load `input` via the binding's official ESS parser.
2. Invoke the binding's official `discretize()` / `simulate()` /
   `mtkcompile()` equivalent in a way that surfaces structural defects
   (cycles, singular systems, algebraic loops).
3. Assert the call raises a structured error whose message contains at
   least one of the substrings in `message_must_contain_one_of`
   (case-insensitive).
4. A silent success (the call returns and produces numerical output
   without raising) is a test FAILURE — that is the audit-positive
   outcome this category is designed to catch.

## Why landing without runner integration is correct

Per the initial-landing scope of esm-sph, the fixture exists so the
per-binding audits have a single shared input to point at. Each binding
picks this category up by adding a runner; follow-up beads will land
those integrations as the per-binding audit determines current
behavior. The fail-fast contract is a property of the fixture +
manifest; runner integrations enforce it per-binding.
