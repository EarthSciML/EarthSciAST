---
title: "Document I/O"
description: "Reading a document from a path, a string or a parsed value, and serializing it back to JSON."
type: "api"
---


| Operation | Kind | Bindings | Summary |
|---|---|---|---|
| [`canonical_index_set_json`](/generated/api/ref/canonical_index_set_json) | function | Python, Rust | Canonical byte form of an index set (`CONFORMANCE_SPEC.md` §5.5.3): the `distinct` rows, each tuple serialised as a JSON array, in §5.5.1 sorted order, as compact UTF-8 JSON. |
| [`canonical_json`](/generated/api/ref/canonical_json) | function | Julia, TypeScript, Rust, Go | Emit the canonical on-wire JSON form of an expression per RFC §5.4.6: keys sorted, no extraneous whitespace, shortest round-trip floats with trailing-`.0` disambiguation for… |
| [`canonicalize`](/generated/api/ref/canonicalize) | function | Julia, TypeScript, Rust, Go | Canonicalize an expression tree per discretization RFC §5.4. |
| [`emit_document`](/generated/api/ref/emit_document) | function | TypeScript, Python | Produce the reference-preserving, self-contained emitted document (esm-spec §9.6.4 rule 5, RFC out-of-line-expression-templates §7.5) from a source document `rawSource` (a… |
| [`emit_esm_string`](/generated/api/ref/emit_esm_string) | function | TypeScript, Python | Canonical byte serialization of an emitted document (esm-spec §9.6.4 rule 5): 2-space indent, object keys sorted lexicographically (UTF-8 byte order) EXCEPT the entries of an… |
| [`format_canonical_float`](/generated/api/ref/format_canonical_float) | function | Julia, TypeScript, Rust | Format a finite `Float64` per RFC §5.4.6. |
| [`load_document`](/generated/api/ref/load_document) | function | Julia, TypeScript, Python, Rust, Go | Parse an ESM document held in memory as a native Julia dict — the same document a `.esm` file holds, just already parsed. |
| [`load_path`](/generated/api/ref/load_path) | function | Julia, TypeScript, Python, Rust, Go | Read and parse an ESM document from a filesystem path. |
| [`load_string`](/generated/api/ref/load_string) | function | Julia, TypeScript, Python, Rust, Go | Parse an ESM document from JSON TEXT — held as a `String`, or streamed from an `IO` the method reads to a string first (the `::IO` method is a sanctioned Julia decoration on the… |
| [`to_json`](/generated/api/ref/to_json) | function | Julia, TypeScript, Python, Rust, Go | Serialize an `EsmFile` to wire-form JSON. |
| [`to_json_compact`](/generated/api/ref/to_json_compact) | function | Julia, TypeScript, Python, Rust, Go | The single-line wire form. |
| [`write_path`](/generated/api/ref/write_path) | function | Julia, TypeScript, Python, Rust, Go | Write an `EsmFile` to `path` as wire-form JSON. |
| [`load_options`](/generated/api/ref/load_options) | type | TypeScript, Rust | Options controlling how the `load*` entry points parse and represent an ESM file. |
| [`loader_field`](/generated/api/ref/loader_field) | type | TypeScript, Python, Rust, Go | A data-fed PARAMETER lowered to a flattened array input (esm-spec §8.5). |
| [`canonicalize_error`](/generated/api/ref/canonicalize_error) | error | Julia, TypeScript, Rust | Error raised by `canonicalize` / `canonical_json`. |

[All topics](/generated/api)
