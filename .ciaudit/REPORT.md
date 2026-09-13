# Julia CI wall-clock audit — EarthSciAST
Branch `audit/julia-ci-runtime` (off main 1d17a4673). Nothing in the repo was modified.
All timings from GitHub Actions `conformance-testing.yml`, runs of 2026-09-12.

## 1. Baseline — whole workflow

| run | total | long pole | julia max leg | rust max leg | standard-conformance |
|---|---|---|---|---|---|
| 34703909739 | 98.1 m | julia-tests (1.12) 74.4 m | 74.4 m | 39.2 m | 21.8 m |
| 34702201266 | 75.3 m | julia-tests (1.11) 53.9 m | 53.9 m | 41.6 m | 21.1 m |
| 34700838214 | 79.0 m | julia-tests (1.12) 57.6 m | 57.6 m | 31.8 m | 21.2 m |
| 34671026222 | 67.3 m | julia-tests (1.11) 45.7 m | 45.7 m | 37.1 m | 21.4 m |
| 34665386076 | 87.7 m | julia-tests (1.11) 64.5 m | 64.5 m | 40.2 m | 22.9 m |

Julia is the long pole in 5/5. `standard-conformance-testing` has
`needs: [julia-tests, …]`, so it starts only after the SLOWEST julia leg, and
`conformance-results` follows it. Workflow total ≈ julia_max + ~22 min, in every run.

## 2. Where the julia leg's time goes

Step timings (run 34703909739):

| step | 1.10 | 1.11 | 1.12 |
|---|---|---|---|
| setup + checkout + setup-julia | 0:10 | 0:14 | 0:24 |
| Cache Julia packages (restore) | 0:00 | 0:19 | 0:19 |
| Install Julia dependencies (step 5) | 1:09 | 0:33 | 1:19 |
| **Run Julia tests — test-env resolve+precompile** | **9:05** | **1:10** | **24:26** |
| **Run Julia tests — actual test execution** | **30:24** | **44:03** | **47:14** |
| coverage process + codecov upload | 0:00 | 0:00 | 0:27 |
| Cache save (post) | 0:13 | 0:15 | 0:21 |

Two distinct costs. They have completely different fixes.

### 2a. Compile: the test-env precompile is cold ~40% of the time

`Pkg.test()` builds a SEPARATE environment (the `[targets] test` set, 26 extra
deps incl. ModelingToolkit / Catalyst / Reactant / SciMLBase) and precompiles it
under `--check-bounds=yes`, a different `Base.CacheFlags` configuration from the
default one step 5 builds. Verified locally:

    julia --check-bounds=yes  -> CacheFlags(check_bounds=1, …)
    julia (default)           -> CacheFlags(check_bounds=0, …)
    --code-coverage           -> does NOT change CacheFlags

So the 1.12 log line `Precompiling for configuration --code-coverage=… --check-bounds=yes …`
is driven by **check-bounds**, not coverage. That configuration IS cached
(`julia-actions/cache@v2` includes `~/.julia/compiled`), and the cost is bimodal:

| run | 1.10 | 1.11 | 1.12 |
|---|---|---|---|
| 34703909739 | 467 pkgs (cold) | 13 (warm) | 464 (cold) |
| 34702201266 | 40 | 465 (cold) | 0 (warm) |
| 34700838214 | 13 (warm) | 13 (warm) | 464 (cold) |
| 34671026222 | 467 (cold) | 13 (warm) | 13 (warm) |
| 34665386076 | 467 (cold) | 465 (cold) | 464 (cold) |

Cold = ~437 test-env packages rebuilt = 8–24 min. Warm = 40–70 s.
**6 of 15 legs cold (40%).**

Cause is NOT dependency drift: the resolved version sets of a cold 1.12 leg
(34703909739) and a warm one (34671026222) are byte-identical (303 entries, 0 diff).
Cause IS GitHub cache eviction:

    gh api repos/EarthSciML/EarthSciAST/actions/cache/usage
      active_caches_size_in_bytes = 11,632,188,610   (11.6 GB)
      active_caches_count = 24

against GitHub's **10 GB per-repo limit** — i.e. permanently over, in continuous
LRU eviction. Each julia leg saves a cache keyed `…;run_id=<unique>`, so every leg
saves ~0.8–1.5 GB on EVERY run: 3 legs × ~1 GB × ~20 runs/day ≈ 60 GB/day written
into a 10 GB budget. 3 of the 6 cold legs were outright `Cache not found`.

PR runs DO restore main's caches (34700838214, a PR run, restored
`run_id=34671026222`, a main push run) — so main-only saving is sufficient.

### 2b. Execution: no single hot test; a long, flat tail

A *failing* run prints the per-testset time tree (passing runs collapse it, because
the top-level `@testset` is not `verbose = true`). Run 34674490941 gives one for all
three legs — 329/330 depth-1 testsets:

| | 1.10 | 1.11 | 1.12 |
|---|---|---|---|
| suite total | 29m55s | ~31m | ~46m |
| top 1 testset | 10.1% | 10.4% | 9.4% |
| top 5 | 24.8% | 24.8% | 21.5% |
| top 10 | 37.5% | 36.4% | 32.1% |
| top 20 | 51.7% | 51.2% | 47.6% |
| testsets under 5 s | 252 of 329 (5.7 min total) | 246 | 206 |

Slowest testsets (seconds, 1.10 / 1.11 / 1.12):

| testset (file) | 1.10 | 1.11 | 1.12 |
|---|---|---|---|
| codegen shared-prelude reads (cg_foreign_scratch_test.jl) | 171 | 192 | 257 |
| codegen tier ≡ pre-codegen, B1 (codegen_kernel_test.jl) | 66 | 67 | 91 |
| Array-op runtime (array_ops_test.jl) | 61 | 57 | 86 |
| Real MTK Extension Integration (real_mtk_integration_test.jl) | 69 | 85 | 61 |
| MTK ext — interp.linear/bilinear | 12 | 14 | **80** |
| direct class emission | 55 | 57 | 72 |
| in-place RHS eltype-generic + zero-alloc | 44 | 43 | 61 |
| cross-equation + affine-box class emission | 47 | 46 | 61 |
| affine access kernels: AD + oop | 42 | 40 | 55 |
| parameter-vector ABI | 29 | 33 | 52 |

Greedy bin-packing of the measured depth-1 testsets:

| shards | 1.10 max | 1.11 max | 1.12 max |
|---|---|---|---|
| 1 (today) | 28.3 m | 30.8 m | 45.4 m |
| 2 | 14.1 | 15.4 | 22.7 |
| 3 | 9.4 | 10.3 | 15.1 |
| 4 | 7.1 | 7.7 | 11.3 |
| 6 | 4.7 | 5.1 | 7.6 |

Per-leg execution time is also very noisy run-to-run (1.11 ranged 31→44 min for the
same commit range), so single-leg comparisons are not reliable evidence; the
structural numbers above are.

### 2c. Coverage overhead — measured, and it is ~zero

Minimal dev-linked env (`.ciaudit/env`: EarthSciAST + ForwardDiff + JSON3 + Test,
julia 1.12.6), running the three slowest codegen testsets
(cg_foreign_scratch + direct_class_emission + cross_eq_class_emission = 390 s of the
1.12 CI leg), under `--check-bounds=yes` with and without
`--code-coverage=@pkg/EarthSciAST.jl` (exactly what `Pkg.test(coverage=true)` passes):

| rep | no coverage (real/user s) | coverage (real/user s) |
|---|---|---|
| 1 | 364.00 / 345.77 | 586.35 / 314.63 |
| 2 | 307.75 / 270.70 | 301.05 / 264.39 |

Rep 1 ran at load average ~29 on a 20-core shared box, so its `real` is contention,
not coverage — note its coverage run used LESS user CPU. Rep 2 is the clean pair and
shows coverage 2% FASTER, i.e. indistinguishable from zero.
Mechanism: Pkg scopes the flag to `--code-coverage=@<pkgdir>`, so only
EarthSciAST/src lines are counted; the hot work in these tests is in emitted RGF
kernels and dependency code. `Process Julia coverage` + Codecov upload cost 27 s.

**Coverage is not a wall-clock lever here.**

## 3. Projected effect, per run

julia_max today vs julia_max with every leg warm (cold penalty removed from the
legs measured cold):

| run | julia_max now | julia_max warm | rust_max | workflow now | workflow after A1+A2 |
|---|---|---|---|---|---|
| 34703909739 | 74.4 | 50.7 | 39.2 | 98.1 | 51.7 |
| 34702201266 | 53.9 | ~38 | 41.6 | 75.3 | 42.6 |
| 34700838214 | 57.6 | 40.3→46.4* | 31.8 | 79.0 | 47.4 |
| 34671026222 | 45.7 | 45.7 | 37.1 | 67.3 | 46.7 |
| 34665386076 | 64.5 | 45.4 | 40.2 | 87.7 | 46.4 |
| **mean** | **59.2** | **45.2** | **38.0** | **81.5** | **47.0** |

*the max moves to a different (already-warm) leg.

After A1 + A2 the workflow is ~47 min instead of ~81 min, and julia leads rust by
only ~7 min. That caps every further julia optimisation: a 2-way shard would put
julia under rust and make `rust-tests (stable)` the long pole; a 4- or 6-way shard
buys nothing beyond that.
