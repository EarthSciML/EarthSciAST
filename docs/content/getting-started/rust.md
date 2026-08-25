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
use earthsci_ast::{load_path, load_string, to_json, validate, EsmFile};
use std::fs;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // From a path, or from a string you already hold
    let esm_file: EsmFile = load_path("model.esm")?;
    let _also: EsmFile = load_string(&fs::read_to_string("model.esm")?)?;

    // `models` is optional in the schema, so it is an Option<IndexMap<..>>
    if let Some(models) = &esm_file.models {
        for (name, model) in models {
            println!("{name}: {} variables", model.variables.len());
        }
    }

    // ValidationResult { is_valid, schema_errors, structural_errors, unit_warnings }
    let result = validate(&esm_file);
    if result.is_valid {
        println!("Valid");
    } else {
        for e in &result.schema_errors { eprintln!("schema: {e:?}"); }
        for e in &result.structural_errors { eprintln!("structural: {e:?}"); }
    }

    // Unit findings are warnings; they never make a document invalid
    for w in &result.unit_warnings { eprintln!("units: {w:?}"); }

    fs::write("output.esm", to_json(&esm_file)?)?;
    Ok(())
}
```

`load_path_with_options` takes metaparameter bindings and a base path when the
document is metaparameterized or uses `$ref`.

### Working with Expressions

`parse_expression` reads infix source and returns an [`Expr`]:

```rust
use earthsci_ast::{parse_expression, to_unicode, to_latex, substitute, free_variables, Expr};
use std::collections::HashMap;

fn expression_example() -> Result<(), Box<dyn std::error::Error>> {
    let expr: Expr = parse_expression("x + y^2")?;

    println!("{}", to_unicode(&expr));
    println!("{}", to_latex(&expr));

    let vars = free_variables(&expr);        // HashSet<String>
    println!("{vars:?}");

    // Substitution maps a name to an expression, not to a string
    let mut subs: HashMap<String, Expr> = HashMap::new();
    subs.insert("x".to_string(), parse_expression("2")?);

    let out = substitute(&expr, &subs);
    println!("{}", to_unicode(&out));
    Ok(())
}
```

## CLI Tool Usage

`esm --help` lists every subcommand; `esm <command> --help` gives its flags. The
most commonly used ones:

### Validation
```bash
esm validate model.esm              # exit status reflects validity
esm validate model.esm --verbose    # detailed findings
```

`validate` takes exactly one file. Use the shell to walk several:

```bash
for f in models/*.esm; do esm validate "$f"; done
```

### Format conversion
```bash
esm convert model.esm --to json                  # to stdout
esm convert model.esm --to compact-json -o out.json
```

`--to` accepts `json` (default) and `compact-json`.

### Expression pretty-printing
```bash
esm pretty model.esm                 # Unicode (default)
esm pretty model.esm -f latex        # also: unicode, ascii
```

`display` is an alias for `pretty`.

### Information and analysis
```bash
esm info model.esm                                  # summary of the document
esm analyze model.esm                               # all analyses
esm analyze model.esm --analysis-type complexity    # also: structure, coupling
esm units model.esm                                 # dimensional analysis report
esm coupling-analysis model.esm                     # coupling dependencies
esm compare a.esm b.esm                             # model difference report
esm diff a.esm b.esm                                # semantic comparison
```

### Schema and fidelity checks
```bash
esm schema-check model.esm                          # JSON schema compliance
esm schema-check model.esm --schema-version 1.0.0
esm round-trip model.esm                            # load/save fidelity
esm validate-fixtures tests/                        # batch validation
```

### Other subcommands

`extract` (pull one component out), `stoich` (stoichiometric matrix), `graph`
(system or expression graphs), `simulate`, `optimize`, `init` (new project from
a template), `benchmark`, `performance-profile`, and `conformance-test`.

## Advanced Library Usage

### Error Handling

Fallible entry points return `EsmError`, whose variants name the stage that
failed:

```rust
use earthsci_ast::{load_path, validate, EsmError};

fn robust_loading(path: &str) -> Result<(), EsmError> {
    let esm_file = match load_path(path) {
        Ok(f) => f,
        Err(EsmError::JsonParse(e))            => { eprintln!("bad JSON: {e}"); return Err(EsmError::JsonParse(e)); }
        Err(EsmError::SchemaValidation(m))     => { eprintln!("schema: {m}");   return Err(EsmError::SchemaValidation(m)); }
        Err(EsmError::StructuralValidation(m)) => { eprintln!("structural: {m}"); return Err(EsmError::StructuralValidation(m)); }
        Err(e)                                 => { eprintln!("load failed: {e}"); return Err(e); }
    };

    let result = validate(&esm_file);
    if !result.is_valid {
        for e in &result.schema_errors     { eprintln!("schema: {e:?}"); }
        for e in &result.structural_errors { eprintln!("structural: {e:?}"); }
        return Err(EsmError::StructuralValidation(
            format!("{path} failed validation")));
    }

    println!("Loaded and validated {path}");
    Ok(())
}
```

The full variant set is `JsonParse`, `SchemaValidation`, `StructuralValidation`,
`ExpressionEvaluation`, `UnitValidation`, `FileRead`, `FileWrite`, and `Other`.

### Performance

There is no separate streaming or zero-copy parser — `load_path` /
`load_string` are the parsing surface, and the crate gets its speed from what
happens *inside* them:

- **Load-time interning.** Structurally identical expression subtrees are
  hash-consed onto one `Arc<ExpressionNode>` while they are deserialized, so a
  template-expanded discretization never materializes its duplicate subtrees.
  This makes `Expr::clone` O(1) for operator trees.
- **Common-subexpression elimination.** The simulation path evaluates each
  distinct subtree once per scope rather than once per occurrence.

Practical guidance:

```rust
use earthsci_ast::{load_path, validate};

// Load once and reuse — parsing, reference resolution and the template
// rewrite all happen in load_path.
let esm_file = load_path("model.esm")?;
for _ in 0..100 {
    let _ = validate(&esm_file);
}
# Ok::<(), earthsci_ast::EsmError>(())
```

Cargo features control how much of the crate you compile:

| Feature | Default | What it adds |
| --- | --- | --- |
| `cli` | on | the `esm` binary (pulls in `clap`) |
| `solve` | on | the ODE solver (pulls in `diffsol`) |
| `wasm` | off | the WebAssembly bindings |
| `esio` | off | the EarthSciIO data-provider bridge |
| `conformance-adapters` | off | the cross-language conformance adapter binaries |

For a library-only dependency, turn the defaults off:

```toml
[dependencies]
earthsci-ast = { version = "0.1", default-features = false }
```

### Custom Validation Rules

There is no `Validator` trait to implement — a custom rule is a plain function
over `&EsmFile` that you run alongside `validate`:

```rust
use earthsci_ast::{load_path, validate, EsmFile, VariableType};

/// Every model must declare at least one unknown, and be lowercase-named.
fn house_rules(esm_file: &EsmFile) -> Vec<String> {
    let mut problems = Vec::new();
    let Some(models) = &esm_file.models else { return problems };

    for (name, model) in models {
        if *name != name.to_lowercase() {
            problems.push(format!("models.{name}: model names must be lowercase"));
        }

        let unknowns = model
            .variables
            .values()
            .filter(|v| v.var_type == VariableType::Unknown)
            .count();

        if unknowns == 0 {
            problems.push(format!("models.{name}.variables: no unknown declared"));
        }
    }
    problems
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let esm_file = load_path("model.esm")?;

    let standard = validate(&esm_file);
    let custom = house_rules(&esm_file);

    if standard.is_valid && custom.is_empty() {
        println!("Passed all validation checks");
    } else {
        for p in custom { eprintln!("{p}"); }
    }
    Ok(())
}
```

Note the esm 1.0.0 variable model: there are exactly two declared types,
`VariableType::Unknown` and `VariableType::Parameter`. Whether an unknown is an
ODE state or an observed follows from the equation that defines it, not from a
declared type.

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
    const esmData = '{"esm": "1.0.0", "metadata": {"name": "Test"}}';

    try {
        const esmFile = loadString(esmData);
        console.log('Loaded:', esmFile.metadata.name);

        const validation = validate(esmFile);
        if (validation.isValid) {
            console.log('✓ Valid ESM file');
        } else {
            [...validation.schemaErrors, ...validation.structuralErrors]
                .forEach(error => console.error('✗', error));
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
                const esmFile = loadString(content);
                const validation = validate(esmFile);

                if (validation.isValid) {
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
            "esm": "1.0.0",
            "metadata": {
                "name": "Test Model"
            }
        }"#;

        let esm_file = load_string(esm_data).unwrap();
        assert_eq!(esm_file.metadata.name, "Test Model");
    }

    #[test]
    fn test_validation_catches_errors() {
        let invalid_esm = r#"
        {
            "esm": "1.0.0",
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

        let esm_file = load_string(invalid_esm).unwrap();
        let validation = validate(&esm_file);
        assert!(!validation.is_valid);
        assert!(!validation.structural_errors.is_empty()
                || !validation.schema_errors.is_empty());
    }

    #[test]
    fn test_expression_substitution() {
        // `Expr` is Integer | Number | Variable | Operator(Arc<ExpressionNode>),
        // and n-ary — not a binary tree. Build one by parsing.
        let expr = parse_expression("x + y").unwrap();

        let mut substitutions: HashMap<String, Expr> = HashMap::new();
        substitutions.insert("x".to_string(), parse_expression("2").unwrap());

        let result = substitute(&expr, &substitutions);

        // x is gone, y remains
        let free = free_variables(&result);
        assert!(!free.contains("x"));
        assert!(free.contains("y"));
        assert_eq!(to_unicode(&result), "2 + y");
    }
}
```

### Benchmarking

```rust
use criterion::{black_box, criterion_group, criterion_main, Criterion};
use earthsci_ast::{load_string, validate};

fn bench_load_large_file(c: &mut Criterion) {
    let large_esm = generate_large_test_file(1000); // 1000 models

    c.bench_function("load_large_file", |b| {
        b.iter(|| {
            let esm_file = load_string(black_box(&large_esm)).unwrap();
            black_box(esm_file);
        });
    });
}

fn bench_validation(c: &mut Criterion) {
    let esm_data = std::fs::read_to_string("test_data/complex_model.esm").unwrap();
    let esm_file = load_string(&esm_data).unwrap();

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
use earthsci_ast::{validate, EsmFile, ValidationResult};
use serde::Deserialize;

#[derive(Deserialize)]
struct ValidationConfig {
    /// Treat dimensional-analysis findings as failures
    strict_units: bool,
    /// Reject models that declare a variable no equation mentions
    allow_unused_variables: bool,
}

/// The crate ships one `validate`; policy on top of it is yours.
fn validate_with_config(esm_file: &EsmFile, config: &ValidationConfig) -> bool {
    let result: ValidationResult = validate(esm_file);
    if !result.is_valid {
        return false;
    }

    // `unit_warnings` are advisory by design — promote them only if asked
    if config.strict_units && !result.unit_warnings.is_empty() {
        for w in &result.unit_warnings {
            eprintln!("units: {w:?}");
        }
        return false;
    }

    if !config.allow_unused_variables {
        if let Some(models) = &esm_file.models {
            for (name, model) in models {
                if model.equations.is_empty() && !model.variables.is_empty() {
                    eprintln!("models.{name}: variables declared but no equations");
                    return false;
                }
            }
        }
    }

    true
}
```

### Pipeline Integration

```rust
use std::process::{Command, Stdio};

/// Integrate with external tools
fn run_external_validator(filename: &str) -> Result<bool, Box<dyn std::error::Error>> {
    // First, validate with our internal validator
    let content = std::fs::read_to_string(filename)?;
    let esm_file = load_string(&content)?;
    let internal_result = validate(&esm_file);

    if !internal_result.is_valid {
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