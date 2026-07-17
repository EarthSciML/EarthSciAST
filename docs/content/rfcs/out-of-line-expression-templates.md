# RFC — Out-of-line expression templates

**Status:** Draft v3 (measurements reproducible; design pinned to R1/R2 in §6; §7.3 audit re-run under the corrected predicate with `tools/opacity_audit.py`; version-gate/emit-stamp semantics pinned in §7.8 rules; not yet prototyped)
**Bead:** (unassigned)
**Affects spec version:** §9.6.3 substitution, §9.6.4 (**replaced**: Option A → Option B), §9.7.3 (composition → checking), §10.7 flatten **and esm-libraries-spec §4.7.5** (FlattenedSystem carries a template registry), schema description strings (no shape change — see §7.5.6). Gated at `esm: 0.9.0`.
**Scope:** The *authored* wire vocabulary is unchanged — no new op, no rule-authoring change, no edits to any authored `.esm`. The *emitted* form changes: template references survive `parse → emit`, and emit materializes the referenced templates into the document (§7.5).

---

## 1. Proposal

**Stop inlining expression templates. Keep the reference — through load, through the rewrite
fixpoint, through flatten, and through `parse → emit` — and compile each distinct template body
once.**

Two requirements pin the design (§6):

- **R1 — Templates survive round trip.** A document that crosses the wire (`emit` → transfer →
  `load`) must still carry its factoring, so the receiver can build it in a reasonable amount of
  time. Reference preservation cannot be a private build-path optimization; it must be the
  emitted form.
- **R2 — Five-binding parity.** Whatever Julia must solve, Python, Go, Rust, and TypeScript must
  also solve. The design confines the mandatory cross-binding surface to load / emit / validate /
  flatten (all specified here) and leaves compile-once as an optimization any binding MAY adopt
  (§7.7).

§2–§5 are why this is necessary; §7 is the contract; §12 is how to verify it.

## 2. The abstraction already exists — load throws it away

§9.6 already provides the mechanism. From §1 of the spec:

> *Factoring third.* An author MAY name a fixed Expression AST tree as an
> `expression_templates` entry (§9.6) … and reference it elsewhere by name **with parameter
> substitution**. A template body MAY reference other match-less templates as a
> statically-checked acyclic DAG that is **inlined at load** (§9.7.3). Factoring is **not**
> programming: bodies are fixed AST trees, parameters are pure-syntactic substitution slots,
> no recursion, no metaprogramming.

A named AST body, parameters, substitution, acyclic, no recursion. That is a function defined
inside the AST, and it is already in the spec today. ESD's PPM stencils **are** expression
templates; the discretization library is a template-library file (§9.6.1 / §9.7.1). Concretely:
`ppm_flux_D_lon_mono_inflow_bc`'s rule body is one `makearray` whose seven region values are
seven `apply_expression_template` references to seven named stencil files (interior, `i1`–`i3`,
`iNm2`–`iN`), each parameterized on whole fields (`q`, `U`, `qbc_w`).

**The defect is three words: "inlined at load."** The author factors the body; load discards the
factoring. Everything downstream — flatten, `_resolve_indices`, `_compile`, `_stencilize` —
then works on a tree in which every instantiation of the same body is a distinct, unrelated
copy, and the build spends its life re-lowering copies it cannot recognise as the same thing.

## 3. What it costs today

Building a **343-cell** model (7×7×7, two tracers, monotone PPM on three axes) lowers
**31 million** AST nodes and takes **~3 minutes**. The full ReSEACT Stage-C assembly
(12 SuperFast species, GEOS-FP forcing) has **never completed a build** in three attempts
(90 min, 85 min, 17 min — all killed, none finished).

Measured on `prof_*.esm`: the verified 7×7×7 `transport_3d` stack with a 2-species toy network,
varying only WHICH AXES carry a flux divergence. Uncontended, Julia 1.12.6. Method traps in §12.

### 3.1 Compiled templates are a cross-product of boundary classes

| axes | spine templates | build |
|---|---|---|
| `lon` | 15 | 19.4 s |
| `lon,lat` | 99 | 18.7 s |
| `lon,lat,lev` | **689** | **186.8 s** |

~7× per added axis. PPM authors 7 stencils per axis (`i1`, `i2`, `i3`, `interior`, `iNm2`,
`iNm1`, `iN`). A cell's template identity is its class **combination** across axes: 7³ = 343,
×ghost patterns ≈ 689.

`689 ≈ 2 × 343 cells`. With 6 boundary classes per axis on a 7-wide grid there is ~**one
interior cell per axis** — the grid is nearly all boundary, so §4c's cell grouping has almost
nothing left to collapse.

### 3.2 Spine size, and the total

Per spine, 24 of 689 sampled evenly:

| metric | per spine |
|---|---|
| tree positions | 110,566 |
| **distinct objects** (what `_compile` lowers) | **45,415** |
| distinct structures (a perfect DAG) | 16,345 |

`689 × 45,415` = **31,290,763**, cross-checked against **29,344,761** `_compile` calls counted
by an independent instrument (~6% apart).

### 3.3 Inlining is the cause, and it compounds

| | 1 axis | 3 axes |
|---|---|---|
| inlining blowup (positions / structures) | 2.3× | **6.8×** |
| objects per spine | 6,228 | 45,415 |

A 3-axis spine is **7.3×** a 1-axis spine, not 3×. The redundancy *grows* as more templates are
fused into one body — that is the tell that inlining creates it.

## 4. Root cause

After the pointwise lift, one species' per-cell RHS is

```
( -( A + B + C ) + q·( D + E + F ) ) / m
```

`A`, `B`, `C` are `index(makearray_lon…)`, `index(makearray_lat…)`, `index(makearray_lev…)` —
three independent template instantiations, each a `makearray` whose `regions` are that axis's
boundary classes and whose `values` entries are **inlined stencil bodies**.

`_stencilize` builds one spine for the whole RHS. Walking it, `_select_region` picks each
makearray's region from the cell's index, so the branch key is the *tuple*
`(A-region, B-region, C-region)` → 7×7×7. The `lon_i1` body is re-lowered once for every
`(i1, j*, k*)` pair — **49 times** — and every copy is unrecognisable as the same body, because
the reference was inlined away at load.

The three makearrays never interact; they are summed. The cross-product is an artifact of
inlining, not a property of the mathematics.

## 5. What preserving the reference buys

```
today:       one spine per (lon-class, lat-class, lev-class) → 7×7×7 = 343 (×ghost ≈ 689)
out-of-line: 7 lon bodies + 7 lat bodies + 7 lev bodies      → 21 compiled bodies
             each cell's RHS = 3 references + a few ops      → tiny
```

Each body carries one axis's PPM — a 1-axis spine, **6,228** objects measured, not the fused
**45,415**.

| | node-lowerings |
|---|---|
| today — 689 × 45,415 | **31,290,763** |
| out-of-line — ~21 bodies × 6,228 + 343 tiny use sites | **~140,000** |
| | **≈ 100–200× less** |

**7+7+7 replaces 7×7×7.** It moves the exponent, not a constant. And because the stencil
parameters are whole fields, one compiled body can serve every species, not just every cell.

## 6. Requirements, and why this is sound

**R1 (round trip)** exists because emitted documents are how models travel: a receiver handed
`emit(load(f))` must be no worse off than a receiver handed `f`. Under Option A the emitted form
is the expanded form — the factoring is destroyed *in the document itself*, and the receiver
inherits §3's build times with no way back. R1 makes reference preservation a property of the
format, not of one binding's build pipeline. (The binding-internal alternative this rules out is
recorded in §10.)

**R2 (parity)** exists because the five bindings share one document semantics and one
conformance suite; a load-behavior change that only Julia implements forks the format. The
design keeps the mandatory surface small: the expensive part (compile-once) is an optimization
with a specified safe fallback (§7.7), not a conformance requirement.

Why the change stays small:

- **No new syntax.** Template definition and reference already exist (§9.6, §9.7).
- **No new semantics, one stated exception.** A reference to a fixed AST body with substituted
  parameters is *defined* to equal the inlined body (§7.4). The single observable divergence
  from Option A — `match` patterns do not see through surviving references — is pinned,
  audited, and fixture-tested (§7.3, §11.2).
- **§9.6's own guarantees are the preconditions.** Fixed bodies, purely syntactic parameter
  slots, acyclic, no recursion, no metaprogramming — exactly what makes
  compile-once-reference-many sound. A language with recursion or metaprogramming could not do
  this safely; this one can, by construction.
- **This is not esm-tzp.** `closed-function-registry.md` removed `registered_functions` because
  they called **out** to handler code implemented per language binding — semantics outside the
  document, hence drift. An expression template's body **is** Expression AST, in the file,
  canonically serializable, evaluated by machinery every binding already has:

  | kind | semantics live in | status |
  |---|---|---|
  | **Closed functions** (`fn`: `interp.*`, `datetime.*`) | the **spec** (§9) | current |
  | ~~Registered functions~~ (external handler IDs) | each **binding** | removed (esm-tzp) |
  | **Expression templates** (§9.6) | the **document** | current — and now preserved |

## 7. The Option B contract

### 7.1 Load pipeline

Per document, the §9.7.6 within-load order, with two amendments (marked ★):

1. Resolve imports — recursively, instantiating, renaming, rebinding per edge (§9.7.2/§9.7.7).
2. Merge index sets (§9.7.5).
3. Close and fold metaparameters (§9.7.6).
4. ★ §9.7.3 body **checking** — build the body-reference graph, reject cycles
   (`apply_expression_template_recursive_body`) and depth > 32
   (`template_body_expansion_too_deep`), compute each template's *target-bearing* flag (§7.2).
   **No inlining.**
5. ★ Eager-expansion pre-pass (§7.2) over the component's expression positions.
6. §9.6.3 fixpoint — unchanged selection and traversal; substitution per §7.3.

There is no expansion phase after the fixpoint. Non-eager references survive in expression
positions, inside lowered rule-body copies, through flatten (§7.6), and through emit (§7.5).

### 7.2 Eager expansion — the rewrite-target carve-out

Rewrite-target ops must never hide inside a surviving reference, or the fixpoint could not
lower them and the `unlowered_operator` gate would misfire. Let **T** be the set of ops no
evaluator implements: §4.2's open rewrite-target tier (a spatial — or any right-hand-side —
`D`, the sugar ops `grad`/`div`/`laplacian`/`integral`, every open-namespace custom op), plus
the two §4.2-listed forms the spec defines to be *eliminated at load* rather than evaluated:
`table_lookup` (§9.5) and `enum` (§4.5).

- A **template is target-bearing** iff its body contains any node whose op ∈ T — anywhere,
  including inside the `bindings` of nested references — or references (transitively, through
  the §7.1-step-4-checked DAG) a target-bearing template. Computable at registration; cached.
- An **`apply_expression_template` node is eager** iff its template is target-bearing, or any of
  its `bindings` values contains a node with op ∈ T or a nested eager reference.

Loaders MUST expand eager nodes — and only eager nodes — by pure substitution (§9.6.3 c5),
innermost-first, in a pre-pass **before** the fixpoint (§7.1 step 5). The pre-pass consumes no
`MAX_REWRITE_PASSES` budget. For eager nodes this reproduces Option A's ordering exactly, so
compound-precedence matching (a Godunov rule firing on structure partly supplied by a template)
behaves as today. The `unlowered_operator` gate then walks the reference-preserving tree
unchanged: eager expansion guarantees no member of T survives inside any remaining reference.

### 7.3 What the rewrite engine sees

- `match` patterns MUST NOT contain `apply_expression_template` nodes (unchanged).
- The engine treats surviving (non-eager) references as **leaves**: it does not descend into
  their `bindings`, no pattern matches structure inside them, a pattern metavariable binds one
  as a whole sub-AST, and a `where` `shape` constraint fails on one (a reference is not a bare
  variable name).
- **Instantiation** (§9.6.3 c5) is amended: parameter substitution applies inside the
  `bindings` values of nested references exactly as in any other Expression position; the
  `name` field is never a substitution site; params shadow as before. If instantiation
  introduces an eager reference into the tree (a rule body that references a target-bearing
  template), the engine expands it immediately as part of the same rewrite.
- **The one divergence from Option A:** a pattern can no longer match structure that would only
  assemble across a surviving-reference boundary — e.g. a compound rule over pure
  evaluable-core structure where part of the compound comes from a non-target-bearing template.

  *The correct audit predicate.* "Every pattern carries an op ∈ T" is necessary but **not**
  sufficient to rule the divergence out: eagerness is a property of *templates* (target-bearing
  body or bindings, §7.2), not of rule patterns, so a pattern can anchor on a `D` while
  requiring pure evaluable-core structure beside or beneath the anchor that a surviving
  (target-free) reference hides — e.g. `ppm_flux_D_lon_mono_inflow_bc` matches the compound
  `D(*(U,q), …)`, and a use site that factored `*(U,q)` into a target-free template would slip
  it. The divergence is unobservable iff **no structural (non-metavariable) pattern position is
  supplied by a surviving reference at any use site** — a claim about rules *and* use sites.
  Three rule-side exposure classes: (i) *pure structural fragments* — pattern subtrees that are
  op nodes containing no op ∈ T (anything containing a T op is force-expanded and cannot hide);
  (ii) *ground literal args* — a non-param string matches only that bare variable reference,
  never a reference node; (iii) *`where` `shape` constraints* — a surviving reference fails
  `shape`, which under Option A passed only when the inlined body was itself a bare variable
  name.

  *Audit (2026-07-17, corrected predicate; `tools/opacity_audit.py`).* Corpus =
  EarthSciDiscretizations + this repo + reseact.esm + wildlandfire.esm, 1,129 `.esm` files, 144
  match rules (115 ESD + 29 in-repo fixtures). Exposure inventory: 12 rules carry pure
  structural fragments (all in the latlon3d flux family, fragment `*(U,q)` directly under the
  `D` anchor), 1 rule carries a ground arg (the `per_variable_scheme_literal_args/` fixture, by
  design), 119 rules carry `where` constraints, and 11 bare-variable-body templates exist (the
  `shape` degenerate). Use-site side: of 293 authored expression-position references, 292 are
  target-free and would survive (1 is a coupling-library `transform` reference — a different
  mechanism, consumed at load, out of scope). **Zero surviving references share even an op-node
  ancestor with any op ∈ T** — so no pattern anchored at a T op (i.e., every current rule) can
  have any structural position supplied by a surviving reference, anywhere in the corpus. The
  divergence is unobservable today; it is a *corpus* fact that a new rule or a new authored
  factoring can invalidate, which is why the spec text states the semantics outright and two
  fixtures pin them.

  *The sharpest failure mode is silent, not loud.* When a compound rule fails to fire across a
  reference boundary, a **lower-priority generic rule can still match** by binding the surviving
  reference whole with a metavariable — a silent scheme substitution (e.g. first-order upwind
  where the author expected monotone PPM), not an `unlowered_operator` rejection. Pinned by the
  `opacity_priority_shadowing/` fixture (§9.2) alongside `opacity_negative/`.

### 7.4 `Expand` — a function, not a phase

Define **`Expand(tree)`**: replace every `apply_expression_template` node by its template's
body under pure substitution, to a fixpoint (the §9.7.3 DAG is acyclic and substitution is
confluent, so the result is order-independent). `Expand` is deterministic: two expansions of
the same `(template, bindings)` pair MUST produce structurally identical ASTs with bit-equal
constants (Option A rule 3, carried over). `Expand ∘ load_B` MUST equal Option A's load image
— except at the §7.3 divergence, which the corpus audit shows is currently vacuous.

Semantics are defined by the image: **a reference denotes exactly what its expansion denotes.**
Every consumer MAY expand — wholly, per node, or not at all — but observable behavior MUST be
as if it evaluated `Expand(tree)`: numeric results bit-identical, diagnostics per §8.

### 7.5 The emitted form

`parse → emit` produces a **self-contained, reference-preserving** document:

1. **Call sites survive verbatim** — surviving references emit as they stand post-load
   (post-substitution, post-fold). Eagerly-expanded nodes are gone, as under Option A.
2. **Referenced templates are materialized.** Each component carries, in its own
   `expression_templates` block, the transitive closure of templates named by its surviving
   references (closure includes references inside materialized bodies). Entries are the
   *registered instances*: post-`only`, post-`rename`/`rebind`, post-metaparameter-fold,
   checked but uninlined. `only` is respected automatically — materialization is by reference
   closure. (Load-side corollary, pinned during the Julia implementation: with bodies
   uninlined, an `only`-filtered import MUST carry the kept templates' transitive
   body-reference closure into the importer's registry, or the kept rules' surviving
   references dangle; carried entries participate in §9.7.4 dedup/conflict checks like any
   import. Spec §9.7.2's `only` row states this.) Match rules are never materialized (they
   are consumed by the fixpoint; only match-less entries are referenceable, §9.6.2).
3. **Authored declarations survive verbatim**, exactly as Option A rule 5: in-file
   `expression_templates` registries, top-level registries, and `metaparameters` blocks. A
   template-library file still round-trips to itself byte-wise.
4. **Imports are consumed**, as today: `expression_template_imports` does not survive emit
   (§9.7.6). The materialized registry is what replaces the inlined copies as the edge's
   residue.
5. **Canonical order:** authored entries first, in authored order; materialized entries after,
   sorted lexicographically by name (UTF-8 byte order). All five bindings MUST emit this exact
   order — it is the cross-binding byte-identity contract for the new surface. In the
   canonical byte writer, every JSON object's keys emit sorted EXCEPT the
   `expression_templates` block, which preserves this entry order (pinned during the Julia
   implementation: the pre-existing golden canonicalizer sorted all keys, and the two
   readings coincide only while no component mixes authored + materialized entries — so the
   exception is stated normatively rather than left to collide later). Component-level
   authored `match` rules — consumed by the fixpoint, invocable by nothing — are dropped
   from the emitted component; component-level authored match-less entries survive verbatim.
   Top-level (library) registries survive verbatim including their match rules (item 3).
6. **Names may be dotted.** Renamed imports materialize under their post-rename names
   (`fine.ppm_D_interior`). **No schema shape change is needed:** the schema's three
   `expression_templates` objects use unconstrained `additionalProperties` — no
   `propertyNames`/`patternProperties` key pattern exists, so dotted keys are already
   schema-valid on disk. What must change is (a) any binding resolver that rejects dotted
   template names, which MUST accept them, and (b) the schema's stale *description strings*
   (esm-schema.json:1417, :1675 — "Loaders MUST expand … at load time (Option A round-trip)"
   and "Templates do NOT call other templates and do NOT recurse", the latter already
   contradicting §9.7.3), which MUST be rewritten to Option B wording. Collisions are
   impossible at emit: the merged scope was already collision-checked at load (§9.7.4).
7. **Idempotency (normative):** `emit ∘ load` is a byte-wise fixed point —
   `emit(load(emit(load(f)))) == emit(load(f))`. On reload, materialized entries are ordinary
   local declarations, step-4 checking passes, the fixpoint matches nothing (targets are gone),
   and re-emit reproduces the bytes. This is the R1 property test.

### 7.6 Flatten

Flatten — specified in spec §10.7 **and, normatively for the algorithm, in
esm-libraries-spec §4.7.5**, whose FlattenedSystem is the cross-binding API boundary and
gains the merged registry as a first-class field — acquires two duties it never needed while
references were pre-inlined:

- **Scoping into bodies.** The variable-renaming map flatten applies to a component's equations
  applies identically to free variable references inside that component's carried template
  bodies and inside surviving references' `bindings`.
- **Registry merge.** Component registries merge into the flattened document. Deep-equal
  same-name entries (post-scoping) dedupe at first occurrence — the common case: two components
  importing one stencil produce identical folded bodies. A non-deep-equal same-name collision
  renames **both** entries deterministically to `<ComponentPath>.<name>`, rewriting their
  references in lockstep. No new diagnostic: the rename is total and deterministic.

### 7.7 Evaluation strategies (what R2 actually costs)

Conformance never requires compile-once. An evaluator MAY:

- **Expand at build** — call `Expand` once when constructing the evaluator. Semantics free,
  cost identical to today. This is the expected strategy for Python/Go/Rust/TS, whose
  conformance workloads are small.
- **Evaluate/compile references natively** — compile each distinct body once and emit calls.
  REQUIRED to be bit-identical to the `Expand` image; gated per §12. This is Julia's build
  path, and it is where §5's ~100–200× lives. Memoization keys are binding-internal (§7.9 Q1).

### 7.8 Replacement spec text (ready to splice)

> #### 9.6.4 Round-trip — Option B (reference-preserving)
>
> The round-trip model from `esm: 0.9.0` is **Option B: reference preservation**. Option A
> (always-expanded, §9.6.4 of spec versions 0.4.0–0.8.x) is the historical model implemented
> by pre-0.9.0 loaders. **There is no version-switched dual pipeline:** an Option B loader
> applies Option B load semantics to every document it accepts (any declared `esm` ≥ 0.4.0
> carrying template constructs). Rule 4's pattern-opacity is the only observable divergence
> from Option A on older documents, and it is unobservable on the audited corpus (§7.3 of the
> RFC); a loader MUST NOT special-case older versions to recover Option A matching.
>
> 1. **Load resolves; it does not expand.** Loaders resolve imports, renames, and
>    metaparameters and run the §9.6.3 fixpoint as before, but MUST NOT expand
>    `apply_expression_template` nodes except as rule 3 requires. Template references survive
>    load; downstream code MAY recognise them (that is the point), but MUST give them the
>    semantics of rule 2.
> 2. **A reference denotes its expansion.** `Expand(tree)` — full pure substitution to the
>    acyclic fixpoint — is deterministic (structurally identical ASTs, bit-equal constants,
>    caching unobservable). All observable behavior MUST be as if evaluated on `Expand(tree)`;
>    numeric results MUST be bit-identical to it.
> 3. **Eager expansion.** A reference whose template is target-bearing (its composed body
>    contains, transitively, an op no evaluator implements — the §4.2 open rewrite-target
>    tier, or the load-eliminated `table_lookup`/`enum` forms), or whose `bindings` carry
>    such an op or such a reference, MUST be expanded innermost-first in a pre-pass before the
>    §9.6.3 fixpoint. The pre-pass consumes no `MAX_REWRITE_PASSES` budget. Consequently no
>    rewrite-target op can survive inside a reference, and the pre-evaluation
>    `unlowered_operator` gate walks the reference-preserving tree unchanged.
> 4. **Patterns do not see through surviving references.** The rewrite engine treats a
>    surviving reference as a leaf: patterns match it only whole (via a metavariable), never
>    inside it; `where` constraints fail on it. Instantiation substitutes through nested
>    references' `bindings`; `name` is never a substitution site; an eager reference introduced
>    by instantiation expands as part of the same rewrite.
> 5. **Round-trip emits the reference-preserving, self-contained form.** Surviving call sites
>    emit verbatim. Each component materializes into its `expression_templates` the transitive
>    closure of templates its surviving references name — registered instances: post-`only`,
>    post-rename, post-fold, uninlined — authored entries first in authored order, then
>    materialized entries in lexicographic (UTF-8) name order. Registry keys admit dotted
>    identifiers. Match rules are not materialized. `expression_template_imports` is consumed
>    as before. Authored declarations survive verbatim; a template-library file round-trips to
>    itself. `emit ∘ load` MUST be a byte-wise fixed point.
> 6. **Validators discharge validity per §9.6.9.** A document is valid iff `Expand(document)`
>    is valid; bindings MUST discharge this via registration-time, call-site, and memoized
>    per-instantiation checks (§9.6.9), not by materializing the full expansion.
> 7. **Flatten carries registries** (§10.7; esm-libraries-spec §4.7.5): the component-scoping
>    map applies inside carried bodies and reference `bindings`; registries merge with
>    deep-equal dedup and deterministic `<ComponentPath>.<name>` rename on non-equal collision.
> 8. **Version stamping.** An emitted document that carries any surviving
>    `apply_expression_template` call site or any **materialized** registry entry MUST declare
>    `esm: 0.9.0` or later, regardless of the source document's declared version — the bump
>    happens at the first emit. An emitted document carrying neither (no templates at all, or
>    only authored declarations surviving verbatim per rule 5) keeps the source's declared
>    version, so the rest of the corpus round-trips byte-identically as today. Pre-0.9.0
>    loaders therefore reject reference-preserving documents at their ordinary version gate —
>    loudly — instead of accepting them, expanding at load, and silently re-emitting the
>    de-factored form.
>
> #### 9.7.3 Registration-time body checking
>
> A template `body` MAY contain `apply_expression_template` nodes referencing other templates
> that are in scope and match-less. After the effective sequence (§9.7.4) is fixed, the loader
> builds the body-reference graph, rejects cycles (`apply_expression_template_recursive_body`)
> and chains deeper than `MAX_TEMPLATE_EXPANSION_DEPTH = 32`
> (`template_body_expansion_too_deep`), and computes target-bearing flags (§9.6.4 rule 3).
> Bodies are **not** inlined. `match` patterns MUST NOT contain `apply_expression_template`
> nodes.

> #### 9.6.9 Validation discharge (new)
>
> A document is valid iff `Expand(document)` is valid. Bindings MUST discharge this without
> materializing the full expansion, per the re-homing table (RFC §8, spliced here verbatim):
> registration-time checks on composed folded bodies (`makearray_region_inverted` — sound
> because region bounds admit metaparameter expressions but not template params, §9.6.1),
> call-site checks (unknown template, bindings mismatch), and memoized per-instantiation
> checks (units, shape, `geometry_manifold_invalid`, keyed on
> `(template id, scalar-field values, per-param unit+shape signature)`, diagnostics naming
> call-site path, template name, and intra-body path). The `unlowered_operator` walk runs on
> the reference-preserving tree, sound by §9.6.4 rule 3. No new diagnostic codes.
>
> #### 10.7 addition (mirrored in esm-libraries-spec §4.7.5)
>
> **Template registries flatten with their components.** The variable-renaming map flatten
> applies to a component's equations applies identically to free variable references inside
> that component's carried template bodies and inside surviving references' `bindings`
> (template `params` shadow, exactly as in §9.6.1). Component registries merge into the
> flattened document: deep-equal same-name entries (post-scoping) dedupe at first occurrence;
> a non-deep-equal same-name collision renames **both** entries deterministically to
> `<ComponentPath>.<name>`, rewriting their references in lockstep — total, deterministic, no
> new diagnostic. The flattened representation (esm-libraries-spec §4.7.5, "FlattenedSystem")
> carries the merged registry as a first-class field in every binding; downstream consumers
> (graph construction, simulation backends, emit) resolve surviving references against it.

§9.6.3's constraint 5 gains the two sentences of rule 4 above (substitution through `bindings`;
`name` never a site). §9.6.5 gains: *reference-preserving emit, dotted registry keys,
materialized registries, and the §9.6.4-rule-8 version stamp arrive at `esm: 0.9.0`.*

### 7.9 The v1 open questions, resolved

| v1 §6.2 question | Resolution |
|---|---|
| 1. Keyed by what? | **Out of the spec.** The spec guarantees reference ≡ expansion (§7.4); compiled-body memoization keys are binding-internal. Julia's fast path: `(template id, scalar-field param values, params-bound-to-bare-references)` — ESD's stencils all qualify (`q`, `U`, `qbc_*` are whole fields), so one body per template serves every cell and species. Anything outside the fast path (arbitrary-AST bindings) MAY fall back to per-node `Expand` — always sound. |
| 2. `match`-driven rules | References survive **both** §9.7.3 composition and §9.6.3 instantiation (§7.1, §7.3). Forced by R1 — the emitted lowered form keeps them — and by the prize: the blowup-relevant references live *inside* match-rule bodies. |
| 3. Metaparameter folding | Unchanged: folds at load; materialized instances are folded (§7.5). Fold variants are already distinct registrations (§9.7.4/§9.7.7); their count is bounded by import instances, not cells. |
| 4. Downstream identity | Binding-internal; gated by the checksum + `ESS_STENCIL_DISABLE` differential (§12), unchanged from v1. |

## 8. Validation re-homing (new spec §9.6.9)

Option A rule 4 said "validators run on the expanded form." The replacement, as a table —
normative anchor: *a document is valid iff `Expand(document)` is valid*, discharged as:

| Check / diagnostic | Option A home | Option B home |
|---|---|---|
| Schema validation | expanded document | the reference-preserving document (references are already legal in every Expression position; registry keys are already unconstrained in the schema, so dotted names validate — binding resolvers MUST accept them) |
| `apply_expression_template_unknown_template`, `…_bindings_mismatch` | call site, at load | unchanged |
| `…_recursive_body`, `template_body_expansion_too_deep` | §9.7.3 registration (then inlined) | §9.7.3 registration (check-only); same codes |
| `makearray_region_inverted` | expanded, folded form | registration, on the composed folded body. Sound because region bounds cannot contain template params — params substitute only in variable-reference and scalar-field positions (§9.6.1) — so the check is instantiation-independent |
| `geometry_manifold_invalid` | expanded form | per-instantiation (a `manifold` may be a param), memoized; diagnostic reports (call-site path, template name, intra-body path) |
| Units and shape checks | expanded form | per-instantiation, memoized on `(template id, scalar-field values, per-param unit+shape signature)` |
| `unlowered_operator` | pre-evaluation walk of the expanded tree | the same walk on the reference-preserving tree; sound by eager expansion (§7.2) |
| `rewrite_rule_nonterminating` | fixpoint | unchanged; the eager pre-pass consumes no pass budget |

No new diagnostic codes.

## 9. Conformance, goldens, migration

### 9.1 The goldens are reused, not churned

v1 said "every AST golden changes." Under Option B that is wrong, and the correction matters:
the 21 existing `expanded*.esm` conformance goldens become the pinned oracle for `Expand` —
each fixture asserts `Expand(load(fixture))` is structurally equal to its existing golden. The
16 numeric golden JSONs are untouched (semantics are identical by §7.4). Each
expression-template fixture *gains* one golden — `emitted.esm`, the canonical
reference-preserving emit — and loses none.

### 9.2 New fixtures (`tests/conformance/expression_templates/`)

- `emit_materialized_registry/` — `import_smoke`'s consuming model, emitted: imports gone,
  referenced stencils materialized, call sites intact; plus the §7.5.7 idempotency assertion.
- `emit_rename_dotted_keys/` — `import_rename_two_instances`, emitted: dotted registry keys on
  disk (the schema pin).
- `eager_target_bearing/` — one match-less template whose body carries a `D`, one that
  doesn't; the first's reference is expanded and lowered at load, the second's survives
  (positive + negative in one golden).
- `opacity_negative/` — a compound `match` pattern whose shape only assembles across a
  surviving-reference boundary: MUST NOT fire (§7.3's pinned divergence).
- `opacity_priority_shadowing/` — the silent version of the divergence (§7.3): a
  high-priority compound rule (à la `D(*(U,q))`) whose structural fragment is hidden in a
  target-free reference, plus a lower-priority generic `D($f)` rule. The golden pins that the
  compound rule does NOT fire and the generic rule DOES — by binding the surviving reference
  whole — so the behavior is explicit, deterministic, and identical in all five bindings.
- `per_instantiation_validation/` — a `manifold`-param template, two call sites, one
  inadmissible: rejected on the expanded-equivalent check, naming the offending call site.
- `flatten_registry_merge/` — two components referencing one stencil (dedup) and a forced
  non-equal collision (deterministic owner-path rename).
- Property over **all** fixtures, all five bindings: `emit ∘ load` idempotent byte-wise.

### 9.3 Version gate and compatibility

Reference-preserving emit, materialized registries, and dotted registry keys arrive at
`esm: 0.9.0` (§9.6.5 gains the gate). New loaders accept every older form — an 0.8.x authored
file uses only vocabulary that is unchanged here — and run the **one** Option B pipeline on
every document they accept; there is no version-switched dual load path (§7.8 intro). Emit
stamps `esm: 0.9.0` on any document that leaves it carrying surviving references or
materialized registry entries, and preserves the declared version otherwise (§7.8 rule 8) —
so `emit ∘ load` reaches its byte-wise fixed point on the first emit for old documents and
immediately for 0.9.0 ones. Old loaders reject 0.9.0 documents at the ordinary version gate;
nothing forks silently. Migration cannot split semantics: call sites and registries are
constructs every binding already implements, and `Expand` is the old expansion code
re-pointed at a function boundary.

### 9.4 Per-binding work plan (identical shape ×5 — R2)

1. §9.7.3 composition → check-only + target-bearing flags (mostly a deletion).
2. Eager-expansion pre-pass; fixpoint substitution through `bindings`; references-as-leaves.
3. `Expand` as a public function (the existing expansion machinery, repointed).
4. Validators re-homed per §8 (memoized instantiation checks).
5. Emit materialization + canonical ordering + version stamping (§7.5, §7.8 rule 8); accept
   dotted template names in resolvers (no schema shape change, §7.5.6).
6. Flatten body-scoping and registry merge (§7.6; the binding's FlattenedSystem representation
   gains the merged registry, esm-libraries-spec §4.7.5).

Evaluation strategy per binding: default is `Expand`-at-build (§7.7) — correctness free, cost
unchanged. Julia additionally implements reference-aware compilation in
`_stencilize`/`_compile` (identity-keyed memo gains a `(template, key)` tier at the reference
boundary), gated by §12. That is the only binding-specific engineering, and it is optional
machinery under the spec.

## 10. Alternatives, and the measurements that rejected them

Recorded so they are not re-tried. Each was pursued; none survived contact with a measurement
or a requirement.

- **A `let` / shared-binding node** — **1.48×** (1 axis), **2.78×** (3 axes). Shares
  subexpressions *within* a body while leaving 689 fused bodies standing. A schema change and
  every golden, for 2.78×. Note it is *fusion* that grows the prize (2.3 → 6.8), so removing
  the fusion removes most of what a `let` would have recovered: the two are not additive.
- **Hash-consing the build memo** — prototyped. `_BuildMemo` is identity-keyed and 93.8% of its
  misses are structurally redundant, which looks like a large prize. A structural-hash tier over
  `_compile` + `_resolve_indices` was **correct** (identical solve checksum) and cut allocation
  21% at 2 axes, but ran **>6× slower** at 3 axes: the hash cache (an `IdDict` over every
  `OpExpr`) grows to millions of entries and outruns its own savings exactly where the win was
  needed. This is the sharpest argument for this RFC — hash-consing pays to *re-discover* the
  sharing that inlining destroyed. Not destroying it is free.
- **Type stability across the build** — JET reports 540 runtime-dispatch sites, hot functions
  included (`_compile_fn_node` ×12, `_resolve_indices` ×11, `_sub_preserving` ×9). The CPU
  profile caps the prize: dispatch (`ijl_apply_generic` 1.8% + `sig_match_fast` 2.0%) ≈ **4%** of
  main-thread CPU, while **GC is ~67%** — and that GC is driven by real structures, not boxing
  (instability markers ≈12% of allocations by count, far less by bytes). A core-IR refactor
  touching everything, for ~4–8%.
- **Binding-internal lazy composition ("as-if expanded")** — considered for v2; rejected by
  **R1**. Keep Option A in the spec and let the Julia build defer expansion internally behind
  an observational-equivalence carve-out: §5's win, zero golden churn, no other binding
  touched. But emit would still produce the expanded form — a document that crosses the wire
  arrives de-factored and unbuildable in reasonable time, and four bindings' emitters would
  keep producing documents the fifth cannot afford to rebuild (R2). The factoring has to live
  in the document, not in one binding's memory.

## 11. Risks

1. **The ~21-body estimate is structural, not measured.** It follows from the measured
   cross-product (15 → 99 → 689) and the measured 1-axis spine (6,228 objects), but no
   out-of-line build exists yet. Largest uncertainty here.
2. **The §7.3 opacity divergence is a real semantic exception.** Audited unobservable on the
   entire current corpus under the corrected predicate (§7.3: zero surviving references share
   an op-node ancestor with any rewrite-target op, over 1,129 files and 144 rules;
   `tools/opacity_audit.py`), and pinned by `opacity_negative/` and
   `opacity_priority_shadowing/` — but this is a corpus fact, not a theorem: a future rule
   with pure-structural pattern content, or a future authored factoring that hides such
   content under a rewrite-target op, would behave differently than under Option A — in the
   shadowing case *silently*, by falling through to a lower-priority rule. The spec text
   states the semantics; the audit script re-runs in CI-time against a grown corpus.
3. **Emit byte-identity is a new five-binding canonicalization surface.** Ordering is pinned
   (§7.5.5) and the idempotency property runs in all five bindings, but canonical-bytes bugs
   are historically where bindings drift first (see §9.6.4 rule 5's history).
4. **Flatten registry machinery is new in all five bindings.** The dedup/rename rules are
   specified (§7.6) and fixture-pinned, but flatten previously never touched templates at all.
5. **Runtime effect unmeasured.** This trades a 45,415-node per-cell tree for smaller bodies
   plus indirection. Plausibly a net win on instruction cache — a prediction, not a result.
6. **Saturation with N** (v1 risk 5, kept for the record): boundary classes per axis do not
   grow with N, so per-build template count saturates near 689 while cells grow; build cost may
   be roughly resolution-independent, making 7×7×7 near worst-case per cell. It would not make
   this RFC wrong — the fixed cost is ~3 min at 2 species and unbuilt at 12.

## 12. How to verify

**Reproduce the measurements.** Vary only the axes carrying a flux divergence on the 7×7×7
`transport_3d` stack; count spine templates at the `_BuildMemo()` construction in
`_build_branch_template` (stencil.jl), and `_compile` hits/misses at compile.jl. Two traps
produced wrong answers during this investigation:

- **Measure every spine, not the first.** The first spine built is the trivial `m` continuity
  equation (231 positions at 1 axis, 437 at 3). Mistaking it for a PPM spine understates spine
  size ~40×.
- **`load+flatten` costs ~17 s whether or not the rules match**, and a cold process pays a fixed
  ~17 s JIT floor. Neither is evidence about lowering — subtract both before comparing builds.

**Gate the change.** Three gates, in order:

1. **The bridge:** `Expand(load_B(fixture))` structurally equals the existing `expanded*.esm`
   golden, for every expression-template fixture, in all five bindings. This ties Option B to
   Option A semantics using the goldens we already have.
2. **The round trip:** `emit ∘ load` is a byte-wise fixed point on every fixture (R1's
   property test), all five bindings, and the new `emitted.esm` goldens agree across bindings.
3. **The build:** out-of-line compilation must be bit-identical — build both ways and compare
   the solved state vector exactly. (The hash-consing prototype was validated this way —
   `CHECKSUM=3384.89671520359`, `prof_lon_lat.esm`, 1029 states.) `ESS_STENCIL_DISABLE=1`
   already forces the per-cell fallback for differential testing; the compile-once path gets
   the same escape hatch and the same differential test.

**Commit the fixtures.** The `prof_*.esm` measurement stack exists only outside the repo; it
must land under `tests/` (or a `bench/` sibling) with this change, or gate 3 is not
reproducible by anyone else.
