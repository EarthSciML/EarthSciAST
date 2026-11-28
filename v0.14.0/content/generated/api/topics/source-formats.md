---
title: "Source formats"
description: "Writing and reading a whole document as Markdown (LaTeX math) or Typst source, losslessly, and the canonical form both start from."
type: "api"
---


| Operation | Kind | Bindings | Summary |
|---|---|---|---|
| [`canonicalize_document`](/generated/api/ref/canonicalize_document) | function | Julia, TypeScript, Python, Rust, Go | The document-level canonical step: every units string of a decoded document (the JSON object `to_json` writes and `load_document` reads, e.g. from `JSON3.read`) takes the… |
| [`parse_document`](/generated/api/ref/parse_document) | function | Julia, TypeScript, Python, Rust, Go | Read an ESM document written in the source format `format`: `:markdown` (`parse_markdown`) or `:typst` (`parse_typst`). |
| [`parse_markdown`](/generated/api/ref/parse_markdown) | function | Julia, TypeScript, Python, Rust, Go | Read a Markdown ESM document (Lean `Source.Md.parseMd`). |
| [`parse_typst`](/generated/api/ref/parse_typst) | function | Julia, TypeScript, Python, Rust, Go | Read a Typst ESM document (Lean `Source.Typ.parseTyp`). |
| [`print_document`](/generated/api/ref/print_document) | function | Julia, TypeScript, Python, Rust, Go | Print an ESM document in the source format `format`: `:markdown` (`print_markdown`) or `:typst` (`print_typst`). |
| [`print_markdown`](/generated/api/ref/print_markdown) | function | Julia, TypeScript, Python, Rust, Go | Print an ESM document as Markdown: YAML front matter, LaTeX math in `$$` displays, remark directives for components, declarations and reactions, and fenced `esm:` blocks for… |
| [`print_typst`](/generated/api/ref/print_typst) | function | Julia, TypeScript, Python, Rust, Go | Print an ESM document as Typst (Lean `Source.Typ.printTyp`): the `esm` Typst package's `esm-document` header, Typst math displays and the package's functions for components,… |

[All topics](/generated/api)
