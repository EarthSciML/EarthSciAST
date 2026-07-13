# EarthSciAST Dependency Management System

This directory contains a comprehensive dependency management system for the EarthSciAST multi-language workspace, supporting TypeScript, Python, and Julia packages.

## Overview

The dependency management system provides:

- **Cross-language dependency resolution** - Manages dependencies across TypeScript, Python, and Julia packages
- **Version compatibility checking** - Detects and reports version conflicts between packages
- **Dependency tree analysis** - Visualizes and analyzes dependency relationships
- **Automatic conflict resolution** - Suggests compatible version resolutions
- **Lockfile generation** - Creates and maintains consistent dependency snapshots
- **Workspace-wide updates** - Coordinates updates across all package types

## Files

- `deps` - Unified CLI wrapper for all dependency management operations
- `dependency-manager.js` - TypeScript/JavaScript package dependency manager
- `dependency_resolver.py` - Python package dependency resolver
- `julia_deps.jl` - Julia package dependency manager
- `workspace.json` - Workspace configuration defining all packages

## Quick Start

### Check for dependency conflicts across all packages:
```bash
./scripts/deps check
```

### Install dependencies for all packages:
```bash
./scripts/deps install
```

### Update dependencies for a specific package:
```bash
./scripts/deps update esm-format-js
```

### Generate comprehensive dependency report:
```bash
./scripts/deps report
```

## Commands

### General Commands

- `./scripts/deps check [type]` - Check for dependency conflicts
- `./scripts/deps install [package]` - Install dependencies
- `./scripts/deps update [package]` - Update dependencies
- `./scripts/deps resolve [type]` - Show conflict resolutions
- `./scripts/deps report` - Generate comprehensive report
- `./scripts/deps tree` - Show dependency tree
- `./scripts/deps list` - List all workspace packages

### Package Type Filters

You can filter operations by package type:
- `js`, `typescript` - TypeScript/JavaScript packages
- `py`, `python` - Python packages
- `jl`, `julia` - Julia packages

### Examples

```bash
# Check only Python packages
./scripts/deps check py

# Install dependencies for TypeScript packages
./scripts/deps install esm-format-js

# Update all Julia packages
./scripts/deps update esm-format-jl

# Generate conflict resolutions for all packages
./scripts/deps resolve
```

## Package Configuration

The `workspace.json` file defines all packages in the workspace. It records where
each package lives and how it is published; per-package versions are not
duplicated here, they live in each package's own manifest (`Project.toml`,
`package.json`, `pyproject.toml`, `Cargo.toml`).

```json
{
  "name": "EarthSciAST",
  "workspaces": {
    "packages": ["pkg/*"]
  },
  "dependencies": {
    "earthsci-ast-jl": {
      "path": "./pkg/EarthSciAST.jl",
      "type": "julia",
      "julia_name": "EarthSciAST",
      "registry": "General"
    },
    "earthsci-ast-ts": {
      "path": "./pkg/earthsci-ast-ts",
      "type": "typescript",
      "npm_name": "@earthsciml/ast",
      "registry": "https://registry.npmjs.org"
    },
    "earthsci-ast-py": {
      "path": "./pkg/earthsci-ast-py",
      "type": "python",
      "pypi_name": "earthsci-ast",
      "registry": "https://pypi.org"
    }
  }
}
```

`workspace.json` is edited by hand. CI must not write it: a workflow that
commits it back to `main` will conflict with every developer push.

## TypeScript Package Manager

Located in `dependency-manager.js`, this handles:

- `package.json` parsing and validation
- npm/yarn lock file management
- Version conflict detection
- Dependency tree analysis
- Automatic updates via npm/yarn

### Usage:
```bash
node scripts/dependency-manager.js <command> [options]

Commands:
  list        List all packages
  tree        Show dependency tree
  conflicts   Check for version conflicts
  install     Install dependencies
  update      Update dependencies
  report      Generate compatibility report
```

## Python Dependency Resolver

Located in `dependency_resolver.py`, this provides:

- `pyproject.toml` parsing
- Version compatibility analysis
- Virtual environment management
- pip-tools integration for lockfile generation
- Dependency conflict resolution

### Requirements:
```bash
pip install tomli packaging
```

### Usage:
```bash
python scripts/dependency_resolver.py <command> [options]

Commands:
  check       Check for version conflicts
  resolve     Show suggested resolutions
  update      Update package dependencies
  lockfile    Generate/update lockfile
```

## Julia Dependency Manager

Located in `julia_deps.jl`, this handles:

- `Project.toml` and `Manifest.toml` management
- Julia package ecosystem integration
- Compatibility constraint analysis
- Pkg.jl integration for updates

### Usage:
```bash
julia scripts/julia_deps.jl <command> [options]

Commands:
  check       Check for version conflicts
  resolve     Show suggested resolutions
  install     Install package dependencies
  update      Update package dependencies
  report      Generate compatibility report
```

## Dependency Report Format

The system generates comprehensive JSON reports with:

```json
{
  "timestamp": "2026-02-15T10:30:00Z",
  "workspace": "EarthSciAST",
  "reports": {
    "typescript": {
      "packages": 1,
      "conflicts": 0,
      "tree": { ... },
      "recommendations": []
    },
    "julia": {
      "julia_packages": 1,
      "conflicts": 0,
      "package_details": { ... },
      "recommendations": []
    }
  }
}
```

## Integration with CI/CD

The dependency management system integrates with continuous integration:

### GitHub Actions Example:
```yaml
- name: Check Dependencies
  run: ./scripts/deps check

- name: Install Dependencies
  run: ./scripts/deps install

- name: Generate Dependency Report
  run: ./scripts/deps report
```

## Troubleshooting

### Common Issues:

1. **Python virtual environment issues**
   - The system automatically creates virtual environments for Python packages
   - Ensure Python 3.8+ is installed

2. **Julia package resolution failures**
   - Run `julia -e "using Pkg; Pkg.resolve()"` in the package directory
   - Check compatibility constraints in `Project.toml`

3. **TypeScript dependency conflicts**
   - Check `package-lock.json` is committed
   - Use `npm audit` for security vulnerabilities

4. **Missing dependencies**
   - Ensure all required package managers are installed (node, python3, julia)
   - Check that workspace.json is properly configured

### Logs and Debugging:

- Use `./scripts/deps report` to generate detailed diagnostics
- Check individual package manager logs in their respective directories
- Enable verbose output with package manager specific flags

## Contributing

When adding new packages to the workspace:

1. Update `workspace.json` with package information
2. Ensure package follows naming conventions
3. Run `./scripts/deps check` to verify no conflicts
4. Update this README if adding new package types

For bug reports or feature requests, please use the project's issue tracker.