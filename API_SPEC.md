# EarthSciAST API Surface Contract

**Status:** phase 1 of API harmonization — the contract and its enforcement.
**Companion manifest:** [`api-surface.json`](api-surface.json) (machine-readable).
**Format spec:** [`esm-spec.md`](esm-spec.md) / [`esm-schema.json`](esm-schema.json).

`esm-schema.json` is language-neutral: it says what an ESM *document* is, once,
and every binding conforms to that one statement. Nothing played the same role
for the *API*. Five bindings implement one format, each documented separately in
[`esm-libraries-spec.md`](esm-libraries-spec.md) §5 in prose that has gone stale,
and nothing anywhere pinned the public surface. So the bindings drifted: the same
capability acquired different names, the same name acquired different meanings,
and neither could fail a test.

This document is the API's `esm-schema.json`. It names every public operation
**once**, in canonical `snake_case`, and gives a mechanical rule for deriving
each binding's spelling from that one name. `api-surface.json` carries the same
content for machines, and five surface tests hold every binding to it.

---

## 1. Scope, and how to read this

Five packages are in scope:

| Binding | Package | Surface declaration |
|---|---|---|
| Julia | `EarthSciAST.jl` | the `export` block of `src/EarthSciAST.jl` |
| TypeScript | `@earthsciml/ast` | named re-exports of `src/index.ts` |
| Python | `earthsci-ast` | `__all__` of `src/earthsci_ast/__init__.py` |
| Rust | `earthsci-ast` | root `pub use` / `pub const` of `src/lib.rs` |
| Go | `.../pkg/esm` | package-level exported identifiers |

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
both conforming Python. Pick one per binding and stay consistent. TypeScript's
`deriveODEs` survives only as a deprecated alias of `deriveOdes` (§8 item 5).

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

`api-surface.json` carries the current count (`counts.by_tier`), and §6 lists
every member, grouped by how many bindings export it.

### extension seam

Named and documented, **may differ between bindings, may break at a minor**.
This is where a binding is allowed to be itself: a Julia build seam that has no
Rust counterpart, a Rust performance knob that has no reason to exist in
TypeScript. Being in this tier is not a demerit — it is a promise that the
symbol is *reachable and documented*, and a warning that it is not portable.

Counted in `api-surface.json` (`counts.by_tier`). Known members, called out by
name:

- **Julia's build/inspection seam** — `BuildInspection`, `evaluate_expr`,
  `expanded_model`, `expand_flattened_refs`, `param_map`, `parameter_classes`,
  `remake_parameters`, and the deprecated `build_evaluator` until its removal
  (§8 item 23).
- **Julia's forcing-buffer surface** (the live forcing buffers of a **Problem**,
  and the hook that mirrors a host refresh into a compiled program's argument
  arrays) — `forcing_buffers`, `forcing_buffer_index`, `sync_forcing!`.
- **Rust's `intern` / `performance` / `simulate_array` internals** —
  `CompactExpr`, `PerformanceError`, `ParallelEvaluator`, `ModelAllocator`,
  `compile_array`, `stoichiometric_matrix_parallel`, and the module paths
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
the five surface tests assert. There is no private section of the manifest,
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

**TypeScript and Go are deliberately non-simulating.** They read, write,
analyse, and transform documents; they do not integrate them. A `simulate`
missing from Go is conformance, not a gap. This matches the tier labels in
`esm-libraries-spec.md` §5, which give TypeScript and Go "Core + Analysis" and
no Simulation tier.

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

So **Python's `solve` takes `abstol` / `reltol` / `alg`, not scipy's `atol` /
`rtol` / `method`**, and Rust's `SolveOptions` fields are `alg` and `saveat`,
not `solver` and `output_times`.

The rationale is that these names travel with the *problem*, not the *solver*.
A user who writes an ESM document and runs it from Julia, then from Python,
should be tuning the same knob under the same name. Deferring to each
language's local numerical convention is how three bindings end up spelling one
knob three ways.

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
decided during JSON DECODING) on `loadPath` and `loadString` only. A
`loadDocument` caller has already decoded the JSON, so the option has nothing
to act on there; a caller who wants tagged literals passes the text to
`loadString` with `canonical: true`.

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
keyword, and an option that does nothing is worse than none. Go additionally
exports `WritePathCompact` (extension tier).

The COMPACT form is byte-identical across bindings: Python pins
`separators=(",", ":")`, since `json.dumps(indent=None)` otherwise emits
`", "` / `": "` where serde_json, `encoding/json` and `JSON.stringify` emit
nothing.

The graph serializer is `to_json_graph` in all five (§8 item 8). Julia's
`to_json` also keeps `Graph` methods, a deprecated alias of `to_json_graph`
that dispatches on argument type and renders byte-identical output.

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

**Today:** all five export it, all five take only a **typed (loaded)
document**, all five return the four-field result, and none raises on an
invalid document. JSON text goes through the separate `validate_text`, which
also reports a load failure (malformed JSON, a schema violation, an
unresolvable mount) as a `ValidationResult` instead of raising. Julia and
Python also have `validate_path` for a file (§8 item 13).

| Binding | `validate` | `validate_text` | `validate_path` |
|---|---|---|---|
| Julia | `validate(file::EsmFile)` | `validate_text(text; base_path)` | `validate_path(path)` |
| TypeScript | `validate(document, { basePath })` — a loaded `EsmFile`, or a plain object of the same shape; a string throws a `TypeError` naming `validateText` | `validateText(text, { basePath })` | — |
| Python | `validate(esm_file, *, base_path=None)` — anything but an `EsmFile` raises `TypeError` | `validate_text(text, *, base_path=None)` | `validate_path(path, *, base_path=None)` |
| Rust | `validate(&EsmFile)` | `validate_text(json_str, base_path: Option<&Path>)`; `validate_complete` is its deprecated alias | — |
| Go | `Validate(*ESMFile)` | `ValidateText(jsonStr, opts ...LoadOption)` | — |

One divergence remains, in **schema errors**. Julia's `validate` re-runs the
schema check over the re-serialized document, and TypeScript's runs it over
whatever object it is handed, so either can report `schema_errors`. Python's,
Rust's and Go's `validate` run **no schema check at all**: their
`schema_errors` is empty by construction, because a typed document can only
exist by having already passed the schema at load. In all five the schema
check on text belongs to `validate_text`.

Go's `ValidateStructural` (see below) still returns the legacy
`*DetailedValidationResult` shape (`Valid` + a flat `Messages` list).

#### `validate_schema`

`validate_schema(data) -> [SchemaError]` — Julia and TypeScript export it and
return one structured `SchemaError{path, keyword, message}` per violation,
matching AJV's `allErrors`. Python, Rust and Go do not export it; their schema
check is reached through the `load_*` entry points and `validate_text`.

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

- **`system_kind` arity.** Settled in phase 6 (§8 item 11): Go took a second
  `domain *Domain` argument that neither its `SystemKind` nor its
  `EffectiveSystemKind` body read, and has dropped it. All five now take the
  model and nothing else. Julia, TypeScript, Python and Go export the whole
  family the item rules — `system_kind` (derived), `declared_system_kind` (the
  explicit field, nullable) and `effective_system_kind` (`declared ?? derived`).
  Rust exports only `system_kind`.
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

**Today** all five accept the full domain in all three renderers (§8 item 18);
TypeScript additionally accepts a single `Reaction`. A container has no
mathematical notation, so a `Model`, `ReactionSystem` or `EsmFile` renders as
its esm-spec §6.3 text summary. Rust takes any `T: TextRenderable`, which
`Expr`, `Equation` and the three containers implement; Go takes its untyped
`Expression` and switches on the dynamic type.

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
| `lower_enums` | **pure**, returns a new file; `lower_enums!` is the in-place twin; raises `EnumLoweringError` | **pure**, returns a new file, throws `EnumLoweringError` | **pure**, returns a new file; `lower_enums_mut` is the in-place twin; raises `EnumLoweringError` | **pure**, `(&EsmFile) -> Result<EsmFile, EnumLoweringError>`; `lower_enums_mut` is the in-place twin, `lower_enums_raw` the raw-`Value` seam | **pure**, returns `(*ESMFile, error)` carrying `*EnumLoweringError`; `LowerEnumsMut` is the in-place twin |
| `resolve_subsystem_refs` | `resolve_subsystem_refs!(file, base_path)`, raises `SubsystemRefError` | **`async`**, returns `Promise<void>`; the only binding that resolves remote `http(s)://` refs | mutates, returns `None` | `(&mut EsmFile, &Path) -> Result<(), DiagnosticError>`; `resolve_subsystem_refs_raw` is the raw-`Value` seam | returns `error` |
| `resolve_template_machinery` | `(raw, base_path; metaparameters, load_ref)` | `(rawData, basePath, {metaparameters, readFile, validateSchema})` | `(raw, base_path, metaparameters)` — no loader seam | `(&Value, &Path, &BTreeMap)` — no loader seam | **not exported** |
| `expand_coupling_imports` | returns the coupling list | returns `CouplingEntry[] \| undefined` | returns the list | returns `Result<Option<Vec<_>>, _>` | **not exported** |

> **⚠ Two cross-cutting divergences here.** (a) **`resolve_template_machinery`
> takes the raw, undecoded document in all four bindings that export it**, not
> a typed `EsmFile` (§8 item 14). (b) **TypeScript's `resolve_subsystem_refs`
> is the only `async` one**, and the only one that resolves remote refs.

### 5.8 Simulation (Julia, Python, Rust)

**Canonical.** One noun and one verb. `esm-libraries-spec.md` §2.5 is normative;
this is the surface it implies.

```
esm_problem(input, tspan, *, p, u0, providers, model_name,
            metaparameters, base_path, sample_time, compiler) -> Problem
solve(prob, *, alg, abstol, reltol, saveat, callback, maxiters) -> Solution
remake(prob, *, p, u0, tspan) -> Problem
init(prob, *, alg, ...) -> Integrator
step!(integrator) / solve!(integrator)
callbacks(prob) -> CallbackSet
observed_field(prob, name) -> Array
compiler(prob) -> <vocabulary value>
compiler_report(prob) -> per-rule tier record
EnsembleProblem(prob, rewrite) -> EnsembleProblem
rhs_program(prob) -> program                     # Julia, Rust; see below
select(prog, writes, terms) -> program
halo(op, dec) -> (variable, index set) => (lo, hi)
restrict(op, dec, owned, storage) -> tile        # Rust: RhsProgram::tile
lanes(op, kind, ...) -> lane program
```

A `Solution` carries `retcode` (SciML `ReturnCode`) and is read **by flattened
variable name**, not by state-vector position (`esm-libraries-spec.md`
§2.5.7). The key is the binding's own name type: Julia indexes by `Symbol`
through `SymbolicIndexingInterface` (`sol[Symbol("Decay.N")]`; a `String` key
is not accepted), Python by `str` (`sol["Decay.N"]`), Rust through
`Solution::get(&str)`. Errors are `SimulateError`.

**Per-binding type spelling.** The canonical name is `esm_problem`; §2.1's
consistency rule fixes the transliteration. Julia's only other `Esm`-prefixed
export is `EsmFile`, so Julia spells the type **`EsmProblem`**, not
`ESMProblem` — the latter would make Julia inconsistent with itself, which
§2.1 forbids. Go would spell it `ESMProblem` if it had one; it does not, and
will not.

**`simulate` is deleted in all three bindings**, not deprecated — it conflated
build with run, which is why two of the three had already grown a second
`prepare`-shaped entry point beside it. `prepare` / `PreparedModel` / `Prepared`
are replaced by Problem construction, which absorbs the same pipeline (rewrite →
value invention → gated fetch → compile). `build_evaluator` is **deprecated**
(§8 item 23): the build is private behind `esm_problem`, and the exported name
is an alias that warns and forwards, kept for one minor. What used to come off it comes off the Problem —
`prob.f!` / `prob.u0` / `prob.p` / `prob.var_map`, `forcing_buffers(prob)`,
`forcing_buffer_index(prob)`, `compiler_report(prob)` — and the compiled
right-hand side it reached through `form = :oop` is `compiler = :xla`.

#### The §2.2.7 clock: `resolve_time_span`, `time_origin`, `timestamp_to_seconds`

A `solver.time_span` bound is either a number of seconds or an RFC 3339 UTC
timestamp (`YYYY-MM-DDThh:mm:ss[.f]Z`). A timestamp counts from the document's
**time origin** — `domain.temporal.reference_time`, else
`domain.temporal.start`, else the POSIX epoch — as

```
seconds = (W − W₀) + (f − f₀)
```

the whole-second difference in integers, then the fractions added in binary64.
No binding reads a host date library: the calendar is the proleptic Gregorian
`days_from_civil`, so the range and the leap-year rules are the same everywhere.

| Canonical | Julia | Python | Rust | TypeScript | Go | Returns |
|---|---|---|---|---|---|---|
| `resolve_time_span` | `resolve_time_span` | `resolve_time_span` | `resolve_time_span` | `resolveTimeSpan` | `ResolveTimeSpan` | the interval to simulate: the call-site `tspan`, else the document's converted `time_span`, else none |
| `time_origin` | `time_origin` | `time_origin` | `time_origin` | – | – | the origin itself, as binary64 seconds from the POSIX epoch (`0.0` when the document declares none) |
| `timestamp_to_seconds` | `timestamp_to_seconds` | `timestamp_to_seconds` | `timestamp_to_seconds` | – | – | one timestamp, in seconds from that origin |

`time_origin` and `timestamp_to_seconds` are the two halves of
`resolve_time_span`'s arithmetic, exposed so a caller can convert a timestamp of
its own — a run config, or an interval it was handed — without reaching into a
binding's internals. `timestamp_to_seconds` accepts exactly the bound form
(`Z`, no offset), so it agrees with `resolve_time_span` bit for bit: the same
operands in the same order.

**The source.** Both read the origin from a document or from its `domain`
alone, so a caller can convert a timestamp before the document loads — to
check a raw document's `solver.time_span` itself, say:

| Binding | Signatures |
|---|---|
| Julia | `time_origin(file::EsmFile)`, `time_origin(domain)` with `domain` a `Domain`, a raw JSON value (an `AbstractDict` with String or Symbol keys, a `JSON3.Object` included, or a string, vector, number or boolean) or `nothing`; `timestamp_to_seconds` takes the same first argument, then `timestamp` |
| Python | `time_origin(source)`, `timestamp_to_seconds(source, timestamp)`, `source` an `EsmFile`, a `Domain`, a raw JSON value (`dict`, `list`, `str`, `int`, `float`, `bool`) or `None`; another type is a `TypeError`, raised before `timestamp` is looked at |
| Rust | `time_origin<S: TimeOriginSource + ?Sized>(source: &S) -> Result<f64, _>`, `timestamp_to_seconds(source: &S, timestamp: &str) -> Result<f64, _>`; the sealed trait `TimeOriginSource` is implemented for `EsmFile`, `Domain`, `serde_json::Value`, `Option<T>`, `&T`, `Box<T>`, `Rc<T>` and `Arc<T>` |

The raw form is the document's `domain` JSON value, `null` (or Julia
`nothing`, Python `None`, Rust `Value::Null`) for a document without one. It is
read as the load-time check reads it (esm-spec §2.2.7): a present origin key
selects its field, `null` included, and a `temporal` that is not an object has
no origin field. A `domain` that is neither an object nor `null` (a string, an
array, a number or a boolean) has no origin to read, and is refused with
`time_origin_invalid` naming `/domain` rather than read as the epoch. Every
form gives the same answer for the same domain.

**Refusals.** Each cause has its own code, so a caller tells them apart without
reading the message:

| Code | Cause |
|---|---|
| `timestamp_malformed` | `timestamp` is not a string, or not of the form `YYYY-MM-DDThh:mm:ss[.f]Z` |
| `timestamp_no_calendar_day` | `timestamp` is of that form, but its day is not in its month (`2019-02-30`, `02-29` outside a leap year) |
| `time_origin_invalid` | the origin field that applies is present but is not an RFC 3339 date-time naming a calendar day, or a raw `domain` is not an object; the message names the pointer (`/domain/temporal/...` or `/domain`) |

`timestamp_to_seconds` checks them in that order, the timestamp before the
origin, in every binding. `time_origin` can only raise `time_origin_invalid`.
`resolve_time_span` is unchanged: it and the load-time check raise
`solver_time_span_invalid` for every cause, naming `/solver/time_span`, since
esm-spec §2.2.5 gives a `time_span` that is no interval one code.

Reconstructing a timestamp's POSIX time from the pair is a separate matter.
`time_origin(f) + timestamp_to_seconds(f, ts)` rounds `W₀ + f₀` and
`(W − W₀) + (f − f₀)` separately before adding them, so it equals `W + f` only
to within binary64 rounding — exactly when the fractions are representable
(origin `.25`, timestamp `.5`), one ulp off otherwise (origin `.2`, timestamp
`.1`). A caller who needs a timestamp's POSIX time converts it against no
domain, whose origin is the epoch itself: `timestamp_to_seconds(nothing, ts)`
in Julia, `timestamp_to_seconds(None, ts)` in Python, and in Rust
`timestamp_to_seconds(&serde_json::Value::Null, ts)` or
`timestamp_to_seconds(&None::<Domain>, ts)` (a bare `&None` leaves the source
type unnamed and does not compile).

Julia, Python and Rust carry all three operations. TypeScript and Go carry
`resolve_time_span` but not the two accessors — neither binding simulates, and
the pair exists for a host driving a run — though their code registries list
the three codes, as every registry lists the whole vocabulary.

#### The initial state: `initial_state`

```
initial_state(prob) -> u0                      # Rust only; extension tier
```

The state a Problem integrates from at `tspan[0]`, one value per state element,
aligned with the Problem's state names (Rust: `prob.state_variable_names()`, the
flattened element names a `Solution`'s state rows carry). It is built exactly as
a solve builds it, without integrating: per element, the first of the Problem's
`u0` entry, an initialization equation (esm-spec §6.2), an `ic` equation or
field initial condition (§11.4, §11.4.1), and the declared `default`, with the
Problem's `p` (else the parameter defaults) bound in every initial condition's
scope (§6.6.5). So it depends on neither `tspan` nor any solver option, and a
field `ic` reads the forcing as construction bound it, without the
discrete-cadence fields a solve refreshes, so it gives the same state before and
after a solve. A Problem with no solve has no initial state: nothing to
integrate is `NotDynamic` and a Float32 document that integrates is
`Float32Unsupported`, as for `solve`; an element no source values is
`InvalidInitialCondition`, as in a solve. A Rust
`RhsProgram`'s `default_state()` is the declared defaults alone.

The SciML name `u0` already means the CALLER's override bindings in Python
(`prob.u0`, a dict) and Rust (`EsmProblem::u0()`), so the built state takes a
name of its own. Julia holds it in the `prob.u0` field (a vector indexed through
`prob.var_map`), an extension seam rather than an exported accessor. Python has
no accessor: the built state is reachable only as `init(prob).u` before the
first step. The shared cases in `tests/conformance/initial_state/`
(CONFORMANCE_SPEC §5.53) are keyed by element name, so a second binding that
adds `initial_state` runs them as they stand; the name becomes `stable` once it
does.

#### `compiler`: which strategy builds the right-hand side

`compiler` names the strategy a Problem's right-hand side is built with. Each
binding has several — a tree walk, generated code, a tape, an XLA emitter, a
lambdified scalar form — and absent this keyword it chooses among them by
inspecting the document. `compiler` makes the choice the caller's, and makes
what ran readable off the Problem afterwards.

The vocabulary is **closed**, and it has three kinds of member.
**`interpreter`** is deliberately simple, and exists as the **correctness check
for the other compilers** — nothing else. **`native`** is the **universally fast
option with no heavy external dependencies**: in Julia the
`RuntimeGeneratedFunctions` codegen the package already carries, in Rust the
tape, which needs no extra crate, in Python vectorized NumPy, already a base
dependency. That is why it is the default — it is the one value that is both
fast and always available. The rest are **specialty compilers**, each special in
one of two ways: `sympy` and `mtk` work only for some documents, and `xla` needs
a heavy external dependency to exist at all.

The members transliterate per §2: a Julia `Symbol`, a Python `str`, a variant of
a Rust `Compiler` enum carried on `ProblemOptions`.

| Value | Role | Promise | Julia | Rust | Python |
|---|---|---|---|---|---|
| `native` | Universally fast, no heavy external dependency — hence the default | **The default.** This binding's compiled or vectorized tiers, for **every** document regardless of shape. A rule that would need a per-cell tree walk is a build error naming the rule and the deepest decline reason. No fallback, ever. | `:native` — every kernel lands on the codegen, affine or whole-array tier | `Compiler::Native` — the array runtime's tape for every document | `"native"` — whole-box vectorized NumPy only |
| `interpreter` | Deliberately simple; the correctness check for the other compilers | The **reference**, and only the reference: every fast tier off, complete over the evaluable core, **no performance promise of any kind**. A caller picks it to check another compiler, not to run a model. | `:interpreter` — the tree walk with the per-cell runner for every kernel | `Compiler::Interpreter` — the per-cell oracle, no tape and no vectorized overlay | `"interpreter"` — the NumPy interpreter with the scalar `faq` evaluator for every aggregate |
| `xla` | Specialty: needs a heavy external dependency | StableHLO through XLA. Hard error on anything it cannot lower, which is already its behaviour. | `:xla` — **live.** The direct emitter, off the out-of-place compiled intermediate representation, compiled once per build and wrapped in the Problem's in-place `f!`; needs Reactant loaded, and says so with `compiler_unavailable` when it is not. `EARTHSCI_JULIA_XLA_DEVICE` (`cpu`/`gpu`) picks the client and the report names it | `Compiler::Xla` — the emitter over the tape; needs the `xla` feature **and** a usable `xla_extension` in the process, or `compiler_unavailable` | `compiler_unavailable` |
| `mtk` | Specialty: only some documents — the one that runs events and implicit equations | A ModelingToolkit `System`, structurally compiled and run through its own `ODEProblem`. The one compiler that runs **events and implicit equations** — the constructs §5.39 of `CONFORMANCE_SPEC.md` has the others refuse. "Only some documents" is the rest of the promise: a document fed by LOADED DATA (a provider, an array handed in at the call, the projection-pushdown rewrite), one with a CONTINUOUS spatial dimension, one carrying a geometry operator, and a time derivative of an expression are each refused BY NAME. | `:mtk` — `System` → `mtkcompile` → `ODEProblem`; needs ModelingToolkit loaded | `compiler_unavailable` | `compiler_unavailable` |
| `sympy` | Specialty: only some documents — scalar ones | A lambdified SymPy **scalar** right-hand side. Refuses array documents and constraints it cannot solve. | `compiler_unavailable` | `compiler_unavailable` | `"sympy"` |

**The default is `native`, and it is strict.** An unspecified `compiler` means
`native`, and under `native` a rule the compiled tiers cannot express is a
BUILD error, not a quiet demotion to a slower path. This is the rule
`CONFORMANCE_SPEC.md` §5.38.3 already applies to the compiled backends,
generalized: a compiler either runs the whole document or names what it
refused. `native` covers every document in the evaluable core, so its
refusals are reserved for the constructs outside its scope, each refused by
name: events, implicit equations and SDE noise (`unsupported_construct`, which
`mtk` runs for the first two), and a spatial operator with no discretization
rule (`unlowered_operator`, refused under every compiler). In Julia and Rust,
the bindings the native plan covers, every compiler-driven conformance tier
requires `native` for every fixture; a `native` refusal of anything else is a
defect, and no tier ledger excuses it. Python is exempt: its `native` gaps are
recorded as named exclusions in the tiers that meet them.

**A binding that does not implement a value refuses it.** Never by selecting
another one: the point of naming a compiler is that the caller knows which ran.
The three failures are the registry codes of esm-spec §9.6.6 —
`compiler_unknown` (outside the vocabulary), `compiler_unavailable` (in it, but
this binding, build or process cannot provide it; the message names what to
load or build) and `compiler_refused_rule` (the chosen compiler cannot run this
document; the message names the compiler, the rule — an equation or an
observed, component-qualified — and the reason).

**What the emitted program covers, under `xla`.** A binding whose `xla` emits
only the right-hand side must not serve the Problem's other evaluations — the
build-time materialization of constants and static observeds, the per-segment
seed, and the observeds reported at output times — from an evaluator that
declines on its own terms, and says which passes the emitted program covers.
Serving them from whatever the emitter itself consumed satisfies that, since
it has already been gated. This is the condition under which the refusal above
means anything: a second evaluator beside the emitted program would put rules
back on a per-cell walk with nothing in the report to show for it. In Rust
what the emitter consumed is the tape — `Compiler::Xla` runs the right-hand
side and the finite-difference Jacobian differenced out of it on the compiled
executable, and every other pass on that tape — and a rule that did not lower
to the tape is refused before the emitter is reached, so the refusal names the
rule and its cadence tier rather than an instruction.

**Every Problem reports what ran.** `compiler` gives the vocabulary value the
build actually used, and `compiler_report` gives, per rule, the tier it landed
on — which is informative even under `native`, where the interesting question
is affine versus codegen versus whole-array, or taped versus fused. Both names
and both meanings are stable surface. The report's exact **shape** is
per-binding for now and is not pinned here. A compiler that builds a FOREIGN
program reports that program's decisions in the same record: `mtk` names, per
rule, whether the compiled system integrates it, carries it in a residual, or
ELIMINATED it into an observed equation — the third being a decision no other
compiler makes and none of them can report.

**A compiler that builds a foreign program may index its solution in that
program's own naming.** §2.5.7 of `esm-libraries-spec.md` makes name-keyed
result access the documented path, and it stays the documented path; but a
solution produced by a foreign solver carries that solver's symbols, and a
binding is not required to translate them. The portable surface on such a
Problem is the name → state-slot map the Problem already exposes (Julia's
`var_map`) together with `observed_field`, which answer the DOCUMENT's
flattened names under every compiler.

**Callback composition:** a `callback` argument to `solve` REPLACES the
Problem's set entirely. To extend rather than replace, read the set back with
`callbacks(prob)` and compose explicitly. See §2.5.4 of the libraries spec for
why replacement is the safe default.

**What this replaced, per binding:**

| Knob | Julia (was) | Python (was) | Rust (was) |
|---|---|---|---|
| relative tolerance | `reltol` (`1e-4`) | `rtol` (`1e-10`) | `reltol` (`1e-6`) |
| absolute tolerance | `abstol` (`1e-6`) | `atol` (`1e-14`) | `abstol` (`1e-8`) |
| solver | `alg` | `method: str = "LSODA"` | `solver: SolverChoice` |
| output times | `saveat` | absent | `output_times: Option<Vec<f64>>` |
| options passing | keywords | positional-or-keyword | `&SimulateOptions` struct |
| run outcome | `success` + `retcode` + `message` | `success` + `message` + counters | step/eval counters |
| re-parameterize | `remake_parameters` (params only) | rebuild | rebuild |

**Correction of record.** An earlier revision of this table gave Julia's
defaults as `1e-10`/`1e-14` and concluded that Julia and Python already agreed,
with Rust the lone outlier. That was a misreading, caught by the Julia arm during
implementation: `1e-10` is `DEFAULT_TEST_RELTOL` in the inline-test runner
(`src/run_tests.jl`), whose partner is `1e-12`, not `1e-14`. Julia's actual
`simulate` defaults are `DEFAULT_SIM_RELTOL = 1e-4` / `DEFAULT_SIM_ABSTOL =
1e-6` (`src/simulate.jl`).

So the real situation is worse than recorded: **all three bindings default to
different tolerances**, spanning six orders of magnitude —

| | reltol | abstol |
|---|---|---|
| Julia | `1e-4` | `1e-6` |
| Rust | `1e-6` | `1e-8` |
| Python | `1e-10` | `1e-14` |

— and no two of them solve the same document comparably by default. Python's
docstring says its defaults were chosen to match Julia's; they match the *test*
constants, not the simulate ones.

**Ruled: the canonical defaults are Julia's.**

| Canonical | Value |
|---|---|
| `reltol` | `1e-4` |
| `abstol` | `1e-6` |

Python loosens by six orders and Rust by two; Julia is unchanged. The direction
is deliberate. A library default is what a document gets when its author has
expressed no opinion about accuracy, and the cheapest of the three is the right
thing to hand someone who has not asked — a default should be a sane starting
point, not a silent decision to spend six orders of magnitude of extra work on
their behalf. An author who needs tighter integration says so, and now says so
under the same name in every binding, which is the part that was actually
broken.

**A test that asserts trajectory accuracy MUST pass an explicit tolerance**
rather than lean on the default. Some did, and they are why this change is
visible: a test calibrated against an implicit `1e-10` is really asserting
something about the library's default, not about the model. Widening such a
test's own comparison threshold to keep it green is the wrong repair; give it
the tolerance it actually needs.

`observed_field` also had three different arities — Julia
`(prep, insp::BuildInspection, name)`, requiring the caller to have threaded the
same `BuildInspection` through `prepare`; Python `(prep, name)`; Rust a method on
`Prepared` taking only `name`. It is `(prob, name)` in all three, with build
observability moved to a construction-time seam.

#### `observed_field` on a document with no state variables

A document that declares no differential equations — `system_kind: nonlinear`,
every result an observed — has nothing to integrate. `solve` on it is a
run with no content, and each binding says so its own way (Rust
`SimulateError::NotDynamic`; Python's array pathway `ReturnCode.Failure`; the
scalar pathway samples the observed bodies over `tspan`; Julia hands back a
`Success` whose state rows are empty). **`observed_field` is the way such a
document's results are read**, and it is stable API, so it MUST answer on a
plain `esm_problem(input, tspan)` with no further options — no build flag, no
particular input spelling, no `inspect` sink. A binding whose stable function
needs an undocumented precondition to say anything has not implemented it.

**On the wasm surface** the same path is the `observed_fields` export
(`src/wasm.rs`), which returns every field at once — `{ names, fields: { [name]:
{ shape, values } } }` — rather than one per call. A `wasm_bindgen` boundary
cannot hand JS a live `EsmProblem` handle (this is the same constraint that
makes `solve` build-and-run in one call), so a per-name `observed_field` would
rebuild the problem on every lookup. The names it reports are
`observed_field_names`, and each is resolved through `observed_field`, so the
resolution rule below is the one a JS host gets.

#### `observed_field` on a data-fed parameter (Rust)

A DATA-FED parameter (`esm-spec.md` §5.4, `update: {kind: "data"}`) that the
build pipeline ingested is as observable as an observed: `observed_field`
returns the values its provider supplied, and an observed of the same spelling
wins. Ingested tables can be hundreds of MB, so the Problem keeps one only when
the caller names it in `ProblemOptions::retain_data_fields` (the right-hand
side's own copy is moved into the forcing buffer, not kept for read-back); for
an ingested parameter that was not named, `observed_field` fails with an error
that names the option. Such a parameter is not listed by `observed_field_names`.
Julia and Python do not answer for one yet.

#### Reading an observed of a document that DOES integrate

`observed_field` reports what the BUILD materialized, which is a constant. An
observed of a dynamic model is not one — it varies along the trajectory — and a
`Solution` carries **state rows only**, in every binding. So there was no way to
read one back at all: a model author asserting on `NOx` where the states are
`NO` and `NO2` got "not found" on a model that was fine.

The missing argument is the solution. An observed is a pure function of
`(state, params, t)`: the problem holds the function — the topo-sorted observed
graph and the parameter bindings — and the solution holds the arguments, which
is exactly why neither alone can answer.

```
observed_trajectory(prob, sol, name)    -> Array               # Rust, STRICT
observed_trajectories(prob, sol, names) -> (name, Array)[]     # one pass, TOLERANT
```

The plural is tolerant where the singular is strict: a name that is not an
observed variable — most often a STATE, which the caller already has in the
solution — is OMITTED from the result rather than failing the call, and the
result is keyed by the spelling that was asked for so the caller can tell which
came back. That split is what lets a host hand over a list of variable names
without first knowing which kind each one is.

**Not a second arity of `observed_field`, and the reason is the return RANK.** A
field is the shape the document declares; a trajectory is that shape with a time
axis added. Two ranks under one name is a contract a caller cannot read off the
call site. A binding that can overload MAY still spell it as an extra arity of
`observed_field` — Julia and Python are free to — and this is the
transliteration §2.1 fixes for the one that cannot.

**Julia reads one point of a trajectory instead**, as keywords on the same
function: `observed_field(prob, name; u, t)` is the observed at state `u` (laid
out like `prob.u0`, e.g. `sol.u[k]`) and time `t`. The result is the field's own
rank, so it is not the second-rank contract ruled out above; a trajectory is a
loop over the saved points. Without `u` it is the build-time field, and an
observed that reads the state is refused there, as in the other bindings.

Name resolution is the rule below, unchanged. Scalar backend only: the
array/spatial runtime materializes observeds per cell inside itself rather than
through this graph, and a static document has no trajectory and wants
`observed_field`. **Rust only today**, hence `extension` tier rather than
`stable`; it becomes stable when Julia and Python implement it.

> Julia's `SymbolicIndexingInterface` already returns observeds from `sol[…]`,
> so §2.5.7's claim that "a solution is indexed by variable name" has been true
> in one binding and not the others. This is the gap, named.

**On the wasm surface** this is `Solution.observed(name)` / `observedMany(names)`
on the handle returned by `Problem.solve` — see the `Problem` / `Solution`
classes in `src/wasm.rs`. The handle holds the problem it came from, so a host
cannot read a solution against the wrong bindings.

**Name resolution.** Build-time field names are **flattened and
component-qualified** (`Sites.North.u`). A binding MUST resolve `name` by this
precedence, stopping at the first rule that applies:

1. **Exact hit** — `name` is a field name.
2. **Bare name** — `name` carries no `.`, and the problem has exactly **one
   component**; it then resolves to the unique field with that tail.

A *component* is everything before a flattened name's final segment, and `""`
for an unqualified one; the problem's component count is the number of distinct
ones across its fields. A bare name against a **multi-component** problem MUST
be refused, naming every qualified candidate so the author can spell it, rather
than bound to one of them.

**The gate is the component count, not ambiguity**, and the difference is the
point. Under an ambiguity gate a bare `ur` that happens to be unique today
resolves, and mounting a second component tomorrow — one that need not even
declare a `ur` — changes what an existing script means, silently and at a
distance. The stricter rule makes the qualified spelling the only one that
survives composition, which is the spelling composition produces anyway.

> This deliberately diverges from esm-spec §6.6.2's override-key rule, which is
> ambiguity-gated (its rule 3 binds a bare key that is the trailing segment of
> exactly one flattened name). That rule governs keys an author writes **inside
> a document**, where the local spelling is the mandated one and the document's
> own composition is fixed; this one governs names a caller passes **from
> outside**, across recompositions the caller does not control. Both refuse to
> bind an ambiguous bare name to an arbitrary candidate, which is the property
> §6.6.2 calls out as non-conforming.

#### The public right-hand side: programs, workspaces and forcing sets

**Status.** Julia and Rust, under `compiler = native` (issue #541, RFC U4).
Python exports `rhs_program`, `forcing_set` and `default_forcing_set`, and each
raises `compiler_unavailable`. TypeScript and Go have no simulator and export
none of it. No schema or format change. `CONFORMANCE_SPEC.md` §5.51 is the gate;
its fixtures are `tests/conformance/public_rhs_program/`.

A Problem's right-hand side is a **program**: built once, immutable, and shared
by every thread that evaluates it. Everything an evaluation mutates lives in a
**workspace** the caller owns, one per concurrent caller. Forcing is not state
of the program: it is an argument, an immutable **forcing set** stamped with an
epoch no other set carries. The tile and lane programs of "Range-restricted
right-hand sides" below are programs in the same sense and follow every rule
here except where that section says otherwise.

##### The surface

| Canonical | Julia | Rust | Python |
|---|---|---|---|
| `rhs_program(prob)` | `rhs_program(prob)` | `rhs_program(&prob) -> Result<RhsProgram, SimulateError>` | raises `compiler_unavailable` |
| workspace | `rhs_workspace(x)` | `new_workspace(&self) -> RhsWorkspace` on `RhsProgram`, `TileProgram`, `LaneProgram` | — |
| states | `n_states(prog)`, `state_layout(prog) -> Vector{StateBlock}` | `RhsProgram::n_states(&self) -> usize`, `RhsProgram::state_layout(&self) -> &[StateBlock]` | — |
| parameters | `parameters(prog) -> Vector{ParamSlot}`, `parameter_vector(prog, overrides = Dict{String,Float64}()) -> Vector{Float64}` | `RhsProgram::parameters(&self) -> &[ParamSlot]`, `RhsProgram::parameter_vector(&self, &HashMap<String, f64>) -> Result<Vec<f64>, SimulateError>` | — |
| forcing slots | `forcing_slots(x) -> Vector{ForcingSlot}` | `forcing_slots(&self) -> &[ForcingSlot]` on each program type | — |
| forcing set | `forcing_set(x, bufs) -> ForcingSet` | `ForcingSet::new(&RhsProgram, Vec<Arc<[f64]>>) -> Result<ForcingSet, RhsError>` | raises `compiler_unavailable` |
| default forcing | `default_forcing_set(x) -> ForcingSet` | `RhsProgram::default_forcing(&self) -> ForcingSet` | raises `compiler_unavailable` |
| refresh | `replace_forcing(fs, slot, buf) -> ForcingSet` | `ForcingSet::replace(&self, slot: usize, Arc<[f64]>) -> Result<ForcingSet, RhsError>` | — |
| epoch | `forcing_epoch(fs) -> UInt64` | `ForcingSet::epoch(&self) -> u64` | — |
| evaluate | `rhs!(du, x, ws, u, aux, p, t, fs) -> du` | `eval_into(&self, u, aux, p, t, forcing: &ForcingSet, du, ws) -> Result<(), RhsError>` on `RhsProgram` and `TileProgram` | — |
| evaluate lanes | `rhs!(du, lanes, ws, u, aux, p, t, fs, cells, n)` | `LaneProgram::eval_into(&self, u, aux, p, t, forcing: &ForcingSet, cells, n, du, ws) -> Result<(), RhsError>` | — |
| pre-gathered lanes | `gather_lane_inputs!(li, lanes, p, t, fs, cells, n)`, then `rhs!(du, lanes, ws, u, aux, p, t, li, cells, n)` | `LaneProgram::gather_lane_inputs(&self, &mut LaneInputs, p, t, forcing: &ForcingSet, cells, n) -> Result<(), RhsError>`, then `eval_gathered_into(&self, u, aux, &LaneInputs, p, t, cells, n, du, ws) -> Result<(), RhsError>` | — |
| array parameters | `esm_problem(…; runtime_array_parameters = false)` | `ProblemOptions::runtime_array_parameters: bool` (default `false`) | — |

The entry point is the free function `rhs_program(prob)`: the Problem stays
between the document and the program, so construction (§2.5.2 of
`esm-libraries-spec.md`) is the one place a document is rewritten, fetched and
compiled. There is no `RhsProgram::from_problem`.

**Rust types.**

```rust
pub struct RhsProgram   { /* Arc<…> */ }   // Send + Sync + Clone
pub struct TileProgram  { /* Arc<…> */ }   // Send + Sync + Clone
pub struct LaneProgram  { /* Arc<…> */ }   // Send + Sync + Clone
pub struct RhsWorkspace { /* … */ }        // Send, !Sync
pub struct ForcingSet   { /* epoch: u64, bufs: Arc<[Arc<[f64]>]> */ }   // Send + Sync + Clone

pub struct ParamSlot   { pub name: String, pub default: Option<f64> }
pub struct ForcingSlot { pub name: String, pub shape: Vec<usize>, pub kind: SlotKind }
pub enum   SlotKind    { Forcing, ArrayParameter }
pub struct StateBlock  { pub name: String, pub flat_offset: usize, pub shape: Vec<usize> }

#[non_exhaustive]
pub enum RhsError {
    Fault { code: &'static str, message: String },
    Shape { what: &'static str, expected: usize, got: usize },
    ForeignProgram { what: &'static str },
    ForcingSignature { detail: String },
    SlotIndex { slot: usize, slots: usize },
    NotGathered,
}
```

All of them are re-exported at the crate root. `RhsError` implements
`std::error::Error` and `Display`. `Shape` is a length mismatch only
(`expected` and `got` are lengths); a workspace or lane inputs from another
program is `ForeignProgram`, a forcing set for other slots is
`ForcingSignature` (its `detail` names the first slot that differs), an
out-of-range slot index to `replace` is `SlotIndex`, and lane inputs whose last
gather failed, or that were never gathered, are `NotGathered`. Build-time calls (`rhs_program`, `select`,
`halo`, `tile`, `lanes`, `parameter_vector`) keep `SimulateError`.

**Julia types.** `ForcingSet`, `ForcingSlot` (`name::String`,
`shape::Vector{Int}`, `kind::Symbol`, `:forcing` or `:array_parameter`),
`ParamSlot` (`name::String`, `default::Union{Float64,Nothing}`) and `StateBlock`
(`name::String`, `offset::Int` 1-based, `shape::Vector{Int}`) are exported.
`parameters` is the existing export, with a method on programs.

##### Thread safety (normative)

- **Rust.** `RhsProgram`, `TileProgram`, `LaneProgram` and `ForcingSet` are
  `Send + Sync + Clone`, unconditionally, and a clone is a reference-count
  increment. `RhsWorkspace` is `Send` and not `Sync`. A static assertion in the
  crate's tests pins each. No type that holds an `Rc`, a `RefCell` or a `Cell`
  carries an `unsafe impl Send` or `Sync`. The workspace MAY carry an
  `unsafe impl Send` whose only justification is the fused executor's raw
  pointers into its own buffers, which are rewritten before every use; the
  impl's `SAFETY` comment says so.
- **Julia.** A program, a forcing set and a layout are never mutated after they
  are built. `rhs!` is reentrant across distinct workspaces: any number of tasks
  may evaluate one program at once, each with its own workspace.
- **Both.** A workspace serves one call at a time. Sharing one between
  concurrent calls is a caller error (Rust prevents it with `&mut`).

##### Semantics of an evaluation (normative)

1. **Purity.** The output is a function of the program, `u`, `aux`, `p`, `t` and
   the forcing set's contents, and of nothing else. It is bitwise identical
   across threads, across workspaces, whatever a workspace evaluated before, and
   under any interleaving of concurrent calls.
2. **Reference.** On the same inputs a program equals the binding's existing
   single-threaded evaluation bitwise: in Rust, `debug_eval_rhs_into` with a
   scratch from `debug_new_scratch_taped` whose forcing buffer holds the same
   data; in Julia, the Problem's `f!` with its forcing buffers holding the same
   data. Same kernels, same order.
3. **Output.** A whole-domain program zeroes `du` and then writes it; a state
   with no `D(·)` equation comes back `0`. A tile writes only its owned rows and
   a lane program only lanes `1..n`, leaving every other element untouched
   ("Range-restricted right-hand sides").
4. **Workspace.** A workspace belongs to the program that made it and to every
   clone of that program. Passing it to another program — including a program
   `select`ed, tiled or laned from this one — is `RhsError::ForeignProgram {
   what: "workspace" }` in Rust and an `ArgumentError` in Julia, never undefined
   behaviour. The check is on a stable identity of the shared program, not on
   the address of the handle, so moving or cloning the handle keeps a workspace
   valid.
5. **Section caching.** The compiled program keeps its constant, segment and
   continuous sections, and each workspace keys them on its own inputs:
   - the constant section re-runs when the bitwise hash of `p` differs from the
     one the workspace last primed;
   - the segment section re-runs when `forcing_epoch(fs)` differs from the epoch
     the workspace last primed;
   - every forcing and array-parameter load is in the segment section (the
     program is built with every forcing slot in its discrete set), so no
     forcing value is ever cached past a change of set.
   A fresh workspace primes both on its first call.
6. **No allocation.** After warm-up, a call allocates nothing, including a
   call that re-runs the constant or segment section because `p` or the forcing
   set changed (Rust: the counting-allocator test; Julia ≥ 1.12: `@allocated`
   is zero).
7. **Errors.** A fail-closed fault (esm-spec §4.3.3 and the faults of
   `CONFORMANCE_SPEC.md` §5.5.5 and §5.23) is returned as `RhsError::Fault {
   code, message }` in Rust, with the code the fault carries today (for example
   `E_TREEWALK_CONSTARRAY_OOB`), and thrown as the existing `TreeWalkError` in
   Julia. `du` is then unspecified. No fault survives the call: no latch shared
   between workspaces or threads, no thread-local left armed, no panic, no NaN
   fill. A call on another thread or another workspace never observes it, and
   the faulted workspace's next call is unaffected. A wrong length of `u`,
   `aux`, `p` or `du` is `RhsError::Shape` naming the argument (`"u"`,
   `"aux"`, `"p"`, `"du"`); a forcing set built for another forcing signature
   is `RhsError::ForcingSignature`, and a workspace from another program
   `RhsError::ForeignProgram`. Julia throws `DimensionMismatch` for a length
   and `ArgumentError` for a set or workspace that does not belong.
8. **No internal threads.** An evaluation never spawns, joins, or runs on a
   global pool. Julia's Polyester chunking is off inside `rhs!` (the Problem's
   own `f!`, used by `solve`, may keep it).
9. **Precision is the program's.** An evaluation arms the program's precision
   itself; no result depends on a thread's ambient precision. The state is
   `f64` (Julia `Float64`) only; a generic state scalar is #542's (RFC U5).

##### States and parameters (normative)

- `n_states(prog)` is the length of `u` (the layout's `u` length). For a
  whole-domain program `aux` is empty; a `select`ed program's `aux` follows
  "Selection" below.
- `state_layout(prog)` lists the `u` blocks in flat-layout order (0-d states by
  sorted name, then arrays by sorted name): the flattened name, the offset of
  its first element (0-based in Rust, 1-based in Julia), and its declared shape
  (empty for a 0-d state). Each block is column-major, first index fastest. It
  is derived from `tile_layout(prog)` / `RhsProgram::layout()` and agrees with
  it by construction.
- **The parameter vector.** `p` is a dense `f64` vector of length
  `length(parameters(prog))`, in the order `parameters(prog)` lists: the
  program's scalar parameters that are not externally fed (those are forcing
  slots, below), by flattened name, ascending in byte order.
  `ParamSlot.default` is the declared default (`None` / `nothing` when there is
  none). `parameter_vector(prog, overrides)` is strict: each entry is the
  override if one is given, else the default; a parameter with neither, and an
  override key that names no parameter, is an error naming it. The lenient
  `debug_resolve_params` stays a debug seam. Rust's `parameter_names` and
  `default_parameters` are folded into `parameters()`.
- Derived programs (`select`, `tile`, `lanes`) have the parent's `parameters`
  and the parent's `forcing_slots`, in the same order, so one `p` and one
  forcing set serve a whole decomposition.

##### Forcing sets (normative)

- **Slots.** `forcing_slots(x)` lists, in ascending byte order of flattened
  name, every input the program reads that is not state and not a scalar
  parameter: every externally fed parameter (`kind = Forcing`; a parameter
  whose `update` takes its value from a data source or a handler) and, when
  `runtime_array_parameters` is on, every shaped parameter with a value
  (`kind = ArrayParameter`). `shape` is the variable's declared shape, resolved.
  The kind follows the parameter, not how its value arrived: `Forcing` when
  the parameter is externally fed (or the buffer is a provider's that no
  parameter declares), `ArrayParameter` otherwise, including a shaped
  parameter whose value the caller supplied at construction. A Julia
  `param_arrays` entry is a live buffer even with `runtime_array_parameters`
  off, so a shaped parameter bound through it is an `ArrayParameter` slot
  either way.
- **Buffers.** A set holds one buffer per slot, in slot order, of length
  `prod(shape)` (1 for a 0-d slot), **column-major** (first index fastest), the
  same convention as the state. Rust takes `Arc<[f64]>`; Julia takes any
  `AbstractVector{Float64}` (or array) of that length and reads it in linear
  order. A set does not copy its buffers and its holders must not mutate them:
  Rust enforces it, and in Julia mutating a buffer after building a set is
  undefined behaviour (the epoch would not change). Any transpose into the
  compiled kernels' layout happens in the load, never per call.
- **Construction.** `forcing_set(x, bufs)` / `ForcingSet::new` checks the slot
  count and each buffer's length (`RhsError::Shape { what: "forcing", .. }`;
  Julia `DimensionMismatch`) and stamps the set with a fresh epoch.
- **Epochs.** One process-wide counter (`AtomicU64` in Rust,
  `Threads.Atomic{UInt64}` in Julia), incremented for every set built; an epoch
  is never reused within a process. Two distinct sets never share an epoch,
  so a stale read is impossible by construction. A clone of a set is the same
  set and keeps its epoch. Julia's process-global `_FORCING_EPOCH` is not
  consulted on the `rhs!` path.
- **Refresh is a swap.** `replace_forcing(fs, slot, buf)` / `replace` returns a
  NEW set with a new epoch, sharing every other buffer; the old set is
  unchanged and stays valid for whoever still holds it. `slot` is 0-based in
  Rust and 1-based in Julia; a slot past the end is `RhsError::SlotIndex` in
  Rust. There is no in-place refresh and no invalidation call.
- **Default.** `default_forcing_set(x)` / `default_forcing()` is the Problem's
  forcing when `rhs_program(prob)` ran: provider data, a caller's array, or the
  declared default broadcast over the slot's shape, and for an
  `ArrayParameter` slot the parameter's value. It is a copy taken at program
  build; later changes to the Problem's own buffers are not seen. Every call
  returns the same set (same buffers, same epoch).
- **Compatibility.** A set is valid for the program it was built against and for
  every program derived from it or cloned from it (same slots). A set whose
  slot signature differs is `RhsError::ForcingSignature`.

##### Run-time array parameters (normative)

`runtime_array_parameters` is a construction option, off by default. Off, a
shaped parameter with a value is baked into the compiled program exactly as
today, bit for bit, `remake` refuses to change it, and it is no slot. On, every
shaped parameter with a value (its default, or a construction-time array the
caller supplied) becomes an `ArrayParameter` forcing slot: the build does not
fold it into constant observeds, `default_forcing` carries its value, and a new
value takes a new forcing set, never a rebuild. A run-time array parameter is
read like forcing, through the segment section. Under `runtime_array_parameters
= true` the program evaluated with its default forcing set equals the program
built with the option off, bitwise.

##### Compilers

`rhs_program` requires `compiler = native` for the semantics above. A native
Problem one of whose rules did not tape is refused at `rhs_program` with
`compiler_refused_rule`, naming the rule. `compiler = interpreter` is kept as the
reference oracle where the binding can meet the thread-safety rules above with
it (shared data behind `Arc`, per-call state on the workspace, no thread-local
surviving a call); under any other compiler `rhs_program` raises
`compiler_unavailable`. `solve` on a native Problem evaluates through the same
program (one workspace held by the solver), so there is one code path and the
solve's numbers do not change.

**Not here.** Observed outputs are not readable from a workspace (#543, RFC
U6). Precision semantics of a `Float32` document (#542, RFC U5). XLA programs are
not `Send + Sync` by this section (#544, RFC U13). Internal parallelism of one
evaluation.

#### Range-restricted right-hand sides: selection, tiles and lanes

**Status.** Julia and Rust, under `compiler = native` (issue #540, RFC U3).
Python exports the entry points and each raises `compiler_unavailable`.
TypeScript and Go have no simulator and export none of it. No schema or format
change: the decomposition, the boxes and the selection are API arguments.
`CONFORMANCE_SPEC.md` §5.50 is the gate; its fixtures are
`tests/conformance/range_restricted_rhs/`.

A Problem's right-hand side `F` evaluates the whole model over the whole domain.
These entries evaluate one **operator** `F_k` — a subset of the additive terms,
selected by #539 provenance, writing only that operator's variables — over a
**tile** (an owned box of a horizontal decomposition, reading halo cells from an
extended local array) or over **lanes** (a run-time list of cells or columns).
Index space stays global, so a `makearray` boundary region applies exactly where
the global domain has a boundary and interior stencils apply at every other tile
edge. The contract is bitwise: the tiles' owned outputs, assembled, equal the
operator's whole-domain right-hand side bit for bit, and every lane equals its
cell.

##### The surface

| Canonical | Julia | Rust | Python |
|---|---|---|---|
| `rhs_program(prob)` | `rhs_program(prob)` | `rhs_program(&prob) -> Result<RhsProgram, SimulateError>` | raises `compiler_unavailable` |
| `select(prog, writes, terms)` | `select(prog; writes = :all, terms = :all)` | `RhsProgram::select(&self, &RhsSelection) -> Result<RhsProgram, SimulateError>` | raises `compiler_unavailable` |
| `halo(op, dec)` | `halo(op, dec) -> Dict{Tuple{String,String},Tuple{Int,Int}}` | `RhsProgram::halo(&self, &Decomposition) -> Result<HaloReport, SimulateError>` | raises `compiler_unavailable` |
| `restrict(op, dec, owned, storage)` | `restrict(op, dec; owned, storage)` | `RhsProgram::tile(&self, &Decomposition, &TileBox) -> Result<TileProgram, SimulateError>` | raises `compiler_unavailable` |
| `lanes(op, kind, capacity)` | `lanes(op, kind, sets)` | `RhsProgram::lanes(&self, LaneKind, capacity: usize) -> Result<LaneProgram, SimulateError>` | raises `compiler_unavailable` |
| layout | `tile_layout(prog_or_tile)`, `lane_layout(lanes)` | `RhsProgram::layout() -> &TileLayout`, `TileProgram::layout() -> &TileLayout`, `LaneProgram::layout() -> &LaneLayout` | — |
| workspace, evaluate | see "The public right-hand side" above | see "The public right-hand side" above | — |
| pre-gathered lane inputs | `lane_inputs(lanes, L)`, then as above | `LaneProgram::lane_inputs(&self) -> LaneInputs`, then as above | — |
| decomposition | `Decomposition(; axes, faces)` | `Decomposition { axes: Vec<AxisCut>, faces: Vec<(String, String)> }`, `AxisCut { index_set: String, period: Option<i64> }` | — |

Julia's `restrict` is Rust's `tile`; the RFC names both and both are kept.

**The program.** `rhs_program(prob)` is the Problem's right-hand side as a
program value: the whole model, over the whole domain, with `u` the Problem's
state and `aux` empty — the public right-hand side above. `select`
returns another program of the same type; `halo`, `restrict`/`tile` and `lanes`
take one. A program carries the flattened system it was built from, so
`select` re-flattens nothing and re-parses nothing.

- **Julia.** `writes` is `:all` or a vector of flattened state names; `terms`
  is `:all` or a vector of `TermOrigin`. `dec = Decomposition(axes = ["lon" =>
  (period = 144,), "lat" => (period = nothing,)], faces = ["lon_nodes" =>
  "lon"])`. `owned` and `storage` are `index set => UnitRange` pairs, one per
  decomposed axis: `restrict(op, dec; owned = ("lon" => 17:32, "lat" => 1:13),
  storage = ("lon" => 14:35, "lat" => -2:16))`. `kind` is `:cells` or
  `:columns`; `sets` names the index sets a lane's `cells` column indexes, in
  order. `p` is `parameter_vector(prog)` and `fs` a `ForcingSet` (above).
  Buffers are `Vector{Float64}`; `cells` is a `Matrix{Int32}` of size `[D, L]`;
  `rhs!` returns `du`.
- **Rust.** `RhsSelection { writes: Option<Vec<String>>, terms:
  Option<Vec<TermOrigin>> }`, `None` meaning all. `TileBox { owned: Vec<(String,
  RangeInclusive<i64>)>, storage: Vec<(String, RangeInclusive<i64>)> }`.
  `LaneKind::Cells { sets: Vec<String> }` or `LaneKind::Columns { sets:
  Vec<String> }`. `HaloReport { reach: BTreeMap<(String, String), (i64, i64)>
  }`, keyed `(variable, index set)`. Buffers are `&[f64]` / `&mut [f64]`, `cells`
  is `&[i32]` holding `[D, capacity]` column-major, `p` is the program's
  parameter vector (`RhsProgram::parameters()`), the forcing is a `ForcingSet`,
  and every `eval_into` returns `Result<(), RhsError>` (above).

**Layouts.** `TileLayout` holds two lists of `TileBlock`, `u` and `aux`, and
their lengths. A `TileBlock` is `{ name, sets, storage, owned, base, strides }`:
the variable, its index sets in shape order, its storage box and owned box per
set (inclusive, global coordinates; `owned` is empty for an `aux` block), its
base offset in the buffer (1-based in Julia, 0-based in Rust) and its
column-major strides. A whole-domain program's layout is the same record with
storage = owned = the variable's global box. `LaneLayout` holds `u` and `aux`
lists of `LaneBlock { name, sets, extents, offset }` — the variable's non-lane
index sets, their extents and its offset in units of lanes (below) — and the
lane sets.

##### Selection (normative)

`select(prog; writes, terms)` returns the program of one operator. It is a
**flatten-level rewrite** keyed by #539 provenance (esm-libraries-spec §4.7.5):

1. **Terms.** For every flattened equation, keep each contribution whose
   `origins` intersect `terms`, matched by `TermOrigin` equality (a
   `{"component": path}` or a `{"coupling": k}`). `terms = all` keeps every
   contribution. The kept contributions are summed as a LEFT FOLD in their
   original relative order — the order and the association #539's invariant
   fixes.
2. **Writes.** Every equation whose target is not in `writes` is dropped.
   `writes = all` is every state of the program. A kept equation whose
   contributions were all dropped has right-hand side `0`: an operator that
   does not touch a variable it writes.
3. **Completeness.** A variable outside `writes` that has a kept contribution
   is refused with `range_selection_writes_incomplete`, naming the variable and
   the contribution's origins. Selection never silently discards a term the
   caller selected.
4. **Inputs.** `u` covers the written variables `W_k`; `aux` covers `R_k \
   W_k`, the states the kept rules read (directly or through observeds) that
   the operator does not write. Both are in the flat layout's order: 0-d states
   by sorted name, then arrays by sorted name. `aux` is read-only.
5. **Recompile.** The selected flattened system is compiled under the
   program's compiler. Observeds no kept rule reads are not evaluated.

Every bitwise claim below is against `select(prog; …)` evaluated over the whole
domain, written `G_k`. `Σ_k G_k = F` holds only to rounding, because dropping
summands changes the association; `CONFORMANCE_SPEC.md` §5.50 bounds it.
`terms = all` with `writes = W_k` is the same program as an operator's derived
document, when a planner emits one.

##### Terms of a decomposition

- **Decomposition.** The caller names the horizontal index sets it cuts, each
  one's period if periodic, and the face index sets that stagger off it (for
  example `lon_nodes` off `lon`). Every other index set (`lev`, species,
  records) is whole on every tile. A period is the axis's global extent.
- **Owned box `B`.** One inclusive range per decomposed index set, inside
  `1..N`.
- **Storage box `S`.** `B` dilated by the halo. Along a non-periodic axis it may
  extend past `1..N`. Along a periodic axis it is expressed in unwrapped
  coordinates, for example `-2..16`.
- **Face sets.** Cell `i` owns face `i`, its low face; the tile that owns cell
  `N` also owns face `N+1`. Owned faces are the owned cells, plus `N+1` at the
  high edge; storage faces are `S`'s cells plus one. A face quantity stored on
  the cell index set is just a cell variable.
- **Rank storage.** Several tiles may share one storage box (a rank's extended
  array). With `S` equal to the whole domain, storage is the global layout.

##### Halo report (normative)

`halo(op, dec)` returns, for every state variable `v ∈ R_k` and every decomposed
or face index set `s` on `v`'s shape, the pair `(lo, hi)`: how far the owned
output reaches into `v` along `s`. It is the smallest pair such that, for every
owned box `B`, `B` dilated by `(lo, hi)` (in face coordinates for a face set)
contains every in-domain cell of `v` a tile owning `B` reads.

- **Composition.** Offsets compose through observeds. If `du[i]` reads `F[i]`
  and `F[i+1]`, and `F[j]` reads `u[j-3..j+2]`, then `u` needs `(3, 3)`.
- **Region reach.** Each `makearray` region contributes its own reach; the
  report is the maximum over regions, so a reach that occurs only in a boundary
  slab is included.
- **Wraps.** A periodic wrap counts as reach across the seam, whether the
  evaluator's periodic gather does it or the rule spells it out (`f[NLON-1]`
  read from cell 1 is a reach of 2 below cell 1).
- **Refusals.** A contraction, scan or data-dependent subscript along a
  decomposed axis has no finite reach: `halo` raises `range_global_locality`
  naming the rule and the axis.

The report names only states. Forcing and array parameters are read in full: a
tile or lane program takes the same whole-domain `ForcingSet` as the program it
was derived from. A forcing reach report and windowed forcing sets are not
specified.

##### Tile semantics (normative)

Let `G_k` be the operator program over the whole domain. Suppose `u_S` and
`aux_S` agree with the global state on every in-domain cell of `S`, and on a
periodic axis every cell outside `1..N` holds the value at its wrapped index.
Then for every `v ∈ W_k` and every owned cell `c` of `v`:

    tile(u_S, aux_S, p, t)[v, c]  ==  G_k(u, aux, p, t)[v, c]   (bitwise)

The compiler reaches this by the following rules.

1. **Region clipping.** Each `makearray` region's global box is intersected
   with the need box of its output. Empty intersections are dropped. Order, and
   "later overwrites earlier", are kept. A PPM tile owning `lon ∈ 17..32` keeps
   only the interior `[4, N-2]`; the tile owning `1..16` keeps slabs 1, 2 and 3
   and the interior `4..16`.
2. **Reads.** Each read of `v` at global index `g` along axis `a` resolves in
   this order:
   - `g` in storage → read storage.
   - `a` periodic with period `N`, and `g ± N` in storage → read that cell.
     This covers both explicit wraps and the periodic gather policy.
   - `g` outside `1..N`, `a` not periodic → today's out-of-range rule: zero
     ghost for states and observeds, the declared policy for const arrays.
   - Otherwise → build error `range_halo_insufficient`, naming the rule, the
     variable, the axis and the missing cells.
3. **Observeds.** Each array observed is evaluated on its need box. That box is
   the union of its readers' need boxes, each widened by that reader's offsets,
   clipped to the observed's global extent. It is recomputed by every tile that
   needs it; observeds are never exchanged.
4. **Writes.** Only the `(W_k, owned)` rows of `du` are written. Every other
   element of `du` is left untouched. Tiles sharing a storage box may therefore
   write one shared `du` concurrently.
5. **Dead halo cells.** Storage cells outside `1..N` on a non-periodic axis are
   never read. The caller may leave them uninitialized; the conformance test
   fills them with NaN.

Boxes are fixed at build. Out-of-domain reads keep today's semantics; an
in-domain read outside storage is a build error, never a ghost zero. Filling the
halo is the caller's job.

##### Tile layout (normative)

`u_S`, `aux_S` and `du_S` are species-major. Each variable is one column-major
block over its storage box (first index fastest), in flat-layout order: today's
layout with `S` in place of the global box. `du_S` has `u_S`'s layout; only
owned rows are written. Index offsets are rebased by storage origin alone:

    slot = base_v + Σ_d (g_d - S_lo[v,d]) · stride[v,d]

with `g` the global index. Region bounds, coordinates and index-derived values
keep their global 1-based values.

##### Lanes (normative)

`lanes(op, kind, …)` evaluates an operator whose locality is `pointwise`
(`kind = cells`) or `column` (`kind = columns`) over a run-time list of cells.

- **Inputs.** `cells` is an `Int32` array of global indices, `[D, L]`, column
  `l` the index tuple of lane `l` over the lane sets in the order named. For
  `cells` the lane sets are every index set of the written variables' shape;
  for `columns` they are the horizontal sets, and the column is every other
  set. Every state in `u` and `aux` carries every lane set.
- **Layout.** `u_L`, `aux_L` and `du_L` are species-major with the lane index
  fastest. Variable `v`, in flat-layout order, holds `C_v` column elements (the
  product of its non-lane extents; 1 for `cells`), at offset `off_v = Σ_{v'
  before v} C_{v'}`; element `e` (1-based, column-major over the non-lane sets)
  of lane `l` is at slot `(off_v + e - 1)·L + l`. For a pointwise operator that
  is `(s-1)·L + l`; for one species on a column, `((s-1)·nlev + (k-1))·L + l`.
- **Semantics.** For each lane `l ≤ n` and each `v ∈ W_k`, `du_L[v, l] ==
  G_k(…)[v, cells[:, l]]` bitwise. A lane's result depends only on its own
  inputs, so padding a batch with duplicates of a real cell is safe and
  discardable, and lane order and batch composition cannot change a value.
- **Reads.** State reads at offset 0 (pointwise) or along the column (column)
  come from `u_L` and `aux_L`. Every read that depends on the cell's index is
  evaluated from `cells`: coordinate expressions, level gates, and affine reads
  of forcing, array parameters, const arrays and state-free observeds.
  State-free observeds keep their whole-domain build-time values and are
  gathered per lane. A read that leaves the cell (pointwise) or the column
  (column) is refused with `compiler_refused_rule`, naming the rule and saying
  "lane".
- **Pre-gathered inputs.** `lane_inputs` returns per-lane buffers for every
  non-state input, `gather_lane_inputs!` fills them for a `cells` list, and the
  pre-gathered evaluation reads them in place of the gathers. Its results are
  bitwise those of the plain call.
- **Capacity.** Julia loops over lanes with a run-time count, so one build
  serves every `L` (`L = size(cells, 2)`). Rust slot boxes are static, so a lane
  program is built per capacity (re-lowering only, no document rebuild) and `L`
  is the capacity. A call passes `n ≤ L`; lanes `n+1..L` are computed and
  unspecified.

##### Native only, and strict

`select` works on any program. `halo`, `restrict`/`tile` and `lanes` require a
program built with `compiler = native`; under any other compiler they raise
`compiler_unavailable`, naming the call. There is no fallback to the interpreter
and no path that evaluates the global `F` and discards the rest. A native tier
that cannot be restricted raises `range_global_locality` where decision 8 below
covers it, and otherwise `compiler_refused_rule` naming the rule and saying
"tile restriction" or "lane". A silent wrong answer is never an option.

**What tiles refuse (decision 8).** A write to a 0-d state, and a contraction, a
scan or a data-dependent gather along a decomposed axis: these have `global`
locality. A contraction along an axis that is NOT cut is ordinary per-tile work.

| Code | Raised by | Meaning |
|---|---|---|
| `range_halo_insufficient` | `restrict` / `tile` | An in-domain read falls outside storage and has no periodic image in it (tile rule 2). Names the rule, the variable, the axis and the missing cells. |
| `range_global_locality` | `halo`, `restrict` / `tile` | A 0-d state write on a tile, or a contraction, scan or data-dependent gather along a decomposed axis. Names the rule and, where there is one, the axis. |
| `range_selection_writes_incomplete` | `select` | `writes` omits a variable whose kept contributions are non-empty. Names the variable and the origins. |
| `range_box_invalid` | `halo`, `restrict` / `tile`, `lanes` | An owned box not inside its storage box or outside `1..N`; an unknown index set; a face set declared against an axis the decomposition does not cut; a period that is not the axis's extent; lane sets that do not match the kind. Names the index set. |

**Cost (normative for Julia and Rust).** A tile's call touches, copies,
transposes or fills no cell outside its storage box: the run cost is O(need
box), never O(domain). Building a tile may re-lower (Rust) but never
re-flattens or re-parses the document. A steady-state call allocates nothing
(Julia ≥ 1.12). One Julia lane build serves every lane count; Rust re-lowers
per capacity.

**Not here.** Halo exchange, MPI and threading are the caller's. Tile boxes are
fixed at build; there is no run-time box argument. Restricted observeds are not
exported. `global` operators (SSA, connected components, horizontal sums) stay
whole-domain. XLA tile and lane programs are U13's. A `makearray` origin for a
whole-domain program (the RFC's open question 5) is not settled here.

### 5.9 Reference resolution

`build_reference_graph(model, model_name="", index_sets=<none>) -> ReferenceGraph`
and `resolve_references(document) -> {str: ReferenceGraph}`, raising
`ReferenceResolutionError`. All five bindings export both (TypeScript
`buildReferenceGraph` / `resolveReferences`, Go `BuildReferenceGraph` /
`ResolveReferences`). `resolve_references` takes a **loaded** document — the
output of `load_path` / `load_string` / `load_document`, or its JSON view — whose
`expression_template_imports` and `{ref}` mounts are already resolved, because an
imported file's `index_sets` reach the registry only at load (esm-spec §9.7.5) and
a raw file whose `faq` ranges name an imported axis would otherwise report it as
`E_REF_UNDECLARED_INDEX_SET`.

> **The split §8 items 10 and 17 closed.** All five bindings now take the
> document-scoped registry as an optional third argument to
> `build_reference_graph`, and all five name the error
> `ReferenceResolutionError`. Rust keeps
> `build_reference_graph_with_index_sets` and `ReferenceError` as deprecated
> aliases for one minor; they are the old spellings of the same function and
> the same type, not a second capability.

### 5.10 Reactions

`derive_odes(system) -> Model` and `stoichiometric_matrix(system) -> Matrix`
(rows = species, columns = reactions). All five, as of phase 6 — Go exported
neither, so two symbols that four bindings agreed on were `stable` with a hole
in exactly one column, which is the drift §2 and §3 exist to catch.

Rust and Go have an error channel on `derive_odes` (`DeriveError`, `error`).
**TypeScript alone returns a struct** from `stoichiometric_matrix` —
`{matrix, species, reactions}` — so TypeScript is the only binding where the row
and column labels are recoverable.

**Species ORDER is DECLARATION order, in both functions, in all five bindings**
— the order the document writes the `species` object's keys in. It is
observable: it is the ROW order of the stoichiometric matrix and the EQUATION
order of the derived model. Pinned cross-binding by
`tests/conformance/reactions/species_order.json` (README beside it), driven by a
test in each of the five bindings.

It was not harmonized before phase 6b, and nothing in `tests/` asserted it,
which is why five bindings had drifted into three different answers without a
single failure. Measured before the change:

| | `derive_odes` | `stoichiometric_matrix` |
|---|---|---|
| Julia | declaration | declaration |
| Python | declaration | declaration |
| TypeScript | declaration | declaration |
| Rust | declaration | **sorted by name** |
| Go | **sorted by name** | **sorted by name** |

Declaration order was canonical on both counts: it is the majority in both
columns, and it is what this section already said. Two bindings moved.

**The derived equations are one exact tree in all five bindings**, in
`derive_odes` and in `flatten` alike: esm-libraries-spec §4.6.2 fixes operand
order, how each coefficient is written (a loss of 1 is `-1 * rate`, an integral
coefficient an integer literal) and one n-ary `+` per species. Pinned
cross-binding by `tests/conformance/reactions/lowering_form.json`.

**Rust** dropped the sort in `stoichiometric_matrix` (`src/reactions.rs`) and in
its `parallel`-feature twin (`src/performance.rs`, which sorted to stay
consistent with it). The sort's stated justification was "so indices are
reproducible" — but `ReactionSystem.species` is an `IndexMap`, whose key
iteration is already deterministic AND already the authored order, so the sort
bought nothing the container had not already given and cost the agreement with
Rust's own `derive_odes`, which never sorted.

**Go** moved both functions, and this one was not free. `ReactionSystem.Species`
is a `map[string]Species` — a genuinely unordered Go map that has lost
declaration order by the time either function runs — so sorting really was Go's
only deterministic option *at that call site*. It was not Go's only option in
the package: `ESMFile.keyOrders` already records the authored JSON key order of
every object in the document, captured by `LoadString` before the template pass
re-marshals (Go's encoder writes map keys sorted, so the order has to be taken
from the text), and `flatten` has read species order from it all along via
`orderedKeys`. What was missing was a route from a bare `*ReactionSystem` back
to it. `ReactionSystem` now carries an unexported `speciesOrder []string` that
`LoadString` fills from `keyOrders`, and both functions iterate
`orderedKeys(system.Species, system.speciesOrder)`.

The field is unexported and untagged: it widens neither the API surface nor the
wire. `orderedKeys` falls back to sorted-name order for any species the recorded
order does not mention, so the two places with no authored order to prefer — a
`*ReactionSystem` built directly in code, and one reached through a subsystem
mount (held as `any` and decoded on demand) — keep the previous behaviour and
stay deterministic. That is the same fallback `ESMFile.declarationOrder` already
documents.

**A separate defect the new corpus caught on its first run.** TypeScript's
`derive_odes` ignored `constant: true`: a reservoir species was typed `unknown`
and given a `D(s, t) = 0` equation, where esm-spec §7.4 holds it fixed and the
other four bindings lower it to a `parameter` with no ODE. TypeScript's own
`flatten` path already did the right thing, and two of the other bindings'
comments cite TypeScript as doing it. Fixed in `src/reactions.ts`, and pinned by
the reservoir case in the corpus. This is a SEMANTIC divergence, not an ordering
one; it is recorded here because this corpus is what found it.

**Still open, deliberately out of scope of the ordering work:**

1. **The return SHAPE of `stoichiometric_matrix`.** TypeScript returns
   `{matrix, species, reactions}`; the other four return a bare matrix. So
   TypeScript is the only binding in which the row and column labels are
   recoverable at all — which is also why its corpus driver can make a stronger
   assertion than the other four (it compares the row labels directly, where
   they compare the matrix and infer the order from it). Harmonizing this is a
   `stable` return-type change and therefore major-or-aliased under §10.
2. **A non-reservoir species with no net contribution from any reaction.** Rust
   and Go emit no equation for it; TypeScript emits `D(s, t) = 0`. Not exercised
   by the corpus (its only zero-contribution species is also a reservoir) and
   not measured in Julia or Python.

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
| `add_coupling` | function | `add_coupling` | `addCoupling` | `add_coupling` / `add_coupling_to_file` | `add_coupling` | `AddCoupling` |
| `add_equation` | function | `add_equation` | `addEquation` | `add_equation` / `add_equation_to_model` | `add_equation` | `AddEquation` |
| `add_reaction` | function | `add_reaction` | `addReaction` | `add_reaction` / `add_reaction_to_system` | `add_reaction` | `AddReaction` |
| `add_species` | function | `add_species` | `addSpecies` | `add_species` / `add_species_to_system` | `add_species` | `AddSpecies` |
| `add_variable` | function | `add_variable` | `addVariable` | `add_variable` / `add_variable_to_model` | `add_variable` | `AddVariable` |
| `algebraic_unknowns` | function | `algebraic_unknowns` | `algebraicUnknowns` | `algebraic_unknowns` | `algebraic_unknowns` | `AlgebraicUnknowns` |
| `brownian_parameters` | function | `brownian_parameters` | `brownianParameters` | `brownian_parameters` | `brownian_parameters` | `BrownianParameters` |
| `build_reference_graph` | function | `build_reference_graph` | `buildReferenceGraph` | `build_reference_graph` | `build_reference_graph` / `build_reference_graph_with_index_sets` | `BuildReferenceGraph` |
| `can_migrate` | function | `can_migrate` | `canMigrate` | `can_migrate` | `can_migrate` | `CanMigrate` |
| `component_node` | type | `ComponentNode` | `ComponentNode` | `ComponentNode` | `ComponentNode` | `ComponentNode` |
| `constant_parameters` | function | `constant_parameters` | `constantParameters` | `constant_parameters` | `constant_parameters` | `ConstantParameters` |
| `contribution` | type | `Contribution` | `Contribution` | `Contribution` | `Contribution` | `Contribution` |
| `coupling_edge` | type | `CouplingEdge` | `CouplingEdge` | `CouplingEdge` | `CouplingEdge` | `CouplingEdge` |
| `dependency_edge` | type | `DependencyEdge` | `DependencyEdge` | `DependencyEdge` | `DependencyEdge` | `DependencyEdge` |
| `derive_odes` | function | `derive_odes` | `deriveODEs` / `deriveOdes` | `derive_odes` | `derive_odes` | `DeriveODEs` |
| `discrete_parameters` | function | `discrete_parameters` | `discreteParameters` | `discrete_parameters` | `discrete_parameters` | `DiscreteParameters` |
| `enum_lowering_error` | error | `EnumLoweringError` | `EnumLoweringError` | `EnumLoweringError` | `EnumLoweringError` | `EnumLoweringError` |
| `expression_parse_error` | error | `ExpressionParseError` | `ExpressionParseError` | `ExpressionParseError` | `ExpressionParseError` | `ExpressionParseError` |
| `flatten` | function | `flatten` | `flatten` | `flatten` | `flatten` | `Flatten` |
| `flatten_metadata` | type | `FlattenMetadata` | `FlattenMetadata` | `FlattenMetadata` | `FlattenMetadata` | `FlattenMetadata` |
| `flattened_system` | type | `FlattenedSystem` | `FlattenedSystem` | `FlattenedSystem` | `FlattenedSystem` | `FlattenedSystem` |
| `free_variables` | function | `free_variables` | `freeVariables` | `free_variables` | `free_variables` | `FreeVariables` |
| `graph` | type | `Graph` | `Graph` | `Graph` | `Graph` | `Graph` |
| `is_ode_state` | function | `is_ode_state` | `isOdeState` | `is_ode_state` | `is_ode_state` | `IsODEState` |
| `library_version` | constant | `LIBRARY_VERSION` | `LIBRARY_VERSION` | `LIBRARY_VERSION` | `LIBRARY_VERSION` | `LibraryVersion` |
| `load_document` | function | `load_document` | `loadDocument` | `load_document` | `load_document` | `LoadDocument` |
| `load_path` | function | `load_path` | `loadPath` | `load_path` | `load_path` | `LoadPath` |
| `load_string` | function | `load_string` | `loadString` | `load_string` | `load_string` | `LoadString` |
| `lower_enums` | function | `lower_enums` / `lower_enums!` | `lowerEnums` | `lower_enums` | `lower_enums` | `LowerEnums` |
| `migrate` | function | `migrate` | `migrate` | `migrate` | `migrate` | `Migrate` |
| `migration_error` | error | `MigrationError` | `MigrationError` | `MigrationError` | `MigrationError` | `MigrationError` |
| `observed_unknowns` | function | `observed_unknowns` | `observedUnknowns` | `observed_unknowns` | `observed_unknowns` | `ObservedUnknowns` |
| `ode_states` | function | `ode_states` | `odeStates` | `ode_states` | `ode_states` | `ODEStates` |
| `parse_equation` | function | `parse_equation` | `parseEquation` | `parse_equation` | `parse_equation` | `ParseEquation` |
| `parse_expression` | function | `parse_expression` | `parseExpression` | `parse_expression` | `parse_expression` | `ParseExpression` |
| `reference_edge` | type | `ReferenceEdge` | `ReferenceEdge` | `ReferenceEdge` | `ReferenceEdge` | `ReferenceEdge` |
| `reference_graph` | type | `ReferenceGraph` | `ReferenceGraph` | `ReferenceGraph` | `ReferenceGraph` | `ReferenceGraph` |
| `reference_resolution_error` | error | `ReferenceResolutionError` | `ReferenceResolutionError` | `ReferenceResolutionError` | `ReferenceError` / `ReferenceResolutionError` | `ReferenceResolutionError` |
| `reference_vertex` | type | `ReferenceVertex` | `ReferenceVertex` | `ReferenceVertex` | `ReferenceVertex` | `ReferenceVertex` |
| `reject_solver_external_pre_v13` | function | `reject_solver_external_pre_v13` | `rejectSolverExternalPreV13` | `reject_solver_external_pre_v13` | `reject_solver_external_pre_v13` | `RejectSolverExternalPreV13` |
| `reject_solver_pre_v11` | function | `reject_solver_pre_v11` | `rejectSolverPreV11` | `reject_solver_pre_v11` | `reject_solver_pre_v11` | `RejectSolverPreV11` |
| `reject_solver_time_span_pre_v13` | function | `reject_solver_time_span_pre_v13` | `rejectSolverTimeSpanPreV13` | `reject_solver_time_span_pre_v13` | `reject_solver_time_span_pre_v13` | `RejectSolverTimeSpanPreV13` |
| `reject_template_imports_pre_v08` | function | `reject_template_imports_pre_v08` | `rejectTemplateImportsPreV08` | `reject_template_imports_pre_v08` | `reject_template_imports_pre_v08` | `RejectTemplateImportsPreV08` |
| `remove_coupling` | function | `remove_coupling` | `removeCoupling` | `remove_coupling` / `remove_coupling_from_file` | `remove_coupling` | `RemoveCoupling` |
| `remove_reaction` | function | `remove_reaction` | `removeReaction` | `remove_reaction` / `remove_reaction_from_system` | `remove_reaction` | `RemoveReaction` |
| `remove_species` | function | `remove_species` | `removeSpecies` | `remove_species` / `remove_species_from_system` | `remove_species` | `RemoveSpecies` |
| `remove_variable` | function | `remove_variable` | `removeVariable` | `remove_variable` / `remove_variable_from_model` | `remove_variable` | `RemoveVariable` |
| `resolve_references` | function | `resolve_references` | `resolveReferences` | `resolve_references` | `resolve_references` | `ResolveReferences` |
| `resolve_subsystem_refs` | function | `resolve_subsystem_refs!` | `resolveSubsystemRefs` | `resolve_subsystem_refs` | `resolve_subsystem_refs` | `ResolveSubsystemRefs` |
| `resolve_time_span` | function | `resolve_time_span` | `resolveTimeSpan` | `resolve_time_span` | `resolve_time_span` | `ResolveTimeSpan` |
| `sampled_parameters` | function | `sampled_parameters` | `sampledParameters` | `sampled_parameters` | `sampled_parameters` | `SampledParameters` |
| `schema_version` | constant | `SCHEMA_VERSION` | `SCHEMA_VERSION` | `SCHEMA_VERSION` | `SCHEMA_VERSION` | `SchemaVersion` |
| `simplify` | function | `simplify` | `simplify` | `simplify` | `simplify` | `Simplify` |
| `solver_external_location` | function | `solver_external_location` | `solverExternalLocation` | `solver_external_location` | `solver_external_location` | `SolverExternalLocation` |
| `stoichiometric_matrix` | function | `stoichiometric_matrix` | `stoichiometricMatrix` | `stoichiometric_matrix` | `stoichiometric_matrix` | `StoichiometricMatrix` |
| `substitute` | function | `substitute` | `substitute` | `substitute` | `substitute` | `Substitute` |
| `supported_migration_targets` | function | `supported_migration_targets` | `getSupportedMigrationTargets` / `supportedMigrationTargets` | `supported_migration_targets` | `get_supported_migration_targets` / `supported_migration_targets` | `SupportedMigrationTargets` |
| `system_kind` | function | `system_kind` | `systemKind` | `system_kind` | `system_kind` | `SystemKind` |
| `term_origin` | type | `TermOrigin` | `TermOrigin` | `TermOrigin` | `TermOrigin` | `TermOrigin` |
| `to_ascii` | function | `to_ascii` | `toAscii` | `to_ascii` | `to_ascii` | `ToASCII` |
| `to_dot` | function | `to_dot` | `toDot` | `to_dot` | `to_dot` | `ToDOT` |
| `to_json` | function | `to_json` | `toJson` | `to_json` | `to_json` | `ToJSON` |
| `to_json_compact` | function | `to_json_compact` | `toJsonCompact` | `to_json_compact` | `to_json_compact` | `ToJSONCompact` |
| `to_json_graph` | function | `to_json_graph` | `toJsonGraph` | `to_json_graph` | `to_json_graph` | `ToJSONGraph` |
| `to_latex` | function | `to_latex` | `toLatex` | `to_latex` | `to_latex` | `ToLatex` |
| `to_mermaid` | function | `to_mermaid` | `toMermaid` | `to_mermaid` | `to_mermaid` | `ToMermaid` |
| `to_unicode` | function | `to_unicode` | `toUnicode` | `to_unicode` | `to_unicode` | `ToUnicode` |
| `unit_warning` | type | `UnitWarning` | `UnitWarning` | `UnitWarning` | `UnitWarning` | `UnitWarning` |
| `validate` | function | `validate` | `validate` | `validate` | `validate` | `Validate` |
| `validate_text` | function | `validate_text` | `validateText` | `validate_text` | `validate_complete` / `validate_text` | `ValidateText` |
| `validation_result` | type | `ValidationResult` | `ValidationResult` | `ValidationResult` | `ValidationResult` | `ValidationResult` |
| `variable_node` | type | `VariableNode` | `VariableNode` | `VariableNode` | `VariableNode` | `VariableNode` |
| `write_path` | function | `write_path` | `writePath` | `write_path` | `write_path` | `WritePath` |

#### Exported by four of the five

| Canonical | Kind | Julia | TS | Python | Rust | Go |
|---|---|---|---|---|---|---|
| `add_continuous_event` | function | `add_continuous_event` | `addContinuousEvent` | `add_continuous_event` / `add_continuous_event_to_model` | – | `AddContinuousEvent` |
| `add_discrete_event` | function | `add_discrete_event` | `addDiscreteEvent` | `add_discrete_event` / `add_discrete_event_to_model` | – | `AddDiscreteEvent` |
| `affect_equation` | type | `AffectEquation` | – | `AffectEquation` | `AffectEquation` | `AffectEquation` |
| `canonical_json` | function | `canonical_json` | `canonicalJson` | – | `canonical_json` | `CanonicalJSON` |
| `canonicalize` | function | `canonicalize` | `canonicalize` | – | `canonicalize` | `Canonicalize` |
| `closed_function_error` | error | `ClosedFunctionError` | `ClosedFunctionError` | – | `ClosedFunctionError` | `ClosedFunctionError` |
| `closed_function_names` | function | `closed_function_names` | `closedFunctionNames` | – | `closed_function_names` | `ClosedFunctionNames` |
| `component_graph` | function | `component_graph` | `componentGraph` | `component_graph` | `component_graph` | – |
| `compose` | function | `compose` | `compose` | – | `compose` | `Compose` |
| `conflicting_derivative_error` | error | `ConflictingDerivativeError` | `ConflictingDerivativeError` | `ConflictingDerivativeError` | – | `ConflictingDerivativeError` |
| `contains` | function | – | `contains` | `contains` | `contains` | `Contains` |
| `continuous_event` | type | `ContinuousEvent` | – | `ContinuousEvent` | `ContinuousEvent` | `ContinuousEvent` |
| `coupling_entry` | type | `CouplingEntry` | – | `CouplingEntry` | `CouplingEntry` | `CouplingEntry` |
| `data_source` | type | `DataSource` | – | `DataSource` | `DataSource` | `DataSource` |
| `data_source_binding` | type | `DataSourceBinding` | – | `DataSourceBinding` | `DataSourceBinding` | `DataSourceBinding` |
| `data_source_determinism` | type | `DataSourceDeterminism` | – | `DataSourceDeterminism` | `DataSourceDeterminism` | `DataSourceDeterminism` |
| `data_source_location` | type | `DataSourceLocation` | – | `DataSourceLocation` | `DataSourceLocation` | `DataSourceLocation` |
| `data_source_temporal` | type | `DataSourceTemporal` | – | `DataSourceTemporal` | `DataSourceTemporal` | `DataSourceTemporal` |
| `declared_system_kind` | function | `declared_system_kind` | `declaredSystemKind` | `declared_system_kind` | – | `DeclaredSystemKind` |
| `dimension_promotion_error` | error | `DimensionPromotionError` | `DimensionPromotionError` | `DimensionPromotionError` | – | `DimensionPromotionError` |
| `discrete_event` | type | `DiscreteEvent` | – | `DiscreteEvent` | `DiscreteEvent` | `DiscreteEvent` |
| `discrete_event_trigger` | type | `DiscreteEventTrigger` | – | `DiscreteEventTrigger` | `DiscreteEventTrigger` | `DiscreteEventTrigger` |
| `distribution` | type | `Distribution` | – | `Distribution` | `Distribution` | `Distribution` |
| `domain` | type | `Domain` | – | `Domain` | `Domain` | `Domain` |
| `edge_kind` | type | – | `EdgeKind` | `EdgeKind` | `EdgeKind` | `EdgeKind` |
| `effective_system_kind` | function | `effective_system_kind` | `effectiveSystemKind` | `effective_system_kind` | – | `EffectiveSystemKind` |
| `equation` | type | `Equation` | – | `Equation` | `Equation` | `Equation` |
| `error_codes` | constant | `ERROR_CODES` | `ERROR_CODES` | `ERROR_CODES` | `ERROR_CODES` | – |
| `esm_file` | type | `EsmFile` | – | `EsmFile` | `EsmFile` | `ESMFile` |
| `expand_coupling_imports` | function | `expand_coupling_imports` | `expandCouplingImports` | `expand_coupling_imports` | `expand_coupling_imports` | – |
| `expression_graph` | function | `expression_graph` | `expressionGraph` | `expression_graph` | `expression_graph` | – |
| `expression_template_error` | error | `ExpressionTemplateError` | `ExpressionTemplateError` | `ExpressionTemplateError` | – | `ExpressionTemplateError` |
| `extract` | function | `extract` | `extract` | `extract` / `extract_component_from_file` | – | `Extract` |
| `functional_update` | type | `FunctionalUpdate` | – | `FunctionalUpdate` | `FunctionalUpdate` | `FunctionalUpdate` |
| `loader_field` | type | – | `LoaderField` | `LoaderField` | `LoaderField` | `LoaderField` |
| `lower_expression_templates` | function | `lower_expression_templates` | `lowerExpressionTemplates` | `lower_expression_templates` | – | `LowerExpressionTemplates` |
| `metadata` | type | `Metadata` | – | `Metadata` | `Metadata` | `Metadata` |
| `model` | type | `Model` | – | `Model` | `Model` | `Model` |
| `model_variable` | type | `ModelVariable` | – | `ModelVariable` | `ModelVariable` | `ModelVariable` |
| `observed_definitions` | function | `observed_definitions` | `observedDefinitions` | `observed_definitions` | `observed_definitions` | – |
| `operator_compose_ambiguous_bare_name_error` | error | `OperatorComposeAmbiguousBareNameError` | `OperatorComposeAmbiguousBareNameError` | `OperatorComposeAmbiguousBareNameError` | – | `OperatorComposeAmbiguousBareNameError` |
| `operator_compose_no_merge_error` | error | `OperatorComposeNoMergeError` | `OperatorComposeNoMergeError` | `OperatorComposeNoMergeError` | – | `OperatorComposeNoMergeError` |
| `operator_compose_require_match_error` | error | `OperatorComposeRequireMatchError` | `OperatorComposeRequireMatchError` | `OperatorComposeRequireMatchError` | – | `OperatorComposeRequireMatchError` |
| `parameter_update` | type | `ParameterUpdate` | – | `ParameterUpdate` | `ParameterUpdate` | `ParameterUpdate` |
| `reaction` | type | `Reaction` | – | `Reaction` | `Reaction` | `Reaction` |
| `reaction_system` | type | `ReactionSystem` | – | `ReactionSystem` | `ReactionSystem` | `ReactionSystem` |
| `reject_expression_templates_pre_v04` | function | `reject_expression_templates_pre_v04` | `rejectExpressionTemplatesPreV04` | `reject_expression_templates_pre_v04` | – | `RejectExpressionTemplatesPreV04` |
| `remove_equation` | function | `remove_equation` | `removeEquation` | `remove_equation` / `remove_equation_from_model` | `remove_equation` | – |
| `remove_event` | function | `remove_event` | `removeEvent` | `remove_event` / `remove_event_from_model` | – | `RemoveEvent` |
| `rename_variable` | function | `rename_variable` | `renameVariable` | `rename_variable` / `rename_variable_in_model` | – | `RenameVariable` |
| `resolve_template_machinery` | function | `resolve_template_machinery` | `resolveTemplateMachinery` | `resolve_template_machinery` | `resolve_template_machinery` | – |
| `resolve_tolerances` | function | `resolve_tolerances` | `resolveTolerances` | `resolve_tolerances` | `resolve_tolerances` | – |
| `solver` | type | `Solver` | – | `Solver` | `Solver` | `Solver` |
| `solver_time_span` | type | `SolverTimeSpan` | – | `SolverTimeSpan` | `SolverTimeSpan` | `SolverTimeSpan` |
| `species` | type | `Species` | – | `Species` | `Species` | `Species` |
| `substitute_in_model` | function | – | `substituteInModel` | `substitute_in_model` | `substitute_in_model` | `SubstituteInModel` |
| `substitute_in_reaction_system` | function | – | `substituteInReactionSystem` | `substitute_in_reaction_system` | `substitute_in_reaction_system` | `SubstituteInReactionSystem` |
| `unit_finding_dimensionless_literal` | constant | `UNIT_FINDING_DIMENSIONLESS_LITERAL` | – | `UNIT_FINDING_DIMENSIONLESS_LITERAL` | `UNIT_FINDING_DIMENSIONLESS_LITERAL` | `UnitFindingDimensionlessLiteral` |
| `vertex_kind` | type | – | `VertexKind` | `VertexKind` | `VertexKind` | `VertexKind` |

#### Exported by three of the five

| Canonical | Kind | Julia | TS | Python | Rust | Go |
|---|---|---|---|---|---|---|
| `cadence_error` | error | – | – | `CadenceError` | `CadenceError` | `CadenceError` |
| `callbacks` | function | `callbacks` | – | `callbacks` | `callbacks` | – |
| `canonicalize_error` | error | `CanonicalizeError` | `CanonicalizeError` | – | `CanonicalizeError` | – |
| `compiler_report` | type | `CompilerReport` | – | `CompilerReport` | `CompilerReport` | – |
| `component_exists` | function | – | `componentExists` | `component_exists` | `component_exists` | – |
| `component_graph` | type | – | `ComponentGraph` | – | `ComponentGraph` | `ComponentGraph` |
| `convert_units` | function | – | `convertUnits` | `convert_units` | `convert_units` | – |
| `couple_multiplicative_no_tendency_error` | error | – | `CoupleMultiplicativeNoTendencyError` | `CoupleMultiplicativeNoTendencyError` | – | `CoupleMultiplicativeNoTendencyError` |
| `coupling_import` | type | `CouplingImport` | – | `CouplingImport` | – | `CouplingImport` |
| `coupling_import_options` | type | – | `CouplingImportOptions` | – | `CouplingImportOptions` | `CouplingImportOptions` |
| `domain_unit_mismatch_error` | error | `DomainUnitMismatchError` | `DomainUnitMismatchError` | `DomainUnitMismatchError` | – | – |
| `edit_error` | error | `EditError` | – | – | `EditError` | `EditError` |
| `esm_problem` | function | `esm_problem` | – | `esm_problem` | `esm_problem` | – |
| `esm_problem` | type | `EsmProblem` | – | `EsmProblem` | `EsmProblem` | – |
| `evaluate` | function | – | – | `evaluate` | `evaluate` | `Evaluate` |
| `evaluate_closed_function` | function | `evaluate_closed_function` | – | – | `evaluate_closed_function` | `EvaluateClosedFunction` |
| `flatten_error` | error | – | `FlattenError` | `FlattenError` | `FlattenError` | – |
| `flattened_equation` | type | – | `FlattenedEquation` | `FlattenedEquation` | – | `FlattenedEquation` |
| `flattened_variable` | type | – | `FlattenedVariable` | `FlattenedVariable` | – | `FlattenedVariable` |
| `format_canonical_float` | function | `format_canonical_float` | `formatCanonicalFloat` | – | `format_canonical_float` | – |
| `free_parameters` | function | – | `freeParameters` | `free_parameters` | `free_parameters` | – |
| `function_table` | type | `FunctionTable` | – | `FunctionTable` | – | `FunctionTable` |
| `function_table_axis` | type | `FunctionTableAxis` | – | `FunctionTableAxis` | – | `FunctionTableAxis` |
| `is_coupling_library_doc` | function | – | `isCouplingLibraryDoc` | `is_coupling_library_doc` | `is_coupling_library_doc` | – |
| `lower_enums_mut` | function | – | – | `lower_enums_mut` | `lower_enums_mut` | `LowerEnumsMut` |
| `map_variable` | function | `map_variable` | `mapVariable` | – | – | `MapVariable` |
| `max_template_expansion_depth` | constant | – | `MAX_TEMPLATE_EXPANSION_DEPTH` | `MAX_TEMPLATE_EXPANSION_DEPTH` | – | `MaxTemplateExpansionDepth` |
| `merge` | function | – | `merge` | `merge` / `merge_esm_files` | – | `Merge` |
| `observed_field` | function | `observed_field` | – | `observed_field` | `observed_field` | – |
| `parameter` | type | `Parameter` | – | `Parameter` | – | `Parameter` |
| `parse_unit` | function | – | `parseUnit` | – | `parse_unit` | `ParseUnit` |
| `reference` | type | `Reference` | – | `Reference` | – | `Reference` |
| `rhs_program` | function | `rhs_program` | – | `rhs_program` | `rhs_program` | – |
| `schema_validation_error` | error | `SchemaValidationError` | `SchemaValidationError` | `SchemaValidationError` | – | – |
| `substitute_in_equations` | function | `substitute_in_equations` | `substituteInEquations` | – | – | `SubstituteInEquations` |
| `time_origin` | function | `time_origin` | – | `time_origin` | `time_origin` | – |
| `timestamp_to_seconds` | function | `timestamp_to_seconds` | – | `timestamp_to_seconds` | `timestamp_to_seconds` | – |
| `unit_conversion_error` | error | `UnitConversionError` | `UnitConversionError` | `UnitConversionError` | – | – |
| `unit_finding` | type | `UnitFinding` | – | `UnitFinding` | `UnitFinding` | – |
| `unit_finding_analysis` | constant | – | – | `UNIT_FINDING_ANALYSIS` | `UNIT_FINDING_ANALYSIS` | `UnitFindingAnalysis` |
| `unit_finding_dimensional_mismatch` | constant | – | – | `UNIT_FINDING_DIMENSIONAL_MISMATCH` | `UNIT_FINDING_DIMENSIONAL_MISMATCH` | `UnitFindingDimensionalMismatch` |
| `unit_finding_unparseable` | constant | – | – | `UNIT_FINDING_UNPARSEABLE` | `UNIT_FINDING_UNPARSEABLE` | `UnitFindingUnparseable` |
| `unknowns` | function | `unknown_names` / `unknowns` | `unknowns` | `unknowns` | – | – |
| `validate_equation_dimensions` | function | `validate_equation_dimensions` | – | – | `validate_equation_dimensions` | `ValidateEquationDimensions` |

#### Exported by two of the five

| Canonical | Kind | Julia | TS | Python | Rust | Go |
|---|---|---|---|---|---|---|
| `apply_dae_contract` | function | – | – | – | `apply_dae_contract` | `ApplyDAEContract` |
| `apply_scope_injections` | function | – | `applyScopeInjections` | – | `apply_scope_injections` | – |
| `apply_unit_conversion` | function | `apply_unit_conversion` / `apply_unit_conversion!` | – | `apply_unit_conversion` | – | – |
| `area_tolerance_ok` | function | – | – | `area_tolerance_ok` | `area_tolerance_ok` | – |
| `assertion_result` | type | `AssertionResult` | – | – | `AssertionResult` | – |
| `build_unit_env` | function | – | – | – | `build_unit_env` | `BuildUnitEnv` |
| `cadence` | type | – | – | – | `Cadence` | `Cadence` |
| `callback_set` | type | – | – | `CallbackSet` | `CallbackSet` | – |
| `canonical_index_set_json` | function | – | – | `canonical_index_set_json` | `canonical_index_set_json` | – |
| `circular_reference_error` | error | – | `CircularReferenceError` | `CircularReferenceError` | – | – |
| `compiler` | type | – | – | `Compiler` | `Compiler` | – |
| `coordinate` | type | – | – | – | `Coordinate` | `Coordinate` |
| `coupling_couple` | type | `CouplingCouple` | – | – | – | `CouplingCouple` |
| `coupling_role` | type | – | – | – | `CouplingRole` | `CouplingRole` |
| `cyclic_promotion_error` | error | `CyclicPromotionError` | – | `CyclicPromotionError` | – | – |
| `dae_info` | type | – | – | – | `DaeInfo` | `DAEInfo` |
| `data_source_kind` | type | – | – | `DataSourceKind` | `DataSourceKind` | – |
| `decomposition` | type | `Decomposition` | – | – | `Decomposition` | – |
| `default_abstol` | constant | – | `DEFAULT_ABSTOL` | – | `DEFAULT_ABSTOL` | – |
| `default_forcing_set` | function | `default_forcing_set` | – | `default_forcing_set` | – | – |
| `default_reltol` | constant | – | `DEFAULT_RELTOL` | – | `DEFAULT_RELTOL` | – |
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
| `ensemble_problem` | type | – | – | `EnsembleProblem` | `EnsembleProblem` | – |
| `entity_not_found_error` | error | – | `EntityNotFoundError` | – | – | `EntityNotFoundError` |
| `ephemeral_injected_file` | function | – | `ephemeralInjectedFile` | – | `ephemeral_injected_file` | – |
| `error_code_names` | function | `error_code_names` | – | – | `error_code_names` | – |
| `evaluate_cellwise` | function | `evaluate_cellwise` | – | – | `evaluate_cellwise` | – |
| `exact_scale` | type | – | – | – | `ExactScale` | `ExactScale` |
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
| `forcing_set` | function | `forcing_set` | – | `forcing_set` | – | – |
| `forcing_set` | type | `ForcingSet` | – | – | `ForcingSet` | – |
| `forcing_slot` | type | `ForcingSlot` | – | – | `ForcingSlot` | – |
| `geometry_error` | error | – | – | `GeometryError` | `GeometryError` | – |
| `get_component_type` | function | – | `getComponentType` | – | `get_component_type` | – |
| `graph_edge` | type | – | – | `GraphEdge` | – | `GraphEdge` |
| `grid_plan` | type | `GridPlan` | – | – | `GridPlan` | – |
| `group_aggregate` | function | – | – | `group_aggregate` | `group_aggregate` | – |
| `group_gridding_by_grid` | function | `group_gridding_by_grid` | – | – | `group_gridding_by_grid` | – |
| `halo` | function | `halo` | – | `halo` | – | – |
| `init` | function | – | – | `init` | `init` | – |
| `inline_test_options` | type | `InlineTestOptions` | – | – | `InlineTestOptions` | – |
| `integrator` | type | – | – | `Integrator` | `Integrator` | – |
| `intersect_polygon` | function | – | – | `intersect_polygon` | `intersect_polygon` | – |
| `is_template_library_doc` | function | – | `isTemplateLibraryDoc` | – | `is_template_library_doc` | – |
| `lanes` | function | `lanes` | – | `lanes` | – | – |
| `load_options` | type | – | `LoadOptions` | – | `LoadOptions` | – |
| `lower_reactions_to_equations` | function | `lower_reactions_to_equations` | – | – | `lower_reactions_to_equations` | – |
| `materialize_value_invention` | function | – | – | `materialize_value_invention` | `materialize_value_invention` | – |
| `observed_definition` | function | `observed_definition` | – | – | – | `ObservedDefinition` |
| `operator` | type | – | – | `Operator` | `Operator` | – |
| `output_error` | error | `OutputError` | – | – | `OutputError` | – |
| `output_meta` | type | `OutputMeta` | – | – | `OutputMeta` | – |
| `output_plan` | type | `OutputPlan` | – | – | `OutputPlan` | – |
| `param_slot` | type | `ParamSlot` | – | – | `ParamSlot` | – |
| `parameter_sweep` | type | – | – | – | `ParameterSweep` | `ParameterSweep` |
| `parameters` | function | `parameter_names` / `parameters` | `parameters` | – | – | – |
| `parse_error` | error | `ParseError` | `ParseError` | – | – | – |
| `parse_unit_conversion` | function | `parse_unit_conversion` | – | `parse_unit_conversion` | – | – |
| `partition` | type | – | – | `Partition` | `Partition` | – |
| `plan_dimension_coordinates` | function | `plan_dimension_coordinates` | – | – | `plan_dimension_coordinates` | – |
| `plot` | type | – | – | – | `Plot` | `Plot` |
| `plot_axis` | type | – | – | – | `PlotAxis` | `PlotAxis` |
| `plot_series` | type | – | – | – | `PlotSeries` | `PlotSeries` |
| `plot_value` | type | – | – | – | `PlotValue` | `PlotValue` |
| `polygon_area` | function | – | – | `polygon_area` | `polygon_area` | – |
| `product_matrix` | function | – | `productMatrix` | `product_matrix` | – | – |
| `rank` | function | – | – | `rank` | `rank` | – |
| `ranking` | type | – | – | `Ranking` | `Ranking` | – |
| `remake` | function | – | – | `remake` | `remake` | – |
| `restrict` | function | `restrict` | – | `restrict` | – | – |
| `return_code` | type | – | – | `ReturnCode` | `ReturnCode` | – |
| `run_inline_tests` | function | `run_inline_tests` | – | – | `run_inline_tests` | – |
| `schema_error` | error | – | – | – | `SchemaError` | `SchemaError` |
| `schema_error` | type | `SchemaError` | `SchemaError` | – | – | – |
| `select` | function | `select` | – | `select` | – | – |
| `simulate_error` | error | `SimulateError` | – | – | `SimulateError` | – |
| `skolem` | function | – | – | `skolem` | `skolem` | – |
| `skolem_edge` | function | – | – | `skolem_edge` | `skolem_edge` | – |
| `slice_out_of_domain_error` | error | `SliceOutOfDomainError` | – | `SliceOutOfDomainError` | – | – |
| `solution` | type | – | – | `Solution` | `Solution` | – |
| `solve` | function | – | – | `solve` | `solve` | – |
| `state_block` | type | `StateBlock` | – | – | `StateBlock` | – |
| `step` | function | – | – | `step` | `step` | – |
| `structural_error` | error | – | – | – | `StructuralError` | `StructuralError` |
| `substitute_in_model_with_context` | function | – | – | – | `substitute_in_model_with_context` | `SubstituteInModelWithContext` |
| `substitute_in_reaction_system_with_context` | function | – | – | – | `substitute_in_reaction_system_with_context` | `SubstituteInReactionSystemWithContext` |
| `substitute_with_context` | function | – | – | – | `substitute_with_context` | `SubstituteWithContext` |
| `substrate_matrix` | function | – | `substrateMatrix` | `substrate_matrix` | – | – |
| `subsystem_ref_error` | error | `SubsystemRefError` | – | `SubsystemRefError` | – | – |
| `sweep_dimension` | type | – | – | – | `SweepDimension` | `SweepDimension` |
| `sweep_range` | type | – | – | – | `SweepRange` | `SweepRange` |
| `system_kind` | type | – | `SystemKind` | – | `SystemKind` | – |
| `temporal_domain` | type | – | – | `TemporalDomain` | – | `TemporalDomain` |
| `time_point` | type | – | – | – | `TimePoint` | `TimePoint` |
| `time_span` | type | – | – | – | `TimeSpan` | `TimeSpan` |
| `to_julia_code` | function | `to_julia_code` | – | `to_julia_code` | – | – |
| `tolerance` | type | – | – | – | `Tolerance` | `Tolerance` |
| `unit` | type | – | – | – | `Unit` | `Unit` |
| `unmapped_domain_error` | error | `UnmappedDomainError` | – | `UnmappedDomainError` | – | – |
| `unsupported_mapping_error` | error | `UnsupportedMappingError` | – | `UnsupportedMappingError` | – | – |
| `validate_path` | function | `validate_path` | – | `validate_path` | – | – |
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

<!-- END GENERATED: stable-surface -->

---

## 7. Extension seams

641 symbols. They are enumerated in `api-surface.json` with
`"tier": "extension"`; this section says what the families are and why each is
allowed to differ.

| Family | Bindings | Why it is a seam |
|---|---|---|
| Julia build/inspection | Julia | `BuildInspection` exposes the tree-walk evaluator's internals so downstream analysers (EarthSciASTDiff) can differentiate the expanded tree. There is no cross-language analogue to harmonize against. `build_evaluator` is deprecated and leaves the surface at its removal (§8 item 23); `BuildInspection` remains because `esm_problem`'s `inspect` keyword takes one, and the compiler half of what it carried is `compiler_report`, which both an `EsmProblem` and a `BuildInspection` answer. |
| Julia forcing buffers | Julia | The compiled program's argument ABI, now read off an `EsmProblem` (`forcing_buffers(prob)`) rather than off an out-of-place build product. Its shape is dictated by the compiled program's argument arrays and will change with the emitter. |
| Julia MTK/Catalyst export | Julia | `mtk2esm`, `mtk2esm_gaps`, `GapReport` — migration tooling for one host ecosystem. |
| Rust `intern` / `performance` | Rust | Hash-consing and allocator knobs. Feature-gated (`parallel`, `custom_alloc`) and performance-shaped, not semantics-shaped. |
| Rust `simulate_array` | Rust | The native-only spatial/PDE backend. Its surface tracks the backend, not the format. |
| Runtime I/O | Julia, Python, Rust | Providers, refresh callbacks, sinks, checkpoints. The concrete implementations live in EarthSciIO; these are the protocol the host binds to. |
| Go diagnostic codes | Go | The `Code*` / `Error*` / `Role*` / `SystemKind*` constants. Their *values* are conformance-pinned by the shared fixture corpus; their Go *identifiers* are not. |
| TypeScript analysis | TypeScript | The complexity/CSE/differentiation toolkit under `src/analysis/`. A TypeScript-only authoring aid. |

Go carries the largest extension surface, most of it the diagnostic-code
constants.

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
| 3 | `abstol` / `reltol` / `saveat` / `alg` | Python uses scipy's `rtol`/`atol`/`method`; Rust's `SimulateOptions` uses `solver`/`output_times`. Rust's default tolerances are 4 orders looser than the other two. | Subsumed by the phase-4 simulation reshape: the option names come along with `simulate` being deleted and `Problem`/`solve` replacing it. SciML spelling everywhere (§4). The default VALUES are a separate, still-open decision — the premise that Julia and Python already agreed on `1e-10`/`1e-14` was a misreading; all three differ. See the correction of record in §5.8. **CLOSED (phase 6).** The default VALUES were ruled by the user during phase 4: Julia's `reltol = 1e-4` / `abstol = 1e-6` are canonical in every binding, and §5.8 carries the table. Nothing is open on this row. | Python, Rust |
| 4 | `closed_function_names` | A function in Julia, Rust and Go; a **constant array** `CLOSED_FUNCTION_NAMES` in TypeScript. | **DONE (phase 6).** TypeScript exports `closedFunctionNames()`; `CLOSED_FUNCTION_NAMES` is a deprecated alias for one minor, returned by identity so the two are the same array. The two spellings are different KINDS, so the manifest carries them as two entries (`function` 4/5 `stable`, `constant` TypeScript-only `extension`) rather than one alias pair. | TypeScript |
| 5 | `derive_odes` | TypeScript spells it `deriveODEs`, violating §2 — and is internally inconsistent, since it already spells the siblings `odeStates` and `isOdeState`. | **DONE (phase 6).** Renamed to `deriveOdes`; `deriveODEs` stays a deprecated alias for one minor (§10) and is the same function object. | TypeScript |
| 6 | `unknowns` / `parameters` | TypeScript and Python export `unknowns`/`parameters`; Julia exports `unknown_names`/`parameter_names` for the same query. | Canonical is `unknowns`/`parameters`. Julia keeps its `*_names` spellings as aliases — the bare names collide badly in Julia's flat namespace. **DONE (phase 6).** Julia gained `unknowns` / `parameters`; `unknown_names` / `parameter_names` stay as aliases. The collision was MEASURED, not assumed — with `using EarthSciAST, ModelingToolkit, Catalyst`, a bare `unknowns(m)` raises an ambiguity error, which is why both spellings stay. | Julia |
| 7 | edit operations | Python suffixes every edit with its container: `add_variable_to_model`, `remove_coupling_from_file`, `extract_component_from_file`, `merge_esm_files`. Julia, TypeScript and Rust use the bare verb. | Python gains the bare names; the suffixed ones become aliases. **DONE (phase 6).** Python gained all 16 bare names (the sample in the Problem column was not the whole set); every suffixed name survives as a deprecated alias emitting `DeprecationWarning`. None of the 16 bare names collided. | Python |
| 8 | `to_dot` / `to_mermaid` / `to_json` | Julia and TypeScript export three rendering functions (TypeScript spells the third `toJsonGraph`); Go spells the same renderings as **six** functions, `ExportComponentGraphDOT` … `ExportExpressionGraphMermaid`. | **Ruled (phase 6).** `to_json` is the *document* serializer (item 2); it cannot also be the graph renderer in the four bindings without overloading. Canonical trio is `to_dot(graph)` / `to_mermaid(graph)` / `to_json_graph(graph)` — the spelling TypeScript and Python already share. Go's six `Export*` functions collapse to `ToDOT` / `ToMermaid` / `ToJSONGraph`, each taking an exported `Graph` interface that `*ComponentGraph` and `*ExpressionGraph` satisfy via an unexported marker method. Rust adds all three. **TypeScript VERIFIED (phase 6):** `toDot` / `toMermaid` / `toJsonGraph` are already generic over `Graph<N, E>` and dispatch on the graph kind (`Graph.kind` when tagged, else sniffed from the first node), and `tests/conformance/graph/cases.json` exercises all three against BOTH the component and expression graph of every corpus document. No rename needed. | TypeScript, Go |
| 9 | `substitute_with_context` | Rust names the scoped-substitution family `*_with_context` (`ScopedContext`); Go names it `*WithScoped`. | Canonical `substitute_with_context`; Go renames. **DONE (phase 6).** Go's four exported `*WithScoped` functions and its one unexported helper are now `*WithContext`. | Go |
| 10 | `reference_resolution_error` | Julia and Python raise `ReferenceResolutionError`; Rust's is `ReferenceError`. | Rust renames, keeping a type alias for one minor. **DONE (phase 6).** Rust renamed; `ReferenceError` kept as a `#[deprecated]` type alias for one minor. | Rust |
| 11 | `system_kind` family | `system_kind` is a function everywhere but takes an extra `domain` in Go; `declared_system_kind` exists in TypeScript and Python; `declared_system_kind_mismatch` only in Julia; `EffectiveSystemKind` only in Go. Three overlapping two-binding subsets. | **Ruled (phase 6).** The four spellings are three distinct questions plus one composition. `system_kind(model)` is the *derived* kind — Go drops the `domain` argument, which both Go bodies already ignore. `declared_system_kind(model)` reads the explicit field, nullable. `effective_system_kind(model)` is `declared ?? derived` — the question a caller choosing a solver actually asks. All three become `stable` in all five. Julia's `declared_system_kind_mismatch` is **deleted**: it is one line over the other two, and the only 1-of-5 member of the family. **TypeScript DONE (phase 6):** `effectiveSystemKind(model)` added alongside the existing `systemKind` / `declaredSystemKind`. | Julia, TS, Python, Go |
| 12 | `validate` return shape | Go's `Validate` returns the legacy `DetailedValidationResult`; the four-field shape everyone else returns is Go's *other* function, `ValidateFile`. | Go's `Validate` returns the four-field `ValidationResult`; `ValidateFile` folds into it. **DONE (phase 6).** Go's `Validate` returns the four-field `ValidationResult`; `ValidateFile` folded in. `SchemaErrors` is always empty, because a `*ESMFile` can only exist by having passed the schema at load — matching Rust's documented behaviour. | Go |
| 13 | `validate` input type | Rust and Go accept only a typed document; Julia also accepts a path; Python accepts path/text/dict/document; TypeScript accepts text/object. | `validate(file)` takes a typed document everywhere. Path and text convenience become `validate_path` / `validate_text`. **TypeScript DONE (phase 6):** `validate(document)` is typed (and throws a `TypeError` naming `validateText` if handed a string at runtime, since a JS caller has no compiler to stop them); `validateText(text)` added. TypeScript deliberately has **no** `validatePath`: `@earthsciml/ast` targets the browser as well as Node and exposes no synchronous filesystem read, so a `validatePath` here would be a Node-only stub that breaks the bundle. A caller reads the file and calls `validateText(text, { basePath })`. **CLOSED (phase 6b): Julia gained `validate_text(text; base_path)`, so the symbol is 5/5.** Phase 6's Julia agent correctly declined it at the time — this row scoped the work to RENAMING an existing convenience, and Julia had no text one to rename — but at four bindings out of five it had become a parity hole rather than a rename, which is a different question. Julia's version is the text twin of its existing `validate_path` and shares `load_failure_structural_error` with it. Its bad-input behaviour was MEASURED against the other four rather than assumed: Python's `validate_text` and Go's `ValidateText` both return `is_valid=false` with populated `schema_errors` for schema-invalid AND malformed text and neither raises, so Julia renders three channels — a `SchemaValidationError`'s structured errors straight into `schema_errors`, a codeless `ParseError` (malformed JSON) as one root `SchemaError` under the `parse` keyword, and a `(code, path)`-carrying rejection into `structural_errors`. Julia now returns the same error counts as Python on both bad inputs. **One residual, recorded not fixed:** `validate_path` renders only the third channel and still RAISES on schema-invalid or malformed input, so Julia's two convenience entry points differ on bad input. Changing `validate_path` is a behaviour change to a `stable` function nobody asked for and is left alone. | all five |
| 14 | raw-`Value` entry points | Rust takes untyped `serde_json::Value` for `lower_enums`, `resolve_subsystem_refs`, `resolve_template_machinery` and `prepare`, where every other binding takes a typed document. | Add typed wrappers at the canonical names; keep the raw forms as `*_raw` extension seams. **PARTLY DONE, PARTLY REFUSED (phase 6).** `lower_enums` and `resolve_subsystem_refs` gained typed wrappers with `*_raw` seams. `prepare` is moot — phase 4 deleted it. `resolve_template_machinery` was REFUSED with evidence: the premise says every other binding takes a typed document, and all three measured take raw — Python `(raw: Any, …)`, Julia `(raw_data, …)`, TypeScript `(rawData: unknown, …)`. A typed wrapper would have made Rust the only non-conformant binding. | Rust |
| 15 | `lower_enums` mutation | TypeScript is pure; Julia, Python, Rust and Go mutate in place. Julia raises `ParseError` where the rest raise `EnumLoweringError`. | Canonicalize on the pure form; mutating variants take Julia's `!`. Julia raises `EnumLoweringError`. **TypeScript VERIFIED (phase 6):** `lowerEnums(file)` returns a new document and shares unchanged subtrees with the input — it never writes through its argument — and raises `EnumLoweringError` (an `EsmDiagnosticError` subclass carrying a registry-backed `code`), not a bare `Error`. Nothing to change. **DONE:** `lower_enums` is pure in all five; the in-place twins are Julia's `lower_enums!` and `lower_enums_mut` in Python, Rust and Go (`LowerEnumsMut`), and Julia raises `EnumLoweringError`. | Julia, Python, Rust, Go |
| 16 | `substitute` cycles | ~~Only Go detects substitution cycles; the other four loop.~~ **RESOLVED — the premise was false, and inverted.** The other four never looped: all four are single-pass, so a cyclic binding set terminates on its own, exactly as CONFORMANCE_SPEC.md §2.2.3 rule 1 requires. Go was the sole non-conformant binding: it expanded replacements *transitively*, which (a) silently corrupted chained renames — `substitute("a", {a: b, b: c})` returned `"c"`, not `"b"`, mis-applying every overlapping rename through `renameRawExpr` — and (b) made cyclic sets non-terminating, which was then patched with cycle detection instead of by removing the transitivity. | Go made single-pass; `SubstitutionError` / `cyclic_substitution` removed as unnecessary. Pinned cross-binding by `tests/substitution/cyclic_bindings.json`. | Go (done) |
| 17 | `build_reference_graph` index sets | Python threads `index_sets` as a third argument, Rust via a separate function, **Julia not at all** — it reads the pre-0.8.0 nested shape. Julia and Python resolve v0.8.0 documents differently. | **Ruled (phase 6), after a correction.** The first ruling said the canonical signature was `build_reference_graph(document)`. That is not implementable: the function builds the graph of ONE MODEL and takes the model name in all four bindings that have it, and the document-level entry point already exists as `resolve_references(document)`. The Julia agent refused it and was right. Canonical is **`build_reference_graph(model, model_name, index_sets = <none>)`** — the document-scoped registry is an OPTIONAL TRAILING argument, not a separate function name and not required. Omitted, it falls back to a model-nested `index_sets` (the pre-0.8.0 shape); on a collision the model-nested one wins, which is Go's existing merge rule. Rust folds `build_reference_graph_with_index_sets` in; Python already conforms; Go's third argument becomes optional; TypeScript gains the function. **The Julia bug is real and confirmed**: Julia read `model["index_sets"]` where `esm-schema.json` declares `index_sets` only at `/properties/index_sets`, so `resolve_references` THREW `ReferenceResolutionError(E_REF_UNDECLARED_INDEX_SET)` on any 1.0.0 document with a top-level registry, where Python, Rust and Go all returned a graph. **TypeScript ADDED (phase 6):** ported from Python (the most complete of the four: it registers every node before resolving any reference, so a forward `from_faq` resolves), except for the registry rule, which follows Go and Rust: the model-nested pre-0.8.0 `index_sets` is MERGED on top of the document-scoped one, so a model-level entry wins a collision, where Python treats the two as either/or. Verified against the Python binding over all shared `tests/valid/**` fixtures — vertices, edges and topological order identical, zero mismatches, under both registry rules, because no shared fixture carries the two shapes at once. | Julia, Rust, Go, TypeScript |
| 18 | display domain | `to_unicode` / `to_latex` accept containers in TypeScript and Python, throw on them in Julia, and accept expressions only in Rust and Go. | All three renderers accept the full domain in every binding. **TypeScript VERIFIED (phase 6):** `toUnicode` / `toLatex` / `toAscii` (and `toMathML`) all take `Expr | Equation | Model | ReactionSystem | Reaction | EsmFile`. Nothing to change. **DONE:** Julia, Rust and Go accept the full domain too (§5.5). | Julia, Rust, Go |
| 19 | Go initialisms | Go has both `OpIC` and `ErrorIcInReactionSystem`; also `ToAscii` and `FmtAscii` against §2.1's `ASCII`. | `ErrorICInReactionSystem`, `ToASCII`, `FmtASCII`. **DONE (phase 6),** plus an audit finding. The three named renames landed. Go then audited all 385 exported names, every method on an exported type, and every exported struct field against §2.1, and found two further violations: `UnitWarning.LhsUnits` and `.RhsUnits`, left open for a ruling. **CLOSED (phase 6b): renamed to `LHSUnits` / `RHSUnits`.** The ruling is that Go's own house style already decided it — `FlattenedEquation.LHSString` / `.RHSString` (`pkg/esm/flatten.go`) spell the same two initialisms uppercase, so these two fields were the outliers, not the precedent. The wire contract is untouched and was VERIFIED so: the `json:"lhs_units"` / `json:"rhs_units"` tags are unchanged, and a `UnitWarning` marshal→unmarshal→marshal round trip is byte-identical before and after the rename. The `"lhs_units"` / `"rhs_units"` keys `promoteUnitFindings` writes into `StructuralError.Details` are likewise unchanged. Struct fields remain non-manifest symbols, so `api-surface.json` does not move. | Go |
| 20 | `component_graph` alias | TypeScript exports **both** `component_graph` (snake_case, violating §2) and `componentGraph`. | **DONE (phase 6).** `component_graph` is deleted. It was kept only for the (since-deleted) editor package's web components, which had already migrated to `componentGraph`; no caller outside this binding's own tests remained. | TypeScript |
| 21 | `compiler` | Each binding picks its build strategy by inspecting the document, and a caller can neither ask for one nor read back which ran. Julia's stable entry point always builds the tree walk, so its XLA emitter is unreachable from `esm_problem`; Rust routes on whether the document is arrayed; Python routes on document content between two pathways that disagree numerically. | `esm_problem` gains the keyword `compiler` over §5.8's closed vocabulary (`interpreter` / `native` / `xla` / `mtk` / `sympy`), defaulting to a **strict** `native`, and every Problem exposes `compiler` and `compiler_report`. Julia `compiler::Symbol`, Python `compiler: str \| None`, Rust `ProblemOptions.compiler: Option<Compiler>` over a new `Compiler` enum. Adding an optional keyword is a minor (§10). Flipping the default is a behaviour change and lands together with the conformance tier that measures what it refuses (`CONFORMANCE_SPEC.md` §5.44). **DONE.** Implemented in Julia, Rust and Python: the keyword, the strict `native` default, the three selection failures and the two readbacks are live in all three, and §5.44's compiler-agreement tier carries the goldens the refusals are measured against. The specialty members land per binding on the same one-way ratchet: Python's `sympy` and Julia's `mtk` are reachable from `esm_problem` (Julia's needs ModelingToolkit loaded and is the one compiler that runs the events and implicit equations of `CONFORMANCE_SPEC.md` §5.39); Rust's `xla` reached `esm_problem` on 2026-09-22 — the emitter over the tape now builds the Problem's right-hand side and the Jacobian differenced out of it, and rust is `bindings_required` for `xla` in that tier, on a build that has the feature and the extension. Julia's `:xla` reached `esm_problem` too: the direct StableHLO emitter builds the Problem's right-hand side, compiled once per build, and hands the solver a finite-difference Jacobian through it, so every Julia member of the vocabulary is reachable from the stable entry point. | Julia, Python, Rust |
| 22 | Rust `Compile` | Rust already exports an enum `Compile::{Auto, Always, Never}`, which decides whether a right-hand side is built **at all** — the static-versus-dynamic question — and says nothing about *which* compiler builds it. Beside item 21's `Compiler` the two names differ by one letter and mean different things, which is exactly the confusion §2 exists to prevent — and the collision is worse on the struct than on the type, since item 21 puts a field `compiler` next to the existing field `compile` on the same `ProblemOptions`. | Rename the type to `Rhs::{Auto, Always, Never}` and the field to `rhs`, keeping `Compile` as a deprecated type alias for one minor (§10). `Compile` is `extension` tier, so the rename is a minor. **DONE (compiler selection):** the enum is `Rhs`, the field is `ProblemOptions::rhs`, and `pub type Compile = Rhs` carries `#[deprecated(since = "0.2.0")]` for its one minor. | Rust |
| 23 | `build_evaluator` | §5.8 kept it as a documented extension seam on two grounds: it is the entry point for a caller who wants the compiled right-hand side without a Problem around it, and it has substantial downstream use. Item 21 answers both — `esm_problem(…; compiler=:xla)` *is* the compiled right-hand side, and the downstream use is one package, which migrates to that call. | **DONE except the downstream migration.** `build_evaluator` is no longer documented surface: the build is private (`_build_evaluator`) behind `esm_problem`, and the exported name is a deprecated alias that warns once and forwards, kept for one minor (§10). The forcing-buffer seam re-hung on the Problem — `forcing_buffers(prob)` / `forcing_buffer_index(prob)` answer for **every** compiler, not only for an out-of-place build, and `sync_forcing!` takes that container — and the compiler half of `BuildInspection` is `compiler_report`, which a `BuildInspection` and an `EsmProblem` now both answer. Every in-package caller (src, ext, scripts, test, docs) moved off the name. `BuildInspection` itself stays exported: `esm_problem`'s `inspect` keyword takes one, and a build that REFUSED leaves no Problem to read the partial report off. **The downstream migration is not done.** ReSEACT (`run_reseact_reactant.jl`, `tools/adjoint_gradient.jl`, `tools/rx_adjoint_check.jl`, `tools/sensitivity_forward.jl`, `tools/diag/*`, `prototypes/*`) calls `EA.build_evaluator(doc; form = :oop, …)` on each half of an operator-split document, reads `EA.forcing_buffers(fo)` off the product, mirrors it to device arrays and re-syncs with `EA.sync_forcing!` at each cadence boundary, and then traces its OWN macro step — advection plus sub-cycled chemistry over one window — of which the emitted right-hand side is a COMPONENT. `EarthSciASTDiff.prepare_jacobian` reaches the same seam through `build_kwargs = (; form = :oop, …)`. Both qualified and bare calls keep working on the alias (EarthSciASTDiff's tests call the bare name after `using EarthSciAST`), so nothing breaks today. Four things are still missing before the alias can be deleted: (1) a public way to obtain the out-of-place compiled intermediate representation itself, since `compiler = :xla` hands back a Problem whose `f!` is already compiled and host-in/host-out and cannot be composed into a larger traced program; (2) live forcing under `compiler = :xla`, which is a named refusal today (the device re-sync is not wired to the refresh callback's `post_refresh` hook); (3) a Problem-shaped replacement for `prepare_jacobian`'s `build_kwargs`; (4) an answer for a caller that builds SEVERAL right-hand sides from one document and drives them in one time loop, which one Problem does not describe. | Julia |
| G-2 | `supported_migration_targets` | TypeScript and Rust spelled it `get_supported_migration_targets`; Julia, Python and Go spell it `supported_migration_targets`. One capability under two canonical names, so the manifest carried two `stable` entries for it. | **TypeScript DONE (phase 6).** `supportedMigrationTargets()` added at the canonical name over the same table `migrate` / `canMigrate` use; `getSupportedMigrationTargets` stays a deprecated alias for one minor (§10), the same function object. **Rust DONE (phase 6)** as well (`a154aa171`): `supported_migration_targets` is the definition, `get_supported_migration_targets` a `#[deprecated]` delegate. Both spellings fold under the canonical name via `ALIAS_OVERRIDES`, so the manifest carries one entry, not two. | TypeScript, Rust |
| G-3 | `build_reference_graph` | Exported by Julia, Python, Rust and Go; **absent in TypeScript** — a four-of-five gap in a `stable` symbol that no row above covered. | **DONE (phase 6).** TypeScript gains `buildReferenceGraph`, plus the rest of the module's public surface (`resolveReferences`, `ReferenceGraph`, `ReferenceVertex`, `ReferenceEdge`, `VertexKind`, `EdgeKind`, `ReferenceResolutionError`), so the family is 5/5. See item 17 for the signature and the cross-binding verification. | TypeScript |
| H-4 | Python layering | Python re-exported the whole `data_sources` loader stack through the top-level `__all__` — 32 spellings, of which 29 were `extension`-tier and Python-only — so `import earthsci_ast` handed you a data-loading toolkit as well as a format library. `xarray` and `netcdf4` sat in the BASE dependency set, which a comment justified as "the IO tier hard-depends on them". | **DONE (phase 6).** The premise was measured FALSE: no module under `earthsci_ast/` imports `xarray` or `netCDF4` at module scope — `xarray` is imported inside `data_sources._xarray._default_xarray_opener`, and `netCDF4` is never imported by this package at all (it is the engine xarray selects). With all three of `xarray` / `netCDF4` / `scipy` blocked by an import hook, `import earthsci_ast` already succeeded and `__all__` was still the full 272, so nothing had to be restructured to make the split possible. The 29 `extension` spellings left `__all__` and now live only on `earthsci_ast.data_sources`; Python's declared surface is **272 -> 243**. The three `stable` spellings in that block — `apply_unit_conversion`, `parse_unit_conversion`, `UnitConversionError` — were **deliberately KEPT** at the top level: Julia defines them in core `src/unit_conversion.jl` (not `EarthSciASTEarthSciIOExt`), TypeScript exports `UnitConversionError` from its index, and §6 carries all three as `stable`, so dropping them would have made Python the sole non-conformant binding and downgraded a stable symbol. The manifest's `stable` count is unchanged at 272 — every symbol removed was `extension`. `xarray` / `netcdf4` moved to a new `data` extra; `scipy` had already moved to `simulate` in an earlier round, per esm-libraries-spec §2.4 / §2.5.9. A missing optional dependency is reported at the point of use, naming the extra. | Python |

---

## 9. How the surface is enforced

Five tests, one per binding, each asserting in **both** directions that the
binding's declared surface equals `api-surface.json`:

| Binding | Test | Reads |
|---|---|---|
| Julia | `pkg/EarthSciAST.jl/test/api_surface_test.jl` | `names(EarthSciAST)` |
| TypeScript | `pkg/earthsci-ast-ts/src/api-surface.test.ts` | the `index.ts` re-export list |
| Python | `pkg/earthsci-ast-py/tests/test_api_surface.py` | `earthsci_ast.__all__` |
| Rust | `pkg/earthsci-ast-rs/tests/api_surface.rs` | the crate root's `pub use` / `pub const` |
| Go | `pkg/earthsci-ast-go/pkg/esm/api_surface_test.go` | a `go/ast` walk of package `esm` |

Each also checks kinds — a manifest `error` must be a throwable, a manifest
`type` must not be a function — and each guards against passing vacuously if its
parser matches nothing.

A cross-cutting check runs all five extractions at once:

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
`derive_odes` already use — so the surface tests keep asserting both.

Promoting `extension` → `stable` is a minor. Demoting `stable` → `extension` is
a major, because it removes a compatibility promise.

Argument-level changes are governed the same way: adding an optional keyword is
a minor, renaming or reordering an argument of a `stable` function is a major.
The §8 SciML renames are therefore major-or-aliased, not silent.

### Deprecations in flight

| Name | Binding | Since | Replacement | Removed in |
|---|---|---|---|---|
| `build_evaluator` | Julia | §8 item 23 | `esm_problem(input, tspan; compiler = …)`; `prob.f!` / `prob.u0` / `prob.p` / `prob.var_map`, `forcing_buffers(prob)`, `forcing_buffer_index(prob)`, `compiler_report(prob)`; `compiler = :xla` for what `form = :oop` handed a compiled backend | the next minor |
| `to_json(::Graph)` methods | Julia | §8 item 8 | `to_json_graph` | the next major |
| `deriveODEs` | TypeScript | §8 item 5 | `deriveOdes` | the next major |
| `getSupportedMigrationTargets` | TypeScript | §8 item G-2 | `supportedMigrationTargets` | the next major |
| `CLOSED_FUNCTION_NAMES` | TypeScript | §8 item 4 | `closedFunctionNames()` | the next minor |
| the container-suffixed edit operations (`add_variable_to_model`, `remove_coupling_from_file`, `merge_esm_files`, …) | Python | §8 item 7 | the bare verbs (`add_variable`, `remove_coupling`, `merge`, …) | the next major |
| `validate_complete` | Rust | §8 item 13 | `validate_text` | the next major |
| `get_supported_migration_targets` | Rust | §8 item G-2 | `supported_migration_targets` | the next major |
| `build_reference_graph_with_index_sets` | Rust | §8 item 17 | `build_reference_graph` with its trailing `index_sets` argument | the next major |
| `ReferenceError` | Rust | §8 item 10 | `ReferenceResolutionError` | the next major |
| `Compile` | Rust | §8 item 22 | `Rhs` | the next minor |

The removal release follows the alias's tier in the table above: a spelling of
a `stable` symbol leaves at a major, an `extension` one at a minor.

**An alias stays exported until it is removed**, as the rule above requires.
Its purpose is that a downstream keeps running while it migrates. For
`build_evaluator` a downstream does reach the bare name: EarthSciASTDiff calls `build_evaluator(…)`
after `using EarthSciAST` throughout its tests and scripts, which an unexported
alias would answer with `UndefVarError` rather than the deprecation warning. It
therefore stays in the manifest and in §6's count until the release that
deletes it.

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
  surface, and pointed here from its own heading. Phase 6 fixed the two tier
  labels this row used to flag: §5.4 (Rust) now reads "Core + Analysis +
  Simulation" and §5.5 (Go) "Core + Analysis", with the Go description
  rewritten. The parenthetical that once justified the Rust label — "exports
  `simulate`, `simulate_array` and `prepare`" — no longer holds either: phase 4
  deleted `simulate` and `prepare` from every binding, and `simulate_array` is
  a module, not an exported function. Rust's Simulation tier now rests on
  `esm_problem` / `solve` / `compile_array`. Its §2.4.4 conformance table is
  still stale. Reconciling or retiring that section is follow-up work.
