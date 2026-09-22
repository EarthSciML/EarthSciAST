# `data_source_unbound` — a forcing nothing bound is refused, not defaulted

A **data-fed parameter** is one whose `update` is `{kind: "data", source: …,
from: {file_variable: …}}` (esm-spec §5.4, §8.5). From esm 1.0.0 that parameter
IS the loaded field: a data source is not a component and has no coupling edge,
so the `update` block is the whole of the document's statement that this number
comes from a file.

This category pins what happens when a build is asked for and **nothing bound
it** — no provider object for it, no array loaded for it, no caller-supplied `p`
value for it. The ruling is REFUSAL at construction, with the diagnostic
`data_source_unbound` (esm-spec §9.6.6), naming the parameter, the
`data_sources` entry, and what the caller can pass instead.

## Why refusal, and not the `default`

Because the alternative is not a missing number, it is a **whole trajectory that
looks like an answer**. `unbound_scalar_forcing.esm` declares `Forcing.k` with a
`default` of 0.1. Run it with nothing bound and you get `x(1) = exp(-0.1) =
0.9048…`, reported under the label of a decay rate the document says is read
from `Wind`. Nothing in the result records that `Wind` was never opened; the
number is well-formed, plausible, reproducible, and wrong. A refusal costs the
caller one line — pass `providers`, or pin the parameter with `p` — and a
default-valued run costs them the result.

The shaped fixture makes the same point from the other side.
`unbound_array_forcing.esm` gives `Forcing.k` a `shape` and **no** `default`,
because a field has no scalar placeholder to fall back to. Whatever a binding
produces there is a property of how it seeded an array, not of the document.

## The ruling is a document contract, not a compiler capability

The refusal MUST be identical in shape under `compiler=native` and
`compiler=interpreter`. Whether a particular compiler can *lower* a read of the
forcing channel is a separate question with its own code
(`compiler_refused_rule`); whether anything *bound* the forcing is decided before
any right-hand side is built, and is the same answer for every compiler. A
binding whose two compilers disagree here — one refusing and one running — is
reporting a compiler property in place of a document property, which is what
this category fails.

## The escape hatch is a control, not a loophole

A caller who passes an explicit `p` value for the parameter **has bound it**.
That is how a data-fed document runs offline, and it is how its own inline tests
run at all — `Test.parameter_overrides` (esm-spec §6.6) is the `p` argument of
`esm_problem` by another name. `control_caller_pins_the_forcing.esm` is
`unbound_scalar_forcing.esm` with that pin, and it must BUILD and RUN and report
`exp(-0.5)`, not `exp(-0.1)`: the pinned rate has to reach the right-hand side,
not merely silence the refusal.

`control_plain_parameter.esm` is the other control — the same document with the
`update` block deleted, so 0.1 really is the parameter's value. It takes the same
evaluator and must still run, which is what attributes the refusals in this
category to the unbound data feed rather than to the document's shape.

## `unresolvable_source` accepts two codes

`unresolvable_source.esm` names a source the document does not declare. That is
a VALIDATION defect with its own code — `data_source_undefined`, esm-spec §8.5,
pinned by `tests/invalid/data_source_undefined_reference.esm` — and a binding
whose simulation front door runs structural validation reports it as such and
never reaches the build. A binding whose front door does not must still refuse,
and the reason it refuses is this category's: a source that does not resolve is
not a source that is bound. The manifest therefore lists both codes in
`accepts`, and a case is green under either. What no binding may do is what two
of them did before this category existed: drop the loader field on the floor
(because its source did not resolve), leave the parameter looking ordinary, and
integrate it at its `default`.

## What each binding did before the ruling

Measured on these fixtures, 2026-09-22, before the change:

| Binding | Compiler | Unbound data-fed parameter, nothing passed |
|---|---|---|
| Julia | `native` and `interpreter` | Built, bound `Forcing.k` from its `default` of 0.1, and reported `x(1) = 0.9048374180359661`. The shaped fixture refused with an uncoded `E_TREEWALK_UNSUPPORTED_SHAPE`. |
| Python | `native` and `interpreter` | Built. The in-tree default provider tried the declared URL at construction, failed, and the failure was stashed in the problem's segment seed; `solve` then raised an uncoded `AttributeError` from inside the loader driver. The `p` pin did not help — it took the same path. |
| Rust | `native` | Refused, but as `compiler_refused_rule` — "wholesale: unresolved symbol (forcing/NaN sentinel?) `k`" — which reports the tape's limits in place of the document's defect, and which the `p` pin did not clear. |
| Rust | `interpreter` | Built, and refused at SOLVE with an uncoded `E_TREEWALK_UNBOUND_NAME`. |

Three different answers to one question, none of them a registered code, and one
of them a number.

## Files

| Fixture | Expect |
|---|---|
| `unbound_scalar_forcing.esm` | refuse — scalar forcing, `default` 0.1, source resolves |
| `unbound_array_forcing.esm` | refuse — shaped forcing, no `default` |
| `unresolvable_source.esm` | refuse — the `update.source` names no declared source |
| `control_caller_pins_the_forcing.esm` | run — the same document, `Forcing.k` pinned to 0.5 |
| `control_plain_parameter.esm` | run — the same document with no `update` block |

Consumed by `pkg/EarthSciAST.jl/test/data_source_unbound_conformance_test.jl`,
`pkg/earthsci-ast-py/tests/test_data_source_unbound_conformance.py` and
`pkg/earthsci-ast-rs/tests/data_source_unbound_conformance.rs`. The normative
statement is CONFORMANCE_SPEC.md §5.46.
