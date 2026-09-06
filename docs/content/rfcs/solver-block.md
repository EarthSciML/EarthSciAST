---
title: "A top-level `solver` block: numerics the document knows about itself"
description: "An optional, top-level, purely advisory `solver` block carrying stiffness, integration tolerances, and a splitting hint — facts about the model that every binding independently needs and none can derive cheaply. Advisory by construction: a binding that ignores every field still conforms. Not an algorithm name, not a compile knob, not part of the flattened IR."
---

Status: scoped (implementation not started)
Target format version: 1.1.0 (additive; gated with `solver_version_too_old`)
Issue: [EarthSciML/EarthSciAST#187](https://github.com/EarthSciML/EarthSciAST/issues/187)

## Summary

A `.esm` document cannot currently say anything about how it must be
integrated. The motivating case is `components/gaschem/pollu.esm` in
EarthSciModels — the Verwer (1994) POLLU stiff-ODE benchmark, rate constants
spanning ~`8e-7` to ~`7e9` 1/s. scipy's LSODA cannot integrate it at all; BDF
does the full 3600 s in ~0.2 s and reproduces the published reference. That is
a property of the model, true in Julia and Rust as well — but because the
document cannot state it, the knowledge lives downstream as a basename lookup
table in one binding's test harness:

```python
# EarthSciModels tools/run_esm_inline_tests.py
SOLVER_METHOD_OVERRIDE_FILENAMES: Dict[str, str] = {"pollu.esm": "BDF"}
```

Every other binding and every downstream consumer will rediscover the same fact
the same way — as a hang or a Fortran overflow — and build its own table. This
adds one optional top-level block so the fact is stated once, in the document,
portably:

```json
{
  "esm": "1.1.0",
  "metadata": { "…": "…" },
  "solver": {
    "stiffness": "high",
    "abstol": 1e-8,
    "reltol": 1e-6,
    "splitting": "strang"
  },
  "reaction_systems": { "Pollu": { "…": "…" } }
}
```

Every field is optional, the block itself is optional, and **every field is
advisory**: a binding that reads the block and does nothing with it is
conforming. What is normative is that every binding parses it, validates it,
and round-trips it unchanged.

Rust has a second, independent stake in this. `rust-diffsol-solver-guard-gap.md`
records 33 conformance cases where `earthsci-ast-rs` **hangs indefinitely** —
one solve observed stuck for over 2.5 hours — on exactly the stiff / non-smooth
right-hand sides this field describes, with no fail-fast guard. `stiffness:
"high"` gives that binding a documented basis for selecting an implicit method,
or for refusing fast instead of hanging.

## Decisions of record

Eight questions were open. Seven were ruled by the maintainer; the eighth is
noted below as decided here, and is the one most worth a second look in review.

| # | Question | Decision | Why |
|---|---|---|---|
| 1 | Placement | **Top-level only** | Matches §9's flatten-to-a-single-solver-object model, opens exactly one sealed container, and covers the motivating case. A per-component block with a §6.6.4-style resolution order stays available as a later additive change; nothing here forecloses it. |
| 2 | Advisory or normative | **Fully advisory** | Every field is a MAY. Keeps the block from becoming the portability hazard a literal algorithm name would be. Cost is stated plainly under *Consequences* below. |
| 3 | `splitting` semantics | **Advisory hint, no prescribed substep structure** | The document declares that its system tolerates or benefits from operator splitting. It does not prescribe how a binding splits, and it does not amend §9. |
| 4 | Delivery | **Spec + schema + all five bindings + conformance** | A field no binding reads is decoration. |
| 5 | Tolerance spelling | **`abstol` / `reltol`, flat numbers** | Exactly the `solve()` keyword names (API_SPEC §4), so `solver.abstol` → `solve(abstol=)` is a literal pass-through. Deliberately *not* the `tolerance: {abs, rel}` object, which is assertion-comparison tolerance (§6.6.4) — a different quantity that must not be confused with integration accuracy. API_SPEC §189–190 already rejected scipy's `atol`/`rtol` for the API surface; the document follows the API. |
| 6 | Version gating | **Bump to 1.1.0; reject `solver` under a lower declared version with `solver_version_too_old`** | Follows the `template_import_version_too_old` precedent exactly. Minor bump because the change is purely additive. |
| 7 | Precedence | **Caller > document > binding default** | An explicit `solve(prob, abstol=…)` always wins; the document's value replaces the binding's built-in default (`reltol 1e-4` / `abstol 1e-6`, API_SPEC §5.8). Mirrors §6.6.4's most-specific-first order and keeps `solve()`'s signature meaningful. |
| 8 | Inline-test runner tolerances | **Runner-pinned tolerances count as *caller*, so they win over `solver.abstol`/`reltol`** — decided here, not by the maintainer | The inline-test runners pin their own tolerances (Python's `DEFAULT_TEST_RELTOL = 1e-10`) precisely to hold cross-binding agreement fixed. If a document's `solver` block could loosen the integration tolerance *underneath its own assertions*, an author could make a failing assertion pass by editing the solver block. `stiffness` and `splitting` are unaffected and do apply during inline tests — which is what the POLLU case actually needs, so this rule costs the motivating case nothing. |

## The block

| Field | Type | Values | Meaning |
|---|---|---|---|
| `stiffness` | string | `"low"` \| `"moderate"` \| `"high"` | The author's declaration of the system's stiffness. A binding MAY select an implicit / BDF-family integrator on `"high"`. |
| `abstol` | number | `> 0` | Absolute integration tolerance the document asks for. |
| `reltol` | number | `> 0` | Relative integration tolerance the document asks for. |
| `splitting` | string | `"none"` \| `"lie"` \| `"strang"` | Advisory: the system tolerates or benefits from this operator-splitting convention. Carries no prescribed substep structure. |

All four optional. The vocabulary for `splitting` is deliberately the same as
the discretization RFC §7.5 dimensional-splitting field — one word, one meaning
across the spec — even though this occurrence is advisory and that one is
executable.

**Absence is not a default value.** A document with no `solver` block, or with
no `stiffness` key, has *not declared* its stiffness. It does not thereby
declare `"low"`. Bindings MUST NOT treat absence as an assertion about the
system.

**The block is closed** (`additionalProperties: false`) and carries
`minProperties: 1`. An empty `solver: {}` would be a second spelling of
absence, and the format's convention is that any given state has a unique
representation — the same reasoning that makes a one-element `ParameterUpdate`
array invalid. *This is the one schema detail worth a second opinion in review:*
the alternative (allow `{}`) costs one invalid fixture but removes an
easy-to-hit authoring error.

## What the block is not for

Stated up front, because a container named `solver` invites accretion:

- **Not algorithm names.** `"BDF"` and `"LSODA"` are scipy identifiers; Julia
  wants `Rosenbrock23`. A document carrying one would not be portable. The
  spec is right to have no `alg` field and this does not add one.
- **Not binding-specific compile knobs.** `cse` is a `sympy.lambdify` concern
  with no meaning outside Python. It belongs in the harness.
- **Not a DAE declaration.** The issue floats one; it is redundant here. Every
  binding already *derives* `system_class` from the equation set, and
  `dae-binding-strategies.md` records what each does with the answer. A
  declared field could only agree with the derivation or contradict it.
- **Not part of the flattened IR.** Flattening (§10.7) does not consume,
  transform, or namespace the block. It is document-level configuration that
  rides alongside the flat system, not an input to building it.

## Semantics, precisely

**Advisory (MAY).** A conforming binding may ignore any or every field. Two
bindings may therefore produce different trajectories for the same document —
see *Consequences*.

**Normative (MUST), and therefore conformance-testable:**

1. Parse and validate the block. An unknown key, an unknown enum member, a
   non-positive tolerance, or a wrong JSON type is a validation failure — that
   is schema conformance, not behavior, and is not excused by the block being
   advisory.
2. Round-trip it **verbatim** through `parse → emit`. `solver` is authored
   configuration, a peer of `tolerance` and `parameter_overrides` — not a
   load-time construct like `expression_template_imports`, which §9.7.6 has
   consumed and discarded by emit time.
3. Reject `solver` in a document declaring `esm` below `1.1.0`, with
   `solver_version_too_old`.
4. Leave the flattened system unchanged. Presence of `solver` MUST NOT alter
   equations, variable classification, or namespacing.

**Resolution order for `abstol` / `reltol`,** most-specific first:

1. An explicit argument at the `solve()` call site — including a tolerance an
   inline-test runner pins for itself (decision 8).
2. Otherwise, the document's `solver.abstol` / `solver.reltol`.
3. Otherwise, the binding default (`reltol 1e-4`, `abstol 1e-6`).

## Consequences of "advisory"

Worth stating rather than discovering: because a binding may ignore
`stiffness`, the conformance suite **cannot** assert that POLLU integrates. It
can assert parse, validate, round-trip, the version gate, and the diagnostics —
nothing about resulting trajectories. Two conforming bindings can legitimately
disagree on the same document, which cuts against the cross-binding-agreement
property the suite exists to protect.

That is the accepted trade: it is what keeps a coarse, portable hint from
hardening into a portability hazard. The spec text will say so explicitly, so
the advisory status is a decision on the record rather than an omission someone
later reads as a bug.

## Work breakdown

### 1. Spec — `esm-spec.md`

- New **§2.2 Solver hints (`solver`)**, immediately after §2.1 (`coordinates`),
  which is the established precedent for a top-level, optional, purely
  additive registry that changes no dynamics. §2.2 carries the field table,
  the advisory/normative split, the resolution order, the non-goals, and the
  consequences paragraph above.
- §2 top-level JSON sketch and field table: add the `solver` row.
- §6.6.4: a cross-reference distinguishing assertion-comparison `tolerance`
  from integration `abstol`/`reltol`, and stating decision 8.
- Diagnostics table: `solver_version_too_old`.

### 2. Schema — `esm-schema.json`

- New `$defs.Solver`: closed, `minProperties: 1`, the four fields, enums on
  `stiffness` and `splitting`, `exclusiveMinimum: 0` on both tolerances.
- `properties.solver` at top level.
- `$id` → `https://earthsciml.org/schemas/esm/1.1.0/esm.schema.json`. Every
  binding derives its schema-version constant from this string, so it is the
  single edit that performs the version bump.
- Propagate to the four vendored copies and regenerate the TypeScript
  artifacts; `scripts/sync-schema.sh` must pass:
  - `pkg/EarthSciAST.jl/data/esm-schema.json`
  - `pkg/earthsci-ast-rs/src/esm-schema.json`
  - `pkg/earthsci-ast-py/src/earthsci_ast/data/esm-schema.json`
  - `pkg/earthsci-ast-go/pkg/esm/esm-schema.json`
  - `pkg/earthsci-ast-ts/src/embedded-schema.ts` (generated), `src/generated.ts`
    (`json2ts`)

### 3. Version bump audit (the one task whose size is not yet known)

`SchemaVersion` / `SCHEMA_VERSION` is derived from the schema `$id` in every
binding — by construction it cannot hand-drift, which makes the bump mostly
mechanical. Two things still need checking rather than assuming:

- The migration path. `migration.go` (and its four siblings) already models an
  **additive line `1.0.0 … <current>`** whose migration is a no-op marker bump,
  so 1.0.0 → 1.1.0 should need no new transform — only confirmation that the
  no-op path is reached and that migration tests, which are written against the
  derived constant rather than a literal, still pass.
- Fixtures pinned against the *current* version rather than their own. The
  known instance is `pkg/EarthSciAST.jl/test/expression_ic_conformance_test.jl`,
  which asserts `file.esm == SCHEMA_VERSION` for a fixture declaring `1.0.0`;
  that assertion breaks on the bump. The audit is to find the rest of that
  class. The ~57 corpus fixtures declaring `esm: "1.0.0"` are *not* affected —
  they remain valid 1.0.0 documents and stay as they are.

### 4. Bindings

Common to all five: a `Solver` type, parse, emit, round-trip, validation, the
version gate, and a public accessor declared in `api-surface.json` (the surface
tests assert the declared surface in both directions, so an undeclared
accessor fails CI).

| Binding | Additional work |
|---|---|
| **Julia** | `src/types.jl` struct; `src/error_codes.jl` gains `SOLVER_VERSION_TOO_OLD`; `src/simulate.jl` applies the resolution order in `solve`; `src/run_tests.jl` follows decision 8. |
| **Python** | `solve()` applies the order; the inline-test runner keeps its pinned `DEFAULT_TEST_RELTOL`. This is the binding whose downstream harness the block is meant to retire. |
| **Rust** | `src/diagnostic.rs`; `src/simulate.rs` applies the order and MAY consult `stiffness` — see the diffsol guard gap above. |
| **TypeScript** | Types and validation only; no `solve`. Regenerated artifacts must match. |
| **Go** | Types, validation, gate; no `solve`. |

### 5. Conformance and fixtures

- `tests/valid/solver_block.esm` — all four fields, `esm: "1.1.0"`.
- `tests/invalid/` — one fixture each: unknown enum member, unknown key inside
  the block, non-positive `abstol`, empty `solver: {}`, and `solver` declared
  under `esm: "1.0.0"` (→ `solver_version_too_old`).
- Round-trip fixture proving the block emits verbatim.
- A stiff, POLLU-shaped fixture under `tests/conformance/`, **informative**:
  it pins the intended reading of `stiffness: "high"` and is a place for a
  binding to demonstrate it acts on the hint. It cannot gate, because the
  field is advisory (see *Consequences*).
- `tests/COVERAGE_MATRIX.md` and `CONFORMANCE_SPEC.md` updated for the new
  category.

### 6. Docs

- `MIGRATION.md`: a `new`-kind row (pure addition, nothing to migrate) plus a
  `format`-kind row for the 1.1.0 bump.
- This RFC's status → accepted on merge.

## Deferred, deliberately

Each of these is additive later and is not foreclosed by anything above:

- **Per-component `solver`** on `Model` / `ReactionSystem`, with a §6.6.4-style
  resolution order — the honest shape for an assembly that mounts stiff
  chemistry beside non-stiff advection. Deferred because it opens two more
  sealed containers and forces a merge rule (does a stiff subsystem make the
  assembly stiff?) that no document yet needs answered.
- **Per-`Test` override**, letting one assertion integrate differently.
- **Executable splitting** — a real substep structure across coupled
  components. This would amend §9's single-flat-system model and needs its own
  design; it is not a solver knob.
- **A numeric stiffness ratio** in place of, or alongside, the coarse enum.
