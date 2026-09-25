# Scaling tier: build and run-time gates for `compiler = native`

The native universal-coverage plan sets four measurable targets for the
`native` compiler: its compiled code does not grow with the number of cells N,
its build costs under 20 ns per state beyond a constant, each right-hand-side
call stays within 1.25x of a hand-written loop (serially and threaded), and a
steady call allocates nothing. This tier turns each target into a gate that can
fail, over generated document families from 10^2 to 10^6 cells.

It measures; it does not change what any compiler does. The interpreter stays
the correctness oracle: other tiers (`compiler_agreement`, `compiled_rhs`)
check native against it, and the Rust wasm suite checks the committed small
fixtures here the same way.

## Layout

```
tests/conformance/scaling/
├── README.md            # this file: running it, the result format, the gates
├── generate.py          # the one shared generator (deterministic)
├── manifest.json        # families, size ladders, gates and thresholds, the ledger
├── check.py             # applies the gates and the ledger to result files
├── test_check.py        # the checker's own test, on canned result files
├── sweep.sh             # the Slurm driver for the full ladder (submits sweep.sbatch jobs)
├── sweep.sbatch         # one sweep job: one family, every size, one thread mode
├── vendor/
│   └── pollu_reaction_system.json   # the Pollu mechanism, so generation needs no EarthSciModels
└── fixtures/            # the generated documents at the PR sizes (N = 10^2, 10^3), committed
    ├── index.json
    └── <family>/<family>_N<n>.esm
```

Larger sizes are generated at run time into a build directory and are never
committed.

## Running it

```bash
# Documents: the full ladder into a scratch directory (not /tmp for 10^6).
python3 tests/conformance/scaling/generate.py --out "$BUILD/scaling"          # every size
python3 tests/conformance/scaling/generate.py --out "$BUILD/scaling" --sizes pr
python3 tests/conformance/scaling/generate.py --out "$BUILD/scaling" --family stencil_2d --max-n 100000

# The committed fixtures are current (CI runs this):
python3 tests/conformance/scaling/generate.py --check
python3 tests/conformance/scaling/generate.py --write-fixtures   # after changing a family

# Rust adapter (one child process per document, so a timeout or an
# out-of-memory kill is recorded and the run carries on):
cd pkg/earthsci-ast-rs
cargo run --release --features conformance-adapters,parallel --bin earthsci-scaling-adapter-rust -- \
    --index ../../tests/conformance/scaling/fixtures/index.json --output rust-serial.json
cargo run --release --features conformance-adapters,parallel --bin earthsci-scaling-adapter-rust -- \
    --index "$BUILD/scaling/index.json" --output rust-threaded.json --threads 16

# Gates:
python3 tests/conformance/scaling/check.py rust-serial.json --gates deterministic   # PR CI
python3 tests/conformance/scaling/check.py rust-serial.json rust-threaded.json      # sweep
```

`sweep.sh` runs the whole Rust ladder on Slurm: one exclusive job per family
and thread mode, then one job running `check.py` over every result. Its header
lists the environment it reads (`SCALING_BUILD` is required):

```bash
SCALING_BUILD=/scratch/$USER/scaling tests/conformance/scaling/sweep.sh
```

## Families

| family | what it exercises | N counts | ladder |
|---|---|---|---|
| `stencil_1d` .. `stencil_4d` | rank-1 to rank-4 diffusion, zero-ghost boundaries, one affine box | cells | 10^2 .. 10^6 |
| `transport_3d` | the transport benchmark: five boundary classes per axis through expression-template matches, min/max limiter | cells | 10^2 .. 10^6 |
| `chemistry_grid` | a 20-species reaction system lifted pointwise onto a lon x lat grid by `operator_compose`, plus lon advection | grid cells (20 states each) | 10^2 .. 10^6 |
| `prefix_scan` | an inclusive measure-weighted prefix scan (filtered `faq`) over a non-uniform layer thickness, feeding the right-hand side | cells | 10^2 .. 10^6 |
| `source_receptor` | a dense square contraction `sum_j K[i,j] e[j]` over a non-uniform `K[i,j] = 0.001 (1 + sin(i j))` the document defines by formula | receptors | 10^2 .. 3162 |
| `regrid` | conservative regrid: bin-skolem broad phase, inline `polygon_intersection_area`, apply every call | source cells | 10^2 .. 3162 |
| `unstructured_gather` | the indirect gather `u[nbr[i,k]]` over a permuted periodic mesh | cells | 10^2 .. 10^6 |
| `scalar_chemistry` | N/20 scalar Pollu boxes written as one scalar ODE per state | states | 10^2 .. 10^5 |

Grid families round the side (`round(N^(1/rank))`), so `n_cells` in a result
is the actual count and `n` is the nominal ladder value. `source_receptor` and
`regrid` stop at 3162 because their work or their declared dense intermediates
grow as N^2; `scalar_chemistry` stops at 10^5 because the document itself
grows with N, which is also why the flat-code-size gate does not apply to it
(`gate_exclusions` in the manifest).

No array a hand loop reads densely is uniform in its document:
`source_receptor`'s `K` and `prefix_scan`'s `dz` are defined by formulas of
their indices, so a compiler must materialize them and read them on every
call, as it would a loaded array, rather than serve every element from one
value. (Rust's tape computes both in its build-once section and gathers them
per call.)

## The measured state

Every binding evaluates the right-hand side at the same point, so a hand loop,
native and the interpreter can be compared exactly:

- parameters at their declared defaults, `t = 0`;
- state element `k` (0-based, in the family's **canonical order** below) is
  `s_k = d_k * (1 + 0.1 * sin(0.37 * k)) + 0.01 * (1 + sin(0.53 * k))`, where
  `d_k` is the declared default of that element's variable (a species'
  `default` for the chemistry families).

Canonical order (bindings map their own state layout onto it by element name):

| family | canonical order |
|---|---|
| `stencil_*`, `transport_3d` | the one state variable, row-major (last axis fastest) |
| `chemistry_grid` | species in the mechanism's declaration order (the vendored file's order), each row-major over (lon, lat) |
| `prefix_scan`, `unstructured_gather` | `u[1..N]` |
| `source_receptor` | `c[1..N]`, then `e[1..N]` |
| `regrid` | `F_src[1..N]`, then `F_tgt[1..N]` |
| `scalar_chemistry` | box-major: box 1's 20 species in declaration order, then box 2's, ... |

## Result format

One JSON file per binding and run (serial and threaded runs are separate
files). Fields that cannot be measured are `null`, never omitted and never 0.

```json
{"binding": "rust", "compiler": "native", "threads": 1, "commit": "<sha>", "host": "<hostname>",
 "target": "x86_64-unknown-linux-gnu", "load_average": "0.02 0.10 0.31", "cpus": 128,
 "results": [
   {"family": "stencil_2d", "n": 10000, "n_cells": 10000, "n_states": 10000,
    "status": "ok",
    "reason": null,
    "build_s": 0.0,
    "code_size": 0,
    "code_size_unit": "tape_instructions",
    "first_call_s": 0.0,
    "steady_rhs_s": 0.0,
    "allocs_per_call": 0,
    "hand_loop_s": 0.0,
    "hand_loop_max_abs_diff": 0.0,
    "dy_max_abs": 0.0,
    "interpreter_max_abs_diff": 0.0}]}
```

| field | meaning |
|---|---|
| `load_average`, `cpus` (file level) | how busy the machine was when the run started, and its core count: a timing run wants a machine nothing else shares (an exclusive Slurm node, or an idle one) |
| `status` | `"ok"`, `"refused"` (the compiler refused the document by name; `reason` is its text) or `"error"` (anything else, including a timeout or a killed child process; `reason` says which) |
| `n`, `n_cells`, `n_states` | the nominal ladder size, the actual cell count, the state-vector length |
| `build_s` | wall seconds of `esm_problem` (reading and parsing the file included), after a warm-up build of a trivial document in the same process |
| `code_size`, `code_size_unit` | the size of what the compiler emitted. Rust: tape instructions over all three cadence sections. Julia: the adapter's stated measure |
| `first_call_s` | the first right-hand-side call after the build (it primes build-once sections) |
| `steady_rhs_s` | median of repeated calls after the first: at least 5 calls and at least 0.25 s of calls, at most 1000 |
| `allocs_per_call` | bytes allocated per steady call (Rust: a counting global allocator in the adapter binary; Julia: `@allocated`) |
| `hand_loop_s` | median steady time of the family's hand-written loop on the same state, timed the same way; threaded runs time the threaded loop |
| `hand_loop_max_abs_diff` | max over the state of `abs(dy_hand - dy_compiler)` |
| `dy_max_abs` | max over the state of `abs(dy_compiler)`, the scale for the hand-loop check |
| `interpreter_max_abs_diff` | max `abs(dy_compiler - dy_interpreter)` at the same point, or `null` when the adapter did not run the interpreter (it does so only up to a size cap, since the interpreter walks per cell) |
| `hand_loop_threads` | threads the hand loop used (a prefix scan's running sum is sequential, so its threaded reference is the serial loop) |
| `hand_loop_checked_against` | `"native"`, or `"interpreter"` when native refused the document: the hand loop is then checked against the interpreter's `dy` (up to the size cap), so the reference is known good before native learns the construct |

Adapters may add fields of their own (the Rust adapter adds `code_size_detail`,
`hand_loop_error`, `interpreter_error`); the checker ignores fields it does not
know.

## Gates

Thresholds live in `manifest.json` under `gates`.

| gate | kind | holds when |
|---|---|---|
| `builds` | deterministic | `status` is `"ok"`. A refusal or error fails it, and the other gates are then unmeasurable for that (family, N) |
| `code_size_flat` | deterministic | `code_size` is identical at every N that built (slack 0: no measure has a legitimate wobble yet) |
| `no_steady_alloc` | deterministic | `allocs_per_call` is 0 where measurable |
| `hand_loop_agrees` | deterministic | `hand_loop_max_abs_diff <= 1e-12 * max(1, dy_max_abs)`, so a wrong reference cannot make a slow compiler look fast. Checked against the interpreter when native refused |
| `build_slope` | timing | `(build_s(Nmax) - build_s(Nmin)) / (n_states(Nmax) - n_states(Nmin))` under 20 ns, over the smallest and largest N that built with at most 10^6 cells |
| `speed` | timing | `steady_rhs_s / hand_loop_s <= 1.25` in each result file, from 10^4 states up (below that a call takes microseconds and the ratio measures timer noise; `source_receptor`, whose work is N^2, lowers it to 2000 through `gate_overrides`) |

The deterministic gates run in PR CI at the PR sizes (the Rust leg of
`conformance-testing.yml`; `generate.py --check` runs in its lint job). The
timing gates need a clean machine and the big sizes: they run on the scheduled
`scaling-sweep.yml` (with `check.py --report-timing`, so they print but never
go red) and through `sweep.sh`, and do not block merges until plan phase 6.
The ledger's timing entries come from `sweep.sh` on an exclusive node.

The Rust wasm suite (`pkg/earthsci-ast-rs/tests/wasm_suite.rs`) also builds
every committed fixture here under native and the interpreter on wasm32 and
requires bit-identical right-hand sides; a native refusal passes there only
where the Rust ledger has a `builds` entry for it.

## The known-failure ledger

`manifest.json` `ledger.<binding>` lists what fails today:

```json
{"family": "regrid", "n": 1000, "gate": "builds", "threads": "serial",
 "measured": "refused: polygon_intersection_area has no tape lowering",
 "reason": "geometry leaf not lowered", "phase": 3}
```

`n` omitted means every N of the family (and the family-level gates, which
have no N); `n_min` says a family-level failure appears only from that N up,
so a run that stops below it (the PR sizes) neither matches the entry nor
marks it stale; `provisional` says a timing entry was measured on a machine
that was not clean; `threads` (`"serial"` or `"threaded"`) omitted means both;
`compiler` defaults to `"native"`. `phase` is the plan phase expected to fix
it: 2 for build time and code size, 3 or 4 for refusals, 5 for speed and
threading.

The rule is one-way. A failure not in the ledger is red. A ledger entry for a
deterministic gate that now passes is red too, with "remove this entry", so
the ledger can only shrink. A ledger entry for a timing gate that now passes
is reported (`fixed?`) but not red, because timing noise could flip it back.
