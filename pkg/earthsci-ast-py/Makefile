# Makefile for earthsci-ast Python package

.PHONY: help build clean install install-dev test lint format typecheck check upload upload-test all

# Virtual environment directory
VENV_DIR = venv
PYTHON = $(VENV_DIR)/bin/python
PIP = $(VENV_DIR)/bin/pip

help:
	@echo "Available commands:"
	@echo "  help          Show this help message"
	@echo "  build         Build package (wheel and source distribution)"
	@echo "  clean         Clean build artifacts"
	@echo "  install       Install package in development mode"
	@echo "  install-dev   Install package with development dependencies"
	@echo "  test          Run tests"
	@echo "  lint          Run linting (ruff)"
	@echo "  format        Format code with ruff"
	@echo "  typecheck     Run static type checking (mypy)"
	@echo "  check         Check package metadata"
	@echo "  upload-test   Upload to TestPyPI"
	@echo "  upload        Upload to PyPI (production)"
	@echo "  all           Clean, format, lint, test, build"

# Create virtual environment if it doesn't exist
$(VENV_DIR)/bin/activate:
	python3 -m venv $(VENV_DIR)
	$(PIP) install --upgrade pip setuptools wheel

# Build package
build: $(VENV_DIR)/bin/activate
	$(PYTHON) -m build

# Clean build artifacts
clean:
	rm -rf build/
	rm -rf dist/
	rm -rf src/*.egg-info/
	find . -type d -name __pycache__ -exec rm -rf {} +
	find . -type f -name "*.pyc" -delete

# Install in development mode
install: $(VENV_DIR)/bin/activate
	$(PIP) install -e .

# Install with development dependencies. Includes the optional `plot` extra so
# the matplotlib-backed SimulationResult.plot path is available in dev/test
# (matplotlib is optional in packaging but the suite may exercise it).
install-dev: $(VENV_DIR)/bin/activate
	$(PIP) install -e .[dev,test,plot]

# Package + test deps in the venv, file-guarded on the pytest binary so `make
# test` self-provisions on a fresh checkout instead of failing on a bare venv.
# The `plot` extra keeps matplotlib present for SimulationResult.plot.
$(VENV_DIR)/bin/pytest: $(VENV_DIR)/bin/activate
	$(PIP) install -e .[test,plot]

# Dev tooling (ruff + mypy from the `dev` extra), file-guarded on the ruff binary
# so repeated lint/format/typecheck runs don't reinstall. ruff and mypy are
# direct (dev) dependencies, so they run from the venv (no uvx needed); the same
# `.[dev]` install provides mypy for the typecheck target below.
$(VENV_DIR)/bin/ruff: $(VENV_DIR)/bin/activate
	$(PIP) install -e .[dev]

# Run tests (mirrors CI: `python -m pytest tests/`; pyproject sets
# pythonpath=["src"], so src/ is importable without setting PYTHONPATH).
test: $(VENV_DIR)/bin/pytest
	$(PYTHON) -m pytest tests/

# Run linting over the package source (ruff).
lint: $(VENV_DIR)/bin/ruff
	$(PYTHON) -m ruff check src/

# Format code
format: $(VENV_DIR)/bin/ruff
	$(PYTHON) -m ruff format src/ tests/

# Static type checking — INFORMATIONAL / non-blocking (leading `-`): mypy
# currently reports many pre-existing errors, so it must not gate the build.
typecheck: $(VENV_DIR)/bin/ruff
	-$(PYTHON) -m mypy src/

# Check package metadata
check: build
	$(PYTHON) -m twine check dist/*

# Upload to TestPyPI
upload-test: build check
	$(PYTHON) -m twine upload --repository testpypi dist/*

# Upload to PyPI
upload: build check
	$(PYTHON) -m twine upload dist/*

# Run all checks and build
all: clean format lint test build check
	@echo "All checks passed! Package is ready for distribution."