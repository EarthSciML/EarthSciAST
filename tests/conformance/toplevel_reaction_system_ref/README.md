# `toplevel_reaction_system_ref` — a top-level `reaction_systems.<k>` `{ref}` mount

Shared fixtures for esm-spec §4.7 "Two mount forms, one mechanism" at the
top-level `reaction_systems.<k>` attachment point. An entry there that carries a
`ref` and no `species` is a mount edge: the referenced file's single reaction
system (or the one its `reaction_system` selector names) is spliced in under the
key `<k>`, so a coupled document can name a reaction-system file the way it
names a model file at `models.<k>`.

All five bindings implement the form, through the same edge pipeline each runs
for a top-level `models.<k>` `{ref}`.

## The fixtures

| File | Role |
|---|---|
| `leaf.esm` | One reaction system, `Chem`: A → B at rate `k`. |
| `two_systems_leaf.esm` | Two reaction systems, `Chem` and `Slow`, so a mount must choose one. |
| `basic.esm`, `basic_inline.esm` | `leaf.esm` mounted at `reaction_systems.Chem` beside an inline model, and the same document written inline. |
| `selector.esm`, `selector_inline.esm` | `two_systems_leaf.esm`'s `Slow` mounted under a different key, `Chem2`, by the selector; and inline. |
| `nested.esm`, `nested/mid.esm` | A mount of a document in a subdirectory that itself mounts `../leaf.esm` at the same form: the inner `ref` resolves against `nested/`. Loads to `basic_inline.esm`. |
| `ambiguous.esm` | A two-system leaf with no selector. Refused. |
| `unknown_selector.esm` | A selector naming a reaction system the leaf does not declare. Refused. |
| `missing_file.esm` | A `ref` to a file that does not exist. Refused. |
| `expected.json` | The contract. |

## What `expected.json` pins

- `implemented_by` — the bindings that mount the form (all five). A binding not
  listed must refuse every fixture here that uses it, with
  `mount_form_unsupported`.
- `loads` — `{fixture: inline_fixture}`. After load and emit, the two documents'
  `models` and `reaction_systems` blocks are deep-equal.
- `load_errors` — `{fixture: {code: [bindings]}}`, as in
  `tests/conformance/mount_element_type/`. A binding listed under no code must
  still refuse the fixture.

None of the fixtures declares `metaparameters` or `index_sets`; that half of the
pipeline at this form (edge `bindings`, the `index_sets` merge,
`index_set_rename`) is pinned by each binding's own mount-rename tests.

## What each binding asserts

- `pkg/EarthSciAST.jl/test/toplevel_reaction_system_ref_test.jl`
- `pkg/earthsci-ast-rs/tests/toplevel_reaction_system_ref.rs`
- `pkg/earthsci-ast-py/tests/test_mount_index_set_rename.py::test_toplevel_reaction_system_ref_loads_as_if_written_inline`
  and `::test_toplevel_reaction_system_ref_bad_mount_is_refused`
- `pkg/earthsci-ast-go/pkg/esm/mount_index_set_rename_test.go::TestTopLevelReactionSystemRefConformanceFixtures`
- `pkg/earthsci-ast-ts/src/mount-index-set-rename.test.ts` ("tests/conformance/toplevel_reaction_system_ref")
