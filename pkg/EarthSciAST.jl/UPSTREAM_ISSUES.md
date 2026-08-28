# Upstream issues we are waiting on

Six issues filed 2026-08-24 against Reactant.jl and Enzyme-JAX, all found while
compiling the ReSEACT atmospheric chemistry model through the Reactant backend
(`ext/EarthSciASTReactantExt.jl` + `src/tree_walk/oop.jl`).

Every candidate was re-verified against current versions before filing rather
than filed from the older write-ups. That mattered — two of the most serious
candidates turned out to be **already fixed upstream** and were not filed (see
[Not filed](#not-filed) below).

**Environment all of these were measured on:** Julia 1.12.6 x86_64-linux-gnu ·
Reactant 0.2.280 · Reactant_jll 0.0.405+0 · Enzyme 0.13.199 · EnzymeCore 0.8.21 ·
Enzyme_jll 0.0.290+0 · CPU (PJRT).

| # | Issue | Repo | Status |
|---|---|---|---|
| 1 | [`concat_broadcast_slice` merges concatenate operands along the wrong axis](https://github.com/EnzymeAD/Enzyme-JAX/issues/2938) | Enzyme-JAX #2938 | open |
| 2 | [`Ops.constant(::Number)` is not memoized while `Ops.constant(::DenseArray)` is](https://github.com/EnzymeAD/Reactant.jl/issues/3215) | Reactant.jl #3215 | open |
| 3 | [`broadcast_to_size` emits `broadcast_in_dim` for already-matching shapes](https://github.com/EnzymeAD/Reactant.jl/issues/3216) | Reactant.jl #3216 | open |
| 4 | [Batched forward mode fails to lower, by either available route](https://github.com/EnzymeAD/Reactant.jl/issues/3217) | Reactant.jl #3217 | open |
| 5 | [Segfault instead of a diagnostic when `CreateReverseDiff` fails](https://github.com/EnzymeAD/Reactant.jl/issues/3218) | Reactant.jl #3218 | open |
| 6 | [Missing autodiff rules for `stablehlo.case`, in either direction](https://github.com/EnzymeAD/Enzyme-JAX/issues/2939) | Enzyme-JAX #2939 | open |

Two notes on #3218. It is the one candidate that was **not** re-run on 0.2.280 —
it needs a ~600 s model build per probe and was last observed on Reactant 0.2.274
/ Reactant_jll 0.0.395+1 / Enzyme 0.13.190. And the defect is in Enzyme's
`CoreDialectsAutoDiffImplementations.cpp`, so it may get moved to EnzymeAD/Enzyme.
The requested fix — a null check on `revFn` before `revFn.getOperation()` — is
worth making whether or not the underlying failure still reproduces.

Reproducers live in the ReSEACT model repository under `tools/diag/`:
`rof_concat_repro.jl` (#2938), `reactant_emission_repro.jl` (#3215 and #3216),
`rof_batchfwd.jl` (#3217), `rof_repro.jl` / `rof_sweep.sh` / `rof_results.tsv`
(the #3218 bisection), `mwe_case_reverse.jl` (#2939). Full prior write-up:
`tools/diag/UPSTREAM_reverse_over_forward.md`.

## What each one unblocks

### #2938 — `concat_broadcast_slice` miscompile

**Today:** any build that forms this shape must pass
`excluded_passes=["concat_broadcast_slice"]`. Because the input program contains
no `concatenate` at all — `vcat` lowers to `dynamic_update_slice`, and the
pipeline itself forms the concatenate via `dynamic_update_to_concat` — there is
no way to avoid it by writing the emitter differently.

**Unblocks:** dropping that workaround, and more importantly *emitting
concatenates at all without fear*. Here it failed the verifier loudly, but the
same merge is a silent wrong-shape miscompile whenever the shapes happen to
agree. Two pieces of planned work emit exactly this shape and are gated on it:

- the **lattice-gather replacement** — merged access-descriptor slot vectors are
  affine lattices (`oop_merge.jl` concatenates each member's `out .+ delta`), and
  ~2/3 of the s64 index-constant bytes could be replaced by *k* strided slices and
  one `concatenate` instead of a `stablehlo.gather` over a dense index constant;
- `Reactant.Compiler.CONCATS_TO_DUS[] = true`, which rewrites in the opposite
  direction and therefore changes which concatenates survive to this pattern.

### #3215 — scalar constants not memoized

**Today:** `src/tree_walk/oop.jl`'s emission value-numbering seam (`ess-oop-gvn`)
exists partly to work around this. Two uses of the same scalar get different SSA
values, so structural CSE above them cannot see `k .* x` and `k .* x` as the same
expression — the sharing has to be recovered by our own memo instead.

**Unblocks:** simplifying or retiring part of the GVN seam, and smaller modules
before XLA runs. On a chemistry RHS the duplicated scalars account for thousands
of ops. Note this is a **trace-time and module-size** win, not an execution win —
XLA's CSE already collapses the duplicates before they execute.

### #3216 — broadcast scaffolding

**Today:** one elementwise `a .+ b` on two identically-shaped operands emits
eleven `stablehlo` ops (5 transpose, 4 broadcast_in_dim, 1 constant, 1 add).

**Unblocks:** the same thing as #3215 and by the same mechanism — Julia trace
time, peak MLIR module size, and sharing that structural CSE can no longer find.
Again **not** an execution win; XLA eliminates the redundancy. These two together
are the reason the emitted module is much larger than the arithmetic requires,
which is what makes trace and compile expensive at CONUS scale.

### #3217 — batched forward mode

**This is the one that unblocks a design choice rather than an optimisation.**

**Today:** a coloured Jacobian built from N serial forward derivatives does not
share one differentiated callee — each colour carries roughly its own copy of the
RHS. Measured on ReSEACT: **120.1 MB against 34.8 MB** for the same program with
a finite-difference Jacobian, a 3.5x module and a 6.1x trace time. Both documented
routes to a batched form fail to lower, so the only available shape is the one
that multiplies the nested-derivative count.

**Unblocks:** an AD-based Jacobian at a module size that is actually affordable,
which is currently the reason the symbolic block Jacobian
(`rx_sym_block_jac.jl`) and finite differences are carrying that role. It also
reduces what an *outer* derivative has to cross, which is the reverse-over-forward
adjoint path.

### #3218 — segfault instead of a diagnostic

**Today:** a reverse-over-forward compile dies with SIGSEGV, no MLIR diagnostic,
and a Julia `try`/`catch` cannot see it. The failing callee cannot be identified
from outside the compiler: the information exists only in the process that dies,
and the shipped `libReactantExtra.so` is stripped.

**Unblocks:** diagnosis, not performance. With `emitError()` in place the report
would have named the failing op in one run instead of a bisection that never
reproduced it on a toy. This is the difference between "reverse-over-forward is
mysteriously broken on large modules" and a specific, fixable callee.

### #2939 — no autodiff rule for `stablehlo.case`

**Today:** `Reactant.Ops.case` inside differentiated code is a hard compile
failure in both directions — reverse with `could not compute the adjoint for this
operation`, forward with `RegionBranchOpInterface not implemented`. It fails at
compile time rather than returning a silently wrong gradient, which is the good
kind of broken.

**Unblocks:** the least of the six, for us specifically, and worth saying so.
Two constructs in the same script already do this exactly, at relative error 0:

| Construct | Emits | Reverse mode |
|---|---|---|
| `@trace if` (2-arm) | `stablehlo.if` | exact, rel err 0 |
| `@trace if` (3-arm) | 2x `stablehlo.if` | exact, rel err 0 |
| `ifelse` | `stablehlo.select` | exact, rel err 0 |
| `Ops.case` | `stablehlo.case` | **fails** |

So there is a working route today and nothing is blocked outright. What a fix
buys is spelling an n-way branch as ONE dispatch instead of n-1 nested two-arm
`stablehlo.if`s — which matters if a multi-way branch ever lands on a hot lane
axis, and not otherwise. The narrowness of the gap is also the argument for it
being tractable to implement; precedent is Enzyme-JAX #1579 (`stablehlo.sort`),
closed once a concrete case arrived.

Related correction: our own `HELPERS.md` used to say "keep `@trace if` out of
differentiated code". That is wrong — `@trace if` emits `stablehlo.if`, never
`stablehlo.case` (`grep -c Ops.case src/ControlFlow.jl` is 0 across
0.2.274-0.2.280), and it differentiates exactly. Only an explicit
`Reactant.Ops.case` reaches the broken op.

## What these do NOT unblock

Worth stating plainly so nobody waits on the wrong thing. The dominant costs
measured in the ReSEACT adjoint workstream are **not** caused by any of these:

- The ROS23 step is **bandwidth-bound**. It performs ~1,005 M element-ops of
  which only 4.1% is physics arithmetic; ~72% is traffic on >=500k-element
  buffers, dominated by whole-buffer `concatenate` rewrites of the flat extended
  observed buffer. That is an emitter-shape problem in *our* code
  (`_oop_prefix_copy` / `_oop_fill_levels`), not an upstream bug.
- **Build cost** was ~90% geometry setup, addressed by the compile-once and
  rank-specialisation fixes in `src/tree_walk/geometry_setup.jl`.
- **Compile cost** is sublinear in grid and driven by constant bytes, of which
  ~2/3 are affine-lattice gather indices we materialise ourselves.

#3215 and #3216 shrink the module handed to XLA, so they help trace and compile
time. Neither changes execution time. Only #3217 changes an architectural option.

## Not filed

Recorded so nobody re-walks them.

- **Reverse mode over a `while` loop with a data-dependent condition** —
  already open as Enzyme-JAX #2565. Do not re-file.
- **Enzyme-JAX #88** is the umbrella "Tracking issue for missing HLO derivatives"
  and already lists `CaseOp`. #2939 was filed as a standalone issue with a
  concrete Julia reproducer rather than as a comment there; nothing was added
  to #88.
- **Binomial checkpointing: wrong gradient + segfault — FIXED upstream.**
  Re-verified clean on 0.2.280, and confirmed to still fire on a pinned 0.2.274
  environment (rel 1.05e-3 wrong gradient; SIGSEGV rc 139), so the probes are
  known to fire rather than merely known to be quiet.
- **XLA:CPU wrong results with >1 intra-op thread — ~~FIXED upstream~~
  RETRACTED 2026-08-24, STILL FIRES, belongs on the file-it list.** The clean bill
  (238,400 calls, zero faults) was measured at 6x6x8. At CONUS with the
  `xla_cpu_prefer_vector_width=128` workaround off, a 40,000-call chemistry soak
  (`tools/diag/conus_race_soak.sbatch`, slurm 10127446, 4 intra-op threads, 3h03)
  produced **1 non-finite and 1 bit-differing call**: 13 non-finite entries, every
  state group at the single cell (2,1,1), at call 7,909. Four immediate re-issues
  of the byte-identical call each came back clean and each differed from the bad
  result in exactly those 13 entries — the documented signature. Rate ~2.5e-5,
  about 400x rarer than the ~1e-2 on record at 6x6x8, but not zero. Independently,
  slurm 10127204 leg 0 aborted a real CONUS backward sweep with `fixed-sequence
  replay of macro step 11 lands NaN`.

  **Why the clean bill was wrong, and the lesson worth keeping.** 6x6x8 is not
  merely a smaller n — it is the WRONG PROGRAM. Transport (`ssp_step`) never
  faulted in 40,000 CONUS calls either; only the larger chemistry graph reaches
  whatever is left. **No number of 6x6x8 calls can clear this flag.** A negative
  result is only as good as the program it ran on, and "we ran 238,400 calls"
  reads as thoroughness while measuring the wrong thing.
- **`update_global_state!(; xla_force_host_platform_device_count=N)`** — our own
  misuse, not a defect. That function is distributed-coordinator setup only and
  has no XLA-flag keyword; the flag belongs in `XLA_FLAGS`.

Because the Binomial entry is fixed, one piece of in-repo guidance is now wrong:
`Binomial(n)` is the **only** checkpointing setting that works with a runtime
trip count on 0.2.280 (no checkpointing and `Periodic(n)` both fail with
`'stablehlo.dynamic_pad' op can't be translated to XLA HLO`).

Separately, `xla_cpu_use_fusion_emitters=false` is not a field in 0.2.280's
`CompileOptions` DebugOptions at all, and the way it fails is a trap:
`CompileOptions(; xla_debug_options=(; xla_cpu_use_fusion_emitters=false))`
validates nothing and returns happily, then throws an `ArgumentError` later inside
`Reactant.XLA.get_debug_options` — i.e. at `@compile` time, after the trace.

## RESEACT_ADJ_XLAFIX: keep it at 1

Measured at CONUS on one allocation, both legs (slurm 10127204, NMACRO=12):
the workaround costs **1.13x peak RSS** (17.83 vs 15.82 GB) and **6.8% of forward
pass** (76.63 vs 71.78 s over a byte-identical accept/reject ladder); compile wall
time is a wash (1051.3 vs 1077.8 s). The driver comment's "roughly doubles compile
memory" does **not** survive. Its 4.0e-5 relative J shift does: +8.30e-05 measured
at 12 macro steps, same sign and order. But the MECHANISM has changed — in August
the gap was attributed to the racy leg integrating a different trajectory through
spurious rejections; here both legs produced byte-identical ladders and identical
accepted-step counts, so the residual gap is the vector-width change itself.
