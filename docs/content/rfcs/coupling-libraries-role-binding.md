# RFC — Coupling libraries, role binding, and the removal of `coupletype`

**Status:** Draft (proposed changeset for review)
**Bead:** TBD (file on acceptance)
**Affects spec version:** 0.8.0 (rides *inside* the in-progress clean break; no bump, no compat shims)
**Scope:** `esm-spec.md` §5 / §7 (remove `coupletype`), §10.1 entry table, and new §10.9
(coupling-library files), §10.10 (coupling imports and role binding), §10.11 (diagnostics);
`esm-libraries-spec.md` §4.7.5 (flatten-time expansion of `coupling_import`); `esm-schema.json`
(+ 4 binding mirrors); conformance fixtures; and follow-up rig migration in
[EarthSciModels](../earthscimodels) (strip `coupletype`; reissue `couplings/*.esm` as
coupling-library files). Coupling *content* — which components wire to which — stays in
EarthSciModels; this RFC only adds the mechanism.
**Depends on:** the §9.7 template-library-imports resolver for **reference resolution only** (§4.7
formats, relative/URL resolution and `${VAR}` expansion, canonical-path cycle detection); the
§9.7.7 transitive-rename *discipline* (one simultaneous substitution over an enumerated occurrence
surface), reused here over a **new, coupling-specific surface** normatively enumerated in §4.2 —
*not* the §9.7.7 occurrence list verbatim; and the `esm-libraries-spec.md` §4.7.5 flattening
algorithm, into which `coupling_import` expansion is inserted. Nothing here touches the §9.6.3
fixpoint engine or the §9.7.10 pre-fixpoint injection regime.

---

## 1. Motivation

Coupling is the one part of an assembly the format cannot factor or reuse. Everything else —
models, reaction systems, data loaders, discretization rules — is referenceable: a model is
mounted by a §4.7 subsystem `ref`, a rule is pulled in by a §9.7.2 template import. But the
`coupling` block, the array of `variable_map` / `couple` edges that wires those components into
a coupled system, can only be authored inline in the assembling document. There is no
coupling-by-reference edge, no coupling library, nothing.

The cost is concrete and recurring. The wiring of the Rothermel + NFDRS fire-behavior stack —
`FuelModelLookup.sigma → RothermelFireSpread.sigma`, `FuelModelLookup.w_0 →
RothermelFireSpread.w0`, the dead-fuel-moisture chain, the wind/slope terms — is intrinsic to
what "the Rothermel behavior stack" *is*. It is not specific to any one fire model. Yet every
assembly that stands the stack up (`wildlandfire.esm` today; any future fire model) must
re-author all ~15 of those edges by hand. The same is true of every recurring coupling in the
standard library.

The format *knows* these couplings recur — [EarthSciModels](../earthscimodels) ships a
`couplings/` directory (`fastjx_geoschem.esm`, `earthscidata_spatial_params.esm`, …). But those
files are inert. Each is a standalone document of interface *stubs* plus edges, migrated from a
Julia source it cites in its own metadata (e.g. `GasChem.jl@8c12c048:src/fastjx_couplings.jl`).
Nothing in the repository references them; there is no load-time path that pulls one into an
assembly. They are the fossil record of a reuse mechanism that did not survive serialization.

That mechanism was **type dispatch**. In EarthSciMLBase (the Julia framework) each system
carries a coupling type, and a registered method keyed on a *pair* of types —
`couple2(::FastJXCoupler, ::GEOSChemGasPhaseCoupler)` — returns the connecting equations.
`couple(a, b)` finds it by dispatch and emits the edges automatically
(`EarthSciMLBase/src/coupled_system.jl` `couple2(x_t(x), y_t(y))`, applied over every pair in
`graph.jl`). Serialization kept only the ghost: the `coupletype` field, demoted in §5/§7 to
*"Informational label identifying this system's role in coupling"* — a string nothing dispatches
on. We audited all five bindings: every occurrence of `coupletype` is a struct-field declaration,
a schema entry, or a `None`/passthrough construction site. It is dead weight.

And type dispatch was never the right primitive to resurrect. Its defining failure: **two
components of the same type that must couple differently.** Two fuel sources feeding two separate
spread models; two ERA5 loaders at different pressure levels. Dispatch matches by *kind*, so
`couple2(::FuelModel, ::Rothermel)` fires for both indistinguishably — it cannot express "wire
*this* fuel to *that* spread model." Structural matching answers *what kind of thing is this*; the
question an assembler actually needs answered is *which one*.

This RFC gives coupling the reuse layer every other part of the format already has, and it does
so with **explicit name binding** — answering *which one* directly. Note that the framework's own
`couple(a, b)` *already* names both systems explicitly; type dispatch only chose *which equations*
to emit between them. So the natural serialization of `couple(a, b)` against a reusable equation
set is exactly *"import this library, bind role A to `a` and role B to `b`"* — explicit binding is
the direct analogue of the framework call, not a regression from it. What the library supplies is
the reused part (the equations); what the import supplies is the part the framework always made
explicit (which two components). A wrong binding is not silently mis-wired: after expansion the
edges are ordinary scoped-reference coupling edges, so a bind to a component that does not expose a
referenced variable fails at flattening with the existing `unresolved_scoped_ref`
(`esm-libraries-spec.md` §4.7.5) — the same check that guards every hand-authored edge today. It
then deletes the vestigial `coupletype` field, whose only purpose was the dispatch that name
binding replaces.

## 2. Summary of changes

Two additions and one deletion. No structural matching, no interface contract, no auto-binding:
every role is bound by name, and every binding is validated the way every coupling edge already is.

1. **Coupling-library files (§10.9).** A new pure document kind (parallel to the §9.7.1
   template-library file): payload is top-level `coupling_roles` (the file's declared formal
   component parameters, each an optional human-readable `description`) plus a `coupling` array
   whose edges are authored over role names. It MUST NOT declare `models`, `reaction_systems`,
   `data_loaders`, `domain`, or `index_sets` — it is nothing but reusable wiring. The `w_0 → w0`
   variable-name correspondence, the transforms, the `factor`s all live here, authored once.

2. **The `coupling_import` entry (§10.10).** A new `CouplingEntry` variant
   `{ "type": "coupling_import", "ref": …, "bind": { <role>: <local component> } }`, usable
   anywhere an ordinary coupling entry is. `ref` names a coupling-library file (§4.7 formats);
   `bind` maps **every** role the library declares to a component in the assembly. At flatten the
   entry expands into concrete `variable_map` / `couple` entries by substituting the bound actuals
   for the role names (§4.2). The expansion feeds §10.7 / §4.7.5 flattening; the `coupling_import`
   entry itself is preserved in the source document (§4.3).

3. **Delete `coupletype`.** Removed from `Model` and `ReactionSystem` in the schema and all four
   binding mirrors, from the §5/§7 field tables, and from every example. The role a component
   plays is now named where it is actually used — at an import's `bind` — and a wrong pairing
   fails at flatten via `unresolved_scoped_ref`, not silently. Because `Model`/`ReactionSystem`
   are `additionalProperties: false`, a straggler document still carrying `coupletype` fails
   validation loudly, which is the intended clean-break behavior.

**Non-goals / what is *not* deleted.** The inline coupling-entry grammar —
`variable_map`, `couple`, `operator_compose`, `callback`, `event`, their transforms and §10.5
lifting — stays exactly as is. It is the irreducible vocabulary that both an assembly's one-off
wiring *and* a coupling library's edge bodies are built from; a coupling library is a *packaging*
of those entries, not a replacement for them. Deleting it is neither workable (the import
mechanism has nothing to expand *into*) nor desirable (a genuinely assembly-specific edge — e.g.
`wildlandfire.esm`'s `USGS3DEP.raw.elevation → TerrainRegrid.F_raw`, which is specific to this
assembly's chosen data source — should stay a one-line inline entry, not be forced into a
separate roled file). The dividing line the RFC draws: **recurring** couplings become libraries;
**one-off** couplings stay inline; both live in the same `coupling` array.

## 3. The coupling-library file (§10.9)

A **coupling-library file** is a valid ESM document (`esm`, `metadata`) whose payload is:

- `coupling_roles` (**required**, non-empty) — a map from role name to a role descriptor; and
- `coupling` (**required**, non-empty) — an array of §10.1 coupling entries whose system-naming
  fields (the scoped-reference `from` / `to`, a `couple`/`operator_compose` `systems` array, a
  `connector` equation's references, and any scoped reference inside an Expression `transform`;
  §4.2 enumerates the full set) are written against role names as their top-level system segment.

It MUST NOT declare `models`, `reaction_systems`, `data_loaders`, `domain`, `index_sets`,
`metaparameters`, or `expression_templates`. Purity keeps the three reference mechanisms
disjoint, exactly as §9.7.1 does for template libraries: a §4.7 subsystem file is not importable
as a coupling library, a template-library file is not importable as a coupling library, and a
coupling-library file is includable only through `coupling_import` — never as a subsystem
(`subsystem_ref_is_coupling_library`) or a template import (`template_import_is_coupling_library`).

A coupling library MUST NOT itself contain `coupling_import` entries in this revision
(`coupling_library_nested_import`). Layering coupling libraries on coupling libraries is a clean
future extension (it would reuse the §9.7.4 depth-first-post-order + diamond-dedup machinery) but
is deferred to keep v1's resolution order trivially acyclic; there is no forcing use case yet.

**No discretization injection, and no `callback` entries, inside a library edge.** A library edge
MUST NOT carry an `expression_template_imports` map (`coupling_library_illegal_payload`). Such a
map is a §9.7.10/§10.8 *pre-fixpoint* injection, consumed by the §9.6.3 fixpoint **before**
flattening; but a `coupling_import` expands **at** flatten (§4.3) — strictly *after* the fixpoint —
so an injection carried on a library edge could never reach the engine that consumes it. It would
be a silent dead letter, so it is forbidden outright. Discretization is instead chosen at the mount
that makes it necessary — a §4.7 subsystem-ref edge or an inline §10.8 coupling entry in the
*assembling* document — never inside reusable wiring; for the same reason the `coupling_import`
entry itself carries no injection map (§9). A library also MUST NOT contain `callback` entries
(`coupling_library_illegal_payload`): a `callback` exposes only a registered `callback_id` and an
opaque `config` bag (§10.1) with no structured system-reference field, so a role reference inside
it could be neither located nor rewritten by the §4.2 substitution — it would silently mis-wire
rather than fail loudly, which this design forbids everywhere else. The role-bearing entry types a
library MAY therefore contain are exactly `variable_map`, `couple`, `operator_compose`, and
`event`.

**Reference resolution inside a library is role-scoped, not §4.6-scoped.** In an ordinary document
a coupling edge's top-level segment must resolve to a top-level `models` / `reaction_systems` /
`data_loaders` key (§4.6, `esm-spec.md` line 540). A library file has no such systems, so that
resolution is **suspended** when a coupling-library file is validated on its own: at every §4.2
role-occurrence site (that table is the normative enumeration of where a role name may appear), the
top-level segment must instead name a declared role (`coupling_edge_unknown_role` otherwise), and a
role that appears in `coupling_roles` but at no §4.2 occurrence site is `coupling_role_unused`. Both
checks therefore walk the *same* surface the substitution rewrites — a role used only at a site the
surface omits would be spuriously flagged unused, so the §4.2 surface must be exhaustive. Ordinary
§4.6 resolution applies only *after* binding, when each role segment has been rewritten to a real
component (§4.3).

**Why no `index_sets` / templates in the library.** A regridding `transform` (§10.4, §8.6) is an
Expression that references the *receiving component's* build-once weight arrays and the index
sets its variables are shaped over, and §10.4 fixes that "template invocations in the transform
expand against the template registry of the component that owns the `to` target." After binding,
the `to` target is a real component in the assembly, so its weights, index sets, and templates are
all in scope there. The library needs none of its own; it only needs the role names, which binding
resolves. This is what keeps the library a *pure* wiring artifact.

**One deliberate timing carve-out — stated, not glossed.** For an *inline* edge, §10.4 expands the
transform's `apply_expression_template` invocations **at load** (§9.6.4), because the `to` owner is
written explicitly and its template registry is populated at load, *before* the §9.6.3 fixpoint. A
*library* edge cannot follow that timing: its `to` owner is a role, unknown until binding, and
binding happens at flatten (§4.3). So for the edges an import expands, transform-template
expansion is **relocated to flatten** — run against the *bound* `to` owner's registry immediately
after role substitution. This is a small, explicit **extension** of §10.4's load-time rule, not a
reuse of it (§10.4's own words are "expand at load, before validation and flattening"), and the
§10 revision MUST say so rather than imply the timing is unchanged. Two consequences are made
normative:

1. **Library transform templates MUST expand to an already-lowered form.** The relocated expansion
   runs *after* the §9.6.3 fixpoint, so any rewrite-target operator it introduced (`grad`, `div`,
   spatial `D`) could never be lowered and would trip the `unlowered_operator` gate. A regridding
   `transform` is an ordinary `aggregate`/`index` expression and carries none; a library edge whose
   transform template would expand to a rewrite-target operator is rejected with
   `coupling_library_illegal_payload`. (The common `param_to_var` edge has no transform template at
   all and is unaffected.)
2. **Byte-identical flatten (§4.3, §11) is claimed only where the expanded transform is
   fixpoint-invariant.** Every regridding `aggregate` is — the fixpoint does not rewrite core FAQ
   ops — so the equivalence holds for the motivating case and for all template-free edges
   unconditionally; it is *not* asserted for a hypothetical library transform whose load-time and
   flatten-time expansions would diverge (constraint 1 removes the only way that could happen).

### 3.1 Role descriptors

Each entry of `coupling_roles` is a role descriptor with a single optional field:

```jsonc
"coupling_roles": {
  "Fuel":   { "description": "Anderson-13 fuel-property source (sigma, w_0, delta, M_x, h)." },
  "Spread": { "description": "Rothermel (1972) spread model consuming those properties." }
}
```

A role descriptor carries **no structural contract**. Roles are the library's *formal parameters*
— names, not types or shapes. There is deliberately no `interface`, no variable-name list, and no
kind: the library's edges already spell exactly which variables each role must expose (that is
what `Fuel.w_0 → Spread.w0` *says*), and after binding the ordinary flatten-time scoped-reference
resolution (`unresolved_scoped_ref`, `esm-libraries-spec.md` §4.7.5) checks that the bound
component actually exposes them. A separate, redeclared "interface" would only be a second copy of
information the edges already carry — one that could drift out of sync with them — so the RFC does
not introduce one. The safety it would have provided is provided, unduplicated, by resolving the
expanded edges.

`description` is documentation only: it never affects binding or expansion, and it round-trips
verbatim.

## 4. The `coupling_import` entry and role binding (§10.10)

An assembly reuses a coupling library with a new entry in its ordinary `coupling` array:

```jsonc
{
  "type": "coupling_import",
  "ref":  "../earthscimodels/couplings/rothermel_fuel.esm",
  "bind": { "Fuel": "FuelModelLookup", "Spread": "RothermelFireSpread" }
}
```

`ref` resolves by the §4.7 formats (relative path, absolute path, URL, `${VAR}`), with the same
per-binding capability rules and the same `coupling_import_unresolved` failure as a template
import. `bind` is a map from role name to a **scoped component reference** in the assembly: a
top-level `models` / `reaction_systems` / `data_loaders` key, or a dotted path to a nested
subsystem (`Parent.Child`). Data loaders are bindable (a `Loader` role binds a `data_loaders`
entry). The referenced component must exist and be a system or loader
(`coupling_import_bind_not_a_component`) — not a variable.

**Component-reference resolution (distinct from §4.6).** A `bind` value is resolved as a
*component* path, not a §4.6 *variable* path: §4.6 always reads the final segment as a variable
name, whereas a `bind` value names a system all the way down. Split the value on `"."` into
segments `[s₁, …, sₖ]`; `s₁` MUST name a top-level `models` / `reaction_systems` / `data_loaders`
key, and each subsequent `sᵢ` MUST name a key in the preceding system's `subsystems` map. The
*whole* path MUST terminate on a system or loader node — a path that bottoms out at (or passes
through) a variable, parameter, or species, or whose first segment matches no top-level component,
is `coupling_import_bind_not_a_component`. This is the same hierarchy walk §4.7 uses to mount a
subsystem, stopped one level short of a variable; it is a distinct procedure from the §4.6
scoped-reference resolution the *expanded* edges later undergo (§4.2), where the trailing segment
is again a variable.

### 4.1 The matching rule — every role is bound by name

The rule is deliberately trivial: **there is no search and no inference.** For a `coupling_import`
edge referencing a library that declares roles `R₁ … Rₙ`:

1. **Every role MUST have a `bind` entry.** A declared role absent from `bind` is
   `coupling_import_role_unbound`. (There is no auto-binding: a missing role is always an error,
   never a guess.)
2. **Every `bind` key MUST name a declared role.** A `bind` key that is not one of `R₁ … Rₙ` is
   `coupling_import_unknown_role` (catches typos and stale binds against a changed library).
3. **Every `bind` value MUST resolve to a component.** A value that does not resolve to a
   top-level or nested `models` / `reaction_systems` / `data_loaders` component is
   `coupling_import_bind_not_a_component`.

That is the whole rule. `bind` is a total, checked map from the library's formal parameters to the
assembly's actual components — the functor-application shape, with the library as the functor and
`bind` as its argument list. Because binding is total and explicit, it is unambiguous by
construction: the two-same-type-components case that type dispatch answered wrongly is answered
here simply by writing two different `bind` values, and nothing has to be disambiguated after the
fact. Checks 1–2 run once the library is resolved (they need only the declared role set); check 3
runs once the assembly's components are mounted (§4.7 resolution).

**What replaces the old interface check.** A `bind` whose *keys* are all correct but whose *value*
names a component that does not actually expose a variable the library's edges reference is **not**
caught here — it is caught at flatten, when the expanded edge `Fuel.w_0 → Spread.w0` becomes
`LandfireFuel.w_0 → RothermelStatic.w0` and `RothermelStatic.w0` fails to resolve
(`unresolved_scoped_ref`, `esm-libraries-spec.md` §4.7.5 / line 380). This is the same diagnostic,
at the same point, that a hand-authored edge to a nonexistent variable produces today. The mechanism
introduces no new class of "bad binding" — a bad binding is just a bad edge, discovered where all
bad edges are.

### 4.2 Expansion and the role-substitution occurrence surface (normative)

Once every role of an import edge is bound, the entry expands: each edge in the library's
`coupling` array is emitted into the assembly's effective coupling sequence with **every
role-named top-level segment rewritten to its bound actual**. A role bound to a dotted path
(`Parent.Child`) replaces the single role segment with the full path, so `Fuel.w_0` under
`bind: { "Fuel": "Parent.Child" }` becomes `Parent.Child.w_0` (a well-formed §4.6 reference).

The rewrite is **one simultaneous substitution** (role → actual for all roles at once; the §9.7.7
transitive-rename *discipline*), but it is applied over a **coupling-specific occurrence surface,
enumerated here** — the §9.7.7 occurrence list (index-set keys, metaparameter expression sites,
template scope keys, template-body free names) does **not** cover coupling edges, so this list is
normative for coupling-library expansion and is new work, not a reuse of the §9.7.7 site list.
A role name occurs, and is rewritten, at exactly these sites of a library edge:

| Entry field | Occurrence of a role name | Present in |
|---|---|---|
| `from`, `to` | top-level segment of the scoped reference | `variable_map` |
| `systems[]` | each array element (a bare system name) | `couple`, `operator_compose` |
| `connector.equations[].from` / `.to` | top-level segment of the scoped reference | `couple` |
| `connector.equations[].expression` | top-level segment of every scoped reference in the Expression | `couple` |
| `transform` (Expression form) | top-level segment of every scoped reference in the Expression | `variable_map` |
| `apply_expression_template` node `bindings` **values** | top-level segment of each bound scoped reference — a free-variable target, not an ordinary operand, so it is enumerated explicitly (cf. §9.7.7 `rebind`); an `apply_expression_template` node may nest inside **any** Expression this surface already visits — a `transform`, a `connector` `expression`, **or** any `event` Expression (`conditions[]`, `affects[]`/`affect_neg[]` `.rhs`, `trigger.expression`) — so its `bindings` values are rewritten wherever it occurs | `variable_map`, `couple`, `event` |
| `translate` map | each key **and** each value (both are variable/system references) | `operator_compose` |
| `conditions[]` | top-level segment of every scoped reference in each condition Expression | `event` |
| `affects[]`, `affect_neg[]` | top-level segment of `.lhs` (target-variable reference) and of every scoped reference in `.rhs` (Expression) | `event` |
| `trigger.expression` | top-level segment of every scoped reference in the Expression (the `condition` trigger form only; `periodic` / `preset_times` triggers carry no references) | `event` |
| `functional_affect` | top-level segment of each entry of `read_vars`, `read_params`, `modified_params` | `event` |
| `discrete_parameters[]` | top-level segment of each scoped-parameter reference | `event` |

The `event` rows enumerate every reference-bearing field of a §5.6 cross-system event
(`esm-schema.json` `CouplingEvent`); an implementation supporting `event` in libraries MUST rewrite
all of them. `callback` entries and edge-level `expression_template_imports` do **not** appear in
this table because §10.9 forbids both inside a library (they are not role-substitutable — see §3);
they are rejected at library validation, never reached at expansion.

Non-reference fields (`transform` *string* values, `factor`, `lifting`, `description`, `event_type`,
`name`, `handler_id`, `root_find`, `reinitialize`, literal Expression operands) copy unchanged. An
**opaque `config` bag** — a `functional_affect`'s `config` (`additionalProperties: true`) — is
copied verbatim and is **not** a substitution surface: a role reference buried inside it could not
be rewritten, so a library MUST NOT hide a component reference there (author it in a structured
`read_vars` / `read_params` / `modified_params` slot, which the table above rewrites). The
variable-name correspondence *within* an edge — `w_0` on
the `Fuel` side, `w0` on the `Spread` side — is fixed by the library body and needs no per-variable
remapping: `bind` names *components*, and each component fixes its own variable spellings. (A
single library reused across two variable-spelling-incompatible variants of one role would need a
per-role variable rename; deferred, §14.)

Beyond the two exclusions §10.9 *mandates* for every binding (`callback` entries and edge-level
`expression_template_imports`, §3), an implementation MAY *further* restrict the permitted entry
types — e.g. accept `variable_map` + `couple` only — and enforce that narrowing with
`coupling_library_illegal_payload`; if it does not narrow, it MUST support all four role-bearing
types (`variable_map`, `couple`, `operator_compose`, `event`) and rewrite every site in the table
above. The table is the contract either way.

### 4.3 Timing, ordering, and round-trip

**`coupling_import` is a coupling entry, and coupling entries resolve at flatten.** Unlike the
§9.7.10 template-injection forms — which run *before* the §9.6.3 fixpoint because they must lower
operators — a `coupling_import` produces only coupling edges, and coupling edges are resolved by
the flattening algorithm (`esm-libraries-spec.md` §4.7.5; `esm-spec.md` §10.7, "Flattening is the
process of resolving all coupling rules"). So `coupling_import` expands **at flatten time**, as a
**new sub-step of §4.7.5**. Subsystem mounting and template-import resolution are *not* part of
§4.7.5 — they run earlier, at load, under §2.1b / §2.1c ("before validation or any other
processing"), so by the time §4.7.5 runs every `bind` target and every library edge already
resolves against fully-mounted components. Within §4.7.5 the expansion sub-step is inserted
*after* the variable-namespacing step (§4.7.5 step 2, itself preceded by the step-1 reaction-system
ODE derivation) and *before* the coupling-rule step (§4.7.5 step 3). Expanded edges are spliced
into the coupling sequence **in the position of the import entry**, preserving `coupling`-array
order; two import entries never interleave. It is expressly **not** in the §9.7.10 pre-fixpoint
injection regime.

**Round-trip.** Because expansion is a flatten-time step and not a load-time construct consumed by
the fixpoint, the source document round-trips with the `coupling_import` entry **intact** — exactly
like every other coupling entry, and unlike the §9.7.10 injection *fields* (`expression_template_imports`
on an edge), which the spec's composition-form regime subsumes at emit. The canonical serialized
`coupling` array keeps `{ type, ref, bind }`; the *flattened* system contains the expanded edges.
This is the spec's standing principle applied unchanged: **source files retain authored coupling
structure; flattening resolves it.** An assembly that inlines the library's edges by hand and an
assembly that imports them produce byte-identical *flattened* systems (§11), because both resolve
at the same §4.7.5 step; they differ only in their source `coupling` array, which is the point.
Concretely, expansion is inserted **between §4.7.5 step 2 (namespacing) and step 3 (apply coupling
rules)**, so the expanded edges *are* the coupling rules step 3 applies and step 4 records in the
flattened system's "which coupling rules were applied" metadata (§4.7.5 step 4) — the recorded
rules are the expanded edges, never the `coupling_import` indirection, which is why byte-identity
covers the flattened metadata and not merely the equations. (The `coupling_import` source entry is
retained only in the *source* document, a separate artifact from the flattened system.)

Two independent import edges referencing the same library with *different* `bind` maps expand to
two independent edge sets — the multiple-instantiation payoff that type dispatch structurally
cannot produce.

## 5. Deleting `coupletype` (§5, §7)

`coupletype` existed to key the type dispatch that §4.1 name binding replaces. With dispatch
gone, the field carries no meaning the format acts on — it is already, per its own §5/§7 gloss,
"informational." Delete it:

- **Schema.** Remove the `coupletype` property from `$defs/Model` and `$defs/ReactionSystem`
  (`esm-schema.json:1292,1569`) and the four binding-mirrored copies. Both defs are
  `additionalProperties: false`, so any document still carrying `coupletype` now fails validation
  with a clear unknown-property error — the loud, intended clean-break failure, no silent ignore.
  Unlike the template-library RFC's `template_import_version_too_old`, this RFC introduces **no**
  version gate for the new `coupling_roles` / `coupling_import` constructs: 0.8.0 is a clean break,
  and `additionalProperties: false` on the document root (rejecting a stray `coupling_import` or
  `coupling_roles` in a sub-0.8.0 file that lacks the new `oneOf`/`anyOf` branches) is the sole,
  sufficient guard. The asymmetry is deliberate — the template constructs could be *silently*
  mis-lowered by an old engine, whereas these fail schema validation outright.
- **Bindings.** Remove the field from each language's `Model` / `ReactionSystem` type and from
  every construction/clone site (mechanical field removal; the field is never read for behavior —
  confirmed across all five bindings, no control-flow change).
- **Spec.** Drop the `coupletype` rows from the §5 (`esm-spec.md:993`) and §7 (`:1631`) field
  tables and scrub it from every example block (`:890`, `:1029`, `:1069`, `:1452`, `:3047`).
- **Rig (EarthSciModels).** Strip `coupletype` from every component `.esm` (mechanical), and
  reissue the `couplings/*.esm` documents as §10.9 coupling-library files (roles + edges, no stub
  models) — turning the migration fossils into live, importable libraries.

Human-readable role labeling is not lost: a coupling library's `coupling_roles` names and
`description`s carry the role semantics at the point of reuse, and a component's `metadata.tags`
carry any coarse "this is a fuel model" labeling far better than a single dispatch string did.

## 6. Worked example — the Rothermel fuel coupling, reused and instantiated

**The library** (`../earthscimodels/couplings/rothermel_fuel.esm`), authored once — roles are
names with optional descriptions; the edges themselves state the variable correspondence:

```jsonc
{
  "esm": "0.8.0",
  "metadata": { "name": "RothermelFuelCoupling",
    "description": "Anderson-13 fuel properties → Rothermel (1972) spread inputs." },
  "coupling_roles": {
    "Fuel":   { "description": "fuel-property source" },
    "Spread": { "description": "Rothermel spread model" }
  },
  "coupling": [
    { "type": "variable_map", "from": "Fuel.sigma", "to": "Spread.sigma", "transform": "param_to_var" },
    { "type": "variable_map", "from": "Fuel.w_0",   "to": "Spread.w0",    "transform": "param_to_var" },
    { "type": "variable_map", "from": "Fuel.delta", "to": "Spread.delta", "transform": "param_to_var" },
    { "type": "variable_map", "from": "Fuel.M_x",   "to": "Spread.Mx",    "transform": "param_to_var" },
    { "type": "variable_map", "from": "Fuel.h",     "to": "Spread.h",     "transform": "param_to_var" }
  ]
}
```

**The common case** — one fuel, one spread model. `wildlandfire.esm` replaces five inline edges
with one entry that names the two components it wires:

```jsonc
{ "type": "coupling_import",
  "ref":  "../earthscimodels/couplings/rothermel_fuel.esm",
  "bind": { "Fuel": "FuelModelLookup", "Spread": "RothermelFireSpread" } }
```

**The multiple-instantiation case** — the failure type dispatch cannot express. An assembly with
two fuel sources (a static LANDFIRE fuel and a dynamic-load fuel) feeding two spread models simply
writes two imports with different binds; the same library instantiates twice into two independent
wirings, with no ambiguity to resolve because each binding is explicit:

```jsonc
{ "type": "coupling_import", "ref": ".../rothermel_fuel.esm",
  "bind": { "Fuel": "LandfireFuel", "Spread": "RothermelStatic"  } },
{ "type": "coupling_import", "ref": ".../rothermel_fuel.esm",
  "bind": { "Fuel": "DynamicFuel", "Spread": "RothermelDynamic" } }
```

**The generic-reuse case** — one library, many bindings. A `loader_to_cartesian_regrid` library
with roles `{ Loader, Regridder }` is imported three times in `wildlandfire.esm` — terrain, fuel,
met — instead of three near-identical inline edge sets. Each loader is routed to its **own**
regridder, so no two imports share a `Regridder` bind and no `param_to_var` target is driven twice
(§7):

```jsonc
{ "type": "coupling_import", "ref": ".../loader_to_cartesian_regrid.esm",
  "bind": { "Loader": "USGS3DEP", "Regridder": "TerrainRegrid" } },
{ "type": "coupling_import", "ref": ".../loader_to_cartesian_regrid.esm",
  "bind": { "Loader": "LANDFIRE",  "Regridder": "FuelRegrid"    } },
{ "type": "coupling_import", "ref": ".../loader_to_cartesian_regrid.esm",
  "bind": { "Loader": "ERA5",      "Regridder": "Era5Regrid"    } }
```

If a bind is wrong — say `RothermelStatic` has no parameter `w0` — the edge
`LandfireFuel.w_0 → RothermelStatic.w0` fails at flatten with `unresolved_scoped_ref` naming
`RothermelStatic.w0`, exactly as the equivalent hand-authored edge would.

## 7. Determinism and flatten semantics

Expansion is a pure structural rewrite over ordered inputs, so it is deterministic and
round-trip-stable:

- Binding is a total explicit map (§4.1) — there is **no search, no scan, no "pick the first."**
  Every role's actual is written down, so the resolved wiring is a function of the source bytes
  alone.
- Expanded entries are spliced at the import entry's position and, within one import, in the
  library's `coupling`-array order. Two imports never interleave.
- Substitution is one simultaneous role→actual rewrite over the §4.2 occurrence surface.

**No new merge semantics.** `coupling_import` introduces new *sources* of ordinary coupling
entries, not new kinds of entry. After expansion the edges enter §4.7.5 exactly as inline edges
do, and the guarantee this RFC rests on is precisely that equivalence: *whatever §4.7.5 does with a
given set of edges, it does identically whether those edges were authored inline or produced by an
import.* It is **not** a claim about any specific order-dependent failure — the flattening
algorithm is commutative by construction (`esm-libraries-spec.md` line 442, "the order of entries
in the `coupling` array does not affect the final result"), so the RFC neither asserts nor relies
on a "first edge wins, second edge fails" outcome. Two points need stating because expansion
happens *inside* flatten:

- **A mis-bind surfaces as `unresolved_scoped_ref`, but over the *expanded* edges, not the source.**
  That code is defined in the structural-validation table (`esm-libraries-spec.md` §3 / line 380)
  and today runs on the *loaded, pre-flatten* representation — where a `coupling_import` is still
  `{type, ref, bind}` and the expanded edges do not yet exist, so the load-time pass cannot see them.
  A conforming implementation MUST therefore run the coupled-system reference resolution over the
  *expanded* edge set (§10.10.2) rather than the source `coupling` array; a bound component that
  lacks a referenced variable then fails with `unresolved_scoped_ref`, the same diagnostic a
  hand-authored edge to a nonexistent variable produces. Whether that runs inside the flatten pass or
  as a separate coupled-system validation over the flattened form is a binding choice (the reference
  binding catches it via `expand_coupling_imports` → validate; auto-folding it into a single
  `validate()`/`flatten()` call is a documented parity follow-up); the requirement is only that the
  check sees the expanded edges. This is what makes "a bad binding is just a bad edge, caught where
  all bad edges are" literally true. A non-additive derivative collision remains
  `ConflictingDerivativeError` (`esm-libraries-spec.md` :568, :618).
- **A double-driven target is neither created nor specially diagnosed by imports.** Two edges (two
  imports, or an import and an inline edge) whose `param_to_var` targets collide on one parameter
  are exactly as well- or ill-formed as two inline edges doing the same, and are handled by
  whatever §4.7.5 already does with an over-determined target — identically for both origins, with
  no bespoke "double-drive" code. Binding two roles onto one component that is then driven twice is
  easy to do by accident, so the corrected §6 generic-reuse example routes each loader to its *own*
  regridder for exactly this reason; the case is left permitted (§14.4) but authors should read a
  shared `param_to_var` target as a smell.

## 8. Diagnostics (new §10.11; mirrored into the §9.6.6 table)

Named for parity with the §9.7 template-import codes (`template_import_unresolved`,
`template_import_not_library`, `subsystem_ref_is_template_library`, …). No interface- or
auto-bind-related codes exist, because neither concept does.

| Code | Raised when |
|---|---|
| `coupling_import_unresolved` | A `coupling_import` `ref` failed to load or parse (reports path/URL and cause). Mirrors `template_import_unresolved`. |
| `coupling_import_not_library` | A `coupling_import` `ref` targets a document that is not a pure coupling-library file (§10.9). |
| `subsystem_ref_is_coupling_library` | A §4.7 subsystem `ref` targets a coupling-library file. |
| `template_import_is_coupling_library` | A §9.7.2 template import targets a coupling-library file. |
| `coupling_library_illegal_payload` | A coupling-library file declares `models` / `reaction_systems` / `data_loaders` / `domain` / `index_sets` / `metaparameters` / `expression_templates` (§10.9 purity); **or** contains a `callback` entry or a library edge carrying `expression_template_imports` (§10.9 — neither is role-substitutable, §3); **or** carries a library edge whose `transform` template would expand to a rewrite-target operator (`grad` / `div` / spatial `D`), which the post-fixpoint flatten-time expansion could never lower (§3 timing carve-out); **or** (if the binding further restricts entry types) an entry type it does not permit. |
| `coupling_library_nested_import` | A coupling-library file contains a `coupling_import` entry (v1 forbids layering). |
| `coupling_edge_unknown_role` | A library edge's top-level system segment, at any §4.2 occurrence site, is not a declared role. |
| `coupling_role_unused` | A declared role appears at no §4.2 occurrence site in any library edge. |
| `coupling_import_unknown_role` | A `bind` key names a role the referenced library does not declare. |
| `coupling_import_role_unbound` | A role the referenced library declares has no `bind` entry (binding is total; there is no auto-bind). |
| `coupling_import_bind_not_a_component` | A `bind` value does not resolve to a top-level or subsystem component in the assembly. |

A bound component that resolves but lacks a variable the library's edges reference is **not** a new
code: it surfaces at flatten as the existing `unresolved_scoped_ref` (§4.1, §7).

## 9. Schema changes (`esm-schema.json`, 0.8.0 — in-progress clean break, no bump)

1. **Remove** `coupletype` from `$defs/Model.properties` (`:1292`) and
   `$defs/ReactionSystem.properties` (`:1569`). (Both are `additionalProperties: false`; nothing
   else changes.)
2. **Add** a top-level optional `coupling_roles` property — descriptor carries only an optional
   `description`, no structural contract:

   ```jsonc
   "coupling_roles": {
     "type": "object",
     "additionalProperties": {
       "type": "object", "additionalProperties": false,
       "properties": {
         "description": { "type": "string" }
       }
     },
     "description": "Coupling-library formal component roles (§10.9). Present only in a coupling-library file, which pairs it with a role-scoped `coupling` array and declares no models/loaders."
   }
   ```

   **And add a fifth branch to the document root's payload-presence `anyOf`** (`esm-schema.json:12`
   — today `{models} | {reaction_systems} | {data_loaders} | {expression_templates}`):
   `{ "required": ["coupling_roles"] }`. This is load-bearing, not cosmetic: a coupling-library file
   declares *none* of those four payloads, so without this branch it fails root-schema validation
   (step 1) and never reaches any resolver check — exactly as a template-library file would have
   without its `expression_templates` branch. Mirror the branch into all four schema copies.
3. **Add** `CouplingImport` to the `CouplingEntry` `oneOf` (`:2664` — currently a clean 5-way
   `oneOf` discriminated by `type` const; a 6th `$ref` slots in with no other change):

   ```jsonc
   "CouplingImport": {
     "type": "object", "additionalProperties": false,
     "required": ["type", "ref"],
     "properties": {
       "type": { "const": "coupling_import" },
       "ref":  { "type": "string", "description": "§4.7 reference to a coupling-library file." },
       "bind": {
         "type": "object", "additionalProperties": { "type": "string" },
         "description": "Total map from every library role name to a scoped component reference in the assembly (§10.10.1). No role may be omitted; there is no auto-binding."
       },
       "description": { "type": "string" }
     }
   }
   ```
   A `coupling_import` entry carries **no** `expression_template_imports` field (§10.8 injection is
   a property of the wiring entries, not of an import indirection); `additionalProperties: false`
   enforces this.
4. A document-shape constraint (expressed in prose in §10.9, enforced by the resolver): a file
   with `coupling_roles` is a coupling-library file and MUST NOT carry `models` /
   `reaction_systems` / `data_loaders` / `domain` / `index_sets` / `metaparameters` /
   `expression_templates`. JSON Schema can express the property exclusion via
   `not`/`dependentSchemas` if desired; the resolver check with `coupling_library_illegal_payload`
   is normative either way (JSON Schema alone under-constrains here, so the resolver check is
   required regardless). **Presence of top-level `coupling_roles` is the sole positive identifier
   of the file kind** (and the discriminant the cross-kind checks
   `subsystem_ref_is_coupling_library` / `template_import_is_coupling_library` test after loading a
   `ref`'s target): a document carrying both `coupling_roles` and a forbidden payload is classified
   deterministically as a *malformed coupling library* (`coupling_library_illegal_payload`), never
   as an assembly with a stray `coupling_roles`.

Propagate every change above — including the root-`anyOf` branch (item 2) — to all schema
carriers, which are **not** the four the earlier drafts listed. The canonical `esm-schema.json` is
copied verbatim to the four JSON mirrors by `scripts/sync-schema.sh`:
`pkg/earthsci-ast-py/src/earthsci_ast/data/esm-schema.json`, `pkg/earthsci-ast-rs/src/esm-schema.json`,
`pkg/earthsci-ast-go/pkg/esm/esm-schema.json`, and `pkg/EarthSciAST.jl/data/esm-schema.json`
(Julia — omitted from the earlier list). `sync-schema.sh` *also* regenerates the **TypeScript**
binding's embedded schema (`pkg/earthsci-ast-ts/src/embedded-schema.ts`, used by the Ajv validator),
but it does **not** regenerate the json2ts type surface — run `npm run generate-types` in
`pkg/earthsci-ast-ts` for `src/generated.ts`. Rust and Go additionally carry
hand-written typed structs that the JSON copy does not update:
`pkg/earthsci-ast-rs/src/types.rs` (delete the `coupletype` field on `Model` / `ReactionSystem`
plus the ~40 `coupletype: None` construction/clone sites across the crate) and
`pkg/earthsci-ast-go/pkg/esm/types.go` (delete the `CoupleType` field on both structs). Python and
Julia are schema-driven and carry no typed `coupletype`.

## 10. Spec changes (`esm-spec.md`, `esm-libraries-spec.md`)

- **§5 / §7 field tables and examples:** delete the `coupletype` rows and scrub the field from
  all example blocks (line references in §5 above).
- **§10.1 entry-type table** (`esm-spec.md:2763`): add the `coupling_import` row.
- **New §10.9 "Coupling-library files":** the pure-document-kind definition (§3 here), purity
  constraints (including the `callback`-entry and edge-level-`expression_template_imports`
  exclusions), role descriptors, and the role-scoped-resolution rule (§4.6 suspension) judged over
  the §4.2 occurrence surface.
- **New §10.10 "Coupling imports and role binding":** the `coupling_import` entry, the §4.1
  total-binding matching rule, the component-reference resolution rule for `bind` values (distinct
  from §4.6 variable resolution), the §4.2 substitution occurrence-surface table, and §4.3
  timing/ordering/round-trip.
- **New §10.11 "Coupling-import diagnostics":** the §8 table, cross-linked from the §9.6.6 master
  table.
- **Existing §10.8 cross-reference** (`esm-spec.md:2901`, coupling-entry template injection): note
  the contrast — that section's injection *fields* are pre-fixpoint composition forms that do not
  survive emit (§9.7.10), whereas a `coupling_import` *entry* is authored coupling structure that
  resolves at flatten and is preserved (§4.3). The two must not be conflated.
- **`esm-libraries-spec.md` §4.7.5 (flattening algorithm):** add the `coupling_import` expansion
  step — after subsystem resolution, before coupling-rule substitution — and state that expanded
  edges are indistinguishable from inline edges thereafter.
- **§4.6 note:** the "coupling references must be fully qualified from the top-level system name"
  rule (`esm-spec.md:542`) is satisfied *post-binding* for library edges; inside a library file
  the top-level segment is a role, checked by role membership, and qualified to a real component
  when the import edge binds it.

## 11. Conformance fixtures

- **Library validity:** a well-formed coupling library round-trips; libraries that declare a
  `model`, contain a `callback` entry, or carry an edge-level `expression_template_imports` map
  (each `coupling_library_illegal_payload`), reference an undeclared role
  (`coupling_edge_unknown_role`), declare an unused role (`coupling_role_unused`), or nest an
  import (`coupling_library_nested_import`) each fail with the named code. A separate case confirms
  a bare coupling-library file (`coupling_roles` + `coupling`, no `models`/loaders) **passes**
  root-schema validation — the regression guard for the §9 root-`anyOf` branch.
- **Binding — total and checked:** an import binding every role resolves; an import omitting a
  declared role raises `coupling_import_role_unbound`; a `bind` key naming an undeclared role
  raises `coupling_import_unknown_role`; a `bind` value that is not a component raises
  `coupling_import_bind_not_a_component`.
- **Mis-bind caught downstream:** an import whose `bind` is structurally complete but points a role
  at a component lacking a referenced variable flattens to `unresolved_scoped_ref` naming the
  missing `Component.var` — the same failure as the equivalent inline edge (proving no bespoke
  contract is needed).
- **Equivalence:** an assembly using a `coupling_import` and an otherwise-identical assembly with
  the edges inlined flatten to the **same** coupled system (byte-identical post-flatten, *including*
  the flattened metadata's "coupling rules applied" list, which records the expanded edges in both
  builds — §4.3), proving expansion is pure sugar over the existing coupling layer. The natural
  corpus: `wildlandfire.esm` before/after factoring the Rothermel/NFDRS stack — the numerics
  (elevation/fuel/`r_eff` means) must not move. The source documents differ (import entry vs. inline
  edges); the flattened systems do not.
- **Multiple instantiation:** two imports of one library with distinct `bind` maps produce two
  independent, non-interfering edge sets; a library exercising every §4.2 occurrence site — a
  `couple` with a `systems` array and connector equations, an `operator_compose` with a `translate`
  map, a `variable_map` whose `transform` is an `apply_expression_template` with role-scoped
  `bindings` values, and an `event` referencing roles in its `conditions` / `affects` /
  `discrete_parameters` — rewrites every role occurrence and leaves every non-reference field
  (including any `functional_affect.config` bag) byte-unchanged.
- **Cross-kind rejection:** a coupling library targeted by a subsystem ref
  (`subsystem_ref_is_coupling_library`) or a template import
  (`template_import_is_coupling_library`), and a `coupling_import` targeting a model
  (`coupling_import_not_library`).
- **`coupletype` removal:** a document carrying `coupletype` fails
  (`additionalProperties`/unknown-property), across a model and a reaction system.

## 12. Binding implementation notes

- **Reused:** reference resolution (§4.7 formats, `${VAR}`, URL, cycle detection), already
  implemented for template imports; `coupling_import` calls the same resolver. The
  simultaneous-substitution *discipline* of §9.7.7 is reused too.
- **New:** the §4.2 occurrence-surface rewrite (coupling `from`/`to`, `systems[]`, connector
  equations, `transform` Expressions *including* `apply_expression_template` `bindings` values,
  `translate`, and the `event` reference fields — `conditions` / `affects` / `affect_neg` /
  `trigger.expression` / `functional_affect` read/modified lists / `discrete_parameters`) — this is
  a **new substitution surface**, not a call into the existing §9.7.7 rename path, which does not
  touch coupling entries; the library-file purity checks (including the mandatory `callback` and
  edge-injection exclusions) + the role-scoped-resolution checks; the component-reference
  resolution of `bind` values; and the §4.1 total-binding validation. The matching logic is now a
  trivial map lookup (no search, no interface satisfaction), which is *less* code than the earlier
  auto-bind design, at the cost of requiring every role to be named.
- **Ordering:** expansion is a step inside §4.7.5 flatten (after subsystem resolution, before
  coupling-rule substitution), **not** in the §9.7.10 pre-fixpoint injection pass. Bindings that
  already implement §4.7.5 have the natural insertion point.
- **`coupletype` deletion** is a mechanical field removal across all five bindings, with no
  control-flow change since the field is never read.
- **Round-trip:** the `coupling_import` entry is preserved by the source serializer like any
  coupling entry; emitters need a `CouplingImport` case but **no** reverse-factoring of expanded
  edges back into an import — expansion is one-way at flatten, and the flattened system is a
  separate artifact from the source document.

## 13. Phasing

1. Schema: remove `coupletype`, add `coupling_roles` + `CouplingImport` (all mirrors). Land the
   `coupletype` scrub across the spec and the EarthSciModels component files in the same change —
   it is independent of the import machinery and unblocks the clean break immediately.
2. One reference binding (Python, the CI gate of record): library parse + purity check, the §4.1
   total-binding validation, §4.2 expansion at flatten, the diagnostics, and the equivalence
   fixture.
3. Reissue `EarthSciModels/couplings/*.esm` as coupling-library files; factor the Rothermel/NFDRS
   stack out of `wildlandfire.esm` as the first real consumer and confirm byte-identical flatten.
4. Julia and Rust bindings to parity (they already carry the §4.7 resolver and the §4.7.5 flatten
   this builds on); then TypeScript and Go.

## 14. Open questions

1. **Per-role variable rename.** Deferred (§4.2). If a single library must serve two
   variable-spelling-incompatible variants of one role (same role, different variable spellings),
   a `rename` sub-map per role — the coupling analogue of §9.7.7 free-name rebinding — would
   express it. No forcing use case yet; a coupling library is normally written for specific
   variable spellings, so the role abstraction is over *component instances*, not incompatible
   variable vocabularies.
2. **Library layering.** Deferred (§3): coupling libraries importing coupling libraries. The
   §9.7.4 depth-first-post-order + diamond-dedup machinery would carry it; deferred for lack of a
   use case and to keep v1's order trivially acyclic.
3. **Permitted entry types in a library.** Two exclusions are *settled*, not open: a library may
   never contain a `callback` entry or an edge-level `expression_template_imports` map, because
   neither is role-substitutable (§3, §4.2). The open question is only whether to *further* narrow
   the four remaining role-bearing types (`variable_map`, `couple`, `operator_compose`, `event`).
   Recommending the full four (no further restriction) keeps libraries as expressive as inline
   coupling; a `variable_map` + `couple` subset is simpler to implement first. Proposed: all four
   normative, a narrower subset allowed as a documented capability gap
   (`coupling_library_illegal_payload`).
4. **Self-binding.** Nothing forbids `bind: { A: X, B: X }` (both roles to one component) or a role
   bound to a component the library then couples to itself. The expanded edges are ordinary and
   validated ordinarily (a genuine self-loop that over-drives a target fails at §4.7.5). Left
   permitted; flagged in case a static "distinct-binding" warning is wanted.
