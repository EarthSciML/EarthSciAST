# RFC — Match-pattern scoping constraints (`where`) for §9.6 rewrite rules

**Status:** Spec + schema + Julia reference implementation + conformance fixtures landed
(this branch). Python / Rust / TypeScript / Go ports are **wave 2** — deliberately not in
this change; see §10 for the porting checklist.
**Affects spec version:** 0.8.0 (rides *inside* the in-progress 0.8.0 window; **no
version bump**, no dedicated version gate — like `priority`, the construct is covered by
the existing §9.6.5 gates: files < 0.4.0 already reject on templates, and the 0.8.0
window is unreleased).
**Scope:** `esm-spec.md` §9.6.1 / §9.6.3 / §9.6.6 / §9.6.7 / §9.6.8, `esm-schema.json`
(+ 4 copies + TS embedded), `src/lower_expression_templates.jl` (+ one structural-field
line in `src/template_imports.jl`), conformance fixtures. The §9.7 import-edge
**index-set renaming** mechanism is owned by a sibling change; §7 states the one
composition requirement this RFC places on it.

---

## 1. Motivation

A production-readiness audit of the EarthSciDiscretizations standard library
(`../earthscidiscretizations`, `grids/*/rules/*.esm`) found that every shipped
discretization rule matches on `(op, wrt-literal)` — e.g. any `D(·, wrt: "x")`
(`cartesian_uniform_1d/rules/upwind1_D_periodic.esm`,
`central_D2_zero_grad_bc.esm`, `latlon/rules/central_D_lon_zero_grad_bc.esm`) — or on
the **bare op**: the MPAS finite-volume divergence rule
(`mpas/rules/fv_divergence_cell.esm`) matches every `{op: "div", args: ["F"]}` in the
importing component with no discriminator at all. Two consequences:

1. **A rule rewrites ALL matching nodes in the importing component.** Two grids each
   contributing a `div` scheme (a regional MPAS mesh nested in a global one; an MPAS
   ocean mesh coupled to a lat-lon atmosphere in one component), or mixed schemes on one
   axis (upwind for the advected `u`, central for the diffused `v`), are inexpressible
   except by fragile `priority` games — and priority cannot express *disjointness* at
   all: it can only make one rule always win, never route each node to its own rule.
2. **Name capture across unrelated consumers.** A consumer axis that merely happens to
   be *named* `x` is captured by an imported cartesian rule matching `wrt: "x"`, whether
   or not the consumer's variable has anything to do with that grid.

The §9.6.3 engine is deliberately dumb — structural match, priority, declaration order,
bounded fixpoint, byte-identical everywhere — and must stay that way. What is missing is
a **static, declarative discriminator** that lets a rule say *which* nodes it is for.

## 2. What the §9.6 pattern grammar already expresses (survey)

The pattern grammar (§9.6.1 `match`; reference matcher `_match_pattern` in
`src/lower_expression_templates.jl`) already provides, without any new construct:

| Capability | How | Status before this RFC |
|---|---|---|
| **Per-variable selectivity** | A **non-parameter** string in an `args` position matches only that exact bare variable reference: `{"op": "D", "args": ["u"], "wrt": "x"}` with `params: []` fires only on `D(u, x)`. `params` MAY be empty since 0.8.0, and the body can reference `u` literally. | **Worked, but undocumented.** Now sanctioned in §9.6.1/§9.6.8 and pinned by the `per_variable_scheme_literal_args/` fixture. |
| Scalar-field literals | `wrt: "x"`, `dim`, `side` etc. match literally when not a param. | Documented (§9.6.1). |
| Compound patterns | Whole-term matches (Godunov Hamiltonian) with `priority` out-ranking per-derivative rules. | Documented (§9.6.3). |
| Nonlinear patterns | The same param twice must bind deep-equal subtrees (`_json_equal` guard). | Implemented. |
| Field-presence constraints | An object pattern constrains exactly the fields it names; extra node fields are permitted. | Implemented. |

**The real gap** is exactly one thing: *no way to predicate a wildcard on the static
declaration of what it captures*. `{"op": "div", "args": ["F"]}` cannot say "…where `F`
is a field over `edges`". Everything else in §1 falls out of that gap (per-variable
selectivity falls out of ground patterns, above). So this RFC adds the **minimal**
mechanism that closes it — one optional field, one constraint kind — and documents the
ground-pattern selector as the sanctioned per-variable mechanism rather than inventing a
second one.

## 3. Design: the `where` field

One new **optional** field on an `expression_templates` entry, beside `match`:

```json
"fv_divergence_cell": {
  "params": ["F"],
  "match": { "op": "div", "args": ["F"] },
  "where": { "F": { "shape": ["edges"] } },
  "body":  { "...": "the TRiSK aggregate over cells" }
}
```

- Keys are declared `params`. Values are constraint objects. The **v1 constraint
  vocabulary is exactly one kind**: `shape`, a non-empty ordered array of index-set
  names.
- The constraint on `p` is satisfied iff the sub-AST bound to `p` by the structural
  match is a **bare variable-reference string** naming a declaration in the enclosing
  component whose declared `shape` (§6) equals the constraint's list **exactly** (same
  names, same order). Everything else fails: compound sub-AST, numeric literal,
  scalar-field-bound literal, scoped `System.var` reference, undeclared name, scalar
  variable, never-bound param.
- Evaluation is **fully static** — declared shapes at lowering time, never runtime
  values. No shape inference over compound expressions in v1: the judgment is
  deliberately syntactic and conservative, so eligibility depends only on declarations
  and the §9.6.3 determinism contract (priority order, declaration-order tie-break,
  bounded fixpoint, byte-identical fixpoints) is untouched.

### Why a sibling field, not annotations inside the pattern

Considered and rejected:

1. **In-pattern annotations** (e.g. `{"op": "div", "args": [{"param": "F", "shape":
   ["edges"]}]}`). Rejected: the pattern grammar's canonical form becomes ambiguous — an
   object in an operand position is today unambiguously a sub-*pattern* (an Expression
   node to match structurally), and §9.6.1's whole scalar-field binding rule rests on
   "params appear as bare strings". A second object shape in operand position would need
   its own disambiguation rule everywhere patterns are walked (matcher, §9.7.3
   composition checks, renaming, linting) and would leak into `body` symmetry questions.
   A sibling field keeps patterns exactly what they were: plain Expressions with
   bare-string wildcards.
2. **A guard expression** (mini-language over captures). Rejected as the classic slippery
   slope out of "purely structural, no evaluation" (§9.6.3 constraint 1). The v1 need is
   a declaration lookup, not a predicate language; the closed constraint-object
   vocabulary can grow new *kinds* (e.g. `location` for staggering) without ever
   becoming evaluable.
3. **Overloading `priority`** / rule-ordering conventions. Rejected: priority selects a
   winner among rules that all fire; it cannot express that a rule *does not apply* at a
   node (see §1, consequence 1).

Placement as a top-level template field also gives schema validation for free
(`additionalProperties: false` on the constraint object pins the v1 vocabulary), and
keeps `match` byte-identical to 0.7-era rules for diffing.

## 4. Semantics

**Eligibility, pinned in the §9.6.3 algorithm.** At each node in a pass, the engine
considers every `match` rule whose pattern structurally matches **and whose `where`
constraints are satisfied by the resulting bindings**. Constraint filtering is part of
match *eligibility* — it happens **before** the priority/declaration-order selection. A
constraint-excluded rule is a non-matching rule at that node, exactly as if its pattern
had failed structurally; in particular a high-`priority` constraint-excluded rule never
shadows a lower-priority rule that does fire (pinned by a unit test; the reference
implementation realizes it as a per-candidate `_match_pattern(...) &&
_where_satisfied(...)` in the pre-sorted scan, which is equivalent).

**Registration-time name check.** A `shape` constraint's index-set names resolve against
the **consuming document's** merged `index_sets` registry (§9.7.5), at the point where
the rule enters a component's effective sequence (§9.7.4). An unknown name is
`template_constraint_unknown_index_set` — a loud typo failure mirroring
`template_import_unknown_name`. A library file constraining against index sets it
declares itself passes when imported (its `index_sets` merge before registration);
loading/validating a library standalone does not run the check (nothing registers).

**A constrained rule that never fires is not an error.** It is indistinguishable from
any other non-matching rule.

**Composition with `unlowered_operator` (§9.6.8).** If the *only* candidate rule for a
spatial `D`/`div` is constraint-excluded, the node is simply not rewritten; the fixpoint
converges with the rewrite-target intact (loading stays permissive), and the existing
pre-evaluation gate rejects it exactly as if no rule had been imported. No new failure
mode, no new gate.

## 5. Worked example A — two meshes, two `div` rules, one component

The audit's headline inexpressibility. Mesh a and mesh b each contribute a
finite-volume divergence; both rules' patterns are structurally identical:

```json
"index_sets": {
  "cells_a": {"kind": "interval", "size": 5}, "edges_a": {"kind": "interval", "size": 9},
  "cells_b": {"kind": "interval", "size": 6}, "edges_b": {"kind": "interval", "size": 11}
},
"variables": {
  "F_a": {"type": "state", "units": "1", "shape": ["edges_a"]},
  "F_b": {"type": "state", "units": "1", "shape": ["edges_b"]},
  "div_a": {"type": "observed", "units": "1", "shape": ["cells_a"],
            "expression": {"op": "div", "args": ["F_a"]}},
  "div_b": {"type": "observed", "units": "1", "shape": ["cells_b"],
            "expression": {"op": "div", "args": ["F_b"]}}
},
"expression_templates": {
  "fv_div_mesh_a": {
    "params": ["F"],
    "match": {"op": "div", "args": ["F"]},
    "where": {"F": {"shape": ["edges_a"]}},
    "body":  {"op": "*", "args": ["inv_area_a", "F"]}
  },
  "fv_div_mesh_b": {
    "params": ["F"],
    "match": {"op": "div", "args": ["F"]},
    "where": {"F": {"shape": ["edges_b"]}},
    "body":  {"op": "*", "args": ["inv_area_b", "F"]}
  }
}
```

`div(F_a)` is lowered by `fv_div_mesh_a` only and `div(F_b)` by `fv_div_mesh_b` only —
at *equal* priority. Under the pre-`where` engine the declaration-order tie-break would
have sent **both** nodes to `fv_div_mesh_a`. (Conformance: `two_div_two_meshes/`; the
bodies are stand-ins — a real rule's body is the TRiSK `aggregate`, unchanged by this
RFC.)

## 6. Worked example B — mixed schemes on one axis (upwind `u`, central `v`)

Needs **no new construct**: per-variable selectivity is a *ground pattern* — a
non-parameter string in an `args` position matches only that exact bare reference. This
was already true of the matcher and is now the sanctioned mechanism (§9.6.1/§9.6.8):

```json
"expression_templates": {
  "upwind1_D_u": {
    "params": [],
    "priority": 10,
    "match": {"op": "D", "args": ["u"], "wrt": "x"},
    "body":  {"op": "*", "args": ["upwind_coef", "u"]}
  },
  "central_D_any": {
    "params": ["f"],
    "match": {"op": "D", "args": ["f"], "wrt": "x"},
    "body":  {"op": "*", "args": ["central_coef", "f"]}
  }
}
```

The ground rule takes `D(u, x)`; the wildcard rule takes every other `D(·, x)`. The
ground rule out-ranks the generic one by **explicit** `priority` — the engine never
infers specificity (§9.6.3), so the precedence is the author's portable choice.
(Conformance: `per_variable_scheme_literal_args/`. In a library context the `u`-rule is
authored against the consumer's variable name; a library that wants to stay
name-agnostic uses `where` shape-scoping instead — the two selectors are orthogonal and
compose.)

## 7. Interaction with §9.7 (imports, renaming, metaparameters)

- **Consuming-registry resolution.** Constraints name index sets *as seen in the
  consuming document's registry*. Since imported `index_sets` merge into that registry
  (§9.7.5) before any rule registers, a grid library's rules constrained to its own sets
  compose with zero extra machinery.
- **Import-edge index-set renaming** (sibling change, in flight): instantiating a grid
  twice under renamed index sets MUST rewrite the imported templates' `where.*.shape`
  entries together with the imported `index_sets` and `aggregate` range references
  (`ranges.{from,of}`). This is the natural composition — after renaming, the rule
  arrives constrained to the renamed sets, and the consumer's variables declared over
  those renamed sets select it. **This RFC places exactly that one requirement on the
  renaming mechanism**; the renaming branch owns its implementation.
- **Metaparameters.** `where` is a structural field: §9.7.6 expression-position
  substitution never rewrites its contents (reference implementation:
  `"where"` added to `_META_SUBST_SKIP_KEYS`). Index-set *names* are a namespace,
  not integer sites.
- **Diamond dedup / conflicts.** `where` participates in the deep-equal identity of a
  template like every other field (§9.7.4): same-name templates differing only in
  `where` are a `template_import_name_conflict`, not a silent merge.

## 8. Diagnostics (§9.6.6 additions)

| Code | Meaning |
|---|---|
| `template_constraint_unknown_index_set` | **New.** A `where` `shape` constraint names an index set the consuming document's merged registry does not declare; raised at rule registration in the consuming component. |
| `apply_expression_template_invalid_declaration` | **Extended.** Also covers a malformed `where`: `where` without `match`, a key that is not a declared param, an unknown constraint kind (v1 admits exactly `shape`), or an empty/non-string `shape` list. |

## 9. Schema + conformance fixtures

`esm-schema.json` `$defs.ExpressionTemplate` gains the optional `where` property
(`additionalProperties` → constraint object with **required** `shape`,
`additionalProperties: false`); mirrors synced via `scripts/sync-schema.sh` (Go / Rust /
Julia / Python copies + the generated TS `embedded-schema.ts`).

Fixtures under `tests/conformance/expression_templates/` (README documents each):

- `constrained_match_scope/` — positive + negative in one document, one expanded golden.
- `two_div_two_meshes/` — §5 verbatim.
- `per_variable_scheme_literal_args/` — §6 verbatim.
- `constraint_unknown_index_set/` — `error.json`, stage `load`.

Fixture literals avoid integral-valued floats (`1.5`, not `1.0`) per the existing
goldens convention.

## 10. Wave-2 porting checklist (Python / Rust / TypeScript / Go)

Each binding's §9.6.3 engine gains, in order:

1. **Structural validation** of `where` at template registration:
   requires `match`; keys ⊆ `params`; constraint object = exactly `{shape:
   [nonempty strings...]}` → `apply_expression_template_invalid_declaration`.
2. **Shape environment** per component: variable name → declared `shape`
   (ordered list) for every shaped variable; scalars and reaction-system
   species/parameters (no `shape` field) are absent.
3. **Registration check**: every constraint index-set name ∈ the document's merged
   `index_sets` keys → else `template_constraint_unknown_index_set`. Run where match
   rules register into a component's effective sequence — NOT when a library file is
   loaded standalone.
4. **Eligibility filter** in the per-node candidate scan: pattern match AND
   constraint satisfaction (`bindings[p]` is a bare string, declared, shape ==
   constraint exactly, names and order), before priority/declaration-order selection.
5. **Metaparameter substitution skip** for the `where` field (whatever the binding's
   equivalent of `_META_SUBST_SKIP_KEYS` is).
6. Drive the four fixtures of §9; replicate the two non-fixture pins as unit tests:
   *constraints filter before priority* (high-priority excluded rule does not shadow a
   low-priority firing rule) and *compound argument fails conservatively* (no error, no
   rewrite).
7. Schema copy arrives via `sync-schema.sh`; no other loader surface changes
   (round-trip already emits the expanded form, so `where` never survives load).

## 11. EarthSciDiscretizations adoption (concrete, per rule)

To be applied in `../earthscidiscretizations` after this lands (not in this change):

- **`mpas/rules/fv_divergence_cell.esm`** — add `"where": {"F": {"shape": ["edges"]}}`.
  The rule then fires only on divergences of edge-fields of *its* mesh; a second MPAS
  instance imported under renamed sets (§7) is automatically scoped to
  `edges_<instance>`. This closes the audit's headline "matches every div in the
  component" finding.
- **`latlon/rules/central_D_lon_zero_grad_bc.esm`** — add
  `"where": {"f": {"shape": ["lon", "lat"]}}`. Closes the "unrelated consumer axis
  named `lon`" capture: a consumer variable must actually be declared over the grid's
  `(lon, lat)` registry entries, not merely differentiated along something called
  `lon`. (Order is the declared storage order used by the rule's stencil/regions —
  exact-order equality is a feature here, not a limitation.)
- **`cartesian_uniform_1d/rules/central_D2_zero_grad_bc.esm`** and
  **`upwind1_D_periodic.esm`** — add `"where": {"f": {"shape": ["x"]}}` to both. The
  compound D2 rule keeps its `priority: 10` over the upwind rule (compound-first is
  still a priority concern, §9.6.3); `where` scopes both to genuine `x`-fields. For a
  model that wants upwind-`u` / central-`v` on the same axis, the library rules stay as
  the generic tier and the model adds ground-pattern rules per §6 at higher priority.
- **Caveat to document in ESD**: a shape-constrained rule does not fire on `div` of a
  *compound* flux expression (e.g. `div(u*h)` written inline). The pattern for that is
  the one the library already uses everywhere: bind the flux to a declared observed
  (shaped) variable and take `div` of it — which is also what the audit's fixture
  problems do.

## 12. Resolved decisions

1. **Exact-shape equality** (names and order), not subset/permutation: deterministic,
   explains itself, and matches how a stencil actually consumes storage order. A
   `shape_includes`-style kind can be added to the closed vocabulary later without
   breaking v1 rules.
2. **Bare-variable-only judgment** (no shape inference over compounds): keeps the
   constraint a declaration lookup; inference is a wave-3 discussion if the ESD library
   ever needs it (see §11 caveat — it currently does not).
3. **Constraint failure ≠ error; unknown index set = error.** Never-firing is a normal
   state (the gate catches real omissions at evaluation); a name outside the registry is
   unconditionally a typo and fails at load, mirroring `template_import_unknown_name`.
4. **No dedicated version gate**: rides the unreleased 0.8.0 window (precedent:
   `priority`).
5. **Binding ports deferred to wave 2** (this RFC lands spec + schema + Julia reference
   + fixtures; the fixtures are the cross-binding contract).
