# Julia compiler census — phase 0 of "Choosing the Compiler"

Branch `compiler/census-julia`, cut from `compiler-selection` at 4d03022b9. Nothing in
`src/`, `ext/` or `test/` was modified; the only tracked addition is
`pkg/EarthSciAST.jl/scripts/compiler_census.jl`, the sweep driver, and this document.

The question phase 0 has to answer is narrow and factual: **the `native` compiler will
refuse any document whose right-hand side still walks the expression tree once per output
cell. How many corpus documents is that, and why?** Everything below is measured or cited;
nothing is proposed.

Raw sweep output (not committed): `/scratch/ctessum/compiler-sel/logs/census-julia/`
— `census.jsonl` (one JSON object per document), `manifest.txt`, the per-shard
`census.jsonl.shard*` files with their `.err`/`.out` companions, the slurm job log
`slurm-10661421.out`, and the two read-only aggregators `aggregate.py` and `section1.py`
(the latter emits §1 of this document verbatim, so no number below was transcribed by
hand).

## Summary

| | |
|---|---|
| documents in the corpus | 1217 (859 under `tests/`, 358 under `EarthSciModels`) |
| documents that build | 817 |
| …that reach the array cascade at all | 126 |
| …with a per-cell landing at BUILD | 3, **all of them build-only** |
| …with a per-cell tree walk at RHS-call time | **0** |
| codegen declines, any reason, either pass | **0** |
| decline / bail sites classified | 47 throw sites + 16 speculative catches + 2 unguarded ones |
| sites whose landing walks the tree per cell at RHS | 2 kinds: a `_CodegenDecline` that recurs on the overflow pass, and the whole-array contraction tier *accepting* |
| simulation/build test files classified | 155 (97 stay, 52 move to a fixture, 6 to a refusal tier) |
| `ESS_*` reads in `src/` + `ext/` | 67 sites, 61 variables; 60 test files touch 47 of them |

Three things in here were not in the plan's description of the cascade and change how the
census has to be read; each is substantiated in §0 and §2.

1. **The whole-array contraction tier is not code-generated.** When it *accepts* an
   equation, its runner walks the tree once per output cell on every right-hand-side call
   (array_contraction.jl:71-79). On this tier success, not decline, is what leaves an
   interpreter in the RHS.
2. **A primary codegen decline does not mean the interpreter runs.** The overflow emission
   retries at `typemax(Int)` and, with `ESS_F64_OVERFLOW_CODEGEN` on, serves Float64 as
   well. Only a decline that recurs there reaches `_run_acc_kernel!`. `:budget`, the one
   cost-class reason, structurally cannot recur.
3. **Two catch blocks on the array-contraction path swallow every exception** with no
   `_is_resource_error` guard (resolve.jl:640, build.jl:4367), against the doctrine in
   errors.jl:56-78 — on the very tier that exists because the alternative exhausts memory.
   Recorded, not fixed.

---

## 0. What "per-cell interpreter at RHS time" actually means in this build

`_CASCADE_TALLY` alone cannot answer the question, and the plan's shorthand — "a rule lands
on the per-cell interpreter runner" — needs three distinctions the tally keys do not draw.
All three were read out of the code before the sweep was written.

**(a) Per-cell BUILD is not per-cell RHS.** `:percell_loop` / `:percell_acc`
(build.jl:4315) record that a `faq` equation declined every whole-array tier and was
scalarized one output cell at a time *at build*. The resulting cell entries are merged into
indirect-outs access kernels (acc_merge.jl) and those kernels are then offered to the
codegen tier like any other. A document can be entirely per-cell at build and entirely
compiled at RHS.

**(b) A primary codegen decline is not the interpreter either.** `_build_codegen_rhs`
(codegen_kernel.jl:1421) runs twice. The PRIMARY pass emits under
`_codegen_node_budget()` = 64,000,000 nodes; whatever it declines is retried by the
OVERFLOW ("dual") pass under `_dual_codegen_node_budget()` = `typemax(Int)`
(codegen_kernel.jl:119). With `ESS_F64_OVERFLOW_CODEGEN` on — the default,
codegen_kernel.jl:145 — the overflow generated function *also serves Float64 calls*
(codegen_kernel.jl:1744-1770). So `codegen_decline_budget` on its own means "compiled by
the second emission", not "interpreted".

**(c) `dual_codegen_decline_<reason>` is the real count.** A kernel both emissions decline
ends up in `_KernelSection.dual_resid` and is run by `_run_acc_kernel!`
(codegen_kernel.jl:1740 / :1767, access_kernel.jl:675) — the `_eval_acc` tree walk, once
per output cell, under every element type. Summed over a build, the
`dual_codegen_decline_*` tally keys are exactly `length(dual_resid)`, because
`_build_codegen_rhs` bumps exactly one tally key per kernel (a `_kernel` key on success,
a `_decline_<reason>` key on failure) and does so *before* the `any(covered) || return
nothing` early exit. A build makes kernel sections at two places — the main RHS
(acc_merge.jl:673) and each observed level (build.jl:3025) — and both feed the same tally,
which is right: an observed-level kernel the emitter declines walks per cell on every RHS
call too.

**One more RHS-time tree walk the plan does not name.** The whole-array contraction tier
(`:array_contraction`) is *not* codegen'd. Its runner is
`array_contraction.jl:71-79`, and its inner statement is

```julia
for c in eachindex(outs)
    _ac_seek!(ac, c)
    du[outs[c]] = _eval_node(body, u, p, t, T)
end
```

— one `_eval_node` tree walk per output cell, every RHS call. The file says so itself
("a section is invisible to every one of them", array_contraction.jl:18-21). By the
plan's own criterion this tier is a per-cell interpreter at RHS time, so the census
reports it as a separate column rather than folding it into the headline.

So the census reports **two separate quantities**, and the difference between them is the
whole point of the exercise:

* **per-cell at BUILD** — `:percell_loop` / `:percell_acc` fired, the equation was
  scalarized once per output cell during construction, and the kernels that came out of
  it were then compiled. The right-hand side carries no tree walk from it. This costs
  build wall time and build memory, nothing per step.
* **per-cell at RHS** — a kernel both codegen passes declined, or an accepted whole-array
  contraction. This is what runs on every right-hand-side call, and it is what `native`
  refuses.

A document can be entirely in the first category and entirely compiled at RHS.

Three interpreted surfaces are deliberately NOT in the second category, listed so nobody
mistakes them for it:

* the scalar equation list (`acc_merge.jl:743`, one `_eval_node` per scalar state slot per
  call) and the CSE prelude tiers (`acc_merge.jl:708/729/740`). These are per RHS call but
  per *slot*, not per cell; every document has them, and they scale with the number of
  scalar states rather than with a grid.
* `:scan`. `_apply_scan_fold!` (scan.jl:108) accumulates over `du` slots and evaluates no
  tree; the scan tier's *terms* go through the ordinary affine and codegen tiers.
* the whole of `geometry_compile.jl`, whose own header calls it "the COMPILED **setup-time**
  geometry path" (geometry_compile.jl:5). Its `_eval_node` per cell
  (geometry_compile.jl:418-420, :470) runs during materialization, not from `f!`.

---

## 1. Corpus census

**The answer, up front: on this corpus the `native` compiler would refuse nothing.** Of
the 817 documents that build, **zero** leave a kernel on the per-cell interpreter at
right-hand-side call time, and **zero** produce a codegen decline of any reason, on either
emission pass. Three documents scalarize an equation per output cell — but all three do it
at BUILD only; the kernels that came out were compiled, and their right-hand sides walk no
tree.

That is a real result about this corpus, not about the language. It is also a result about
what the corpus is: only 126 of the 817 built documents (15%) contain an array equation
that reaches the cascade at all. The rest are scalar fixtures whose right-hand sides run
the scalar `_eval_node` list, which is interpreted but per slot, not per cell (§0).

**Limits of this sweep, stated so the zero is not over-read.**

1. **The source-receptor document the whole-array contraction tier exists for is not in
   the measured set, and cannot be reached by this harness.**
   `tests/conformance/pushdown/fixtures/isrm.esm` fails the census run with
   `E_TREEWALK_UNSUPPORTED_SHAPE: ISRM.src_N`. Setting `pushdown_rewrite = true` does not
   rescue it either — it then fails with `KeyError: key "ISRM.X" not found`, because the
   pushdown gates are derived from *provider* records the census supplies none of
   (both checked directly; log `isrm_probe.log`). Corpus-wide the `:array_contraction`
   tally is therefore 0: the one tier whose *accepted* path interprets per cell was never
   exercised by this sweep, and a document that does exercise it needs provider wiring a
   path-only census cannot give it. Nothing else in the corpus meets the tier's admission
   floor either — `_array_contraction_min()` is 1024 contracted elements
   (resolve.jl:598-602). **This is the single largest gap in the zero.**
2. **The fixtures are small.** `codegen_decline_budget` is the one decline reason that
   depends on extent rather than on the construct, and at these grid sizes nothing came
   near the 64-million-node budget. At production extents it would fire — and would still
   not reach the interpreter, because the overflow pass's budget is `typemax(Int)` and
   `f64cg` routes Float64 through it (§0b). The *capability* reasons, by contrast, are
   structural: a document that has `box_rank > 3` or an op outside the emitter ladders has
   it at every extent.
3. **Per-cell BUILD cost does scale with the grid.** The three build-only documents are
   cheap here (0.5–5.2 s) because their arrays are small. The scaling warning at
   build.jl:4241-4256 is about exactly this, and this census does not measure it.
4. **Documents needing a provider, a metaparameter binding or a model selection the front
   door cannot guess** fall back to `build_evaluator`, which skips flattening; 48 of the
   817 took that path. Their coupling is therefore not exercised.

**No document timed out, exhausted memory or killed its worker** across all 1217. The
`isrm.esm`-class out-of-memory risk did not materialise, for the reason limitation 1
gives: that document fails shape resolution in seconds and never gets far enough to
allocate.


### 1A. What the sweep covered

The manifest is every `.esm` under `tests/` in the worktree and under the read-only
`EarthSciModels` checkout: **1217 documents**. Each was built in a worker
process with `ESS_CODEGEN_DEBUG=1` and `ESS_STENCIL_DEBUG=1`, through
`EarthSciAST.esm_problem(path, (0.0, 1.0))` where that works and
`build_evaluator(load_path(path))` where the front door needs arguments the document
does not supply (providers, metaparameters, a model selection). Which entry point each
document used is recorded per document.

| | documents |
|---|---|
| in the manifest | 1217 |
| built | **817** |
| did not build | 400 |
| &nbsp;&nbsp;— from `tests/` | 859 in manifest, 471 built |
| &nbsp;&nbsp;— from `EarthSciModels` | 358 in manifest, 346 built |
| &nbsp;&nbsp;— built through `esm_problem` | 769 |
| &nbsp;&nbsp;— built through `build_evaluator` | 48 |
| median build wall time (built documents) | 1.50 s |
| total build wall time (built documents) | 20 min |

### 1B. Headline: per-cell at BUILD versus per-cell at RHS

The two are different questions and the corpus answers them differently. Counts are
over the **817 documents that built**.

| landing | documents | share of built |
|---|---|---|
| reaches the array cascade at all (any `:affine` / `:scan` / `:array_contraction` / `:percell_*`) | **126** | 15.4% |
| per-cell at BUILD (any `:percell_loop` / `:percell_acc` / `:percell_disabled`) | **3** | 0.4% |
| &nbsp;&nbsp;— of which BUILD-ONLY: the kernels were then compiled, RHS carries no tree walk | **3** | 0.4% |
| **per-cell at RHS — a kernel both codegen passes declined** | **0** | 0.0% |
| **per-cell at RHS — an accepted whole-array contraction section** | **0** | 0.0% |
| **per-cell at RHS — either of the two above (what `native` refuses)** | **0** | 0.0% |
| a PRIMARY codegen decline (the overflow pass may still have compiled it) | **0** | 0.0% |
| no per-cell landing of any kind | **814** | 99.6% |

Summed over the built documents, in the units each tally actually counts:

| quantity | unit | total |
|---|---|---|
| `:percell_loop` + `:percell_acc` + `:percell_disabled` | equations | 4 |
| kernels on `_run_acc_kernel!` at RHS (`dual_codegen_decline_*`) | kernels | 0 |
| whole-array contraction sections | equations | 0 |
| kernels the PRIMARY emission compiled (`codegen_kernel`) | kernels | 228 |
| kernels the OVERFLOW emission compiled (`dual_codegen_kernel`) | kernels | 0 |
| kernels the PRIMARY emission declined (`codegen_decline_*`) | kernels | 0 |

### 1C. Cascade landings, summed over the built documents

| tally key | total | documents |
|---|---|---|
| `codegen_kernel` | 228 | 126 |
| `affine` | 176 | 123 |
| `direct_classmerge_round1_merge` | 79 | 45 |
| `scan` | 7 | 5 |
| `percell_acc` | 4 | 3 |

### 1D. Decline-reason histogram

PRIMARY emission (`codegen_decline_<reason>`) — a decline here does **not** mean the
interpreter runs; the overflow emission gets the kernel next.

| reason | kernels | documents |
|---|---|---|
| _(none — no built document produced a primary codegen decline)_ | 0 | 0 |

OVERFLOW emission (`dual_codegen_decline_<reason>`) — **this is the per-cell
interpreter at RHS time**, one row per kernel in `_KernelSection.dual_resid`.

| reason | kernels | documents |
|---|---|---|
| _(none — no built document left a kernel on the per-cell interpreter)_ | 0 | 0 |

### 1E. Top 20 documents by per-cell kernels

Ranked by kernels left on the per-cell interpreter at RHS, then by per-cell BUILD
equations. `where` says whether the per-cell work survives into the RHS call.

| interp kernels at RHS | array-contraction sections | per-cell BUILD equations | where | build s | document |
|---|---|---|---|---|---|
| 0 | 0 | 2 | build only | 5.2 | `tests/valid/geometry/conservative_regrid_assembly.esm` |
| 0 | 0 | 1 | build only | 0.7 | `tests/valid/faq/join_moves_running_exhaust.esm` |
| 0 | 0 | 1 | build only | 0.5 | `tests/valid/faq/ragged_member_gather.esm` |

### 1F. Documents that did not build

Most of these are supposed not to build: `tests/invalid/**` is the invalid-fixture
corpus and the coupling libraries and template fragments are not standalone models.
Grouped by the error each one raised.

| count | status | error code / type |
|---|---|---|
| 77 | build_error | `SchemaValidationError` |
| 64 | build_error | `E_TREEWALK_NO_MODEL` |
| 47 | build_error | `unlowered_operator` |
| 39 | build_error | `unsupported_construct` |
| 24 | build_error | `E_TREEWALK_UNSUPPORTED_SHAPE` |
| 20 | build_error | `ParseError` |
| 11 | build_error | `E_TREEWALK_UNBOUND_VARIABLE` |
| 10 | build_error | `E_TREEWALK_UNSUPPORTED_RECURRENCE` |
| 6 | build_error | `derived_index_set_unmaterialized` |
| 6 | build_error | `E_TREEWALK_UNSUPPORTED_EQUATION` |
| 5 | build_error | `metaparameter_name_conflict` |
| 5 | build_error | `E_TREEWALK_AMBIGUOUS_MODEL` |
| 4 | build_error | `indexed_definition_unsupported_form` |
| 4 | build_error | `E_TREEWALK_UNDECLARED_INDEX_SET` |
| 4 | build_error | `MethodError` |
| 4 | build_error | `template_import_unknown_name` |
| 4 | build_error | `subsystem_index_set_rename_unknown_name` |
| 3 | build_error | `data_source_url_unresolved` |
| 3 | build_error | `unresolved_subsystem_ref` |
| 3 | build_error | `unknown_enum` |
| 3 | build_error | `E_TREEWALK_GEOMETRY_OPERAND` |
| 3 | build_error | `subsystem_index_set_conflict` |
| 3 | build_error | `E_TREEWALK_UNSUPPORTED_OP` |
| 2 | build_error | `template_constraint_unknown_index_set` |
| 2 | build_error | `template_inject_target_not_component` |
| 44 | build_error | _38 further codes, one to two documents each_ |

No document timed out, exhausted memory or killed its worker; the known
out-of-memory risk (`isrm.esm`-class documents) did not materialise in this corpus.

### 1G. Slowest builds

| build s | entry | document |
|---|---|---|
| 25.1 | `esm_problem` | `EarthSciModels/components/gaschem/geoschem_fullchem.esm` |
| 23.3 | `esm_problem` | `tests/bench/transport_3axis_7cubed.esm` |
| 12.2 | `esm_problem` | `tests/valid/derivative_trailing_boundary_operands.esm` |
| 12.0 | `esm_problem` | `tests/conformance/expression_templates/import_rename_diamond/fixture.esm` |
| 11.5 | `esm_problem` | `tests/valid/toplevel_ref_index_set_merge.esm` |
| 10.9 | `esm_problem` | `tests/conformance/expression_templates/import_rename_integral_axis/expanded.esm` |
| 10.8 | `esm_problem` | `EarthSciModels/components/atmospheric_deposition/wesley_dry_gas.esm` |
| 10.0 | `esm_problem` | `EarthSciModels/components/urban_canopy/urban_canopy_model.esm` |
| 9.2 | `esm_problem` | `tests/spatial/pde_inline_assertions_exec.esm` |
| 8.8 | `esm_problem` | `tests/valid/template_import_minimal.esm` |
| 8.5 | `esm_problem` | `tests/fixtures/faq/01_pure_ode_analytical.esm` |
| 8.5 | `esm_problem` | `tests/indexing/idx_outside_faq.esm` |

### 1H. Decline notices the build itself printed

`ESS_STENCIL_DEBUG=1` and `ESS_CODEGEN_DEBUG=1` were set for every document and their
stderr was captured per document (first 40 lines each, so line counts are a lower
bound on busy documents; document counts are exact).

| notice | lines | documents |
|---|---|---|
| `[ess-affine] FIRED` — the affine tier took the equation | 188 | 124 |
| `[ess-codegen/codegen]` emission summary | 143 | 126 |
| `[ess-affine] DECLINED` — fell through to per-cell BUILD | 4 | 3 |



---

## 2. Decline-site classification

Enumerated by grep over `src/tree_walk/` (plus the four `_is_resource_error` sites that sit
outside it and are reached from the build): `_CodegenDecline(` — 25 throw sites;
`_StencilFallback(` — 22 throw sites; `_is_resource_error` — 16 catch sites; `catch` —
24 blocks in `src/tree_walk/`.

Classes are as the plan defines them:

* **capability** — the fast tier cannot express the construct;
* **cost** — both paths can express it and a budget/cap/heuristic chose the slower one;
* **build-only** — only build time changes, the RHS-time shape is unaffected.

The extra column **"per-cell tree walk at RHS?"** is what ruling D6 turns on. Across all
47 throw sites and 16 speculative catches it is `yes` in exactly two places: a
`_CodegenDecline` that recurs on the overflow emission (group B), and — not a decline at
all — the whole-array contraction tier ACCEPTING an equation (group C's last row).
Everything else lands on a compiled or table-driven runner, or costs only build time.

### 2A. `_StencilFallback` — the affine stencil tier (22 sites)

Every one of these is caught at **`src/tree_walk/stencil_affine.jl:1418-1424`**
(`_try_affine_stencil`'s outer `catch`), which logs under `ESS_STENCIL_DEBUG` and returns
`nothing`. `build.jl:4196-4207` then retries the same body fused once (if the equation had
template sites), offers it to the whole-array contraction tier if that tier's gate admits
it (build.jl:4269-4281), and otherwise drops to `_compile_faq_percell!`
(build.jl:4326). The per-cell entries merge into access kernels and those go on to the
codegen tier, so the *RHS* is compiled unless group B also declines.

| file:line | enclosing fn | trigger | class |
|---|---|---|---|
| stencil.jl:416 | `_stencilize_op_core` | an elementwise op carrying structural fields (gates / filter / ranges) under a loop var | capability |
| stencil.jl:429 | `_stencilize_op_core` | a loop-var-dependent op outside the stencil vocabulary | capability |
| stencil.jl:589 | `_attach_exprtbl_evals!` | subtree-table rescue: the subtree is not build-time evaluable | capability |
| stencil.jl:707 | `_stencilize_index` | `index` with no arguments | capability |
| stencil.jl:716 | `_stencilize_index` | `index` rank ≠ the array's declared rank | capability |
| stencil.jl:724 | `_stencilize_index` | live-forcing (pgather) rank mismatch | capability |
| stencil.jl:732 | `_stencilize_index` | const-array rank mismatch | capability |
| stencil.jl:767 | `_stencilize_index` | index into a non-array / unknown variable under a loop var | capability |
| stencil.jl:802 | `_stencilize_indexed` | `makearray` region value of reduced rank | capability |
| stencil.jl:813 | `_stencilize_indexed` | `index(aggregate)` carrying a join or filter | capability |
| stencil.jl:817 | `_stencilize_indexed` | `index(aggregate)` `output_idx`/arg mismatch | capability |
| stencil.jl:820 | `_stencilize_indexed` | `index(aggregate)` with no body | capability |
| stencil.jl:842 | `_stencilize_indexed` | `index(aggregate)` contracted index not const-foldable | capability |
| stencil.jl:1055 | `_branch_key_indexed!` | branch key: contracted index not const-foldable | capability |
| stencil.jl:1163 | `_eval_recipe` | eval recipe: the subtree is not build-time evaluable | capability |
| stencil_affine.jl:113 | `_lower_to_access_node` | a contraction node inside a template body | capability |
| stencil_affine.jl:123 | `_lower_to_access_node` | an access-node kind the affine lowering has no case for | capability |
| stencil_affine.jl:342 | `_derive_output_affine` | the output layout is not affine in the output indices | capability |
| stencil_affine.jl:1092 | `_derive_lane_repl` | a loop-literal name that is not an output index | capability |
| stencil_affine.jl:1190 | `_derive_lane_repl` | pgather index not affine within the box | capability |
| stencil_affine.jl:1199 | `_derive_lane_repl` | pgather index not affine within the box (second arm) | capability |
| stencil_affine.jl:1271 | `_process_affine_box!` | box output slot disagrees with `var_map` | capability |

**Per-cell tree walk at RHS? No** — the landing path is a per-cell *build* whose kernels
are compiled by group B. What these sites cost is build time that scales with the grid
(build.jl:4241-4256 says so explicitly), not RHS time.

### 2B. `_CodegenDecline` — the RuntimeGeneratedFunction emitter (25 sites, 10 reasons)

All caught at **`src/tree_walk/codegen_kernel.jl:1450-1473`**, which rolls the partial
emission back, leaves `covered[j] == false` and bumps
`<tally>_decline_<reason>`. `tally` is `:codegen` on the primary pass and `:dual_codegen`
on the overflow pass.

| reason | sites | trigger | class | per-cell tree walk at RHS? |
|---|---|---|---|---|
| `budget` | codegen_kernel.jl:285 | emitted-node count passed `_codegen_node_budget()` (64 M, `ESS_CODEGEN_NODE_BUDGET`) | **cost** | **no** — the overflow pass's budget is `typemax(Int)`, so this reason cannot recur there; the kernel is compiled by the second emission and served at Float64 too (`f64cg`) |
| `unsupported_desc` | :383 | an access descriptor kind `_cg_fetch` has no case for | capability | **yes** if the overflow pass declines it too — same code path, so it does |
| `foreign_scratch` | :449 | a CSE read whose owning prelude is not this section's; `ESS_CG_FOREIGN_SCRATCH_DISABLE` forces it | capability | **yes** on the same condition |
| `unsupported_bound` | :457 | a reduction bound that is neither `_FixedBound` nor `_VarBound` | capability | **yes** |
| `unsupported_op` | :483, :702, :708, :710, :715, :719, :723, :726, :731, :737, :744, :749, :754, :759, :762 | an op outside the four emitter ladders, or the right op with the wrong arity | capability | **yes** |
| `unknown_kind` | :490 | an `_Node` kind the emitter does not handle | capability | **yes** |
| `subcall_order` | :668 | a sub-kernel whose invariant slots were not registered before the call site | capability (an ordering limitation, not a construct) | **yes** |
| `fn_payload` | :845 | a closed-function payload shape the emitter cannot box | capability | **yes** |
| `box_rank` | :1039 | a strided Cartesian box of rank > 3 | capability | **yes** |
| ~~`body_split_unsupported`~~ | :1405 | the body exceeds `_codegen_fn_node_cap()` (20 000) and this Julia cannot split safely | **cost on Julia ≥ 1.12, capability below it** — `_cg_split_supported()` is a version gate (codegen_kernel.jl:1208-1223: on < 1.12 the inner functions become untyped opaque closures that box per cell and segfault when nested) | **yes** where it fires |

**REMOVED since this census.** `body_split_unsupported` no longer exists. The
split now has a second TRANSPORT (`_cg_split_by_value`): each sub-function is
compiled as its own `RuntimeGeneratedFunction` and reaches the body in a tuple
appended to `tabs`, called at a literal index, so no inner definition — and no
opaque closure — is involved. Julia < 1.12 takes that transport, every Julia can
split, and an oversized body is compiled rather than declined. The row is kept,
struck through, because the environment-dependent CLASS it recorded is the thing
that changed.

The reasons that recur on the overflow pass are the ones that put a kernel on
`_run_acc_kernel!`. `budget` is the only reason that structurally cannot, and now
the only one whose class depends on anything but the document.

### 2C. Whole-array contraction — the tier that accepts *and* interprets

| file:line | trigger | lands on | class | per-cell tree walk at RHS? |
|---|---|---|---|---|
| build.jl:4269-4281 (gate) | the tier is only *offered* the equation when the affine tier already declined, no gates/filter, constant contracted extents, ⊕ ∈ {+, *, max, min}, and ∏\|k…\| ≥ `_array_contraction_min()` | per-cell scalarize when the gate rejects | build-only (an admission rule, not a decline) | n/a |
| build.jl:4283-4301 (`ac === nothing`) | `_try_compile_array_contraction` could not resolve or lower the symbolic body | per-cell scalarize → access kernels → codegen | capability | no |
| build.jl:4367 (`catch` → `return nothing`) | `_compile` threw on the symbolic marker body | same | capability | no |
| **accepted path** (`:array_contraction`, build.jl:4288) | the tier took the equation | `_apply_array_contraction!`, array_contraction.jl:71-79 | — | **yes** — `_eval_node` per output cell, and no codegen tier ever sees it |

The last row is the one worth flagging: on this tier, *success* is the case that leaves a
per-cell tree walk in the RHS. Whether `native` must refuse it is a ruling, not a
measurement, so the census reports the count separately.

### 2D. Speculative catches (`catch err; _is_resource_error(err) && rethrow(); …`)

The doctrine is in `src/errors.jl:56-78`: a speculative pass may decline on any error
except `OutOfMemoryError`, `StackOverflowError` and `InterruptException`, which must pass
through unwrapped.

| file:line | enclosing fn | trigger | lands on | class | per-cell at RHS? |
|---|---|---|---|---|---|
| tree_walk/resolve.jl:556-559 | `_try_build_contraction_loop` | the body will not `_resolve_indices` with the contracted indices symbolic | the unrolled contraction (correctness first) | capability | no |
| tree_walk/geometry_setup.jl:1332-1344 | `_fill_map_fast` caller | the compile-once setup map cannot evaluate a leaf | `_fill_map_percell` — a **setup-time** sweep | build-only | no |
| tree_walk/oop_merge.jl:552-555 | `_merge_acc_kernel_classes` | merging a kernel class threw, or the merged plan is not vectorizable | the class's members stay unmerged | cost | no |
| tree_walk/oop_merge.jl:980-983 | cross-equation merge | same, for the cross-equation classes | same | cost | no |
| tree_walk/build.jl:555-563 | declared-dims probe | a range this pass cannot read as a dense integer interval | "not a declared-dims producer" | build-only | no |
| tree_walk/build.jl:1397-1405 | scalar `ic` const-fold | the `ic` RHS does not const-fold | **rebrands** as `E_TREEWALK_UNSUPPORTED_EQUATION` — a hard build error, not a decline | build-only (refusal) | no |
| tree_walk/helpers.jl:585-590 | `_resolve_field_ic` step (2) | the `ic` RHS is not a broadcast constant | try step (3), then a hard error | build-only | no |
| tree_walk/helpers.jl:599-602 | `_resolve_field_ic` step (3) | not a coordinate expression either | the step-(4) hard error | build-only | no |
| tree_walk/helpers.jl:772-775 | field-IC fast path | `_compile` declined the closed-form body | the per-cell **IC** fill (setup, not RHS) | build-only | no |
| tree_walk/helpers.jl:916-919 | `_CellEval` builder | resolve/compile declined the cellwise expression | the per-cell setup fill | build-only | no |
| lower_expression_templates.jl:1455-1460 | manifold pre-check | a template reference that will not expand | leaves the diagnostic to the build path | build-only | no |
| lower_expression_templates.jl:2436-2440 | `_esm_stamp_floor` | an unparsable version string | the machinery floor | build-only | no |
| pointwise_lift.jl:74-80 | `_detect_lift_loops` | an unknown template / bad bindings while peeking | detection fails as before | build-only | no |
| pointwise_lift.jl:341-347 | shape walk | same | same | build-only | no |

Two catch blocks in `src/tree_walk/` swallow **everything**, with no `_is_resource_error`
guard, contrary to the `errors.jl` doctrine:

| file:line | code | what it swallows |
|---|---|---|
| tree_walk/resolve.jl:640-642 | bare `catch` → `return nothing` (`_try_build_array_contraction`'s symbolic resolve) | an `OutOfMemoryError` or `InterruptException` raised while resolving the symbolic body becomes a silent tier decline |
| tree_walk/build.jl:4367-4369 | bare `catch` → `return nothing` (`_try_compile_array_contraction`'s `_compile`) | the same, one frame later |

Both are on the array-contraction path, which is the tier that exists precisely because
the alternative exhausts memory — so these are the two places where an out-of-memory
build is most likely to be misread as "this document does not fit the tier". Recorded,
not fixed; this is a census.

The remaining `catch` blocks in `src/tree_walk/` are not declines and are listed for
completeness: `compile.jl:1021` (memoizes a `CanonicalizeError` then rethrows),
`compile.jl:1044` (CSE keying — `err isa CanonicalizeError || rethrow()`),
`build_helpers.jl:318` (the broadcast-lowering budget, `_BroadcastBudgetExceeded` → the
memoized walk; a pure build-time cost switch), `geometry_setup.jl:84` and `:445`
(`GeometryError` → a build diagnostic / a zero-area cell), `resolve.jl:1326` and `:1359`
(`TreeWalkError` → "this index is not statically discoverable"), and `build.jl:5364`
(`E_TREEWALK_UNBOUND_VARIABLE` → `UnboundVariableError`).

---

## 3. Test-file classification

Scope: every file under `pkg/EarthSciAST.jl/test/` that runs a simulation or a build,
found by grepping for `esm_problem`, `solve(`, `build_evaluator`, `run_inline_tests`,
`simulate(`, `simulate!`. The literal `solve(` also matches `resolve(`, which inflates the
raw grep by 31 files; each was checked and 30 of them do perform a real build, so they are
kept. `test/native_typed_agreement_test.jl` is the one exclusion — it matched only through
`resolve(` and never builds. Final set: **155 files**. Three further files build but match
none of the six terms and are noted at the end.

Buckets, as the plan defines them:

1. **move-to-fixture** — a document plus an expected trajectory or observed value; a
   candidate for a cross-language fixture with an inline `tests` block or a golden.
2. **stays** — checks binding-internal state: allocations, threading, progress callbacks,
   build inspection, cascade tallies, type stability, generated-function internals.
3. **refusal tier** — checks a refusal or a diagnostic; belongs in a golden-free refusal
   tier.

Totals: **stays 97, move-to-fixture 52, refusal tier 6.**

### 3A. Bucket table

| File (under `pkg/EarthSciAST.jl/`) | Bucket | Reason |
|---|---|---|
| test/access_kernel_foundation_test.jl | stays | Hand-builds access-kernel IR and pins bit-identity of `_eval_acc` / `_run_acc_kernel!` against a per-cell reference. |
| test/array_contraction_test.jl | stays | Differential bit-identity against the `ESS_ARRAY_CONTRACTION_DISABLE` build, plus cascade-tally assertions. |
| test/array_obs_materialize_test.jl | stays | Differential against the `ESS_ARRAY_OBS_INLINE=1` build; the oracle is another Julia build, not a document. |
| test/array_ops_test.jl | move-to-fixture | Builds array-op documents, solves, checks against analytical references (minority: MTK lowering and parse round-trip). |
| test/auto_pushdown_rewrite_test.jl | stays | Asserts four specific internal constructs; the numeric oracle is a hand-written plain-Julia model. |
| test/broadcast_alignment_test.jl | move-to-fixture | §4.3.4 broadcast/name-alignment semantics with expected values against an explicit-`faq` oracle. |
| test/build_inspection_test.jl | stays | The subject is `BuildInspection`, a binding-internal observability surface. |
| test/build_once_spatial_field_conformance_test.jl | move-to-fixture | Already a conformance adapter over a shared fixture plus an analytic golden (§5.12). |
| test/cg_foreign_scratch_test.jl | stays | Codegen emitter declines, `_CSECache` reads and cascade tallies. |
| test/codegen_body_split_test.jl | stays | Forced-split codegen via `ESS_CODEGEN_FN_NODE_CAP`; asserts the tier did not decline. |
| test/codegen_kernel_test.jl | stays | Differential oracle: codegen against the `ESS_CODEGEN_DISABLE` interpreter, with tally checks. |
| test/codegen_lanespec_test.jl | stays | Differential oracle over per-lane interp specs inside the emitter. |
| test/codegen_subcall_fn_test.jl | stays | Sub-kernel `@noinline` function tier, node-count floor, cascade tally. |
| test/codegen_threaded_test.jl | stays | Chunk partitioning, thread disjointness, a threaded subprocess run. |
| test/compile_once_templates_test.jl | stays | Bit-identity of the compile-once tier against the `ESS_TEMPLATE_REF_DISABLE` image. |
| test/conformance_assertion_nonfinite_test.jl | move-to-fixture | Conformance adapter: the §6.6.3 assertion predicate over shared fixtures with expected verdicts. |
| test/conformance_assertion_tolerance_test.jl | move-to-fixture | Conformance adapter pinning the tolerance predicate as a pure function of (actual, expected, rel, abs). |
| test/conformance_const_array_gather_bounds_test.jl | refusal tier | Every case pins `E_TREEWALK_CONSTARRAY_OOB` or an in-range control. |
| test/conformance_elementwise_observed_gather_test.jl | move-to-fixture | Runs `run_inline_tests` over committed fixtures and reproduces committed goldens. |
| test/conformance_override_key_diagnostics_test.jl | refusal tier | Pins unknown / ambiguous / resolving `parameter_overrides` keys as errors. |
| test/conformance_pde_inline_array_overrides_test.jl | move-to-fixture | Conformance adapter over committed fixtures and goldens (shaped inline array data). |
| test/conformance_pde_inline_dead_observed_test.jl | move-to-fixture | Conformance adapter reproducing committed golden actuals for a dead array observed. |
| test/conformance_pde_inline_ic_param_override_test.jl | move-to-fixture | Conformance adapter, committed fixture and golden for §6.6.5 build-time scope. |
| test/conformance_pde_inline_observed_indexed_lhs_test.jl | move-to-fixture | Conformance adapter for the indexed-LHS observed spelling. |
| test/conformance_pde_inline_observed_param_rank2_test.jl | move-to-fixture | Conformance adapter for a rank-2 parameter-referencing observed. |
| test/conformance_pde_inline_observed_rank2_test.jl | move-to-fixture | Conformance adapter for a rank-2 observed. |
| test/conformance_pde_inline_observed_state_dependent_test.jl | move-to-fixture | Conformance adapter for a state-dependent array observed. |
| test/conformance_pde_inline_reference_dimension_names_test.jl | move-to-fixture | Conformance adapter for dimension-name binding in a `reference`. |
| test/conformance_scalar_ic_test.jl | move-to-fixture | Conformance adapter over committed 0-D `ic` fixtures and goldens. |
| test/conformance_shaped_observed_scalar_broadcast_test.jl | move-to-fixture | Conformance adapter for scalar-to-shaped broadcast. |
| test/conformance_shaped_parameter_broadcast_test.jl | move-to-fixture | Conformance adapter for a shaped parameter with a scalar default. |
| test/conformance_static_evaluation_assertions_test.jl | move-to-fixture | Assertion `time` semantics on algebraic and integrating documents with expected values. |
| test/container_in_document_test.jl | move-to-fixture | Pins the cross-binding rule that a container's inline tests build over the whole document. |
| test/contraction_loop_test.jl | stays | Build-size scaling, zero-allocation hot path, tier identity against the unroll. |
| test/contraction_tier_order_test.jl | stays | Which internal tier a reduction is offered to, measured by cascade tallies and build cost. |
| test/cross_eq_class_emission_test.jl | stays | Class-emitter internals with four env-gated oracles and cascade tallies. |
| test/dag_walk_memo_test.jl | stays | Memoized DAG-walk complexity — a `foreach_subexpr_once` regression. |
| test/data_output_test.jl | stays | `build_output_callback` and sink lifecycle wiring around a hand-written ODE. |
| test/data_refresh_e2e_test.jl | stays | Callback and `tstops` composition, zero-allocation properties of the refresh seam. |
| test/data_refresh_test.jl | stays | `build_refresh_callback`: buffer identity, in-place refresh, allocation. |
| test/datetime_typed_core_test.jl | stays | Registry-declared typed scalar cores, allocation counts, per-tier differential builds. |
| test/direct_class_emission_test.jl | stays | Emitter grouping signature and grid-independent kernel counts via cascade tallies. |
| test/discrete_materialize_conformance_test.jl | move-to-fixture | Shared fixture and analytic golden (§5.13) that Python and Rust reproduce. |
| test/discrete_materialize_test.jl | stays | The `materialize_out` sink, cache-fill semantics and taint classification. |
| test/dual_fast_path_test.jl | stays | Dual overflow codegen tier against the interpreter, budget-gated, cascade-tallied. |
| test/esm_problem_test.jl | stays | `EsmProblem` as a Julia artifact: snapshot semantics, no re-derivation, `remake`. |
| test/expand_memo_oracle_test.jl | stays | Differential oracle for the template-expansion memo. |
| test/expanded_model_seam_test.jl | stays | The `expanded_model` API seam: non-mutation and name-resolution parity. |
| test/f64_overflow_codegen_test.jl | stays | Float64 routing through the overflow generated function against the interpreter oracle. |
| test/faq_conformance_test.jl | move-to-fixture | Loads shared `tests/valid/faq/` fixtures that already carry inline `tests` blocks. |
| test/flattened_to_esm_test.jl | stays | `reconstruct` / `flatten` / `flattened_to_esm` field-preservation plumbing. |
| test/fn_content_cse_test.jl | stays | Content-keyed value numbering of fn payloads inside the kernel CSE. |
| test/function_tables_lowering_path_test.jl | move-to-fixture | A real document whose `table_lookup` observed must answer its inline-test assertions. |
| test/geometry_assembly_conformance_test.jl | move-to-fixture | Shared fixture with exact rational expectations for the conservative-regrid assembly. |
| test/geometry_conformance_test.jl | move-to-fixture | Shared fixtures under the §5.8.2 tolerance gate, mirrored by Python. |
| test/geometry_overlap_join_conformance_test.jl | move-to-fixture | One shared fixture end to end with expected weights and fluxes. |
| test/geometry_polygon_intersection_area_test.jl | move-to-fixture | Shared conformance fixture for the fused clip-and-area leaf with expected areas. |
| test/geometry_ranged_clip_test.jl | move-to-fixture | Declarative overlap matrix with hand-computed 2x2 / 3x3 expectations. |
| test/grid_invariance_test.jl | stays | Asserts kernel counts, spine node counts, descriptor widths and tallies are grid-independent. |
| test/inline_tests_test.jl | move-to-fixture | `coords` / `integral` / `from_file` conventions pinned 1:1 with the Python and Rust suites. |
| test/intern_oracle_test.jl | stays | Differential oracle for AST interning. |
| test/inverse_trig_conformance_test.jl | move-to-fixture | Shared fixture whose inline `tests` block Python and Rust already check. |
| test/join_on_equality_gate_test.jl | stays | Two differential arms against the pre-change build plus enumeration-cost assertions. |
| test/join_on_self_join_test.jl | stays | Gated on `ESS_JOIN_ON_GATE_DISABLE` and the resolver's key-resolution internals. |
| test/lane_table_intern_test.jl | stays | Asserts object identity of interned lane tables in the build product. |
| test/loaded_ic_bc_simulation_test.jl | move-to-fixture | End-to-end run of a committed fixture with expected trajectory values. |
| test/loader_ingest_and_select_test.jl | move-to-fixture | Runs the committed ingest fixture and pins the same numbers as the Rust mirror. |
| test/merged_rename_reach_conformance_test.jl | move-to-fixture | Driven by a shared manifest under `tests/conformance/merged_rename_reach/`. |
| test/mounted_component_tests_test.jl | move-to-fixture | §6.6 mount-edge rule on fixtures already shared with Python and Rust. |
| test/mtk_continuous_event_options_test.jl | stays | A ModelingToolkit export detail (`SymbolicContinuousCallback.affect_neg`). |
| test/mtk_export_test.jl | stays | `mtk2esm` export and round-trip — a Julia-only direction. |
| test/observed_field_static_test.jl | stays | The `observed_field` API contract and its name-resolution rule. |
| test/observed_materialization_test.jl | stays | `_materialized_obs_scope` producer ordering and buffer reuse. |
| test/oop_merge_test.jl | stays | Kernel-class merge bit-identity against `ESS_OOP_MERGE_DISABLE`. |
| test/out_of_line_templates_test.jl | move-to-fixture | Drives the shared `tests/conformance/expression_templates/` families. |
| test/overlap_gate_conformance_test.jl | move-to-fixture | Two end-to-end documents with expected candidate sets and fluxes. |
| test/parameter_classes_test.jl | stays | The parameter-class partition and the `remake` refusal — a Julia runtime-API contract. |
| test/parameter_gradient_test.jl | stays | ForwardDiff derivative with respect to the parameter vector, `_rhs_value_type` promotion. |
| test/parameter_vector_abi_test.jl | stays | `ComponentVector` parameter ABI, allocation and type behaviour. |
| test/pde_inline_dead_observed_test.jl | stays | Julia-side regression on `BuildInspection.observed_exprs`; the cross-binding gate already exists. |
| test/pde_inline_scalar_slot_collision_test.jl | stays | `_scalar_slot` / `_state_cells` resolution under Julia's hash-ordered `Dict` iteration. |
| test/phase5_clean_auto_test.jl | stays | Fully-automatic pushdown checked against a hand-written plain-Julia oracle. |
| test/prepare_pushdown_record_gate_test.jl | stays | Gate derivation from the rewrite record, inspected through `BuildInspection`. |
| test/prepare_pushdown_single_member_test.jl | stays | A one-member support-set pin mirroring a Python test; asserts internal gather structure. |
| test/pushdown_cell_geometry_test.jl | move-to-fixture | §5.5.7 cell-axis renumbering with numeric expectations, paired with a Python mirror. |
| test/pushdown_edge_test.jl | stays | The internal const-tier dependency edge against a plain-Julia oracle. |
| test/pushdown_template_ref_test.jl | stays | Pins that the desugar recogniser declines through surviving template references. |
| test/reactant_direct_emit_test.jl | stays | Opt-in compiled-backend StableHLO emission checked against the Julia interpreter. |
| test/reactant_direct_sharding_test.jl | stays | Multi-device sharding agreement — hardware-gated backend internals. |
| test/reactant_lane_dedup_test.jl | stays | Size of the emitted XLA constant under lane dedup. |
| test/reaction_system_ref_test.jl | move-to-fixture | A reaction system mounted by reference must flatten and simulate identically to the inlined document. |
| test/real_mtk_integration_test.jl | stays | ModelingToolkit extension loading, `System` / `PDESystem` construction and export gating. |
| test/recurrence_validation_test.jl | refusal tier | Every case asserts the error code and the JSON pointer path for §4.3.1.1 rejection. |
| test/refresh_conformance_test.jl | move-to-fixture | Shared fixture and analytic golden (§5.10) reproduced by Python and Rust. |
| test/rhs_time_derivative_resolution_test.jl | move-to-fixture | §4.2 right-hand-side `D` resolution through `run_inline_tests` with expected values. |
| test/runtests.jl | stays | The suite driver itself (include order, target gating, verbose reporting). |
| test/scalar_batch_test.jl | stays | Build-time lane bucketing; host-only, asserts the build product. |
| test/scalar_ops_test.jl | stays | Differential agreement between three internal op ladders at the bit level. |
| test/scan_prefix_test.jl | stays | The O(N) scan path against the O(N^2) guarded fold, with cascade tallies. |
| test/scoped_assertion_variable_test.jl | move-to-fixture | Fixtures already shared with Python and Rust. |
| test/setup_map_compile_once_test.jl | stays | Bit-exactness of the compile-once setup-map materializer against the per-cell path. |
| test/shape_promotion_consumer_refs_test.jl | stays | `promote_downstream_shapes` consumer rewriting — an internal flatten/build pass. |
| test/shape_promotion_test.jl | stays | The same promotion pass, including the aggregate promotion boundary. |
| test/simulate_e2e_test.jl | move-to-fixture | Decay, reversible reaction, autocatalysis and Robertson, each with analytic or published references. |
| test/simulate_run_test.jl | stays | The `esm_problem` + `solve` two-step API surface and flattener naming. |
| test/stencil_affine_ad_test.jl | stays | ForwardDiff Jacobian bit-identity, affine against `ESS_STENCIL_DISABLE` per-cell. |
| test/stencil_affine_const_fold_test.jl | stays | `_derive_lane_repl` invariance derivation inside the affine stencilizer. |
| test/stencil_affine_contract_test.jl | stays | Unrolled contraction on the affine path against the per-cell reference. |
| test/stencil_affine_cross_shape_test.jl | stays | Cross-shape state-gather lowering with two additional kill switches. |
| test/stencil_affine_cse_test.jl | stays | Per-cell CSE on the affine spine; one evaluation per cell, zero allocation. |
| test/stencil_affine_diff_test.jl | stays | End-to-end differential affine against per-cell, with a tier-fired guard. |
| test/stencil_affine_fn_test.jl | stays | Interp `:fn` nodes on the affine path against the per-cell reference. |
| test/stencil_affine_invariant_test.jl | stays | Loop-invariant hoist slot counts and per-call re-evaluation. |
| test/stencil_affine_pgather_tbl_test.jl | stays | Non-affine forcing lane-table lowering against two oracles. |
| test/stencil_affine_pgather_test.jl | stays | Live-forcing gather lowered to `_AccForcingBox`; the aliased buffer is never copied. |
| test/stencil_indexed_contraction_test.jl | stays | Reduced-rank / contracted region values in `_stencilize_indexed`, cascade-tallied. |
| test/stencil_subtree_tbl_test.jl | stays | Subtree-table rescue against three internal build modes, with tally assertions. |
| test/streaming_checkpoint_test.jl | stays | Checkpoint predicate builtins, `DiscreteCallback` firing, Zarr restart plumbing. |
| test/streaming_coords_test.jl | stays | CF attributes and coordinate values on disk in a Zarr v3 store. |
| test/streaming_multigrid_test.jl | stays | `group_gridding_by_grid` sink splitting and per-store read-back. |
| test/subsystem_loader_conformance_test.jl | move-to-fixture | Shared fixture and analytic golden (§5.11) for a data source consumed by the owning model. |
| test/template_imports_test.jl | move-to-fixture | Drives the shared expression-template and invalid-template-import fixtures. |
| test/tests_blocks_execution_test.jl | move-to-fixture | Walks a shared fixture's inline `tests`, solves, verifies each assertion. |
| test/tree_walk_allocation_test.jl | stays | Allocation counts for `f!` at two grid sizes, plus thread-count interaction. |
| test/tree_walk_audit_fixes_test.jl | stays | Internal helpers: `_parse_cell_key`, `_sub_preserving`, the `_PGatherRef` side channel. |
| test/tree_walk_binning_alias_test.jl | stays | Two build-time limitations of the skolem/alias resolvers, read through `BuildInspection`. |
| test/tree_walk_const_array_boundary_test.jl | move-to-fixture | Periodic / clamp const-array boundary semantics with concrete expected values. |
| test/tree_walk_cse_test.jl | stays | `n_cse_slots` / `n_cse_occurrences` build diagnostics and allocation. |
| test/tree_walk_elementwise_obs_gather_test.jl | stays | Julia-side regression on the elementwise observed push-down; the cross-binding gate exists already. |
| test/tree_walk_faq_test.jl | move-to-fixture | `faq` derivative evaluation over discretized fixtures against analytic stencil values. |
| test/tree_walk_iip_generic_test.jl | stays | Eltype-generic `f!` scratch, Dual support, type stability and allocation. |
| test/tree_walk_indexed_observed_lhs_test.jl | stays | Julia owner-bucket collector regression; the cross-binding gate is the conformance adapter. |
| test/tree_walk_inline_const_index_test.jl | stays | Const-array registry interning of an inline `const` gather target. |
| test/tree_walk_join_test.jl | move-to-fixture | §5.3 join/filter semantics with expected values and invariances. |
| test/tree_walk_observed_slots_test.jl | stays | Named prelude slot counts, dependency order and fallbacks. |
| test/tree_walk_op_table_test.jl | stays | Containment relations between Julia's parallel op ladders and whitelists. |
| test/tree_walk_param_gather_test.jl | stays | `_NK_PARAM_GATHER` live-buffer aliasing and linearization. |
| test/tree_walk_semiring_test.jl | move-to-fixture | §5.1-§5.6 semiring identities and `aggregate` / `faq` equivalence with expected values. |
| test/tree_walk_tcadence_test.jl | stays | Time-cadence tier classification counts and skip behaviour across call sequences. |
| test/tree_walk_test.jl | move-to-fixture | Op-by-op expression semantics, decay and 1-D heat solves with expected values. |
| test/tree_walk_untiered_test.jl | stays | The `ESS_UNTIERED` kill switch itself — the reference every other tiering test depends on. |
| test/tree_walk_vectorized_test.jl | stays | Compiled kernel and spine node counts must be independent of N. |
| test/tree_walk_xcse_test.jl | stays | Cross-kernel fn-CSE through shared prelude slots; asserts slot sharing in the build. |
| test/unevaluable_operator_test.jl | refusal tier | §9.6.6: the op must be refused at build with the right code and name. |
| test/unlowered_operator_walk_test.jl | refusal tier | §9.6.3 constraint 6: `unlowered_operator` rejection at the document. |
| test/unsupported_construct_conformance_test.jl | refusal tier | Shared manifest of three constructs the evaluator must refuse with stated codes. |
| test/value_invention_frontdoor_test.jl | stays | The value-invention front door and `Relational` engine sizing inside the resolver. |
| test/value_invention_materialize_conformance_test.jl | move-to-fixture | Shared manifest with a value case and a refused case. |
| test/vi_overlap_scaling_test.jl | stays | Candidate-driven enumeration cost against the cartesian product — a performance property. |
| test/wall2/phaseE_engagement_test.jl | stays | Proves the compile-once fast path engages with zero fallback on a transcribed structure. |
| test/wildfire_simulation_test.jl | move-to-fixture | End-to-end `simulate` of the committed `wildfire_atmosphere_ocean.esm` against expected values. |
| test/wrt_default_omitted_test.jl | move-to-fixture | §4.2 "absent `wrt` means `t`", through `run_inline_tests` against explicitly-spelled twins. |
| test/xeq_variant_oracle_test.jl | stays | Differential oracle for the cross-equation variant memo. |
| test/zarr_sink_e2e_test.jl | stays | Sink lifecycle and EarthSciIO round-trip against an in-RAM reference run. |
| test/zero_alloc_harness.jl | stays | The shared allocation-measurement harness. |

Three further files build or run tests but match none of the six grep terms, so they are
outside the table; all three would bucket as **stays**: `test/run_esm_tests_test.jl`
(drives `run_esm_tests`), `test/geom_overlap_drive_test.jl` and
`test/geom_sweep_specialize_test.jl` (both drive `_materialize_geom_array` setup builds).

### 3B. Tests that set or read an `ESS_*` variable

These are the tests that have to be replaced, not merely moved, when the switches retire:
a test whose oracle is `ESS_<TIER>_DISABLE=1` has no oracle once the switch is gone, so it
needs either an agreement-tier fixture (two bindings must agree on the same document) or a
report assertion (the build must *say* which tier it used). **60 test files** touch at
least one `ESS_*` variable in code; **47 distinct variables** are touched.

| File (under `pkg/EarthSciAST.jl/`) | `ESS_*` variable(s) | Example file:line |
|---|---|---|
| test/access_kernel_foundation_test.jl | `ESS_STENCIL_DISABLE` | access_kernel_foundation_test.jl:239 |
| test/array_contraction_test.jl | `ESS_ARRAY_CONTRACTION_DISABLE`, `ESS_ARRAY_CONTRACTION_MIN`, `ESS_CONTRACTION_LOOP` | array_contraction_test.jl:105, :83, :128 |
| test/array_obs_materialize_test.jl | `ESS_ARRAY_OBS_INLINE`, `ESS_STENCIL_DISABLE` | array_obs_materialize_test.jl:20, :335 |
| test/cg_foreign_scratch_test.jl | `ESS_CG_FOREIGN_SCRATCH_DISABLE`, `ESS_CODEGEN_DISABLE` | cg_foreign_scratch_test.jl:87, :89 |
| test/codegen_body_split_test.jl | `ESS_CODEGEN_BODY_SPLIT_DISABLE`, `ESS_CODEGEN_FN_NODE_CAP` | codegen_body_split_test.jl:48, :47 |
| test/codegen_kernel_test.jl | `ESS_CODEGEN_DISABLE` | codegen_kernel_test.jl:25 |
| test/codegen_lanespec_test.jl | `ESS_CODEGEN_DISABLE`, `ESS_OOP_MERGE_DISABLE` | codegen_lanespec_test.jl:37, :38 |
| test/codegen_subcall_fn_test.jl | `ESS_CG_SUBCALL_FN`, `ESS_CG_SUBCALL_FN_MIN_NODES`, `ESS_NESTED_TEMPLATE_BOUNDARY`, `ESS_THREADS_MIN_CELLS` | codegen_subcall_fn_test.jl:100, :102, :101, :167 |
| test/codegen_threaded_test.jl | `ESS_CGT_CHILD`, `ESS_CG_THREADS_DISABLE`, `ESS_CODEGEN_DISABLE`, `ESS_CODEGEN_NODE_BUDGET`, `ESS_F64_OVERFLOW_CODEGEN`, `ESS_THREADS_DISABLE`, `ESS_THREADS_MIN_CELLS` | codegen_threaded_test.jl:123, :140, :118, :210, :212, :184, :176 |
| test/compile_once_templates_test.jl | `ESS_STENCIL_DISABLE`, `ESS_TEMPLATE_REF_DISABLE` | compile_once_templates_test.jl:63, :62 |
| test/contraction_loop_test.jl | `ESS_CONTRACTION_LOOP`, `ESS_CONTRACTION_LOOP_MIN` | contraction_loop_test.jl:72, :73 |
| test/contraction_tier_order_test.jl | `ESS_ARRAY_CONTRACTION_MIN`, `ESS_CONTRACTION_LOOP`, `ESS_CONTRACTION_LOOP_MIN`, `ESS_STENCIL_DISABLE` | contraction_tier_order_test.jl:101, :99, :100, :103 |
| test/cross_eq_class_emission_test.jl | `ESS_CODEGEN_DISABLE`, `ESS_CROSS_EQ_CLASS_EMIT_DISABLE`, `ESS_DIRECT_CLASS_EMIT_DISABLE`, `ESS_KERNEL_CLASS_MERGE_DISABLE`, `ESS_OOP_MERGE_DISABLE`, `ESS_STENCIL_DISABLE` | cross_eq_class_emission_test.jl:138, :135, :136, :137, :192, :139 |
| test/datetime_typed_core_test.jl | `ESS_CODEGEN_DISABLE`, `ESS_STENCIL_DISABLE` | datetime_typed_core_test.jl:240 |
| test/direct_class_emission_test.jl | `ESS_CODEGEN_DISABLE`, `ESS_DIRECT_CLASS_EMIT_DISABLE`, `ESS_KERNEL_CLASS_MERGE_DISABLE`, `ESS_OOP_MERGE_DISABLE`, `ESS_STENCIL_DISABLE` | direct_class_emission_test.jl:124, :122, :123, :172, :125 |
| test/dual_fast_path_test.jl | `ESS_CODEGEN_DISABLE`, `ESS_CODEGEN_NODE_BUDGET`, `ESS_DUAL_CODEGEN_DISABLE` | dual_fast_path_test.jl:92, :88, :90 |
| test/expand_memo_oracle_test.jl | `ESS_EXPAND_MEMO_DISABLE`, `ESS_STENCIL_DISABLE`, `ESS_TEMPLATE_REF_DISABLE` | expand_memo_oracle_test.jl:50, :67, :78 |
| test/expression_templates_test.jl | `ESS_TEMPLATE_REF_DISABLE` | expression_templates_test.jl:76 |
| test/f64_overflow_codegen_test.jl | `ESS_CODEGEN_DISABLE`, `ESS_CODEGEN_NODE_BUDGET`, `ESS_F64_OVERFLOW_CODEGEN` | f64_overflow_codegen_test.jl:91, :87, :89 |
| test/fn_content_cse_test.jl | `ESS_STENCIL_DISABLE` | fn_content_cse_test.jl:21 |
| test/geom_overlap_drive_test.jl | `ESS_GEOM_OVERLAP_GATE_DISABLE`, `ESS_GEOM_OVERLAP_GATE_VERIFY` | geom_overlap_drive_test.jl:120, :139 |
| test/geom_sweep_specialize_test.jl | `ESS_GEOM_SWEEP_SPECIALIZE_DISABLE`, `ESS_GEOM_SWEEP_VERIFY` | geom_sweep_specialize_test.jl:75, :309 |
| test/grid_invariance_test.jl | `ESS_CODEGEN_DISABLE` | grid_invariance_test.jl:78 |
| test/intern_oracle_test.jl | `ESS_INTERN_DISABLE`, `ESS_STENCIL_DISABLE` | intern_oracle_test.jl:48, :213 |
| test/join_on_equality_gate_test.jl | `ESS_JOIN_ON_GATE_DISABLE` | join_on_equality_gate_test.jl:74 |
| test/join_on_self_join_test.jl | `ESS_JOIN_ON_GATE_DISABLE` | join_on_self_join_test.jl:76 |
| test/lane_table_intern_test.jl | `ESS_CODEGEN_DISABLE`, `ESS_KERNEL_CLASS_MERGE_DISABLE`, `ESS_LANE_INTERN_DISABLE`, `ESS_STENCIL_DISABLE` | lane_table_intern_test.jl:43, :41, :40, :42 |
| test/oop_merge_test.jl | `ESS_CODEGEN_DISABLE`, `ESS_KERNEL_CLASS_MERGE_DISABLE`, `ESS_OOP_MERGE_DISABLE` | oop_merge_test.jl:155, :252, :29 |
| test/out_of_line_templates_test.jl | `ESS_TEMPLATE_REF_DISABLE` | out_of_line_templates_test.jl:387 |
| test/reactant_direct_emit_test.jl | `ESS_ARRAY_CONTRACTION_MIN`, `ESS_CONTRACTION_LOOP`, `ESS_CONTRACTION_LOOP_MIN`, `ESS_OOP_BATCH` | reactant_direct_emit_test.jl:411, :410, :410, :412 |
| test/reactant_lane_dedup_test.jl | `ESS_LANE_INTERN_DISABLE` | reactant_lane_dedup_test.jl:232 |
| test/reactant_locate_test.jl | `ESS_RX_LOCATE`, `ESS_RX_LOCATE_LADDER_MAX` | reactant_locate_test.jl:94, :169 |
| test/scalar_batch_test.jl | `ESS_ARRAY_CONTRACTION_MIN`, `ESS_CONTRACTION_LOOP`, `ESS_CONTRACTION_LOOP_MIN`, `ESS_OOP_BATCH` | scalar_batch_test.jl:41, :39, :40, :42 |
| test/scan_prefix_test.jl | `ESS_CODEGEN_DISABLE`, `ESS_STENCIL_DISABLE`, `ESS_UNTIERED` | scan_prefix_test.jl:71, :72 |
| test/scope_injection_test.jl | `ESS_TEMPLATE_REF_DISABLE` | scope_injection_test.jl:31 |
| test/setup_map_compile_once_test.jl | `ESS_SETUP_MAP_COMPILE_ONCE_DISABLE`, `ESS_SETUP_MAP_COMPILE_ONCE_VERIFY` | setup_map_compile_once_test.jl:52, :165 |
| test/simulate_run_test.jl | `ESS_TEMPLATE_REF_DISABLE` | simulate_run_test.jl:184 |
| test/stencil_affine_ad_test.jl | `ESS_STENCIL_DISABLE` | stencil_affine_ad_test.jl:23 |
| test/stencil_affine_const_fold_test.jl | `ESS_STENCIL_DISABLE` | stencil_affine_const_fold_test.jl:84 |
| test/stencil_affine_contract_test.jl | `ESS_STENCIL_DISABLE` | stencil_affine_contract_test.jl:19 |
| test/stencil_affine_cross_shape_test.jl | `ESS_CODEGEN_DISABLE`, `ESS_LANE_AFFINE_KEY_DISABLE`, `ESS_STATE_BOX_DISABLE`, `ESS_STENCIL_DISABLE` | stencil_affine_cross_shape_test.jl:72, :74, :75, :170 |
| test/stencil_affine_cse_test.jl | `ESS_STENCIL_DISABLE` | stencil_affine_cse_test.jl:18 |
| test/stencil_affine_diff_test.jl | `ESS_STENCIL_DISABLE` | stencil_affine_diff_test.jl:85 |
| test/stencil_affine_fn_test.jl | `ESS_STENCIL_DISABLE` | stencil_affine_fn_test.jl:19 |
| test/stencil_affine_invariant_test.jl | `ESS_STENCIL_DISABLE` | stencil_affine_invariant_test.jl:17 |
| test/stencil_affine_pgather_tbl_test.jl | `ESS_AK_TBL_DEBUG`, `ESS_LANE_AFFINE_KEY_DISABLE`, `ESS_OBSREF_DISABLE`, `ESS_STENCIL_DISABLE` | stencil_affine_pgather_tbl_test.jl:122, :38, :29 |
| test/stencil_affine_pgather_test.jl | `ESS_STENCIL_DISABLE` | stencil_affine_pgather_test.jl:23 |
| test/stencil_indexed_contraction_test.jl | `ESS_STENCIL_DISABLE` | stencil_indexed_contraction_test.jl:124 |
| test/stencil_subtree_tbl_test.jl | `ESS_CODEGEN_DISABLE`, `ESS_STENCIL_DISABLE`, `ESS_SUBTREE_TBL_DISABLE` | stencil_subtree_tbl_test.jl:92, :69 |
| test/template_imports_test.jl | `ESS_TEMPLATE_REF_DISABLE` | template_imports_test.jl:156 |
| test/toplevel_mount_edge_pipeline_test.jl | `ESS_TEMPLATE_REF_DISABLE` | toplevel_mount_edge_pipeline_test.jl:378 |
| test/tree_walk_allocation_test.jl | `ESS_THREADS_MIN_CELLS` | tree_walk_allocation_test.jl:219 |
| test/tree_walk_cse_test.jl | `ESS_TCADENCE_DISABLE`, `ESS_UNTIERED` | tree_walk_cse_test.jl:496, :1143 |
| test/tree_walk_iip_generic_test.jl | `ESS_STENCIL_DISABLE`, `ESS_UNTIERED` | tree_walk_iip_generic_test.jl:241, :147 |
| test/tree_walk_observed_slots_test.jl | `ESS_UNTIERED` | tree_walk_observed_slots_test.jl:299 |
| test/tree_walk_tcadence_test.jl | `ESS_TCADENCE_DISABLE`, `ESS_UNTIERED` | tree_walk_tcadence_test.jl:117, :304 |
| test/tree_walk_untiered_test.jl | `ESS_UNTIERED` | tree_walk_untiered_test.jl:48 |
| test/tree_walk_vectorized_test.jl | `ESS_STENCIL_DISABLE` | tree_walk_vectorized_test.jl:274 |
| test/tree_walk_xcse_test.jl | `ESS_CODEGEN_DISABLE`, `ESS_OOP_MERGE_DISABLE`, `ESS_STENCIL_DISABLE`, `ESS_XCSE_DISABLE` | tree_walk_xcse_test.jl:179, :73, :407, :72 |
| test/xeq_variant_oracle_test.jl | `ESS_STENCIL_DISABLE`, `ESS_XEQ_VARIANT_DISABLE` | xeq_variant_oracle_test.jl:139, :54 |

Distinct variables, by how many test files touch each:

```
ESS_STENCIL_DISABLE 28   ESS_CODEGEN_DISABLE 16   ESS_TEMPLATE_REF_DISABLE 8
ESS_UNTIERED 6           ESS_CONTRACTION_LOOP 5   ESS_OOP_MERGE_DISABLE 5
ESS_ARRAY_CONTRACTION_MIN 4   ESS_CONTRACTION_LOOP_MIN 4   ESS_KERNEL_CLASS_MERGE_DISABLE 4
ESS_CODEGEN_NODE_BUDGET 3     ESS_THREADS_MIN_CELLS 3
ESS_DIRECT_CLASS_EMIT_DISABLE 2   ESS_F64_OVERFLOW_CODEGEN 2   ESS_JOIN_ON_GATE_DISABLE 2
ESS_LANE_AFFINE_KEY_DISABLE 2     ESS_LANE_INTERN_DISABLE 2    ESS_OOP_BATCH 2
ESS_TCADENCE_DISABLE 2
and one file each: ESS_AK_TBL_DEBUG, ESS_ARRAY_CONTRACTION_DISABLE, ESS_ARRAY_OBS_INLINE,
ESS_CGT_CHILD, ESS_CG_FOREIGN_SCRATCH_DISABLE, ESS_CG_SUBCALL_FN,
ESS_CG_SUBCALL_FN_MIN_NODES, ESS_CG_THREADS_DISABLE, ESS_CODEGEN_BODY_SPLIT_DISABLE,
ESS_CODEGEN_FN_NODE_CAP, ESS_CROSS_EQ_CLASS_EMIT_DISABLE, ESS_DUAL_CODEGEN_DISABLE,
ESS_EXPAND_MEMO_DISABLE, ESS_GEOM_OVERLAP_GATE_DISABLE, ESS_GEOM_OVERLAP_GATE_VERIFY,
ESS_GEOM_SWEEP_SPECIALIZE_DISABLE, ESS_GEOM_SWEEP_VERIFY, ESS_INTERN_DISABLE,
ESS_NESTED_TEMPLATE_BOUNDARY, ESS_OBSREF_DISABLE, ESS_RX_LOCATE,
ESS_RX_LOCATE_LADDER_MAX, ESS_SETUP_MAP_COMPILE_ONCE_DISABLE,
ESS_SETUP_MAP_COMPILE_ONCE_VERIFY, ESS_STATE_BOX_DISABLE, ESS_SUBTREE_TBL_DISABLE,
ESS_THREADS_DISABLE, ESS_XCSE_DISABLE, ESS_XEQ_VARIANT_DISABLE
```

Two stale mentions worth a grep on retirement: `test/runtests.jl` names 17 variables in
include-line comments only, and `test/codegen_subcall_fn_test.jl:21` names
`ESS_CG_SUBCALL_FN_DISABLE` in prose while the code at :100 uses `ESS_CG_SUBCALL_FN`.


---

## 4. `ESS_*` environment reads in `src/` and `ext/` — the phase-2 retirement list

Every `get(ENV, "ESS_…")` read in `src/` and `ext/`, found by
`grep -rn 'ENV, "ESS_\|ENV\["ESS_' src/ ext/`. 67 read sites, 61 distinct variables.
Kinds: **oracle kill switch** (turns a tier off so the slower reference path runs — the
differential oracle a test compares against), **opt-in gate** (a tier that ships OFF and
only runs when the variable is set), **dual-run verify** (runs both paths and asserts they
agree), **debug logger** (prints or dumps, changes no result), **tuning threshold** (a
numeric budget / cap / minimum).

| file:line | variable | default | kind |
|---|---|---|---|
| src/intern.jl:61 | `ESS_INTERN_DISABLE` | off | oracle kill switch |
| src/lower_expression_templates.jl:1853 | `ESS_EXPAND_MEMO_DISABLE` | off | oracle kill switch |
| src/resolve.jl:591 | `ESS_TEMPLATE_REF_DISABLE` | off | oracle kill switch |
| src/tree_walk/acc_merge.jl:103 | `ESS_DIRECT_CLASS_EMIT_DISABLE` | off | oracle kill switch |
| src/tree_walk/acc_merge.jl:148 | `ESS_CROSS_EQ_CLASS_EMIT_DISABLE` | off | oracle kill switch |
| src/tree_walk/acc_merge.jl:423 | `ESS_LANE_INTERN_DISABLE` | off | oracle kill switch |
| src/tree_walk/acc_merge.jl:659 | `ESS_OOP_PROBE` | off | debug logger |
| src/tree_walk/access_kernel.jl:1030 | `ESS_THREADS_DISABLE` | off | oracle kill switch (threading) |
| src/tree_walk/access_kernel.jl:1058 | `ESS_THREADS_MIN_CELLS` | 512 | tuning threshold |
| src/tree_walk/build.jl:290 | `ESS_STENCIL_DEBUG` | off | debug logger |
| src/tree_walk/build.jl:382 | `ESS_ARRAY_OBS_INLINE` | off | oracle kill switch (forces the inlining variant) |
| src/tree_walk/build.jl:455 | `ESS_ARRAY_OBS_DEBUG` | off | debug logger |
| src/tree_walk/build.jl:459 | `ESS_ARRAY_OBS_DEBUG` | off | debug logger |
| src/tree_walk/build.jl:4220 | `ESS_STENCIL_DEBUG` | off | debug logger |
| src/tree_walk/build.jl:4289 | `ESS_STENCIL_DEBUG` | off | debug logger |
| src/tree_walk/build.jl:4303 | `ESS_STENCIL_DEBUG` | off | debug logger |
| src/tree_walk/build.jl:4321 | `ESS_STENCIL_DEBUG` | off | debug logger |
| src/tree_walk/codegen_kernel.jl:70 | `ESS_CODEGEN_DISABLE` | off | oracle kill switch |
| src/tree_walk/codegen_kernel.jl:71 | `ESS_CODEGEN_DEBUG` | off | debug logger |
| src/tree_walk/codegen_kernel.jl:83 | `ESS_CODEGEN_NODE_BUDGET` | 64 000 000 | tuning threshold |
| src/tree_walk/codegen_kernel.jl:117 | `ESS_DUAL_CODEGEN_DISABLE` | off | oracle kill switch |
| src/tree_walk/codegen_kernel.jl:119 | `ESS_DUAL_CODEGEN_NODE_BUDGET` | `typemax(Int)` | tuning threshold |
| src/tree_walk/codegen_kernel.jl:145 | `ESS_F64_OVERFLOW_CODEGEN` | **on** (`!= "0"`) | oracle kill switch (default-on) |
| src/tree_walk/codegen_kernel.jl:174 | `ESS_CG_FOREIGN_SCRATCH_DISABLE` | off | oracle kill switch |
| src/tree_walk/codegen_kernel.jl:256 | `ESS_CG_HELPER_DEDUP_DISABLE` | off | oracle kill switch |
| src/tree_walk/codegen_kernel.jl:269 | `ESS_CG_SUBCALL_FN_DISABLE` | off | oracle kill switch |
| src/tree_walk/codegen_kernel.jl:270 | `ESS_CG_SUBCALL_FN` | **off** (needs `"1"`) | opt-in gate — the sub-kernel function tier ships DISABLED |
| src/tree_walk/codegen_kernel.jl:276 | `ESS_CG_SUBCALL_FN_MIN_NODES` | 64 | tuning threshold |
| src/tree_walk/codegen_kernel.jl:926 | `ESS_CG_STRUCT_DUMP` | `""` (no dump) | debug logger (dump directory) |
| src/tree_walk/codegen_kernel.jl:1208 | `ESS_CODEGEN_FN_NODE_CAP` | 20 000 | tuning threshold |
| src/tree_walk/codegen_kernel.jl:1398 | `ESS_CODEGEN_BODY_SPLIT_DISABLE` | off | oracle kill switch |
| src/tree_walk/codegen_kernel.jl:1624 | `ESS_CG_THREADS_DISABLE` | off | oracle kill switch (threading) |
| src/tree_walk/const_tier.jl:145 | `ESS_TCADENCE_DISABLE` | off | oracle kill switch |
| src/tree_walk/const_tier.jl:165 | `ESS_UNTIERED` | off | oracle kill switch |
| src/tree_walk/geometry_setup.jl:554 | `ESS_GEOM_SWEEP_SPECIALIZE_DISABLE` | off | oracle kill switch |
| src/tree_walk/geometry_setup.jl:561 | `ESS_GEOM_SWEEP_VERIFY` | off | dual-run verify |
| src/tree_walk/geometry_setup.jl:724 | `ESS_GEOM_OVERLAP_GATE_DISABLE` | off | oracle kill switch |
| src/tree_walk/geometry_setup.jl:733 | `ESS_GEOM_OVERLAP_GATE_VERIFY` | off | dual-run verify |
| src/tree_walk/geometry_setup.jl:1232 | `ESS_SETUP_MAP_COMPILE_ONCE_DISABLE` | off | oracle kill switch |
| src/tree_walk/geometry_setup.jl:1241 | `ESS_SETUP_MAP_COMPILE_ONCE_VERIFY` | off | dual-run verify |
| src/tree_walk/oop.jl:93 | `ESS_OOP_BATCH` | **on** (`!= "0"`) | oracle kill switch (default-on) |
| src/tree_walk/oop.jl:365 | `ESS_OOP_PROBE` | off | debug logger |
| src/tree_walk/oop_merge.jl:73 | `ESS_OOP_MERGE_DISABLE` | off | oracle kill switch |
| src/tree_walk/oop_merge.jl:74 | `ESS_KERNEL_CLASS_MERGE_DISABLE` | off | oracle kill switch (second spelling of the same gate) |
| src/tree_walk/oop_merge.jl:638 | `ESS_OOP_MERGE_EXPAND_DISABLE` | off | oracle kill switch |
| src/tree_walk/resolve.jl:527 | `ESS_CONTRACTION_LOOP` | **on** (`!= "0"`) | oracle kill switch (default-on) |
| src/tree_walk/resolve.jl:529 | `ESS_CONTRACTION_LOOP_MIN` | 8 | tuning threshold |
| src/tree_walk/resolve.jl:596 | `ESS_ARRAY_CONTRACTION_DISABLE` | off | oracle kill switch |
| src/tree_walk/resolve.jl:598 | `ESS_ARRAY_CONTRACTION_MIN` | 1024 | tuning threshold |
| src/tree_walk/semiring.jl:370 | `ESS_JOIN_ON_GATE_DISABLE` | off | oracle kill switch |
| src/tree_walk/stencil.jl:77 | `ESS_STENCIL_DISABLE` | off | oracle kill switch (forces the per-cell reference RHS) |
| src/tree_walk/stencil.jl:154 | `ESS_XEQ_VARIANT_DISABLE` | off | oracle kill switch |
| src/tree_walk/stencil.jl:253 | `ESS_NESTED_TEMPLATE_BOUNDARY_DISABLE` | off | oracle kill switch |
| src/tree_walk/stencil.jl:254 | `ESS_NESTED_TEMPLATE_BOUNDARY` | **off** (needs `"1"`) | opt-in gate — the nested-template boundary ships DISABLED |
| src/tree_walk/stencil.jl:256 | `ESS_NESTED_TEMPLATE_BOUNDARY_MIN_NODES` | 256 | tuning threshold |
| src/tree_walk/stencil.jl:462 | `ESS_SUBTREE_TBL_DISABLE` | off | oracle kill switch |
| src/tree_walk/stencil.jl:563 | `ESS_STENCIL_DEBUG` | off | debug logger |
| src/tree_walk/stencil.jl:1218 | `ESS_PGATHER_OOB_DEBUG` | off | debug logger |
| src/tree_walk/stencil_affine.jl:241 | `ESS_LANE_AFFINE_KEY_DISABLE` | off | oracle kill switch |
| src/tree_walk/stencil_affine.jl:768 | `ESS_AK_TBL_DEBUG` | off | debug logger |
| src/tree_walk/stencil_affine.jl:828 | `ESS_STATE_BOX_DISABLE` | off | oracle kill switch |
| src/tree_walk/stencil_affine.jl:897 | `ESS_OBSREF_DISABLE` | off | oracle kill switch |
| src/tree_walk/stencil_affine.jl:1371 | `ESS_STENCIL_DEBUG` | off | debug logger |
| src/tree_walk/stencil_affine.jl:1420 | `ESS_STENCIL_DEBUG` | off | debug logger |
| src/tree_walk/xcse.jl:98 | `ESS_XCSE_DISABLE` | off | oracle kill switch |
| ext/reactant_interp.jl:279 | `ESS_RX_LOCATE` | `"auto"` | tuning threshold (mode selector) |
| ext/reactant_interp.jl:280 | `ESS_RX_LOCATE_LADDER_MAX` | 8 | tuning threshold |

Counts by kind, over the 67 read sites: oracle kill switch 38, debug logger 13,
tuning threshold 11, dual-run verify 3, opt-in gate 2.

Three observations for phase 2.

* **Two tiers ship off.** `ESS_CG_SUBCALL_FN` (codegen_kernel.jl:270) and
  `ESS_NESTED_TEMPLATE_BOUNDARY` (stencil.jl:254) both require the variable to be exactly
  `"1"`; their `_DISABLE` partners are therefore dead in the default configuration. Any
  test that exercises those tiers exercises a code path no production build takes.
* **`ESS_KERNEL_CLASS_MERGE_DISABLE` and `ESS_OOP_MERGE_DISABLE` are the same gate**
  (oop_merge.jl:73-74, `||`), so retiring one without the other changes nothing.
* **`ESS_CGT_CHILD` is read only in the test suite** (`codegen_threaded_test.jl:123`, a
  marker the parent sets on a re-launched child process). It is not in `src/` or `ext/`
  and does not belong on the library retirement list, but it does have to survive
  whatever replaces the threaded-codegen test.

