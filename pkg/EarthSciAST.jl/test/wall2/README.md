# Wall #2 fix — type-stable observed-field evaluation at full scale

**Problem.** Build-time observed fields (`_observed_field` → `evaluate_cellwise` →
`_eval_cellwise`) were evaluated ONE output cell at a time, and each cell re-ran
`_index_at_cell → _resolve_indices(+unroll) → _compile`. Because const/provider-array
reads constant-fold to per-cell *literals* (they require concrete subscripts), an
observed defined by a contracting aggregate `conc[rcv]=Σ_c A[c,rcv]·E[c]` rebuilt its
entire N_src-wide term tree for **every** output cell — O(N_cells·N_src), on a
dynamically-typed AST path. At ISRM scale (52,411 cells × 1,520 sources × 5 pathways)
it never finished (Phase A: ~1,750 s + ~260 GiB alloc-churn projected). This blocked
running the whole model — the SR contraction is inlined into `deathsK` — through
`EA.prepare`'s observed graph.

**Fix (phased, branch `wall2` off `pushdown`).**
- **A** `phaseA_scaling_bench.jl` — reproduced + instrumented: confirmed the
  O(N_cells·N_src) recompile signature + type-instability; profiler pinned the cost to
  per-cell AST re-resolution.
- **B** `_NK_CONST_GATHER` (compile.jl) — a compiled node that reads a captured
  const/provider array at an offset computed AT EVAL TIME from subscript children, so a
  const read can survive resolution with the output index still symbolic. Mirrors
  `_NK_PARAM_GATHER`.
- **C** compile-once evaluator (`_cellwise_compile_once` / `_index_at_cell_sym` /
  `_ConstGatherRef`, helpers.jl + resolve.jl + compile.jl) — resolve+unroll+compile the
  observed body ONCE with the output index bound as a parameter, then rebind per cell
  into the type-stable `_NK_CONTRACTION` reducer. Reuses the SAME unrolling as the
  per-cell path, so reduction order (hence the float sum) is **bit-identical**.
  → 52,411-cell compute goes from "never finishes" to **~12 s, flat ~6 MiB** working set.
  Includes the OOM fix (see below).
- **D** optional BLAS accelerator (`evaluate_cellwise(…; blas_accel=true)`,
  pde_inline_tests.jl) — recognizes the linear mat-vec `conc=A'·E` (reuses `_pd_detect`'s
  `_pd_matvec_factors`) and does one `mul!` over the whole field. ~120× over Phase C.
  NOT bit-identical (BLAS sums in a different order; measured max rel-diff 6.21e-15);
  Phase C stays the bit-exact baseline and the default.
- **E** engagement proof (`phaseE_engagement_test.jl`) — the fast path ENGAGES
  (no fallback) and is bit-identical on the REAL `deathsK` structure (nested aggregates,
  a non-contracting outer aggregate, output-indexed const gathers).

## The OOM (important)

Phase B's `_const_gather_node` originally did `Vector{Float64}(vec(A))` — a full **copy**
of the source array. An unrolled contraction lowers ONE gather per reduced term, so that
copy was O(N_terms·sizeof(A)); at N_src=1520 × a ~0.6 GiB SR slab it allocated ~1 TiB
during a *single* compile and **crashed the whole machine**. Fixed: a dense `Float64`
array now `vec`s to an **aliasing** `Vector{Float64}` (zero data copy) shared across all
terms — safe because const arrays are build-time read-only (the same sharing
`_NK_PARAM_GATHER` uses for a live buffer). Verified bounded via `phaseC_memory_probe.jl`.

## Correctness & conformance

- Phase C is **bit-identical** to the prior per-cell path (same reduction order); the
  BLAS path (opt-in) agrees to ~1e-15.
- `_NK_CONST_GATHER` and the compile-once evaluator are **Julia reference-implementation
  internals**. They are value-invariant (produce identical results to the const-fold
  path), so they carry **NO cross-language conformance obligation** — deliberately NOT
  added to `CONFORMANCE_SPEC.md`. Other-language engines are free to (but need not)
  adopt an equivalent optimization; observable behavior is unchanged.

## Deferred: the full-scale oracle number

Reproducing `sum(deathsK)=7524.918845602511` end-to-end through `build_evaluator` needs
~3.2 GiB of re-fetched SR data plus the multi-GiB model-build (MTK/Symbolics) footprint —
which does not fit the 8 GiB dev machine (the build stack alone thrashes it). The
mechanism is proven at 52,411-cell scale (Phase C probe) and on the real `deathsK`
structure (Phase E); the definitive oracle run is deferred to a larger machine. The
`run-model-jl-pushdown` runner Manifest is already re-pointed at this `wall2` worktree
for that run; `L3_FIRSTN=<n> julia --project=. L3_full.jl` drives it (reduced or full).
