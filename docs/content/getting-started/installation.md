# Installation & Setup

Get the ESM format libraries installed and running on your system. Choose the language(s) that best fit your workflow.

## Quick Install

### Julia
```bash
julia -e 'using Pkg; Pkg.add(url="https://github.com/EarthSciML/EarthSciAST", subdir="pkg/EarthSciAST.jl")'
```

### TypeScript/JavaScript
```bash
npm install @earthsciml/ast
```

### Python
```bash
pip install earthsci-ast  # When available on PyPI
# Or install from source:
git clone https://github.com/EarthSciML/EarthSciAST.git
cd EarthSciAST/pkg/earthsci-ast-py
pip install -e .
```

### Rust
```bash
cargo install earthsci-ast --features cli
# Or add to Cargo.toml:
# [dependencies]
# earthsci-ast = "0.1.0"
```

## Detailed Installation

### System Requirements

**Minimum Requirements:**
- **Julia**: Version 1.8 or later
- **Node.js**: Version 16 or later (for TypeScript/JavaScript)
- **Python**: Version 3.8 or later
- **Rust**: Version 1.65 or later

**Recommended:**
- **Julia**: Version 1.9+ for best ModelingToolkit integration
- **Node.js**: Version 18+ for ESM support
- **Python**: Version 3.10+ for latest features
- **Rust**: Version 1.70+ for latest optimization features

### Julia Installation

#### From GitHub (Recommended)
```julia
using Pkg
Pkg.add(url="https://github.com/EarthSciML/EarthSciAST", subdir="pkg/EarthSciAST.jl")
```

#### Development Setup
```julia
using Pkg
Pkg.develop(url="https://github.com/EarthSciML/EarthSciAST", subdir="pkg/EarthSciAST.jl")
```

#### Verify Installation
```julia
using EarthSciAST
println("EarthSciAST.jl installed successfully!")

# Test basic functionality
esm_data = """{"esm": "0.1.0", "metadata": {"name": "Test"}}"""
esm_file = parse_esm(esm_data)
println("Loaded test model: ", esm_file.metadata.name)
```

### TypeScript/JavaScript Installation

#### NPM
```bash
npm install @earthsciml/ast
```

#### Yarn
```bash
yarn add @earthsciml/ast
```

#### Pnpm
```bash
pnpm add @earthsciml/ast
```

#### CDN (Browser)
```html
<!-- ES Modules -->
<script type="module">
  import { load, validate } from 'https://unpkg.com/@earthsciml/ast/dist/esm/index.js';
</script>

<!-- UMD (older browsers) -->
<script src="https://unpkg.com/@earthsciml/ast/dist/umd/index.js"></script>
```

#### Verify Installation
```javascript
// Node.js/CommonJS
const { load, validate } = require('@earthsciml/ast');

// ES Modules
import { load, validate } from '@earthsciml/ast';

// Test functionality
const esmData = '{"esm": "0.1.0", "metadata": {"name": "Test"}}';
const esmFile = load(esmData);
console.log('Loaded test model:', esmFile.metadata.name);
```

### Python Installation

#### From PyPI (when available)
```bash
pip install earthsci-ast
```

#### From Source
```bash
git clone https://github.com/EarthSciML/EarthSciAST.git
cd EarthSciAST/pkg/earthsci-ast-py
pip install -e .
```

#### With Optional Dependencies
```bash
# For visualization support
pip install earthsci-ast[viz]

# For symbolic computation
pip install earthsci-ast[symbolic]

# All optional features
pip install earthsci-ast[all]
```

#### Virtual Environment Setup
```bash
# Create virtual environment
python -m venv esm_env
source esm_env/bin/activate  # Linux/macOS
# esm_env\Scripts\activate   # Windows

# Install package
pip install earthsci-ast
```

#### Conda Environment
```bash
# Create conda environment
conda create -n esm_env python=3.10
conda activate esm_env

# Install dependencies
conda install numpy scipy matplotlib sympy

# Install ESM format
pip install earthsci-ast
```

#### Verify Installation
```python
import earthsci_ast
print("earthsci-ast installed successfully!")

# Test basic functionality
esm_data = '{"esm": "0.1.0", "metadata": {"name": "Test"}}'
esm_file = earthsci_ast.load_esm(esm_data)
print(f"Loaded test model: {esm_file.metadata.name}")
```

### Rust Installation

#### CLI Tool
```bash
# Install from GitHub
cargo install --git https://github.com/EarthSciML/EarthSciAST \
  --root . earthsci-ast --features cli

# Or clone and install locally
git clone https://github.com/EarthSciML/EarthSciAST.git
cd EarthSciAST/pkg/earthsci-ast-rs
cargo install --path . --features cli
```

#### Library Dependency
Add to your `Cargo.toml`:
```toml
[dependencies]
earthsci-ast = { git = "https://github.com/EarthSciML/EarthSciAST", package = "earthsci-ast" }

# Or with specific features
earthsci-ast = { git = "https://github.com/EarthSciML/EarthSciAST", package = "earthsci-ast", features = ["wasm"] }
```

#### WebAssembly
```bash
# Install wasm-pack
cargo install wasm-pack

# Clone repository
git clone https://github.com/EarthSciML/EarthSciAST.git
cd EarthSciAST/pkg/earthsci-ast-rs

# Build for web
wasm-pack build --target web --features wasm
```

#### Verify Installation
```bash
# CLI tool
esm --version
esm validate --help

# Test functionality
echo '{"esm": "0.1.0", "metadata": {"name": "Test"}}' > test.esm
esm validate test.esm
```

```rust
// Library usage
use earthsci_ast::{load, validate};

fn main() {
    let esm_data = r#"{"esm": "0.1.0", "metadata": {"name": "Test"}}"#;
    let esm_file = load(esm_data).unwrap();
    println!("Loaded test model: {}", esm_file.metadata.name);
}
```

## Multi-Language Setup

For comprehensive ESM format development, you may want multiple languages:

### Complete Development Environment
```bash
# 1. Install Julia
curl -fsSL https://install.julialang.org | sh
julia -e 'using Pkg; Pkg.add(url="https://github.com/EarthSciML/EarthSciAST", subdir="pkg/EarthSciAST.jl")'

# 2. Install Node.js and package
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt-get install -y nodejs
npm install -g @earthsciml/ast

# 3. Install Python and package
sudo apt-get install python3 python3-pip
pip install earthsci-ast

# 4. Install Rust and CLI
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
cargo install earthsci-ast --features cli
```

### Docker Environment
```dockerfile
FROM ubuntu:22.04

# Install system dependencies
RUN apt-get update && apt-get install -y \
    curl git build-essential \
    python3 python3-pip \
    nodejs npm

# Install Julia
RUN curl -fsSL https://install.julialang.org | sh

# Install Rust
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

# Install ESM packages
RUN pip install earthsci-ast
RUN npm install -g @earthsciml/ast
RUN cargo install earthsci-ast --features cli
RUN julia -e 'using Pkg; Pkg.add(url="https://github.com/EarthSciML/EarthSciAST", subdir="pkg/EarthSciAST.jl")'

WORKDIR /workspace
```

## Troubleshooting

### Common Issues

#### Julia Package Installation
```julia
# If you get package conflicts
using Pkg
Pkg.resolve()

# If you need to update dependencies
Pkg.update()

# Clear package cache if needed
Pkg.gc()
```

#### Node.js Module Resolution
```bash
# Clear npm cache
npm cache clean --force

# Delete node_modules and reinstall
rm -rf node_modules package-lock.json
npm install
```

#### Python Installation Issues
```bash
# Upgrade pip first
pip install --upgrade pip setuptools wheel

# Install with verbose output for debugging
pip install -v earthsci-ast

# Use --user if permissions issues
pip install --user earthsci-ast
```

#### Rust Compilation Errors
```bash
# Update Rust toolchain
rustup update

# Clear cargo cache
cargo clean

# Install with verbose output
cargo install --verbose earthsci-ast --features cli
```

### Platform-Specific Notes

#### Windows
- Use PowerShell or Command Prompt with Administrator privileges
- Install Visual Studio Build Tools for Rust compilation
- Use Python from Microsoft Store or python.org installer

#### macOS
- Install Xcode Command Line Tools: `xcode-select --install`
- Consider using Homebrew for Node.js and Python
- M1/M2 Macs: Ensure native ARM64 builds when possible

#### Linux
- Install build essentials: `sudo apt-get install build-essential`
- For Ubuntu/Debian, use apt for system packages
- For CentOS/RHEL, use yum/dnf for system packages

### Version Compatibility

| ESM Format | Julia Package | TypeScript | Python | Rust CLI |
|------------|--------------|------------|---------|----------|
| 0.1.0      | 0.1.0        | 0.1.0     | 0.1.0   | 0.1.0    |

All packages are designed to be compatible with ESM Format version 0.1.0. Cross-language compatibility is maintained through the shared JSON schema.

## Next Steps

After installation:
1. **Try the Quick Start** — [Quick Start Guide](quick-start.md)
2. **Choose Your Language** — Jump to your language-specific guide:
   - [Julia](julia.md) — For simulation and scientific computing
   - [TypeScript](typescript.md) — For web applications
   - [Python](python.md) — For data analysis and visualization
   - [Rust](rust.md) — For performance-critical applications
3. **Explore Examples** — Check out [Real-World Examples](../examples/)

## Getting Help

- **Installation Issues** — Check the [Troubleshooting Guide](../troubleshooting/)
- **Language-Specific Problems** — See individual language guides
- **Bug Reports** — File issues in the [GitHub repository](https://github.com/EarthSciML/EarthSciAST)

Ready to get started? Head to the [Quick Start Guide](quick-start.md)!