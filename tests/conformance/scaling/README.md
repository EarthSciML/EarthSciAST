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
├── sweep_issue.py       # turns a red clean sweep's check.py --json into a GitHub issue
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

# Rust adapter (one child process per document, so a timeout, an
# out-of-memory kill or passing --max-rss-gb is recorded and the run carries
# on; the Julia adapter does the same with one child per family):
cd pkg/earthsci-ast-rs
export RUSTFLAGS="-C llvm-args=-align-loops=64"   # for timings: see Timing builds below
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

### Timing builds

Build the Rust adapter with `RUSTFLAGS="-C llvm-args=-align-loops=64"` for
any timing run; `sweep.sh` and `scaling-sweep.yml` do. Without it, a hot loop
starts wherever the code before it ends, so an unrelated change elsewhere in
the binary can move a hand loop's time by tens of percent and flip a speed verdict
either way. Built aligned, two commits whose hand loops are identical time
those loops nearly the same. Aligned is not always the
faster placement; it is the same placement every time. Compare timings only
between binaries built the same way. The deterministic gates do not need it.

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
| `gather_index` | a gather through a computed 64-class index array into two inline `const` tables, `-rate[cls[i]] u[i] + emis[cls[i]]` | cells | 10^2 .. 10^6 |
| `column_search` | a per-column count of levels above a threshold used as a subscript, `u[c, max(1, cnt[c])]` (the YSU `kpbl` shape), 20 levels | cells | 10^2 .. 10^6 |
| `column_sum` | a rank-0 column sum nested in a 3-D `faq` body, `sum_l u[i,j,l]`, 20 levels | cells | 10^2 .. 10^6 |
| `join_keyed` | a value-equality `join` on computed keys evaluated at build, about four matching rows per cell, feeding the right-hand side | cells (= rows) | 10^2 .. 10^6 |

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

Two hand loops do less work than a literal reading of their document, because
a person writing the loop would: `column_sum`'s computes each column's sum once
and applies it to the column's 20 cells (the sum does not depend on the output
level, and the fold order over levels is the document's), and `join_keyed`'s
does the join once at setup, bucketing the rows by key, and reads the sums on
every call (the join reads no state, so it is build-time work). A compiler
that recomputes either per cell or per call is slower than the reference by
that work, which is the point.

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
| `prefix_scan`, `unstructured_gather`, `gather_index`, `join_keyed` | `u[1..N]` |
| `column_search`, `column_sum` | the one state variable, column-major (first axis fastest, levels slowest): the layout both bindings' native compilers give it, so the hand loops read the layout native reads |
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
    "n_bytes": 0,
    "build_s": 0.0,
    "build_repeats": 10,
    "build_s_interleaved": null,
    "build_interleaved_repeats": null,
    "build_interleaved_diff_s": null,
    "dense_bytes": 0,
    "code_size": 0,
    "code_size_unit": "tape_instructions",
    "first_call_s": 0.0,
    "steady_rhs_s": 0.0,
    "allocs_per_call": 0,
    "hand_loop_s": 0.0,
    "hand_loop_max_abs_diff": 0.0,
    "dy_max_abs": 0.0,
    "interpreter_max_abs_diff": 0.0,
    "hand_loop_serial_s": 0.0,
    "serial_steady_rhs_s": null}]}
```

`manifest.json`'s `result_format_version` is 3. Version 2 had no
`build_s_interleaved`, `build_interleaved_repeats` or
`build_interleaved_diff_s`; version 1 had none of
those nor `build_repeats`, `dense_bytes`, `hand_loop_serial_s` or
`serial_steady_rhs_s`, and its `build_s` was a single build. Older files still
check: a missing field turns off only what reads it (the build slope then fits
`build_s`, and an allowance or carve-out is off), and the row's note says so.

| field | meaning |
|---|---|
| `load_average`, `cpus` (file level) | how busy the machine was when the run started, and its core count: a timing run wants a machine nothing else shares (an exclusive Slurm node, or an idle one) |
| `status` | `"ok"`, `"refused"` (the compiler refused the document by name; `reason` is its text) or `"error"` (anything else, including a timeout or a killed child process; `reason` says which) |
| `n`, `n_cells`, `n_states` | the nominal ladder size, the actual cell count, the state-vector length |
| `n_bytes` | the document file's size in bytes (the `build_slope` gate's size allowance reads it) |
| `build_s` | wall seconds of `esm_problem` (reading and parsing the file included), after a warm-up build in the same process: the fastest of `build_repeats` builds of the document, repeated while they total under 1 s and at most 10 times. A build of a few milliseconds varies by a large fraction of itself between runs, and one sample of it at each end of the ladder made the build slope swing by hundreds of ns/state |
| `build_repeats` | how many builds `build_s` is the fastest of |
| `build_s_interleaved`, `build_interleaved_repeats` | on the two documents the build slope is fitted between only: the median of `build_interleaved_repeats` builds of each, taken alternately in one process after the family's ladder (below). `null` elsewhere, and for a family whose builds would not fit 10 pairs in 5 s |
| `build_interleaved_diff_s` | on the larger of those two documents only: the median over the interleaved pairs of its build minus the smaller document's build taken beside it, which the build slope is fitted from |
| `dense_bytes` | bytes of the declared-dense arrays the build writes in full: an array the document declares at a shape (`regrid`'s overlap arrays, source x target) that the build materializes at that shape. Julia: the build's setup arrays that the document declares at a shape over sized index sets and that the build materialized at exactly that shape; any other setup array (an index or geometry table the build derives at its own extent) is not counted. Rust: `null`, since its build materializes no declared shape (a declared-dense `faq` becomes tape sections that run on the first call). `null` gets no dense allowance |
| `code_size`, `code_size_unit` | the size of what the compiler emitted. Rust: tape instructions over all three cadence sections. Julia: the adapter's stated measure |
| `first_call_s` | the first right-hand-side call after the build (it primes build-once sections) |
| `steady_rhs_s` | median of repeated calls after the first: at least 5 calls and at least 0.25 s of calls, at most 1000 |
| `allocs_per_call` | bytes allocated per steady call (Rust: a counting global allocator in the adapter binary; Julia: `@allocated`) |
| `hand_loop_s` | median steady time of the family's hand-written loop on the same state, timed the same way; threaded runs time the threaded loop |
| `hand_loop_serial_s` | the serial hand loop, timed the same way in the same process (equal to `hand_loop_s` in a serial run) |
| `serial_steady_rhs_s` | threaded runs below 10^4 cells (`n_cells` under the speed gate's `small_n_max`): native's steady call with its thread budget forced to one, same process (Rust: inside a one-thread rayon pool; Julia: a second build whose sections are all held serial). Its `dy` must be bit-identical to the threaded call's, or the result is an error. `null` otherwise |
| `hand_loop_max_abs_diff` | max over the state of `abs(dy_hand - dy_compiler)` |
| `dy_max_abs` | max over the state of `abs(dy_compiler)`, the scale for the hand-loop check |
| `interpreter_max_abs_diff` | max `abs(dy_compiler - dy_interpreter)` at the same point, or `null` when the adapter did not run the interpreter (it does so only up to a size cap, since the interpreter walks per cell) |
| `hand_loop_threads` | threads the hand loop used (a prefix scan's running sum is sequential, so its threaded reference is the serial loop) |
| `hand_loop_checked_against` | `"native"`, or `"interpreter"` when native refused the document: the hand loop is then checked against the interpreter's `dy` (up to the size cap), so the reference is known good before native learns the construct |

Adapters may add fields of their own (the Rust adapter adds `code_size_detail`,
`hand_loop_error`, `interpreter_error`; both add `peak_rss_bytes`, the child
process's peak resident memory, and a file-level `max_rss_gb` and `timeout_s`,
the guards the run used); the checker ignores fields it does not know.

A document the machine cannot hold is a result, not a lost run: each adapter
measures in child processes, kills a child past `--max-rss-gb` (12 GB by
default on every machine, so whether a document fits is a property of the
document and the compiler, not of the machine) or `--timeout-s`, and records
that document as `"error"` with a `reason` that starts `out of memory:`,
`timeout:` or `the child process ...`, and the family's larger sizes as
`not attempted: ...`. Such a `builds` failure goes in the ledger like any
other; since the document did not build, its other gates skip (below).

**A null measure on a document that built is a missing measurement.** For a
result with `status: "ok"`, a null `allocs_per_call` or `hand_loop_max_abs_diff`
fails its gate (`no_steady_alloc`, `hand_loop_agrees`), with the adapter's
`hand_loop_error` or `reason` as the note: an adapter that built the document
and did not measure it has failed, and a skip there would leave the gate
unchecked. The one exception is a measure the result itself declares
unmeasurable, in an optional `unmeasurable` map from field name to why
(`"unmeasurable": {"allocs_per_call": "no counting allocator on this target"}`);
the gate then reports `skip`. Neither adapter writes that map today: the Rust
adapter binary always installs its counting allocator, Julia's `@allocated`
always answers, and both bindings have a hand loop for every family. For a
document that did not build, every measure is unmeasured and its gates skip
(`hand_loop_agrees` is still checked against the interpreter where the adapter
ran it).

## Gates

Thresholds live in `manifest.json` under `gates`.

| gate | kind | holds when |
|---|---|---|
| `builds` | deterministic | `status` is `"ok"`. A refusal or error fails it, and the other gates are then unmeasurable for that (family, N). `native` is required for every document of every compiler-driven tier, so this gate takes no ledger entry: a native `builds` entry is a manifest error |
| `code_size_flat` | deterministic | `code_size` is identical at every N that built, up to the gate's `slack` (0). A family's `gate_overrides` may state a slack per binding, with a `why` that bounds the spread: Rust's stencil and transport families state one, because fusion's fold decision depends on row length, while the lowered tape it can only shrink is flat (`code_size_detail.lowered`) |
| `no_steady_alloc` | deterministic | `allocs_per_call` is 0 (null on a built document fails, unless the result declares it unmeasurable). A ledger entry for it states `max_bytes_per_call`, the most it excuses, and a measure past that bound is red (`EXCEEDS`) |
| `hand_loop_agrees` | deterministic | `hand_loop_max_abs_diff <= 1e-12 * max(1, dy_max_abs)`, so a wrong reference cannot make a slow compiler look fast. Checked against the interpreter when native refused |
| `build_slope` | timing | `(build_s(Nmax) - build_s(Nmin)) / (n_states(Nmax) - n_states(Nmin))` under 20 ns, with `build_interleaved_diff_s` in place of the difference when the larger end has it (below), plus the document-size and dense-array allowances below, over the smallest and largest N that built with at most 10^6 cells |
| `speed` | timing | `steady_rhs_s / hand_loop_s <= 1.25` in each result file, from 10^4 states up (below that a call takes microseconds and the ratio measures timer noise). Two families stop short of 10^4 states and lower it to 2000 through `gate_overrides`: `source_receptor`, whose work is N^2, and `regrid`, whose ladder stops at 6324 states and whose call at 2000 states is already a few microseconds. In a threaded file, a result below 10^4 cells is checked against native's own serial call instead (below) |

### The build slope's two ends

A build of a few milliseconds drifts by a fraction of a millisecond between one
step of a ladder and the next in the same process, while the slope's whole
allowance over a family that stops at 3162 is about 0.12 ms. One minimum per
size, taken minutes apart, can therefore read a slope several times the true
one in either direction. So after a family's ladder the adapters rebuild the
two documents the slope is fitted between (the smallest and largest
`n_states` that built, at most 10^6 cells) in pairs in one process, in the
order lo hi, hi lo, lo hi, ... up to 100 pairs and within 5 s in all. Julia's
collector runs before each of these builds and never inside one: otherwise a
collection of the ladder's garbage lands in whichever build crosses the
threshold, in a pattern that can favour one end by tens of ns/state. The slope is
fitted from the median over pairs of the larger build minus the smaller
(`build_interleaved_diff_s`): drift lands on both builds of a pair alike and
cancels, where separate medians of the two ends still carried it, and the
alternating order puts each end first in half the pairs, since a build that
follows a build of the same document runs warmer. A family whose builds are
too long for 10 pairs in 5 s keeps the ladder's `build_s`, which is already
large against the noise there. The thresholds are unchanged.

### The build slope's document-size allowance

The build includes reading the document, so a family that carries its data
inline (`regrid`'s cell bounds, `unstructured_gather`'s neighbour table,
`scalar_chemistry`'s equations) has a document that grows with N, and reading
it costs time per state that no compiler can avoid. The gate pays for that
reading and nothing else:

```
limit = max_ns_per_state + per_byte_ns[binding] * (n_bytes(Nmax) - n_bytes(Nmin)) / (n_states(Nmax) - n_states(Nmin))
```

`per_byte_ns` is per binding, because their loaders differ by about 2x: it is
twice the binding's measured document load (no build) per byte of inline data,
the load itself plus one more pass of the same cost for the build to read the
values out of the loaded document into its own arrays (the manifest's
`per_byte_ns_why` has the measurement). So a family whose build is the load
and one read of its data passes, and whatever else the build does per state
still has to fit in 20 ns. The rate is measured on data arrays; a document
whose growth is equations rather than data (`scalar_chemistry`) loads at a
higher rate per byte in both bindings, which the gate's own rate does not
cover.

A family whose document grows by equations states its own rate in its
`gate_overrides.build_slope.per_byte_ns`, per binding, with a `why`. Only
`scalar_chemistry` does: one scalar ODE per state, which the Julia loader
validates and coerces equation by equation at about 3000 ns per byte, and the
Rust loader at about 100. That per-equation load cost (schema validation, in
Julia) is a known cost separate from the compiler, so the family's rate is
twice it, by the same reasoning as above. It excuses loading, not compiling:
the rest of the build must still fit in 20 ns per state.

A document whose size does not grow with N (every stencil, `transport_3d`,
`chemistry_grid`, `prefix_scan`, `source_receptor`: their size changes by a
few bytes of digits) gets an allowance of about 0, so the gate is the plain 20
ns/state there. A result without `n_bytes` (written before the adapters
recorded it) gets no allowance either, and the row's note says so.

### The build slope's dense-array allowance

A document may declare an array dense over a large index space: `regrid`'s
`A_ij` and `W_ij` are declared over source x target, N^2 elements, although
only the admitted pairs are ever non-zero. A build that materializes the
declared shape writes N^2 pages, which costs time per state that grows with N
however good the compiler is. The gate pays for those page writes and nothing
else, by the same rule in both bindings:

```
+ dense_page_ns[binding] * (dense_bytes(Nmax) - dense_bytes(Nmin)) / (n_states(Nmax) - n_states(Nmin))
```

`dense_page_ns` is twice the binding's measured cost of writing fresh pages
(allocating an array and writing every element once, so each page is faulted in
and zeroed): the write, plus one more pass of the same cost for the build to
read the array back into its own tables (the manifest's `dense_page_ns_why` has
the measurement). It pays for the materialized shape, not for work per admitted
element, which still has to fit the rest of the limit. A build that writes no
declared-dense array (`dense_bytes` 0 at both ends, or `null`) gets nothing.

### The threaded speed gate below 10^4 cells

Over fewer than 10^4 cells a threaded call is a few microseconds of work: there
is little to divide, and a hand loop tuned for that one size can still win
where a general compiler should not be made to chase it. Below `small_n_max`
cells (`n_cells`, 10^4) the threaded speed gate therefore asks a different
question: not whether native keeps up with the threaded hand loop, but whether
turning threads on made native slower than running it serially.

```
n_cells < small_n_max (threaded files):  steady_rhs_s / serial_steady_rhs_s <= max_ratio
```

Both times come from the same process: the adapters time native's call a
second time with its thread budget forced to one. From 10^4 cells up the
threaded gate is the ratio to the threaded hand loop as before. Every family's
N = 10^4 rung has at least 10^4 cells, except `scalar_chemistry`, whose
`n_cells` counts boxes (500 at N = 10^4, 5000 at 10^5): its threaded calls are
a few microseconds, and it falls under the carve-out through N = 10^5. A serial file gets no carve-out, and a result without
`serial_steady_rhs_s` (written before the adapters recorded it) is gated
against the hand loop, with a note. The manifest's `small_n_why` records the
ruling.

### Gating on a hosted runner, and filing a red sweep

A hosted CI runner is not a clean machine: its ratios move by several times
between runs, in both directions (the manifest's `hosted_runner.why` has the
numbers). `check.py --hosted` is the mode for it: the deterministic gates run
exactly, the speed gate fails only past `hosted_runner.max_timing_ratio` (3),
a regression the size of a fall-back to a slower path, which no noise
produces, and the build slope is printed but never red (a millisecond of
jitter over the PR sizes' few hundred states is hundreds of ns/state). The exact bars run on the
scheduled clean sweep on the dedicated node (`sweep.sh`), whose `check.py
--json` output `sweep_issue.py` turns into a GitHub issue naming every red row:

```bash
python3 tests/conformance/scaling/sweep_issue.py "$SCALING_BUILD/check.json"          # print the issue
python3 tests/conformance/scaling/sweep_issue.py "$SCALING_BUILD/check.json" --file   # file it with gh
```

It prints nothing and exits 0 when the sweep is green, so a scheduled job can
run it unconditionally.

PR CI runs every gate at the PR sizes with `check.py --hosted` (the Julia and
Rust legs of `conformance-testing.yml`; `generate.py --check` runs in its lint
job), so a deterministic failure or a speed ratio past 3 blocks the merge. The scheduled `scaling-sweep.yml` runs the full ladder the same way.
The exact timing bars need a clean machine and the big sizes: they run through
`sweep.sh` on the dedicated node, and a red sweep is filed with
`sweep_issue.py` (above).
The ledger's timing entries come from `sweep.sh` on an exclusive node.

The Rust wasm suite (`pkg/earthsci-ast-rs/tests/wasm_suite.rs`) also builds
every committed fixture here under native and the interpreter on wasm32 and
requires bit-identical right-hand sides; a native refusal fails it.

## The known-failure ledger

`manifest.json` `ledger.<binding>` lists what fails today:

```json
{"family": "regrid", "n": 1000, "gate": "speed", "threads": "serial",
 "measured": 1.4155, "reason": "the apply's fused group trails the hand loop",
 "phase": 5}
```

`n` omitted means every N of the family (and the family-level gates, which
have no N); `n_min` says a family-level failure appears only from that N up,
so a run that stops below it (the PR sizes) neither matches the entry nor
marks it stale; `provisional` says a timing entry was measured on a machine
that was not clean; `threads` (`"serial"` or `"threaded"`) omitted means both;
`compiler` defaults to `"native"`. `phase` is the plan phase expected to fix
it: 2 for build time and code size, 5 for speed and threading (a refusal is
never ledgered: see the `builds` gate).

A `no_steady_alloc` entry must also state `max_bytes_per_call`, a positive
integer: the entry excuses an allocation up to that many bytes per call and no
more. A measure past it is red (`EXCEEDS`), so a ledgered 128 bytes that jumps
to megabytes is a regression, not a ledgered failure. The committed bounds are
twice the largest value the entry's `measured` records, room for a section or
two more of the same dispatch cost; an entry missing its bound, or a bound on
any other gate, is red.

The rule is one-way. A failure not in the ledger is red. A ledger entry for a
deterministic gate that now passes is red too, with "remove this entry", so
the ledger can only shrink. A ledger entry for a timing gate that now passes
is reported (`fixed?`) but not red, because timing noise could flip it back.
