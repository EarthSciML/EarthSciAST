# RFC — Scope-directed template injection (assembler- and test-chosen discretization)

**Status:** Draft (proposed changeset for review)
**Bead:** TBD (file on acceptance)
**Affects spec version:** 0.8.0 (rides *inside* the in-progress clean break; no bump, no compat shims)
**Scope:** `esm-spec.md` §4.7 / §6.6 / §6.7 / §9.6.1 / §9.7.2 / §9.7.4 / new §9.7.10 / §10,
`esm-schema.json` (+ 5 binding mirrors), conformance fixtures, follow-up in all five bindings.
Discretization *content* stays **out of scope** — it lives in `../earthscidiscretizations`; this RFC
only lets a composing document, or an inline test, choose *which* library a component is lowered by.
**Depends on:** template-library imports (`template-library-imports.md`, §9.7) and the
open-op-namespace fixpoint engine (`open-op-namespace-fixpoint-rewrite.md`, §9.6.3) being present
in a binding. This RFC only *re-targets the scope* an existing import list registers into; it touches
neither the import grammar nor the rewrite engine.

---

## 1. Motivation

A PDE model component — advection, diffusion, a Saint-Venant surface-runoff model — is written
against the PDE-operator sugar (`grad`, `div`, `laplacian`, spatial `D`, §4.2). Those ops are
**rewrite-targets** (§9.6.3 constraint 6): they load fine, but a component MUST have a `match`
rule lower them to an `aggregate` + `makearray` stencil before it can be evaluated, and a spatial
derivative over a finite domain is inseparable from its boundary treatment, so *the rule is the
discretization* (§9.6.8).

The problem is **where that rule is allowed to live.** §9.6.1 / §9.6.3 constraint 4 make rewrite
rules **component-local**: a rule imported into a `model`/`reaction_system` is visible only within
*that* component's expression positions. So today the discretization rule must be imported by the
very component that declares the `grad` equations. That welds a reusable leaf component to one
discretization: you cannot run `SaintVenantPDE` with central differences here and upwind there
without editing the file, and you cannot keep the file discretization-agnostic and still evaluate
it — anywhere.

Nothing available today lifts this weld, in **any** of the three contexts where a leaf needs to run:

- **Composition.** A larger model pulls leaf components in as subsystems by reference (§4.7) or wires
  them with `coupling` (§10); both mount a component as a **child scope**. There is no document- or
  coupling-level `expression_template_imports` (§9.7.2 admits the field only inside a component or at
  the top of a *library* file, and a library file may not carry `models`/`coupling`), and even if
  there were, component-local scope would keep a parent's rules from reaching a child's `grad`
  nodes. The spec's own worked example (§13.1) shows the only path available: the `central_grad_*`
  rules are declared **inside** the `Advection` leaf model, next to its `grad` equations; the
  `coupling` block above selects and wires components but is structurally unable to say a word about
  discretization.
- **Inline tests / examples.** A `Test` targets its enclosing component implicitly ("there is no
  `model_ref` field: the target is implicit from document location", §6.6) and is
  `additionalProperties: false` — there is no slot to attach a discretization, so a PDE component's
  inline tests (§6.6.5 PDE-aware assertions) cannot be *run* against any concrete scheme. This is why
  `saint_venant.esm` carries `tests: []`.

Consequence: a genuinely reusable, discretization-agnostic PDE component is **un-runnable in every
context**, because the one place a rule may be registered (the leaf's own scope) is exactly the place
we want to keep empty. `EarthSciModels/.../surface_runoff/saint_venant.esm` is the forcing example
already in the repo: it uses `grad`, imports no discretization, and carries `tests: []` — a valid
file that nothing can simulate. It should *stay* agnostic, and the **assembler or the test** should
choose the discretization.

## 2. Summary of changes

The missing primitive is a **scope-directed template import**: an `expression_template_imports` list
registered into a *target component's* template scope instead of the current component's own scope.
One primitive, three attachment points — all in the *consuming* surface (composing document or test
block), none touching the leaf file.

| # | Change | Target | Timing | Where |
|---|--------|--------|--------|-------|
| A | **`SubsystemRef.expression_template_imports`** — ordered `TemplateImport[]` on a §4.7 subsystem-ref edge. | Implicit — the referenced component (edge mounts exactly one). | Load-time (consumed by the fixpoint) | schema `SubsystemRef` + §4.7 |
| B | **`CouplingEntry.expression_template_imports`** — map `{ <target-system>: TemplateImport[] }` on any coupling entry; key MUST name a model/reaction-system the entry references. | Explicit — a coupling entry references two-plus systems. | Load-time (consumed by the fixpoint) | schema all `Coupling*` defs + §10 |
| C | **`Test.expression_template_imports` / `Example.expression_template_imports`** — ordered `TemplateImport[]` on a `Test`/`Example` object. | Implicit — the enclosing component (§6.6 implicit target). | Execution-time (ephemeral per-run build) | schema `Test`/`Example` + §6.6/§6.7 |
| D | **Semantics (§9.7.10)** — every form *widens the target component's rule set* and nothing else: component-local scope preserved, §9.7.4 order/dedup/conflict verbatim. A/B resolve at load and do not survive `parse → emit`; C is authored per-run config and **does** survive. | — | — | §9.7.10 (new) + §9.7.4 |
| E | **Diagnostics** — `template_inject_target_unknown`, `template_inject_target_is_loader`, `template_inject_target_not_component`; existing `template_import_*` codes fire unchanged for the import list. | — | — | §9.6.6 table |

**Design invariant (the whole point):** the leaf component file is never edited. Everything that
selects a discretization is expressed in the consuming surface. `saint_venant.esm` keeps its bare
`grad` and empty local scope; a composition says "mount it, lower its `grad` with central
differences," and a test on it says "run me under upwind at n = 64."

**Explicitly NOT done** (see §8): a document-level `discretization` block (rejected — the natural
owner of the choice is the mount/wiring edge or the test, not a free-floating registry);
*overriding* a rule the leaf already imports (injection is **additive** — an agnostic leaf has an
empty scope, so there is nothing to override; a leaf that baked in its own rule is not agnostic and
is out of scope); injection into a **nested** sub-component more than one level below a composition
edge (§8.3).

## 3. `SubsystemRef.expression_template_imports` (§4.7)

A §4.7 subsystem reference gains one optional field, reusing the §9.7.2 `TemplateImport` shape
verbatim (`ref`, `only?`, `bindings?`, `prefix?`, `rename?`, `rebind?`):

```json
{
  "subsystems": {
    "Runoff": {
      "ref": "../components/environmental_transport/surface_runoff/saint_venant.esm",
      "expression_template_imports": [
        { "ref": "esd://cartesian/central_grad_zero_grad_bc.esm",
          "bindings": { "NX": 200, "NY": 120 } }
      ]
    }
  }
}
```

The mounted `Runoff` component contributes its `grad` equations; the injected import contributes the
`match` rule that lowers them. The target is **implicit**: a subsystem-ref edge mounts exactly one
component, and the imports register into *that* component's scope. No target selector is needed or
allowed here.

**Composition with existing `SubsystemRef` fields.** `expression_template_imports` composes with the
edge's `model` selector and `bindings` (`esm-schema.json` `SubsystemRef`): `model` still selects
*which* top-level model of a multi-model referenced file is spliced in (the injected imports register
into that selected component); the edge's own `bindings` still close the *referenced document's*
metaparameters (§9.7.6 site 3), while `expression_template_imports[k].bindings` close the *imported
library's* metaparameters (grid size for the stencil) — both ordinary §9.7.6 sites. The injected
`ref` MUST resolve to a template-library file (§9.7.1) — `template_import_not_library` otherwise —
exactly as a §9.7.2 import does; the subsystem `ref` itself still MUST resolve to a component file
(`subsystem_ref_is_template_library` otherwise). No new file form.

## 4. `CouplingEntry.expression_template_imports` (§10)

Every coupling entry (`operator_compose`, `couple`, `variable_map`, `callback`, `event`) gains one
optional field: a **map from a target system name to an ordered `TemplateImport[]`**. Unlike the
subsystem-ref form the target is explicit, because a coupling entry references two or more systems
and some (a data loader in a `variable_map`) cannot host rules.

```json
{
  "type": "operator_compose",
  "systems": ["SimpleOzone", "Advection"],
  "expression_template_imports": {
    "Advection": [
      { "ref": "esd://latlon/central_grad_zero_grad_bc.esm",
        "bindings": { "NLON": 144, "NLAT": 91 } }
    ]
  },
  "description": "Compose chemistry onto advection; lower Advection's grad with central differences."
}
```

Reads naturally: *compose these two, and discretize `Advection` with central differences.* The 0-D
chemistry system `SimpleOzone` names no key and receives nothing.

**Target resolution.** Each map key MUST name a system **referenced by that entry**:
`operator_compose`/`couple` → a member of `systems`; `variable_map`/`callback`/`event` → any system
named by that entry's reference fields. Otherwise `template_inject_target_unknown`. A key resolving
to a data loader is `template_inject_target_is_loader` (a loader is pure I/O with no expression
positions, §14); a key resolving to neither model, reaction system, nor loader is
`template_inject_target_not_component`. Resolution follows §4.6 scoped-reference rules, so a
subsystem path (`"Parent.RefSubsystem"`) is a valid key when the entry references a nested system.

**Why the entry, not a top-level block.** A coupling entry already *names* the systems it composes;
hanging the discretization on the entry that mounts a PDE component into the assembly keeps the
choice next to the wiring that makes it necessary, and needs no new top-level section (§8.1).

## 5. `Test` / `Example` injection (§6.6 / §6.7)

`Test` and `Example` each gain one optional field — an ordered `TemplateImport[]`, same shape as
§9.7.2 — registered into the **enclosing** component's template scope for that run only:

```json
{
  "id": "runoff_central_n64",
  "description": "Saint-Venant runoff under central differences at n = 64.",
  "time_span": { "start": 0.0, "end": 100.0 },
  "expression_template_imports": [
    { "ref": "esd://cartesian/central_grad_zero_grad_bc.esm",
      "bindings": { "NX": 64, "NY": 64 } }
  ],
  "assertions": [
    { "variable": "h", "time": 100.0, "expected": 0.0,
      "reduce": "L2_error", "reference": { "op": "sin", "args": [{ "op": "*", "args": [3.14159, "x"] }] },
      "tolerance": { "abs": 1e-3 } }
  ]
}
```

The target is **implicit** — the enclosing model/reaction-system, exactly as the test's assertion
target is implicit (§6.6). No selector is needed. This is the field that finally makes §6.6.5
PDE-aware assertions runnable on a discretization-agnostic component: the injected rule lowers the
component's `grad` in the per-test build, the resulting spatial field is collapsed to a scalar via
`coords` or `reduce` at the assertion `time`, and the L2/Linf reference machinery (§6.6.5) checks it.

**One suite, many schemes.** Because each `Test`/`Example` carries its own list and each runs as an
independent ephemeral build (§6.1 of §9.7.10 below), a single component's suite may exercise it under
central vs. upwind, or across a convergence sweep, by varying the injected `ref`/`bindings`
per test — with no conflict between tests and no edit to the component. `bindings` close the
library's grid-size metaparameters, which must agree with the index-set sizes the component's
variables are shaped over (an inconsistency surfaces at the ephemeral build as the ordinary
`template_import_index_set_conflict` / shape error).

## 6. Semantics (new §9.7.10)

### 6.1 The shared operation

All three forms compile to the same load operation: **extend a target component's effective template
scope (§9.7.4) with an appended `TemplateImport[]`**, exactly as if the target had added those
entries to the end of its own `expression_template_imports`. Component-local scope (§9.6.3 constraint
4) is **preserved, not escaped**: the injected rules become part of *the target's own* scope and do
not leak to its parent or siblings; the only new capability is *who may write into that scope* — now
also the consuming surface, not just the component's file. A rule injected into `Advection` still
fires only on `Advection`'s expression positions; a parent still cannot discretize a grandchild it
does not directly mount (§8.3). Determinism (byte-identical post-lowering ASTs across all five
bindings) is untouched: injection only widens the rule set handed to the already-deterministic engine.

**Merge order.** When one target receives imports from more than one source, they concatenate into
its §9.7.4 effective declaration order in this fixed, structure-determined order: (1) the target's
own `expression_template_imports`; (2) its subsystem-ref edge's injection (§3), if mounted by ref;
(3) coupling-entry injections (§4) in `coupling`-array order; (4) for a test/example run, that
test's injection (§5). Concatenation then feeds §9.7.4 unchanged — depth-first post-order, deep-equal
diamond dedup at first occurrence, non-deep-equal same-name collision `template_import_name_conflict`.
(Forms A/B and form C never mix in one build: A/B build the assembled document, C builds an ephemeral
per-test instance of a leaf; step 4 applies only in the latter.)

### 6.2 Timing — two regimes

**Forms A/B (composition) resolve at load and are consumed by the fixpoint.** §4.7 already fixes the
timing: subsystem references resolve at load, "before validation or any other processing," yielding a
form "identical to a file with all subsystems defined inline." Injection rides that step: when the
resolver mounts a component it extends that component's scope with its subsystem-ref injection (§3)
and every coupling-entry injection keyed to it (§4), in the §6.1 order, *before* the §9.6.3 fixpoint
(§9.7.6 within-load order: resolve imports → merge index sets → close metaparameters → body
composition → fixpoint). Coupling-entry injections are collected after all `coupling`-named systems
resolve, so a coupling entry may target an inline-declared system as well as a referenced one. The
fixpoint then lowers the target's `grad`/`div`/spatial-`D`; the `unlowered_operator` gate (§9.6.3
constraint 6) never trips on it. A composition that mounts a PDE component **without** injecting (and
where the component imports nothing itself) still fails cleanly at evaluation with
`unlowered_operator` naming the surviving op — the same failure as today, now with an obvious fix.

**Form C (test/example) resolves at execution time, in an ephemeral build.** A test's injection must
**not** run at component load — doing so would lower the enclosing component's `grad` in the
canonical document and prevent a sibling test from choosing a different scheme. Instead the inline
runner (§6.6) constructs, per test, an ephemeral instance of the enclosing component with that test's
imports appended to its scope (§6.1 steps 1 + 4), runs the §9.6.3 fixpoint on *that* instance, and
evaluates. The enclosing component in the loaded/persisted document is never mutated.

### 6.3 Round-trip

Injection fields share the round-trip fate of the *timing regime* they belong to:

- **Forms A/B do not survive `parse → emit`.** Like a component's own `expression_template_imports`
  (§9.7.6), they are load-time constructs consumed by the fixpoint; the canonical emitted form is the
  assembled document with the mounted/target component's operators already lowered (Option A
  always-expanded, §9.6.4), and the injection field is gone — subsumed into that component's now-lowered
  scope, exactly as the subsystem ref/coupling edge it rode on is resolved.
- **Form C survives `parse → emit` verbatim.** A `Test`/`Example` injection is authored per-run
  configuration, a peer of `parameter_overrides`, `initial_conditions`, and `tolerance`. The
  enclosing component round-trips with its `grad` **intact** (§9.6.3 constraint 6 — a file may
  round-trip carrying rewrite-targets), and the test's `expression_template_imports` is preserved so
  the runner can rebuild the ephemeral instance on the next run. Source files remain the source of
  truth in both regimes.

### 6.4 Index sets and metaparameters

In every form the injected library's `index_sets` merge into the **document's** registry as a
§9.7.5 import would (deep-equal idempotent; non-equal collision `template_import_index_set_conflict`),
so the stencil's axes and the target component's variable shapes resolve against one registry, and the
library's metaparameters close via `expression_template_imports[k].bindings` at the injection edge
(left-open names re-export per §9.7.6 site 2). This is what lets one rule file serve every resolution
— the assembler (or the test) binds the grid size at the edge, and the same file serves a convergence
sweep by re-binding.

## 7. Diagnostics (added to the §9.6.6 table)

| Code | Raised when |
|---|---|
| `template_inject_target_unknown` | A `CouplingEntry.expression_template_imports` key names no system referenced by that entry. |
| `template_inject_target_is_loader` | A coupling-entry injection key resolves to a data loader (no expression positions to rewrite). |
| `template_inject_target_not_component` | A coupling-entry injection key resolves to something that is neither model, reaction system, nor loader. |

Subsystem-ref (§3) and test/example (§5) injections need no target-selector diagnostics — their
target is implicit. The import list *itself* reuses every existing §9.7 code unchanged:
`template_import_unresolved` (bad `ref`), `template_import_not_library` (`ref` is a component file),
`template_import_unknown_name` (bad `only`/`bindings` name), `template_import_cycle`, the
`template_import_rename_*` / `template_import_rebind_*` family, `template_import_name_conflict` /
`template_import_index_set_conflict` (§6.1 merge), and `metaparameter_*`.

## 8. Alternatives considered / deferred

### 8.1 A top-level `discretization` block (rejected)

A document-level map `{ "<system>": TemplateImport[] }` sibling to `coupling` reads cleanly for the
whole-document case but (a) duplicates the target-selection the coupling entry has for free, (b)
separates the discretization choice from the wiring that forces it, and (c) invents a new top-level
section where extending existing edges suffices. The subsystem-ref edge (§3) covers "discretize the
thing I mount"; the coupling-entry map (§4) covers "discretize a system as I wire it"; the test field
(§5) covers "discretize the thing I test." Nothing is left for a standalone block to do.

### 8.2 Making rules non-component-local for coupled systems (rejected)

Letting a parent's rules descend into children would collapse the component-local invariant that
keeps two meshes' `div` rules from cross-firing (§9.6.8, `two_div_two_meshes`). Injection keeps the
invariant and adds only an *authoring* channel into a specific target's scope.

### 8.3 Deeper (nested) targeting (deferred)

Injection targets the mounted/named/enclosing component's own expression positions, one level below
the edge. A `grad` inside a *nested* sub-component of a mounted file is that sub-component's concern;
reaching it needs its own injection along the ref chain, or a scoped target key (§4 already admits
`"Parent.Child"` keys for coupling entries; the subsystem-ref and test forms do not). Generalizing
the implicit-target forms to scoped targets is deferred until a real two-level case appears.

## 9. Schema changes (sketch)

`SubsystemRef` (add one property; `additionalProperties` stays `false`):

```json
"expression_template_imports": {
  "type": "array",
  "description": "Template-library imports registered into the REFERENCED component's template scope (esm-spec §9.7.10) — assembler-chosen discretization for a mounted PDE component, without editing the leaf file. Same entry shape as §9.7.2; target implicit (this edge mounts one component). Load-time only; consumed by the §9.6.3 fixpoint; does not survive parse→emit.",
  "items": { "$ref": "#/$defs/TemplateImport" }
}
```

Each `Coupling*` def (`CouplingOperatorCompose`, `CouplingCouple`, `CouplingVariableMap`,
`CouplingCallback`, `CouplingEvent`; `additionalProperties` stays `false`):

```json
"expression_template_imports": {
  "type": "object",
  "description": "Map from a target system referenced by this coupling entry to the template-library imports registered into THAT component's template scope (esm-spec §9.7.10). Each key MUST name a model/reaction-system this entry references (template_inject_target_unknown otherwise); a data-loader key is template_inject_target_is_loader. Load-time only; does not survive parse→emit.",
  "additionalProperties": { "type": "array", "items": { "$ref": "#/$defs/TemplateImport" } }
}
```

`Test` and `Example` (add one property each; `additionalProperties` stays `false`):

```json
"expression_template_imports": {
  "type": "array",
  "description": "Template-library imports registered into the ENCLOSING component's template scope for THIS run only (esm-spec §9.7.10 / §6.6) — lets a discretization-agnostic PDE component's inline tests/examples run under an assembler-free, per-test discretization. Same entry shape as §9.7.2; target implicit. Execution-time (ephemeral per-run build); authored per-run configuration, so it DOES survive parse→emit (peer of parameter_overrides / tolerance).",
  "items": { "$ref": "#/$defs/TemplateImport" }
}
```

No new `$defs` are introduced; all three forms reuse `TemplateImport`.

## 10. Conformance fixtures (proposed)

Under `tests/conformance/expression_templates/`:

- `inject_subsystem_ref/` — a composing document mounts a bare-`grad` leaf by `ref` and injects a
  central-difference rule bound to a concrete grid; golden is the assembled document with the leaf's
  `grad` lowered and the injection field absent. Negative twin: same mount **without** injection →
  `unlowered_operator` at the evaluation gate.
- `inject_coupling_entry/` — an `operator_compose` of a 0-D reaction system and a spatial model,
  injecting into the spatial model by name; golden as above. Negatives: a data-loader key in a
  `variable_map` (`template_inject_target_is_loader`), an unreferenced-system key
  (`template_inject_target_unknown`).
- `inject_test_block/` — a discretization-agnostic PDE leaf whose own `tests` carry
  `expression_template_imports`; the runner golden is the per-test lowered instance + assertion pass,
  and the **`parse → emit` golden keeps the component's `grad` and the test's import field intact**
  (the form-C round-trip contract). A second test in the same file injects a *different* scheme,
  proving one suite / many schemes with no conflict.
- `inject_two_discretizations/` — one leaf mounted twice under different `prefix`es and injected with
  central vs. upwind rules, proving assembler-chosen discretization and coexistence (reuses §9.7.7
  two-instance machinery unchanged).
- `inject_convergence_sweep/` — one leaf, one rule file, four injections (composition edges *and* a
  four-test suite) binding `N ∈ {16,32,64,128}` — a convergence study with no generated fixtures.

Each golden is emitted once and asserted byte-identical across all five bindings, per §9.6.4.

## 11. Binding impact

The change is localized to two existing phases, and touches neither the rewrite engine, the
`TemplateImport` resolver, nor the metaparameter folder — all reused as-is:

1. **Subsystem-resolution / coupling-assembly** (forms A/B): after loading a mounted component and
   before the fixpoint, splice the injected list into that component's effective scope in the §6.1
   order — the same list a component's own `expression_template_imports` already produces.
2. **Inline-test/example runner** (form C, §6.6): before building a test's evaluator, append the
   test's imports to an ephemeral copy of the enclosing component's scope and run the fixpoint on that
   copy; never mutate the persisted component.

Bindings without remote-ref support reject a URL `ref` in an injected import with the existing
`template_import_unresolved`, identically to a §9.7.2 import (§4.7 optional-remote rule). Expected
touch: the loader/assembler and inline-test-runner modules plus the conformance harness in Julia,
TypeScript, Python, Rust, and Go.
