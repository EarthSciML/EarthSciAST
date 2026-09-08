---
title: "Mount-edge index-set renaming"
description: "An opt-in `index_set_rename` on a component mount edge, so one document can mount two components that use the same axis name at different lengths."
---

# RFC — Mount-edge index-set renaming (`index_set_rename`)

**Status:** Draft (proposed changeset for review)
**Issue:** EarthSciML/EarthSciAST#198 item 4 — "Document-scoped index sets forbid two column
components with different NLEV"
**Affects spec version:** 1.0.0 (purely additive; no bump, no compat shims — a document that
does not use the field parses, resolves and emits byte-identically)
**Scope:** `esm-spec.md` §4.7 ("Index-set merge") + §9.7.5 + the §9.6.6 diagnostics table;
`esm-schema.json` `$defs/SubsystemRef` (+ the four binding schema mirrors and the TS embedded
schema); conformance fixtures; binding loaders.
**Depends on:** `template-library-imports.md` (§9.7 as shipped) and
`template-import-renaming.md` (§9.7.7). This RFC closes that RFC's §11 open question —
*"Renaming at §4.7 subsystem edges — not needed so far (mount names already namespace),
revisit only on a concrete case."* #198 item 4 is the concrete case, and the parenthetical is
a false premise (§1.3).

---

## 1. Motivation

### 1.1 The reported case

EqWeFiC assembles WRF-in-`.esm` column physics by mounting components into one document and
wiring them with document-level `coupling.variable_map`. Two of those components are columns
over the *same* grid family — `column_nonuniform_1d`, whose axis is named `lev` — at different
lengths: a 59-layer atmospheric column and a 4-layer slab soil column. Each component closes
the grid library's `NLEV` at its own import edge, so each contributes `lev` to the **document**
registry, one as `{interval, 59}` and one as `{interval, 4}`.

`index_sets` is a document-scoped registry, and the merge rule at both mount forms is
deep-equal-or-error, so the load fails:

```
[subsystem_index_set_conflict] index set 'lev' from subsystem ref './soil_column.esm'
(kind=interval, size=4) collides with a non-deep-equal declaration in the importing
document (kind=interval, size=59).
```

The reporter's surface-layer + slab + PBL chain therefore has to be split into two separate
assemblies, which defeats the point of the assembly.

### 1.2 The scoping itself is correct and must not change

Document scope for `index_sets` is load-bearing in at least six places, and each of them is
a deliberate, documented decision:

| Where | Why document scope |
|---|---|
| `ModelVariable.shape` / `Parameter.shape` | "ordered list of index-set names drawn from the document-scoped `index_sets` registry" — how every array extent is resolved. |
| `aggregate` `ranges.<sym> = {"from": …}` | The only declaration site for an iteration domain; a typo must be `undefined_index_set`, never a silent empty set. |
| `IndexSet.from_faq` (`kind: "derived"`) | §4.7 states explicitly that `from_faq` MUST resolve against the **whole document's** expression nodes, and that node `id` is document-unique — a phase-6 correction made precisely because a per-model registry made a cross-model derived index set unresolvable (`tests/valid/wildfire_atmosphere_ocean.esm`). |
| §11.2 model dimensionality | Derived from how many index sets a model's unknowns are shaped over. |
| §9.6.1 `where` `shape` constraints | Named "as spelled in the CONSUMING document's merged `index_sets` registry". |
| §2.1 `coordinates` | CF role follows the source array's declared `shape`, matched **by dimension identity, not by length**, so that "two distinct same-length axes (e.g. `atm_lat` and `ocn_lat` in a coupled run) never cross-attach". |

The deep-equal-or-error merge is equally load-bearing: `tests/invalid/template_imports/`
`subsystem_index_set_conflict.esm` exists precisely because the pre-pin behavior — importer
silently wins, mounted mesh's own axis size discarded — was a real, silent corruption.

So the fix is **not** to re-scope index sets or to loosen the merge. It is to give the
assembler a way to say *"this mount's `lev` is not that mount's `lev`"*.

### 1.3 Why mount names do not already solve it

`template-import-renaming.md` §11 deferred subsystem-edge renaming on the grounds that
"mount names already namespace". They do — for **variables**: after §4.7 resolution,
`Parent.RefSubsystem.variable` is a scoped reference and two mounts of one leaf keep their
unknowns apart. They do **not** for index sets, which are the one declaration kind that
deliberately escapes the mount and lands in a single document-wide registry. The premise was
false; #198 item 4 is the case §11 asked to be revisited on.

### 1.4 What is already possible, and what is not

There is a workaround, and it is worth stating because it covers a real slice of the problem
(verified against the Python binding on the #198 reproducer):

> The **leaf** may rename the library axis at its **own** §9.7.7 import edge —
> `{"ref": "./column_grid.esm", "bindings": {"NLEV": 4}, "rename": {"lev": "soil_lev"}}` —
> and write `soil_lev` in its own `shape`s and ranges. The assembly then loads, with
> `{lev: 59, soil_lev: 4}` in the document registry.

It does not cover the two cases that matter:

1. **A leaf you do not own.** §9.7.1's no-edit bar is about libraries, but the same logic
   applies to a third-party component: forking a component to rename an axis forfeits
   upstream fixes. Worse, it pushes the burden the wrong way — every reusable component
   would have to pre-namespace its axes *on the guess* that some future assembly will
   collide, which is exactly the "generic names are the point" argument §9.7.7 was written
   to answer for libraries.
2. **One component mounted twice.** Two soil columns at two resolutions, a nested-domain
   pair, a convergence pair in one assembly: **no** leaf-side edit can express this, because
   both mounts read the same file. This is §9.7.7's "one family, two instances" motivation,
   one level up the reference DAG, and it is inexpressible today.

---

## 2. Summary of the change

| # | Change | Where |
|---|---|---|
| A | **`index_set_rename`** on a mount edge — an optional `{old: new}` map on `$defs/SubsystemRef`, which is the schema shape of **both** the §4.7 `subsystems.<k> = {ref}` edge and the top-level `models.<k>` / `reaction_systems.<k>` `{ref}` mount. Applied at load to the fully-resolved mounted document, before its `index_sets` merge into the mounting document's registry. Normative and implemented at the §4.7 subsystem edge in all five bindings; at a top-level model-ref mount it follows that form's index-set merge, which is not yet uniform (§4.11). | schema + §4.7 |
| B | **Transitivity list** (normative occurrence sites) for a mount-edge index-set rename — a superset of §9.7.7's, because a mount carries a whole component and not just declarations: it adds `shape`, `Assertion.coords` keys, and `DataSourceSelectAxis.gated_by`. | §4.7 |
| C | **One new diagnostic**, `subsystem_index_set_rename_unknown_name`; the three §9.7.7 rename diagnostics (`template_import_rename_invalid`, `template_import_rename_collision`) are reused verbatim. | §9.6.6 |
| D | **Sharper `subsystem_index_set_conflict` / `template_import_index_set_conflict` text**: name both contributors, both definitions, and the remedy. Independent of A–C and useful even if A–C never ship. | all bindings |

**Explicitly NOT done** (§5): component-scoped index sets; automatic namespacing of a mount's
axes; a `prefix` counterpart; renaming anything other than index sets at a mount edge;
loosening the deep-equal merge.

---

## 3. Design

### 3.1 The field

```jsonc
"models": {
  "Atm":  { "ref": "./atm_column.esm" },
  "Soil": { "ref": "./soil_column.esm", "index_set_rename": { "lev": "soil_lev" } }
}
```

and identically on a §4.7 subsystem edge:

```jsonc
"subsystems": {
  "Soil": { "ref": "./soil_column.esm", "index_set_rename": { "lev": "soil_lev" } }
}
```

`index_set_rename` is an object mapping an index-set name **as the mounted document sees it**
to the name it takes in the mounting document. It composes with the edge's existing fields:
`bindings` still closes the referenced document's metaparameters (§9.7.6 site 3),
`expression_template_imports` still injects a discretization into the referenced component's
scope (§9.7.10), and `model` / `reaction_system` still select among several components.

### 3.2 Edge pipeline (normative)

For one mount edge, in order — the §9.7.7 edge pipeline with the target kind changed from
"library" to "component":

1. **The target resolves in its OWN scope.** The referenced document is loaded and resolved
   as a *complete document*: its own subsystem refs, its own `expression_template_imports`
   (with *their* §9.7.7 renames), this edge's `bindings` and `expression_template_imports`
   injection, its metaparameter close and fold, its §9.7.5 index-set merge, and the §9.6.3
   fixpoint. This is §9.7.6 site 3's rule verbatim ("a subsystem ref is resolved as a
   complete document and folded to concrete integers at the mount").
2. **`index_set_rename` applies** to that resolved document, as ONE simultaneous substitution
   (swaps are well-defined; chains do not cascade), over the occurrence sites of §3.4.
3. **The renamed document's `index_sets` merge** into the mounting document's registry under
   their post-rename names, deep-equal-or-error exactly as today (§4.7 / §9.7.5), and the
   component splices in.

Consequently the map's **keys speak the mounted document's own post-resolution vocabulary** —
the names you would see if you loaded the leaf standalone and read its `index_sets`. If the
leaf itself imported a grid library under `prefix: "g"`, its document-visible axis is `g.lev`
and the mount writes `{"g.lev": "soil.lev"}`. This is the same "target's export vocabulary"
rule §9.7.7 states for import edges, and it is the only rule under which the mount edge is
writable without reading the leaf's transitive import closure.

Renaming is **per edge**: step 2 covers what *this* referenced document declares and imports,
and an axis reaching the registry through a mount *nested inside* the referenced document is
renamed (or not) at that nested edge, by its own `index_set_rename`. This is not a limitation
dressed up as a rule — it is what keeps the semantics binding-independent. The bindings
already disagree about whether a nested mount's axes land in the leaf's registry (Rust, Go,
Julia) or go straight to the root's (Python); making an outer rename responsible for inner
contributions would inherit that disagreement. Per-edge renaming composes down the reference
DAG by composition of the maps, never by cascade, and no binding has to decide whose edge a
nested contribution belongs to.

### 3.3 Domain: index sets only

A mount edge renames index sets and nothing else, because index sets are the only declaration
kind that crosses a mount into document scope:

- **Templates** are component-local (§9.6.3 constraint 4); two mounts never see each other's.
- **Metaparameters** are closed at the mount by `bindings` / defaults (§9.7.6 site 3); a
  mount is a closed build boundary, so there is nothing to re-export and nothing to rename.
- **Variables, parameters, species** are namespaced by the mount key (§4.6).
- **Node `id`s** are document-unique but are *identities*, not names in a vocabulary; see
  §6 open questions.

`prefix` is deliberately omitted (§5.4).

### 3.4 Transitivity — normative occurrence sites

A mount-edge index-set rename rewrites the declaration key **and every reference to the old
name inside the mounted document**. The list is §9.7.7's, plus the three sites that only exist
because a mount carries a whole component rather than a set of declarations. Site 6b is a
§9.7.7 site the pre-existing declaration walk did not cover; it is added to **both** walks
here, so import-edge and mount-edge renaming stay one rule.

| # | Site | Note |
|---|---|---|
| 1 | `index_sets` registry key | The declaration itself. |
| 2 | `IndexSet.of` entries (ragged parent list) | §9.7.7 site; **not** to be confused with `ranges.<sym>.of`, which is a list of bound index *symbols* and is never rewritten. |
| 3 | `aggregate` `ranges.<sym>` → `{"from": <name>}` | §9.7.7 site. |
| 4 | Expression axis scalars `wrt`, `dim`, `integral`'s `var` | §9.7.7 site (§4.2). |
| 5 | `integral` `lower` / `upper` **when the value is a bare string naming a renamed index set** | §9.7.7 site; any other bound is an ordinary expression position and is left alone. |
| 6 | `ExpressionTemplate.where.<param>.shape` entries | §9.7.7 site (§9.6.1). Constraint **keys** are param names and are never rewritten. |
| 6b | `aggregate` `join.<i>.on` key-column entries (§4.9.5) | §9.7.7 site, **added in this change and applied to §9.7.7's own walk too**. An `on` name resolves as a loop symbol, then the index set one of the node's ranges draws `{from}`, then a data column (CONFORMANCE_SPEC §5.5.8); only the middle class is an axis, so an entry is rewritten **iff** it is a key of the rename map. A clause's `syms` are bound symbols and are never rewritten. |
| 7 | **`ModelVariable.shape` / `Parameter.shape` entries** | **New.** The site that makes the whole mechanism work — a mounted component's arrays are declared over the axis by name. |
| 8 | **`Assertion.coords` KEYS** (§6.6.5 PDE-aware assertions) | **New.** The keys are spatial index-set / dimension names. |
| 9 | **`DataSourceSelectAxis.gated_by`** (§8.9.2) | **New.** Names a `kind: "derived"` index set. |

Never rewritten, for the avoidance of doubt: `IndexSet.from_faq` and `ExpressionNode.id` (node
identities, not axis names); `IndexSet.offsets` / `IndexSet.values` / `IndexSet.member_factor`
(keyed-factor *variable* names — §9.7.7's `rebind` domain, not `rename`'s);
`aggregate.output_idx`, `ranges` **keys** and a `join` clause's `syms` (bound index symbols); `coordinates.<k>.source`
(a data-array name); every structural scalar in the §9.7.7 protected set (`op`, `reduce`,
`semiring`, `manifold`, `fn`, `table`, `side`, `attrs`, `members`).

### 3.5 Grammar and checks

- A key MUST name an index set of the **resolved** mounted document, else
  `subsystem_index_set_rename_unknown_name`. Renames never invent names, matching
  §9.7.7's `template_import_rename_unknown_name` rule and `only`/`bindings` before it. A
  silent no-op for an unknown key was rejected for the same reason it was rejected in
  §9.7.7: a misspelled axis would then reappear as the original collision, one layer removed
  from its cause.
- A target MUST be a dotted identifier (segments `[A-Za-z_][A-Za-z0-9_]*` joined by single
  dots), else `template_import_rename_invalid` — the §9.7.7 grammar, reused verbatim so
  `atm.lev` and `soil.lev` are spellable.
- Post-rename names MUST be distinct within the edge, else `template_import_rename_collision`.
- Identity entries are no-ops. An absent or empty map is the identity and MUST leave the
  mounted document byte-identical to today's resolution.
- The map is **not** required to be total: axes the mount does not name pass through
  unrenamed, which is what makes a *deliberately shared* axis (a common `cells` mesh, a
  common `time`) still merge deep-equal across two mounts.

### 3.6 Round-trip

`index_set_rename` rides on a mount edge, and a mount edge is a **load-time construct**: after
resolution "the in-memory representation is identical to a file with all subsystems defined
inline" (§4.7). Like `bindings` and the §9.7.10 injection on the same edge, the field is
consumed at load and does **not** survive `parse → emit`; the emitted document carries the
inlined component with its axes already spelled under the post-rename names, and a registry
that already holds them. `emit ∘ load` remains a byte-wise fixed point, because the second
load has no edge left to rename.

---

## 4. Side effects — what this does and does not disturb

This is the section #198 asks for. Each row states the effect and the reason it is contained.

### 4.1 Documents that do not use the field

Unchanged, byte-for-byte, at every stage: the field is optional, absent everywhere in
`tests/`, and the loader's behavior when it is absent (or empty) is the identity. No existing
document changes meaning; no golden moves. This is the single strongest argument for the
design over every alternative in §5.

### 4.2 Round trip (`parse → emit`)

See §3.6. Two second-order notes:

- The **mounted component's own** `expression_templates` registry survives `parse → emit`
  (§9.6.4 rule 5) and is materialized into the spliced component. Under a rename it is
  materialized with renamed `wrt` / `where.shape` / `{"from"}` occurrences. That is correct
  and required — a rule instance that still matched the pre-rename axis would silently stop
  firing — but it does mean the emitted registry is *not* byte-identical to the leaf file's,
  which is already true of any mount that binds metaparameters.
- A **template-library** file is never mountable (`subsystem_ref_is_template_library`), so
  the §9.6.4-rule-5 generic-load round-trip is untouched.

### 4.3 Interaction with `expression_template_imports` (§9.7.2 / §9.7.10)

Both directions were checked:

- **The leaf's own imports** are resolved *before* the mount rename (pipeline step 1), so a
  leaf that already renames the library axis at its own edge is renamed again, from its
  post-rename name. Renames compose by composition of the two maps, never by cascade.
- **The mount edge's §9.7.10 injection** merges the injected library's `index_sets` into the
  *document's* registry. Under this RFC those axes are part of the resolved mounted document
  at step 2, so they are renamed too. That is the behavior an assembler wants: injecting a
  stencil library at two mounts with two different grid `bindings` is exactly the case that
  collides today, and the mount rename is what separates them.
- **Ordering hazard, flagged:** if a binding ever moved the §9.7.10 injection's index-set
  merge to *after* the mount (rather than through the leaf's resolution), the injected axes
  would escape the rename. The pipeline in §3.2 pins the order to prevent it. **No fixture
  covers a mount that renames *and* injects** — `mount_rename_two_columns.esm` renames only —
  so the order is pinned by prose alone; a mount edge carrying both
  `expression_template_imports` and `index_set_rename` is the regression test this RFC still
  owes.

### 4.4 Interaction with §9.7.6 metaparameter substitution

None, by construction: the rename runs strictly after the mounted document's metaparameters
are closed and folded (§9.7.6 site 3, "resolved as a complete document and folded to concrete
integers at the mount"), and it renames axes, not metaparameters. Two consequences worth
stating:

- Index-set **sizes** are concrete integers by the time the rename runs, so a renamed axis can
  never carry a symbolic size into the mounting registry.
- §9.7.6's `metaparameter_name_conflict` check ("a metaparameter name MUST NOT collide with
  any variable, parameter, species, or index-set name visible in the document") is evaluated
  on the mounting document's **post-merge** registry, i.e. against the *renamed* names. A
  rename can therefore *create* a collision (`index_set_rename: {"lev": "NLEV"}` against a
  declared metaparameter `NLEV`) — which is correct: it fails loudly with the existing code,
  and the author picks another name.

### 4.5 Interaction with `variable_map` endpoints that name shaped variables

`coupling.variable_map` endpoints name **variables** (`Atm.T`, `Soil.Tsoil`), and this RFC
renames **axes**, so no endpoint spelling changes. Three real interactions:

- The document-level coupling is authored by the same assembler that wrote the rename, in the
  post-rename vocabulary. An entry that still names `lev` after both mounts renamed it away
  fails cleanly with `undefined_index_set` at the site that names it, not silently.
- §10.5 regridding / lifting between differently-shaped endpoints is expressed as an ordinary
  `aggregate` coupling expression; its `{"from": …}` ranges name the merged registry, so they
  name post-rename axes. **This is the interaction that makes the mechanism useful rather
  than merely legal**: `Atm.T[atm.lev] → Soil.Tsoil[soil.lev]` needs both axes to exist
  simultaneously in one registry, which is precisely what is impossible today.
- A `variable_map` whose two endpoints are shaped over what *were* the same axis name and are
  now two distinct axes stops being a same-shape copy and becomes a shape mismatch. That is
  the truth being surfaced, not a regression — the two arrays were never the same length.

### 4.6 `from_faq`, node `id`s, and mounting one file twice

`IndexSet.from_faq` names an expression node by `id`, and `id` is document-unique (§4.7). A
`kind: "derived"` index set inside a mounted leaf is renamed at site 1; its `from_faq` is
**not** rewritten, because it is a node identity. That is right for a single mount.

Mounting the **same** file twice, however, splices the same node `id`s into one document twice
and is a duplicate-`id` load error **today, independently of this RFC**. So §1.4's "one
component mounted twice" case is unblocked by this RFC only for leaves that assign no `id`s
(the overwhelming majority — `id` is optional and used only as a `from_faq` referent). Making
`id`s mount-relative is a separate change and is listed in §6.

### 4.7 Ragged index sets and keyed factors

A `kind: "ragged"` index set names its CSR factors (`offsets`, `values`) by **bare variable
name**, resolved out of a component. Two mounts of one mesh family therefore still collide on
those factor names even under an axis rename — the §9.7.7 `rebind` mechanism exists for
exactly this at import edges and has no mount-edge counterpart here. Deliberate: the reported
case is `kind: "interval"` columns, `rebind`'s cross-component story is unsettled (a mount's
factors are component-scoped, so the target of a rebind would have to be a §4.6 scoped
reference into a sibling mount), and adding it speculatively is how §9.7 fields acquire
semantics nobody can state. Listed in §6.

### 4.8 Coordinates (§2.1)

`coordinates` entries name a data array, and their CF role is derived from that array's
`shape`. Renaming an axis therefore changes a coordinate's dimension identity, which is what
"matched by dimension identity, not by length" was written to want: after the rename,
`atm.lev` and `soil.lev` no longer cross-attach. No `coordinates` field names an index set
directly, so nothing in §2.1 needs a rewrite rule.

### 4.9 Diagnostics and existing invalid fixtures

`tests/invalid/template_imports/subsystem_index_set_conflict.esm` and
`index_set_conflict.esm` keep their codes: the field is absent there, so the collision still
fires. Only the message **text** changes (change D), and `expected_errors.json` pins codes,
not messages.

### 4.10 What could not be fully ruled out locally

Stated plainly, because the change touches the load pipeline:

1. **Only targeted tests were run.** The shared fixtures and the five per-binding regression
   tests pass, and Go `build`+`vet`, Rust `cargo check --lib` and TS `tsc --noEmit` are clean,
   but neither `scripts/test-conformance.sh` nor any binding's full suite was run locally
   (CI does that). The most likely place for a surprise is a fixture that already carried a
   `shape` / `coords` key the new walk now visits — it should be inert there (the walk only
   rewrites names present in a non-empty rename map, and every existing fixture's map is
   absent), but "should be inert" is an argument, not a test run.
2. **A rename walk that misses an occurrence site fails loudly, not silently.** Sites 7–9 are
   new work in all five bindings. A miss surfaces as `undefined_index_set` /
   `array_shape_mismatch` at the site that names the stale axis, never as a silently
   mis-sized array — but two bindings could still disagree about *which* loud failure they
   give for the same document.
3. **The two mount forms resolve at different times in different bindings** (§4.11). At a
   §4.7 subsystem edge every binding resolves the leaf as a complete document at the mount,
   which is what makes this change uniform there. The top-level `models.<k>` `{ref}` form
   does not have that property today, so the field's reach at that form is not yet uniform,
   and #198 item 3 is changing exactly that merge.
4. **Interaction with an inline test's ephemeral build (§9.7.10 timing regime 2).** A test's
   injection rebuilds the enclosing component per test; a mount rename belongs to the
   composed document and should be invisible to a leaf's own tests run standalone. Believed
   fine (the ephemeral build starts from the persisted component, which the mount never
   mutates on disk) but not exercised by a fixture here, and #198 item 2 is separately
   re-litigating when a mounted leaf's tests run at all.

### 4.11 Where the field reaches today, per binding

`$defs/SubsystemRef` is the schema shape of both mount forms, so the field is *spellable* at
both. What it *does* at the top-level `models.<k>` `{ref}` form follows that form's index-set
merge, which the five bindings do not implement alike — a pre-existing divergence that is
#198 item 3's subject, not this RFC's:

| Binding | §4.7 subsystem edge | Top-level `models.<k>` `{ref}` mount |
|---|---|---|
| Julia | implemented | mount exists, but it splices the leaf raw and **drops** its `index_sets`, deferring the leaf's `expression_template_imports` to the root pass — no merge, so nothing to rename |
| Rust | implemented | same deferral as Julia |
| Python | implemented | **implemented** — both forms share `_load_ref_data`, which already resolves the leaf fully at the mount and merges its `index_sets` |
| TypeScript | implemented | the form is not inlined at all (a bare `{ref}` stub returns immediately) |
| Go | implemented | the form does not exist |

The honest summary: this RFC makes the mechanism uniform at the edge where the merge itself
is uniform, and Python gets the top-level form for free because its two mount forms are one
code path. Bringing Julia/Rust/TS/Go's top-level form up to the same line is item 3's work,
and the field needs nothing further once that lands.

---

## 5. Alternatives considered and rejected

### 5.1 Component-scoped index sets (the issue's other suggestion)

Give every component its own registry, with the document registry as a fallback. **Rejected.**
It contradicts six documented decisions at once (§1.2 table): `from_faq` would become
unresolvable across models again — undoing the phase-6 correction that made
`wildfire_atmosphere_ocean.esm` loadable — §9.6.1 `where` constraints would lose their
stated referent ("the CONSUMING document's merged registry"), §2.1's dimension-identity
matching would need a scope qualifier, and every `shape` resolution in every binding, every
runner, and every flatten path would need a scope parameter threaded through it. It is also
strictly *more* than the reported case needs: the assembler wants two axes to coexist and be
wireable to each other, not to be invisible to each other. And a fallback rule ("look in the
component, then the document") reintroduces shadowing, which §9.7.6 explicitly bans
("there is no shadowing").

### 5.2 Automatic namespacing at the mount (`<mountkey>.<axis>`)

Rename every mounted axis silently. **Rejected.** It breaks the mounted-mesh pattern that
§4.7 was written to make sound — an importer deliberately shaping its own variables over a
mounted mesh file's `cells` — and it would break `tests/valid/subsystem_index_set_merge.esm`,
whose entire point is that the host's `diag` is shaped over the mesh file's axis. Silent
namespacing also turns a deliberate shared axis into two axes with no diagnostic at all,
which is the failure mode §1.2's conflict pin was introduced to eliminate.

### 5.3 Namespace only on collision

Auto-rename only when a collision would otherwise fire. **Rejected.** The resulting name
depends on mount order, which makes it non-deterministic under a reordering that is otherwise
semantically inert, and the assembler has to discover the invented name to wire coupling to
it. §9.7 has consistently chosen "loud and explicit" over "clever and implicit".

### 5.4 A `prefix` counterpart to §9.7.2's

`"prefix": "soil"` renaming every surviving axis to `soil.<axis>`. **Deferred, not rejected**
— it is a strict superset of the mechanism and can be added later without changing anything
here. Left out of v1 because at a *mount* (unlike a library import) the axes are usually
mostly-shared and only one or two collide: a blanket prefix would silently detach the
deliberately-shared ones (`cells`, a common vertical coordinate), which is §5.2's failure mode
wearing an opt-in hat. Explicit `rename` makes the author say which axes are private.

### 5.5 Loosen the merge to allow same-name-different-definition

**Rejected outright.** It is the exact silent corruption
`tests/invalid/template_imports/subsystem_index_set_conflict.esm` was added to pin: the
importer's declaration wins and the mounted component's arrays are silently allocated at the
wrong length.

### 5.6 Status quo — leaf-side rename only

**Rejected as insufficient**, see §1.4: it cannot express one component mounted twice, and it
requires every reusable component to pre-namespace defensively.

### 5.7 A rename spelled inside the `ref` string

`"ref": "./soil.esm as soil"`. **Rejected** for the reason §9.7.7's own alternatives section
gives: string micro-syntax inside a field that is otherwise a verbatim §4.7 reference, which
breaks URL refs and offers no per-name control.

---

## 6. Open questions for a human to settle

1. **Field name.** `index_set_rename` is explicit about its domain, at the cost of not matching
   §9.7.2's bare `rename`. Reusing `rename` on `SubsystemRef` would read symmetrically but
   would imply the §9.7.7 domain (templates ∪ index sets ∪ open metaparameters), only one
   third of which crosses a mount. Recommendation: keep `index_set_rename`.
2. **How does the top-level `models.<k>` `{ref}` mount get there?** (§4.11.) Schema-wise the
   field is already free at that form, and Python honours it today. The other four need item
   3's decision first: either the deferring bindings (Julia, Rust) resolve a mounted leaf as a
   closed build boundary the way the subsystem edge does — which costs them the loader-API
   metaparameters reaching a mounted leaf document-wide — or the top-level merge is defined
   some other way. That is a real trade-off and it is item 3's to make, not this RFC's.
   **This matters for the reporter**: EqWeFiC's assemblies use top-level `ref` mounts (they
   are pushed there by #198 item 1, since `variable_map` cannot reach into a subsystem), so
   `index_set_rename` unblocks them under Python today and under the Rust CLI only once item
   3 lands.
3. **Mount-relative node `id`s** (§4.6) — required before "one component mounted twice" works
   for a leaf that assigns `id`s. Separate change, separate RFC.
4. **A `rebind` counterpart** for ragged keyed factors at a mount edge (§4.7). Needs a
   motivating case and a decision on whether a mount's rebind target may be a §4.6 scoped
   reference into a sibling mount.
5. **Should `prefix` (§5.4) ship at all**, or is explicit-only the permanent answer?

---

## 7. Diagnostics

| Code | Meaning |
|---|---|
| `subsystem_index_set_rename_unknown_name` | A mount edge's `index_set_rename` key names an index set the resolved mounted document does not declare (§4.7). The mount-edge mirror of `template_import_rename_unknown_name`. |
| `template_import_rename_invalid` (reused) | An `index_set_rename` target is not a valid dotted identifier, or the map is not a string→string object. |
| `template_import_rename_collision` (reused) | Two keys of one edge map onto one target name. |
| `subsystem_index_set_conflict` (text sharpened) | Now names **both** contributors (the mounting document, or the earlier mount, and this mount), both definitions, and points at `index_set_rename`. |

## 8. Fixtures

Shared corpus (every `.esm` under `tests/valid/**` and `tests/invalid/**` is swept by
`scripts/conformance_corpus.py` in all five bindings):

- `tests/valid/mount_rename_atm_column.esm` (`lev` = interval/59) and
  `tests/valid/mount_rename_soil_column.esm` (`lev` = interval/4) — two components of the
  same `column_nonuniform_1d` family that independently spell their axis `lev` at different
  lengths; each loads standalone.

  Each declares `lev` in its **own** top-level `index_sets` rather than importing it from a
  shared grid library. That is a corpus constraint, not a design one: four bindings (Julia,
  Go, TypeScript, and the Python sweep) run a reference-resolution pass over every
  `tests/valid/**` fixture **from the raw document**, where an axis contributed by an
  unresolved `expression_template_imports` edge is invisible and an `aggregate` range over it
  is a false `E_REF_UNDECLARED_INDEX_SET`. Renaming an axis that arrives through a template
  import is normative (§4.7 edge pipeline step 1), but it currently has **no** regression
  fixture; covering it needs either an inline per-binding test or a corpus sweep that loads
  before it resolves.
- `tests/valid/mount_rename_two_columns.esm` — the #198 item 4 reproducer with the fix
  applied: the soil mount carries `index_set_rename: {"lev": "soil_lev"}` and the merged
  registry holds **both** `lev` (59) and `soil_lev` (4).
- `tests/invalid/template_imports/mount_rename_unknown_index_set.esm` (+
  `expected_errors.json`, `resolver_only`) — `subsystem_index_set_rename_unknown_name`.

Per-binding regression tests (`mount_index_set_rename` / `mount-index-set-rename` in each
package) pin two things in all five: the rename rewrites the registry key **and** the mounted
component's variable `shape` and aggregate `{"from"}` range while leaving the sibling mount
untouched, and an unknown key is a loud load error. Two more are pinned only in **Python**:
that the same pair still collides *without* the field
(`test_without_the_rename_the_two_columns_still_collide`), and that two keys onto one target
is `template_import_rename_collision` (`test_two_rename_keys_onto_one_target_is_a_collision`).
Porting those two to the other four bindings is left open.

A post-lowering `expanded.esm` golden under `tests/conformance/` was deliberately **not**
added: the fixture's value is the registry and the mounted component's spelling, both of which
the per-binding tests assert directly, and a new golden would need the generator script run
across bindings this PR does not otherwise touch.

## 9. Porting checklist (done in all five)

Per binding, at the single point where a mount edge merges the referenced document's
top-level `index_sets` into the mounting registry:

1. Read and validate `index_set_rename` off the edge (string→string object; dotted-identifier
   targets; distinct targets) — reuse the existing §9.7.7 `name_map` so the grammar
   diagnostics are shared.
2. Check every key against the **resolved** mounted document's `index_sets` keys.
3. Apply one simultaneous substitution over the §3.4 sites of the resolved mounted document.
   Note the walk is a NEW one, not the §9.7.7 declaration walk: in a whole component `from`
   also names a data source (`Parameter.update.from`), a coupling endpoint
   (`variable_map.from`) and a connector endpoint, so the mount walk keys off *position*
   (an `op`-bearing node's `ranges`) rather than the bare `from` key, and never rewrites a
   bare string on its own account.
4. Merge under the post-rename names, unchanged.
5. Drive the shared fixtures.

Landing points: Rust `template_imports.rs::apply_mount_index_set_rename` called from
`ref_loading.rs::resolve_value`; Python `template_imports.apply_mount_index_set_rename`
called from `parse._load_ref_data`; Julia `template_imports.jl::apply_mount_index_set_rename`
called from `resolve.jl::_lower_and_coerce`; TypeScript
`template-imports.ts::applyMountIndexSetRename` called from `ref-loading.ts::resolveRefDocument`;
Go `template_rename.go::applyMountIndexSetRename` called from
`subsystem_ref.go::resolveSubsystemMap`.
