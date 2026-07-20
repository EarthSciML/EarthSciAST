# Pre-audit for AST hash-consing (perf plan A1) — identity-keyed sites, 2026-07-19

Scope: every `IdDict` / `objectid` use in `pkg/EarthSciAST.jl/src` (+ `ext`),
classified for safety under structural interning of the expression AST.
Interning maps every `OpExpr` to a canonical object per structure, so after the
intern pass **object identity (`===` / `objectid`) of an interned node IS
structural equality** within one build. The classification question for each
site is therefore: does the site key a value that is a pure function of node
STRUCTURE (plus build-constant context) — in which case merging structurally
identical nodes only turns memo misses into hits — or does it key a value that
depends on the node's USE SITE (its position in the tree / which occurrence it
is), in which case merging changes behavior?

Leaves (`NumExpr`/`IntExpr`/`VarExpr`) are immutable structs whose fields are
bits/`String`, so Julia's egal (`===`, and hence `IdDict`/`objectid`) is
ALREADY content-based for them — interning only concerns `OpExpr` (mutable,
pointer identity; see the types.jl field-table comment).

Classification legend:
- **(a) structural memo** — value is a pure function of node structure and
  build-constant context. Safe under interning; merging = more hits.
- **(a*) visited-set / dedup** — pure existence/collection walk; merging only
  removes duplicate work (monotone collectors, identical results).
- **(b→a) use-site key, value-safe under merge** — identity today
  distinguishes occurrences, but every consumer's behavior on merge is
  value-identical by that consumer's own documented contract (details below).
  Requires only that the key table be TRANSLATED through the intern map.
- **(n/a)** — not keyed on `ASTExpr` at all (raw JSON nodes, `_Node` IR,
  runtime buffers); interning does not touch these keys.

## The three named suspects

| site | class | analysis |
|---|---|---|
| `_TemplateCtx.sites :: IdDict{OpExpr,OpExpr}` (tree_walk/stencil.jl:121; recorded lower_expression_templates.jl:1810; translated build_helpers.jl:42-68, stencil_affine.jl:828-838) | **(b→a)** | Keys are template expansion roots; the VALUE (the originating apply node) is documentary only — the only consumers are `haskey` boundary checks (stencil.jl:264, 452) and a debug counter (stencil_affine.jl:856). Merging two structurally identical roots collapses them to one key: the boundary check still fires at each occurrence during traversal. A structurally-identical NON-root merging with a root additionally becomes a compile-once boundary; that is value-safe by the tier's own contract ("grouping is identical by construction", stencil.jl:291-299) and is guarded by the intern differential oracle. Required fix: after interning, re-key each entry via the intern map (`sites[intern(root)] = ap`), else every entry silently misses and the tier degrades to the fused build (perf loss, not wrongness). Done in `_build_evaluator_impl`. |
| `vkey = (objectid(node), bodykey)` → `_TemplateCtx.variants` (stencil.jl:311) | **(b→a)** | Compiled-variant memo per (root identity, region-class branch key). The variant is a pure function of (node structure, bodykey, per-equation compile context): `_branch_key!` already carries ALL `idx_env` dependence — that is what lets the SAME root object share one variant across branches today. After interning, `objectid(node)` is structural, so structurally identical roots within one equation share a variant; by the same purity argument the shared variant is bit-identical to the per-site ones it replaces (lane recipes are appended per occurrence at each occurrence's own base — stencil.jl:338-341 — so per-use bookkeeping is unchanged). `_TemplateCtx` is per-equation, so no cross-equation merge is possible. `_BENCH_BODY_VARIANTS` drops accordingly (that is the intended sharing). |
| `_TemplateCtx.bound_bodies :: IdDict{OpExpr,Vector{Tuple{Vector{ASTExpr},ASTExpr}}}` (stencil.jl:136, 350-365) | **(b→a)** | Bound-body cache per (producer identity, k-arg identity tuple). The bound body is `_sub_preserving(body, oi=>kargs)` — a pure function of producer structure + karg structures. Interning makes the `ka[i] === kargs[i]` probe hit for structurally equal kargs; the shared bound body is the identical substitution result. Merging structurally identical producers likewise yields the identical bound body. |

Conclusion for the suspects: after interning, identity IS the structure these
memos are morally keyed on, so no explicit site-id re-keying is required; the
required change is the sites-table translation plus the bit-exact oracle
(intern vs `ESS_INTERN_DISABLE=1`) that pins the value-safety arguments above.

## Exhaustive sweep — remaining sites

### tree_walk build path

| site | class | note |
|---|---|---|
| `_SubMemo = IdDict{OpExpr,ASTExpr}`, `_sub_preserving` (tree_walk/helpers.jl:41-130) | (a) | substitution memo, fresh per call; bindings fixed within a call. Unchanged nodes map to themselves (`memo[expr]=expr`, original `args` vector returned), so sharing survives the rewrite for untouched subtrees. |
| `_ObsSeen = IdDict{OpExpr,UInt8}` two-mode scan (helpers.jl:199-292) | (a*) | (node, mode)-keyed monotone set-collector; mode bit handles the one position-dependent distinction (structural vs expression position). Already DAG-safe today. |
| `_count_obs_refs!` `total`/`uncond :: IdDict{OpExpr,Int}` (helpers.jl:352-353) | (a) | PATH-multiplicity propagation over the unique-node DAG. Path counts are invariant under tree→DAG merging (paths through two identical copies = paths through the merged node), so tallies are byte-identical. |
| `_BuildMemo.resolve/compile :: IdDict{OpExpr,…}` (tree_walk/compile.jl:115-119) | (a) | resolve/compile are pure functions of the node given fixed per-equation context (documented at the struct). Interning turns cross-copy misses into hits — the A1 payoff. |
| `_PGatherKeyCtx.memo` (compile.jl:614-618) | (a) | identity-preserving rewrite memo. |
| `_CSEKeyMemos.canon/key` (compile.jl:725-729), `_canonicalize_memo` (737) | (a) | canonicalization/CSE-key are pure structural functions; errors memoized and replayed. |
| `_cse_count!` `seen`/`total`/`uncond` (compile.jl:827-861) | (a) | same path-multiplicity invariance as `_count_obs_refs!`; CSE keys are canonical-JSON (structural) already, so counts per key are unchanged. |
| `_CSEContext.compiled :: IdDict{OpExpr,_Node}` (compile.jl:1043, 1165) | (a) | per-batch compile memo, pure per context. |
| `_StencilCtx.smemo :: IdDict{OpExpr,ASTExpr}` (stencil.jl:207) | (b→a) | `_stencilize` dedup: a merged node's second occurrence reuses the first occurrence's sentinel + lanes instead of pushing duplicate recipes. Explicitly documented value-safe ("only removes duplicate work, never changes a value", stencil.jl:247-251) — the lane values are recipe-evaluated identically; arithmetic order in the spine is unchanged. This is exactly the sharing mechanism interning is meant to feed. |
| `_StencilCtx.vsmemo`, `gmemo`, `_refs_idxset`/`_child_refs_idxset` memos (stencil.jl:123, 212, 470-580) | (a) | pure predicate "references a loop index in idxset", idxset fixed per query. |
| `_branch_key!` `seen :: IdDict{OpExpr,Nothing}` (stencil.jl:547-580) | (a*) | key-emission walk dedup (checked: dedup is on the guard memo walk, key bytes derive from structure + idx_env). |
| `_translate_sites_lockstep!` `seen` (build_helpers.jl:42-68) | (a*) | lockstep dedup on the old node; merged keys degrade at worst to "site not found → fused build" (documented fail-safe). |
| tree_walk/resolve.jl:92-183 (`_has_index_set_ref` seen; resolve memo) | (a)/(a*) | pure predicate / rewrite memo. |
| stencil_affine.jl:76-89 `IdDict{_Node,_Node}` (ESS-0hh lowering memo) | (n/a)+(a) | `_Node`-keyed; lowering is pure per (lane_repl, acc); benefits indirectly from shared `_Node` spines. |
| stencil_affine.jl:152-162 `seen::IdDict{Any,Bool}` subkernel collect | (a*) | dedup collector. |
| `_AffineSig.bmemo :: IdDict{OpExpr,Bool}` (stencil_affine.jl:196) | (a) | pure affine-classification predicate memo. |
| stencil_affine.jl:403 `seen` | (a*) | walk dedup. |
| `_desc_key` `objectid(d.arr)/objectid(d.conn)/objectid(d)` (stencil_affine.jl:572-575) | (n/a) | keys RUNTIME BUFFER identity (which array a kernel reads) — semantic and deliberate; interning of expressions never touches buffer objects. The `(0xff, objectid(d))` arm is the "never merge" fail-safe: a node object now reachable twice merges only with itself. |
| stencil_affine.jl:876 `flat_cache :: IdDict{Any,Vector{Float64}}` | (n/a) | keyed on const-array objects (flattening cache). |
| acc_merge.jl:76 `objectid(n.payload)`; :144 `_fn_spec_hash(s)=objectid(s)` fallback | (n/a) | buffer identity in merge signature (deliberate, documented); the objectid fallback is the fail-safe for unknown spec types (over-split, never under-split). |
| access_kernel.jl:717 `seen`, :773 `pos_of::IdDict{_Node,Int}` | (n/a)/(a*) | `_Node`-level walk/postorder numbering. |
| access_kernel.jl:738-740 `(…objectid(n.payload)…)`, `(0xff, objectid(n))` | (n/a) | buffer identity + never-merge fail-safe (self-merge only). |
| access_kernel.jl:1021 `(kind, idx, sym, objectid(arr), objectid(scratch))` | (n/a) | runtime buffer identity. |
| geometry_setup.jl:41-42, 149-150 `seen` sets | (a*) | existence predicates. |
| semiring.jl:333-334 `_expr_has_join` seen | (a*) | existence predicate. |
| build.jl / build_helpers.jl `template_sites` unions | — | plumbing for the sites table (see suspects). |

### front-end / shared passes (run before the intern point; audited for completeness)

| site | class | note |
|---|---|---|
| parse.jl:111-127, resolve.jl:325-326 task-local parse memo `IdDict{Any,ASTExpr}` | (n/a) | keyed on RAW JSON node identity; the existing source of parse-time sharing. |
| json_walk.jl:64-66 `_to_ordered` memo | (n/a) | raw JSON. |
| flatten.jl:298-306 `_collect_spatial_dims!` seen | (a*) | collector. |
| namespacing.jl:58-96 memo | (a) | rewrite memo, prefix fixed per call. |
| shape_promotion.jl:103-107 memo | (a) | rewrite memo. |
| registered_functions.jl:811-831 `_lower_expr_enums` memo | (a) | rewrite memo. |
| pointwise_lift.jl:67 `peek :: IdDict{OpExpr,Any}` | (a) | analysis-only template-body expansion memo (pure fn of apply node + registry). |
| cadence.jl:205-231 `ClassMemo = IdDict{Any,String}` | (n/a)/(a) | keys raw JSON dict nodes; class is a pure structural derivation. |
| lower_expression_templates.jl memos/seen (309-1533) | (a)/(a*) | raw-JSON rewrite memos and dedup walks; sites recording at :1810 is the suspects-table entry. |
| expression.jl:184-202 `foreach_subexpr_once`, :462-466 `_free_variables_dag` | (a*)/(a) | dedup walk / pure structural set. |
| ext/EarthSciASTDataRefreshExt.jl:35 `IdDict{Any,Int}` | (n/a) | data-provider identity. |

### Mutation audit (precondition for interning at the build entry)

`OpExpr` is mutable ONLY for pointer identity; a sweep for field assignment
(`node.field = …`, `setfield!`, container mutation `push!/append!/empty!/
sort!/…` on node-owned `args`/`values`/`ranges`/`table_axes`/`bindings`)
across src/ and ext/ found **no post-construction mutation of any expression
node** — all rewrites go through `reconstruct` on fresh vectors/dicts
(`_sub_arg_vec` copies before writing; `_sub_ranges` builds a fresh Dict;
canonicalize.jl:199 reads `a.args` into a fresh `out`). edit.jl / canonicalize.jl /
template_imports.jl mutate MODEL-level collections (variables/equations
dicts/vectors), never expression nodes. Interning after
`_expand_model_refs!` at the `_build_evaluator_impl` entry is therefore safe:
no later pass mutates a (now shared) node in place.

### Required changes before/with interning

1. Translate `_template_sites` through the intern map at the intern point
   (b→a suspects above): `sites[intern(root)] = apply_node`.
2. Everything else: no re-keying required; the (b→a) merges are value-safe by
   the contracts cited above and are pinned by the intern differential oracle
   (`ESS_INTERN_DISABLE=1` vs default must produce bit-identical `du` and
   identical state maps on the gridded fixtures).
