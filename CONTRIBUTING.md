# Contributing to EarthSciAST

Thank you for your interest in contributing to EarthSciAST! This guide covers everything you need to know to get started with development, testing, and submitting contributions to this multi-language earth science serialization project.

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

EarthSciAST is a language-agnostic JSON-based format for earth science model components with implementations across multiple programming languages:

- **Julia** (EarthSciAST.jl) - Complete MTK/Catalyst integration
- **TypeScript** (@earthsciml/ast) - Web/Node.js types and utilities
- **Python** (earthsci_ast) - Scientific Python integration
- **Rust** (earthsci-ast) - High-performance implementation
- **Go** (earthsci-ast-go) - Lightweight Go implementation

All implementations must maintain conformance across languages through our comprehensive test suite.

## Development Setup

### Prerequisites

Ensure you have the following installed:

- **Julia** 1.9+ (for Julia package development and testing)
- **Node.js** 20+ and npm (for TypeScript/JavaScript packages)
- **Python** 3.8+ and pip (for Python package development)
- **Rust** 1.75.0+ and Cargo (for Rust package development)
  - No C/C++ toolchain needed. The spherical-geometry kernel is `s2rst`, a
    pure-Rust port of Google's s2geometry, so `cargo build` works from a clean
    checkout with nothing but Cargo — and cross-compiles to `wasm32-unknown-unknown`
    unchanged.
  - **Only** for the opt-in `s2-cpp` feature (the C++ differential oracle,
    `cargo test --features s2-cpp --test geometry_s2_differential`) do you also
    need **CMake** and **OpenSSL headers**: that path builds vendored s2geometry
    via `s2bindings-sys`, which includes `<openssl/bn.h>`. On Linux the distro
    package (`libssl-dev` / `openssl-devel`) puts these on the default include
    path. On **macOS**, Homebrew's openssl is keg-only, so the crate ships a
    `pkg/earthsci-ast-rs/.cargo/config.toml` that adds both Homebrew prefixes to
    `CXXFLAGS` — `brew install cmake openssl@3` and it builds with no manual
    environment. (Upstream bug: the shim CMake target does not inherit OpenSSL's
    include dirs; see that config for the full note.)
- **Go** 1.19+ (for Go package development)
- **Git** (for version control)

### Initial Setup

1. **Clone the repository:**
   ```bash
   git clone https://github.com/EarthSciML/EarthSciAST.git
   cd EarthSciAST
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
EarthSciAST/
├── pkg/                 # Language-specific implementations
│   ├── EarthSciAST.jl/        # Julia implementation
│   ├── earthsci-ast-ts/    # TypeScript implementation
│   ├── earthsci_ast/          # Python implementation
│   ├── earthsci-ast-rs/  # Rust implementation
│   └── earthsci-ast-go/       # Go implementation
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
6. **Surface Discipline**: The public API of every binding is pinned by
   [`API_SPEC.md`](API_SPEC.md) and [`api-surface.json`](api-surface.json).
   Naming a new export follows the transliteration rule in `API_SPEC.md` §2,
   and the manifest must be regenerated in the same commit:
   `python3 scripts/gen-api-surface.py`

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
- **Public API changes** must regenerate `api-surface.json`. Each binding has a
  surface test that fails when its exports and the manifest disagree in either
  direction; `python3 scripts/extract-api-surface.py --check` runs the same
  comparison for all six at once. See [`API_SPEC.md`](API_SPEC.md) §9.

## Contribution Workflow

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

### Julia (EarthSciAST.jl)

- **Primary Implementation**: Julia is the reference implementation
- **Testing**: All changes must pass Julia test suite
- **Dependencies**: Use Project.toml for dependency management
- **Integration**: Maintain ModelingToolkit.jl and Catalyst.jl compatibility
- **Performance**: Profile performance-critical code paths

```bash
# Julia development workflow
cd pkg/EarthSciAST.jl
julia --project=. -e 'using Pkg; Pkg.activate("."); Pkg.test()'
```

### TypeScript (@earthsciml/ast)

- **Standards**: Strict TypeScript (`npm run typecheck`), ESLint + Prettier
- **Testing**: Vitest for unit tests
- **Build**: Support both Node.js and browser environments (ESM + CJS bundles via rollup)
- **Types**: Maintain comprehensive type definitions

```bash
# TypeScript development workflow
cd pkg/earthsci-ast-ts
npm install
npm run typecheck
npm run lint
npm run format:check
npm test
npm run build
```

### Python (earthsci_ast)

- **Standards**: PEP 8, type hints, Black formatting
- **Testing**: pytest for unit tests, mypy for type checking
- **Packaging**: Use pyproject.toml, support Python 3.8+
- **Dependencies**: Scientific Python ecosystem (NumPy, pandas)

```bash
# Python development workflow
cd pkg/earthsci-ast-py
pip install -e .[dev]
python -m pytest
python -m mypy earthsci_ast/
python -m black earthsci_ast/
```

### Rust (earthsci-ast)

- **Standards**: rustfmt, clippy, comprehensive error handling
- **Testing**: Standard Rust testing with cargo test
- **Performance**: Focus on high-performance parsing/serialization
- **Safety**: No unsafe code without thorough justification

```bash
# Rust development workflow
cd pkg/earthsci-ast-rs
cargo fmt
cargo clippy -- -D warnings
cargo test
# The bench target is gated behind the `benchmarks` feature, so a plain
# `cargo bench` builds nothing. CI compiles it with an explicit feature list
# (see below for why it is not `--all-features`).
cargo bench --features benchmarks  # for performance testing
```

**The `xla` compiled backend.** The `xla` feature emits the tape IR as an XLA
computation and runs it through PJRT (`pkg/earthsci-ast-rs/README.md` has the
full description). It is OFF by default and **excluded from every
`--all-features` invocation**, because it links a prebuilt 144 MB
`xla_extension` release that is fetched separately and never vendored:

```bash
# once, outside the checkout
scripts/fetch-xla-extension.sh --variant cpu
export XLA_EXTENSION_DIR=$HOME/.cache/earthsci/xla/xla_extension-0.10.0-cpu/xla_extension
export LIBCLANG_PATH=/path/to/llvm/lib      # the xla crate's build script runs bindgen

cd pkg/earthsci-ast-rs
cargo test --features xla --lib --tests     # the emitter's own tests (doctests need
                                            # LD_LIBRARY_PATH=$XLA_EXTENSION_DIR/lib; see the crate README)
cargo build --features conformance-adapters,xla \
  --bin earthsci-compiled-rhs-adapter-rust  # the compiled_rhs adapter
```

Without `XLA_EXTENSION_DIR` the feature's tests skip with a message rather
than failing, and the adapter answers `--engine compiled` with the tier's
`unavailable` outcome. Like `esio`, the feature may raise the effective MSRV
above the crate's declared 1.89, which is the other reason CI names its
features explicitly instead of using `--all-features`.

#### The two workflows, and which one gates XLA

The compiled backends are tested by a workflow of their own, and the split is
deliberate:

| | `.github/workflows/conformance-testing.yml` | `.github/workflows/xla-backends.yml` |
|---|---|---|
| Runs on | every push/PR touching `pkg/**`, `tests/**`, `scripts/**` | only pushes/PRs touching the Rust crate, the Julia package, `tests/conformance/compiled_rhs/**`, the tier runner, or the fetch script |
| `xla` cargo feature | **never** — every `--features` list there names its features explicitly and omits `xla` (and `--all-features` is likewise avoided) | `conformance-adapters,xla`, with `XLA_EXTENSION_DIR` exported from a cached fetch |
| Reactant | never — `ESM_TEST_REACTANT` is unset, so the `reactant_*_test.jl` files are skipped by `runtests.jl` | set to `1` for `test/reactant_direct_emit_test.jl`, run standalone from the adapter's own env |
| `compiled-RHS compiled producer` stages | report `unavailable` and **skip visibly** | required: `scripts/assert-compiled-rhs-available.py` fails the job unless the binding's status in the report JSON is `ok` |
| Cost | minutes | a 144 MB XLA download (cached per pinned version), a full `xla`-feature crate build, and a Reactant precompile — the Julia job budgets 120 minutes |

The skip in the main workflow is legal because
`tests/conformance/compiled_rhs/manifest.json` leaves
`engines.compiled.bindings_required` empty and lists julia and rust under
`bindings_optional`. That also means the tier runner **exits 0 on a skip**,
which is why `xla-backends.yml` asserts on the report rather than trusting the
exit code. A *refusal* — a model an emitter cannot lower — is a hard failure in
both workflows wherever the fixture lists the binding in `compiled_required`;
optionality covers availability only.

Running the same commands locally:

```bash
# --- what the rust-xla job does -----------------------------------------
scripts/fetch-xla-extension.sh --variant cpu --dest "$HOME/xla-ext"
export XLA_EXTENSION_DIR=$HOME/xla-ext/xla_extension-0.10.0-cpu/xla_extension
export LIBCLANG_PATH=/path/to/llvm/lib   # CI uses the distro's libclang-dev

cargo build --manifest-path pkg/earthsci-ast-rs/Cargo.toml \
  --features conformance-adapters,xla
cargo test --manifest-path pkg/earthsci-ast-rs/Cargo.toml \
  --features conformance-adapters,xla --lib --tests
LD_LIBRARY_PATH=$XLA_EXTENSION_DIR/lib cargo test \
  --manifest-path pkg/earthsci-ast-rs/Cargo.toml \
  --features conformance-adapters,xla --doc

python3 scripts/run-compiled-rhs-conformance.py --self-test
EARTHSCI_COMPILED_RHS_ADAPTER_RUST="cargo run --quiet --manifest-path pkg/earthsci-ast-rs/Cargo.toml --features conformance-adapters,xla --bin earthsci-compiled-rhs-adapter-rust --" \
  python3 scripts/run-compiled-rhs-conformance.py --bindings rust --engine compiled \
    --output conformance-results/compiled_rhs/rust_compiled_report.json
python3 scripts/assert-compiled-rhs-available.py \
  conformance-results/compiled_rhs/rust_compiled_report.json rust

# --- what the julia-xla job does ----------------------------------------
env=pkg/EarthSciAST.jl/scripts/compiled_rhs_reactant_env
julia --project=$env -e 'using Pkg; Pkg.develop(path="pkg/EarthSciAST.jl"); Pkg.instantiate(); Pkg.precompile()'
ESM_TEST_REACTANT=1 julia --project=$env \
  -e 'cd("pkg/EarthSciAST.jl/test"); include("reactant_direct_emit_test.jl")'

EARTHSCI_COMPILED_RHS_ADAPTER_JULIA="julia pkg/EarthSciAST.jl/scripts/compiled_rhs_adapter.jl" \
  python3 scripts/run-compiled-rhs-conformance.py --bindings julia --engine compiled \
    --output conformance-results/compiled_rhs/julia_compiled_report.json
python3 scripts/assert-compiled-rhs-available.py \
  conformance-results/compiled_rhs/julia_compiled_report.json julia
```

`Pkg.test()` on the Julia package is *not* how the emitter's tests are run:
the full target is heavy, and `reactant_direct_emit_test.jl` is written to run
standalone from the adapter's Reactant environment (its own header documents
the invocation above). Everything runs from the repository root.

### Go (earthsci-ast-go)

- **Standards**: gofmt, go vet, standard Go conventions
- **Testing**: Go standard testing package
- **Simplicity**: Maintain lightweight, dependency-minimal design
- **Performance**: Focus on fast parsing and low memory usage

```bash
# Go development workflow
cd pkg/earthsci-ast-go
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

Thank you for contributing to EarthSciAST! Your contributions help advance earth science modeling capabilities across programming languages.