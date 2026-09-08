# Issue #234 — WIP findings (scratch; to be removed before the PR)

## Verified reproduction
`pkg/earthsci-ast-rs/target/release/esm test <file>`

- `delta_direct.esm`  -> 3 pass
- `delta_split.esm`   -> 3 err: "Exceeded maximum number of nonlinear solver failures (51) at time = 39.76304343430315"
- `alias_split_N58_passes.esm` -> passes
- `alias_split_N59_fails.esm`  -> same solver error
- `alias_direct_N70_passes.esm` -> passes

## The reported "size threshold" is an artefact
`ESS_TAPE_CHECK=1` bit-compares the taped RHS against the legacy per-cell oracle.

- delta_direct            -> no divergence
- delta_split             -> `dy[0] diverged at t=0: tape -2.88e-1 vs legacy 0e0`
- alias_split_N58_PASSES  -> **same divergence**  <-- it is equally wrong, it just
                              happens to keep integrating, and its tolerance is 1e9
- alias_direct_N70        -> no divergence

So the alias corrupts the RHS at EVERY size. lev=58 vs 59 is not a threshold in the
bug, only in whether the corrupted ODE defeats the Newton solve.

Also: `alias_direct_N70_passes.esm` is not a valid "bigger system" control — its
stencil bound is hardcoded `min(59, k+1)` while `lev.size` is 70.

## Path bisection (on alias_split_N59_fails.esm)
- ESS_TAPE_DISABLE=1  -> PASSES
- ESS_VEC_DISABLE=1   -> PASSES
- ESS_TAPE_SIMD_DISABLE=1 -> still fails
- ESS_TAPE_FUSE_DISABLE=1 -> still fails

=> the defect is in the tape lowering (`src/simulate_array/tape/`), not in the DAE
   structure, the solver, initialisation or conditioning.

## Wrong value
tape dy[0] = -0.288 = rlx * (0 - 288) => the tape evaluates `Tsfc` as 0 instead of 288.
The alias's value never reaches the consumer.

## Minimal discriminators (.scratch/var/)
| probe | shape | result |
|---|---|---|
| s1_bare_alias_scalar | scalar consumer, `Tsfc = Tsfc_raw` | ok |
| s2..s7 scalar variants | ok |
| a1_bare_alias_N4 / N59 | array (`aggregate`) consumer | **DIVERGED** |
| a2_arith_alias_N4 / N59 | alias body `Tsfc_raw * 1.0` | ok |
| a3_direct_N4 / N59 | no alias | ok |
| a4_alias_into_D_N4 / N59 | alias read straight from the `D` rule body | **DIVERGED** |

=> trigger is: an observed whose defining body is a BARE `Expr::Variable`
   (so its lowering emits NO instruction and reuses the producer's LV),
   read from an array/per-cell rule body. N is irrelevant (N=4 reproduces).

## Suspect
`compute_exports` in `src/simulate_array/tape/lower.rs`: for a rule that emitted
nothing, `rule_home_chunk[ord]` is None and the `Export` is appended at the END of
the cadence stream, after its consumers. Not yet confirmed — need the tape report.
