# Makefile for earthsci-ast Python package

.PHONY: help build clean install install-dev test lint format check upload upload-test all

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
	@echo "  lint          Run linting (flake8)"
	@echo "  format        Format code with black"
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

# Install with development dependencies
install-dev: $(VENV_DIR)/bin/activate
	$(PIP) install -e .[dev,test]

# Run tests
test: $(VENV_DIR)/bin/activate
	$(PYTHON) -m pytest tests/

# Run linting
lint: $(VENV_DIR)/bin/activate
	$(PYTHON) -m flake8 src/ tests/

# Format code
format: $(VENV_DIR)/bin/activate
	$(PYTHON) -m black src/ tests/

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