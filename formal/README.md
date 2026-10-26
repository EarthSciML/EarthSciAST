# `formal/` — a Lean 4 model of the ESM specification

This directory holds one Lean model of `esm-spec.md` and `CONFORMANCE_SPEC.md`,
written clause by clause from the spec text, **not** from any binding's source.
It serves two purposes:

1. **Proofs.** Claims the spec makes (rewriting is deterministic, the units
   checker is sound, an empty `min_sum` reduction is `+∞`, …) are stated as
   Lean theorems about the model and proven, or refuted with a counterexample.
2. **A reference participant.** The model is executable. The `esm-lean`
   adapter reads the same fixture JSON the bindings read and emits the same
   result JSON, so the conformance runners can score every binding against a
   reference that is not one of the bindings.

## Layout

| Path | Contents |
|---|---|
| `lean-toolchain`, `lakefile.toml` | Pinned Lean toolchain and Mathlib version |
| `Esm/` | The model, one module per spec area |
| `Adapter/Main.lean` | The `esm-lean` executable used by the conformance runners |
| `inventory/*.json` | Every normative (`MUST`) clause of the two spec files, classified |
| `properties/*.json` | The property registry, one file per spec area: what is claimed about which clauses, and its status (`properties.json` lists verified checkers) |
| `QUESTIONS.md` | Spec ambiguities awaiting a ruling, and the rulings once made |
| `../scripts/formal-audit.py` | The audit gate |

## Building locally

The toolchain and Mathlib cache are large. On the cluster, keep them on
`/projects` or `/scratch` — never `/` or `/tmp`, which are RAM-backed:

```bash
export ELAN_HOME=/projects/illinois/eng/cee/ctessum/ctessum/libs/elan
export PATH=$ELAN_HOME/bin:$PATH
cd formal
lake exe cache get   # prebuilt Mathlib; never build Mathlib from source
lake build
python3 ../scripts/formal-audit.py all
```

## Rules

- **Properties quantify.** A statement about fixed inputs is a test, not a
  theorem. The audit rejects a `lean_statement` with no quantifier unless the
  entry carries `closed_ok` with a reason.
- **Statements are never edited to make them pass.** If the spec changes, the
  old property is retired (with a pointer to the ruling) and a new one added.
  A fix turns a refuted property into a proven one with its statement unchanged.
- **A refutation needs a reproducer**: a fixture under `tests/` showing the
  behaviour in at least one binding, or a `QUESTIONS.md` entry showing the spec
  admits it. A Lean counterexample with neither is presumed to be a model bug.
- **When the model disagrees with every binding, the model is suspect first.**
- **No escape hatches.** `sorry`, `admit`, `native_decide`, new `axiom`
  declarations and kernel-check skipping are rejected everywhere except in a
  registered verified checker (`verified_checkers` in `properties.json`), and
  a theorem may depend only on `propext`, `Classical.choice` and `Quot.sound`.
- **Every batch of proofs gets a hollow-proof review** by someone who did not
  write it: a statement that assumes its conclusion, or holds vacuously because
  its hypotheses cannot all be true, passes every automated check.

## The clause inventory (`inventory/*.json`)

Every occurrence of `MUST` (including `MUST NOT`) in `esm-spec.md` and
`CONFORMANCE_SPEC.md` is covered by exactly one clause entry's quote (a clause
whose quote contains several `MUST`s covers them all). One file per chunk of
one spec file:

```json
{
  "source": "esm-spec.md",
  "clauses": [
    {
      "id": "spec.4.2.minmax-arity",
      "section": "4.2",
      "quote": "Conforming bindings MUST reject `min`/`max` nodes with fewer than two arguments.",
      "class": "semantic",
      "phase": 2,
      "area": "scalar",
      "note": "A min/max node with fewer than two arguments is rejected at load."
    }
  ]
}
```

| Field | Meaning |
|---|---|
| `id` | `spec.<section>.<slug>` for `esm-spec.md`, `conf.<section>.<slug>` for `CONFORMANCE_SPEC.md`. Lower case; the slug names the requirement. Unique across all files. |
| `section` | The number of the nearest numbered heading above the quote (`4.2`, `9.6.3`, `7.3a`). Un-numbered sub-headings belong to the numbered section that contains them. |
| `quote` | Verbatim text from the spec containing the `MUST`, long enough to occur exactly once in the file. Line breaks and runs of spaces are ignored when matching, so a quote may be copied across a hard wrap. |
| `class` | `semantic`, `later` or `out_of_scope` (below). |
| `phase` | For `semantic` and `later`: the plan phase that formalizes it (below). Omit for `out_of_scope`. |
| `area` | One of the areas listed in `scripts/formal-audit.py` (`AREAS`). |
| `note` | One line. For `semantic`/`later`: the property it becomes, in plain words. For `out_of_scope`: why. |
| `concern` | Optional. Set it when the clause is ambiguous, contradicts another clause, cannot be stated precisely as written, or relies on a fact that seems false. Say exactly what is wrong. Each concern becomes a `QUESTIONS.md` entry. |
| `blocked_by` | Optional, `Q-n`. Set only when the citation itself cannot pass the audit because the spec document is defective (a section number used twice, say). The audit then reports the failure as a known spec defect instead of an error. Once the spec is fixed the citation passes, and the audit fails on the stale `blocked_by` until it is removed and the ruling recorded, so the question is closed in the same change that fixes it. |

### Classes

- **`semantic`** — the clause constrains something the model computes in its
  assigned phase: the value of an expression, an accept/reject verdict and its
  diagnostic code, the output of a structural transform (canonicalization,
  rewriting, flattening, ordering of emitted sets), or an exact constant.
- **`later`** — formalizable in principle, but it depends on something the plan
  does not model in phases 0–7, such as runtime event handling or an
  integrator's trajectory. Give the nearest phase.
- **`out_of_scope`** — not a property of the format's semantics: file I/O and
  data access, performance and memory, API shape and naming in a binding,
  review or authoring policy ("reviewers MUST reject…"), or the mechanics of the
  conformance harness itself.

### Phases

| Phase | Scope |
|---|---|
| 0 | Infrastructure (no clauses are assigned here) |
| 1 | Closed function registry (§9.2–9.5) and the unit registry table (§4.8.1) |
| 2 | Scalar expression evaluation (§4.1–4.2), parsing, canonical form, round-trip, the units checker (§4.8.2+), the determinism contract and semiring registry (CONFORMANCE §5.5–5.6), diagnostics for these |
| 3 | Arrays, `faq`, `makearray`, broadcasting, gathers (§4.3 and the array sections of CONFORMANCE §5) |
| 4 | Rewrite rules, templates, imports, metaparameters, discretization rules (§9.6–9.7) |
| 5 | Reaction systems, flattening, coupling, name resolution, subsystem inclusion, events, domain/ICs (§4.4–4.7, §4.9, §5, §7, §10, §11) |
| 6 | Simulation against manufactured or exact solutions (the PDE-simulation and solver tiers) |
| 7 | Compiled backends, precision, anything beyond the spec core |

## The property registry (`properties/*.json`)

```json
{
  "verified_checkers": [],
  "properties": [
    {
      "id": "P-closed-searchsorted-least-index",
      "clauses": ["spec.9.2.searchsorted-semantics"],
      "statement": "searchsorted returns the least index i with xs[i] ≥ x, or N+1.",
      "lean_statement": "∀ (xs : Array Float) (x : Float), ...",
      "status": "proven",
      "theorem": "Esm.Closed.searchsorted_least"
    }
  ]
}
```

`status` is `open`, `proven`, `refuted` (with `reproducer`: a repo path or a
`QUESTIONS.md` anchor) or `question` (with `question`: a `QUESTIONS.md` anchor
`Q-n`). For `proven`, the audit elaborates `example : <lean_statement> :=
@<theorem>`; for `refuted`, `example : ¬ (<lean_statement>) := @<theorem>`.
