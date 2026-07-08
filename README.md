# EarthSciAST

[![Cross-Language Conformance Testing](https://github.com/EarthSciML/EarthSciAST/actions/workflows/conformance-testing.yml/badge.svg)](https://github.com/EarthSciML/EarthSciAST/actions/workflows/conformance-testing.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**EarthSciML Serialization Format** — A language-agnostic JSON-based format for earth science model components, their composition, and runtime configuration.

## Overview

The ESM (`.esm`) format enables persistence, interchange, and version control for earth science models across multiple programming languages. Every model is fully self-describing: all equations, variables, parameters, species, and reactions are specified in the format itself, allowing conforming parsers in any language to reconstruct the complete mathematical system.

The format is language-agnostic (Julia, TypeScript, Python, Rust, Go), human-readable JSON, composable, validated, and supports rich mathematical expressions. See the [format specification](esm-spec.md) for details.

## Quick Start

### Loading an ESM Model

**Julia:**
```julia
using EarthSciAST
esm_file = load("model.esm")
println("Model has $(length(esm_file.models)) components")
```

**TypeScript/Node.js:**
```typescript
import { load, validate } from '@earthsciml/ast';
const esmFile = load('model.esm');
const result = validate(esmFile);
```

**Python:**
```python
import earthsci_ast
esm_file = earthsci_ast.load("model.esm")
print(f"Model has {len(esm_file.models)} components")
```

## Packages

This repository contains multiple language implementations of the ESM format:

| Package | Language | Description | Directory |
|---------|----------|-------------|-----------|
| **EarthSciAST.jl** | Julia | Complete MTK/Catalyst integration | [`pkg/EarthSciAST.jl/`](pkg/EarthSciAST.jl/) |
| **@earthsciml/ast** | TypeScript | Web/Node.js types and utilities | [`pkg/earthsci-ast-ts/`](pkg/earthsci-ast-ts/) |
| **earthsci_ast** | Python | Scientific Python integration | [`pkg/earthsci-ast-py/`](pkg/earthsci-ast-py/) |
| **earthsci-ast** | Rust | High-performance implementation | [`pkg/earthsci-ast-rs/`](pkg/earthsci-ast-rs/) |
| **earthsci-ast-go** | Go | Lightweight Go implementation | [`pkg/earthsci-ast-go/`](pkg/earthsci-ast-go/) |
| **earthsci-ast-editor** | SolidJS | Interactive web-based editor | [`pkg/earthsci-ast-editor/`](pkg/earthsci-ast-editor/) |

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
earthsci-ast = "0.1.0"
```

### Go
```bash
go get github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go
```

## Format Specification

The ESM format supports:

- **Models**: ODE-based model components with variables, parameters, and equations
- **Reaction Systems**: Chemical reaction networks with species and reactions
- **Coupling**: Rules for composing multiple model components
- **Domain**: Spatial and temporal domain specifications
- **Operators**: Registered mathematical operators and data loaders
- **Metadata**: Authorship, provenance, and documentation

### Example ESM File

```json
{
  "esm": "0.1.0",
  "metadata": {
    "name": "SimpleChemistry",
    "description": "Basic atmospheric chemistry model",
    "authors": ["Chris Tessum"]
  },
  "models": {
    "chemistry": {
      "variables": [
        {
          "name": "O3",
          "description": "Ozone concentration",
          "units": "molec/cm^3",
          "initial": 1e12
        }
      ],
      "equations": [
        {
          "lhs": {
            "op": "D",
            "args": ["O3", "t"]
          },
          "rhs": {
            "op": "-",
            "args": [
              {
                "op": "*",
                "args": ["k1", "O3"]
              }
            ]
          }
        }
      ]
    }
  }
}
```

## Documentation

- **[Format Specification](esm-spec.md)** — Complete ESM format documentation
- **[Library Specification](esm-libraries-spec.md)** — Requirements for ESM library implementations
- **[Schema Reference](esm-schema.json)** — Authoritative JSON schema
- **[Conformance Spec](CONFORMANCE_SPEC.md)** — Fixture format, execution protocol, CI integration, and run commands
- **[Validation Matrix](ESM_COMPLIANCE_VALIDATION_MATRIX.md)** — Reference taxonomy of testable requirements

## Contributing

We welcome contributions! This project uses:

- **[Beads](https://github.com/beadshq/beads)** for issue tracking and project management
- **Julia** testing with `julia --project=. -e 'using Pkg; Pkg.test()'`
- **Cross-language conformance tests** to ensure implementation consistency

### Testing the Conformance Infrastructure

```bash
# Run full conformance tests (requires working language implementations)
./scripts/test-conformance.sh
```

See individual package directories for language-specific development guides.

## License

This project is licensed under the [MIT License](LICENSE).

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