# EarthSciAST

## Overview

**EarthSciAST** is short for "Earth Science Abstract Syntax Tree". This repository contains a specification of an AST suitable for use in Earth science or geoscience modeling, utilities to read, write, and manipulate the AST, and utilities for compiling the AST into a runnable simulation.

These utilities have overlapping implementations in multiple languages:

| Package | Language | Directory |
|---|---|---|
| **EarthSciAST.jl** | Julia | [`pkg/EarthSciAST.jl/`](pkg/EarthSciAST.jl/) 
| **@earthsciml/ast** | TypeScript | [`pkg/earthsci-ast-ts/`](pkg/earthsci-ast-ts/) 
| **earthsci-ast** | Python | [`pkg/earthsci-ast-py/`](pkg/earthsci-ast-py/) 
| **earthsci-ast** | Rust | [`pkg/earthsci-ast-rs/`](pkg/earthsci-ast-rs/) 
| **earthsci-ast-go** | Go | [`pkg/earthsci-ast-go/`](pkg/earthsci-ast-go/)


| Capability | Julia | TypeScript | Python | Rust | Go |
|---|:--:|:--:|:--:|:--:|:--:|
| **Core** — parse, serialize, validate, display, canonicalize, graph, edit, flatten | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Classification** — derived variable classification | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Simulation** — run a simulation | ✅ | — | ✅ | ✅ | — |
| **Runtime I/O** — data-source providers, refresh cadence, output sinks, checkpoints | ✅ | — | ✅ | ✅ | — |
| **Hardware Acceleration** – run on GPUs (experimental) | ✅ | — | - | ✅ | — |

> [!NOTE]
> For the most part, this is a project that has been grown rather than built. As such, don't be surprised by occasional eccentricities!

## Format

Models are primarily and canonically specified in files with the extension `.esm`, using a subset of the [JSON](https://www.json.org/json-en.html) format. 
However, it isn't necessarily expected that humans should be reading and writing the .esm files directly.
Instead, you can write something like:

```
D(x)/Dt = sigma * (y - x)
D(y)/Dt = x * (rho - z) - y
D(z)/Dt = x * y - beta * z
```

and then the software utilities above can turn that into an esm file that looks like:

```json
{
  "esm": "1.0.0",
  "metadata": {
    "name": "lorenz",
    "description": "",
    "tags": [],
    "authors": [],
    "created": "2026-09-25T21:45:27.403Z"
  },
  "models": {
    "lorenz": {
      "variables": {
        "x": {
          "type": "unknown",
          "units": "",
          "default": 1,
          "description": ""
        },
        "y": {
          "type": "unknown",
          "units": "",
          "default": 0,
          "description": ""
        },
        "z": {
          "type": "unknown",
          "units": "",
          "default": 0,
          "description": ""
        },
        "sigma": {
          "type": "parameter",
          "units": "",
          "default": 10,
          "description": ""
        },
        "rho": {
          "type": "parameter",
          "units": "",
          "default": 28,
          "description": ""
        },
        "beta": {
          "type": "parameter",
          "units": "",
          "default": 2.666666667,
          "description": ""
        }
      },
      "equations": [
        {
          "lhs": {
            "op": "D",
            "wrt": "t",
            "args": [
              "x"
            ]
          },
          "rhs": {
            "op": "*",
            "args": [
              "sigma",
              {
                "op": "-",
                "args": [
                  "y",
                  "x"
                ]
              }
            ]
          }
        },
        {
          "lhs": {
            "op": "D",
            "wrt": "t",
            "args": [
              "y"
            ]
          },
          "rhs": {
            "op": "-",
            "args": [
              {
                "op": "*",
                "args": [
                  "x",
                  {
                    "op": "-",
                    "args": [
                      "rho",
                      "z"
                    ]
                  }
                ]
              },
              "y"
            ]
          }
        },
        {
          "lhs": {
            "op": "D",
            "wrt": "t",
            "args": [
              "z"
            ]
          },
          "rhs": {
            "op": "-",
            "args": [
              {
                "op": "*",
                "args": [
                  "x",
                  "y"
                ]
              },
              {
                "op": "*",
                "args": [
                  "beta",
                  "z"
                ]
              }
            ]
          }
        }
      ]
    }
  }
}
```


## Installation

The installation method varies depending on which language you are using:

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


## License

This project is licensed under the [GNU Affero General Public License v3.0](LICENSE).

## Citation

If you use EarthSciAST in your research, please cite:

```bibtex
@software{earthsciserialization,
  title = {EarthSciAST: An Abstract Syntax Tree Format and },
  author = {EarthSciML Authors and Contributors},
  year = {2026},
  url = {https://github.com/EarthSciML/EarthSciAST}
}
```
