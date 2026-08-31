# EarthSciAST

[![Cross-Language Conformance Testing](https://github.com/EarthSciML/EarthSciAST/actions/workflows/conformance-testing.yml/badge.svg)](https://github.com/EarthSciML/EarthSciAST/actions/workflows/conformance-testing.yml)
[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](https://www.gnu.org/licenses/agpl-3.0)

**EarthSciML Abstract Syntax Tree Format** — A language-agnostic JSON-based format for earth science model components, their composition, and runtime configuration.

> [!NOTE]
> For the most part, this is a project that has been grown rather than built. As such, don't be surprised by occasional eccentricities!

## Overview

The ESM (`.esm`) format enables persistence, interchange, and version control for earth science models across multiple programming languages. Every model is fully self-describing: all equations, variables, parameters, species, and reactions are specified in the format itself, allowing conforming parsers in any language to reconstruct the complete mathematical system.

The format is language-agnostic (Julia, TypeScript, Python, Rust, Go), human-readable JSON, composable, validated, and supports rich mathematical expressions. See the [format specification](esm-spec.md) for details.

## Packages and Capabilities

Five language implementations. All five read and write the same
`esm-schema.json` and are held to a shared cross-language conformance suite, so
they agree on parsing, serialization, validation, canonical form, and display.
They differ in how far up the stack they go.

| Capability | Julia | TypeScript | Python | Rust | Go |
|---|:--:|:--:|:--:|:--:|:--:|
| **Core** — parse, serialize, validate, display, canonicalize, graph, edit, flatten | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Classification** — derived variable classification (esm-spec §6.3.1) | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Simulation** — build a right-hand side and integrate it | ✅ | — | ✅ | ✅ | — |
| **Runtime I/O** — data-source providers, refresh cadence, output sinks, checkpoints | ✅ | — | ✅ | ✅ | — |

TypeScript and Go are **deliberately non-simulating**: they exist to read,
check, transform, and display documents, not to run them.

| Package | Language | Directory | Notes |
|---|---|---|---|
| **EarthSciAST.jl** | Julia | [`pkg/EarthSciAST.jl/`](pkg/EarthSciAST.jl/) | Reference implementation; ModelingToolkit and Catalyst integration, tree-walk engine for discretized PDEs |
| **@earthsciml/ast** | TypeScript | [`pkg/earthsci-ast-ts/`](pkg/earthsci-ast-ts/) | Types and utilities for web and Node.js |
| **earthsci-ast** | Python | [`pkg/earthsci-ast-py/`](pkg/earthsci-ast-py/) | NumPy/SciPy/SymPy integration |
| **earthsci-ast** | Rust | [`pkg/earthsci-ast-rs/`](pkg/earthsci-ast-rs/) | High-performance implementation, plus the `esm` CLI and WASM bindings |
| **earthsci-ast-go** | Go | [`pkg/earthsci-ast-go/`](pkg/earthsci-ast-go/) | Lightweight reader/checker |

The exported surface of every binding is pinned in
[`api-surface.json`](api-surface.json) and tiered in [API_SPEC.md](API_SPEC.md);
each binding has a test that fails if its exports drift from the manifest.

## Installation

### Julia
```julia
using Pkg
Pkg.add("EarthSciAST")
```

### TypeScript/Node.js
```bash
npm install @earthsciml/ast
```

### Python
```bash
pip install earthsci-ast
```

### Rust
```toml
[dependencies]
earthsci-ast = "0.1.1"
```

### Go
```bash
go get github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go
```

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

> Earlier drafts had `operators`, `registered_functions`, `grids`,
> `staggering_rules`, and `discretizations` blocks. All five are **removed** —
> grid geometry is ordinary data, and discretization is a template rewrite.

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

```bash
# Run full conformance tests (requires working language implementations)
./scripts/test-conformance.sh
```

See individual package directories for language-specific development guides.

## License

This project is licensed under the [GNU Affero General Public License v3.0](LICENSE).

## Citation

If you use EarthSciAST in your research, please cite:

```bibtex
@software{earthsciserialization,
  title = {EarthSciAST: Language-agnostic serialization for earth science models},
  author = {Chris Tessum and contributors},
  year = {2026},
  url = {https://github.com/EarthSciML/EarthSciAST}
}
```
