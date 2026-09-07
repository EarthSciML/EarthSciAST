# `mounted_component_tests` — inline tests do not cross a mount edge

Shared fixtures pinning the esm-spec §6.6 rule that a **mounted component's
inline tests are not part of the mounting document**, across the three bindings
that run inline tests (Julia, Python, Rust; see `API_SPEC.md`).

## The rule

A component's `tests` are assertions about that component under *its own*
standalone conditions. A document that mounts it — a top-level `models` /
`reaction_systems` entry that is a `{ref}` mount object (§4.7, §9.7.10) — may
legitimately change those conditions: a `variable_map` entry replaces one of its
parameters with another component's state (§10), a mount-edge
`expression_template_imports` lowers it under a different discretization
(§9.7.10), a mount-edge `bindings` closes a metaparameter at another value
(§9.7.6). Re-running the leaf's assertions there checks a claim its author never
made, and reports a component that is correct as broken.

So the mount **drops** the mounted component's `tests` at load. They run when the
mounted component's own file is the test target — which a directory-wide test run
reaches anyway, so nothing goes unasserted.

## The fixtures

| File | Role |
|---|---|
| `fixtures/leaf.esm` | `Decay`: `du/dt = −k·u` with `k` defaulting to 1, plus its own inline test asserting `u(1) = 1/e`. Passes standalone. |
| `fixtures/assembly.esm` | Mounts `leaf.esm` as `Decay` by a top-level `models` `{ref}`, adds its own `Forcing` component, and couples `Forcing.rate → Decay.k` (`param_to_var`), so the mounted leaf runs at `k = 5`. |

The coupling is what makes the pair a *gate* rather than a smoke test: with the
mounted tests re-run, `u(1) = exp(−5) ≈ 0.0067` against an expected `exp(−1) ≈
0.368` — a failure two orders of magnitude wide, which no tolerance hides. The
assembly's own test (`Forcing.forcing_holds_its_rate`) is the control: it must
still run, so a binding cannot pass by refusing to run anything.

## What each binding asserts

Driven by per-binding test files rather than by a harness manifest, in the manner
of `pkg/earthsci-ast-rs/tests/subsystem_mount_join_names.rs`:

- `pkg/EarthSciAST.jl/test/mounted_component_tests_test.jl`
- `pkg/earthsci-ast-py/tests/test_mounted_component_tests.py`
- `pkg/earthsci-ast-rs/tests/mounted_component_tests.rs`

Each one checks the same three things: the leaf passes standalone; the assembly's
inline-test run yields rows for `Forcing` and none for `Decay`; and the loaded
assembly's `Decay` carries no `tests` while keeping the rest of the leaf's
content (the drop happens at the mount, not in the runner, so every consumer of
the assembled document agrees about what it asserts).

Reported as issue #198 item 2, where a leaf that passes standalone contributed
767 ERROR/FAIL rows to the document that mounted it.
