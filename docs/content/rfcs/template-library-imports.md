# RFC — Template libraries, cross-file imports, and load-time metaparameters

**Status:** Draft (proposed changeset for review)
**Bead:** TBD (file on acceptance)
**Affects spec version:** 0.8.0 (rides *inside* the in-progress clean break; no bump, no compat shims)
**Scope:** `esm-spec.md` §1.1 / §2 / §4.7 / §9.6 / new §9.7, `esm-schema.json` (+ 4 binding
mirrors), conformance fixtures, and follow-up work in all five bindings. Discretization
*content* is explicitly **out of scope** — it lives in `../earthscidiscretizations`.
**Depends on:** the open-op-namespace-fixpoint-rewrite engine (§9.6.3 outermost-first +
priority + bounded fixpoint + `unlowered_operator` gate) being present in a binding before
that binding implements this RFC. Imports only *widen the rule set* handed to that engine;
nothing here touches the engine itself.

---

## 1. Motivation

§9.6.1 declares templates **component-local** and defers "top-level templates and
cross-component sharing … to a follow-up RFC". This is that RFC. The forcing use case is
the rewrite of [EarthSciDiscretizations](../earthscidiscretizations) — the standard
library of discretization rules that §9.6.8 promises — as a **layered, pure-data library
of `.esm` files**:

1. a *grid file* declares the index sets and geometry constants of a grid family;
2. an *interior-stencil file* references the grid file and defines the interior
   finite-difference/finite-volume operator as a named (match-less) template;
3. a *BC file* references the stencil file and wraps it into the complete auto-applied
   `match` rule on spatial `D` — a `makearray` whose interior region invokes the imported
   stencil and whose boundary-face regions encode the boundary condition (§9.6.8);
4. a *consuming model* imports the rule it wants and writes `D(c, wrt: lon)`.

Today the format cannot express any of the sharing edges above:

- `expression_templates` cannot appear outside a single `model`/`reaction_system`
  (§9.6.1), so there is no such thing as a rule *file*.
- A template `body` cannot reference another template
  (`apply_expression_template_recursive_body`, §9.6.3 constraint 2), so a BC layer cannot
  reuse an interior stencil; every BC variant would copy-paste the stencil `aggregate`.
- `index_sets` sizes, `aggregate` dense `ranges`, and `makearray` `regions` are literal
  integers, so every rule is welded to one concrete resolution. A library would need a
  generated file per (rule × resolution), and a convergence study (n = 16, 32, 64, 128)
  would need generated-fixture machinery in every consuming repo.

Three coupled mechanisms close these gaps: **template-library files + imports** (§3),
**registration-time body composition** (§4), and **load-time metaparameters** (§5). All
three resolve entirely at load, before validation and before the §9.6.3 fixpoint, so the
determinism contract — byte-identical post-lowering ASTs across all five bindings — is
preserved unchanged.

## 2. Summary of changes

| # | Change | Where |
|---|--------|-------|
| A | **Template-library files**: a document form whose payload is top-level `expression_templates` (+ optional top-level `index_sets`, `metaparameters`, `expression_template_imports`). Added to §2's "at least one of" rule. | schema + §2 + §9.7.1 |
| B | **`expression_template_imports`**: ordered import list `{ref, only?, bindings?}` on models, reaction systems, and library files. Resolution reuses §4.7 semantics; imported `index_sets` merge into the document registry; effective declaration order is pinned. | schema + §9.7.2/§9.7.4/§9.7.5 |
| C | **Registration-time body composition**: template bodies MAY contain `apply_expression_template` nodes referencing in-scope **match-less** templates; statically-checked acyclic DAG, depth ≤ `MAX_TEMPLATE_EXPANSION_DEPTH = 32`, inlined by pure substitution **before** the fixpoint runs. `match` patterns still MUST NOT contain them. | §9.6.3 + §9.7.3 |
| D | **Load-time metaparameters**: document-scoped named integers (`metaparameters`), bindable at import/subsystem-ref edges and at the loader API; admissible (as names or small integer expressions) in `index_sets` interval sizes, `aggregate` dense `ranges`, and `makearray` `regions`; substituted as integer literals in expression positions. Everything closes to concrete integers at load. | schema + §9.7.6 |
| E | **Zero-parameter templates**: `params` may be empty (`minItems` 1 → 0) so library constants need no dummy parameter. | schema + §9.6.1 |
| F | **`SubsystemRef.bindings`**: a §4.7 subsystem reference MAY bind the referenced document's metaparameters (e.g. a convergence wrapper instantiating a problem file at n = 32). | schema + §4.7 |

**Explicitly NOT done:** import renaming/namespacing (`as` prefixes) — deferred until a
real collision that `only` + explicit `priority` cannot resolve is exhibited;
non-integer metaparameters — deferred (every motivating site is an index bound or size);
cross-file sharing of anything *other* than templates, index sets, and metaparameters
(variables, equations, loaders keep their existing §4.7 subsystem pathway).

## 3. Template-library files and imports

### 3.1 The library-file form (§9.7.1)

A **template-library file** is a valid ESM document (`esm`, `metadata`) whose payload is:

- `expression_templates` (required, non-empty) — top-level, same entry shape as §9.6.1;
- `index_sets` (optional) — the document-scoped registry, as today;
- `metaparameters` (optional, §5);
- `expression_template_imports` (optional) — libraries can layer on other libraries.

It MUST NOT declare `models`, `reaction_systems`, `data_loaders`, `coupling`, or
`domain`. Purity keeps the two reference mechanisms disjoint: a §4.7 subsystem file is
never importable as a library (`template_import_not_library`) and a library file is never
includable as a subsystem (`subsystem_ref_is_template_library`). §2's existence rule
becomes "at least one of `models`, `reaction_systems`, `data_loaders`, or
`expression_templates`".

### 3.2 The `expression_template_imports` field (§9.7.2)

An **ordered array** appearing (i) inside a `model` or `reaction_system`, or (ii) at the
top level of a library file. Each entry:

| Field | Required | Meaning |
|---|---|---|
| `ref` | ✓ | Path or URL of a template-library file. Reference format and resolution timing are §4.7's, verbatim: relative paths resolve against the referencing file's directory; resolution happens at load, before validation; cycle detection over canonical paths. |
| `only` | | Array of template names to import. Absent = all. Naming a template the target does not declare is `template_import_unknown_name`. `only` filters *visibility for consumers*, not the target file's internal wiring — the target's own body references and match rules are resolved in its own scope first. |
| `bindings` | | Object binding the target document's open metaparameters to integers (§5.3). |

Import-graph cycles (over canonical paths) are rejected with `template_import_cycle`.
A `ref` that fails to load or parse is `template_import_unresolved`.

### 3.3 Effective declaration order (§9.7.4)

The §9.6.3 engine tie-breaks equal-`priority` rules by *declaration order*. With imports,
that order is pinned as the **depth-first post-order over the import DAG**:

> the effective sequence of a component (or library file) = for each entry of its
> `expression_template_imports`, in array order: the imported file's effective sequence;
> then the component's own declarations, in declaration order.

Duplicates arriving via diamond imports deduplicate at first occurrence when the two
definitions are **deep-equal after resolution** (same instantiated body, match, priority,
params). A same-name collision with *different* definitions — import/import or
import/local — is `template_import_name_conflict`. The engine never infers precedence
across libraries: authors state inter-library precedence with explicit `priority`, and
the effective sequence only breaks exact ties, exactly as within a single file today.

### 3.4 `index_sets` merge (§9.7.5)

An imported file's top-level `index_sets` merge into the importing **document's**
document-scoped registry (after metaparameter instantiation, §5.4). Deep-equal
redeclaration is idempotent — diamonds are fine. A non-equal collision is
`template_import_index_set_conflict`. This is what lets a grid file own its axes: the
consuming model's variables are shaped over `["lon", "lat"]` without redeclaring them.

## 4. Registration-time body composition (§9.7.3)

A template `body` MAY contain `apply_expression_template` nodes referencing other
templates that are **in scope** (declared locally or imported) and **match-less** (a
`match` rule is a rewrite step, not a named fragment; referencing one is
`apply_expression_template_unknown_template` — it is not visible as an invocable name).

After the effective sequence is fixed, and before the §9.6.3 fixpoint runs, the loader:

1. builds the reference graph over `apply_expression_template` nodes in bodies;
2. rejects cycles (self or mutual) with `apply_expression_template_recursive_body` —
   this diagnostic is hereby **redefined** from "any nesting" to "cyclic reference";
3. rejects reference chains deeper than `MAX_TEMPLATE_EXPANSION_DEPTH = 32` with
   `template_body_expansion_too_deep`;
4. inlines in topological order by §9.6.3-constraint-5 pure substitution.

Substitution is confluent (no evaluation, no capture: parameters are the only free names
and each inlining closes over its own bindings), so topological order cannot affect the
result. By the time any `match` rule is considered by the engine, every rule body is a
closed Expression AST containing **zero** `apply_expression_template` nodes — the §9.6.3
engine, its pass bound, its priority selection, and the `unlowered_operator` gate operate
on exactly the same model of the world as today.

`match` patterns MUST NOT contain `apply_expression_template` nodes (unchanged).

## 5. Load-time metaparameters (§9.7.6)

### 5.1 Declaration

A top-level document field:

```json
"metaparameters": {
  "NLON": { "type": "integer", "default": 144, "description": "zonal cell count" },
  "NLAT": { "type": "integer", "default": 91 }
}
```

`type` is required and MUST be `"integer"` (the only v1 type). `default` is optional.
A metaparameter name MUST NOT collide with any variable, parameter, species, or index-set
name visible in the document (`metaparameter_name_conflict`) — there is no shadowing.

### 5.2 Admissible sites

A **metaparameter expression** is: an integer literal; a declared metaparameter name; or
`{"op": <"+"|"-"|"*"|"/">, "args": [<metaparameter expressions>...]}` (with unary `-`
allowed). Metaparameter expressions are admissible wherever the schema previously
required a bare integer in a *structural* position:

- `index_sets.<name>.size` (interval kind);
- `aggregate` dense `ranges` tuple entries (`[start, stop]` / `[start, step, stop]`);
- `makearray` `regions` bound pairs.

These sites are **folded to concrete integers at load** with exact integer arithmetic;
`/` MUST divide exactly and folding MUST NOT overflow a 64-bit signed integer, else
`metaparameter_type_error`.

In ordinary **expression positions** (template bodies, equations, `index` args, …) a
metaparameter name is written as a bare string — the same surface syntax as a variable
reference — and is **substituted as an integer literal** during load. No folding happens
in expression positions: `{"op": "/", "args": [360, "NLON"]}` becomes
`{"op": "/", "args": [360, 144]}` and stays an AST division. (Folding only where the
schema demands an integer keeps the rule trivially deterministic; everything else is the
evaluator's job.)

### 5.3 Binding sites and value flow

Bindings flow **down** the reference DAG; open (unbound) metaparameters flow **up**:

1. **Import edge**: `expression_template_imports[k].bindings` closes the named
   metaparameters of the imported document — the imported subtree is instantiated with
   those values before its templates/index_sets enter the importer's scope.
2. **Re-export**: metaparameters of an imported document left *unbound* at the edge are
   inherited into the importing document's own metaparameter scope (deep-equal
   declarations dedupe; conflicting redeclarations are `template_import_name_conflict`).
   Binding NLON once at the top of a four-file chain therefore reaches the grid file at
   the bottom.
3. **Subsystem edge**: a §4.7 `{"ref": …}` subsystem reference MAY carry the same
   `bindings` field, closing the referenced document's metaparameters (e.g. a ten-line
   convergence wrapper binding a problem file to `n = 32`).
4. **Loader API**: hosts MAY bind the *root* document's open metaparameters at load
   (`load(file, metaparameters = {...})`) — the command-line `-D` of the mechanism.
5. **Defaults, last**: after API bindings, any still-open metaparameter takes its
   `default`; one with no default is `metaparameter_unbound`.

Because instantiation happens per import edge, a diamond whose two paths bind the same
underlying file *differently* produces non-deep-equal templates or index sets and is
rejected by the existing conflict diagnostics — no new machinery, no ambiguity.

### 5.4 Ordering within load

For each document, innermost-first: resolve imports (recursively, instantiating at each
edge) → merge index_sets → close + fold this document's metaparameters → then §4
body-composition and the §9.6.3 fixpoint on fully-concrete trees. Validators run on the
folded, expanded form (§9.6.4 unchanged). Round-trip emits the expanded, folded form;
neither `expression_template_imports` nor `metaparameters` nor top-level
`expression_templates` survives `parse → emit`; source files remain the source of truth.

## 6. Worked example — the four-file layering

**File 1 — `grid_latlon.esm`** (grid: metaparameters, axes, geometry constant):

```json
{
  "esm": "0.8.0",
  "metadata": { "name": "grid_latlon", "description": "Uniform lon-lat grid, NLON x NLAT" },
  "metaparameters": {
    "NLON": { "type": "integer", "default": 144 },
    "NLAT": { "type": "integer", "default": 91 }
  },
  "index_sets": {
    "lon": { "kind": "interval", "size": "NLON" },
    "lat": { "kind": "interval", "size": "NLAT" }
  },
  "expression_templates": {
    "dlon_deg": { "params": [], "body": { "op": "/", "args": [360, "NLON"] } }
  }
}
```

**File 2 — `central_D_lon_interior.esm`** (interior stencil; match-less):

```json
{
  "esm": "0.8.0",
  "metadata": { "name": "central_D_lon_interior" },
  "expression_template_imports": [ { "ref": "./grid_latlon.esm" } ],
  "expression_templates": {
    "central_D_lon_interior": {
      "params": ["f"],
      "body": {
        "op": "aggregate", "output_idx": ["i", "j"], "args": ["f"],
        "ranges": { "i": [2, { "op": "-", "args": ["NLON", 1] }], "j": { "from": "lat" } },
        "expr": { "op": "/", "args": [
          { "op": "-", "args": [
            { "op": "index", "args": ["f", { "op": "+", "args": ["i", 1] }, "j"] },
            { "op": "index", "args": ["f", { "op": "-", "args": ["i", 1] }, "j"] } ] },
          { "op": "*", "args": [2, { "op": "apply_expression_template", "args": [],
                                     "name": "dlon_deg", "bindings": {} }] } ] }
      }
    }
  }
}
```

**File 3 — `central_D_lon_zero_grad_bc.esm`** (the complete auto-applied rule):

```json
{
  "esm": "0.8.0",
  "metadata": { "name": "central_D_lon_zero_grad_bc" },
  "expression_template_imports": [ { "ref": "./central_D_lon_interior.esm" } ],
  "expression_templates": {
    "central_D_lon_zero_grad_bc": {
      "params": ["f"],
      "match": { "op": "D", "args": ["f"], "wrt": "lon" },
      "body": {
        "op": "makearray", "args": [],
        "regions": [
          [[2, { "op": "-", "args": ["NLON", 1] }], [1, "NLAT"]],
          [[1, 1], [1, "NLAT"]],
          [["NLON", "NLON"], [1, "NLAT"]]
        ],
        "values": [
          { "op": "apply_expression_template", "args": [],
            "name": "central_D_lon_interior", "bindings": { "f": "f" } },
          { "op": "aggregate", "output_idx": ["j"], "args": ["f"],
            "ranges": { "j": { "from": "lat" } },
            "expr": { "op": "/", "args": [
              { "op": "-", "args": [ { "op": "index", "args": ["f", 2, "j"] },
                                     { "op": "index", "args": ["f", 1, "j"] } ] },
              { "op": "apply_expression_template", "args": [], "name": "dlon_deg", "bindings": {} } ] } },
          { "op": "aggregate", "output_idx": ["j"], "args": ["f"],
            "ranges": { "j": { "from": "lat" } },
            "expr": { "op": "/", "args": [
              { "op": "-", "args": [ { "op": "index", "args": ["f", "NLON", "j"] },
                                     { "op": "index", "args": ["f", { "op": "-", "args": ["NLON", 1] }, "j"] } ] },
              { "op": "apply_expression_template", "args": [], "name": "dlon_deg", "bindings": {} } ] } }
        ]
      }
    }
  }
}
```

**File 4 — a consuming model**, at double resolution:

```json
{
  "esm": "0.8.0",
  "metadata": { "name": "advection_lon" },
  "models": {
    "Advection": {
      "expression_template_imports": [
        { "ref": "https://earthsciml.org/lib/central_D_lon_zero_grad_bc.esm",
          "only": ["central_D_lon_zero_grad_bc"],
          "bindings": { "NLON": 288, "NLAT": 181 } }
      ],
      "variables": {
        "c": { "type": "state", "units": "kg/m^3", "shape": ["lon", "lat"], "description": "tracer" },
        "u": { "type": "parameter", "units": "m/s", "default": 5.0, "description": "zonal wind" }
      },
      "equations": [
        { "lhs": { "op": "D", "args": ["c"], "wrt": "t" },
          "rhs": { "op": "*", "args": [ { "op": "-", "args": ["u"] },
                                        { "op": "D", "args": ["c"], "wrt": "lon" } ] } }
      ]
    }
  }
}
```

At load: file 4's import edge binds NLON/NLAT and instantiates files 3 → 2 → 1;
`lon`/`lat` (sizes 288/181) merge into file 4's registry; `dlon_deg` and the interior
stencil inline into the rule body at registration; the unchanged §9.6.3 fixpoint lowers
`D(c, wrt: lon)`; the gate confirms nothing unlowered survives. Byte-identical across
bindings. The same four files serve a convergence sweep by re-binding at the edge — no
generated fixtures.

Reprojection fragments and regridding coupling expressions share by the same mechanism: a
library exports match-less coordinate-transform or overlap-weight templates; a coupling
`transform` invokes them.

## 7. Determinism

- Import resolution, instantiation, dedup, and conflict checks depend only on file
  content and the (ordered) import arrays — no filesystem enumeration, no clocks.
- Metaparameter folding is exact 64-bit integer arithmetic with mandatory divisibility —
  no floating point, no platform variance.
- Body inlining is confluent pure substitution over a statically-acyclic DAG.
- The rewrite engine's inputs (rule sequence + concrete trees) are therefore identical
  across bindings, and §9.6.3 already guarantees the rest: all five bindings MUST produce
  byte-identical post-lowering canonical ASTs, or the same rejection diagnostic.

## 8. Diagnostics (new §9.7.8; mirrored into the §9.6.6 table)

| Code | Meaning |
|---|---|
| `template_import_version_too_old` | File declares `esm` < 0.8.0 but carries `expression_template_imports`, top-level `expression_templates`, or `metaparameters`. |
| `template_import_unresolved` | An import `ref` failed to load or parse (reports path/URL and cause). |
| `template_import_not_library` | Import target is not a pure template-library file (carries models/reaction_systems/data_loaders/coupling/domain, or lacks top-level `expression_templates`). |
| `subsystem_ref_is_template_library` | A §4.7 subsystem `ref` targets a template-library file. |
| `template_import_cycle` | Import-graph cycle over canonical paths (reports the cycle). |
| `template_import_name_conflict` | Same template or metaparameter name reaches one scope with non-deep-equal definitions. |
| `template_import_unknown_name` | `only` names a template the target does not declare. |
| `template_import_index_set_conflict` | Merged `index_sets` name collides with a non-deep-equal definition. |
| `apply_expression_template_recursive_body` | *(redefined)* Template-body reference cycle (self or mutual). |
| `template_body_expansion_too_deep` | Body-reference chain exceeds `MAX_TEMPLATE_EXPANSION_DEPTH` (32). |
| `metaparameter_unbound` | A metaparameter is still open after edge bindings, API bindings, and defaults. |
| `metaparameter_type_error` | A binding is not an integer; a fold divides inexactly or overflows; a metaparameter expression uses an op outside `+ - * /`. |
| `metaparameter_name_conflict` | A metaparameter name collides with a visible variable/parameter/species/index-set name. |

## 9. Schema changes (`esm-schema.json`, 0.8.0 — in-progress clean break, no bump)

1. **New `$defs/TemplateImport`**: object, `additionalProperties: false`, required
   `["ref"]`; `ref` string (minLength 1); `only` unique non-empty string array
   (minItems 1); `bindings` object of integers.
2. **New `$defs/Metaparameters`**: object; each value `{type: "integer"` (required
   const), `default?: integer, description?: string}`, `additionalProperties: false`.
3. **New `$defs/MetaparameterExpression`** (recursive): `oneOf` integer / string /
   `{op: enum["+","-","*","/"], args: [MetaparameterExpression...] (minItems 1)}`.
4. **Top-level `properties`**: add `expression_templates`
   (`additionalProperties: {"$ref": "#/$defs/ExpressionTemplate"}`),
   `expression_template_imports` (array of `TemplateImport`), `metaparameters`
   (`$ref Metaparameters`). Extend the root `anyOf` with
   `{"required": ["expression_templates"]}`.
5. **`$defs/Model`, `$defs/ReactionSystem`**: add `expression_template_imports` beside
   `expression_templates`.
6. **`$defs/SubsystemRef`**: add optional `bindings` (object of integers).
7. **`$defs/ExpressionTemplate`**: `params.minItems` 1 → 0; description updated for §9.7.3
   (bodies may reference match-less templates; resolved at registration; acyclic;
   depth ≤ 32; `match` may not).
8. **Metaparameter-expression widening**: `$defs/IndexSet.size` → `oneOf` [integer,
   `$ref MetaparameterExpression`]; `ExpressionNode.ranges` dense-tuple items and
   `ExpressionNode.regions` bound-pair items likewise. (String metaparameter names are
   covered by the `MetaparameterExpression` ref.)

Library-file purity, DAG acyclicity, conflict detection, folding, and version gating are
resolver-level checks (the `resolver_only` convention of `tests/invalid/expected_errors.json`).
Run `scripts/sync-schema.sh`, then `scripts/sync-schema.sh --check`.

## 10. Spec changes (`esm-spec.md`)

| Section | Change |
|---|---|
| §1.1 | "Factoring third" extends to library files: templates may be shared via §9.7 imports and bodies may reference match-less templates as a statically-checked acyclic DAG; still no recursion, no metaprogramming. |
| §2 | Add the three new top-level rows; extend the "at least one of" sentence; note library files as the discretization-library carrier. |
| §4.7 | Add `bindings` to the reference-format table; closing paragraph cross-referencing §9.7 (distinct mechanisms; neither can target the other's file kind). |
| §9.6.1 | Drop the deferral parenthetical; point to §9.7; `params` may be empty. |
| §9.6.2 | `name` may reference an imported template; note §9.7.3 body references. |
| §9.6.3 | Constraint 2: "declaration order" = §9.7.4 effective sequence; body-reference sentence updated (cycle, not nesting). Constraint 4: "declared in or imported into". |
| §9.6.5 | The new constructs arrive at `esm: 0.8.0`; older files carrying them → `template_import_version_too_old`. |
| §9.6.6 | Append the §8 diagnostics rows. |
| §9.6.7 | Add the new fixture set (§11). |
| §9.6.8 | Replace "or by composing with rules that library provides" hand-wave with a pointer to §9.7 and the layered grid → stencil → BC pattern. |
| **new §9.7** | Normative text for §3–§5 above + the worked example. |

Also: `esm-libraries-spec.md` §2.1b gains the import-resolution algorithm (parallel to the
subsystem algorithm); `ESM_COMPLIANCE_VALIDATION_MATRIX.md` gains rows for each new
diagnostic; `CONFORMANCE_SPEC.md` fixture-category text mentions the new fixtures.

## 11. Conformance fixtures

`tests/conformance/expression_templates/`:

- `import_smoke/` — the §6 four-file example (`grid_latlon.esm`,
  `central_D_lon_interior.esm`, `central_D_lon_zero_grad_bc.esm`, `fixture.esm`) +
  `expanded.esm`. All five bindings: structurally-equal post-lowering model.
- `import_diamond/` — two import paths reaching the same grid file with equal
  instantiation; dedupe; golden.
- `import_order_determinism/` — two libraries with equal-priority rules matching the same
  node: winner fixed by import order; a variant flips the winner with explicit
  `priority`. Also entries in `tests/conformance/determinism/manifest.json`.
- `metaparameter_resolutions/` — one problem file loaded at `n = 4` and `n = 8` via
  subsystem-ref `bindings` wrappers → two goldens.

`tests/invalid/template_imports/` (+ `expected_errors.json`, `resolver_only` where
appropriate): `import_cycle_a/b.esm`, `import_not_library.esm`,
`subsystem_ref_is_library.esm`, `import_name_conflict.esm`, `import_unknown_only.esm`,
`index_set_conflict.esm`, `body_apply_cycle.esm`, `body_chain_too_deep.esm`,
`metaparameter_unbound.esm`, `metaparameter_inexact_division.esm`,
`metaparameter_name_conflict.esm`, `import_version_too_old.esm`.

`tests/valid/template_import_minimal.esm` + sibling library files (library files are
schema-valid documents and enter the valid suite; each binding's valid-loop must tolerate
a model-less document).

## 12. Binding implementation notes

Per binding, the work is: (a) extend the existing ref-loading module to load library
files under the same visited-set cycle detection; (b) import-graph resolution, per-edge
instantiation, effective-order construction, `only` filtering, dedup/conflict checks,
index_sets merge; (c) metaparameter close + fold pass; (d) registration-time DAG inlining
feeding the existing fixpoint engine; (e) the version gate and the §8 diagnostic codes;
(f) loader-API metaparameter overrides.

| Binding | Ref loading | Templates/engine |
|---|---|---|
| Julia | `packages/EarthSciSerialization.jl/src/parse.jl` (`resolve_subsystem_refs!`, `_load_ref`, `_canonical_ref`) | `src/lower_expression_templates.jl` |
| Python | `src/earthsci_toolkit/reference_resolution.py` | `src/earthsci_toolkit/lower_expression_templates.py` |
| TypeScript | `src/ref-loading.ts` | `src/lower_expression_templates.ts` |
| Rust | `src/ref_loading.rs` | `src/lower_expression_templates.rs` |
| Go | `pkg/esm/subsystem_ref.go` | `pkg/esm/lower_expression_templates.go` |

Julia is the reference implementation and generates all goldens.

## 13. Phasing

1. **Spec + schema** (this RFC, `esm-spec.md`, `esm-schema.json` + mirrors, matrix/docs
   sweep) — one logical change per `SCHEMA_CHANGE_PROCEDURE.md`.
2. **Julia reference** + the §11 fixtures with Julia-derived goldens.
3. **Python / TypeScript / Rust / Go ports** (parallel; each lands behind the §9.6.3
   engine for that binding).
4. **EarthSciDiscretizations bootstrap** consumes the mechanism (separate repo effort).

## 14. Open questions

- Import renaming (`as` prefixes) — deferred; revisit on first real collision.
- Non-integer metaparameters (e.g. a real-valued domain extent) — deferred; extents can
  live as ordinary parameters whose defaults are expressions over metaparameters.
- §6.6.5 inline-test `reference` expressions over *unstructured* grids (reference needs
  coordinate variables, not dimension names) — tracked separately; `from_file` references
  cover the gap meanwhile.
