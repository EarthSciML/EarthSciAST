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

## CLOSED: the full-scale oracle number

**Status: done.** `isrm.esm`'s `run-model-jl-pushdown/L3_full.jl` now reproduces the
tutorial totals end-to-end through `EA.build_evaluator`'s observed graph, at full
52,411 × 1,520 × 43,650 scale against the live `s3://inmap-model/isrm_v1.2.1.zarr`:

```
BUILD done in 634.3 s
gated selection: layer=1  |members|=1520  rcv=Colon()   (1,520 SR rows fetched, not 52,411)
evaluating observed deathsK ... 305.1 s   [fastpath hits=21 miss=0]
  sum(deathsK) = 7524.918845602511   target 7524.918845602511   rel.err 0.0%
  sum(deathsL) = 16979.63217148708   target 16979.632171487083  rel.err -0.0%
```

Peak RSS ≈ 7.8 GiB. Phase C's fast path engaged everywhere (`miss=0`).

### The old diagnosis in this section was wrong — do not repeat it

This section previously said the run needed "a larger machine." It did not. Moving to a
188 GiB box did **not** make it run; it OOM-killed at ~25 GiB inside a 40 GiB cgroup.
Three independent, unrelated causes were in play, and none of them was hardware:

1. **The zarr reader buffered every chunk before assembling the output.** EarthSciIO's
   Julia and Rust readers accumulated all decoded chunks in a `Dict`/`HashMap` keyed by
   chunk coordinate, then assembled. For one SR pathway that is 416 chunks × ~21 MB
   decompressed = **8.7 GiB held to produce a 0.59 GiB slab** (~15×). Fixed by scattering
   each chunk into the output and freeing it immediately (EarthSciIO `822ee6d` Julia,
   `ceca310` Rust; the Python reader already streamed). Measured at ISRM scale:
   9.17 → 1.56 GiB and 193.1 → 120.8 s. Not an EarthSciAST bug at all.

2. **Julia sizes its GC heap from total system RAM, not from the cgroup.** With 188 GiB
   visible and a 40 GiB `memory.max`, the heap grows past the cap before collecting — so
   **a larger machine makes this failure mode worse, not better**, which is exactly the
   inversion the old text fell into. Fixed by passing `--heap-size-hint` sized to the
   cgroup minus whatever else shares it. Never size it from `free -g`.

3. **Array-valued observeds were inlined into every consumer cell** — the real blocker,
   and the only one in this package. `deathsK` consumes `conc_*`, which consume the
   per-source emission fields `E_VOC`/`E_NOx`/…; each of those is itself a spatial join
   (an aggregate over source cells × all 43,650 emission records, with containment
   comparisons). Inlined, that entire join was re-evaluated at **each of the 52,411
   receptor cells**: ≈ 5 × 1,520 × 43,650 terms per cell ≈ 1.7e13 node evaluations, or
   ~870 years at the measured 158 ns/node. Note this sits *upstream* of Phases B–E: the
   compile-once path was engaging correctly, it was just compiling a body that contained
   the whole join. Fixed by materializing array-valued observeds once and referencing the
   result — `perf/array-observed-factor` for the runtime path, and this branch's
   `_materialized_obs_scope` for the build-time `_observed_field` path.

The lesson worth keeping: "it OOMs at scale" was three separate defects in two repos plus
a runtime-configuration mistake. Each was found by measurement — a memory probe isolating
a single fetch (cause 1), a two-pathway plateau test ruling out retention (cause 2), and a
CPU profile putting 99.3% of samples under `_eval_cells → _CellEval → _eval_node` with
`_eval_node_comparison` a top self-time frame (cause 3). Sizing hardware against the
symptom would have fixed none of them.

### Reproducing

`run-model-jl-pushdown`'s Manifest must point at an EarthSciAST carrying the cause-3 fix
and an EarthSciIO carrying the cause-1 fix. Then:

```
julia -t 2 --heap-size-hint=12G --project=. L3_full.jl     # full run
L3_FIRSTN=<n> julia --project=. L3_full.jl                 # reduced, self-checking
```

The full run also emits a `results.json` in the isrm.esm cross-language contract shape
with `mode="runtime_observed_graph"`.
