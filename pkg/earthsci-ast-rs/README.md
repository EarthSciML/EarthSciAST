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
examples and benches as an rpath, so none of those has to carry
`LD_LIBRARY_PATH` at run time (`readelf -d <binary> | grep RUNPATH` to check).
The one exception is doctests: rustdoc links its own test binary and a build
script's link arguments do not reach it, so with the feature on that binary
fails to load the extension. Either skip the doc step or give it the path:

```bash
cargo test --features xla --lib --tests                       # everything but doctests
LD_LIBRARY_PATH="$XLA_EXTENSION_DIR/lib" cargo test --features xla --doc
```

A default build neither links the extension nor needs any of this:
`cargo check --all-targets` with default features stays green on a machine
that has never heard of XLA.

### Running on a GPU

`EARTHSCI_XLA_PLATFORM=gpu` (or `=cuda`) selects a GPU PJRT client;
`EARTHSCI_XLA_GPU_MEMORY_FRACTION` (default 0.75) and
`EARTHSCI_XLA_GPU_PREALLOCATE=1` tune its allocator. CPU is the default.

A GPU run needs two things beyond a CPU one, and they fail in different
places:

1. **the CUDA extension.** `scripts/fetch-xla-extension.sh --variant cuda12`,
   then rebuild — `build.rs` bakes the rpath at BUILD time, so pointing
   `XLA_EXTENSION_DIR` at the CUDA tree after the fact changes nothing. With
   the CPU extension, `EARTHSCI_XLA_PLATFORM=gpu` fails inside
   `xla_runtime::client()` with a message that says which case it looks like.
2. **the CUDA shared libraries the CUDA extension hard-links.** cuDNN, NCCL,
   nvshmem, cuBLAS, cuFFT, cuSPARSE, nvJitLink, the CUDA runtime and NVRTC are
   `DT_NEEDED` entries, not `dlopen` calls, so the dynamic loader wants all of
   them before `main` runs whether or not the program uses any. A stock node
   with a driver and a toolkit does not have them. A missing one is therefore
   NOT a Rust error — it is `error while loading shared libraries:
   libcudnn.so.9` and no output at all.

   `scripts/setup-xla-gpu-libs.sh --prefix <dir outside the repo>` builds a
   directory that satisfies every one of them from pinned NVIDIA wheels, plus
   the `ptxas` XLA needs to assemble its kernels (without which every GPU
   compilation fails with "No PTX compilation provider is available"), and
   prints the lines to export:

   ```bash
   scripts/fetch-xla-extension.sh --variant cuda12 --dest "$HOME/xla"
   export XLA_EXTENSION_DIR=$HOME/xla/xla_extension-0.10.0-cuda12/xla_extension
   cargo build --features conformance-adapters,xla   # rpath baked here

   eval "$(scripts/setup-xla-gpu-libs.sh --prefix "$HOME/xla-gpu-libs" --quiet)"
   # -> LD_LIBRARY_PATH, XLA_FLAGS=--xla_gpu_cuda_data_dir=..., EARTHSCI_XLA_PLATFORM=gpu
   ```

   The script also builds a stub for `nvshmem_transport_ibrc.so.3`: the
   extension names that soname and the nvshmem wheel ships its transports at
   ABI 6. Nothing calls into the transport on ONE node, so a stub satisfies
   the loader; it would be wrong for a multi-node nvshmem collective, and the
   generated file says so.

On a batch system the job needs a GPU, real-disk scratch, and the exports
above — generically:

```bash
#SBATCH --gres=gpu:1
#SBATCH --mem=24000
export TMPDIR=<a real-disk directory>        # XLA writes compilation scratch here;
                                             # a RAM-backed /tmp is an OOM kill
source <the exports printed by setup-xla-gpu-libs.sh>
cargo test --release --features conformance-adapters,xla --test xla_compiled_rhs \
  -- --nocapture --test-threads=1
```

`tests/xla_compiled_rhs.rs` has a GPU arm that runs the whole `compiled_rhs`
tier when `EARTHSCI_XLA_PLATFORM=gpu` is set and skips with a message
otherwise. It checks the client's platform NAME before any fixture, so a build
that silently fell back to CPU fails rather than passing.

`earthsci-xla-device-probe` (a `xla`-feature binary) reports what the client
picked and what a device costs: `devices`, `largest`, `residency
<fixture.esm> [iters]`, `multidevice`.

### Device-resident state

`CompiledRhs::eval(u, p, t)` is a pure function of host data: it uploads the
state and parameters, runs, and downloads the derivative. That is right for
the conformance tier, which evaluates unrelated probe states, and wrong for a
solver, which evaluates a state it just produced — there the two transfers per
call move the same numbers off the device and straight back on.

`CompiledRhs::on_device(u, p)` returns a `DeviceRhs` that splits the transfer
from the evaluation:

```rust,ignore
let rhs = CompiledRhs::compile(&model)?;          // once per model
let mut dev = rhs.on_device(&u0, &params)?;       // one upload
for k in 0..steps {
    dev.euler_step(t0 + dt * k as f64, dt)?;      // rhs + update, entirely on device
}
let u = dev.state_to_host()?;                     // one download
```

* `eval_at(t)` runs against the buffers already on the device and leaves the
  derivative there; nothing crosses to the host.
* `du_to_host()` / `state_to_host()` are the transfers, made explicit — call
  them when you want the numbers, not once per step.
* `du_device()` hands the resident derivative to another device computation.
* `set_state(u)` re-uploads from the host, for a caller that is not stepping.
* `euler_step(t, dt)` does `u <- u + dt * f(u, p, t)` through a second tiny
  compiled program, so the loop above has no transfer in it at all. It is
  there to make the residency usable, not because explicit Euler is a good
  integrator: a real solver would fuse its stage into the emitted program.

`t` is re-uploaded every call — it is one scalar, and keeping it resident
would cost another compiled program to advance it.

### Multi-device: not available through `xla` 0.4.4

Sharding a model's state across several GPUs is **not reachable** from this
crate version, and the gap is in the crate's C++ shim (`xla_rs/xla_rs.cc`),
not in XLA:

* `compile` constructs `CompileOptions options;` and passes it unchanged, so
  every executable is built with `num_replicas = 1`, `num_partitions = 1`,
  `use_spmd_partitioning = false` and the default device assignment. None of
  those is settable from Rust.
* `execute` and `execute_b` both call `exe->Execute({input_buffer_ptrs},
  options)` — one argument group, i.e. one replica. A replicated executable
  could not be fed even if one could be built.
* `XlaBuilder::SetSharding` / `OpSharding` are not wrapped, so the emitter
  cannot annotate operations for SPMD partitioning.

What IS reachable: `PjRtClient::devices` / `addressable_devices`,
`buffer_from_host_buffer(.., Some(&device))` to place a buffer on a chosen
device, and `PjRtBuffer::copy_to_device`. `earthsci-xla-device-probe
multidevice` prints what each of these does on the machine you run it on.
Until the shim grows the three items above, use one process per GPU
(`CUDA_VISIBLE_DEVICES`) for independent work.

## License

MIT

## Contributing

Please see the main repository for contribution guidelines.
