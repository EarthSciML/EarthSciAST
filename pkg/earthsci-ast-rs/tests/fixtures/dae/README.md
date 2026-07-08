# Rust DAE-contract test fixtures (RFC §12 / gt-pmkd)

These fixtures exercise the **rust-binding-specific** trivial-DAE
preprocessing strategy described in
`docs/rfcs/dae-binding-strategies.md`. They are not cross-binding
conformance fixtures — the rust binding rewrites trivially factorable
DAEs to ODEs in-place rather than handing them to a DAE assembler, so
its post-`discretize()` output shape diverges from the
`tests/conformance/discretization/dae_missing/` expectations (which
require `metadata.system_class == "dae"` on the accepted path).

| Fixture | What it exercises |
|---|---|
| `pure_ode.json` | Baseline ODE; guards against false-positive DAE classification. |
| `trivial_observed.json` | Observed equation `y = x^2` alongside `dx/dt = -k*y`. The preprocessor factors `y` into the ODE; post-`discretize()` the system is a pure ODE with `factored_equation_count == 1`. |
| `nontrivial_implicit.json` | Implicit constraint `x^2 + y^2 = 1` alongside `dx/dt = y`. The LHS is not a bare variable, so the preprocessor cannot factor it — `discretize()` aborts with `E_NONTRIVIAL_DAE`. |

The integration test at `tests/dae_contract.rs` loads each fixture,
calls `discretize(esm, DiscretizeOptions { dae_support })` with both
`true` and `false`, and asserts the stamped metadata (or the error
code) per fixture. Unit-test-level coverage of the preprocessor itself
lives in `src/dae.rs` under `mod tests`.
