# RFC — Import-edge renaming, namespacing, and free-name rebinding for template libraries

**Status:** Draft (proposed changeset for review)
**Bead:** TBD (file on acceptance; the beads DB is offline at authoring time)
**Affects spec version:** 0.8.0 (rides *inside* the in-progress clean break; no bump, no compat shims)
**Scope:** `esm-spec.md` §9.7 (new §9.7.7; §9.7.2/§9.7.4/§9.7.5 touched; §9.6.6 table),
`esm-schema.json` `$defs/TemplateImport` (+ 4 binding mirrors + the TS embedded schema),
conformance fixtures, Julia reference implementation. **Binding ports (Python, Rust,
TypeScript, Go) are explicitly a later wave** (§10); this RFC lands spec + schema + Julia +
fixtures only. Library *content* changes (e.g. ESD adopting the mechanism) are out of scope —
they live in `../earthscidiscretizations`.
**Depends on:** the template-library-imports RFC (§9.7 as shipped: imports, `only`,
`bindings`, metaparameters, DFS-post-order effective sequence, deep-equal merge). Renaming
only translates names at import edges; the §9.6.3 engine, the §9.7.3 composer, and the
§9.7.6 folding machinery are untouched.

---

## 1. Motivation

The template-library-imports RFC deferred renaming: *"import renaming (`as` prefixes) —
deferred until a real collision that `only` + explicit `priority` cannot resolve is
exhibited."* The production-readiness audit of the EarthSciDiscretizations standard library
exhibited it, three ways at once — and none of the three is a *priority* problem, so the
deferral's escape hatches do not apply:

1. **One family, two instances.** Every ESD grid family declares generic names — the
   cartesian family's index set `x`, metaparameter `N`, templates `dx`/`x_coord`; the
   lat-lon family's `lon`/`lat`; the regridding pair's `src_cells`/`tgt_cells`. Deep-equal
   merge semantics (§9.7.4/§9.7.5) make importing the family twice at different sizes a
   loud conflict (`template_import_index_set_conflict` — correctly: `x` cannot be both size
   8 and size 16). A two-grid model (fine/coarse, nested domains, a convergence pair in one
   file, two regrid pairs) is simply inexpressible.
2. **Consumer-name collisions.** A model that already owns `lon`/`lat` (very common) cannot
   import a library that also declares them with different sizes; `only` filters templates,
   not index sets or metaparameters.
3. **Reserved free names.** The MPAS divergence rule's body reads five free-name keyed
   factors — `areaCell`, `dvEdge`, `nEdgesOnCell`, `edgesOnCell`, `edgeSignOnCell` — that the
   consumer MUST expose as bare-name arrays (today: observed aliases of a mounted mesh
   subsystem, `areaCell := mesh.areaCell`, resolved by the `_factor_scope` bare-name →
   unique-shallowest-dot-suffix rule at tree-walk). Bare-name wiring reserves those five
   names globally in the consuming model and caps the mechanism at ONE mesh per component.

Copying-and-renaming library files violates the library's no-edit bar and forfeits
upstream fixes. The missing primitive is a load-time translation of imported names into
the importer's vocabulary — per edge, so each edge is an *instance*.

## 2. Summary of changes

| # | Change | Where |
|---|--------|-------|
| A | **`prefix`** on a `TemplateImport` entry: every surviving exported name (templates after `only`, index sets, metaparameters left open by the edge's `bindings`) is renamed to `<prefix>.<name>`, transitively through the imported declarations. | schema + §9.7.2 + §9.7.7 |
| B | **`rename`** map (exported name → importer-visible name): fine-grained renames; entries override `prefix`. Unknown keys error; targets are grammar-checked; collisions error. | schema + §9.7.2 + §9.7.7 |
| C | **`rebind`** map (free name → replacement variable name): rewrites free variable names in imported template bodies/matches and ragged keyed factors (`areaCell` → `meshA.areaCell`). Unknown (non-occurring) keys error. | schema + §9.7.2 + §9.7.7 |
| D | **Merge semantics clarified**, not changed: renaming applies before the §9.7.4/§9.7.5 merge, so different renames of one file are distinct registrations and identical edges still dedupe. | §9.7.4/§9.7.5 |
| E | Four new stable diagnostics (§6). | §9.6.6 + §9.7.9 |

**Explicitly NOT done:** renaming at §4.7 subsystem edges (subsystems already namespace
their contents by mount name); renaming rewrite-target *ops* (ops are an open namespace,
not declared names — see §8); any new dedup machinery (renaming reuses the existing
deep-equal merge unchanged); any change to §9.6.3 selection, §9.7.3 composition, or
§9.7.6 folding.

## 3. Design

### 3.1 The three fields (§9.7.2)

| Field | Meaning |
|---|---|
| `prefix` | Dotted identifier. Every surviving exported name without an explicit `rename` entry becomes `<prefix>.<name>`. |
| `rename` | Object, exported name → importer-visible name. Overrides `prefix` per name. |
| `rebind` | Object, free name → replacement variable name. Operates on the *free* (undeclared) names of the imported declarations. |

`rename` addresses **declared** names (templates, index sets, metaparameters); `rebind`
addresses **free** names (keyed factors and other free variable references). The domains
are disjoint by construction, and each map polices its own domain: a `rename` key that is
not exported errors, a `rebind` key that names a declared name errors with a pointer to
`rename`.

### 3.2 Edge pipeline and vocabulary (normative, §9.7.7)

Per edge, in order: resolve target in its own scope → `bindings` → `only` →
`prefix`/`rename`/`rebind` → merge. Therefore `only`, `bindings`, `rename`, and `rebind`
all speak the **target's export vocabulary** (post the target's own internal renames, pre
this edge's). Two consequences worth spelling out:

- At the edge that renames, bindings read naturally:
  `{ "ref": "./grid.esm", "prefix": "fine", "bindings": { "N": 16 } }` — you instantiate
  the library in its own vocabulary, then mount the result under a namespace.
- At a *deeper* edge, the renamed name IS the export name. A mid-layer library that
  imported the grid under `prefix: "g"` and left `N` open re-exports the metaparameter as
  `g.N`; its importer binds `{"g.N": 16}`; after another `prefix: "l"` the loader API binds
  `l.g.N`. Prefixes nest; there is exactly one name per instance at every level.

The alternative — post-rename vocabulary at the same edge (`bindings: {"fine.N": 16}`) —
was rejected: it makes the common one-liner clumsy without adding power, since deeper
edges already get the renamed vocabulary for free.

A corollary of the ordering: a metaparameter closed by the same edge's `bindings` is not
renameable (it no longer exists downstream), and a template filtered by `only` is not
renameable. Both are loud `template_import_rename_unknown_name` errors, which doubles as
typo protection — renames never invent names.

### 3.3 Transitivity (normative occurrence sites)

Renaming a name rewrites its declaration key AND every reference inside the surviving
imported declarations — never anything in the consumer's own text (the consumer authors
post-rename names directly):

- **index set** — registry key; `of` parent lists of ragged/derived definitions;
  `{"from": <name>}` references; the `wrt`/`dim` axis scalar fields of Expression nodes in
  `body` **and `match`** (param-shadowed per §9.6.1). The `match` clause is the load-bearing
  one: a rule matching `D(f, wrt: "x")` imported under `prefix: "fine"` becomes an instance
  matching `D(f, wrt: "fine.x")` — instances fire only on their own axis.
- **metaparameter** — declaration key; bare-string occurrences in expression positions of
  bodies/matches (param-shadowed); names inside metaparameter expressions in the
  structural integer sites (`size`, dense `ranges`, `regions`). Downstream binding sites
  close it under the new name.
- **template** — scope key; `apply_expression_template.name` references in surviving
  bodies. (The target's own §9.7.3 composition has usually inlined these already; a
  binding that composes lazily MUST still rewrite them.)

Renames and rebinds apply as ONE simultaneous substitution: swaps are well-defined,
chains do not cascade, and application order cannot matter.

### 3.4 Free-name rebinding semantics

The free names of an edge's surviving declarations are: strings in variable-reference
positions of template bodies/matches (including `aggregate` `args` entries and `index`
gathers) plus ragged `offsets`/`values` factors — minus params (shadowed per declaration)
and minus declared names. Pinned decisions, with rationale:

- **Rebind of a non-occurring name = error** (`template_import_rebind_unknown_name`), not
  a no-op. A silent no-op would leave the library's real factor contract in force while
  the consumer believes it redirected it — exactly the misconfiguration class (a typo'd
  `areaCel`) that §9.7's loud-conflict philosophy exists to catch. This matches the
  existing precedents: unknown `only` names and unknown `bindings` names both error.
- **Rebind of a bound index symbol = error** (`template_import_rename_invalid`). Range
  keys are object *keys*, unreachable by value substitution; "rebinding" `i` or `k` could
  only desynchronize a rule body.
- **Targets must be fresh** (`template_import_rename_collision` otherwise): a target
  colliding with a remaining free name would silently merge two factors (e.g. offsets and
  weights reading one array); colliding with a param or bound index would be captured at
  substitution time. Identity entries are no-ops (harmless, tool-friendly).
- **Dotted targets are ordinary §4.6 scoped references.** `areaCell → meshA.areaCell`
  produces exactly the reference the hand-written observed-alias pattern produces today;
  evaluation is the existing scoped-reference machinery's business. This both frees the
  bare names in the consumer and is the two-mesh mechanism: instance A rebinds its five
  factors to `meshA.*`, instance B to `meshB.*`.

### 3.5 Diamonds, dedup, instances (§9.7.4/§9.7.5)

Renaming precedes the merge, so the merge needs no new rules: the same file imported under
different renames yields differently-named definitions that register independently (two
instances — the point of the mechanism); edges identical in `ref`, instantiation, and
renames/rebinds yield deep-equal definitions that dedupe at first occurrence exactly as
today. There is deliberately **no dedup across renames**, and a shared dependency imported
via two differently-prefixed paths arrives twice under two namespaces — deterministic
duplication, the same trade every namespaced module system makes.

### 3.6 Match-rule instances and their limits

Both instances of an imported `match` rule register, each at its edge's §9.7.4 position,
with authored `priority` unchanged. Renaming distinguishes the *patterns* only through the
renamed names the pattern mentions:

- axis-carrying patterns (`wrt`/`dim` naming a library index set) become instance-specific
  — the two-grid fixture relies on this;
- a bare op + wildcard pattern (the current MPAS `{op: "div", args: ["F"]}`) is identical
  across instances: both register, both match every `div`, and the earlier edge wins every
  tie — the second instance is dead for auto-application.

The spec therefore carries guidance (§9.7.7): a library that intends per-grid
instantiation of an auto-applied rule SHOULD put the grid's identity in the pattern via a
scalar field that names a library index set (e.g. `{op: "div", args: ["F"],
dim: "cells"}` — renamed to `dim: "meshA.cells"` per instance). Whether ESD's MPAS rule
adopts that (and what the consumer-side `div` sugar then looks like) is an ESD decision
flagged for its maintainers; renaming deliberately does NOT touch ops, which are an open
namespace with structural matching, not declared names.

### 3.7 Identifier grammar

`prefix` and every `rename`/`rebind` **target**: one or more `[A-Za-z_][A-Za-z0-9_]*`
segments joined by single dots (`template_import_rename_invalid` otherwise). Keys are
never grammar-checked — they must match whatever the target actually exports (or whatever
occurs free), whatever that spelling is. The dot is the format's one namespace separator
(§4.6 scoped references, subsystem mounts, re-exported metaparameter names); reusing it
keeps renamed declared names and rebound scoped references visually and mechanically
uniform.

## 4. Determinism

Renaming/rebinding is a pure, per-edge, load-time string substitution over the resolved
scope: no filesystem enumeration, no evaluation, no new ordering inputs. Canonical bytes,
§9.6.3 selection and tie-breaks (the effective sequence is unchanged except for the names
in it), `MAX_TEMPLATE_EXPANSION_DEPTH`, and the §9.7.6 folding rules are all unaffected.
All bindings MUST produce byte-identical post-lowering ASTs for the §7 fixtures, or the
same rejection diagnostic.

## 5. Worked example — one cartesian grid library, two instances

**Library — `grid_uniform_1d.esm`** (generic names; never edited):

```json
{
  "esm": "0.8.0",
  "metadata": { "name": "grid_uniform_1d" },
  "metaparameters": { "N": { "type": "integer", "default": 4 } },
  "index_sets": { "x": { "kind": "interval", "size": "N" } },
  "expression_templates": {
    "dx": { "params": [], "body": { "op": "/", "args": [1, "N"] } },
    "central_D_x": {
      "params": ["f"],
      "match": { "op": "D", "args": ["f"], "wrt": "x" },
      "body": {
        "op": "aggregate", "output_idx": ["i"], "args": ["f"],
        "ranges": { "i": [2, { "op": "-", "args": ["N", 1] }] },
        "expr": { "op": "/", "args": [
          { "op": "-", "args": [
            { "op": "index", "args": ["f", { "op": "+", "args": ["i", 1] }] },
            { "op": "index", "args": ["f", { "op": "-", "args": ["i", 1] }] } ] },
          { "op": "*", "args": [2, { "op": "apply_expression_template",
                                     "args": [], "name": "dx", "bindings": {} }] } ] }
      }
    }
  }
}
```

**Consumer** — both instances in one model:

```json
{
  "esm": "0.8.0",
  "metadata": { "name": "two_grids" },
  "models": {
    "TwoGrids": {
      "expression_template_imports": [
        { "ref": "./grid_uniform_1d.esm", "prefix": "fine",   "bindings": { "N": 16 } },
        { "ref": "./grid_uniform_1d.esm", "prefix": "coarse", "bindings": { "N": 8 } }
      ],
      "variables": {
        "cf": { "type": "state", "units": "1", "shape": ["fine.x"] },
        "cc": { "type": "state", "units": "1", "shape": ["coarse.x"] }
      },
      "equations": [
        { "lhs": { "op": "D", "args": ["cf"], "wrt": "t" },
          "rhs": { "op": "D", "args": ["cf"], "wrt": "fine.x" } },
        { "lhs": { "op": "D", "args": ["cc"], "wrt": "t" },
          "rhs": { "op": "D", "args": ["cc"], "wrt": "coarse.x" } }
      ]
    }
  }
}
```

At load, per edge: the library resolves in its own scope (`dx` composes into the rule
body); `bindings` instantiate `N`; the prefix renames `x → fine.x` (transitively: the
registry key, and `wrt: "x"` inside the rule's `match`) and `dx → fine.dx`,
`central_D_x → fine.central_D_x`. The merged registry carries `fine.x` (16) and `coarse.x`
(8) without conflict; each rule instance fires only on its own axis; the expanded
equations hold per-instance ranges (`[2, 15]` vs `[2, 7]`) and spacings (`1/16` vs `1/8`,
AST divisions). This is the `import_rename_two_instances/` conformance fixture, golden
included. A convergence *pair* in one file is now a two-line difference of the same edges.

## 6. Diagnostics (into §9.6.6; gated like all of §9.7 by `template_import_version_too_old`)

| Code | Meaning |
|---|---|
| `template_import_rename_unknown_name` | `rename` names a name the target does not export at this edge (surviving exports = templates after `only`, index sets, metaparameters left open by `bindings`). |
| `template_import_rebind_unknown_name` | `rebind` names a name that does not occur free in the imported declarations — including naming a *declared* name (that is a rename, not a rebind). |
| `template_import_rename_collision` | Two names of one namespace mapped onto one target, or a renamed/rebound name collides with a name still in use inside the imported declarations (remaining free name, bound index symbol, template param, or another target). |
| `template_import_rename_invalid` | `prefix` or a rename/rebind target is not a valid dotted identifier; a rename/rebind map is malformed; or a `rebind` key addresses a bound index symbol. |

All four are resolver-level (`resolver_only` in `tests/invalid/expected_errors.json`):
the schema stays permissive (plain strings) so the grammar and name checks are
cross-binding-uniform diagnostics rather than schema-dialect artifacts.

## 7. Conformance fixtures

`tests/conformance/expression_templates/` (goldens generated by
`scripts/generate-template-import-goldens.jl`):

- `import_rename_two_instances/` — the §5 example, expanded golden.
- `import_rebind_keyed_factors/` — MPAS-style ragged keyed-factor rule
  (`row_count`/`row_cols`/`row_w`) rebound to `meshA_*` arrays; registry offsets/values
  AND body rewritten; a consumer variable named `row_count` coexists (un-reservation).
- `import_rename_diamond/` — one file imported thrice: identical renamed edges dedupe; a
  differently-prefixed edge registers distinctly; the equal-priority tie between the two
  axis-less rule instances is pinned by the §9.7.4 order (`y = 6 * x`).

`tests/invalid/template_imports/` (+ `expected_errors.json`, all `resolver_only`):
`rename_unknown_name.esm`, `rebind_unknown_free_name.esm`, `rename_collision.esm`,
`rename_invalid_identifier.esm`. `tests/valid/template_import_rename_lib.esm` backs the
collision fixture (two templates in one namespace) and joins the valid suite.

## 8. Alternatives considered

- **`as` on the ref string** (`"ref": "./grid.esm as fine"`): string micro-syntax inside a
  field that is otherwise a verbatim §4.7 reference; breaks URL refs containing spaces;
  gives no per-name control and no rebinding. Rejected for structured fields.
- **Silent no-op for unknown rename/rebind keys**: rejected — see §3.4; consistency with
  `only`/`bindings` unknown-name errors won.
- **Renaming ops** (so two MPAS mesh instances could split an axis-less `div` match):
  rejected — ops are an open namespace matched structurally, not declared names; the
  right fix is grid identity in the pattern (§3.6), which composes with renaming.
- **Dedup across renames** (recognize `fine.dx` ≡ `coarse.dx` modulo names): rejected —
  instances are the feature, and α-equivalence-modulo-renaming is exactly the kind of
  cleverness §9.7 has avoided; deep-equal on post-rename names is decidable at a glance.

## 9. Spec and schema changes

| Where | Change |
|---|---|
| §9.7.2 | Three new rows (`prefix`, `rename`, `rebind`) in the entry table. |
| new §9.7.7 | Normative semantics: edge pipeline, vocabulary, transitivity sites, rebinding, dedup, match-rule instances, grammar, version gate. (Worked example → §9.7.8, diagnostics pointer → §9.7.9.) |
| §9.7.4 | Renaming precedes the merge; distinct registrations across renames; identical edges still dedupe; tie behavior for identical patterns. |
| §9.7.5 | Index sets merge under post-rename names. |
| §9.6.6 | The §6 rows. |
| `esm-schema.json` | `$defs/TemplateImport`: `prefix` (string, minLength 1), `rename` / `rebind` (objects of non-empty strings); description updated. Mirrors + TS embedded schema via `scripts/sync-schema.sh`. |

## 10. Binding implementation notes — porting checklist (wave 2)

Julia (`pkg/EarthSciAST.jl/src/template_imports.jl`,
`_apply_edge_renames!`) is the reference and generated the goldens. **Python, Rust,
TypeScript, and Go port in a later wave**; the compliance matrix rows carry
Julia = implemented, others = pending until then. Per binding, the §9.7 import resolver
gains one step, called after `bindings` instantiation and `only` filtering, before the
scope merge:

1. Parse/validate the three fields: prefix + all targets against the dotted-identifier
   grammar (`template_import_rename_invalid`); maps must be string→string objects.
2. Check `rename` keys against the surviving export set (templates ∪ index sets ∪ open
   metaparameters) → `template_import_rename_unknown_name`.
3. Build per-namespace final-name maps (`rename` entry, else prefix-join, else identity);
   enforce per-namespace uniqueness → `template_import_rename_collision`.
4. Inventory the surviving declarations: free names (variable-reference positions,
   param-shadowed per template, plus ragged `offsets`/`values`; minus declared names),
   bound index symbols (`output_idx` entries + `ranges` keys, all nesting depths), and
   the union of all `params`.
5. Check `rebind` keys: declared → `template_import_rebind_unknown_name` (message points
   to `rename`); bound symbol → `template_import_rename_invalid`; not free →
   `template_import_rebind_unknown_name`.
6. Freshness guard: every changed metaparameter final and every rebind target must not
   hit remaining free names ∪ bound symbols ∪ params ∪ earlier new names →
   `template_import_rename_collision`.
7. Apply as ONE simultaneous substitution (drop identity entries): a declaration walk
   rewriting (a) bare strings in variable-reference positions via {metaparameter renames
   ∪ rebinds}, (b) `{"from": …}` values and `wrt`/`dim` scalar fields via the index-set
   map (param-shadowed), (c) `apply_expression_template.name` via the template map —
   while protecting structural scalar fields (`op`, `id`, `reduce`, `semiring`,
   `manifold`, `fn`, `table`, `side`, `attrs`, `members`, `from_faq`, the metaparameter
   skip set) and `of` lists; then re-key the three registries in order, rewriting
   registry `of` via the index-set map (registry `of` = parent index sets; range-level
   `of` = bound indices — do not conflate them).
8. Preserve declaration order through re-keying (the §9.7.4 sequence is positional).
9. Drive the shared fixtures: three goldens structurally byte-equal post-lowering; four
   invalid fixtures produce the exact codes; the §9.7.7 unit pins (re-export chains with
   dotted binding keys incl. the loader API, identity no-ops, rename-after-bindings
   unknown, rebind guards, grammar).

Estimated locus per binding: the module named in the template-library RFC §12 table
(`reference_resolution.py` / `ref-loading.ts` / `ref_loading.rs` / `subsystem_ref.go`
plus each `lower_expression_templates` sibling that hosts the §9.7 resolver).

## 11. Open questions

- Should ESD's MPAS-family rules move their mesh identity into the match pattern
  (§3.6) so auto-applied rules become per-mesh instantiable? (ESD repo decision;
  flagged to its maintainers.)
- Renaming at §4.7 subsystem edges — not needed so far (mount names already namespace),
  revisit only on a concrete case.
- A `hiding`/exclusion counterpart to `only` — no motivating case yet.
