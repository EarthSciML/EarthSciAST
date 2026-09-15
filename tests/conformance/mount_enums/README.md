# `mount_enums` — a mounted file's `enum` ops resolve in its own `enums` block

Shared fixtures pinning esm-spec §9.3 ("Mounted files") across all five
bindings: an `enum` op in a file mounted at a §4.7 edge resolves against that
file's `enums` block, at both mount forms, and `enums` do not merge into the
mounting document.

Reported as issue #260. Two leaves declared `probe.Symbol` as 1 and 2. Mounted
together, the bindings either merged the two blocks (first declaration wins, so
leaf two silently read 1), resolved the leaves against the mounting document's
block (an assembly declaring `probe.Symbol = 7` gave both leaves 7), refused the
mount with `unknown_enum`, or left the leaves' `enum` ops unlowered.

## The fixtures

| File | Role |
|---|---|
| `leaf_one.esm`, `leaf_two.esm` | Each declares `probe.Symbol` (1 and 2) and reads it back into `value`. Both load on their own. |
| `toplevel.esm` | The issue's case: both leaves mounted by top-level `models` `{ref}`s. Declares no enums. |
| `toplevel_importer_redeclares.esm` | The mounting document declares `probe.Symbol = 7` and reads it. The leaves keep 1 and 2; its own op reads 7. |
| `subsystems.esm` | The same, with the leaves mounted at `subsystems.<k>` `{ref}` edges. |
| `mid.esm`, `nested.esm` | `nested.esm` mounts `mid.esm` (top-level form), which declares `probe.Symbol = 5` and mounts `leaf_two.esm` (subsystem form). Each edge resolves the file below it: 5 and 2. |
| `assembly_names_leaf_enum.esm` | Invalid. The mounting document's own `enum` op names `probe`, which only the leaf declares → `unknown_enum`. |
| `expected.json` | What each fixture loads to: `loads` maps `Model[.Subsystem…].variable` to the integer constant its defining equation lowers to; `errors` maps a fixture to its diagnostic code. |

## What each binding asserts

Each binding loads every fixture with refs resolved and checks `expected.json`:

- `pkg/EarthSciAST.jl/test/mount_enums_test.jl`
- `pkg/earthsci-ast-py/tests/test_mount_enums.py`
- `pkg/earthsci-ast-rs/tests/mount_enums.rs`
- `pkg/earthsci-ast-go/pkg/esm/mount_enums_test.go`
- `pkg/earthsci-ast-ts/src/mount-enums.test.ts`
