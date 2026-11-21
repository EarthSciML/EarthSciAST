# Source documents loaded from files (`source_documents`)

esm-spec §1.2.1: a loader that reads a document from a path or a URL picks its
format by the file extension alone — `.md` is a Markdown source document, `.typ`
a Typst source document, and every other name (`.esm` among them) JSON. The rule
holds for the root document and at every ref site: subsystem mounts at both
forms (§4.7), template imports (§9.7.2) and coupling imports (§10.10). So a
library can be converted file by file, and a `.esm` document can import a `.typ`
library or mount a `.md` model.

`manifest.json` lists the cases:

| Case | Fixture | Expect |
|---|---|---|
| `root_typst` | Typst root importing `library.typ`, mounting `leaf.md` | same as twin |
| `root_markdown` | Markdown root importing `library.md`, mounting `leaf.typ` | same as twin |
| `json_root_mixed_refs` | JSON root importing `library.typ`, mounting `leaf.md` | same as twin |
| `mount_toplevel_typst` | top-level `models.<k>` mount of `leaf.typ` | same as twin |
| `coupling_import_typst` | `coupling_import` of `coupling_library.typ` | flattens |
| `root_typst_json_content` | `json_content.typ` (JSON text) as the root | `parse_error` |
| `root_markdown_json_content` | `json_content.md` (JSON text) as the root | `parse_error` |
| `import_json_content` | template import of `json_content.typ` | `template_import_unresolved` |
| `mount_json_content` | subsystem mount of `json_content.md` | `unresolved_subsystem_ref` |
| `mount_toplevel_json_content` | top-level `models.<k>` mount of `json_content.typ` | `unresolved_subsystem_ref` |
| `coupling_import_json_content` | `coupling_import` of `json_content.typ` | `coupling_import_unresolved` |
| `root_typst_removed_op` | `removed_op.typ` (calls the removed `fn`) as the root | `removed_op` |
| `root_markdown_removed_op` | `removed_op.md` (calls the removed `fn`) as the root | `removed_op` |
| `mount_removed_op` | subsystem mount of `removed_op.md` | `removed_op` |
| `mount_toplevel_removed_op` | top-level `models.<k>` mount of `removed_op.typ` | `removed_op` |
| `import_removed_op` | template import of `removed_op.typ` | `removed_op` |
| `coupling_import_removed_op` | `coupling_import` of `removed_op.md` | `removed_op` |
| `import_json_removed_op` | template import of `twins/removed_op.esm`, the JSON twin | `removed_op` |

How a binding runs a case:

- **`same_as_twin`**: load `fixture` and `twin` (under `twins/`, where every file
  is `.esm` JSON). Both must load, and their serialized documents must be equal
  once every string value of a `ref` key is replaced by one placeholder (an
  authored `ref` round-trips verbatim, so the spellings are the only expected
  difference).
- **`ok`**: the case must succeed through `driver`.
- **`error`**: the case must fail with `code` through `driver`: `load`, or
  `flatten` for a coupling import (a binding that resolves coupling imports
  earlier may fail at load with the same code).

The `json_content` files hold a valid `.esm` document as JSON text. A loader that
picked the format by looking at the content would accept them; read by their
extension they are not Markdown or Typst documents and are refused, which is the
point of the `error` cases. The `removed_op` files call `fn`, an operator
removed at esm 2.0.0: a source document's refusal of it keeps the code
`removed_op` wherever it happens, as the wire-boundary refusal of the same
document written as JSON does (`import_json_removed_op`), rather than turning
into the ref site's unresolved code.

Wired into: Julia `test/source_documents_test.jl`, Python
`tests/test_source_documents.py`, Rust `tests/source_documents_conformance.rs`,
TypeScript `src/source-documents.test.ts`, Go `pkg/esm/source_documents_test.go`.
