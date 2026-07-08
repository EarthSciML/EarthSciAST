# Build and Distribution Guide

This document describes how to build and distribute the `earthsci-ast` Python package.

## Quick Start

```bash
# Install development dependencies
make install-dev

# Build the package
make build

# Run all checks (format, lint, test, build)
make all
```

## Build System Overview

The package uses modern Python packaging with:
- **pyproject.toml**: Modern package configuration
- **setuptools**: Build backend with PEP 517/518 support
- **build**: Modern build tool
- **twine**: Secure PyPI uploading
- **GitHub Actions**: Automated CI/CD

## Development Setup

1. **Create virtual environment and install dependencies:**
   ```bash
   make install-dev
   ```

2. **Install package in development mode:**
   ```bash
   make install
   ```

## Building the Package

### Using Make (Recommended)
```bash
# Clean build
make clean

# Build package (creates wheel and source distribution)
make build

# Build with all quality checks
make all
```

### Using Build Script
```bash
./scripts/build.sh
```

### Manual Build
```bash
source venv/bin/activate
python -m build
```

## Quality Checks

### Code Formatting
```bash
make format    # Format with black
```

### Linting
```bash
make lint      # Check with flake8
```

### Testing
```bash
make test      # Run pytest
```

### Package Validation
```bash
make check     # Validate with twine
```

## Publishing

### To TestPyPI (Safe Testing)
```bash
# Using script (recommended)
./scripts/publish.sh test

# Using make
make upload-test

# Manual
python -m twine upload --repository testpypi dist/*
```

### To PyPI (Production)
```bash
# Using script with confirmation
./scripts/publish.sh prod

# Using make
make upload

# Manual
python -m twine upload dist/*
```

## Authentication

### Option 1: API Tokens (Recommended)
1. Create API tokens at:
   - PyPI: https://pypi.org/manage/account/token/
   - TestPyPI: https://test.pypi.org/manage/account/token/

2. Configure `~/.pypirc`:
   ```bash
   cp .pypirc.template ~/.pypirc
   chmod 600 ~/.pypirc
   # Edit ~/.pypirc with your tokens
   ```

### Option 2: Environment Variables
```bash
export TWINE_USERNAME=__token__
export TWINE_PASSWORD=pypi-your-api-token
```

## Continuous Integration

The project includes GitHub Actions workflows:

### Triggers
- **Push to main/develop**: Runs tests and publishes to TestPyPI
- **Pull requests**: Runs tests only
- **Releases**: Publishes to production PyPI

### Workflow Features
- Tests on Python 3.8-3.12
- Code quality checks (flake8)
- Coverage reporting (codecov)
- Automatic publishing with trusted publishing (no tokens needed)

## Version Management

Update version in `pyproject.toml`:
```toml
[project]
version = "0.2.0"  # Update this
```

For releases:
1. Update version in `pyproject.toml`
2. Commit and push changes
3. Create a GitHub release/tag
4. GitHub Actions will automatically publish to PyPI

## Package Structure

```
earthsci_ast/
├── src/
│   └── earthsci_ast/          # Main package code
├── tests/                   # Test files
├── dist/                    # Built distributions
├── scripts/                 # Build automation scripts
│   ├── build.sh            # Build script
│   └── publish.sh          # Publishing script
├── pyproject.toml          # Modern package config
├── Makefile                # Build automation
├── BUILD.md                # This document
└── README.md               # Package documentation
```

## Troubleshooting

### Common Issues

**Build fails with missing dependencies:**
```bash
make install-dev  # Ensure dev dependencies are installed
```

**Upload fails with 403 error:**
- Check your API token is correct
- Ensure you have upload permissions
- Verify package name is available

**Tests fail:**
```bash
make test  # Run tests to see specific failures
```

**Import errors after installation:**
```bash
pip install -e .  # Reinstall in development mode
```

### Debug Mode

For detailed build output:
```bash
python -m build --verbose
```

For twine upload debugging:
```bash
python -m twine upload --verbose dist/*
```

## Dependencies

### Runtime Dependencies
- jsonschema>=4.0
- sympy>=1.9
- pint>=0.20
- numpy>=1.20
- scipy>=1.7
- matplotlib>=3.5
- xarray>=0.20
- netcdf4>=1.5

### Development Dependencies
- pytest>=6.0
- pytest-cov>=3.0
- black>=22.0
- flake8>=4.0
- mypy>=0.990
- build>=0.8
- twine>=4.0

## Security

- Never commit API tokens or credentials
- Use API tokens instead of passwords
- Keep `.pypirc` file private (chmod 600)
- Use TestPyPI for testing uploads

## Support

For build system issues:
1. Check this documentation
2. Review GitHub Actions logs
3. Open an issue with build output