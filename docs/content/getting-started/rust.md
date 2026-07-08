# Getting Started with EarthSci Toolkit in Rust

The Rust implementation provides high-performance parsing, validation, and CLI tools with WebAssembly support for web deployment. It's ideal for production tools, system integration, and performance-critical applications.

## Installation

### As a Library
Add to your `Cargo.toml`:
```toml
[dependencies]
earthsci-ast = "0.1.0"
```

### CLI Tool from Source
```bash
git clone https://github.com/EarthSciML/EarthSciAST.git
cd EarthSciAST/pkg/earthsci-ast-rs
cargo install --path . --features cli
```

### WebAssembly Package
```bash
# Install wasm-pack if you haven't already
cargo install wasm-pack

# Build WASM package
cd pkg/earthsci-ast-rs
wasm-pack build --target web --features wasm
```

## Core Capabilities

The Rust implementation provides **Core + CLI** tier capabilities:
- ✅ High-performance parsing and serialization
- ✅ Comprehensive validation with detailed error reporting
- ✅ Mathematical expression manipulation
- ✅ CLI tool for validation, conversion, and analysis
- ✅ WebAssembly compilation for web use
- ✅ Cross-platform binary distribution
- ✅ Zero-copy parsing for large files

## Basic Library Usage

### Loading and Validating ESM Files

```rust
use earthsci_ast::{load, save, validate, EsmFile};
use std::fs;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Load from file
    let content = fs::read_to_string("model.esm")?;
    let esm_file: EsmFile = load(&content)?;
    println!("Loaded: {}", esm_file.metadata.name);

    // Validate loaded file
    let validation_result = validate(&esm_file);
    if validation_result.valid {
        println!("✓ Valid ESM file");
    } else {
        for error in validation_result.errors {
            eprintln!("✗ {}: {}", error.path, error.message);
        }
    }

    // Save back to JSON
    let json_output = save(&esm_file)?;
    fs::write("output.esm", json_output)?;

    Ok(())
}
```

### Working with Expressions

```rust
use earthsci_ast::{Expression, parse_expression, to_unicode, to_latex, substitute, free_variables};
use std::collections::HashMap;

fn expression_example() -> Result<(), Box<dyn std::error::Error>> {
    // Parse mathematical expression
    let expr_json = r#"{"op": "+", "args": ["x", {"op": "^", "args": ["y", "2"]}]}"#;
    let expr: Expression = parse_expression(expr_json)?;

    // Pretty-print in different formats
    println!("Unicode: {}", to_unicode(&expr));    // x + y²
    println!("LaTeX: {}", to_latex(&expr));        // x + y^{2}

    // Analyze expression
    let variables = free_variables(&expr);           // vec!["x", "y"]
    println!("Free variables: {:?}", variables);

    // Substitute values
    let mut substitutions = HashMap::new();
    substitutions.insert("x".to_string(), "2".to_string());
    substitutions.insert("y".to_string(), "t".to_string());

    let substituted = substitute(&expr, &substitutions);
    println!("After substitution: {}", to_unicode(&substituted)); // 2 + t²

    Ok(())
}
```

## CLI Tool Usage

The CLI tool provides comprehensive functionality for working with ESM files:

### File Validation
```bash
# Validate a single file
esm validate model.esm

# Validate multiple files
esm validate *.esm

# Validate with detailed output
esm validate model.esm --verbose

# Validate directory recursively
esm validate models/ --recursive
```

### Format Conversion
```bash
# Convert to compact JSON
esm convert model.esm -o compact.json -f compact-json

# Convert to pretty-printed JSON
esm convert model.esm -o pretty.json -f pretty-json

# Convert to YAML (if feature enabled)
esm convert model.esm -o model.yaml -f yaml

# Batch conversion
esm convert input_dir/ -o output_dir/ -f compact-json --recursive
```

### Expression Pretty-Printing
```bash
# Show all expressions in Unicode
esm pretty-print model.esm -f unicode

# Show expressions in LaTeX
esm pretty-print model.esm -f latex

# Show specific model's expressions
esm pretty-print model.esm --model atmospheric_chemistry

# Export to file
esm pretty-print model.esm -f latex -o expressions.tex
```

### File Information and Analysis
```bash
# Basic file information
esm info model.esm

# Detailed statistics
esm stats model.esm

# Dependency analysis
esm deps model.esm

# Variable usage analysis
esm analyze variables model.esm

# Expression complexity analysis
esm analyze complexity model.esm
```

### Schema Operations
```bash
# Generate JSON schema
esm schema --output esm-schema.json

# Validate against custom schema
esm validate model.esm --schema custom-schema.json

# Schema version information
esm schema --version
```

## Advanced Library Usage

### Error Handling

```rust
use earthsci_ast::{EsmError, ValidationError, load, validate};

fn robust_loading(filename: &str) -> Result<(), EsmError> {
    let content = std::fs::read_to_string(filename)
        .map_err(|e| EsmError::Io(e))?;

    match load(&content) {
        Ok(esm_file) => {
            let validation = validate(&esm_file);
            if !validation.valid {
                for error in validation.errors {
                    match error.error_type {
                        ValidationError::SchemaViolation => {
                            eprintln!("Schema error at {}: {}", error.path, error.message);
                        },
                        ValidationError::UnitMismatch => {
                            eprintln!("Unit mismatch at {}: {}", error.path, error.message);
                        },
                        ValidationError::UnresolvedReference => {
                            eprintln!("Unresolved reference at {}: {}", error.path, error.message);
                        }
                    }
                }
                return Err(EsmError::Validation(validation));
            }
            println!("Successfully loaded and validated {}", filename);
        },
        Err(e) => {
            eprintln!("Failed to parse {}: {}", filename, e);
            return Err(e);
        }
    }
    Ok(())
}
```

### Performance Optimization

```rust
use earthsci_ast::{EsmFile, load_streaming, validate_streaming};
use std::fs::File;
use std::io::BufReader;

fn handle_large_file(filename: &str) -> Result<(), Box<dyn std::error::Error>> {
    let file = File::open(filename)?;
    let reader = BufReader::new(file);

    // Stream parsing for large files (low memory usage)
    let esm_file = load_streaming(reader)?;

    // Streaming validation (processes in chunks)
    let validation = validate_streaming(&esm_file)?;

    if validation.valid {
        println!("Large file validated successfully");
    }

    Ok(())
}

// Zero-copy parsing for read-only access
fn zero_copy_analysis(content: &str) -> Result<(), Box<dyn std::error::Error>> {
    let esm_file = earthsci_ast::parse_borrowed(content)?;

    // Work with borrowed data (no allocations for string data)
    println!("Model name: {}", esm_file.metadata.name);
    println!("Number of models: {}", esm_file.models.len());

    // esm_file references content, so content must remain valid
    Ok(())
}
```

### Custom Validation Rules

```rust
use earthsci_ast::{EsmFile, ValidationResult, ValidationError, Validator};

struct CustomValidator;

impl Validator for CustomValidator {
    fn validate(&self, esm_file: &EsmFile) -> ValidationResult {
        let mut errors = Vec::new();

        // Custom rule: All model names must be lowercase
        for (name, _) in &esm_file.models {
            if name != &name.to_lowercase() {
                errors.push(ValidationError {
                    path: format!("models.{}", name),
                    message: "Model names must be lowercase".to_string(),
                    error_type: ValidationError::CustomRule,
                });
            }
        }

        // Custom rule: Must have at least one state variable per model
        for (name, model) in &esm_file.models {
            let state_vars = model.variables.iter()
                .filter(|v| v.var_type == "state")
                .count();

            if state_vars == 0 {
                errors.push(ValidationError {
                    path: format!("models.{}.variables", name),
                    message: "Models must have at least one state variable".to_string(),
                    error_type: ValidationError::CustomRule,
                });
            }
        }

        ValidationResult {
            valid: errors.is_empty(),
            errors,
        }
    }
}

fn main() {
    let esm_file = load(&content).unwrap();

    // Use custom validator
    let custom_validator = CustomValidator;
    let custom_result = custom_validator.validate(&esm_file);

    // Combine with standard validation
    let standard_result = validate(&esm_file);

    if custom_result.valid && standard_result.valid {
        println!("Passed all validation checks");
    }
}
```

## WebAssembly Integration

### Building for WASM

```bash
# Install wasm-pack
cargo install wasm-pack

# Build for web target
wasm-pack build --target web --features wasm

# Build for Node.js target
wasm-pack build --target nodejs --features wasm

# Build for bundler target (webpack, etc.)
wasm-pack build --target bundler --features wasm
```

### Using in JavaScript/TypeScript

```javascript
import init, { load, validate, to_unicode } from './pkg/earthsci_ast.js';

async function main() {
    // Initialize the WASM module
    await init();

    // Use Rust functions from JavaScript
    const esmData = '{"esm": "0.1.0", "metadata": {"name": "Test"}}';

    try {
        const esmFile = load(esmData);
        console.log('Loaded:', esmFile.metadata.name);

        const validation = validate(esmFile);
        if (validation.valid) {
            console.log('✓ Valid ESM file');
        } else {
            validation.errors.forEach(error => {
                console.error(`✗ ${error.path}: ${error.message}`);
            });
        }

        // Pretty-print expressions
        if (esmFile.models) {
            Object.values(esmFile.models).forEach(model => {
                model.equations?.forEach(eq => {
                    const unicode = to_unicode(eq.rhs);
                    console.log(`${eq.lhs} = ${unicode}`);
                });
            });
        }

    } catch (error) {
        console.error('Error:', error);
    }
}

main();
```

### Web Application Integration

```html
<!DOCTYPE html>
<html>
<head>
    <title>ESM Format WASM Demo</title>
</head>
<body>
    <input type="file" id="file-input" accept=".esm,.json">
    <div id="output"></div>
    <div id="errors"></div>

    <script type="module">
        import init, { load, validate, to_unicode } from './pkg/earthsci_ast.js';

        await init();

        document.getElementById('file-input').addEventListener('change', async (e) => {
            const file = e.target.files[0];
            if (!file) return;

            const content = await file.text();
            const outputDiv = document.getElementById('output');
            const errorsDiv = document.getElementById('errors');

            try {
                const esmFile = load(content);
                const validation = validate(esmFile);

                if (validation.valid) {
                    outputDiv.innerHTML = `
                        <h3>${esmFile.metadata.name}</h3>
                        <p>${esmFile.metadata.description || ''}</p>
                        <p>Models: ${Object.keys(esmFile.models || {}).length}</p>
                    `;
                    errorsDiv.innerHTML = '<p style="color: green;">✓ Valid ESM file</p>';
                } else {
                    errorsDiv.innerHTML = validation.errors
                        .map(err => `<p style="color: red;">✗ ${err.path}: ${err.message}</p>`)
                        .join('');
                }
            } catch (error) {
                errorsDiv.innerHTML = `<p style="color: red;">Parse error: ${error}</p>`;
            }
        });
    </script>
</body>
</html>
```

## Cross-Platform Distribution

### GitHub Actions Build Pipeline

```yaml
name: Build and Release

on:
  push:
    tags: ['v*']

jobs:
  build:
    strategy:
      matrix:
        os: [ubuntu-latest, windows-latest, macos-latest]
        include:
          - os: ubuntu-latest
            target: x86_64-unknown-linux-gnu
            name: linux-x64
          - os: windows-latest
            target: x86_64-pc-windows-msvc
            name: windows-x64
          - os: macos-latest
            target: x86_64-apple-darwin
            name: macos-x64

    runs-on: ${{ matrix.os }}

    steps:
    - uses: actions/checkout@v3
    - uses: actions-rs/toolchain@v1
      with:
        toolchain: stable
        target: ${{ matrix.target }}

    - name: Build
      run: cargo build --release --target ${{ matrix.target }} --features cli

    - name: Package
      run: |
        mkdir dist
        cp target/${{ matrix.target }}/release/esm* dist/
        tar -czf earthsci-ast-${{ matrix.name }}.tar.gz -C dist .

    - name: Upload
      uses: actions/upload-artifact@v4
      with:
        name: earthsci-ast-${{ matrix.name }}
        path: earthsci-ast-${{ matrix.name }}.tar.gz
```

### Docker Integration

```dockerfile
# Dockerfile
FROM rust:1.70 as builder

WORKDIR /app
COPY . .
RUN cargo build --release --features cli

FROM debian:bullseye-slim

RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*

COPY --from=builder /app/target/release/esm /usr/local/bin/

ENTRYPOINT ["esm"]
```

```bash
# Build and run
docker build -t earthsci-ast .
docker run --rm -v $(pwd):/data earthsci-ast validate /data/model.esm
```

## Testing and Benchmarking

### Unit Testing

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_valid_esm_loads() {
        let esm_data = r#"
        {
            "esm": "0.1.0",
            "metadata": {
                "name": "Test Model"
            }
        }"#;

        let esm_file = load(esm_data).unwrap();
        assert_eq!(esm_file.metadata.name, "Test Model");
    }

    #[test]
    fn test_validation_catches_errors() {
        let invalid_esm = r#"
        {
            "esm": "0.1.0",
            "metadata": {
                "name": "Test"
            },
            "models": {
                "test": {
                    "variables": [],
                    "equations": [
                        {
                            "lhs": "x",
                            "rhs": {"op": "+", "args": ["y", "z"]}
                        }
                    ]
                }
            }
        }"#;

        let esm_file = load(invalid_esm).unwrap();
        let validation = validate(&esm_file);
        assert!(!validation.valid);
        assert!(!validation.errors.is_empty());
    }

    #[test]
    fn test_expression_substitution() {
        let expr = Expression::Binary {
            op: "+".to_string(),
            left: Box::new(Expression::Variable("x".to_string())),
            right: Box::new(Expression::Variable("y".to_string())),
        };

        let mut substitutions = HashMap::new();
        substitutions.insert("x".to_string(), "2".to_string());

        let result = substitute(&expr, &substitutions);
        // Test that x was replaced with 2
        match result {
            Expression::Binary { left, .. } => {
                match **left {
                    Expression::Number(n) => assert_eq!(n, "2"),
                    _ => panic!("Expected number after substitution"),
                }
            },
            _ => panic!("Expected binary expression"),
        }
    }
}
```

### Benchmarking

```rust
use criterion::{black_box, criterion_group, criterion_main, Criterion};
use earthsci_ast::{load, validate};

fn bench_load_large_file(c: &mut Criterion) {
    let large_esm = generate_large_test_file(1000); // 1000 models

    c.bench_function("load_large_file", |b| {
        b.iter(|| {
            let esm_file = load(black_box(&large_esm)).unwrap();
            black_box(esm_file);
        });
    });
}

fn bench_validation(c: &mut Criterion) {
    let esm_data = std::fs::read_to_string("test_data/complex_model.esm").unwrap();
    let esm_file = load(&esm_data).unwrap();

    c.bench_function("validate_complex", |b| {
        b.iter(|| {
            let result = validate(black_box(&esm_file));
            black_box(result);
        });
    });
}

criterion_group!(benches, bench_load_large_file, bench_validation);
criterion_main!(benches);
```

## Integration Patterns

### Configuration-Driven Validation

```rust
use serde::Deserialize;

#[derive(Deserialize)]
struct ValidationConfig {
    strict_units: bool,
    allow_unused_variables: bool,
    max_equation_complexity: usize,
}

fn validate_with_config(esm_file: &EsmFile, config: &ValidationConfig) -> ValidationResult {
    let mut validator = StandardValidator::new();

    if config.strict_units {
        validator.enable_strict_unit_checking();
    }

    if !config.allow_unused_variables {
        validator.enable_unused_variable_detection();
    }

    validator.set_max_equation_complexity(config.max_equation_complexity);

    validator.validate(esm_file)
}
```

### Pipeline Integration

```rust
use std::process::{Command, Stdio};

/// Integrate with external tools
fn run_external_validator(filename: &str) -> Result<bool, Box<dyn std::error::Error>> {
    // First, validate with our internal validator
    let content = std::fs::read_to_string(filename)?;
    let esm_file = load(&content)?;
    let internal_result = validate(&esm_file);

    if !internal_result.valid {
        return Ok(false);
    }

    // Then run external validation tool
    let output = Command::new("external_esm_validator")
        .arg(filename)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()?;

    Ok(output.status.success())
}
```

## Next Steps

- **Reference** — Browse the [Rust API Reference](../api/rust/)
- **Source** — Read the [earthsci-ast-rs crate source](https://github.com/EarthSciML/EarthSciAST/tree/main/pkg/earthsci-ast-rs)
- **Examples** — Explore the [examples directory](../examples/)

## Common Patterns

### Builder Pattern for Model Construction

```rust
use earthsci_ast::{EsmFile, Model, ModelVariable, ModelEquation, Metadata};

pub struct EsmBuilder {
    file: EsmFile,
}

impl EsmBuilder {
    pub fn new(name: &str) -> Self {
        Self {
            file: EsmFile {
                esm: "0.1.0".to_string(),
                metadata: Metadata {
                    name: name.to_string(),
                    description: None,
                    author: None,
                    created: chrono::Utc::now().format("%Y-%m-%d").to_string(),
                },
                models: HashMap::new(),
                ..Default::default()
            },
        }
    }

    pub fn add_model(mut self, model: Model) -> Self {
        self.file.models.insert(model.name.clone(), model);
        self
    }

    pub fn build(self) -> EsmFile {
        self.file
    }
}

// Usage
let esm_file = EsmBuilder::new("Atmospheric Chemistry")
    .add_model(
        Model {
            name: "atmosphere".to_string(),
            variables: vec![
                ModelVariable {
                    name: "O3".to_string(),
                    var_type: "state".to_string(),
                    units: Some("molec/cm^3".to_string()),
                    ..Default::default()
                }
            ],
            equations: vec![
                ModelEquation {
                    lhs: "O3".to_string(),
                    rhs: parse_expression(r#"{"op": "*", "args": ["-k", "O3"]}"#).unwrap(),
                    ..Default::default()
                }
            ],
            ..Default::default()
        }
    )
    .build();
```

Ready for high-performance ESM processing? Browse the [Rust API Reference](../api/rust/) and the [crate source](https://github.com/EarthSciML/EarthSciAST/tree/main/pkg/earthsci-ast-rs).