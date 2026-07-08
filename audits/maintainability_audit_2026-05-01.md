# EarthSciAST — Maintainability Audit

**Date:** 2026-05-01
**Auditor:** polecat chrome (review-only, esm-rv3)
**Scope:** Whole repo, depth-first on load-bearing areas
**Status:** No commits; this report is the deliverable.

Severity legend: **P0** ship-stopper · **P1** high · **P2** medium · **P3** low.
Effort: **S** ≤½ day · **M** ½–2 days · **L** > 2 days.

---

## Executive Summary

The repo is in fundamentally good shape. The single biggest recent win — retirement of
the parallel test-path evaluators (`mms_evaluator` × 5 bindings, `grid_assembly.apply_*!`,
~9.3k LoC; commit `3b6e68db2`, bead `esm-4t5`) — closes the dominant historical
maintainability hazard. Cross-binding parity for the *core* canonical operations
(parse / canonicalize / flatten / discretize / serialize) is high. No deferred or
blocked beads exist as tech-debt overhang.

The remaining issues fall into three buckets:

1. **Residual single-pathway leakage.** Per-binding `expression.{py,jl,ts,rs}::evaluate(expr, bindings)`
   functions still walk the AST in parallel to the official runners. They are not
   per-rule-shape dispatch (so they are not the egregious anti-pattern that `esm-4t5`
   killed), but they are still parallel evaluators that tests and a few
   library callers reach for. They need either (a) explicit "official runner" status
   in AGENTS.md or (b) deletion in favor of the documented runners
   (`numpy_interpreter`, `tree_walk`, `simulate`, `codegen`).
2. **A real gap in cross-binding parity:** the Rust binding lacks `lower_enums`
   entirely, and the TS `serialize.ts` is an 18-line `JSON.stringify` wrapper.
3. **Conformance harness asymmetry.** The shared harness drives 5 categories
   across 4 bindings; Go does not produce conformance-output for cross-binding
   diffing, and 6 well-populated fixture categories (graphs, mathematical_correctness,
   scoping, spatial, serialization, version_compatibility) are not exercised by
   the harness at all.

---

## 1. Single-Pathway-Rule Compliance (TOP PRIORITY)

The parent rule (rig `AGENTS.md` lines 39-90) is now mostly enforced. The legacy
file inventory from `esm-4t5` (mms_evaluator.jl, mms_evaluator.py, mms_evaluator.rs,
stencil-evaluator.ts, walker_ghost_fill.go, plus grid_assembly imperative kernels)
is gone — verified by direct `ls`. No `if rule.kind == "flux_1d_ppm"` style
dispatch remains in any runner.

### Findings

| # | Sev | File:Line | Finding | Remediation | Effort |
|---|---|---|---|---|---|
| 1.1 | **P1** | `pkg/earthsci-ast-py/src/earthsci_ast/expression.py:118` | `evaluate(expr, bindings) -> float`: 200-line generic AST walker that dispatches on `expr.op` (`+`, `*`, `^`, `fn`, `const`, …). Walks the same canonical AST `numpy_interpreter` walks but is a separate codepath. AGENTS.md lists `numpy_interpreter` + `simulation.simulate()` as the two official Python runners — `expression.evaluate` is **not** listed. Currently used by `data_loaders/variables.py:35,82` (unit-conversion constants), `tests/test_expression.py`, `tests/test_closed_functions.py`. | Either (a) delete + rewrite the three callers to drive the canonical pipeline through `numpy_interpreter`, or (b) document `expression.evaluate` as the spec-compliant scalar-AST evaluator and add it to the runner table. (a) is cleaner; (b) is cheaper. | M |
| 1.2 | **P1** | `pkg/EarthSciAST.jl/src/expression.jl:172` | Mirror of 1.1 in Julia (`evaluate(expr::OpExpr, bindings)`). 257 lines of operator dispatch (`+`, `*`, `^`, trig, extrema, registered-function bridge). Not listed in the Julia binding's official-runner table (only MTK + `tree_walk.jl` are). | Same options as 1.1. If kept, AGENTS.md must explicitly enumerate it; if deleted, route the unit-conversion + test callers through `tree_walk.build_evaluator`. | M |
| 1.3 | **P2** | `pkg/earthsci-ast-ts/src/expression.ts:88` | TypeScript `evaluate(expr, bindings)`. TS has only one official runner (`codegen.ts` — AST → JS lowering) but no in-process evaluator was ever the official runner. This 100-line walker functions as one. | Define `expression.ts::evaluate` as a sanctioned scalar evaluator in AGENTS.md, or have `codegen.ts` produce a JS function that callers invoke for evaluation. | S–M |
| 1.4 | **P2** | `pkg/earthsci-ast-rs/src/expression.rs:67-118` | Rust `evaluate(expr, bindings)`. AGENTS.md lists `simulate.rs` (diffsol) and `simulate_array.rs` (ndarray) as the two official runners; this file is a third codepath used only by tests. | Delete; route tests through `simulate` with a single-step ODE wrapper, or escalate the 3rd-runner status to AGENTS.md. | S–M |
| 1.5 | **P2** | `pkg/earthsci-ast-py/src/earthsci_ast/data_loaders/variables.py:35,82` | `apply_unit_conversion()` calls `expression.evaluate(conversion, {})` for constant-folding unit-conversion expressions. This is a library-side caller (not test-only), so 1.1 cannot simply be deleted without also fixing this path. | Replace with the canonical "constant-fold via `numpy_interpreter` with empty state" wrapper, or build a dedicated `fold_constant_expr()` helper. | S |

No `if rule.kind == X` style branches outside `rule_engine.{jl,py}` were found. The
`kind == "panel_dispatch"` branches in `rule_engine.jl:787` and `rule_engine.py:927`
are *inside* the production rule engine and are therefore allowed.

---

## 2. Cross-Binding Parity

### Canonical-operation matrix

| Operation | Julia | Python | TypeScript | Rust | Go | Notes |
|---|---|---|---|---|---|---|
| parse | ✓ 1888 | ✓ 3087 | ✓ 5922 | ✓ 1303 | ✓ 497 | TS LoC unusually high — likely combined parse+validate |
| validate | ✓ 1349 | ✓ 1547 | ✓ 1312 | ✓ 2936 | ✓ 1267 | Rust has the largest/most-stuffed module — see §6 |
| canonicalize | ✓ 432 | ✓ 394 | ✓ 421 | ✓ 654 | ✓ 256 | LoC roughly aligned |
| lower_expression_templates | ✓ 485 | ✓ 275 | ✓ 341 | ✓ 576 | ✓ 442 | All five bindings shipped; well-tested |
| lower_enums | ✓ (registered_functions.jl:410) | ✓ | ✓ | **✗ MISSING** | ✓ | **Real gap (P1).** |
| flatten | ✓ 1474 | ✓ 1245 | ✓ 440 | ✓ 1119 | ✓ 726 | TS unusually thin — verify completeness |
| discretize | ✓ 564 | ✓ 448 | ✓ 529 | ✓ (in dae.rs) | ✓ 637 | Rust hides discretize inside `dae.rs` — discoverability hit |
| evaluate (scalar) | ⚠ unsanctioned | ⚠ unsanctioned | ⚠ unsanctioned | ⚠ unsanctioned | n/a (Go is parse+validate only) | See §1 |
| simulate | ✓ MTK + tree_walk | ✓ simulation.py | ✗ (none — codegen only) | ✓ simulate + simulate_array | ✗ (by design) | TS has no in-process simulator |
| serialize | ✓ 1163 | ✓ 1172 | ⚠ **18 LoC** | ✓ 248 | ✓ 141 | TS = bare `JSON.stringify` |
| display / pretty-print | ✓ 937 | ✓ 1200 | ✓ 1339 | ✓ 2336 | ✓ 739 | Naming drift: TS uses `formatExpressionNode`, others `to_unicode`/`to_latex` |

### Findings

| # | Sev | Finding | Remediation | Effort |
|---|---|---|---|---|
| 2.1 | **P1** | `pkg/earthsci-ast-rs/` has no `lower_enums` (no source file, no public function, no `enum`-op handler). `enum` ops in input ESM files surface to the Rust runner unlowered. | Port `lower_enums!` semantics from Julia (`registered_functions.jl:410`) into a new `lower_enums.rs`; add fixture coverage in `tests/conformance/`. | M |
| 2.2 | **P1** | `pkg/earthsci-ast-ts/src/serialize.ts` is 18 LoC: just `JSON.stringify(file, null, 2)`. Other bindings handle ordered keys, AST round-trip canonicalization, dropping internal/cached fields. TS will round-trip-mismatch on any model that goes through `lower_*` passes. | Implement a real serializer mirroring `serialize.py` (1172 LoC) — at minimum: AST canonical form, key ordering by schema, drop transient flags. Add round-trip tests through the conformance harness. | M–L |
| 2.3 | **P2** | Naming drift in display: TS uses `formatExpressionNode`, others use `to_unicode`/`to_latex`. | Add `toUnicode`/`toLatex` aliases in TS or rename for cross-binding muscle memory. | S |
| 2.4 | **P3** | Rust `discretize` lives inside `dae.rs` rather than its own file. Inconsistent with the other four bindings. | Extract `discretize.rs`. | S |

### Conformance-suite coverage gap

Per `tests/COVERAGE_MATRIX.md` and `tests/conformance/`:
- The shared harness (`scripts/test-conformance.sh`) drives **5 categories** —
  valid, invalid, display, substitution, graphs — across 4 bindings.
- **Go is not driven through the cross-binding adapter**; it only runs
  native `go test ./...`, so its conformance-output cannot be diffed against
  Julia / Python / Rust / TS.
- Six fixture categories with substantial content are *not* exercised by the
  harness: `graphs/` (23), `mathematical_correctness/` (8),
  `scoping/` (10), `spatial/` (3), `serialization/` (1),
  `version_compatibility/` (19).

---

## 3. Inline / Conformance Test Coverage

### Fixture inventory (counts by category, top of `tests/`)

| Category | Files | Driven by harness |
|---|---|---|
| invalid | 83 | ✓ |
| future | 73 | (planned features — by design not driven) |
| property_corpus | 50 | ✓ (round-trip) |
| valid | 37 | ✓ |
| conformance (manifests) | 60 | ✓ |
| closed_functions | 25 | per-binding only |
| graphs | 23 | ✗ (gap) |
| version_compatibility | 19 | ✗ |
| simulation | 19 | per-binding only |
| coupling | 16 | per-binding only |
| display | 13 | ✓ |
| events | 12 | per-binding only |
| scoping | 10 | ✗ |
| discretizations | 9 | per-binding only |
| mathematical_correctness | 8 | ✗ |
| end_to_end | 7 | per-binding only |
| grids | 4 | per-binding only |
| substitution | 3 | ✓ |
| spatial | 3 | ✗ |
| indexing, validation, serialization | 1 each | ✗ |

### Findings

| # | Sev | Finding | Remediation | Effort |
|---|---|---|---|---|
| 3.1 | **P1** | The 23 `graphs/` fixtures and the 8 `mathematical_correctness/` fixtures are not driven by any binding's conformance test. These are exactly the categories where silent cross-binding numerical drift would sit. | Add adapter scripts (mirror the existing `run-julia-conformance.jl` pattern) for these two categories first. | M |
| 3.2 | **P2** | The conformance harness skips Go entirely from the cross-binding diff. | Either accept that (Go is parse+validate only and cannot produce numerical output) and document it, or add a parse+validate conformance-output adapter so Go's parse normalisation is checked against the others. | S–M |
| 3.3 | **P2** | 27 Python tests skip with `pytest.skip` for unimplemented closed functions; TS and Go each have 1-2 skips for the same reason. The skips are scattered across files; no single tracking issue. | File a single bead enumerating all skipped fixtures with target binding × function pairs; close skips one at a time. | S |
| 3.4 | **P3** | Test scratch files committed at TS package root: `debug_test.mjs`, `test_real_schema.js`, `test_bug_fixed.js` (verified tracked via `git ls-files`). Not run by CI. | Delete; they are not gitignored despite being throwaway. | S |
| 3.5 | **P3** | `pkg/earthsci-ast-go/test_simple.esm` is tracked but referenced by no test. | Delete or convert into a fixture under `tests/`. | S |

---

## 4. Dead Code + Duplication

| # | Sev | File:Line | Finding | Remediation | Effort |
|---|---|---|---|---|---|
| 4.1 | **P3** | `pkg/earthsci-ast-ts/src/generated.ts:1945, 1973` | Two `@deprecated` schema fields for v0.1.0 → v0.2.0 transitional `domain.boundary_conditions` shim (RFC §10.1). | Schedule removal in v0.3.0; until then, fine. Leave-alone. | n/a |
| 4.2 | **P2** | `pkg/earthsci-ast-py/src/earthsci_ast/codegen.py:254,264,273,543,553` | Five `# TODO` placeholder comments emitting unimplemented codegen for coupling / domain / data-loader targets. | Either implement or strip the stubs; placeholder comments mislead readers about what `codegen.py` supports. | M |
| 4.3 | **P3** | `pkg/earthsci-ast-py/src/earthsci_ast/simulation.py:1064 simulate_legacy(…)` | Legacy entry kept alongside `simulate(…)` (line 1076). | Audit callers; if all internal callers are migrated, delete `simulate_legacy`. | S |
| 4.4 | **P3** | `pkg/earthsci-ast-py/src/earthsci_ast/simulation.py:1824 simulate_reaction_system(…)` | Parallel-feeling entry-point next to `simulate`. Possibly redundant with the canonical pipeline. | Verify it's still called by `reactions.py` consumers; collapse if not. | S |
| 4.5 | **P3** | `pkg/earthsci-ast-editor/src/typescript_integration.ts:435,452,453` | 3 TODOs for "file-based storage on Node.js" and "submit to API endpoint". | If editor is browser-only, drop the Node-side TODOs and document the constraint. | S |

No tracked build artifacts found. `pkg/earthsci-ast-py/build/` is `.gitignored`.

---

## 5. Documentation Hygiene

| # | Sev | File | Finding | Remediation | Effort |
|---|---|---|---|---|---|
| 5.1 | **P2** | `ESM_COMPLIANCE_VALIDATION_MATRIX.md` | Self-described as "static reference taxonomy" but does not index `expression_templates` test fixtures (`tests/conformance/expression_templates/`), and predates the `esm-4t5` retirement. | Update with current fixture inventory and remove any references to `mms_evaluator` / `stencil-evaluator` / `walker_ghost_fill`. | M |
| 5.2 | **P2** | `pkg/earthsci-ast-py/README.md` | Only 48 lines; example code references `ExprNode` constructor without showing canonical usage. README does not state Python's simulation tier limitations (0D, no spatial ops). | Expand to match the Rust README pattern; document tier limits explicitly so users don't assume PDE support. | M |
| 5.3 | **P3** | `WORKER_PROMPT.md`, `ATMOSPHERIC_CHEMISTRY_VERIFICATION_REPORT.md` at repo root | Snapshot artifacts mixed with normative docs. Discoverability hit for new contributors who hit them via `ls`. | Move into `docs/snapshots/` or delete `ATMOSPHERIC_CHEMISTRY_VERIFICATION_REPORT.md` (its content is preserved in git history). | S |
| 5.4 | **P3** | Root `Project.toml` | This file lives at the repo root but the actual Julia binding's `Project.toml` is `pkg/EarthSciAST.jl/Project.toml`. New contributors will mistake the root one for the binding manifest. | Add a one-line comment to the root `Project.toml` pointing to the binding, or remove if unused. | S |
| 5.5 | **P3** | `esm-spec.md` §9.6 (`expression_templates`) | Section is well-written but does not link to the cross-binding lower-pass implementations. | Add a "References" subsection listing each binding's `lower_expression_templates` entry-point. | S |
| 5.6 | n/a | `esm-uwe` umbrella | Not visible in `esm-spec.md` or commit history (last 30 commits). Either an internal coordination bead or the audit prompt naming-drift; nothing to update on the doc side. | — | n/a |

---

## 6. Build / Dependency Health

| # | Sev | Finding | Remediation | Effort |
|---|---|---|---|---|
| 6.1 | **P2** | `pkg/earthsci-ast-rs/Cargo.toml` pins `edition = "2024"` and `rust-version = "1.88.0"`. Rust 2024 edition is stabilised but contributors on slightly older toolchains will see opaque error messages. | Document the 1.88+ requirement in the Rust README's "Build" section. | S |
| 6.2 | **P2** | `pkg/earthsci-ast-rs/Cargo.toml` pins `diffsol = "0.11"`. Inline comment notes a "0.11.0 hardcoded `pub use` quirk". v0.12 is upstream. | Track a follow-up bead: bump diffsol to ≥0.12 once the upstream API stabilises. | M |
| 6.3 | **P3** | JSON-schema-validator skew: Rust uses `jsonschema 0.19`, Python `jsonschema >=4.0`, TS `ajv ^8.17`, Go `gojsonschema` (transitive), Julia `JSONSchema.jl 1`. No coordinated policy on schema-validation behaviour parity. | Add a `tests/conformance/schema_validator/` category that hits each binding with edge-case schema features (oneOf, additionalProperties, patternProperties) and asserts equivalent error codes. | M |
| 6.4 | **P3** | `pkg/earthsci-ast-py/pyproject.toml` lower-bounds-only on numpy/scipy/sympy. Fine for a research stack but means CI will silently absorb upstream behaviour changes. | Add upper-bounds-on-major (`numpy<3`, `scipy<2`, `sympy<2`) so CI breaks loudly on pre-release upgrades. | S |

No critical CVEs surfaced from version inspection beyond what the recent
`postcss` bump (`93530f285`) already addressed. Lockfiles look healthy.

---

## 7. Architectural Smells

| # | Sev | Finding | Remediation | Effort |
|---|---|---|---|---|
| 7.1 | **P2** | God module: `pkg/earthsci-ast-rs/src/validate.rs` is 2,936 LoC and mixes JSON-schema validation with structural / coupling / unit-balance checks. | Split into `validate.rs` (schema) + `structural.rs` (equation balance) + `coupling.rs`. Mirrors the Python decomposition. | L |
| 7.2 | **P2** | God module: `pkg/earthsci-ast-py/src/earthsci_ast/simulation.py` is 2,172 LoC handling flatten → SymPy bridge → SciPy integration. | Extract `sympy_bridge.py` (lambdify + `cse` + `Abs` workaround); keep `simulation.py` for solver wiring. | M–L |
| 7.3 | **P3** | God module: `pkg/earthsci-ast-rs/src/rule_engine.rs` is 2,171 LoC. | Extract `rule_applier.rs`; keep `rule_engine.rs` for canonical-form dispatch. | M |
| 7.4 | **P3** | The Rust `discretize` lives inside `dae.rs`, while every other binding has a dedicated `discretize.{jl,py,ts,go}`. | Extract `discretize.rs`. | S |
| 7.5 | n/a | No cyclic-import patterns detected via spot-check. The rule-engine / runner boundary is clean — runners walk AST only, rule application is fully upstream. | — | — |

---

## 8. Tech Debt with Stale Context

- `bd list --status=deferred` → no issues. ✓
- `bd list --status=blocked` → no issues. ✓
- `esm-4t5` (single-pathway-rule retirement) closed 2026-04-29; ~9.3k LoC deleted across 5 bindings. ✓
- `esm-qrj` referenced from `AGENTS.md` line 80 ("Audit + formal documentation tracked under `esm-qrj`") for `tree_walk.jl` — verify this bead is current; if it's already closed, the AGENTS.md note is stale.

---

## Top 10 Priorities

Ordered by *impact / effort*:

1. **Resolve the unsanctioned `expression.evaluate` parallel-walker situation** in all four bindings (findings 1.1–1.4). Either delete + reroute callers, or document them as sanctioned scalar-AST evaluators. Right now the rule says "no parallel evaluators" while four parallel evaluators exist. **(P1, M each)**
2. **Implement `lower_enums` in the Rust binding** (2.1). The only true cross-binding parity gap. **(P1, M)**
3. **Replace the 18-line TypeScript `serialize.ts` stub** (2.2) with a real serializer. Without it, TS can never pass conformance round-trip on lowered forms. **(P1, M–L)**
4. **Drive the `graphs/` and `mathematical_correctness/` fixture categories through the conformance harness** (3.1). The two highest-value untested categories. **(P1, M)**
5. **Split `validate.rs` (2,936 LoC)** along schema vs. structural lines (7.1). Makes future Rust-binding contributions tractable. **(P2, L)**
6. **Refresh `ESM_COMPLIANCE_VALIDATION_MATRIX.md`** (5.1) — index expression_templates fixtures, drop references to retired evaluators. **(P2, M)**
7. **Expand `pkg/earthsci-ast-py/README.md`** (5.2) — document Python tier limits so users don't assume PDE support. **(P2, M)**
8. **Resolve or strip the 5 `# TODO` placeholders in `codegen.py`** (4.2). Either implement the unimplemented codegen targets or stop advertising them. **(P2, M)**
9. **Bring Go into the cross-binding conformance-output adapter** (3.2) for parse+validate, even though Go does not simulate. Otherwise Go silently drifts. **(P2, S–M)**
10. **Delete tracked test scratch files** (`debug_test.mjs`, `test_real_schema.js`, `test_bug_fixed.js`, `test_simple.esm`) (3.4, 3.5). Trivial, but the noise is real. **(P3, S)**

---

## Method notes

- ~75 minutes wall time. Audit method: targeted `grep` + sampling. Did **not**
  run full test suites (per repo CLAUDE.md: they OOM).
- Verified all retired-evaluator filenames are gone via direct `ls`.
- Verified `esm-4t5`, deferred, and blocked bead lists via `bd`.
- Where a sub-agent finding contradicted my own spot-check, I sided with my
  spot-check (e.g. the agent claimed Julia lacked `lower_enums`; verified it
  exists in `registered_functions.jl:410`. The agent claimed root `Project.toml`
  had loose compat; verified the *binding's* `Project.toml` has full `[compat]`).
