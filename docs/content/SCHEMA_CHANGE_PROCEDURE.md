# ESM Format Change Procedure

This document defines the canonical procedure for evolving the `.esm` serialization format. Every change to the on-disk shape of `.esm` files — whether adding a field, loosening a constraint, or renaming an op — moves through the same four ordered steps so the **spec**, **schema**, **language bindings**, and **existing components** never drift out of alignment.

> The automation in [`RELEASE_PROCESS.md`](RELEASE_PROCESS.md) and [`RELEASE_PIPELINE.md`](RELEASE_PIPELINE.md) handles version-bump publishing across registries. *This* document defines what must be in the repo **before** that pipeline is triggered.

## Scope

Apply this procedure when any of the following is true:

- A new field, op, or `$defs` definition is added.
- An existing field accepts new shapes (e.g. `oneOf` widening, additional enum values).
- A constraint is tightened (additional required fields, stricter `pattern`).
- A field, op, or definition is removed or renamed.
- The set of components that pass schema validation changes for any reason other than fixing a previously-out-of-spec file.

Skip this procedure only for fixes that change nothing observable in the schema (typos in descriptions, code-comment edits, internal refactors of binding parsers that do not change accepted inputs).

## Versioning

The schema is semver-versioned in two places:

- `$id` in `esm-schema.json` (e.g. `https://earthsciml.org/schemas/esm/0.5.0/esm.schema.json`)
- The `version` strings in each binding manifest (see Step 3)

Bump rules:

| Change kind | Bump |
|---|---|
| Adding a new optional field, op, or `$defs` entry | **MINOR** |
| Widening an existing field via `oneOf` (backward-compatible authoring expansion) | **MINOR** |
| Adding a new required field, removing/renaming an existing one, tightening a `pattern` | **MAJOR** |
| Fixing a description, refactoring `$defs` references with no observable input change | **PATCH** |

PATCH-only changes still go through every step below; only the spec wording or schema body may change, but the four-step sequence still applies.

## The four steps

These steps are **ordered** and **must all complete in one logical change** (one PR, or one polecat run dispatching through `mol-update-spec-schema`). Reviewers should reject a change that lands any step without the others.

### Step 1 — Update the spec (`esm-spec.md`)

The spec is the human-readable source of truth. Update it **first** so that anyone reading the spec next can describe the new shape correctly even before the schema is touched.

For every change:

1. Locate the affected section (e.g. §6.7.4 for `examples.plots`, §11 for domains).
2. Edit the field tables, prose, and any RFC reference to describe the new shape.
3. Add or update worked examples in the spec body if the change affects authoring patterns users will need to learn.
4. If the change is large enough to warrant an RFC, add a file under `docs/content/rfcs/` and link it from the schema's `description` field (the schema already does this for the closed-function registry and AST templates — follow that style).

The spec is normative for the format. If something is in the spec and not the schema, the spec wins; if it is in the schema and not the spec, the schema is presumed under-documented and gets a follow-up.

### Step 2 — Update the schema (and bump its version)

The canonical schema is `esm-schema.json` at the repo root. **Edit only the root copy** — the other four copies are mirrors maintained by `scripts/sync-schema.sh`.

1. Edit `esm-schema.json` to reflect the spec change.
2. Bump the version embedded in `$id` according to the table above.
3. Update the schema's top-level `description` field if the change is significant — historical entries for v0.3.0 and v0.4.0 demonstrate the expected wording (one or two sentences per minor version, linking to the RFC if any).
4. Run `scripts/sync-schema.sh` to copy the new root schema into all four binding-mirror locations:
   - `pkg/earthsci-ast-go/pkg/esm/esm-schema.json`
   - `pkg/earthsci-ast-rs/src/esm-schema.json`
   - `pkg/EarthSciAST.jl/data/esm-schema.json`
   - `pkg/earthsci-ast-py/src/earthsci_ast/data/esm-schema.json`
5. Run `scripts/sync-schema.sh --check` to confirm everything is aligned. This is exactly what the `schema-sync-check.yml` workflow does on CI.

The five copies exist because each language's package registry only ships files inside the package directory; the schema must be embedded as package data in each binding. See the comment block at the top of `scripts/sync-schema.sh` for the canonical list and rationale.

### Step 3 — Update the language bindings

The schema body is metadata; the **parsers, validators, code-generators, and runtime types** in each binding must be updated so that the new schema shape is actually understood end-to-end. Embedded-schema sync from Step 2 is *not* sufficient.

Touch points per binding:

| Binding | Package path | Files that typically need updating |
|---|---|---|
| Python | `pkg/earthsci-ast-py/` | `src/earthsci_ast/parse.py`, `src/earthsci_ast/esm_types.py`, `tests/test_*` |
| Julia | `pkg/EarthSciAST.jl/` | `src/parse.jl` (or equivalent), `src/types.jl`, `test/` |
| Rust | `pkg/earthsci-ast-rs/` | `src/lib.rs`, `src/types.rs`, `tests/` |
| Go | `pkg/earthsci-ast-go/` | `pkg/esm/types.go`, `pkg/esm/parse.go`, `*_test.go` |
| TypeScript | `pkg/earthsci-ast-ts/` | `src/*.ts` if the change affects parsing (the TS package is publish-only for the schema in some releases — check the package's actual responsibilities) |

For each binding:

1. Update the parser to accept the new shape.
2. Update the runtime types/dataclasses to expose the new structure to consumers (or to normalize the new shape onto an existing internal representation — this is what `_parse_plot` does for inline-array `y` mapping onto the existing `series` list).
3. Add or update tests covering the new shape with at least one round-trip fixture.
4. Bump the binding-manifest version string to match the schema version. The manifests are listed in `scripts/sync-schema.sh` under `VERSION_MANIFESTS`:
   - `pkg/earthsci-ast-ts/package.json`
   - `pkg/earthsci-ast-py/pyproject.toml`
   - `pkg/earthsci-ast-rs/Cargo.toml`
   - `pkg/EarthSciAST.jl/Project.toml`

(Go uses module-path versioning via tags and is not in `VERSION_MANIFESTS`.)

When a binding cannot be updated in the same change (e.g. an external dependency is blocking), still update its embedded schema mirror so `schema-sync-check.yml` passes, and file a follow-up issue tagged `binding-debt:<lang>` so the gap is visible.

### Step 4 — Update `.esm` components as necessary

A schema change can produce three flavors of effect on already-on-disk components:

1. **No-op change** — additive, optional, default-only. Existing components keep validating without edits and may declare the new schema version when they want to (no requirement).
2. **New authoring form** — components MAY use the new shape. Components that adopt the new shape **MUST** declare the new schema version in their top-level `"esm":` field. Components that retain the old shape may keep their existing version declaration.
3. **Breaking change** — every component on disk must be migrated to the new shape. Components that have not been migrated MUST keep the old `"esm":` version (and will not validate against the new schema). A migration sweep — usually a polecat-driven run — is part of the same change.

For flavors 2 and 3, file a bead in `EarthSciModels` (or wherever the affected components live) tracking the per-file sweep, linked to the `EarthSciAST` change bead.

For flavor 1 (a non-breaking widening, like adding an array form of `plots.y`), no immediate `.esm` edits are required, but a migration plan can be filed if you want existing components to start using the new shape as a future cleanup.

## Driving the procedure as a polecat formula

The `mol-update-spec-schema` formula in this repo's `.gc/pack/` automates the orchestration of these four steps for a polecat: it pours one wisp per step, each carrying the rules above as its prompt, and threads the agreed schema-version bump through all of them so the binding manifests, schema `$id`, and component `"esm":` declarations stay consistent.

Dispatch with a bead carrying the proposed change as `metadata.spec_change_summary` (one to three paragraphs describing what's changing and why) and, when known, `metadata.schema_version_bump` (`patch | minor | major`). The formula will fail fast if either is missing.

## Review and merge

Schema-changing PRs go through normal review with three additional checklist items, surfaced by the `schema-sync-check.yml` workflow and the per-binding test suites:

- [ ] Spec, schema (`$id`), and all binding-manifest versions agree.
- [ ] Every binding has a test exercising the new shape (or a tracked exception under `binding-debt:<lang>`).
- [ ] If components were touched, every touched `.esm` file declares the new `"esm":` version.

Once merged to `main`, the existing release automation in [`RELEASE_PIPELINE.md`](RELEASE_PIPELINE.md) handles cross-registry publication.
