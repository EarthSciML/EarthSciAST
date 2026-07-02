# RFC — Open operator namespace + fixpoint rewrite engine (grad/div/laplacian de-privileged)

**Status:** Draft (proposed changeset for review — no binding work done yet)
**Bead:** TBD (file on acceptance)
**Affects spec version:** 0.8.0 (rides *inside* the clean break; no compat shims)
**Scope:** `esm-schema.json` (+ 4 copies), `esm-spec.md` §4.2 / §9.6 / §9.6.8, conformance
fixtures, and follow-up work in all five bindings. Discretization *rules* are explicitly
**out of scope** — they live in `../earthscidiscretizations`.

---

## 1. Motivation

Two coupled defects in today's spatial-operator story:

1. **The privileged vocabulary doesn't close.** `grad`/`div`/`laplacian` are enum-blessed
   ops (`esm-schema.json:213-278`) that lower to stencils via `match` rewrite rules
   (§9.6.8). But a Godunov Hamiltonian, WENO flux, or flux-limited divergence is a
   *nonlinear compound* of derivatives — e.g. `sqrt(D(u,x)² + D(u,y)²)` upwinded — that is
   **not** `grad` of anything. The fixed vocabulary can name the easy cases and nothing
   else; the moment a scheme needs to match a compound term, the privileged ops are dead
   weight.

2. **The rewrite engine can't match a compound before its parts.** §9.6.3 pins rewriting
   to *one bottom-up pass in declaration order, bodies not re-scanned*. Bottom-up =
   innermost-first: the inner `D`/`grad` node lowers to a central-difference stencil
   **before** the enclosing Godunov pattern is ever visited, so the compound rule can
   never fire. This is true whether the inner token is `grad` or `D` — it is a
   *traversal-strategy* limitation, not a naming one.

The sibling `earthscidiscretizations` catalog already thinks in `D` (`Dx(u) "(= grad in
ESS)"`, `Dxy(u)`, `r⁻²·Dr(r²·Dr(u))`; `operators.md:83`: "match `D(q, wrt=t)` (or whichever
PDE op the scheme discretizes)"). It is waiting on the format to make spatial `D` the one
canonical primitive and to make the rewrite engine expressive enough to match compounds.

## 2. Summary of changes

| # | Change | Where |
|---|--------|-------|
| A | **Open the `op` namespace**: closed *evaluable-core* tier + open *rewrite-target* tier. Drop `grad`/`div`/`laplacian` from the enum. Add optional `attrs` for custom scalar fields. | schema |
| B | **Generalize `D`** to any differentiation variable (spatial `wrt`). A `D` (or any rewrite-target op) reaching evaluation is `unlowered_operator`. | schema + §4.2 |
| C | **Rewrite engine**: outermost-first traversal + explicit integer `priority` + **bounded fixpoint** + `unlowered_operator` gate. Replaces §9.6.3 constraint 2. | §9.6 |
| D | **Recast §9.6.8**: discretization is *ordinary rewrite rules matching spatial `D`*; the rule std-lib lives in `earthscidiscretizations`; `grad`/`div`/`laplacian` appear here **only as non-normative example sugar over `D`**, privileged in no way. | §9.6.8 |
| E | **§4.2 table**: remove `grad`/`div`/`laplacian` rows; generalize `D`. | §4.2 |

**Explicitly NOT done** (was "move 3" in review): this repo ships **no** default
discretization rules. `grad(u,x)` "just working" out of the box is a service of
`earthscidiscretizations`, not of the format.

---

## 3. Change A — open the `op` namespace

The evaluator already treats `grad`/`div`/`laplacian` as non-evaluable placeholders that
exist only to be rewritten (unmatched ⇒ hard error). Their *only* real privilege is the
schema enum. Remove it.

**`esm-schema.json` — `Expression.op` (was lines 210-279):**

```diff
   "op": {
     "type": "string",
-    "description": "Operator name.",
-    "enum": [
-      "+", "-", "*", "/", "^", "D", "ic", "grad", "div", "laplacian", "integral",
-      "exp", "log", "log10", "sqrt", "abs", "sin", ... , "apply_expression_template"
-    ]
+    "minLength": 1,
+    "description": "Operator name. TWO TIERS (esm-spec §4.2). (1) The CLOSED evaluable-core set — every binding's evaluator implements each one directly: arithmetic/comparison/boolean, the elementary functions, the calculus form-ops `D` and `ic` (LHS/structural only), and the array/query ops `aggregate`, `makearray`, `index`, `broadcast`, `reshape`, `transpose`, `concat`, `skolem`, `rank`, `argmin`, `argmax`, `intersect_polygon`, `polygon_intersection_area`, `fn`, `enum`, `const`, `Pre`, `ifelse`, `true`, `table_lookup`, `apply_expression_template`. (2) The OPEN rewrite-target tier — ANY other identifier (a spatial `D` on a right-hand side, or a user op such as `godunov_hamiltonian`). A rewrite-target op carries NO evaluator implementation; it MUST be eliminated by a rewrite rule (§9.6) before evaluation. The schema does not enumerate the open tier, so it cannot catch a typo'd op at validation time; the load-time lowering fixpoint does, rejecting any rewrite-target op that survives with `unlowered_operator`. The evaluable-core set above is the ONLY set the format privileges.",
+    "$comment": "The evaluable-core set is normative and closed; each binding pins it as its evaluator's op registry. It is documented (not enum-enforced) here so the open rewrite-target tier remains expressible."
   },
```

**Add an optional `attrs` object** to `Expression` (for custom scalar params on
rewrite-target ops, generalizing today's named `dim`/`side`/`wrt`/`var` slots):

```diff
+  "attrs": {
+    "type": "object",
+    "description": "Optional named scalar attributes for a rewrite-target op (open tier). Mirrors the role of the fixed `dim`/`side`/`wrt`/`var` slots for core ops, but is open: a custom op (e.g. `godunov_hamiltonian`) carries its scheme parameters here. In a rewrite rule's `match`, an `attrs.<key>` whose value is a bare param name binds that param to the matched literal (§9.6.1). Evaluable-core ops MUST NOT use `attrs`."
+  }
```

*Cost accepted:* opening the namespace removes the enum's typo-catch. That safety net moves
to the binding-level evaluable-core registry + the `unlowered_operator` gate (§Change C):
a bad op still cannot reach evaluation, the error just fires at lowering time, not schema
time.

## 4. Change B — generalize `D`; rewrite-target semantics

`D` stays evaluable-core, but only in its **structural** role (an equation LHS
`D(u) ~ rhs`, consumed by system assembly). A `D` node appearing inside an expression that
must be **evaluated** — any RHS, rate, or observed expression — is a **rewrite-target**: it
denotes a spatial/temporal derivative that a discretization rule must lower to an
`aggregate`/`makearray` stencil. `wrt` generalizes from `"t"` to any declared
differentiation variable (a spatial index-set axis, etc.).

**`esm-schema.json` — `wrt` field (was line 301-303):**

```diff
   "wrt": {
     "type": "string",
-    "description": "Differentiation variable for D operator (e.g., \"t\")."
+    "description": "Differentiation variable for the `D` op — the time variable `t` (structural, equation-LHS use) OR a spatial axis (e.g. \"x\", \"lon\"). A `D` with a spatial `wrt`, or any `D` in a right-hand-side expression position, is a rewrite-target (§9.6.8): it MUST be lowered to a stencil by a discretization rule before evaluation, else `unlowered_operator`."
   },
```

`dim` (was "Spatial dimension for grad operator") is retained only for the non-normative
`grad` example; its description is softened to "legacy alias field; prefer `D` with `wrt`."

## 5. Change C — rewrite engine: outermost-first + priority + bounded fixpoint

Replace §9.6.3 constraint 2 (the single-pass/bottom-up/declaration-order rule) with:

> **2. Outermost-first, priority-ordered, bounded-fixpoint rewriting.** Rule application is
> a sequence of **passes**. One pass is a single **pre-order (outermost-first)** walk of the
> Expression tree. At each node visited, the engine considers every `match` rule whose
> pattern structurally matches that node and selects the **winner deterministically**:
> highest `priority` (integer, default `0`); ties broken by **declaration order** (earliest
> wins). The winner's `body` is instantiated by pure structural substitution (§9.6, constraint
> 5) and replaces the node; the engine does **not** descend into the freshly-produced body
> during the current pass. If no rule matches a node, the walk descends into its children.
>
> Passes repeat until a pass performs **zero** rewrites (the fixpoint), or until
> `MAX_REWRITE_PASSES = 64` passes have run without converging, in which case the file is
> rejected with `rewrite_rule_nonterminating` (naming the last-rewritten node). The pass
> bound is the authoritative termination guard; a self-reintroducing rule now simply fails
> to converge rather than being detected statically. Because selection and traversal are
> fully deterministic, all five bindings MUST produce byte-identical fixpoints (or the same
> non-convergence rejection).
>
> **`priority` and compound precedence.** A rule that matches a *compound* term (e.g. a
> Godunov Hamiltonian `sqrt(add(pow(D(u,x),2), pow(D(u,y),2)))`) declares a higher `priority`
> than the plain per-derivative rule, so — under outermost-first selection — it fires on the
> whole compound **before** the inner `D(u,x)` is ever lowered. This is the author's explicit,
> portable choice; the engine never *infers* "most specific".

**Add `priority` to the rewrite-rule def** (`ExpressionTemplate`, schema `$defs` ~line 1659):

```diff
+  "priority": {
+    "type": "integer",
+    "default": 0,
+    "description": "Selection precedence for an auto-applied (`match`) rule. When multiple rules match one node, the highest `priority` wins; ties break by declaration order. Lets a compound-term rule (Godunov/WENO/flux-limited) out-rank the plain per-derivative rule so it fires on the whole compound first. Ignored when `match` is absent."
+  }
```

**Add the `unlowered_operator` gate.** After the fixpoint converges, the loader walks the
final tree; any node whose `op` is not in the evaluable-core registry (this includes a
spatial `D`, or a `D` in any RHS position) is rejected with a new stable diagnostic:

| Code | Meaning |
|---|---|
| `unlowered_operator` | A rewrite-target op survived the lowering fixpoint into an evaluation position (no rule eliminated it). Names the op and node path. Generalizes today's grad-unreachable error. |

*(This supersedes the per-language `E_TREEWALK_UNREACHABLE_SPATIAL_OP` /
`UnreachableSpatialOperatorError` / `UnsupportedDimensionalityError` codes with one uniform
code.)*

## 6. Change D — recast §9.6.8 (no privileged ops, no shipped rules)

Rewrite §9.6.8 so it describes the **mechanism** and disclaims the vocabulary:

> #### 9.6.8 Discretizing spatial derivatives (rewrite rules over `D`)
>
> A spatial derivative — a `D` op with a spatial `wrt`, on a right-hand side — is a
> **rewrite-target** (§4.2): it has no evaluator and must be lowered to an
> `aggregate` + `makearray` stencil by a `match` rewrite rule (§9.6) before evaluation. As
> with `grad` historically, **the boundary conditions live inside the rule**: the body is a
> single `makearray` whose interior region is the stencil `aggregate` and whose boundary-face
> regions encode the BC (later regions overwrite earlier, §4.3.2). There is no
> boundary-condition construct anywhere else.
>
> **Choosing a scheme = choosing a rule** (central, upwind, WENO, Godunov, a specific BC),
> and a compound scheme out-ranks the plain per-derivative rule via `priority` (§9.6.3).
>
> **This format ships no discretization rules.** The standard library of finite-difference /
> finite-volume rules (and their conformance golden) lives in
> [EarthSciDiscretizations](../earthscidiscretizations). A `.esm` file obtains discretization
> either by declaring in-file `expression_templates` with `match` on `D`, or by composing
> with rules that library provides.
>
> **`grad`/`div`/`laplacian` are not privileged** — they are not evaluable-core ops and the
> format ships no rules for them. They exist only as *optional author sugar*, and are
> definable by a one-line rewrite rule, e.g.:
>
> ```json
> "grad_is_Dx": {
>   "params": ["f"],
>   "match": { "op": "grad", "args": ["f"], "dim": "x" },
>   "body":  { "op": "D",    "args": ["f"], "wrt": "x" }
> }
> ```
>
> after which the ordinary `D`-discretization rules apply. `div`/`laplacian` are sugar for
> sums/compositions of `D` (`div(F)=ΣᵢD(Fᵢ,xᵢ)`, `laplacian(u)=ΣᵢD(D(u,xᵢ),xᵢ)`); the
> bounded fixpoint (§9.6.3) lowers the resulting nested `D`s in subsequent passes. A rule
> author MAY instead match `laplacian` directly and emit a one-shot 5-point stencil — the
> open namespace permits either.

Also strike the "**Bindings ship default built-in rules …, so a file MAY use
`grad`/`div`/`laplacian` with no in-file rules**" sentence at the end of the current §9.6.8
(and the parallel claims at spec lines 2261, 2353, 2462, 2681, 2866-2883) — no built-in
defaults exist any more.

## 7. Change E — §4.2 operator table

- **Remove** the `grad`, `div`, `laplacian` rows (lines 133-135). (`integral` — see Open
  Questions.)
- **Generalize `D`** (line 131): `wrt` may be `t` (structural LHS) or a spatial axis
  (rewrite-target RHS, §9.6.8).

---

## 8. Conformance fixtures

Under `tests/conformance/expression_templates/` (mechanism only — real schemes stay in
`earthscidiscretizations`):

1. **`godunov_beats_inner_deriv/`** — a compound `sqrt(D(u,x)²+D(u,y)²)` with a `priority:100`
   rule matching the whole compound → a marker stencil, and a `priority:0` central-difference
   `D` rule. Assert across all five bindings that the compound rule fires (the inner `D`s are
   **not** independently lowered). This is the anti-regression for defect #2.
2. **`fixpoint_nested_deriv/`** — a `laplacian`→`D(D(·)) + D(D(·))` sugar rule plus a
   `D(D(f,x),x)`→stencil rule; assert convergence in exactly 2 passes and an identical final
   tree everywhere.
3. **`nonterminating_rewrite/`** — a self-reintroducing rule; assert `rewrite_rule_nonterminating`
   at the `MAX_REWRITE_PASSES` bound in all five bindings.
4. **`unlowered_operator/`** — a spatial `D` with no matching rule; assert `unlowered_operator`.

---

## 9. Migration & binding work (post-approval)

- **Schema:** apply Change A/B to `esm-schema.json` and the 4 byte-identical copies
  (`packages/{EarthSciSerialization.jl/data,earthsci-toolkit-rs/src,esm-format-go/pkg/esm,earthsci_toolkit/src/earthsci_toolkit/data}/esm-schema.json`).
- **Bindings (all five):** rewrite engine → outermost-first + `priority` + bounded fixpoint;
  add the evaluable-core registry + `unlowered_operator` gate; generalize `D`'s `wrt`.
- **Fixture audit — low risk:** files that **bring their own** `match` rules for
  `grad`/`div`/`laplacian` (e.g. the advection fixture's in-file `central_grad_*` rules)
  keep working unchanged — `grad` is now just a legal open-tier op string their own rules
  match. Only files that relied on **built-in default** rules break; grep confirms whether
  any conformance fixture did (the advection & wildfire fixtures BYO their rules, so expected
  impact ≈ zero). Re-run the full `pde_simulation_pipeline` gate after the engine change,
  since outermost-first + fixpoint can in principle change a lowering that previously relied
  on bottom-up single-pass.
- **`earthscidiscretizations`:** unblocked to un-archive its `D`-matching rule catalog; no
  change required *by* this RFC, but it becomes the home for what used to be "built-in
  defaults".

## 10. Resolved decisions

All four settled with the author (2026-07-02); folded into the changes above:

1. **`integral` folds into the open tier** — same rationale as grad/div/laplacian. The
   dropped enum removes it automatically; §4.2 now lists it among the rewrite-target sugar.
2. **`attrs` added now** (Change A) — avoids a second schema break when a scheme needs a
   custom scalar field.
3. **`MAX_REWRITE_PASSES = 64`** confirmed as the pinned cross-binding constant.
4. **Permissive `op` `pattern`** added (`^([A-Za-z_][A-Za-z0-9_.]*|[-+*/^<>=!]+)$`) — rejects
   malformed strings without closing the namespace; the load-time gate remains the guard for
   unknown-but-well-formed ops.

## 11. Status

- **Schema (Change A/B): DONE** — `esm-schema.json` edited and propagated byte-identical to
  all 5 copies; well-formed under draft 2020-12; all sampled valid fixtures still validate;
  no invalid fixture regressed (none relied on the op enum).
- **Spec (Change C/D/E): DONE** — §4.2 two-tier note + generalized `D` + sugar demotion;
  §9.6.3 constraint 2 rewritten (outermost-first + priority + bounded fixpoint) + new
  constraint 6 (post-fixpoint gate); §9.6.6 gains `rewrite_rule_nonterminating` +
  `unlowered_operator`; §9.6.8 recast (external std-lib, `D`-based example, grad-sugar
  example); stale "built-in default rules" claims struck.
- **Fixtures + 5 bindings: PENDING** — the large lift; see §8–9.
