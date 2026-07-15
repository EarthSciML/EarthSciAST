# ESM Library Specification

**Companion Libraries for the EarthSciML Serialization Format — Version 0.1.0 Draft**

## 1. Overview

This document specifies the requirements and architecture for libraries that read, write, manipulate, validate, and optionally simulate models defined in the ESM format (`.esm` files). Each library must provide a consistent developer experience in its host language while mapping faithfully to the ESM JSON Schema.

**Companion schema:** The authoritative type definitions, operator enums, and structural constraints are in [`esm-schema.json`](esm-schema.json) (same directory as this document). This spec describes behavior, algorithms, and API surfaces; the schema is the single source of truth for field names, types, required properties, and allowed values.

### 1.1 Design Goals

1. **Fidelity** — Round-trip an `.esm` file through load → manipulate → save without information loss.
2. **Readability** — Render models as human-readable mathematical notation (Unicode, LaTeX, or MathML).
3. **Editability** — Programmatic manipulation of models: substitution, simplification, adding/removing components.
4. **Validation** — Schema validation, structural consistency checks, and unit analysis.
5. **Interoperability** — Libraries in different languages produce and consume identical `.esm` files.
6. **Simulation** (desired) — Convert ESM models into runnable ODE/SDE/jump problems where feasible.

### 1.2 Capability Tiers

Each library implementation is classified into tiers:

| Tier | Capabilities | Required for |
|---|---|---|
| **Core** | Parse, serialize, pretty-print, substitute, validate schema, flatten coupled systems to single equation system with dot-namespaced variables | All languages |
| **Analysis** | Unit checking, equation counting, stoichiometric matrix computation, conservation law detection | All languages |
| **Interactive** | Click-to-edit expressions, structural editing, undo/redo, coupling graph, web component export | `earthsci-ast-editor` (SolidJS) |
| **Simulation** | Convert to native ODE system and solve numerically; Julia converts flattened system to MTK `ODESystem` or `PDESystem` depending on dimensionality | Julia (MTK), Python (SymPy + SciPy), optionally others |
| **Full** | Bidirectional MTK/Catalyst conversion, coupled system assembly, operator dispatch | Julia only (initially) |

---

## 2. Common Architecture

All libraries share the same conceptual layering regardless of implementation language.

### 2.1 Layer Diagram

```
┌─────────────────────────────────────────────┐
│              User-Facing API                │
│  load() / save() / display() / substitute() │
├─────────────────────────────────────────────┤
│            Validation Layer                  │
│  schema / structural / units                 │
├─────────────────────────────────────────────┤
│          Expression Engine                   │
│  AST ↔ symbolic repr / pretty-print / eval   │
├─────────────────────────────────────────────┤
│        Data Model (Type System)              │
│  EsmFile, Model, ReactionSystem, Expression…│
├─────────────────────────────────────────────┤
│         JSON Parse / Serialize               │
│  Schema-aware deserialization                │
└─────────────────────────────────────────────┘
```

### 2.1a Error Handling

The `load()` function must **throw** (or return an error, in languages without exceptions) when given invalid JSON. Specifically:

- **Malformed JSON** (syntax errors): Throw a parse error immediately. Do not attempt recovery.
- **Valid JSON that fails schema validation**: Throw a validation error with the list of schema violations. Libraries must not silently accept invalid files.
- **Valid JSON that passes schema validation but fails structural validation**: `load()` succeeds (returns an `EsmFile`), but the structural issues are reported by the separate `validate()` function. This allows loading partially invalid files for inspection and repair.

### 2.1b Subsystem Reference Resolution

Before validation or any other processing, `load()` must resolve all subsystem references (objects with a `ref` field) to their inline definitions. This ensures the rest of the pipeline operates on a fully expanded in-memory representation.

**Resolution algorithm:**

1. Walk all `subsystems` maps in the loaded file (in both `models` and `reaction_systems`, at any nesting depth).
2. For each subsystem value that is a reference object (has a `ref` field):
   a. Determine the reference type:
      - If `ref` starts with `http://` or `https://`, fetch the content from the URL.
      - Otherwise, treat it as a local file path. Resolve relative paths against the directory of the referencing file.
   b. Parse the referenced file as a valid ESM file.
   c. Extract the single top-level model or reaction system from the referenced file. If the file contains zero or more than one top-level system, report an error.
   d. Replace the reference object with the resolved model or reaction system definition.
3. Resolution is recursive: a referenced file may itself contain subsystem references. Resolve depth-first.
4. Libraries must detect circular references (file A references file B which references file A) and report an error rather than entering infinite recursion.

**Error handling:**

| Condition | Behavior |
|---|---|
| Local file not found | Throw/return error with path and context |
| URL unreachable or returns non-200 | Throw/return error with URL and HTTP status |
| Referenced file is not valid JSON | Throw/return error with path/URL and parse error |
| Referenced file has zero or multiple top-level systems | Throw/return error identifying the file and the count of systems found |
| Circular reference detected | Throw/return error listing the cycle |

After resolution completes, the in-memory representation is indistinguishable from a file with all subsystems defined inline. All subsequent validation, editing, and conversion operates on the resolved representation.

### 2.1c Template Import Resolution (esm-spec §9.7)

Template imports resolve in the same load phase as subsystem references, with the same reference formats and the same visited-set cycle detection, but target **template-library files** (top-level `expression_templates`; esm-spec §9.7.1) instead of single-component files.

**Resolution algorithm:**

1. Collect `expression_template_imports` arrays: on every `model` / `reaction_system`, and at the top level of a library file being imported.
2. For each entry, in array order:
   a. Load `ref` exactly as in §2.1b step 2a-b (URL vs relative path; shared visited set for cycle detection → `template_import_cycle`).
   b. Verify the target is a pure template-library file — top-level `expression_templates` present; no `models` / `reaction_systems` / `data_loaders` / `coupling` / `domain` (`template_import_not_library`).
   c. Recurse into the target's own `expression_template_imports` (depth-first).
   d. Instantiate the target with the edge's metaparameter `bindings` (esm-spec §9.7.6): close the named metaparameters, re-export the rest into the importer's metaparameter scope, fold structural integer sites, substitute expression-position occurrences.
   e. Apply `only` filtering (`template_import_unknown_name` for unknown names).
   f. Merge the target's `index_sets` into the importing document's registry (deep-equal idempotent; `template_import_index_set_conflict` otherwise).
   g. Append the target's effective template sequence to the importer's (esm-spec §9.7.4); dedup deep-equal duplicates; `template_import_name_conflict` for non-equal same-name collisions.
3. After all imports resolve: close and fold the root document's metaparameters (loader-API bindings, then defaults; `metaparameter_unbound` if still open), inline template-body references in topological order (esm-spec §9.7.3), then run the §9.6.3 rewrite fixpoint.

`load()` implementations MUST accept an optional metaparameter-bindings argument (name → integer) applied to the root document (esm-spec §9.7.6 binding site 4).

**Error handling:** as the §2.1b table, plus the `template_import_*` / `metaparameter_*` diagnostics of esm-spec §9.6.6.

After resolution, neither `expression_template_imports` nor `metaparameters` nor top-level `expression_templates` is visible downstream; round-trip emits the expanded, folded form (esm-spec §9.7.6).

### 2.2 Data Model

Every library must define typed representations for:

| ESM concept | Type name (suggested) | Notes |
|---|---|---|
| Top-level file | `EsmFile` | Contains all sections |
| Expression AST | `Expr` | Recursive: `Num`, `Var`, `Op` |
| Equation | `Equation` | `{lhs: Expr, rhs: Expr, _comment?: string}` |
| Affect equation | `AffectEquation` | `{lhs: string, rhs: Expr}` |
| Model variable | `ModelVariable` | `state`, `parameter`, or `observed` |
| Model | `Model` | Variables, equations, events |
| Species | `Species` | Units, default, description |
| Reaction | `Reaction` | Substrates, products, rate |
| Reaction system | `ReactionSystem` | Species, parameters, reactions, events |
| Continuous event | `ContinuousEvent` | Conditions, affects, affect_neg |
| Discrete event | `DiscreteEvent` | Trigger, affects, discrete_parameters |
| Functional affect | `FunctionalAffect` | Handler reference |
| Data loader | `DataLoader` | STAC-like description: `kind`, `source`, `temporal`, `spatial`, `variables`, `regridding` |
| Operator | `Operator` | Registered by ID |
| Coupling entry | `CouplingEntry` | Discriminated union on `type` |
| Domain | `Domain` | Temporal, spatial, BCs, ICs |
| Reference | `Reference` | doi, citation, url, notes |
| Metadata | `Metadata` | Name, authors, tags |

#### 2.2.1 Optional Fields

Several data model types support optional fields for enhanced documentation and debugging:

**Equation `_comment` field**: The `_comment` field is an optional string that provides human-readable documentation about an equation's purpose or mathematical meaning. This field is commonly used in examples and test files to clarify the physical interpretation of equations.

Examples of usage:
- `"_comment": "Fast consumption of A: dA/dt = -k_fast*A + k_slow*B"`
- `"_comment": "Momentum equation x-direction with viscous terms and pressure gradient"`
- `"_comment": "Logistic equation: dp/dt = r*p*(1 - p/K)"`

The comment field is purely for documentation and has no effect on model behavior or validation. Libraries should preserve comments during round-trip serialization and may optionally display them in pretty-printed output or debugging interfaces.

### 2.3 Expression Engine Requirements

The expression engine is the heart of every library. It must support:

#### 2.3.1 Construction

- Build expressions programmatically: `Var("O3")`, `Op("+", [Var("a"), Num(1)])`.
- Parse from ESM JSON (the `Expression` type in the schema).

#### 2.3.2 Pretty-printing

Render an expression tree as a human-readable string. Multiple output formats:

| Format | Example output for `D(O3, t) = -k * O3 * NO + j * NO2` |
|---|---|
| Unicode | `∂O₃/∂t = −k·O₃·NO + j·NO₂` |
| LaTeX | `\frac{\partial \mathrm{O_3}}{\partial t} = -k \cdot \mathrm{O_3} \cdot \mathrm{NO} + j \cdot \mathrm{NO_2}` |
| ASCII | `d(O3)/dt = -k * O3 * NO + j * NO2` |
| Code (language-native) | Julia: `D(O3) ~ -k * O3 * NO + j * NO2` |

Minimum requirement: **Unicode** and **LaTeX**. Language-native code output is desired.

Pretty-printing must handle:

- Operator precedence and associativity (minimize parentheses).
- Subscripts for chemical species (O₃, NO₂, CH₂O).
- Fractions: display `a/b` as `\frac{a}{b}` in LaTeX.
- The `Pre` operator: render as `Pre(x)` or `x⁻` depending on format.
- Calculus operators: `D(x, t)` → `∂x/∂t`, `grad(x, y)` → `∂x/∂y`.

#### 2.3.3 Substitution

Replace a variable or subexpression with another expression:

```
substitute(expr, {"T": Num(298.15)})                    # variable → constant
substitute(expr, {"k1": Op("*", [Num(1.8e-12), ...])})  # variable → expression
substitute(expr, {"_var": Var("O3")})                    # placeholder → variable
```

Substitution must be recursive and handle hierarchical scoped references (`"Model.Subsystem.var"` — see the ESM format spec Section 4.3 for the full resolution algorithm).

#### 2.3.4 Structural Operations

- `free_variables(expr) → Set<string>` — all variable references in the expression.
- `free_parameters(expr) → Set<string>` — subset that are parameters (requires model context).
- `contains(expr, var) → bool` — whether a variable appears in the expression.
- `simplify(expr) → Expr` — optional algebraic simplification (language-dependent). At minimum, implementations should fold constant arithmetic (e.g., `2 + 3` → `5`, `x * 1` → `x`, `x + 0` → `x`, `x * 0` → `0`). Deeper algebraic simplification (factoring, trigonometric identities, etc.) is language-dependent and not required for conformance.
- `evaluate(expr, bindings: Map<string, number>) → number` — numerical evaluation. All variables and parameters must be present in `bindings`; if any variable is unbound, the function must raise an error listing the unbound variables. (Partial evaluation is the responsibility of `substitute`, not `evaluate`.)

#### 2.3.5 Serialization

Convert expression tree back to ESM JSON format (the inverse of parsing). Must produce output that validates against the schema and round-trips identically.

### 2.4 Library Scope and Dependency Policy

**Libraries set up systems; they do not solve them.** The general scope of an EarthSciAST library is to parse, validate, edit, flatten, and convert ESM format files into simulation-ready native solver objects (e.g., `ModelingToolkit.System` in Julia, SciPy-compatible function handles in Python, `diffsol` `OdeProblem` in Rust). **Libraries SHOULD NOT embed their own ODE/PDE solver nor export wrapper functions that perform actual time integration.** This keeps the runtime dependency graph small, avoids version-pinning disputes with downstream solvers, and lets users pick the solver appropriate for their problem.

#### 2.4.1 Rationale

- **Dependency weight.** ODE/PDE solvers bring large transitive dependency trees (SciPy pulls NumPy + BLAS + LAPACK; `OrdinaryDiffEq.jl` pulls the full DifferentialEquations.jl ecosystem with dozens of subpackages). Libraries that only construct systems can ship with far smaller runtime footprints.
- **Solver choice.** Users are better positioned to pick solvers than library authors. A library that hard-codes BDF forces everyone into that solver; a library that produces a native system object lets each user plug in Tsit5, Rosenbrock23, Radau, or a custom method.
- **Browser and embedded targets.** Smaller runtimes are easier to compile to WebAssembly or run in constrained environments. This matters specifically for the Rust + WebAssembly browser-simulation path (`earthsci-ast-rs` + `diffsol`) where every transitive dependency adds to the `.wasm` bundle size.

#### 2.4.2 Testing Requirement for Simulation-Capable Packages

Libraries at a tier that produces simulation-ready systems (currently: Julia via MTK, Python via SciPy-compatible lambdified RHS, Rust via `diffsol` integration) **MUST include integration tests that run an actual simulation end-to-end** — call the solver, integrate forward in time, and assert numerical correctness of the resulting trajectory against an analytical solution (where available) or a published reference (e.g., Robertson's stiff benchmark for chemistry, exponential decay for first-order kinetics). The test suite must demonstrate that the system objects produced by the library are actually solvable, not merely constructible.

**Rationale.** A library can construct an ODE system object that looks correct (right state variables, right parameters, right equation count) but fails when a solver tries to integrate it — due to subtle issues like non-numeric expression nodes, missing initial conditions, unit mismatches, or singular Jacobians. Construction-only tests do not catch these. The only reliable way to verify a system is simulation-ready is to simulate it. The solver used for these tests is a **test** dependency, not a runtime dependency — it does not affect the shipped package's dependency footprint.

- **PDE test discretization (minimum viable).** For PDE tests specifically, use the *minimum* number of grid points that verifies correctness, not numerical accuracy. PDE test cost scales poorly — a 3D test with a 20×20×20 grid is 8000 DOFs and will dominate CI wall-time. The library test suite validates that the system constructor produces a solvable `PDESystem` and that the coupling rules apply correctly, not that the underlying solver achieves a particular numerical convergence rate (that is the solver project's validation, not the library's). Concrete guidance: 1D PDE tests use 5–10 grid points; 2D PDE tests use 3×3 to 5×5; 3D PDE tests use 3×3×3 (avoid larger than 5×5×5 unless the test is specifically validating spatial convergence). Flux boundary condition tests only need enough grid points to evaluate the BC at least once on the boundary — 3–5 per direction is adequate. Assert on structural correctness (right shape, no NaN, conservation holds to within 1%), not pointwise analytical-solution matching.

#### 2.4.3 Preferred Patterns

- **Python.** The solver (`scipy.integrate`) is a test dependency. The runtime package imports it lazily only inside simulation entry points, or the simulation entry point is gated behind an optional `simulate` extra (e.g., `pip install earthsci-ast[simulate]`).
- **Rust.** The solver (`diffsol`) is a feature-gated dependency. A `simulate` Cargo feature brings `diffsol` in; users who only need parse/validate/flatten/graph can depend on the crate without the `simulate` feature and avoid the solver transitive weight.
- **Julia.** The solver (`OrdinaryDiffEq` or a specific subpackage like `OrdinaryDiffEqRosenbrock`) is a test dependency declared in `[targets].test` of `Project.toml`, **not** in `[deps]`. For users who want a one-line simulate API, the library provides a Julia package extension (e.g., `EarthSciASTSolverExt.jl` via a `weakdep` on `OrdinaryDiffEq`), loaded only when the user explicitly does `using OrdinaryDiffEq` alongside the main package. The extension approach preserves the "library sets up systems but does not solve" principle while still giving users easy access to simulation when they want it.

#### 2.4.4 Current Conformance Status

*Informative — update as things change.*

| Library | Status | Notes |
|---|---|---|
| Python (`earthsci_ast`) | ✅ conforms | `tests/test_simulation.py` calls `scipy.integrate.solve_ivp` on multiple canonical problems and asserts trajectory correctness. |
| Rust (`earthsci-ast-rs`) | ✅ conforms (partial) | `tests/simulate_tests.rs` runs Robertson, exponential decay, reversible, and autocatalytic problems through `diffsol`. `diffsol` is currently an unconditional dependency; moving it behind a `simulate` feature flag is a recommended follow-up. |
| Julia (`EarthSciAST.jl`) | ❌ does not conform | The test suite constructs `ODESystem` objects but never calls `solve()`. `real_mtk_integration_test.jl` has `@test_skip` gates and only verifies the returned object is a non-`MockMTKSystem`. Tracked as a follow-up gap. |

---

## 3. Validation

### 3.1 Schema Validation

Every library must validate an `.esm` file against the JSON Schema. This is the first validation pass and catches structural errors (missing required fields, wrong types, invalid enum values).

**Implementation:** Use the language's standard JSON Schema library:

| Language | Library |
|---|---|
| Julia | `JSONSchema.jl` |
| TypeScript | `ajv` |
| Python | `jsonschema` |
| Rust | `jsonschema` (crate) |
| Go | `gojsonschema` |

### 3.2 Structural Validation

Beyond schema correctness, validate mathematical and semantic consistency:

#### 3.2.1 Equation–Unknown Balance

For each model:

- Count state variables (type `"state"`) → `n_states`.
- Count equations whose LHS is a time derivative `D(var, t)` → `n_odes`.
- **Check:** `n_odes == n_states`. If not, report which variables lack equations or which equations lack corresponding state variables.

For each reaction system:

- The number of ODEs is determined automatically (one per species), so this check is inherently satisfied. Instead, verify:
  - Every species referenced in a reaction is declared in `species`.
  - Every parameter referenced in a rate expression is declared in `parameters`.

#### 3.2.2 Reference Integrity

- Every variable name referenced in an equation exists in the model's `variables` (or in a subsystem's variables, if using a scoped reference).
- Every scoped reference in coupling entries resolves to an actual variable by walking the subsystem hierarchy. A reference like `"A.B.C"` must resolve as: `A` is a top-level system, `B` is a subsystem of `A`, and `C` is a variable/species/parameter in `B`. The last dot-separated segment is always the variable name; all preceding segments form the system path. See the ESM format spec Section 4.3 for the full resolution algorithm.
- Every `discrete_parameters` entry in an event matches a declared parameter.
- Every `from`/`to` in coupling entries references an existing model, reaction system, data loader, or operator (including subsystems nested at any depth).
- Every `operator` in `operator_apply` coupling entries exists in the `operators` section.

#### 3.2.3 Event Consistency

- Continuous event conditions are expressions (not booleans) — they should be zero-crossing detectable.
- Discrete event `condition` triggers should produce boolean values (comparisons, logical ops).
- Every variable referenced in `affects` (both LHS and RHS) is declared in the owning model/reaction system (or uses valid scoped references for cross-system events).
- Functional affect `read_vars` and `read_params` reference declared variables.

#### 3.2.4 Reaction Consistency

- Every species in substrates/products is in `species`.
- Stoichiometries are positive integers.
- No reaction has both `substrates: null` and `products: null` (would be a null reaction).
- Rate expressions only reference declared parameters, species, or known functions.

### 3.3 Unit Validation

Unit validation checks dimensional consistency of equations. This is the most complex validation and may be approximate.

#### 3.3.1 Approach

1. Parse unit strings into a canonical dimensional representation (e.g., `"mol/mol/s"` → `{mol: 0, s: -1}` since mol/mol cancels).
2. Propagate dimensions through expressions:
   - Addition/subtraction: operands must have the same dimensions.
   - Multiplication: dimensions add.
   - Division: dimensions subtract.
   - `D(x, t)`: dimension of x divided by dimension of t.
   - Functions (exp, log, sin, …): argument must be dimensionless; result is dimensionless.
   - `^`: base dimensions multiplied by exponent (which must be dimensionless).
3. For each equation, verify LHS and RHS have the same dimensions.

#### 3.3.2 Unit Libraries

| Language | Recommended |
|---|---|
| Julia | `Unitful.jl` or `DynamicQuantities.jl` |
| TypeScript | `mathjs` units or custom lightweight parser |
| Python | `pint` |
| Rust | `uom` |

#### 3.3.3 Limitations

- ESM unit strings are free-form (e.g., `"mol/mol"`, `"cm^3/molec/s"`) and not standardized to a specific unit system. Libraries should parse common patterns but may need to accept unrecognized units as opaque strings.
- Cross-system unit validation (through coupling) requires resolving scoped references first.
- Some operators (registered by reference) have opaque semantics — their inputs/outputs are declared with units, but the internal transformation cannot be checked.

### 3.4 Validation API

Every library must expose:

```
validate(file: EsmFile) → ValidationResult
```

Where `ValidationResult` contains:

- `schema_errors: List<SchemaError>` — JSON Schema violations.
- `structural_errors: List<StructuralError>` — equation/unknown balance, reference integrity.
- `unit_warnings: List<UnitWarning>` — dimensional inconsistencies (warnings, not hard errors, because unit strings may be ambiguous).
- `is_valid: bool` — true if no schema or structural errors.

#### Error Type Structures

```
SchemaError:
  path: string          # JSON Pointer to the offending location (e.g., "/models/SuperFast/equations/0/rhs")
  message: string       # Human-readable description (e.g., "Required property 'op' is missing")
  keyword: string       # JSON Schema keyword that failed (e.g., "required", "enum", "type")

StructuralError:
  path: string          # JSON Pointer to the relevant component (e.g., "/models/SuperFast")
  code: string          # Machine-readable error code (see below)
  message: string       # Human-readable description
  details: Map<string, any>  # Additional context (e.g., {"variable": "O3", "expected_in": "variables"})

UnitWarning:
  path: string          # JSON Pointer to the equation or expression
  message: string       # Human-readable description
  lhs_units: string     # Inferred units of the LHS
  rhs_units: string     # Inferred units of the RHS
```

**Structural error codes:**

| Code | Description |
|---|---|
| `equation_count_mismatch` | Number of ODE equations does not match number of state variables |
| `undefined_variable` | Variable referenced in an equation is not declared |
| `undefined_species` | Species referenced in a reaction is not declared |
| `undefined_parameter` | Parameter referenced in a rate expression is not declared |
| `undefined_system` | Coupling entry references a nonexistent model, reaction system, data loader, or operator |
| `undefined_operator` | `operator_apply` references a nonexistent operator |
| `unresolved_scoped_ref` | Scoped reference (e.g., `"Model.Subsystem.var"`) cannot be resolved — a segment in the system path does not exist or the final variable is not declared. Also raised at flatten for an edge produced by a `coupling_import` expansion whose bound component lacks a referenced variable (esm-spec §10.10.3) |
| `coupling_import_unresolved` | A `coupling_import` `ref` failed to load or parse (esm-spec §10.11) |
| `coupling_import_not_library` | A `coupling_import` `ref` targets a document that is not a coupling-library file (no top-level `coupling_roles`) |
| `subsystem_ref_is_coupling_library` | A §4.7 subsystem `ref` targets a coupling-library file |
| `template_import_is_coupling_library` | A §9.7.2 template import targets a coupling-library file |
| `coupling_library_illegal_payload` | A coupling-library file declares a forbidden payload (`models`/`reaction_systems`/`data_loaders`/`domain`/`index_sets`/`metaparameters`/`expression_templates`), contains a `callback` entry or an edge-level `expression_template_imports` map, or carries a transform template that would expand to a rewrite-target operator (esm-spec §10.9) |
| `coupling_library_nested_import` | A coupling-library file contains a `coupling_import` entry |
| `coupling_edge_unknown_role` | A library edge's top-level system segment, at an occurrence site, is not a declared role |
| `coupling_role_unused` | A declared role appears at no occurrence site in any library edge |
| `coupling_import_unknown_role` | A `bind` key names a role the referenced library does not declare |
| `coupling_import_role_unbound` | A role the referenced library declares has no `bind` entry (binding is total) |
| `coupling_import_bind_not_a_component` | A `bind` value does not resolve to a top-level or subsystem component in the assembly |
| `invalid_discrete_param` | `discrete_parameters` entry does not match a declared parameter |
| `null_reaction` | Reaction has both `substrates: null` and `products: null` |
| `missing_observed_expr` | Observed variable is missing its `expression` field |
| `event_var_undeclared` | Variable in event affects/conditions is not declared |
| `unresolved_subsystem_ref` | Subsystem reference points to a local file that does not exist (canonical; RETIRES `ref_not_found` — CONFORMANCE_SPEC §7.1.3f) |
| `ref_unreachable` | Subsystem reference URL is unreachable or returned a non-200 status |
| `ref_invalid_json` | Referenced file is not valid JSON or not a valid ESM file |
| `ambiguous_subsystem_ref` | Referenced file contains zero or more than one top-level model/reaction system (canonical; RETIRES `ref_ambiguous_system` — CONFORMANCE_SPEC §7.1.3f) |
| `ref_circular` | Circular subsystem reference detected (e.g., file A → file B → file A) |

---

## 4. Editing Operations

Beyond expression-level substitution, libraries must support model-level editing:

### 4.1 Variable Operations

- `add_variable(model, name, variable)` — add a new variable to a model.
- `remove_variable(model, name)` — remove a variable (and warn/error if referenced in equations).
- `rename_variable(model, old_name, new_name)` — rename everywhere: variables, equations, events, coupling references.

### 4.2 Equation Operations

- `add_equation(model, equation)` — append an equation.
- `remove_equation(model, index_or_lhs)` — remove by index or by LHS match.
- `substitute_in_equations(model, bindings)` — apply substitution across all equations in a model.

### 4.3 Reaction Operations

- `add_reaction(system, reaction)` — add a reaction to a reaction system.
- `remove_reaction(system, id)` — remove by reaction ID.
- `add_species(system, name, species)` — add a species.
- `remove_species(system, name)` — remove a species (warn if used in reactions).

### 4.4 Event Operations

- `add_continuous_event(model, event)` — add a continuous event.
- `add_discrete_event(model, event)` — add a discrete event.
- `remove_event(model, name)` — remove by event name.

### 4.5 Coupling Operations

- `add_coupling(file, entry)` — add a coupling rule.
- `remove_coupling(file, index)` — remove by index.
- `compose(file, system_a, system_b)` — convenience: create an `operator_compose` entry.
- `map_variable(file, from, to, transform)` — convenience: create a `variable_map` entry.

### 4.6 Model-Level Operations

- `merge(file_a, file_b) → EsmFile` — merge two ESM files, combining models, reaction systems, and coupling.
- `extract(file, component_name) → EsmFile` — extract a single model or reaction system into a standalone file.
- `derive_odes(reaction_system) → Model` — generate the ODE model from a reaction system's stoichiometry and rate laws.
- `stoichiometric_matrix(reaction_system) → Matrix` — compute the net stoichiometric matrix.

### 4.7 Coupling Resolution

Libraries at **all tiers** (including Core) must implement coupling resolution as a **flattening** operation: transforming a set of coupled component systems into a single flat equation system with dot-namespaced variables. This flattened representation is the canonical intermediate form — it is the output of coupling resolution and the input to simulation backends, graph construction, and validation.

Libraries that support simulation (Julia, Python) additionally convert the flattened system into native solver objects (see Section 4.7.5). Libraries at the Core tier produce the flattened representation but do not convert to solver-specific types.

**Resolution order:** The order of entries in the `coupling` array does not affect the final result. Coupling rules are commutative — the same mathematical system is produced regardless of the order in which rules are applied. (This matches the behavior of EarthSciMLBase.jl, which is tested across all permutations of system ordering.)

However, for deterministic intermediate representations (e.g., variable naming), libraries should process coupling entries in array order.

#### 4.7.1 `operator_compose` Algorithm

`operator_compose` merges two ODE systems by matching time derivatives on the left-hand side and adding right-hand side terms together. This is the primary mechanism for adding physical processes (advection, diffusion, deposition) to chemical or dynamical systems.

**Algorithm:**

1. **Extract dependent variables.** For each equation in both systems, extract the dependent variable from the LHS:
   - If the LHS is `D(var, t)`, the dependent variable is `var`.
   - Otherwise, the dependent variable is the LHS expression itself.

2. **Apply translations.** If a `translate` map is provided, build a mapping from system A variable names to system B variable names (with optional conversion factors). Translations use scoped references (e.g., `"ChemModel.ozone": "PhotolysisModel.O3"`).

3. **Match equations.** For each equation in system A, find a matching equation in system B by comparing dependent variables:
   - **Direct match:** Both equations have `D(x, t)` on the LHS with the same variable name `x`.
   - **Translation match:** The translate map maps A's variable to B's variable.
   - **Placeholder expansion:** If system B's equation uses the `_var` placeholder (e.g., `D(_var, t) = ...`), it matches _every_ state variable in system A. The placeholder equation is cloned once per matched variable, with `_var` substituted for the actual variable name.

4. **Combine matched equations.** For each matched pair:
   - The final equation for variable `x` has the original LHS: `D(x, t)`.
   - The RHS is the sum of both systems' RHS expressions: `rhs_A + factor * rhs_B`, where `factor` is the conversion factor from the translate map (default 1).
   - Variables from system B that appear in the combined RHS are added to the merged system's variable list.

5. **Preserve unmatched equations.** Equations in either system that have no match are included in the merged system unchanged.

**Placeholder expansion example:** Given system A (a reaction system with species O₃, NO, NO₂) composed with system B (advection with equation `D(_var)/dt = -u·∂_var/∂x - v·∂_var/∂y`), the result contains three advection equations:

```
D(O₃)/dt  = [chemistry RHS for O₃]  + (-u·∂O₃/∂x  - v·∂O₃/∂y)
D(NO)/dt  = [chemistry RHS for NO]  + (-u·∂NO/∂x   - v·∂NO/∂y)
D(NO₂)/dt = [chemistry RHS for NO₂] + (-u·∂NO₂/∂x  - v·∂NO₂/∂y)
```

#### 4.7.2 `couple` Semantics

`couple` provides bidirectional coupling between two systems via a `ConnectorSystem` — a set of explicit equations that define how variables in one system affect the other.

The `connector.equations` array contains the complete coupling specification, explicitly provided by the user. Couplers must be manually added to a coupled system; they are not auto-discovered via dispatch or type matching.

**Resolution algorithm for `couple`:**

1. Read the `connector.equations` array.
2. For each connector equation:
   - Resolve the `from` and `to` scoped references to their respective systems and variables.
   - Apply the coupling based on the `transform` type:
     - `additive`: Add the `expression` as a source/sink term to the target variable's ODE RHS.
     - `multiplicative`: Multiply the target variable's existing ODE RHS by the `expression`.
     - `replacement`: Replace the target variable's value with the `expression` (used for algebraic constraints).
3. Variables referenced across systems become shared — the coupled system includes both systems' variables.

#### 4.7.3 `variable_map` Resolution

`variable_map` replaces a parameter in one system with a variable provided by another system (typically a data loader).

1. Resolve the `from` scoped reference to the source system and variable.
2. Resolve the `to` scoped reference to the target system and parameter.
3. Apply the transform:
   - `param_to_var`: The target parameter is promoted from a constant to a time-varying variable whose value comes from the source. In the merged system, the parameter is removed from the target's parameter list and becomes a shared variable.
   - `identity`: Direct assignment without type change.
   - `additive`: The source value is added to the target variable's equation RHS.
   - `multiplicative`: The target variable's equation RHS is multiplied by the source value.
   - `conversion_factor`: Same as `param_to_var` but the source value is multiplied by the `factor` field before assignment.

#### 4.7.4 `operator_apply` and `callback` Resolution

These coupling types register runtime-specific components. Libraries record them in the coupled system metadata but cannot resolve their behavior (they are opaque references to runtime implementations). For validation, libraries verify that the referenced operator or callback ID exists in the file's `operators` section or is a known registered ID.

#### 4.7.5 Coupled System Flattening Algorithm

All libraries (including Core tier) must implement the flattening algorithm. Flattening transforms a set of coupled component systems into a single flat equation system where all variables and parameters are uniquely identified by dot-namespaced names.

**Dot-namespacing convention:** Every variable, parameter, and species in the flattened system is prefixed with its owning system's name, using dot notation. For nested subsystems, each level of the hierarchy is included. Examples:

| Original | System | Flattened name |
|---|---|---|
| `O3` (species) | `SimpleOzone` | `SimpleOzone.O3` |
| `u_wind` (parameter) | `Advection` | `Advection.u_wind` |
| `T` (variable) | `GEOSFP` | `GEOSFP.T` |
| `NO2` (species) | `Atmosphere.Chemistry` | `Atmosphere.Chemistry.NO2` |

**Algorithm:**

1. **Derive ODEs from reaction systems.** For each reaction system in the file, generate the equivalent ODE equations using the stoichiometry and rate laws (as specified in Section 4.6 `derive_odes`). This converts reaction systems into a uniform equation-based representation.

2. **Namespace all variables.** For each component system (model, derived ODE system from reaction systems, data loader):
   - Prefix every variable, parameter, and species name with the system name and a dot.
   - Rewrite all equations so that variable references use the dot-namespaced names.
   - For nested subsystems, the prefix is the full path: `Parent.Child.variable`.

   **Between steps 2 and 3 — Expand coupling imports (esm-spec §10.10).** Before applying coupling
   rules, replace each `coupling_import` entry in the coupling sequence with the concrete edges its
   referenced **coupling-library file** (esm-spec §10.9) declares, substituting the bound actual
   component for every role-named top-level segment (esm-spec §10.10.2), spliced **in the position
   of the import entry**. Resolution of the library `ref`, the totality and validity of `bind`, and
   library purity are checked at this step, raising the esm-spec §10.11 diagnostics
   (`coupling_import_unresolved`, `coupling_import_not_library`, `coupling_import_role_unbound`,
   `coupling_import_unknown_role`, `coupling_import_bind_not_a_component`,
   `coupling_library_illegal_payload`, …). A library edge's transform templates
   (`apply_expression_template`) expand here against the **bound** `to` owner's template registry,
   to an already-lowered form (esm-spec §10.4 carve-out). After this sub-step every entry in the
   sequence is an ordinary coupling entry; the `coupling_import` source entry is retained only in
   the *source* document (esm-spec §10.10.3), never in the flattened system. The expansion is a
   pure structural rewrite over ordered inputs and does not disturb the commutativity of the
   coupling-rule step.

3. **Apply coupling rules.** Process each coupling entry to merge equations across systems. Because a
   `coupling_import` is expanded (above) into ordinary edges before this step, its edges are
   indistinguishable from inline edges here. A mis-bind therefore surfaces the same way any bad edge
   does: the coupled-system reference resolution (the `unresolved_scoped_ref` check, §3) applied to
   the **expanded** coupling reports a bound component that lacks a referenced variable. The
   load-time `unresolved_scoped_ref` pass cannot catch it — it runs before expansion and never sees
   the expanded edges — so a conforming library MUST run coupling-reference resolution over the
   expanded edge set (whether inside flattening or as a coupled-system validation over the flattened
   form).
   - **`operator_compose`**: Match equations by dependent variable (applying the `translate` map and `_var` placeholder expansion as described in Section 4.7.1). Combine matched equations by summing their RHS terms. The resulting equation uses the namespaced LHS variable (e.g., `D(SimpleOzone.O3, t) = [chemistry RHS] + [advection RHS]`).
   - **`couple`**: Apply connector equations, resolving the `from` and `to` scoped references to their namespaced equivalents.
   - **`variable_map`**: Substitute the target parameter with the source variable. For `param_to_var`, replace all occurrences of `Target.param` with `Source.var` in the flattened equations and remove the parameter from the target's parameter list.
   - **`operator_apply` / `callback`**: Record in the flattened system's metadata as opaque runtime references.

4. **Collect the flattened system.** The result is a single flat system containing:
   - **All equations** from all component systems, with coupling modifications applied, using dot-namespaced variable names.
   - **All state variables** (dot-namespaced), with duplicates merged where coupling unifies them.
   - **All parameters** (dot-namespaced), minus any that were promoted to variables by `variable_map`.
   - **All events** from all component systems, with variable references rewritten to dot-namespaced form.
   - **Domain** from the file's `domain` section (if present).
   - **Metadata** recording which component systems were flattened and which coupling rules were applied.

**Example:** Given an ESM file with `SimpleOzone` (reaction system with O₃, NO, NO₂), `Advection` (model with `_var` placeholder), and `GEOSFP` (data loader providing T, u, v), coupled via `operator_compose` and `variable_map`, the flattened system contains:

```
State variables: SimpleOzone.O3, SimpleOzone.NO, SimpleOzone.NO2
Parameters:      SimpleOzone.k_NO_O3, SimpleOzone.jNO2 (T, u, v promoted to variables)
Variables:       GEOSFP.T, GEOSFP.u, GEOSFP.v

Equations:
  D(SimpleOzone.O3, t)  = -SimpleOzone.k_NO_O3 * SimpleOzone.O3 * SimpleOzone.NO
                          + SimpleOzone.jNO2 * SimpleOzone.NO2
                          + (-GEOSFP.u * grad(SimpleOzone.O3, x) - GEOSFP.v * grad(SimpleOzone.O3, y))

  D(SimpleOzone.NO, t)  = [chemistry terms] + [advection terms]
  D(SimpleOzone.NO2, t) = [chemistry terms] + [advection terms]
```

**Namespacing preserves identity.** Two systems may both declare a variable named `T` — namespacing ensures `GEOSFP.T` and `Atmosphere.T` remain distinct unless explicitly unified by a coupling rule.

**The flattened system is the API boundary.** All downstream operations — graph construction, validation of the coupled system, export to simulation backends — operate on the flattened representation rather than the individual component systems.

**Conflict detection.** Before flattening, libraries MUST check that no species is both the LHS of an explicit `D(X, t) = …` equation (in any `models` entry) and a reactant or product of any reaction (in any `reaction_systems` entry). Such a system is over-determined: the reaction contribution to `d[X]/dt` would silently shadow the user's equation. Libraries raise `ConflictingDerivativeError` naming every offending (fully namespaced) species. The same check fires from `validate` / `validate_structural` so load-time validation catches the conflict before flattening is attempted.

#### 4.7.6 Dimension Promotion for Hybrid Flattening

> **Status (v0.8.0).** The **Interface** construct — its `dimension_mapping` and
> `regridding` fields and the file-level `interfaces` section — was **removed** in
> v0.8.0 (see `esm-schema.json`: "Removed … all regridding configuration
> (`Model.regrid`, `RegridSpec`, `Interface.regridding`)"). Cross-grid and
> cross-dimensional coupling is no longer a separate interface/geometry construct:
> it is expressed as an ordinary **regridding expression** carried in the coupling
> entry's `transform` — an `aggregate` (Functional Aggregate Query) over index
> sets, the same algebra as discretization and reductions. See esm-spec.md §8.6
> (regridding as a coupling expression), §10.5 (coupling across grids and
> dimensionality), and §12 (the retired Interfaces section). No binding performs
> `dimension_mapping` validation, because no such field exists; the error types
> this subsection once tied to Interface validation are correspondingly
> reserved/parity-only or repurposed (see §4.7.6.10).

A single `.esm` file may still combine systems living on different spatial dimensions: a 0D box-model reaction system, a 1D vertical-diffusion PDE, a 2D horizontal transport PDE, a 3D atmospheric tracer PDE. Flattening a hybrid file requires a well-defined rule for how state variables, reactions, and equations from lower-dimensional systems are **promoted** onto higher-dimensional domains so that coupling operators can combine their RHS terms pointwise. In v0.8.0 that promotion is realized by the regridding expression on the coupling `transform` and by the pointwise spatial lift (esm-spec.md §10.5), not by an Interface record.

**Terminology.**
- A **domain** is a spatial/temporal specification (see `Domain` in Section 2.2). A system's domain is either `null` (0D — box model) or a reference to a `domains` entry that declares one or more spatial axes (e.g. `{x, y}` or `{x, y, z}`).
- **Promotion** is the act of rewriting a variable or equation so it lives on a higher-dimensional target domain while preserving its mathematical meaning.
- A **regridding expression** — the `aggregate`/FAQ on a coupling entry's `transform` (esm-spec.md §8.6, §10.5) — is how promotion is realized numerically. It replaces the removed `Interface.dimension_mapping` / `Interface.regridding` pair: there is no separate interface record and no `dimension_mapping` enum.

**Kinds of promotion (each now spelled as a regridding expression).** The rows below name *what* a promotion does; in v0.8.0 each is written as an `aggregate` expression on the coupling `transform`, not as an `Interface.dimension_mapping` value:

| Kind | Source → Target | Meaning |
|---|---|---|
| `broadcast` | 0D → N-D | The source value is spatially uniform on the target domain. A 0D variable `v` becomes a field `v(x, y, …)` whose value is identical at every target grid point. |
| `identity` | N-D → N-D (same grid) | Source and target share axes and grid; no interpolation is needed. |
| `slice` | N-D → (N-k)-D | Evaluate the source at fixed coordinate values along `k` of its axes (e.g. project a 3D field onto its surface `z=0`). |
| `project` | N-D → M-D, M<N | Integrate or average out `N-M` axes (an `aggregate` reduction declaring `"integrate"` vs `"average"` and the axes to reduce). |
| `regrid` | N-D → N-D (different grid) | Same axes but different discretization; an `aggregate` regridding expression (nearest, linear/bilinear/trilinear, or conservative overlap-area weighting — esm-spec.md §8.6). |

**Tier expectations.** `broadcast` and `identity` are trivial and available everywhere. `slice`, `project`, and `regrid` are Analysis-/Advanced-tier and, being ordinary `aggregate` expressions, are handled by the same evaluator as any other FAQ; there is no Interface tier-gate. A library that cannot evaluate a requested regridding kernel surfaces the reserved `UnsupportedMappingError` (see §4.7.6.10) rather than an Interface-mapping error.

**Implicit broadcast.** When a 0D system is coupled to an N-D system, libraries apply `broadcast` promotion implicitly — a 0D value is spatially uniform, the only unambiguous default — so the common 0D↔N-D case needs no explicit transform. (The removed `UnmappedDomainError` path, which formerly fired when no `Interface` covered a cross-domain coupling, is reserved/never-raised; see §4.7.6.10.)

**Reaction systems on PDE domains.** When a `ReactionSystem` lives on a PDE domain (its `domain` field references a domain with spatial axes), `lower_reactions_to_equations` still emits `D(species, t) = Σ stoich·rate` equations. The rate expressions are evaluated pointwise on the target domain: each grid point sees the local species concentrations and the local values of any parameters. Spatial derivatives (advection, diffusion) are added in a later pass by `operator_compose` — the reaction lowering itself is dimension-agnostic.

**Hybrid operator semantics.** Section 4.7.5 step 3 describes how `operator_compose`, `couple`, and `variable_map` combine equations. For hybrid flattening:

1. **`operator_compose`:** Before summing matched equations, apply dimension promotion so that both RHS terms live on the target (highest-dimensional) domain. The resulting equation uses the target domain's independent variables. Example: composing a 0D chemistry RHS with a 2D advection RHS produces a 2D reaction-advection equation whose chemistry term is implicitly broadcast onto the 2D grid.
2. **`couple`:** The connector equations' `from` and `to` references are resolved after promotion; a connector equation that ties a 0D source value to a PDE field produces a boundary-condition-like term at the point(s) selected by the coupling entry's regridding expression (e.g. a `slice` aggregate).
3. **`variable_map`:** The source variable is promoted to the target domain before substitution, so `param_to_var` on a 0D parameter with a PDE-domain replacement produces a field that varies across the target grid.

**Independent-variable computation.** After coupling, libraries compute the flattened system's `independent_variables` by:
1. Starting with `[:t]`.
2. Scanning every equation for spatial operators (`grad`, `div`, `laplacian`, or `D` with `wrt ≠ "t"`) and adding each referenced spatial dimension.
3. Scanning every `domains` entry in the file for spatial axes and adding them.

The result is `[:t]` for purely 0D systems and `[:t, :x, :y, …]` for PDE systems. This is what determines whether the downstream constructor produces an `ODESystem` or a `PDESystem`.

##### 4.7.6.6 Slice ODE-to-PDE Coupling Interpretation

When a `slice` regridding expression bridges a 0D source ODE (e.g. a surface deposition velocity) to an N-D diffusive PDE on the same axis, Core-/Analysis-tier implementations MAY interpret the source equation as either a pointwise volumetric source at the slice coordinate OR a flux boundary condition on the diffusive variable at that coordinate. The choice is an implementation detail that MUST be documented by each library.

##### 4.7.6.10 Error Taxonomy

The hybrid flattening path defines eight named errors that every implementation MUST expose as named exception classes for cross-language error-name parity. Because the **Interface**/`dimension_mapping` construct was removed in v0.8.0, most are now **reserved/parity-only** — defined and catchable by name, but never raised, since no dimension-mapping validation exists. Three are genuinely raised, but by mechanisms unrelated to the removed Interface machinery, as noted below.

| Error | Status | Trigger |
|---|---|---|
| `ConflictingDerivativeError` | **raised** | Two systems define non-additive equations for the same dependent variable — the same §4.7.5 flatten check (a species is both an explicit `D(X,t)` LHS and a reaction reactant/product). Not a dimension-mapping error. |
| `DimensionPromotionError` | **raised (repurposed)** | Not by Interface validation (which no longer exists), but by the §10.5 pointwise spatial lift / array shape-promotion: a species' operator makearrays yield no full-rank interior-stencil gather, or elementwise array-observed operands resolve to conflicting grid shapes. |
| `DomainUnitMismatchError` | **raised (optional parity)** | An OPTIONAL preflight over `variable_map` couplings whose `transform == "identity"`, when the source and target variables carry non-empty, declared-**different** units. A units check on an identity `variable_map`, not tied to any Interface; `conversion_factor` and `param_to_var` transforms are exempt. Implemented in the Julia binding. |
| `UnmappedDomainError` | *reserved / never raised* | Formerly: a cross-domain coupling with no `Interface` mapping rule. With Interfaces removed and 0D↔N-D handled by implicit broadcast, nothing raises it. |
| `UnsupportedMappingError` | *reserved / never raised* | Formerly: an `Interface` requested an unsupported `dimension_mapping`/regridding kind. Reserved for a library that cannot evaluate a requested regridding kernel. |
| `DomainExtentMismatchError` | *reserved / never raised* | Would fire if an `identity` bridge joined domains with incompatible extents; no binding performs this check. |
| `SliceOutOfDomainError` | *reserved / never raised* | Would fire if a `slice` reached outside the source domain; only relevant to a higher-tier `slice` implementation. |
| `CyclicPromotionError` | *reserved / never raised* | Would fire if promotion rules formed a cycle; no promotion graph is built. |

All 8 types MUST remain defined as named exception classes in every implementation for cross-language error-name parity, whether or not a given binding ever raises them.

**Worked example: 0D chemistry + 2D transport.** A file containing `Chem` (a `ReactionSystem` on the 2D grid `grid2d = {x, y}`) and no explicit `Advection` model, coupled only by the presence of a shared domain, flattens to:

```
State variables: Chem.O3, Chem.NO, Chem.NO2     (each a field on {x, y})
Parameters:      Chem.k_NO_O3, Chem.jNO2
Equations (pointwise on grid2d):
  D(Chem.O3, t)  = -Chem.k_NO_O3 * Chem.O3 * Chem.NO + Chem.jNO2 * Chem.NO2
  D(Chem.NO, t)  = [chemistry terms]
  D(Chem.NO2, t) = [chemistry terms]
Independent variables: [:t, :x, :y]
```

Adding an explicit `Advection` model on the same grid with `_var` placeholder equations and coupling them via `operator_compose` sums an advection term onto each of the three equations — the placeholder expansion rule from §4.7.1 is unchanged for hybrid cases.

**Follow-up work.** The full set of hybrid tests — 1D vertical diffusion + 0D surface deposition, 3D PDE + 2D reaction subsystem via a `slice` regridding expression — and the `project`/`regrid` regridding-expression implementations are Analysis-tier and Advanced-tier follow-up work, tracked in successor beads.

### 4.8 Graph Representations

Every library must be able to produce two distinct graph representations of an `.esm` file. These graphs are **data-only**: libraries return language-idiomatic adjacency structures (nodes, edges, connectivity) but do **not** render, lay out, or visualize the graph. Rendering is the sole concern of downstream consumers (`earthsci-ast-editor`'s `<CouplingGraph>` component, CLI export to DOT/Mermaid, or user code).

#### 4.8.1 System Graph (Component-Level)

A directed graph where **nodes are model components** (models, reaction systems, data loaders, operators) and **edges are coupling rules**.

```
component_graph(file: EsmFile) → Graph<ComponentNode, CouplingEdge>
```

**Nodes:**

| Node type | Source |
|---|---|
| `model` | Each key in `models` |
| `reaction_system` | Each key in `reaction_systems` |
| `data_loader` | Each key in `data_loaders` |
| `operator` | Each key in `operators` |

Each node carries its name, type, and summary metadata (variable count, equation count, species count, etc.).

**Edges:**

Each coupling entry produces one or more directed edges:

| Coupling type | Edge(s) |
|---|---|
| `operator_compose` | Bidirectional edge between the two systems |
| `couple` | Bidirectional edge between the two systems |
| `variable_map` | Directed edge from source to target (e.g., `GEOSFP → SimpleOzone`), labeled with the mapped variable |
| `operator_apply` | Directed edge from operator to the system(s) it modifies |
| `callback` | Edge from callback to the system it targets |
| `event` (cross-system) | Directed edge(s) from condition variables' systems to affected variables' systems |

Each edge carries the coupling type, a human-readable label (e.g., `"T"` for a temperature variable map), and the full coupling entry for detail views.

**Example output** for the MinimalChemAdvection file:

```
Nodes: [SimpleOzone (reaction_system), Advection (model), GEOSFP (data_loader)]
Edges:
  SimpleOzone ←operator_compose→ Advection
  GEOSFP —[T]→ SimpleOzone          (variable_map)
  GEOSFP —[u]→ Advection            (variable_map)
  GEOSFP —[v]→ Advection            (variable_map)
```

This is the graph that `earthsci-ast-editor`'s `<CouplingGraph>` component renders visually.

#### 4.8.2 Expression Graph (Variable-Level)

A directed graph where **nodes are variables and parameters** and **edges are mathematical dependencies** extracted from equations.

```
expression_graph(file: EsmFile) → Graph<VariableNode, DependencyEdge>
expression_graph(model: Model) → Graph<VariableNode, DependencyEdge>
expression_graph(system: ReactionSystem) → Graph<VariableNode, DependencyEdge>
expression_graph(equation: Equation) → Graph<VariableNode, DependencyEdge>
expression_graph(reaction: Reaction) → Graph<VariableNode, DependencyEdge>
expression_graph(expr: Expr) → Graph<VariableNode, DependencyEdge>
```

The function can be called at any level of granularity:

- **File:** Merges all systems and resolves coupling into cross-system edges.
- **Model / Reaction system:** Graph for a single component.
- **Equation:** Graph for one equation — the LHS variable as the target, all RHS free variables as sources.
- **Reaction:** Graph for one reaction — substrates, products, and rate parameters as nodes, stoichiometric and rate edges between them.
- **Expression:** Graph for an arbitrary expression — every variable in the expression becomes a node, and the tree structure is flattened into dependency edges. This is useful for inspecting a single rate law or a complex subexpression.

**Nodes:**

Every variable, parameter, and species that appears in any equation or reaction. Each node carries:

- `name: string` — variable name (scoped if from a file-level graph)
- `kind: "state" | "parameter" | "observed" | "species"` — the variable's role
- `units: string | null`
- `system: string` — which model/reaction system owns it

**Edges:**

For each equation `D(x)/dt = f(a, b, c, ...)`, create directed edges from each free variable in the RHS to the LHS variable:

- `a → x` with label `"D(x)/dt"` (meaning: `a` influences the time derivative of `x`)

For reaction systems, edges are derived from the stoichiometry:

- For reaction `NO + O₃ →[k] NO₂`: edges `NO → NO₂`, `O₃ → NO₂`, `NO → NO` (self-loss), `O₃ → O₃` (self-loss), `k → NO₂`, `k → NO`, `k → O₃`.

More precisely, for each reaction, every species and parameter appearing in the rate expression or as a substrate gets an edge to every species whose concentration changes.

Edges carry:

- `source: string` — the influencing variable
- `target: string` — the influenced variable
- `relationship: "additive" | "multiplicative" | "rate" | "stoichiometric"` — how the dependency arises
- `equation_index: number | null` — which equation/reaction produced this edge
- `expression: Expr | null` — the relevant subexpression (optional, for detail views)

**Coupled file-level graph:** When called on a full `EsmFile`, the expression graph resolves coupling rules to create cross-system edges. A `variable_map` from `GEOSFP.T` to `SimpleOzone.T` merges those into a single node (or creates an identity edge, depending on the `merge_coupled` option). An `operator_compose` adds the operator model's RHS dependencies to the target system's variables.

**Example output** for the SimpleOzone reaction system:

```
Nodes: [O₃ (species), NO (species), NO₂ (species), T (param), jNO₂ (param)]
Edges:
  NO  → O₃  (stoichiometric, R1: loss)
  O₃  → O₃  (stoichiometric, R1: loss)
  NO  → NO₂ (stoichiometric, R1: production)
  O₃  → NO₂ (stoichiometric, R1: production)
  T   → O₃  (rate, R1: k(T) in rate expression)
  T   → NO₂ (rate, R1: k(T) in rate expression)
  NO₂ → NO  (stoichiometric, R2: production)
  NO₂ → O₃  (stoichiometric, R2: production)
  jNO₂→ NO  (rate, R2)
  jNO₂→ O₃  (rate, R2)
```

#### 4.8.3 Graph Data Structure

Libraries should return graphs in their language's idiomatic structure. The minimum interface:

```
Graph<N, E>:
  nodes: List<N>
  edges: List<{source: N, target: N, data: E}>
  adjacency(node: N) → List<{neighbor: N, edge: E}>
  predecessors(node: N) → List<N>
  successors(node: N) → List<N>
```

Libraries should also support serializing graphs to common interchange formats (as strings, not rendered images):

- **DOT** (Graphviz) — for piping to `dot` or other layout engines
- **JSON adjacency list** — for web consumption
- **Mermaid** — for embedding in Markdown documentation

---

## 5. Language-Specific Libraries

### 5.1 Julia — `EarthSciAST.jl`

**Tier: Full**

Julia is the primary language for EarthSciML and has the richest integration story. This library bridges ESM files and the ModelingToolkit/Catalyst/EarthSciML ecosystem.

#### 5.1.1 Dependencies

- `JSON3.jl` — JSON parsing/serialization
- `JSONSchema.jl` — schema validation
- `ModelingToolkit.jl` — symbolic ODE systems
- `Catalyst.jl` — reaction networks
- `Unitful.jl` or `DynamicQuantities.jl` — unit checking
- `EarthSciMLBase.jl` — coupled system assembly (for Full tier)

#### 5.1.2 Core API

```julia
using EarthSciAST

# Load and save
file = EarthSciAST.load("model.esm")
EarthSciAST.save(file, "model_v2.esm")

# Pretty-print a model
display(file.models["SuperFast"])
# Output:
#   ∂O₃/∂t = −k_NO_O₃·O₃·NO·M + jNO₂·NO₂
#   ∂NO₂/∂t = k_NO_O₃·O₃·NO·M − jNO₂·NO₂

# LaTeX
EarthSciAST.to_latex(file.models["SuperFast"])

# Print entire file summary
show(file)
# Output:
#   ESM v0.1.0: MinimalChemAdvection
#   Models: Advection (2 params, 1 eq)
#   Reactions: SimpleOzone (3 species, 2 params, 2 rxns)
#   Data Loaders: GEOSFP (u, v, T)
#   Coupling: 4 rules
#   Domain: lon [-130, -100], 2024-05-01 to 2024-05-03

# Validation
result = EarthSciAST.validate(file)
result.is_valid          # true
result.structural_errors # []
result.unit_warnings     # [UnitWarning("k_NO_O3 units cm^3/molec/s may be inconsistent...")]

# Substitution
new_model = substitute(file.models["SuperFast"], Dict("T" => 300.0))

# Derive ODEs from reactions
odes = derive_odes(file.reaction_systems["SimpleOzone"])

# Stoichiometric matrix
S = stoichiometric_matrix(file.reaction_systems["SimpleOzone"])
```

#### 5.1.3 MTK/Catalyst Conversion (Full Tier)

The key capability unique to Julia: bidirectional conversion between ESM and live MTK/Catalyst objects. As of v0.0.2 this is delivered via **Julia package extensions** (the `EarthSciASTMTKExt` and `EarthSciASTCatalystExt` submodules). Users do not need to call any availability-check function — they simply `using` `ModelingToolkit` and/or `Catalyst` and the constructors below become defined.

**Weak dependencies.** `ModelingToolkit`, `Catalyst`, and `Symbolics` are declared in `[weakdeps]` of `EarthSciAST.jl`'s `Project.toml`. Loading `EarthSciAST` alone does **not** force the solver stack to load — precompilation of the main package is fast and side-effect free.

**Public API.** The public API is constructor dispatch on the foreign system types:

```julia
using EarthSciAST, ModelingToolkit, Catalyst

# ESM → FlattenedSystem (single intermediate, always-first step)
flat = flatten(file)

# FlattenedSystem → MTK System (pure-ODE path)
sys = ModelingToolkit.System(flat; name=:SuperFast)
# ArgumentError if flat.independent_variables includes spatial dims — the
# error message explicitly redirects the user to ModelingToolkit.PDESystem.

# FlattenedSystem → MTK PDESystem (PDE path)
pde = ModelingToolkit.PDESystem(flat; name=:SuperFast)
# ArgumentError if flat is a pure ODE (independent_variables == [:t]) —
# the error message explicitly redirects the user to ModelingToolkit.System.

# Convenience forms that flatten first:
sys = ModelingToolkit.System(file.models["SuperFast"];    name=:SuperFast)
pde = ModelingToolkit.PDESystem(file.models["Atmosphere"]; name=:Atmosphere)

# Catalyst
rxn = Catalyst.ReactionSystem(file.reaction_systems["SimpleOzone"]; name=:Ozone)

# Reverse direction (round-trip for tests and tooling)
model = EarthSciAST.Model(sys)
rxn_m = EarthSciAST.ReactionSystem(rxn)

# Simulate
using OrdinaryDiffEq
prob = ODEProblem(sys, file.domain)   # or discretize() for PDESystem
sol = solve(prob, Tsit5())
```

**Fallback without MTK/Catalyst.** If the user has not imported `ModelingToolkit` or `Catalyst`, the same constructor pattern is available via `MockMTKSystem`, `MockPDESystem`, and `MockCatalystSystem` — plain-Julia struct types exported from the main package:

```julia
using EarthSciAST   # no MTK, no Catalyst

mock_sys = MockMTKSystem(file.models["SuperFast"];    name=:SuperFast)
mock_pde = MockPDESystem(file.models["Atmosphere"];   name=:Atmosphere)
mock_cat = MockCatalystSystem(file.reaction_systems["SimpleOzone"]; name=:Ozone)
```

`MockMTKSystem(::Model)` on a PDE-shaped model raises the same `ArgumentError` that redirects the user to `MockPDESystem`, and vice versa — the dispatch semantics mirror the real constructors. These mocks are the no-MTK fallbacks called out by the §1.2 capability tiers; tier detection uses `Base.get_extension(EarthSciAST, :EarthSciASTMTKExt)` rather than an ad-hoc `check_mtk_availability` helper.

**Flattened system to MTK conversion details.**

The constructor `ModelingToolkit.System(::FlattenedSystem)` handles the pure-ODE path; `ModelingToolkit.PDESystem(::FlattenedSystem)` handles the PDE path. The dispatch split is determined by `flat.independent_variables` (which is populated by `flatten` based on the hybrid-flattening rules in §4.7.6):

- `independent_variables == [:t]` → ODE path. Build an `ODESystem`/`System` with state variables depending on `t`, equations, continuous/discrete events.
- `independent_variables` contains spatial dims (`:x`, `:y`, `:z`, ...) → PDE path. Build a `PDESystem` with state variables depending on `t` and the spatial dims, equations, boundary conditions, and initial conditions.

The constructors always call `flatten` internally when invoked on a `Model` or `EsmFile`, so users do not need to flatten themselves unless they want to inspect the intermediate. There is a single source of truth for dimension and coupling resolution — the `flatten` step — and the extension code only deals with the already-canonical FlattenedSystem.

**Surface-source → flux BC lowering (Julia-specific convention).**

When the flattened system includes a state variable of the form `V.at_<dim>` that is produced by a `slice_variable` primitive and has a standalone ODE `D(V.at_<dim>, t) = f(...)`, AND the base variable `V` has a diffusive equation on the same spatial dimension, the Julia extension **lowers the slice-ODE to a flux boundary condition** on the base variable:

```
D_coeff * Differential(<dim>)(V)(t, <dim>_0) ~ f(...)
```

rather than emitting the slice-ODE as a pointwise source term in the lowest grid cell. This is the physically correct interpretation for surface deposition of a diffusing tracer (the surface deposition velocity has units of length/time and acts as a flux, not a volumetric source). §4.7.6.6 permits either interpretation at the spec level; the Julia library's choice is flux BC. Substitution rewrites references to `V.at_<dim>` in `f(...)` to reference the base variable `V` at the slice coordinate, so the resulting BC is self-contained.

This lowering is implemented inside `EarthSciASTMTKExt`; the `EarthSciMLBase.slice_variable` primitive itself remains interpretation-agnostic.

**Removed APIs (v0.0.2 breaking change, acceptable at pre-1.0).** The following names that existed in earlier pre-release versions have been deleted:

- `to_mtk_system`, `to_catalyst_system`
- `from_mtk_system`, `from_catalyst_system`
- `check_mtk_availability`, `check_catalyst_availability`, `check_mtk_catalyst_availability`
- `src/availability.jl` (the runtime availability-check module)

Callers must migrate to the constructor-dispatch API above.

#### 5.1.4 Expression Mapping

| ESM AST | MTK/Symbolics.jl |
|---|---|
| `{"op": "D", "args": ["O3"], "wrt": "t"}` | `Differential(t)(O3)` |
| `{"op": "+", "args": ["a", "b"]}` | `a + b` |
| `{"op": "exp", "args": ["x"]}` | `exp(x)` |
| `{"op": "Pre", "args": ["x"]}` | `Pre(x)` |
| `{"op": "grad", "args": ["x"], "dim": "y"}` | `Differential(y)(x)` |
| `{"op": "ifelse", "args": [cond, a, b]}` | `ifelse(cond, a, b)` |
| `"O3"` (string) | `@variables O3(t)` |
| `3.14` (number) | `3.14` (literal) |

#### 5.1.5 Event Mapping

| ESM Event | MTK Callback |
|---|---|
| Continuous event | `SymbolicContinuousCallback` |
| Discrete event (condition) | `SymbolicDiscreteCallback` with boolean condition |
| Discrete event (periodic) | `SymbolicDiscreteCallback` with `PeriodicCallback` |
| Discrete event (preset_times) | `SymbolicDiscreteCallback` with `PresetTimeCallback` |
| `affect_neg` | `SymbolicContinuousCallback(conditions, affect, affect_neg=...)` |
| `discrete_parameters` | `SymbolicDiscreteCallback(...; discrete_parameters=[p])` |
| Functional affect | `(affect!, [vars...], [params...], [discretes...], ctx)` tuple registered by `handler_id` |

#### 5.1.6 End-to-End Simulation Test Coverage

`EarthSciAST.jl` produces simulation-ready `ModelingToolkit.System`
objects, so its test suite MUST verify that the returned systems integrate
correctly end-to-end with `OrdinaryDiffEq`. Construction-only tests (verifying
that a non-mock object is returned) are insufficient: they cannot catch
silent bugs such as non-numeric `Expr` nodes, missing initial conditions, unit
mismatches, or singular Jacobians — all of which surface only inside `solve`.

The test file `test/simulate_e2e_test.jl` is part of `runtests.jl` and MUST
cover at minimum:

1. **Exponential decay** — `D(x, t) = −k·x`, `x(0) = 1`, `k = 0.1`. Build via
   `ModelingToolkit.System(::Model)`, call `ODEProblem` + `solve` with `Tsit5`
   to `t = 10`, assert `x(10) ≈ exp(−1)` to `rtol = 1e-6`. Sample intermediate
   points against the analytical curve.

2. **Reversible first-order reaction** — `A ⇌ B` with `k_fwd = 1.0`,
   `k_rev = 0.5`, `A(0) = 1`, `B(0) = 0`. Integrate to steady state and
   assert `A_eq = k_rev / (k_fwd + k_rev)`, `B_eq = k_fwd / (k_fwd + k_rev)`
   along with mass conservation `A + B = A0 + B0`.

3. **Autocatalytic reaction with mass conservation** —
   `A + B → 2B` with `k = 2.0`, `A(0) = 1`, `B(0) = 0.01`. Built via the
   `ReactionSystem` → `flatten` → `ModelingToolkit.System` path so the
   reaction-to-ODE derivation is exercised. Assert that total mass `A + B`
   is conserved at every stored time step (`atol = 1e-8`) and that the
   trajectory matches the closed-form logistic solution at several
   intermediate points.

4. **Robertson stiff benchmark** —
   `dA/dt = −0.04·A + 1e4·B·C`,
   `dB/dt =  0.04·A − 1e4·B·C − 3e7·B²`,
   `dC/dt =  3e7·B²`, with `A(0) = 1`, `B(0) = C(0) = 0`. Integrate with
   `Rodas5P` (or any L-stable Rosenbrock) to `t = 4e10`. Assert against
   the reference values in Hairer & Wanner, *Solving ODEs II*, Table 1.4
   at `t ∈ {0.4, 4, 40, 400, 4000, 40000}` to `rtol = 5e-4`, plus mass
   conservation `A + B + C = 1` and the steady-state limit
   `A, B → 0, C → 1` at `t = 4e10`. Robertson is the canonical stiff
   validation case; if it integrates correctly, the stiff path is proven.

5. **.esm fixture round-trip vs inline reference** —
   Load each fixture under `tests/simulation/*.esm`, walk its inline
   `tests` blocks, build a `System`, and compare the numerical trajectory
   against each test's declared `assertions` at the documented
   sample times under the resolved (assertion > test > model) tolerance.
   This proves that the Julia library reproduces the cross-language
   analytical or numerical reference carried in the fixture itself — the
   earlier `reference_solutions/*.json` filesystem pairing was migrated
   to inline `tests` blocks by gt-l5b and gt-3lff.

**Dependency discipline.** The solver packages used by these tests
(`OrdinaryDiffEqTsit5`, `OrdinaryDiffEqRosenbrock`) MUST live in
`[extras]` + `[targets].test` only — never in `[deps]`. The runtime package
remains lean and precompiles fast; users who only need `load`/`save`/`flatten`
do not pay the cost of the full `SciMLBase` stack.

**Initial conditions and parameters.** The `EarthSciASTMTKExt`
constructor wires `ModelVariable.default` values into the Symbolics variables
via `Symbolics.setdefaultval`, so `ODEProblem(sys, [], tspan)` can be called
with an empty `u0` / `p` map — MTK picks up the defaults automatically. This
is what makes the e2e tests callable without manually restating the
initial-condition map that was already declared in the ESM model.

---

### 5.2 TypeScript / SolidJS — `@earthsciml/ast` + `earthsci-ast-editor`

**Tier: Core + Analysis (@earthsciml/ast), Interactive Editing (earthsci-ast-editor)**

The web story is split into two packages with a clean dependency boundary:

- **`@earthsciml/ast`** — Pure TypeScript, zero framework dependencies. Types, parsing, validation, substitution, LaTeX/Unicode string generation. Usable in any JS/TS environment (Node, Deno, Bun, browser, web workers).
- **`earthsci-ast-editor`** — SolidJS-based interactive expression and model editor. Renders the AST directly as clickable, editable DOM elements. Exported as both Solid components and framework-agnostic web components.

#### 5.2.1 Why SolidJS for the Editor

The expression editor is fundamentally a tree of reactive nodes. When a user clicks a variable in a 200-term equation and replaces it, only that node and its ancestors need to update. This maps directly to Solid's reactivity model:

- **Granular reactivity:** Each AST node is a signal. Editing one node updates only its DOM element — no virtual DOM diffing of the entire expression tree.
- **`createStore` with path-based updates:** `setStore("args", 1, "args", 0, "op", "+")` maps naturally to AST path manipulation.
- **No re-render cascade:** React would re-render the whole expression tree on any edit (or require extensive `memo` boundaries at every node). Solid updates in place.
- **Small bundle:** The editor component adds ~7KB gzipped (Solid runtime) vs ~40KB+ (React).
- **Web component export:** Solid components compile to native custom elements via `solid-element`, making them embeddable in React, Vue, Svelte, plain HTML, or the seshat.pub platform without framework coupling.

#### 5.2.2 `@earthsciml/ast` — Pure TypeScript Library

**Dependencies:** `ajv` (schema validation). No framework, no DOM.

```
esm-format/
├── src/
│   ├── types.ts          # TypeScript type definitions matching JSON Schema
│   ├── parse.ts          # JSON → typed EsmFile
│   ├── serialize.ts      # EsmFile → JSON
│   ├── expression.ts     # Expr type, construction, traversal
│   ├── pretty-print.ts   # Unicode, LaTeX, ASCII string formatters
│   ├── substitute.ts     # Expression and model-level substitution
│   ├── validate.ts       # Schema + structural + unit validation
│   ├── units.ts          # Unit parsing and dimensional analysis
│   ├── reactions.ts      # Stoichiometric matrix, ODE derivation
│   ├── edit.ts           # Model editing operations
│   ├── codegen.ts        # Julia/Python code generation from ESM
│   └── index.ts          # Public API
├── schema/
│   └── esm.schema.json   # Bundled JSON Schema
├── tests/
└── package.json
```

**Core API:**

```typescript
import {
  load, save, validate,
  substitute, freeVariables,
  deriveODEs, stoichiometricMatrix,
  toLatex, toUnicode, toAscii,
  type EsmFile, type Expr, type Model
} from '@earthsciml/ast';

// Parse from JSON string or object
const file: EsmFile = load(jsonString);

// Serialize back
const json: string = save(file);

// Pretty-print to strings (no DOM, no framework)
console.log(toUnicode(file.models!['SuperFast']));
// ∂O₃/∂t = −k_NO_O₃·O₃·NO·M + jNO₂·NO₂

const latex: string = toLatex(file.models!['SuperFast']);
// \frac{\partial \mathrm{O_3}}{\partial t} = ...

// Validate
const result = validate(file);
console.log(result.isValid);           // true
console.log(result.structuralErrors);  // []

// Substitute
const modified = substitute(file.models!['SuperFast'], { T: 300.0 });

// Free variables in an expression
const vars: Set<string> = freeVariables(expr);

// Derive ODEs from reactions
const odeModel: Model = deriveODEs(file.reactionSystems!['SimpleOzone']);

// Stoichiometric matrix
const S: number[][] = stoichiometricMatrix(file.reactionSystems!['SimpleOzone']);

// Generate Julia code for backend simulation
const juliaCode: string = toJuliaCode(file);
```

**Type definitions:**

```typescript
// Expression AST
type Expr = number | string | ExprNode;

interface ExprNode {
  op: string;
  args: Expr[];
  wrt?: string;  // for D
  dim?: string;  // for grad
}

// Discriminated union for coupling
type CouplingEntry =
  | { type: 'operator_compose'; systems: [string, string]; translate?: Record<string, TranslateTarget>; description?: string }
  | { type: 'couple'; systems: [string, string]; connector: Connector; description?: string }
  | { type: 'variable_map'; from: string; to: string; transform: string; factor?: number; description?: string }
  | { type: 'operator_apply'; operator: string; description?: string }
  | { type: 'callback'; callback_id: string; config?: Record<string, unknown>; description?: string }
  | { type: 'event'; event_type: 'continuous' | 'discrete'; /* ... */ };

// Discrete event trigger - discriminated union
type DiscreteEventTrigger =
  | { type: 'condition'; expression: Expr }
  | { type: 'periodic'; interval: number; initial_offset?: number }
  | { type: 'preset_times'; times: number[] };
```

Types should be auto-generated from the JSON Schema where possible (using `json-schema-to-typescript`), then augmented with utility functions.

#### 5.2.3 `earthsci-ast-editor` — SolidJS Interactive Editor

**Dependencies:** `solid-js`, `solid-element` (web component export), `@earthsciml/ast` (peer dependency).

```
earthsci-ast-editor/
├── src/
│   ├── components/
│   │   ├── ExpressionNode.tsx    # Core: renders a single AST node
│   │   ├── ExpressionEditor.tsx  # Composes nodes into a full expression
│   │   ├── EquationEditor.tsx    # LHS = RHS with editable sides
│   │   ├── ModelEditor.tsx       # Full model: variables + equations + events
│   │   ├── ReactionEditor.tsx    # Reaction system editor
│   │   ├── CouplingGraph.tsx     # Visual coupling diagram
│   │   ├── ValidationPanel.tsx   # Live validation feedback
│   │   └── FileSummary.tsx       # Overview of entire ESM file
│   ├── primitives/
│   │   ├── ast-store.ts          # Solid store wrapping EsmFile
│   │   ├── selection.ts          # Selected AST node tracking
│   │   ├── highlighted-var.ts    # Cross-equation variable highlight on hover
│   │   ├── history.ts            # Undo/redo stack
│   │   └── validation.ts         # Reactive validation signals
│   ├── layout/
│   │   ├── fraction.tsx          # CSS fraction layout
│   │   ├── superscript.tsx       # Exponent positioning
│   │   ├── subscript.tsx         # Chemical subscript
│   │   ├── radical.tsx           # Square root rendering
│   │   └── delimiters.tsx        # Parentheses with auto-sizing
│   ├── web-components.ts         # Custom element registration
│   └── index.ts                  # Public API
├── tests/
└── package.json
```

#### 5.2.4 `ExpressionNode` — The Core Component

Every AST node renders as a Solid component that knows its own path, handles click/hover events, and uses CSS for math-like layout. This is the key design — no KaTeX, no MathJax, no static rendering. The math _is_ the editor.

```tsx
// Conceptual structure — each AST node is an interactive component
import { Component, Show, For, createSignal } from 'solid-js';
import type { Expr, ExprNode } from '@earthsciml/ast';

interface ExpressionNodeProps {
  expr: Expr;                      // reactive (from Solid store)
  path: (string | number)[];       // AST path for this node
  highlightedVars: Accessor<Set<string>>;   // currently highlighted equivalence class
  onHoverVar: (name: string | null) => void; // set/clear hovered variable
  onSelect: (path: (string | number)[]) => void;
  onReplace: (path: (string | number)[], newExpr: Expr) => void;
}

const ExpressionNodeComponent: Component<ExpressionNodeProps> = (props) => {
  const [hovered, setHovered] = createSignal(false);

  // Number literal
  if (typeof props.expr === 'number') {
    return (
      <span
        class="esm-num"
        classList={{ 'esm-hovered': hovered() }}
        onMouseEnter={() => setHovered(true)}
        onMouseLeave={() => setHovered(false)}
        onClick={() => props.onSelect(props.path)}
      >
        {formatNumber(props.expr)}
      </span>
    );
  }

  // Variable reference
  if (typeof props.expr === 'string') {
    const isHighlighted = () => props.highlightedVars().has(props.expr);
    return (
      <span
        class="esm-var"
        classList={{
          'esm-hovered': hovered(),
          'esm-var-highlighted': isHighlighted(),
        }}
        onMouseEnter={() => { setHovered(true); props.onHoverVar(props.expr); }}
        onMouseLeave={() => { setHovered(false); props.onHoverVar(null); }}
        onClick={() => props.onSelect(props.path)}
      >
        {renderChemicalName(props.expr)}  {/* O3 → O₃ */}
      </span>
    );
  }

  // Operator node — dispatch to layout components
  return <OperatorLayout node={props.expr} path={props.path} {...props} />;
};
```

**Layout components** handle the visual math rendering:

```tsx
// Fraction layout for division
const FractionLayout: Component<{num: Expr; den: Expr; path: ...}> = (props) => (
  <span class="esm-frac">
    <span class="esm-frac-num">
      <ExpressionNodeComponent expr={props.num} path={[...props.path, 'args', 0]} />
    </span>
    <span class="esm-frac-bar" />
    <span class="esm-frac-den">
      <ExpressionNodeComponent expr={props.den} path={[...props.path, 'args', 1]} />
    </span>
  </span>
);

// Derivative layout: ∂O₃/∂t rendered as fraction
const DerivativeLayout: Component<{node: ExprNode; path: ...}> = (props) => (
  <span class="esm-deriv">
    <span class="esm-frac">
      <span class="esm-frac-num">∂<ExpressionNodeComponent expr={props.node.args[0]} ... /></span>
      <span class="esm-frac-bar" />
      <span class="esm-frac-den">∂{props.node.wrt}</span>
    </span>
  </span>
);
```

**CSS handles math typography** — no canvas, no SVG, just styled spans:

```css
.esm-frac {
  display: inline-flex;
  flex-direction: column;
  align-items: center;
  vertical-align: middle;
}
.esm-frac-bar {
  width: 100%;
  height: 1px;
  background: currentColor;
  margin: 1px 0;
}
.esm-frac-num, .esm-frac-den {
  padding: 0 2px;
  font-size: 0.85em;
}
.esm-var {
  font-style: italic;
  cursor: pointer;
  transition: background 0.1s ease;
}
.esm-var:hover, .esm-hovered {
  background: rgba(59, 130, 246, 0.1);
  border-radius: 2px;
}
.esm-var-highlighted {
  background: rgba(250, 204, 21, 0.25);
  border-radius: 2px;
  box-shadow: 0 0 0 1px rgba(250, 204, 21, 0.5);
}
.esm-var-highlighted.esm-hovered {
  background: rgba(250, 204, 21, 0.4);
}
.esm-selected {
  background: rgba(59, 130, 246, 0.2);
  outline: 1px solid rgb(59, 130, 246);
  border-radius: 2px;
}
.esm-num {
  font-variant-numeric: tabular-nums;
  cursor: pointer;
}
```

#### 5.2.5 Interaction Model

**Variable hover highlighting:** Hovering over any variable name highlights _every_ occurrence of that variable across all visible equations. This works across equation boundaries — hover `O₃` in one equation and every `O₃` in the model lights up in yellow. The highlight is driven by a `highlightedVars` signal shared across all `ExpressionNode` instances:

```typescript
import { createSignal, createMemo } from 'solid-js';
import type { EsmFile } from '@earthsciml/ast';

// Build equivalence classes from coupling rules at file load / on coupling change
function buildVarEquivalences(file: EsmFile): Map<string, Set<string>> {
  const groups = new UnionFind<string>();

  for (const entry of file.coupling ?? []) {
    if (entry.type === 'variable_map') {
      // GEOSFP.T → SimpleOzone.T means these are the same quantity
      groups.union(entry.from, entry.to);
    }
    if (entry.type === 'operator_compose' && entry.translate) {
      for (const [from, to] of Object.entries(entry.translate)) {
        const toVar = typeof to === 'string' ? to : to.var;
        groups.union(from, toVar);
      }
    }
  }

  // Return a map: any variable name → all equivalent names
  return groups.toEquivalenceMap();
}

// One signal per editor scope
const equivalences = createMemo(() => buildVarEquivalences(file));
const [hoveredVar, setHoveredVar] = createSignal<string | null>(null);

// The set of names to highlight — includes all equivalent variables
const highlightedVars = createMemo(() => {
  const v = hoveredVar();
  if (!v) return new Set<string>();
  return equivalences().get(v) ?? new Set([v]);
});

// Each ExpressionNode checks membership in the set
// isHighlighted = () => highlightedVars().has(props.expr)
```

**Highlighting passes through equalities.** The coupling section defines which variables across different models refer to the same physical quantity. When `variable_map` maps `GEOSFP.T` to `SimpleOzone.T`, or `operator_compose` translates `SuperFast.O3` to `Advection._var`, these form equivalence classes. Hovering any member of an equivalence class highlights all members that are currently visible.

Concretely: if the file contains `{ "type": "variable_map", "from": "GEOSFP.T", "to": "SimpleOzone.T" }`, then hovering `T` in the SimpleOzone model also highlights `T` in the GEOSFP data loader panel and `GEOSFP.T` / `SimpleOzone.T` in the coupling graph. The user sees the full data flow path for that quantity.

Equivalence classes are computed once (and reactively recomputed when coupling rules change) using a union-find structure. The `highlightedVars` memo produces a `Set<string>` so that each `ExpressionNode`'s `isHighlighted()` check is an O(1) set lookup, not a traversal.

The highlight scoping is configurable:
- **Model scope** (default): Highlight within the current model or reaction system. Equivalences are not resolved — only literal name matches.
- **File scope:** Highlight across all models with equivalence resolution. This is the mode where hovering `T` in one model lights up every coupled `T` everywhere. This is the most useful mode for understanding data flow.
- **Equation scope:** Highlight only within the current equation.

Scoped references are normalized: both `O3` (bare) and `SimpleOzone.O3` (qualified) are recognized as the same variable when the context model is `SimpleOzone`. For subsystems, the full path is used: `SimpleOzone.GasPhase.O3` refers to variable `O3` in subsystem `GasPhase` of `SimpleOzone`.

**Selection:** Click any AST node to select it. The selected node is highlighted and its AST path is exposed. A detail panel shows the node's type, value, parent context, and available actions.

**Inline editing:** Double-click a number to type a new value. Double-click a variable to get an autocomplete dropdown of available variables. Changes propagate through the Solid store and trigger revalidation.

**Structural editing:** Select a node, then:
- **Replace:** Type a new expression or pick from a palette.
- **Wrap:** Wrap the selected node in an operator (e.g., select `O3`, click "negate" → `−O3`).
- **Unwrap:** If the selected node is a unary op, replace it with its argument.
- **Delete:** Remove a term from a sum/product (adjusting the parent node).
- **Drag-and-drop:** Reorder terms in commutative operations (addition, multiplication).

**Expression palette:** A sidebar with common operations — derivatives, common functions, arithmetic operators, chemical species from the current model. Drag from palette to expression to insert.

**Store architecture:**

```typescript
import { createStore, produce } from 'solid-js/store';
import type { EsmFile } from '@earthsciml/ast';
import { validate } from '@earthsciml/ast';

const [file, setFile] = createStore<EsmFile>(loadedFile);

// Path-based update — only the affected node re-renders
function replaceNode(path: (string | number)[], newExpr: Expr) {
  setFile(...pathToStoreArgs(path), newExpr);
  // Solid automatically updates only the affected ExpressionNode
}

// Example: replace the rate of reaction R1
setFile('reaction_systems', 'SimpleOzone', 'reactions', 0, 'rate', {
  op: '*',
  args: [2.0e-12, { op: 'exp', args: [{ op: '/', args: [-1400, 'T'] }] }]
});

// Validation runs reactively
const validationResult = createMemo(() => validate(file));
```

**Undo/redo:**

```typescript
import { createUndoHistory } from './primitives/history';

const { undo, redo, canUndo, canRedo } = createUndoHistory(file, setFile);
// Each setFile call is automatically captured as a history entry
```

#### 5.2.6 Web Component Export

`earthsci-ast-editor` components are exported as standard web components via `solid-element`, making them embeddable in any framework:

```typescript
// web-components.ts
import { customElement } from 'solid-element';
import { ExpressionEditor } from './components/ExpressionEditor';
import { ModelEditor } from './components/ModelEditor';

customElement('esm-expression-editor', { expr: {}, onChange: () => {} }, ExpressionEditor);
customElement('esm-model-editor', { model: {}, onChange: () => {} }, ModelEditor);
customElement('esm-file-editor', { file: {}, onChange: () => {} }, FileEditor);
```

Usage in plain HTML:
```html
<esm-expression-editor
  expr='{"op": "+", "args": ["a", "b"]}'
  onchange="handleChange(event.detail)"
/>
```

Usage in React (via wrapper or directly as custom element):
```jsx
<esm-model-editor
  ref={el => { el.model = myModel; el.addEventListener('change', handleChange); }}
/>
```

Usage in the seshat.pub platform or any other framework — no adapter needed.

#### 5.2.7 Higher-Level Editor Components

Beyond individual expressions, `earthsci-ast-editor` provides composed editors for entire sections:

**`<ModelEditor>`** — Displays all equations in a model with editable variables panel, equation list, and event editor. Variables show type badges (state/parameter/observed) and units.

**`<ReactionEditor>`** — Reaction system editor showing reactions in chemical notation (`NO + O₃ →[k₁] NO₂`) with clickable rate expressions. Add/remove reactions via UI.

**`<CouplingGraph>`** — Visual directed graph of model components and their coupling relationships. Nodes are models/reaction systems/data loaders; edges are coupling entries. Click an edge to edit the coupling rule. Consumes the data-only graph structure from `@earthsciml/ast`'s `component_graph()` and handles layout and rendering internally (e.g., using `d3-force` for layout, Solid for DOM rendering).

**`<FileSummary>`** — Read-only overview panel showing the structured summary (as specified in Section 6.3 of this document), with links that scroll to / select the relevant editor section.

**`<ValidationPanel>`** — Reactive panel showing schema errors, structural errors, and unit warnings. Updates live as the user edits. Clicking an error highlights the offending node in the expression editor.

#### 5.2.8 Code Generation

The pure `@earthsciml/ast` library (not the editor) provides code generation for backend simulation. Code generation covers **models and reaction systems** — their variables, parameters, equations, reactions, and events. Coupling and domain configuration are emitted as structured comments or stubs that the user can complete manually.

**Scope:** Code generation must handle:

- Model variables (state, parameter, observed) with units and defaults.
- Model equations (ODE equations with full expression translation).
- Reaction system species, parameters, and reactions.
- Events (continuous and discrete) with affect equations.

Code generation does **not** need to handle (these are emitted as TODO comments):

- Coupling resolution (the generated code defines individual systems; the user composes them).
- Domain setup (emitted as commented-out boilerplate with values from the file).
- Data loaders and operators (runtime-specific; emitted as placeholder comments with the loader/operator ID).

```typescript
import { toJuliaCode, toPythonCode } from '@earthsciml/ast';

// Generate a self-contained Julia script
const julia: string = toJuliaCode(file);
// Output:
//   using ModelingToolkit, Catalyst, EarthSciMLBase, OrdinaryDiffEq
//   @parameters T = 298.15 [unit = u"K"] jNO2 = 0.005 [unit = u"1/s"]
//   @species O3(t) = 40e-9 NO(t) = 0.1e-9 NO2(t) = 1e-9
//   rxs = [
//     Reaction(1.8e-12 * exp(-1370/T), [NO, O3], [NO2]),
//     Reaction(jNO2, [NO2], [NO, O3]),
//   ]
//   @named sys = ReactionSystem(rxs, t)
//   # TODO: Coupling — operator_compose(SimpleOzone, Advection)
//   # TODO: Domain — lon [-130, -100], 2024-05-01 to 2024-05-03

// Generate a self-contained Python script
const python: string = toPythonCode(file);
// Output:
//   import earthsci_ast as esm
//   file = esm.load_string('''...''')
//   solution = esm.simulate(file, tspan=(0, 86400), ...)
```

**Expression-to-code mapping:**

| ESM AST | Julia output | Python output |
|---|---|---|
| `{"op": "+", "args": ["a", "b"]}` | `a + b` | `a + b` |
| `{"op": "*", "args": ["k", "A", "B"]}` | `k * A * B` | `k * A * B` |
| `{"op": "D", "args": ["O3"], "wrt": "t"}` | `D(O3)` | `Derivative(O3(t), t)` |
| `{"op": "exp", "args": [x]}` | `exp(x)` | `sp.exp(x)` |
| `{"op": "ifelse", "args": [c, a, b]}` | `ifelse(c, a, b)` | `sp.Piecewise((a, c), (b, True))` |
| `{"op": "Pre", "args": ["x"]}` | `Pre(x)` | `Function('Pre')(x)` |
| `{"op": "^", "args": ["x", 2]}` | `x^2` | `x**2` |
| `{"op": "grad", "args": ["x"], "dim": "y"}` | `Differential(y)(x)` | `sp.Derivative(x, y)` |

---

### 5.3 Python — `earthsci_ast`

**Tier: Core + Analysis + Simulation**

Python provides simulation capability via SymPy for symbolic manipulation and SciPy for numerical integration.

#### 5.3.1 Dependencies

- `jsonschema` — schema validation
- `sympy` — symbolic math, expression representation, ODE solving
- `scipy` — numerical ODE integration (`solve_ivp`)
- `pint` — unit validation
- `numpy` — numerical arrays

#### 5.3.2 Package Structure

```
earthsci_ast/
├── __init__.py
├── types.py          # Dataclass definitions for ESM types
├── parse.py          # JSON → dataclasses
├── serialize.py      # Dataclasses → JSON
├── expression.py     # Expr ↔ SymPy conversion, pretty-print
├── substitute.py     # Substitution operations
├── validate.py       # Schema + structural + unit validation
├── units.py          # Pint-based unit checking
├── reactions.py      # Stoichiometric matrix, ODE derivation
├── edit.py           # Model editing operations
├── simulate.py       # SymPy → SciPy ODE solver bridge
└── display.py        # IPython/Jupyter display integration
```

#### 5.3.3 Core API

```python
import earthsci_ast as esm

# Load and save
file = esm.load("model.esm")
esm.save(file, "model_v2.esm")

# Pretty-print (uses sympy.pretty or LaTeX)
print(esm.to_unicode(file.models["SuperFast"]))
# ∂O₃/∂t = −k_NO_O₃·O₃·NO·M + jNO₂·NO₂

print(esm.to_latex(file.models["SuperFast"]))
# \frac{\partial O_3}{\partial t} = ...

# In Jupyter notebooks — rich display
file.models["SuperFast"]  # renders LaTeX equations inline

# Validate
result = esm.validate(file)
assert result.is_valid
print(result.unit_warnings)

# Substitute
modified = esm.substitute(file.models["SuperFast"], {"T": 300.0})

# Derive ODEs
ode_model = esm.derive_odes(file.reaction_systems["SimpleOzone"])
```

#### 5.3.4 SymPy Integration

The Python library converts ESM expressions to SymPy `Expr` objects and back:

| ESM AST | SymPy |
|---|---|
| `{"op": "D", "args": ["O3"], "wrt": "t"}` | `Derivative(O3(t), t)` |
| `{"op": "+", "args": ["a", "b"]}` | `a + b` |
| `{"op": "exp", "args": [{"op": "/", "args": [-1370, "T"]}]}` | `exp(-1370/T)` |
| `{"op": "Pre", "args": ["x"]}` | `Function('Pre')(x)` (custom) |
| `{"op": "*", "args": [1.8e-12, "O3", "NO"]}` | `1.8e-12 * O3 * NO` |
| `{"op": "ifelse", "args": [c, a, b]}` | `Piecewise((a, c), (b, True))` |
| `"O3"` (string) | `Symbol('O3')` or `Function('O3')(t)` |

```python
# Convert ESM expression to SymPy
sympy_expr = esm.to_sympy(esm_expression)

# Convert SymPy expression back to ESM
esm_expr = esm.from_sympy(sympy_expr)

# Use SymPy's simplify
simplified = esm.simplify(esm_expression)  # wraps sympy.simplify

# Symbolic Jacobian
J = esm.jacobian(file.models["SuperFast"])  # returns SymPy Matrix
```

#### 5.3.5 Simulation via SciPy

The Python `simulate()` function consumes a `FlattenedSystem` as its canonical input (per spec §4.7.5 — the flattened representation is the API boundary between coupling resolution and any downstream backend). The `EsmFile` overload is a thin convenience wrapper that calls `flatten()` internally.

```python
# Simulate from a FlattenedSystem (canonical path)
flat = esm.flatten(file)
solution = esm.simulate(
    flat,
    tspan=(0, 86400),       # 1 day in seconds
    parameters={"SimpleOzone.T": 298.15, "SimpleOzone.jNO2": 0.005},
    initial_conditions={"SimpleOzone.O3": 40e-9, "SimpleOzone.NO": 0.1e-9},
    method="BDF",
)

# Convenience overload — flattens internally
solution = esm.simulate(
    file,
    tspan=(0, 86400),
    parameters={"T": 298.15, "jNO2": 0.005},  # bare names also accepted
    initial_conditions={"O3": 40e-9, "NO": 0.1e-9, "NO2": 1e-9},
    method="BDF",
)

# solution is a SimulationResult
print(solution.t)     # time points
print(solution.y)     # state trajectories (rows in solution.vars order)
print(solution.vars)  # ["SimpleOzone.O3", "SimpleOzone.NO", "SimpleOzone.NO2"]
solution.plot()       # matplotlib integration
```

**Parameter and initial condition lookup.** Both dot-namespaced (`"SimpleOzone.k"`) and bare names (`"k"`) are accepted. The dot-namespaced form takes precedence; the bare name acts as an unambiguous fallback. Parameters not provided fall back to the variable's `default` (or `0`).

**Implementation approach:**

1. Call `flatten(file)` to obtain the canonical `FlattenedSystem`. This pre-resolves all coupling rules — `operator_compose` (LHS-match + sum, with `_var` placeholder expansion), `couple` connectors, and `variable_map` substitutions — and lowers reaction systems to ODEs via `derive_odes()`.
2. Reject *undiscretized* spatial operators: if `len(flat.independent_variables) > 1`, raise `UnsupportedDimensionalityError` (see §5.4.6 for the cross-language origin of this error name in the Rust simulator). A surviving spatial independent variable means a spatial operator was never discretized into an `arrayop` stencil. Once discretized, the spatial axis folds into array dimensions, so `independent_variables == ["t"]` and `simulate()` integrates the PDE through the array-op interpreter like any other system.
3. Convert each flattened equation's RHS to a SymPy expression using the dot-namespaced symbol map.
4. Substitute parameter values, then `sympy.lambdify()` to create a fast NumPy-callable RHS function.
5. Call `scipy.integrate.solve_ivp()`.

**Dimension promotion tier (§4.7.6).** The Python library is **Core tier** for dimension promotion: it handles broadcast and identity mappings (a flattened system whose independent variables are exactly `["t"]`). Slice, project, and regrid mappings raise `UnsupportedMappingError`. An *undiscretized* spatial operator (a spatial independent variable surviving in the flattened system) raises `UnsupportedDimensionalityError`, with a message telling the user to apply the discretization template that lowers it to an `arrayop` stencil. This is not a PDE-capability limit: once discretized, Python simulates the PDE natively (§5.9 cross-language PDE-simulation conformance).

**Conflict and validation errors.** `flatten()` exposes the full Rust `FlattenError` taxonomy as Python exception classes (cross-language error-name parity per §4.7.5 and §4.7.6):

- `ConflictingDerivativeError` (§4.7.5) when two systems define non-additive equations for the same dependent variable;
- `DimensionPromotionError` (§4.7.6) when a variable or equation cannot be promoted given the available `Interface`s;
- `UnmappedDomainError` (§4.7.6) when a coupling references a variable whose domain has no mapping rule;
- `UnsupportedMappingError` when a `dimension_mapping` type that the Core tier does not implement (`slice`, `project`, `regrid`, or a spatial operator) is encountered;
- `DomainUnitMismatchError` (§4.7.6) when a coupling across an `Interface` requires an undeclared unit conversion;
- `DomainExtentMismatchError` when an `identity` mapping is asked to bridge domains with incompatible extents;
- `SliceOutOfDomainError` when a `slice` mapping reaches outside the source variable's domain;
- `CyclicPromotionError` when promotion rules form a cycle.

`simulate()` additionally raises `UnsupportedDimensionalityError` (§5.4.6) when given a flattened system whose `independent_variables` is not exactly `["t"]`. All names match the Rust `FlattenError` enum variants and Rust `CompileError::UnsupportedDimensionalityError` so cross-language validators can interoperate.

**Event handling in SciPy:**

| ESM event type | SciPy mechanism |
|---|---|
| Continuous event | `solve_ivp` `events` parameter (zero-crossing functions) |
| Discrete (condition) | Manual stepping with condition check |
| Discrete (periodic) | Manual stepping at fixed intervals |
| Discrete (preset_times) | Use `t_eval` combined with manual affect application |

Since SciPy's event handling is less sophisticated than DifferentialEquations.jl, the Python simulation tier has limitations:

- Direction-dependent affects (`affect_neg`) require custom zero-crossing direction detection.
- Discrete events with complex triggers require manual integration loop management.
- Functional affects are not supported (they are runtime-specific).
- An *undiscretized* spatial operator (`grad`, `div`, `laplacian`) causes `simulate()` to raise `UnsupportedDimensionalityError`: it must first be rewritten to an `arrayop` stencil by a discretization template (`expression_templates` / `apply_expression_template`), which the Python binding applies at load time like every other binding. Once discretized, `simulate()` integrates the PDE natively — Python is one of the three PDE-simulation bindings (§5.9), not a 0D-only box-model solver.

#### 5.3.6 Jupyter Integration

```python
# In Jupyter, ESM objects have rich _repr_latex_ methods
file.models["SuperFast"]  # renders equations as LaTeX

# Interactive model explorer
esm.explore(file)  # widget showing models, reactions, coupling graph
```

---

### 5.4 Rust — `earthsci-ast`

**Tier: Core + Analysis**

Rust provides a high-performance, memory-safe implementation suitable for CLI tools, WASM compilation (for web), and embedding in other systems.

**Flattening scope (Core tier only).** The Rust implementation of `flatten()` targets the Core dimension-promotion tier: it supports `broadcast` and `identity` mappings per §4.7.6, and raises `FlattenError::UnsupportedMapping` with the specific type name (`slice`, `project`, `regrid`, or the spatial operator that was encountered — `grad`, `div`, `laplacian`, `D(_, x)`, etc.) for anything beyond that. This scope limit is a flatten-tier decision, not a simulation limit: the Rust array simulator does run discretized PDEs (`arrayop` systems — see §5.9 cross-language PDE-simulation conformance). The `slice`/`project`/`regrid` dimension-mapping rewrites are simply not yet implemented in Rust `flatten()`. The full cross-language §4.7.6.10 error taxonomy (`ConflictingDerivative`, `DimensionPromotion`, `UnmappedDomain`, `UnsupportedMapping`, `DomainUnitMismatch`, `DomainExtent`, `SliceOutOfDomain`, `CyclicPromotion`) is defined on the Rust `FlattenError` enum for API parity even where a given variant is never raised by Core tier.

#### 5.4.1 Dependencies

- `serde` + `serde_json` — serialization
- `jsonschema` — schema validation
- `wasm-bindgen` — optional, for WASM target
- `diffsol` (0.11) — native-only ODE solver, used by `simulate()` (gated to non-wasm targets via `cfg(not(target_arch = "wasm32"))`); pulls in `faer` for the linear-algebra backend used at the call site

#### 5.4.2 Crate Structure

```
esm-format/
├── src/
│   ├── lib.rs
│   ├── types.rs        # Struct definitions with serde derives
│   ├── expression.rs   # Expr enum, pretty-print, substitution
│   ├── validate.rs     # Schema + structural validation
│   ├── units.rs        # Unit parsing and checking
│   ├── reactions.rs    # Stoichiometric matrix
│   ├── edit.rs         # Editing operations
│   └── display.rs      # Unicode/LaTeX formatters
├── Cargo.toml
└── tests/
```

#### 5.4.3 Key Design Decisions

**Expression type as an enum:**

```rust
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(untagged)]
pub enum Expr {
    Num(f64),
    Var(String),
    Node(ExprNode),
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ExprNode {
    pub op: String,
    pub args: Vec<Expr>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub wrt: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub dim: Option<String>,
}
```

**Coupling as a tagged enum:**

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum CouplingEntry {
    #[serde(rename = "operator_compose")]
    OperatorCompose { systems: [String; 2], translate: Option<HashMap<String, TranslateTarget>>, description: Option<String> },
    #[serde(rename = "variable_map")]
    VariableMap { from: String, to: String, transform: String, description: Option<String> },
    // ... etc
}
```

#### 5.4.4 WASM Target

The Rust library can be compiled to WASM and used by the TypeScript library for performance-critical operations (validation, large expression manipulation). The TypeScript library would use the pure-TS implementation by default but optionally delegate to WASM:

```typescript
import { validate } from '@earthsciml/ast';
import { validate as validateWasm } from 'esm-format-wasm'; // optional fast path
```

#### 5.4.5 CLI Tool

The Rust crate should also produce a CLI binary:

```bash
# Validate an ESM file
esm validate model.esm

# Pretty-print
esm display model.esm
esm display model.esm --format=latex

# Extract a single model
esm extract model.esm --component=SuperFast > superfast.esm

# Diff two ESM files (semantic diff)
esm diff model_v1.esm model_v2.esm

# Generate stoichiometric matrix
esm stoich model.esm --system=SimpleOzone

# System graph (component-level)
esm graph model.esm                          # DOT format to stdout
esm graph model.esm --format=mermaid         # Mermaid format
esm graph model.esm --format=json            # JSON adjacency list
esm graph model.esm | dot -Tsvg > graph.svg  # pipe to Graphviz

# Expression graph (variable-level)
esm graph model.esm --level=expression                           # all systems merged
esm graph model.esm --level=expression --system=SimpleOzone      # single system
esm graph model.esm --level=expression --format=mermaid

# Convert between formats
esm convert model.esm --to=messagepack  # future binary format
```

#### 5.4.6 Native Simulation (`simulate()`, gt-5ws)

The Rust crate exposes a native, correctness-first simulator: a `diffsol`-backed ODE integrator plus a vectorized array-op runtime that integrates discretized PDEs. v1 is intentionally limited in these ways:

- **Time-integration domain.** The simulator consumes a `FlattenedSystem` whose `independent_variables` is exactly `["t"]` — which *includes* discretized PDEs, whose spatial axis is folded into `arrayop` dimensions and integrated natively by the array-op runtime (see §5.9). A system that still carries a spatial independent variable holds an *undiscretized* spatial operator and returns `CompileError::UnsupportedDimensionalityError`; discretize it first (apply the `expression_templates` stencil rewrite).
- **No event handling.** Models with non-empty `continuous_events` or `discrete_events` return `CompileError::UnsupportedFeatureError` and are routed to the future Rust events bead.
- **No coupling beyond Core flatten.** Anything `flatten()` itself rejects (`slice` / `project` / `regrid`, *undiscretized* spatial operators, mismatched dimension mappings) is rejected upstream and never reaches the simulator.
- **Native only.** The whole `simulate` module is gated behind `cfg(not(target_arch = "wasm32"))`, so the WASM build (which has a separate follow-up bead for simulator exposure) does not pull in `diffsol`.
- **Compiled API for parameter sweeps.** A `Compiled` value is built once via `Compiled::from_flattened` / `from_model` / `from_file` and then reused across many `Compiled::simulate(...)` calls with different `params` and `initial_conditions` HashMaps. A one-shot `simulate(file, tspan, params, ic, opts)` convenience wrapper exists for the common single-run case.
- **Solver options.** `SimulateOptions` selects between `SolverChoice::Bdf` (default — implicit BDF, the canonical stiff solver), `SolverChoice::Sdirk` (TR-BDF2 SDIRK), and `SolverChoice::Erk` (explicit Tsitouras 5(4) for non-stiff problems), plus tolerances (`abstol` / `reltol`), `max_steps`, and an optional dense `output_times` grid.
- **Interpreted RHS, finite-difference Jacobian.** The interpreter walks an internal `ResolvedExpr` tree (variable references resolved to typed indices into the state, parameter, observed, and `t` slots). The Jacobian-vector product handed to diffsol is forward-difference; v1 deliberately does not generate symbolic or compiled-WASM Jacobians, since the bead is correctness-focused.

```rust
use earthsci_ast::{Compiled, SimulateOptions, SolverChoice, simulate};
use std::collections::HashMap;

let compiled = Compiled::from_file(&file)?;
let mut params = HashMap::new();
params.insert("Decay.k".to_string(), 0.1);
let mut ic = HashMap::new();
ic.insert("Decay.N".to_string(), 1.0);
let opts = SimulateOptions {
    solver: SolverChoice::Bdf,
    abstol: 1e-10,
    reltol: 1e-8,
    max_steps: 10_000,
    output_times: Some(vec![0.0, 1.0, 10.0, 100.0]),
};
let solution = compiled.simulate((0.0, 100.0), &params, &ic, &opts)?;
```

The v1 acceptance harness includes the Robertson stiff problem (verified against Hairer & Wanner Table 1.4 reference values), an exponential-decay analytical comparison, mass-conservation invariants for autocatalysis, and round-trips from the canonical `tests/simulation/*.esm` fixtures. WASM exposure, event handling, hybrid PDE coupling, symbolic Jacobians, and sensitivity analysis are all explicit follow-up beads.

---

### 5.5 Go — `earthsci-ast-go` (Optional)

**Tier: Core**

Go is useful for server-side tooling, CI/CD validation, and API backends.

#### 5.5.1 Minimal Scope

- Parse/serialize ESM files using standard `encoding/json`.
- Schema validation via `gojsonschema`.
- Pretty-print to Unicode and LaTeX.
- Structural validation (equation counting, reference checks).
- Substitution.

No simulation capability. The Go library serves as a validation and transformation layer in backend services.

---

## 6. Display Format Specification

All libraries must produce identical output for a given display format when given the same input. This section specifies the exact rendering rules.

### 6.1 Unicode Display

**Chemical species subscripts:** Digits following chemical element symbols become subscripts. Libraries must use an **element-aware tokenizer** that recognizes chemical element symbols (one uppercase letter optionally followed by one lowercase letter, matching entries in the periodic table) and subscripts trailing digits.

**Algorithm:**

1. Split the name on underscores into segments (e.g., `k_NO_O3` → `["k", "NO", "O3"]`).
2. For each segment, scan left-to-right matching the pattern `[A-Z][a-z]?` against a lookup table of chemical element symbols (H, He, Li, Be, B, C, N, O, F, Ne, Na, Mg, Al, Si, P, S, Cl, Ar, K, Ca, …all 118 elements).
3. If a match is found and is immediately followed by one or more digits, convert those digits to Unicode subscript characters (₀₁₂₃₄₅₆₇₈₉).
4. If a segment does not start with a recognized element symbol, leave it unchanged (e.g., `k` → `k`, `var2` → `var2`).
5. Rejoin segments with underscores (for Unicode) or `\_` (for LaTeX).

| Input | Output | Reasoning |
|---|---|---|
| `O3` | `O₃` | `O` is oxygen, `3` subscripted |
| `NO2` | `NO₂` | `N` is nitrogen, `O` is oxygen, `2` follows `O` |
| `CH2O` | `CH₂O` | `C` is carbon, `H` is hydrogen, `2` follows `H`, `O` is oxygen |
| `H2O2` | `H₂O₂` | Both digit groups follow element symbols |
| `k_NO_O3` | `k_NO_O₃` | `k` is not an element, `N`/`O` are elements, `3` follows `O` |
| `var2` | `var2` | `V` could be vanadium but `va` is not followed by a digit after an element match; `var` doesn't start with a valid element+digit pattern |
| `T` | `T` | No trailing digits |
| `jNO2` | `jNO₂` | `j` is not an element, skip; `N` is nitrogen, `O` is oxygen, `2` follows `O` |

**Note:** The element lookup table must be included in each library (a static list of 118 symbol strings). The algorithm is greedy — it tries to match two-character element symbols before one-character symbols (e.g., `Ca` matches calcium before `C` matches carbon).

**Number formatting:** Numbers in Unicode display use the following rules:

| Condition | Format | Example |
|---|---|---|
| Integer (no fractional part) | Plain integer | `3`, `−1`, `1000` |
| Decimal, 1–4 significant digits | Decimal notation | `0.005`, `298.15` |
| \|value\| < 0.01 or \|value\| ≥ 10000 | Scientific notation with Unicode superscripts | `1.8×10⁻¹²`, `2.46×10¹⁹` |
| Exactly 0.0 | `0` | `0` |

For LaTeX, use `\times 10^{...}` for scientific notation. For ASCII, use `e` notation (e.g., `1.8e-12`).

**Operators:**

| AST | Unicode |
|---|---|
| `D(x, t)` | `∂x/∂t` |
| `grad(x, y)` | `∂x/∂y` |
| `a * b` | `a·b` |
| `-a` (unary) | `−a` (minus sign, not hyphen) |
| `a + (-b)` | `a − b` |
| `Pre(x)` | `Pre(x)` |

**Precedence rules** (highest to lowest):

1. Function application: `f(x)`
2. Exponentiation: `x^n` → `xⁿ` (for small integer exponents) or `x^(expr)`
3. Unary minus: `−x`
4. Multiplication/Division: `a·b`, `a/b`
5. Addition/Subtraction: `a + b`, `a − b`

Parentheses are only added when necessary for disambiguation.

### 6.2 LaTeX Display

Follow standard LaTeX math conventions. Fractions use `\frac{}{}`, derivatives use `\frac{\partial}{\partial t}`, species names use `\mathrm{}`.

### 6.3 Model Summary Display

When displaying a full model or file, show a structured summary:

```
ESM v0.1.0: MinimalChemAdvection
  "O3-NO-NO2 chemistry with advection and external meteorology"
  Authors: Chris Tessum

  Reaction Systems:
    SimpleOzone (3 species, 3 parameters, 2 reactions)
      R1: NO + O₃ → NO₂    rate: 1.8×10⁻¹² · exp(−1370/T) · M
      R2: NO₂ → NO + O₃    rate: jNO₂

  Models:
    Advection (2 parameters, 1 equation)
      ∂_var/∂t = −u_wind·∂_var/∂x − v_wind·∂_var/∂y

  Data Loaders:
    GEOSFP: u, v, T (gridded_data)

  Coupling:
    1. operator_compose: SimpleOzone + Advection
    2. variable_map: GEOSFP.T → SimpleOzone.T
    3. variable_map: GEOSFP.u → Advection.u_wind
    4. variable_map: GEOSFP.v → Advection.v_wind

  Domain: lon [−130, −100] (Δ0.3125°), 2024-05-01 to 2024-05-03
```

---

## 7. Testing Requirements

### 7.1 Conformance Test Suite

A language-independent test suite ensures all libraries produce consistent results. The test suite is a collection of `.esm` files paired with expected outputs:

```
tests/
├── valid/
│   ├── minimal_chemistry.esm          # minimal valid file
│   ├── full_coupled.esm               # exercises all sections
│   ├── events_all_types.esm           # all event variants
│   ├── reaction_system_only.esm       # no models section
│   └── model_only.esm                 # no reaction_systems section
├── invalid/
│   ├── missing_esm_version.esm        # schema error
│   ├── unknown_variable_ref.esm       # structural error
│   ├── equation_count_mismatch.esm    # more states than equations
│   ├── invalid_trigger_type.esm       # bad discrete event trigger
│   └── circular_coupling.esm          # coupling references nonexistent system
├── display/
│   ├── expr_precedence.json           # expression → expected Unicode/LaTeX
│   ├── chemical_subscripts.json       # species name → expected display
│   └── model_summary.json            # file → expected summary string
├── substitution/
│   ├── simple_var_replace.json        # input expr + bindings → expected output
│   ├── nested_substitution.json
│   └── scoped_reference.json
├── graphs/
│   ├── system_graph.json              # file → expected nodes + edges (component level)
│   ├── expression_graph.json          # file → expected nodes + edges (variable level)
│   ├── coupled_expression_graph.json  # file with coupling → merged variable graph
│   └── expected_dot/                  # expected DOT output for each test case
│       ├── system_graph.dot
│       └── expression_graph.dot
└── simulation/
    ├── box_model_ozone.esm            # simple ODE, expected trajectory
    ├── bouncing_ball.esm              # continuous events
    └── expected/
        ├── box_model_ozone.csv        # t, O3, NO, NO2 columns
        └── bouncing_ball.csv
```

### 7.2 Test Fixture Authoring

The conformance test suite must be authored as a standalone, language-independent artifact stored in the `EarthSciAST` repository alongside the schema and specs. Test fixtures are **not** generated from any single library implementation — they are the canonical source of truth.

**Minimum fixture set for Phase 1 (required before cross-language conformance testing):**

1. **`valid/minimal_chemistry.esm`** — The `MinimalChemAdvection` example from the format spec (Section 13). This is the baseline test: every library must parse, validate, pretty-print, and round-trip this file identically.
2. **`valid/events_all_types.esm`** — A file exercising continuous events (with `affect_neg`, `root_find`), discrete events (condition, periodic, preset_times), discrete parameters, and a functional affect.
3. **`invalid/missing_esm_version.esm`** and **`invalid/unknown_variable_ref.esm`** — Minimal files that fail schema and structural validation respectively, with expected error codes documented in a companion `expected_errors.json`.
4. **`display/expr_precedence.json`** — Array of `{input: Expression, unicode: string, latex: string}` triples covering: operator precedence (nested `+`/`*`/`^`), chemical subscripts, derivatives, Pre operator, scientific notation numbers.
5. **`substitution/simple_var_replace.json`** — Array of `{input: Expression, bindings: object, expected: Expression}` triples.

Each expected output must be reviewed and agreed upon before being committed, since it defines the conformance standard.

### 7.3 Round-Trip Tests

For every valid `.esm` file: `load(save(load(file))) == load(file)`. JSON key ordering and whitespace may differ, but the parsed data model must be identical.

### 7.4 Cross-Language Tests

Periodically, the CI runs the same test suite across Julia, TypeScript, Python, and Rust and compares outputs. Failures indicate divergence in rendering or validation logic.

### 7.5 End-to-End Simulation Tests

Libraries that produce simulation-ready system objects (see Section 2.4) must include integration tests that invoke a real solver on the produced system and assert numerical correctness of the integrated trajectory. Construction-only tests are insufficient — the solver is the only reliable check that system objects are actually simulation-ready. The solver is a test dependency, not a runtime dependency. See Section 2.4.2 for the full requirement, including PDE test discretization minimums.

---

## 8. Versioning and Compatibility

### 8.1 Schema Version

The `"esm"` field in each file specifies the schema version. Libraries must:

- Reject files with a major version they don't support.
- Accept files with a minor version ≤ their supported minor version (backward compatible).
- Warn on files with a higher minor version (forward compatible — unknown fields ignored). Since the JSON Schema uses `additionalProperties: false` for strict validation at a specific version, libraries must **skip JSON Schema validation** for files whose minor version exceeds the library's supported version and rely on structural validation only.

### 8.2 Library Versions

Libraries follow semver independently of the schema version. Each library's documentation specifies which schema versions it supports.

### 8.3 Migration

When the schema version changes, each library should provide a migration function:

```
migrate(file: EsmFile, target_version: string) → EsmFile
```

---

## 9. Implementation Priority

### Phase 1: Foundation (All Languages)

1. Type definitions / data model.
2. JSON parse / serialize with schema validation.
3. Expression pretty-printing (Unicode + LaTeX).
4. Expression substitution.
5. Structural validation (equation counting, reference integrity).
6. Round-trip tests passing.

### Phase 2: Analysis

7. Unit parsing and dimensional checking.
8. `derive_odes` from reaction systems.
9. `stoichiometric_matrix` computation.
10. System graph (component-level) and expression graph (variable-level).
11. Graph export (DOT, Mermaid, JSON).
12. Model editing operations.
13. Conformance test suite passing across all languages.

### Phase 3: Simulation

14. Julia: MTK/Catalyst bidirectional conversion.
15. Julia: coupled system assembly.
16. Python: SymPy expression conversion.
17. Python: SciPy-backed box model simulation.
18. Python: event handling in simulation.

### Phase 4: Ecosystem

19. Rust: WASM compilation for web use.
20. Rust: CLI tool.
21. `@earthsciml/ast`: Julia and Python code generation.
22. `earthsci-ast-editor`: `ExpressionNode` component with click-to-select, hover highlight, CSS math layout.
23. `earthsci-ast-editor`: Inline editing (double-click numbers/variables), autocomplete.
24. `earthsci-ast-editor`: Structural editing (wrap/unwrap/delete/drag-reorder).
25. `earthsci-ast-editor`: Expression palette sidebar.
26. `earthsci-ast-editor`: `ModelEditor`, `ReactionEditor` composed components.
27. `earthsci-ast-editor`: `CouplingGraph` visualization.
28. `earthsci-ast-editor`: `ValidationPanel` with error-to-node linking.
29. `earthsci-ast-editor`: Undo/redo history.
30. `earthsci-ast-editor`: Web component export via `solid-element`.
31. Julia: full EarthSciML integration (data loaders, operators, spatial simulation).

---

## 10. Outstanding Issues

The following items are acknowledged gaps in this specification. They do not block Phase 1 or Phase 2 implementation and will be addressed in subsequent revisions.

| Issue | Affected area | Notes |
|---|---|---|
| `derive_odes` algorithm not fully specified | Section 4.6 | Standard mass-action kinetics ODE generation from stoichiometry + rate laws. Need to specify handling of source reactions (null substrates), sink reactions (null products), and constraint equations. |
| Stoichiometric matrix convention not stated | Section 4.6 | Must specify: species × reactions (rows × columns), net stoichiometry (products − substrates). |
| Expression graph edge rules for reactions are ambiguous | Section 4.8.2 | The rule for which nodes get edges (self-loops, rate parameter edges) needs a precise algorithm, not just an example. |
| Unit string parsing grammar undefined | Section 3.3 | Unit strings are free-form. A formal grammar or recognized-token list (including `molec`, `ppb`, `ppm`) would improve cross-language consistency. |
| Python simulation with spatial operators | Section 5.3.5 | Coupling resolution with `operator_compose` involving spatial derivatives (grad, laplacian) is not meaningful for 0D simulation. The spec should clarify that Python simulation skips spatial terms or raises an error. |
| Code generation templates underspecified | Section 5.2.8 | Exact rules for emitting parameter defaults, unit strings (Julia `u"..."`, Python `pint`), and boilerplate structure need more detail. |
| `earthsci-ast-editor` CSS theming / dark mode | Section 5.2.4 | No specification for CSS custom properties or theme customization. |
| Concurrency / thread safety | All libraries | Not addressed. Relevant for Julia (multi-threaded solvers) and Rust (Send/Sync bounds). |

---

## 11. Summary Table

| Capability | Julia | TS `@earthsciml/ast` | Solid `earthsci-ast-editor` | Python | Rust | Go |
|---|---|---|---|---|---|---|
| Parse / serialize | ✓ | ✓ | — | ✓ | ✓ | ✓ |
| Schema validation | ✓ | ✓ | — | ✓ | ✓ | ✓ |
| Unicode pretty-print | ✓ | ✓ (string) | ✓ (DOM) | ✓ | ✓ | ✓ |
| LaTeX pretty-print | ✓ | ✓ (string) | — | ✓ | ✓ | ✓ |
| Substitution | ✓ | ✓ | ✓ (interactive) | ✓ | ✓ | ✓ |
| Structural validation | ✓ | ✓ | — | ✓ | ✓ | ✓ |
| Unit validation | ✓ | ✓ | — | ✓ | ✓ | — |
| Derive ODEs from reactions | ✓ | ✓ | — | ✓ | ✓ | — |
| Stoichiometric matrix | ✓ | ✓ | — | ✓ | ✓ | — |
| System graph (component) | ✓ | ✓ | ✓ (visual) | ✓ | ✓ | ✓ |
| Expression graph (variable) | ✓ | ✓ | ✓ (visual) | ✓ | ✓ | ✓ |
| Graph export (DOT/Mermaid) | ✓ | ✓ | — | ✓ | ✓ | ✓ |
| Model editing (programmatic) | ✓ | ✓ | — | ✓ | ✓ | — |
| Click-to-edit expressions | — | — | ✓ | — | — | — |
| Drag-and-drop reordering | — | — | ✓ | — | — | — |
| Expression palette | — | — | ✓ | — | — | — |
| Undo/redo | — | — | ✓ | — | — | — |
| Coupling graph visualization | — | — | ✓ | — | — | — |
| Live validation panel | — | — | ✓ | — | — | — |
| Web component export | — | — | ✓ | — | — | — |
| MTK ↔ ESM conversion | ✓ | — | — | — | — | — |
| Catalyst ↔ ESM conversion | ✓ | — | — | — | — | — |
| Coupled system assembly | ✓ | — | — | — | — | — |
| 0D simulation (box model) | ✓ | — | — | ✓ | 0D stiff ODEs (diffsol backend; events and coupling deferred) | — |
| Spatial (discretized-PDE) simulation | ✓ | — | — | ✓ | ✓ (arrayop runtime; §5.9) | — |
| Event simulation | ✓ | — | — | partial | — | — |
| WASM target | — | — | — | — | ✓ | — |
| CLI tool | — | — | — | — | ✓ | — |
| Julia code generation | — | ✓ | — | — | — | — |
| Python code generation | — | ✓ | — | — | — | — |
| Jupyter integration | — | — | — | ✓ | — | — |

**Note.** Libraries marked with a ✓ for any simulation capability row (0D simulation, Spatial simulation, Event simulation) are considered **simulation-capable** and must include end-to-end simulation tests per Section 2.4.2 — the test suite must invoke a real solver on the library's produced system object and assert numerical correctness, not merely that the object was constructed. Solvers used for these tests are test-only dependencies; libraries MUST NOT embed a solver as a runtime dependency (Section 2.4).
