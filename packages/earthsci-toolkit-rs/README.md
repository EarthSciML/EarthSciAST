# EarthSci Toolkit - Rust Implementation

Rust implementation of the EarthSciML Serialization Format (ESM).

## Features

- **Core**: Parse, serialize, pretty-print, substitute, validate (schema + structural)
- **Analysis**: Unit checking, equation counting, structural validation, component graphs
- **Simulation**: diffsol-backed ODE integration plus a vectorized array/PDE runtime
- **CLI Tool**: `esm` command-line interface for validation, conversion, analysis, and simulation
- **WASM**: WebAssembly compilation for in-browser loading, validation, and 0-D simulation
- **Conformance**: Adapter binaries for the cross-language conformance harness

## Installation

### As a Library

Add this to your `Cargo.toml`:

```toml
[dependencies]
earthsci-toolkit = "0.8"
```

### As a CLI Tool

```bash
cargo install earthsci-toolkit
```

(The `cli` feature is part of the default feature set.)

### For WASM

```bash
wasm-pack build --target web --features wasm
```

## Usage

### Library

```rust
use earthsci_toolkit::{load, save, validate};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Load an ESM file (parses, schema-validates, and runs the load-time
    // lowering passes)
    let content = std::fs::read_to_string("model.esm")?;
    let esm_file = load(&content)?;

    // Validate it (structural checks on the typed representation)
    let validation_result = validate(&esm_file);
    if !validation_result.is_valid {
        for error in &validation_result.structural_errors {
            println!("Error: {}", error.message);
        }
    }

    // Save it back
    let json = save(&esm_file)?;
    println!("{json}");
    Ok(())
}
```

To simulate:

```rust
use earthsci_toolkit::{load, simulate, SimulateOptions};
use std::collections::HashMap;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let esm_file = load(&std::fs::read_to_string("model.esm")?)?;
    let sol = simulate(
        &esm_file,
        (0.0, 10.0),
        &HashMap::new(), // parameter overrides
        &HashMap::new(), // initial-condition overrides
        &SimulateOptions::default(),
    )?;
    println!("{} output points", sol.time.len());
    Ok(())
}
```

### CLI

```bash
# Validate an ESM file
esm validate model.esm

# Convert to compact JSON
esm convert model.esm -o model_compact.json --to compact-json

# Pretty print expressions (unicode, latex, or ascii)
esm pretty model.esm -f latex

# Run a simulation
esm simulate model.esm --time 10 -o results.json

# Analyze structure / complexity / coupling
esm analyze model.esm

# Batch-validate a directory of fixtures
esm validate-fixtures tests/valid --recursive

# Show file information
esm info model.esm
```

Run `esm --help` for the full command list.

## Examples

Runnable examples live in `examples/` (`cargo run --example <name>`):
`roundtrip_expression` (also driven by the property-corpus conformance
script), `pde_conformance`, `canonical_expand`, `segmented_refresh_solve`,
and `unit_validation`.

## Building

### Library and CLI

```bash
cargo build --release
```

### WASM

```bash
wasm-pack build --target web --features wasm
```

## Development

Run tests:

```bash
cargo test
```

Run tests with all features:

```bash
cargo test --all-features
```

Run benchmarks (the bench target is gated behind the `benchmarks` feature, so
a plain `cargo bench` builds nothing):

```bash
cargo bench --features benchmarks
```

Format code:

```bash
cargo fmt
```

Lint:

```bash
cargo clippy --all-targets --all-features
```

## Cargo features

- `default`: `cli`
- `cli`: the `esm` command-line binary (requires clap)
- `wasm`: WebAssembly bindings (requires wasm-bindgen)
- `parallel` / `simd` / `zero_copy` / `custom_alloc` / `performance`:
  opt-in experimental performance utilities in the `performance` module
  (benchmark support; not used by the core simulate paths)
- `benchmarks`: enables the criterion bench target

## License

MIT

## Contributing

Please see the main repository for contribution guidelines.
