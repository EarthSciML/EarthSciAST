# Release Process Documentation

## Overview

The EarthSciAST project uses an automated release system that manages publishing across five language implementations:

- **Julia**: EarthSciAST.jl (Julia General Registry)
- **TypeScript/JavaScript**: @earthsciml/ast (npm)
- **Python**: earthsci-ast (PyPI)
- **Rust**: earthsci-ast (crates.io)
- **Go**: earthsci-ast-go (Go modules)

## Semantic Versioning

We follow [Semantic Versioning](https://semver.org/) (SemVer):
- **MAJOR**: Breaking changes across language implementations
- **MINOR**: New features (backward compatible)
- **PATCH**: Bug fixes and improvements

## Automated Release Workflow

### Triggers

1. **Automatic**: Push to `main` branch with package changes
2. **Manual**: Workflow dispatch with version type selection

### Process

1. **Change Detection**: Analyzes commits since last release
2. **Version Calculation**: Determines version bump type from commit messages
3. **Cross-Language Compatibility**: Tests all language implementations
4. **Version Synchronization**: Updates all package configuration files
5. **Release Creation**: Creates GitHub release with auto-generated notes
6. **Package Publishing**: Publishes to all registries simultaneously

## Manual Release Process

### Prerequisites

1. Ensure all CI tests pass
2. Update documentation if needed
3. Test compatibility between language implementations

### Steps

#### 1. Prepare Release

```bash
# Check current status
python scripts/version-manager.py check

# Bump version (patch/minor/major)
python scripts/version-manager.py bump minor

# Or prepare specific version
python scripts/version-manager.py release 1.2.0
```

#### 2. Create Release

```bash
# Commit changes
git add .
git commit -m "Release v1.2.0

- Add new feature X
- Fix bug Y
- Improve performance Z

Co-Authored-By: Claude <noreply@anthropic.com>"

# Tag and push
git tag -a v1.2.0 -m "Release v1.2.0"
git push origin main --tags
```

#### 3. Verify Publishing

The GitHub Actions workflows will automatically:
- Run all tests across all languages
- Publish packages to their respective registries
- Update compatibility matrix
- Generate and upload release notes

## Registry Configuration

### Required Secrets

Configure these secrets in GitHub repository settings:

- `NPM_TOKEN`: npm publishing token
- `CARGO_REGISTRY_TOKEN`: crates.io API token
- `PYPI_API_TOKEN`: PyPI trusted publishing or API token

### Registry URLs

- **Julia**: https://github.com/JuliaRegistries/General
- **npm**: https://registry.npmjs.org
- **PyPI**: https://pypi.org
- **crates.io**: https://crates.io
- **Go**: https://proxy.golang.org

## Version Compatibility Matrix

The system maintains a compatibility matrix in `workspace.json`:

```json
{
  "compatibility_matrix": {
    "0.1.0": {
      "julia": "0.1.0",
      "typescript": "0.1.0",
      "python": "0.1.0",
      "rust": "0.1.0",
      "go": "0.1.0",
      "status": "compatible",
      "tested": "2026-02-15T18:00:00Z"
    }
  }
}
```

## Commit Message Conventions

We use [Conventional Commits](https://www.conventionalcommits.org/):

- `feat:` - New features (triggers minor version bump)
- `fix:` - Bug fixes (triggers patch version bump)
- `feat!:` or `BREAKING CHANGE:` - Breaking changes (triggers major version bump)
- `docs:` - Documentation changes
- `refactor:` - Code refactoring
- `test:` - Test additions/changes
- `chore:` - Maintenance tasks

## Cross-Language Testing

Before each release, the system runs compatibility tests:

1. **Julia**: `julia --project=. -e 'using Pkg; Pkg.test()'`
2. **TypeScript**: `npm run test:ci`
3. **Python**: `python -m pytest tests/ -v`
4. **Rust**: `cargo test`
5. **Go**: `go test ./...`

## Package Structure

Each language implementation follows consistent structure:

```
pkg/
├── EarthSciAST.jl/          # Julia package
│   ├── Project.toml       # Julia dependencies
│   └── src/
├── earthsci-ast-ts/       # TypeScript package
│   ├── package.json       # npm configuration
│   └── src/
├── earthsci_ast/            # Python package
│   ├── pyproject.toml     # Python packaging
│   └── src/
├── earthsci-ast-rs/    # Rust crate
│   ├── Cargo.toml         # Rust dependencies
│   └── src/
└── earthsci-ast-go/         # Go module
    ├── go.mod             # Go dependencies
    └── pkg/
```

## Emergency Release Process

For critical fixes requiring immediate release:

1. Create hotfix branch: `git checkout -b hotfix/critical-fix`
2. Make minimal necessary changes
3. Test thoroughly
4. Use manual workflow dispatch with patch version
5. Monitor release process closely

## Rollback Process

If a release has issues:

1. **Immediate**: Create new patch release fixing the issue
2. **Registry-specific rollback**:
   - npm: `npm unpublish package@version` (within 24 hours)
   - PyPI: File support request (cannot self-unpublish)
   - crates.io: `cargo yank crate_name --vers version`
   - Julia: Create PR to General registry
   - Go: Cannot unpublish, create new version

## Monitoring and Verification

### Post-Release Checklist

- [ ] All packages published successfully
- [ ] GitHub release created with correct notes
- [ ] Compatibility matrix updated
- [ ] All registries show new version
- [ ] Installation commands work
- [ ] Documentation updated

### Registry Status Pages

- npm: https://status.npmjs.org
- PyPI: https://status.python.org
- crates.io: https://status.crates.io
- Julia: https://status.julialang.org
- Go: https://status.golang.org

## Troubleshooting

### Common Issues

1. **Publishing fails**: Check secrets configuration and network connectivity
2. **Version conflicts**: Ensure versions are synchronized across all packages
3. **Test failures**: Review compatibility matrix and fix breaking changes
4. **Registry delays**: Some registries may take time to index new packages

### Debug Commands

```bash
# Check package build status
npm run build                    # TypeScript
python -m build                  # Python
cargo build                      # Rust
julia --project=. -e 'using Pkg; Pkg.build()' # Julia
go build ./...                   # Go

# Verify package contents
npm pack && tar -tzf *.tgz      # npm
python -m build && ls dist/     # Python
cargo package --list           # Rust

# Test installation
npm install @earthsciml/ast          # npm
pip install earthsci-ast          # PyPI
cargo add earthsci-ast            # crates.io
julia> ] add EarthSciAST          # Julia
go get github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go # Go
```

## Contact

For release process issues:
- Create issue in repository
- Contact maintainers
- Check GitHub Actions logs for detailed error information