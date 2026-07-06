# Project Instructions for AI Agents

## Build & Test

See [CONTRIBUTING.md](CONTRIBUTING.md) for full setup and [CONFORMANCE_SPEC.md](CONFORMANCE_SPEC.md) for cross-language conformance details.

```bash
# Cross-language conformance tests (all languages)
./scripts/test-conformance.sh

# Individual language tests
julia --project=. -e 'using Pkg; Pkg.test()'                       # Julia
cd packages/earthsci-toolkit && npm test                            # TypeScript
cd packages/earthsci_toolkit && python3 -m pytest tests/ -v         # Python
cd packages/earthsci-toolkit-rs && cargo test                       # Rust
cd packages/esm-format-go && go test ./...                          # Go
cd packages/esm-editor && npm test                                  # SolidJS editor

# Dependency management
./install.sh --all       # Install all language environments
./install.sh --check     # Verify system requirements
```

## Architecture Overview

EarthSciSerialization is a language-agnostic JSON format for earth science model components, defined by `esm-schema.json` and documented in `esm-spec.md`. Language implementations live under `packages/`:

- **EarthSciSerialization.jl** — Julia reference implementation (MTK/Catalyst integration)
- **earthsci-toolkit** — TypeScript types and utilities
- **earthsci_toolkit** — Python scientific integration
- **earthsci-toolkit-rs** — Rust high-performance implementation
- **esm-format-go** — Go lightweight implementation
- **esm-editor** — SolidJS interactive web editor

Shared test fixtures in `tests/` (valid, invalid, conformance) ensure cross-language consistency.

## Conventions & Patterns

- Follow conventional commits: `type(scope): description` (e.g. `feat(julia): add expression support`)
- All implementations must conform to `esm-schema.json` and pass `./scripts/test-conformance.sh`
- Follow each language's idiomatic style (see [CONTRIBUTING.md](CONTRIBUTING.md#language-specific-standards))
