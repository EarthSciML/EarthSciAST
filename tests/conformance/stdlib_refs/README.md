# Standard-library refs (`stdlib_refs`)

esm-spec §4.7 reserves the `esm:` ref scheme: `esm:std/<file>.esm` resolves, in
every binding, to the copy of the repository's `lib/` that the binding bundles
in its own package (`scripts/sync-lib.sh` writes the copies). This tier checks
the form at each ref site and the unresolved cases.

The documents here sit away from `lib/` and none uses a relative path to it.
`manifest.json` lists the cases:

| Case | Ref | Expect |
|---|---|---|
| `import_interp` | template import of `esm:std/interp.esm` | same as twin |
| `mount_solar_subsystem` | `subsystems.<k>` mount of `esm:std/solar.esm` | same as twin |
| `mount_solar_toplevel` | top-level `models.<k>` mount of `esm:std/solar.esm` | same as twin |
| `import_interp_via_env` | `${ESM_STDLIB_TEST_REF}` set to `esm:std/interp.esm` | same as twin |
| `import_unknown_file` | `esm:std/nope.esm` | `template_import_unresolved` |
| `import_other_namespace` | `esm:other/interp.esm` | `template_import_unresolved` |
| `import_no_namespace` | `esm:interp.esm` | `template_import_unresolved` |
| `import_parent_segment` | `esm:std/../lib/interp.esm` | `template_import_unresolved` |
| `import_env_not_expanded` | `esm:std/${ESM_STDLIB_TEST_NAME}` set to `interp.esm` | `template_import_unresolved` |
| `mount_unknown_file` | `subsystems.<k>` mount of `esm:std/nope.esm` | `unresolved_subsystem_ref` |
| `mount_unknown_file_toplevel` | top-level mount of `esm:std/nope.esm` | `unresolved_subsystem_ref` |
| `coupling_import_unknown_file` | `coupling_import` of `esm:std/nope.esm` | `coupling_import_unresolved` |

How a binding runs a case:

- **`same_as_twin`**: load `fixture` and `twin` (under `twins/`, which reaches the
  same library file through `../../../../lib/`). Both must load, and their
  serialized documents must be equal once every string value of a `ref` key is
  replaced by one placeholder (an authored `ref` round-trips verbatim, so the two
  spellings are the only expected difference).
- **`error`**: the case must fail with `code` through `driver`: `load`, or
  `flatten` for a coupling import (a binding that resolves coupling imports
  earlier may fail at load with the same code).
- **`env`**: set these environment variables around the case and restore them
  afterwards.

`mount_solar_*` also cover the rule that relative refs inside a bundled file
resolve among the bundled files once `lib/solar.esm` imports `calendar.esm`.
Each binding's unit tests check that rule directly with a substitute bundle, as
well as cycle detection by `esm:std` identity and loading a document from a
string with no base directory.

Wired into: Julia `test/stdlib_refs_test.jl`, Python
`tests/test_stdlib_refs.py`, Rust `tests/stdlib_refs_conformance.rs`,
TypeScript `src/stdlib-refs.test.ts`, Go `pkg/esm/stdlib_refs_test.go`.
