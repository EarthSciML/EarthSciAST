# Automated Release Pipeline Documentation

This document describes the comprehensive automated release pipeline for the EarthSciAST project, including CI/CD integration, multi-platform distribution, and multi-language package coordination.

## Overview

The release pipeline provides:

- **Automated Release Management**: Intelligent version detection and release coordination
- **Multi-Language Package Publishing**: Synchronized releases across Julia, TypeScript, Python, and Rust
- **Cross-Platform Binary Distribution**: Native executables for Linux, macOS, and Windows
- **Comprehensive Testing**: Conformance testing and cross-language compatibility validation
- **Automated Changelog Generation**: Structured changelog based on conventional commits

## Pipeline Architecture

### Core Components

1. **Integrated Release Pipeline** (`.github/workflows/integrated-release-pipeline.yml`)
   - Main orchestrator for all release activities
   - Triggers automatically on push to main or manual dispatch
   - Coordinates package-specific workflows

2. **Consolidated Publish Workflow** (`.github/workflows/release-publish.yml`)
   - Fires on `release: published` and on `push` of `v*` tags
   - Julia General registry registration
   - TypeScript/JavaScript package publishing to NPM (stable + beta)
   - Python package build and publish to PyPI / TestPyPI
   - Rust package publishing to crates.io plus cross-platform binary assets
   - Go module tagging and `proxy.golang.org` indexing trigger

   Per-language CI test matrices were absorbed into `conformance-testing.yml`
   (gt-9ju), and per-language publish workflows were consolidated here (gt-567).

3. **Distribution Workflows**
   - `binary-release.yml`: Cross-platform binary compilation and distribution

4. **Supporting Tools**
   - `scripts/release-coordinator.sh`: Manual release coordination script
   - `scripts/generate-changelog.py`: Automated changelog generation
   - `workspace.json`: Version and coordination tracking

## Release Process

### Automatic Releases

Automatic releases trigger when:
- Changes are pushed to the `main` branch
- Changes are detected in any `pkg/` directory
- Conventional commit messages indicate the appropriate version bump type

```bash
# Example commit messages that trigger releases:
git commit -m "feat(julia): add new ESM parser functionality"    # minor release
git commit -m "fix(rust): resolve memory leak in CLI tool"       # patch release
git commit -m "feat!: breaking change to core API"              # major release
```

### Manual Releases

#### Using the Integrated Pipeline (GitHub Actions)

1. Go to Actions → "Integrated Release Pipeline"
2. Click "Run workflow"
3. Select version type: `major`, `minor`, `patch`, or `prerelease`
4. Choose prerelease type if applicable: `alpha`, `beta`, `rc`
5. Optionally force release even without detected changes

#### Using the Release Coordinator Script

```bash
# Basic release (patch version)
./scripts/release-coordinator.sh

# Minor version release
./scripts/release-coordinator.sh --version-type minor

# Preview changes without making them
./scripts/release-coordinator.sh --dry-run

# Force release without confirmation
./scripts/release-coordinator.sh --force --auto-approve

# Full help
./scripts/release-coordinator.sh --help
```

## Version Management

### Version Calculation

The pipeline uses semantic versioning (SemVer) with the following rules:

- **Major**: Breaking changes (detected by `BREAKING CHANGE:` or `!` in commit messages)
- **Minor**: New features (commits starting with `feat:`)
- **Patch**: Bug fixes and other changes
- **Prerelease**: Manual selection with suffixes like `-alpha.1`, `-beta.1`, `-rc.1`

### Version Synchronization

All packages maintain synchronized version numbers:

```json
{
  "version": "1.2.3",
  "packages": {
    "julia": "v1.2.3",
    "typescript": "v1.2.3",
    "python": "v1.2.3",
    "rust": "v1.2.3"
  }
}
```

## Package Publishing

### Julia (EarthSciAST.jl)

- Tests run on Julia 1.9, 1.10, 1.11, 1.12
- Automatic registration with Julia General Registry
- Coverage reporting via Codecov
- Package tagged as `EarthSciAST-v{version}`

**Installation**:
```julia
using Pkg; Pkg.add("EarthSciAST")
```

### TypeScript/JavaScript (@earthsciml/ast)

- Tests run on Node.js 18, 20, 21
- Published to NPM registry
- Beta versions published on main branch pushes
- Production versions on tagged releases

**Installation**:
```bash
npm install @earthsciml/ast
```

### Python (earthsci_ast)

- Tests run on Python 3.8-3.12
- Published to PyPI with trusted publishing
- Test releases on TestPyPI for main branch
- Production releases on tagged releases

**Installation**:
```bash
pip install earthsci-ast
```

### Rust (earthsci-ast)

- Cross-compilation for multiple targets
- CLI binary distribution
- Crate publishing to crates.io
- Integration with binary release pipeline

**Installation**:
```toml
[dependencies]
earthsci-ast = "1.2.3"
```

## Binary Distribution

### Supported Platforms

- **Linux x64**: `x86_64-unknown-linux-gnu`
- **macOS x64**: `x86_64-apple-darwin`
- **macOS ARM64**: `aarch64-apple-darwin` (Apple Silicon)
- **Windows x64**: `x86_64-pc-windows-gnu`

### Distribution Methods

1. **Individual Platform Archives**
   - `.tar.gz` for Unix-like systems
   - `.zip` for Windows
   - SHA256 checksums for verification
   - Platform-specific install scripts

2. **Universal Installer**
   - Auto-detecting platform script
   - One-command installation: `curl -sSL https://github.com/REPO/releases/latest/download/update.sh | bash`
   - Automatic PATH configuration

### Installation Examples

```bash
# Universal installer (recommended)
curl -sSL https://github.com/EarthSciML/EarthSciAST/releases/latest/download/update.sh | bash

# Manual installation
wget https://github.com/EarthSciML/EarthSciAST/releases/latest/download/esm-cli-1.2.3-linux-x64.tar.gz
tar -xzf esm-cli-1.2.3-linux-x64.tar.gz
cd esm-cli-1.2.3-linux-x64/
./install.sh
```

## Quality Assurance

### Testing Strategy

1. **Unit Tests**: Language-specific test suites
2. **Integration Tests**: Cross-language compatibility testing
3. **Conformance Tests**: ESM specification compliance validation
4. **Security Scanning**: Vulnerability assessment with Trivy
5. **SBOM Generation**: Software Bill of Materials for supply chain security

### Automated Quality Gates

Releases are blocked if:
- Any unit tests fail
- Conformance tests don't pass
- Cross-language compatibility is broken
- Security vulnerabilities are detected (high severity)
- Package building fails for any target platform

### Quality Metrics

- **Test Coverage**: Tracked per language with Codecov
- **Performance Benchmarks**: Automated performance regression testing
- **Security Score**: Based on Trivy scans and dependency analysis
- **Compatibility Matrix**: Cross-version compatibility tracking

## Monitoring and Notifications

### Release Status Tracking

Each release maintains status information in `workspace.json`:

```json
{
  "version": "1.2.3",
  "release_coordination": {
    "status": "success",
    "completed": "2024-02-17T10:30:00Z",
    "workflow_run_id": "123456789",
    "binaries_status": "success",
    "conformance_status": "success"
  }
}
```

### Failure Handling

- **Automatic Issue Creation**: Failed releases create GitHub issues with diagnostic information
- **Partial Release Recovery**: Individual components can be re-run if they fail
- **Rollback Capability**: Tagged releases can be reverted if critical issues are discovered

## Configuration

### Environment Variables

Key configuration through GitHub repository settings:

- `NPM_TOKEN`: NPM registry authentication
- `GITHUB_TOKEN`: Automatically provided for GitHub operations

### Customization Options

- **Version Bump Strategy**: Configurable conventional commit parsing
- **Package Selection**: Enable/disable specific language packages
- **Platform Targets**: Customize binary build targets
## Troubleshooting

### Common Issues

1. **Release Not Triggering**
   - Check that changes are in `pkg/` directories
   - Verify commit messages follow conventional commit format
   - Consider using `--force` flag for manual releases

2. **Package Publishing Failures**
   - Verify authentication tokens are properly configured
   - Check for version conflicts with existing releases
   - Review package-specific workflow logs

3. **Binary Build Failures**
   - Check cross-compilation setup for target platforms
   - Verify Rust toolchain installation in CI
   - Review platform-specific build logs

### Support Resources

- **GitHub Issues**: Report bugs and request features
- **GitHub Actions Logs**: Detailed pipeline execution logs
- **Documentation**: This file and inline code comments
- **Community**: Discussions in GitHub repository

## Future Enhancements

### Planned Features

- **Release Notes Automation**: Enhanced changelog generation with PR linking
- **Canary Releases**: Automated canary deployments for gradual rollouts
- **Performance Tracking**: Historical performance metrics across releases
- **Dependency Management**: Automated dependency updates with testing

### Contributing to the Pipeline

1. Follow conventional commit message format
2. Test changes with `--dry-run` mode first
3. Update documentation for new features
4. Coordinate changes that affect multiple packages

---

For questions or issues with the release pipeline, please open a GitHub issue with the `release` and `ci/cd` labels.