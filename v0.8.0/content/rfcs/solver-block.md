---
title: "A top-level `solver` block: numerics the document knows about itself"
description: "An optional, top-level, purely advisory `solver` block carrying stiffness, integration tolerances, and a splitting hint — facts about the model that every binding independently needs and none can derive cheaply. Advisory governs the mechanism, never the outcome: a binding that ignores every field and still converges conforms; one that ignores them and hangs does not. Not an algorithm name, not a compile knob, not part of the flattened IR."
---

Status: implemented (esm 1.1.0)
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
and round-trips it unchanged — and, unchanged by this proposal, that it
integrates the document successfully and agrees with the other bindings within
the CONFORMANCE_SPEC §5.9 error band. Advisory governs *how* a binding gets the
right answer, never *whether* it has to.

Rust has a second, independent stake in this. `rust-diffsol-solver-guard-gap.md`
records 33 conformance cases where `earthsci-ast-rs` **hangs indefinitely** —
one solve observed stuck for over 2.5 hours — on exactly the stiff / non-smooth
right-hand sides this field describes, with no fail-fast guard. `stiffness:
"high"` gives that binding a documented basis for selecting an implicit method,
or for refusing fast instead of hanging.

## Decisions of record

Eight questions were open. Seven were ruled by the maintainer. The eighth was
decided here, got it wrong, and is recorded in its corrected form — the error
was treating integration tolerance and assertion tolerance as the same
quantity.

| # | Question | Decision | Why |
|---|---|---|---|
| 1 | Placement | **Top-level only** | Matches §9's flatten-to-a-single-solver-object model, opens exactly one sealed container, and covers the motivating case. A per-component block with a §6.6.4-style resolution order stays available as a later additive change; nothing here forecloses it. |
| 2 | Advisory or normative | **Fully advisory** | Every field is a MAY. Keeps the block from becoming the portability hazard a literal algorithm name would be. Advisory applies to the *mechanism*, never to the outcome — see *What "advisory" does and does not mean*. |
| 3 | `splitting` semantics | **Advisory hint, no prescribed substep structure** | The document declares that its system tolerates or benefits from operator splitting. It does not prescribe how a binding splits, and it does not amend §9. |
| 4 | Delivery | **Spec + schema + all five bindings + conformance** | A field no binding reads is decoration. |
| 5 | Tolerance spelling | **`abstol` / `reltol`, flat numbers** | Exactly the `solve()` keyword names (API_SPEC §4), so `solver.abstol` → `solve(abstol=)` is a literal pass-through. Deliberately *not* the `tolerance: {abs, rel}` object, which is assertion-comparison tolerance (§6.6.4) — a different quantity that must not be confused with integration accuracy. API_SPEC §189–190 already rejected scipy's `atol`/`rtol` for the API surface; the document follows the API. |
| 6 | Version gating | **Bump to 1.1.0; reject `solver` under a lower declared version with `solver_version_too_old`** | Follows the `template_import_version_too_old` precedent exactly. Minor bump because the change is purely additive. |
| 7 | Precedence | **Caller > document > binding default** | An explicit `solve(prob, abstol=…)` always wins; the document's value replaces the binding's built-in default (`reltol 1e-4` / `abstol 1e-6`, API_SPEC §5.8). Mirrors §6.6.4's most-specific-first order and keeps `solve()`'s signature meaningful. |
| 8 | Inline-test runner tolerances | **The order applies uniformly: the runner's `DEFAULT_TEST_RELTOL` / `DEFAULT_TEST_ABSTOL` are *binding defaults*, so the document wins over them** | Integration tolerance and assertion tolerance are separate quantities, and conflating them was an error in an earlier draft of this document. `DEFAULT_TEST_RELTOL` is handed to the *solver*; what an assertion is compared at is the document's own `tolerance: {abs, rel}` (§6.6.4). Loosening integration accuracy therefore makes an assertion *more* likely to fail, not less — there is no pass-manufacturing hazard to defend against, and the field that could manufacture a pass is `tolerance`, which the author already controls. Letting the document win is also the better outcome for agreement: every binding then integrates at the same tolerance instead of at five different runner defaults. |

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

**The block is closed** (`additionalProperties: false`) but does **not** carry
`minProperties: 1`. An empty `solver: {}` is legal and NORMALIZES to absence at
load.

This went the other way first, on the argument that `{}` and absence are two
spellings of one state and the format keeps a unique representation per state —
the reasoning that makes a one-element `ParameterUpdate` array invalid. Checking
the schema settled it against that: `solver` would have been the **only**
optional top-level container rejecting an empty object. `coordinates`,
`index_sets`, `metaparameters` and `coupling_roles` all admit one, and
`coordinates` is the block §2.2 is modelled on. A lone exception is a rule a
reader has to learn for no gain, and a trap for any tool assembling the block
from optional inputs that all happened to be absent. (The one other
`minProperties` in the schema, on `EnumDeclaration`, is a different case: a
*named* enum declaring no members is broken, where an unnamed singleton block
declaring nothing is merely redundant.)

The cost is one normalization, and it must be applied **at load** rather than
left to the emitters — otherwise the bindings disagree. `omitempty` on Go's
pointer field tests nil, not emptiness; Rust's `skip_serializing_if` is
per-field, so an empty `Solver` still emits its enclosing `{}`; TypeScript
serializes the whole document object. All three would have round-tripped `{}`
verbatim while Python and Julia dropped it. Normalizing at load means the typed
document never holds a block with nothing set, in any binding.

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

**Advisory (MAY).** A conforming binding may ignore any or every field, and
may reach a conforming result by any route. Two bindings may therefore differ
in the integrator they select and in the last bits of the trajectory — but not
in whether they integrate, nor by more than the §5.9 band. See *What "advisory"
does and does not mean*.

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

1. An explicit argument at the `solve()` call site.
2. Otherwise, the document's `solver.abstol` / `solver.reltol`.
3. Otherwise, the binding default (`reltol 1e-4`, `abstol 1e-6`).

## What "advisory" does and does not mean

Advisory governs the **mechanism**, never the **outcome**.

A binding is free to reach the right answer by any route: its default
integrator, its own stiffness detection, or by reading `stiffness` and
selecting an implicit method. A binding that ignores every field in the block
and still converges is fully conforming. What no binding is free to do is
**fail** — hang, overflow, or return a trajectory outside the agreement band.

That requirement is not created, weakened, or qualified by this block. It is
CONFORMANCE_SPEC §5.9, which already governs simulation output: numeric
tolerance rather than byte-identity, an explicitly stated rel/abs band, and a
gate that fails loudly on any divergence beyond it. §5.9 is exactly the
"error tolerance, separate from the solver tolerance" that the outcome is
judged against, and it long predates this proposal.

So the block adds information that helps a binding choose a method that
converges. It does not hand any binding an excuse for not converging. A
stiff conformance fixture therefore **gates** like any other simulation
fixture: ignoring `stiffness: "high"` is permitted, and failing POLLU is not.
The two statements are consistent precisely because the hint is about how a
binding gets there, not about whether it has to arrive.

One interaction worth noting for the implementer. §5.9.2 pins each binding's
integrator and step controls per binding in `manifest.json` (`integrators`) so
the comparison stays apples-to-apples. A document-level `stiffness` declaration
is the same fact stated one level up, in the document rather than in the
harness — which is the whole point of the issue. Whether a stiff fixture's
manifest entry should defer to the document, or keep pinning per binding for
reproducibility, is a decision for the fixture work in §5 below, not for the
schema.

## Work breakdown

### 1. Spec — `esm-spec.md`

- New **§2.2 Solver hints (`solver`)**, immediately after §2.1 (`coordinates`),
  which is the established precedent for a top-level, optional, purely
  additive registry that changes no dynamics. §2.2 carries the field table,
  the advisory/normative split, the resolution order, the non-goals, and the
  consequences paragraph above.
- §2 top-level JSON sketch and field table: add the `solver` row.
- §6.6.4: a cross-reference stating that assertion-comparison `tolerance` and
  integration `abstol`/`reltol` are separate quantities that resolve
  independently — the confusion the two spellings exist to prevent.
- Diagnostics table: `solver_version_too_old`.

### 2. Schema — `esm-schema.json`

- New `$defs.Solver`: closed (no `minProperties` — an empty block normalizes
  to absence at load), the four fields, enums on
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
| **Julia** | `src/types.jl` struct; `src/error_codes.jl` gains `SOLVER_VERSION_TOO_OLD`; `src/simulate.jl` applies the resolution order in `solve`; `src/run_tests.jl`'s `DEFAULT_TEST_*` become defaults the document can displace. |
| **Python** | `solve()` applies the order; `DEFAULT_TEST_RELTOL` / `DEFAULT_TEST_ABSTOL` in the inline-test runner become defaults the document can displace. This is the binding whose downstream basename table the block is meant to retire. |
| **Rust** | `src/diagnostic.rs`; `src/simulate.rs` applies the order and MAY consult `stiffness` — see the diffsol guard gap above. |
| **TypeScript** | Types and validation only; no `solve`. Regenerated artifacts must match. |
| **Go** | Types, validation, gate; no `solve`. |

### 5. Conformance and fixtures

- `tests/valid/solver_block.esm` — all four fields, `esm: "1.1.0"`.
- `tests/invalid/` — one fixture each: unknown enum member, unknown key inside
  the block, non-positive `abstol`, and `solver` declared under `esm: "1.0.0"`
  (→ `solver_version_too_old`). There is deliberately no empty-block fixture:
  `{}` is legal and normalizes to absence.
- Round-trip fixture proving the block emits verbatim.
- A stiff, POLLU-shaped fixture under `tests/conformance/`, **gating** under
  the §5.9 numeric-tolerance contract, anchored on the published reference
  (`O3@3600 = 5.523140`). Every executing binding must integrate it and land
  inside the band. How each gets there is its own business — default
  integrator, its own stiffness detection, or by reading `stiffness: "high"`.
  Two sub-tasks the fixture work must settle: whether the fixture's
  `manifest.json` `integrators` entry defers to the document or keeps pinning
  per binding (§5.9.2), and whether Rust can clear the gate at all today given
  `rust-diffsol-solver-guard-gap.md` — if it cannot, that is a Rust bug the
  fixture exposes, not a reason to downgrade the fixture.
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
