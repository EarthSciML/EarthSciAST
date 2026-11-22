# Project Instructions for AI Agents

## Build & Test

See [CONTRIBUTING.md](CONTRIBUTING.md) for full setup and [CONFORMANCE_SPEC.md](CONFORMANCE_SPEC.md) for cross-language conformance details.

```bash
# Cross-language conformance tests (all languages)
./scripts/test-conformance.sh

# Individual language tests
julia --project=. -e 'using Pkg; Pkg.test()'                       # Julia (no ModelingToolkit/Catalyst)
julia --project=pkg/EarthSciAST.jl/test/mtk pkg/EarthSciAST.jl/test/mtk/runtests.jl  # Julia MTK/Catalyst suite (Pkg.develop the package into that env first; see CONTRIBUTING.md)
cd pkg/earthsci-ast-ts && npm test                            # TypeScript
cd pkg/earthsci-ast-py && python3 -m pytest tests/ -v         # Python
cd pkg/earthsci-ast-rs && cargo test                       # Rust
cd pkg/earthsci-ast-go && go test ./...                          # Go

# Dependency management
./install.sh --all       # Install all language environments
./install.sh --check     # Verify system requirements
```

## Conventions & Patterns

- Follow conventional commits: `type(scope): description` (e.g. `feat(julia): add expression support`)
- All implementations must conform to `esm-schema.json` and pass `./scripts/test-conformance.sh`
- Follow each language's idiomatic style (see [CONTRIBUTING.md](CONTRIBUTING.md#language-specific-standards))

Do not put "Co-Authored-By: Claude ..." in any commit messages. Claude is an LLM and LLMs cannot take responsibility for outputs, therefore they cannot be authors.

Whe you receive a report from a subagent that includes abbreviations, shorthand, or acronyms that the subagent made up, if you discuss the report with me please discuss it using actual words rather than the shorthand made up by the subagent.

When developing locally, only run test suites directly related to the code you are changing; leave the full test suite to be run by CI.

Automatically generated .esm files for testing or benchmarks should not be checked into git; instead they should be generated at run-time.

This is a large project, subject to bit-rot. As you are working, be on the lookout for opportunities to improve the elegance and maintainability of the code. When you find small opportunities, just implement them as part of your normal work. If you find larger opportunities, flag them to the user. Before implementing a new feature, check whether a similar feature already exists, and prefer generalizing existing capabilities to implementing new capabilities that are similar.
