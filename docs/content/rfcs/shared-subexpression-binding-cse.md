# RFC — Shared-subexpression binding (`let`) and canonical common-subexpression elimination for lowered ASTs

**Status:** Draft (proposed changeset for review)
**Bead:** TBD (file on acceptance; the beads DB is offline at authoring time)
**Affects spec version:** 0.8.0 (rides *inside* the in-progress clean break; no bump, no compat shims)
**Scope:** `esm-spec.md` §4 (new `let`/`var` expression nodes), §5.5.3 + `CONFORMANCE_SPEC.md` §5.5.3.1 (canonical emit — the normative CSE pass and its determinism), §9.6.4 (post-lowering gate accepts `let`/`var`), §9.6.6 (diagnostics); `esm-schema.json` (`$defs/LetExpression` + `$defs/VarRef`, + the four binding-mirror schemas + the TypeScript embedded schema); conformance fixtures; Julia reference implementation. **Binding ports (Python, Rust, TypeScript, Go) are explicitly a later wave** (§10); this RFC lands spec + schema + Julia + fixtures only. Library *content* changes (e.g. EarthSciDiscretizations regenerating its WENO / HJ-WENO goldens under CSE) are out of scope — they live in `../earthscidiscretizations`.
**Depends on:** the ast-expression-templates RFC (§9.7.3 composition/inlining) and the open-op-namespace-fixpoint-rewrite RFC (§9.6.3 lowering fixpoint). CSE runs strictly *after* lowering, on the fully-expanded tree, and *before* canonical emit; it does not touch the fixpoint, template composition, or §9.7.6 folding.

---

## 1. Motivation

The lowering pipeline **fully inlines** templates: the §9.6.4 post-lowering gate requires zero
`apply_expression_template` nodes and zero unlowered rewrite-target ops (`D`/`grad`/`div`/`laplacian`),
so a lowered rewrite result is a single, fully-expanded **tree** with no sharing. For linear
finite-difference stencils this is fine (a lowered central-difference Laplacian is a few KB). For
**nonlinear high-order** schemes it is catastrophically redundant, because the same nonlinear
sub-quantities are recomputed structurally many times over.

Concrete, measured (the EarthSciDiscretizations standard library, WENO-Z reconstructions):

| Lowered golden | Bytes | Node instances | Distinct nodes | Redundancy |
|---|---|---|---|---|
| `weno5_D_periodic` (5th-order WENO advection) | 2,415,374 | 10,615 | 1,000 | **90.6 %** |
| `hjweno_norm_D1_periodic` (Jiang–Peng HJ-WENO `\|∇u\|`) | 6,374,791 | 23,413 | 1,701 | **92.7 %** |

The redundancy is intrinsic to the scheme, not the authoring: WENO-Z's smoothness indicators
`β_k` (each a sum of squares of divided differences), `τ₅ = |β₀ − β₂|`, and the three nonlinear
weights are each recomputed once per candidate stencil, and the whole reconstruction is
recomputed once per `makearray` region (interior aggregate + five periodic-wrap faces) and, for
HJ-WENO, once per one-sided derivative `u_x^±`. A single WENO-Z reconstruction subtree appears on
the order of a dozen times.

Consequences:

1. **Committed goldens bloat the repository permanently.** Conformance goldens are checked in
   (`CONFORMANCE_SPEC.md`); git history cannot be slimmed without a force-rewrite. Two schemes
   already carry ~8.5 MB of golden. Every future high-order/nonlinear scheme — WENO7/9, higher-order
   PPM, spectral, flux-limited systems, ENO — compounds this.
2. **The cross-binding byte-compare processes multi-MB trees** in all five bindings on every CI run.
3. **Source-level factoring does not help the golden.** Factoring an author file into helper
   templates (the PPM idiom, `apply_expression_template` from a rule into a pointwise helper) shrinks
   the *source* `.esm` ~95 %, but the helper inlines at lowering, so the golden is unchanged. The
   golden size is intrinsic to a fully-inlined tree.

The missing primitive is a way to **represent a shared subexpression in the lowered AST**, plus a
**canonical, deterministic** common-subexpression-elimination pass that produces byte-identical
output across bindings (the entire conformance model rests on byte-identical canonical emit,
`CONFORMANCE_SPEC.md` §5.5.3). CSE is exactly the transformation the measured 90–93 % redundancy
invites; the only thing missing is somewhere to put the shared result.

## 2. Summary of changes

| # | Change | Where |
|---|--------|-------|
| A | **`let` expression node** — `{ "op": "let", "bindings": [ { "name": "$cse_0", "value": <expr> }, … ], "body": <expr> }` — binds subexpressions to hygienic local names, each referenced by a **`var` node** `{ "op": "var", "name": "$cse_0" }`. A pure value binding: evaluated once, referenced N times. | schema + §4 |
| B | **Normative canonical CSE pass.** After §9.6.3 lowering and before §5.5.3 canonical emit, a **deterministic** pass hoists common subexpressions into `let` bindings. Fully specified (canonical hash, traversal order, hoist threshold, name scheme, binding order, index-scope constraint) so all five bindings emit **byte-identical** CSE'd goldens. | `CONFORMANCE_SPEC.md` §5.5.3 + new §5.5.4 |
| C | **§9.6.4 gate accepts `let`/`var`.** They are neither unlowered rewrite-target ops nor `apply_expression_template`; they are value bindings and are the *expected* residue of canonical emit for redundant trees. | §9.6.4 |
| D | **Evaluation & hygiene.** `let` bindings are evaluated once (memoized) in declaration order; `var` resolves to the nearest enclosing binding; bound names live in a **reserved `$`-prefixed namespace** and may not shadow model variables, index names, or template parameters. | §4 + tree-walk |
| E | **Three new stable diagnostics** (§9.6.6). | §9.6.6 |

**Explicitly NOT done:** CSE as an author-facing optimization (authors never *write* `let` — it is
emitter-only, though the node is legal to hand-author and round-trips); a general DAG/node-id
serialization (rejected, §8.1); any change to the §9.6.3 fixpoint, §9.7.3 composition, or §9.7.6
folding; the orthogonal "declarable-periodic index set" that would remove the `makearray`-region
multiplier (a separate RFC — §8.4).

## 3. Design

### 3.1 The `let` and `var` nodes (§4)

```jsonc
{ "op": "let",
  "bindings": [ { "name": "$cse_0", "value": <expr> },
                { "name": "$cse_1", "value": <expr referencing $cse_0> } ],
  "body": <expr referencing $cse_0, $cse_1> }
```

- **`var`** — `{ "op": "var", "name": "$cse_k" }` — resolves to the value of the nearest enclosing
  binding named `$cse_k`. A `var` that resolves to no in-scope binding is a hard error (§6, `cse_unbound_var`).
- **Hygiene.** Binding names are drawn from a reserved namespace: the leading `$` is not a legal
  first character for author-declared model variables, index sets, or template parameters (identifier
  grammar §4.x), so `$cse_k` cannot collide with any author name. A `let` binding whose name is not
  `$`-prefixed, or that shadows another in-scope `$`-binding, is a `let_binding_name_collision` error.
- **Purity / single evaluation.** Each binding `value` is evaluated **once**, in declaration order,
  and its result reused for every `var` reference. Because the AST is side-effect-free (esm-spec §1),
  single-evaluation is *observationally* identical to inlining — CSE is a pure size/representation
  optimization with no numeric effect. Bindings may reference earlier bindings (declaration order is
  a topological order); a binding referencing a later or its own name is a `let_binding_cycle` error.
- **Scope.** A `let` introduces its bindings only within its own `body`. `let` may nest and may
  appear anywhere an expression may appear (including a `makearray` `value`, an `aggregate` `expr`,
  or another binding's `value`).

### 3.2 The canonical CSE pass (normative — new §5.5.4)

CSE runs as a fixed stage of **canonical emit**, on the fully-lowered tree, *after* the §9.6.3
fixpoint and *before* number-canonicalization/serialization (§5.5.3.1). It is a **pure function of
the lowered tree**; this is the load-bearing requirement — every binding must implement the identical
algorithm so the emitted bytes match.

> **Placement lesson (carried from `template-import-renaming` §4 and the integer-narrowing fix):**
> the canonical pipeline has *two* entry points — the load/save path (`parse_expression`) and the
> template-import golden writer (the machinery path that bypasses `parse_expression`). The CSE pass
> MUST run on both, or the golden writer emits an un-CSE'd tree while round-trip emits a CSE'd one.

The pass, precisely:

1. **Canonical hashing (structural identity).** Assign every subexpression a canonical hash computed
   bottom-up over its *number-canonicalized* form (§5.5.3.1 rules applied first, so `2` and `2.0`
   hash equal and bindings do not diverge on integral-float representation). Two subexpressions are
   "the same" iff their canonical hashes are equal. Commutativity is **not** normalized (the hash is
   over the AST as written post-lowering; `a+b` and `b+a` are distinct) — this keeps the pass a
   simple structural fold and avoids a normalization can-of-worms; the lowering machinery already
   emits operands in a fixed order.
2. **Index-scope constraint (correctness).** A subexpression that references a bound index variable
   (an `aggregate` `output_idx`/range index in scope) may only be hoisted to a `let` **inside** that
   index's binder — hoisting it above would leave the index unbound. Formally: a subexpression's
   *hoist ceiling* is the innermost enclosing binder of any free index it references (or the tree
   root if it references none). CSE hoists each shared subexpression to a `let` at its hoist ceiling.
   In practice this is the key split: the periodic-wrap **face** values are literal-indexed (no free
   index) → hoisted to a single `let` at the `makearray` root, capturing the ~6× cross-region sharing;
   the **interior aggregate** body's shared subexpressions reference `i` → hoisted to a `let` just
   inside the aggregate, capturing within-body sharing.
3. **Hoist threshold.** Hoist a subexpression iff it occurs **≥ `CSE_MULTIPLICITY_MIN` = 2** times
   within a common hoist ceiling **and** its node count is **≥ `CSE_SIZE_MIN` = 3**. The size floor
   prevents hoisting trivial leaves and unary wrappers (`dx`, `2`, `index(u,i)`), for which a `var`
   reference costs as much as the inlined node. Both constants are **normative** (identical across
   bindings); §11 discusses tuning.
4. **Binding order and names.** Within each hoist ceiling, collect the hoistable subexpressions and
   order them by **(a)** dependency (a subexpression used inside another's value precedes it —
   topological), then **(b)** first-occurrence in a fixed **pre-order** left-to-right traversal of the
   ceiling body, as the deterministic tie-break. Assign names `$cse_0, $cse_1, …` in that order,
   **restarting the counter at each hoist ceiling** but disambiguated by scope (inner ceilings nest,
   so `$cse_0` of an inner aggregate shadows nothing because scopes do not overlap — or, to keep names
   globally unique for easier reading, number monotonically across the whole tree in the traversal
   order; the reference implementation SHALL choose one and the fixtures pin it).
5. **Rewrite.** Replace each hoisted occurrence with `{op:var,name}` and wrap the ceiling body in the
   `let`. Emit.

Because steps 1–5 are a deterministic function of the lowered tree, the byte output is identical on
every binding that implements them.

### 3.3 Interaction with `makearray` regions and aggregates

WENO redundancy is **both** within a region (`β_0` twice per flux) **and** across regions (all six
regions share the reconstruction). The pass captures both because it runs on the whole lowered
rewrite result (the `makearray` and everything under it):

- Cross-region sharing (the ~6× multiplier) lands in a **top-level `let` wrapping the `makearray`**,
  binding the literal-indexed reconstruction pieces the faces share.
- Within-aggregate sharing lands in a **`let` inside the aggregate `expr`**, bound to `i` (the
  interior stencil's index), because those pieces reference `i` and cannot escape the binder (§3.2.2).

### 3.4 Round-trip and evaluation

A `let`-bearing document round-trips (load → save) byte-stably (CSE is idempotent: a second pass finds
nothing new above threshold). Evaluation: tree-walk maintains a binding environment; on entering a
`let` it evaluates each `value` once (in order) into the environment; `var` looks up the environment;
on leaving, the bindings pop. Every binding language has a native lowering (Julia `let`/`Ref` memo,
Python locals, Rust `let`, TypeScript `const`, Go local `var`).

## 4. Determinism

The whole RFC rests on the CSE pass being a **pure, total function of the lowered AST** whose output
is **byte-identical across bindings** after §5.5.3.1 number canonicalization. The normative surface
that must be spec-pinned (not left to implementations):

- the canonical **hash** domain (number-canonicalized AST; no commutativity normalization);
- the **hoist-ceiling** rule (innermost binder of any referenced free index);
- the threshold constants **`CSE_MULTIPLICITY_MIN = 2`, `CSE_SIZE_MIN = 3`**;
- the **ordering** (topological, then fixed pre-order first-occurrence) and the **name scheme**;
- that the pass runs in **both** canonical-emit entry points (load/save and the template-import golden
  writer).

A dedicated conformance fixture (§7) pins a CSE'd golden byte-for-byte and asserts all five bindings
reproduce it, exactly as the number-format and renaming RFCs are gated.

## 5. Worked example (illustrative slice)

A single WENO-Z weight reuses `β_0` (a 9-node sum-of-squares of divided differences) in both `α_0`
and, via `τ₅ = |β₀ − β₂|`, every `α_k`. Inlined (today):

```jsonc
// α_0 and α_1 each re-inline the full β_0 subtree (…9 nodes…), twice, per flux, per region
{ "op": "/", "args": [ 0.1, { "op": "^", "args": [ { "op": "+", "args": [ 1e-6, <β_0: 9 nodes> ] }, 2 ] } ] }
// …<β_0: 9 nodes> reappears verbatim in τ₅ and in α_2's normalization…
```

After CSE (proposed):

```jsonc
{ "op": "let",
  "bindings": [ { "name": "$cse_0", "value": <β_0: 9 nodes> },
                { "name": "$cse_1", "value": <β_2: 9 nodes> },
                { "name": "$cse_2", "value": { "op": "abs", "args": [ { "op": "-",
                              "args": [ {"op":"var","name":"$cse_0"}, {"op":"var","name":"$cse_1"} ] } ] } } ],
  "body": /* the reconstruction, now referencing $cse_0…$cse_2 in place of the repeated subtrees */ }
```

Projected golden sizes from the measured distinct-node fractions: **`weno5_D_periodic` ≈ 2.4 MB →
~0.24 MB; `hjweno_norm_D1_periodic` ≈ 6.1 MB → ~0.47 MB** (≈ 10×). The reduction scales with a
scheme's redundancy, so it grows with scheme order/nonlinearity — exactly the cases that hurt today.

## 6. Diagnostics (into the §9.6.6 table)

| Code | When |
|---|---|
| `cse_unbound_var` | a `var` node resolves to no in-scope `let` binding (malformed hand-authored/round-tripped doc). |
| `let_binding_name_collision` | a binding name is not `$`-prefixed, or shadows another in-scope binding of the same name. |
| `let_binding_cycle` | a binding references its own name or a later sibling (violates declaration-order topological requirement). |

All three are load/validate-time, gated like the rest of the clean break.

## 7. Conformance fixtures (proposed)

1. **Hand-authored `let` round-trip + eval** — a small doc using `let`/`var` explicitly; asserts
   round-trip byte-stability and that evaluation equals the inlined equivalent (numeric identity).
2. **CSE golden** — a deliberately redundant lowered scheme whose **CSE'd** canonical golden is pinned
   byte-for-byte (the primary artifact all bindings must reproduce). A WENO-Z reconstruction is the
   natural candidate; a small synthetic redundant stencil keeps the fixture legible.
3. **Determinism / cross-binding** — the same source lowered and CSE'd by all five bindings must emit
   byte-identical goldens (the §4 guarantee).
4. **Threshold boundary** — a subexpression at exactly `CSE_SIZE_MIN`/multiplicity 2 (hoisted) vs one
   just under (not hoisted), pinning the normative constants.
5. **Index-scope** — a shared subexpression referencing an `aggregate` index is hoisted *inside* the
   aggregate, never above it (the §3.2.2 correctness constraint).

## 8. Alternatives considered

### 8.1 DAG serialization (node ids + `$ref`) — rejected
Represent the lowered AST as a DAG with structural sharing by node id. More invasive to the JSON tree
model, harder to keep hygienic and human-readable, and it forces every consumer (not just evaluators)
to resolve references. A `let` node subsumes the same sharing with local, legible scoping and a native
lowering in every binding language.

### 8.2 Author-facing CSE / hand-written `let` as the primary path — rejected as *primary*
CSE is an emitter concern; requiring authors to write `let` fights "the AST is math" (§1.1) and would
entangle the §9.6.3 fixpoint with binding forms. The node is nonetheless legal to hand-author (it
round-trips and evaluates), so a future optimizing author or tool may emit it directly.

### 8.3 Leave goldens fully inlined (status quo) — rejected
The bloat is not a one-off; it compounds with every high-order/nonlinear scheme and is permanent in
git history.

### 8.4 Declarable-periodic index set (remove the region multiplier) — complementary, separate RFC
A large part of WENO's size is the ~6× `makearray`-region multiplier (interior + five periodic-wrap
faces materialized as single-cell regions, per `CONFORMANCE_SPEC.md` §5.9.3). A declarable-periodic
interval index set with a state-variable periodic gather that lowers to a *single* compact aggregate
would remove that multiplier (~6×). It is **orthogonal and complementary** to CSE (which removes the
~10× within-tree redundancy); together they compound. It belongs in its own RFC — CSE is the more
general lever (it helps *any* redundant tree, periodic or not) and is proposed first.

### 8.5 Source-only factoring (helper templates) — orthogonal, already applied downstream
Factoring an author rule into pointwise helper templates shrinks the source `.esm` ~95 % but not the
golden (helpers inline). It improves authoring/readability and is already applied in ESD; it does not
substitute for CSE.

## 9. Spec and schema changes

- **`esm-spec.md` §4** — grammar and evaluation for `let`/`var`; identifier grammar note reserving the
  `$`-prefixed binding namespace; single-evaluation/purity statement.
- **`esm-spec.md` §5.5.3 + `CONFORMANCE_SPEC.md` §5.5.3.1 → new §5.5.4** — the normative CSE pass
  (§3.2 here), its determinism surface (§4), and the requirement that it run in both canonical-emit
  entry points.
- **`esm-spec.md` §9.6.4** — the post-lowering gate accepts `let`/`var`; clarify they are not
  rewrite-target ops and not `apply_expression_template`.
- **`esm-spec.md` §9.6.6** — three diagnostics (§6).
- **`esm-schema.json`** — `$defs/LetExpression` (`op` const `let`; `bindings` array of
  `{name: reserved-identifier, value: Expression}`; `body: Expression`) and `$defs/VarRef` (`op`
  const `var`; `name: reserved-identifier`), added to the `Expression` `oneOf`; mirrored in the four
  binding schemas and the TypeScript embedded schema.

## 10. Binding implementation notes — porting checklist (wave 2)

This RFC lands **spec + schema + Julia reference + fixtures** only. Ports (Python, Rust, TypeScript,
Go) are a later wave. Per binding:

1. **Canonical emitter** — implement the §3.2 CSE pass identically (canonical hash over
   number-canonicalized AST; hoist-ceiling by free-index binder; the two normative constants; the
   fixed ordering and name scheme). Wire it into **both** emit entry points.
2. **Evaluator** — a binding environment for `let`/`var` (native `let`/const/local; single-eval memo).
3. **Validator** — the three diagnostics; reserved `$`-namespace check.
4. **Gate** — accept `let`/`var` post-lowering.
5. **Cross-binding** — the determinism fixture (§7.3) must byte-match the Julia golden.

Reference order: Julia first (mints the goldens); the determinism fixture is the acceptance gate for
each port.

## 11. Open questions

1. **Placement policy.** This RFC specifies hoisting to the innermost legal ceiling (least-common
   binder). A simpler "single flat `let` per ceiling body" is easier to eyeball; a more aggressive
   nested placement is marginally smaller. The reference implementation should start with the
   ceiling rule as written (deterministic and near-optimal) and the fixtures pin whatever it does.
2. **Threshold tuning.** `CSE_SIZE_MIN = 3`, `CSE_MULTIPLICITY_MIN = 2` are proposed to maximize golden
   shrink while keeping tiny shared leaves inline. These are normative once chosen; changing them later
   is a golden-regenerating change. Worth a quick sensitivity sweep on the ESD WENO/HJ-WENO trees before
   ratifying.
3. **CSE inside aggregate bodies in v1, or defer?** The cross-region (face) sharing is the larger,
   simpler win and is index-free. Within-aggregate sharing is index-scoped and slightly more intricate.
   Both are specified here; an incremental landing could ship face-level (root `let`) first and
   aggregate-level second, if that de-risks the ports.
4. **Interaction with a future declarable-periodic index set (§8.4).** If periodic faces stop being
   materialized as regions, the cross-region multiplier disappears and CSE's remaining job is purely
   within-tree — the two features compose cleanly, but the fixtures should be revisited when both land.

---

*Downstream motivation and measurements: the EarthSciDiscretizations WENO5 / HJ-WENO migration
(`../earthscidiscretizations`), whose fully-inlined goldens (2.4 MB / 6.1 MB, 90.6 % / 92.7 % redundant)
are the concrete driver for this RFC. Those schemes are being held out of the ESD commit pending this
feature so their goldens land ~10× smaller rather than being committed inlined and regenerated later.*
