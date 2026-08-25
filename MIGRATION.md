# Migration guide

Breaking changes to the EarthSciAST public API, newest first. Every entry
gives the exact before/after spelling in each binding.

---

## Phase 6 — tidying the surfaces and locking them

Per-binding sections; each binding lands its own share. The normative target is
`API_SPEC.md` §8.

### Julia

| Before | After | Why |
|---|---|---|
| `unknown_names(model)` | `unknowns(model)` | §8 item 6. `unknown_names` / `parameter_names` **stay exported** — they are not going away — because the canonical bare names collide with `ModelingToolkit.unknowns` / `.parameters`. After `using EarthSciAST, ModelingToolkit`, a bare `unknowns(m)` is an ambiguity error in Julia; write `EarthSciAST.unknowns(m)` or keep using `unknown_names(m)`. |
| `parameter_names(model)` | `parameters(model)` | as above |
| `declared_system_kind_mismatch(model)` | **deleted** | §8 item 11. It was Julia-only and one line over the two functions that replace it. `nothing` ⇒ `declared_system_kind(m) === nothing \|\| declared_system_kind(m) == system_kind(m)`; the `(declared, derived)` tuple ⇒ `(declared_system_kind(m), system_kind(m))`. The `system_kind_mismatch` **finding** is unchanged — `validate` still reports it with the same code, path and `details`. |
| — | `declared_system_kind(model)` | new: reads the explicit field, `nothing` when absent |
| — | `effective_system_kind(model)` | new: `declared` if present, else derived — the question a caller choosing a solver asks |
| `validate(path::AbstractString)` | `validate_path(path)` | §8 item 13. `validate` takes a **typed document** in every binding; one name meant "check this document" in four bindings and "read this file and check it" in Julia. `validate(::String)` is now a `MethodError`, deliberately: a silent file read is worse than a loud failure. `validate_path` keeps the whole old behaviour, including rendering a load-time rejection as the structural finding the corpus pins. |
| `lower_enums!(file)` | `lower_enums(file)` (pure) or `lower_enums!(file)` (in place) | §8 item 15. The canonical name is the pure form, which deep-copies; the mutating twin keeps Julia's `!` (`API_SPEC.md` §2.2). Both are exported. |
| `catch e; e isa ParseError` around enum lowering | `catch e; e isa EnumLoweringError` | §8 item 15, and a real defect: Julia raised `ParseError` where TypeScript, Python and Rust all raise `EnumLoweringError`. `EnumLoweringError <: EarthSciASTError` carries a structured `code` (`enum_op_malformed` / `unknown_enum` / `unknown_enum_symbol`) instead of interpolating it into the message. |
| `to_json(graph)` | `to_json_graph(graph)` | §8 item 8. `to_json` is the **document** serializer (§8 item 2). The `Graph` methods of `to_json` remain one minor as a deprecated alias and render byte-identical output. |
| `to_unicode(model)` / `to_latex(file)` threw `ArgumentError` | returns the container summary | §8 item 18. All three renderers now accept the full domain — expressions **and** `Model` / `ReactionSystem` / `EsmFile`. A container summary has no format-specific form, so all three return the same plain text; `to_ascii`'s output is unchanged. |

#### `update` diagnostic pointers lost a spurious `/0` (bug fix)

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

#### `build_reference_graph` reads the 1.0.0 `index_sets` registry (bug fix)

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

### Python

#### The `data_sources` loader stack is no longer re-exported at the top level

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
in the base install, so no extra is needed just to import them.

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

#### `xarray` and `netcdf4` left the base dependency set

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

#### `scipy`: no change to the dependency set, clearer message

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

---

## Phase 4 — the simulation surface: `Problem` + `solve`

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
split is gone.

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
- `EnsembleProblem` is the canonical form for sweeps and Monte Carlo. Go's
  orphaned `ParameterSweep` / `SweepRange` / `SweepDimension` — a sweep vocabulary
  in the one binding with no solver to run it — are deleted rather than
  harmonized.
- `build_evaluator` **survives unchanged** as a documented extension seam. It has
  117 real call sites downstream and is not deprecated by any of this.
- **Solvers are optional.** Constructing a Problem must not require the
  integrator. Rust's `diffsol` is now behind a `solve` feature; Python's SciPy is
  a `simulate` extra; Julia's solver stays a package extension.

---

## Phase 2 — document I/O and version constants

Three symbols changed, in all five bindings, in one release. The old names are
**deleted**, not deprecated: each of the three was defective in a way a
compatibility shim would have to preserve.

### `load` → `load_path` / `load_string` / `load_document`

`load(<string>)` meant a **file path** in Julia and Go and **JSON text** in
TypeScript and Rust. Python sniffed: `os.path.exists(s)` decided which. One
name, one argument type, opposite meanings, and no type error anywhere to
catch the difference — a program ported between bindings failed at runtime, or,
if the path happened to be valid JSON, did the wrong thing silently.

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

That is exactly what `earthsci_ast.validate()` now does internally, since its
own documented contract requires it.

### `save` → `to_json` / `to_json_compact` / `write_path`

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
`to_json_compact` is a one-line wrapper over it.

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
type and both keep the name. Python's graph serializer is now re-exported as
`to_json_graph`:

```python
from earthsci_ast import to_json_graph   # was: to_json, on a Graph
from earthsci_ast import to_json         # now: the DOCUMENT serializer
```

### `VERSION` / `ESM_FORMAT_VERSION` → `SCHEMA_VERSION` + `LIBRARY_VERSION`

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

### Bug fixed in the same round

`EarthSciAST.load(::IO)` in Julia skipped top-level `{ref}` inlining and
`resolve_subsystem_refs!`, which the path and dict methods both ran. A document
loaded from a stream therefore kept its subsystem refs as unresolved
`SubsystemRef`s — and `flatten` **silently skips** an unresolved `SubsystemRef`.
Same bytes, strictly smaller system, no error. All three entry points now share
one pipeline; the successor of `load(::IO)` is `load_string(::IO)`.
