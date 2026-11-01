---
title: "flattened_system"
description: "Stable type · Flatten"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Flatten](/generated/api/topics/flatten)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `FlattenedSystem` | `FlattenedSystem` | `FlattenedSystem` | `FlattenedSystem` | `FlattenedSystem` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct FlattenedSystem
FlattenedSystem(ivs, sv, p, obs, eqs, cev, dev, dom, meta, isets, ftabs, treg, alg, brw, disc, ics, lfs, lshapes, contribs)
FlattenedSystem(ivs, sv, p, obs, eqs, cev, dev, dom, meta)
FlattenedSystem(ivs, sv, p, obs, eqs, cev, dev, dom, meta, isets, ftabs)
FlattenedSystem(ivs, sv, p, obs, eqs, cev, dev, dom, meta, isets, ftabs, treg)
FlattenedSystem(ivs, sv, p, obs, eqs, cev, dev, dom, meta, isets, ftabs, treg, alg, brw, disc, ics, lfs, lshapes)
FlattenedSystem(flat::FlattenedSystem; independent_variables, state_variables, parameters, observed_variables, equations, continuous_events, discrete_events, domain, metadata, index_sets, function_tables, template_registry, algebraic_variables, brownian_parameters, discrete_parameters, field_ics, loader_fields, lifted_shapes, equation_contributions)
```

```julia
FlattenedSystem
```

A coupled ESM file flattened into a single symbolic representation.

All variables, parameters, and species are dot-namespaced (e.g.
`"SimpleOzone.O3"`, `"Atmosphere.Chemistry.NO2"`). Equations are real
`Equation` objects whose ASTExpr trees reference namespaced names via `VarExpr`.
This is the canonical intermediate form consumed by MTK/PDESystem constructors
(in the Julia extension) and by cross-language code generators.

Fields:
- `independent_variables::Vector{Symbol}`: `[:t]` for pure-ODE systems, or
  `[:t, :x, :y, ...]` when spatial operators are present.
- `state_variables::OrderedDict{String, ModelVariable}`: the SOLVED-FOR VECTOR —
  namespaced state variables and species (from lowered reactions), PLUS
  `algebraic_variables`, PLUS any arrayed observed that materializes into a
  buffer (esm-libraries-spec §4.7.5 step 4).
- `parameters::OrderedDict{String, ModelVariable}`: namespaced parameters,
  minus any promoted to variables by `variable_map`.
- `observed_variables::OrderedDict{String, ModelVariable}`: the namespaced
  unknowns an equation DEFINES, at either LHS spelling (esm-spec §6.3.1). NOT
  disjoint from `state_variables`: a scalar observed is eliminated by
  substitution and is in this map alone, while an arrayed one materializes into
  a buffer and is in both.
- `equations::Vector{Equation}`: all equations after reaction lowering and
  coupling, with variable references rewritten to namespaced form.
- `continuous_events::Vector{ContinuousEvent}`: collected from every source
  model with references rewritten.
- `discrete_events::Vector{DiscreteEvent}`: ditto.
- `domain::Union{Domain, Nothing}`: the target domain after any dimension
  promotion (§4.7.6), or `nothing` for purely 0D systems.
- `metadata::FlattenMetadata`: provenance.
- `index_sets::OrderedDict{String, IndexSet}`: the merged document-scoped
  index-set registry (RFC semiring-faq-unified-ir §5.2), collected from every
  source model and namespaced per-component (`<prefix>.<setname>`) so the value-
  invention geometry of sibling components — e.g. five conservative regridders
  each declaring `src_cells` / `candidate_pairs` / `clip_ring` — does not
  collide after flattening. Empty when no source model declares any.
- `function_tables::Dict{String, FunctionTable}`: the file-scoped sampled
  function tables (esm-spec §9.5) referenced by `table_lookup` AST nodes. These
  are keyed by globally-unique table id, so they are merged without namespacing.
  Empty when the file declares none. Carrying both here is what lets a flattened
  system round-trip back into a runnable single-model `EsmFile` (`flattened_to_esm`)
  without dropping the geometry registry or the table data.
- `template_registry::OrderedDict{String, Any}`: the merged expression-template
  registry (esm-spec §9.6.4 rule 7 / §10.7).
- `algebraic_variables::OrderedDict{String, ModelVariable}`: unknowns constrained
  only by an expression-LHS equation (esm-spec §6.3.1). A **subset** of
  `state_variables`, not a sibling bucket — a DAE solves for them, so they occupy
  a slot of the `u` vector.
- `brownian_parameters::OrderedDict{String, ModelVariable}`: `update.kind ==
  "wiener"`. A **subset** of `parameters`. This bucket is what makes the flattened
  form self-describing: §6.3.1's `system_kind` derivation tests it FIRST, so a
  `FlattenedSystem` that dropped it could not report `"sde"` and a consumer would
  integrate a stochastic system as a deterministic one.
- `discrete_parameters::OrderedDict{String, ModelVariable}`: any other `update`.
  A **subset** of `parameters`.
- `field_ics::Vector{Pair{String, ASTExpr}}`: deferred `ic` equations (esm-spec
  §11.4.1), REMOVED from `equations`.
- `loader_fields::Vector{LoaderField}`: provider-served loaded fields the system
  consumes (esm-spec §8.5).
- `lifted_shapes::OrderedDict{String, Vector{Int}}`: post-lift grid extents for
  arrayed states (§10.5).
- `equation_contributions::Vector{Vector{Contribution}}`: per-term provenance
  (esm-libraries-spec §4.7.5), parallel to `equations`. Entry `i` lists the
  [`Contribution`](/generated/api/ref/contribution)s whose left-fold sum is equation `i`'s right-hand side
  (its `faq` body when the pointwise lift wrapped it), each with the
  [`TermOrigin`](/generated/api/ref/term_origin)s that authored it. `eq_owners` inside `flatten` is the
  slot owner a later merge reads, not this. Read it with
  [`equation_contributions`](/generated/api/extension/julia#x-equation_contributions).

ORDERING (esm-libraries-spec §4.7.5 step 4, normative): every ordered map and
list above is in DOCUMENT ORDER — components in the order the file declares them,
variables in the order their component declares them, coupling-merged entries
keeping the position of their first occurrence. Ordering is observable, because a
parameter vector is positional; lexicographic sorting or a host map's iteration
order is non-conforming. The order therefore has to be preserved at the SOURCE:
`EsmFile.models` / `.reaction_systems` / `.index_sets` / `.function_tables` and
`Model.variables` / `.subsystems` are `OrderedDict`s populated by the parser in
document order, so the accumulators here inherit it.

---

```julia
FlattenedSystem(flat::FlattenedSystem; kwargs...) -> FlattenedSystem
```

Keyword copy-constructor: rebuild a `FlattenedSystem`, copying every field from
`flat` by default and overriding only the keywords explicitly passed. Route all
copy-with-changes transforms (e.g. the shape-promotion passes) through this so
a newly added field is preserved by default instead of silently dropped by an
11-positional-argument re-listing.

`equation_contributions` is parallel to `equations`, so it is not copied when
`equations` is replaced alone: it RESETS to one contribution per equation (its
body) with EMPTY origins, "author unknown" (esm-libraries-spec §4.7.5). A stale
list must not survive a caller's edit. A pass that keeps provenance passes both.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/flatten.jl#L116)

**Example** (`flatten`)

```julia
doc = load_path(joinpath(FIXTURES, "coupled.esm"))
sys = flatten(doc)
@assert sys isa FlattenedSystem

# Every name is qualified by the component it came from.
@assert collect(keys(sys.state_variables)) == ["Heater.T", "Box.T_air"]
# The param_to_var variable_map replaced the parameter Box.T_wall with the
# state Heater.T, so Box.T_wall is not a parameter of the flattened system...
@assert collect(keys(sys.parameters)) == ["Heater.rate", "Box.k"]

# ...and the equations read Heater.T where Box.T_wall was.
equations = [to_ascii(eq) for eq in sys.equations]
foreach(println, equations)
@assert equations == [
    "D(Heater.T)/Dt = Heater.rate",
    "D(Box.T_air)/Dt = Box.k * (Heater.T - Box.T_air)",
]
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/julia/coupling.jl#L7-L23">docs/api/examples/julia/coupling.jl</a></p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
interface FlattenedSystem {
    independentVariables: string[];
    stateVariables: FlattenedVariableMap;
    parameters: FlattenedVariableMap;
    observedVariables: FlattenedVariableMap;
    algebraicVariables: FlattenedVariableMap;
    brownianParameters: FlattenedVariableMap;
    discreteParameters: FlattenedVariableMap;
    equations: FlattenedEquation[];
    continuousEvents: ContinuousEvent[];
    discreteEvents: DiscreteEvent[];
    domain: Domain | null;
    metadata: FlattenMetadata;
    indexSets: Record<string, unknown>;
    functionTables: Record<string, unknown>;
    templateRegistry: Record<string, unknown>;
    fieldIcs: FieldInitialCondition[];
    loaderFields: LoaderField[];
    liftedShapes: Record<string, number[]>;
    systemKind: SystemKind;
}
```

A fully flattened representation of a coupled ESM system — the canonical
field set of esm-libraries-spec §4.7.5 step 4.

WHICH unknowns are observed is `observedVariables`, and each one's
DEFINING EXPRESSION is its equation in `equations`, as an AST. A
coupling `variable_map` performs its substitution in place, so its effect is
visible in `equations` and `parameters` rather than in a side table.

Python exposes a `variables` property (namespaced name -> role label); this
binding has no field of that name.

**Properties**

- `independentVariables` — Always contains `"t"`. A spatial axis appears only while an UNDISCRETIZED
  spatial differential still names it, so a discretized (array) system stays a
  pure ODE.
- `stateVariables` — The SOLVED-FOR VECTOR: every unknown the solver advances or solves for —
  differential unknowns, PLUS `algebraicVariables`, PLUS any arrayed
  observed that materializes into a buffer. NOT esm-spec §6.3.1's `odeStates`.
- `parameters` — ALL parameters of every cadence, minus any promoted by `variable_map`.
- `observedVariables` — Unknowns DEFINED by an equation naming them on its LHS (esm-spec §6.3.1).
- `algebraicVariables` — Unknowns CONSTRAINED only by an expression-LHS equation. A SUBSET of
  `stateVariables` — a DAE solves for them.
- `brownianParameters` — Parameters whose `update.kind` is `"wiener"` — the SDE noise sources. A
  SUBSET of [`parameters`](/generated/api/ref/parameters), not a sibling bucket (esm-spec §6.3.1).
- `discreteParameters` — Parameters carrying any OTHER `update`. A SUBSET of [`parameters`](/generated/api/ref/parameters).
- `equations` — The governing equations — dynamics and constraints — coupling applied,
  dot-namespaced. Entries classified out into `fieldIcs` are REMOVED.
- `continuousEvents` — Continuous events, dot-namespaced.
- `discreteEvents` — Discrete events, dot-namespaced.
- `domain` — The file's `domain` section, unchanged, or `null`.
- `metadata` — Provenance metadata.
- `indexSets` — Document-scoped index-set registry; required to interpret arrayed equations.
- `functionTables` — Merged function-table registry; resolves `table_lookup`.
- `templateRegistry` — The MERGED expression-template registry (esm-spec §9.6.4 rule 7, §10.7):
  the union of the component registries with their bodies component-scoped
  FIRST, deep-equal same-name entries deduplicated at first occurrence, and
  non-deep-equal collisions renamed along the reference DAG.
- `fieldIcs` — Deferred scoped-reference / array `ic` equations (esm-spec §11.4.1).
- `loaderFields` — Provider-served loaded fields the system consumes.
- `liftedShapes` — Post-lift grid shapes for arrayed states, e.g. `{ "Chemistry.O3": [4, 2] }`.
- `systemKind` — The system kind DERIVED from the FLATTENED system (esm-spec §6.3.1),
  testing `brownianParameters` FIRST — which is exactly why that bucket must
  survive flattening.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/flatten.ts#L415)

**Example** (`flatten`)

```typescript
const doc = loadPath(fixture('coupled.esm'))
const flat = flatten(doc)

// Variables are namespaced by the system that declared them.
assert.deepEqual(Object.keys(flat.stateVariables), ['Heater.T', 'Box.T_air'])
assert.deepEqual(Object.keys(flat.parameters), ['Heater.rate', 'Box.k'])
assert.equal(flat.stateVariables['Box.T_air'].units, 'K')

// The `param_to_var` variable_map replaces the box's wall-temperature
// parameter with the heater's temperature: `Box.T_wall` is gone from the
// parameters above, and the box equation reads `Heater.T` in its place.
const equations = flat.equations.map((eq) => toAscii(eq))
assert.deepEqual(equations, [
  'D(Heater.T)/Dt = Heater.rate',
  'D(Box.T_air)/Dt = Box.k * (Heater.T - Box.T_air)',
])
assert.deepEqual(
  flat.equations.map((eq) => eq.sourceSystem),
  ['Heater', 'Box'],
)
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/typescript/flatten.ts#L9-L28">docs/api/examples/typescript/flatten.ts</a></p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class FlattenedSystem
FlattenedSystem(independent_variables: list[str] = (lambda: ['t'])(), state_variables: OrderedDict[str, FlattenedVariable] = OrderedDict(), parameters: OrderedDict[str, FlattenedVariable] = OrderedDict(), observed_variables: OrderedDict[str, FlattenedVariable] = OrderedDict(), equations: list[FlattenedEquation] = list(), continuous_events: list[ContinuousEvent] = list(), discrete_events: list[DiscreteEvent] = list(), domain: Domain | None = None, metadata: FlattenMetadata = FlattenMetadata(), index_sets: dict[str, Any] = dict(), loader_fields: list[LoaderField] = list(), lifted_shapes: dict[str, tuple[int, ...]] = dict(), _infer_shapes_cache: dict[str, tuple[int, ...]] | None = None, algebraic_variables: OrderedDict[str, FlattenedVariable] = OrderedDict(), brownian_parameters: OrderedDict[str, FlattenedVariable] = OrderedDict(), discrete_parameters: OrderedDict[str, FlattenedVariable] = OrderedDict(), function_tables: dict[str, Any] = dict(), template_registry: dict[str, Any] = dict(), field_ics: list[tuple[str, Expr]] = list(), initialization_faqs: list[tuple[str, Expr]] = list())
FlattenedSystem.system_kind: str  # property
FlattenedSystem.variables: dict[str, str]  # property
```

The result of flattening an EsmFile per spec §4.7.5.

**Fields**

- `independent_variables` — Independent variables of the flattened system. Always contains `"t"`
  for temporal evolution; spatial independent variables (`"x"`, `"y"`,
  `"z"`) appear only when the equations contain spatial derivative
  operators (`grad`, `div`, `laplacian`).
- `state_variables` — The SOLVED-FOR VECTOR, keyed by dot-namespaced name: the differential
  unknowns, PLUS `algebraic_variables`, PLUS any arrayed observed that
  materializes into a buffer (esm-libraries-spec §4.7.5 step 4).
- `parameters` — Dot-namespaced parameters, keyed by their namespaced name.
  Parameters promoted to variables by `variable_map` are removed.
- `observed_variables` — The dot-namespaced unknowns an equation DEFINES, at either LHS spelling
  (esm-spec §6.3.1). NOT disjoint from `state_variables`: a scalar
  observed is eliminated by substitution and is in this map alone, while
  an arrayed one materializes into a buffer and is in both.
- `equations` — Flattened equations as Expr trees.
- `continuous_events` — Continuous events, with variable references rewritten to dot-namespaced
  form.
- `discrete_events` — Discrete events, similarly namespaced.
- `domain` — The file's `domain` section, if any (passed through unchanged).
- `metadata` — Provenance about which systems were flattened and which rules applied.

Backwards-compatibility helpers (`variables` dict and string-keyed
helpers) are exposed via properties so existing call sites continue to work.

**Members**

- `system_kind` — The flattened system's derived MTK system kind (esm-spec §6.3.1), computed by [`classification.system_kind`](/generated/api/ref/system_kind-function) over the flattened variables and equations — "sde" / "pde" / "nonlinear" / "ode", tested in that order.
- `variables` — Type label by namespaced name (compat with the old FlattenedSystem).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/flatten.py#L507)

**Example** (`flatten`)

```python
coupled = earthsci_ast.load_path(FIXTURES / "coupled.esm")
flat = earthsci_ast.flatten(coupled)

# Every name is now qualified by the model it came from.
assert list(flat.state_variables) == ["Heater.T", "Box.T_air"]
assert {"Heater.rate", "Box.k"} <= set(flat.parameters)
for name, var in flat.state_variables.items():
    print(f"{name}: {var.units}, default {var.default}")

for eq in flat.equations:
    print(eq.lhs_str, "=", eq.rhs_str)
heater, box = flat.equations
assert earthsci_ast.to_ascii(heater.rhs) == "Heater.rate"

# The param_to_var variable_map replaced the box's wall-temperature parameter
# with the heater's temperature: it is gone from the equations AND from the
# parameters.
assert earthsci_ast.to_ascii(box.rhs) == "Box.k * (Heater.T - Box.T_air)"
assert "Box.T_wall" not in earthsci_ast.free_variables(box.rhs)
assert "Box.T_wall" not in flat.parameters
assert flat.metadata.source_systems == ["Heater", "Box"]
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/python/flatten.py#L11-L31">docs/api/examples/python/flatten.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct FlattenedSystem {
    pub independent_variables: Vec<String>,
    pub state_variables: IndexMap<String, ModelVariable>,
    pub parameters: IndexMap<String, ModelVariable>,
    pub observed_variables: IndexMap<String, ModelVariable>,
    pub algebraic_variables: IndexMap<String, ModelVariable>,
    pub brownian_parameters: IndexMap<String, ModelVariable>,
    pub discrete_parameters: IndexMap<String, ModelVariable>,
    pub field_ics: Vec<(String, Expr)>,
    pub equations: Vec<Equation>,
    pub equation_contributions: Vec<Vec<Contribution>>,
    pub equation_lifted: Vec<bool>,
    pub continuous_events: Vec<ContinuousEvent>,
    pub discrete_events: Vec<DiscreteEvent>,
    pub domain: Option<Domain>,
    pub index_sets: IndexMap<String, IndexSet>,
    pub function_tables: IndexMap<String, FunctionTable>,
    pub template_registry: IndexMap<String, Value>,
    pub loader_fields: Vec<LoaderField>,
    pub lifted_shapes: IndexMap<String, Vec<i64>>,
    pub metadata: FlattenMetadata,
}

impl FlattenedSystem { pub fn system_kind(&self) -> SystemKind }
```

Spec-compliant flattened coupled system (§4.7.5).

The shape matches the Julia and Python flattened systems:
real [`Expr`](/generated/api/ref/expr)-tree equations (not strings), ordered variable maps for
deterministic iteration, and full provenance metadata.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/flatten.rs#L498) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.FlattenedSystem.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type FlattenedSystem struct {
	// IndependentVariables is ["t"] for a discretized system; an undiscretized
	// spatial differential adds the axes it names.
	IndependentVariables []string
	// StateVariables is the SOLVED-FOR VECTOR: every unknown the solver
	// advances or solves for — differential unknowns (including every reaction
	// species, which gets a derived D equation), PLUS AlgebraicVariables, PLUS
	// any arrayed observed that materializes into a buffer. NOT the same set as
	// esm-spec §6.3.1's ode_states.
	StateVariables []FlattenedVariable
	// Parameters is ALL parameters of every cadence, minus any promoted to
	// variables by `variable_map`.
	Parameters []FlattenedVariable
	// ObservedVariables are the unknowns an equation DEFINES, at either LHS
	// spelling (esm-spec §6.3.1). A SCALAR observed is eliminated by
	// substitution into its consumers and is NOT in StateVariables; an ARRAYED
	// one materializes into a buffer and IS, so the two lists are not a
	// partition (esm-libraries-spec §4.7.5 step 4).
	ObservedVariables []FlattenedVariable
	// AlgebraicVariables are the unknowns constrained only by an expression-LHS
	// equation. A SUBSET of StateVariables.
	AlgebraicVariables []FlattenedVariable
	// BrownianParameters are the parameters whose `update.kind` is "wiener" —
	// the SDE noise sources. A SUBSET of Parameters, not a sibling bucket:
	// SystemKind tests this bucket FIRST, so dropping it forfeits "sde".
	BrownianParameters []FlattenedVariable
	// DiscreteParameters are the parameters carrying any other `update`. A
	// SUBSET of Parameters.
	DiscreteParameters []FlattenedVariable
	// Equations are the governing equations — dynamics and constraints — with
	// coupling applied and variables dot-namespaced. Entries classified out into
	// FieldICs are REMOVED from this list.
	Equations []FlattenedEquation
	// ContinuousEvents / DiscreteEvents are the components' events,
	// dot-namespaced. They were one untyped `Events []any` bucket, which no
	// other binding has and which no consumer could dispatch on without a type
	// switch.
	ContinuousEvents []ContinuousEvent
	DiscreteEvents   []DiscreteEvent
	// Domain is the file's `domain` section, unchanged.
	Domain *Domain
	// Metadata records which components were flattened and which coupling rules
	// applied.
	Metadata FlattenMetadata
	// IndexSets is the document-scoped index-set registry, required to interpret
	// arrayed equations.
	IndexSets []FlattenedIndexSet
	// FunctionTables is the merged function-table registry; it resolves a
	// surviving `table_lookup`. Flattening deliberately does NOT lower those
	// nodes (esm-spec §9.5.3 / §9.5.4 — see lower_table_lookup.go), so this
	// registry is what makes them evaluable: (*FlattenedSystem).Evaluate lowers
	// against it.
	FunctionTables []FlattenedFunctionTable
	// TemplateRegistry is the merged expression-template registry (esm-spec
	// §9.6.4 rule 7, §10.7).
	TemplateRegistry []FlattenedTemplate
	// FieldICs are the deferred scoped-reference / array `ic` equations
	// (esm-spec §11.4.1), removed from Equations.
	FieldICs []FieldIC
	// LoaderFields are the provider-served loaded fields the system consumes.
	LoaderFields []LoaderField
	// LiftedShapes are the post-lift grid shapes for arrayed states.
	LiftedShapes []LiftedShape
}

func (f *FlattenedSystem) DeclaredTypes() map[string]string

func (f *FlattenedSystem) Evaluate(expr Expression, bindings map[string]float64) (float64, error)

func (f *FlattenedSystem) InitialValues() map[string]float64

func (f *FlattenedSystem) Lookup(name string) (FlattenedVariable, bool)

func (f *FlattenedSystem) SystemKind() string
```

FlattenedSystem is a coupled system flattened into a single system — the canonical intermediate form between an ESMFile and any downstream consumer, and the API boundary all of graph construction, validation and simulation export operate on.

Field-by-field this is esm-libraries-spec §4.7.5 step 4's normative table, transliterated per API\_SPEC.md §2. Each `name → variable` ordered map is spelled as a SLICE of FlattenedVariable: a Go map has no order, and order is part of the contract, so the slice IS the ordered map and Lookup gives the by-name access. See the file header for the ordering and subset rules.

**Methods**

```go
func (f *FlattenedSystem) DeclaredTypes() map[string]string
```

DeclaredTypes maps every flattened variable's namespaced name to its DECLARED esm 1.0.0 type ("unknown" / "parameter").

It is a derived VIEW, not a field, because the canonical field set has no room for a second, unordered, less informative copy of the three variable lists; a caller that wants the derived role or the metadata reads those.

```go
func (f *FlattenedSystem) Evaluate(expr Expression, bindings map[string]float64) (float64, error)
```

Evaluate numerically evaluates expr with the flattened system's merged function-table registry in scope. Flattening does not lower `table_lookup` (see the file header), so this is what resolves the surviving node against the FunctionTables the flattened system carries for exactly that purpose.

```go
func (f *FlattenedSystem) InitialValues() map[string]float64
```

InitialValues maps each state variable to its initial value: the declared scalar `default`, or 0.0 when it declares none.

Every state variable carries its own `default` (of any type) in StateVariables; this method is the numeric projection of those defaults.

```go
func (f *FlattenedSystem) Lookup(name string) (FlattenedVariable, bool)
```

Lookup returns the flattened variable with the given namespaced name, searching the state, parameter and observed maps in that order. It is the by-name half of the ordered maps the slices above spell.

```go
func (f *FlattenedSystem) SystemKind() string
```

SystemKind is the flattened system's derived MTK system kind (esm-spec §6.3.1): "sde" / "pde" / "nonlinear" / "ode", tested in that order.

It is available on the flattened form precisely because BrownianParameters survives flattening — the derivation's first row is "any parameter in brownian\_parameters", so a FlattenedSystem that dropped the bucket could not report "sde" and a consumer would integrate a stochastic system as a deterministic one.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/flatten.go#L430) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#FlattenedSystem)

</div>

</div>
