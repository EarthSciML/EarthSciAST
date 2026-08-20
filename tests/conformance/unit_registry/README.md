# Unit-registry conformance (`tests/conformance/unit_registry/`)

Cross-binding conformance for **esm-spec §4.8**, asserted at the level a
document actually meets it: **one unit string at a time**.

## Why this set exists

Every other units fixture in the corpus is a `.esm` document, so it can only pin
the verdict a whole FILE gets. That is enough to catch a binding that rejects a
good file, and not enough to catch three things that bit us in one week:

1. **A missing registry entry is indistinguishable from a wrong document.**
   `isrm.esm` declared `ton/yr` on the FF10 `ANN_VALUE` column — which is what
   that column really holds. Julia's `load()` accepted the file, Python's
   rejected it, and both were behaving as designed: the unit TABLE agreed (all
   five bindings refuse `ton`), what differed was which entry point enforces it.
   The document was right that the column is short tons and wrong that `ton` is
   a unit. The fix was to give the registry `short_ton` — and to make that
   addition visible as a *pinned* fact rather than five independent edits.

2. **A scale error is invisible to dimensional analysis.** `short_ton` and
   `tonne` have the same dimension. So do a 365-day year and a Julian one. A
   dimension-only check passes a binding that defines the short ton as 1000 kg
   and mis-scales every US emissions inventory by 10%. Pinning scales here found
   a live one immediately: **Rust's `yr` was 3.1536e7 s (365 days) while Julia,
   Python, Go and TypeScript all carried 31557600 s (365.25 days)** — 0.0685%,
   in every `yr`-denominated conversion, invisible to every existing test.

3. **A rejection is a contract too.** A valid-only fixture cannot express "and
   `ton` must NOT resolve". A binding that quietly adds `ton` has not added a
   synonym; it has made a document mean three different masses depending on who
   reads it.

## The golden

`golden/unit_verdicts.json`, three lists:

| List | Contract |
|---|---|
| `accept` | The string MUST resolve; its DIMENSION must equal the binding's own result for `canonical`; and when `scale_to_canonical` is non-null, converting 1 `units` to `canonical` must give that factor within a 1e-12 relative tolerance. |
| `reject` | The string MUST NOT resolve. Severity of the resulting finding is §4.8.4's; this file pins only that it does not resolve. |
| `reject_scaling_factor` | MUST NOT resolve, **and** the diagnostic must contain `scaling factor`. |

`scale_to_canonical` is `null` exactly for the affine units. §4.8.1 deliberately
does not model the offset, so their pure multiplicative factor is not a
physically meaningful conversion and asserting one would be asserting on an
artefact of the representation.

`reject_scaling_factor` is the only place in the corpus where a unit-parser
*message* is pinned, and it has a specific reason. Every other rejection is
guessable from the string: `not_a_unit` is not a unit, `cm3` should be `cm^3`.
`(m/s)^-1/3` is not guessable — it LOOKS like a rational exponent, and §4.8.2
reads it as `((m/s)^-1) / 3`. Before this rule four bindings accepted it and gave
it **three different meanings** (Julia dropped the 1/3, Rust/Go/TypeScript
retained it, Python rejected the string), and two of those differ only in scale,
which nothing downstream can see. The author has to be told *which* mistake they
made, so the message is part of the contract.

## Adapters

| Binding | File |
|---|---|
| Julia | `pkg/EarthSciAST.jl/test/unit_registry_conformance_test.jl` |
| Python | `pkg/earthsci-ast-py/tests/test_unit_registry_conformance.py` |
| Rust | `pkg/earthsci-ast-rs/tests/unit_registry_conformance.rs` |

Go and TypeScript are `scope_excluded` in the manifest: both carry the same
table and assert it in their own unit tests, but neither has an adapter yet.

The document-level halves of the same contract are
`tests/valid/units_inventory_registry.esm` (the FF10 units resolve, with their
exact scales) and `tests/invalid/units_discriminator_scaling_factor.esm` (a
scaling factor is a hard `unit_parse_error`) — those go through the ordinary
`scripts/compare-conformance-outputs.py` agreement check, which is what pins
that all five bindings reach the same verdict on the same FILE.

## Known divergences this file deliberately does not pin

Listed in `manifest.json` under `known_divergences_not_pinned_here`, so that a
green run here is not misread as "the five unit implementations agree". The
largest is that **Rust still has an SI-prefix mechanism** (`parse_si_prefixed`),
which §4.8.1 says a binding MUST disable or gate on the table — so Rust resolves
`Tm`, `dam`, `dg`, `PW`, `fs`, which every other binding rejects. Those strings
are absent from `reject` for that reason, and the divergence is its own fix.
