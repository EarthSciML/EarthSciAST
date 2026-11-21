---
title: "API reference"
description: "Every stable operation of the five EarthSciAST bindings, side by side."
type: "api"
api_tabs: true
---


EarthSciAST has five bindings — Julia, TypeScript, Python, Rust and Go — that read, check, transform and (in three of them) simulate the same `.esm` documents. This reference has one page per **stable** operation, with a tab for each binding showing its spelling, signatures and documentation, taken from the binding's own documentation tooling, along with runnable examples. The examples run in CI, so what is shown here is what the code does.

The surface has two tiers (see [API_SPEC.md §3](https://github.com/EarthSciML/EarthSciAST/blob/main/API_SPEC.md#3-surface-tiers)). **Stable** names are harmonized across bindings and break only at a major version. **Extension** names are a binding's own documented seams; they may differ between bindings and may change in a minor release, and each binding lists them on one page.

## Guides

- [Getting started](/generated/api/guides/getting-started) — Load a document, check it, look inside, print it, change it, flatten a coupled one, derive a reaction system's equations, and simulate.

## Capability profiles

Not every binding does everything. An operation missing from a binding outside its profile is by design, and the operation's page says so.

| Profile | Covers | Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|---|---|
| core | parse / serialize / validate / display / canonicalize / graph / edit / flatten | yes | yes | yes | yes | yes |
| classification | esm-spec §6.3.1 derived variable classification | yes | yes | yes | yes | yes |
| simulation | build an RHS and integrate it; TypeScript and Go are deliberately non-simulating | yes | — | yes | yes | — |
| runtime I/O | data-source providers, refresh cadence, output sinks, checkpoints | yes | — | yes | yes | — |

## Topics

- [Document I/O](/generated/api/topics/document-io) (15) — Reading a document from a path, a string or a parsed value, and serializing it back to JSON.
- [Versions and migration](/generated/api/topics/versions) (9) — The format and library version constants, and migrating a document written for an older version of the format.
- [Validation](/generated/api/topics/validation) (11) — Checking a document against the schema and the structural rules of the specification, and reading the errors that result.
- [Document types](/generated/api/topics/document-types) (45) — The in-memory types that mirror the sections of an .esm document: models, variables, equations, reaction systems, domains, events, data sources and more.
- [Variable classification](/generated/api/topics/classification) (20) — Which variables of a model are integrated states, algebraic unknowns, observed quantities or parameters of each kind (esm-spec section 6.3.1).
- [Expressions](/generated/api/topics/expressions) (20) — Parsing, inspecting, substituting into, simplifying and evaluating expressions and equations.
- [Display](/generated/api/topics/display) (4) — Rendering expressions, equations, models and whole documents for people, as plain text, Unicode or LaTeX.
- [Editing](/generated/api/topics/editing) (23) — Adding, removing and renaming the parts of a document, and composing, merging and extracting components.
- [Flatten](/generated/api/topics/flatten) (20) — Turning a coupled document into a single system of variables and equations, and the errors coupling can raise.
- [Load-time lowering and templates](/generated/api/topics/lowering) (20) — The passes a loader runs before a document is usable: enum lowering, subsystem references, expression templates and coupling imports.
- [Graphs](/generated/api/topics/graphs) (22) — Component, expression and reference graphs of a document, and exporting them as DOT, Mermaid or JSON.
- [Reactions](/generated/api/topics/reactions) (5) — Deriving ordinary differential equations from a reaction system, and its stoichiometric matrices.
- [Units](/generated/api/topics/units) (15) — Parsing unit strings, converting between units and checking the dimensional consistency of equations.
- [Simulation](/generated/api/topics/simulation) (24) — Building a problem from a document, integrating it, and reading states and observed quantities from the solution.
- [Runtime I/O](/generated/api/topics/runtime-io) (14) — Refresh cadence, output planning and gridding: the protocol a host uses to feed data into and write results out of a running simulation.
- [Relational keys and geometry](/generated/api/topics/relational) (11) — Deterministic keys, ranking and grouping for relational index sets, and the polygon geometry used by regridding.
- [Errors](/generated/api/topics/errors) (4) — The base error type, the parse error, and the table of diagnostic codes shared by every binding. Errors specific to one operation are listed with it.
- [Other](/generated/api/topics/other) (23) — Stable operations not yet placed in a topic.

Or browse [all stable operations A–Z](/generated/api/ref).

## Bindings

| Binding | Package | Version | Docs from | Stable | Extension |
|---|---|---|---|---|---|
| [Julia](/generated/api/bindings/julia) | `EarthSciAST.jl` | 0.7.0 | Base.Docs (Julia 1.13.3) | 203 | [141](/generated/api/extension/julia) |
| [TypeScript](/generated/api/bindings/typescript) | `@earthsciml/ast` | 0.7.0 | typescript 6.0.3 compiler API | 154 | [91](/generated/api/extension/typescript) |
| [Python](/generated/api/bindings/python) | `earthsci-ast` | 0.7.0 | griffe 2.3.2 | 237 | [37](/generated/api/extension/python) |
| [Rust](/generated/api/bindings/rust) | `earthsci-ast` | 0.7.0 | rustdoc JSON (rustdoc 1.101.0-nightly (21b707e3f 2026-09-30)), format_version 61 | 239 | [148](/generated/api/extension/rust) |
| [Go](/generated/api/bindings/go) | `github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm` | 0.7.0 | go/doc go1.26.10 | 184 | [289](/generated/api/extension/go) |

[Documentation coverage](/generated/api/coverage) lists the stable names each binding has not documented yet.
