# Scaling tier: the Julia side

The tier itself (families, the measured state, the result format, the gates
and the ledger) is described in [../README.md](../README.md). This directory
holds what is Julia's:

| file | what it is |
|---|---|
| `adapter.jl` | builds each document under `compiler = :native` and writes one result file |
| `hand_loops.jl` | the hand-written reference right-hand side of every family |
| `sweep.sh`, `sweep.sbatch` | the Slurm driver for the full ladder, serial and threaded |

The adapter runs in its own environment, `pkg/EarthSciAST.jl/scripts/scaling_env`
(EarthSciAST, JSON3, Polyester). Only its `Project.toml` is committed; the
adapter develops the local package into it and instantiates it on first use.

## Running it

```bash
# The PR sizes (what CI runs), serially, deterministic gates only:
julia --project=pkg/EarthSciAST.jl/scripts/scaling_env tests/conformance/scaling/julia/adapter.jl \
    --docs tests/conformance/scaling/fixtures --output julia-serial.json --budget 0 --interpreter-max-states 0
python3 tests/conformance/scaling/check.py julia-serial.json --gates deterministic --require pr

# Any generated tree, threaded:
python3 tests/conformance/scaling/generate.py --out "$BUILD/scaling" --max-n 100000
julia -t 16 --project=pkg/EarthSciAST.jl/scripts/scaling_env tests/conformance/scaling/julia/adapter.jl \
    --docs "$BUILD/scaling" --output julia-t16.json

# The full sweep on Slurm (one exclusive node per family and thread mode):
SCALING_BUILD=/scratch/$USER/scaling-julia tests/conformance/scaling/julia/sweep.sh
```

Options: `--family F` (repeatable), `--max-n N`, `--budget S` (the least
seconds each steady measurement samples, default 0.25), `--max-build S` (stop
a family's ladder once a build takes longer, or once the next one is projected
to from the last two; default 1800), `--interpreter-max-states N` (build the
interpreter too, as an oracle, up to this many states; default 2000, 0 turns
it off; the interpreter's per-cell expansion of a prefix scan or a dense
contraction grows as N^2 in memory, past 12 GB at prefix_scan's 10^4 cells), `--max-rss-gb G` and `--timeout-s S` (see below; defaults 12 and
1800), `--in-process` (measure in this process, without either guard).

Each family's ladder runs in a child Julia process that the adapter watches.
A child whose resident memory passes `--max-rss-gb`, or that finishes no
document for `--timeout-s`, is killed, and a child that dies on its own (the
kernel's out-of-memory killer, a crash) is noticed: the document it was on is
recorded as an `error` whose `reason` says which (`out of memory: ...`,
`timeout: ...`, `the child process was killed by signal ...`), and the
family's larger sizes as `not attempted`. So a document too big for the
machine is a ledgerable result, and the rest of the run carries on. The cap
is the same on every machine by default (12 GB, which fits a hosted runner's
16 GB with room for the runner) and is passed to the child as its GC
`--heap-size-hint`, so whether a document fits does not depend on how much
memory the machine happens to have. It reads `/proc`, so it is enforced on
Linux only.

## What each field is, in Julia

- `build_s` is the wall time of `esm_problem(path, (0, 1); compiler = :native)`.
  Before a family's ladder the adapter builds that family's smallest document
  once, untimed, so no recorded build includes compiling the build path
  itself (most of a minute in a fresh process).
- `first_call_s` is the first `prob.f!` call after the build. It includes
  compiling the generated functions, unless a previous size emitted the same
  expressions, in which case Julia reuses the compiled code: that is a
  property of native (its program does not depend on N), not an artefact.
- `steady_rhs_s` is the median of individual `prob.f!` calls after one
  untimed call: at least 5, at least `--budget` seconds, at most 1000.
- `allocs_per_call` is `@allocated prob.f!(du, u, p, t)` behind a function
  barrier, after two warm calls.
- `threads` in the file header is `Threads.nthreads()`. The adapter always
  loads Polyester, because loading it is how native's threaded tier is turned
  on today (`EarthSciASTPolyesterExt`); with one thread native runs its serial
  path. In a threaded run `hand_loop_s` is the threaded hand loop and
  `hand_loop_serial_s` the serial one.
- `status` is `refused` for a `compiler_refused_rule` out of the build and
  `error` for anything else; `reason` carries the message.

Julia fills the optional `hand_loop_threads` and `hand_loop_checked_against`
(`"interpreter"` when native did not build and the interpreter did, so a loop
is known good before native reaches it), and adds these fields of its own:

| field | meaning |
|---|---|
| `tiers` | the compiler report's tier breakdown, `[[tier, rules], ...]` (`compiler_report(prob)`, folded by `tier_histogram`). A per-cell tier (`percell_build`, `scalar`) shows up here |
| `code_size_parts` | the code-size measure's two terms and the number of generated functions |
| `hand_loop_serial_s` | the serial hand loop's time (equal to `hand_loop_s` in a serial run) |
| `interpreter_note` | why the interpreter oracle did not run, when it did not |
| `peak_rss_bytes` | the highest resident memory the adapter sampled (every 0.1 s) in the child process while it worked on this document; memory the child held from a smaller size counts, as it would in any run of the ladder |

## The code-size measure

`code_size_unit` is `emitted_expr_nodes+walked_nodes`. The adapter walks every
field reachable from `prob.f!` and sums two things:

1. For each distinct `RuntimeGeneratedFunction` it reaches (distinct by the
   hash of its expression), the number of nodes in its expression: every
   `Expr` counts one and every leaf (symbol, literal, line number) counts one.
   That is the count native's own function-size cap (`_cg_expr_size`) uses.
   It covers every compiled tier, since the affine, scan, contraction and
   per-cell-build tiers all emit generated functions.
2. The number of distinct `_Node` objects it reaches: the trees the scalar
   and per-cell interpreted tiers walk on every call.

The walk skips any array or dict whose element type cannot hold either (slot
tables, constants, state-sized buffers), so data that legitimately grows with
N is never counted, and it visits each object once, so it is deterministic:
the same document gives the same count on every run and every machine.

Why it is flat when the build is O(1): an O(1) build emits one program per
equation whose loop bounds and strides come from tables or constants, not one
statement per cell, so the expression is the same at every N. Neither term
counts data, so the only way the measure grows is code proportional to N: an
unrolled contraction (one term per contracted element), code a per-cell
build emits per cell or per cell class, or one walked tree per scalar
equation. The measure does not see a build that is O(N) in bookkeeping while
emitting flat code (every affine stencil today): that is the build-slope
gate's job.

## The hand loops

`hand_loops.jl` has one reference right-hand side per family, written the way
someone would write that document in Julia: `@inbounds`, boundary cases peeled
out of the innermost loop, no `@simd`, no intrinsics, the document's order of
operations. Each is a function of the outermost index, so:

- the serial reference runs the rows in order;
- the threaded reference is the same rows under `Threads.@threads :static`.

Every loop is checked against native's dy at the measured state
(`hand_loop_max_abs_diff`); on the PR fixtures every one agrees bit for bit.
Notes per family:

- The stencils and transport read the state as one column-major block
  (native's layout); a zero ghost is a literal `0.0`. Transport writes each
  (j, k) row in four passes (x derivative, + y, + z, sign), the same arithmetic
  in the same order as one expression per cell, so no inner loop tests a
  boundary class.
- `chemistry_grid` is one loop per species over the row, as the document has
  one equation per species; the mechanism is inlined with the species fixed,
  so each loop computes only the rates that species reads.
- `prefix_scan` is a running sum, so it has one row, and its threaded
  reference is its serial loop.
- `source_receptor` stores K transposed, so a receptor's row is contiguous.
- `regrid` builds the document's weights once in setup (the same bin join,
  alive filter and row-sum normalisation; the cells are rectangles, so each
  overlap is a product of two interval overlaps) and applies them as a sparse
  row loop per call.
- `unstructured_gather` reads the neighbour table out of the document (the
  const equation defining `nbr`).
- `scalar_chemistry` reads each box's 20 species through a slot table, since
  scalar states have no array layout.

`Threads.@threads` costs a few microseconds per call to start its tasks,
where native's Polyester dispatch costs less, so at the smallest sizes a
threaded ratio favours native.
