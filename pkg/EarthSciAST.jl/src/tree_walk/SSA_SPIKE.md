# ess-oop-ssa — SSA-style class-to-class references in the `:oop` emitter (spike)

Status: **spike**, behind `ESS_OOP_SSA=1` (read at build time, default OFF — the
flag-off build is byte-for-byte the pre-spike emitter). Code: `oop.jl` (the
`_OopSSA*` section before `_oop_eval_acck`, the analysis section before
`_make_rhs_oop`, and the guarded arms threaded through `_oop_eval_acck` /
`_oop_run_acc_vec` / `_oop_fill_level`). Tests:
`test/tree_walk_oop_ssa_test.jl` (host, bit-identity + engagement + AD),
`test/reactant_oop_ssa_test.jl` (traced census; opt-in via `ESM_TEST_REACTANT=1`).

## What it attacks

The register-file tax measured on ReSEACT at 288 cells: the compiled `:oop`
step communicates between merged kernel classes THROUGH the flat extended
vector `ue` — every fill kernel's result scattered in (whole-buffer
`dynamic_update_slice` rewrites under a trace), every consumer reading it back
through dense precomputed gathers whose index vectors are also ~17 kB/cell of
constants. 58.3% of the optimized step's element volume was data movement; the
buffers are pure implementation artifact (the step returns only `(u_next, err)`).

With the flag on, a consumer descriptor references its producer's RESULT VALUE:

* **tier 1 (direct)** — the gather is exactly one producer's whole block ⇒ the
  producer's SSA value, zero ops;
* **tier 2 (slice)** — the gather decomposes into few consecutive-position runs,
  each inside one producer ⇒ one `slice` per run (+ one `concatenate` when
  more than one run);
* **tier 2b (producer gather)** — the mapping lies inside ONE producer but
  shatters into more runs than slices are worth ⇒ one `gather` of that
  producer's value at producer-local positions. Exactly the single op the dense
  `ue` gather was, over an index vector of the same length: the win is not op
  count, it is that the read no longer touches the flat buffer;
* **tier 3 (fallback)** — everything else keeps the dense gather from `ue`,
  byte-for-byte.

Three descriptor surfaces feed those tiers: a kernel's own top-level
descriptors, its TEMPLATE SUB-KERNEL (`_NK_SUBCALL`) descriptors — resolved by
`_build_oop_desc_vectors` against the same parent lanes, so decomposable by the
same map, but indexed by `S.acc` and therefore carried in a per-sub table — and
GHOST-MASKED `_AK_STATE_TBL_BOX` descriptors, where a masked lane's value is
discarded by the emitter's `ifelse` select and is therefore a WILDCARD the
decomposition fills with whatever continues a neighbouring run. Each of the
three has a bisect knob (`ESS_OOP_SSA_SUB`, `ESS_OOP_SSA_PGATHER`,
`ESS_OOP_SSA_GHOST`, all default ON inside `ESS_OOP_SSA=1`), which is what lets
one process A/B an arm and what each engagement test's negative control flips.

A producer's scatter into `ue` is emitted only when static accounting finds a
residual reader of its block; otherwise it is skipped and the value flows only
through references. Final `du` scatters (the real output) are untouched.

## Soundness (static facts + one runtime guard)

* Fill levels read the state and strictly LOWER levels only; redirects require
  `producer.level < consumer.level` (the raw state `u` is producer 1, level 0).
* Slot ownership is LAST-writer: slots rewritten by later kernels, level
  scalar fills, per-cell fallback kernels, or level scan folds are disowned
  (or re-owned by the later writer), and the level check refuses any redirect
  that could observe the wrong write.
* Every non-redirected read surface marks residual slots: scalar-walker trees
  (`_NK_STATE`, `_NK_STATE_GATHER`), E-lane (in-reduce) and sub-kernel plans,
  `_AK_STATE_FIXED` pins, ghost-masked table gathers, declined descriptors,
  level scan folds. Any per-cell (non-vectorizable) kernel disables ALL
  scatter skipping — its reads cannot be enumerated.
* Runtime guard: a producer whose spine hoists to a lane-invariant SCALAR
  records no value; redirects to it fall back to the gather and its scatter
  still runs, so the build-time `skip` verdict never outruns reality.

Bit-identity is the contract: a redirect returns the exact array (or slice of
it) the scatter would have copied, so `:oop`(on) ≡ `:oop`(off) ≡ `:inplace`
at Float64 `==`, ForwardDiff jacobians `==`, and compiled-on ≡ compiled-off
bit-for-bit (asserted).

## Coverage map (test fixtures, `oop_ssa_stats`)

"Edges" = redirect candidates: top-level cell-lane state-gather descriptors of
vectorizable kernels (ghost-masked ones excluded and counted as fallback).

| fixture | edges fast/total | elems fast/total | scatters skipped | notes |
|---|---|---|---|---|
| fan (2 observeds × 4 classes, N=12) | 11/11 | 132/132 | 2/2 | all tier 1/2 |
| chain g→h→state (N=12, ghost at edge) | 6/6 | 59/59 | 3/3 | build splits `h`; final read = 2-producer slice+concat |
| merged class (g1,g2 → one kernel, N=6) | 3/3 | 24/24 | 1/1 | member reads = slices at offsets inside ONE producer value |
| reaction–diffusion, no observeds (N=16) | 7/7 | 46/46 | 0/0 | prefix reads become slices of `u` |

Full suite (`Pkg.test()`, `ESM_TEST_REACTANT=1`) at 4x5-era main: flag OFF
89 034 pass / 8 broken / 89 042; forced ON 89 029 pass / 5 fail / 8 broken, the
5 being exactly `reactant_oop_intern_test.jl`'s interning-ENGAGEMENT assertions
(see Interactions below). Whole host corpus green with the flag FORCED on: tree_walk_oop (164),
oop_merge (75), array_obs_materialize (78), scan_prefix (333),
oop_scalar_batch (42), observed_materialization (20), observed_slots (36),
iip_generic — all bit-identical to `f!` — and green with the flag OFF
(default path untouched: tree_walk_oop 164, tree_walk_oop_ssa 45). A sweep
over the shared `tests/valid` conformance corpus is inert (the 16 fixtures
that build a bare evaluator are 0-D — no array kernels, 0 edges) and 16/16
bit-pattern-identical on/off.

## Census delta (raw `@code_hlo optimize=false`, ON vs OFF)

| module | total ops | dynamic_update_slice | constants | slices | concat |
|---|---|---|---|---|---|
| fan | **150** / 176 | **4** / 6 | **33** / 39 | 4 / 5 | 1 / 1 |
| chain | **77** / 113 | **1** / 4 | **14** / 23 | 6 / 7 | **2** / 1 |

The DUS delta equals `n_skipped_scatters` exactly (asserted); the extra chain
concatenate is the multi-producer reference's cost. On these toy fixtures
XLA's optimizer converges the two programs (18 ≡ 18 ops optimized) — at scale
that convergence is precisely what fails (pairwise slice-CSE went quadratic on
CONUS; the buffers exceed L3), so the emission-level census is the measure.

## Measured on ReSEACT — and the blocker order the spike guessed is WRONG

The spike listed its remaining tier-3 fallbacks "in expected ReSEACT impact
order" and put ghost-masked table gathers first. `oop_ssa_stats` now carries a
per-reason blocker tally (which read surface still reads each surviving
producer's block), and on the ReSEACT transport RHS at 6x6x8 it says:

| | spike | + this extension |
|---|---|---|
| top-level edges redirected | 51 / 100 | **97 / 100** |
| top-level elements | 5 292 / 32 148 | **24 948 / 32 148** |
| SUB-KERNEL descriptors redirected | 0 / 885 | **731 / 885** |
| sub-kernel elements | 0 / 1 074 487 | **896 863 / 1 074 487** |
| producer scatters skipped | 6 / 17 | **13 / 17** |
| blocked producers, by reason | sub 9, frag 5, scalar 2, scan 1 | sub 2, scalar 2, scan 1 |
| … blocked SOLELY by that reason | sub 4, frag 1 | scalar 2, sub 1 |

Two things in that table refute the spike's ordering:

* **there are ZERO ghost-masked descriptors in this build** (`n_ghost_edges = 0`
  at both 6x6x8 and on split part 2), and none at all in any of the 1-D host
  fixtures — so blocker #1, the one the note called the primary target, has no
  coverage to give here. It is implemented anyway (it is cheap and it is
  correct), and the unit tests cover it directly, but it is not what was
  holding the scatters.
* **the sub-kernel descriptors are the read surface that matters**: 885 of the
  985 candidate descriptors and 1 074 487 of the 1 106 635 candidate READ
  ELEMENTS — 33x the top-level edges' volume — and they held 9 of the 11
  surviving producer scatters alive. Blocker #2, listed second and described as
  "mechanical, not conceptual", was the whole game.

E-lane CSR gathers (#3) and `_AK_STATE_FIXED` pins are likewise 0 here. What is
left is blocker #4 (scalar-walker reads: 2 producers, and BOTH of them are
blocked by nothing else) plus one sub-kernel descriptor group and one level scan
fold.

## What blocks the rest (tier-3 fallbacks, in the order the spike GUESSED)

1. ~~**Ghost-masked `_AK_STATE_TBL_BOX` gathers**~~ — CLOSED (`_ssa_lane_owners`'
   wildcard fill), and measured at ZERO coverage on ReSEACT: no build in this
   corpus emits one. Kept because it is correct and free.
2. ~~**Sub-kernel (`_NK_SUBCALL`) descriptor plans**~~ — CLOSED (per-sub tables
   on `_OopSSAKernel.subs`, `_oop_ssa_subctx` at the `_NK_SUBCALL` arm). This
   was the real blocker: 731/885 descriptors and 896 863 read elements
   redirected, 7 more producer scatters skipped.
3. **E-lane (in-reduce) CSR gathers.** Per-entry `(cell, neighbour)` reads
   repeat cells — median run length 1 — so slices+concat lose to the gather;
   would need segment-level ops instead. Left as gathers deliberately.
4. **Scalar-walker and lane-batched scalar reads** (`_NK_STATE`,
   `_NK_STATE_GATHER`, batch slot vectors) — REDIRECTABLE, MEASURED, and NOT
   WORTH IT. They are reachable through the same slot→(producer, position) map,
   published per read surface as a consumer level; an implementation took
   transport from 13/17 to 15/17 scatters skipped and `blockers.scalar` to 0.
   It cost **4.3% on the transport reverse**: two whole-buffer copies removed
   against ~140 copy instructions added, because these reads were already cheap
   relative to the buffer versions they pinned, and redirecting one keeps a
   producer value live across a level boundary instead of letting it die into
   `ue`. Coverage is not the objective function; the copy census is.

   It is also INERT under the shipped gate. `ESS_OOP_SSA_SKIP_WHOLE` skips
   nothing unless EVERY tracked producer can go, and 15 of 17 is not 17 of 17 —
   the scan and sub-kernel blockers below survive it. So closing #4 alone
   changes no emitted program at the default; it would only pay as the LAST of
   the transport blockers to fall. Do not re-attempt it on its own.
5. ~~**Fragmented gathers**~~ (`nseg > min(64, max(8, L÷4))`) — CLOSED by tier
   2b: past the slice threshold a single-producer mapping gathers the producer's
   VALUE instead of the buffer. `frag` went 5 blocked producers → 0. A
   fragmented MULTI-producer mapping has no one-op form and still falls back.
6. **Per-cell fallback kernels** disable scatter-skipping globally (reads
   un-enumerable). Rare on affine builds.

## Interactions

* `reactant_oop_test.jl` passes 35/35 with the flag forced on (traced
  end-to-end, ODE solve, frozen-`t` contract, live-forcing refusal — all
  unchanged).
* `reactant_oop_intern_test.jl` under a FORCED corpus-wide `ESS_OOP_SSA=1`
  fails its 5 interning-ENGAGEMENT assertions (hits == 0, slices already
  minimal) while every value assertion passes: with the fan model's reads
  redirected there are no duplicate `ue` reads left for the memo to dedupe.
  That is the two features composing, not a regression — interning remains
  load-bearing for exactly the reads SSA does not redirect (ghost gathers,
  E-lane plans, fallback descriptors). The default suite (flag off) is
  untouched.
* Live forcing (`param_arrays`/`rhs_with_buffers`) rides through unchanged —
  forcing reads go through the buffers argument, never `ue` — and the
  discrete-cadence refresh stays visible with fill scatters skipped (probed).

## ReSEACT at CONUS: 1.36x on the whole adjoint loop, chemistry exact

Measured 2026-09-09 at 4x5 CONUS (13x7x72, 6 552 cells), two driver builds in
ONE process, arms interleaved, every pair run in BOTH arm orders — reproducing
to three digits, so the order is not what is being measured.
`tools/diag/p13_ssa_ab.jl` + `tools/diag/p11_ue_traffic.py` in the consuming
repo.

| program | arms off | arms on | off/on | copies | real element writes |
|---|---|---|---|---|---|
| `ros_step` (chemistry) | 38.90 ms | 28.23 ms | **1.38** (bit-for-bit) | | |
| `ros_vjp` | 81.11 ms | 56.71 ms | **1.43** (λ bit-for-bit) | | |
| `rhs` (transport RHS) | 3.755 ms | 6.405 ms | 0.59 | 2 → 3 | 2.49 M → 2.69 M |
| `rhs_vjp` | 80.5 ms | 72.2 ms | **1.12** | **98 → 82** | 59.55 M → 55.22 M |
| `ssp_step` (4-stage) | 13.41 ms | 24.25 ms | 0.55 | 8 → 12 | 10.43 M → 16.97 M |
| `ssp_vjp` | 306.6 ms | 254.9 ms | **1.20** | **394 → 331** | 231.8 M → 176.3 M |

Weighted by the adjoint's step mix (45.3 chemistry + 3.2 transport steps per
300 s window) the per-window cost is 6.46 s → 4.74 s, **1.36x**.

WHY THE TRANSPORT FORWARD LOSES. A producer's `dynamic_update_slice` into `ue`
ALIASES its operand in the FORWARD, so XLA:CPU writes only the update and the
scatter is nearly free there; skipping it instead forces the producer's value to
be materialized as its own buffer. On the PPM transport RHS (17 producers,
blocks up to 3 456 elements) that trade is a loss. On chemistry it is a win in
both directions, because there the redirect replaces fragmented gathers of the
12 326-element buffer with gathers of much smaller producer values and 59 of 59
scatters disappear.

The copies the scatter chain causes are all in the REVERSE, where each `ue`
version has ~70 live consumers and copy-insertion duplicates the whole buffer
per version. That is where removing readers pays on both halves: `ssp_vjp`
loses 63 of its 394 whole-buffer copies and 24% of its write traffic for 1.20x,
against a ~1.8x ceiling if every copy vanished.

It is also why `ess-oop-levelbase` (one read version per level) failed where
this succeeds: it reduced VERSIONS, which the forward already got for free,
instead of removing READERS. Its census went 99 → 102 copies; this one goes
98 → 82 and 394 → 331.

## The scatter-skip GATE: redundant is not the same as expensive

The verdict above is STATIC — "nothing reads this producer's block off `ue` any
more, so the scatter is redundant". It says nothing about COST, and the CONUS
table is the counter-example: the transport forward is 1.8x SLOWER with more
scatters skipped. So the skip is now gated, and finding the gate meant
instrumenting first. `oop_ssa_producers(f)` reports, per tracked producer, its
fill level, value length, how many redirected read surfaces now source from it
and at what element volume, how many of those take the whole value with no op
at all, the residual-read reasons, and both verdicts (`skippable`, `skip`).

**PRODUCER BLOCK SIZE — the obvious guess — is refuted by that table.** At
6x6x8:

| | transport (part 1) | chemistry (part 2) |
|---|---|---|
| producers | 17 | 59 |
| statically skippable | 13 | **59 — all of them** |
| skippable element volume | 4 874 of 8 042 | 53 964 of 53 964 |
| largest skipped block | 3 456 | **20 736** (then 10 368, 5 184) |
| redirected read volume / block | 0.125 … 58 230 | 1.0 … 198 |
| tier-1 (whole-value) reads | 4 producers, 1 each | 30+ producers, up to 87 |

Chemistry skips producers 6x larger than transport's largest and WINS, so no
size bound separates the two. Nor does the read-volume ratio: transport spans
both extremes of it.

What actually differs is **whether the flat buffer can DIE**. Chemistry skips
59 of 59, so nothing scatters into `ue` at all and the whole 12 326-element
buffer (247 423 at CONUS) is dead code. Transport skips 13 of 17, so `ue` is
assembled anyway — and a PARTIAL skip is the worst of both worlds: the flat
buffer is still allocated and still written by the four surviving producers,
AND each skipped producer's value becomes a buffer of its own instead of being
fused into an aliasing `dynamic_update_slice`. The forward pays for both.

So the gate is ALL-OR-NOTHING per build:

```
ESS_OOP_SSA_SKIP_WHOLE=1   (default) skip only when EVERY tracked producer's
                           scatter can go, so `ue` actually retires
ESS_OOP_SSA_SKIP_WHOLE=0   allow partial skipping (what the arms shipped with)
ESS_OOP_SSA_SKIP=0         never skip -- the negative control for the gate
ESS_OOP_SSA_SKIP_MAXLEN=n  per-producer block-size bound   (both RELEASED by
ESS_OOP_SSA_SKIP_MINRATIO=x per-producer read-volume bound   default: they are
                           the refuted hypotheses, kept bisectable)
ESS_OOP_SSA_SKIP_PIDS=3,7  per-producer bisect; `!3,7` inverts
```

Declining a skip is always CORRECT — it emits a write nothing reads, exactly
what the flag-off build does — and the gate touches only whether the scatter is
emitted. The redirect tables are untouched, so `n_skippable_scatters` (a
read-graph fact) is identical in every arm and only `n_skipped_scatters` moves;
`n_gate_declined` is the difference. On ReSEACT the default gate leaves
chemistry exactly as the arms had it (59 of 59, `ue` dead) and takes transport
to 0 of 17 — the redirects without the skip.

### Measured: the gate wins on BOTH sides

4x5 CONUS (13x7x72, 6 552 cells), three arms in ONE process, interleaved, both
arm orders (`tools/diag/p14_ssa_gate.jl` in the consuming repo). `noskip` is
what the default gate emits on transport (0 of 17) and `ungated` is #283
(13 of 17); on chemistry the gate emits `ungated` unchanged, so the chemistry
row is #283's.

| program | flag off | gate (= `noskip`) | #283 (= `ungated`) |
|---|---|---|---|
| `ssp_step` | 14.668 ms | 19.887 ms (**0.738**) | 21.310 ms (0.688) |
| `rhs` | 4.127 ms | 4.938 ms (**0.836**) | 6.523 ms (0.633) |
| `ssp_vjp` | 360.279 ms | 251.832 ms (**1.431**) | (1.203) |
| `ssp_vjp`, arms reversed | 347.620 ms | 254.526 ms (**1.366**) | |
| `ros_step` (chemistry) | | 1.38 | 1.38 |
| `ros_vjp` (chemistry) | | 1.43 | 1.43 |

The gate roughly HALVES the transport primal regression (0.688 -> 0.738 on the
4-stage step, 0.633 -> 0.836 on the bare RHS) and, unexpectedly, IMPROVES the
transport VJP from #283's 1.203 to 1.37-1.43: the redirects pay better once a
partial skip is not working against them. Chemistry is untouched — the gate
leaves that build structurally identical (59 of 59, `n_gate_declined = 0`).

**The falsifiable test of the explanation.** "A partial skip pays twice" and
"one big producer is the problem" both predict the transport regression; they
differ on what removing ONE producer does. `ESS_OOP_SSA_SKIP_PIDS=!17` drops
the skip of the 3 456-element producer (78 624 at CONUS, the largest by 15x)
and keeps the other twelve:

| `ssp_step` | flag off | #283 (13 of 17) | `!17` (12 of 17) |
|---|---|---|---|
| | 14.433 ms | 24.397 ms (0.592) | 24.768 ms (**0.583**) |

`no17` is not better than `ungated`. Size is not what makes a skip expensive;
PARTIALNESS is. That is why the gate is all-or-nothing and why the two
per-producer bounds ship released.

### The loop, counting replay

Per accepted step the adjoint runs the primal TWICE — the forward `T.step` and
the backward `T.replay` — and the VJP once, so a primal regression is paid
twice against one VJP win. Against the measured 2x2.5 48 h decomposition
(576 windows, transport step+replay 427 s and vjp 2 048 s):

| term | flag off | #283 | + this gate |
|---|---|---|---|
| chemistry (step + replay + vjp) | 5 106 s | 3 633 s | 3 633 s |
| transport (step + replay + vjp) | 2 475 s | 2 411 s | **1 995 s** |
| refresh | 1 792 s | 1 792 s | 1 792 s |
| host remainder | 123 s | 123 s | 123 s |
| **loop** | **9 495 s** | 7 959 s (1.19x) | **7 543 s (1.26x)** |

Transport was a WASH under #283 — the 1.20x VJP win almost exactly cancelled
the doubled primal regression, so the whole 1.19x was chemistry. With the gate
transport is a real 1.24x and the loop moves 1.19x -> 1.26x. The break-even for
the gate is `ssp_vjp >= 1.032`; it delivers ~1.40, so the trade is net-positive
by a wide margin rather than marginally. (Predicted 1.257x from the break-even
arithmetic before measuring; measured 1.26x.)

### The criterion NOT met, and further work

The target for the gate was the transport primal back to >= 0.95 of flag-off.
It is **0.738** on `ssp_step` and 0.836 on `rhs`. The gate halves the
regression; it does not remove it. With ZERO scatters skipped the only
difference from flag-off is the redirects themselves, so something on the
transport primal still materializes that the flat-buffer gather did not — the
producer values that the sub-kernel and tier-2b redirects now read from. That
is the next thing to measure (a per-arm redirect gate would price it), and it
is a separate decision from the skip.

## What is NOT verified

Bit-identity across the arms is asserted and holds on HOST (`==`) and, on the
toy fixtures, in the traced census (`reactant_oop_ssa_test.jl`, which pins the
DUS delta to `n_skipped_scatters`). At CONUS the two arms are NOT bit-identical:
changing the operand graph changes XLA's fusion, hence FMA and vectorization
order. chemistry `ros_step` is bit-for-bit and `ros_vjp`'s λ is bit-for-bit; on
transport the largest ABSOLUTE difference is 5.6e-15 on `ssp_step` (1.1e-18 of
scale) and 3.5e-18 on `ssp_vjp`'s λ (3.2e-16 of scale), and NOT ONE of the
85 176 state or λ components in any program differs by more than 1e-9 of that
quantity's own scale. The POINTWISE relative metric is uninformative here — it
reads exactly 2.0 on an opposite-signed component at ~1e-310 — which is why the
probe reports absolute and scale-relative figures plus a component count.

## Generalization assessment (honest)

The chemistry chain this spike targets is exactly the fixture shape that
redirects 100%: merged `_is_outs` classes with concatenated member runs,
consumers reading per-member slices (the gather-lattice study measured ~2/3 of
ReSEACT's dense gathers decomposable into slices+concat, and the rest keep the
fallback plus the corresponding producer scatters). The Jacobian and stage
solves run through the same emitter, so they inherit whatever the RHS trace
gains; nothing here is chemistry-specific. NOT verified here: ReSEACT itself
(needs the offline env) — the A/B timing is the coordinator's follow-up.
