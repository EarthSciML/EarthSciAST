# Migration guide

This release harmonizes the EarthSciAST public API across all six bindings. It
carries three coordinated bodies of change:

- **Document I/O and version constants** — `load`, `save` and `VERSION` split
  into entry points that mean one thing each, in all five language bindings.
- **The simulation surface** — `simulate` is replaced by an `EsmProblem` you
  build and a `solve` you run, in Julia, Python and Rust.
- **The tidy-and-lock pass** — the reconciliations recorded in
  `API_SPEC.md` §8, plus Rust's encapsulation (H-3), Python's layering (H-4)
  and the one-CLI rule (H-5). After it, `api-surface.json` is the enforced
  contract: six tests, one per binding, assert the declared surface against it
  in both directions.

It also carries two changes to the **`.esm` document format** itself, which
affect your documents rather than your code.

This guide is organised for someone with a working codebase who wants to know
what breaks and what to write instead. If you have five minutes, read Part I.

---

## How to read a row

Every row in this guide carries a kind:

| Kind | Meaning |
|---|---|
| `deleted` | The old spelling is **gone**. Your code stops compiling (or raises `AttributeError` / `MethodError` / `NameError`). The row gives the expression that replaces it. |
| `alias` | Renamed, with the old spelling kept as a **deprecated alias for one minor release** (`API_SPEC.md` §10). It still works today and is removed at the next major. Both spellings are in `api-surface.json` and both are asserted by the surface tests, so neither can vanish silently. |
| `semantics` | **Same name, different behaviour.** Nothing fails to compile. These are the dangerous ones. |
| `packaging` | Affects how you install, depend on or import — not what the symbols are called. |
| `format` | Affects `.esm` **documents**, in every binding at once. |
| `new` | Pure addition. Nothing to migrate; listed because it is the replacement some `deleted` row points at. |

Where a deprecation alias exists, it disappears **at the next major release**.
Aliases are not a permanent compatibility layer; they exist so you can move at
your own pace inside one minor.

---

# Part I — Start here: the changes that do not fail to compile

Everything below keeps its old name and its old call shape. Your build stays
green and your program does something different. Audit these first.

| Binding | Symbol | What changed | How it shows up |
|---|---|---|---|
| Python, Rust, Go | `lower_enums` / `LowerEnums` | Now **pure**. It returns the lowered document instead of writing through its argument. | Python: your document is silently **not lowered**, no error. Go and Rust: the signature moved with it, so the compiler catches you. |
| Julia | enum lowering | Raises `EnumLoweringError`, not `ParseError`. | A `catch e; e isa ParseError` stops matching and the error escapes your handler. |
| all five | `validate` | Takes a **typed document** only. Path and text moved to `validate_path` / `validate_text`. Python's sniff is gone. | Python and TypeScript raise `TypeError`; Julia raises `MethodError`. A compile error in Rust and Go. |
| Go | `Validate` | Returns the four-field `*ValidationResult`, not `*DetailedValidationResult`. | Compile error on `.Valid` / `.Messages` — but a caller that only nil-checked the pointer now reads a *different verdict shape*. |
| Go | `SystemKind`, `EffectiveSystemKind` | Lost the `domain` argument. | Compile error (arity). |
| Rust | `stoichiometric_matrix` | Species are in **declaration order**, no longer sorted by name. | Row order of the matrix changes. Indices you cached are wrong. |
| Go | `DeriveODEs`, `StoichiometricMatrix` | Same: declaration order, read from the authored JSON key order. | As above. |
| Rust | `derive_odes` | Now copies `system.parameters` into the derived model's `variables`. | The derived model *closes* where it previously had undeclared variables. Counts change. |
| Go | `Substitute` | Single-pass, no longer transitive. `Substitute("a", {a: b, b: c})` returns `"b"`, not `"c"`. | Chained renames that were silently mis-applied now apply correctly. Goldens change. |
| Julia, Python, Rust | `solve` default tolerances | `reltol = 1e-4`, `abstol = 1e-6` everywhere — **looser** than Rust's and Python's old defaults. | Trajectory assertions fail. |
| Julia, Python, Rust | a failed **build** | Raises instead of returning a failed result. | Code inspecting `result.success` for build failures never sees it; the exception propagates. |
| Python | `UnitWarning.path` | Was the string `"unit_validation"` at every site; is now `""` (the document root). | A consumer matching on that literal stops matching. |
| Python | index-set merge | A model-nested `index_sets` now **merges over** the document-scoped registry instead of being invisible to it. | Different resolution verdicts on pre-0.8.0-shaped documents. |
| Julia | diagnostic pointers | A scalar `update: {...}` no longer reports a synthetic `/0` segment. | A consumer matching on diagnostic JSON Pointers sees a different path. |
| all five | `from_faq` | Resolves against the **whole document**, not one model. | Documents that used to be rejected now load; duplicate node ids that used to be legal now fail. |
| Rust | `esm graph` CLI | Output changed in all three formats; `--level=expression` now works. | Any golden capturing CLI output. |

Each of these is expanded in the per-binding table it belongs to.

---

# Part II — The document format changed

These two changes are `format`-kind: they apply to `.esm` documents in every
binding at once, whether or not you touch any API.

### `from_faq` resolves at DOCUMENT scope

`index_sets` is a **document-scoped** registry — `esm-schema.json` declares it
only at `/properties/index_sets`. But every binding resolved a
`kind: "derived"` entry's `from_faq` against the expression nodes of **one
model**. Those two facts cannot both be right: the same registry entry is
visible to every model in the document, so an entry that can only name one
model's nodes is incoherent.

`from_faq` now resolves against the whole document. A consuming model's
reference graph gains a real vertex for a producer in another model, at path
`models/<Model>/<local path>`, so the partition pass can walk
`index_set -> node` across the model boundary. A `from_faq` naming no node
**anywhere** is still `unknown_faq_node` / `E_REF_UNKNOWN_FAQ_NODE`, with the
message widened from "in model 'X'" to "in the document".

**This makes previously-rejected documents load.**
`tests/valid/wildfire_atmosphere_ocean.esm` — the atmosphere model consuming a
candidate-pair set produced by the ocean model — resolved in *no* binding
before, and its `from_faq` resolves now.

Public signatures are unchanged. `build_reference_graph(model, model_name, …)`
still takes one model and keeps the per-model check, because a direct caller
holds a model and no document; `resolve_references(document)` is the entry
point that has a document and threads the document-wide node map into every
build.

### An expression-node `id` must now be unique per DOCUMENT

This follows from the above and is the one genuinely **breaking** format
change: the schema required a node `id` to be unique "among the expression
nodes of its model". A cross-model `from_faq` would then be ambiguous, so
uniqueness widens to the document.

**A document that reused an `id` across two models was legal and is now
invalid.** The same id in two models is a load-time
`E_REF_DUPLICATE_NODE_ID`, reported with model-qualified paths on both sides.

Verified against every `.esm` under `tests/`: **zero** fixtures reuse an id
across models, so widening the rule invalidates nothing that exists here. Check
your own documents if you author `id`s by hand.

### The index-set merge rule is now the same in all five

The optional trailing `index_sets` argument **merges** a pre-0.8.0
model-nested registry *on top of* the document-scoped one, so a model-level
entry wins a collision. Julia, TypeScript, Rust and Go already did this;
**Python alone was either/or** — supplying a document registry made the
model-nested key invisible. Measured before the change: a `ranges[*].from`
naming a model-nested-only set raised `undeclared_index_set` in Python and
resolved in Go and Rust; with the same name in both, Python took the *document*
entry where Go and Rust took the *model* one. Python now matches.

---

# Part III — Per-binding upgrade tables

Rows point at Part IV where a change is shared across bindings and the
reasoning is worth reading once rather than five times.

## Julia — `EarthSciAST.jl`

| Before | After | Kind |
|---|---|---|
| `load(path::String)` | `load_path(path)` | `deleted` |
| `load(io::IO)` | `load_string(io)` — and it now runs the full pipeline, see below | `deleted` |
| `load(doc::AbstractDict)` | `load_document(doc)` | `deleted` |
| `save(file, path::String)` | `write_path(file, path)` → `nothing` | `deleted` |
| `save(file, io::IO)` | `write(io, to_json(file))` | `deleted` |
| `ESM_FORMAT_VERSION` | `SCHEMA_VERSION` | `deleted` |
| — | `LIBRARY_VERSION` (the package version, from `pkgversion`) | `new` |
| `simulate(input, tspan; …)` | `solve(esm_problem(input, tspan; …), alg; …)` | `deleted` |
| `simulate(prep, tspan; …)` | `solve(prob, alg; …)` | `deleted` |
| `prepare(input; …)` → `PreparedModel` | `esm_problem(input, tspan; …)` → `EsmProblem` | `deleted` |
| `SimulateOptions` / `SimulationResult` / `SolverChoice` | gone; options are SciML's and a solution is a real `ODESolution` | `deleted` |
| `remake_parameters(prep, overrides)` | `remake(prob; p = overrides)` (`SciMLBase.remake`) | `semantics` |
| `observed_field(prep, insp::BuildInspection, name)` | `observed_field(prob, name)` | `semantics` |
| `unknown_names(model)` | `unknowns(model)` | `alias` — **kept, not going away**, see below |
| `parameter_names(model)` | `parameters(model)` | `alias` — as above |
| `declared_system_kind_mismatch(model)` | for the `nothing` case: `declared_system_kind(m) === nothing \|\| declared_system_kind(m) == system_kind(m)`; for the `(declared, derived)` tuple: `(declared_system_kind(m), system_kind(m))` | `deleted` |
| — | `declared_system_kind(model)` — reads the explicit field, `nothing` when absent | `new` |
| — | `effective_system_kind(model)` — `declared` if present, else derived | `new` |
| `validate(path::AbstractString)` | `validate_path(path)` | `deleted` |
| `validate(file)` | takes a **typed document** only; `validate(::String)` is now a `MethodError`, deliberately | `semantics` |
| — | `validate_text(text; base_path)` | `new` |
| `lower_enums!(file)` | `lower_enums(file)` is the **pure** canonical form (it deep-copies); `lower_enums!(file)` is the in-place twin. Both exported. | `semantics` |
| `catch e; e isa ParseError` around enum lowering | `catch e; e isa EnumLoweringError` | `semantics` |
| `to_json(graph)` | `to_json_graph(graph)` | `alias` |
| `to_unicode(container)` / `to_latex(container)` threw `ArgumentError` | returns the container summary | `semantics` |
| `build_reference_graph(model, name)` on a 1.0.0 document | takes an optional trailing `index_sets`; `resolve_references` threads it | `semantics` (bug fix) |
| diagnostic pointer `…/update/0/…` for a scalar `update` | `…/update/…` | `semantics` |
| `from_faq` / node `id` uniqueness | see [Part II](#part-ii--the-document-format-changed) | `format` |

### `unknown_names` and `parameter_names` stay exported

They are aliases, but they are **not** on the one-minor clock — they are not
going away. The canonical bare names collide: after
`using EarthSciAST, ModelingToolkit`, a bare `unknowns(m)` is an ambiguity
error against `ModelingToolkit.unknowns` (and `parameters` against
`.parameters`). The collision was **measured** with
`using EarthSciAST, ModelingToolkit, Catalyst`, not assumed. Write
`EarthSciAST.unknowns(m)`, or keep using `unknown_names(m)`.

### `declared_system_kind_mismatch` is deleted with no alias

It was Julia-only — the sole 1-of-5 member of the family — and one line over
the two functions that replace it. The `system_kind_mismatch` **finding** is
unchanged: `validate` still reports it with the same code, path and `details`.

### `EnumLoweringError` carries a code

`EnumLoweringError <: EarthSciASTError` carries a structured `code`
(`enum_op_malformed` / `unknown_enum` / `unknown_enum_symbol`) instead of
interpolating it into the message. This was a real defect, not only a rename:
Julia raised `ParseError` where TypeScript, Python and Rust all raised
`EnumLoweringError`.

### `validate_path` still raises on bad input — `validate_text` does not

Recorded, not fixed. `validate_text` renders a schema-invalid document, a
malformed-JSON parse failure and a `(code, path)`-carrying rejection into the
`ValidationResult`'s three channels, and returns the same error counts as
Python on both bad inputs. `validate_path` renders only the third channel and
still **raises** on schema-invalid or malformed input. Changing it would be a
behaviour change to a `stable` function nobody asked for, so it was left alone.
If you need uniform non-raising behaviour, read the file yourself and call
`validate_text`.

### `update` diagnostic pointers lost a spurious `/0` (bug fix)

Julia's typed model normalizes a scalar `update: {...}` into a one-element
`Vector{ParameterUpdate}` at parse time. The three passes that walk update
rules interpolated that **synthetic** index into the JSON Pointer they report,
so a document writing the object form was told about

    /models/M/variables/v/update/0/from/unit_conversion

— a pointer that resolves to nothing in its own source. It is now

    /models/M/variables/v/update/from/unit_conversion

matching the corpus pin for `tests/invalid/undefined_variable_in_unit_conversion.esm`
and the TypeScript, Python and Go bindings. The array form is unchanged and
still carries its index (`/update/0/...`, `/update/1/...`), because there the
index is real.

Affected: `undefined_variable` (and any other reference finding) inside
`update[*].when`, `update[*].expression` and `update[*].from.unit_conversion`,
plus the `unit_inconsistency` `UnitFinding` subpaths for the same positions —
whose message also no longer says "update rule 0" for a document with one rule.
A consumer matching on diagnostic paths should expect the corrected pointer.

### `build_reference_graph` reads the 1.0.0 `index_sets` registry (bug fix)

`build_reference_graph(model, model_name)` read `model["index_sets"]` — the
**pre-0.8.0 nested** shape. Since v0.8.0 the registry is a sibling of `models`
at the top of the document, and `esm-schema.json` declares `index_sets` at
`/properties/index_sets` and nowhere else. So on any real 1.0.0 document Julia
saw an EMPTY registry: every `ranges[*].from` target looked undeclared and the
pass **threw** `E_REF_UNDECLARED_INDEX_SET`, where Python, Rust and Go all built
the graph — index-set vertices, `range_from` edges and `from_faq` edges
included.

`resolve_references(document)` now threads `document["index_sets"]` into every
model, and the registry is an optional **trailing** argument for direct callers:

```julia
build_reference_graph(model, "M", document["index_sets"])
```

Omitting it still falls back to a model-nested `index_sets` key, so pre-0.8.0
raw-model callers are unaffected. Regression coverage:
`pkg/EarthSciAST.jl/test/reference_graph_test.jl`, testset
`"index_sets at DOCUMENT scope (esm 1.0.0 flat shape)"`.

### `load(::IO)` skipped half the pipeline (bug fix)

`EarthSciAST.load(::IO)` skipped top-level `{ref}` inlining and
`resolve_subsystem_refs!`, which the path and dict methods both ran. A document
loaded from a stream therefore kept its subsystem refs as unresolved
`SubsystemRef`s — and `flatten` **silently skips** an unresolved `SubsystemRef`.
Same bytes, strictly smaller system, no error. All three entry points now share
one pipeline; the successor of `load(::IO)` is `load_string(::IO)`.

## TypeScript — `@earthsciml/ast`

| Before | After | Kind |
|---|---|---|
| `load(input, opts?)` | `loadPath(path, opts?)` / `loadString(json, opts?)` / `loadDocument(obj, opts?)` | `deleted` |
| `save(file, opts?)` | `toJson(file, opts?)` | `deleted` |
| `SaveOptions` | `ToJsonOptions` | `deleted` |
| — | `toJsonCompact(file)`, `writePath(file, path)` | `new` |
| `VERSION` | `SCHEMA_VERSION` — ⚠ **not** `LIBRARY_VERSION`; TypeScript's `VERSION` was the *schema* version | `deleted` |
| — | `LIBRARY_VERSION` — a **different number** (the package version) | `new` |
| `deriveODEs(system)` | `deriveOdes(system)` | `alias` |
| `CLOSED_FUNCTION_NAMES` (constant array) | `closedFunctionNames()` (function) | `alias` |
| `getSupportedMigrationTargets(v)` | `supportedMigrationTargets(v)` | `alias` |
| `component_graph(file)` | `componentGraph(file)` | `deleted` |
| `ExpressionAnalyzer` | `analyzeExpression(expr)` — the single member it forwarded to | `deleted` |
| `EsmFormat` (deprecated type alias) | `EsmFile` — the canonical name; the generated type is `ESMFormat` | `deleted` |
| `validate(text \| object)` | `validate(document)`; JSON text goes to `validateText(text, { basePath })` | `semantics` |
| `canonical` option on `load` | applies to `loadPath` / `loadString` only | `semantics` |
| — | `effectiveSystemKind(model)` | `new` |
| — | `buildReferenceGraph`, `resolveReferences`, `ReferenceGraph`, `ReferenceVertex`, `ReferenceEdge`, `VertexKind`, `EdgeKind`, `ReferenceResolutionError` | `new` |
| `from_faq` / node `id` uniqueness | see [Part II](#part-ii--the-document-format-changed) | `format` |

### `validate` is typed, and there is deliberately no `validatePath`

`validate(document)` is typed, and **throws a `TypeError` naming `validateText`**
if handed a string at runtime — a JS caller has no compiler to stop them.

`@earthsciml/ast` targets the browser as well as Node and exposes no
synchronous filesystem read, so a `validatePath` here would be a Node-only stub
that breaks the bundle. Read the file yourself and call
`validateText(text, { basePath })`.

### `deriveODEs`, `CLOSED_FUNCTION_NAMES`, `getSupportedMigrationTargets`

All three old spellings are still exported for one minor and are bound to the
*same object* as the new one — asserted by a test in each case:

- `closedFunctionNames()` returns the same frozen array `CLOSED_FUNCTION_NAMES`
  names, **by identity**, so the two cannot drift. Note this is a **kind**
  change as well as a rename: a constant became a function, matching Julia,
  Rust and Go, so binding-agnostic code no longer has to special-case
  TypeScript. `api-surface.json` carries them as two entries because they are
  two kinds.
- `deriveODEs` was the last `API_SPEC.md` §2.1 violation in this binding, and
  an internally inconsistent one — the siblings were already `odeStates` and
  `isOdeState`.

After this release no TypeScript or editor export carries a snake_case
spelling.

### `toDot` / `toMermaid` / `toJsonGraph` did not change

Verified during phase 6 rather than changed: all three were already generic
over `Graph<N, E>` and dispatch on the graph kind, and
`tests/conformance/graph/cases.json` exercises them against both the component
and the expression graph of every corpus document. `lowerEnums` was likewise
already pure and already raised `EnumLoweringError`, and the display renderers
already accepted the full domain.

## Python — `earthsci-ast`

| Before | After | Kind |
|---|---|---|
| `load(path_or_string)` (sniffed on `os.path.exists`) | `load_path(path)` / `load_string(json)` / `load_document(dict)` | `deleted` |
| `save(file)` | `to_json(file)` | `deleted` |
| `save(file, path)` | `write_path(file, path)` → `None` | `deleted` |
| `parse._CURRENT_VERSION` (private `(major, minor, patch)` tuple) | `SCHEMA_VERSION` (public string) | `deleted` |
| `__version__` | `LIBRARY_VERSION` (`__version__` still works) | `alias` |
| `simulate(file, tspan, …)` | `solve(esm_problem(file, tspan, …))` | `deleted` |
| `prepare(input, …)` → `PreparedModel` | `esm_problem(input, tspan, …)` → `EsmProblem` | `deleted` |
| solver options `method` / `atol` / `rtol` | `alg` / `abstol` / `reltol` (SciML spelling) | `deleted` |
| 16 suffixed edit operations (`add_variable_to_model`, …) | the bare verbs (`add_variable`, …) — full table below | `alias` |
| `validate(path \| text \| dict \| document)` | `validate(document)`; `validate_path(path)`; `validate_text(text)` | `semantics` |
| `lower_enums(file)` mutated in place | `lower_enums(file)` is **pure**; `lower_enums_mut(file)` is the in-place twin | `semantics` |
| `to_json` on a `Graph` | `to_json_graph(graph)`; `to_json` is the **document** serializer | `deleted` |
| — | `effective_system_kind(model)` | `new` |
| — | `lower_enums`, `lower_enums_mut`, `EnumLoweringError` now in `__all__` | `new` |
| — | `ERROR_CODES`, `UnitFinding`, `UNIT_FINDING_DIMENSIONAL_MISMATCH` / `_UNPARSEABLE` / `_ANALYSIS` | `new` |
| `UnitWarning` with no `code`; `path == "unit_validation"` | `UnitWarning(path, code, message, lhs_units, rhs_units)`; `path == ""` where the raise site has no pointer | `semantics` |
| a model-nested `index_sets` invisible when a document registry was supplied | merged **over** the document registry, as in the other four | `semantics` |
| 29 `data_sources` loader names on `earthsci_ast` | `earthsci_ast.data_sources` — full table below | `packaging` |
| `xarray` / `netcdf4` in the base dependency set | the `data` extra | `packaging` |
| `earthsci-*-adapter-python` console scripts | `python3 -m …`; deps in the `conformance` extra | `packaging` |
| `from_faq` / node `id` uniqueness | see [Part II](#part-ii--the-document-format-changed) | `format` |

### The 16 edit operations dropped their container suffix

Python suffixed every edit with its container; Julia, TypeScript and Rust use
the bare verb, which is also what `API_SPEC.md` §2 transliterates the canonical
name to. All sixteen suffixed names survive as deprecated aliases that emit a
`DeprecationWarning` and forward, for one minor per §10. None of the sixteen
bare names collided with an existing export.

| Before | After |
|---|---|
| `add_variable_to_model` | `add_variable` |
| `rename_variable_in_model` | `rename_variable` |
| `remove_variable_from_model` | `remove_variable` |
| `add_equation_to_model` | `add_equation` |
| `remove_equation_from_model` | `remove_equation` |
| `add_reaction_to_system` | `add_reaction` |
| `remove_reaction_from_system` | `remove_reaction` |
| `add_species_to_system` | `add_species` |
| `remove_species_from_system` | `remove_species` |
| `add_continuous_event_to_model` | `add_continuous_event` |
| `add_discrete_event_to_model` | `add_discrete_event` |
| `remove_event_from_model` | `remove_event` |
| `add_coupling_to_file` | `add_coupling` |
| `remove_coupling_from_file` | `remove_coupling` |
| `merge_esm_files` | `merge` |
| `extract_component_from_file` | `extract` |

### `lower_enums` is pure — this one is silent

`lower_enums(file)` returns the lowered document and **does not write through
its argument**. Nothing in Python's signature changed, so a caller that ignored
the return value now gets an unlowered document with no error.

The in-place twin is `lower_enums_mut(file)`, which computes the pure result
and grafts it back into the original `EsmFile` *and* the nested `Model` /
`ReactionSystem` objects, so a caller holding a nested model sees the lowered
trees. A document that fails to lower is now left **untouched** rather than
half lowered, because lowering completes before any graft — a promise the
mutating version could not make.

The error contract is unchanged: an undeclared enum raises `EnumLoweringError`
with code `unknown_enum`, an undeclared symbol with `unknown_enum_symbol`, and
both still subclass `ValueError`.

### `validate` no longer sniffs

`validate()` sniffed a path, JSON text, a `dict` or a document out of one
argument — the exact defect `load` was split to remove. It is now typed-only
and raises `TypeError` naming the alternative:

```python
validate(document)                       # a typed EsmFile
validate_path(path)                      # a filesystem path
validate_text(text, base_path=base)      # JSON text
validate(load_document(data))            # an already-decoded dict
```

`validate_path` and `validate_text` share a `_validate_loaded` that carries the
old sniff's error-conversion clauses verbatim, so verdicts for malformed
documents are unchanged: both report a **load** failure as a
`ValidationResult` rather than raising.

Fixed in the same pass: `ESMEditor`'s post-edit validation of a bare `Model` or
`ReactionSystem` never worked — it crashed on `esm_file.models` and returned
`is_valid=False` with a `validation_error` at path `""`, reporting the *edit*
as invalid when nothing was wrong with it. Post-edit validation is
document-scoped, so it now runs only for an `EsmFile` target and records a
warning saying so otherwise.

### The `data_sources` loader stack is no longer re-exported at the top level

`earthsci_ast` is the **format** library: parse / validate / serialize /
display / canonicalize / graph / edit / flatten / classify. The runtime
data-loading tier now lives only in its own package, matching the Rust crate's
non-default `esio` feature and Julia's `EarthSciASTEarthSciIOExt` extension.

| Before | After |
|---|---|
| `from earthsci_ast import load_grid` | `from earthsci_ast.data_sources import load_grid` |
| `from earthsci_ast import load_points, load_static, load_data, resolve_files` | `from earthsci_ast.data_sources import load_points, load_static, load_data, resolve_files` |
| `from earthsci_ast import GridLoader, PointsLoader, StaticLoader` | `from earthsci_ast.data_sources import GridLoader, PointsLoader, StaticLoader` |
| `from earthsci_ast import expand_url_template, expand_with_mirrors, template_placeholders` | `from earthsci_ast.data_sources import ...` |
| `from earthsci_ast import parse_iso_duration, file_anchor_for_time, file_anchors_in_range, records_for_file` | `from earthsci_ast.data_sources import ...` |
| `from earthsci_ast import cache_path_for_url, cached_fetcher, cached_opener, resolve_data_dir, CacheMiss` | `from earthsci_ast.data_sources import ...` |
| `from earthsci_ast import open_with_fallback, apply_variable_mapping` | `from earthsci_ast.data_sources import ...` |
| `from earthsci_ast import UrlTemplateError, TimeResolutionError, MirrorFallbackError, GridLoaderError, PointsLoaderError, StaticLoaderError, DataSourceDispatchError` | `from earthsci_ast.data_sources import ...` |

29 spellings in total. **The functions did not move and did not change** — only
the namespace they are re-exported through. `earthsci_ast.data_sources` ships
in the base install, so no extra is needed just to import them. Python's
declared surface goes **272 → 243**; every spelling removed was `extension`
tier, so the manifest's `stable` count is unchanged at 272.

Nothing is aliased: the old top-level spelling raises `AttributeError`. It is a
*self-diagnosing* one, naming the import that works:

```
>>> earthsci_ast.load_grid
AttributeError: `earthsci_ast.load_grid` moved to the data-loading tier in
phase-6 H-4 and is no longer re-exported at the top level. Import it from its
own package instead:

    from earthsci_ast.data_sources import load_grid
```

**Three names deliberately stay** on the top level — `apply_unit_conversion`,
`parse_unit_conversion` and `UnitConversionError`. They are `stable`, not
`extension`: Julia exports them from core (`src/unit_conversion.jl`, not the
EarthSciIO extension) and TypeScript exports `UnitConversionError` from its
index. They are pure arithmetic over a declared conversion and open no file, so
they belong to the format library even though this binding files them under
`data_sources/`.

### `xarray` and `netcdf4` left the base dependency set

```
pip install earthsci-ast            # format library — no netCDF stack
pip install "earthsci-ast[data]"    # + xarray + netcdf4: the grid/static readers
```

Most of the loader tier needs **neither**, and keeps working on a base install:
URL-template expansion, ISO-8601 time resolution, mirror fallback, the cache
index, unit conversion, and the CSV/JSON `points` loader. Only the xarray-backed
`grid` / `static` openers do. Asking for one without the extra is an error that
names the extra rather than an `ImportError` from three frames down:

```
XarrayLoaderError: the default data-loader opener needs `xarray`, which is not
installed. This is an OPTIONAL dependency: install the data-loading extra with
`pip install "earthsci-ast[data]"`, or pass an explicit `opener=` to the loader.
```

A loader handed an explicit `opener=` never needed xarray in the first place and
is unaffected.

### `scipy`: no change to the dependency set, clearer message

`scipy` had **already** left the base set in an earlier round (the `simulate`
extra), which is what esm-libraries-spec §2.4 / §2.5.9 requires — a library must
not embed a solver as a runtime dependency. Two stale comments claiming it was
"a HARD dependency (declared unconditionally in pyproject.toml)" are corrected.
Behaviour is unchanged: `esm_problem(...)` builds without SciPy, and `solve`
returns `ReturnCode.Failure` rather than raising on import. The message now
names the extra:

```
SciPy is required to solve an EsmProblem but is not installed. SciPy is an
OPTIONAL dependency of earthsci-ast (a library must not embed a solver as a
runtime dependency; esm-libraries-spec §2.4). Install it with
`pip install "earthsci-ast[simulate]"`.
```

### The conformance adapters are no longer console scripts

`[project.scripts]` is deleted, so `earthsci-determinism-adapter-python`,
`earthsci-cadence-adapter-python` and `earthsci-pde-sim-adapter-python` are no
longer installed onto `PATH`. `esm` (Rust) is the only command-line tool this
project ships. The adapters keep their `python3 -m` entry points, and a new
`conformance` extra carries their runtime deps (`numpy`, and `scipy` for the
PDE-simulation trajectory integration). `scripts/test-conformance.sh` already
drove them through `$EARTHSCI_<SUITE>_ADAPTER_<BINDING>`, so nothing in the
conformance path changes.

## Rust — `earthsci-ast`

| Before | After | Kind |
|---|---|---|
| `load(&str)` — took **JSON text** | `load_string(s)`; `load_path(p)` is unchanged and still takes a path; `load_document(&Value)` is new | `deleted` |
| `load_with_options(&str, &o)` | `load_string_with_options`; `load_path_with_options` unchanged; `load_document_with_options` new | `deleted` |
| `save(&file)` | `to_json(&file)` | `deleted` |
| `save_compact(&file)` | `to_json_compact(&file)` | `deleted` |
| — | `write_path(&file, path)`, plus an `EsmError::FileWrite` variant | `new` |
| `VERSION` | `LIBRARY_VERSION` — ⚠ **not** `SCHEMA_VERSION`; Rust's `VERSION` was the *package* version | `deleted` |
| `simulate(&file, tspan, &p, &u0, &opts)` | `solve(&esm_problem(…)?, &opts)` | `deleted` |
| `prepare(…)` → `Prepared`, `PrepareOptions` | `esm_problem(…)` → `EsmProblem`, `ProblemOptions` | `deleted` |
| `Compiled::simulate` | `Compiled::solve` | `deleted` |
| wasm export `simulate` | `solve` | `deleted` |
| `SimulateOptions` fields `solver` / `output_times` / `max_steps` | `alg` / `saveat` / `maxiters` (SciML spelling) | `deleted` |
| `substitute_in_expression(expr, bindings)` | `substitute(expr, bindings)` | `deleted` |
| `ReferenceError` | `ReferenceResolutionError` | `alias` |
| `validate_complete(json, base_path)` | `validate_text(json, base_path)` | `alias` |
| `build_reference_graph_with_index_sets(model, name, sets)` | `build_reference_graph(model, name, sets)` — an optional trailing argument | `alias` |
| `get_supported_migration_targets(v)` | `supported_migration_targets(v)` | `alias` |
| `lower_enums(&mut Value)` — raw and mutating | `lower_enums(&EsmFile) -> EsmFile` — typed and **pure**; `lower_enums_mut` in place; `lower_enums_raw` the raw pass | `semantics` |
| `resolve_subsystem_refs(&mut Value)` | `resolve_subsystem_refs(&mut EsmFile)`; `resolve_subsystem_refs_raw` is the raw pass | `semantics` |
| `stoichiometric_matrix` sorted species by name | declaration order | `semantics` |
| `derive_odes` omitted `system.parameters` | copies each parameter in as a `VariableType::Parameter` | `semantics` |
| `to_unicode` / `to_latex` / `to_ascii` took expressions only | take the full domain via `display::TextRenderable` | `semantics` |
| `esm graph` / `esm stoich` output | routed through the library renderers; all three formats changed | `semantics` |
| — | `to_dot`, `to_mermaid`, `to_json_graph` as free functions generic over `Graph` | `new` |
| — | the `Graph` trait, re-exported at the crate root | `new` |
| — | `ERROR_CODES`, `error_code_names()` | `new` |
| `earthsci_ast::<module>::X` | the crate root, or `earthsci_ast::extension::<module>::X` | `packaging` |
| `diffsol` a hard dependency | behind the `solve` feature | `packaging` |
| conformance-adapter binaries in a default build | behind the non-default `conformance-adapters` feature | `packaging` |
| `from_faq` / node `id` uniqueness | see [Part II](#part-ii--the-document-format-changed) | `format` |

### Module paths: the crate is encapsulated now (H-3)

`src/lib.rs` declared **53 `pub mod`s**, so the crate's real public surface was
322 declared root spellings *plus* 514 module-qualified paths across 56
reachable modules — 181 of which were in no manifest at all and were never
meant to be API. Root `pub mod` is now **8**, and resolvable paths **514 → 122**.
The **declared** surface is unchanged.

If you import through a module path, repoint it:

```rust
// before
use earthsci_ast::graph::Graph;
use earthsci_ast::reference_resolution::{EdgeKind, resolve_references};

// after — these are root exports
use earthsci_ast::{Graph, EdgeKind, resolve_references};
```

Anything reachable-but-not-stable that has a demonstrated consumer lives in the
one deliberately-named tier-2 seam, `earthsci_ast::extension`, whose submodules
mirror the private module a symbol came from so provenance survives and generic
names (`expand`, `gather`) cannot collide:

```rust
// before
use earthsci_ast::error::MessageError;
use earthsci_ast::substitute::substitute_in_continuous_event;

// after
use earthsci_ast::extension::error::MessageError;
use earthsci_ast::extension::substitute::substitute_in_continuous_event;
```

Four seams keep their own top-level path and are documented as such:
`intern`, `performance` and `simulate_array` (all three named verbatim in
`API_SPEC.md` §3), `provider` (§7's Runtime I/O family), the feature-gated
`esio_provider` and `wasm` bridges, and the doc-hidden `adapter_support` (the
conformance-adapter binaries are separate crate targets and cannot see
`pub(crate)`).

The `Graph` trait re-export closes a hole H-3 opened: `to_dot`, `to_mermaid`
and `to_json_graph` are root-exported `stable` symbols generic over
`G: Graph`, but the trait itself was never re-exported — a public generic
function with a private bound. A caller could invoke them on a concrete graph
but could not write any generic function over graphs, or name the bound at all.

### `esm graph` output changed in all three formats

The CLI rendered graphs with its own private renderer instead of the library's
`to_dot` / `to_mermaid` / `to_json_graph`, and the two had drifted:

- **DOT**: the CLI wrote `[label="x", shape=y]`, the library writes
  `[label="x" shape=y]` — a byte diff on every node line.
- **DOT / Mermaid**: the CLI interpolated ids and labels raw, with no escaping,
  so a component name containing a quote or a backslash produced **malformed**
  DOT from the CLI and correct DOT from the library.
- **JSON**: an entirely different document. Node key `type` not
  `component_type`, edge keys `from`/`to`/`type` not `source`/`target`/`data`,
  no `metadata`, and **no `adjacency` map at all** — even though
  esm-libraries-spec §5.4.5 calls that output "JSON adjacency list".

Two consequences: `--level=expression` now **works** (it used to print "not yet
implemented" and exit 1), and `esm stoich` calls the library's
`stoichiometric_matrix` instead of hand-rolling one from a sorted species
order — which would have printed the rows of one matrix under the column labels
of another once species order became declaration order.

Nothing in this repository pinned the old CLI output. If you have a golden that
captures it, regenerate it.

### `resolve_template_machinery` did **not** change

Flagged as a raw-`Value` entry point to wrap, then refused with evidence: every
binding takes raw JSON here — Python `(raw: Any, …)`, Julia `(raw_data, …)`,
TypeScript `(rawData: unknown, …)`. A typed wrapper would have made Rust the
only non-conformant binding.
`resolve_subsystem_refs_with_metaparameters` likewise keeps its raw signature
and its name: it is a Rust-only extension seam with no cross-binding
counterpart, so renaming it buys no convergence.

## Go — `earthsci-ast-go`

| Before | After | Kind |
|---|---|---|
| `Load(path, opts...)` | `LoadPath(path, opts...)`; `LoadString(json, opts...)` unchanged; `LoadDocument(map, opts...)` new | `deleted` |
| `Serialize(file)` | `ToJSON(file)` | `deleted` |
| `SerializeCompact(file)` | `ToJSONCompact(file)` | `deleted` |
| `SaveToFile(file, path)` | `WritePath(file, path)` | `deleted` |
| `SaveCompactToFile(file, path)` | `WritePathCompact(file, path)` | `deleted` |
| — | `LibraryVersion` (`SchemaVersion` is unchanged) | `new` |
| `Validate(file) *DetailedValidationResult` | `Validate(file) *ValidationResult` — the four-field shape | `semantics` |
| `ValidateFile(file, jsonStr)` | `ValidateText(jsonStr, opts...)` | `deleted` |
| `SystemKind(model, domain)` | `SystemKind(model)` | `semantics` |
| `EffectiveSystemKind(model, domain)` | `EffectiveSystemKind(model)` | `semantics` |
| — | `DeclaredSystemKind(model) *string` | `new` |
| `LowerEnums(file) error` — in place | `LowerEnums(file) (*ESMFile, error)` — **pure**; `LowerEnumsMut(file) error` in place | `semantics` |
| `LowerEnumsError` | `EnumLoweringError` | `deleted` |
| `ExportComponentGraphDOT` / `ExportExpressionGraphDOT` | `ToDOT(Graph)` | `deleted` |
| `ExportComponentGraphMermaid` / `ExportExpressionGraphMermaid` | `ToMermaid(Graph)` | `deleted` |
| `ExportComponentGraphJSON` / `ExportExpressionGraphJSON` | `ToJSONGraph(Graph)` | `deleted` |
| `DOTExporter` / `MermaidExporter` / `JSONExporter` and `NewDOTExporter` / `NewMermaidExporter` / `NewJSONExporter` | the three functions above | `deleted` |
| `SubstituteWithScoped` | `SubstituteWithContext` | `deleted` |
| `SubstituteInModelWithScoped` | `SubstituteInModelWithContext` | `deleted` |
| `SubstituteInReactionSystemWithScoped` | `SubstituteInReactionSystemWithContext` | `deleted` |
| `SubstituteInFileWithScoped` | `SubstituteInFileWithContext` | `deleted` |
| `ErrorIcInReactionSystem` | `ErrorICInReactionSystem` | `deleted` |
| `ToAscii` | `ToASCII` | `deleted` |
| `FmtAscii` | `FmtASCII` | `deleted` |
| `UnitWarning.LhsUnits` / `.RhsUnits` (struct fields) | `.LHSUnits` / `.RHSUnits` | `deleted` |
| `Substitute` expanded replacements transitively | single-pass: `{a: b, b: c}` renames `a` to `b`, not to `c` | `semantics` |
| `DeriveODEs` / `StoichiometricMatrix` sorted species by name | authored declaration order, read from `ESMFile.keyOrders` | `semantics` |
| `ToUnicode` / `ToLatex` / `ToASCII` took expressions only | take the full domain | `semantics` |
| — | the `Graph` interface, `DeriveODEs`, `StoichiometricMatrix`, `LevelError`, `LevelWarning` | `new` |
| `main.go` — the `esm-go` CLI | **deleted**; use `esm` (Rust) | `packaging` |
| `from_faq` / node `id` uniqueness | see [Part II](#part-ii--the-document-format-changed) | `format` |

### `Validate` returns a different struct

Go answered the canonical name `validate` with the legacy message-oriented
`DetailedValidationResult` and put the four-field shape every other binding
returns on a *second* function, `ValidateFile`.

```go
// before
res := esm.Validate(file)          // *DetailedValidationResult{Valid, Messages}

// after
res := esm.Validate(file)          // *ValidationResult{SchemaErrors,
                                   //   StructuralErrors, UnitWarnings, IsValid}
```

`DetailedValidationResult` and `ValidationMessage` **still exist** and are
still exported (`extension` tier). If you want the legacy shape, call
`ValidateStructural(file)`, which is unchanged and is what `Validate`
delegated to.

`Validate`'s `SchemaErrors` is **always empty**, matching Rust's documented
behaviour: a `*ESMFile` can only exist by having come through `LoadString` /
`LoadPath` / `LoadDocument`, all of which schema-validate and refuse to return a
document that fails. Text is the only input that can carry schema errors, which
is why `ValidateFile`'s work went to `ValidateText(jsonStr, opts...)` — and the
typed argument `ValidateFile` took beside the text, one the schema half never
read, is gone.

`ValidatePath` is deliberately **not** added: Go has no path-validating library
entry point to rename, and the CLI's was in `main.go`, which H-5 removes.

### `SystemKind` lost its `domain` argument

Verified unread before removal: neither `SystemKind`'s nor
`EffectiveSystemKind`'s body referenced it, and `SystemKind`'s own doc comment
claimed it was "used only for the independent-variable name" — a claim its body
contradicted. The parameter was vestigial from the pre-v0.8.0 rule that read
`Domain.spatial`, which v0.8.0 deleted;
`tests/conformance/classification/manifest.json` already spelled the contract
`system_kind(model)`.

`DeclaredSystemKind` is the only member of the family that can answer "the
document did not say" — `SystemKind` always derives an answer and
`EffectiveSystemKind` always produces one.

### `LowerEnums` is pure

```go
// before
err := esm.LowerEnums(file)            // file mutated

// after
lowered, err := esm.LowerEnums(file)   // file untouched
err := esm.LowerEnumsMut(file)         // file mutated
```

The signature moved with the semantics, so the pure form *will* fail to
compile — this one is not silent in Go. The hazard is switching to
`LowerEnumsMut` mechanically without noticing why the pure form exists: the
pass writes as it walks and does not roll back, so an in-place failure leaves
the caller's document **partially lowered** with no way to tell. `LowerEnums`
returns a nil document alongside the error, so that value cannot exist.

Purity is achieved by copying exactly the containers the pass writes into — the
models / reaction-systems maps and the equation, event, reaction and coupling
slices inside them — and nothing else, so this is not a whole-document deep
copy.

The error type is renamed to join the cross-binding symbol Rust and TypeScript
already shared: `LowerEnumsError` → `EnumLoweringError`. It is `extension`
tier, so the rename is a minor under §10 and carries no alias.

### The six graph exporters became three

Go named the same three renderings as six functions, one per (format, graph
type) pair, plus three exported exporter objects reachable in parallel. The
union of the two graph types is now the exported `Graph` interface, whose only
method is **unexported** — no type outside package `esm` can satisfy it, which
is what makes the type switch inside each renderer total.

`ToJSONGraph`, not `ToJSON`: `to_json` is the document serializer and one name
cannot carry both meanings. The rendering bodies were moved, not edited — the
emitted DOT / Mermaid / JSON text is byte-identical, as
`tests/conformance/graph/cases.json` requires. All nine deleted names were
`extension` tier, so removing them is a minor under §10.

### `Substitute` is single-pass — and this one is silent

Go expanded replacements **transitively**, which (a) silently corrupted chained
renames — `Substitute("a", {a: b, b: c})` returned `"c"`, not `"b"`,
mis-applying every overlapping rename through `renameRawExpr` — and (b) made
cyclic binding sets non-terminating, which was then patched with cycle
detection instead of by removing the transitivity.

The other four bindings never looped: all four are single-pass, so a cyclic
binding set terminates on its own, exactly as `CONFORMANCE_SPEC.md` §2.2.3
rule 1 requires. Go was the sole non-conformant binding. `SubstitutionError`
and the `cyclic_substitution` code are removed as unnecessary; the `error`
return is retained for signature stability across the substitution family.
Pinned cross-binding by `tests/substitution/cyclic_bindings.json`.

**A binding map is now usable as a simultaneous rename map.** If you were
relying on transitive expansion, apply the map twice.

### Species order is authored order

`ReactionSystem.Species` is a `map[string]Species`, and by the time
`DeriveODEs` or `StoichiometricMatrix` runs, declaration order is gone — so
sorting really was the only deterministic option *at that call site*. It was
not the only option in the package: `ESMFile.keyOrders` records the authored
JSON key order of every object in the document, captured by `LoadString` from
the text before the template pass re-marshals. `ReactionSystem` now carries an
unexported, untagged `speciesOrder []string` that `LoadString` fills from it.
The field widens neither the API surface nor the wire.

Sorted-name order remains the fallback wherever no authored order exists — a
system built in code, or one reached through a subsystem mount — so those keep
today's behaviour and stay deterministic. Pinned by the new cross-binding
corpus `tests/conformance/reactions/species_order.json`.

### `LHSUnits` / `RHSUnits`: the wire contract is untouched

The `json:"lhs_units"` / `json:"rhs_units"` tags are unchanged — verified by a
marshal → unmarshal → marshal round trip that is byte-identical before and
after the rename — and the `"lhs_units"` / `"rhs_units"` keys
`promoteUnitFindings` writes into `StructuralError.Details` are likewise
unchanged. Only the Go field names moved, to match this package's own house
style: `FlattenedEquation.LHSString` / `.RHSString` already spelled the same
two initialisms uppercase, so these two fields were the outliers.

Struct fields are not manifest symbols, so `api-surface.json` does not move for
this row.

### There is no Go CLI any more

`pkg/earthsci-ast-go/main.go` is deleted. It was a second command-line tool,
`esm-go`, with six overlapping commands (parse / validate / pretty-print /
substitute / save / summary). Nothing under `scripts/`, no Makefile, no
conformance runner and no documentation invoked it — `grep -rn esm-go` over
`*.md` returns nothing. The conformance adapter is a different binary,
`cmd/esm-conformance`, which is untouched. `esm` (Rust) is the project's only
shipped CLI.

## Editor — `@earthsciml/ast-editor`

**Nothing changed.** All 71 declared spellings are identical before and after.
The editor's web components had already migrated off TypeScript's
`component_graph` before it was deleted, which is why deleting it broke no
caller.

---

# Part IV — Cross-cutting changes, explained once

## Document I/O: `load` → `load_path` / `load_string` / `load_document`

`load(<string>)` meant a **file path** in Julia and Go and **JSON text** in
TypeScript and Rust. Python sniffed: `os.path.exists(s)` decided which. One
name, one argument type, opposite meanings, and no type error anywhere to
catch the difference — a program ported between bindings failed at runtime, or,
if the path happened to be valid JSON, did the wrong thing silently.

The old names are **deleted, not deprecated**: a compatibility shim would have
had to preserve the sniff, which is the defect.

| Was | Now — read a FILE | Now — parse JSON TEXT | Now — take a PARSED document |
|---|---|---|---|
| Julia `load(path::String)` | `load_path(path)` | `load_string(json)` | `load_document(dict)` |
| Julia `load(io::IO)` | – | `load_string(io)` | – |
| Julia `load(doc::AbstractDict)` | – | – | `load_document(doc)` |
| TypeScript `load(input, opts?)` | `loadPath(path, opts?)` | `loadString(json, opts?)` | `loadDocument(obj, opts?)` |
| Python `load(path_or_string)` | `load_path(path)` | `load_string(json)` | `load_document(dict)` |
| Rust `load(&str)` | `load_path(p)` *(unchanged)* | `load_string(s)` | `load_document(&Value)` |
| Rust `load_with_options(&str, &o)` | `load_path_with_options` *(unchanged)* | `load_string_with_options` | `load_document_with_options` |
| Go `Load(path, opts...)` | `LoadPath(path, opts...)` | `LoadString(json, opts...)` *(unchanged)* | `LoadDocument(map, opts...)` |

All three run the identical pipeline: top-level `{ref}` inlining, version
gates, schema validation, §9.7 template machinery, typed coercion, and nested
subsystem-ref resolution. `load_path` anchors relative refs at the file's own
directory; the other two take `base_path` (Go: `WithBasePath`).

Options move to the entry points they apply to. TypeScript's `canonical` (which
tags numeric literals during JSON DECODING) applies to `loadPath` and
`loadString` only — a `loadDocument` caller has already decoded, and should
run `losslessJsonParse` on the text itself if it wants tagged leaves.

Two sanctioned per-binding decorations:

- **Rust** keeps `*_with_options` twins; it has no default arguments.
- **Julia** gives `load_string` an `::IO` method beside `::AbstractString`. It
  reads the stream to a string and parses that — a method on the canonical
  entry point, not a fourth one.

**If you sniffed on purpose.** A few callers legitimately accept "a path or the
content" — a conformance harness holding fixture text rather than its path is
the usual case. Do the sniff yourself, at your own boundary, where it is
visible:

```python
if isinstance(x, dict):        doc = load_document(x, base_path=base)
elif os.path.exists(x):        doc = load_path(x, base_path=base)
else:                          doc = load_string(x, base_path=base)
```

Note that **`validate()` no longer does this for you**. The phase-2 split moved
the sniff out of `load`; the phase-6 pass moved it out of `validate` too, for
the same reason — see each binding's `validate` row.

## Serialization: `save` → `to_json` / `to_json_compact` / `write_path`

`save` was pure serialization in TypeScript and Rust, a disk write in Julia,
and both in Python (`path=None` decided). Go alone split them by name — and
used names no other binding used. **No function in this API both writes and
returns the payload any more.**

| Was | Now |
|---|---|
| Julia `save(file, path::String)` | `write_path(file, path)` → `nothing` |
| Julia `save(file, io::IO)` | `write(io, to_json(file))` |
| TypeScript `save(file, opts?)` | `toJson(file, opts?)` |
| TypeScript `SaveOptions` | `ToJsonOptions` |
| Python `save(file)` | `to_json(file)` |
| Python `save(file, path)` | `write_path(file, path)` → `None` |
| Rust `save(&file)` | `to_json(&file)` |
| Rust `save_compact(&file)` | `to_json_compact(&file)` |
| Go `Serialize(file)` | `ToJSON(file)` |
| Go `SerializeCompact(file)` | `ToJSONCompact(file)` |
| Go `SaveToFile(file, path)` | `WritePath(file, path)` |
| Go `SaveCompactToFile(file, path)` | `WritePathCompact(file, path)` |

`to_json_compact` exists in all five rather than being an option, because Rust
and Go have no default arguments and so cannot express `to_json(file,
indent=0)`. Python (`to_json(file, *, indent=2)`) and TypeScript
(`toJson(file, {indent, canonical})`) take the option as well, and their
`to_json_compact` is a one-line wrapper over it. `write_path` is present in all
five, TypeScript included.

**Julia takes no `indent`**, and its `to_json_compact` returns exactly what
`to_json` returns. The reason is a defect this rename surfaced rather than
introduced: `save` passed `indent=2` to `JSON3.write`, and JSON3 ignores that
keyword — so Julia has been emitting UNINDENTED JSON all along while claiming
otherwise. Rather than carry an option that does nothing, `to_json` takes
none and says so. (Byte-canonical output has always been a separate path:
`emit_esm_string`, esm-spec §9.6.4 rule 5.)

The COMPACT bytes now agree across bindings. Python's `json.dumps(indent=None)`
still emits `", "` / `": "` separators where serde_json, `encoding/json` and
`JSON.stringify` emit none, so `to_json_compact` pins `separators=(",", ":")`.

Rust gains an `EsmError::FileWrite` variant. `write_path`'s I/O failures used
to have to be reported through `FileRead`, whose message reads "failed to read
{path}" — the wrong sentence for a failed write.

**Name collision worth knowing about.** `to_json` was already the graph
serializer's name in Julia and Python (TypeScript and Rust had already moved
theirs to `toJsonGraph` / `to_json_graph`). Julia's two dispatch on argument
type and both keep the name — the `Graph` methods are a deprecated alias of
`to_json_graph` for one minor and render byte-identical output. Python's graph
serializer is now re-exported as `to_json_graph`:

```python
from earthsci_ast import to_json_graph   # was: to_json, on a Graph
from earthsci_ast import to_json         # now: the DOCUMENT serializer
```

## Version constants: `SCHEMA_VERSION` + `LIBRARY_VERSION`

`VERSION` meant the **schema** version in TypeScript and the **package**
version in Rust. Julia exported only `ESM_FORMAT_VERSION` (the schema version,
under a name nobody else used). Python kept the format version private, as
`parse._CURRENT_VERSION`, and as a `(major, minor, patch)` tuple rather than a
string. Go exposed neither.

Two public **string** constants everywhere:

| Was | Now |
|---|---|
| Julia `ESM_FORMAT_VERSION` | `SCHEMA_VERSION` |
| Julia *(none)* | `LIBRARY_VERSION` |
| TypeScript `SCHEMA_VERSION` | `SCHEMA_VERSION` *(unchanged)* |
| TypeScript `VERSION` *(alias of the above)* | `LIBRARY_VERSION` — a **different number** |
| Python `parse._CURRENT_VERSION` *(private tuple)* | `SCHEMA_VERSION` *(public string)* |
| Python `__version__` | `LIBRARY_VERSION` *(`__version__` still works)* |
| Rust `SCHEMA_VERSION` | `SCHEMA_VERSION` *(unchanged)* |
| Rust `VERSION` | `LIBRARY_VERSION` |
| Go `SchemaVersion` | `SchemaVersion` *(unchanged)* |
| Go *(none)* | `LibraryVersion` |

> **⚠ TypeScript callers reading `VERSION`:** it was the SCHEMA version. The
> replacement is `SCHEMA_VERSION`, not `LIBRARY_VERSION`.
>
> **⚠ Rust callers reading `VERSION`:** it was the PACKAGE version. The
> replacement is `LIBRARY_VERSION`, not `SCHEMA_VERSION`.

Python's `_CURRENT_VERSION` tuple still exists as an internal, now derived from
`SCHEMA_VERSION` rather than being the source of truth. `migration.SCHEMA_VERSION`
is re-exported from `parse` rather than computed a second time.

Each constant is derived from that binding's existing source of truth rather
than a second hand-kept copy: `SCHEMA_VERSION` from the bundled schema's `$id`
(TypeScript, Python, Go) or a literal pinned to it by a test (Julia, Rust);
`LIBRARY_VERSION` from `CARGO_PKG_VERSION` (Rust), `pkgversion` (Julia),
`importlib.metadata` (Python), and package.json pinned by a test (TypeScript).
Go's `LibraryVersion` is the exception, and says why at the constant: a Go
module carries no in-tree version manifest — its version is the git tag — so
there is nothing to derive from or pin against.

## The simulation surface: `EsmProblem` + `solve`

`simulate` is **deleted** in Julia, Python and Rust — not deprecated, not
aliased. So are `prepare`, `PreparedModel` / `Prepared`, `SimulateOptions`,
`SimulationResult` and `SolverChoice`. TypeScript and Go are unaffected: they
have no simulation surface and gain none.

The normative contract is `esm-libraries-spec.md` §2.5; the surface it implies is
`API_SPEC.md` §5.8.

### `simulate(...)` → `esm_problem(...)` + `solve(...)`

A run is now two steps, because their costs differ by orders of magnitude and
their inputs differ in kind. Construction is deterministic per *document* — it
rewrites, invents values, fetches gated provider data, and compiles the
right-hand side. `solve` varies only per-*run* knobs.

```
prob = esm_problem(input, tspan; p, u0, providers, ...)   # build once
sol  = solve(prob; alg, abstol, reltol, saveat, ...)      # run per knob-set
```

This is not a new idea being imposed: two of the three bindings had already grown
a second, `prepare`-shaped entry point beside `simulate` precisely because callers
needed the split. It was spelled differently in each, and took different
arguments. `prepare` is *replaced by* construction, not kept beside it.

| Was | Now |
|---|---|
| Julia `simulate(input, tspan; ...)` | `solve(esm_problem(input, tspan; ...), alg; ...)` |
| Julia `simulate(prep, tspan; ...)` | `solve(prob, alg; ...)` |
| Julia `prepare(input; ...)` → `PreparedModel` | `esm_problem(input, tspan; ...)` → `EsmProblem` |
| Julia `remake_parameters(prep, overrides)` | `remake(prob; p = overrides)` |
| Python `simulate(file, tspan, ...)` | `solve(esm_problem(file, tspan, ...))` |
| Python `prepare(input, ...)` → `PreparedModel` | `esm_problem(input, tspan, ...)` → `EsmProblem` |
| Rust `simulate(&file, tspan, &p, &u0, &opts)` | `solve(&esm_problem(...)?, &opts)` |
| Rust `prepare(...)` → `Prepared` | `esm_problem(...)` → `EsmProblem` |
| Rust `Compiled::simulate` | `Compiled::solve` |
| Rust wasm export `simulate` | `solve` |

The type is `EsmProblem` in all three, following `EsmFile` — which is prefixed in
every binding, including the ones with module namespacing.

Julia's `remake_parameters` still exists as an `extension`-tier helper, but it
now takes an `EsmProblem` and returns the swapped parameter vector; the
caller-facing operation is `SciMLBase.remake`, which
`EarthSciAST.remake(prob::EsmProblem; …)` is the same function as.

### Option names are SciML's everywhere

| Canonical | Julia was | Python was | Rust was |
|---|---|---|---|
| `alg` | `alg` | `method: str = "LSODA"` | `solver: SolverChoice` |
| `abstol` | `abstol` | `atol` | `abstol` |
| `reltol` | `reltol` | `rtol` | `reltol` |
| `saveat` | `saveat` | *(absent)* | `output_times` |
| `maxiters` | — | — | `max_steps` |

### Default tolerances changed, in the LOOSE direction

**`reltol = 1e-4`, `abstol = 1e-6`** in every binding — Julia's values.

All three previously differed, spanning six orders of magnitude (Julia
`1e-4`/`1e-6`, Rust `1e-6`/`1e-8`, Python `1e-10`/`1e-14`), so no two solved the
same document comparably without the caller naming a tolerance. A default is what
a document gets when its author has expressed no opinion about accuracy, so it is
the cheapest of the three rather than the most accurate.

**If you have a test that asserts a trajectory, give it an explicit tolerance.**
A test that relied on the old default was asserting something about the library's
default rather than about your model, and it will now fail. Widening the
assertion's own comparison threshold is the wrong repair. This is not
hypothetical: 21 tests in this repo were in exactly that position, and all 21
were fixed by passing the accuracy they actually needed.

### `success` + `message` → `retcode`

A solution carries `retcode` from the SciML `ReturnCode` vocabulary — at minimum
`Success`, `MaxIters`, `Unstable`, `Terminated`, and a solver-failure code. It
replaces a `success` boolean beside free-text `message`, and, in Rust, step and
eval counters that callers were reading as a proxy for whether the run finished.
Counters remain as informative statistics. A caller must be able to tell "ran to
the end of `tspan`" from "stopped early, here is why" without parsing prose.

Julia goes further: a solution is now a real `ODESolution`, and
`SciMLBase.__init` / `__solve` are specialized on `EsmProblem`, so the standard
SciML entry points work directly.

### A failed BUILD raises

An unlowerable operator, a cyclic observed graph, or an undiscretized spatial
operator is a *construction* error and is raised as one. `retcode` describes runs
that happened; a document that never became a Problem has no run to describe.
`simulate` used to report these as a failed result while `prepare` raised — that
split is gone. **Code that inspected `result.success` for build failures needs a
`try` / `except`, not a rename.**

### Callbacks: a `callback` argument REPLACES the Problem's set

Callbacks are declared on the Problem, because a callback that refreshes provider
buffers or writes an output stream belongs to the document, not to a particular
run's tolerances. A `callback` argument to `solve` **replaces** that set — it does
not append, merge, or wrap.

To extend rather than replace, read the set back and compose explicitly:

```
solve(prob; callback = compose(callbacks(prob), my_extra_callback))
```

Solver **stops are unioned, not replaced**: a Problem's refresh and output anchors
are `tstops` its callbacks need to be correct, and a refresh callback that is
never stopped at silently interpolates across a data boundary.

### Results are indexed by NAME

`sol["Chem.O3"]`, not `sol.u[3]`. Julia implements `SymbolicIndexingInterface`;
the others expose name-keyed accessors. The flattened state ordering is an
implementation detail that coupling can change, so positional access is no longer
the documented path.

### Also

- `observed_field(prob, name)` — two arguments in all three. Julia's took
  `(prep, insp::BuildInspection, name)` and required the caller to have threaded
  the same `BuildInspection` through `prepare`; Rust's was a method on `Prepared`.
- `init` / `step!` / `solve!` expose the stepping lifecycle. On this path **the
  caller owns the sink lifecycle** — `solve` brackets the run with sink
  open/close, and a caller stepping manually is outside that bracket.
- `EnsembleProblem` is the canonical form for sweeps and Monte Carlo.
- **Solvers are optional.** Constructing a Problem must not require the
  integrator. Rust's `diffsol` is now behind a `solve` feature; Python's SciPy is
  a `simulate` extra; Julia's solver stays a package extension.

> **Correction to an earlier draft of this guide.** A previous revision recorded
> that Go's `ParameterSweep` / `SweepRange` / `SweepDimension` were deleted as an
> orphaned sweep vocabulary. **They were not, and they should not be**: they are
> `.esm` **document** types for the `parameter_sweep` block of a component's
> `analyses`, not a simulation API, and Go round-trips them
> (`pkg/esm/tests_analyses_roundtrip_test.go`). All three are still exported and
> still in `api-surface.json`. Nothing to migrate.

## Packaging and distribution

| Binding | Change |
|---|---|
| Python | `xarray`, `netcdf4` → the `data` extra. `scipy` → the `simulate` extra (already true before this release; the stale comments claiming otherwise are corrected). `numpy` + `scipy` for the conformance adapters → the new `conformance` extra. |
| Python | 29 loader names left `__all__`; import them from `earthsci_ast.data_sources`. |
| Python | `[project.scripts]` deleted — the three `earthsci-*-adapter-python` console scripts are gone; use `python3 -m`. |
| Rust | Root `pub mod` 53 → 8. Rewrite `earthsci_ast::<module>::X` to the crate root or `earthsci_ast::extension::<module>::X`. |
| Rust | `diffsol` behind the `solve` feature; the three conformance-adapter binaries behind the non-default `conformance-adapters` feature, so a default `cargo build` / `install` / `publish` no longer produces them. |

> **`default-features = false` now silently costs you `solve`.** The `solve`
> feature is in `default`, so a plain dependency is unaffected — but a crate
> that opted out of default features for some unrelated reason (dropping the
> `cli`, say, back when `solve` was not yet a feature) loses the integrator
> without ever naming it. The failure does not read as a missing feature:
>
> ```
> error[E0432]: unresolved import `earthsci_ast::solve`
>   note: found an item that was configured out
> error[E0599]: no method named `solve` found for struct `ArrayCompiled`
> ```
>
> `esm_problem`, `ProblemOptions`, `Alg`, `SolveOptions`, `compile_array`,
> `load_path_with_options` and `ArrayCompiled` all resolve normally, so the
> crate looks migrated right up to the point it has to integrate. If you build
> with `default-features = false` and you solve, add `features = ["solve"]`.
> Found in `simpleclimate.esm/run-model-rs` while migrating it.

| Go | `main.go` deleted — no more `esm-go` binary. |
| all | **`esm` (Rust) is the only command-line tool this project ships.** |

---

# Part V — What did NOT change

Listed because knowing the boundary is what stops you over-migrating.

- **`to_json(file)` is the document serializer** in all five, and stays that
  way. The graph renderer is `to_json_graph`. Julia's two dispatch on argument
  type; Julia's `Graph` methods of `to_json` are the one deprecated alias.
- **`build_evaluator` survives unchanged** as a documented `extension`-tier
  seam. It has 117 real call sites downstream and is not deprecated by any of
  this.
- **`load_path` (Rust) and `LoadString` (Go)** already meant what they now mean
  and are untouched.
- **`SCHEMA_VERSION` (TypeScript, Rust) and `SchemaVersion` (Go)** are
  unchanged.
- **The `system_kind_mismatch` finding** is unchanged — `validate` still reports
  it with the same code, path and `details`. Only Julia's
  `declared_system_kind_mismatch` *function* went away.
- **Graph rendering bytes** are unchanged in every binding. Go's six exporters
  became three functions by moving the bodies, not editing them, and Rust's
  three free functions forward to the inherent renderers. Pinned by
  `tests/conformance/graph/cases.json`. (The Rust **CLI**'s output did change —
  it had drifted from the library.)
- **Error code VALUES** are unchanged everywhere. Python's and Rust's new
  `ERROR_CODES` registries are built from the existing definitions rather than
  restating them, and are tested to resolve every name to its original string.
- **Go's `lhs_units` / `rhs_units` JSON keys** are unchanged; only the Go struct
  field names moved.
- **Go's `DetailedValidationResult`** still exists and is still exported;
  `ValidateStructural` returns it.
- **`resolve_template_machinery`** takes raw JSON in every binding and is
  untouched.
- **Go's `ParameterSweep` / `SweepRange` / `SweepDimension`** are `.esm`
  document types and are untouched.
- **The `@earthsciml/ast-editor` surface** is unchanged in full.
- **TypeScript's `lowerEnums`, `toDot` / `toMermaid` / `toJsonGraph`, and the
  display renderers** were already conformant and were verified, not changed.
- **`Expression` and `Expr` (TypeScript) are deliberately not collapsed.** They
  are two different types; see the note at the top of `types.ts`.

---

## Where the contract lives

- `API_SPEC.md` §6 — the full `stable` surface; §8 — the reconciliation ledger;
  §10 — the change policy (what an alias means and how long it lives).
- `api-surface.json` — the machine-checked manifest. A symbol carrying two
  spellings for one binding is a live deprecation alias, and both spellings are
  asserted.
- `python3 scripts/extract-api-surface.py --check` — asserts all six bindings
  against the manifest, in both directions.
