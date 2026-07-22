# Wall #2 — Phase A findings (reproduce & instrument)

Julia 1.12.6. Benchmark: `test/wall2/phaseA_scaling_bench.jl` (drives the real
`evaluate_cellwise` → `_eval_cellwise` hot path with a faithful hand-built aggregate
`conc[rcv] = Σ_c A[c,rcv]·E[c]` over const arrays; `deaths` variant wraps it in
`exp(k·conc)-1`).

## Scaling (SWEEP 1: vary N_rcv at N_src=1520)

| N_rcv  | time     | bytes     | allocs        | allocs/cell |
|-------:|---------:|----------:|--------------:|------------:|
| 100    | 0.63 s   | 503.7 MiB | 11,254,004    | 112,540     |
| 1,000  | 6.45 s   | 4.99 GiB  | 117,033,614   | 117,034     |
| 10,000 | 66.79 s  | 50.28 GiB | 1,198,302,614 | 119,830     |

Full-scale PROJECTION (N_rcv=52,411, single pathway): **~350 s, ~6.28e9 allocs**;
**×5 pathways ≈ 1,750 s of pure compute + ~260 GiB allocation churn.** With the
type-instability + GC pressure at that allocation volume, it effectively never finishes —
this is Wall #2.

## O(N_rcv × N_src) signature — CONFIRMED

Normalized `time/(N_rcv·N_src)` and `allocs/(N_rcv·N_src)` are FLAT across both sweeps
(~3,960–4,400 ns and ~69–79 allocs per cell per source) — cost is O(N_rcv·N_src), i.e.
per output cell the whole N_src-wide contraction tree is rebuilt. NOT O(N_rcv + N_src).

## Type-instability — CONFIRMED

`Base.return_types` of the per-cell pipeline stages:
- `_index_at_cell`  → `ASTExpr`                         (concrete=FALSE)
- `_resolve_indices`→ `Union{NumExpr,Any,IntExpr,…}`    (concrete=FALSE)
- `_compile`        → `_Node`                           (concrete=true, but fed `resolved::ANY`)
`@code_warntype` shows `resolved::ANY`, `node::ANY` on the hot path.

## Profiler attribution — ROOT CAUSE REFINED

Dominant self-time is NOT `_compile` (0.2% of stacks). It is the per-cell **AST
re-resolution / re-unrolling**:
- `_resolve_index_of_arrayop` (resolve.jl:258/301) → `_foreach_aggregate_term`
  (resolve.jl:216/224/231/232) — re-expands the N_src-term reduction PER cell,
- `_sub_preserving` (helpers.jl:47/85/126) — re-substitutes the output index into the
  body PER cell,
- `reconstruct` / `_reconstruct_opexpr` (types.jl:335/464) — rebuilds OpExprs PER cell.

`_compile` is cheap by comparison. The killer is rebuilding the resolved AST 52,411 times.

## Verdict

Root cause CONFIRMED and SHARPENED: the observed-field evaluator re-runs the full
`_index_at_cell → _resolve_indices(+unroll) → _compile` pipeline for every output cell
because the output index is baked to a concrete Int at `_resolve_index_of_arrayop`
(resolve.jl:275, `k_vals = _eval_const_int(...)`), which forces const-array reads to
constant-fold to per-cell literals.

FIX (validated by this profile):
- Phase B: add `_NK_CONST_GATHER` — a runtime-indexed const/provider-array read — so a
  const-array access can survive resolution with the output index still SYMBOLIC.
- Phase C: hoist the entire resolve+unroll+compile ONCE with the output index bound as a
  parameter; per cell only rebind the output-index param and re-walk the type-stable
  `_NK_CONTRACTION`. Eliminates the per-cell rebuild AND the type-instability.

No second bottleneck observed (build_evaluator observed-synthesis not implicated; all cost
is in per-cell evaluation).
