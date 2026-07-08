---
title: "EarthSciAST"
description: "Language-agnostic JSON-based format for earth science model components."
---

**EarthSciML Serialization Format** — a language-agnostic JSON-based format for
earth science model components, their composition, and runtime configuration.

The ESM (`.esm`) format enables persistence, interchange, and version control
for earth science models across multiple programming languages. Every model is
fully self-describing: all equations, variables, parameters, species, and
reactions are specified in the format itself, allowing conforming parsers in
any language to reconstruct the complete mathematical system.

Reference implementations are available in Julia, TypeScript, Python, Rust, and
Go, with a SolidJS-based interactive editor. All implementations share the same
`esm-schema.json` and are validated against a common cross-language conformance
suite.

## Start here

- [Getting Started — Installation](getting-started/installation/)
- [API Reference](api/)
- [Examples](examples/)
- [Tutorials](tutorial/)
- [Guides](guides/)
- [RFCs & Design Notes](rfcs/)
- [Troubleshooting](troubleshooting/)

## Specification

The authoritative format specification is [`esm-spec.md`](https://github.com/EarthSciML/EarthSciAST/blob/main/esm-spec.md)
at the repository root, alongside the machine-readable
[`esm-schema.json`](https://github.com/EarthSciML/EarthSciAST/blob/main/esm-schema.json).

Design proposals and extensions live under [RFCs](rfcs/), including the
[discretization RFC](rfcs/discretization/) and
[DAE binding strategies](rfcs/dae-binding-strategies/).

## What's new

Recent changes are tracked via release notes in the
[GitHub releases page](https://github.com/EarthSciML/EarthSciAST/releases).
A curated changelog will be wired in here once available.
