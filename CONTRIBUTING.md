# Contributing to EarthSciSerialization

Thank you for your interest in contributing to EarthSciSerialization! This guide covers everything you need to know to get started with development, testing, and submitting contributions to this multi-language earth science serialization project.

## Table of Contents

- [Overview](#overview)
- [Development Setup](#development-setup)
- [Project Structure](#project-structure)
- [Coding Standards](#coding-standards)
- [Testing Requirements](#testing-requirements)
- [Contribution Workflow](#contribution-workflow)
- [Language-Specific Guidelines](#language-specific-guidelines)
- [Documentation](#documentation)
- [Issue Tracking](#issue-tracking)
- [Release Process](#release-process)
- [Getting Help](#getting-help)

## Overview

EarthSciSerialization is a language-agnostic JSON-based format for earth science model components with implementations across multiple programming languages:

- **Julia** (EarthSciSerialization.jl) - Complete MTK/Catalyst integration
- **TypeScript** (earthsci-toolkit) - Web/Node.js types and utilities
- **Python** (earthsci_toolkit) - Scientific Python integration
- **Rust** (earthsci-toolkit) - High-performance implementation
- **Go** (esm-format-go) - Lightweight Go implementation
- **SolidJS** (esm-editor) - Interactive web-based editor

All implementations must maintain conformance across languages through our comprehensive test suite.

## Development Setup

### Prerequisites

Ensure you have the following installed:

- **Julia** 1.9+ (for Julia package development and testing)
- **Node.js** 20+ and npm (for TypeScript/JavaScript packages)
- **Python** 3.8+ and pip (for Python package development)
- **Rust** 1.75.0+ and Cargo (for Rust package development)
- **Go** 1.19+ (for Go package development)
- **Git** (for version control)

### Initial Setup

1. **Clone the repository:**
   ```bash
   git clone https://github.com/EarthSciML/EarthSciSerialization.git
   cd EarthSciSerialization
   ```

2. **Install dependencies for all packages:**
   ```bash
   # Install environments for every supported language
   ./install.sh --all
   ```

3. **Run the setup verification:**
   ```bash
   # Check all required tools are installed
   ./install.sh --check
   ```

4. **Run the full test suite:**
   ```bash
   # Julia tests (primary testing framework)
   julia --project=. -e 'using Pkg; Pkg.test()'

   # Cross-language conformance tests
   ./scripts/test-conformance.sh
   ```

### Environment Configuration

`install.sh` accepts per-language flags so you can set up only the environments you need:

```bash
# Install only the languages you intend to work on
./install.sh --julia
./install.sh --ts --py
./install.sh --rust --go

# Install development tools (linters, formatters, etc.)
./install.sh --dev
```

## Project Structure

```
EarthSciSerialization/
├── packages/                 # Language-specific implementations
│   ├── EarthSciSerialization.jl/        # Julia implementation
│   ├── earthsci-toolkit/    # TypeScript implementation
│   ├── earthsci_toolkit/          # Python implementation
│   ├── earthsci-toolkit-rs/  # Rust implementation
│   ├── esm-format-go/       # Go implementation
│   └── esm-editor/          # SolidJS web editor
├── tests/                   # Cross-language conformance tests
│   ├── valid/              # Valid ESM files for testing
│   ├── invalid/            # Invalid ESM files for validation testing
│   ├── conformance/        # Cross-language test fixtures
│   └── README.md           # Detailed testing documentation
├── scripts/                # Development and build scripts
├── docs/                   # Documentation and specifications
├── .github/workflows/      # CI/CD workflows
├── esm-spec.md            # Format specification
├── esm-libraries-spec.md  # Library implementation requirements
└── esm-schema.json        # Authoritative JSON schema
```

## Coding Standards

### General Principles

1. **Consistency First**: All language implementations must produce identical results for the same inputs
2. **Schema Compliance**: All changes must maintain compatibility with `esm-schema.json`
3. **Test-Driven Development**: Write tests before implementation
4. **Documentation**: All public APIs must be documented
5. **Error Handling**: Provide clear, actionable error messages

### Language-Specific Standards

Each language implementation should follow its ecosystem's conventions:

- **Julia**: Follow [Julia Style Guide](https://docs.julialang.org/en/v1/manual/style-guide/)
- **TypeScript**: Use ESLint + Prettier, follow strict type checking
- **Python**: Follow PEP 8, use type hints, run black formatter
- **Rust**: Follow `rustfmt` and `clippy` recommendations
- **Go**: Follow `gofmt` and standard Go conventions

### Code Quality Requirements

All code contributions must:

- Pass language-specific linters and formatters
- Maintain 90%+ test coverage for new functionality
- Include appropriate error handling and validation
- Follow semantic versioning for breaking changes
- Be compatible with specified minimum language versions

## Testing Requirements

See [CONFORMANCE_SPEC.md](CONFORMANCE_SPEC.md) for the fixture format, execution protocol, and run commands.

### Test Requirements for Contributions

- **All tests must pass** before code submission
- **New features** require corresponding conformance tests
- **Bug fixes** must include regression tests
- **Breaking changes** require migration guides and deprecation notices

## Contribution Workflow

### Issue Tracking

We use **[Beads](https://github.com/beadshq/beads)** for project management and issue tracking:

```bash
# Find available work
bd ready

# View issue details
bd show <issue-id>

# Claim an issue
bd update <issue-id> --status=in_progress

# Close completed work
bd close <issue-id>
```

### Development Process

1. **Find or Create an Issue:**
   ```bash
   # Find ready work
   bd ready

   # Or create new issue
   bd create --title="Add feature X" --type=feature --priority=2
   ```

2. **Create a Branch:**
   ```bash
   git checkout -b feature/issue-description
   ```

3. **Make Changes:**
   - Write tests first (TDD approach)
   - Implement functionality
   - Run tests frequently: `julia --project=. -e 'using Pkg; Pkg.test()'`
   - Commit small, focused changes

4. **Test Everything:**
   ```bash
   # Run full test suite
   julia --project=. -e 'using Pkg; Pkg.test()'
   ./scripts/test-conformance.sh

   # Verify required tools are installed
   ./install.sh --check
   ```

5. **Submit Pull Request:**
   - Ensure all tests pass
   - Update documentation as needed
   - Reference the issue being addressed
   - Include clear description of changes

### Commit Guidelines

Follow conventional commit format:

```
type(scope): description

Examples:
feat(julia): add expression evaluation support
fix(typescript): resolve schema validation edge case
docs(spec): update coupling section examples
test(conformance): add mathematical correctness fixtures
```

## Language-Specific Guidelines

### Julia (EarthSciSerialization.jl)

- **Primary Implementation**: Julia is the reference implementation
- **Testing**: All changes must pass Julia test suite
- **Dependencies**: Use Project.toml for dependency management
- **Integration**: Maintain ModelingToolkit.jl and Catalyst.jl compatibility
- **Performance**: Profile performance-critical code paths

```bash
# Julia development workflow
cd packages/EarthSciSerialization.jl
julia --project=. -e 'using Pkg; Pkg.activate("."); Pkg.test()'
```

### TypeScript (earthsci-toolkit)

- **Standards**: Strict TypeScript (`npm run typecheck`), ESLint + Prettier
- **Testing**: Vitest for unit tests
- **Build**: Support both Node.js and browser environments (ESM + CJS bundles via rollup)
- **Types**: Maintain comprehensive type definitions

```bash
# TypeScript development workflow
cd packages/earthsci-toolkit
npm install
npm run typecheck
npm run lint
npm run format:check
npm test
npm run build
```

### Python (earthsci_toolkit)

- **Standards**: PEP 8, type hints, Black formatting
- **Testing**: pytest for unit tests, mypy for type checking
- **Packaging**: Use pyproject.toml, support Python 3.8+
- **Dependencies**: Scientific Python ecosystem (NumPy, pandas)

```bash
# Python development workflow
cd packages/earthsci_toolkit
pip install -e .[dev]
python -m pytest
python -m mypy earthsci_toolkit/
python -m black earthsci_toolkit/
```

### Rust (earthsci-toolkit)

- **Standards**: rustfmt, clippy, comprehensive error handling
- **Testing**: Standard Rust testing with cargo test
- **Performance**: Focus on high-performance parsing/serialization
- **Safety**: No unsafe code without thorough justification

```bash
# Rust development workflow
cd packages/earthsci-toolkit-rs
cargo fmt
cargo clippy -- -D warnings
cargo test
cargo bench  # for performance testing
```

### Go (esm-format-go)

- **Standards**: gofmt, go vet, standard Go conventions
- **Testing**: Go standard testing package
- **Simplicity**: Maintain lightweight, dependency-minimal design
- **Performance**: Focus on fast parsing and low memory usage

```bash
# Go development workflow
cd packages/esm-format-go
go fmt ./...
go vet ./...
go test ./...
```

## Documentation

### Documentation Requirements

All contributions must include appropriate documentation:

- **API Documentation**: All public functions/types/methods
- **Usage Examples**: Demonstrating new functionality
- **Format Specification Updates**: For changes affecting the ESM format
- **Migration Guides**: For breaking changes

### Building Documentation

```bash
# Generate documentation for all packages
./scripts/generate_docs.py
```

## Issue Tracking

We use Beads for comprehensive project management:

### Creating Issues

```bash
# Create different types of issues
bd create --title="Bug: parsing fails on complex expressions" --type=bug --priority=1
bd create --title="Feature: add GraphQL operator support" --type=feature --priority=2
bd create --title="Docs: improve Python API examples" --type=task --priority=3
```

### Issue Labels and Priorities

- **Priority Levels**: P0 (critical) to P4 (backlog)
- **Types**: bug, feature, task, epic, documentation
- **Languages**: julia, typescript, python, rust, go
- **Areas**: parser, schema, validation, performance, conformance

### Dependencies and Blocking

```bash
# Add dependencies between issues
bd dep add <dependent-issue> <blocking-issue>

# View blocked issues
bd blocked
```

## Release Process

### Version Management

All packages follow semantic versioning:

- **Major** (X.0.0): Breaking changes to ESM format or public APIs
- **Minor** (0.X.0): New features, backward compatible
- **Patch** (0.0.X): Bug fixes, backward compatible

### Release Workflow

1. **Version Coordination**: All language packages maintain synchronized versions
2. **Testing**: Full conformance test suite must pass (`./scripts/test-conformance.sh`)
3. **Documentation**: Update all relevant documentation
4. **Security**: Run security scans (`./scripts/package-security-scanner.py`) and address vulnerabilities
5. **Changelog**: Generate comprehensive changelog
6. **Tagging**: Tag and publish each language package per its ecosystem (e.g., `npm publish`, `cargo publish`, Julia registry PR)

## Getting Help

### Communication Channels

- **Issues**: Use Beads issue tracker for bug reports and feature requests
- **Discussions**: GitHub Discussions for questions and broader topics
- **Security**: See SECURITY.md for security-related concerns

### Common Development Tasks

**Adding a new operator:**
1. Update `esm-schema.json` with operator definition
2. Add conformance fixtures under `tests/valid/` (or `tests/invalid/` for parse errors)
3. Implement in each language package
4. Update format specification (`esm-spec.md`)

**Adding a registered function (the `call` escape hatch):**

Registered functions are a deliberate escape hatch for operations that cannot be
written as a finite composition of built-in AST ops. Prefer the AST — every new
registered function imposes a per-binding implementation burden on all five
languages. Before filing a PR that adds one, work through this checklist:

1. **Verify the operation is NOT expressible in existing AST ops.** Consult the
   decision table in `esm-spec.md` §9.2 ("When to use `call` vs. AST ops"). In
   particular, `x^n`, `max`/`min`, clip/clamp, sign-dependent branching, and the
   standard trig / exp / log / sqrt family all have native AST ops and MUST be
   written as such. A `call` is justified only for tabulated lookups,
   implicit/iterative solves, or platform-dependent adapters.
2. **Declare the calling contract** in the owning rule's `registered_functions`
   block: `id`, `signature` (`arg_count`, `arg_types`, `return_type`), `units`,
   and `arg_units`. Unit hints are strongly encouraged so bindings can dimension-check.
3. **Provide a reference implementation in at least Julia and Python** so that
   authors of the remaining three bindings (Rust, Go, TypeScript) have a
   template for their handler wiring.
4. **Acknowledge the burden.** Each new registered function means five
   binding-level handler registrations and five sets of tests. If the
   functionality could instead be delivered as an AST op or a stateful operator
   (Section 9.1), that path is almost always preferable.
5. **Code review gate.** PRs that add a `registered_functions` entry are
   rejected unless step 1 is explicitly addressed in the PR description — the
   reviewer MUST confirm the operation cannot be written in existing AST ops
   before approving.

**Adding a new validation rule:**
1. Add invalid test cases to `tests/invalid/`
2. Update `expected_errors.json` with error codes
3. Implement validation in each language
4. Document in library specification

**Performance optimization:**
1. Add a benchmark in the relevant binding's test suite
2. Profile and optimize implementation
3. Verify conformance is maintained
4. Document performance characteristics

### Development Environment Issues

**Missing or incompatible tools:**
```bash
./install.sh --check        # Diagnose missing language toolchains
```

**Test failures:**
```bash
./scripts/test-conformance.sh  # Run full conformance tests
```

Thank you for contributing to EarthSciSerialization! Your contributions help advance earth science modeling capabilities across programming languages.