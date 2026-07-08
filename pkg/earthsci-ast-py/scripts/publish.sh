#!/bin/bash
# Publishing script for earthsci-ast Python package

set -e  # Exit on any error

echo "🚀 Publishing earthsci-ast Python package"

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(dirname "$SCRIPT_DIR")"

# Change to package directory
cd "$PACKAGE_DIR"

# Check if virtual environment exists
if [ ! -d "venv" ]; then
    echo "❌ Virtual environment not found. Please run 'make install-dev' first."
    exit 1
fi

# Activate virtual environment
source venv/bin/activate

# Check if dist directory exists
if [ ! -d "dist" ]; then
    echo "❌ No built packages found. Please run 'make build' first."
    exit 1
fi

# Parse command line argument for repository
REPOSITORY="pypi"
if [ "$1" = "test" ]; then
    REPOSITORY="testpypi"
    echo "📤 Uploading to TestPyPI..."
elif [ "$1" = "prod" ] || [ "$1" = "production" ]; then
    REPOSITORY="pypi"
    echo "📤 Uploading to PyPI (production)..."
elif [ -n "$1" ]; then
    echo "❌ Unknown repository: $1"
    echo "Usage: $0 [test|prod]"
    exit 1
else
    # Default to TestPyPI for safety
    REPOSITORY="testpypi"
    echo "📤 No repository specified, defaulting to TestPyPI..."
fi

echo "🔍 Checking package integrity..."
python -m twine check dist/*

echo "📋 Package contents:"
ls -la dist/

# Confirm before uploading to production PyPI
if [ "$REPOSITORY" = "pypi" ]; then
    echo ""
    echo "⚠️  WARNING: You are about to upload to production PyPI!"
    echo "This action cannot be undone. Are you sure? (y/N)"
    read -r response
    if [ "$response" != "y" ] && [ "$response" != "Y" ]; then
        echo "❌ Upload cancelled."
        exit 1
    fi
fi

# Upload
if [ "$REPOSITORY" = "testpypi" ]; then
    echo "📤 Uploading to TestPyPI..."
    python -m twine upload --repository testpypi dist/*
    echo ""
    echo "✅ Upload to TestPyPI complete!"
    echo "🔗 View at: https://test.pypi.org/project/earthsci-ast/"
    echo ""
    echo "To install from TestPyPI:"
    echo "  pip install --index-url https://test.pypi.org/simple/ earthsci-ast"
else
    echo "📤 Uploading to PyPI (production)..."
    python -m twine upload dist/*
    echo ""
    echo "✅ Upload to PyPI complete!"
    echo "🔗 View at: https://pypi.org/project/earthsci-ast/"
    echo ""
    echo "To install:"
    echo "  pip install earthsci-ast"
fi