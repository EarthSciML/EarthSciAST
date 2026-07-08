# Project Instructions for AI Agents

## Build & Test

See [CONTRIBUTING.md](CONTRIBUTING.md) for full setup and [CONFORMANCE_SPEC.md](CONFORMANCE_SPEC.md) for cross-language conformance details.

```bash
# Cross-language conformance tests (all languages)
./scripts/test-conformance.sh

# Individual language tests
julia --project=. -e 'using Pkg; Pkg.test()'                       # Julia
cd pkg/earthsci-ast-ts && npm test                            # TypeScript
cd pkg/earthsci-ast-py && python3 -m pytest tests/ -v         # Python
cd pkg/earthsci-ast-rs && cargo test                       # Rust
cd pkg/earthsci-ast-go && go test ./...                          # Go
cd pkg/earthsci-ast-editor && npm test                                  # SolidJS editor

# Dependency management
./install.sh --all       # Install all language environments
./install.sh --check     # Verify system requirements
```

## Architecture Overview

EarthSciAST is a language-agnostic JSON format for earth science model components, defined by `esm-schema.json` and documented in `esm-spec.md`. Language implementations live under `pkg/`:

- **EarthSciAST.jl** — Julia reference implementation (MTK/Catalyst integration)
- **earthsci-ast-ts** (`@earthsciml/ast`) — TypeScript types and utilities
- **earthsci-ast-py** (`earthsci-ast`) — Python scientific integration
- **earthsci-ast-rs** (`earthsci-ast`) — Rust high-performance implementation
- **earthsci-ast-go** — Go lightweight implementation
- **earthsci-ast-editor** (`@earthsciml/ast-editor`) — SolidJS interactive web editor

Shared test fixtures in `tests/` (valid, invalid, conformance) ensure cross-language consistency.

## Conventions & Patterns

- Follow conventional commits: `type(scope): description` (e.g. `feat(julia): add expression support`)
- All implementations must conform to `esm-schema.json` and pass `./scripts/test-conformance.sh`
- Follow each language's idiomatic style (see [CONTRIBUTING.md](CONTRIBUTING.md#language-specific-standards))
