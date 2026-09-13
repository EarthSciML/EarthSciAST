# EarthSci Toolkit - Rust Implementation

Rust implementation of the EarthSciML Abstract Syntax Tree Format (ESM).

## Features

- **Core**: Parse, serialize, pretty-print, substitute, validate (schema + structural)
- **Analysis**: Unit checking, stoichiometric matrices, structural validation, component graphs
- **Simulation**: diffsol-backed ODE integration plus a vectorized array/PDE runtime
- **CLI Tool**: `esm` command-line interface for validation, conversion, analysis, and simulation
- **WASM**: WebAssembly compilation for in-browser loading, validation, and 0-D simulation
- **Conformance**: Adapter binaries for the cross-language conformance harness

## Installation

### As a Library

Add this to your `Cargo.toml`:

```toml
[dependencies]
earthsci-ast = "0.8"
```

### As a CLI Tool

```bash
cargo install earthsci-ast
```

(The `cli` feature is part of the default feature set.)

### For WASM

```bash
wasm-pack build --target web --features wasm
```

## Usage

### Library

```rust
use earthsci_ast::{load, save, validate};

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
use earthsci_ast::{load, simulate, SimulateOptions};
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

# Write GRIDDED output: dimension-labeled, row-major [time, ...spatial]
# arrays with CF coordinates, plus the named observed fields alongside the
# state (repeat --observed for several).
esm simulate model.esm --time 10 --observed flux --format grid -o results.json

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
- `conformance-adapters`: the cross-language conformance adapter binaries
- `esio`: the EarthSciIO data-provider bridge
- `xla`: the compiled right-hand-side backend (see below)

## Compiled right-hand side (`xla` feature)

`simulate_array::tape` compiles a model's observed + RHS rules into a flat
instruction program. With the **non-default** `xla` feature that program can
also be emitted as an XLA computation

```text
rhs(u: f64[N], p: f64[M], t: f64[]) -> du: f64[N]
```

and run through PJRT (`earthsci_ast::xla_runtime`), instead of being
interpreted by the slab executor.

Two properties are deliberate:

* **No fallback.** A model carrying any rule the emitter cannot lower is a
  hard error naming the rule and the reason, never a partly-interpreted run.
  The `compiled_rhs` conformance tier records such a model as a named
  refusal.
* **Numerical, not bitwise, agreement.** XLA's `exp`/`log`/`pow` are not
  Rust's libm. The tier's tolerance classes
  (`tests/conformance/compiled_rhs/README.md`) are the contract.

### Setup

The feature links a prebuilt `xla_extension` release (144 MB for CPU), which
this repository does **not** vendor. Fetch it once, outside the checkout:

```bash
scripts/fetch-xla-extension.sh --variant cpu        # or --variant cuda12
export XLA_EXTENSION_DIR=$HOME/.cache/earthsci/xla/xla_extension-0.10.0-cpu/xla_extension
```

The script verifies a pinned SHA-256 before unpacking and prints the exact
`export` line for the directory it chose.

Building also needs a C++ toolchain and libclang for the `xla` crate's
bindgen step:

```bash
export LIBCLANG_PATH=/path/to/llvm/lib          # directory holding libclang.so
cargo build --features xla
cargo test  --features xla
```

`build.rs` bakes `$XLA_EXTENSION_DIR/lib` into this crate's binaries, tests,
examples and benches as an rpath, so nothing has to carry `LD_LIBRARY_PATH`
at run time (`readelf -d <binary> | grep RUNPATH` to check). A default build
neither links the extension nor needs any of this: `cargo check --all-targets`
with default features stays green on a machine that has never heard of XLA.

`EARTHSCI_XLA_PLATFORM=gpu` selects a GPU PJRT client (needs the `cuda12`
extension and a visible device); CPU is the default and the only configuration
this backend has been exercised on.

## License

MIT

## Contributing

Please see the main repository for contribution guidelines.
