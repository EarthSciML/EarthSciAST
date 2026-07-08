# Verification Review — RFC Discretization v2.1

> **SUPERSEDED (v0.8.0 clean break).** The bespoke discretization / spatial-grid machinery this document concerns was removed from the schema in v0.8.0; grid geometry and discretization are now expressed as `aggregate` Functional Aggregate Query nodes (see `semiring-faq-unified-ir.md`). Retained for historical context only.


**Reviewer:** polecat `thunder` (no prior authorship or review of this RFC)
**Document:** `docs/rfcs/discretization.md`, 2079 lines, v2.1 (§17.1 addenda; landed via commit 26f73a83 / gt-woe1)
**Prior reviews verified against:** `docs/rfcs/discretization-review-v2.md` (gt-j6do, brahmin) and `docs/rfcs/discretization-review-v2-parallel.md` (gt-adhm, ghoul)
**Bead:** gt-xirj
**Date:** 2026-04-18
**Scope:** narrow — verify §17.1's F1–F10 closure claims against the sections they cite, check for regressions, nothing else.

---

## Summary

v2.1 lands concrete, normative text for every F1–F10 item. The ten blocking fixes are not gestured at — they produce enumerated tables, closed enums, error-code strings, and worked examples. The architectural direction is unchanged; v2.1 is a targeted editorial round on top of v2.

**Verdict:** v2.1 is Step-1-ready, with two small inconsistencies flagged below that do not gate Step 1 acceptance. One mislabeled "Resolves" claim in §17.1 should be corrected for honesty but the underlying status is already covered correctly in the deferred-items list.

---

## Per-F-item verdict

| F-item | Cites | Verdict | Notes |
|---|---|---|---|
| **F1** §7.3 MPAS worked example | §7.3 + §7.1.1 chooser | **Resolved** | Lowered `arrayop` at L1079–1094 is base-spec-conformant: `output_idx: []`, `ranges: {"k": [0, <expr>]}` pair form, `reduce: "+"` string, explicit `args` list. `$target` binds to `c` via the §7.1.1 `emits_location`-first chooser; every `index` into an edge field uses `index(edgesOnCell, c, k)`, never bare `$target`. Self-validation note at L1096–1123 requires the conformance fixture to JSON-schema-validate against base-spec `arrayop`. Closes gt-j6do **New C2** and gt-adhm **C2**. |
| **F2** §5.4.6 number formatting | §5.4.6 | **Resolved** | Normative adoption of RFC 8785 JCS §3.2.2.3 (L449–455). Explicit rules for integer-valued floats (L458–472), shortest round-trip non-integer floats (L473–478), exponent breakpoints (L479–483), positive/negative zero including `-0` float spelling (L484–487), subnormals (L488–492), and NaN/Inf rejection with error code `E_CANONICAL_NONFINITE` (L493–502). §5.4.4 also adds the type-preserving identity-elimination rule (L414–425) that fixes gt-j6do New C1(c)'s `*(1.0, x) → x` type-loss. Closes gt-j6do **New C1** and gt-adhm **C1**. |
| **F3** §7.1.1 `$target` + dim→component | §7.1.1 | **Resolved** (mostly — one mis-scoped claim) | §7.1.1 now carries: the `emits_location`-first chooser for unstructured grids (L892–906), operand-via-connectivity convention (L908–916), `k_bound` as a second in-scope reserved local index (L918–933), five cartesian component names `i,j,k,l,m` with explicit spec-bump requirement beyond 5 dims (L931–935), `dimensions.indexOf` mapping (L937–945), and `dim` overloading rationale for unstructured grids (L953–962). Closes gt-adhm **C2, C3, M4, M7** and gt-j6do **new-m1, new-m7**. ⚠ The addendum text also claims F3 "Resolves gt-j6do **New M3**"; this is not accurate — see *Flag 1* below. |
| **F4** §7.2.1 expansion protocol | §7.2.1 | **Resolved** | Five-step protocol enumerated (L993–1028): rule match → scheme selection → `applies_to` guard check (guard-only, no rebinding) → name-aligned binding flow (no implicit rename; missing bindings raise `E_SCHEME_MISMATCH`) → expansion. Pattern-variable dominance rule from rule over scheme explicitly stated (L1007–1009). `applies_to` depth fixed at 1 (L1030–1034). "No second pass" clause (L1036–1039). Closes gt-adhm **C4** and gt-j6do **new-m6, m8**. |
| **F5** §5.2.5 post-rewrite walker | §5.2.5 | **Resolved** | Option (a) pinned normatively (L246–253) with options (b) and (c) explicitly called out as non-conforming. Cross-pass re-entry permitted (L255–257). `max_passes = 32` justification added (L259–264): 2× deepest MVP scheme chain. `rules` ordering rule covering both map (insertion order) and array forms (L266–273). Closes gt-adhm **C5** and gt-j6do **open question 4, m7**. |
| **F6** §5.4.7 `-`, `/`, `neg` canon | §5.4.7 | **Resolved** | Binary `-` kept distinct, non-commutative, non-flattening (L534–542); binary `/` same (L555–562). Unary `neg` canonical form pinned, including numeric-literal absorption (`neg(5) → -5` literal) and double-negation (L544–553). `/(0,0)` raises `E_CANONICAL_DIVBY_ZERO` (L560). Algebraic-only rewrites like `-(x,x)→0` and `/(x,x)→1` explicitly out of scope of canonical form (L540–542, L561–562). No new AST ops introduced (L564–568). Closes gt-adhm **M6**. |
| **F7** §5.3 / §7.2 `regrid.method` closed set | §5.3 | **Resolved** | Four-value enum table with normative semantics for `nearest`, `bilinear`, `conservative`, `panel_seam` (L337–342). `E_UNKNOWN_REGRID_METHOD` at load time (L333–335). Emitter discipline pinned at L348–365: `panel` selectors emit `panel_seam` fixedly; couplings supply method via `coupling.<c>.regrid_method` (§10.1, L1388); literal author-supplied `regrid` validates at parse time. Closes gt-adhm **M1** and gt-j6do **open question 3**. |
| **F8** §9.2.1 worked periodic BC | §9.2.1 | **Resolved** | Canonical-side declaration rule (xmin preferred; pair implicit, L1270–1276). Full 1D advection fixture with periodic wrap rule (L1278–1303) using `replacement`, not `use`, which also doubles as the example the §5.2 table had lacked (gt-j6do **new-m4**). Canonical-form output at `i=0` with `mod(i-1+Nx, Nx)` (L1331–1344). Explicit statement that canonicalization does NOT collapse `mod(i-1+Nx, Nx)` symbolically (L1346–1349). Closes gt-adhm **M2**. |
| **F9** §13.1 Step 1 acceptance | §13.1 Step 1 | **Resolved** | Acceptance (L1557–1590) now exercises: rule-engine with three fixtures covering single match, fixed-point, and `E_RULES_NOT_CONVERGED` at reduced `max_passes`; `regrid` round-trip + `E_UNKNOWN_REGRID_METHOD` rejection; `passthrough` annotation with and without; numeric-literal corner cases (integer-valued float, shortest round-trip, subnormals, negative zero) and `E_CANONICAL_NONFINITE` rejection. Closes gt-j6do **New M2**. |
| **F10** §12 DAE-abort conformance | §12 | **Resolved** | Error code pinned exactly as `E_NO_DAE_SUPPORT` (L1488–1490). Three-step conformance at L1492–1510 (success-path with DAE enabled, disabled-path expecting exit ≠ 0 and the exact error string, anti-silent-success introspection check). Julia/Rust must implement both paths; Python/Go/TS may stub success path but MUST emit exact error on failure path (L1512–1517). Closes gt-j6do **New M5**. |

---

## Editorial cleanup — verdicts

Each row: item cited in §17.1's editorial list → section landed → verdict.

| Item | Cites | Verdict |
|---|---|---|
| §9.4 ghost-variable naming `<scheme>__<logical>__<side>` | §9.4 L1372 | **Resolved** (gt-j6do open q 5). |
| §5.2 rule-field table adds `use`, `produces`, `region` (advisory) | §5.2 L157–164 | **Resolved** (gt-j6do new-m2/m3/m4). `region` explicitly advisory and non-matching, addressing brahmin's new-m2. |
| §6.4.2 `apply_axis_flip` clarified as not on-wire | §6.4.2 L801–813 | **Partially resolved**. The footnote is clear that `apply_axis_flip` is pedagogical and the canonical on-wire form is the piecewise D₄ expansion, with fixtures under `step4_cubed_sphere/`. But the worked example at L787–798 still shows `apply_axis_flip` inline rather than the piecewise form; the canonical piecewise expansion is deferred to a follow-up "Appendix A" bead (L808–813). ghoul's new-m5 recommended either replacing the example with the piecewise form OR moving it to a separately labeled appendix — neither is fully done. Not a Step-1 blocker (Step-1 fixtures are cartesian); fixture authoring for Step 4 will force the issue. |
| §6.4.1 `builtin` name versioning | — (cited but landed as L537-adjacent; see gt-j6do new-m8) | **Resolved**. |
| §5.4.9 comparator memoization note | §5.4.9 L586–595 | **Resolved** (gt-adhm m1). Correctly stated as implementation note, not conformance requirement. |
| §5.4.4 zero-elimination iterates over int+float together | §5.4.4 L405–408 | **Resolved** (gt-adhm m3). |
| §11 Step 4/5 — where `regrid` wrap happens | §11 L1436–1451 | **Resolved** (gt-adhm m6). Step 4 puts cross-grid coupling wrapping on the coupling resolver; Step 5 puts cross-grid scheme-emission wrapping on the rule engine with `E_MISSING_REGRID` enforcement. |
| §5.2.5 `max_passes = 32` justification | §5.2.5 L262–264 | **Resolved** (gt-adhm m7). |
| §10 `coupling.<c>.regrid_method` + §10.1 + §16 | §10.1 L1388, §11 L1440, §16 L1794 | **Resolved**. New optional field with `E_MISSING_REGRID_METHOD` when cross-grid coupling lacks it. Deliverable-list updated accordingly. |

---

## Regressions and internal inconsistencies

**Flag 1 — §17.1 F3 overclaims resolution of gt-j6do New M3.**
F3's prose (L1973) says it "Resolves gt-j6do **New M3**." gt-j6do's New M3 asks for a per-op **`args`-position** leaf-vs-subtree table for `grad`/`div`/`laplacian` (brahmin review-v2 L234–264), analogous to §5.2.1's per-op name-class table. §7.1.1 does not add such a table; it only handles `$target`, dim-component mapping, and `k_bound`. The same issue is listed in §17.1's explicit deferred block (L2058–2060): "gt-j6do **New M3** ... an explicit table lands with the next rule-engine amendment." The deferred listing is the accurate status. The F3 "Resolves" claim contradicts it and should be removed or softened to "addresses" / "partially resolves." Non-blocking; a documentation-coherence fix.

**Flag 2 — §7.1 `target_binding` row contradicts §7.1.1 chooser.**
§7.1's discretization-fields table (L875) still reads: "unstructured: bound to the iteration index of the operand's location, e.g. `c` for `cell`, `e` for `edge`, `v` for `vertex`". §7.1.1 (L892–906) now pins the chooser as **`emits_location`-first, operand's location otherwise**. A reader of §7.1's table alone will derive the wrong rule. Low-risk for implementers (they will land on §7.1.1 by the time they parse a scheme), but the table row should be aligned with §7.1.1 — either by summarizing the chooser in one line or by cross-referencing §7.1.1 instead of restating the old rule.

**No genuine regressions found.** The §7.3 MPAS expansion, §5.4 canonical form, §5.2.5 walker semantics, §5.3 `regrid` enum, §9.2.1 periodic BC, §12 DAE contract, and §13.1 Step 1 acceptance either preserve prior v2 intent (when it was correct) or narrow it (when it was under-specified). `method: "panel_seam"` in the §6.4.2 worked example remains consistent with the new §5.3 closed enum.

---

## Explicitly deferred (not re-reviewed; scope-compliant)

§17.1 lists the following as deferred to 0.2.x / 0.3. Each is legitimate (out-of-MVP or narrow edge case that does not block Step-1 infra):

- gt-j6do **New M1** (mesh loader 3 field-addressing paths) — documentation now, schema unification later.
- gt-j6do **New M3** (per-op `args` leaf/subtree table for calculus ops) — see Flag 1; deferred pending next rule-engine amendment.
- gt-j6do **New M4** (loader `determinism.temporal_interpolation`) — Step 2 scope.
- gt-j6do **New M6** (shape-mismatched couplings) — Step 2/3 scope.
- gt-adhm **M3** (extended bare-string resolution for `face_coords` / `independent_variable`) — Step 2 schema additions.
- gt-adhm **M5** (axis-specific schemes vs axis-parameterized metric) — 0.3 candidate.
- gt-adhm **M8** (Python/Go/TS disposition in Steps 2–4) — Step 2 acceptance refinement.

---

## Final call

**v2.1 is Step-1-ready.**

All ten F-items in §17.1 land concrete, normative text in the sections they cite. The canonical-form bit-identity story is decidable (RFC 8785 JCS pinned; NaN/Inf rejected; signed zero/subnormal behavior specified; `*(1.0, x)` type-loss fixed). The §7.3 MPAS expansion validates against base-spec `arrayop` by construction. The rule-engine semantics (termination, pattern-variable flow, scheme `applies_to` protocol, `regrid` method closed set) are pinned. Step 1 acceptance now exercises the infrastructure it ships.

Two documentation-coherence fixes should land before Step 1 fixture authoring but do not block the architectural go-ahead:

1. Soften §17.1 F3's "Resolves gt-j6do New M3" to match the explicit deferral in the deferred-items block (Flag 1).
2. Align §7.1's `target_binding` table row (L875) with the §7.1.1 `emits_location`-first chooser (Flag 2).

Both are editorial (single-line fixes) and can land inline without a v2.2.

---

*End of v2.1 verification.*
