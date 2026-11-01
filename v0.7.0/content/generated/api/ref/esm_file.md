---
title: "esm_file"
description: "Stable type · Document types"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Document types](/generated/api/topics/document-types)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `EsmFile` | not exported | `EsmFile` | `EsmFile` | `ESMFile` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct EsmFile
EsmFile(esm::String, metadata::Metadata; models, reaction_systems, data_sources, coupling, domain, enums, function_tables, index_sets, expression_templates, metaparameters, component_templates, coordinates, coupling_roles, solver, document_base)
```

```julia
EsmFile
```

Main ESM file structure containing all components.

`models`, `reaction_systems`, `index_sets`, `function_tables` and
`component_templates` are `OrderedDict`s populated by the parser in DOCUMENT
ORDER — see [`Model`](/generated/api/ref/model) for why, and esm-libraries-spec §4.7.5 step 4 for the
normative rule.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/types.jl#L2377)

**Example** (`load`)

```julia
doc = load_path(joinpath(FIXTURES, "decay.esm"))
@assert doc isa EsmFile
@assert collect(keys(doc.models)) == ["Decay"]

# The same document from a JSON string already in memory.
json = read(joinpath(FIXTURES, "decay.esm"), String)
from_string = load_string(json)
@assert collect(keys(from_string.models)) == ["Decay"]
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/docs/api/examples/julia/documents.jl#L7-L14">docs/api/examples/julia/documents.jl</a></p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this type.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class EsmFile
EsmFile(version: str, metadata: Metadata, models: dict[str, Model] = dict(), reaction_systems: dict[str, ReactionSystem] = dict(), events: list[ContinuousEvent | DiscreteEvent] = list(), data_sources: dict[str, DataSource] = dict(), operators: list[Operator] = list(), registered_functions: dict[str, RegisteredFunction] = dict(), coupling: list[CouplingEntry] = list(), enums: dict[str, dict[str, int]] = dict(), function_tables: dict[str, FunctionTable] = dict(), domain: Domain | None = None, index_sets: dict[str, Any] = dict(), coordinates: dict[str, Any] = dict(), solver: Solver | None = None, expression_templates: dict[str, Any] = dict(), coupling_roles: dict[str, Any] = dict(), metaparameters: dict[str, Any] = dict(), component_templates: dict[str, Any] = dict(), coupling_import_base: str | None = None, document_base: str | None = None)
EsmFile.esm: str  # property
```

Root container for an ESM format file.

**Members**

- `esm` — Alias for version field (matches JSON 'esm' key).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/esm_types.py#L1331)

**Example** (`inspect`)

```python
model = doc.models["Decay"]
for name, var in model.variables.items():
    print(f"{name}: {var.type} [{var.units}]")
assert {n: v.type for n, v in model.variables.items()} == {
    "N": "unknown",
    "lambda": "parameter",
    "half_life": "unknown",
}

# The file declares only "unknown" and "parameter"; the finer classes are derived.
assert earthsci_ast.ode_states(model) == ["N"]
assert earthsci_ast.observed_unknowns(model) == ["half_life"]
assert earthsci_ast.algebraic_unknowns(model) == []
assert earthsci_ast.constant_parameters(model) == ["lambda"]
assert earthsci_ast.unknowns(model) == ["N", "half_life"]
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/docs/api/examples/python/documents.py#L68-L82">docs/api/examples/python/documents.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct EsmFile {
    pub esm: String,
    pub metadata: Metadata,
    pub index_sets: Option<IndexMap<String, IndexSet>>,
    pub coordinates: Option<IndexMap<String, Coordinate>>,
    pub solver: Option<Solver>,
    pub expression_templates: Option<Value>,
    pub metaparameters: Option<Value>,
    pub models: Option<IndexMap<String, Model>>,
    pub reaction_systems: Option<IndexMap<String, ReactionSystem>>,
    pub data_sources: Option<IndexMap<String, DataSource>>,
    pub operators: Option<IndexMap<String, Operator>>,
    pub enums: Option<IndexMap<String, IndexMap<String, i64>>>,
    pub coupling: Option<Vec<CouplingEntry>>,
    pub coupling_roles: Option<IndexMap<String, CouplingRole>>,
    pub domain: Option<Domain>,
    pub function_tables: Option<IndexMap<String, FunctionTable>>,
    pub component_templates: Option<IndexMap<String, Value>>,
    pub coupling_import_base: Option<String>,
    pub document_base: Option<String>,
}
```

Top-level ESM file structure

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/types/document.rs#L8) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.EsmFile.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type ESMFile struct {
	ESM             string                    `json:"esm"`
	Metadata        Metadata                  `json:"metadata"`
	Models          map[string]Model          `json:"models,omitempty"`
	ReactionSystems map[string]ReactionSystem `json:"reaction_systems,omitempty"`
	// DataSources is the document-scoped ingest registry (esm-spec 8). It is
	// NOT a map of components: nothing here can be coupled, subsystem'd, or used
	// as a scoped-reference path root.
	DataSources map[string]DataSource `json:"data_sources,omitempty"`
	// Enums holds file-local symbol → integer mappings used by the
	// `enum` AST op (esm-spec §9.3). Each entry is an enum name; its value is
	// a map from symbolic names (strings) to integers — ANY integer, negative,
	// zero or positive, since a member is a categorical code and not a 1-based
	// position (CONFORMANCE_SPEC, "An `enums` Member Is a Code, Not a
	// Position"). Lowering (resolution to `const`-op
	// integers) happens at load time.
	Enums    map[string]map[string]int `json:"enums,omitempty"`
	Coupling []CouplingEntry           `json:"coupling,omitempty"` // deserialized coupling entries (discriminated union)
	// CouplingRoles is present only in a coupling-library file (esm-spec §10.9):
	// the map of formal component roles a role-scoped `coupling` array wires.
	// Presence of this key is the sole positive identifier of the
	// coupling-library file kind (see isCouplingLibraryDoc). An assembly file
	// never declares it.
	CouplingRoles map[string]CouplingRole `json:"coupling_roles,omitempty"`
	// Domain is the single temporal domain shared by every component in the
	// document. A document has at most one domain. See esm-spec §11.
	Domain *Domain `json:"domain,omitempty"`
	// FunctionTables holds top-level sampled function tables (esm-spec §9.5,
	// v0.4.0). Each entry is a FunctionTable referenced by `table_lookup` AST
	// op nodes via its key.
	FunctionTables map[string]FunctionTable `json:"function_tables,omitempty"`
	// IndexSets is the document-scoped registry of named index sets
	// (RFC semiring-faq-unified-ir §5.2), keyed by name — the single,
	// document-level declaration site for every iteration domain shared by all
	// models in the document. A `faq` range references one by name as
	// { "from": <name> } and arrayed-variable `shape` lists draw dimension
	// names from it. As of v0.8.0 this moved from a per-Model field to
	// document scope: one registry, shared by every model.
	IndexSets map[string]IndexSet `json:"index_sets,omitempty"`
	// Coordinates is the document-scoped, OPTIONAL registry of coordinate
	// variables (RFC streaming-output-sinks §8), keyed by name. Purely additive:
	// a document without it emits exactly as before, which is why it is
	// `omitempty` — materializing `"coordinates": {}` on every coordinate-less
	// document would be pure noise. Go modelled no field for it at all, so
	// `json.Unmarshal` dropped the whole block at parse and the emitter had
	// nothing to emit: the CF metadata that tells an output writer which arrays
	// are latitude and longitude was silently deleted by a load → save.
	Coordinates map[string]Coordinate `json:"coordinates,omitempty"`
	// SolverHints is the document-scoped, OPTIONAL and purely ADVISORY solver
	// block (esm-spec §2.2): stiffness, integration tolerances and a splitting
	// hint the document knows about itself. Purely additive — presence changes
	// no equations, no classification and no flattened system — which is why it
	// is `omitempty`: materializing `"solver": {}` on every document without one
	// would be noise. An empty block is LEGAL in the schema (§2.2) and means
	// exactly what absence means, so `normalizeSolver` maps it to nil at decode
	// — `omitempty` on a POINTER tests nil only, so without that a decoded
	// `&Solver{}` would re-emit as `"solver": {}` while Python and Julia dropped
	// it.
	//
	// Named SolverHints rather than Solver so the FIELD does not collide with
	// the Solver TYPE in this package.
	SolverHints *Solver `json:"solver,omitempty"`
	// Metaparameters is the top-level §9.7.1 metaparameter declaration block, and
	// ExpressionTemplates the top-level rewrite-rule registry — the payload of a
	// template-library file (§9.7.1).
	//
	// Both are DECLARATIONS — peers of `index_sets` — not `apply_expression_template`
	// CALL SITES, and esm-spec §9.6.4 rule 5 requires them to survive `parse → emit`
	// VERBATIM: a template-library file MUST round-trip to itself. They are held as
	// raw JSON precisely so that "verbatim" is literal — canonicalizeValue preserves
	// a json.RawMessage as-authored rather than re-encoding it.
	//
	// Go used to model neither field, so `json.Unmarshal` silently DROPPED both keys
	// at parse and the emitter could not emit what it had never kept. A pure library
	// file re-emitted as `{esm, metadata, index_sets}` — carrying NONE of the five
	// top-level payload keys the schema's `anyOf` requires — so a conforming library
	// file was unrepresentable: legal on disk, illegal the moment it was loaded and
	// re-emitted (tests/valid/template_import_lib.esm,
	// tests/valid/template_import_rename_lib.esm).
	Metaparameters      json.RawMessage `json:"metaparameters,omitempty"`
	ExpressionTemplates json.RawMessage `json:"expression_templates,omitempty"`
	// contains filtered or unexported fields
}

func (e *ESMFile) Evaluate(expr Expression, bindings map[string]float64) (float64, error)

func (e *ESMFile) ToJSON() ([]byte, error)

func (esm *ESMFile) UnmarshalJSON(data []byte) error

func (e *ESMFile) ValidateStruct() error
```

ESMFile represents the top-level ESM file structure

**Methods**

```go
func (e *ESMFile) Evaluate(expr Expression, bindings map[string]float64) (float64, error)
```

Evaluate numerically evaluates expr with THIS DOCUMENT's §9.5 function tables in scope: every `table_lookup` is lowered to its §9.5.3 closed-function form first, then the ordinary scalar evaluator runs.

It is the document-scoped counterpart of the package-level Evaluate, which takes only an expression and therefore cannot resolve a `table_lookup` at all — the table registry lives in the document. Reaching for the package-level one on a document's own equation is what made a `table_lookup` observed unevaluable while its hand-lowered twin worked (issue #188).

```go
func (e *ESMFile) ToJSON() ([]byte, error)
```

ToJSON converts the ESM file to canonical (indented) JSON bytes.

Unlike Serialize (serialize.go), ToJSON does NOT run (\*ESMFile).ValidateStruct first — it serializes whatever it is given. Callers that need the file validated before emission should use Serialize (which returns a string) or call ValidateStruct explicitly; ToJSON exists for the raw byte form and for round-trip paths that have already validated.

```go
func (esm *ESMFile) UnmarshalJSON(data []byte) error
```

Custom JSON unmarshaling for ESMFile

```go
func (e *ESMFile) ValidateStruct() error
```

ValidateStruct checks the field-level invariants of the ESM file (the required `esm` version string) plus the "at least one component present" invariant. It is intentionally named distinctly from the package-level semantic validator Validate(\*ESMFile) (validate.go), which performs the richer structural/reference/unit checks — the two are different layers.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/types.go#L1243) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ESMFile)

</div>

</div>
