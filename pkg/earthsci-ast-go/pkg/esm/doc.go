// Package esm implements the EarthSciAST (.esm) JSON format for earth-science
// model components: parsing, validation, canonicalization, expression-template
// and coupling-library resolution, flattening, and rendering of the
// language-agnostic AST. It is the Go binding of the format normatively defined
// by esm-schema.json and documented in esm-spec.md at the repository root; the
// on-wire representation and diagnostic codes are cross-language contracts
// verified by the shared conformance suite, so byte-level output and error
// codes must stay in lockstep with the other bindings.
package esm
