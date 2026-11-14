# Format gap — §5.5.3.1 does not reach the document `save()` path; five bindings disagree on integral typed float fields

**Status:** Ruled — Option A adopted (see *The ruling*). Spec amendment and four binding changes owed.
**Component:** `CONFORMANCE_SPEC.md` §5.5.3 / §5.5.3.1, and every binding's document serializer
**Severity:** latent. No test in the repo currently fails. Nothing is known to have corrupted a
document — but the divergence is real, unpinned, and undetected by construction.

## Symptom

A JSON number whose value is integral round-trips with a different *spelling* depending on which
binding wrote it, and the spelling depends on which struct field it sits in. Given a fixture that
spells `"stoichiometry": 1`, a load-then-save cycle emits `1` in Julia, Python, Go and TypeScript,
and `1.0` in Rust. Given `"start": 0` inside a `time_span`, it emits `0` in Go and TypeScript and
`0.0` in Julia, Python and Rust.

Both spellings parse back to the same value, so nothing breaks today. The problem is that no rule
says which is correct, and the bindings have quietly settled on three different answers.

## What the spec actually says, and where it stops

The canonical-number rule is **§5.5.3.1 of `CONFORMANCE_SPEC.md`** (`:722`), not `esm-spec.md` —
there is no §5.5.3 in the format spec, which has misled at least one prior investigation.

Rule 1 (`CONFORMANCE_SPEC.md:731-738`):

> **Integral-float normalization.** A JSON number whose mathematical value is integral and
> representable in `Int64` serializes as an **integer literal**, regardless of how the source
> document spelled it (`0.0` → `0`, `2.5e1` → `25`). This mirrors JSON3's numeric narrowing on
> parse […] fixtures MUST avoid integral-valued float literals wherever the float-ness is
> semantic — write `1.5`, not `1.0`

Rule 3 extends it to expression operands (`:774-777`), "independent of any binding's JSON-reader
number typing."

The gap is in the **scope sentence** (`:724-729`), which names exactly two byte forms: the compact
index-set serialization of §5.5.3, and the golden-writer form used by the conformance goldens.
Rule 3 adds a third obligation at the AST-literal boundary. **The ordinary document `save()` /
`to_json()` path is named nowhere.**

So on a strict reading, typed struct fields are out of scope and every binding is compliant. On the
spirit of rule 1 — "a property of a number's *value*" — they are in scope and three bindings are
wrong. The text supports both readings, which is why the implementations diverged.

### Not to be confused with the opposite rule

RFC §5.4.6's `canonical_json` expression-equivalence form deliberately **keeps** the trailing `.0`
so `1.0` and `1` stay distinguishable for algebraic canonicalization. Its cross-binding golden pins
this: `tests/conformance/canonical/float_subnormal.json` expects `5e-324,1.0,2.5`. Go documents the
split at `pkg/earthsci-ast-go/pkg/esm/canonical.go:25-27`. Any fix must not touch that path.

## Per-field evidence

| field (wire key) | Julia | Python | Rust | Go | TypeScript |
|---|---|---|---|---|---|
| `stoichiometry` | `1` | `1` | **`1.0`** | `1` | `1` |
| `time_span.start` / `.end` | `0.0` | `0.0` | `0.0` | **`0`** | **`0`** |
| `parameter.default` | `1.0` | `1` (passthrough) | `1.0` | `1` | `1` |
| `variable_map.factor` (`1000000.0`) | **`1.0e6`** | `1000000.0` | `1000000.0` | `1000000` | `1000000` |
| AST literal operands | `1` | `1` | `1` | `1` | `1` |

Expression operands agree in all five — every binding has explicit rule-3 code. The divergence is
confined to typed struct fields, and it is *field-dependent*, not binding-dependent: no binding is
uniformly right.

Where each binding's canonicalization lives:

- **Go — complete and deliberate.** `canonicalFloat64String` (`pkg/esm/canonical.go:28-35`) is
  applied by reflection to every `float64` including struct fields (`:111-116`, `:158+`), driven
  from `serialize.go:15-24`, and pinned by `TestSaveTypedFloatFields`
  (`pkg/esm/canonical_test.go:178-203`), which asserts a field of `2.0` emits `2`. Go is the only
  binding that treats this as a contract. (Its `marshalCanonical` doc comment, `serialize.go:8-14`,
  is stale — it claims §5.4.6 trailing-`.0` semantics, the opposite of what the code does.)
- **TypeScript — implicit, by language.** `toJson` strips numeric literals then calls
  `JSON.stringify` (`src/serialize.ts:76-83`), so integral values print without `.0` for free. The
  `.0`-preserving mode is opt-in and defaults off (`:44-56`).
- **Julia and Python — one field each.** Both have an `_emit_stoich` shim covering stoichiometry
  only (`EarthSciAST.jl/src/serialize.jl:17-22`; `earthsci_ast/serialize.py:64-76`), with the same
  stated rationale: *"so existing integer-only fixtures stay byte-identical through a parse /
  re-emit cycle."* Every other float field is identity-encoded. Julia additionally emits large
  integral floats in Julia syntax (`1.0e6`), which no other binding produces.
- **Rust — none on this path.** Canonical emission exists (`serialize_canonical_f64`,
  `src/types/expression.rs:187-198`; `canon_number`, `src/lower_expression_templates/emit.rs:182-197`)
  but is wired only to `Expr` and to the golden emitter. `to_json` (`src/serialize.rs:37-39`) is
  unconditional derived serde.

## Why no test catches it

Three independent blind spots, all structural:

1. **The cross-binding round-trip gate compares a binding against itself.**
   `tests/conformance/README.md` defines it as `save(load(F))` vs `save(load(save(load(F))))` —
   passes 2 and 3, never against `F`. Reference adapter:
   `EarthSciAST.jl/test/conformance_round_trip_test.jl:59`. Anything a binding normalizes on the
   first pass is normalized identically on the second.
2. **Comparison is on parsed values, not bytes.** The README is explicit: "Map ordering is free —
   comparison is on parsed JSON values, not strings." `1` and `1.0` parse equal.
3. **`scripts/test-conformance.sh` never compares emitted document bytes at all.** Its comparison
   functions (`check_coverage`, `check_outcomes`, `check_pins`, `check_rendering`,
   `check_agreement`) cover valid/invalid outcomes and diagnostic codes only.

The four byte-wise gates that do exist all miss it: the `canonical/*` corpus is §5.4.6 (which wants
`1.0`); the `emitted.esm` goldens route through the writer that already normalizes; the determinism
index sets use the `.0`-preserving formatter; and the property corpus is expression-only and runs
julia/python/typescript only.

## What has been fixed, and what has not

**Fixed (Rust only, narrow, no ruling required):** `StoichiometricEntry.coefficient` now emits an
integer literal, bringing Rust in line with the other four bindings on the one field where all four
already agreed and where two of them carry an explicit shim for the purpose. That was a Rust-only
outlier across 103 corpus occurrences, including `tests/valid/minimal_chemistry.esm:68` — the first
entry of the round-trip manifest. A text-comparing regression test now pins it.

Rust's `tests/round_trip.rs` also carried a doc comment asserting that it compares numbers by value
*because* the crate normalizes integral floats on save — a normalization it did not perform. The
comment has been corrected to state the real reason: several typed float fields still differ in
spelling across bindings pending the ruling below.

**Not yet fixed:** everything else in the table. For `time_span`, `parameter.default` and `factor`
the split is three-to-two with Rust in the *majority*, so no binding could fix these unilaterally —
which is why they waited on the ruling rather than being cleaned up alongside stoichiometry. Under
the ruling below they all resolve the same way, in every binding at once.

## The ruling

**Decided: extend §5.5.3.1 rule 1 to govern the document `save()` path.** Every binding emits an
integral, Int64-representable typed float field as an integer literal. There are no per-field
exceptions and no grandfathering — the rule is a property of a number's value, as rule 3 already
says, and it now holds on every emission path rather than on three of them.

The alternative considered and rejected was declaring `save()` explicitly out of scope. That would
have cost nothing to implement, but it leaves `.esm` documents non-byte-stable across bindings, so
any workflow that diffs a saved document against its source sees spurious churn — and it would have
frozen the cross-binding round-trip gate as value-based permanently.

### What this ruling requires

Spec, first — this is a behavior change to five serializers, so it goes through
`docs/content/SCHEMA_CHANGE_PROCEDURE.md`:

1. **`CONFORMANCE_SPEC.md` §5.5.3.1** — amend the scope sentence (`:724-729`) to name the document
   `save()` / `to_json()` path alongside the compact index-set form and the golden-writer form.
   State explicitly that §5.4.6 `canonical_json` is unaffected and still preserves the trailing
   `.0`, so the two rules are not confused again.

Then, per binding:

2. **Go** — already compliant (`canonicalFloat64String` applied by reflection). Action: none, except
   correcting the stale `marshalCanonical` doc comment (`serialize.go:8-14`), which describes the
   opposite rule. `TestSaveTypedFloatFields` is promoted from a Go-local guarantee to the pin for a
   format requirement.
3. **TypeScript** — already compliant by language default. Action: add an explicit test so the
   guarantee is pinned rather than incidental, since it currently depends on `JSON.stringify`
   behavior nobody has asserted.
4. **Rust** — `StoichiometricEntry.coefficient` is done (see below). Remaining: a general pass over
   the ~30 typed `f64` fields, or a serializer-level normalization equivalent to Go's reflection
   walk. The building block exists — `serialize_canonical_f64` (`src/types/expression.rs:187-198`).
5. **Python** — generalize `_canonical_number` (`serialize.py:86-100`), currently wired only to
   expressions and array descriptors, to cover typed fields; `_emit_stoich` then becomes redundant.
6. **Julia** — the largest change. Every `kind = :float` row in the serializer is identity-encoded
   (`serialize.jl:573-597`), and Julia additionally emits large integral floats in Julia syntax
   (`1.0e6`), which no other binding produces and which the rule forbids. Both need fixing.
7. **Corpus** — regenerate any golden containing `N.0` in a typed field. Scope this by running the
   change against the corpus and diffing, not by grepping: the affected set is whatever actually
   moves.

### What this unblocks

With number spelling removed from the list of legitimate cross-binding differences, the round-trip
conformance gate becomes tightenable — it could compare `save(load(F))` against `F` rather than
against itself, which is the change that would close the silent-field-drop blind spot described
under *Related* below. That is the main reason to prefer this ruling over the cheaper one.

## Related

- The round-trip gate's compare-against-itself shape is a wider problem than numbers — it is blind
  to any field a binding silently drops at load, which is how Julia's missing `analyses` support
  went unnoticed. That is being tracked separately.
- `docs/content/SCHEMA_CHANGE_PROCEDURE.md` governs whichever option is chosen; Option A is a
  behavior change to five serializers and needs the full procedure, Option B is prose only.
