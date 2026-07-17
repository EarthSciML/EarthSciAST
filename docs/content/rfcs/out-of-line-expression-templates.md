# RFC — Out-of-line expression templates

**Status:** Draft (measurements are reproducible; the change is not yet prototyped)
**Bead:** (unassigned)
**Affects spec version:** §9.6 / §9.7.3 expansion *timing*. Wire format **unchanged**.
**Scope:** When a template instantiation is expanded. No new op, no new document section,
no per-binding semantics, no rule-authoring change, no `.esm` edits.

---

## 1. Proposal

**Stop inlining expression templates at load. Keep the reference, and compile each distinct
template body once.**

That is the whole RFC. Everything below is why it is necessary, why it is sound, and what
it costs.

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
templates; the discretization library is a template-library file (§9.6.1 / §9.7.1).

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
varying only WHICH AXES carry a flux divergence. Uncontended, Julia 1.12.6. Method traps in §8.

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

**7+7+7 replaces 7×7×7.** It moves the exponent, not a constant — see §7 for what does not.

## 6. Why this is a small change, not a new language

- **No new syntax.** Template definition and reference already exist (§9.6, §9.7).
- **No new semantics.** A reference to a fixed AST body with substituted parameters is *defined*
  to equal the inlined body. There is nothing to specify that is not already specified.
- **§9.6's own guarantees are the preconditions.** "Factoring is **not** programming" — fixed
  bodies, purely syntactic parameter slots, acyclic, no recursion, no metaprogramming — is
  exactly what makes compile-once-reference-many sound. A language with recursion or
  metaprogramming could not do this safely; this one can, by construction.
- **Wire format unchanged.** ESD and every authored `.esm` are untouched.
- **This is not esm-tzp.** `closed-function-registry.md` removed `registered_functions` because
  they called **out** to handler code implemented per language binding — semantics outside the
  document, hence drift. An expression template's body **is** Expression AST, in the file,
  canonically serializable, evaluated by machinery every binding already has:

  | kind | semantics live in | status |
  |---|---|---|
  | **Closed functions** (`fn`: `interp.*`, `datetime.*`) | the **spec** (§9) | current |
  | ~~Registered functions~~ (external handler IDs) | each **binding** | removed (esm-tzp) |
  | **Expression templates** (§9.6) | the **document** | current — but inlined away |

  §1's "no per-file declaration of new functions" governs the §9 closed registry and `fn` nodes.
  It does not touch §9.6, which *is* a per-file declaration of named AST.

### 6.1 What does change

Expansion **timing** in §9.6/§9.7.3, and therefore the lowered AST: template references survive
where copies used to be. **Every AST golden changes.** That is the real cost of this RFC and
should not be understated.

### 6.2 Open design questions

1. **Keyed by what?** Two instantiations share a compiled body only if their parameter *shapes*
   agree. Parameters bound to per-cell indices differ per use site; parameters bound to whole
   fields do not. The equivalence key needs a precise definition — this is the crux of the work.
2. **`match`-driven rules.** A rewrite rule instantiates its template at match sites (§9.6.3).
   Does the reference survive the rewrite, or only match-less body references (§9.7.3)?
3. **Metaparameter folding** (§9.6.4 / §9.6.8) folds region bounds at binding sites. Folded
   variants are distinct bodies; how many survive is unmeasured.
4. **Downstream identity.** §4c guarantees it builds the same `_VecKernel`s as the per-cell path,
   including lane↔out-slot pairing and first-seen order. Out-of-line instantiation must preserve
   that, or the differential test (`ESS_STENCIL_DISABLE=1`) will say so.

## 7. Alternatives, and the measurements that rejected them

Recorded so they are not re-tried. Each was pursued; none survived contact with a measurement.

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

## 8. Risks

1. **The ~21-body estimate is structural, not measured.** It follows from the measured
   cross-product (15 → 99 → 689) and the measured 1-axis spine (6,228 objects), but no
   out-of-line build exists yet. Largest uncertainty here.
2. **Golden churn.** §6.1.
3. **Runtime effect unmeasured.** This trades a 45,415-node per-cell tree for smaller bodies plus
   indirection. Plausibly a net win on instruction cache — a prediction, not a result.
4. **Ghost factor.** `689 ≈ 2 × 343` implies ~2 ghost patterns per class-combination; whether
   ghost patterns factor per-axis is unverified.
5. **Urgency, not validity.** Boundary classes per axis do not grow with N, so templates saturate
   near 689 while cells grow: build cost may be roughly *independent of resolution*, making
   7×7×7 near worst-case per cell. **Untested** (needs `transport_3d` at N≥12; the hybrid
   coefficients and analytic fields are sized for 7 levels). It would not make this RFC wrong —
   the fixed cost is ~3 min at 2 species and unbuilt at 12 — but it is the cheapest thing on this
   page to check, and it belongs in the decision.

## 9. How to verify

**Reproduce the measurements.** Vary only the axes carrying a flux divergence on the 7×7×7
`transport_3d` stack; count spine templates at the `_BuildMemo()` construction in
`_build_stencil_template` (stencil.jl), and `_compile` hits/misses at compile.jl. Two traps
produced wrong answers during this investigation:

- **Measure every spine, not the first.** The first spine built is the trivial `m` continuity
  equation (231 positions at 1 axis, 437 at 3). Mistaking it for a PPM spine understates spine
  size ~40×.
- **`load+flatten` costs ~17 s whether or not the rules match**, and a cold process pays a fixed
  ~17 s JIT floor. Neither is evidence about lowering — subtract both before comparing builds.

**Gate the change.** Out-of-line instantiation must be bit-identical, so the acceptance test is a
checksum: build both ways and compare the solved state vector exactly. (The hash-consing
prototype was validated this way — `CHECKSUM=3384.89671520359`, `prof_lon_lat.esm`, 1029 states.)
`ESS_STENCIL_DISABLE=1` already forces the per-cell fallback for differential testing; this
change should get the same escape hatch and the same differential test.
