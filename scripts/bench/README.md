# Phase-0 bench harness

Canonical performance fixtures + a regression gate for the perf-gap-closure plan
(`reseact.esm/prototypes/perf-gap-closure-plan.md`, Phase 0). One command prints
the baseline table for HEAD and writes JSON; `--compare` fails loudly on >10%
regression against the committed baseline.

## Usage

From the repo root:

```sh
# fast fixtures (proxy27, t3d_7x7x7) + reference kernel  (~15 min)
julia --project=pkg/EarthSciAST.jl scripts/bench/run_bench.jl

# additionally the 7x7x72 fixture (~25 min build on current main)
julia --project=pkg/EarthSciAST.jl scripts/bench/run_bench.jl --full

# regression gate: nonzero exit if any tracked metric regresses >10%
julia --project=pkg/EarthSciAST.jl scripts/bench/run_bench.jl --compare
```

Options: `--json=PATH` (results JSON, default `scripts/bench/results.json`),
`--baseline=PATH` (default `scripts/bench/baseline.json`),
`--only=proxy27,t3d_7x7x7,t3d_7x7x72,ref_kernel`.

Environment: `RESEACT_ROOT` (reseact.esm checkout; defaults to the real sibling
path) and `ESD_ROOT` (EarthSciDiscretizations; defaults to a sibling of
`RESEACT_ROOT`).

The first run instantiates `scripts/bench/Project.toml` (BenchmarkTools /
ForwardDiff live there, stacked onto `LOAD_PATH` — they are test-only deps of
the package and are not added to the package project).

## What is recorded per fixture

- `build_s` — `build_evaluator` wall time (compile-once tier counters on);
  for proxy27 also `build_warm_s`, a second in-session rebuild with the build
  machinery already JIT-compiled (the number `08c4985b` quotes).
- `body_variants` / `compile_calls` — `EarthSciAST._BENCH_BODY_VARIANTS[]` /
  `_BENCH_COMPILE_CALLS[]` (enabled via `_BENCH_ON[]` + `_bench_reset!()`).
- `rhs_f64_s` / `rhs_f64_allocs` — warm in-place `f!(du,u,p,t)` time
  (BenchmarkTools minimum) and bytes/call at Float64.
- `rhs_dual_s` / `rhs_dual_allocs` — same through the SAME in-place evaluator
  at `ForwardDiff.Dual{Nothing,Float64,1}` eltype (the tree-walk RHS is generic
  in its value type; see `test/tree_walk_iip_generic_test.jl`).
- `peak_rss_mb` — `VmHWM` from `/proc/self/status` (process high-water mark;
  monotone across fixtures, so read it as "peak so far", ordered
  proxy27 → t3d_7x7x7 → t3d_7x7x72).

## Fixtures

| name | what | notes |
|---|---|---|
| `proxy27` | `fixtures/proxy27.esm` — 3×3×3, 27 states, branch-free donor-cell upwind along lon+lev, no-flux walls, 9 region classes | Self-contained reconstruction of the ephemeral "controlled 27-box proxy" used to validate `08c4985b` (the original was never committed). Exercises the affine access-kernel lowering + box classes without ESD imports. |
| `t3d_7x7x7` | ReSEACT Stage-B analytic-winds monotone-PPM transport, 7×7×7, 1029 states | Loaded from `RESEACT_ROOT/prototypes/transport_3d/transport_3d.esm` when that artifact matches the on-disk ESD rule contract; otherwise regenerated from the ESD exemplar by `gen_transport_fixture.py` (see below). |
| `t3d_7x7x72` | same physics on the full 72-level GEOS-FP column, 7×7×72 (`--full` only) | Always regenerated (72-level needs the `reseact_3d/hybrid_coefs.json` hybrid table). Stand-in for `reseact_3d.esm`, which cannot load on this machine (its GEOSFP subsystem refs `EarthSciModels/components/earthsci_data/geosfp.esm`, not present). |
| `ref_kernel` | `ref_kernel.jl` — hand-written CW84 monotone-PPM lon face-flux + divergence loop over 7×7×72 | The denominator for the plan's "RHS within 2–3× of hand-written" gate. `rhs_equiv_s` = 9 × one-tracer lon sweep (3 axes × 3 advected fields, the m/mq/dev structure). A cost yardstick, not a conformance artifact. |

### Why fixtures are (sometimes) regenerated

`prototypes/transport_3d/transport_3d.esm` is a *generated artifact* that tracks
the ESD regional-inflow rule contract (1-operand vs 3-operand `D` after ESD
`e358325`). When the committed artifact and the on-disk ESD checkout disagree,
`run_bench.jl` regenerates the fixture from
`ESD_ROOT/problems/latlon3d_transport_cwc_regional_inflow.esm` with
`gen_transport_fixture.py` (a parameterized port of the prototype's
`gen_t3d.py`), staged in a temp dir with a symlink so the
`../../../EarthSciDiscretizations/...` refs still resolve to the live checkout —
rules are imported by reference, never copied. The chosen path is recorded as
`source` in the JSON, and `--compare` warns when it differs from the baseline's.

## Baseline

`baseline.json` is a committed `run_bench.jl` output (same schema). It is
machine-specific (recorded on the 20-core baseline box; wall-clock numbers move
with hardware and load — the counters and allocs do not). To re-baseline after
an intentional change:

```sh
julia --project=pkg/EarthSciAST.jl scripts/bench/run_bench.jl --full --json=scripts/bench/baseline.json
```

`--compare` checks, per fixture present in both files:
`build_s`, `build_warm_s`, `rhs_f64_s`, `rhs_dual_s`, `rhs_*_allocs`,
`body_variants`, `compile_calls`, `sweep_s`, `rhs_equiv_s` — failing on any
value >10% above baseline.
