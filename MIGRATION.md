# Migration guide

Breaking changes to the EarthSciAST public API, newest first. Every entry
gives the exact before/after spelling in each binding.

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
