#!/bin/bash
# Build script for earthsci-ast Python package

set -e  # Exit on any error

echo "🔨 Building earthsci-ast Python package"

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

echo "📋 Cleaning previous builds..."
rm -rf build/ dist/ src/*.egg-info/

echo "🔧 Building package..."
python -m build

echo "✅ Checking build artifacts..."
python -m twine check dist/*

echo ""
echo "🎉 Build complete!"
echo "📦 Built files:"
ls -la dist/

echo ""
echo "To upload to TestPyPI:"
echo "  python -m twine upload --repository testpypi dist/*"
echo ""
echo "To upload to PyPI (production):"
echo "  python -m twine upload dist/*"