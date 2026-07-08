# tests/future/ — Staged fixture corpora awaiting wiring

This directory holds fixture sets that were authored with a clear intent (each
subdirectory has its own README explaining the test categories) but were never
wired into any binding's test suite or the cross-language conformance harness.

They live here instead of being deleted because the authoring cost was real and
the fixtures may be useful if the corresponding test wiring is ever implemented.

## Contents

| Subdirectory    | Size | Intent                                                      | Candidate consumer                              |
|-----------------|-----:|-------------------------------------------------------------|-------------------------------------------------|
| `robustness/`   |   22 | Stress / memory / numerical / recursion edge cases          | Per-binding stress suite (not yet scoped)       |
| `security/`     |   17 | Security vectors: XML bomb, injection, unicode attacks, etc. | Per-binding parser hardening suite             |
| `expressions/`  |   17 | Expression AST round-trip / parser error / evaluation tests | gt-tvz shared conformance harness, gt-72z fuzz  |
| `reactions/`    |    4 | Reaction-system ODE generation + stoichiometric matrices    | Binding-level reaction-system tests             |
| `domain_solver/`|    7 | Spatial/temporal domain discretization + solver configs     | Binding-level domain/solver tests               |
| `editing/`      |    5 | Editor operation fixtures (add/remove/merge/extract)        | `pkg/earthsci-ast-editor` test suite                |

## Decision rule

If a subdirectory here is still unwired by **2026-10-15** (six months from
staging), delete it. The intent clearly didn't materialize and the fixtures are
costing more than they're worth to keep in the tree.

If you wire a subdirectory into a test suite, promote it back up to `tests/` and
update the cross-language harness or binding-specific runner that consumes it.

## Context

These were triaged out of the root `tests/` directory in gt-57c (2026-04-15).
See that bead for the full audit of which subdirectories were orphaned and why.
