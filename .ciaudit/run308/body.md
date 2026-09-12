The conformance workflow takes ~81 min. The julia matrix is the long pole in
every run measured, and the harness that follows it adds a flat ~22 min. None of
that is test rigor: the same tests run before and after this PR, plus one new
assertion.

## Measured baseline (before)

Runs 34703909739, 34702201266, 34700838214, 34671026222, 34665386076:

| run | total | long pole | julia max | rust max | conformance |
|---|---|---|---|---|---|
| 34703909739 | 98.1 m | julia (1.12) 74.4 m | 74.4 | 39.2 | 21.8 |
| 34702201266 | 75.3 m | julia (1.11) 53.9 m | 53.9 | 41.6 | 21.1 |
| 34700838214 | 79.0 m | julia (1.12) 57.6 m | 57.6 | 31.8 | 21.2 |
| 34671026222 | 67.3 m | julia (1.11) 45.7 m | 45.7 | 37.1 | 21.4 |
| 34665386076 | 87.7 m | julia (1.11) 64.5 m | 64.5 | 40.2 | 22.9 |

Julia is the long pole 5/5, and workflow total is julia_max + ~22 min every time.
Inside a julia leg the time is two unrelated things — a test-env precompile
(40-70 s warm, 8-24 min cold) and 25-45 min of serial test execution — which need
different fixes.

## What each commit does

**`perf(ci): run cross-language conformance concurrently with the suites`**
`standard-conformance-testing` had `needs: [julia-tests, …]`. It has no data
dependency on those jobs — own checkout, own `Pkg.instantiate`, own npm/pip/cargo
builds, downloads no artifact — so the list bought ordering, not inputs, and cost
a flat ~22 min because it could not start until the slowest julia leg finished.

This changes a real behaviour, deliberately: a conformance verdict can now appear
alongside a RED binding suite, where before a red suite left conformance
`skipped` with no verdict. The verdict is real but was computed against a binding
whose suite did not pass, so it is not evidence the binding is correct. The
workflow's overall verdict is unchanged — every per-language job still fails it
on its own. `--skip-binding-suites` is untouched and still load-bearing.
`conformance-results` keeps its `skipped` branch (nothing can skip the harness
now, but `skipped` must never read as a pass), with its message and the
PR-comment rationale corrected.

**`perf(ci): restore the julia depot everywhere, save it only from main`**
The test-env precompile was fully cold on 6 of 15 legs sampled — ~437 packages
rebuilt under `--check-bounds=yes`. Not dependency drift: the resolved version
sets of a cold 1.12 leg (34703909739) and a warm one (34671026222) are
byte-identical, 303 entries, zero diff. It was eviction. `actions/cache/usage`
reported **11.6 GB across 24 caches against GitHub's 10 GB limit**, the ten
largest all julia depots, because `julia-actions/cache` keys every save on a
unique `run_id` and caches are scoped per ref — so each live PR kept its own full
set, 3 legs x ~1 GB x ~20 runs/day into a 10 GB budget.

Restore stays everywhere; save happens only on `main`. PRs lose nothing: a PR run
can read its base branch's caches, and did — run 34700838214 (a pull request)
restored the cache written by run 34671026222 (a push to main). The key is pinned
to the package `Project.toml` rather than the run, so main re-saves only when
dependencies change and the exact-key hit no-ops the rest of the time, which
bounds the cache count with no deletion step. Tradeoff, stated plainly: a depot
no longer tracks upstream drift between `Project.toml` changes, so warm runs
re-precompile whatever actually moved. `v1` in the key is a hand-bumpable epoch.

**`test(julia): print the per-testset time table on every run`**
A passing `DefaultTestSet` prints one line; the tree with the `Time` column
appears only on failure, so the suite's cost profile was visible only on red runs.
`verbose = true` publishes it on every run at no runtime cost. It is also what
makes the shard evidence below readable.

**`perf(julia): split the test suite across two parallel shards`**
No single hot test exists — the slowest testset is 9-10% of the suite, the top
five are 21-25%, and 206 of ~330 finish under 5 s. So: `ESM_TEST_SHARDS` /
`ESM_TEST_SHARD`, round-robin by position. Defaults are one shard, so local
`Pkg.test()` is unchanged.

## Measured: this PR's own CI run (34715642294)

**Every leg in this run was COLD. These are not the steady-state numbers.** The
depot saves only from `main`, so this PR restores nothing under the new
`julia-depot-v1-…` key; and 1.13 arrived with #306 and has no depot under any key
at all. All six legs logged `Cache not found`.

| leg | job | setup | restore | install | precompile | suite exec | cache |
|---|---|---|---|---|---|---|---|
| 1.10 shard 1 | 30.8 m | 0.2 | 0.0 | 1.1 | ~8.9 | 20m28s | COLD (467 pkgs) |
| 1.10 shard 2 | 29.8 m | 0.1 | 0.0 | 1.1 | ~9.3 | 19m13s | COLD (467 pkgs) |
| 1.12 shard 1 | 45.7 m | 0.3 | 0.0 | 1.0 | ~18.2 | 25m50s | COLD (466 pkgs) |
| 1.12 shard 2 | 58.6 m | 0.2 | 0.0 | 1.3 | ~24.2 | 32m18s | COLD (466 pkgs) |
| 1.13 shard 1 | 39.9 m | 0.2 | 0.0 | 1.1 | ~15.7 | 22m49s | COLD (438 pkgs) |
| 1.13 shard 2 | 27.9 m | 0.2 | 0.0 | 0.8 | ~11.5 | 15m18s | COLD (438 pkgs) |

Whole workflow: **83.9 min**, against the 81.5 min mean baseline. On a
fully-cold run this PR is not faster, and that is expected — the cache commit
cannot show its value until a depot exists. What IS visible now:

* `standard-conformance-testing` passed in **20.0 min running concurrently**,
  finishing at +38 min into an 83.9 min run. A1 delivered, measured.
* Suite execution is halved per job: max 20m28s (1.10), 32m18s (1.12), 22m49s
  (1.13) against serial baselines of 25.5 min mean (1.10) and 37.4 min mean
  (1.12).

### Shard balance

Pure execution time, between `Testing Running tests` and `Test Summary`, so
precompile is excluded:

| version | shard 1 | shard 2 | split |
|---|---|---|---|
| 1.10 | 20m28s | 19m13s | 52 / 48 |
| 1.12 | 25m50s | 32m18s | 44 / 56 |
| 1.13 | 22m49s | 15m18s | 60 / 40 |

1.12's skew is mostly runner variance, not the split: both shards precompiled
**exactly 466 packages** — byte-identical work — and took 18.2 vs 24.2 min, a
1.33x runner-speed difference. Normalising the suite times by that factor gives
≈51/49.

1.13's skew is genuinely the split. 1.13 is slower than 1.10 on several testsets
that happen to land on odd positions — `table_lookup lowering on the evaluation
path (§9.5.3)` is 29 s on 1.10 and 89 s on 1.13, and `tree_walk.jl evaluator`,
`merged_rename_reach` and `polygon_intersection_area` add ~43 s more. Round-robin
is balance-agnostic by design, so it can skew when one version's slow testsets
cluster in a single parity class. It is still a large win on 1.13 (22m49s max
against ~38 min of combined work); if it ever matters the fix is reordering the
list, not changing what runs.

### An honest correction to the sharding projection

Sharding was projected to halve execution. It does not, quite: combined execution
across both shards is 39.7 min on 1.10 and 58.1 min on 1.12, against serial
baselines of 25.5 and 37.4 min — **about 55% more total work**. Per-testset times
include the JIT compilation each testset triggers, and two processes re-pay the
overlapping parts of that. The wall-clock win per leg is therefore ~5 min on 1.10
and ~5-12 min on 1.12, not the ~20 min the additive projection suggested.

That matters for what the second shard is worth. Projected steady state below
puts julia at ~28-35 min against `rust-tests (stable)` at 40.2 min, so **rust
becomes the long pole and the second shard buys little at the workflow level
today**. Its value is headroom: julia stops being the pole and stays off it as
the suite grows. The wins that move the workflow number are the first two commits.

## Projected steady state (a projection, not a measurement)

Once a depot exists on `main` under the new key, precompile drops from 8-24 min
to the 40-70 s observed on warm legs in the baseline sample:

| leg | projected |
|---|---|
| 1.10 | ~23 min |
| 1.12 | ~28-35 min |
| 1.13 | ~25 min |
| rust-tests (stable), measured | 40.2 min |

Workflow ≈ **40-45 min** against the 81.5 min baseline mean, with rust as the new
long pole. The first main run after merge will still be cold; the second is the
steady-state number.

## Cache footprint

| | caches | size |
|---|---|---|
| before | 9 julia + 16 other | 8.33 + 2.26 = **10.6 GB** (over the 10 GB limit) |
| after | 3 julia + 16 other | 2.56 + 2.26 = **4.8 GB** |
| after, worst-case julia size | 3 julia + 16 other | **7.4 GB** |

Both shards share one depot key (no shard component) and only shard 1 saves, so
sharding does not multiply the cache count.

**Side effect, stated plainly:** on a cache MISS the two shards each precompile
the same dependency set independently — 466 packages twice on 1.12 in this run.
It is wall-clock neutral because they run in parallel, but it doubles the
runner-minutes spent precompiling on the first run after any `Project.toml`
change. Warm runs both restore the same depot and pay it once.

## Rigor

The partition is the whole argument for sharding, so it is asserted rather than
claimed. Every shard walks the entire list and registers every unit, skipping
only bodies it does not own, so the registry is identical everywhere and new
`shard_include` lines are assigned automatically instead of through a
hand-maintained list that can drift. `shard_partition_test.jl` runs
unconditionally in every shard and checks that, for the configured shard count
and a spread of others, the assignment is total, in range, covers every unit and
is pairwise disjoint — and that this process ran exactly its own units in order.

Verified locally before pushing: 217 units split 109/108, union equal to the full
list, intersection empty, unsharded equal to everything, bad shard index rejected
at startup. Verified discriminating: sabotaging the owner function to drop every
fifth unit turns the range, union and size assertions red.

Verified in this CI run, on all three versions — the per-testset tables that
`verbose = true` now prints were diffed between shards:

| version | shard 1 testsets | shard 2 testsets | appearing in BOTH |
|---|---|---|---|
| 1.10 | 165 | 167 | 1 |
| 1.12 | 165 | 167 | 1 |
| 1.13 | 165 | 167 | 1 |

That single overlap is `shard partition (ESM_TEST_SHARDS/ESM_TEST_SHARD)` itself,
which is deliberately unconditional. Every other testset ran in exactly one
shard, on every version. The partition test passed 55/55 in all six legs.

The inline "Fixture sweeps" block takes a shard slot explicitly via
`shard_claim`; otherwise it would run in both shards and the partition would be
false.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
