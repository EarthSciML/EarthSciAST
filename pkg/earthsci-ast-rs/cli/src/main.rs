//! The `esm` binary target: a native-only command-line tool.
//!
//! The implementation is `esm_impl.rs` next to this file, and it is compiled
//! ONLY for native targets. It reads files, drives the build pipeline and
//! constructs data providers -- none of which exist on `wasm32`, where
//! `ProblemOptions` carries no build half at all (`build_pipeline`,
//! `build_providers`, `PrepareProvider` and friends are all
//! `cfg(not(target_arch = "wasm32"))`).
//!
//! The gate has to live HERE rather than in the workflow: cargo builds every
//! declared bin for whatever `--target` it is handed, and it builds bins even
//! for `cargo test --test <name>`, so both the wasm build step and the wasm
//! test suite pulled this in. `autobins = false` in Cargo.toml is what keeps
//! `esm_impl.rs` from being discovered as a second binary target.

#[cfg(not(target_arch = "wasm32"))]
#[path = "esm_impl.rs"]
mod esm_impl;

#[cfg(not(target_arch = "wasm32"))]
fn main() -> std::process::ExitCode {
    esm_impl::main()
}

/// On `wasm32` the CLI is an empty stub, so the crate still builds for the
/// target without the command-line tool coming along.
#[cfg(target_arch = "wasm32")]
fn main() {}
