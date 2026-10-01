# Agent Instructions

## Simulation runner pathway (ABSOLUTE)

EarthSciAST hosts the rule engine and the simulation runners that consume it.
There is **one and only one** pathway from a model artifact to a numerical
result. Every contributor — and every AI agent — must use it.

### The single pathway

```
.esm JSON → parse → AST (canonical form)
         → AST transforms (canonicalize, flatten, discretize, substitute, …)
         → official simulation runner (consumes AST directly, no shortcuts)
```

No step is allowed to bypass the AST. The runner does not receive a
pre-numericised, pre-tabulated, or imperatively rewritten form of the
rules; it walks the same canonical AST that the rule engine produced.

### Official simulation runners

A binding **may** ship more than one official runner. Each must satisfy
all four invariants below:

1. **AST-pure.** Walks the canonical AST directly. No imperative shortcut,
   no materialised rule output that bypasses the AST.
2. **No per-rule-shape dispatch.** No `if rule.kind == flux_1d_ppm then …`
   branches at the runner layer. All rule-shape handling happens in
   `discretize` (production), upstream of the runner.
3. **Documented use case.** Docs state when to choose this runner over the
   alternatives (system size, performance, feature support).
4. **Public API.** Invokable by users — not just by test infrastructure.

Current Julia runners:

### Official per-binding runners (cross-language)

Each binding has its own official runner(s) consuming the same canonical AST:

| Binding    | Official runner(s)                                                                        | File(s) |
|------------|-------------------------------------------------------------------------------------------|---------|
| Julia      | ModelingToolkit; `tree_walk.jl`                                                           | `pkg/EarthSciAST.jl/src/mtk_export.jl`, `tree_walk.jl` |
| Python     | `numpy_interpreter` (AST evaluator); `simulation.simulate()` (SciPy backend)              | `pkg/earthsci-ast-py/src/earthsci_ast/numpy_interpreter.py`, `simulation.py` |
| Rust       | `simulate` (diffsol scalar ODE); `simulate_array` (ndarray array-op runtime)              | `pkg/earthsci-ast-rs/src/simulate.rs`, `simulate_array.rs` |
| TypeScript | `codegen` (canonical-AST → JS lowering)                                                   | `pkg/earthsci-ast-ts/src/codegen.ts` |
| Go         | (none — `earthsci-ast-go` is parse + validate only by design)                               | — |


## What the Format Supports

A document is a single JSON object. Two keys are required — `esm` (the format
version) and `metadata` — and everything else is optional, so the smallest
valid file declares nothing but its own identity.

**Components** — the things that carry equations:

- **`models`** — components with variables and equations. A variable is declared
  `unknown` or `parameter`; whether an unknown is an ODE state or an observed is
  *derived* from the equation that defines it, not declared.
- **`reaction_systems`** — chemical networks of species and reactions, lowerable
  to ODEs.

**Composition:**

- **`coupling`** — rules for composing components: variable maps, additive and
  multiplicative couplings, operator apply/compose, and events.
- **`coupling_roles`** — formal component roles, for a coupling-library file.
- **`expression_templates`** / **`expression_template_imports`** — `match`
  rewrite rules and the imports that bring in a template library. This is how
  spatial discretization is expressed: continuous operators such as `grad`,
  `div`, and `laplacian` are rewritten into explicit stencils.

**Data and shape:**

- **`data_sources`** — ingest configuration for external data. A data source is
  not a component: it has no variables and is not a coupling endpoint; external
  data reaches a model as a parameter whose `update` draws from it.
- **`index_sets`** — named index sets that array dimensions range over.
- **`coordinates`** — coordinate variables for output.
- **`function_tables`** — sampled function tables with named axes.
- **`enums`** — file-local symbol-to-integer mappings for categorical lookups.
- **`metaparameters`** — values bound at load, so one document serves many
  resolutions.
- **`domain`** — the single temporal domain shared by the document. Spatiality
  comes from variable *shape*, not from a per-component domain.

**Expressions** are built from operators in two tiers. The **evaluable core is
closed** — arithmetic, comparison, logical, elementary functions, constants,
`D`/`ic`, conditionals, array construction and indexing, aggregation, closed
function calls, geometry, and value invention — and every binding implements all
of it. That is deliberate: a conforming reader in any language can evaluate any
document without executing author-supplied code. The second tier is
**rewrite-target** ops (`grad`, `div`, `laplacian`, a spatial `D`, or an op you
invent); these have no evaluator and must be lowered by a template rewrite
before a document can run.

### Example

```json
{
  "esm": "1.0.0",
  "metadata": {
    "name": "SimpleDecay",
    "description": "Exponential decay with a known analytical solution",
    "authors": ["Chris Tessum"]
  },
  "models": {
    "ExponentialDecay": {
      "variables": {
        "N": {
          "type": "unknown",
          "units": "mol",
          "default": 100.0,
          "description": "Amount of decaying species"
        },
        "lambda": {
          "type": "parameter",
          "units": "1/s",
          "default": 0.1,
          "description": "Decay constant"
        }
      },
      "equations": [
        {
          "lhs": { "op": "D", "args": ["N"], "wrt": "t" },
          "rhs": {
            "op": "*",
            "args": [{ "op": "-", "args": ["lambda"] }, "N"]
          }
        }
      ]
    }
  }
}
```

Note the shapes that trip people up: `variables` is an **object keyed by name**,
not an array; the differentiated variable is in `args` with the independent
variable in **`wrt`**; and an initial value is the variable's `default`.

## Documentation

- **[Format Specification](esm-spec.md)** — Complete ESM format documentation
- **[Library Specification](esm-libraries-spec.md)** — Requirements for ESM library implementations
- **[Schema Reference](esm-schema.json)** — Authoritative JSON schema
- **[Conformance Spec](CONFORMANCE_SPEC.md)** — Fixture format, execution protocol, CI integration, and run commands
- **[Validation Matrix](ESM_COMPLIANCE_VALIDATION_MATRIX.md)** — Reference taxonomy of testable requirements

## Contributing

We welcome contributions! This project uses:

- **Cross-language conformance tests** to ensure implementation consistency

### Testing the Conformance Infrastructure



### Prohibitions (ABSOLUTE)

- **No new test-only evaluators.** If a test wants to compare numerical
  output against a reference, it runs the official pathway above. Tests do
  not get their own parallel evaluator.
- **No new doc-only / example-only evaluators.** Examples consume the same
  pathway users would.
- **No imperative shortcut paths inside a runner.** A runner that special-
  cases a rule shape, flattens an AST node into a hand-rolled numeric
  kernel, or short-circuits the AST walk for "speed" violates invariant
  #1 and must be fixed or rejected.
- **No per-rule-shape dispatch at the runner layer.** Rule-shape handling
  belongs in `discretize`. If a rule shape doesn't materialize correctly
  through the production pipeline, the bug is in the production pipeline.
