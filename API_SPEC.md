# EarthSciAST API Surface Contract

**Status:** phase 1 of API harmonization — the contract and its enforcement.
**Companion manifest:** [`api-surface.json`](api-surface.json) (machine-readable).
**Format spec:** [`esm-spec.md`](esm-spec.md) / [`esm-schema.json`](esm-schema.json).

`esm-schema.json` is language-neutral: it says what an ESM *document* is, once,
and every binding conforms to that one statement. Nothing played the same role
for the *API*. Six bindings implement one format, each documented separately in
[`esm-libraries-spec.md`](esm-libraries-spec.md) §5 in prose that has gone stale,
and nothing anywhere pinned the public surface. So the bindings drifted: the same
capability acquired different names, the same name acquired different meanings,
and neither could fail a test.

This document is the API's `esm-schema.json`. It names every public operation
**once**, in canonical `snake_case`, and gives a mechanical rule for deriving
each binding's spelling from that one name. `api-surface.json` carries the same
content for machines, and six surface tests hold every binding to it.

---

## 1. Scope, and how to read this

Six packages are in scope:

| Binding | Package | Surface declaration |
|---|---|---|
| Julia | `EarthSciAST.jl` | the `export` block of `src/EarthSciAST.jl` |
| TypeScript | `@earthsciml/ast` | named re-exports of `src/index.ts` |
| Python | `earthsci-ast` | `__all__` of `src/earthsci_ast/__init__.py` |
| Rust | `earthsci-ast` | root `pub use` / `pub const` of `src/lib.rs` |
| Go | `.../pkg/esm` | package-level exported identifiers |
| Editor | `@earthsciml/ast-editor` | named re-exports of `src/index.ts` |

The canonical name is always `snake_case`, for every kind of symbol. A symbol's
identity is the pair **(canonical name, kind)**, where kind is one of
`function`, `type`, `error`, `constant`. That pair — not the spelling — is what
two bindings must agree on to be talking about the same thing. It is also why
`system_kind` appears twice below: TypeScript's `systemKind` function and its
`SystemKind` type are genuinely two symbols.

`api-surface.json` is **bootstrapped from what the bindings export today**, not
from where this document wants them to end up. Every assertion in it is true of
the current tree, so the surface tests are green on `main`. Everything this
document wants changed is in §8, *Planned reconciliations*, which nothing
asserts. A red suite on `main` would be worse than an incomplete manifest.

---

## 2. The transliteration rule

One canonical name mechanically determines the name in every binding. Given a
canonical `snake_case` name and its kind:

| Kind | Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|---|
| `function` | verbatim | `lowerCamelCase` | verbatim | verbatim | `PascalCase` |
| `type` | `PascalCase` | `PascalCase` | `PascalCase` | `PascalCase` | `PascalCase` |
| `error` | `PascalCase` | `PascalCase` | `PascalCase` | `PascalCase` | `PascalCase` |
| `constant` | `SCREAMING_SNAKE` | `SCREAMING_SNAKE` | `SCREAMING_SNAKE` | `SCREAMING_SNAKE` | `PascalCase` |

Worked examples:

| Canonical | Kind | Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|---|---|
| `ode_states` | function | `ode_states` | `odeStates` | `ode_states` | `ode_states` | `ODEStates` |
| `to_json` | function | `to_json` | `toJson` | `to_json` | `to_json` | `ToJSON` |
| `esm_file` | type | `EsmFile` | `EsmFile` | `EsmFile` | `EsmFile` | `ESMFile` |
| `dae_info` | type | `DaeInfo` | `DaeInfo` | `DaeInfo` | `DaeInfo` | `DAEInfo` |
| `schema_version` | constant | `SCHEMA_VERSION` | `SCHEMA_VERSION` | `SCHEMA_VERSION` | `SCHEMA_VERSION` | `SchemaVersion` |

### 2.1 Initialisms

Go **must** uppercase an initialism wherever one appears, per Go's own naming
convention: `ODEStates`, `ToJSON`, `ESMFile`, `DAEInfo`, `IsODEState`. The
recognised set is:

> `esm` `ode` `dae` `pde` `sde` `ast` `json` `xml` `url` `uri` `id` `io` `dot`
> `cf` `ic` `rhs` `lhs` `cse` `faq` `api` `http` `https` `uuid` `csv` `ascii`
> `html` `cli` `mtk` `ml` `db` `os` `ip` `tls`

Every other binding **may** uppercase an embedded initialism but is not required
to: `AstExpr` and `ASTExpr` are both conforming Julia, `EsmFile` and `ESMFile`
both conforming Python. Pick one per binding and stay consistent — TypeScript
currently is not (see §8, `derive_odes`).

### 2.2 Sanctioned per-binding decorations

Two spelling details are binding-idiom, not divergence, and neither creates a
new canonical symbol:

- **Julia's mutating `!`.** A Julia function that mutates its argument may append
  `!` (`resolve_subsystem_refs!`, `lower_enums!`). It may also export both twins
  under one canonical name, as `apply_unit_conversion` does.
- **Go's error-value prefix.** A sentinel `var ErrX` is kind `error`, not
  `constant`.

### 2.3 What the rule is *not*

It does not settle argument lists, argument order, keyword-vs-positional,
mutation, or error channel. Those are §4 and §5. A binding can satisfy §2
perfectly and still be wildly incompatible — `load` was, until §5.1 split it.

---

## 3. Surface tiers

Every exported symbol belongs to exactly one tier.

### stable API

Harmonized across bindings, surface-tested, **breaks only at a major version**.
A `stable` symbol may not be renamed, removed, or have its kind changed in a
minor release. Adding one is a minor.

Today's rule for membership, applied mechanically by
`scripts/gen-api-surface.py`: a `(name, kind)` exported by **two or more**
bindings is `stable`. Two independent implementations agreeing on a name is the
best available evidence that the name is load-bearing rather than incidental.
The editor's component surface is `stable` by explicit allowlist, since it is
that package's entire public product.

**237 symbols.** 31 of them are exported by five or more bindings; 8 are
allowlisted single-binding entries.

### extension seam

Named and documented, **may differ between bindings, may break at a minor**.
This is where a binding is allowed to be itself: a Julia build seam that has no
Rust counterpart, a Rust performance knob that has no reason to exist in
TypeScript. Being in this tier is not a demerit — it is a promise that the
symbol is *reachable and documented*, and a warning that it is not portable.

**641 symbols.** Known members, called out by name:

- **Julia's build/inspection seam** — `build_evaluator`, `BuildInspection`,
  `evaluate_expr`, `expanded_model`, `expand_flattened_refs`, `param_map`,
  `parameter_classes`, `remake_parameters`.
- **Julia's forcing-buffer surface** (out-of-place RHS explicit buffers, perf
  plan B2) — `rhs_with_buffers`, `forcing_buffers`, `forcing_buffer_index`,
  `sync_forcing!`, `oop_intern_stats`, `oop_intern_stats_reset!`.
- **Rust's `intern` / `performance` / `simulate_array` internals** —
  `CompactExpr`, `PerformanceError`, `ParallelEvaluator`, `ModelAllocator`,
  `Compiled`, `ResolvedExpr`, `interpret`, `compile_array`,
  `fold_constant_expr`, `stoichiometric_matrix_parallel`, and the module paths
  `earthsci_ast::intern::*`, `::performance::*`, `::simulate_array::*`.
- **Host/runtime integration seams** — the callback constructors
  (`build_refresh_callback`, `build_output_callback`,
  `build_checkpoint_callback`), the sink protocol (`AbstractSink`,
  `build_zarr_sink`, `zarr_restart_state`), and the provider constructors
  (`providers_from_document`, `PrepareProvider`).

Rust's `pub mod` list is pinned at module granularity only: a module's interior
is an extension seam, and `api-surface.json` records the module list rather than
each module's members.

### private

Everything else — and genuinely unreachable. **A symbol absent from
`api-surface.json` must not be exported.** That is not a convention; it is what
the six surface tests assert. There is no private section of the manifest,
because privacy is expressed by absence.

### Capability profiles

Not every capability belongs in every binding, and "absent" must be
distinguishable from "drifted away".

| Profile | Bindings | Covers |
|---|---|---|
| core | Julia, TS, Python, Rust, Go | parse / serialize / validate / display / canonicalize / graph / edit / flatten |
| classification | Julia, TS, Python, Rust, Go | esm-spec §6.3.1 derived variable classification |
| simulation | Julia, Python, Rust | build an RHS and integrate it |
| runtime I/O | Julia, Python, Rust | data-source providers, refresh cadence, output sinks, checkpoints |
| UI | Editor | interactive SolidJS editing components |

**TypeScript and Go are deliberately non-simulating.** They read, write,
analyse, and transform documents; they do not integrate them. A `simulate`
missing from Go is conformance, not a gap. This matches
`esm-libraries-spec.md` §5's own tier labels — TypeScript "Core + Analysis",
Go "Core" — which are the one part of that section still accurate. Its label
for Rust is not (see §11).

---

## 4. SciML vocabulary is canonical

Where a concept comes from the SciML common interface, **the SciML spelling is
the canonical one**, in every binding, regardless of what that language's own
numerical ecosystem calls it:

| Canonical | Means | Not |
|---|---|---|
| `abstol` | absolute solver tolerance | `atol` |
| `reltol` | relative solver tolerance | `rtol` |
| `saveat` | output times / output step | `output_times`, `t_eval` |
| `tspan` | `(t0, t1)` integration interval | `t_span`, `time_range` |
| `u0` | initial state vector | `y0`, `x0` |
| `p` | parameter vector | `params`, `args` |
| `alg` | solver algorithm | `method`, `solver` |
| `retcode` | solver return code | `status`, `success` |
| `remake` | rebuild a problem with substitutions | `update`, `with_` |
| `solve` | run to completion | — |
| `init` | build a stepping iterator | — |

So **Python takes `abstol` / `reltol` / `alg`, not scipy's `atol` / `rtol` /
`method`**, and Rust's `SimulateOptions` field is `saveat`, not `output_times`.
Neither is true today; both are in §8.

The rationale is that these names travel with the *problem*, not the *solver*.
A user who writes an ESM document and runs it from Julia, then from Python,
should be tuning the same knob under the same name. Deferring to each
language's local numerical convention is exactly how the current three-way split
happened.

---

## 5. Core stable operations

Argument roles, return type, and error type for the operations that carry the
format. Each entry gives the **canonical contract**, then what each binding does
**today**, then any divergence that §8 will close. Where a divergence is listed,
the canonical contract is the target, not a description of current behaviour.

### 5.1 Document I/O

#### `load_path` / `load_string` / `load_document` — read a document

**Canonical, and landed.** Three entry points, one per input shape, each
saying which it is:

| Canonical | Takes | Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|---|---|
| `load_path` | a filesystem path | `load_path` | `loadPath` | `load_path` | `load_path` | `LoadPath` |
| `load_string` | JSON text | `load_string` | `loadString` | `load_string` | `load_string` | `LoadString` |
| `load_document` | an already-parsed native document | `load_document` | `loadDocument` | `load_document` | `load_document` | `LoadDocument` |

All three raise `ParseError` on malformed input, `SchemaValidationError` on a
schema violation, and `SubsystemRefError` on an unresolvable `{ref}`, and all
three run the SAME pipeline — top-level `{ref}` inlining, version gates, schema
validation, §9.7 template machinery, typed coercion, and nested subsystem-ref
resolution. `load_path` anchors relative refs at the file's own directory; the
other two take `base_path`.

Options ride on the entry points they apply to: `metaparameters` and
`base_path` on all three; TypeScript's `canonical` (tagged numeric literals,
decided during JSON DECODING) on `loadPath` and `loadString` only — a
`loadDocument` caller has already decoded and should run `losslessJsonParse`
itself.

Per-binding decorations, sanctioned under §2.2:

- **Rust** keeps its `*_with_options` twins — `load_string_with_options`,
  `load_document_with_options`, `load_path_with_options` — because it has no
  default arguments.
- **Julia** gives `load_string` an `::IO` method alongside `::AbstractString`;
  it reads the stream to a string and parses that. This is a method on the
  canonical entry point, not a fourth one — `JSON3.read` and `read` accept both
  shapes too.

**What it replaced — `load`, which meant two different things:**

| Binding | Old signature | A `String` argument was |
|---|---|---|
| Julia | `load(path::String; …)`, plus `::IO` and `::AbstractDict` methods | **a path** |
| Go | `Load(path string, opts ...LoadOption)`; `LoadString(json string, …)` | **a path** |
| TypeScript | `load(input: string \| object, options?: LoadOptions)` | **JSON text** |
| Rust | `load(json_str: &str)`; `load_path(path)`, `load_with_options` | **JSON text** |
| Python | `load(path_or_string: str \| Path \| dict, *, …)` | **either — it sniffed** |

> **⚠ This was the most dangerous divergence in the surface.** One name, one
> argument type, opposite meanings, and no type error anywhere to catch it. A
> user who ported `load(s)` from Julia to TypeScript got a parse error on a
> path string — or, if the path happened to be valid JSON, silence. Python's
> sniff was worse still: `os.path.exists(s)` decided, so the same program could
> change meaning when a file appeared or vanished.
>
> `load` is **deleted**, not deprecated, in all five. A deprecation shim would
> have to keep the sniff, which is the defect.

#### `to_json` / `write_path` — serialize and write a document

**Canonical, and landed.** `to_json(file, opts) -> string` is PURE and never
touches disk. `write_path(file, path)` writes and returns nothing (or the
binding's idiomatic empty/error result). **No function in this API both writes
and returns the payload.**

| Canonical | Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|---|
| `to_json` | `to_json` | `toJson` | `to_json` | `to_json` | `ToJSON` |
| `to_json_compact` | `to_json_compact` | `toJsonCompact` | `to_json_compact` | `to_json_compact` | `ToJSONCompact` |
| `write_path` | `write_path` | `writePath` | `write_path` | `write_path` | `WritePath` |

`to_json_compact` exists in all five rather than being an option, because Rust
and Go have no default arguments and so cannot express `to_json(file,
indent=0)`. Python (`to_json(file, *, indent=2)`) and TypeScript
(`toJson(file, {indent, canonical})`) also take the option, and their
`to_json_compact` wraps it. Julia takes no `indent`: `JSON3.write` ignores the
keyword, so `save(file, path)` has been emitting UNINDENTED bytes all along
despite passing `indent=2`, and an option that does nothing is worse than
none. Go additionally keeps `WritePathCompact` (extension tier), the rename of
its `SaveCompactToFile`.

The COMPACT form is byte-identical across bindings: Python pins
`separators=(",", ":")`, since `json.dumps(indent=None)` otherwise emits
`", "` / `": "` where serde_json, `encoding/json` and `JSON.stringify` emit
nothing.

Julia's `to_json` shares its name with the graph serializer (`to_json(::Graph)`,
graph.jl) and dispatches on argument type. Python's graph serializer is
re-exported as `to_json_graph`, matching the `toJsonGraph` / `to_json_graph`
that TypeScript and Rust already used.

**What it replaced:**

| Binding | Old signature | Wrote to disk? |
|---|---|---|
| TypeScript | `save(file: EsmFile, options?: SaveOptions): string` | no |
| Rust | `save(&EsmFile) -> Result<String, EsmError>`; `save_compact` | no |
| Julia | `save(file::EsmFile, path::String)`; `save(file::EsmFile, io::IO)` | **yes** |
| Python | `save(esm_file, path=None) -> str` | **optionally** |
| Go | `Serialize`; `SerializeCompact`; `SaveToFile`; `SaveCompactToFile` | split by name |

> **⚠ `save` was a side-effecting write in two bindings and a pure function in
> two others.** Go was the only binding whose *names* made the distinction —
> and the only binding whose names matched nobody else's.

#### `SCHEMA_VERSION` / `LIBRARY_VERSION` — the two version constants

**Canonical, and landed.** Two public **string** constants in every binding:

| Canonical | Meaning | Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|---|---|
| `schema_version` | the `.esm` FORMAT version | `SCHEMA_VERSION` | `SCHEMA_VERSION` | `SCHEMA_VERSION` | `SCHEMA_VERSION` | `SchemaVersion` |
| `library_version` | the package's OWN version | `LIBRARY_VERSION` | `LIBRARY_VERSION` | `LIBRARY_VERSION` | `LIBRARY_VERSION` | `LibraryVersion` |

Each is derived from that binding's existing source of truth, never a second
hand-kept copy: `SCHEMA_VERSION` comes from the bundled schema's `$id` in
TypeScript, Python and Go, and is a literal pinned to that `$id` by a test in
Julia and Rust. `LIBRARY_VERSION` comes from `CARGO_PKG_VERSION` (Rust),
`pkgversion` (Julia), `importlib.metadata` (Python), and package.json pinned by
a test (TypeScript). Go has no in-tree version manifest — a module's version is
its git tag — so `LibraryVersion` is a maintained constant with nothing to
derive from or pin against; that is documented at the constant.

**What it replaced:** `VERSION` meant the SCHEMA version in TypeScript and the
PACKAGE version in Rust — one name, two meanings. Julia exported only
`ESM_FORMAT_VERSION` (the schema version, under a name nobody else used).
Python kept the format version PRIVATE as `parse._CURRENT_VERSION`, and as a
`(major, minor, patch)` TUPLE rather than a string. Go exposed neither
publicly. `VERSION` is **deleted** in TypeScript and Rust.

### 5.2 Validation

#### `validate`

**Canonical.** `validate(file) -> ValidationResult`, where `ValidationResult`
carries `schema_errors`, `structural_errors`, `unit_warnings`, and `is_valid`.
Total: it reports, it does not raise.

**Today:** all five export it and none raises. Two divergences:

- **Input type.** Rust and Go accept only a typed `&EsmFile` / `*ESMFile`.
  TypeScript accepts JSON text or an object. Julia accepts an `EsmFile` **or a
  path**. Python accepts an `EsmFile`, JSON text, a dict, **or a path**.
- **Return shape.** Julia, TypeScript, Python and Rust return the four-field
  result. **Go's `Validate` returns the legacy `*DetailedValidationResult`
  (`Valid` + a flat `Messages` list).** Go's four-field equivalent is a
  *different function*, `ValidateFile(file, jsonStr) *ValidationResult`.
- Rust's `validate` performs **no schema validation at all** — its
  `schema_errors` is empty by construction.

#### `validate_schema`

`validate_schema(data) -> [SchemaError]` — Julia and TypeScript return one
structured `SchemaError{path, keyword, message}` per violation, matching AJV's
`allErrors`. Rust's `validate_schema(&Value) -> Result<(), EsmError>` collapses
every violation into one `"; "`-joined string. Python and Go do not export it.

#### `validate_structural`

`validate_structural(file) -> [StructuralError]`. Julia returns coded
`StructuralError{path, message, error_type}` records with 0-based JSON Pointer
paths. Go's `ValidateStructural` returns prose `ValidationMessage`s and excludes
unit checks; its coded twin is `ValidateStructuralWithCodes`.

> Note the kind: Julia's `SchemaError` and `StructuralError`, and TypeScript's
> and Python's `ValidationError`, are **diagnostic records, not throwables**.
> The manifest records them as `type`, and the Julia and Python surface tests
> assert they are not `Exception` subtypes.

### 5.3 Classification (esm-spec §6.3.1)

esm 1.0.0 declares two variable types and derives everything else, so these
functions are the only sanctioned way to ask what a variable *is*. All five
bindings export the family; all are total and return sorted names.

| Canonical | Contract |
|---|---|
| `ode_states(model) -> [str]` | unknowns with a time derivative |
| `observed_unknowns(model) -> [str]` | unknowns defined by an explicit equation |
| `algebraic_unknowns(model) -> [str]` | unknowns constrained implicitly |
| `is_ode_state(model, name) -> bool` | membership test |
| `brownian_parameters(model) -> [str]` | Wiener-driven parameters |
| `discrete_parameters(model) -> [str]` | event/schedule-updated parameters |
| `sampled_parameters(model) -> [str]` | distribution-drawn parameters |
| `constant_parameters(model) -> [str]` | never updated |
| `system_kind(model) -> SystemKind` | `ode` / `dae` / `sde` / `pde` / `nonlinear` |
| `observed_definitions(model) -> {str: Expr}` | observed name → defining expression |

Divergences:

- **`system_kind` arity.** Go alone takes a second argument,
  `SystemKind(model *Model, domain *Domain)`, documented as accepted only so
  callers need not change. Go also exports `EffectiveSystemKind` with no
  counterpart anywhere.
- **Return type.** TypeScript and Rust return a `SystemKind` enum; Julia,
  Python and Go return a bare string.
- **`observed_definitions`** has an extra `bare_only: bool = False` parameter in
  Python that exists nowhere else, and is not exported from Go at all (Go
  exports only the singular `ObservedDefinition(model, name)`).
- **Ordering.** Rust returns a sorted `BTreeMap`; Julia/Python/TypeScript return
  insertion-ordered maps. Rust's own `free_variables` returns an *unordered*
  `HashSet`, which is inconsistent within Rust.

### 5.4 Expressions

| Canonical | Contract | Fallible? |
|---|---|---|
| `free_variables(expr) -> {str}` | free variable names | no, anywhere |
| `simplify(expr) -> Expr` | algebraic simplification | no, anywhere |
| `substitute(expr, bindings) -> Expr` | capture-free substitution | no, anywhere |
| `parse_expression(text) -> Expr` | inverse of `to_ascii` | yes, `ExpressionParseError` |
| `parse_equation(text) -> Equation` | inverse of `to_ascii` on an equation | yes, `ExpressionParseError` |
| `canonicalize(expr) -> Expr` | RFC §5.4 canonical form | yes, `CanonicalizeError` |
| `canonical_json(expr) -> str` | canonical serialization | yes, `CanonicalizeError` |

Divergences:

- **`substitute` fallibility.** None — resolved. `substitute` is infallible in
  every binding. Substitution is SINGLE-PASS (CONFORMANCE_SPEC.md §2.2.3 rule
  1): a replacement is inserted verbatim and never re-substituted, so
  self- and mutually-referential binding sets terminate on their own and there
  is nothing to detect. Go's `(Expression, error)` signatures are retained for
  stability across its substitution family, but no error is returned.
- **`substitute` arity.** TypeScript alone takes a third
  `context?: SubstitutionContext`, and it changes semantics materially: with a
  context, a dotted reference not present in `bindings` is resolved through the
  file hierarchy and replaced with the referenced variable's **declared default
  value**. Go has this only behind an unexported function.
- **`canonical_json` return type.** Go returns `[]byte`; everyone else returns a
  string.
- **Canonicalization error point.** Go gates emissible fields on the *input*
  tree; TypeScript and Julia gate the *canonicalized* tree. Same error code,
  different detection point.
- **`parse_equation` return.** Go returns `*Equation`; everyone else a value.

### 5.5 Display

`to_ascii(target) -> str`, `to_unicode(target) -> str`, `to_latex(target) -> str`.

**Canonical.** All three accept the full render domain: `Expr`, `Equation`,
`Model`, `ReactionSystem`, `EsmFile`. Total.

**Today the accepted domain differs three ways:**

| Binding | `to_ascii` accepts | `to_unicode` / `to_latex` accept |
|---|---|---|
| TypeScript | `Expr`, `Equation`, `Model`, `ReactionSystem`, `Reaction`, `EsmFile` | same |
| Python | `Expr`, `Equation`, `Model`, `ReactionSystem`, `EsmFile` | same |
| Julia | all of the above | **`Expr`/`Equation` only — containers throw `ArgumentError`** |
| Rust | **`&Expr` only** | `&Expr` only |
| Go | **`Expression` only** | `Expression` only |

### 5.6 Flatten

**Canonical.** `flatten(file, *, base_path=".", load_ref=None) -> FlattenedSystem`.
Raises the §4.7.6.10 error taxonomy (`ConflictingDerivativeError`,
`DimensionPromotionError`, `UnmappedDomainError`, `UnsupportedMappingError`,
`DomainUnitMismatchError`, `DomainExtentMismatchError`,
`SliceOutOfDomainError`, `CyclicPromotionError`).

The options are reachable five different ways today: keywords (Julia),
positional (Python), an options object (TypeScript), and **a separate function**
in Rust (`flatten_with_options`) and Go (`FlattenWithOptions`). Julia and Rust
additionally overload on `Model` / `ReactionSystem` (`flatten_model` in Rust).

### 5.7 Load-time lowering

| Canonical | Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|---|
| `lower_enums` | mutates, returns file, raises **`ParseError`** | **pure**, returns new file, throws `EnumLoweringError` | mutates, returns file, raises `EnumLoweringError` | mutates a raw `&mut Value`, returns `Result<(), EnumLoweringError>` | mutates, returns `*LowerEnumsError` |
| `resolve_subsystem_refs` | `resolve_subsystem_refs!(file, base_path)`, raises `SubsystemRefError` | **`async`**, returns `Promise<void>`; the only binding that resolves remote `http(s)://` refs | mutates, returns `None` | takes a raw `&mut Value` + `&Path` | returns `error` |
| `resolve_template_machinery` | `(raw, base_path; metaparameters, load_ref)` | `(rawData, basePath, {metaparameters, readFile, validateSchema})` | `(raw, base_path, metaparameters)` — no loader seam | `(&Value, &Path, &BTreeMap)` — no loader seam | **not exported** |
| `expand_coupling_imports` | returns the coupling list | returns `CouplingEntry[] \| undefined` | returns the list | returns `Result<Option<Vec<_>>, _>` | **not exported** |

> **⚠ Three cross-cutting divergences here.** (a) **Rust takes untyped raw
> `serde_json::Value` documents** for `lower_enums`, `resolve_subsystem_refs`,
> `resolve_template_machinery` and `prepare`, where every other binding takes a
> typed `EsmFile`. (b) **TypeScript is the only non-mutating `lower_enums`**,
> and the only `async` `resolve_subsystem_refs`. (c) **Julia raises `ParseError`
> from `lower_enums`** where the other four raise a dedicated
> `EnumLoweringError`.

### 5.8 Simulation (Julia, Python, Rust)

**Canonical.**

```
prepare(input, *, parameters, const_arrays, providers, model_name,
        metaparameters, base_path, sample_time) -> PreparedModel
simulate(prepared_or_input, tspan, *, alg, parameters, initial_conditions,
         reltol, abstol, saveat) -> SimulationResult
observed_field(prepared, name) -> Array
```

`prepare` runs the deterministic-per-document pipeline once; `simulate` varies
only per-run knobs. Both raise `SimulateError`.

**Today:**

| Knob | Julia | Python | Rust |
|---|---|---|---|
| relative tolerance | `reltol` (`1e-10`) | **`rtol`** (`1e-10`) | `reltol` (**`1e-6`**) |
| absolute tolerance | `abstol` (`1e-14`) | **`atol`** (`1e-14`) | `abstol` (**`1e-8`**) |
| solver | `alg` (SciML algorithm, required) | **`method: str = "LSODA"`** | **`solver: SolverChoice`** |
| output times | `saveat` | **absent** | **`output_times: Option<Vec<f64>>`** |
| options passing | keywords | positional-or-keyword | `&SimulateOptions` struct |

> **⚠ Rust's default tolerances are four orders of magnitude looser than
> Julia's and Python's** (`1e-6`/`1e-8` against `1e-10`/`1e-14`). Python's
> docstring says its defaults were deliberately matched to Julia's; Rust's were
> never brought into that agreement. Two bindings solving the same document with
> default options do not produce comparable trajectories.

`observed_field` arity differs three ways: Julia takes
`(prep, insp::BuildInspection, name)` — the caller must have threaded the same
`BuildInspection` through `prepare` — Python takes `(prep, name)`, and Rust is a
method on `Prepared` taking only `name`. Rust also returns a borrowed array
only, where Python may return a float scalar.

### 5.9 Reference resolution

`build_reference_graph(model, model_name="") -> ReferenceGraph` and
`resolve_references(document) -> {str: ReferenceGraph}`, raising
`ReferenceResolutionError`. Julia, Python and Rust only — TypeScript and Go do
not implement the semiring-FAQ node addressing of RFC §6.1.

> **⚠ A behavioural, not cosmetic, split.** Python's `build_reference_graph`
> takes a third `index_sets` argument; Rust puts the same capability in a
> separate `build_reference_graph_with_index_sets`; **Julia has no way to pass a
> document-scoped registry at all** and reads the pre-0.8.0 model-nested
> `model["index_sets"]` instead. For a v0.8.0 document whose `index_sets` sits
> beside `models`, Julia and Python resolve differently. Rust also names the
> error `ReferenceError` where Julia and Python name it
> `ReferenceResolutionError`.

### 5.10 Reactions

`derive_odes(system) -> Model` and `stoichiometric_matrix(system) -> Matrix`
(rows = species, columns = reactions). Julia, TypeScript, Python and Rust; Go
exports neither.

Rust alone has an error channel (`DeriveError`). **TypeScript alone returns a
struct** from `stoichiometric_matrix` — `{matrix, species, reactions}` — so
TypeScript is the only binding where the row and column labels are recoverable.

---

## 6. The full stable surface

Generated from `api-surface.json` by `scripts/gen-api-surface.py`; **do not
hand-edit between the markers** — the generator rewrites the block, and
`scripts/extract-api-surface.py --check` fails when it is stale. `–` means the
binding does not export the symbol; check §3's capability profiles before
reading that as a gap.

<!-- BEGIN GENERATED: stable-surface -->

#### Exported by all five format bindings

| Canonical | Kind | Julia | TS | Python | Rust | Go |
|---|---|---|---|---|---|---|
| `algebraic_unknowns` | function | `algebraic_unknowns` | `algebraicUnknowns` | `algebraic_unknowns` | `algebraic_unknowns` | `AlgebraicUnknowns` |
| `brownian_parameters` | function | `brownian_parameters` | `brownianParameters` | `brownian_parameters` | `brownian_parameters` | `BrownianParameters` |
| `can_migrate` | function | `can_migrate` | `canMigrate` | `can_migrate` | `can_migrate` | `CanMigrate` |
| `component_node` | type | `ComponentNode` | `ComponentNode` | `ComponentNode` | `ComponentNode` | `ComponentNode` |
| `constant_parameters` | function | `constant_parameters` | `constantParameters` | `constant_parameters` | `constant_parameters` | `ConstantParameters` |
| `coupling_edge` | type | `CouplingEdge` | `CouplingEdge` | `CouplingEdge` | `CouplingEdge` | `CouplingEdge` |
| `dependency_edge` | type | `DependencyEdge` | `DependencyEdge` | `DependencyEdge` | `DependencyEdge` | `DependencyEdge` |
| `discrete_parameters` | function | `discrete_parameters` | `discreteParameters` | `discrete_parameters` | `discrete_parameters` | `DiscreteParameters` |
| `expression_parse_error` | error | `ExpressionParseError` | `ExpressionParseError` | `ExpressionParseError` | `ExpressionParseError` | `ExpressionParseError` |
| `flatten` | function | `flatten` | `flatten` | `flatten` | `flatten` | `Flatten` |
| `flatten_metadata` | type | `FlattenMetadata` | `FlattenMetadata` | `FlattenMetadata` | `FlattenMetadata` | `FlattenMetadata` |
| `flattened_system` | type | `FlattenedSystem` | `FlattenedSystem` | `FlattenedSystem` | `FlattenedSystem` | `FlattenedSystem` |
| `free_variables` | function | `free_variables` | `freeVariables` | `free_variables` | `free_variables` | `FreeVariables` |
| `is_ode_state` | function | `is_ode_state` | `isOdeState` | `is_ode_state` | `is_ode_state` | `IsODEState` |
| `library_version` | constant | `LIBRARY_VERSION` | `LIBRARY_VERSION` | `LIBRARY_VERSION` | `LIBRARY_VERSION` | `LibraryVersion` |
| `load_document` | function | `load_document` | `loadDocument` | `load_document` | `load_document` | `LoadDocument` |
| `load_path` | function | `load_path` | `loadPath` | `load_path` | `load_path` | `LoadPath` |
| `load_string` | function | `load_string` | `loadString` | `load_string` | `load_string` | `LoadString` |
| `migrate` | function | `migrate` | `migrate` | `migrate` | `migrate` | `Migrate` |
| `migration_error` | error | `MigrationError` | `MigrationError` | `MigrationError` | `MigrationError` | `MigrationError` |
| `observed_unknowns` | function | `observed_unknowns` | `observedUnknowns` | `observed_unknowns` | `observed_unknowns` | `ObservedUnknowns` |
| `ode_states` | function | `ode_states` | `odeStates` | `ode_states` | `ode_states` | `ODEStates` |
| `parse_equation` | function | `parse_equation` | `parseEquation` | `parse_equation` | `parse_equation` | `ParseEquation` |
| `parse_expression` | function | `parse_expression` | `parseExpression` | `parse_expression` | `parse_expression` | `ParseExpression` |
| `reject_template_imports_pre_v08` | function | `reject_template_imports_pre_v08` | `rejectTemplateImportsPreV08` | `reject_template_imports_pre_v08` | `reject_template_imports_pre_v08` | `RejectTemplateImportsPreV08` |
| `resolve_subsystem_refs` | function | `resolve_subsystem_refs!` | `resolveSubsystemRefs` | `resolve_subsystem_refs` | `resolve_subsystem_refs` | `ResolveSubsystemRefs` |
| `sampled_parameters` | function | `sampled_parameters` | `sampledParameters` | `sampled_parameters` | `sampled_parameters` | `SampledParameters` |
| `schema_version` | constant | `SCHEMA_VERSION` | `SCHEMA_VERSION` | `SCHEMA_VERSION` | `SCHEMA_VERSION` | `SchemaVersion` |
| `simplify` | function | `simplify` | `simplify` | `simplify` | `simplify` | `Simplify` |
| `substitute` | function | `substitute` | `substitute` | `substitute` | `substitute` | `Substitute` |
| `system_kind` | function | `system_kind` | `systemKind` | `system_kind` | `system_kind` | `SystemKind` |
| `to_ascii` | function | `to_ascii` | `toAscii` | `to_ascii` | `to_ascii` | `ToAscii` |
| `to_json` | function | `to_json` | `toJson` | `to_json` | `to_json` | `ToJSON` |
| `to_json_compact` | function | `to_json_compact` | `toJsonCompact` | `to_json_compact` | `to_json_compact` | `ToJSONCompact` |
| `to_latex` | function | `to_latex` | `toLatex` | `to_latex` | `to_latex` | `ToLatex` |
| `to_unicode` | function | `to_unicode` | `toUnicode` | `to_unicode` | `to_unicode` | `ToUnicode` |
| `validate` | function | `validate` | `validate` | `validate` | `validate` | `Validate` |
| `validation_result` | type | `ValidationResult` | `ValidationResult` | `ValidationResult` | `ValidationResult` | `ValidationResult` |
| `variable_node` | type | `VariableNode` | `VariableNode` | `VariableNode` | `VariableNode` | `VariableNode` |
| `write_path` | function | `write_path` | `writePath` | `write_path` | `write_path` | `WritePath` |

#### Exported by four of the five

| Canonical | Kind | Julia | TS | Python | Rust | Go |
|---|---|---|---|---|---|---|
| `add_coupling` | function | `add_coupling` | `addCoupling` | – | `add_coupling` | `AddCoupling` |
| `add_equation` | function | `add_equation` | `addEquation` | – | `add_equation` | `AddEquation` |
| `add_reaction` | function | `add_reaction` | `addReaction` | – | `add_reaction` | `AddReaction` |
| `add_species` | function | `add_species` | `addSpecies` | – | `add_species` | `AddSpecies` |
| `add_variable` | function | `add_variable` | `addVariable` | – | `add_variable` | `AddVariable` |
| `affect_equation` | type | `AffectEquation` | – | `AffectEquation` | `AffectEquation` | `AffectEquation` |
| `build_reference_graph` | function | `build_reference_graph` | – | `build_reference_graph` | `build_reference_graph` | `BuildReferenceGraph` |
| `canonical_json` | function | `canonical_json` | `canonicalJson` | – | `canonical_json` | `CanonicalJSON` |
| `canonicalize` | function | `canonicalize` | `canonicalize` | – | `canonicalize` | `Canonicalize` |
| `closed_function_error` | error | `ClosedFunctionError` | `ClosedFunctionError` | – | `ClosedFunctionError` | `ClosedFunctionError` |
| `component_graph` | function | `component_graph` | `componentGraph` / `component_graph` | `component_graph` | `component_graph` | – |
| `conflicting_derivative_error` | error | `ConflictingDerivativeError` | `ConflictingDerivativeError` | `ConflictingDerivativeError` | – | `ConflictingDerivativeError` |
| `contains` | function | – | `contains` | `contains` | `contains` | `Contains` |
| `continuous_event` | type | `ContinuousEvent` | – | `ContinuousEvent` | `ContinuousEvent` | `ContinuousEvent` |
| `coupling_entry` | type | `CouplingEntry` | – | `CouplingEntry` | `CouplingEntry` | `CouplingEntry` |
| `data_source` | type | `DataSource` | – | `DataSource` | `DataSource` | `DataSource` |
| `data_source_binding` | type | `DataSourceBinding` | – | `DataSourceBinding` | `DataSourceBinding` | `DataSourceBinding` |
| `data_source_determinism` | type | `DataSourceDeterminism` | – | `DataSourceDeterminism` | `DataSourceDeterminism` | `DataSourceDeterminism` |
| `data_source_location` | type | `DataSourceLocation` | – | `DataSourceLocation` | `DataSourceLocation` | `DataSourceLocation` |
| `data_source_temporal` | type | `DataSourceTemporal` | – | `DataSourceTemporal` | `DataSourceTemporal` | `DataSourceTemporal` |
| `derive_odes` | function | `derive_odes` | `deriveODEs` | `derive_odes` | `derive_odes` | – |
| `dimension_promotion_error` | error | `DimensionPromotionError` | `DimensionPromotionError` | `DimensionPromotionError` | – | `DimensionPromotionError` |
| `discrete_event` | type | `DiscreteEvent` | – | `DiscreteEvent` | `DiscreteEvent` | `DiscreteEvent` |
| `discrete_event_trigger` | type | `DiscreteEventTrigger` | – | `DiscreteEventTrigger` | `DiscreteEventTrigger` | `DiscreteEventTrigger` |
| `distribution` | type | `Distribution` | – | `Distribution` | `Distribution` | `Distribution` |
| `domain` | type | `Domain` | – | `Domain` | `Domain` | `Domain` |
| `equation` | type | `Equation` | – | `Equation` | `Equation` | `Equation` |
| `esm_file` | type | `EsmFile` | – | `EsmFile` | `EsmFile` | `ESMFile` |
| `expand_coupling_imports` | function | `expand_coupling_imports` | `expandCouplingImports` | `expand_coupling_imports` | `expand_coupling_imports` | – |
| `expression_graph` | function | `expression_graph` | `expressionGraph` | `expression_graph` | `expression_graph` | – |
| `expression_template_error` | error | `ExpressionTemplateError` | `ExpressionTemplateError` | `ExpressionTemplateError` | – | `ExpressionTemplateError` |
| `functional_update` | type | `FunctionalUpdate` | – | `FunctionalUpdate` | `FunctionalUpdate` | `FunctionalUpdate` |
| `lower_enums` | function | `lower_enums!` | `lowerEnums` | – | `lower_enums` | `LowerEnums` |
| `lower_expression_templates` | function | `lower_expression_templates` | `lowerExpressionTemplates` | `lower_expression_templates` | – | `LowerExpressionTemplates` |
| `metadata` | type | `Metadata` | – | `Metadata` | `Metadata` | `Metadata` |
| `model` | type | `Model` | – | `Model` | `Model` | `Model` |
| `model_variable` | type | `ModelVariable` | – | `ModelVariable` | `ModelVariable` | `ModelVariable` |
| `observed_definitions` | function | `observed_definitions` | `observedDefinitions` | `observed_definitions` | `observed_definitions` | – |
| `parameter_update` | type | `ParameterUpdate` | – | `ParameterUpdate` | `ParameterUpdate` | `ParameterUpdate` |
| `reaction` | type | `Reaction` | – | `Reaction` | `Reaction` | `Reaction` |
| `reaction_system` | type | `ReactionSystem` | – | `ReactionSystem` | `ReactionSystem` | `ReactionSystem` |
| `reference_edge` | type | `ReferenceEdge` | – | `ReferenceEdge` | `ReferenceEdge` | `ReferenceEdge` |
| `reference_graph` | type | `ReferenceGraph` | – | `ReferenceGraph` | `ReferenceGraph` | `ReferenceGraph` |
| `reference_vertex` | type | `ReferenceVertex` | – | `ReferenceVertex` | `ReferenceVertex` | `ReferenceVertex` |
| `reject_expression_templates_pre_v04` | function | `reject_expression_templates_pre_v04` | `rejectExpressionTemplatesPreV04` | `reject_expression_templates_pre_v04` | – | `RejectExpressionTemplatesPreV04` |
| `remove_coupling` | function | `remove_coupling` | `removeCoupling` | – | `remove_coupling` | `RemoveCoupling` |
| `remove_reaction` | function | `remove_reaction` | `removeReaction` | – | `remove_reaction` | `RemoveReaction` |
| `remove_species` | function | `remove_species` | `removeSpecies` | – | `remove_species` | `RemoveSpecies` |
| `remove_variable` | function | `remove_variable` | `removeVariable` | – | `remove_variable` | `RemoveVariable` |
| `resolve_references` | function | `resolve_references` | – | `resolve_references` | `resolve_references` | `ResolveReferences` |
| `resolve_template_machinery` | function | `resolve_template_machinery` | `resolveTemplateMachinery` | `resolve_template_machinery` | `resolve_template_machinery` | – |
| `species` | type | `Species` | – | `Species` | `Species` | `Species` |
| `stoichiometric_matrix` | function | `stoichiometric_matrix` | `stoichiometricMatrix` | `stoichiometric_matrix` | `stoichiometric_matrix` | – |
| `substitute_in_model` | function | – | `substituteInModel` | `substitute_in_model` | `substitute_in_model` | `SubstituteInModel` |
| `substitute_in_reaction_system` | function | – | `substituteInReactionSystem` | `substitute_in_reaction_system` | `substitute_in_reaction_system` | `SubstituteInReactionSystem` |
| `unit_warning` | type | `UnitWarning` | `UnitWarning` | – | `UnitWarning` | `UnitWarning` |

#### Exported by three of the five

| Canonical | Kind | Julia | TS | Python | Rust | Go |
|---|---|---|---|---|---|---|
| `add_continuous_event` | function | `add_continuous_event` | `addContinuousEvent` | – | – | `AddContinuousEvent` |
| `add_discrete_event` | function | `add_discrete_event` | `addDiscreteEvent` | – | – | `AddDiscreteEvent` |
| `cadence_error` | error | – | – | `CadenceError` | `CadenceError` | `CadenceError` |
| `canonicalize_error` | error | `CanonicalizeError` | `CanonicalizeError` | – | `CanonicalizeError` | – |
| `closed_function_names` | function | `closed_function_names` | – | – | `closed_function_names` | `ClosedFunctionNames` |
| `component_exists` | function | – | `componentExists` | `component_exists` | `component_exists` | – |
| `component_graph` | type | – | `ComponentGraph` | – | `ComponentGraph` | `ComponentGraph` |
| `compose` | function | `compose` | `compose` | – | – | `Compose` |
| `convert_units` | function | – | `convertUnits` | `convert_units` | `convert_units` | – |
| `coupling_import` | type | `CouplingImport` | – | `CouplingImport` | – | `CouplingImport` |
| `coupling_import_options` | type | – | `CouplingImportOptions` | – | `CouplingImportOptions` | `CouplingImportOptions` |
| `domain_unit_mismatch_error` | error | `DomainUnitMismatchError` | `DomainUnitMismatchError` | `DomainUnitMismatchError` | – | – |
| `edge_kind` | type | – | – | `EdgeKind` | `EdgeKind` | `EdgeKind` |
| `edit_error` | error | `EditError` | – | – | `EditError` | `EditError` |
| `evaluate` | function | – | – | `evaluate` | `evaluate` | `Evaluate` |
| `evaluate_closed_function` | function | `evaluate_closed_function` | – | – | `evaluate_closed_function` | `EvaluateClosedFunction` |
| `extract` | function | `extract` | `extract` | – | – | `Extract` |
| `flatten_error` | error | – | `FlattenError` | `FlattenError` | `FlattenError` | – |
| `flattened_equation` | type | – | `FlattenedEquation` | `FlattenedEquation` | – | `FlattenedEquation` |
| `flattened_variable` | type | – | `FlattenedVariable` | `FlattenedVariable` | – | `FlattenedVariable` |
| `format_canonical_float` | function | `format_canonical_float` | `formatCanonicalFloat` | – | `format_canonical_float` | – |
| `free_parameters` | function | – | `freeParameters` | `free_parameters` | `free_parameters` | – |
| `function_table` | type | `FunctionTable` | – | `FunctionTable` | – | `FunctionTable` |
| `function_table_axis` | type | `FunctionTableAxis` | – | `FunctionTableAxis` | – | `FunctionTableAxis` |
| `graph` | type | `Graph` | `Graph` | `Graph` | – | – |
| `is_coupling_library_doc` | function | – | `isCouplingLibraryDoc` | `is_coupling_library_doc` | `is_coupling_library_doc` | – |
| `loader_field` | type | – | `LoaderField` | `LoaderField` | – | `LoaderField` |
| `map_variable` | function | `map_variable` | `mapVariable` | – | – | `MapVariable` |
| `max_template_expansion_depth` | constant | – | `MAX_TEMPLATE_EXPANSION_DEPTH` | `MAX_TEMPLATE_EXPANSION_DEPTH` | – | `MaxTemplateExpansionDepth` |
| `parameter` | type | `Parameter` | – | `Parameter` | – | `Parameter` |
| `parse_unit` | function | – | `parseUnit` | – | `parse_unit` | `ParseUnit` |
| `prepare` | function | `prepare` | – | `prepare` | `prepare` | – |
| `reference` | type | `Reference` | – | `Reference` | – | `Reference` |
| `reference_resolution_error` | error | `ReferenceResolutionError` | – | `ReferenceResolutionError` | – | `ReferenceResolutionError` |
| `remove_equation` | function | `remove_equation` | `removeEquation` | – | `remove_equation` | – |
| `remove_event` | function | `remove_event` | `removeEvent` | – | – | `RemoveEvent` |
| `rename_variable` | function | `rename_variable` | `renameVariable` | – | – | `RenameVariable` |
| `schema_validation_error` | error | `SchemaValidationError` | `SchemaValidationError` | `SchemaValidationError` | – | – |
| `simulate` | function | `simulate` | – | `simulate` | `simulate` | – |
| `substitute_in_equations` | function | `substitute_in_equations` | `substituteInEquations` | – | – | `SubstituteInEquations` |
| `supported_migration_targets` | function | `supported_migration_targets` | – | `supported_migration_targets` | – | `SupportedMigrationTargets` |
| `to_dot` | function | `to_dot` | `toDot` | `to_dot` | – | – |
| `to_mermaid` | function | `to_mermaid` | `toMermaid` | `to_mermaid` | – | – |
| `unit_conversion_error` | error | `UnitConversionError` | `UnitConversionError` | `UnitConversionError` | – | – |
| `validate_equation_dimensions` | function | `validate_equation_dimensions` | – | – | `validate_equation_dimensions` | `ValidateEquationDimensions` |
| `vertex_kind` | type | – | – | `VertexKind` | `VertexKind` | `VertexKind` |

#### Exported by two of the five

| Canonical | Kind | Julia | TS | Python | Rust | Go |
|---|---|---|---|---|---|---|
| `apply_dae_contract` | function | – | – | – | `apply_dae_contract` | `ApplyDAEContract` |
| `apply_scope_injections` | function | – | `applyScopeInjections` | – | `apply_scope_injections` | – |
| `apply_unit_conversion` | function | `apply_unit_conversion` / `apply_unit_conversion!` | – | `apply_unit_conversion` | – | – |
| `area_tolerance_ok` | function | – | – | `area_tolerance_ok` | `area_tolerance_ok` | – |
| `build_unit_env` | function | – | – | – | `build_unit_env` | `BuildUnitEnv` |
| `cadence` | type | – | – | – | `Cadence` | `Cadence` |
| `canonical_index_set_json` | function | – | – | `canonical_index_set_json` | `canonical_index_set_json` | – |
| `circular_reference_error` | error | – | `CircularReferenceError` | `CircularReferenceError` | – | – |
| `coupling_couple` | type | `CouplingCouple` | – | – | – | `CouplingCouple` |
| `coupling_role` | type | – | – | – | `CouplingRole` | `CouplingRole` |
| `cyclic_promotion_error` | error | `CyclicPromotionError` | – | `CyclicPromotionError` | – | – |
| `dae_info` | type | – | – | – | `DaeInfo` | `DAEInfo` |
| `data_source_kind` | type | – | – | `DataSourceKind` | `DataSourceKind` | – |
| `declared_system_kind` | function | – | `declaredSystemKind` | `declared_system_kind` | – | – |
| `derive_output_gridding` | function | `derive_output_gridding` | – | – | `derive_output_gridding` | – |
| `derive_output_meta` | function | `derive_output_meta` | – | – | `derive_output_meta` | – |
| `derive_output_plan` | function | `derive_output_plan` | – | – | `derive_output_plan` | – |
| `desugar_pushdown` | function | – | – | `desugar_pushdown` | `desugar_pushdown` | – |
| `dimension` | type | – | – | – | `Dimension` | `Dimension` |
| `distinct` | function | – | – | `distinct` | `distinct` | – |
| `domain_extent_mismatch_error` | error | `DomainExtentMismatchError` | – | `DomainExtentMismatchError` | – | – |
| `earth_sci_ast_error` | error | `EarthSciASTError` | – | `EarthSciAstError` | – | – |
| `emit_document` | function | – | `emitDocument` | `emit_document` | – | – |
| `emit_esm_string` | function | – | `emitEsmString` | `emit_esm_string` | – | – |
| `entity_not_found_error` | error | – | `EntityNotFoundError` | – | – | `EntityNotFoundError` |
| `enum_lowering_error` | error | – | `EnumLoweringError` | – | `EnumLoweringError` | – |
| `ephemeral_injected_file` | function | – | `ephemeralInjectedFile` | – | `ephemeral_injected_file` | – |
| `error_codes` | constant | `ERROR_CODES` | `ERROR_CODES` | – | – | – |
| `evaluate_cellwise` | function | `evaluate_cellwise` | – | – | `evaluate_cellwise` | – |
| `expand` | function | – | – | `Expand` | – | `Expand` |
| `expand_document` | function | – | `expandDocument` | `expand_document` | – | – |
| `expr` | type | – | – | `Expr` | `Expr` | – |
| `expr_node` | type | – | – | `ExprNode` | – | `ExprNode` |
| `expression_graph` | type | – | – | – | `ExpressionGraph` | `ExpressionGraph` |
| `expression_graph_options` | type | – | – | – | `ExpressionGraphOptions` | `ExpressionGraphOptions` |
| `field_reduce` | function | `field_reduce` | – | – | `field_reduce` | – |
| `flatten_template_registries` | function | – | `flattenTemplateRegistries` | `flatten_template_registries` | – | – |
| `flatten_with_options` | function | – | – | – | `flatten_with_options` | `FlattenWithOptions` |
| `float_key_error` | error | – | – | `FloatKeyError` | `FloatKeyError` | – |
| `geometry_error` | error | – | – | `GeometryError` | `GeometryError` | – |
| `get_component_type` | function | – | `getComponentType` | – | `get_component_type` | – |
| `get_supported_migration_targets` | function | – | `getSupportedMigrationTargets` | – | `get_supported_migration_targets` | – |
| `graph_edge` | type | – | – | `GraphEdge` | – | `GraphEdge` |
| `grid_plan` | type | `GridPlan` | – | – | `GridPlan` | – |
| `group_aggregate` | function | – | – | `group_aggregate` | `group_aggregate` | – |
| `group_gridding_by_grid` | function | `group_gridding_by_grid` | – | – | `group_gridding_by_grid` | – |
| `intersect_polygon` | function | – | – | `intersect_polygon` | `intersect_polygon` | – |
| `is_template_library_doc` | function | – | `isTemplateLibraryDoc` | – | `is_template_library_doc` | – |
| `load_options` | type | – | `LoadOptions` | – | `LoadOptions` | – |
| `lower_reactions_to_equations` | function | `lower_reactions_to_equations` | – | – | `lower_reactions_to_equations` | – |
| `materialize_value_invention` | function | – | – | `materialize_value_invention` | `materialize_value_invention` | – |
| `merge` | function | – | `merge` | – | – | `Merge` |
| `observed_definition` | function | `observed_definition` | – | – | – | `ObservedDefinition` |
| `observed_field` | function | `observed_field` | – | `observed_field` | – | – |
| `operator` | type | – | – | `Operator` | `Operator` | – |
| `output_error` | error | `OutputError` | – | – | `OutputError` | – |
| `output_meta` | type | `OutputMeta` | – | – | `OutputMeta` | – |
| `output_plan` | type | `OutputPlan` | – | – | `OutputPlan` | – |
| `parse_error` | error | `ParseError` | `ParseError` | – | – | – |
| `parse_unit_conversion` | function | `parse_unit_conversion` | – | `parse_unit_conversion` | – | – |
| `partition` | type | – | – | `Partition` | `Partition` | – |
| `pde_assertion_result` | type | `PdeAssertionResult` | – | – | `PdeAssertionResult` | – |
| `plan_dimension_coordinates` | function | `plan_dimension_coordinates` | – | – | `plan_dimension_coordinates` | – |
| `polygon_area` | function | – | – | `polygon_area` | `polygon_area` | – |
| `prepared_model` | type | `PreparedModel` | – | `PreparedModel` | – | – |
| `product_matrix` | function | – | `productMatrix` | `product_matrix` | – | – |
| `rank` | function | – | – | `rank` | `rank` | – |
| `ranking` | type | – | – | `Ranking` | `Ranking` | – |
| `run_pde_tests` | function | `run_pde_tests` | – | – | `run_pde_tests` | – |
| `schema_error` | error | – | – | – | `SchemaError` | `SchemaError` |
| `schema_error` | type | `SchemaError` | `SchemaError` | – | – | – |
| `simulate_error` | error | `SimulateError` | – | – | `SimulateError` | – |
| `simulation_result` | type | `SimulationResult` | – | `SimulationResult` | – | – |
| `skolem` | function | – | – | `skolem` | `skolem` | – |
| `skolem_edge` | function | – | – | `skolem_edge` | `skolem_edge` | – |
| `slice_out_of_domain_error` | error | `SliceOutOfDomainError` | – | `SliceOutOfDomainError` | – | – |
| `structural_error` | error | – | – | – | `StructuralError` | `StructuralError` |
| `substrate_matrix` | function | – | `substrateMatrix` | `substrate_matrix` | – | – |
| `subsystem_ref_error` | error | `SubsystemRefError` | – | `SubsystemRefError` | – | – |
| `system_kind` | type | – | `SystemKind` | – | `SystemKind` | – |
| `temporal_domain` | type | – | – | `TemporalDomain` | – | `TemporalDomain` |
| `time_span` | type | – | – | – | `TimeSpan` | `TimeSpan` |
| `to_json_graph` | function | – | `toJsonGraph` | `to_json_graph` | – | – |
| `to_julia_code` | function | `to_julia_code` | – | `to_julia_code` | – | – |
| `tolerance` | type | – | – | – | `Tolerance` | `Tolerance` |
| `unit` | type | – | – | – | `Unit` | `Unit` |
| `unit_finding` | type | `UnitFinding` | – | – | `UnitFinding` | – |
| `unit_finding_analysis` | constant | – | – | – | `UNIT_FINDING_ANALYSIS` | `UnitFindingAnalysis` |
| `unit_finding_dimensional_mismatch` | constant | – | – | – | `UNIT_FINDING_DIMENSIONAL_MISMATCH` | `UnitFindingDimensionalMismatch` |
| `unit_finding_unparseable` | constant | – | – | – | `UNIT_FINDING_UNPARSEABLE` | `UnitFindingUnparseable` |
| `unknowns` | function | – | `unknowns` | `unknowns` | – | – |
| `unmapped_domain_error` | error | `UnmappedDomainError` | – | `UnmappedDomainError` | – | – |
| `unsupported_mapping_error` | error | `UnsupportedMappingError` | – | `UnsupportedMappingError` | – | – |
| `validate_schema` | function | `validate_schema` | `validateSchema` | – | – | – |
| `validate_structural` | function | `validate_structural` | – | – | – | `ValidateStructural` |
| `validate_units` | function | – | `validateUnits` | `validate_units` | – | – |
| `validation_error` | type | – | `ValidationError` | `ValidationError` | – | – |
| `value_invention_error` | error | – | – | `ValueInventionError` | `ValueInventionError` | – |
| `value_invention_result` | type | – | – | `ValueInventionResult` | `ValueInventionResult` | – |
| `var_gridding` | type | `VarGridding` | – | – | `VarGridding` | – |
| `var_plan` | type | `VarPlan` | – | – | `VarPlan` | – |
| `variable_in_use_error` | error | – | `VariableInUseError` | – | – | `VariableInUseError` |
| `variable_kind` | type | – | `VariableKind` | – | `VariableKind` | – |

#### Editor package

| Canonical | Kind | TS | Editor |
|---|---|---|---|
| `coupling_graph` | type | – | `CouplingGraph` |
| `create_ast_store` | function | – | `createAstStore` |
| `equation_editor` | type | – | `EquationEditor` |
| `expression` | type | – | `Expression` |
| `expression_node` | type | – | `ExpressionNode` |
| `file_summary` | type | – | `FileSummary` |
| `model_editor` | type | – | `ModelEditor` |
| `reaction_editor` | type | – | `ReactionEditor` |
| `register_web_components` | function | – | `registerWebComponents` |
| `validation_panel` | type | – | `ValidationPanel` |

<!-- END GENERATED: stable-surface -->

---

## 7. Extension seams

641 symbols. They are enumerated in `api-surface.json` with
`"tier": "extension"`; this section says what the families are and why each is
allowed to differ.

| Family | Bindings | Why it is a seam |
|---|---|---|
| Julia build/inspection | Julia | `build_evaluator` and `BuildInspection` expose the tree-walk evaluator's internals so downstream analysers (EarthSciASTDiff) can differentiate the expanded tree. There is no cross-language analogue to harmonize against. |
| Julia forcing buffers | Julia | The out-of-place RHS argument ABI. Its shape is dictated by the compiled program's argument arrays and will change with the emitter. |
| Julia MTK/Catalyst export | Julia | `mtk2esm`, `mtk2esm_gaps`, `GapReport` — migration tooling for one host ecosystem. |
| Rust `intern` / `performance` | Rust | Hash-consing and allocator knobs. Feature-gated (`parallel`, `custom_alloc`) and performance-shaped, not semantics-shaped. |
| Rust `simulate_array` | Rust | The native-only spatial/PDE backend. Its surface tracks the backend, not the format. |
| Runtime I/O | Julia, Python, Rust | Providers, refresh callbacks, sinks, checkpoints. The concrete implementations live in EarthSciIO; these are the protocol the host binds to. |
| Go graph exporters | Go | `DOTExporter` / `JSONExporter` / `MermaidExporter` and their `New*` constructors are a Go-idiomatic object surface with no counterpart elsewhere (§8 replaces the free functions, not the exporters). |
| Go diagnostic codes | Go | The ~84 `Code*` / `Error*` / `Role*` / `SystemKind*` constants. Their *values* are conformance-pinned by the shared fixture corpus; their Go *identifiers* are not. |
| TypeScript analysis | TypeScript | The complexity/CSE/differentiation toolkit under `src/analysis/`. A TypeScript-only authoring aid. |
| Editor internals | Editor | Everything beyond the allowlisted components: primitives, path utilities, highlight/validation contexts. |

Go carries the largest extension surface (177 of its 275 symbols) — a direct
consequence of §8's Go-side renames not having happened yet, plus the
diagnostic-code constants.

---

## 8. Planned reconciliations

**Nothing in this section is asserted by any test.** These are the intended
changes, recorded so the manifest can stay bootstrapped and green. Each is also
in `api-surface.json` under `planned`. Renames land with the old name kept as a
deprecated alias for one minor, then removed at the next major (§10).

| # | Canonical | Problem | Resolution | Affects |
|---|---|---|---|---|
| 1 | `load` | Julia and Go took a **file path**; TypeScript and Rust took **JSON text**; Python sniffed. Same name, same argument type, opposite meanings. | **DONE.** Split into `load_path` / `load_string` / `load_document`; `load` deleted (a deprecation shim would have to keep the sniff). See §5.1. | all five |
| 2 | `save` | Pure serialization in TypeScript and Rust, a disk write in Julia, both in Python. Go alone distinguished them by name, using nobody else's names. | **DONE.** `to_json(file, opts) -> string` pure everywhere; `write_path(file, path)` writes and returns nothing; `to_json_compact` in all five. See §5.1. | all five |
| 2b | `VERSION` | Meant the SCHEMA version in TypeScript and the PACKAGE version in Rust. Julia exported only `ESM_FORMAT_VERSION`; Python kept the format version private as a tuple; Go exposed neither. | **DONE.** `SCHEMA_VERSION` and `LIBRARY_VERSION`, both public strings, in all five; `VERSION` deleted. See §5.1. | all five |
| 3 | `abstol` / `reltol` / `saveat` / `alg` | Python uses scipy's `rtol`/`atol`/`method`; Rust's `SimulateOptions` uses `solver`/`output_times`. Rust's default tolerances are 4 orders looser than the other two. | SciML spelling everywhere (§4). Python gains `reltol`/`abstol`/`alg`; Rust renames `solver`→`alg`, `output_times`→`saveat`; Rust's defaults align to `1e-10`/`1e-14`. | Python, Rust |
| 4 | `closed_function_names` | A function in Julia, Rust and Go; a **constant array** `CLOSED_FUNCTION_NAMES` in TypeScript. | TypeScript adds `closedFunctionNames()`; the constant becomes a deprecated alias. | TypeScript |
| 5 | `derive_odes` | TypeScript spells it `deriveODEs`, violating §2 — and is internally inconsistent, since it already spells the siblings `odeStates` and `isOdeState`. | Rename to `deriveOdes`. | TypeScript |
| 6 | `unknowns` / `parameters` | TypeScript and Python export `unknowns`/`parameters`; Julia exports `unknown_names`/`parameter_names` for the same query. | Canonical is `unknowns`/`parameters`. Julia keeps its `*_names` spellings as aliases — the bare names collide badly in Julia's flat namespace. | Julia |
| 7 | edit operations | Python suffixes every edit with its container: `add_variable_to_model`, `remove_coupling_from_file`, `extract_component_from_file`, `merge_esm_files`. Julia, TypeScript and Rust use the bare verb. | Python gains the bare names; the suffixed ones become aliases. | Python |
| 8 | `to_dot` / `to_mermaid` / `to_json` | Julia and TypeScript export three rendering functions (TypeScript spells the third `toJsonGraph`); Go spells the same renderings as **six** functions, `ExportComponentGraphDOT` … `ExportExpressionGraphMermaid`. | Canonical `to_dot(graph)` / `to_mermaid(graph)` / `to_json(graph)` dispatching on graph kind. Go's `Export*` family becomes `ToDOT`/`ToMermaid`/`ToJSON`. | TypeScript, Go |
| 9 | `substitute_with_context` | Rust names the scoped-substitution family `*_with_context` (`ScopedContext`); Go names it `*WithScoped`. | Canonical `substitute_with_context`; Go renames. | Go |
| 10 | `reference_resolution_error` | Julia and Python raise `ReferenceResolutionError`; Rust's is `ReferenceError`. | Rust renames, keeping a type alias for one minor. | Rust |
| 11 | `system_kind` family | `system_kind` is a function everywhere but takes an extra `domain` in Go; `declared_system_kind` exists in TypeScript and Python; `declared_system_kind_mismatch` only in Julia; `EffectiveSystemKind` only in Go. Three overlapping two-binding subsets. | Drop Go's vestigial `domain` argument. Decide whether `EffectiveSystemKind` is `declared_system_kind`'s peer or a Go convenience, then harmonize the trio. | Julia, TS, Python, Go |
| 12 | `validate` return shape | Go's `Validate` returns the legacy `DetailedValidationResult`; the four-field shape everyone else returns is Go's *other* function, `ValidateFile`. | Go's `Validate` returns the four-field `ValidationResult`; `ValidateFile` folds into it. | Go |
| 13 | `validate` input type | Rust and Go accept only a typed document; Julia also accepts a path; Python accepts path/text/dict/document; TypeScript accepts text/object. | `validate(file)` takes a typed document everywhere. Path and text convenience become `validate_path` / `validate_text`. | all five |
| 14 | raw-`Value` entry points | Rust takes untyped `serde_json::Value` for `lower_enums`, `resolve_subsystem_refs`, `resolve_template_machinery` and `prepare`, where every other binding takes a typed document. | Add typed wrappers at the canonical names; keep the raw forms as `*_raw` extension seams. | Rust |
| 15 | `lower_enums` mutation | TypeScript is pure; Julia, Python, Rust and Go mutate in place. Julia raises `ParseError` where the rest raise `EnumLoweringError`. | Canonicalize on the pure form; mutating variants take Julia's `!`. Julia raises `EnumLoweringError`. | Julia, Python, Rust, Go |
| 16 | `substitute` cycles | ~~Only Go detects substitution cycles; the other four loop.~~ **RESOLVED — the premise was false, and inverted.** The other four never looped: all four are single-pass, so a cyclic binding set terminates on its own, exactly as CONFORMANCE_SPEC.md §2.2.3 rule 1 requires. Go was the sole non-conformant binding: it expanded replacements *transitively*, which (a) silently corrupted chained renames — `substitute("a", {a: b, b: c})` returned `"c"`, not `"b"`, mis-applying every overlapping rename through `renameRawExpr` — and (b) made cyclic sets non-terminating, which was then patched with cycle detection instead of by removing the transitivity. | Go made single-pass; `SubstitutionError` / `cyclic_substitution` removed as unnecessary. Pinned cross-binding by `tests/substitution/cyclic_bindings.json`. | Go (done) |
| 17 | `build_reference_graph` index sets | Python threads `index_sets` as a third argument, Rust via a separate function, **Julia not at all** — it reads the pre-0.8.0 nested shape. Julia and Python resolve v0.8.0 documents differently. | One signature carrying the document-scoped registry. Also a bug fix. | Julia, Rust |
| 18 | display domain | `to_unicode` / `to_latex` accept containers in TypeScript and Python, throw on them in Julia, and accept expressions only in Rust and Go. | All three renderers accept the full domain in every binding. | Julia, Rust, Go |
| 19 | Go initialisms | Go has both `OpIC` and `ErrorIcInReactionSystem`; also `ToAscii` and `FmtAscii` against §2.1's `ASCII`. | `ErrorICInReactionSystem`, `ToASCII`, `FmtASCII`. | Go |
| 20 | `component_graph` alias | TypeScript exports **both** `component_graph` (snake_case, violating §2) and `componentGraph`. | Drop `component_graph`. | TypeScript |

---

## 9. How the surface is enforced

Six tests, one per binding, each asserting in **both** directions that the
binding's declared surface equals `api-surface.json`:

| Binding | Test | Reads |
|---|---|---|
| Julia | `pkg/EarthSciAST.jl/test/api_surface_test.jl` | `names(EarthSciAST)` |
| TypeScript | `pkg/earthsci-ast-ts/src/api-surface.test.ts` | the `index.ts` re-export list |
| Python | `pkg/earthsci-ast-py/tests/test_api_surface.py` | `earthsci_ast.__all__` |
| Rust | `pkg/earthsci-ast-rs/tests/api_surface.rs` | the crate root's `pub use` / `pub const` |
| Go | `pkg/earthsci-ast-go/pkg/esm/api_surface_test.go` | a `go/ast` walk of package `esm` |
| Editor | `pkg/earthsci-ast-editor/src/api-surface.test.ts` | the `index.ts` re-export list |

Each also checks kinds — a manifest `error` must be a throwable, a manifest
`type` must not be a function — and each guards against passing vacuously if its
parser matches nothing.

A cross-cutting check runs all six extractions at once:

```bash
python3 scripts/extract-api-surface.py --check
```

### Notes on the mechanisms

- **TypeScript** parses `index.ts` rather than importing it, because roughly a
  fifth of the surface is `export type` and erased at runtime — a runtime
  `import * as api` would silently miss all of it. The wildcard
  `export * from './types.js'` cannot be enumerated without resolving the
  barrel, and its members are schema-derived and churn with `esm-schema.json`,
  so the manifest pins the **barrel list** instead: adding or removing a
  wildcard re-export is still a surface change that must be declared.
- **Rust** would ideally use `cargo public-api`. It is not installed here
  (`cargo public-api --version` → `no such command`) and requires a nightly
  toolchain, since it drives `rustdoc`'s unstable JSON output. The test is the
  vendored equivalent: it parses the crate root — the only source of
  `earthsci_ast::<name>` paths — and additionally proves **at compile time**
  that a representative sample of the manifest's names really resolve, which
  catches a `pub use` naming something that no longer exists behind a `cfg`.
  If `cargo public-api` becomes available, replace the textual half; keep the
  compile-time half.
- **Go** covers package-level `func` / `type` / `const` / `var`. Methods on an
  exported type are covered by that type's entry rather than listed separately:
  the manifest records the symbols a caller can name as `esm.X`, and a method is
  reachable only through its receiver.
- **Julia** reads `names(EarthSciAST)` rather than parsing the `export` block,
  so what is asserted is what a caller can actually reach after
  `using EarthSciAST`.

### Changing the surface

1. Make the change.
2. `python3 scripts/gen-api-surface.py`
3. Review the diff to `api-surface.json`. A new symbol lands in `extension`
   unless two bindings export it.
4. Record the tier decision in this document. A new `stable` symbol needs a row
   in §6; a `stable` symbol that is being *removed* needs a major version.

---

## 10. Change policy

| Tier | Add | Rename | Remove | Change kind |
|---|---|---|---|---|
| stable | minor | major (alias for ≥1 minor first) | major | major |
| extension | minor | minor (alias encouraged) | minor | minor |
| private | any time | any time | any time | any time |

A **deprecation alias** keeps the old name exported and in the manifest, in the
same tier, for at least one minor release. The alias is a manifest entry with
multiple spellings for that binding — the shape `apply_unit_conversion` and
`component_graph` already use — so the surface tests keep asserting both.

Promoting `extension` → `stable` is a minor. Demoting `stable` → `extension` is
a major, because it removes a compatibility promise.

Argument-level changes are governed the same way: adding an optional keyword is
a minor, renaming or reordering an argument of a `stable` function is a major.
The §8 SciML renames are therefore major-or-aliased, not silent.

---

## 11. What phase 1 did not settle

- **Argument contracts below §5.** §5 pins the ~60 operations that carry the
  format. The remaining `stable` symbols are pinned by name, kind, and tier
  only; harmonizing their argument lists is phase 2.
- **Error taxonomy.** The eight flatten errors are already cross-language, but
  the rest of the error surface is not: `EsmError` (Rust), `EarthSciAstError`
  (Python), `DiagnosticError` (Go) and `EsmMachineryError` (TypeScript) are four
  different root types with no stated relationship.
- **Return-container ordering.** Rust returns sorted `BTreeMap`s in some places
  and unordered `HashSet`s in others. Ordering is observable and should be part
  of the contract.
- **The wildcard barrel.** TypeScript's `export * from './types.js'` is pinned
  as a barrel, not member by member. Enumerating it means generating the
  manifest from the schema, which is the right long-term answer and out of scope
  here.
- **`esm-libraries-spec.md` §5.** Now superseded by this document for API
  surface, and pointed here from its own heading. Its §2.4.4 conformance table
  and §5.5 Go description remain stale, and its §5.4 tier label for Rust —
  "Core + Analysis" — contradicts both the Rust binding (which exports
  `simulate`, `simulate_array` and `prepare`) and a paragraph three lines
  further down the same section, which says the Rust array simulator runs
  discretized PDEs. Reconciling or retiring that section is follow-up work.
