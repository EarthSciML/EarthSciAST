---
title: "Python extension seams"
description: "Python's extension-tier names: documented, reachable, not portable."
type: "api"
---


Extension-tier names are part of this binding's documented surface but are not harmonized across bindings, and may change in a minor release ([API_SPEC.md §7](https://github.com/EarthSciML/EarthSciAST/blob/main/API_SPEC.md#7-extension-seams)).

37 names.

### `assert_partitions` {#x-assert_partitions}

*function* · canonical name `assert_partitions`

```python
assert_partitions(model: Any) -> None
```

Assert the §6.3.1 invariant: the three unknown sets partition the
unknowns and the four parameter sets partition the parameters, disjointly
and exhaustively. Raises [`ClassificationError`](/generated/api/extension/python#x-classificationerror) otherwise.

The spec states these ARE partitions; a binding that derives rather than
declares them can break the property silently, so it is checked rather than
assumed.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/classification.py#L578)

### `BuildInspection` {#x-buildinspection}

*type* · canonical name `build_inspection`

```python
class BuildInspection
BuildInspection(setup_arrays: dict[str, np.ndarray] = dict(), const_arrays: dict[str, Any] = dict(), observed_exprs: dict[str, Expr] = dict(), params: dict[str, float] = dict())
```

Observability record for `simulate` — the Python mirror of the
Julia binding's `BuildInspection` (`build_evaluator(...; inspect=…)`).

Pass one via the `inspect` keyword
(`esm_problem(file, tspan, inspect=BuildInspection())`) and the NumPy
array/PDE pathway fills it with named BUILD-TIME products that are
otherwise internal to the evaluator:

* `setup_arrays` — the materialized build-time geometry arrays, keyed by
  (flattened) observed name: the per-pair overlap-area matrix `A_ij`,
  its row-sums `A_j`, the normalized weights `W_ij`, and every other
  STATE-FREE array-valued observed (no transitive state / `t`
  reference), evaluated once at build. This is the official inspection
  surface for conformance runners that gate per-pair regridding values
  (CONFORMANCE_SPEC §5.8).
* `const_arrays` — the build-time array registry: the value-invention
  join-key buffers (broad-phase bins) and provider-/loader-injected input
  arrays.
* `observed_exprs` — the dependency-ordered observed substitution map
  (flattened name → RHS expression), exactly as the RHS driver
  materializes it each step.
* `params` — the resolved SCALAR parameter values (model defaults with
  any `parameter_overrides` applied), keyed by (flattened) parameter
  name. These are load-time CONSTANTS, so a build-time cellwise evaluation
  (`evaluate_cellwise`, a §6.6.5 analytic `reference`, coordinate-
  expression `ic` seeding) may bind them into scope — while STATE stays
  out of scope. The observed-assertion form already binds them (a state-
  free observed is materialized into `setup_arrays` with these values);
  `params` exposes the same map for the reference / `ic` positions.

Filling the record never changes the simulation: the returned
[`Solution`](/generated/api/ref/solution) is identical with or without `inspect`
(nothing downstream consults the record). Only the NumPy array-op pathway
fills it; the scalar SymPy pathway accepts and ignores it.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/simulation_array.py#L1195)

### `ClassificationError` {#x-classificationerror}

*error* · canonical name `classification_error`

```python
class ClassificationError(Exception)
```

A model that cannot be classified (e.g. a cycle among observed
definitions, which the DAE contract forbids).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/classification.py#L131)

### `CompilerRefusedRuleError` {#x-compilerrefusedruleerror}

*error* · canonical name `compiler_refused_rule_error`

```python
class CompilerRefusedRuleError(SimulationError)
CompilerRefusedRuleError(compiler: str, rule: str, reason: str, *, declines: tuple[tuple[str, str], ...] = (), phase: str = 'construction')
```

`compiler_refused_rule`: this compiler cannot run this rule.

Raised at CONSTRUCTION, naming the compiler, the rule (an equation or an
observed, component-qualified) and the reason. Never a fallback: the rule is
not then run on a slower path.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/compiler.py#L111)

### `COMPILERS` {#x-compilers}

*constant* · canonical name `compilers`

```python
COMPILERS: tuple[str, ...] = ('native', 'interpreter', 'xla', 'mtk', 'sympy')
```

The closed vocabulary, in the order §5.8's table lists it. Every binding has
the same five members; which of them it PROVIDES is per-binding.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/compiler.py#L56)

### `CompilerUnavailableError` {#x-compilerunavailableerror}

*error* · canonical name `compiler_unavailable_error`

```python
class CompilerUnavailableError(SimulationError)
CompilerUnavailableError(value: str, reason: str)
```

`compiler_unavailable`: in the vocabulary, but not provided here.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/compiler.py#L96)

### `CompilerUnknownError` {#x-compilerunknownerror}

*error* · canonical name `compiler_unknown_error`

```python
class CompilerUnknownError(SimulationError)
CompilerUnknownError(value: object)
```

`compiler_unknown`: the value is outside the closed vocabulary.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/compiler.py#L83)

### `component_type` {#x-component_type}

*function* · canonical name `component_type`

```python
component_type(file: EsmFile, component_id: str) -> str | None
```

The kind of component `component_id` names in `file`:
`"model"`, `"reaction_system"`, or `None` when it names neither.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/graph.py#L404)

### `densify_parallel_edges` {#x-densify_parallel_edges}

*function* · canonical name `densify_parallel_edges`

```python
densify_parallel_edges(ring: object, max_segment_deg: float, *, lat_atol: float = 1e-09) -> np.ndarray
```

Subdivide each *parallel* edge of a lon-lat `ring` into short great-circle segments.

Each parallel edge (constant latitude) wider than `max_segment_deg` degrees
of longitude is split into great-circle segments at most `max_segment_deg`
wide, inserting the intermediate vertices **on the parallel** (linear in
lon-lat).

The `spherical` / `geodesic` manifolds model every polygon edge — the
clip's and the `polygon_area` FAQ's — as a **great-circle geodesic** (RFC
§B.4 / §5.8.4). A lon-lat cell edge running along a parallel is a *small
circle*, not a great circle, so a single wide great-circle edge bows off the
parallel and a coarse polar cell carries a real area error: ≈4% for a 30° cell
next to the pole, ≈1% at 15°, scaling with the **square of the cell's
longitude width**. Replacing one wide parallel edge with many short
great-circle chords that each stay on the parallel drives that error toward
zero — the standard mitigation (XIOS) for coarse polar lat-lon grids.

This is an **opt-in pre-clip** step: apply it to each operand before
[`intersect_polygon`](/generated/api/ref/intersect_polygon) (and the `polygon_area` FAQ) when polar accuracy
matters. It is **off by default** — nothing in the evaluator calls it — so the
default clip / area behaviour is unchanged. Only parallel edges are touched: a
meridian already lies on a great circle, and a slanted edge is not a parallel,
so both are returned whole. `max_segment_deg` must be positive; `lat_atol`
(degrees) is the tolerance for judging an edge to lie along a parallel. Returns
the densified ring as `[n, 2]` *distinct* lon-lat vertices (implicit closure
preserved).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/geometry.py#L687)

### `EditOperation` {#x-editoperation}

*type* · canonical name `edit_operation`

```python
class EditOperation
EditOperation(operation_type: str, target_type: str, target_id: str, data: dict[str, Any] = dict(), metadata: dict[str, Any] = dict())
```

Represents an editing operation that can be applied to an ESM structure.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/edit.py#L37)

### `EditResult` {#x-editresult}

*type* · canonical name `edit_result`

```python
class EditResult
EditResult(success: bool, modified_object: Any = None, errors: list[str] = list(), warnings: list[str] = list(), validation_result: ValidationResult | None = None)
```

Result of an editing operation.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/edit.py#L48)

### `equijoin` {#x-equijoin}

*function* · canonical name `equijoin`

```python
equijoin(left: Iterable[Any], right: Iterable[Any], *, on_left: Callable[[Any], Any] = _identity, on_right: Callable[[Any], Any] = _identity) -> list[tuple[Any, Any]]
```

Value-equality equi-join (rule 5): emit every `(l, r)` pair where
`on_left(l) == on_right(r)`.

Hashing / `searchsorted` is used **only** to match keys; the result is
emitted **sorted by the canonical key** `(on_left(l), l, r)`, so the output
is independent of bucket iteration order *and* of input order. This is the
connectivity-inversion primitive — join an edge→cell table against a cell
table on the shared ID to recover the *edges of cell i*. Join keys must be
non-float (rule 1).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/relational.py#L282)

### `ESMEditor` {#x-esmeditor}

*type* · canonical name `esm_editor`

```python
class ESMEditor
ESMEditor(validate_after_edit: bool = True)
ESMEditor.apply_operation(target: EsmFile | Model | ReactionSystem, operation: EditOperation) -> EditResult
ESMEditor.remove_variable(model: Model, var_name: str) -> EditResult
ESMEditor.add_variable(model: Model, var_name: str, var_info: ModelVariable) -> EditResult
ESMEditor.modify_variable(model: Model, var_name: str, **updates) -> EditResult
ESMEditor.add_equation(model: Model, equation: Equation) -> EditResult
ESMEditor.remove_equation(model: Model, index: int) -> EditResult
ESMEditor.add_species(reaction_system: ReactionSystem, species: Species) -> EditResult
ESMEditor.add_reaction(reaction_system: ReactionSystem, reaction: Reaction) -> EditResult
ESMEditor.remove_reaction(reaction_system: ReactionSystem, reaction_name: str) -> EditResult
ESMEditor.remove_species(reaction_system: ReactionSystem, species_name: str) -> EditResult
ESMEditor.add_continuous_event(model: Model, event: ContinuousEvent) -> EditResult
ESMEditor.add_discrete_event(model: Model, event: DiscreteEvent) -> EditResult
ESMEditor.remove_event(model: Model, event_name: str) -> EditResult
ESMEditor.add_coupling(esm_file: EsmFile, coupling: CouplingEntry) -> EditResult
ESMEditor.remove_coupling(esm_file: EsmFile, index: int) -> EditResult
ESMEditor.substitute_in_expression(expr: Expr, substitutions: dict[str, Expr]) -> Expr
ESMEditor.rename_variable(target: Model | ReactionSystem, old_name: str, new_name: str) -> EditResult
ESMEditor.merge(file_a: EsmFile, file_b: EsmFile) -> EditResult
ESMEditor.extract(esm_file: EsmFile, component_name: str) -> EditResult
```

Editor for ESM format structures with validation and safety checks.

**Members**

- `apply_operation` — Apply an editing operation to a target structure.
- `remove_variable` — Remove a variable from a model.
- `add_variable` — Add a variable to a model.
- `modify_variable` — Modify a variable in a model.
- `add_equation` — Add an equation to a model.
- `remove_equation` — Remove an equation from a model by index.
- `add_species` — Add a species to a reaction system.
- `add_reaction` — Add a reaction to a reaction system.
- `remove_reaction` — Remove a reaction from a reaction system.
- `remove_species` — Remove a species from a reaction system.
- `add_continuous_event` — Add a continuous event to a model.
- `add_discrete_event` — Add a discrete event to a model.
- `remove_event` — Remove an event from a model (searches both continuous and discrete events).
- `add_coupling` — Add a coupling entry to an ESM file.
- `remove_coupling` — Remove a coupling entry from an ESM file by index.
- `substitute_in_expression` — Substitute variables in an expression.
- `rename_variable` — Rename a variable throughout a model or reaction system.
- `merge` — Merge two ESM files.
- `extract` — Extract a single component into a standalone ESM file.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/edit.py#L59)

### `evaluate_rhs` {#x-evaluate_rhs}

*function* · canonical name `evaluate_rhs`

```python
evaluate_rhs(file_or_flat: EsmFile | FlattenedSystem, state: dict[str, float], t: float = 0.0, parameters: dict[str, float] | None = None, *, compiler: str | None = None) -> dict[str, float]
```

Evaluate the discretized method-of-lines RHS f(state, t) of an
array/PDE model, returning a `{element_name: derivative}` map keyed by the
column-major element names (`u[1]`, `u[2,3]`, ...).

This is the single-shot RHS hook the cross-language PDE-simulation
conformance tier uses to check that Julia, Python, and Rust
agree on the *discretized RHS* independently of any integrator. `state`
supplies the value of every state element (same keying as
`initial_conditions` in `simulate`).

`compiler` is the same closed vocabulary `esm_problem` takes, and for
the same reason: this entry point builds and evaluates a right-hand side, so
WHICH machinery does it is the caller's to name. `None` means `native`,
which is strict — a rule that would walk per cell is `compiler_refused_rule`
here too. `sympy` has no scalar-lambdified form to offer a single-shot RHS
probe and is refused.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/simulation_array.py#L3329)

### `expand_equation_placeholders` {#x-expand_equation_placeholders}

*function* · canonical name `expand_equation_placeholders`

```python
expand_equation_placeholders(equation: Equation, variable_names: list[str]) -> list[Equation]
```

Expand _var placeholders in an equation to create multiple equations,
one for each variable name in the list.

**Parameters**

- `equation` (`Equation`) — Equation that may contain _var placeholders
- `variable_names` (`list[str]`) — List of variable names to substitute for _var

**Returns**

- `list[Equation]` — List of equations with _var replaced by each variable name

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/substitute.py#L225)

### `from_sympy` {#x-from_sympy}

*function* · canonical name `from_sympy`

```python
from_sympy(sympy_expr: sp.Expr) -> Expr
```

Convert SymPy expression back to ESM expression.

Dispatch is by `sympy_expr.func.__name__` via the `_FROM_SYMPY_*`
tables for the uniform function/operator ops (trig, hyperbolic, Min/Max,
And/Or, ...). Ops needing custom arg reshaping or metadata — `Pow`
(`^`), `log` (natural vs `log10`), `Derivative` (`wrt`),
`Piecewise` (`ifelse`) — and the numeric/symbol atoms stay explicit.

**Parameters**

- `sympy_expr` (`sp.Expr`) — SymPy expression to convert

**Returns**

- `Expr` — ESM expression

**Raises**

- [`SimulationError`](/generated/api/extension/python#x-simulationerror) — If a Piecewise with more than two branches is
  encountered — it has no single-`ifelse` representation, so it
  cannot be converted losslessly.
- `TypeError` — If an otherwise unsupported SymPy expression type is
  encountered.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/expression.py#L820)

### `GeometryBackendUnavailable` {#x-geometrybackendunavailable}

*error* · canonical name `geometry_backend_unavailable`

```python
class GeometryBackendUnavailable(GeometryError)
```

A spherical/geodesic clip was requested but `spherely` is not installed.

The spherical manifolds delegate the clip to `spherely` (S2 via s2geography),
which is pre-1.0 and an *optional* pinned dependency
(`pip install 'earthsci_ast[geometry]'`). The planar manifold needs no
backend. Conformance suites skip the spherical path when this is raised rather
than failing — same posture as the `deferred_in` tag in the byte-golden
conformance manifests.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/geometry.py#L72)

### `has_var_placeholder` {#x-has_var_placeholder}

*function* · canonical name `has_var_placeholder`

```python
has_var_placeholder(expr: Expr) -> bool
```

Check if an expression contains _var placeholder.

**Parameters**

- `expr` (`Expr`) — Expression to check

**Returns**

- `bool` — True if expression contains _var placeholder, False otherwise

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/substitute.py#L249)

### `jacobian` {#x-jacobian}

*function* · canonical name `jacobian`

```python
jacobian(model: Model) -> sp.Matrix
```

Compute the Jacobian matrix of the ODE system in a model.

**Parameters**

- `model` (`Model`) — Model containing state variables and equations

**Returns**

- `sp.Matrix` — SymPy Matrix representing the Jacobian

**Raises**

- `ValueError` — If model has no state variables or equations

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/expression.py#L916)

### `MANIFOLDS` {#x-manifolds}

*constant* · canonical name `manifolds`

```python
MANIFOLDS: tuple[str, ...] = ('planar', 'spherical', 'geodesic')
```

The closed set of manifold names [`intersect_polygon`](/generated/api/ref/intersect_polygon) accepts, matching
the `manifold` enum on the `intersect_polygon` op in esm-schema.json.
`"planar"` clips in the flat lon-lat plane; `"spherical"` and
`"geodesic"` both clip on the sphere through the optional `spherely`
dependency (see the module docstring).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/geometry.py#L54)

### `model_nodes` {#x-model_nodes}

*function* · canonical name `model_nodes`

```python
model_nodes(document: Any, _prefix: str = '') -> Iterator[tuple[str, Any]]
```

Yield `(dot_path, model_node)` for every model in a document, INCLUDING
nested subsystems, so classification can be reported per model node.

Classification is a property of one model node. A binding that flattens the
document first and classifies once returns a single merged answer, which the
`subsystem_scope` conformance fixture rejects.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/classification.py#L619)

### `partition` {#x-partition}

*function* · canonical name `partition`

```python
partition(model: Mapping[str, Any]) -> Partition
```

Run the cadence-partition pass over a parsed model.

Classifies every node by the cadence lattice (`max`-propagation + the
gather rule), derives the materialization frontier at both thresholds,
checks the three guards (acyclicity / no continuous relational /
`expect_cadence` agreement), and reports the class summary and the
hot-tree / per-event-handler emptiness. Raises [`CadenceError`](/generated/api/ref/cadence_error) on any
guard violation. The CONST-folded *buffers* are produced separately via
`compute_fold` (they need the document-literal inputs).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/cadence.py#L740)

### `polygon_area_via_faq` {#x-polygon_area_via_faq}

*function* · canonical name `polygon_area_via_faq`

```python
polygon_area_via_faq(ring: np.ndarray, manifold: str) -> float
```

Evaluate the (unsigned) `polygon_area` FAQ for a vertex `ring` through
the generic aggregate machinery — the same `.eval_expr` path the array
simulator uses. `ring` is the (open or closed) `[n, 2]` lon/lat vertex
ring; it is closed internally so the wrap edge `v→1` is the ordinary `v+1`
lookup. Returns `0.0` for a degenerate (`< 3` distinct vertex) ring.

Planar uses the Gauss–Green shoelace FAQ; spherical / geodesic uses the Van
Oosterom–Strackee spherical-excess fan FAQ.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/area_faq.py#L161)

### `pushdown_diagnostics` {#x-pushdown_diagnostics}

*function* · canonical name `pushdown_diagnostics`

```python
pushdown_diagnostics(esm: dict, model_name: str | None = None) -> list[dict]
```

The residual diagnostics [`desugar_pushdown`](/generated/api/ref/desugar_pushdown) would emit for `esm`.

One record per aggregate that IS join-shaped (it bins records into the cells
of an index set and feeds a provider-backed rank-2 array through a
`+`-semiring mat-vec) but whose containment predicate the recogniser could
not read, so the rewrite does not fire for it and that array is fetched
WHOLESALE.

Inspectable, side-effect-free counterpart of the warning stream: same
records, same order (sorted by `variable`/`consumer`/`array`), stable
field set (`code`, `variable`, `consumer`, `array`, `index_set`,
`reason`, `template`, `consequence`), pinned across bindings by the
`tests/conformance/pushdown/` corpus. Empty for a document that already
carries the rewrite record, for one with no model selected, and —
deliberately — for one that simply is NOT join-shaped: "no join here" is not
a defect.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/pushdown_rewrite.py#L1399)

### `resolve_model_refs` {#x-resolve_model_refs}

*function* · canonical name `resolve_model_refs`

```python
resolve_model_refs(esm_file: EsmFile, base_path: str, loader_metaparameters: dict[str, int] | None = None, parent_metaparameters: dict[str, int] | None = None, _mount_chain: tuple[str, ...] = (), _enclosing_precision: str = _DEFAULT_ELEMENT_TYPE) -> None
```

Resolve all top-level model references in an ESM file.

The top-level analog of [`resolve_subsystem_refs`](/generated/api/ref/resolve_subsystem_refs). Walks
`esm_file.models`; any entry whose value is an unresolved
`{"ref": "<file|url>"}` dict — carried verbatim by `_parse_esm_data`
and permitted by the schema's top-level `models`
`oneOf[Model, SubsystemRef]` — is fetched, schema-validated, and its
single top-level model is spliced into `models[X]` under the SAME key
`X` with `name = X`.

Because flatten collects the spliced model with prefix `X`, its flat
variable names `X.<var>` already equal the coupling-edge endpoint names —
a coupled document that imports its components by name assembles with zero
coupling-edge rewrites. This generalizes the existing ref mechanism to the
top-level `models` map; it introduces no new primitive.

Resolution reuses `_fetch_ref_content` + `_parse_esm_data` and then
recursively resolves the spliced model's own subsystem refs (relative to
the referenced file's directory) via `_resolve_model_subsystems`.

Must run BEFORE [`resolve_subsystem_refs`](/generated/api/ref/resolve_subsystem_refs) so that every top-level
entry is a concrete `Model` before the subsystem walk — which assumes
`model.subsystems` exists — visits it.

**Parameters**

- `esm_file` (`EsmFile`) — The parsed ESM file to resolve references in (modified in place)
- `base_path` (`str`) — The base directory for resolving relative file paths
- `loader_metaparameters` (`dict[str, int] | None`) — The `metaparameters` passed to the
  `load_*` entry point (esm-spec §9.7.6 binding site 4). Forwarded to each mounted
  leaf's resolution so a §9.7.10 form-A mount edge closes the leaf's
  declared metaparameters (e.g. NX/NY) under the loader's grid when the
  edge itself carries no explicit `bindings`.
- `parent_metaparameters` (`dict[str, int] | None`) — The MOUNTING document's closed metaparameter
  environment, the scope each edge's `bindings` expressions fold
  against (esm-spec §9.7.6 binding site 3).
- `_mount_chain` (`tuple[str, ...]`) — Private. The canonical paths of the top-level mounts
  currently on the resolution path, so that an assembly mounting an
  assembly that mounts back is a `CircularReferenceError` rather
  than unbounded recursion. Path-scoped, not visit-once: the same
  component file may be mounted by several keys.

**Raises**

- [`CircularReferenceError`](/generated/api/ref/circular_reference_error) — If circular references are detected
- [`SubsystemRefError`](/generated/api/ref/subsystem_ref_error) — If a reference cannot be resolved or does not
  contain a top-level model

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/parse.py#L2370)

### `RuleTier` {#x-ruletier}

*type* · canonical name `rule_tier`

```python
class RuleTier
RuleTier(rule: str, phase: str, tier: str, declines: tuple[tuple[str, str], ...] = ())
RuleTier.per_cell: bool  # property
```

One rule's landing: which tier answered, and what declined first.

`rule` is the equation or observed, component-qualified, in the spelling
the refusal would name. `phase` is WHEN the evaluation happened — a
Python build evaluates rules in three places (§2.5.10 puts all three under
the compiler), and the census found six sevenths of the per-cell landings in
the first of them:

* `construction` — the const-geometry hoist and the static-observed
  materialization, inside `esm_problem` itself;
* `rhs` — one evaluation of the right-hand side;
* `observed-output` — the observeds reported at output times.

`declines` is the chain that led here, fastest tier first, as
`(tier, reason)` pairs.

**Members**

- `per_cell` — Did this rule land on a Python walk per output cell?

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/compiler.py#L178)

### `serialize_canonical` {#x-serialize_canonical}

*function* · canonical name `serialize_canonical`

```python
serialize_canonical(rows: Sequence[Any]) -> str
```

Canonical byte form of an **already-ordered** index set
(`CONFORMANCE_SPEC.md` §5.5.3): each row serialised as a JSON array (or a
bare scalar), as **compact JSON** (`,` / `:` separators, no spaces,
UTF-8, no `\uXXXX` escaping).

Use [`canonical_index_set_json`](/generated/api/ref/canonical_index_set_json) for raw (unsorted) input — it runs
[`distinct`](/generated/api/ref/distinct) first. This helper is for output already in §5.5.1 order
(e.g. the pairs from [`group_aggregate`](/generated/api/ref/group_aggregate)).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/relational.py#L379)

### `SimulationError` {#x-simulationerror}

*error* · canonical name `simulation_error`

```python
class SimulationError(EarthSciAstError)
```

Exception raised during the SymPy bridge or simulation.

Defined in this leaf module (it imports nothing from the package) rather
than beside the code that raises it, because the modules that raise it sit
on both sides of an import edge: `expression` and `sympy_bridge` raise
it for a malformed expression or a cyclic algebraic system, and
`earthsci_ast.compiler` — which `earthsci_ast.numpy_interpreter`
imports, and which `expression` therefore imports transitively — raises
its three `compiler_*` subclasses. `expression.py` re-exports the name,
so `earthsci_ast.simulation.SimulationError` and every other established
spelling are unchanged.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/errors.py#L79)

### `solve_all` {#x-solve_all}

*function* · canonical name `solve_all`

```python
solve_all(integrator: Integrator) -> Solution
```

Run `integrator` to completion — the spec's `solve!`.

Named `solve_all` rather than `solve` because Python cannot overload on
argument type and [`solve`](/generated/api/ref/solve) already names the EsmProblem-to-Solution verb.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/problem.py#L2578)

### `SolverBlockError` {#x-solverblockerror}

*error* · canonical name `solver_block_error`

```python
class SolverBlockError(Exception)
SolverBlockError(code: str, message: str)
```

Raised for a `solver` block a document may not carry.

Carries the stable diagnostic `code` (esm-spec §2.2.5) alongside the
message, matching how `ExpressionTemplateError` reports the §9.7 gate.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/solver.py#L78)

### `to_python_code` {#x-to_python_code}

*function* · canonical name `to_python_code`

```python
to_python_code(file: dict[str, Any]) -> str
```

Generate a self-contained Python script from an ESM file.

**Parameters**

- `file` (`dict[str, Any]`) — ESM file dictionary (parsed from JSON)

**Returns**

- `str` — Python script as a string

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/codegen.py#L79)

### `to_sympy` {#x-to_sympy}

*function* · canonical name `to_sympy`

```python
to_sympy(expr: Expr, symbol_map: dict[str, sp.Symbol] | None = None) -> sp.Expr
```

Convert ESM expression to SymPy expression.

Thin wrapper over `_expr_to_sympy` — the single ESM→SymPy
converter shared with the simulation tier (`sympy_bridge.py`) — run
with `structural_ops=True` so the genuine `D` converts to a
`sympy.Derivative` while every open-tier rewrite-target op
(`grad`/`div`/`laplacian`/`curl`/`integral` and any custom op,
all unprivileged) plus `Pre` becomes an opaque `sympy.Function`
placeholder (symbolic-analysis semantics, e.g. for
`symbolic_jacobian`).

Bare string variable names auto-create symbols: any name not present in
`symbol_map` gets a fresh `sympy.Symbol` which is also recorded
in the (caller-visible) map, so repeated references share one symbol.

**Parameters**

- `expr` (`Expr`) — ESM expression to convert
- `symbol_map` (`dict[str, sp.Symbol] | None`) — Optional mapping from variable names to SymPy symbols;
  mutated in place as new symbols are created.

**Returns**

- `sp.Expr` — SymPy expression

**Raises**

- [`SimulationError`](/generated/api/extension/python#x-simulationerror) — If an unsupported expression type or operation is
  encountered, or an operation has the wrong number of arguments.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/expression.py#L732)

### `UnitConversionResult` {#x-unitconversionresult}

*type* · canonical name `unit_conversion_result`

```python
class UnitConversionResult
UnitConversionResult(success: bool, converted_value: float | None = None, conversion_factor: float | None = None, error_message: str | None = None)
```

Result of unit conversion operation.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/units.py#L1164)

### `UnitValidationResult` {#x-unitvalidationresult}

*type* · canonical name `unit_validation_result`

```python
class UnitValidationResult
UnitValidationResult(is_valid: bool, errors: list[str] = list(), warnings: list[str] = list(), unit_registry: dict[str, str] = dict(), dimensional_analysis: dict[str, Any] = dict(), findings: list[UnitFinding] = list())
UnitValidationResult.add_error(code: str, message: str, lhs_units: str = '', rhs_units: str = '') -> None
UnitValidationResult.add_warning(code: str, message: str, lhs_units: str = '', rhs_units: str = '') -> None
```

Result of unit validation check.

**Members**

- `add_error` — Record a hard finding: the prose in `errors`, the code in `findings`.
- `add_warning` — Record an advisory finding: the prose in `warnings`, the code in `findings`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/units.py#L1135)

### `UnitValidator` {#x-unitvalidator}

*type* · canonical name `unit_validator`

```python
class UnitValidator
UnitValidator()
UnitValidator.validate_esm_file(esm_file: EsmFile) -> UnitValidationResult
UnitValidator.validate_model(model: Model, scoped: ScopedUnits | None = None) -> UnitValidationResult
UnitValidator.validate_reaction_system(rs: ReactionSystem, scoped: ScopedUnits | None = None) -> UnitValidationResult
UnitValidator.validate_equation(equation, equation_id: str) -> UnitValidationResult
UnitValidator.validate_expression(expr: Expr, context: str = '') -> UnitValidationResult
UnitValidator.convert_units(value: float, from_unit: str, to_unit: str) -> UnitConversionResult
```

Validator for dimensional consistency in ESM format structures.

**Members**

- `validate_esm_file` — Validate unit consistency across an entire ESM file.
- `validate_model` — Validate unit consistency within a model.
- `validate_reaction_system` — Validate unit consistency within a reaction system.
- `validate_equation` — Validate dimensional consistency of an equation.
- `validate_expression` — Validate dimensional consistency of an expression.
- `convert_units` — Convert a value from one unit to another.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/units.py#L1338)

### `UnsupportedDimensionalityError` {#x-unsupporteddimensionalityerror}

*error* · canonical name `unsupported_dimensionality_error`

```python
class UnsupportedDimensionalityError(FlattenError)
```

The flattened system has a dimensionality the simulator cannot handle.

Raised by esm_problem() when the flattened system still contains a spatial
independent variable. Such a system carries an *undiscretized* spatial
operator (a spatial `D` or `grad`/`div`/`laplacian` sugar) that no
discretization rule reduced to a stencil, so it surfaces the uniform
cross-binding `code = "unlowered_operator"` diagnostic (esm-spec §4.2 /
§9.6.8).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/flatten.py#L231)

### `UnsupportedVersionError` {#x-unsupportedversionerror}

*error* · canonical name `unsupported_version_error`

```python
class UnsupportedVersionError(EarthSciAstError)
```

Exception raised when ESM version is not supported.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/parse.py#L117)
