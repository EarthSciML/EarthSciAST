# RFC — In-file AST templates for repeated Expression patterns (v2)

**Status:** Draft v2 (revised after fury's 2026-04-28 review of v1 / esm-ylm)
**Bead:** esm-adb (this revision); esm-ylm (closed v1 review)
**Affects spec version:** 0.3.0 → 0.4.0 (additive; same version bump as esm-jcj if both land together)
**Scope:** Schema mechanism only; no language-binding work in this RFC. Implementation lives in esm-giy.

---

## 1. Motivation

Large reaction-system `.esm` files contain hundreds of inline rate
expressions that share a small set of canonical functional forms — Arrhenius
(`k = A · exp(−Ea / T)`), Troe pressure-dependent fall-off, and JPL
temperature-dependent variants. Today the only mechanism in the schema is
to inline the full Expression AST per reaction. At repetition counts in the
hundreds, that costs file size, visual signal-to-noise, and any
compile-time guarantee that two reactions are "the same form" with
different scalar parameters.

This RFC proposes a bounded in-file mechanism for factoring repeated
**deep-AST operation patterns** within a single component, while
preserving dsc-acj's anchor principle that math stays in the `.esm`
(not in per-language runtime code).

### 1.1 Out of scope (and why)

This RFC does **not** address:

- **Repeated single-`fn`-node operations** (`interp.linear`,
  `interp.bilinear`, etc.). These are already opaque single nodes by
  §9.2 design — the spec deliberately collapsed them into one node to
  avoid alias-elimination blowup in symbolic-rewriting bindings. Wrapping
  a one-node call in a template is indirection at zero authoring win.
- **Repeated *data*** (sampled tables, photolysis flux slabs, axes that
  recur across tables). That is data-shaped repetition, not AST-shaped
  repetition; it is the subject of esm-jcj (sampled function tables).
  The fastjx pattern is solved there, not here.
- **Cross-component / library-style template sharing.** Top-level
  templates and template files importable across components are deferred
  to a follow-up RFC if demand emerges.
- **Computed templates, recursive templates, or templates that call other
  templates.** Bodies are fixed Expression ASTs with parameter
  substitution slots; no metaprogramming.

This narrowing is the v1 design. v2 may reopen any of these once the
mechanism is real and the limitations are felt.

---

## 2. Reconciling with `esm-spec.md` §1.1 (REQUIRED principle update)

`esm-spec.md` §1.1 ("Authoring Policy") is broader than §9.1's
closed-function-registry rule. It is a stance that the `.esm` is a **flat**
description, not a programmable one. An `expression_templates` block
introduces a new declaration kind whose purpose is to be referenced by
name elsewhere in the file. That is structural, not "just another op",
so this RFC cannot stand on the §9.1 principle alone.

**The §1.1 update this RFC depends on, stated normatively:**

> **Authoring policy: AST first, registry second, factoring third.**
>
> 1. *AST first.* The closed AST op set in §4 is the primary authoring
>    surface. New mathematics SHOULD be expressible as a finite tree of
>    existing ops.
> 2. *Registry second.* Operations that genuinely cannot be written as
>    AST trees (tabulated lookups, iterative solves, platform adapters)
>    use the closed `fn`-op registry per §9.1; addition is normative
>    spec work, not authoring.
> 3. *Factoring third.* Within a single component, an author MAY name a
>    fixed Expression AST tree as an `expression_templates` entry and
>    reference it elsewhere by name with parameter substitution.
>    Factoring is **not** programming: bodies are fixed AST trees,
>    parameters are pure-syntactic substitution slots, no recursion, no
>    cross-template calls, no metaprogramming.
>
> Mechanisms that require any capability beyond fixed-tree parameter
> substitution (conditional includes, generated definitions, computed
> bindings) are out of scope and require a separate RFC that revisits
> §1.1.

This explicit principle update is the gating change that opens the door
for templates *and* fences off every future "but my proposal isn't so
different from templates, so it's fine" argument.

---

## 3. Concrete repetition the RFC solves

### 3.1 In-tree precedent (downstream rig)

The canonical real-world example is the GEOS-Chem full-chemistry gas-phase
reaction system. It does not currently live in the ESS rig — it lives in
the sibling EarthSciModels rig at
`components/gaschem/geoschem_fullchem.esm` (57,628 lines,
`reaction_systems.GEOSChemGasPhase`).

**Concrete repetition counts (measured 2026-04-28):**

| Pattern | Reaction count | What the AST looks like |
|---|---:|---|
| Total reactions in `GEOSChemGasPhase` | 819 | — |
| Simple rates (no `exp`) | 331 | constants, products, and divisions only |
| **Single-`exp` Arrhenius** (`A · exp(B/T) [· num_density]`) | **398** | one `exp` node wrapping `B/T` divided by `T` |
| **Two-`exp` rates** (Arrhenius + correction or sum-of-Arrhenius) | 70 | two independent `exp(B/T)` factors / sums |
| Three-`exp` rates (fall-off / equilibrium with side terms) | 3 | three `exp` nodes |
| Four-/five-/six-`exp` rates (Troe, JPL pressure-dependent, equilibrium fall-off) | 4 / 8 / 5 | nested fall-off forms |

That is **398 reactions where the rate AST is structurally one of:**

```json
{"op": "*", "args": [
  <A>,
  {"op": "exp", "args": [{"op": "/", "args": [<-Ea>, "T"]}]},
  "num_density"
]}
```

— differing only in the scalar `<A>` and `<-Ea>` constants — **plus 90
more reactions where the rate AST is a fixed shape parameterized by a
small handful of scalar constants** (Troe / JPL fall-off forms repeat
the same nested structure across reactions, with kinf, k0, and Fc
parameters varying per reaction).

In raw counts: out of 819 reactions, **488 use a kinetic AST shape that
recurs across the file**. That is the repetition this RFC reduces.

**Concrete examples** (extracted from `geoschem_fullchem.esm`):

- A canonical single-`exp` Arrhenius rate AST that recurs ~398 times:
  `{op:"*", args: [A, {op:"exp", args:[{op:"/", args:[B, "T"]}]}, "num_density"]}`
  — with the v1 templates mechanism, this is a single
  `apply_expression_template` reference per reaction with bindings
  `{A: <const>, Ea: <const>}`.

- A canonical multi-`exp` H₂O₂-formation pattern (the `exp3` pattern in
  the file): four nested `exp(B/T)` terms with seven scalar parameters,
  repeating a sum-of-Arrhenius + water-vapor-correction shape. This is
  the kind of 4–10 node AST that benefits most from naming.

### 3.2 Cross-rig status and v1 acceptance

`components/gaschem/` is **not** in the ESS rig at HEAD. The downstream
file is informational evidence of the repetition pattern and the design
target. v1 acceptance does **not** require migrating that component into
ESS. Per fury's review (esm-ylm §7), an **ESS-internal authoring fixture**
exhibiting the same canonical kinetic-form repetition is sufficient
evidence the schema works.

The fixture v1 acceptance criterion is therefore:

- A new fixture under `tests/valid/` (or equivalent) declaring a small
  reaction system (5–10 reactions) that uses
  `apply_expression_template` against a 2–3 entry `expression_templates`
  block (one Arrhenius template, optionally one fall-off template).
- Numeric agreement across all five bindings on this fixture (Julia,
  Python, Rust, TypeScript, Go).
- Round-trip `load → save` produces fully-expanded ASTs (Option A,
  see §4).

Real-world 500+ repetition migrations live downstream in EarthSciModels
and are out of scope for this ESS RFC.

---

## 4. Round-trip semantics — Option A (always-expanded), normatively

**The v1 round-trip model is Option A: parse-time expansion. There is
no Option B in v1.**

**Normative rules:**

1. **Expansion happens at load.** Loaders MUST expand
   `apply_expression_template` to a fully-substituted Expression AST
   before any validator, evaluator, doc generator, or `esm-write` sees
   the tree. After load, downstream code operates on a normal Expression
   AST — it MUST NOT branch on whether a node was produced by template
   expansion.

2. **Round-trip emits the expanded form.** The canonical AST stored on
   disk after `parse → emit` is the expanded form. Source `.esm` files
   that author with `expression_templates` and `apply_expression_template`
   are the **source of truth**; the emitter does not re-derive template
   references from an expanded AST.

   **Authoring convention:** authors who want to preserve template
   references keep the source `.esm` in version control. The emitter is
   a one-way operation from the author's perspective — round-trip is
   for canonicalization, not for editing.

3. **Pure syntactic substitution.** Every parameter occurrence in the
   body is replaced by the bound argument's AST in source order.
   Expansion MUST NOT depend on argument evaluation. This forecloses
   any "lazy template" or "macro-with-eval" drift.

4. **Validators run on the expanded form.** Schema validation, type
   checks, and domain checks (every check defined in §4 / §9 of the
   spec) run on the expanded AST. Error messages reference expanded
   AST locations; bindings MAY additionally surface the source
   `apply_expression_template` site as context, but the canonical
   diagnostic location is post-expansion.

5. **Caching is a pure optimization.** Bindings MAY structural-hash on
   `(template_id, bindings)` and cache the expanded AST, but the cached
   AST MUST be structurally identical (same op tree, same constants
   bit-equal) to a fresh expansion. Bindings MAY skip caching entirely.
   Caching MUST NOT be observable to consumers.

**Why Option A and not Option B:** preserving source form on round-trip
requires every binding to track unexpanded ASTs internally alongside
the expanded form, and to re-fold expanded trees into source form on
emit. That is real cost across five bindings, for a benefit (round-trip
preserves authoring intent) that authors already get by keeping the
source `.esm` in version control. v2 may revisit if there is
demonstrated demand.

---

## 5. The `expression_templates` block

### 5.1 Declaration

`expression_templates` is declared **inside a single `model` or
`reaction_system`**. It is a JSON object whose keys are template names
and whose values are template definitions:

```json
"expression_templates": {
  "arrhenius": {
    "params": ["A", "Ea"],
    "body": {
      "op": "*",
      "args": [
        "A",
        {"op": "exp", "args": [{"op": "/", "args": [{"op": "-", "args": ["Ea"]}, "T"]}]},
        "num_density"
      ]
    }
  }
}
```

**Required fields:**

- `params`: array of parameter names (strings). Must be unique within
  one template. Each name is a placeholder occurring zero or more times
  in `body`.
- `body`: a normal Expression AST. Parameter occurrences are written as
  the bare parameter name string in any position where a variable
  reference would appear.

### 5.2 Reference

Reactions (or any expression position within the same component)
reference templates via a new Expression op:

```json
"rate": {
  "op": "apply_expression_template",
  "name": "arrhenius",
  "bindings": {"A": 1.8e-12, "Ea": 1500}
}
```

**Required fields on `apply_expression_template`:**

- `name`: string; must match a template declared in the same component.
- `bindings`: object mapping each parameter in the template's `params`
  to a value. Values MAY be:
  - numeric literals,
  - variable name references (strings),
  - arbitrary Expression ASTs (full subtrees).

### 5.3 Constraints

These constraints are normative; bindings MUST reject violations at
load.

1. **AST → AST only.** Templates take Expression args, produce an
   Expression. No string interpolation, no schema-level substitution,
   no metaprogramming.
2. **No control flow, no recursion, no template-calls-template.**
   Body is a fixed AST tree. The body MAY internally use `ifelse`,
   `min`, `max`, etc. — those are evaluated post-expansion as normal
   Expression nodes; they are not interpreted by the template
   mechanism. The body MUST NOT contain
   `apply_expression_template` itself (no template-calls-template).
3. **Typed signatures (positional-by-name).** Schema validates that
   every entry in `params` has a value in `bindings` and that
   `bindings` contains no extras. (Per-param type tags — `Number`
   vs. `Expression` vs. `ArrayRef` — are deferred to v2.)
4. **Component-local scope.** Templates declared inside one
   `model` / `reaction_system` are visible only within that
   component's expression positions. Top-level templates and
   cross-component sharing are out of scope (deferred to v2 RFC if
   needed).
5. **Pure syntactic substitution.** See §4 rule 3.
6. **Determinism.** Two fresh expansions of the same
   `(template_id, bindings)` pair MUST produce structurally identical
   ASTs (same op tree, bit-equal constants). This is required by §4
   rule 5 and pinned here for reviewer ease.

### 5.4 Spec-version gate

`expression_templates` and `apply_expression_template` arrive at
`esm: 0.4.0`. Files declaring `esm: 0.3.0` or earlier MUST reject any
file that uses either construct.

---

## 6. Compatibility / migration

- **Additive.** Templates do not change the meaning of any existing
  `.esm` file. Files that don't use `expression_templates` are
  unaffected.
- **No required migration.** Existing inline ASTs continue to work.
  Conversion is an authoring choice, not a requirement.
- **No mechanism-source migrators in v1.** A KPP → `.esm` migrator (or
  similar) is a separate work item. Land the schema mechanism first;
  migrators can follow downstream.

---

## 7. Implementation impact (for esm-giy, not this RFC)

- **Schema:** add `expression_templates` block to model /
  reaction_system schema; add `apply_expression_template` to the
  ExpressionNode `op` enum with `name` (required) + `bindings`
  (required object) fields; add expansion-time validator (every
  `params` entry must have a `bindings` value, no extras).
- **All five bindings:** add an expansion pass at load, before
  `_parse_expr` / equivalent. Cache expanded ASTs structurally per §4
  rule 5. After load, downstream code is unchanged — it sees a normal
  Expression AST.
- **Doc generator:** render template definitions on the component page
  as a separate section; render reaction rates **in source form by
  default** (template name + bindings table), with the expanded form
  available behind a toggle. (This is downstream of schema; not v1
  acceptance for this RFC.)
- **Spec text:** add the §1.1 "factoring third" principle update
  per §2 of this RFC.

---

## 8. Acceptance for v1

- §1.1 spec text updated to "AST first, registry second, factoring
  third" per §2 of this RFC.
- Schema accepts a `.esm` file declaring `expression_templates` and
  using `apply_expression_template`; rejects same file when `esm`
  version < 0.4.0.
- All five bindings (Julia, Python, Rust, TypeScript, Go) load and
  expand `apply_expression_template` correctly.
- Numeric agreement across all five bindings on the in-tree fixture
  exercising `apply_expression_template` (per §3.2).
- Round-trip (`load → save`) emits expanded ASTs; reading back the
  emitted file produces an identical AST.
- An ESS-internal authoring fixture under `tests/valid/`
  (or equivalent) demonstrates the canonical pattern with 5–10
  reactions and 2–3 template entries (per §3.2).

**Not v1 acceptance criteria** (deliberately excluded):

- Migrating `geoschem_fullchem.esm` (or any other downstream
  reaction system) into the ESS rig.
- File-size win measurements on `geoschem_fullchem.esm` in the
  ESS rig.
- A KPP → `.esm` migrator.
- Doc generator rendering of template references (downstream of
  schema; not gating).

---

## 9. Open questions (deferred, not blocking v1)

The following are intentionally **not** part of the v1 acceptance
criteria. Each is a v2 candidate.

- **Per-param type tags.** Currently any parameter accepts any AST.
  Tagging `params` with `Number` / `Expression` / `ArrayRef` would
  let the schema reject some authoring errors at load. Defer.
- **Top-level / cross-component templates.** Library-style template
  sharing across components is a real ergonomic want once the
  v1 mechanism is in use. Defer.
- **Round-trip preservation (Option B).** If demand emerges to
  preserve template references on round-trip, revisit §4. Defer.
- **Doc generator policy.** Default-source-form vs. default-expanded
  is an authoring/reviewer-experience decision. Pin in a follow-up
  once the doc generator is in use.

---

## 10. References

- esm-ylm (closed) — v1 RFC + fury's 2026-04-28 review with the
  five blocking items addressed in this v2.
- esm-jcj — sampled function tables RFC (the *data*-shaped
  repetition mechanism; orthogonal to this RFC).
- `esm-spec.md` §1.1 — authoring policy (updated by §2 of this RFC).
- `esm-spec.md` §4 — closed AST op set.
- `esm-spec.md` §9.1 — closed `fn`-op registry.
- `esm-spec.md` §9.2 — `interp.linear` / `interp.bilinear` opaque
  single-node design (the reason §1.1 of this RFC excludes
  single-`fn`-node templates).
- `dsc-acj` — "math stays in the `.esm`" anchor principle (informal
  precedent cited in v1; substantive argument unchanged here).
- Downstream precedent:
  `EarthSciModels/components/gaschem/geoschem_fullchem.esm` —
  57,628 lines, `GEOSChemGasPhase` reaction_system, 819 reactions
  with 488 using a recurring kinetic-AST shape (§3.1 measured
  2026-04-28).
