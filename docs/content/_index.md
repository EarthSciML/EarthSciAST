---
title: "EarthSciAST"
description: "Language-agnostic JSON-based format for earth science model components."
---

**EarthSciML Serialization Format** — a language-agnostic JSON-based format for
earth science model components, their composition, and runtime configuration.

Every model is fully self-describing: all equations, variables, parameters,
species, and reactions live in the document itself, so a conforming parser in
any language can reconstruct the complete mathematical system without executing
author-supplied code.

Reference implementations exist in Julia, TypeScript, Python, Rust, and Go.
All share `esm-schema.json` and a common conformance suite.

## Documentation

**[File structure](file-structure/)** — what goes in an `.esm` document, section
by section, with examples.

**[Operators](operators/)** — the expression vocabulary: what each operator
does, what arguments it takes, what it returns, and worked examples.

**[Coupling](coupling/)** — how components are composed: variable maps, additive
and multiplicative coupling, operator apply and compose, and events.

**[Expression templates](templates/)** — `match` rewrite rules, how imports and
metaparameters work, and how spatial discretization is expressed.

## Reference

- [`esm-spec.md`](https://github.com/EarthSciML/EarthSciAST/blob/main/esm-spec.md)
  — the authoritative, normative specification. Everything here is a guide to it.
- [`esm-schema.json`](https://github.com/EarthSciML/EarthSciAST/blob/main/esm-schema.json)
  — the machine-readable schema; single source of truth for field names and types.
- [Standard library](standard_library/) — the shipped `.esm` library files.
- [Units](units-standard/) — the unit-string grammar and registry.
- [RFCs & design notes](rfcs/) — design proposals and the reasoning behind them.
